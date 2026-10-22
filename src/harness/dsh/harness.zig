//! The dsh adapter: `Harness` implemented over the dsh web sidecar.
//!
//! P1 scope (see .scratch/dsh-sidecar-design.md §4): one sidecar per process
//! (`DshEngine`), serving many junclaw session keys side by side (one dsh
//! session and one WS stream per key), streaming assistant text as
//! `Event.delta`, answering `/stop` with `session/cancel` and `/new` with a
//! fresh dsh session for that key only.
//!
//! `DshEngine` is shared and boots lazily: `init` only fills fields, and
//! `ensureBooted` spawns the sidecar (or adopts `boot_url`) on the first dsh
//! turn, outside the session-table lock. `DshHarness` is a lightweight
//! per-session handle with an immutable `session_key`.
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
const fs_compat = @import("../../fs_compat.zig");
const providers = @import("../../providers/root.zig");
const agent_mod = @import("../../agent/root.zig");
const port = @import("../port.zig");
const client_mod = @import("client.zig");
const sidecar_mod = @import("sidecar.zig");
const profile_mod = @import("profile.zig");

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

const ModelSelection = struct { provider: []const u8 = "", model: []const u8 = "" };

/// The model a resumed session recorded, or null when it never selected one
/// (fresh sessions fall back to `agent-default-model`).
fn sessionSelection(allocator: Allocator, client: *DshClient, session_id: []const u8) !?ModelSelection {
    const args = try std.json.Stringify.valueAlloc(allocator, .{
        .request = .{ .sessionId = session_id },
    }, .{});
    defer allocator.free(args);
    var reply = try client.call("session/projections", args);
    defer client.freeReply(&reply);
    if (!reply.ok) return null;

    const Reply = struct {
        values: ?Values = null,
        const Values = struct {
            modelSelection: ?Selection = null,
            const Selection = struct {
                lastUsed: ?ModelSelection = null,
                next: ?ModelSelection = null,
            };
        };
    };
    const parsed = std.json.parseFromSlice(Reply, allocator, reply.value_json, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const values = parsed.value.values orelse return null;
    const selection = values.modelSelection orelse return null;
    return selection.next orelse selection.lastUsed;
}

/// True when the host catalog still advertises this provider/model. A failed
/// catalog read counts as "present" so a transport hiccup never rewrites a
/// user's deliberate selection.
fn catalogContains(allocator: Allocator, client: *DshClient, selection: ModelSelection) bool {
    var reply = client.call("session/modelCatalog", "{}") catch return true;
    defer client.freeReply(&reply);
    if (!reply.ok) return true;

    const Catalog = struct {
        groups: []const Group = &.{},
        const Group = struct {
            id: []const u8 = "",
            models: []const Model = &.{},
        };
        const Model = struct { id: []const u8 = "" };
    };
    const parsed = std.json.parseFromSlice(Catalog, allocator, reply.value_json, .{
        .ignore_unknown_fields = true,
    }) catch return true;
    defer parsed.deinit();
    for (parsed.value.groups) |group| {
        if (!std.mem.eql(u8, group.id, selection.provider)) continue;
        for (group.models) |model| {
            if (std.mem.eql(u8, model.id, selection.model)) return true;
        }
    }
    return false;
}

/// Point a resumed session at the current junclaw default when its recorded
/// model is no longer offered. Best effort: an older dsh without these RPCs
/// leaves the session alone.
fn ensureSessionModel(
    allocator: Allocator,
    client: *DshClient,
    session_id: []const u8,
    route: profile_mod.Route,
) !void {
    const selection = try sessionSelection(allocator, client, session_id) orelse return;
    if (selection.provider.len == 0 or selection.model.len == 0) return;
    if (catalogContains(allocator, client, selection)) return;
    try client.selectModel(session_id, profile_mod.route_id, route.default_model);
}

/// Process-wide dsh state: the sidecar (or an injected boot URL), its
/// credentials, and one dsh session per junclaw key.
///
/// Options slices are borrowed for the engine lifetime (the same contract as
/// `sidecar.Options`); the owner must outlive `deinit`.
pub const DshEngine = struct {
    const Self = @This();

    pub const Options = struct {
        /// Sidecar launch options; ignored when `boot_url` is set. An empty
        /// `bin_js` is resolved from `NULLCLAW_DSH_BIN` at boot.
        sidecar: sidecar_mod.Options,
        /// Use this launch URL instead of spawning a process (tests, or an
        /// externally managed sidecar). The owner-cookie exchange still runs.
        boot_url: ?[]const u8 = null,
        /// Base path used to derive one mapping per key as
        /// `{dir}/{Wyhash(key)}.json`. Null disables resume.
        session_file: ?[]const u8 = null,
        /// Hang guard for one turn waiting on a terminal `turn/end`.
        turn_timeout_ms: u64 = 30_000,
        /// Hang guard for `/stop` waiting on dsh's aborted `turn/end`.
        cancel_timeout_ms: u64 = 10_000,
        /// Hang guard for one HTTP RPC to the sidecar (create/connect/cancel/…).
        rpc_timeout_ms: u64 = 30_000,
        /// Hang guard for the WebSocket upgrade handshake.
        handshake_timeout_ms: u64 = 10_000,
    };

    /// One junclaw key's dsh session. The client's WS lives as long as the
    /// entry, so switching keys is a lookup, never a reconnect.
    /// shortcut: one WS per dsh session instead of the design's single
    /// multiplexed remote.mux stream, upgrade when the key count grows.
    ///
    /// `refs`/`retired` are guarded by `entries_mutex`: a turn holds one ref
    /// for its whole run, and `releaseKey` only frees an entry once the last
    /// ref drops, so a concurrent deinit cannot free an in-flight turn.
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
        refs: usize = 0,
        retired: bool = false,

        fn deinit(self: *Entry, allocator: Allocator) void {
            self.client.deinit();
            allocator.free(self.key);
            if (self.session_file) |path| allocator.free(path);
            allocator.free(self.session_id);
        }
    };

    allocator: Allocator,
    opts: Options,
    /// Set only when this engine spawned the process; `boot_url` bypasses it.
    /// P1 has no auto-restart loop: a dead sidecar surfaces as an error from
    /// the next RPC. `sidecar.restart`/`backoffDelayMs` are ready for the P2
    /// loop.
    sidecar: ?sidecar_mod.Sidecar = null,
    /// Owned copies, set by `ensureBooted`.
    base_url: ?[]u8 = null,
    cookie: ?[]u8 = null,
    /// One live dsh session per junclaw key, all on this one sidecar.
    entries: std.ArrayListUnmanaged(*Entry) = .empty,
    /// Guards `entries` and each entry's `refs`/`retired`.
    entries_mutex: std_compat.sync.Mutex = .{},
    /// Guards the boot transition; boot happens outside every session lock.
    boot_mutex: std_compat.sync.Mutex = .{},
    booted: bool = false,

    /// No spawn, no network: just fields, so the manager can create the engine
    /// while holding the session-table lock.
    pub fn init(allocator: Allocator, opts: Options) Self {
        return .{ .allocator = allocator, .opts = opts };
    }

    /// Release every key's client, the sidecar process and all owned slices;
    /// does not destroy `self`.
    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
        if (self.sidecar) |*sidecar| sidecar.deinit();
        if (self.base_url) |url| self.allocator.free(url);
        if (self.cookie) |value| self.allocator.free(value);
    }

    /// Idempotent lazy boot. The first caller spawns (or adopts) the sidecar
    /// and exchanges the owner cookie; concurrent callers wait on `boot_mutex`
    /// and observe the same result. A failure leaves the engine unbooted with
    /// no half-initialized process, so the next turn can retry.
    pub fn ensureBooted(self: *Self) !void {
        self.boot_mutex.lock();
        defer self.boot_mutex.unlock();
        if (self.booted) return;

        try fs_compat.makePath(self.opts.sidecar.dsh_home);
        // Rewrite the junclaw route in the web profile before spawning: dsh
        // composes the profile once at boot. Idempotent, atomic, and limited
        // to `providers.junclaw` plus the default selection.
        if (self.opts.sidecar.profile) |route| {
            try profile_mod.write(self.allocator, self.opts.sidecar.dsh_home, route);
        }
        if (self.opts.session_file) |base| {
            const dir = std_compat.fs.path.dirname(base) orelse ".";
            try fs_compat.makePath(dir);
        }

        var spawned: ?sidecar_mod.Sidecar = null;
        var cookie: ?[]u8 = null;
        var base_url: ?[]u8 = null;
        errdefer {
            if (spawned) |*sidecar| sidecar.deinit();
            if (cookie) |value| self.allocator.free(value);
            if (base_url) |value| self.allocator.free(value);
        }

        const boot_url = if (self.opts.boot_url) |url| url else blk: {
            var owned_bin: ?[]u8 = null;
            defer if (owned_bin) |value| self.allocator.free(value);
            var sidecar_opts = self.opts.sidecar;
            sidecar_opts.rpc_timeout_ms = self.opts.rpc_timeout_ms;
            if (sidecar_opts.bin_js.len == 0) {
                owned_bin = std_compat.process.getEnvVarOwned(self.allocator, "NULLCLAW_DSH_BIN") catch |err| switch (err) {
                    error.EnvironmentVariableNotFound => return error.DshBinNotConfigured,
                    else => return err,
                };
                sidecar_opts.bin_js = owned_bin.?;
            }
            spawned = try sidecar_mod.Sidecar.start(self.allocator, sidecar_opts);
            break :blk spawned.?.boot_url orelse return error.SidecarNotStarted;
        };
        cookie = try sidecar_mod.fetchOwnerCookieForUrl(self.allocator, boot_url, self.opts.rpc_timeout_ms);
        const endpoint = try client_mod.parseBootEndpoint(boot_url);
        base_url = try self.allocator.dupe(u8, endpoint.base_url);

        self.sidecar = spawned;
        self.cookie = cookie.?;
        self.base_url = base_url.?;
        self.booted = true;
        spawned = null;
        cookie = null;
        base_url = null;
    }

    /// Per-key mapping path: `{dir}/{Wyhash(key)}.json`. Caller frees; null
    /// disables resume.
    pub fn mappingPath(self: *const Self, allocator: Allocator, key: []const u8) !?[]u8 {
        const base = self.opts.session_file orelse return null;
        const dir = std_compat.fs.path.dirname(base) orelse ".";
        return try std.fmt.allocPrint(allocator, "{s}/{x}.json", .{
            dir,
            std.hash.Wyhash.hash(0, key),
        });
    }

    const Acquired = struct { entry: *Entry, created: bool };

    /// Get-or-create this key's entry and take one ref. `ensureBooted` must
    /// have succeeded. Other keys' entries are never touched.
    pub fn acquireEntry(
        self: *Self,
        key: []const u8,
        session_file: ?[]const u8,
        adopt: bool,
    ) !Acquired {
        self.entries_mutex.lock();
        defer self.entries_mutex.unlock();
        if (self.findEntryLocked(key)) |entry| {
            entry.refs += 1;
            return .{ .entry = entry, .created = false };
        }
        return .{ .entry = try self.createEntryLocked(key, session_file, adopt), .created = true };
    }

    /// Take a ref on an existing entry; null never creates one. Used by
    /// interrupt paths, which must not boot or create a dsh session.
    pub fn acquireExisting(self: *Self, key: []const u8) ?*Entry {
        self.entries_mutex.lock();
        defer self.entries_mutex.unlock();
        const entry = self.findEntryLocked(key) orelse return null;
        entry.refs += 1;
        return entry;
    }

    /// Drop one ref, freeing the entry if its key was released meanwhile.
    pub fn releaseEntry(self: *Self, entry: *Entry) void {
        self.entries_mutex.lock();
        entry.refs -= 1;
        const free_now = entry.refs == 0 and entry.retired;
        self.entries_mutex.unlock();
        if (free_now) {
            entry.deinit(self.allocator);
            self.allocator.destroy(entry);
        }
    }

    /// Drop this key's entry (session deinit / eviction). An in-flight turn
    /// keeps it alive through its ref; the shared sidecar stays up.
    pub fn releaseKey(self: *Self, key: []const u8) void {
        self.entries_mutex.lock();
        var free_now = false;
        if (self.findEntryIndexLocked(key)) |index| {
            const entry = self.entries.orderedRemove(index);
            if (entry.refs == 0) {
                free_now = true;
            } else {
                entry.retired = true;
            }
            if (free_now) {
                self.entries_mutex.unlock();
                entry.deinit(self.allocator);
                self.allocator.destroy(entry);
                return;
            }
        }
        self.entries_mutex.unlock();
    }

    /// Caller holds `entries_mutex`.
    fn findEntryLocked(self: *Self, key: []const u8) ?*Entry {
        const index = self.findEntryIndexLocked(key) orelse return null;
        return self.entries.items[index];
    }

    /// Caller holds `entries_mutex`.
    fn findEntryIndexLocked(self: *Self, key: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.key, key)) return index;
        }
        return null;
    }

    /// A client wired to this engine's RPC and handshake deadlines.
    fn newClient(self: *Self) !DshClient {
        var client = try DshClient.init(self.allocator, self.base_url.?, self.cookie.?);
        client.rpc_timeout_ms = self.opts.rpc_timeout_ms;
        client.handshake_timeout_ms = self.opts.handshake_timeout_ms;
        return client;
    }

    /// Build this key's entry. `adopt` resumes the persisted id instead of
    /// creating a session. Caller holds `entries_mutex`; the returned entry
    /// carries one ref.
    fn createEntryLocked(
        self: *Self,
        key: []const u8,
        session_file: ?[]const u8,
        adopt: bool,
    ) !*Entry {
        const mapping: ?[]u8 = if (session_file) |path|
            try self.allocator.dupe(u8, path)
        else
            null;
        errdefer if (mapping) |path| self.allocator.free(path);

        var client = try self.newClient();
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
            // A resumed session keeps the model it recorded. When that model
            // left the catalog (provider or model renamed), switch it to the
            // current default before prompting instead of failing the turn.
            if (self.opts.sidecar.profile) |route| {
                ensureSessionModel(self.allocator, &client, id, route) catch {};
            }
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
            .refs = 1,
        };
        try self.entries.append(self.allocator, entry);
        return entry;
    }
};

