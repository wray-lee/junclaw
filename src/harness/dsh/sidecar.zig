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
        try argv.append(arena, self.opts.node_exe);
        try argv.append(arena, self.opts.bin_js);
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
        var child = std_compat.process.Child.init(self.argv, self.allocator);
        child.cwd = self.opts.workspace;
        child.env_map = self.env_map;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        if (comptime builtin.os.tag != .windows) child.pgid = 0;
        try child.spawn();

        self.child = child;
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
