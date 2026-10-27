//! In-process filtering CONNECT proxy for the WebDriver browser backend.
//!
//! Firefox is pointed at this proxy by its one-shot profile. Only
//! `CONNECT host:port` (HTTPS) is accepted; plain HTTP gets 403 so redirects,
//! sub-resources, new windows and form posts cannot leave through an
//! unvalidated path. The proxy resolves the host itself, validates every
//! binary address with `net_security`, and connects to that pinned address,
//! which closes DNS rebinding / TOCTOU between the check and the connection.
//!
//! Threads: a fixed worker pool plus one copier per active tunnel. Every
//! thread is joined by `stopAndJoin`; on platforms where socket non-blocking
//! mode is a no-op the accept loops are woken with self-connections.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const net_security = @import("../net_security.zig");

const Allocator = std.mem.Allocator;

pub const max_head_bytes = 8 * 1024;
pub const max_headers = 64;
const worker_stack_size = 256 * 1024;
const copier_stack_size = 128 * 1024;

pub const Config = struct {
    allowed_domains: []const []const u8 = &.{},
    worker_count: usize = 32,
    handshake_timeout_ms: u32 = 10_000,
    connect_timeout_ms: u32 = 10_000,
    idle_timeout_ms: u32 = 120_000,
    /// Test seam; production leaves this null and uses the system resolver.
    resolver: ?net_security.AddressResolver = null,
};

const Tunnel = struct {
    client: compat.net.Stream,
    target: ?compat.net.Stream = null,
};

