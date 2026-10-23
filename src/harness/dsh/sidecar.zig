//! dsh sidecar process lifecycle: spawn the web profile, read its launch URL,
//! exchange the token for an owner cookie, drain output, and restart with
//! exponential backoff.
//!
//! The sidecar never writes junclaw message history; the only persisted state
//! is an optional `{"sessionId":"…"}` file.

const std = @import("std");
const builtin = @import("builtin");
const std_compat = @import("compat");
const fs_compat = @import("../../fs_compat.zig");
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const profile_mod = @import("profile.zig");

const Allocator = std.mem.Allocator;

pub const EnvVar = struct { key: []const u8, value: []const u8 };

pub const Options = struct {
    /// Node executable name or absolute path.
    node_exe: []const u8 = "node",
    /// Absolute path to the dsh `lib/bin.js`.
    bin_js: []const u8,
    /// Working directory for the sidecar (= session workspace).
    workspace: []const u8,
    /// dsh profile persistence root (`DSH_HOME`).
    dsh_home: []const u8,
    /// Extra environment entries; these override the defaults below.
    env: []const EnvVar = &.{},
    /// junclaw-owned dsh route; rewritten into the web profile before each
    /// boot and its key injected under the fixed `api_key_env` name.
    profile: ?profile_mod.Route = null,
    /// Upper bound on reading the launch URL from stdout.
    boot_timeout_ms: u64 = 60_000,
    /// Hang guard for the `/connect` owner-cookie HTTP exchange.
    rpc_timeout_ms: u64 = 30_000,
    /// Test seam replacing the `/proc` sweep of leftover dsh processes; null
    /// runs the real sweep. The sweep is what lets a restarted gateway take
    /// back `session.lock` from an orphaned sidecar.
    reap: ?*const fn (ctx: ?*anyopaque, opts: *const Options, exclude_pid: ?i32) void = null,
    reap_ctx: ?*anyopaque = null,
};

/// Exponential restart delay: 200ms, 400ms, … capped at 5s.
pub fn backoffDelayMs(attempt: u32) u64 {
    var delay: u64 = 200;
    var i: u32 = 0;
    while (i < attempt and delay < 5_000) : (i += 1) delay = @min(delay * 2, 5_000);
    return delay;
}

/// Copy the process environment so unknown variables pass through to dsh.
fn inheritedEnviron() std.process.Environ {
    switch (comptime builtin.os.tag) {
        .windows, .freestanding, .other => return .{ .block = .global },
        .wasi, .emscripten => {
            if (comptime builtin.link_libc) {
                const environ = std.c.environ;
                var count: usize = 0;
                while (environ[count] != null) : (count += 1) {}
                return .{ .block = .{ .slice = environ[0..count :null] } };
            }
            return .{ .block = .global };
        },
        else => {
            const environ = std.c.environ;
            var count: usize = 0;
            while (environ[count] != null) : (count += 1) {}
            return .{ .block = .{ .slice = environ[0..count :null] } };
        },
    }
}

/// Inherited environment plus the sidecar-required entries.
pub fn buildEnvMap(allocator: Allocator, opts: Options) !std_compat.process.EnvMap {
    var env = try std.process.Environ.createMap(inheritedEnviron(), allocator);
    errdefer env.deinit();
    try env.put("DSH_HOME", opts.dsh_home);
    try env.put("DSH_TELEMETRY_MODE", "DISABLED");
    try env.put("MOCK_API_KEY", "test-key");
    if (opts.profile) |profile| {
        if (profile.api_key) |key| {
            if (key.len > 0) try env.put(profile_mod.api_key_env, key);
        }
    }
    for (opts.env) |entry| try env.put(entry.key, entry.value);
    return env;
}

/// Persist the dsh session id as `{"sessionId":"…"}`.
pub fn saveSessionId(path: []const u8, session_id: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(.{ .sessionId = session_id }, .{}, &writer);

    const file = try fs_compat.createPath(path, .{});
    defer file.close();
    try file.writeAll(writer.buffered());
}

