//! Scripted OpenAI-compatible provider for the dsh-native acceptance smoke.
//!
//! Serves `/chat/completions` on 127.0.0.1. A request that carries the user
//! marker SMOKE_PING and no `[Tool results]` answers with a bash tool call;
//! the follow-up (or any request without SMOKE_PING) gets the final
//! SMOKE_REPLY_OK. When the request asks for `"stream":true` the final answer
//! arrives as two SSE content deltas, so the smoke can prove live streaming.
//! Every request is appended to MOCK_LOG. No network, no keys.

const std = @import("std");

const max_request_bytes: usize = 1 << 20;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const port = envInt(init, allocator, "MOCK_PORT", 18081);
    const log_path = envAlloc(init, allocator, "MOCK_LOG", "/tmp/mock.log");
    defer allocator.free(log_path);

    const log_file = try std.Io.Dir.createFileAbsolute(io, log_path, .{});
    defer log_file.close(io);

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var server = try address.listen(io, .{ .mode = .stream, .protocol = .tcp, .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("mock provider listening on 127.0.0.1:{d}\n", .{port});
    while (true) {
        const stream = server.accept(io) catch continue;
        handle(allocator, io, stream, log_file) catch {};
        stream.socket.close(io);
    }
}

fn envAlloc(init: std.process.Init, allocator: std.mem.Allocator, name: []const u8, fallback: []const u8) []u8 {
    return init.minimal.environ.getAlloc(allocator, name) catch
        allocator.dupe(u8, fallback) catch @panic("out of memory");
}

fn envInt(init: std.process.Init, allocator: std.mem.Allocator, name: []const u8, fallback: u16) u16 {
    const value = envAlloc(init, allocator, name, "");
    defer allocator.free(value);
    return std.fmt.parseInt(u16, value, 10) catch fallback;
}

fn readSome(io: std.Io, stream: std.Io.net.Stream, buf: []u8) !usize {
    if (buf.len == 0) return 0;
    var data = [1][]u8{buf};
    return io.vtable.netRead(io.userdata, stream.socket.handle, &data);
}

fn writeAll(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var total: usize = 0;
    while (total < bytes.len) {
        var data = [1][]const u8{bytes[total..]};
        const n = try io.vtable.netWrite(io.userdata, stream.socket.handle, "", &data, 1);
        if (n == 0) return error.Unexpected;
        total += n;
    }
}

fn handle(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    log_file: std.Io.File,
) !void {
    // One fixed buffer: the request is at most max_request_bytes, and growing
    // an ArrayList while reading made curl's headers lose their first bytes.
    const buf = try allocator.alloc(u8, max_request_bytes);
    defer allocator.free(buf);

    var filled: usize = 0;
    var header_end: ?usize = null;
    while (header_end == null) {
        if (filled == buf.len) return error.RequestTooLarge;
        const n = try readSome(io, stream, buf[filled..]);
        if (n == 0) return;
        filled += n;
        header_end = std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n");
    }
    const head_end = header_end.?;
    const head = buf[0..head_end];

    var content_length: usize = 0;
    if (headerValue(head, "content-length")) |value| {
        content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
    }
    if (content_length > max_request_bytes) return error.RequestTooLarge;
    const body_start = head_end + 4;
    while (filled < body_start + content_length) {
        if (filled == buf.len) return error.RequestTooLarge;
        const n = try readSome(io, stream, buf[filled..]);
        if (n == 0) return;
        filled += n;
    }
    const body = buf[body_start .. body_start + content_length];

    const line_end = std.mem.indexOfScalar(u8, head, '\r') orelse head.len;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    const method = parts.next() orelse "";
    const path = parts.next() orelse "";

    appendLog(allocator, io, log_file, method, path, body);

    if (std.mem.eql(u8, method, "GET") and std.mem.endsWith(u8, path, "/models")) {
        return sendJson(io, stream, "200 OK", "{\"object\":\"list\",\"data\":[{\"id\":\"smoke-model\",\"object\":\"model\"}]}");
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.endsWith(u8, path, "/chat/completions")) {
        // `[Tool results]` only appears once the engine has run the tool. The
        // streaming smoke message does not carry SMOKE_PING, so it takes the
        // direct-answer path without a tool round.
        const wants_tool = std.mem.indexOf(u8, body, "SMOKE_PING") != null and
            std.mem.indexOf(u8, body, "[Tool results]") == null;
        if (std.mem.indexOf(u8, body, "\"stream\":true") != null and !wants_tool) {
            return sendReplyStream(io, stream);
        }
        if (wants_tool) return sendJson(io, stream, "200 OK", tool_call);
        return sendJson(io, stream, "200 OK", final_reply);
    }
    return sendJson(io, stream, "404 Not Found", "{\"error\":\"not found\"}");
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(key, name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

fn appendLog(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    method: []const u8,
    target: []const u8,
    body: []const u8,
) void {
    const line = std.fmt.allocPrint(allocator, "REQ {s} {s}\n{s}\n", .{ method, target, body }) catch return;
    defer allocator.free(line);
    file.writeStreamingAll(io, line) catch {};
}

/// Two content deltas then a finishing chunk: the caller can tell a live
/// per-chunk relay (two events) from the blocking bridge's one synthesised
/// delta.
fn sendReplyStream(io: std.Io, stream: std.Io.net.Stream) !void {
    try writeAll(io, stream, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n");
    const events = [_][]const u8{
        "{\"id\":\"chatcmpl-smoke\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"smoke-model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}",
        "{\"id\":\"chatcmpl-smoke\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"smoke-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"SMOKE_\"},\"finish_reason\":null}]}",
        "{\"id\":\"chatcmpl-smoke\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"smoke-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"REPLY_OK\"},\"finish_reason\":null}]}",
        "{\"id\":\"chatcmpl-smoke\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"smoke-model\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}",
    };
    for (events) |event| {
        try writeAll(io, stream, "data: ");
        try writeAll(io, stream, event);
        try writeAll(io, stream, "\n\n");
    }
    try writeAll(io, stream, "data: [DONE]\n\n");
}

fn sendJson(io: std.Io, stream: std.Io.net.Stream, status: []const u8, body: []const u8) !void {
    var header: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &header,
        "HTTP/1.1 {s}\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n",
        .{ status, body.len },
    );
    try writeAll(io, stream, head);
    try writeAll(io, stream, body);
}

const tool_call =
    "{\"id\":\"chatcmpl-smoke\",\"object\":\"chat.completion\",\"created\":0,\"model\":\"smoke-model\"," ++
    "\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":null," ++
    "\"tool_calls\":[{\"id\":\"call_smoke_1\",\"type\":\"function\",\"function\":{\"name\":\"bash\"," ++
    "\"arguments\":\"{\\\"command\\\":\\\"echo SMOKE_TOOL_OUTPUT\\\",\\\"description\\\":\\\"Emit the smoke marker\\\"}\"}}]}," ++
    "\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}";

const final_reply =
    "{\"id\":\"chatcmpl-smoke\",\"object\":\"chat.completion\",\"created\":0,\"model\":\"smoke-model\"," ++
    "\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"SMOKE_REPLY_OK\"}," ++
    "\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}";
