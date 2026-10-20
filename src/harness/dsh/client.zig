//! dsh Remote API client: HTTP RPC over the curl subprocess and the
//! `/api/remote.mux` WebSocket event stream.
//!
//! Ownership: `DshClient` owns its `base_url`/`cookie` copies. Events returned
//! by `nextEvent` own their strings; release them with `freeEvent`.

const std = @import("std");
const std_compat = @import("compat");
const websocket = @import("../../websocket.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;

pub const WS_HOST = "127.0.0.1";
pub const WS_PATH = "/api/remote.mux";

// ---------------------------------------------------------------------------
// Boot URL helpers
// ---------------------------------------------------------------------------

pub const BootEndpoint = struct {
    /// Scheme + authority, no path/query (`http://127.0.0.1:4123`).
    base_url: []const u8,
    port: u16,
    token: []const u8,
};

/// Split a dsh launch URL into the HTTP base URL, port, and launch token.
/// Every returned slice borrows from `url`.
pub fn parseBootEndpoint(url: []const u8) !BootEndpoint {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidBootUrl;
    const authority_start = scheme_end + 3;
    const authority_end = std.mem.indexOfAnyPos(u8, url, authority_start, "/?#") orelse url.len;
    const authority = url[authority_start..authority_end];
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return error.InvalidBootUrl;
    const port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.InvalidBootUrl;

    const marker = "token=";
    const token_start = (std.mem.indexOf(u8, url, marker) orelse return error.InvalidBootUrl) + marker.len;
    var token_end = token_start;
    while (token_end < url.len and url[token_end] != '&' and url[token_end] != '#') token_end += 1;
    if (token_end == token_start) return error.InvalidBootUrl;

    return .{
        .base_url = url[0..authority_end],
        .port = port,
        .token = url[token_start..token_end],
    };
}

/// Build the owner-cookie exchange URL (`/connect?token=…&interactions=answer`).
pub fn connectUrl(allocator: Allocator, boot_url: []const u8) ![]u8 {
    const endpoint = try parseBootEndpoint(boot_url);
    return std.fmt.allocPrint(
        allocator,
        "{s}/connect?token={s}&interactions=answer",
        .{ endpoint.base_url, endpoint.token },
    );
}

/// Replace the launch token so the URL can be logged.
pub fn redactUrl(allocator: Allocator, url: []const u8) ![]u8 {
    const marker = "token=";
    const start = std.mem.indexOf(u8, url, marker) orelse return allocator.dupe(u8, url);
    var end = start + marker.len;
    while (end < url.len and url[end] != '&' and url[end] != '#') end += 1;
    return std.fmt.allocPrint(allocator, "{s}{s}<redacted>{s}", .{ url[0..start], marker, url[end..] });
}

/// Build the WebSocket/HTTP `Cookie` request header value.
pub fn cookieHeader(allocator: Allocator, cookie: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Cookie: {s}", .{cookie});
}

pub const HttpResponse = struct {
    status: u16,
    /// Raw response head (status line + headers), used to read Set-Cookie.
    headers: []u8,
    body: []u8,
};

/// Minimal HTTP/1.1 request to the local sidecar over std.http. No curl
/// dependency: the dsh image is a bare Node image.
/// Redirects are never followed: the connect call needs the 302 that carries
/// the owner cookie, and an RPC redirect is an error, not a new transport.
pub fn httpRequest(
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    headers: []const []const u8,
    body: ?[]const u8,
) !HttpResponse {
    var client: std.http.Client = .{ .allocator = allocator, .io = std_compat.io() };
    defer client.deinit();

    var header_buf: [8]std.http.Header = undefined;
    if (headers.len > header_buf.len) return error.TooManyHeaders;
    for (headers, 0..) |header, index| {
        const colon = std.mem.indexOfScalar(u8, header, ':') orelse return error.InvalidHeader;
        header_buf[index] = .{
            .name = std.mem.trim(u8, header[0..colon], " \t"),
            .value = std.mem.trim(u8, header[colon + 1 ..], " \t"),
        };
    }

    const uri = try std.Uri.parse(url);
    var req = try client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = header_buf[0..headers.len],
    });
    defer req.deinit();

    if (body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var request_body = try req.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(payload);
        try request_body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const response_headers = try allocator.dupe(u8, response.head.bytes);
    errdefer allocator.free(response_headers);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var transfer_buffer: [256]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    _ = reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    return .{
        .status = @intFromEnum(response.head.status),
        .headers = response_headers,
        .body = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]),
    };
}