pub const Proxy = struct {
    allocator: Allocator,
    config: Config,
    config_arena: std.heap.ArenaAllocator,
    allowed_domains: []const []const u8 = &.{},
    listener: compat.net.Server = undefined,
    listener_active: bool = false,
    workers: []std.Thread = &.{},
    spawned: usize = 0,
    slots: []?*Tunnel = &.{},
    slots_mutex: compat.sync.Mutex = .{},
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Bind 127.0.0.1:<kernel-assigned port> and start the worker pool.
    /// `allocator` must be thread-safe (the process smp_allocator is): workers
    /// allocate per-request resolution state concurrently.
    pub fn start(allocator: Allocator, config: Config) !*Proxy {
        if (config.worker_count == 0 or config.worker_count > 128) return error.InvalidWorkerCount;
        if (config.handshake_timeout_ms == 0 or config.connect_timeout_ms == 0 or
            config.idle_timeout_ms == 0) return error.InvalidTimeout;

        const self = try allocator.create(Proxy);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .config_arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.freeAll();

        const arena_allocator = self.config_arena.allocator();
        const allowed = try arena_allocator.alloc([]const u8, config.allowed_domains.len);
        for (config.allowed_domains, 0..) |domain, i| {
            allowed[i] = try arena_allocator.dupe(u8, domain);
        }
        self.allowed_domains = allowed;
        self.config.allowed_domains = allowed;

        const address = try compat.net.Address.parseIp4("127.0.0.1", 0);
        self.listener = try address.listen(.{ .reuse_address = true });
        self.listener_active = true;

        self.workers = try allocator.alloc(std.Thread, config.worker_count);
        self.slots = try allocator.alloc(?*Tunnel, config.worker_count);
        @memset(self.slots, null);

        errdefer self.stopAndJoin();
        while (self.spawned < config.worker_count) {
            const index = self.spawned;
            self.workers[index] = try std.Thread.spawn(
                .{ .stack_size = worker_stack_size },
                workerMain,
                .{ self, index },
            );
            self.spawned += 1;
        }
        return self;
    }

    pub fn port(self: *const Proxy) u16 {
        return self.listener.listen_address.in.getPort();
    }

    /// Wake every accept loop, unblock active tunnels, then join all threads.
    /// Idempotent; the listening socket stays open until every worker is gone.
    pub fn stopAndJoin(self: *Proxy) void {
        if (self.stopping.swap(true, .acq_rel)) return;

        if (self.listener_active) {
            var wakes: usize = 0;
            while (wakes < self.spawned) : (wakes += 1) {
                var wake = compat.net.tcpConnectToAddress(self.listener.listen_address) catch continue;
                wake.close();
            }
        }

        self.slots_mutex.lock();
        for (self.slots) |slot| {
            if (slot) |tunnel| shutdownTunnel(tunnel);
        }
        self.slots_mutex.unlock();

        for (self.workers[0..self.spawned]) |thread| thread.join();
        self.spawned = 0;

        if (self.listener_active) {
            self.listener.deinit();
            self.listener_active = false;
        }
    }

    pub fn deinit(self: *Proxy) void {
        self.stopAndJoin();
        const allocator = self.allocator;
        self.freeAll();
        allocator.destroy(self);
    }

    fn freeAll(self: *Proxy) void {
        if (self.listener_active) {
            self.listener.deinit();
            self.listener_active = false;
        }
        if (self.workers.len > 0) self.allocator.free(self.workers);
        if (self.slots.len > 0) self.allocator.free(self.slots);
        self.workers = &.{};
        self.slots = &.{};
        self.config_arena.deinit();
    }

    fn workerMain(self: *Proxy, index: usize) void {
        while (true) {
            var conn = self.listener.accept() catch |err| {
                if (self.stopping.load(.acquire)) return;
                switch (err) {
                    error.WouldBlock => compat.thread.sleep(1 * std.time.ns_per_ms),
                    else => {},
                }
                continue;
            };
            if (self.stopping.load(.acquire)) {
                conn.stream.close();
                return;
            }
            if (!isLoopbackPeer(conn.address)) {
                conn.stream.close();
                continue;
            }

            var tunnel = Tunnel{ .client = conn.stream };
            self.slots_mutex.lock();
            if (self.stopping.load(.acquire)) {
                self.slots_mutex.unlock();
                conn.stream.close();
                return;
            }
            self.slots[index] = &tunnel;
            self.slots_mutex.unlock();

            self.handleConnection(&tunnel) catch {};

            // Unregister before closing so stopAndJoin never shuts down a
            // closed (and possibly reused) handle.
            self.slots_mutex.lock();
            self.slots[index] = null;
            self.slots_mutex.unlock();
            closeTunnel(&tunnel);
        }
    }

    fn handleConnection(self: *Proxy, tunnel: *Tunnel) !void {
        var head_buf: [max_head_bytes]u8 = undefined;
        const head = readHead(tunnel.client, &head_buf, self.config.handshake_timeout_ms) catch |err| {
            switch (err) {
                error.Timeout => sendResponse(tunnel.client, "408", "Request Timeout", "Handshake timed out\n"),
                error.HeadTooLarge => sendResponse(tunnel.client, "400", "Bad Request", "Request head too large\n"),
                else => {},
            }
            return;
        };

        const request = parseRequest(head) catch |err| {
            switch (err) {
                error.OnlyHttps => sendResponse(tunnel.client, "403", "Forbidden", "Only HTTPS is allowed (CONNECT)\n"),
                else => sendResponse(tunnel.client, "400", "Bad Request", "Malformed CONNECT request\n"),
            }
            return;
        };

        var resolved = net_security.resolveConnectAddressesWith(
            self.allocator,
            request.host,
            request.port,
            self.allowed_domains,
            self.config.resolver,
        ) catch |err| {
            switch (err) {
                error.HostNotAllowed, error.LocalAddressBlocked => sendResponse(
                    tunnel.client,
                    "403",
                    "Forbidden",
                    "Destination blocked by browser proxy policy\n",
                ),
                else => sendResponse(tunnel.client, "502", "Bad Gateway", "Destination resolution failed\n"),
            }
            return;
        };
        defer resolved.deinit();

        const target = self.connectResolved(&resolved) orelse {
            sendResponse(tunnel.client, "502", "Bad Gateway", "Destination connection failed\n");
            return;
        };
        errdefer target.close();

        self.slots_mutex.lock();
        tunnel.target = target;
        self.slots_mutex.unlock();
        errdefer {
            self.slots_mutex.lock();
            tunnel.target = null;
            self.slots_mutex.unlock();
        }

        sendEstablished(tunnel.client);

        const copier = std.Thread.spawn(
            .{ .stack_size = copier_stack_size },
            pump,
            .{ target, tunnel.client, self.config.idle_timeout_ms },
        ) catch {
            shutdownTunnel(tunnel);
            return;
        };
        pump(tunnel.client, target, self.config.idle_timeout_ms);
        copier.join();
    }

    fn connectResolved(self: *Proxy, resolved: *const net_security.ResolvedConnectAddresses) ?compat.net.Stream {
        const deadline = compat.time.milliTimestamp() + self.config.connect_timeout_ms;
        for (resolved.addrs) |address| {
            const remaining = deadline - compat.time.milliTimestamp();
            if (remaining <= 0) return null;
            const timeout: u32 = @intCast(@min(remaining, @as(i64, std.math.maxInt(u32))));
            const stream = compat.net.connectWithTimeout(address, timeout) catch continue;
            return stream;
        }
        return null;
    }
};

