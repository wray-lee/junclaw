//! The dsh adapter: `Harness` implemented over the dsh web sidecar.
//!
//! P1 scope (see .scratch/dsh-sidecar-design.md §4): spawn one sidecar, capture
//! the owner cookie, keep one WS stream per process, map junclaw session keys to
//! dsh session ids, stream assistant text as `Event.delta`, answer `/stop` with
//! `session/cancel` and `/new` with a fresh dsh session.
//!
//! P1 explicitly omits the P2 surface: approvals, user questions, steer
//! injection and the approval/question UI. `approval/request` frames are
//! dropped (their payload may contain command text, so they are never logged).
//!
//! Auth: the launch URL carries a per-process token and the owner cookie is a
//! bearer credential. This module logs neither; a future log line must render
//! the URL through `client.redactUrl` and must never print the cookie.

const std = @import("std");
const std_compat = @import("compat");
const providers = @import("../../providers/root.zig");
const agent_mod = @import("../../agent/root.zig");
const port = @import("../port.zig");
const client_mod = @import("client.zig");
const sidecar_mod = @import("sidecar.zig");

const Allocator = std.mem.Allocator;
const DshClient = client_mod.DshClient;

/// How often a waiting turn wakes to check `interrupt_requested`.
/// shortcut: a poll slice instead of an eventfd; /stop lands within one slice.
const poll_slice_ms: u64 = 50;

/// Same text `Agent.handleSlashCommand("/stop")` returns, so the host renders a
/// dsh stop exactly like a native one (the turn reply carries the partial text).
const stop_ack = "No active background task to stop.";
/// Same text `Agent.handleSlashCommand("/new")` returns.
const new_session_ack = "Session cleared.";

