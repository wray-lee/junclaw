//! Client-level tests against the in-process dsh mock (no Node, no real dsh).

const std = @import("std");
const builtin = @import("builtin");
const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const mock_mod = @import("mock.zig");

const Allocator = std.mem.Allocator;
const DshClient = client_mod.DshClient;
const MockDsh = mock_mod.MockDsh;

/// Upper bound for a frame the mock already wrote before the call returned;
/// never asserted on, only a hang guard.
const wait_ms = 5_000;

fn newClient(allocator: Allocator, mock: *MockDsh) !DshClient {
    const base_url = try mock.baseUrl(allocator);
    defer allocator.free(base_url);
    return DshClient.init(allocator, base_url, mock_mod.owner_cookie);
}

fn newSession(allocator: Allocator, client: *DshClient) ![]u8 {
    const session = try client.createSession("/workspace");
    errdefer allocator.free(session);
    try client.connect(session);
    return session;
}

/// Parse a raw frame through the protocol layer and wrap it so the client's
/// free helper can release it.
fn parseFrameEvent(allocator: Allocator, frame: []const u8) !client_mod.Event {
    const session_id = try allocator.dupe(u8, mock_mod.session_id);
    errdefer allocator.free(session_id);
    return .{ .session_id = session_id, .event = try protocol.parseServerFrame(allocator, frame) };
}

fn headerLine(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

test "mock dsh exchanges the boot token for an owner cookie" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/?token={s}",
        .{ mock.port(), mock_mod.test_token },
    );
    defer allocator.free(boot_url);
    const connect_url = try client_mod.connectUrl(allocator, boot_url);
    defer allocator.free(connect_url);

    const response = try client_mod.httpRequest(allocator, .GET, connect_url, &.{}, null);
    defer allocator.free(response.headers);
    defer allocator.free(response.body);
    try std.testing.expectEqual(@as(u16, 302), response.status);

    const set_cookie = headerLine(response.headers, "set-cookie") orelse
        return error.TestExpectedSetCookie;
    const cookie = try protocol.ownerCookieFromSetCookie(allocator, &.{set_cookie});
    defer allocator.free(cookie);
    try std.testing.expectEqualStrings(mock_mod.owner_cookie, cookie);

    // The launch token stays out of responses and out of loggable URLs.
    try std.testing.expect(std.mem.indexOf(u8, response.headers, mock_mod.test_token) == null);
    const redacted = try client_mod.redactUrl(allocator, connect_url);
    defer allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, mock_mod.test_token) == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "<redacted>") != null);

    var client = try newClient(allocator, mock);
    defer client.deinit();
    const session = try client.createSession("/workspace");
    defer allocator.free(session);
    try std.testing.expectEqualStrings(mock_mod.session_id, session);
}

test "mock dsh streams text deltas in order" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const first = try mock_mod.textDeltaFrame(allocator, 0, "one ");
    defer allocator.free(first);
    const second = try mock_mod.textDeltaFrame(allocator, 1, "two ");
    defer allocator.free(second);
    const third = try mock_mod.textDeltaFrame(allocator, 2, "three");
    defer allocator.free(third);
    try mock.setTurnFrames(&.{ first, second, third, mock_mod.turn_completed_frame });

    var client = try newClient(allocator, mock);
    defer client.deinit();
    const session = try newSession(allocator, &client);
    defer allocator.free(session);
    try client.prompt(session, "hello");

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);
    var saw_completed = false;
    for (0..4) |index| {
        var event = try client.nextEvent(wait_ms);
        defer client_mod.freeEvent(allocator, &event);
        switch (event.event) {
            .assistant_chunk => |chunk| switch (chunk) {
                .text_delta => |delta| {
                    try std.testing.expectEqual(@as(u32, @intCast(index)), delta.index);
                    try text.appendSlice(allocator, delta.text);
                },
                else => return error.TestExpectedTextDelta,
            },
            .turn_end => |turn| {
                try std.testing.expectEqualStrings("completed", turn.kind);
                try std.testing.expect(turn.reason_kind == null);
                saw_completed = true;
            },
            else => return error.TestUnexpectedEvent,
        }
    }
    try std.testing.expectEqualStrings("one two three", text.items);
    try std.testing.expect(saw_completed);
}

test "turn/end kinds map at the protocol layer" {
    const allocator = std.testing.allocator;

    var completed = try parseFrameEvent(allocator, mock_mod.turn_completed_frame);
    defer client_mod.freeEvent(allocator, &completed);
    switch (completed.event) {
        .turn_end => |turn| {
            try std.testing.expectEqualStrings("completed", turn.kind);
            try std.testing.expect(turn.reason_kind == null);
        },
        else => return error.TestExpectedTurnEnd,
    }

    var aborted = try parseFrameEvent(allocator, mock_mod.turn_aborted_frame);
    defer client_mod.freeEvent(allocator, &aborted);
    switch (aborted.event) {
        .turn_end => |turn| {
            try std.testing.expectEqualStrings("aborted", turn.kind);
            try std.testing.expectEqualStrings("user", turn.reason_kind.?);
        },
        else => return error.TestExpectedTurnEnd,
    }
}

