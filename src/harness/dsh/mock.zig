//! In-process mock of the dsh web Remote API subset the client speaks.
//!
//! Test-only: serves the `/connect` owner-cookie redirect, POST
//! `/api/<ns>/<method>` RPCs, and the `/api/remote.mux` WebSocket event
//! stream on an ephemeral loopback port. No Node, no real dsh.

const std = @import("std");
const std_compat = @import("compat");
const websocket = @import("../../websocket.zig");

const Allocator = std.mem.Allocator;

pub const session_id = "mock-sess-1";
pub const test_token = "test-key";
pub const owner_cookie = "dsh_owner=test-owner";

/// Terminal frames the mock streams; shapes match `protocol.parseServerFrame`.
pub const turn_completed_frame =
    "{\"type\":\"item\",\"streamId\":\"follow\",\"value\":{\"type\":\"event\"," ++
    "\"event\":{\"type\":\"turn/end\",\"data\":{\"reason\":{\"kind\":\"completed\"}}}}}";
pub const turn_aborted_frame =
    "{\"type\":\"item\",\"streamId\":\"follow\",\"value\":{\"type\":\"event\"," ++
    "\"event\":{\"type\":\"turn/end\",\"data\":{\"reason\":{\"kind\":\"aborted\"," ++
    "\"reason\":{\"kind\":\"user\"}}}}}}";

/// One `assistant-stream` text-delta frame in the `item` envelope.
pub fn textDeltaFrame(allocator: Allocator, index: u32, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"item\",\"streamId\":\"follow\",\"value\":{{\"type\":\"assistant-stream\"," ++
            "\"data\":{{\"type\":\"text-delta\",\"index\":{d},\"text\":{f}}}}}}}",
        .{ index, std.json.fmt(text, .{}) },
    );
}

/// History returned by `session/follow`: only records with `seq` past the
/// requested cursor are included.
const follow_records = [_]struct { seq: u64, json: []const u8 }{
    .{ .seq = 1, .json = "{\"seq\":1,\"type\":\"event\",\"event\":{\"type\":\"assistant/message\",\"text\":\"one\"}}" },
    .{ .seq = 2, .json = "{\"seq\":2,\"type\":\"event\",\"event\":{\"type\":\"assistant/message\",\"text\":\"two\"}}" },
    .{ .seq = 3, .json = "{\"seq\":3,\"type\":\"event\",\"event\":{\"type\":\"turn/end\",\"data\":{\"reason\":{\"kind\":\"completed\"}}}}" },
};