/// Load the persisted dsh session id (caller frees). Null when the file is absent.
pub fn loadSessionId(allocator: Allocator, path: []const u8) !?[]u8 {
    const content = fs_compat.readFileAlloc(std_compat.fs.cwd(), allocator, path, 4096) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(content);

    const Persisted = struct { sessionId: []const u8 };
    const parsed = std.json.parseFromSlice(Persisted, allocator, content, .{}) catch
        return error.InvalidSessionFile;
    defer parsed.deinit();
    return try allocator.dupe(u8, parsed.value.sessionId);
}

const OutputCtx = struct {
    allocator: Allocator,
    file: std_compat.fs.File,
    mutex: std_compat.sync.Mutex = .{},
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    boot_url: ?[]u8 = null,
    eof: bool = false,
};

const MAX_BOOT_SCAN_BYTES: usize = 256 * 1024;

fn stdoutMain(ctx: *OutputCtx) void {
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = ctx.file.read(&chunk) catch {
            ctx.mutex.lock();
            ctx.eof = true;
            ctx.mutex.unlock();
            return;
        };
        if (n == 0) {
            ctx.mutex.lock();
            ctx.eof = true;
            ctx.mutex.unlock();
            return;
        }

        ctx.mutex.lock();
        if (ctx.boot_url == null and ctx.buffer.items.len < MAX_BOOT_SCAN_BYTES) {
            ctx.buffer.appendSlice(ctx.allocator, chunk[0..n]) catch {};
            if (protocol.parseBootUrl(ctx.buffer.items)) |url| {
                ctx.boot_url = ctx.allocator.dupe(u8, url) catch null;
                if (ctx.boot_url != null) ctx.buffer.clearRetainingCapacity();
            }
        }
        ctx.mutex.unlock();
    }
}

fn stderrMain(file: std_compat.fs.File) void {
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&chunk) catch return;
        if (n == 0) return;
        std.debug.print("[dsh] {s}", .{chunk[0..n]});
    }
}

fn killTree(child: *std_compat.process.Child) void {
    if (comptime builtin.os.tag == .windows) {
        _ = child.kill() catch {};
    } else {
        // The child is spawned in its own process group (pgid = 0).
        std.posix.kill(-child.id, std.posix.SIG.KILL) catch {
            _ = child.kill() catch {};
        };
    }
}

/// How long the sweep waits for a SIGKILLed orphan to disappear from /proc
/// (and so release the session lock). Bounded; a stuck process does not block.
const ORPHAN_EXIT_TIMEOUT_MS: u64 = 2_000;

/// Kill dsh processes a previous gateway left behind for this DSH_HOME. A
/// SIGKILLed gateway does not take its sidecar down (the sidecar is its own
/// process group), and that orphan keeps `session.lock`, so a fresh dsh
/// answers `session/writer-held` instead of resuming the session.
/// shortcut: one DSH_HOME should serve one gateway; a second gateway or a
/// hand-started dsh for the same home can still be swept. Upgrade when
/// multiple gateways must share a home.
pub fn reapOrphans(allocator: Allocator, opts: Options, exclude_pid: ?i32) void {
    if (opts.reap) |hook| {
        hook(opts.reap_ctx, &opts, exclude_pid);
        return;
    }
    if (comptime builtin.os.tag != .linux) return;
    reapOrphansIn(allocator, "/proc", opts.bin_js, opts.dsh_home, exclude_pid, killOrphan, null);
}

/// Test seam: `proc_root` and `killer` are injectable so a fake tree can be
/// swept without touching the real process table.
pub fn reapOrphansIn(
    allocator: Allocator,
    proc_root: []const u8,
    bin_js: []const u8,
    dsh_home: []const u8,
    exclude_pid: ?i32,
    killer: *const fn (ctx: ?*anyopaque, pid: i32) void,
    killer_ctx: ?*anyopaque,
) void {
    const pids = collectOrphans(allocator, proc_root, bin_js, dsh_home, exclude_pid, ownPid()) catch return;
    defer allocator.free(pids);
    for (pids) |pid| killer(killer_ctx, pid);
    // The lock is released by process teardown, which can trail the signal.
    for (pids) |pid| waitPidGone(allocator, proc_root, pid);
}

/// The gateway's own pid, or null where the sweep cannot run.
fn ownPid() ?i32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .macos => @intCast(std.c.getpid()),
        else => null,
    };
}

