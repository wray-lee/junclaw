//! Lazily started Firefox/geckodriver lifecycle for the WebDriver backend.
//!
//! One manager owns at most one browser. `acquire`/`release` serialize all
//! commands on the manager mutex (the 2.4 GB target machine must never run two
//! Firefox instances). The geckodriver child is spawned on a kernel-assigned
//! loopback port that is proven to belong to it (see `openOwnedSession`),
//! reaped on every stop path, and rebuilt on the next call when the browser
//! died (OOM, crash) or the driver refused the session.
//!
//! Process cleanup (F5/F6): on POSIX a `sh` wrapper holds a pipe from the
//! agent; the kernel closes it when the agent dies, and a watchdog then kills
//! the whole process group. On Windows geckodriver runs in a Job Object with
//! `KILL_ON_JOB_CLOSE`, so its tree dies with the agent. Inside a container
//! PID 1 exiting is the primary guarantee; these are the per-process backstop.
const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const process_util = @import("process_util.zig");
const client_mod = @import("webdriver_client.zig");
const WebDriverClient = client_mod.WebDriverClient;
const webdriver_security = @import("webdriver_security.zig");
const webdriver_proxy = @import("webdriver_proxy.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.browser);

/// geckodriver usually binds in well under a second; this bounds a broken one.
const startup_timeout_ms: u64 = 10_000;
const readiness_poll_ms: u64 = 100;
const reaper_poll_ms: u64 = 250;
/// A driver that wants more than this to exit on SIGTERM is killed outright.
const shutdown_grace_ms: u64 = 2_000;
const shutdown_poll_ms: u64 = 10;
/// Ownership failures (foreign listener, dead child, profile mismatch) retry
/// on a fresh port; these bounds keep startup at 3 x startup_timeout worst case.
const driver_attempts: usize = 3;
const stderr_capture_bytes: usize = 16 * 1024;

/// POSIX wrapper: the agent holds the write end of stdin. When the agent exits
/// (including SIGKILL/OOM) the kernel closes it, `cat` sees EOF and the
/// watchdog kills the whole process group (`$$` is the group leader).
// Regression: a background subshell without job control is given /dev/null as
// stdin (POSIX async-list rule), so `cat` saw EOF at once and the watchdog
// killed every driver at startup. `exec 3<&0` + `cat <&3` keeps the real pipe.
const driver_wrapper =
    \\drv=$1; shift
    \\"$drv" "$@" </dev/null &
    \\driver=$!
    \\exec 3<&0
    \\( cat <&3 >/dev/null; kill -KILL -$$ ) &
    \\watchdog=$!
    \\wait $driver; status=$?
    \\kill $watchdog 2>/dev/null
    \\exit $status
;

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
    /// Tests only: fixed loopback port for the spawned driver instead of a
    /// kernel-assigned one. Production always leaves this null.
    driver_port_override: ?u16 = null,
};

/// Stderr capture and ownership evidence for one spawned driver.
const DriverLog = struct {
    allocator: Allocator,
    file: compat.fs.File,
    thread: std.Thread,
    mutex: compat.sync.Mutex = .{},
    buffer: [stderr_capture_bytes]u8 = undefined,
    len: usize = 0,

    fn start(allocator: Allocator, file: compat.fs.File) !*DriverLog {
        const self = try allocator.create(DriverLog);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .file = file, .thread = undefined };
        self.thread = try std.Thread.spawn(.{}, readMain, .{self});
        return self;
    }

    /// The reader owns the pipe and closes it at EOF, so child cleanup never
    /// closes a descriptor this thread is blocked on.
    fn readMain(self: *DriverLog) void {
        defer self.file.close();
        var chunk: [1024]u8 = undefined;
        while (true) {
            const n = self.file.read(&chunk) catch return;
            if (n == 0) return;
            self.append(chunk[0..n]);
        }
    }

    fn append(self: *DriverLog, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var rest = bytes;
        if (rest.len >= self.buffer.len) rest = rest[rest.len - self.buffer.len ..];
        if (self.len + rest.len > self.buffer.len) {
            const drop = self.len + rest.len - self.buffer.len;
            std.mem.copyForwards(u8, self.buffer[0 .. self.len - drop], self.buffer[drop..self.len]);
            self.len -= drop;
        }
        @memcpy(self.buffer[self.len .. self.len + rest.len], rest);
        self.len += rest.len;
    }

    fn listeningPort(self: *DriverLog) ?u16 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return findListeningPort(self.buffer[0..self.len]);
    }

    /// Copy the newest bytes out for an error message.
    fn tail(self: *DriverLog, out: []u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const text = self.buffer[0..self.len];
        const wanted = @min(text.len, out.len);
        const copy = text[text.len - wanted ..];
        @memcpy(out[0..copy.len], copy);
        return out[0..copy.len];
    }

    fn deinit(self: *DriverLog) void {
        self.thread.join();
        self.allocator.destroy(self);
    }
};