/// `Harness` over one dsh web sidecar.
///
/// Options slices are borrowed for the harness lifetime (the same contract as
/// `sidecar.Options`); `session_file` is read at init and rewritten on create.
pub const DshHarness = struct {
    const Self = @This();

    pub const Options = struct {
        /// Sidecar launch options; ignored when `boot_url` is set.
        sidecar: sidecar_mod.Options,
        /// Use this launch URL instead of spawning a process (tests, or an
        /// externally managed sidecar). The owner-cookie exchange still runs.
        boot_url: ?[]const u8 = null,
        /// Persist `{"sessionId":…}` here so a new process resumes the session.
        /// Null disables cross-process resume.
        session_file: ?[]const u8 = null,
        /// Hang guard for one turn waiting on a terminal `turn/end`.
        turn_timeout_ms: u64 = 30_000,
        /// Hang guard for `/stop` waiting on dsh's aborted `turn/end`.
        cancel_timeout_ms: u64 = 10_000,
    };

    allocator: Allocator,
    opts: Options,
    /// Set only when this harness spawned the process; `boot_url` bypasses it.
    /// P1 has no auto-restart loop: a dead sidecar surfaces as an error from the
    /// next RPC. `sidecar.restart`/`backoffDelayMs` are ready for the P2 loop.
    sidecar: ?sidecar_mod.Sidecar = null,
    client: DshClient,
    client_live: bool = true,
    connected: bool = false,
    /// Owned copies: rebuilding the client after `/new` needs them.
    base_url: []u8,
    cookie: []u8,
    /// Current dsh session; null until created or loaded from `session_file`.
    session_id: ?[]u8 = null,
    /// junclaw key the current dsh session belongs to; null for a resumed id
    /// adopted by the first turn.
    current_key: ?[]u8 = null,
    /// Host-set before a turn, exactly like NativeHarness.session_key.
    session_key: []const u8 = "",
    /// dsh is single-flight per session: a second turn waits here and runs as
    /// the next queued prompt (P1: no steer injection).
    turn_mutex: std_compat.sync.Mutex = .{},
    interrupt_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: Allocator, opts: Options) !DshHarness {
        var spawned: ?sidecar_mod.Sidecar = null;
        var cookie: ?[]u8 = null;
        var base_url: ?[]u8 = null;
        errdefer {
            if (spawned) |*sidecar| sidecar.deinit();
            if (cookie) |value| allocator.free(value);
            if (base_url) |value| allocator.free(value);
        }

        const boot_url = if (opts.boot_url) |url| url else blk: {
            spawned = try sidecar_mod.Sidecar.start(allocator, opts.sidecar);
            break :blk spawned.?.boot_url orelse return error.SidecarNotStarted;
        };
        cookie = try sidecar_mod.fetchOwnerCookieForUrl(allocator, boot_url);
        const endpoint = try client_mod.parseBootEndpoint(boot_url);
        base_url = try allocator.dupe(u8, endpoint.base_url);

        const dsh_client = try DshClient.init(allocator, base_url.?, cookie.?);

        var self = DshHarness{
            .allocator = allocator,
            .opts = opts,
            .sidecar = spawned,
            .client = dsh_client,
            .base_url = base_url.?,
            .cookie = cookie.?,
        };
        // Ownership moved into `self`.
        spawned = null;
        cookie = null;
        base_url = null;
        errdefer self.deinit();

        if (opts.session_file) |path| {
            // A corrupt mapping falls back to a fresh session (design §2.2).
            const persisted = sidecar_mod.loadSessionId(allocator, path) catch null;
            if (persisted) |session_id| {
                errdefer allocator.free(session_id);
                try self.client.connect(session_id);
                self.connected = true;
                self.session_id = session_id;
            }
        }
        return self;
    }

    /// Release the client, the sidecar process and every owned slice; does not
    /// destroy `self` (the vtable deinit does that for host-owned instances).
    pub fn deinit(self: *Self) void {
        if (self.client_live) {
            self.client.deinit();
            self.client_live = false;
        }
        if (self.sidecar) |*sidecar| sidecar.deinit();
        self.allocator.free(self.base_url);
        self.allocator.free(self.cookie);
        if (self.session_id) |session_id| self.allocator.free(session_id);
        if (self.current_key) |key| self.allocator.free(key);
    }

    pub fn harness(self: *Self) port.Harness {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// True while a stop is waiting for the next turn to consume it. The host
    /// checks this before pre-routing a local command: a pre-turn /stop must
    /// abort that command the way native's `Agent.turn` check does.
    pub fn interruptPending(self: *Self) bool {
        return self.interrupt_requested.load(.acquire);
    }

    // ── session mapping ─────────────────────────────────────────────────────

    /// Junclaw key → dsh session id. The first turn after a restart adopts the
    /// persisted id; later turns reuse it; a different key gets a fresh session
    /// (P1 keeps one session per sidecar; multi-key routing is T4's selection).
    fn ensureSession(self: *Self) !void {
        if (self.session_id) |session_id| {
            if (self.current_key) |key| {
                if (std.mem.eql(u8, key, self.session_key)) {
                    if (!self.connected) try self.reconnect(session_id);
                    return;
                }
            } else {
                if (!self.connected) try self.reconnect(session_id);
                try self.setCurrentKey(self.session_key);
                return;
            }
            try self.startFreshSession();
            return;
        }
        try self.startFreshSession();
    }

    /// `/new` and key switches: close the old session, create and persist a new
    /// one, then point the client's WS at it.
    fn startFreshSession(self: *Self) !void {
        if (self.session_id) |old| {
            if (self.connected) self.client.closeSession(old) catch {};
        }
        const session_id = try self.client.createSession(self.opts.sidecar.workspace);
        errdefer self.allocator.free(session_id);
        if (self.opts.session_file) |path| try sidecar_mod.saveSessionId(path, session_id);
        try self.reconnect(session_id);
        try self.setCurrentKey(self.session_key);
        if (self.session_id) |old| self.allocator.free(old);
        self.session_id = session_id;
    }

    fn setCurrentKey(self: *Self, key: []const u8) !void {
        if (self.current_key) |old| {
            self.allocator.free(old);
            self.current_key = null;
        }
        self.current_key = try self.allocator.dupe(u8, key);
    }

    /// One DshClient speaks one session, so a session swap is a reconnect.
    fn reconnect(self: *Self, session_id: []const u8) !void {
        self.client.deinit();
        self.client_live = false;
        self.connected = false;
        self.client = try DshClient.init(self.allocator, self.base_url, self.cookie);
        self.client_live = true;
        try self.client.connect(session_id);
        self.connected = true;
    }

    // ── vtable ──────────────────────────────────────────────────────────────

    fn runTurn(ptr: *anyopaque, input: port.TurnInput) anyerror!port.TurnResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        self.turn_mutex.lock();
        defer self.turn_mutex.unlock();

        // A stop that landed before the prompt still cancels this turn, so a
        // pre-turn requestInterrupt behaves like native's.
        if (self.interrupt_requested.swap(false, .acquire)) {
            return .{ .reply = try self.allocator.dupe(u8, ""), .end_reason = .interrupted };
        }

        try self.ensureSession();
        const session_id = self.session_id.?;
        const sink = input.sink;

        try self.client.prompt(session_id, input.user_message);

        var text: std.ArrayListUnmanaged(u8) = .empty;
        errdefer text.deinit(self.allocator);

        const deadline = std_compat.time.milliTimestamp() +
            @as(i64, @intCast(self.opts.turn_timeout_ms));
        while (true) {
            if (self.interrupt_requested.swap(false, .acquire)) {
                // session/cancel is sent from this thread: the Shared event
                // queue has exactly one consumer, and cancel() consumes it
                // while waiting for the aborted turn/end.
                var cancelled = self.client.cancel(session_id, self.opts.cancel_timeout_ms) catch |err| switch (err) {
                    // The turn may have ended between the flag and the RPC; the
                    // partial text is still the best reply we have.
                    error.CancelTimeout => return .{
                        .reply = try text.toOwnedSlice(self.allocator),
                        .end_reason = .interrupted,
                    },
                    else => return err,
                };
                defer client_mod.freeCancelResult(self.allocator, &cancelled);
                if (cancelled.partial_text.len > 0) {
                    // A committed prefix replaces the deltas it finalizes.
                    if (cancelled.committed) text.clearRetainingCapacity();
                    try text.appendSlice(self.allocator, cancelled.partial_text);
                    if (!cancelled.committed) {
                        if (sink) |s| s.send(.{ .delta = providers.StreamChunk.textDelta(cancelled.partial_text) });
                    }
                }
                return .{
                    .reply = try text.toOwnedSlice(self.allocator),
                    .end_reason = mapEndReason(cancelled.kind),
                };
            }

            const remaining = deadline - std_compat.time.milliTimestamp();
            if (remaining <= 0) return error.TurnTimeout;

            var event = self.client.nextEvent(@min(@as(u64, @intCast(remaining)), poll_slice_ms)) catch |err| switch (err) {
                error.Timeout => continue,
                else => return err,
            };
            defer client_mod.freeEvent(self.allocator, &event);

            switch (event.event) {
                .assistant_chunk => |chunk| switch (chunk) {
                    .text_delta => |delta| {
                        try text.appendSlice(self.allocator, delta.text);
                        if (sink) |s| s.send(.{ .delta = providers.StreamChunk.textDelta(delta.text) });
                    },
                    // The port union has no tool variant; native reports tools
                    // through `Event.progress`, so mirror that.
                    .tool_call => |call| if (sink) |s| s.send(.{ .progress = .{
                        .kind = .tool,
                        .text = call.name,
                        .arguments_json = call.arguments_json,
                        .phase = .start,
                    } }),
                    .tool_result => |result| if (sink) |s| s.send(.{ .progress = .{
                        .kind = .tool,
                        .text = result.call_id,
                        .phase = .end,
                        .success = !result.is_error,
                    } }),
                    .other => {},
                },
                .committed => |message| {
                    // dsh's finalized step text replaces the delta view it
                    // finalizes, so a turn that streams and commits replies once.
                    // An empty commit (tool-call-only step) is not a reply.
                    if (message.len > 0) {
                        text.clearRetainingCapacity();
                        try text.appendSlice(self.allocator, message);
                    }
                },
                .turn_end => |turn| {
                    const reply = try text.toOwnedSlice(self.allocator);
                    errdefer self.allocator.free(reply);
                    return .{
                        .reply = reply,
                        .end_reason = mapEndReason(turn.kind),
                        .@"error" = if (turn.error_message) |message|
                            try self.allocator.dupe(u8, message)
                        else
                            null,
                    };
                },
                // P1 has no approval/question UI. The payload can carry command
                // text, so it is dropped rather than logged.
                .approval_request => {},
                .ignored, .unknown => {},
            }
        }
    }

    fn requestInterrupt(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.interrupt_requested.store(true, .release);
    }

    fn clearInterrupt(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.interrupt_requested.store(false, .release);
    }

    fn activeToolName(ptr: *anyopaque, allocator: Allocator) anyerror!?[]u8 {
        _ = ptr;
        _ = allocator;
        // Tool calls reach the host as `Event.progress`; P1 has no active-tool
        // snapshot and the host's /stop summary falls back to the generic text.
        return null;
    }

    fn restore(ptr: *anyopaque, input: port.RestoreInput) anyerror!void {
        _ = ptr;
        _ = input;
        // dsh owns the conversation history; resume is session/follow by id, so
        // there is nothing to replay into the engine.
    }

    fn reset(ptr: *anyopaque) void {
        // No local session state to clear: history and commands live in dsh.
        _ = ptr;
    }

    fn invalidatePrompt(ptr: *anyopaque) void {
        // dsh builds its own system prompt per session; nothing is cached here.
        _ = ptr;
    }

    fn info(ptr: *anyopaque) port.Info {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return .{
            .provider_name = "dsh",
            .model_name = "dsh",
            .workspace_dir = self.opts.sidecar.workspace,
            .allowed_paths = &.{},
            .has_own_autonomy = false,
            .queue_mode = .serial,
            .reasoning_mode = .off,
            .redactor = null,
        };
    }

    fn handleLocalCommand(ptr: *anyopaque, content: []const u8) anyerror!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const command = std.mem.trim(u8, content, " \t\r\n");
        if (std.mem.eql(u8, command, "/stop") or std.mem.eql(u8, command, "/abort")) {
            // Do NOT wait on turn_mutex: an active turn owns it, and that
            // turn's loop sends session/cancel and returns the partial text.
            // An idle stop only acks, like native: arming it here would cancel
            // the next prompt (tryLock succeeds only between turns).
            if (self.turn_mutex.tryLock()) {
                self.turn_mutex.unlock();
                return stop_ack;
            }
            self.interrupt_requested.store(true, .release);
            return stop_ack;
        }
        if (std.mem.eql(u8, command, "/new") or
            std.mem.eql(u8, command, "/reset") or
            std.mem.eql(u8, command, "/clear"))
        {
            // Between turns: serialize with runTurn before swapping the client.
            self.turn_mutex.lock();
            defer self.turn_mutex.unlock();
            try self.startFreshSession();
            return new_session_ack;
        }
        return null;
    }

    fn vtableDeinit(ptr: *anyopaque, allocator: Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
        allocator.destroy(self);
    }

    const vtable = port.Harness.VTable{
        .runTurn = runTurn,
        .requestInterrupt = requestInterrupt,
        .clearInterrupt = clearInterrupt,
        .activeToolName = activeToolName,
        .restore = restore,
        .reset = reset,
        .invalidatePrompt = invalidatePrompt,
        .info = info,
        .handleLocalCommand = handleLocalCommand,
        .deinit = vtableDeinit,
    };
};