fn parsePort(base_url: []const u8) !u16 {
    const scheme_end = std.mem.indexOf(u8, base_url, "://") orelse return error.InvalidBaseUrl;
    const authority_start = scheme_end + 3;
    const authority_end = std.mem.indexOfAnyPos(u8, base_url, authority_start, "/?#") orelse base_url.len;
    const authority = base_url[authority_start..authority_end];
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return error.InvalidBaseUrl;
    return std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch error.InvalidBaseUrl;
}

fn newRequestId(allocator: Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std_compat.crypto.random.bytes(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &hex);
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

pub const Event = struct {
    session_id: []u8,
    event: protocol.ServerEvent,
};

pub fn freeEvent(allocator: Allocator, event: *Event) void {
    allocator.free(event.session_id);
    freeServerEvent(allocator, event.event);
}

fn freeServerEvent(allocator: Allocator, event: protocol.ServerEvent) void {
    switch (event) {
        .assistant_chunk => |chunk| switch (chunk) {
            .text_delta => |delta| allocator.free(delta.text),
            .tool_call => |call| {
                allocator.free(call.call_id);
                allocator.free(call.name);
                allocator.free(call.arguments_json);
            },
            .tool_result => |result| {
                allocator.free(result.call_id);
                allocator.free(result.content_json);
            },
            .other => |raw| allocator.free(raw),
        },
        .turn_end => |turn| {
            allocator.free(turn.kind);
            if (turn.reason_kind) |kind| allocator.free(kind);
        },
        .approval_request => |request| {
            allocator.free(request.tool_name);
            allocator.free(request.call_id);
            if (request.display_reason) |reason| allocator.free(reason);
            if (request.event_id) |id| allocator.free(id);
        },
        .ignored => |kind| allocator.free(kind),
        .unknown => |raw| allocator.free(raw),
    }
}

/// State shared with the reader thread. Heap-allocated so moving `DshClient`
/// after `connect` does not invalidate the thread's pointer.
const Shared = struct {
    allocator: Allocator,
    session_id: []u8,
    ws: ?websocket.WsClient = null,
    queue: std.ArrayListUnmanaged(Event) = .empty,
    mutex: std_compat.sync.Mutex = .{},
    lost: bool = false,

    fn enqueueFrame(self: *Shared, frame_json: []const u8) !void {
        const event = protocol.parseServerFrame(self.allocator, frame_json) catch return;
        const session_id = self.allocator.dupe(u8, self.session_id) catch |err| {
            freeServerEvent(self.allocator, event);
            return err;
        };
        errdefer {
            self.allocator.free(session_id);
            freeServerEvent(self.allocator, event);
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.queue.append(self.allocator, .{ .session_id = session_id, .event = event });
    }

    fn nextEvent(self: *Shared, timeout_ms: u64) !Event {
        const deadline = std_compat.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (true) {
            self.mutex.lock();
            if (self.queue.items.len > 0) {
                const event = self.queue.orderedRemove(0);
                self.mutex.unlock();
                return event;
            }
            const lost = self.lost;
            self.mutex.unlock();

            if (lost) return error.ConnectionLost;
            if (std_compat.time.milliTimestamp() >= deadline) return error.Timeout;
            std_compat.thread.sleep(5 * std.time.ns_per_ms);
        }
    }

    fn markLost(self: *Shared) void {
        self.mutex.lock();
        self.lost = true;
        self.mutex.unlock();
    }

    fn deinitContents(self: *Shared) void {
        while (self.queue.items.len > 0) {
            var event = self.queue.orderedRemove(0);
            freeEvent(self.allocator, &event);
        }
        self.queue.deinit(self.allocator);
        self.allocator.free(self.session_id);
    }
};

fn readerMain(shared: *Shared) void {
    while (true) {
        const maybe_text = shared.ws.?.readTextMessage() catch {
            shared.markLost();
            return;
        };
        const text = maybe_text orelse {
            shared.markLost();
            return;
        };
        {
            defer shared.allocator.free(text);
            shared.enqueueFrame(text) catch {};
        }
    }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

pub const DshClient = struct {
    allocator: Allocator,
    base_url: []u8,
    cookie: []u8,
    port: u16,
    shared: ?*Shared = null,
    reader: ?std.Thread = null,

    pub fn init(allocator: Allocator, base_url: []const u8, cookie: []const u8) !DshClient {
        const base_copy = try allocator.dupe(u8, base_url);
        errdefer allocator.free(base_copy);
        return .{
            .allocator = allocator,
            .base_url = base_copy,
            .cookie = try allocator.dupe(u8, cookie),
            .port = try parsePort(base_url),
        };
    }

    pub fn deinit(self: *DshClient) void {
        if (self.shared) |shared| {
            if (shared.ws) |*ws| {
                ws.writeClose();
                ws.stream.shutdown(.both) catch {};
            }
            if (self.reader) |thread| thread.join();
            self.reader = null;
            if (shared.ws) |*ws| ws.deinit();
            shared.deinitContents();
            self.allocator.destroy(shared);
            self.shared = null;
        }
        self.allocator.free(self.base_url);
        self.allocator.free(self.cookie);
    }

    /// Open the WebSocket, subscribe to `$events` and `session/follow`, and
    /// start the single reader thread. One session per client (P0).
    pub fn connect(self: *DshClient, session_id: []const u8) !void {
        if (self.shared != null) return error.AlreadyConnected;

        const shared = try self.allocator.create(Shared);
        errdefer self.allocator.destroy(shared);
        shared.* = .{ .allocator = self.allocator, .session_id = try self.allocator.dupe(u8, session_id) };
        errdefer self.allocator.free(shared.session_id);

        const header = try cookieHeader(self.allocator, self.cookie);
        defer self.allocator.free(header);
        const headers = [_][]const u8{header};
        // dsh signs the owner cookie for the Host authority, so the handshake
        // Host header must carry the port (unlike the bare connectTcp host).
        const handshake_host = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ WS_HOST, self.port });
        defer self.allocator.free(handshake_host);
        const stream = try websocket.WsClient.connectTcp(self.allocator, WS_HOST, self.port);
        errdefer stream.close();
        shared.ws = try websocket.WsClient.connectPlainFromStream(
            self.allocator,
            stream,
            handshake_host,
            WS_PATH,
            &headers,
        );
        errdefer shared.ws.?.deinit();

        const follow = try protocol.buildFollowOpen(self.allocator, "follow", session_id);
        defer self.allocator.free(follow);
        try shared.ws.?.writeText(follow);

        const events = try protocol.buildEventsOpen(self.allocator, "events");
        defer self.allocator.free(events);
        try shared.ws.?.writeText(events);

        const reader = try std.Thread.spawn(.{}, readerMain, .{shared});
        self.shared = shared;
        self.reader = reader;
    }

    /// POST one RPC and parse the `{result:{ok,value}}` envelope.
    /// Redirects are never followed, so a stray 302 surfaces as `UnexpectedStatus`.
    pub fn call(self: *DshClient, method: []const u8, args_json: []const u8) !protocol.RpcReply {
        const rpc_id = try newRequestId(self.allocator);
        defer self.allocator.free(rpc_id);
        const body = try protocol.buildRpcBody(self.allocator, rpc_id, method, args_json);
        defer self.allocator.free(body);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/{s}", .{ self.base_url, method });
        defer self.allocator.free(url);
        const header = try cookieHeader(self.allocator, self.cookie);
        defer self.allocator.free(header);

        const response = try httpRequest(self.allocator, .POST, url, &.{
            header,
            "Content-Type: application/json",
        }, body);
        defer self.allocator.free(response.headers);
        defer self.allocator.free(response.body);

        if (response.status != 200) return error.UnexpectedStatus;
        return protocol.parseRpcBody(self.allocator, response.body);
    }

    pub fn freeReply(self: *DshClient, reply: *protocol.RpcReply) void {
        self.allocator.free(reply.value_json);
        if (reply.error_json) |err| self.allocator.free(err);
        reply.* = .{ .ok = false, .value_json = &.{}, .error_json = null };
    }

    pub fn createSession(self: *DshClient, cwd: []const u8) ![]u8 {
        const args = try std.json.Stringify.valueAlloc(self.allocator, .{ .request = .{ .cwd = cwd } }, .{});
        defer self.allocator.free(args);

        var reply = try self.call("session/create", args);
        defer self.freeReply(&reply);
        if (!reply.ok) return error.RpcFailed;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, reply.value_json, .{}) catch
            return error.InvalidRpcReply;
        defer parsed.deinit();
        const value = switch (parsed.value) {
            .object => |object| object.get("sessionId") orelse return error.InvalidRpcReply,
            else => return error.InvalidRpcReply,
        };
        const session_id = switch (value) {
            .string => |text| text,
            else => return error.InvalidRpcReply,
        };
        return self.allocator.dupe(u8, session_id);
    }

    pub fn prompt(self: *DshClient, session_id: []const u8, text: []const u8) !void {
        return self.sendPrompt(session_id, text, "queue");
    }

    pub fn steer(self: *DshClient, session_id: []const u8, text: []const u8) !void {
        return self.sendPrompt(session_id, text, "steer");
    }

    fn sendPrompt(self: *DshClient, session_id: []const u8, text: []const u8, mode: []const u8) !void {
        const TextPart = struct { type: []const u8, text: []const u8 };
        const request_id = try newRequestId(self.allocator);
        defer self.allocator.free(request_id);

        const args = try std.json.Stringify.valueAlloc(self.allocator, .{
            .request = .{
                .requestId = request_id,
                .sessionId = session_id,
                .mode = mode,
                .content = [1]TextPart{.{ .type = "text", .text = text }},
            },
        }, .{});
        defer self.allocator.free(args);

        var reply = try self.call("session/prompt", args);
        defer self.freeReply(&reply);
        if (!reply.ok) return error.RpcFailed;
    }

    /// Cancel the active turn and wait for its `turn/end` (drop-in events seen
    /// while waiting; the turn is terminal at that point).
    pub fn cancel(self: *DshClient, session_id: []const u8, timeout_ms: u64) !void {
        const shared = self.shared orelse return error.NotConnected;
        const args = try std.json.Stringify.valueAlloc(self.allocator, .{ .request = .{ .sessionId = session_id } }, .{});
        defer self.allocator.free(args);

        var reply = try self.call("session/cancel", args);
        defer self.freeReply(&reply);
        if (!reply.ok) return error.RpcFailed;

        const deadline = std_compat.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (true) {
            const remaining = deadline - std_compat.time.milliTimestamp();
            if (remaining <= 0) return error.CancelTimeout;
            var event = shared.nextEvent(@intCast(remaining)) catch |err| switch (err) {
                error.Timeout => return error.CancelTimeout,
                else => return err,
            };
            const ended = switch (event.event) {
                .turn_end => |turn| std.mem.eql(u8, turn.kind, "aborted"),
                else => false,
            };
            freeEvent(self.allocator, &event);
            if (ended) return;
        }
    }

    pub fn closeSession(self: *DshClient, session_id: []const u8) !void {
        const args = try std.json.Stringify.valueAlloc(self.allocator, .{ .request = .{ .sessionId = session_id } }, .{});
        defer self.allocator.free(args);

        var reply = try self.call("session/close", args);
        defer self.freeReply(&reply);
        if (!reply.ok) return error.RpcFailed;
    }

    /// Pop the next event, waiting at most `timeout_ms`.
    /// Returns `error.ConnectionLost` when the WebSocket reader stopped.
    pub fn nextEvent(self: *DshClient, timeout_ms: u64) !Event {
        const shared = self.shared orelse return error.NotConnected;
        return shared.nextEvent(timeout_ms);
    }
};

