//! Lazily started Firefox/geckodriver lifecycle for the WebDriver backend.
//!
//! One manager owns at most one browser. `acquire`/`release` serialize all
//! commands on the manager mutex (the 2.4 GB target machine must never run two
//! Firefox instances). The geckodriver child is spawned on a random loopback
//! port, reaped on every stop path, and rebuilt on the next call when the
//! browser died (OOM, crash) or the driver refused the session.
const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const client_mod = @import("webdriver_client.zig");
const WebDriverClient = client_mod.WebDriverClient;
const webdriver_security = @import("webdriver_security.zig");
const webdriver_proxy = @import("webdriver_proxy.zig");

const Allocator = std.mem.Allocator;

/// geckodriver usually binds in well under a second; this bounds a broken one.
const startup_timeout_ms: u64 = 10_000;
const readiness_poll_ms: u64 = 100;
const reaper_poll_ms: u64 = 250;

pub const Options = struct {
    /// Attach to an already running WebDriver endpoint instead of spawning
    /// geckodriver. Slices are borrowed from the caller for the manager's life.
    driver_url: ?[]const u8 = null,
    geckodriver_path: []const u8 = "geckodriver",
    headless: bool = true,
    /// 0 disables idle shutdown.
    idle_timeout_ms: u64 = 120_000,
    /// `browser.allowed_domains`, deep-copied into the filtering proxy when the
    /// session starts. The manager is process-wide, so the first caller's
    /// options are the ones in force.
    allowed_domains: []const []const u8 = &.{},
    /// Clock override for idle expiry (tests only); null uses the wall clock.
    clock: ?*const fn () i64 = null,
};

