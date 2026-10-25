//! The dsh adapter: `Harness` implemented over the dsh web sidecar.
//!
//! P1 scope (see .scratch/dsh-sidecar-design.md §4): one sidecar per process
//! (`DshEngine`), serving many junclaw session keys side by side (one dsh
//! session per key over one process-wide `/api/remote.mux` WebSocket), streaming
//! assistant text as `Event.delta`, answering `/stop` with `session/cancel` and
//! `/new` with a fresh dsh session for that key only.
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
const config_types = @import("../../config_types.zig");
const port = @import("../port.zig");
const client_mod = @import("client.zig");
const sidecar_mod = @import("sidecar.zig");
const profile_mod = @import("profile.zig");

const Allocator = std.mem.Allocator;
const DshClient = client_mod.DshClient;

/// How often a waiting turn wakes to check `interrupt_requested`.
/// shortcut: a poll slice instead of an eventfd; /stop lands within one slice.
const poll_slice_ms: u64 = 50;

/// Consecutive failed crash recoveries before the engine stops restarting.
/// Aligned with sidecar `backoffDelayMs` (200/400/800ms for these attempts);
/// one successful rebuild resets the count.
const max_restart_attempts: u32 = 3;

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

    /// One junclaw key's dsh session. Every entry follows its session over the
    /// engine's single mux socket, so switching keys is a lookup, never a
    /// reconnect.
    ///
    /// `refs`/`retired` are guarded by `entries_mutex`: a turn holds one ref
    /// for its whole run, and `releaseKey` only frees an entry once the last
    /// ref drops, so a concurrent deinit cannot free an in-flight turn.
    const Entry = struct {
        key: []u8,
        /// This key's persisted mapping path; null when resume is disabled.
        session_file: ?[]u8 = null,
        client: *DshClient,
        /// This key's `session/follow` stream on the shared socket.
        sub: *client_mod.Subscription,
        session_id: []u8,
        /// dsh is single-flight per session: a second turn on this key waits
        /// here and runs as the next queued prompt (P1: no steer injection).
        turn_mutex: std_compat.sync.Mutex = .{},
        interrupt_requested: std.atomic.Value(bool) = .init(false),
        /// A `/new` swap failed; the next turn must report, never prompt the
        /// old session. Cleared by the next successful reset. Guarded by
        /// `turn_mutex`.
        reset_failed: bool = false,
        refs: usize = 0,
        retired: bool = false,

        fn deinit(self: *Entry, allocator: Allocator) void {
            self.client.unsubscribe(self.sub);
            self.client.release();
            allocator.free(self.key);
            if (self.session_file) |path| allocator.free(path);
            allocator.free(self.session_id);
        }
    };

    allocator: Allocator,
    opts: Options,
    /// `opts.sidecar.bin_js` resolved from the environment at boot, owned by
    /// the engine. Kept alive for restarts and the writer-held sweep.
    bin_js_owned: ?[]u8 = null,
    /// Set only when this engine spawned the process; `boot_url` bypasses it.
    /// Owned processes are restarted automatically after a connection-level
    /// error; an injected `boot_url` is never restarted.
    sidecar: ?sidecar_mod.Sidecar = null,
    /// Set by `ensureBooted`: one HTTP client and one mux socket for every key.
    client: ?*DshClient = null,
    /// Test seam: boot/restart without a process and return the launch URL
    /// (owned by the allocator). Non-null makes the engine self-managed.
    spawn_override: ?*const fn (ctx: ?*anyopaque, allocator: Allocator) anyerror![]u8 = null,
    spawn_ctx: ?*anyopaque = null,
    /// Serializes restarts, so one crash never rebuilds two WebSockets.
    recovery_mutex: std_compat.sync.Mutex = .{},
    /// Consecutive crashes without a completed turn; a terminal `turn/end`
    /// resets it. A boot and handshake alone do not: dsh can die on its first
    /// RPC right after answering the upgrade.
    restart_attempts: u32 = 0,
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
        if (self.client) |client| client.release();
        if (self.bin_js_owned) |value| self.allocator.free(value);
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
        var boot_url_owned: ?[]u8 = null;
        defer if (boot_url_owned) |url| self.allocator.free(url);
        errdefer if (spawned) |*sidecar| sidecar.deinit();

        const boot_url: []const u8 = if (self.opts.boot_url) |url|
            url
        else if (self.spawn_override) |hook| blk: {
            boot_url_owned = try hook(self.spawn_ctx, self.allocator);
            break :blk boot_url_owned.?;
        } else blk: {
            var sidecar_opts = self.opts.sidecar;
            sidecar_opts.rpc_timeout_ms = self.opts.rpc_timeout_ms;
            if (sidecar_opts.bin_js.len == 0) {
                const resolved = std_compat.process.getEnvVarOwned(self.allocator, "NULLCLAW_DSH_BIN") catch |err| switch (err) {
                    error.EnvironmentVariableNotFound => return error.DshBinNotConfigured,
                    else => return err,
                };
                // Persist: restarts and the writer-held sweep must see the
                // real bin path, not the empty needle that matches every pid.
                self.bin_js_owned = resolved;
                self.opts.sidecar.bin_js = resolved;
                sidecar_opts.bin_js = resolved;
            }
            spawned = try sidecar_mod.Sidecar.start(self.allocator, sidecar_opts);
            break :blk spawned.?.boot_url orelse return error.SidecarNotStarted;
        };
        const client = try self.connectClient(boot_url);

        self.sidecar = spawned;
        self.client = client;
        self.booted = true;
        spawned = null;
    }

    /// Exchange the launch URL for the owner cookie and open the one shared
    /// mux socket. Returns a new heap client; the caller installs it.
    fn connectClient(self: *Self, boot_url: []const u8) !*DshClient {
        const cookie = try sidecar_mod.fetchOwnerCookieForUrl(self.allocator, boot_url, self.opts.rpc_timeout_ms);
        defer self.allocator.free(cookie);
        const endpoint = try client_mod.parseBootEndpoint(boot_url);

        const client = try self.allocator.create(DshClient);
        errdefer self.allocator.destroy(client);
        client.* = try DshClient.init(self.allocator, endpoint.base_url, cookie);
        errdefer client.deinit();
        client.rpc_timeout_ms = self.opts.rpc_timeout_ms;
        client.handshake_timeout_ms = self.opts.handshake_timeout_ms;
        // One mux socket for the whole process: dsh rejects a second socket
        // for the same API peer with 409 Conflict.
        try client.connectMux();
        return client;
    }

    /// True when this engine may restart its own sidecar (never an injected
    /// `boot_url`).
    fn selfManaged(self: *const Self) bool {
        return self.opts.boot_url == null and (self.sidecar != null or self.spawn_override != null);
    }

    /// Kill dsh processes left behind by a killed gateway. They keep the
    /// session writer lock, so the live sidecar answers session/writer-held.
    /// Externally managed sidecars (tests, injected `boot_url`) are only swept
    /// when a test seam replaces the real /proc scan.
    fn reapOrphanSidecars(self: *Self) void {
        if (!self.selfManaged() and self.opts.sidecar.reap == null) return;
        self.recovery_mutex.lock();
        defer self.recovery_mutex.unlock();
        const exclude_pid = if (self.sidecar) |*sidecar| sidecar.pid() else null;
        sidecar_mod.reapOrphans(self.allocator, self.opts.sidecar, exclude_pid);
    }

    /// Restart the sidecar and install a fresh client. Caller holds
    /// `recovery_mutex`. The previous client is released, but any key still
    /// bound to it holds a reference until its turn re-attaches.
    fn restartSidecarLocked(self: *Self) !void {
        if (self.restart_attempts >= max_restart_attempts) {
            std.log.warn("dsh sidecar failed to restart {d} times in a row; giving up", .{self.restart_attempts});
            return error.SidecarCrashLoop;
        }
        self.restart_attempts += 1;

        var boot_url_owned: ?[]u8 = null;
        defer if (boot_url_owned) |url| self.allocator.free(url);
        const boot_url: []const u8 = if (self.spawn_override) |hook| blk: {
            boot_url_owned = try hook(self.spawn_ctx, self.allocator);
            break :blk boot_url_owned.?;
        } else blk: {
            const sidecar = if (self.sidecar) |*value| value else return error.SidecarNotStarted;
            try sidecar.restart();
            break :blk sidecar.boot_url orelse return error.SidecarNotStarted;
        };
        const client = try self.connectClient(boot_url);

        // Swap under the entry-table lock: `createEntryLocked` reads
        // `self.client` while holding it, and an entry retains before it
        // releases the lock.
        self.entries_mutex.lock();
        const old = self.client;
        self.client = client;
        self.entries_mutex.unlock();
        if (old) |value| value.release();
    }

    /// A client the failed call actually used, retained so the pointer cannot
    /// be freed and reused while recovery compares it. Caller releases.
    fn currentClient(self: *Self) ?*DshClient {
        self.entries_mutex.lock();
        defer self.entries_mutex.unlock();
        const client = self.client orelse return null;
        client.retain();
        return client;
    }

    /// A terminal turn proves the sidecar is healthy again; only now clear the
    /// crash streak.
    fn noteTurnCompleted(self: *Self) void {
        self.recovery_mutex.lock();
        defer self.recovery_mutex.unlock();
        self.restart_attempts = 0;
    }

    /// Recover from a connection-level error: restart a self-managed sidecar
    /// (unless another turn already did) and re-attach every live session.
    /// `observed_client` is the client the failing call used. Comparing the
    /// client, not a generation counter, matters: a turn can still hold the old
    /// client after another turn has already restarted, and a bare counter
    /// would then restart a second time and kill the fresh sidecar.
    fn recover(self: *Self, entry: ?*Entry, observed_client: *DshClient) !void {
        self.recovery_mutex.lock();
        defer self.recovery_mutex.unlock();

        if (self.client == observed_client) {
            if (!self.selfManaged()) return error.SidecarNotManaged;
            try self.restartSidecarLocked();
        }
        const client = self.client orelse return error.SidecarNotStarted;
        try self.reattachAll(entry, client);
    }

    /// Resume and re-follow every live session on `client`. The caller's entry
    /// is re-attached under its already-held `turn_mutex`; another entry is
    /// only touched when its turn mutex is free. A busy turn re-attaches its
    /// own entry when the dead stream surfaces `ConnectionLost`.
    fn reattachAll(self: *Self, caller: ?*Entry, client: *DshClient) !void {
        var snapshot: std.ArrayListUnmanaged(*Entry) = .empty;
        defer snapshot.deinit(self.allocator);

        {
            self.entries_mutex.lock();
            defer self.entries_mutex.unlock();
            try snapshot.ensureTotalCapacity(self.allocator, self.entries.items.len);
            for (self.entries.items) |entry| {
                entry.refs += 1;
                snapshot.appendAssumeCapacity(entry);
            }
        }
        defer for (snapshot.items) |entry| self.releaseEntry(entry);

        for (snapshot.items) |entry| {
            if (entry.client == client) continue;
            if (caller != null and entry == caller.?) {
                try reattachEntry(entry, client);
                continue;
            }
            if (entry.turn_mutex.tryLock()) {
                defer entry.turn_mutex.unlock();
                reattachEntry(entry, client) catch {};
            }
        }
    }

    /// Move `entry` onto the current client after another turn's recovery.
    /// Caller holds `entry.turn_mutex`.
    fn ensureAttached(self: *Self, entry: *Entry) !void {
        self.recovery_mutex.lock();
        defer self.recovery_mutex.unlock();
        const client = self.client orelse return error.SidecarNotStarted;
        if (entry.client == client) return;
        try reattachEntry(entry, client);
    }

    /// Point `entry` at `client` and follow its session there. The old client
    /// is released once no turn is bound to it.
    ///
    /// `session/follow` reads durable history, so it attaches a session the
    /// fresh sidecar has not loaded yet; the next prompt resumes it (dsh
    /// session-controller README). There is no `session/resume` Remote method:
    /// calling one 404s at the gateway and used to wedge every key.
    fn reattachEntry(entry: *Entry, client: *DshClient) !void {
        const sub = try client.subscribe(entry.session_id);
        client.retain();
        const old = entry.client;
        entry.sub = sub;
        entry.client = client;
        // Drops the old client (and its subscriptions) once no turn holds it.
        old.release();
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

        const client = self.client orelse return error.SidecarNotStarted;
        // Hold the client for the whole network setup; ownership moves to the
        // entry on success.
        client.retain();
        var entry_owns_ref = false;
        defer if (!entry_owns_ref) client.release();

        // A corrupt mapping falls back to a fresh session (design §2.2); an id
        // dsh no longer knows surfaces as an error from this turn.
        var persisted: ?[]u8 = null;
        if (adopt) {
            if (mapping) |path| {
                persisted = sidecar_mod.loadSessionId(self.allocator, path) catch null;
            }
        }
        defer if (persisted) |session_id| self.allocator.free(session_id);

        var sub: ?*client_mod.Subscription = null;
        errdefer if (sub) |value| client.unsubscribe(value);

        var session_id: []u8 = undefined;
        var session_owned = false;
        errdefer if (session_owned) self.allocator.free(session_id);
        if (persisted) |id| {
            sub = try client.subscribe(id);
            // A resumed session keeps the model it recorded. When that model
            // left the catalog (provider or model renamed), switch it to the
            // current default before prompting instead of failing the turn.
            if (self.opts.sidecar.profile) |route| {
                ensureSessionModel(self.allocator, client, id, route) catch {};
            }
            session_id = try self.allocator.dupe(u8, id);
            session_owned = true;
        } else {
            session_id = try client.createSession(self.opts.sidecar.workspace);
            session_owned = true;
            if (mapping) |path| try sidecar_mod.saveSessionId(path, session_id);
            sub = try client.subscribe(session_id);
        }

        const entry_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(entry_key);
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .key = entry_key,
            .session_file = mapping,
            .client = client,
            .sub = sub.?,
            .session_id = session_id,
            .refs = 1,
        };
        try self.entries.append(self.allocator, entry);
        entry_owns_ref = true;
        return entry;
    }
};