/// dsh `turn/end` kind → port reason:
///   completed   → completed        interrupted → interrupted
///   aborted     → interrupted      error       → failed
///   blocked     → blocked          max-tokens  → max_tokens
///   forked      → completed
/// An unknown kind is reported as `.failed`: an end we do not understand must
/// not look like a clean completion.
fn mapEndReason(kind: []const u8) port.EndReason {
    const eq = std.mem.eql;
    if (eq(u8, kind, "completed")) return .completed;
    if (eq(u8, kind, "interrupted")) return .interrupted;
    if (eq(u8, kind, "aborted")) return .interrupted;
    if (eq(u8, kind, "error")) return .failed;
    if (eq(u8, kind, "blocked")) return .blocked;
    if (eq(u8, kind, "max-tokens")) return .max_tokens;
    if (eq(u8, kind, "forked")) return .completed;
    return .failed;
}

// Regression: dsh turn/end kind "blocked" mapped to .failed instead of port .blocked.
test "dsh end reason table" {
    try std.testing.expectEqual(port.EndReason.completed, mapEndReason("completed"));
    try std.testing.expectEqual(port.EndReason.interrupted, mapEndReason("interrupted"));
    try std.testing.expectEqual(port.EndReason.interrupted, mapEndReason("aborted"));
    try std.testing.expectEqual(port.EndReason.failed, mapEndReason("error"));
    try std.testing.expectEqual(port.EndReason.blocked, mapEndReason("blocked"));
    try std.testing.expectEqual(port.EndReason.max_tokens, mapEndReason("max-tokens"));
    try std.testing.expectEqual(port.EndReason.completed, mapEndReason("forked"));
    try std.testing.expectEqual(port.EndReason.failed, mapEndReason("mystery"));
}
