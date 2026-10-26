//! Scripted loopback HTTP server for WebDriver client tests.
//!
//! Every request must map to one entry in `routes`; the thread serves exactly
//! that many connections and then exits. `stopAndJoin` unblocks a pending
//! `accept` with a throwaway connection, so no test leaves the server thread
//! stuck in `accept` on platforms where socket non-blocking mode is a no-op.
const std = @import("std");
const compat = @import("compat");

const Allocator = std.mem.Allocator;

pub const Route = struct {
    method: []const u8,
    path: []const u8,
    status: u16 = 200,
    body: []const u8 = "{\"value\":null}",
};

pub const Request = struct {
    method: []u8 = &.{},
    path: []u8 = &.{},
    body: []u8 = &.{},
};

pub const Server = struct {
    allocator: Allocator,
    listener: compat.net.Server,
    thread: ?std.Thread,
    routes: []const Route,
    requests: []Request,
    request_count: usize = 0,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn start(allocator: Allocator, routes: []const Route) !*Server {
        const address = try compat.net.Address.resolveIp("127.0.0.1", 0);
        var listener = try address.listen(.{ .reuse_address = true });
        errdefer listener.deinit();

        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .listener = listener,
            .thread = null,
            .routes = routes,
            .requests = try allocator.alloc(Request, routes.len),
        };
        errdefer allocator.free(self.requests);
        for (self.requests) |*request| request.* = .{};
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn url(self: *const Server, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.listener.listen_address.in.getPort()});
    }

    /// Join the server thread, waking a blocked accept if requests remain.
    pub fn stopAndJoin(self: *Server) void {
        if (self.thread) |thread| {
            self.stopping.store(true, .release);
            if (self.request_count < self.routes.len) {
                var wake = compat.net.tcpConnectToAddress(self.listener.listen_address) catch null;
                if (wake) |*conn| conn.close();
            }
            thread.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *Server) void {
        self.stopAndJoin();
        self.listener.deinit();
        for (self.requests[0..self.request_count]) |request| {
            self.allocator.free(request.method);
            self.allocator.free(request.path);
            self.allocator.free(request.body);
        }
        self.allocator.free(self.requests);
        self.allocator.destroy(self);
    }

    fn run(self: *Server) void {
        while (self.request_count < self.routes.len) {
            var conn = self.listener.accept() catch return;
            defer conn.stream.close();
            if (self.stopping.load(.acquire)) return;
            const index = self.request_count;
            self.request_count += 1;
            self.handle(&conn, index) catch {};
        }
    }

    fn handle(self: *Server, conn: *compat.net.Server.Connection, index: usize) !void {
        var buf: [8192]u8 = undefined;
        var filled: usize = 0;
        var body_length: usize = 0;
        while (filled < buf.len) {
            const n = conn.stream.read(buf[filled..]) catch return;
            if (n == 0) break;
            filled += n;
            if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n")) |header_end| {
                body_length = contentLength(buf[0..header_end]);
                if (filled >= header_end + 4 + body_length) break;
            }
        }
        const header_end = std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n") orelse return;
        const request_line_end = std.mem.indexOf(u8, buf[0..header_end], "\r\n") orelse header_end;
        var parts = std.mem.splitScalar(u8, buf[0..request_line_end], ' ');
        const method = parts.next() orelse return;
        const path = parts.next() orelse return;
        const body_start = header_end + 4;
        const body = buf[body_start..][0..@min(body_length, filled - body_start)];

        const method_copy = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(method_copy);
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        const body_copy = try self.allocator.dupe(u8, body);
        self.requests[index] = .{ .method = method_copy, .path = path_copy, .body = body_copy };

        const route = self.routes[index];
        var head_buf: [256]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &head_buf,
            "HTTP/1.1 {d} OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ route.status, route.body.len },
        );
        try conn.stream.writeAll(head);
        try conn.stream.writeAll(route.body);
    }
};

fn contentLength(headers: []const u8) usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " "), 10) catch 0;
        }
    }
    return 0;
}