pub const MockDsh = struct {
    allocator: Allocator,
    server: std_compat.net.Server,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    mutex: std_compat.sync.Mutex = .{},
    /// Frames streamed after the next `session/prompt` reply, in test order.
    turn_frames: std.ArrayListUnmanaged([]u8) = .empty,
    ws: ?std_compat.net.Stream = null,

    pub fn init(allocator: Allocator) !*MockDsh {
        const address = try std_compat.net.Address.parseIp("127.0.0.1", 0);
        var server = try address.listen(.{});
        errdefer server.deinit();

        const self = try allocator.create(MockDsh);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .server = server };
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    pub fn deinit(self: *MockDsh) void {
        self.stopping.store(true, .release);
        // Wake the blocking accept with one throwaway connection.
        if (std_compat.net.tcpConnectToAddress(self.server.listen_address)) |stream| {
            stream.close();
        } else |_| {}
        if (self.thread) |thread| thread.join();
        self.server.deinit();
        if (self.ws) |stream| stream.close();
        clearFrames(self.allocator, &self.turn_frames);
        self.turn_frames.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn port(self: *const MockDsh) u16 {
        return self.server.listen_address.in.getPort();
    }

    pub fn baseUrl(self: *const MockDsh, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.port()});
    }

    /// Replace the frames streamed after the next `session/prompt` reply.
    pub fn setTurnFrames(self: *MockDsh, frames: []const []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        clearFrames(self.allocator, &self.turn_frames);
        for (frames) |frame| {
            const copy = try self.allocator.dupe(u8, frame);
            errdefer self.allocator.free(copy);
            try self.turn_frames.append(self.allocator, copy);
        }
    }

    fn acceptLoop(self: *MockDsh) void {
        while (!self.stopping.load(.acquire)) {
            const connection = self.server.accept() catch {
                if (self.stopping.load(.acquire)) return;
                continue;
            };
            if (self.stopping.load(.acquire)) {
                connection.stream.close();
                return;
            }
            self.serve(connection.stream);
        }
    }

    fn serve(self: *MockDsh, stream: std_compat.net.Stream) void {
        var keep_open = false;
        defer if (!keep_open) stream.close();

        const request = readRequest(self.allocator, stream) catch return;
        defer self.allocator.free(request.buffer);

        if (std.mem.startsWith(u8, request.target, "/api/remote.mux")) {
            self.upgrade(stream, request.head) catch return;
            self.mutex.lock();
            self.ws = stream;
            self.mutex.unlock();
            keep_open = true;
            return;
        }

        if (std.mem.startsWith(u8, request.target, "/connect")) {
            serveConnect(stream, request.target) catch return;
            return;
        }

        if (!std.mem.startsWith(u8, request.target, "/api/")) {
            writeHttp(stream, "404 Not Found", "", "{}") catch {};
            return;
        }
        self.serveRpc(stream, request.target["/api/".len..], request.body) catch {};
    }

    fn serveConnect(stream: std_compat.net.Stream, target: []const u8) !void {
        const token = queryValue(target, "token") orelse "";
        if (!std.mem.eql(u8, token, test_token)) {
            try writeHttp(stream, "403 Forbidden", "", "");
            return;
        }
        try writeHttp(
            stream,
            "302 Found",
            "Location: /\r\nSet-Cookie: " ++ owner_cookie ++ "; Path=/; HttpOnly; SameSite=Lax\r\n",
            "",
        );
    }

    fn serveRpc(self: *MockDsh, stream: std_compat.net.Stream, method: []const u8, body: []const u8) !void {
        var value: []u8 = undefined;
        if (std.mem.eql(u8, method, "session/create")) {
            value = try self.allocator.dupe(u8, "{\"sessionId\":\"" ++ session_id ++ "\"}");
        } else if (std.mem.eql(u8, method, "session/follow")) {
            value = try self.buildSnapshot(body);
        } else {
            value = try self.allocator.dupe(u8, "{}");
        }
        defer self.allocator.free(value);

        const response = try std.fmt.allocPrint(
            self.allocator,
            "{{\"result\":{{\"ok\":true,\"value\":{s}}}}}",
            .{value},
        );
        defer self.allocator.free(response);

        try writeHttp(stream, "200 OK", "Content-Type: application/json\r\n", response);
        if (std.mem.eql(u8, method, "session/prompt")) {
            try self.sendTurnFrames();
        } else if (std.mem.eql(u8, method, "session/cancel")) {
            try self.sendFrame(turn_aborted_frame);
        }
    }

    fn sendTurnFrames(self: *MockDsh) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ws = self.ws orelse return;
        for (self.turn_frames.items) |frame| try writeTextFrame(ws, frame);
    }

    fn sendFrame(self: *MockDsh, frame: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ws = self.ws orelse return;
        try writeTextFrame(ws, frame);
    }

    fn buildSnapshot(self: *MockDsh, body: []const u8) ![]u8 {
        const cursor = requestCursor(self.allocator, body) orelse 0;
        var last_seq = cursor;
        for (follow_records) |record| {
            if (record.seq > cursor) last_seq = record.seq;
        }

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        var allocating: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &buf);
        const writer = &allocating.writer;
        try writer.print("{{\"cursor\":{d},\"records\":[", .{last_seq});
        var first = true;
        for (follow_records) |record| {
            if (record.seq <= cursor) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll(record.json);
        }
        try writer.writeAll("],\"assistantStream\":true}");
        buf = allocating.toArrayList();
        return buf.toOwnedSlice(self.allocator);
    }

    fn upgrade(self: *MockDsh, stream: std_compat.net.Stream, head: []const u8) !void {
        const key = headerValue(head, "sec-websocket-key") orelse return error.MissingWebSocketKey;
        const accept = websocket.WsClient.computeAcceptKey(key);
        const response = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept},
        );
        defer self.allocator.free(response);
        try stream.writeAll(response);
    }
};

