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

/// One committed `assistant/message` frame in the `item` envelope. dsh sets
/// `interrupted` when a cancelled turn commits its delivered prefix.
pub fn committedMessageFrame(allocator: Allocator, text: []const u8, interrupted: bool) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"item\",\"streamId\":\"follow\",\"value\":{{\"type\":\"event\"," ++
            "\"event\":{{\"type\":\"assistant/message\",\"seq\":9,\"time\":1," ++
            "\"surfaceOp\":\"append\",\"data\":{{\"turn\":1,\"step\":1,{s}" ++
            "\"stream\":[],\"message\":{{\"id\":\"msg-1\",\"role\":\"assistant\"," ++
            "\"content\":[{{\"type\":\"text\",\"text\":{f}}}]," ++
            "\"source\":{{\"kind\":\"model\",\"provider\":\"mock\",\"model\":\"mock\"}}}}}}}}}}}}",
        .{ if (interrupted) "\"interrupted\":true," else "", std.json.fmt(text, .{}) },
    );
}

/// History returned by `session/follow`: only records with `seq` past the
/// requested cursor are included.
const follow_records = [_]struct { seq: u64, json: []const u8 }{
    .{ .seq = 1, .json = "{\"seq\":1,\"type\":\"event\",\"event\":{\"type\":\"assistant/message\",\"text\":\"one\"}}" },
    .{ .seq = 2, .json = "{\"seq\":2,\"type\":\"event\",\"event\":{\"type\":\"assistant/message\",\"text\":\"two\"}}" },
    .{ .seq = 3, .json = "{\"seq\":3,\"type\":\"event\",\"event\":{\"type\":\"turn/end\",\"data\":{\"reason\":{\"kind\":\"completed\"}}}}" },
};

/// One upgraded WS connection, bound to the dsh session its follow stream named.
const WsConn = struct {
    stream: std_compat.net.Stream,
    session: []u8,
};

/// Test gate that parks the mock's `/connect` handler (and with it the boot)
/// until the test opens it. The condition is event-based; no wall-clock check.
pub const ConnectGate = struct {
    mutex: std_compat.sync.Mutex = .{},
    cond: std_compat.sync.Condition = .{},
    entered: bool = false,
    opened: bool = false,

    /// Called from the mock's serve thread.
    pub fn enter(self: *ConnectGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entered = true;
        self.cond.broadcast();
        while (!self.opened) self.cond.wait(&self.mutex);
    }

    /// Block until a `/connect` is parked in `enter`.
    pub fn waitEntered(self: *ConnectGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.entered) self.cond.wait(&self.mutex);
    }

    pub fn open(self: *ConnectGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.opened = true;
        self.cond.broadcast();
    }
};