fn isLoopbackPeer(address: compat.net.Address) bool {
    if (address.any.family != std.posix.AF.INET) return false;
    const octets: *const [4]u8 = @ptrCast(&address.in.sa.addr);
    return octets[0] == 127 and octets[1] == 0 and octets[2] == 0 and octets[3] == 1;
}

fn shutdownTunnel(tunnel: *Tunnel) void {
    tunnel.client.shutdown(.both) catch {};
    if (tunnel.target) |target| target.shutdown(.both) catch {};
}

fn closeTunnel(tunnel: *Tunnel) void {
    tunnel.client.close();
    if (tunnel.target) |target| target.close();
    tunnel.target = null;
}

fn pump(src: compat.net.Stream, dst: compat.net.Stream, idle_timeout_ms: u32) void {
    // Reads are idle-timed out; writes stay blocking and are unblocked by
    // stopAndJoin's shutdown. A peer that stops reading is eventually cut by
    // the other direction's idle timeout.
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = compat.net.readWithTimeout(src, &buf, idle_timeout_ms) catch {
            dst.shutdown(.both) catch {};
            src.shutdown(.both) catch {};
            return;
        };
        if (n == 0) break;
        dst.writeAll(buf[0..n]) catch {
            dst.shutdown(.both) catch {};
            src.shutdown(.both) catch {};
            return;
        };
    }
    dst.shutdown(.send) catch {};
}

const Request = struct {
    host: []const u8,
    port: u16,
};

const ParseError = error{
    OnlyHttps,
    Malformed,
};

fn readHead(stream: compat.net.Stream, buf: []u8, timeout_ms: u32) ![]const u8 {
    const deadline = compat.time.milliTimestamp() + timeout_ms;
    var filled: usize = 0;
    while (true) {
        if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n")) |end| return buf[0 .. end + 4];
        if (filled == buf.len) return error.HeadTooLarge;

        const remaining = deadline - compat.time.milliTimestamp();
        if (remaining <= 0) return error.Timeout;
        const slice: u32 = @intCast(@min(remaining, @as(i64, std.math.maxInt(u32))));
        const n = compat.net.readWithTimeout(stream, buf[filled..], slice) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        filled += n;
    }
}

fn parseRequest(head: []const u8) ParseError!Request {
    const first_eol = std.mem.indexOf(u8, head, "\r\n") orelse return error.Malformed;
    const line = head[0..first_eol];

    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    const method = parts.next() orelse return error.Malformed;
    const authority = parts.next() orelse return error.Malformed;
    const version = parts.next() orelse return error.Malformed;
    if (parts.next() != null) return error.Malformed;
    if (!std.mem.eql(u8, method, "CONNECT")) return error.OnlyHttps;
    if (!std.mem.eql(u8, version, "HTTP/1.1")) return error.Malformed;

    var header_count: usize = 0;
    var rest = head[first_eol + 2 ..];
    while (rest.len > 0 and !std.mem.eql(u8, rest, "\r\n")) {
        const eol = std.mem.indexOf(u8, rest, "\r\n") orelse return error.Malformed;
        if (eol == 0) break;
        header_count += 1;
        if (header_count > max_headers) return error.Malformed;
        rest = rest[eol + 2 ..];
    }

    return parseAuthority(authority);
}