fn readPpid(allocator: Allocator, proc_root: []const u8, pid: i32) ?i32 {
    var name_buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}", .{pid}) catch return null;
    const stat = readProcFile(allocator, proc_root, name, "stat") orelse return null;
    defer allocator.free(stat);
    // `pid (comm) state ppid …`; comm may contain spaces and parentheses.
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    _ = fields.next() orelse return null; // state
    const ppid_text = fields.next() orelse return null;
    return std.fmt.parseInt(i32, ppid_text, 10) catch null;
}

/// True when `pid` is the gateway, one of its ancestors, or one of its
/// descendants. The sweep must never kill the process tree running it.
fn inOwnProcessTree(allocator: Allocator, proc_root: []const u8, pid: i32, self_pid: i32) bool {
    if (pid == self_pid) return true;
    var current = self_pid;
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        const ppid = readPpid(allocator, proc_root, current) orelse break;
        if (ppid <= 0 or ppid == current) break;
        if (ppid == pid) return true;
        current = ppid;
    }
    current = pid;
    hops = 0;
    while (hops < 64) : (hops += 1) {
        const ppid = readPpid(allocator, proc_root, current) orelse return false;
        if (ppid <= 0 or ppid == current) return false;
        if (ppid == self_pid) return true;
        current = ppid;
    }
    return false;
}

/// Pids whose argv carries this exact `bin_js` and whose environment carries
/// this exact `DSH_HOME`. Excludes `exclude_pid` (the live sidecar of this
/// gateway, which must survive a retry sweep) and the gateway's own process
/// tree.
fn collectOrphans(
    allocator: Allocator,
    proc_root: []const u8,
    bin_js: []const u8,
    dsh_home: []const u8,
    exclude_pid: ?i32,
    self_pid: ?i32,
) ![]i32 {
    const home = std.mem.trimEnd(u8, dsh_home, "/");
    const expected_home = try std.fmt.allocPrint(allocator, "DSH_HOME={s}", .{home});
    defer allocator.free(expected_home);

    var pids: std.ArrayListUnmanaged(i32) = .empty;
    errdefer pids.deinit(allocator);

    var dir = try std_compat.fs.openDirAbsolute(proc_root, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        if (pid <= 0) continue;
        if (exclude_pid) |excluded| if (pid == excluded) continue;
        if (self_pid) |own| if (inOwnProcessTree(allocator, proc_root, pid, own)) continue;
        if (!processOwnsHome(allocator, proc_root, entry.name, bin_js, expected_home)) continue;
        try pids.append(allocator, pid);
    }
    // /proc iteration order is arbitrary; a stable order keeps the sweep and
    // its tests deterministic.
    std.mem.sort(i32, pids.items, {}, std.sort.asc(i32));
    return pids.toOwnedSlice(allocator);
}

fn processOwnsHome(
    allocator: Allocator,
    proc_root: []const u8,
    pid_name: []const u8,
    bin_js: []const u8,
    expected_home: []const u8,
) bool {
    const cmdline = readProcFile(allocator, proc_root, pid_name, "cmdline") orelse return false;
    defer allocator.free(cmdline);
    if (!containsNulEntry(cmdline, bin_js)) return false;

    const environ = readProcFile(allocator, proc_root, pid_name, "environ") orelse return false;
    defer allocator.free(environ);
    return containsNulEntry(environ, expected_home);
}

/// Reads one /proc file, or null when it is gone or unreadable (another
/// user's process, a zombie). 64 KiB covers any realistic cmdline/environ.
fn readProcFile(
    allocator: Allocator,
    proc_root: []const u8,
    pid_name: []const u8,
    file_name: []const u8,
) ?[]u8 {
    const path = std.fs.path.join(allocator, &.{ proc_root, pid_name, file_name }) catch return null;
    defer allocator.free(path);
    const file = std_compat.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024) catch null;
}

fn containsNulEntry(data: []const u8, needle: []const u8) bool {
    // An empty needle equals every NUL-delimited entry (and /proc/cmdline
    // ends with a NUL), so it would match any process.
    if (needle.len == 0) return false;
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| if (std.mem.eql(u8, entry, needle)) return true;
    return false;
}

fn killOrphan(_: ?*anyopaque, pid: i32) void {
    if (comptime builtin.os.tag == .windows) return;
    // The sidecar leads its own process group (pgid = 0); kill the group so
    // any workers dsh spawned die with it.
    std.posix.kill(-pid, std.posix.SIG.KILL) catch {
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    };
}

