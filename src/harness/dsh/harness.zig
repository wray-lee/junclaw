//! The dsh adapter: `Harness` implemented over the dsh web sidecar.
//!
//! P1 scope (see .scratch/dsh-sidecar-design.md §4): spawn one sidecar, capture
//! the owner cookie, serve many junclaw session keys side by side on it (one dsh
//! session and one WS stream per key), stream assistant text as `Event.delta`,
//! answer `/stop` with `session/cancel` and `/new` with a fresh dsh session for
//! that key only.
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

/// `Harness` over one dsh web sidecar, shared by every junclaw session key.
///
/// Options slices are borrowed for the harness lifetime (the same contract as
/// `sidecar.Options`); each key's mapping is read on that key's first turn.
pub const DshHarness = struct {
    const Self = @This();

    pub const Options = struct {
        /// Sidecar launch options; ignored when `boot_url` is set.
        sidecar: sidecar_mod.Options,
        /// Use this launch URL instead of spawning a process (tests, or an
        /// externally managed sidecar). The owner-cookie exchange still runs.
        boot_url: ?[]const u8 = null,
        /// Persist one mapping per key next to this path as
        /// `{dir}/{Wyhash(key)}.json` (the layout `startDshHarness` uses), so a
        /// new process resumes each key's session. Null disables resume.
        session_file: ?[]const u8 = null,
        /// Hang guard for one turn waiting on a terminal `turn/end`.
        turn_timeout_ms: u64 = 30_000,
        /// Hang guard for `/stop` waiting on dsh's aborted `turn/end`.
        cancel_timeout_ms: u64 = 10_000,
    };

    /// One junclaw key's dsh session. The client's WS lives as long as the
    /// entry, so switching keys is a lookup, never a reconnect.
    /// shortcut: one WS per dsh session instead of the design's single
    /// multiplexed remote.mux stream, upgrade when the key count grows.
    const Entry = struct {
        key: []u8,
        /// This key's persisted mapping path; null when resume is disabled.
        session_file: ?[]u8 = null,
        client: DshClient,
        session_id: []u8,
        /// dsh is single-flight per session: a second turn on this key waits
        /// here and runs as the next queued prompt (P1: no steer injection).
        turn_mutex: std_compat.sync.Mutex = .{},
        interrupt_requested: std.atomic.Value(bool) = .init(false),

        fn deinit(self: *Entry, allocator: Allocator) void {
            self.client.deinit();
            allocator.free(self.key);
            if (self.session_file) |path| allocator.free(path);
            allocator.free(self.session_id);
        }
    };

    allocator: Allocator,
    opts: Options,
    /// Set only when this harness spawned the process; `boot_url` bypasses it.
    /// P1 has no auto-restart loop: a dead sidecar surfaces as an error from the
    /// next RPC. `sidecar.restart`/`backoffDelayMs` are ready for the P2 loop.
    sidecar: ?sidecar_mod.Sidecar = null,
    /// Owned copies: each entry's client is built from them.
    base_url: []u8,
    cookie: []u8,
    /// One live dsh session per junclaw key, all on this one sidecar.
    entries: std.ArrayListUnmanaged(*Entry) = .empty,
    /// Guards `entries`; entries live until deinit, so their pointers are
    /// stable outside this lock.
    entries_mutex: std_compat.sync.Mutex = .{},
    /// Host-set before a turn, exactly like NativeHarness.session_key.
    session_key: []const u8 = "",

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

        const self = DshHarness{
            .allocator = allocator,
            .opts = opts,
            .sidecar = spawned,
            .base_url = base_url.?,
            .cookie = cookie.?,
        };
        // Ownership moved into `self`.
        spawned = null;
        cookie = null;
        base_url = null;
        return self;
    }

    /// Release every key's client, the sidecar process and all owned slices;
    /// does not destroy `self` (the vtable deinit does that for host-owned
    /// instances).
    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
        if (self.sidecar) |*sidecar| sidecar.deinit();
        self.allocator.free(self.base_url);
        self.allocator.free(self.cookie);
    }

    pub fn harness(self: *Self) port.Harness {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// True while a stop is waiting for the next turn to consume it. The host
    /// checks this before pre-routing a local command: a pre-turn /stop must
    /// abort that command the way native's `Agent.turn` check does.
    pub fn interruptPending(self: *Self) bool {
        self.entries_mutex.lock();
        defer self.entries_mutex.unlock();
        const entry = self.findEntry(self.session_key) orelse return false;
        return entry.interrupt_requested.load(.acquire);
    }

    // ── session mapping ─────────────────────────────────────────────────────

    /// Per-key mapping path: `{dir}/{Wyhash(key)}.json`, the file
    /// `startDshHarness` names for its key. Caller frees; null disables resume.
    fn sessionFilePath(self: *const Self, allocator: Allocator, key: []const u8) !?[]u8 {
        const base = self.opts.session_file orelse return null;
        const dir = std_compat.fs.path.dirname(base) orelse ".";
        return try std.fmt.allocPrint(allocator, "{s}/{x}.json", .{
            dir,
            std.hash.Wyhash.hash(0, key),
        });
    }

    /// Caller holds `entries_mutex`.
    fn findEntry(self: *Self, key: []const u8) ?*Entry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry;
        }
        return null;
    }

    /// Get-or-create this key's entry: adopt the persisted id via
    /// `session/follow`, else `session/create` and rewrite its mapping file.
    /// Other keys' entries are never touched. Caller holds `entries_mutex`.
    fn ensureEntry(self: *Self) !*Entry {
        if (self.findEntry(self.session_key)) |entry| return entry;
        return self.createEntry(true);
    }

    /// Build this key's entry. `adopt` resumes the persisted id instead of
    /// creating a session. Caller holds `entries_mutex`.
    fn createEntry(self: *Self, adopt: bool) !*Entry {
        const key = self.session_key;

        const mapping = try self.sessionFilePath(self.allocator, key);
        errdefer if (mapping) |path| self.allocator.free(path);

        var client = try DshClient.init(self.allocator, self.base_url, self.cookie);
        errdefer client.deinit();

        // A corrupt mapping falls back to a fresh session (design §2.2); an id
        // dsh no longer knows surfaces as an error from this turn.
        var persisted: ?[]u8 = null;
        if (adopt) {
            if (mapping) |path| {
                persisted = sidecar_mod.loadSessionId(self.allocator, path) catch null;
            }
        }
        defer if (persisted) |session_id| self.allocator.free(session_id);

        var session_id: []u8 = undefined;
        if (persisted) |id| {
            try client.connect(id);
            session_id = try self.allocator.dupe(u8, id);
        } else {
            session_id = try client.createSession(self.opts.sidecar.workspace);
            errdefer self.allocator.free(session_id);
            if (mapping) |path| try sidecar_mod.saveSessionId(path, session_id);
            try client.connect(session_id);
        }
        errdefer self.allocator.free(session_id);

        const entry_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(entry_key);
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .key = entry_key,
            .session_file = mapping,
            .client = client,
            .session_id = session_id,
        };
        try self.entries.append(self.allocator, entry);
        return entry;
    }

    /// `/new`: close and replace only this key's session, rewriting this key's
    /// mapping. Other keys keep their client and session untouched.
    fn resetKeySession(self: *Self) !void {
        self.entries_mutex.lock();
        const maybe_entry = self.findEntry(self.session_key);
        if (maybe_entry == null) {
            defer self.entries_mutex.unlock();
            _ = try self.createEntry(false);
            return;
        }
        const entry = maybe_entry.?;
        self.entries_mutex.unlock();
        // Serialize with this key's active turn before swapping its client.
        entry.turn_mutex.lock();
        defer entry.turn_mutex.unlock();

        // Build the replacement before touching the old session, so a failed
        // create/connect leaves the key on its current session.
        var client = try DshClient.init(self.allocator, self.base_url, self.cookie);
        errdefer client.deinit();
        const session_id = try client.createSession(self.opts.sidecar.workspace);
        errdefer self.allocator.free(session_id);
        if (entry.session_file) |path| try sidecar_mod.saveSessionId(path, session_id);
        try client.connect(session_id);

        entry.client.closeSession(entry.session_id) catch {};
        entry.client.deinit();
        self.allocator.free(entry.session_id);
        entry.client = client;
        entry.session_id = session_id;
    }

    // ── vtable ──────────────────────────────────────────────────────────────

    fn runTurn(ptr: *anyopaque, input: port.TurnInput) anyerror!port.TurnResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        self.entries_mutex.lock();
        const entry = self.ensureEntry() catch |err| {
            self.entries_mutex.unlock();
            return err;
        };
        self.entries_mutex.unlock();
        // Entries live until deinit, so the pointer stays valid while this
        // key's turn runs and other keys' turns come and go.
        entry.turn_mutex.lock();
        defer entry.turn_mutex.unlock();

        // A stop that landed before the prompt still cancels this turn, so a
        // pre-turn requestInterrupt behaves like native's.
        if (entry.interrupt_requested.swap(false, .acquire)) {
            return .{ .reply = try self.allocator.dupe(u8, ""), .end_reason = .interrupted };
        }

        const session_id = entry.session_id;
        const sink = input.sink;

        try entry.client.prompt(session_id, input.user_message);

        var text: std.ArrayListUnmanaged(u8) = .empty;
        errdefer text.deinit(self.allocator);

        const deadline = std_compat.time.milliTimestamp() +
            @as(i64, @intCast(self.opts.turn_timeout_ms));
        while (true) {
            if (entry.interrupt_requested.swap(false, .acquire)) {
                // session/cancel is sent from this thread: the Shared event
                // queue has exactly one consumer, and cancel() consumes it
                // while waiting for the aborted turn/end.
                var cancelled = entry.client.cancel(session_id, self.opts.cancel_timeout_ms) catch |err| switch (err) {
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

            var event = entry.client.nextEvent(@min(@as(u64, @intCast(remaining)), poll_slice_ms)) catch |err| switch (err) {
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
        self.entries_mutex.lock();
        defer self.entries_mutex.unlock();
        const entry = self.findEntry(self.session_key) orelse return;
        entry.interrupt_requested.store(true, .release);
    }

    fn clearInterrupt(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.entries_mutex.lock();
        defer self.entries_mutex.unlock();
        const entry = self.findEntry(self.session_key) orelse return;
        entry.interrupt_requested.store(false, .release);
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
            // Do NOT wait on the key's turn mutex: an active turn owns it, and
            // that turn's loop sends session/cancel and returns the partial
            // text. An idle stop only acks, like native: arming it here would
            // cancel the next prompt (tryLock succeeds only between turns).
            self.entries_mutex.lock();
            defer self.entries_mutex.unlock();
            const entry = self.findEntry(self.session_key) orelse return stop_ack;
            if (entry.turn_mutex.tryLock()) {
                entry.turn_mutex.unlock();
                return stop_ack;
            }
            entry.interrupt_requested.store(true, .release);
            return stop_ack;
        }
        if (std.mem.eql(u8, command, "/new") or
            std.mem.eql(u8, command, "/reset") or
            std.mem.eql(u8, command, "/clear"))
        {
            try self.resetKeySession();
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