fn parseAuthority(authority: []const u8) ParseError!Request {
    if (authority.len == 0 or authority.len > 300) return error.Malformed;
    for (authority) |c| {
        if (c <= 0x20 or c == 0x7f) return error.Malformed;
        switch (c) {
            '@', '/', '?', '#', '\\', '%' => return error.Malformed,
            else => {},
        }
    }

    var host: []const u8 = undefined;
    var port_text: []const u8 = undefined;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.Malformed;
        if (close + 1 >= authority.len or authority[close + 1] != ':') return error.Malformed;
        host = authority[0 .. close + 1];
        port_text = authority[close + 2 ..];
    } else {
        const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return error.Malformed;
        host = authority[0..colon];
        port_text = authority[colon + 1 ..];
        if (std.mem.indexOfAny(u8, host, "[]") != null) return error.Malformed;
    }
    if (host.len == 0 or host.len > 255) return error.Malformed;
    if (port_text.len == 0 or port_text.len > 5) return error.Malformed;
    for (port_text) |c| {
        if (c < '0' or c > '9') return error.Malformed;
    }
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.Malformed;
    if (port == 0) return error.Malformed;
    return .{ .host = host, .port = port };
}

fn sendResponse(stream: compat.net.Stream, status: []const u8, reason: []const u8, body: []const u8) void {
    var buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {s} {s}\r\nContent-Length: {d}\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n",
        .{ status, reason, body.len },
    ) catch return;
    stream.writeAll(head) catch return;
    stream.writeAll(body) catch return;
}

fn sendEstablished(stream: compat.net.Stream) void {
    stream.writeAll("HTTP/1.1 200 Connection Established\r\n\r\n") catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const EchoServer = struct {
    allocator: Allocator,
    listener: compat.net.Server,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: compat.sync.Mutex = .{},
    active: ?compat.net.Stream = null,
    tag: []const u8 = "",

    fn start(allocator: Allocator, tag: []const u8) !*EchoServer {
        const self = try allocator.create(EchoServer);
        errdefer allocator.destroy(self);
        const address = try compat.net.Address.parseIp4("127.0.0.1", 0);
        self.* = .{ .allocator = allocator, .listener = try address.listen(.{ .reuse_address = true }), .tag = tag };
        errdefer self.listener.deinit();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn port(self: *EchoServer) u16 {
        return self.listener.listen_address.in.getPort();
    }

    fn run(self: *EchoServer) void {
        while (!self.stopping.load(.acquire)) {
            var conn = self.listener.accept() catch continue;
            if (self.stopping.load(.acquire)) {
                conn.stream.close();
                return;
            }
            self.mutex.lock();
            self.active = conn.stream;
            self.mutex.unlock();
            self.serve(conn.stream);
            self.mutex.lock();
            self.active = null;
            self.mutex.unlock();
            conn.stream.close();
        }
    }

    fn serve(self: *EchoServer, stream: compat.net.Stream) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = stream.read(&buf) catch return;
            if (n == 0) return;
            if (self.tag.len > 0) stream.writeAll(self.tag) catch return;
            stream.writeAll(buf[0..n]) catch return;
        }
    }

    fn stopAndJoin(self: *EchoServer) void {
        self.stopping.store(true, .release);
        self.mutex.lock();
        if (self.active) |stream| stream.shutdown(.both) catch {};
        self.mutex.unlock();
        var wake = compat.net.tcpConnectToAddress(self.listener.listen_address) catch null;
        if (wake) |*conn| conn.close();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.listener.deinit();
    }

    fn deinit(self: *EchoServer) void {
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

const FakeResolver = struct {
    mutex: compat.sync.Mutex = .{},
    calls: usize = 0,
    plans: []const []const compat.net.Address,

    fn resolve(
        context: ?*anyopaque,
        allocator: Allocator,
        host: []const u8,
        port: u16,
    ) compat.net.GetAddressListError!*compat.net.AddressList {
        _ = host;
        _ = port;
        const self: *FakeResolver = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = @min(self.calls, self.plans.len - 1);
        self.calls += 1;
        const addrs = self.plans[index];

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const list = try arena.allocator().create(compat.net.AddressList);
        list.* = .{ .arena = arena, .addrs = &.{}, .canon_name = null };
        // Grow through list.arena so deinit frees a separate buffer.
        list.addrs = try list.arena.allocator().dupe(compat.net.Address, addrs);
        return list;
    }

    fn hook(self: *FakeResolver) net_security.AddressResolver {
        return .{ .context = self, .resolve = resolve };
    }

    fn callCount(self: *FakeResolver) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.calls;
    }
};

fn connectToProxy(proxy: *Proxy) !compat.net.Stream {
    const address = try compat.net.Address.parseIp4("127.0.0.1", proxy.port());
    const stream = try compat.net.tcpConnectToAddress(address);
    errdefer stream.close();
    return stream;
}

fn sendConnect(stream: compat.net.Stream, authority: []const u8) !void {
    var buf: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(&buf, "CONNECT {s} HTTP/1.1\r\nHost: {s}\r\n\r\n", .{ authority, authority });
    try stream.writeAll(request);
}

fn readStatus(stream: compat.net.Stream) !u16 {
    var buf: [2048]u8 = undefined;
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = compat.net.readWithTimeout(stream, buf[filled..], 5000) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        filled += n;
        if (std.mem.indexOf(u8, buf[0..filled], "\r\n")) |eol| {
            if (eol < 12) return error.BadResponse;
            return std.fmt.parseInt(u16, buf[9..12], 10) catch error.BadResponse;
        }
    }
    return error.BadResponse;
}