fn waitPidGone(allocator: Allocator, proc_root: []const u8, pid: i32) void {
    const name = std.fmt.allocPrint(allocator, "{d}", .{pid}) catch return;
    defer allocator.free(name);
    const path = std.fs.path.join(allocator, &.{ proc_root, name }) catch return;
    defer allocator.free(path);

    const deadline = std_compat.time.milliTimestamp() + @as(i64, @intCast(ORPHAN_EXIT_TIMEOUT_MS));
    while (std_compat.time.milliTimestamp() < deadline) {
        std_compat.fs.accessAbsolute(path, .{}) catch return;
        std_compat.thread.sleep(5 * std.time.ns_per_ms);
    }
}

/// Exchange a launch URL for its owner cookie without spawning a process.
/// Used by the harness when `boot_url` is injected (tests/external sidecar).
pub fn fetchOwnerCookieForUrl(allocator: Allocator, boot_url: []const u8, timeout_ms: u64) ![]u8 {
    const url = try client.connectUrl(allocator, boot_url);
    defer allocator.free(url);

    const response = try client.httpRequest(allocator, .GET, url, &.{}, null, timeout_ms);
    defer allocator.free(response.headers);
    defer allocator.free(response.body);

    if (response.status != 302) return error.OwnerConnectRejected;

    var values: std.ArrayListUnmanaged([]const u8) = .empty;
    defer values.deinit(allocator);
    var lines = std.mem.splitScalar(u8, response.headers, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.ascii.startsWithIgnoreCase(trimmed, "set-cookie:")) continue;
        const value = std.mem.trim(u8, trimmed["set-cookie:".len..], " \t");
        if (value.len > 0) try values.append(allocator, value);
    }
    if (values.items.len == 0) return error.OwnerCookieMissing;
    return protocol.ownerCookieFromSetCookie(allocator, values.items);
}