// ---------------------------------------------------------------------------
// Tests (pure logic; no network, Node, or wall-clock assertions)
// ---------------------------------------------------------------------------

test "buildRpcBody produces the dsh client-request envelope" {
    const body = try protocol.buildRpcBody(std.testing.allocator, "r-1", "session/prompt", "{\"request\":{}}");
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"type\":\"client-request\",\"rpcId\":\"r-1\",\"method\":\"session/prompt\",\"payload\":{\"args\":{\"request\":{}}}}",
        body,
    );
}

test "owner cookies join into one Cookie header" {
    const cookie = try protocol.ownerCookieFromSetCookie(std.testing.allocator, &.{
        "dsh_owner=test-value; Path=/; HttpOnly; SameSite=Lax",
        "dsh_operator=test-operator; Path=/",
    });
    defer std.testing.allocator.free(cookie);
    try std.testing.expectEqualStrings("dsh_owner=test-value; dsh_operator=test-operator", cookie);

    const header = try cookieHeader(std.testing.allocator, cookie);
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings("Cookie: dsh_owner=test-value; dsh_operator=test-operator", header);
}

test "boot URL yields base URL, port, connect URL and a redacted form" {
    const url = "http://127.0.0.1:54321/?token=test-token&interactions=answer";
    const endpoint = try parseBootEndpoint(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:54321", endpoint.base_url);
    try std.testing.expectEqual(@as(u16, 54321), endpoint.port);
    try std.testing.expectEqualStrings("test-token", endpoint.token);

    const connect = try connectUrl(std.testing.allocator, url);
    defer std.testing.allocator.free(connect);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:54321/connect?token=test-token&interactions=answer",
        connect,
    );

    const redacted = try redactUrl(std.testing.allocator, url);
    defer std.testing.allocator.free(redacted);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:54321/?token=<redacted>&interactions=answer",
        redacted,
    );
}