/// Test helper shared with the lifecycle tests: send one CONNECT request and
/// return the proxy's status line plus the open stream (caller closes it).
pub const Response = struct {
    stream: compat.net.Stream,
    status: u16,
};

pub fn requestStatus(proxy: *Proxy, authority: []const u8) !Response {
    const stream = try connectToProxy(proxy);
    errdefer stream.close();
    try sendConnect(stream, authority);
    const status = try readStatus(stream);
    return .{ .stream = stream, .status = status };
}

fn readAtLeast(stream: compat.net.Stream, buf: []u8) !usize {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = compat.net.readWithTimeout(stream, buf[filled..], 5000) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return err,
        };
        if (n == 0) break;
        filled += n;
    }
    return filled;
}

test "proxy rejects private, loopback and numeric-alias CONNECT targets" {
    var proxy = try Proxy.start(testing.allocator, .{ .worker_count = 2 });
    defer proxy.deinit();

    const targets = [_][]const u8{
        "127.0.0.1:443",
        "10.1.2.3:443",
        "172.16.0.1:443",
        "192.168.1.1:443",
        "169.254.169.254:80",
        "[::1]:443",
        "[::ffff:127.0.0.1]:443",
        "[64:ff9b::7f00:1]:443",
        "0177.0.0.1:443",
        "2130706433:443",
        "0x7f.0.0.1:443",
        "192.88.99.1:443",
    };
    for (targets) |target| {
        const response = try requestStatus(proxy, target);
        defer response.stream.close();
        try testing.expectEqual(@as(u16, 403), response.status);
    }
}

test "proxy rejects plaintext HTTP requests" {
    var proxy = try Proxy.start(testing.allocator, .{ .worker_count = 1 });
    defer proxy.deinit();

    const stream = try connectToProxy(proxy);
    defer stream.close();
    try stream.writeAll("GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n");
    try testing.expectEqual(@as(u16, 403), try readStatus(stream));
}

test "proxy rejects malformed CONNECT requests" {
    var proxy = try Proxy.start(testing.allocator, .{ .worker_count = 1 });
    defer proxy.deinit();

    const requests = [_][]const u8{
        "CONNECT example.com HTTP/1.1\r\n\r\n",
        "CONNECT user@example.com:443 HTTP/1.1\r\n\r\n",
        "CONNECT example.com:0 HTTP/1.1\r\n\r\n",
        "CONNECT example.com:99999 HTTP/1.1\r\n\r\n",
        "CONNECT [::1] HTTP/1.1\r\n\r\n",
        "CONNECT example.com:443 HTTP/1.0\r\n\r\n",
        "CONNECT example.com:443 extra HTTP/1.1\r\n\r\n",
    };
    for (requests) |request| {
        const stream = try connectToProxy(proxy);
        defer stream.close();
        try stream.writeAll(request);
        try testing.expectEqual(@as(u16, 400), try readStatus(stream));
    }
}