pub const WebDriverManager = struct {
    allocator: Allocator,
    options: Options,
    mutex: compat.sync.Mutex = .{},
    running: ?Running = null,
    reaper: ?std.Thread = null,
    stop_reaper: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_error: ?[]u8 = null,

    const Running = struct {
        client: WebDriverClient,
        child: ?compat.process.Child = null,
        /// One-shot profile passed to Firefox; deleted on every stop path.
        profile: webdriver_security.Profile,
        /// Filtering proxy Firefox is forced through; joined on every stop
        /// path. Null only for an external `driver_url` endpoint.
        proxy: ?*webdriver_proxy.Proxy = null,
        last_activity_ms: i64,
    };

    pub fn init(allocator: Allocator, options: Options) WebDriverManager {
        return .{ .allocator = allocator, .options = options };
    }

    /// Stop the browser and the idle reaper. Safe to call more than once.
    pub fn deinit(self: *WebDriverManager) void {
        self.shutdown();
        if (self.last_error) |message| self.allocator.free(message);
        self.* = undefined;
    }

    pub fn lastErrorMessage(self: *const WebDriverManager) []const u8 {
        return self.last_error orelse "";
    }

    /// Lock the manager and make sure a live browser session exists. Every
    /// successful acquire must be paired with `release` (use `defer`).
    pub fn acquire(self: *WebDriverManager) !*WebDriverClient {
        self.mutex.lock();
        errdefer self.mutex.unlock();
        try self.ensureLocked();
        const running = &self.running.?;
        running.last_activity_ms = self.now();
        return &running.client;
    }

    pub fn release(self: *WebDriverManager) void {
        if (self.running) |*running| {
            if (running.client.stale) {
                // The next acquire rebuilds geckodriver/Firefox from scratch.
                self.stopLocked();
            } else {
                running.last_activity_ms = self.now();
            }
        }
        self.mutex.unlock();
    }

    /// Close the browser now. Called on agent end / session close / deinit.
    pub fn shutdown(self: *WebDriverManager) void {
        self.stop_reaper.store(true, .release);
        if (self.reaper) |thread| {
            thread.join();
            self.reaper = null;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopLocked();
    }

    fn ensureLocked(self: *WebDriverManager) !void {
        if (self.running != null) return;
        self.running = try self.startLocked();
        self.ensureReaperLocked();
    }

    /// Returns a connected, session-open browser. On success ownership moves to
    /// `self.running`; on failure every spawned child is killed and reaped.
    fn startLocked(self: *WebDriverManager) !Running {
        // The proxy starts first: its port goes into user.js, and no Firefox
        // may start without it (fail closed; there is no direct-connection
        // fallback). An external driver_url endpoint is test-only and owns its
        // own profile, so it keeps running without our proxy.
        var proxy: ?*webdriver_proxy.Proxy = null;
        errdefer if (proxy) |active| active.deinit();
        if (self.options.driver_url == null) proxy = try self.startProxyLocked();

        var profile = webdriver_security.Profile.create(
            self.allocator,
            if (proxy) |active| active.port() else null,
        ) catch |err| {
            self.setLastErrorFmt("failed to create one-shot browser profile: {s}", .{@errorName(err)});
            return err;
        };
        errdefer profile.deinit();

        var child: ?compat.process.Child = null;
        var owned_url: ?[]u8 = null;
        errdefer {
            if (owned_url) |url| self.allocator.free(url);
            if (child) |*spawned| terminateChild(spawned);
        }

        const url = if (self.options.driver_url) |external| blk: {
            const endpoint = try self.allocator.dupe(u8, external);
            owned_url = endpoint;
            break :blk endpoint;
        } else blk: {
            const port = randomLoopbackPort();
            var port_buf: [5]u8 = undefined;
            const port_text = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;
            var spawned = compat.process.Child.init(
                &.{ self.options.geckodriver_path, "--host", "127.0.0.1", "--port", port_text },
                self.allocator,
            );
            // geckodriver must not hold the agent's stdio open; logs are not
            // needed because failures are reported through lastError.
            spawned.stdin_behavior = .Ignore;
            spawned.stdout_behavior = .Ignore;
            spawned.stderr_behavior = .Ignore;
            if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
                // Own process group so stop kills Firefox with the driver.
                spawned.pgid = 0;
            }
            spawned.spawn() catch |err| {
                self.setLastErrorFmt("failed to start geckodriver ({s}): {s}", .{
                    self.options.geckodriver_path,
                    @errorName(err),
                });
                return error.DriverStartFailed;
            };
            child = spawned;
            const endpoint = try std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}", .{port});
            owned_url = endpoint;
            self.waitForReady(endpoint) catch {
                self.setLastErrorFmt("geckodriver did not become ready at {s} within {d} ms", .{
                    endpoint,
                    startup_timeout_ms,
                });
                return error.DriverStartFailed;
            };
            break :blk endpoint;
        };

        var client = WebDriverClient.init(self.allocator, url) catch |err| {
            self.setLastErrorFmt("invalid webdriver endpoint {s}: {s}", .{ url, @errorName(err) });
            return err;
        };
        if (owned_url) |value| {
            self.allocator.free(value);
            owned_url = null;
        }

        client.newSession(.{
            .headless = self.options.headless,
            .profile_path = profile.path,
        }) catch |err| {
            self.setLastErrorFmt("webdriver session creation failed: {s} ({s})", .{
                client.lastErrorMessage(),
                @errorName(err),
            });
            client.deinit();
            return err;
        };
        return .{
            .client = client,
            .child = child,
            .profile = profile,
            .proxy = proxy,
            .last_activity_ms = self.now(),
        };
    }

    /// Start the session's filtering proxy. A failure fails the session start;
    /// falling back to the per-navigation URL check alone is not an option.
    fn startProxyLocked(self: *WebDriverManager) !*webdriver_proxy.Proxy {
        return webdriver_proxy.Proxy.start(self.allocator, .{
            .allowed_domains = self.options.allowed_domains,
        }) catch |err| {
            self.setLastErrorFmt("failed to start browser filtering proxy: {s}", .{@errorName(err)});
            return err;
        };
    }

    fn waitForReady(self: *WebDriverManager, endpoint: []const u8) !void {
        var probe = try WebDriverClient.init(self.allocator, endpoint);
        defer probe.deinit();
        const deadline = nowMs() + startup_timeout_ms;
        while (nowMs() < deadline) {
            if (probe.statusReady()) return;
            compat.thread.sleep(readiness_poll_ms * std.time.ns_per_ms);
        }
        return error.DriverStartTimeout;
    }

    fn stopLocked(self: *WebDriverManager) void {
        if (self.running) |*running| {
            if (running.client.hasSession() and !running.client.stale) {
                // Ask geckodriver to quit Firefox first; the group kill below
                // is the fallback for a driver that cannot honor it.
                running.client.deleteSession() catch {};
            }
            running.client.deinit();
            if (running.child) |*child| terminateChild(child);
            running.profile.deinit();
            // Last, so browser shutdown traffic above can still drain: the
            // proxy stops every tunnel and joins every worker here.
            if (running.proxy) |proxy| proxy.deinit();
            self.running = null;
        }
    }

    fn ensureReaperLocked(self: *WebDriverManager) void {
        if (self.reaper != null) return;
        self.stop_reaper.store(false, .release);
        self.reaper = std.Thread.spawn(.{}, reaperMain, .{self}) catch null;
        // A thread that cannot be spawned only loses automatic idle shutdown;
        // the next acquire still restarts a closed session.
    }

    fn reaperMain(self: *WebDriverManager) void {
        while (!self.stop_reaper.load(.acquire)) {
            compat.thread.sleep(reaper_poll_ms * std.time.ns_per_ms);
            if (self.stop_reaper.load(.acquire)) break;
            self.reapIdleOnce();
        }
    }

    /// One idle-expiry sweep. The reaper thread runs this every poll interval;
    /// tests drive it directly instead of waiting for the thread.
    pub fn reapIdleOnce(self: *WebDriverManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.running) |*running| {
            if (idleExpired(running.last_activity_ms, self.now(), self.options.idle_timeout_ms)) {
                self.stopLocked();
            }
        }
    }

    fn now(self: *const WebDriverManager) i64 {
        return if (self.options.clock) |clock| clock() else nowMs();
    }

    fn setLastErrorFmt(self: *WebDriverManager, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        if (self.last_error) |old| self.allocator.free(old);
        self.last_error = message;
    }

    // ── Process-wide shared manager ─────────────────────────────────
    //
    // Gateway and channel runs each build their own tool set, so a manager
    // per BrowserTool would start one Firefox per session and exhaust a 2.4 GB
    // host. Every tool in the process borrows this manager instead.
    // `shared_mutex` covers lazy creation and teardown, and each action holds a
    // lease, so a concurrent close can never free a manager another action is
    // using.

    /// Borrow the one process-wide manager, creating it on first use. The
    /// caller must pair a successful call with `sharedRelease`. Options come
    /// from the first caller; the process allocator keeps the manager
    /// independent of any one tool's lifetime.
    pub fn sharedAcquire(options: Options) !*WebDriverManager {
        shared_mutex.lock();
        defer shared_mutex.unlock();
        if (shared_manager == null) {
            const manager = try std.heap.page_allocator.create(WebDriverManager);
            manager.* = WebDriverManager.init(std.heap.page_allocator, options);
            shared_manager = manager;
            shared_shutdown_pending = false;
        }
        shared_users += 1;
        return shared_manager.?;
    }

    /// Drop one action lease; a close that raced with the action frees the
    /// manager here.
    pub fn sharedRelease() void {
        shared_mutex.lock();
        defer shared_mutex.unlock();
        std.debug.assert(shared_users > 0);
        shared_users -= 1;
        if (shared_users == 0 and shared_shutdown_pending) destroySharedLocked();
    }

    /// Close the shared browser for every session and report whether one
    /// existed. The next WebDriver action in any session rebuilds it. With no
    /// action in flight the manager itself is freed, which also drops its
    /// borrowed options.
    pub fn sharedShutdown() bool {
        shared_mutex.lock();
        defer shared_mutex.unlock();
        const had_manager = shared_manager != null;
        if (shared_users == 0) {
            destroySharedLocked();
        } else if (shared_manager) |manager| {
            manager.shutdown();
            shared_shutdown_pending = true;
        }
        return had_manager;
    }

    fn destroySharedLocked() void {
        if (shared_manager) |manager| {
            manager.deinit();
            std.heap.page_allocator.destroy(manager);
            shared_manager = null;
        }
        shared_shutdown_pending = false;
    }

    /// Tests only: whether a shared manager exists (running or idle).
    pub fn sharedActiveForTest() bool {
        shared_mutex.lock();
        defer shared_mutex.unlock();
        return shared_manager != null;
    }
};