/// One spawned driver that passed every ownership check (F11). Ownership moves
/// into `Running` on success; `deinit` tears down everything on failure.
const SpawnedDriver = struct {
    client: WebDriverClient,
    child: compat.process.Child,
    log: *DriverLog,
    port: u16,
    job: ?process_util.WindowsJob = null,

    fn deinit(self: *SpawnedDriver) void {
        self.client.deinit();
        if (self.job) |*job| job.close();
        terminateChild(&self.child, self.job != null);
        self.log.deinit();
    }
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
        /// Stderr capture + watchdog pipe owner for a spawned driver.
        driver_log: ?*DriverLog = null,
        /// Windows job holding the driver tree; closing it kills the tree.
        job: ?process_util.WindowsJob = null,
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

        var spawned: ?SpawnedDriver = null;
        errdefer if (spawned) |*driver| driver.deinit();

        var client: WebDriverClient = undefined;
        var child: ?compat.process.Child = null;
        var driver_log: ?*DriverLog = null;
        var job: ?process_util.WindowsJob = null;
        var client_owned = false;
        errdefer if (client_owned) client.deinit();

        if (self.options.driver_url) |external| {
            client = WebDriverClient.init(self.allocator, external) catch |err| {
                self.setLastErrorFmt("invalid webdriver endpoint {s}: {s}", .{ external, @errorName(err) });
                return err;
            };
            client_owned = true;
            client.newSession(.{
                .headless = self.options.headless,
                .profile_path = profile.path,
            }) catch |err| {
                self.setLastErrorFmt("webdriver session creation failed: {s} ({s})", .{
                    client.lastErrorMessage(),
                    @errorName(err),
                });
                return err;
            };
        } else {
            spawned = try self.startSpawnedDriverLocked(profile.path);
            // Ownership moves into `Running`; nothing fallible remains, so the
            // `spawned` errdefer is disarmed by setting it to null.
            client = spawned.?.client;
            child = spawned.?.child;
            driver_log = spawned.?.log;
            job = spawned.?.job;
            spawned = null;
        }

        return .{
            .client = client,
            .child = child,
            .profile = profile,
            .proxy = proxy,
            .driver_log = driver_log,
            .job = job,
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

    /// Spawn geckodriver and accept its endpoint only when every ownership
    /// check passes (F11). A foreign listener on the chosen port, a dead
    /// child, or a session on another profile is rejected and retried on a
    /// fresh port; three failures fail the session start (fail closed).
    fn startSpawnedDriverLocked(self: *WebDriverManager, profile_path: []const u8) !SpawnedDriver {
        var attempt: usize = 0;
        var last_reason: []const u8 = "DriverStartTimeout";
        var tail_buf: [256]u8 = undefined;
        var tail_len: usize = 0;
        while (attempt < driver_attempts) : (attempt += 1) {
            const port = self.options.driver_port_override orelse reserveLoopbackPort() catch |err| {
                self.setLastErrorFmt("failed to reserve a loopback port: {s}", .{@errorName(err)});
                return err;
            };
            var driver = self.spawnDriverLocked(port) catch |err| {
                self.setLastErrorFmt("failed to start geckodriver ({s}): {s}", .{
                    self.options.geckodriver_path,
                    @errorName(err),
                });
                return err;
            };
            var accepted = false;
            defer if (!accepted) driver.deinit();
            self.openOwnedSession(&driver, profile_path, startup_timeout_ms) catch |err| {
                last_reason = @errorName(err);
                tail_len = driver.log.tail(&tail_buf).len;
                continue;
            };
            accepted = true;
            return driver;
        }
        self.setLastErrorFmt("failed to start geckodriver ({s}) after {d} attempts: {s} ({s})", .{
            self.options.geckodriver_path,
            driver_attempts,
            last_reason,
            std.mem.trim(u8, tail_buf[0..tail_len], " \t\r\n"),
        });
        return error.DriverStartFailed;
    }

    fn spawnDriverLocked(self: *WebDriverManager, port: u16) !SpawnedDriver {
        var port_buf: [5]u8 = undefined;
        const port_text = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;
        const use_wrapper = comptime builtin.os.tag != .windows and builtin.os.tag != .wasi;

        var child = if (use_wrapper)
            compat.process.Child.init(&.{
                "/bin/sh",                     "-c",     driver_wrapper, "sh",
                self.options.geckodriver_path, "--host", "127.0.0.1",    "--port",
                port_text,
            }, self.allocator)
        else
            compat.process.Child.init(&.{
                self.options.geckodriver_path, "--host", "127.0.0.1", "--port", port_text,
            }, self.allocator);
        // stdin carries the parent-death pipe; stderr carries geckodriver's
        // "Listening on" banner, which is our ownership proof.
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Pipe;
        if (use_wrapper) {
            // Own process group so stop (and the watchdog) kill Firefox too.
            child.pgid = 0;
        }
        if (comptime builtin.os.tag == .windows) child.start_suspended = true;
        try child.spawn();

        var job: ?process_util.WindowsJob = null;
        var driver_log: ?*DriverLog = null;
        errdefer {
            if (job) |*active| active.close();
            terminateChild(&child, job != null);
            if (driver_log) |active| active.deinit();
        }

        if (comptime builtin.os.tag == .windows) {
            job = process_util.WindowsJob.create() catch |err| blk: {
                log.warn("webdriver job object unavailable ({s}); falling back to taskkill", .{@errorName(err)});
                break :blk null;
            };
            if (job) |*active| {
                active.assignProcess(child.id) catch |err| {
                    log.warn("could not add geckodriver to its job ({s}); falling back to taskkill", .{@errorName(err)});
                    active.close();
                    job = null;
                };
            }
            process_util.resumeSuspendedThread(child.thread_handle) catch |err| {
                self.setLastErrorFmt("failed to resume geckodriver: {s}", .{@errorName(err)});
                return err;
            };
        }

        if (use_wrapper) {
            // Other agent children must not inherit the write end, or the
            // kernel's parent-death EOF never arrives.
            try ensureCloseOnExec(child.stdin.?.handle);
        }

        const stderr_file = child.stderr orelse return error.DriverStartFailed;
        child.stderr = null;
        driver_log = DriverLog.start(self.allocator, stderr_file) catch |err| {
            stderr_file.close();
            return err;
        };

        var url_buf: [64]u8 = undefined;
        const endpoint = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{port}) catch unreachable;
        var client = WebDriverClient.init(self.allocator, endpoint) catch |err| {
            self.setLastErrorFmt("invalid webdriver endpoint {s}: {s}", .{ endpoint, @errorName(err) });
            return err;
        };
        errdefer client.deinit();
        return .{ .client = client, .child = child, .log = driver_log.?, .port = port, .job = job };
    }

    /// Accept the session only when the banner came through our child's pipe,
    /// the child was alive at both readiness checks, and the driver reports
    /// our one-shot profile. `/status` alone is never proof of ownership.
    fn openOwnedSession(
        self: *WebDriverManager,
        driver: *SpawnedDriver,
        profile_path: []const u8,
        timeout_ms: u64,
    ) !void {
        awaitDriverOwnership(&driver.client, driver.log, &driver.child, driver.port, timeout_ms) catch |err| {
            self.setLastErrorFmt("geckodriver on port {d} is not ours: {s}", .{ driver.port, @errorName(err) });
            return err;
        };
        driver.client.newSession(.{
            .headless = self.options.headless,
            .profile_path = profile_path,
        }) catch |err| {
            self.setLastErrorFmt("webdriver session creation failed: {s} ({s})", .{
                driver.client.lastErrorMessage(),
                @errorName(err),
            });
            if (driver.client.hasSession()) driver.client.deleteSession() catch {};
            return err;
        };
        if (!profilesMatch(self.allocator, driver.client.lastProfile(), profile_path)) {
            // Regression: a foreign driver on our port used to be accepted on
            // /status alone; its session now fails the profile check.
            self.setLastErrorFmt("driver reported profile {s}, expected ours", .{
                driver.client.lastProfile() orelse "none",
            });
            driver.client.deleteSession() catch {};
            return error.DriverProfileMismatch;
        }
    }

    fn stopLocked(self: *WebDriverManager) void {
        if (self.running) |*running| {
            if (running.client.hasSession() and !running.client.stale) {
                // Ask geckodriver to quit Firefox first; the job/group kill
                // below is the fallback for a driver that cannot honor it.
                running.client.deleteSession() catch {};
            }
            running.client.deinit();
            // Closing the job is what kills the tree on Windows (F5/F6); on
            // POSIX terminateChild kills the wrapper's process group.
            if (running.job) |*job| job.close();
            if (running.child) |*child| terminateChild(child, running.job != null);
            if (running.driver_log) |driver_log| driver_log.deinit();
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

/// Kernel-assigned free loopback port. The probe socket is closed before
/// geckodriver binds, so a lost race is possible; the ownership checks and the
/// retry loop turn that into a retry instead of a claimed foreign driver.
fn reserveLoopbackPort() !u16 {
    var listener = try (try compat.net.Address.parseIp4("127.0.0.1", 0)).listen(.{});
    defer listener.deinit();
    return listener.listen_address.in.getPort();
}

/// Accept readiness only when the child's own stderr printed the listening
/// banner for `port` (the pipe is ours, so another local process cannot forge
/// it) and the child is alive at that moment and again after `/status` is
/// ready. `/status` alone is never proof of ownership.
fn awaitDriverOwnership(
    client: *WebDriverClient,
    driver_log: *DriverLog,
    child: *compat.process.Child,
    port: u16,
    timeout_ms: u64,
) !void {
    const deadline = nowMs() + @as(i64, @intCast(timeout_ms));
    while (true) {
        if (driver_log.listeningPort() == port) break;
        if ((try child.tryWait()) != null) return error.DriverExitedBeforeReady;
        if (nowMs() >= deadline) return error.DriverStartTimeout;
        compat.thread.sleep(readiness_poll_ms * std.time.ns_per_ms);
    }
    while (true) {
        if (client.statusReady()) {
            if ((try child.tryWait()) != null) return error.DriverExitedBeforeReady;
            return;
        }
        if ((try child.tryWait()) != null) return error.DriverExitedBeforeReady;
        if (nowMs() >= deadline) return error.DriverStartTimeout;
        compat.thread.sleep(readiness_poll_ms * std.time.ns_per_ms);
    }
}

/// Parse the last geckodriver "Listening on 127.0.0.1:<port>" line.
fn findListeningPort(text: []const u8) ?u16 {
    const marker = "Listening on 127.0.0.1:";
    var search_end = text.len;
    while (std.mem.lastIndexOf(u8, text[0..search_end], marker)) |index| {
        const rest = text[index + marker.len ..];
        var digits: usize = 0;
        while (digits < rest.len and digits < 5 and std.ascii.isDigit(rest[digits])) digits += 1;
        if (digits > 0) return std.fmt.parseInt(u16, rest[0..digits], 10) catch null;
        search_end = index;
    }
    return null;
}

/// `moz:profile` must name our one-shot profile. Both sides are resolved
/// (symlinks, trailing separators); Windows paths compare case-insensitively.
fn profilesMatch(allocator: Allocator, reported: ?[]const u8, expected: []const u8) bool {
    const reported_path = reported orelse return false;
    const reported_real = canonicalPath(allocator, reported_path);
    defer if (reported_real) |path| allocator.free(path);
    const expected_real = canonicalPath(allocator, expected);
    defer if (expected_real) |path| allocator.free(path);
    const left = trimTrailingSeparators(reported_real orelse reported_path);
    const right = trimTrailingSeparators(expected_real orelse expected);
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
}

fn canonicalPath(allocator: Allocator, path: []const u8) ?[]u8 {
    return compat.fs.Dir.cwd().realpathAlloc(allocator, path) catch null;
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    return path[0..end];
}

/// The parent-death pipe write end must be close-on-exec: the agent spawns
/// unrelated children (curl, shells) and an inherited copy would keep the
/// watchdog from ever seeing EOF when the agent dies.
fn ensureCloseOnExec(handle: std.posix.fd_t) !void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    const rc = std.posix.system.fcntl(handle, std.posix.F.GETFD, @as(usize, 0));
    const flags: usize = switch (std.posix.errno(rc)) {
        .SUCCESS => @as(usize, @intCast(rc)),
        .INTR => return ensureCloseOnExec(handle),
        else => |err| return std.posix.unexpectedErrno(err),
    };
    if (flags & std.posix.FD_CLOEXEC != 0) return;
    while (true) {
        switch (std.posix.errno(std.posix.system.fcntl(handle, std.posix.F.SETFD, flags | std.posix.FD_CLOEXEC))) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

/// Kill the whole child tree, then reap so no zombie remains. On POSIX the
/// child leads its own process group, so TERM/KILL reach geckodriver and
/// Firefox too; a WNOHANG poll replaces the old fixed sleep. On Windows the
/// job handle (closed by the caller) has already killed the tree; without a
/// job, `taskkill /T /F` is the fallback.
fn terminateChild(child: *compat.process.Child, tree_already_killed: bool) void {
    if (child.term != null) return;
    if (comptime builtin.os.tag == .windows) {
        if (!tree_already_killed) process_util.terminateWindowsProcessTree(child.id);
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    } else if (comptime builtin.os.tag == .wasi) {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    } else {
        std.posix.kill(-child.id, std.posix.SIG.TERM) catch {
            std.posix.kill(child.id, std.posix.SIG.TERM) catch {};
        };
        const deadline = nowMs() + @as(i64, @intCast(shutdown_grace_ms));
        while (true) {
            if ((child.tryWait() catch null) != null) return;
            if (nowMs() >= deadline) break;
            compat.thread.sleep(shutdown_poll_ms * std.time.ns_per_ms);
        }
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

    terminateChild(&child, false);
    // wait() succeeded inside terminateChild, so the process was reaped.
    try std.testing.expect(child.term != null);
}

test "posix driver wrapper kills the whole group when the agent pipe closes" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const pid_path = try compat.fs.path.join(allocator, &.{ tmp_path, "driver.pid" });
    defer allocator.free(pid_path);

    // Fake driver in the wrapper's process group; it records its pid (kept
    // across `exec`) so the test can check the survivor independently.
    const driver_script = try std.fmt.allocPrint(allocator,
        \\echo $$ > '{s}'
        \\exec sleep 300
        \\
    , .{pid_path});
    defer allocator.free(driver_script);

    var child = compat.process.Child.init(&.{
        "/bin/sh", "-c", driver_wrapper, "sh", "/bin/sh", "-c", driver_script,
    }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;
    try child.spawn();
    var agent_pipe: ?compat.fs.File = child.stdin;
    child.stdin = null;
    defer {
        if (agent_pipe) |file| file.close();
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    const pid_text = try waitForFile(allocator, pid_path);
    defer allocator.free(pid_text);
    const driver_pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, " \t\r\n"), 10);
    try std.testing.expect(driver_pid != child.id);
    // Regression: the watchdog's background `cat` used to get /dev/null, so it
    // killed the group at startup while the agent was still alive. The pid file
    // is the sync point: once it exists the driver must still be running.
    try std.testing.expect(processRunning(driver_pid));

    // Regression: an agent killed with SIGKILL/OOM used to leave geckodriver
    // and Firefox running. Closing the write end is what the kernel does when
    // the agent dies; the wrapper's watchdog must kill the group.
    agent_pipe.?.close();
    agent_pipe = null;

    _ = try child.wait();
    try std.testing.expect(child.term != null);
    // No wall-clock assertion: wait until the driver pid stops running.
    try expectProcessGone(driver_pid);
}

test "posix driver watchdog pipe is close-on-exec" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var child = compat.process.Child.init(&.{ "sleep", "300" }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;
    try child.spawn();
    defer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    const fd = child.stdin.?.handle;
    // Regression: an inherited write end would keep the watchdog from seeing
    // EOF when the agent dies, so every stop left geckodriver running.
    try ensureCloseOnExec(fd);
    const rc = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(usize, 0));
    const flags: usize = switch (std.posix.errno(rc)) {
        .SUCCESS => @as(usize, @intCast(rc)),
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(flags & std.posix.FD_CLOEXEC != 0);
}

test "spawned driver that dies without the listening banner is not claimed" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const fake = @import("webdriver_fake_server.zig");
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    var profile = try webdriver_security.Profile.createIn(allocator, tmp_path, null);
    defer profile.deinit();

    const driver_path = try writeExecutableScript(
        compat.fs.Dir.wrap(tmp_dir.dir),
        "fake-geckodriver.sh",
        "#!/bin/sh\nexit 0\n",
        allocator,
    );
    defer allocator.free(driver_path);

    // A foreign service already answers /status ready on the port; the child
    // never printed the banner, so the service must not be claimed.
    const routes = [_]fake.Route{
        .{ .method = "GET", .path = "/status", .body = "{\"value\":{\"ready\":true}}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();

    var manager = WebDriverManager.init(allocator, .{
        .geckodriver_path = driver_path,
        .driver_port_override = @intCast(server.listener.listen_address.in.getPort()),
    });
    defer manager.deinit();

    try std.testing.expectError(error.DriverStartFailed, manager.startSpawnedDriverLocked(profile.path));
    try std.testing.expect(std.mem.indexOf(u8, manager.lastErrorMessage(), "DriverExitedBeforeReady") != null);
    server.stopAndJoin();
    // /status was never trusted, so the foreign service saw no request at all.
    try std.testing.expectEqual(@as(usize, 0), server.request_count);
}

test "spawned driver is accepted after a foreign listener is rejected and retried" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const fake = @import("webdriver_fake_server.zig");
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    var profile = try webdriver_security.Profile.createIn(allocator, tmp_path, null);
    defer profile.deinit();

    const attempts_path = try compat.fs.path.join(allocator, &.{ tmp_path, "attempts" });
    defer allocator.free(attempts_path);
    const driver_script = try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\port=
        \\while [ $# -gt 0 ]; do
        \\  case "$1" in
        \\    --port) port=$2; shift 2 ;;
        \\    *) shift ;;
        \\  esac
        \\done
        \\n=$(cat '{s}' 2>/dev/null || echo 0)
        \\n=$((n + 1))
        \\echo "$n" > '{s}'
        \\if [ "$n" -lt 2 ]; then exit 0; fi
        \\echo "Listening on 127.0.0.1:$port" >&2
        \\exec sleep 300
        \\
    , .{ attempts_path, attempts_path });
    defer allocator.free(driver_script);
    const driver_path =
        try writeExecutableScript(compat.fs.Dir.wrap(tmp_dir.dir), "fake-geckodriver.sh", driver_script, allocator);
    defer allocator.free(driver_path);

    const session_body = try std.fmt.allocPrint(allocator, "{{\"value\":{{\"sessionId\":\"owned-session\",\"capabilities\":{{\"moz:profile\":\"{s}\"}}}}}}", .{profile.path});
    defer allocator.free(session_body);
    const routes = [_]fake.Route{
        .{ .method = "GET", .path = "/status", .body = "{\"value\":{\"ready\":true}}" },
        .{ .method = "POST", .path = "/session", .body = session_body },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();

    var manager = WebDriverManager.init(allocator, .{
        .geckodriver_path = driver_path,
        .driver_port_override = @intCast(server.listener.listen_address.in.getPort()),
    });
    defer manager.deinit();

    // Attempt 1 exits without the banner (foreign service on the port);
    // attempt 2 prints it, so its session is ours.
    var driver = try manager.startSpawnedDriverLocked(profile.path);
    defer driver.deinit();
    try std.testing.expect(driver.client.hasSession());

    server.stopAndJoin();
    try std.testing.expectEqual(@as(usize, 2), server.request_count);
    try std.testing.expectEqualStrings("/status", server.requests[0].path);
    try std.testing.expectEqualStrings("/session", server.requests[1].path);
    const attempts = try readFileAbsolute(allocator, attempts_path);
    defer allocator.free(attempts);
    try std.testing.expectEqualStrings("2\n", attempts);
}

test "spawned driver is rejected when the session reports another profile" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const fake = @import("webdriver_fake_server.zig");
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    var profile = try webdriver_security.Profile.createIn(allocator, tmp_path, null);
    defer profile.deinit();

    const driver_script =
        \\#!/bin/sh
        \\port=
        \\while [ $# -gt 0 ]; do
        \\  case "$1" in
        \\    --port) port=$2; shift 2 ;;
        \\    *) shift ;;
        \\  esac
        \\done
        \\echo "Listening on 127.0.0.1:$port" >&2
        \\exec sleep 300
        \\
    ;
    const driver_path =
        try writeExecutableScript(compat.fs.Dir.wrap(tmp_dir.dir), "fake-geckodriver.sh", driver_script, allocator);
    defer allocator.free(driver_path);

    var routes: [driver_attempts * 3]fake.Route = undefined;
    for (0..driver_attempts) |attempt| {
        const base = attempt * 3;
        routes[base] = .{ .method = "GET", .path = "/status", .body = "{\"value\":{\"ready\":true}}" };
        routes[base + 1] = .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"foreign-session\",\"capabilities\":{\"moz:profile\":\"/elsewhere/profile\"}}}" };
        routes[base + 2] = .{ .method = "DELETE", .path = "/session/foreign-session", .body = "{\"value\":null}" };
    }
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();

    var manager = WebDriverManager.init(allocator, .{
        .geckodriver_path = driver_path,
        .driver_port_override = @intCast(server.listener.listen_address.in.getPort()),
    });
    defer manager.deinit();

    try std.testing.expectError(error.DriverStartFailed, manager.startSpawnedDriverLocked(profile.path));
    try std.testing.expect(std.mem.indexOf(u8, manager.lastErrorMessage(), "DriverProfileMismatch") != null);

    server.stopAndJoin();
    try std.testing.expectEqual(@as(usize, driver_attempts * 3), server.request_count);
    const requests = server.requests[0..server.request_count];
    try std.testing.expectEqual(@as(usize, driver_attempts), countRequests(requests, "/status"));
    try std.testing.expectEqual(@as(usize, driver_attempts), countRequests(requests, "/session"));
}