/// One turn's reasoning display state. `.on` accumulates the trace for the
/// final quoted block; `.off` ignores it; `.stream` (and `.on`) forward it as
/// `<think>…</think>` inline deltas when the host has a live draft, so the
/// host's TagFilter decides what the channel shows. `composeFinalReply` is the
/// native formatter, reused so the quoted block cannot drift from native.
const ReasoningRelay = struct {
    mode: config_types.ReasoningMode,
    /// Non-null only for `sink != null and input.live_stream`; a progress-only
    /// sink must never receive tags it would leave dangling.
    sink: ?port.Sink,
    open: bool = false,
    trace: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *ReasoningRelay, allocator: Allocator) void {
        self.trace.deinit(allocator);
    }

    fn push(self: *ReasoningRelay, allocator: Allocator, text: []const u8) !void {
        // An empty fragment must not open a tag: `off`, empty traces and
        // no-live-stream turns all leave the stream without `<think>`.
        if (text.len == 0 or self.mode == .off) return;
        if (self.mode == .on) try self.trace.appendSlice(allocator, text);
        const sink = self.sink orelse return;
        if (!self.open) {
            sink.send(.{ .delta = providers.StreamChunk.textDelta("<think>") });
            self.open = true;
        }
        sink.send(.{ .delta = providers.StreamChunk.textDelta(text) });
    }

    /// Close an open block before visible text or a turn end. Idempotent, and
    /// never emits a closer that `push` did not open.
    fn close(self: *ReasoningRelay) void {
        const sink = self.sink orelse return;
        if (!self.open) return;
        sink.send(.{ .delta = providers.StreamChunk.textDelta("</think>") });
        self.open = false;
    }

    /// Close the block and build the turn result. In `.on` the reply gets
    /// native's quoted block while `persisted_reply` is the clean visible text;
    /// it is a suffix of the returned reply, so the host still frees one buffer.
    fn finish(
        self: *ReasoningRelay,
        allocator: Allocator,
        text: *std.ArrayListUnmanaged(u8),
        end_reason: port.EndReason,
    ) !port.TurnResult {
        self.close();
        const visible = try text.toOwnedSlice(allocator);
        var reply: []const u8 = visible;
        var persisted: ?[]const u8 = visible;
        if (self.mode == .on and self.trace.items.len > 0) {
            const context = FinalReplyContext{
                .allocator = allocator,
                .reasoning_mode = .on,
                .usage_mode = .off,
            };
            const prefix = try agent_mod.commands.composeFinalReply(&context, "", self.trace.items, .{});
            defer allocator.free(prefix);
            reply = agent_mod.commands.composeFinalReply(&context, visible, self.trace.items, .{}) catch |err| {
                allocator.free(visible);
                return err;
            };
            allocator.free(visible);
            persisted = reply[prefix.len..];
        }
        return .{ .reply = reply, .persisted_reply = persisted, .end_reason = end_reason };
    }
};