test "DshClient keeps the boot base URL and port" {
    var dsh = try DshClient.init(std.testing.allocator, "http://127.0.0.1:4123", "dsh_owner=test");
    defer dsh.deinit();
    try std.testing.expectEqual(@as(u16, 4123), dsh.port);
    try std.testing.expectEqualStrings("http://127.0.0.1:4123", dsh.base_url);
    try std.testing.expectEqualStrings("dsh_owner=test", dsh.cookie);
}

test "event queue routes parsed frames and tags the session" {
    var shared = Shared{
        .allocator = std.testing.allocator,
        .session_id = try std.testing.allocator.dupe(u8, "session-test"),
    };
    defer shared.deinitContents();

    try shared.enqueueFrame(
        "{\"type\":\"item\",\"streamId\":\"follow\",\"value\":{\"type\":\"event\",\"event\":{\"type\":\"turn/end\",\"data\":{\"reason\":{\"kind\":\"aborted\",\"reason\":{\"kind\":\"user\"}}}}}}",
    );
    try shared.enqueueFrame(
        "{\"type\":\"item\",\"streamId\":\"follow\",\"value\":{\"type\":\"assistant-stream\",\"data\":{\"type\":\"text-delta\",\"index\":0,\"text\":\"slow-12 \"}}}",
    );

    var ended = try shared.nextEvent(0);
    try std.testing.expectEqualStrings("session-test", ended.session_id);
    switch (ended.event) {
        .turn_end => |turn| {
            try std.testing.expectEqualStrings("aborted", turn.kind);
            try std.testing.expectEqualStrings("user", turn.reason_kind.?);
        },
        else => return error.TestUnexpectedEvent,
    }
    freeEvent(std.testing.allocator, &ended);

    var chunk = try shared.nextEvent(0);
    try std.testing.expectEqualStrings("session-test", chunk.session_id);
    switch (chunk.event) {
        .assistant_chunk => |value| switch (value) {
            .text_delta => |delta| try std.testing.expectEqualStrings("slow-12 ", delta.text),
            else => return error.TestUnexpectedEvent,
        },
        else => return error.TestUnexpectedEvent,
    }
    freeEvent(std.testing.allocator, &chunk);

    try std.testing.expectError(error.Timeout, shared.nextEvent(0));
}