const Request = struct {
    buffer: []u8,
    head: []const u8,
    method: []const u8,
    target: []const u8,
    body: []const u8,
};

fn readRequest(allocator: Allocator, stream: std_compat.net.Stream) !Request {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buffer.deinit(allocator);
    var chunk: [4096]u8 = undefined;

    const head_end = while (true) {
        if (std.mem.indexOf(u8, buffer.items, "\r\n\r\n")) |pos| break pos + 4;
        if (buffer.items.len > 64 * 1024) return error.RequestTooLarge;
        const n = try stream.read(&chunk);
        if (n == 0) return error.ConnectionClosed;
        try buffer.appendSlice(allocator, chunk[0..n]);
    };

    const head_peek = buffer.items[0..head_end];
    const content_length: usize = if (headerValue(head_peek, "content-length")) |text|
        std.fmt.parseInt(usize, text, 10) catch return error.InvalidRequest
    else
        0;

    while (buffer.items.len < head_end + content_length) {
        const n = try stream.read(&chunk);
        if (n == 0) return error.ConnectionClosed;
        try buffer.appendSlice(allocator, chunk[0..n]);
    }

    const owned = try buffer.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    const head = owned[0..head_end];
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.InvalidRequest;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    const method = parts.next() orelse return error.InvalidRequest;
    const target = parts.next() orelse return error.InvalidRequest;
    return .{
        .buffer = owned,
        .head = head,
        .method = method,
        .target = target,
        .body = owned[head_end..][0..content_length],
    };
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn queryValue(target: []const u8, name: []const u8) ?[]const u8 {
    const question = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[question + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn requestCursor(allocator: Allocator, body: []const u8) ?u64 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const payload = asObject(root.get("payload")) orelse return null;
    const args = asObject(payload.get("args")) orelse return null;
    const request = asObject(args.get("request")) orelse return null;
    return switch (request.get("cursor") orelse return null) {
        .integer => |value| if (value >= 0) @intCast(value) else null,
        else => null,
    };
}

fn asObject(value: ?std.json.Value) ?std.json.ObjectMap {
    const present = value orelse return null;
    return switch (present) {
        .object => |object| object,
        else => null,
    };
}

fn writeHttp(
    stream: std_compat.net.Stream,
    status: []const u8,
    extra_headers: []const u8,
    body: []const u8,
) !void {
    var head: [1024]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &head,
        "HTTP/1.1 {s}\r\n{s}Content-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, extra_headers, body.len },
    );
    try stream.writeAll(text);
    try stream.writeAll(body);
}

/// Server-to-client frame: FIN + text, no mask (RFC 6455 §5.1).
fn writeTextFrame(stream: std_compat.net.Stream, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    var len: usize = 2;
    header[0] = 0x81;
    if (payload.len <= 125) {
        header[1] = @intCast(payload.len);
    } else if (payload.len <= 0xffff) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        len = 4;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        len = 10;
    }
    try stream.writeAll(header[0..len]);
    try stream.writeAll(payload);
}

fn clearFrames(allocator: Allocator, frames: *std.ArrayListUnmanaged([]u8)) void {
    for (frames.items) |frame| allocator.free(frame);
    frames.clearRetainingCapacity();
}