/// Lightweight per-session handle over a shared `DshEngine`. The key is owned
/// and immutable for the handle's life, so one session's turn can never
/// retarget another session.
pub const DshHarness = struct {
    const Self = @This();

    engine: *DshEngine,
    /// Owned copy; the engine's entry table is keyed by this value.
    session_key: []u8,
    /// Owned copy of this key's mapping path; null disables resume.
    session_file: ?[]u8 = null,

    pub fn init(engine: *DshEngine, session_key: []const u8) !Self {
        const allocator = engine.allocator;
        const key = try allocator.dupe(u8, session_key);
        errdefer allocator.free(key);
        return .{
            .engine = engine,
            .session_key = key,
            .session_file = try engine.mappingPath(allocator, session_key),
        };
    }

    /// Release this key's entry (never the shared sidecar) and owned slices;
    /// does not destroy `self` (the vtable deinit does that for host-owned
    /// instances).
    pub fn deinit(self: *Self) void {
        self.engine.releaseKey(self.session_key);
        self.engine.allocator.free(self.session_key);
        if (self.session_file) |path| self.engine.allocator.free(path);
    }

    pub fn harness(self: *Self) port.Harness {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// True while a stop is waiting for the next turn to consume it. The host
    /// checks this before pre-routing a local command: a pre-turn /stop must
    /// abort that command the way native's `Agent.turn` check does.
    pub fn interruptPending(self: *Self) bool {
        const entry = self.engine.acquireExisting(self.session_key) orelse return false;
        defer self.engine.releaseEntry(entry);
        return entry.interrupt_requested.load(.acquire);
    }

    // ── vtable ──────────────────────────────────────────────────────────────

    fn runTurn(ptr: *anyopaque, input: port.TurnInput) anyerror!port.TurnResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const engine = self.engine;
        const allocator = engine.allocator;

        // Lazy boot runs here, on the session's turn thread under the session
        // mutex, never under the session-table lock.
        try engine.ensureBooted();
        const entry = (try engine.acquireEntry(self.session_key, self.session_file, true)).entry;
        defer engine.releaseEntry(entry);
        entry.turn_mutex.lock();
        defer entry.turn_mutex.unlock();

        // A stop that landed before the prompt still cancels this turn, so a
        // pre-turn requestInterrupt behaves like native's.
        if (entry.interrupt_requested.swap(false, .acquire)) {
            return .{ .reply = try allocator.dupe(u8, ""), .end_reason = .interrupted };
        }

        const session_id = entry.session_id;
        const sink = input.sink;

        try entry.client.prompt(session_id, input.user_message);

        var text: std.ArrayListUnmanaged(u8) = .empty;
        errdefer text.deinit(allocator);

        const deadline = std_compat.time.milliTimestamp() +
            @as(i64, @intCast(engine.opts.turn_timeout_ms));
        while (true) {
            if (entry.interrupt_requested.swap(false, .acquire)) {
                // session/cancel is sent from this thread: the Shared event
                // queue has exactly one consumer, and cancel() consumes it
                // while waiting for the aborted turn/end.
                var cancelled = entry.client.cancel(session_id, engine.opts.cancel_timeout_ms) catch |err| switch (err) {
                    // The turn may have ended between the flag and the RPC; the
                    // partial text is still the best reply we have.
                    error.CancelTimeout => return .{
                        .reply = try text.toOwnedSlice(allocator),
                        .end_reason = .interrupted,
                    },
                    else => return err,
                };
                defer client_mod.freeCancelResult(allocator, &cancelled);
                if (cancelled.partial_text.len > 0) {
                    // A committed prefix replaces the deltas it finalizes.
                    if (cancelled.committed) text.clearRetainingCapacity();
                    try text.appendSlice(allocator, cancelled.partial_text);
                    if (!cancelled.committed) {
                        if (sink) |s| s.send(.{ .delta = providers.StreamChunk.textDelta(cancelled.partial_text) });
                    }
                }
                return .{
                    .reply = try text.toOwnedSlice(allocator),
                    .end_reason = mapEndReason(cancelled.kind),
                };
            }

            const remaining = deadline - std_compat.time.milliTimestamp();
            if (remaining <= 0) return error.TurnTimeout;

            var event = entry.client.nextEvent(@min(@as(u64, @intCast(remaining)), poll_slice_ms)) catch |err| switch (err) {
                error.Timeout => continue,
                else => return err,
            };
            defer client_mod.freeEvent(allocator, &event);

            switch (event.event) {
                .assistant_chunk => |chunk| switch (chunk) {
                    .text_delta => |delta| {
                        try text.appendSlice(allocator, delta.text);
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
                        try text.appendSlice(allocator, message);
                    }
                },
                .turn_end => |turn| {
                    const reply = try text.toOwnedSlice(allocator);
                    errdefer allocator.free(reply);
                    return .{
                        .reply = reply,
                        .end_reason = mapEndReason(turn.kind),
                        .@"error" = if (turn.error_message) |message|
                            try allocator.dupe(u8, message)
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
        const entry = self.engine.acquireExisting(self.session_key) orelse return;
        defer self.engine.releaseEntry(entry);
        entry.interrupt_requested.store(true, .release);
    }

    fn clearInterrupt(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const entry = self.engine.acquireExisting(self.session_key) orelse return;
        defer self.engine.releaseEntry(entry);
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
            .workspace_dir = self.engine.opts.sidecar.workspace,
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
            const entry = self.engine.acquireExisting(self.session_key) orelse return stop_ack;
            defer self.engine.releaseEntry(entry);
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

    /// `/new`: close and replace only this key's session, rewriting this key's
    /// mapping. Other keys keep their client and session untouched.
    fn resetKeySession(self: *Self) !void {
        const engine = self.engine;
        const allocator = engine.allocator;

        try engine.ensureBooted();
        const acquired = try engine.acquireEntry(self.session_key, self.session_file, false);
        const entry = acquired.entry;
        defer engine.releaseEntry(entry);
        // A key that had no session gets its first one; there is nothing to
        // replace (the old eager-create behavior).
        if (acquired.created) return;

        // Serialize with this key's active turn before swapping its client.
        entry.turn_mutex.lock();
        defer entry.turn_mutex.unlock();

        // Build the replacement before touching the old session, so a failed
        // create/connect leaves the key on its current session.
        var client = try engine.newClient();
        errdefer client.deinit();
        const session_id = try client.createSession(engine.opts.sidecar.workspace);
        errdefer allocator.free(session_id);
        if (entry.session_file) |path| try sidecar_mod.saveSessionId(path, session_id);
        try client.connect(session_id);

        entry.client.closeSession(entry.session_id) catch {};
        entry.client.deinit();
        allocator.free(entry.session_id);
        entry.client = client;
        entry.session_id = session_id;
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