test "cancel surfaces the aborted turn/end and keeps partial text" {
    // Regression: cancel() returned without exposing turn/end aborted or the
    // assistant text streamed before it.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const first = try mock_mod.textDeltaFrame(allocator, 0, "partial one ");
    defer allocator.free(first);
    const second = try mock_mod.textDeltaFrame(allocator, 1, "partial two");
    defer allocator.free(second);
    // No turn/end: the cancel RPC supplies it.
    try mock.setTurnFrames(&.{ first, second });

    var client = try newClient(allocator, mock);
    defer client.deinit();
    const session = try newSession(allocator, &client);
    defer allocator.free(session);
    try client.prompt(session, "start");

    var result = try client.cancel(session, wait_ms);
    defer client_mod.freeCancelResult(allocator, &result);
    try std.testing.expectEqualStrings("aborted", result.kind);
    try std.testing.expectEqualStrings("user", result.reason_kind.?);
    try std.testing.expectEqualStrings("partial one partial two", result.partial_text);
}

test "session/follow returns records after the cursor" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var client = try newClient(allocator, mock);
    defer client.deinit();
    var reply = try client.call(
        "session/follow",
        "{\"request\":{\"sessionId\":\"mock-sess-1\",\"cursor\":1,\"assistantStream\":true}}",
    );
    defer client.freeReply(&reply);
    try std.testing.expect(reply.ok);

    const snapshot = try protocol.parseSnapshot(allocator, reply.value_json);
    defer if (snapshot.turn_kind) |kind| allocator.free(kind);
    try std.testing.expectEqual(@as(?u64, 3), snapshot.cursor);
    try std.testing.expectEqual(@as(u32, 2), snapshot.record_count);
    try std.testing.expectEqualStrings("completed", snapshot.turn_kind.?);
    try std.testing.expect(std.mem.indexOf(u8, reply.value_json, "\"seq\":1") == null);
}

test "tool-call delta and tool-call for one callId produce one event" {
    // Regression: the tool-call after a tool-call-delta surfaced as a second
    // duplicate tool_call event.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const delta =
        "{\"type\":\"item\",\"streamId\":\"follow\",\"value\":{\"type\":\"assistant-stream\"," ++
        "\"data\":{\"type\":\"tool-call-delta\",\"callId\":\"call-1\",\"name\":\"read\"," ++
        "\"argumentsDelta\":\"{\\\"path\\\":\"}}}";
    const full =
        "{\"type\":\"item\",\"streamId\":\"follow\",\"value\":{\"type\":\"assistant-stream\"," ++
        "\"data\":{\"type\":\"tool-call\",\"callId\":\"call-1\",\"name\":\"read\"," ++
        "\"arguments\":{\"path\":\"example.com\"}}}}";
    try mock.setTurnFrames(&.{ delta, full, mock_mod.turn_completed_frame });

    var client = try newClient(allocator, mock);
    defer client.deinit();
    const session = try newSession(allocator, &client);
    defer allocator.free(session);
    try client.prompt(session, "hello");

    var call_event = try client.nextEvent(wait_ms);
    defer client_mod.freeEvent(allocator, &call_event);
    switch (call_event.event) {
        .assistant_chunk => |chunk| switch (chunk) {
            .tool_call => |call| {
                try std.testing.expectEqualStrings("call-1", call.call_id);
                try std.testing.expectEqualStrings("read", call.name);
                try std.testing.expectEqualStrings("{\"path\":\"example.com\"}", call.arguments_json);
                try std.testing.expect(!call.is_delta);
            },
            else => return error.TestExpectedToolCall,
        },
        else => return error.TestExpectedToolCall,
    }

    // The next event must be the turn end, not a duplicate tool call.
    var end_event = try client.nextEvent(wait_ms);
    defer client_mod.freeEvent(allocator, &end_event);
    switch (end_event.event) {
        .turn_end => |turn| try std.testing.expectEqualStrings("completed", turn.kind),
        else => return error.TestExpectedTurnEnd,
    }
}

test "approval displayReason object yields a display string" {
    // Regression: the {en,zh} displayReason object parsed to a null display.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const approval =
        "{\"type\":\"item\",\"streamId\":\"events\",\"value\":{\"type\":\"waterfall\"," ++
        "\"event\":\"approval/request\",\"eventId\":\"evt-1\",\"request\":{" ++
        "\"toolName\":\"bash\",\"callId\":\"call-1\"," ++
        "\"displayReason\":{\"en\":\"Run outside workspace\",\"zh\":\"在工作区外运行\"}}}}";
    try mock.setTurnFrames(&.{ approval, mock_mod.turn_completed_frame });

    var client = try newClient(allocator, mock);
    defer client.deinit();
    const session = try newSession(allocator, &client);
    defer allocator.free(session);
    try client.prompt(session, "hello");

    var approval_event = try client.nextEvent(wait_ms);
    defer client_mod.freeEvent(allocator, &approval_event);
    switch (approval_event.event) {
        .approval_request => |request| {
            try std.testing.expectEqualStrings("bash", request.tool_name);
            try std.testing.expectEqualStrings("call-1", request.call_id);
            try std.testing.expectEqualStrings("evt-1", request.event_id.?);
            try std.testing.expectEqualStrings("Run outside workspace", request.display_reason.?);
        },
        else => return error.TestExpectedApprovalRequest,
    }

    var end_event = try client.nextEvent(wait_ms);
    defer client_mod.freeEvent(allocator, &end_event);
    switch (end_event.event) {
        .turn_end => |turn| try std.testing.expectEqualStrings("completed", turn.kind),
        else => return error.TestExpectedTurnEnd,
    }
}