test "proxy rejects an oversized request head" {
    var proxy = try Proxy.start(testing.allocator, .{ .worker_count = 1 });
    defer proxy.deinit();

    const stream = try connectToProxy(proxy);
    defer stream.close();
    try stream.writeAll("CONNECT example.com:443 HTTP/1.1\r\nX: ");
    var chunk: [1024]u8 = undefined;
    @memset(&chunk, 'a');
    var written: usize = 0;
    while (written <= max_head_bytes) : (written += chunk.len) {
        stream.writeAll(&chunk) catch break;
    }
    try testing.expectEqual(@as(u16, 400), try readStatus(stream));
}

test "proxy allowlist denies an unlisted host without resolving it" {
    var fake = FakeResolver{ .plans = &.{} };
    var proxy = try Proxy.start(testing.allocator, .{
        .worker_count = 1,
        .allowed_domains = &.{"allowed.test"},
        .resolver = fake.hook(),
    });
    defer proxy.deinit();

    const response = try requestStatus(proxy, "blocked.test:443");
    defer response.stream.close();
    try testing.expectEqual(@as(u16, 403), response.status);
    try testing.expectEqual(@as(usize, 0), fake.callCount());
}

test "proxy rejects a host that resolves to loopback" {
    const local = try compat.net.Address.parseIp4("127.0.0.1", 9);
    var plan = [_]compat.net.Address{local};
    var plans = [_][]const compat.net.Address{plan[0..]};
    var fake = FakeResolver{ .plans = plans[0..] };

    var proxy = try Proxy.start(testing.allocator, .{ .worker_count = 1, .resolver = fake.hook() });
    defer proxy.deinit();

    const response = try requestStatus(proxy, "rebind.test:443");
    defer response.stream.close();
    try testing.expectEqual(@as(u16, 403), response.status);
    try testing.expectEqual(@as(usize, 1), fake.callCount());
}

test "proxy rejects mixed public/private DNS answers" {
    const public = try compat.net.Address.parseIp4("93.184.216.34", 443);
    const private = try compat.net.Address.parseIp4("127.0.0.1", 443);
    var plan = [_]compat.net.Address{ public, private };
    var plans = [_][]const compat.net.Address{plan[0..]};
    var fake = FakeResolver{ .plans = plans[0..] };

    var proxy = try Proxy.start(testing.allocator, .{ .worker_count = 1, .resolver = fake.hook() });
    defer proxy.deinit();

    const response = try requestStatus(proxy, "mixed.test:443");
    defer response.stream.close();
    try testing.expectEqual(@as(u16, 403), response.status);
    try testing.expectEqual(@as(usize, 1), fake.callCount());
}

test "proxy tunnels an allowlisted host to the pinned upstream" {
    var echo = try EchoServer.start(testing.allocator, "A:");
    defer {
        echo.stopAndJoin();
        echo.deinit();
    }
    const upstream = try compat.net.Address.parseIp4("127.0.0.1", echo.port());
    var plan = [_]compat.net.Address{upstream};
    var plans = [_][]const compat.net.Address{plan[0..]};
    var fake = FakeResolver{ .plans = plans[0..] };

    var proxy = try Proxy.start(testing.allocator, .{
        .worker_count = 2,
        .allowed_domains = &.{"upstream.test"},
        .resolver = fake.hook(),
    });
    defer proxy.deinit();

    const response = try requestStatus(proxy, "upstream.test:443");
    defer response.stream.close();
    try testing.expectEqual(@as(u16, 200), response.status);

    try response.stream.writeAll("ping");
    var buf: [16]u8 = undefined;
    const n = try readAtLeast(response.stream, buf[0..6]);
    try testing.expectEqual(@as(usize, 6), n);
    try testing.expectEqualStrings("A:ping", buf[0..n]);
}