pub const Sidecar = struct {
    allocator: Allocator,
    opts: Options,
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8 = &.{},
    env_map: ?*std_compat.process.EnvMap = null,
    child: ?std_compat.process.Child = null,
    /// The live child's pid (POSIX only), so a retry sweep can spare it.
    child_pid: ?i32 = null,
    stdout_ctx: ?*OutputCtx = null,
    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,
    boot_url: ?[]u8 = null,
    base_url: ?[]u8 = null,
    cookie: ?[]u8 = null,
    port: u16 = 0,
    restart_attempt: u32 = 0,

    pub fn start(allocator: Allocator, opts: Options) !Sidecar {
        var self = Sidecar{
            .allocator = allocator,
            .opts = opts,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.deinit();
        try self.initSpawnArgs();
        try self.spawnAndBoot();
        return self;
    }

    pub fn deinit(self: *Sidecar) void {
        self.stop();
        self.clearSessionState();
        self.arena.deinit();
    }

    pub fn pid(self: *const Sidecar) ?i32 {
        return self.child_pid;
    }

    /// Kill the current process (and its group), back off, then reboot and
    /// exchange a fresh owner cookie. The backoff grows while restarts fail.
    pub fn restart(self: *Sidecar) !void {
        self.stop();
        self.clearSessionState();

        const delay = backoffDelayMs(self.restart_attempt);
        if (self.restart_attempt < std.math.maxInt(u32)) self.restart_attempt += 1;
        std_compat.thread.sleep(delay * std.time.ns_per_ms);

        try self.spawnAndBoot();
        self.restart_attempt = 0;
    }

    /// GET `/connect?token=…&interactions=answer` and return the owner cookie.
    pub fn fetchOwnerCookie(self: *Sidecar) ![]u8 {
        const boot_url = self.boot_url orelse return error.SidecarNotStarted;
        return fetchOwnerCookieForUrl(self.allocator, boot_url, self.opts.rpc_timeout_ms);
    }

    fn initSpawnArgs(self: *Sidecar) !void {
        const arena = self.arena.allocator();

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        // The argv must outlive the caller's strings: `ensureBooted` frees its
        // NULLCLAW_DSH_BIN copy when the spawn block ends, while restart()
        // reuses argv. Keep owned copies in the sidecar arena.
        try argv.append(arena, try arena.dupe(u8, self.opts.node_exe));
        try argv.append(arena, try arena.dupe(u8, self.opts.bin_js));
        for ([_][]const u8{ "--profile", profile_mod.profile_name, "--no-open", "--host", "127.0.0.1", "--port", "0" }) |argument| {
            try argv.append(arena, argument);
        }
        self.argv = try argv.toOwnedSlice(arena);

        const env_map = try arena.create(std_compat.process.EnvMap);
        env_map.* = try buildEnvMap(arena, self.opts);
        self.env_map = env_map;
    }

    /// Take ownership of `url` as the boot URL, freeing any previous value.
    fn adoptBootUrl(self: *Sidecar, url: []u8) void {
        if (self.boot_url) |old| self.allocator.free(old);
        self.boot_url = url;
    }

    fn spawnAndBoot(self: *Sidecar) !void {
        // A gateway killed with SIGKILL leaves its sidecar running, still
        // holding session.lock; clear those before dsh boots, or every resume
        // answers session/writer-held.
        reapOrphans(self.allocator, self.opts, null);

        var child = std_compat.process.Child.init(self.argv, self.allocator);
        child.cwd = self.opts.workspace;
        child.env_map = self.env_map;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        if (comptime builtin.os.tag != .windows) child.pgid = 0;
        try child.spawn();

        self.child = child;
        if (comptime builtin.os.tag != .windows) self.child_pid = child.id;
        // A failed boot must not leak a half-started process or its pipes:
        // `restart` retries from a clean state, and a crash loop must not pile
        // up children. `restart_attempt` is only reset by a successful boot.
        errdefer self.stop();
        const stdout_file = child.stdout orelse return error.SidecarSpawnFailed;
        const stderr_file = child.stderr orelse return error.SidecarSpawnFailed;

        const ctx = try self.allocator.create(OutputCtx);
        ctx.* = .{ .allocator = self.allocator, .file = stdout_file };
        self.stdout_ctx = ctx;
        self.stdout_thread = try std.Thread.spawn(.{}, stdoutMain, .{ctx});
        self.stderr_thread = try std.Thread.spawn(.{}, stderrMain, .{stderr_file});

        const boot_url = try self.waitBootUrl();
        // Adopt before any fallible step: from here the Sidecar owns the URL,
        // so error paths must not free it (clearSessionState does).
        self.adoptBootUrl(boot_url);
        const endpoint = try client.parseBootEndpoint(boot_url);

        self.base_url = try self.allocator.dupe(u8, endpoint.base_url);
        self.port = endpoint.port;
        self.cookie = try self.fetchOwnerCookie();
    }

    fn waitBootUrl(self: *Sidecar) ![]u8 {
        const ctx = self.stdout_ctx orelse return error.SidecarSpawnFailed;
        const deadline = std_compat.time.milliTimestamp() + @as(i64, @intCast(self.opts.boot_timeout_ms));
        while (true) {
            ctx.mutex.lock();
            if (ctx.boot_url) |url| {
                const copy = self.allocator.dupe(u8, url) catch |err| {
                    ctx.mutex.unlock();
                    return err;
                };
                ctx.mutex.unlock();
                return copy;
            }
            const eof = ctx.eof;
            ctx.mutex.unlock();

            if (eof) return error.SidecarBootFailed;
            if (std_compat.time.milliTimestamp() >= deadline) return error.SidecarBootTimeout;
            std_compat.thread.sleep(20 * std.time.ns_per_ms);
        }
    }

    fn stop(self: *Sidecar) void {
        self.child_pid = null;
        if (self.child) |*child| killTree(child);

        // The process group is dead, so the pipes report EOF and readers exit.
        if (self.stdout_thread) |thread| {
            thread.join();
            self.stdout_thread = null;
        }
        if (self.stderr_thread) |thread| {
            thread.join();
            self.stderr_thread = null;
        }
        if (self.child) |*child| {
            _ = child.wait() catch {};
            self.child = null;
        }
        if (self.stdout_ctx) |ctx| {
            ctx.buffer.deinit(ctx.allocator);
            if (ctx.boot_url) |url| ctx.allocator.free(url);
            self.allocator.destroy(ctx);
            self.stdout_ctx = null;
        }
    }

    fn clearSessionState(self: *Sidecar) void {
        if (self.boot_url) |url| self.allocator.free(url);
        if (self.base_url) |url| self.allocator.free(url);
        if (self.cookie) |cookie| self.allocator.free(cookie);
        self.boot_url = null;
        self.base_url = null;
        self.cookie = null;
        self.port = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests (pure logic; no Node, network, or wall-clock assertions)
// ---------------------------------------------------------------------------

test "restart backoff starts at 200ms, doubles, and caps at 5s" {
    const expected = [_]u64{ 200, 400, 800, 1600, 3200, 5000, 5000 };
    for (expected, 0..) |want, index| {
        try std.testing.expectEqual(want, backoffDelayMs(@intCast(index)));
    }
}

test "failed boot keeps the restart attempt and reaps the child" {
    // Regression: a boot failure after spawn left the half-started child and
    // its pipe threads running until the next restart (or forever, if the
    // crash-loop cap stopped further restarts).
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .freestanding) {
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;
    var self = Sidecar{
        .allocator = allocator,
        .opts = .{
            .node_exe = "/bin/false",
            .bin_js = "unused",
            .workspace = ".",
            .dsh_home = "/tmp/dsh-sidecar-test-home",
            .boot_timeout_ms = 2_000,
        },
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    defer self.deinit();
    try self.initSpawnArgs();

    try std.testing.expectError(error.SidecarBootFailed, self.restart());
    try std.testing.expectEqual(@as(u32, 1), self.restart_attempt);
    try std.testing.expect(self.child == null);
    try std.testing.expect(self.stdout_thread == null);
    try std.testing.expect(self.stderr_thread == null);
    try std.testing.expect(self.stdout_ctx == null);
}

test "spawn argv owns copies of node_exe and bin_js" {
    // Regression: argv held slices into the caller's strings. `ensureBooted`
    // frees its NULLCLAW_DSH_BIN copy when the spawn block ends, so restart()
    // ran `node` with a dangling module path ("Cannot find module
    // '/nullclaw-data/workspace/@…'") for every reused argv.
    const allocator = std.testing.allocator;
    const node_src = try allocator.dupe(u8, "node-test");
    defer allocator.free(node_src);
    const bin_src = try allocator.dupe(u8, "/opt/dsh/lib/bin.js");
    defer allocator.free(bin_src);

    var sidecar = Sidecar{
        .allocator = allocator,
        .opts = .{ .node_exe = node_src, .bin_js = bin_src, .workspace = "/tmp", .dsh_home = "/tmp" },
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    defer sidecar.deinit();
    try sidecar.initSpawnArgs();

    // Stand in for the caller mutating its copies after start() returned.
    @memset(node_src, 'X');
    @memset(bin_src, 'X');
    try std.testing.expectEqualStrings("node-test", sidecar.argv[0]);
    try std.testing.expectEqualStrings("/opt/dsh/lib/bin.js", sidecar.argv[1]);
}

test "sidecar environment sets required defaults and honors overrides" {
    var env = try buildEnvMap(std.testing.allocator, .{
        .bin_js = "/opt/dsh/lib/bin.js",
        .workspace = "/tmp/workspace",
        .dsh_home = "/tmp/dsh-home",
        .env = &.{.{ .key = "MOCK_API_KEY", .value = "override-key" }},
    });
    defer env.deinit();

    try std.testing.expectEqualStrings("/tmp/dsh-home", env.get("DSH_HOME").?);
    try std.testing.expectEqualStrings("DISABLED", env.get("DSH_TELEMETRY_MODE").?);
    try std.testing.expectEqualStrings("override-key", env.get("MOCK_API_KEY").?);
}

test "session id roundtrips through a small JSON file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "dsh-session.json" });
    defer std.testing.allocator.free(path);

    try saveSessionId(path, "session-test-1");

    const loaded = try loadSessionId(std.testing.allocator, path);
    defer if (loaded) |session_id| std.testing.allocator.free(session_id);
    try std.testing.expect(loaded != null);
    try std.testing.expectEqualStrings("session-test-1", loaded.?);
}

test "missing session id file loads as null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "absent.json" });
    defer std.testing.allocator.free(path);

    try std.testing.expect((try loadSessionId(std.testing.allocator, path)) == null);
}

test "boot URL has one owner across adopt and teardown" {
    // Regression: error path + deinit double-freed boot_url.
    const allocator = std.testing.allocator;
    var sidecar = Sidecar{
        .allocator = allocator,
        .opts = .{ .bin_js = "/nonexistent/bin.js", .workspace = "/tmp", .dsh_home = "/tmp" },
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    defer sidecar.arena.deinit();

    sidecar.adoptBootUrl(try allocator.dupe(u8, "http://127.0.0.1:1/?token=test-token"));
    sidecar.adoptBootUrl(try allocator.dupe(u8, "http://127.0.0.1:2/?token=test-token"));
    try std.testing.expectEqualStrings("http://127.0.0.1:2/?token=test-token", sidecar.boot_url.?);

    sidecar.clearSessionState();
    try std.testing.expect(sidecar.boot_url == null);
}

fn writeProcEntry(dir: std_compat.fs.Dir, name: []const u8, cmdline: []const u8, environ: []const u8) !void {
    try dir.makeDir(name);
    var entry = try dir.openDir(name, .{});
    defer entry.close();
    try entry.writeFile(.{ .sub_path = "cmdline", .data = cmdline });
    try entry.writeFile(.{ .sub_path = "environ", .data = environ });
}

test "collectOrphans matches dsh by bin path and DSH_HOME" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try writeProcEntry(std_compat.fs.Dir.wrap(tmp.dir), "100", "node\x00/opt/dsh/lib/bin.js\x00--profile\x00web\x00", "PATH=/usr/bin\x00DSH_HOME=/tmp/dsh-home\x00");
    // Another DSH_HOME, another dsh install, the excluded live sidecar, and a
    // non-pid entry: none of these belong to this engine.
    try writeProcEntry(std_compat.fs.Dir.wrap(tmp.dir), "101", "node\x00/opt/dsh/lib/bin.js\x00", "DSH_HOME=/tmp/other-home\x00");
    try writeProcEntry(std_compat.fs.Dir.wrap(tmp.dir), "102", "node\x00/opt/other/bin.js\x00", "DSH_HOME=/tmp/dsh-home\x00");
    try writeProcEntry(std_compat.fs.Dir.wrap(tmp.dir), "103", "node\x00/opt/dsh/lib/bin.js\x00", "DSH_HOME=/tmp/dsh-home\x00");
    try writeProcEntry(std_compat.fs.Dir.wrap(tmp.dir), "self", "nullclaw\x00", "DSH_HOME=/tmp/dsh-home\x00");

    const pids = try collectOrphans(allocator, root, "/opt/dsh/lib/bin.js", "/tmp/dsh-home", 103, null);
    defer allocator.free(pids);
    try std.testing.expectEqualSlices(i32, &.{100}, pids);
}

const KillLog = struct {
    allocator: Allocator,
    root: []const u8,
    pids: std.ArrayListUnmanaged(i32) = .empty,
};

fn recordKill(ctx: ?*anyopaque, pid: i32) void {
    const log: *KillLog = @ptrCast(@alignCast(ctx.?));
    log.pids.append(log.allocator, pid) catch {};
    // Model the kernel reaping the process so the bounded wait returns now.
    const name = std.fmt.allocPrint(log.allocator, "{d}", .{pid}) catch return;
    defer log.allocator.free(name);
    var dir = std_compat.fs.openDirAbsolute(log.root, .{}) catch return;
    defer dir.close();
    dir.deleteTree(name) catch {};
}

test "reapOrphansIn kills every leftover dsh for the home" {
    // Regression: a SIGKILLed gateway left its sidecar as an orphan (PPid=1)
    // holding session.lock; the next gateway's dsh answered session/writer-held.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try writeProcEntry(std_compat.fs.Dir.wrap(tmp.dir), "100", "node\x00/opt/dsh/lib/bin.js\x00", "DSH_HOME=/tmp/dsh-home\x00");
    try writeProcEntry(std_compat.fs.Dir.wrap(tmp.dir), "101", "node\x00/opt/dsh/lib/bin.js\x00", "DSH_HOME=/tmp/other-home\x00");
    try writeProcEntry(std_compat.fs.Dir.wrap(tmp.dir), "102", "node\x00/opt/dsh/lib/bin.js\x00", "DSH_HOME=/tmp/dsh-home\x00");

    var log = KillLog{ .allocator = allocator, .root = root };
    defer log.pids.deinit(allocator);
    reapOrphansIn(allocator, root, "/opt/dsh/lib/bin.js", "/tmp/dsh-home", null, recordKill, &log);

    try std.testing.expectEqualSlices(i32, &.{ 100, 102 }, log.pids.items);
    // The sweep waited for each pid to leave the proc tree.
    var dir = try std_compat.fs.openDirAbsolute(root, .{});
    defer dir.close();
    try std.testing.expectError(error.FileNotFound, dir.openDir("100", .{}));
    try std.testing.expectError(error.FileNotFound, dir.openDir("102", .{}));
}

fn writeProcStat(dir: std_compat.fs.Dir, name: []const u8, ppid: i32) !void {
    var entry = try dir.openDir(name, .{});
    defer entry.close();
    var buf: [64]u8 = undefined;
    const stat = try std.fmt.bufPrint(&buf, "{s} (dsh) S {d} 1 1 1\n", .{ name, ppid });
    try entry.writeFile(.{ .sub_path = "stat", .data = stat });
}

test "empty bin path never matches a gateway-shaped process" {
    // Regression: an empty bin_js matched the trailing NUL of /proc/cmdline,
    // so the sweep killed the gateway itself (argv "nullclaw", DSH_HOME set).
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try writeProcEntry(std_compat.fs.Dir.wrap(tmp.dir), "100", "nullclaw\x00", "DSH_HOME=/tmp/dsh-home\x00");
    const pids = try collectOrphans(allocator, root, "", "/tmp/dsh-home", null, null);
    defer allocator.free(pids);
    try std.testing.expectEqualSlices(i32, &.{}, pids);
}

test "sweep spares the gateway process tree and kills orphans" {
    // Regression: every same-bin+home process was killed, including the live
    // sidecar child of this gateway and the gateway's own ancestors.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const raw = std_compat.fs.Dir.wrap(tmp.dir);
    const root = try raw.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const cmdline = "node\x00/opt/dsh/lib/bin.js\x00";
    const environ = "DSH_HOME=/tmp/dsh-home\x00";

    // Gateway 999, its parent 500, and init.
    try writeProcEntry(raw, "999", cmdline, environ);
    try writeProcStat(raw, "999", 500);
    try writeProcEntry(raw, "500", cmdline, environ);
    try writeProcStat(raw, "500", 1);
    // Children of the gateway: the live sidecar 200 and its grandchild 600.
    try writeProcEntry(raw, "200", cmdline, environ);
    try writeProcStat(raw, "200", 999);
    try writeProcEntry(raw, "600", cmdline, environ);
    try writeProcStat(raw, "600", 200);
    // Orphans: adopted by init, and one whose parent is already gone.
    try writeProcEntry(raw, "400", cmdline, environ);
    try writeProcStat(raw, "400", 1);
    try writeProcEntry(raw, "401", cmdline, environ);

    const pids = try collectOrphans(allocator, root, "/opt/dsh/lib/bin.js", "/tmp/dsh-home", null, 999);
    defer allocator.free(pids);
    try std.testing.expectEqualSlices(i32, &.{ 400, 401 }, pids);
}

const ReapCtl = struct { calls: u32 = 0, last_exclude: ?i32 = null };

fn countReap(ctx: ?*anyopaque, _: *const Options, exclude_pid: ?i32) void {
    const ctl: *ReapCtl = @ptrCast(@alignCast(ctx.?));
    ctl.calls += 1;
    ctl.last_exclude = exclude_pid;
}

test "sidecar start reaps leftovers before spawning" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .freestanding) {
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;
    var ctl = ReapCtl{};
    var self = Sidecar{
        .allocator = allocator,
        .opts = .{
            .node_exe = "/bin/false",
            .bin_js = "unused",
            .workspace = ".",
            .dsh_home = "/tmp/dsh-sidecar-test-home",
            .boot_timeout_ms = 2_000,
            .reap = countReap,
            .reap_ctx = &ctl,
        },
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    defer self.deinit();
    try self.initSpawnArgs();

    try std.testing.expectError(error.SidecarBootFailed, self.spawnAndBoot());
    try std.testing.expectEqual(@as(u32, 1), ctl.calls);
    try std.testing.expectEqual(@as(?i32, null), ctl.last_exclude);
}