test "findListeningPort reads the last complete banner" {
    try std.testing.expectEqual(@as(?u16, 4444), findListeningPort("Listening on 127.0.0.1:4444\n"));
    try std.testing.expectEqual(
        @as(?u16, 5555),
        findListeningPort("old Listening on 127.0.0.1:4444\nListening on 127.0.0.1:5555\n"),
    );
    try std.testing.expect(findListeningPort("Listening on 127.0.0.1:") == null);
    try std.testing.expect(findListeningPort("Listening on 127.0.0.1:12ab") == null or
        findListeningPort("Listening on 127.0.0.1:12ab") == 12);
}

test "profilesMatch resolves paths and rejects a foreign profile" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const with_separator = try std.fmt.allocPrint(allocator, "{s}/", .{tmp_path});
    defer allocator.free(with_separator);
    try std.testing.expect(profilesMatch(allocator, with_separator, tmp_path));
    try std.testing.expect(!profilesMatch(allocator, null, tmp_path));
    try std.testing.expect(!profilesMatch(allocator, "/somewhere/else", tmp_path));
}

test "windows job object kills the driver tree when its handle closes" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const dir = compat.fs.Dir.wrap(tmp_dir.dir);
    try dir.writeFile(.{
        .sub_path = "child.ps1",
        .data =
        \\param([string]$PidPath)
        \\$PID | Set-Content -NoNewline -LiteralPath $PidPath
        \\Start-Sleep -Seconds 600
        \\
        ,
    });
    try dir.writeFile(.{
        .sub_path = "wrapper.cmd",
        // cmd.exe stays in front so PowerShell is a grandchild of the job.
        .data =
        \\@echo off
        \\start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0child.ps1" "%~dp0child.pid"
        \\ping -t 127.0.0.1 >NUL
        \\
        ,
    });
    const wrapper = try compat.fs.path.join(allocator, &.{ tmp_path, "wrapper.cmd" });
    defer allocator.free(wrapper);
    const pid_path = try compat.fs.path.join(allocator, &.{ tmp_path, "child.pid" });
    defer allocator.free(pid_path);

    var job = try process_util.WindowsJob.create();
    var job_open = true;
    defer if (job_open) job.close();

    var child = compat.process.Child.init(&.{ "cmd.exe", "/c", wrapper }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    child.start_suspended = true;
    try child.spawn();
    defer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }
    try job.assignProcess(child.id);
    const direct_pid = process_util.processIdOf(child.id);
    try process_util.resumeSuspendedThread(child.thread_handle);

    // The grandchild writes its own pid once it runs; that is the sync event.
    const pid_text = try waitForFile(allocator, pid_path);
    defer allocator.free(pid_text);
    const grandchild_pid = try std.fmt.parseInt(std.os.windows.DWORD, std.mem.trim(u8, pid_text, " \t\r\n"), 10);
    try std.testing.expect(process_util.processExistsWindows(grandchild_pid));

    // Closing the last job handle is exactly what happens when the agent dies.
    job.close();
    job_open = false;

    const deadline = nowMs() + @as(i64, @intCast(startup_timeout_ms));
    while (nowMs() < deadline) {
        if (!process_util.processExistsWindows(grandchild_pid) and
            !process_util.processExistsWindows(direct_pid)) return;
        compat.thread.sleep(shutdown_poll_ms * std.time.ns_per_ms);
    }
    return error.TestUnexpectedResult;
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
    // The manager only owns the proxy once `running` is set below; free it on
    // any early assertion failure instead of leaking it (macOS CI did).
    var proxy_owned = true;
    defer {
        if (proxy_owned) proxy.deinit();
    }
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
    proxy_owned = false;
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