pub const MockDsh = struct {
    allocator: Allocator,
    server: std_compat.net.Server,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    mutex: std_compat.sync.Mutex = .{},
    /// Frames streamed after the next `session/prompt` reply, in test order.
    turn_frames: std.ArrayListUnmanaged([]u8) = .empty,
    /// Frames streamed by `session/cancel` before the aborted `turn/end`.
    cancel_frames: std.ArrayListUnmanaged([]u8) = .empty,
    /// Each harness client opens one WS; frames go to the session's latest one.
    ws_conns: std.ArrayListUnmanaged(WsConn) = .empty,
    /// Session ids the harness sent `session/close` for.
    closed_sessions: std.ArrayListUnmanaged([]u8) = .empty,
    /// Harness-test observability; guarded by `mutex`.
    create_count: u32 = 0,
    prompt_count: u32 = 0,
    cancel_count: u32 = 0,
    connect_count: u32 = 0,
    ws_connections: u32 = 0,
    last_prompt_session: ?[]u8 = null,
    /// Fail the next `/connect` once (boot-failure tests).
    fail_connect_once: bool = false,
    /// Park `/connect` while non-null (boot-blocking tests).
    connect_gate: ?*ConnectGate = null,
    /// Echo each prompt back as a delta plus a completed turn/end.
    echo_prompts: bool = false,
    /// Reply value for `session/modelCatalog`; null replies `{}`.
    model_catalog_json: ?[]u8 = null,
    /// Reply value for `session/projections`; null replies `{}`.
    projection_json: ?[]u8 = null,
    /// `session/selectModel` request bodies, in arrival order.
    select_model_requests: std.ArrayListUnmanaged([]u8) = .empty,

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
        for (self.ws_conns.items) |conn| {
            conn.stream.close();
            self.allocator.free(conn.session);
        }
        self.ws_conns.deinit(self.allocator);
        for (self.closed_sessions.items) |session| self.allocator.free(session);
        self.closed_sessions.deinit(self.allocator);
        if (self.last_prompt_session) |session| self.allocator.free(session);
        if (self.model_catalog_json) |json| self.allocator.free(json);
        if (self.projection_json) |json| self.allocator.free(json);
        for (self.select_model_requests.items) |request| self.allocator.free(request);
        self.select_model_requests.deinit(self.allocator);
        clearFrames(self.allocator, &self.turn_frames);
        self.turn_frames.deinit(self.allocator);
        clearFrames(self.allocator, &self.cancel_frames);
        self.cancel_frames.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn port(self: *const MockDsh) u16 {
        return self.server.listen_address.in.getPort();
    }

    pub fn baseUrl(self: *const MockDsh, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.port()});
    }

    /// Replace the `session/modelCatalog` reply value.
    pub fn setModelCatalog(self: *MockDsh, json: []const u8) !void {
        const copy = try self.allocator.dupe(u8, json);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.model_catalog_json) |old| self.allocator.free(old);
        self.model_catalog_json = copy;
    }

    /// Replace the `session/projections` reply value.
    pub fn setProjection(self: *MockDsh, json: []const u8) !void {
        const copy = try self.allocator.dupe(u8, json);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.projection_json) |old| self.allocator.free(old);
        self.projection_json = copy;
    }

    pub fn selectModelCount(self: *MockDsh) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.select_model_requests.items.len;
    }

    /// Copy of the last `session/selectModel` request body; caller frees.
    pub fn lastSelectModel(self: *MockDsh, allocator: Allocator) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.select_model_requests.items.len == 0) return null;
        return try allocator.dupe(u8, self.select_model_requests.items[self.select_model_requests.items.len - 1]);
    }

    fn recordSelectModel(self: *MockDsh, body: []const u8) void {
        const copy = self.allocator.dupe(u8, body) catch return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.select_model_requests.append(self.allocator, copy) catch self.allocator.free(copy);
    }

    /// Replace the frames streamed after the next `session/prompt` reply.
    pub fn setTurnFrames(self: *MockDsh, frames: []const []const u8) !void {
        return self.replaceFrames(&self.turn_frames, frames);
    }

    /// Replace the frames streamed by the next `session/cancel`.
    pub fn setCancelFrames(self: *MockDsh, frames: []const []const u8) !void {
        return self.replaceFrames(&self.cancel_frames, frames);
    }

    fn replaceFrames(
        self: *MockDsh,
        list: *std.ArrayListUnmanaged([]u8),
        frames: []const []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        clearFrames(self.allocator, list);
        for (frames) |frame| {
            const copy = try self.allocator.dupe(u8, frame);
            errdefer self.allocator.free(copy);
            try list.append(self.allocator, copy);
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
            // The harness sends its `session/follow` open as the first frame;
            // bind this connection to that session for prompt/cancel routing.
            const session = readFollowSession(self.allocator, stream) catch return;
            self.mutex.lock();
            self.ws_conns.append(self.allocator, .{ .stream = stream, .session = session }) catch {
                self.mutex.unlock();
                self.allocator.free(session);
                return;
            };
            self.ws_connections += 1;
            self.mutex.unlock();
            keep_open = true;
            return;
        }

        if (std.mem.startsWith(u8, request.target, "/connect")) {
            self.serveConnect(stream, request.target) catch return;
            return;
        }

        if (!std.mem.startsWith(u8, request.target, "/api/")) {
            writeHttp(stream, "404 Not Found", "", "{}") catch {};
            return;
        }
        self.serveRpc(stream, request.target["/api/".len..], request.body) catch {};
    }

    fn serveConnect(self: *MockDsh, stream: std_compat.net.Stream, target: []const u8) !void {
        self.mutex.lock();
        self.connect_count += 1;
        const fail = self.fail_connect_once;
        if (fail) self.fail_connect_once = false;
        const gate = self.connect_gate;
        self.mutex.unlock();

        if (gate) |g| g.enter();
        if (fail) {
            try writeHttp(stream, "500 Internal Server Error", "", "");
            return;
        }

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
            value = try self.nextSessionValue();
        } else if (std.mem.eql(u8, method, "session/follow")) {
            value = try self.buildSnapshot(body);
        } else if (std.mem.eql(u8, method, "session/modelCatalog")) {
            self.mutex.lock();
            const json = self.model_catalog_json orelse "{}";
            value = self.allocator.dupe(u8, json) catch |err| {
                self.mutex.unlock();
                return err;
            };
            self.mutex.unlock();
        } else if (std.mem.eql(u8, method, "session/projections")) {
            self.mutex.lock();
            const json = self.projection_json orelse "{}";
            value = self.allocator.dupe(u8, json) catch |err| {
                self.mutex.unlock();
                return err;
            };
            self.mutex.unlock();
        } else if (std.mem.eql(u8, method, "session/selectModel")) {
            self.recordSelectModel(body);
            value = try self.allocator.dupe(u8, "{}");
        } else {
            value = try self.allocator.dupe(u8, "{}");
        }
        defer self.allocator.free(value);

        // Record before the reply: the client may return as soon as it reads it.
        const is_prompt = std.mem.eql(u8, method, "session/prompt");
        const is_cancel = std.mem.eql(u8, method, "session/cancel");
        if (is_prompt) self.recordPrompt(body);
        if (is_cancel) self.recordCancel();
        if (std.mem.eql(u8, method, "session/close")) self.recordClose(body);

        const response = try std.fmt.allocPrint(
            self.allocator,
            "{{\"result\":{{\"ok\":true,\"value\":{s}}}}}",
            .{value},
        );
        defer self.allocator.free(response);

        try writeHttp(stream, "200 OK", "Content-Type: application/json\r\n", response);
        if (is_prompt) {
            const session = requestSessionId(self.allocator, body) orelse return;
            defer self.allocator.free(session);
            self.mutex.lock();
            const echo = self.echo_prompts;
            self.mutex.unlock();
            if (echo) {
                try self.sendEchoFrames(session, body);
            } else {
                try self.sendTurnFrames(session);
            }
        } else if (is_cancel) {
            const session = requestSessionId(self.allocator, body) orelse return;
            defer self.allocator.free(session);
            try self.sendCancelFrames(session);
        }
    }

    /// Unique ids prove a harness created a fresh session instead of reusing one.
    fn nextSessionValue(self: *MockDsh) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.create_count += 1;
        const session = try std.fmt.allocPrint(self.allocator, "mock-sess-{d}", .{self.create_count});
        defer self.allocator.free(session);
        return std.json.Stringify.valueAlloc(self.allocator, .{ .sessionId = session }, .{});
    }

    fn recordPrompt(self: *MockDsh, body: []const u8) void {
        const session = requestSessionId(self.allocator, body) orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.prompt_count += 1;
        if (self.last_prompt_session) |old| self.allocator.free(old);
        self.last_prompt_session = session;
    }

    fn recordCancel(self: *MockDsh) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancel_count += 1;
    }

    fn recordClose(self: *MockDsh, body: []const u8) void {
        const session = requestSessionId(self.allocator, body) orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed_sessions.append(self.allocator, session) catch self.allocator.free(session);
    }

    pub fn createCount(self: *MockDsh) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.create_count;
    }

    pub fn promptCount(self: *MockDsh) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.prompt_count;
    }

    pub fn cancelCount(self: *MockDsh) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancel_count;
    }

    /// Number of `/connect` owner-cookie exchanges (= boots) started.
    pub fn connectCount(self: *MockDsh) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.connect_count;
    }

    pub fn failNextConnect(self: *MockDsh) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.fail_connect_once = true;
    }

    /// Park `/connect` in `gate` until it is opened.
    pub fn setConnectGate(self: *MockDsh, gate: ?*ConnectGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.connect_gate = gate;
    }

    /// Echo each prompt text back as the turn reply (distinct per session).
    pub fn setEchoPrompts(self: *MockDsh, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.echo_prompts = enabled;
    }

    pub fn wsConnections(self: *MockDsh) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.ws_connections;
    }

    pub fn closeCount(self: *MockDsh) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return @intCast(self.closed_sessions.items.len);
    }

    pub fn wasClosed(self: *MockDsh, session: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.closed_sessions.items) |closed| {
            if (std.mem.eql(u8, closed, session)) return true;
        }
        return false;
    }

    /// Caller frees. Null before any prompt.
    pub fn lastPromptSession(self: *MockDsh, allocator: Allocator) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.last_prompt_session) |session| try allocator.dupe(u8, session) else null;
    }

    /// Newest connection bound to `session`: a resumed process opens a fresh
    /// WS for an id that an earlier harness instance also used. Caller holds
    /// `mutex`.
    fn wsForSessionLocked(self: *MockDsh, session: []const u8) ?std_compat.net.Stream {
        var index = self.ws_conns.items.len;
        while (index > 0) {
            index -= 1;
            const conn = self.ws_conns.items[index];
            if (std.mem.eql(u8, conn.session, session)) return conn.stream;
        }
        return null;
    }

    fn sendTurnFrames(self: *MockDsh, session: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ws = self.wsForSessionLocked(session) orelse return;
        for (self.turn_frames.items) |frame| try writeTextFrame(ws, frame);
    }

    /// Reply with the prompt's own text, so concurrent sessions are
    /// distinguishable without a per-session frame table.
    fn sendEchoFrames(self: *MockDsh, session: []const u8, body: []const u8) !void {
        const text = requestPromptText(self.allocator, body) orelse
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(text);
        const delta = try textDeltaFrame(self.allocator, 0, text);
        defer self.allocator.free(delta);

        self.mutex.lock();
        defer self.mutex.unlock();
        const ws = self.wsForSessionLocked(session) orelse return;
        try writeTextFrame(ws, delta);
        try writeTextFrame(ws, turn_completed_frame);
    }

    /// A cancelled turn commits its delivered prefix before the terminal frame.
    fn sendCancelFrames(self: *MockDsh, session: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ws = self.wsForSessionLocked(session) orelse return;
        for (self.cancel_frames.items) |frame| try writeTextFrame(ws, frame);
        try writeTextFrame(ws, turn_aborted_frame);
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

/// First text part of a `session/prompt` request; caller frees.
fn requestPromptText(allocator: Allocator, body: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const root = asObject(parsed.value) orelse return null;
    const payload = asObject(root.get("payload")) orelse return null;
    const args = asObject(payload.get("args")) orelse return null;
    const request = asObject(args.get("request")) orelse return null;
    const content = switch (request.get("content") orelse return null) {
        .array => |items| items,
        else => return null,
    };
    if (content.items.len == 0) return null;
    const part = asObject(content.items[0]) orelse return null;
    const text = switch (part.get("text") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    return allocator.dupe(u8, text) catch null;
}

fn requestSessionId(allocator: Allocator, body: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const root = asObject(parsed.value) orelse return null;
    const payload = asObject(root.get("payload")) orelse return null;
    const args = asObject(payload.get("args")) orelse return null;
    const request = asObject(args.get("request")) orelse return null;
    const session = switch (request.get("sessionId") orelse return null) {
        .string => |text| text,
        else => return null,
    };
    return allocator.dupe(u8, session) catch null;
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

/// Read the first client text frame (the harness's `session/follow` open) and
/// return the session id it names. Client frames are masked (RFC 6455 §5.3).
fn readFollowSession(allocator: Allocator, stream: std_compat.net.Stream) ![]u8 {
    var header: [2]u8 = undefined;
    try readExact(stream, &header);
    if ((header[0] & 0x0f) != 0x01) return error.NotTextFrame;
    const masked = (header[1] & 0x80) != 0;
    var length: u64 = header[1] & 0x7f;
    if (length == 126) {
        var ext: [2]u8 = undefined;
        try readExact(stream, &ext);
        length = std.mem.readInt(u16, &ext, .big);
    } else if (length == 127) {
        var ext: [8]u8 = undefined;
        try readExact(stream, &ext);
        length = std.mem.readInt(u64, &ext, .big);
    }
    if (length > 64 * 1024) return error.MessageTooLarge;
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) try readExact(stream, &mask);
    const payload = try allocator.alloc(u8, @intCast(length));
    defer allocator.free(payload);
    try readExact(stream, payload);
    if (masked) {
        for (payload, 0..) |*byte, index| byte.* ^= mask[index % 4];
    }

    // Test-only frames come from `protocol.buildFollowOpen`; a plain search is
    // enough for its flat `"sessionId":"<id>"` field.
    const marker = "\"sessionId\":\"";
    const start = (std.mem.indexOf(u8, payload, marker) orelse return error.NoSessionId) +
        marker.len;
    const end = std.mem.indexOfScalarPos(u8, payload, start, '"') orelse return error.NoSessionId;
    return try allocator.dupe(u8, payload[start..end]);
}

fn readExact(stream: std_compat.net.Stream, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const n = try stream.read(buffer[offset..]);
        if (n == 0) return error.ConnectionClosed;
        offset += n;
    }
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