test "proxy pins the first resolution and never rebinds" {
    var echo_a = try EchoServer.start(testing.allocator, "A:");
    defer {
        echo_a.stopAndJoin();
        echo_a.deinit();
    }
    var echo_b = try EchoServer.start(testing.allocator, "B:");
    defer {
        echo_b.stopAndJoin();
        echo_b.deinit();
    }

    const addr_a = try compat.net.Address.parseIp4("127.0.0.1", echo_a.port());
    const addr_b = try compat.net.Address.parseIp4("127.0.0.1", echo_b.port());
    var plan_a = [_]compat.net.Address{addr_a};
    var plan_b = [_]compat.net.Address{addr_b};
    var plans = [_][]const compat.net.Address{ plan_a[0..], plan_b[0..] };
    var fake = FakeResolver{ .plans = plans[0..] };

    var proxy = try Proxy.start(testing.allocator, .{
        .worker_count = 2,
        .allowed_domains = &.{"pinned.test"},
        .resolver = fake.hook(),
    });
    defer proxy.deinit();

    const response = try requestStatus(proxy, "pinned.test:443");
    defer response.stream.close();
    try testing.expectEqual(@as(u16, 200), response.status);

    try response.stream.writeAll("ping");
    var buf: [16]u8 = undefined;
    const n = try readAtLeast(response.stream, buf[0..6]);
    try testing.expectEqualStrings("A:ping", buf[0..n]);
    try testing.expectEqual(@as(usize, 1), fake.callCount());
}

test "proxy answers 408 when the handshake stalls" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var proxy = try Proxy.start(testing.allocator, .{
        .worker_count = 1,
        .handshake_timeout_ms = 100,
    });
    defer proxy.deinit();

    const stream = try connectToProxy(proxy);
    defer stream.close();
    try stream.writeAll("CONNECT example.com:443 HTTP/1.1\r\nHost: ");
    try testing.expectEqual(@as(u16, 408), try readStatus(stream));
}

test "proxy closes an idle tunnel" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var echo = try EchoServer.start(testing.allocator, "");
    defer {
        echo.stopAndJoin();
        echo.deinit();
    }
    const upstream = try compat.net.Address.parseIp4("127.0.0.1", echo.port());
    var plan = [_]compat.net.Address{upstream};
    var plans = [_][]const compat.net.Address{plan[0..]};
    var fake = FakeResolver{ .plans = plans[0..] };

    var proxy = try Proxy.start(testing.allocator, .{
        .worker_count = 1,
        .allowed_domains = &.{"upstream.test"},
        .idle_timeout_ms = 100,
        .resolver = fake.hook(),
    });
    defer proxy.deinit();

    const response = try requestStatus(proxy, "upstream.test:443");
    defer response.stream.close();
    try testing.expectEqual(@as(u16, 200), response.status);

    var buf: [1]u8 = undefined;
    const n = compat.net.readWithTimeout(response.stream, &buf, 5000) catch |err| switch (err) {
        error.ConnectionResetByPeer => 0,
        else => return err,
    };
    try testing.expectEqual(@as(usize, 0), n);
}

test "proxy stopAndJoin closes active tunnels and joins every worker" {
    var echo = try EchoServer.start(testing.allocator, "");
    defer {
        echo.stopAndJoin();
        echo.deinit();
    }
    const upstream = try compat.net.Address.parseIp4("127.0.0.1", echo.port());
    var plan = [_]compat.net.Address{upstream};
    var plans = [_][]const compat.net.Address{plan[0..]};
    var fake = FakeResolver{ .plans = plans[0..] };

    var proxy = try Proxy.start(testing.allocator, .{
        .worker_count = 4,
        .allowed_domains = &.{"upstream.test"},
        .idle_timeout_ms = 60_000,
        .resolver = fake.hook(),
    });
    defer proxy.deinit();

    const response = try requestStatus(proxy, "upstream.test:443");
    defer response.stream.close();
    try testing.expectEqual(@as(u16, 200), response.status);

    // An open tunnel must not keep stopAndJoin from returning.
    proxy.stopAndJoin();
}

test "proxy stopAndJoin with idle workers is deterministic" {
    var proxy = try Proxy.start(testing.allocator, .{ .worker_count = 3 });
    defer proxy.deinit();
    proxy.stopAndJoin();
}