/// The surface `composeFinalReply` reads from its receiver. The sidecar reply
/// never carries a usage footer; the extra variants exist because the shared
/// formatter switches over them exhaustively.
const FinalReplyContext = struct {
    allocator: Allocator,
    reasoning_mode: config_types.ReasoningMode,
    usage_mode: FinalReplyUsageMode,
    total_tokens: u64 = 0,
};

const FinalReplyUsageMode = enum { off, tokens, full, cost };

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
    /// `agent.reasoning_mode` for this key. Kept here, never on the shared
    /// `DshEngine`, so two sessions cannot overwrite each other's display mode.
    reasoning_mode: config_types.ReasoningMode = .off,

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

    /// Mirror the host's live `/model`, `/think` and `/reasoning` selection.
    /// The sidecar's own request config chooses the model and effort; only the
    /// reasoning display mode is host-owned here.
    pub fn setCallConfig(
        self: *Self,
        model: []const u8,
        reasoning_effort: ?[]const u8,
        reasoning_mode: config_types.ReasoningMode,
    ) void {
        _ = model;
        _ = reasoning_effort;
        self.reasoning_mode = reasoning_mode;
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
        // A crash while creating this key's session surfaces here; restart and
        // retry the acquire once.
        const acquire_client = engine.currentClient() orelse return error.SidecarNotStarted;
        defer acquire_client.release();
        const entry = blk: {
            const acquired = engine.acquireEntry(self.session_key, self.session_file, true) catch |err| {
                if (!engine.selfManaged() or !client_mod.isConnectionError(err)) return err;
                try engine.recover(null, acquire_client);
                break :blk (try engine.acquireEntry(self.session_key, self.session_file, true)).entry;
            };
            break :blk acquired.entry;
        };
        defer engine.releaseEntry(entry);
        entry.turn_mutex.lock();
        defer entry.turn_mutex.unlock();

        // A failed `/new` must never fall back to the old dsh session.
        if (entry.reset_failed) return error.SessionResetFailed;

        // Another key's crash recovery may have replaced the client while this
        // turn waited for the key's turn mutex; re-attach before prompting.
        try engine.ensureAttached(entry);

        // A cancel that timed out left the old turn streaming into this
        // subscription; its frames must never be read as this turn's reply.
        entry.sub.drain();

        // A stop that landed before the prompt still cancels this turn, so a
        // pre-turn requestInterrupt behaves like native's.
        if (entry.interrupt_requested.swap(false, .acquire)) {
            return .{ .reply = try allocator.dupe(u8, ""), .end_reason = .interrupted };
        }

        const session_id = entry.session_id;
        const sink = input.sink;

        // A dead sidecar surfaces here before any text is streamed, so the
        // prompt is safe to retry once after a restart (no duplicate output).
        // One id across attempts: dsh returns the original acceptance for a
        // retry whose requestId is already queued or logged, so the user
        // message is not inserted twice.
        const prompt_request_id = try client_mod.newRequestId(allocator);
        defer allocator.free(prompt_request_id);
        var prompt_retried = false;
        var writer_retried = false;
        while (true) {
            entry.client.promptWithRequestId(session_id, input.user_message, prompt_request_id) catch |err| {
                // A sidecar orphaned by a SIGKILLed gateway still owns the
                // session writer. Clear it once and retry the same session; if
                // it persists, report it instead of dropping history or
                // silently starting a fresh session.
                if (err == error.SessionWriterHeld and !writer_retried) {
                    writer_retried = true;
                    std.log.warn("dsh session {s} is writer-held; reaping leftover sidecars", .{session_id});
                    engine.reapOrphanSidecars();
                    continue;
                }
                if (!client_mod.isConnectionError(err) or prompt_retried or !engine.selfManaged()) return err;
                prompt_retried = true;
                try engine.recover(entry, entry.client);
                continue;
            };
            break;
        }

        var text: std.ArrayListUnmanaged(u8) = .empty;
        errdefer text.deinit(allocator);
        // A progress-only sink gets no live tags; `.on` still accumulates the
        // trace for the final block.
        var relay = ReasoningRelay{
            .mode = self.reasoning_mode,
            .sink = if (input.live_stream) sink else null,
        };
        errdefer relay.close();
        defer relay.deinit(allocator);

        const deadline = std_compat.time.milliTimestamp() +
            @as(i64, @intCast(engine.opts.turn_timeout_ms));
        while (true) {
            if (entry.interrupt_requested.swap(false, .acquire)) {
                // Close before the cancel drain emits partial text, so visible
                // text never lands inside an open thinking block.
                relay.close();
                // session/cancel is sent from this thread: the subscription's
                // event queue has exactly one consumer, and cancelOn() drains
                // it while waiting for the aborted turn/end.
                var cancelled = (try self.cancelAndDrain(entry, session_id, &text, sink)) orelse return
                    // The turn may have ended between the flag and the RPC; the
                    // partial text is still the best reply we have.
                    try relay.finish(allocator, &text, .interrupted);
                defer client_mod.freeCancelResult(allocator, &cancelled);
                return try relay.finish(allocator, &text, mapEndReason(cancelled.kind));
            }

            const remaining = deadline - std_compat.time.milliTimestamp();
            if (remaining <= 0) {
                // Cancel and drain the expired turn before reporting, so its
                // frames cannot land in the next turn. A /stop armed while the
                // cancel drained belonged to this turn, which is now over.
                relay.close();
                var cancelled = try self.cancelAndDrain(entry, session_id, &text, sink);
                _ = entry.interrupt_requested.swap(false, .acquire);
                if (cancelled) |*result| {
                    client_mod.freeCancelResult(allocator, result);
                    return error.TurnTimeout;
                }
                // dsh never sent the aborted turn/end; return what the user
                // already saw rather than an error that drops it.
                return try relay.finish(allocator, &text, .failed);
            }

            var event = entry.sub.nextEvent(@min(@as(u64, @intCast(remaining)), poll_slice_ms)) catch |err| switch (err) {
                error.Timeout => continue,
                else => {
                    if (!client_mod.isConnectionError(err) or !engine.selfManaged()) return err;
                    // The sidecar died mid-turn: restart and re-attach so the
                    // session continues, then keep the text the user already
                    // saw (retrying the prompt would duplicate it).
                    try engine.recover(entry, entry.client);
                    if (text.items.len == 0) return err;
                    return try relay.finish(allocator, &text, .failed);
                },
            };
            defer client_mod.freeEvent(allocator, &event);

            switch (event.event) {
                .assistant_chunk => |chunk| switch (chunk) {
                    .reasoning_delta => |delta| try relay.push(allocator, delta.text),
                    .text_delta => |delta| {
                        relay.close();
                        try text.appendSlice(allocator, delta.text);
                        if (sink) |s| s.send(.{ .delta = providers.StreamChunk.textDelta(delta.text) });
                    },
                    // The port union has no tool variant; native reports tools
                    // through `Event.progress`, so mirror that.
                    .tool_call => |call| {
                        relay.close();
                        if (sink) |s| s.send(.{ .progress = .{
                            .kind = .tool,
                            .text = call.name,
                            .arguments_json = call.arguments_json,
                            .phase = .start,
                        } });
                    },
                    .tool_result => |result| {
                        relay.close();
                        if (sink) |s| s.send(.{ .progress = .{
                            .kind = .tool,
                            .text = result.call_id,
                            .phase = .end,
                            .success = !result.is_error,
                        } });
                    },
                    .other => {},
                },
                .committed => |message| {
                    // dsh's finalized step text replaces the delta view it
                    // finalizes, so a turn that streams and commits replies once.
                    // An empty commit (tool-call-only step) is not a reply.
                    relay.close();
                    if (message.len > 0) {
                        text.clearRetainingCapacity();
                        try text.appendSlice(allocator, message);
                    }
                },
                .turn_end => |turn| {
                    engine.noteTurnCompleted();
                    var result = try relay.finish(allocator, &text, mapEndReason(turn.kind));
                    errdefer allocator.free(result.reply);
                    if (turn.error_message) |message| result.@"error" = try allocator.dupe(u8, message);
                    return result;
                },
                // P1 has no approval/question UI. The payload can carry command
                // text, so it is dropped rather than logged.
                .approval_request => {},
                .ignored, .unknown => {},
            }
        }
    }

    /// Send `session/cancel` and drain this subscription up to the aborted
    /// `turn/end`, folding any text streamed meanwhile into `text`. Returns
    /// null when there is no live turn to drain: dsh acked but never ended it
    /// (`CancelTimeout`), or the turn ended before the RPC (`TurnAlreadyEnded`).
    fn cancelAndDrain(
        self: *Self,
        entry: *DshEngine.Entry,
        session_id: []const u8,
        text: *std.ArrayListUnmanaged(u8),
        sink: ?port.Sink,
    ) !?client_mod.CancelResult {
        const allocator = self.engine.allocator;
        var cancelled = entry.client.cancelOn(entry.sub, session_id, self.engine.opts.cancel_timeout_ms) catch |err| switch (err) {
            error.CancelTimeout, error.TurnAlreadyEnded => return null,
            else => return err,
        };
        errdefer client_mod.freeCancelResult(allocator, &cancelled);
        if (cancelled.partial_text.len > 0) {
            // A committed prefix replaces the deltas it finalizes.
            if (cancelled.committed) text.clearRetainingCapacity();
            try text.appendSlice(allocator, cancelled.partial_text);
            if (!cancelled.committed) {
                if (sink) |s| s.send(.{ .delta = providers.StreamChunk.textDelta(cancelled.partial_text) });
            }
        }
        return cancelled;
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
        const self: *Self = @ptrCast(@alignCast(ptr));
        // This hook cannot report; resetKeySession() records the failure and
        // the next turn reports error.SessionResetFailed.
        self.resetKeySession() catch {};
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
            .reasoning_mode = self.reasoning_mode,
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

        try engine.ensureBooted();
        const acquired = blk: {
            const acquire_client = engine.currentClient() orelse return error.SidecarNotStarted;
            defer acquire_client.release();
            break :blk engine.acquireEntry(self.session_key, self.session_file, false) catch |err| {
                if (!engine.selfManaged() or !client_mod.isConnectionError(err)) return err;
                try engine.recover(null, acquire_client);
                break :blk try engine.acquireEntry(self.session_key, self.session_file, false);
            };
        };
        const entry = acquired.entry;
        defer engine.releaseEntry(entry);
        // A key that had no session gets its first one; there is nothing to
        // replace (the old eager-create behavior).
        if (acquired.created) return;

        // Serialize with this key's active turn before swapping its client.
        entry.turn_mutex.lock();
        defer entry.turn_mutex.unlock();

        // An idle key's sidecar may have died since its last turn. Recover and
        // retry once; otherwise `/new` fails and `reset_failed` reports
        // SessionResetFailed forever with nobody left to recover.
        self.swapSession(entry) catch |err| {
            if (!engine.selfManaged() or !client_mod.isConnectionError(err)) return err;
            try engine.recover(entry, entry.client);
            try self.swapSession(entry);
        };
    }

    /// Build the replacement before touching the old session, so a failed
    /// create/follow leaves the old session untouched. The key is then marked
    /// failed: the next turn reports instead of silently reusing it. The new
    /// follow stream opens on the same mux socket, never a second WebSocket.
    fn swapSession(self: *Self, entry: *DshEngine.Entry) !void {
        const engine = self.engine;
        const allocator = engine.allocator;
        errdefer entry.reset_failed = true;
        const client = entry.client;
        const session_id = try client.createSession(engine.opts.sidecar.workspace);
        errdefer allocator.free(session_id);
        if (entry.session_file) |path| try sidecar_mod.saveSessionId(path, session_id);
        const sub = try client.subscribe(session_id);

        entry.client.closeSession(entry.session_id) catch {};
        client.unsubscribe(entry.sub);
        allocator.free(entry.session_id);
        entry.sub = sub;
        entry.session_id = session_id;
        entry.reset_failed = false;
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