var shared_mutex: compat.sync.Mutex = .{};
var shared_manager: ?*WebDriverManager = null;
var shared_users: usize = 0;
var shared_shutdown_pending: bool = false;

fn nowMs() i64 {
    return compat.time.milliTimestamp();
}

fn idleExpired(last_activity_ms: i64, current_ms: i64, timeout_ms: u64) bool {
    if (timeout_ms == 0) return false;
    const timeout: i64 = std.math.cast(i64, timeout_ms) orelse std.math.maxInt(i64);
    return current_ms - last_activity_ms >= timeout;
}

fn randomLoopbackPort() u16 {
    // 49152-65535 is the IANA dynamic range; collisions surface as a startup
    // readiness timeout instead of a silently shared driver.
    return 49152 + compat.crypto.random.int(u16) % 16384;
}

/// Kill the whole child process group (POSIX) so Firefox cannot outlive
/// geckodriver, then wait so no zombie remains. Windows has no portable group
/// kill here: the DELETE /session above is the primary Firefox shutdown path.
fn terminateChild(child: *compat.process.Child) void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    } else {
        // TERM first so geckodriver can remove its temporary profile, then KILL
        // everything left in the group and reap the driver (no zombie).
        std.posix.kill(-child.id, std.posix.SIG.TERM) catch {
            std.posix.kill(child.id, std.posix.SIG.TERM) catch {};
        };
        compat.thread.sleep(100 * std.time.ns_per_ms);
        std.posix.kill(-child.id, std.posix.SIG.KILL) catch {
            _ = child.kill() catch {};
        };
        _ = child.wait() catch {};
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "idle timeout honors the configured bound" {
    try std.testing.expect(idleExpired(1_000, 121_000, 120_000));
    try std.testing.expect(!idleExpired(1_000, 120_999, 120_000));
    try std.testing.expect(!idleExpired(1_000, 9_999_999, 0));
}

test "terminateChild kills and reaps the spawned process group" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var child = compat.process.Child.init(&.{ "sleep", "300" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;
    try child.spawn();

    terminateChild(&child);
    // wait() succeeded inside terminateChild, so the process was reaped.
    try std.testing.expect(child.term != null);
}

test "manager reuses one session and deletes it on shutdown" {
    const fake = @import("webdriver_fake_server.zig");
    const allocator = std.testing.allocator;

    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\"}}" },
        .{ .method = "GET", .path = "/session/fake-session/title", .body = "{\"value\":\"first\"}" },
        .{ .method = "GET", .path = "/session/fake-session/title", .body = "{\"value\":\"second\"}" },
        .{ .method = "DELETE", .path = "/session/fake-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const endpoint = try server.url(allocator);
    defer allocator.free(endpoint);

    var manager = WebDriverManager.init(allocator, .{ .driver_url = endpoint });
    defer manager.deinit();

    {
        const client = try manager.acquire();
        defer manager.release();
        const title = try client.getTitle(allocator);
        defer allocator.free(title);
        try std.testing.expectEqualStrings("first", title);
    }
    {
        const client = try manager.acquire();
        defer manager.release();
        const title = try client.getTitle(allocator);
        defer allocator.free(title);
        try std.testing.expectEqualStrings("second", title);
    }
    manager.shutdown();

    server.stopAndJoin();
    try std.testing.expectEqual(routes.len, server.request_count);
    try std.testing.expectEqual(@as(usize, 1), countRequests(server.requests[0..server.request_count], "/session"));
}

test "manager uses a one-shot profile and removes it on shutdown" {
    const fake = @import("webdriver_fake_server.zig");
    const allocator = std.testing.allocator;

    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\"}}" },
        .{ .method = "DELETE", .path = "/session/fake-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const endpoint = try server.url(allocator);
    defer allocator.free(endpoint);

    var manager = WebDriverManager.init(allocator, .{ .driver_url = endpoint, .idle_timeout_ms = 0 });
    defer manager.deinit();

    const client = try manager.acquire();
    try std.testing.expect(client.hasSession());
    const profile_path = try allocator.dupe(u8, manager.running.?.profile.path);
    defer allocator.free(profile_path);
    const user_js_path = try compat.fs.path.join(allocator, &.{ profile_path, "user.js" });
    defer allocator.free(user_js_path);
    try compat.fs.accessAbsolute(user_js_path, .{});
    manager.release();

    manager.shutdown();
    server.stopAndJoin();
    try std.testing.expectEqual(routes.len, server.request_count);
    try std.testing.expect(std.mem.indexOf(u8, server.requests[0].body, "\"-profile\"") != null);
    try std.testing.expectError(error.FileNotFound, compat.fs.accessAbsolute(profile_path, .{}));
}

test "manager rebuilds the session after Firefox dies" {
    const fake = @import("webdriver_fake_server.zig");
    const allocator = std.testing.allocator;

    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"dead-session\"}}" },
        .{
            .method = "GET",
            .path = "/session/dead-session/title",
            .status = 500,
            .body = "{\"value\":{\"error\":\"invalid session id\",\"message\":\"browser gone\",\"stacktrace\":\"\"}}",
        },
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"live-session\"}}" },
        .{ .method = "GET", .path = "/session/live-session/title", .body = "{\"value\":\"recovered\"}" },
        .{ .method = "DELETE", .path = "/session/live-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const endpoint = try server.url(allocator);
    defer allocator.free(endpoint);

    var manager = WebDriverManager.init(allocator, .{ .driver_url = endpoint });
    defer manager.deinit();

    {
        const client = try manager.acquire();
        defer manager.release();
        try std.testing.expectError(error.SessionLost, client.getTitle(allocator));
    }
    {
        const client = try manager.acquire();
        defer manager.release();
        const title = try client.getTitle(allocator);
        defer allocator.free(title);
        try std.testing.expectEqualStrings("recovered", title);
    }
    manager.shutdown();

    server.stopAndJoin();
    try std.testing.expectEqual(routes.len, server.request_count);
    try std.testing.expectEqual(@as(usize, 2), countRequests(server.requests[0..server.request_count], "/session"));
}

test "manager reports a missing geckodriver clearly" {
    const allocator = std.testing.allocator;
    var manager = WebDriverManager.init(allocator, .{
        .geckodriver_path = "/nonexistent/junclaw-test-geckodriver",
        .idle_timeout_ms = 0,
    });
    defer manager.deinit();

    try std.testing.expectError(error.DriverStartFailed, manager.acquire());
    try std.testing.expect(std.mem.indexOf(u8, manager.lastErrorMessage(), "geckodriver") != null);
    // Regression: the proxy starts before geckodriver, so this failure path
    // must tear it down again. The testing allocator reports a proxy object
    // that was never deinit'ed (deinit is what joins the worker threads).
    try std.testing.expect(manager.running == null);
}

test "manager filtering proxy follows allowed_domains from options" {
    const allocator = std.testing.allocator;

    // Empty allowlist: a loopback target is refused before any connection.
    var open = WebDriverManager.init(allocator, .{ .idle_timeout_ms = 0 });
    defer open.deinit();
    const open_proxy = try open.startProxyLocked();
    defer open_proxy.deinit();
    const denied = try webdriver_proxy.requestStatus(open_proxy, "localhost:1");
    defer denied.stream.close();
    try std.testing.expectEqual(@as(u16, 403), denied.status);

    // Non-empty allowlist: a listed host keeps the explicit-trust meaning
    // (private-address checks are skipped, the address is still pinned), so it
    // reaches the connect stage, while an unlisted host is denied.
    var trusted = WebDriverManager.init(allocator, .{
        .idle_timeout_ms = 0,
        .allowed_domains = &.{"localhost"},
    });
    defer trusted.deinit();
    const trusted_proxy = try trusted.startProxyLocked();
    defer trusted_proxy.deinit();
    const dialed = try webdriver_proxy.requestStatus(trusted_proxy, "localhost:1");
    defer dialed.stream.close();
    try std.testing.expectEqual(@as(u16, 502), dialed.status);
    const unlisted = try webdriver_proxy.requestStatus(trusted_proxy, "127.0.0.1:1");
    defer unlisted.stream.close();
    try std.testing.expectEqual(@as(u16, 403), unlisted.status);
}

test "stopLocked shuts down the proxy tunnel and joins its workers" {
    const allocator = std.testing.allocator;

    // Upstream that completes the TCP handshake but never replies, so the
    // tunnel is still active when the manager stops.
    const upstream_address = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var upstream = try upstream_address.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    var authority_buf: [32]u8 = undefined;
    const authority = try std.fmt.bufPrint(
        &authority_buf,
        "localhost:{d}",
        .{upstream.listen_address.in.getPort()},
    );

    var manager = WebDriverManager.init(allocator, .{
        .idle_timeout_ms = 0,
        .allowed_domains = &.{"localhost"},
    });
    defer manager.deinit();
    const proxy = try manager.startProxyLocked();
    const proxy_port = proxy.port();
    const tunnel = try webdriver_proxy.requestStatus(proxy, authority);
    defer tunnel.stream.close();
    try std.testing.expectEqual(@as(u16, 200), tunnel.status);

    manager.running = .{
        .client = try WebDriverClient.init(allocator, "http://127.0.0.1:1"),
        .profile = try webdriver_security.Profile.create(allocator, proxy_port),
        .proxy = proxy,
        .last_activity_ms = manager.now(),
    };
    manager.stopLocked();
    try std.testing.expect(manager.running == null);

    // The listener was closed only after every worker was joined.
    const proxy_address = try compat.net.Address.parseIp4("127.0.0.1", proxy_port);
    if (compat.net.tcpConnectToAddress(proxy_address)) |stream| {
        stream.close();
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn countRequests(requests: anytype, path: []const u8) usize {
    var count: usize = 0;
    for (requests) |request| {
        if (std.mem.eql(u8, request.path, path)) count += 1;
    }
    return count;
}