fn readFileAbsolute(allocator: Allocator, path: []const u8) ![]u8 {
    const file = try compat.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024);
}

/// Block until the file exists with content; the deadline only bounds a hang.
fn waitForFile(allocator: Allocator, path: []const u8) ![]u8 {
    const deadline = nowMs() + @as(i64, @intCast(startup_timeout_ms));
    while (nowMs() < deadline) {
        if (readFileAbsolute(allocator, path)) |content| {
            if (content.len > 0) return content;
            allocator.free(content);
        } else |_| {}
        compat.thread.sleep(shutdown_poll_ms * std.time.ns_per_ms);
    }
    return error.TestUnexpectedResult;
}

fn writeExecutableScript(dir: compat.fs.Dir, name: []const u8, content: []const u8, allocator: Allocator) ![]u8 {
    try dir.writeFile(.{ .sub_path = name, .data = content });
    const path = try dir.realpathAlloc(allocator, name);
    errdefer allocator.free(path);
    const file = try compat.fs.openFileAbsolute(path, .{});
    defer file.close();
    try file.chmod(0o755);
    return path;
}

/// No wall-clock assertion: poll until the pid stops running. A Linux zombie
/// counts as gone even if PID 1 has not reaped it yet.
fn expectProcessGone(pid: std.posix.pid_t) !void {
    const deadline = nowMs() + @as(i64, @intCast(shutdown_grace_ms));
    while (nowMs() < deadline) {
        if (!processRunning(pid)) return;
        compat.thread.sleep(shutdown_poll_ms * std.time.ns_per_ms);
    }
    return error.TestUnexpectedResult;
}

fn processRunning(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @as(std.posix.SIG, @enumFromInt(0))) catch return false;
    if (builtin.os.tag == .linux) {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return true;
        const file = compat.fs.openFileAbsolute(path, .{}) catch return true;
        defer file.close();
        var buf: [512]u8 = undefined;
        const n = file.read(&buf) catch return true;
        const text = buf[0..n];
        const close_paren = std.mem.lastIndexOfScalar(u8, text, ')') orelse return true;
        if (close_paren + 2 >= text.len) return true;
        return text[close_paren + 2] != 'Z' and text[close_paren + 2] != 'X';
    }
    return true;
}
