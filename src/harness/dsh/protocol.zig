//! dsh Remote API wire protocol: pure parsing and frame construction.
//!
//! Ownership: every non-optional string slice returned in a parsed value is
//! allocated with the caller-supplied allocator and must be freed by the
//! caller. `parseBootUrl` is the exception: it returns a slice of its input.
//!
//! No IO happens here; the client layer owns HTTP/WebSocket sockets.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

// ---------------------------------------------------------------------------
// Boot / owner cookie
// ---------------------------------------------------------------------------

/// Extract the launch URL from dsh stdout (`dsh web: http://127.0.0.1:<port>/?token=<token>`).
/// Returns a slice of `stdout` or null when no token-bearing URL is present.
pub fn parseBootUrl(stdout: []const u8) ?[]const u8 {
    const marker = "dsh web: ";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, stdout, from, marker)) |pos| {
        var start = pos + marker.len;
        while (start < stdout.len and (stdout[start] == ' ' or stdout[start] == '\t')) start += 1;
        if (std.mem.startsWith(u8, stdout[start..], "http://") or
            std.mem.startsWith(u8, stdout[start..], "https://"))
        {
            var end = start;
            while (end < stdout.len and !isUrlTerminator(stdout[end])) end += 1;
            const candidate = stdout[start..end];
            if (std.mem.indexOf(u8, candidate, "token=") != null) return candidate;
        }
        from = pos + marker.len;
    }
    return null;
}

fn isUrlTerminator(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', 0x1b, '"', '\'' => true,
        else => false,
    };
}

/// Join `Set-Cookie` values into a Cookie request header, dropping attributes.
pub fn ownerCookieFromSetCookie(allocator: Allocator, values: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (values) |header| {
        const end = std.mem.indexOfScalar(u8, header, ';') orelse header.len;
        const pair = std.mem.trim(u8, header[0..end], " \t\r\n");
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (eq == 0 or isCookieAttribute(pair[0..eq])) continue;
        if (out.items.len > 0) try out.appendSlice(allocator, "; ");
        try out.appendSlice(allocator, pair);
    }
    return try out.toOwnedSlice(allocator);
}

fn isCookieAttribute(name: []const u8) bool {
    const attributes = [_][]const u8{
        "path",        "domain",   "expires",  "max-age",
        "secure",      "httponly", "samesite", "priority",
        "partitioned", "comment",
    };
    for (attributes) |attribute| {
        if (std.ascii.eqlIgnoreCase(name, attribute)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// HTTP RPC envelope
// ---------------------------------------------------------------------------

pub const RpcReply = struct {
    ok: bool,
    value_json: []const u8,
    error_json: ?[]const u8,
};

/// Build the POST /api/<method> body.
pub fn buildRpcBody(
    allocator: Allocator,
    rpc_id: []const u8,
    method: []const u8,
    args_json: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"type\":\"client-request\",\"rpcId\":");
    try appendJsonString(allocator, &out, rpc_id);
    try out.appendSlice(allocator, ",\"method\":");
    try appendJsonString(allocator, &out, method);
    try out.appendSlice(allocator, ",\"payload\":{\"args\":");
    try out.appendSlice(allocator, args_json);
    try out.appendSlice(allocator, "}}");
    return try out.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, text, .{});
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

/// Parse `{"result":{"ok":true,"value":...}}` (or the `ok:false` error form).
pub fn parseRpcBody(allocator: Allocator, body: []const u8) !RpcReply {
    const parsed = std.json.parseFromSlice(Value, allocator, body, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const root = asObject(parsed.value) orelse return error.InvalidRpcReply;
    const result = objectField(root, "result") orelse return error.InvalidRpcReply;
    const ok = switch (result.get("ok") orelse return error.InvalidRpcReply) {
        .bool => |value| value,
        else => return error.InvalidRpcReply,
    };

    const value_json = try stringifyField(allocator, result, "value");
    errdefer allocator.free(value_json);
    if (ok) return .{ .ok = true, .value_json = value_json, .error_json = null };
    return .{
        .ok = false,
        .value_json = value_json,
        .error_json = try stringifyField(allocator, result, "error"),
    };
}

fn stringifyField(allocator: Allocator, object: ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return allocator.dupe(u8, "null");
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

// ---------------------------------------------------------------------------
// Server frames
// ---------------------------------------------------------------------------

pub const Chunk = union(enum) {
    text_delta: struct {
        index: u32,
        text: []const u8,
    },
    tool_call: struct {
        call_id: []const u8,
        name: []const u8,
        arguments_json: []const u8,
    },
    tool_result: struct {
        call_id: []const u8,
        content_json: []const u8,
        is_error: bool,
    },
    /// Raw JSON for chunks this layer does not interpret.
    other: []const u8,
};

pub const ServerEvent = union(enum) {
    assistant_chunk: Chunk,
    turn_end: struct {
        kind: []const u8,
        reason_kind: ?[]const u8,
    },
    approval_request: struct {
        tool_name: []const u8,
        call_id: []const u8,
        display_reason: ?[]const u8,
    },
    /// Known but uninteresting event; holds the event type.
    ignored: []const u8,
    /// Unrecognized frame, kept verbatim so callers can log it losslessly.
    unknown: []const u8,
};

/// Parse one WebSocket `item` (or a bare event / `server-event` envelope).
pub fn parseServerFrame(allocator: Allocator, frame_json: []const u8) !ServerEvent {
    const parsed = std.json.parseFromSlice(Value, allocator, frame_json, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    var value = parsed.value;
    if (asObject(value)) |root| {
        if (stringField(root, "type")) |kind| {
            if (std.mem.eql(u8, kind, "item")) {
                value = root.get("value") orelse return unknownEvent(allocator, frame_json);
            }
        }
    }

    const object = asObject(value) orelse return unknownEvent(allocator, frame_json);
    const kind = stringField(object, "type") orelse return unknownEvent(allocator, frame_json);

    if (std.mem.eql(u8, kind, "event") or std.mem.eql(u8, kind, "server-event")) {
        const event = object.get("event") orelse return unknownEvent(allocator, frame_json);
        return parseEvent(allocator, frame_json, event);
    }
    if (std.mem.eql(u8, kind, "waterfall")) return parseWaterfall(allocator, frame_json, object);
    if (std.mem.eql(u8, kind, "assistant-stream")) return parseAssistant(allocator, frame_json, object);
    return parseEvent(allocator, frame_json, value);
}

fn parseEvent(allocator: Allocator, raw: []const u8, value: Value) !ServerEvent {
    const object = asObject(value) orelse return unknownEvent(allocator, raw);
    const kind = stringField(object, "type") orelse return unknownEvent(allocator, raw);

    if (std.mem.eql(u8, kind, "assistant-stream")) return parseAssistant(allocator, raw, object);
    if (std.mem.eql(u8, kind, "turn/end")) return parseTurnEnd(allocator, raw, object);
    if (std.mem.eql(u8, kind, "tool/call")) return parseToolCall(allocator, object);
    if (std.mem.eql(u8, kind, "tool/result")) return parseToolResult(allocator, object);
    if (std.mem.eql(u8, kind, "approval/request")) return parseApproval(allocator, raw, object);
    if (std.mem.eql(u8, kind, "session/title") or
        std.mem.eql(u8, kind, "agent/inbox/spliced")) return ignoredEvent(allocator, kind);
    return unknownEvent(allocator, raw);
}

fn parseAssistant(allocator: Allocator, raw: []const u8, object: ObjectMap) !ServerEvent {
    const chunk_value: Value = if (object.get("data")) |data|
        data
    else if (object.get("chunk")) |chunk|
        chunk
    else if (object.get("frame")) |frame_value| blk: {
        const frame = asObject(frame_value) orelse return unknownEvent(allocator, raw);
        break :blk frame.get("chunk") orelse frame_value;
    } else Value{ .object = object };

    return .{ .assistant_chunk = try parseChunk(allocator, chunk_value) };
}

fn parseChunk(allocator: Allocator, value: Value) !Chunk {
    const object = asObject(value) orelse return .{ .other = try stringifyValue(allocator, value) };
    const kind = stringField(object, "type") orelse
        return .{ .other = try stringifyValue(allocator, value) };

    if (std.mem.eql(u8, kind, "text-delta")) {
        const text = stringField(object, "text") orelse return error.InvalidFrame;
        const index = std.math.cast(u32, intField(object, "index") orelse 0) orelse
            return error.InvalidFrame;
        return .{ .text_delta = .{ .index = index, .text = try allocator.dupe(u8, text) } };
    }

    if (std.mem.eql(u8, kind, "tool-call") or std.mem.eql(u8, kind, "tool-call-delta")) {
        const call_id = stringField(object, "callId") orelse stringField(object, "id") orelse "";
        const name = stringField(object, "name") orelse stringField(object, "toolName") orelse "";
        const arguments_json = if (object.get("arguments")) |arguments|
            try stringifyValue(allocator, arguments)
        else if (stringField(object, "argumentsDelta")) |delta|
            try std.json.Stringify.valueAlloc(allocator, delta, .{})
        else
            try allocator.dupe(u8, "null");
        errdefer allocator.free(arguments_json);
        const call_id_copy = try allocator.dupe(u8, call_id);
        errdefer allocator.free(call_id_copy);
        return .{ .tool_call = .{
            .call_id = call_id_copy,
            .name = try allocator.dupe(u8, name),
            .arguments_json = arguments_json,
        } };
    }

    if (std.mem.eql(u8, kind, "tool-result")) return toolResultChunk(allocator, object);
    return .{ .other = try stringifyValue(allocator, value) };
}

fn parseToolCall(allocator: Allocator, event: ObjectMap) !ServerEvent {
    const data = objectField(event, "data") orelse event;
    const call_id = stringField(data, "callId") orelse stringField(data, "id") orelse "";
    const name = stringField(data, "name") orelse stringField(data, "toolName") orelse "";
    const arguments_json = if (data.get("arguments")) |arguments|
        try stringifyValue(allocator, arguments)
    else
        try allocator.dupe(u8, "null");
    errdefer allocator.free(arguments_json);
    const call_id_copy = try allocator.dupe(u8, call_id);
    errdefer allocator.free(call_id_copy);
    return .{ .assistant_chunk = .{ .tool_call = .{
        .call_id = call_id_copy,
        .name = try allocator.dupe(u8, name),
        .arguments_json = arguments_json,
    } } };
}

fn parseToolResult(allocator: Allocator, event: ObjectMap) !ServerEvent {
    const data = objectField(event, "data") orelse event;
    return .{ .assistant_chunk = try toolResultChunk(allocator, data) };
}

fn toolResultChunk(allocator: Allocator, data: ObjectMap) !Chunk {
    const message = objectField(data, "message") orelse data;
    const call_id = stringField(message, "callId") orelse
        stringField(data, "callId") orelse stringField(data, "id") orelse "";
    const content = message.get("content") orelse
        data.get("result") orelse data.get("output");
    const content_json = if (content) |value|
        try stringifyValue(allocator, value)
    else
        try allocator.dupe(u8, "null");
    errdefer allocator.free(content_json);
    return .{ .tool_result = .{
        .call_id = try allocator.dupe(u8, call_id),
        .content_json = content_json,
        .is_error = boolField(message, "isError") orelse boolField(data, "isError") orelse false,
    } };
}

fn parseTurnEnd(allocator: Allocator, raw: []const u8, event: ObjectMap) !ServerEvent {
    const data = objectField(event, "data") orelse event;
    const reason_value = data.get("reason") orelse event.get("reason");

    var kind: []const u8 = undefined;
    var reason_kind: ?[]const u8 = null;
    if (reason_value) |value| {
        const reason = asObject(value) orelse return error.InvalidFrame;
        kind = stringField(reason, "kind") orelse return error.InvalidFrame;
        if (reason.get("reason")) |nested_value| {
            if (asObject(nested_value)) |nested| reason_kind = stringField(nested, "kind");
        }
    } else {
        kind = stringField(data, "kind") orelse stringField(event, "kind") orelse
            return unknownEvent(allocator, raw);
    }

    const kind_copy = try allocator.dupe(u8, kind);
    errdefer allocator.free(kind_copy);
    const reason_kind_copy: ?[]const u8 = if (reason_kind) |nested_kind|
        try allocator.dupe(u8, nested_kind)
    else
        null;
    return .{ .turn_end = .{ .kind = kind_copy, .reason_kind = reason_kind_copy } };
}

fn parseWaterfall(allocator: Allocator, raw: []const u8, object: ObjectMap) !ServerEvent {
    const event_name = stringField(object, "event") orelse return unknownEvent(allocator, raw);
    if (!std.mem.eql(u8, event_name, "approval/request")) return unknownEvent(allocator, raw);
    const request = objectField(object, "request") orelse return unknownEvent(allocator, raw);
    return parseApprovalRequest(allocator, raw, request);
}

fn parseApproval(allocator: Allocator, raw: []const u8, event: ObjectMap) !ServerEvent {
    const request = objectField(event, "data") orelse
        objectField(event, "request") orelse event;
    return parseApprovalRequest(allocator, raw, request);
}

fn parseApprovalRequest(allocator: Allocator, raw: []const u8, request: ObjectMap) !ServerEvent {
    const tool_name = stringField(request, "toolName") orelse return unknownEvent(allocator, raw);
    const call_id = stringField(request, "callId") orelse return unknownEvent(allocator, raw);

    const tool_copy = try allocator.dupe(u8, tool_name);
    errdefer allocator.free(tool_copy);
    const call_copy = try allocator.dupe(u8, call_id);
    errdefer allocator.free(call_copy);
    const display_copy: ?[]const u8 = if (stringField(request, "displayReason")) |display|
        try allocator.dupe(u8, display)
    else
        null;
    return .{ .approval_request = .{
        .tool_name = tool_copy,
        .call_id = call_copy,
        .display_reason = display_copy,
    } };
}

fn unknownEvent(allocator: Allocator, raw: []const u8) !ServerEvent {
    return .{ .unknown = try allocator.dupe(u8, raw) };
}

fn ignoredEvent(allocator: Allocator, kind: []const u8) !ServerEvent {
    return .{ .ignored = try allocator.dupe(u8, kind) };
}

// ---------------------------------------------------------------------------
// Follow snapshot
// ---------------------------------------------------------------------------

pub const Snapshot = struct {
    cursor: ?u64,
    record_count: u32,
    /// `reason.kind` of the newest `turn/end` record, if any.
    turn_kind: ?[]const u8,
};

pub fn parseSnapshot(allocator: Allocator, value_json: []const u8) !Snapshot {
    const parsed = std.json.parseFromSlice(Value, allocator, value_json, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    var value = parsed.value;
    if (asObject(value)) |root| {
        if (stringField(root, "type")) |kind| {
            if (std.mem.eql(u8, kind, "item")) {
                value = root.get("value") orelse return error.InvalidSnapshot;
            }
        }
    }

    const object = asObject(value) orelse return error.InvalidSnapshot;
    const records_value = object.get("records") orelse return error.InvalidSnapshot;
    const records = switch (records_value) {
        .array => |array| array,
        else => return error.InvalidSnapshot,
    };

    var cursor: ?u64 = null;
    if (object.get("cursor")) |cursor_value| {
        switch (cursor_value) {
            .integer => |raw| if (raw >= 0) {
                cursor = @intCast(raw);
            },
            else => return error.InvalidSnapshot,
        }
    }

    const record_count = std.math.cast(u32, records.items.len) orelse
        return error.InvalidSnapshot;

    var turn_kind: ?[]const u8 = null;
    var index = records.items.len;
    while (index > 0) {
        index -= 1;
        var record_value = records.items[index];
        if (asObject(record_value)) |record| {
            if (stringField(record, "type")) |record_kind| {
                if (std.mem.eql(u8, record_kind, "event")) {
                    record_value = record.get("event") orelse continue;
                }
            }
        }
        const record = asObject(record_value) orelse continue;
        const record_kind = stringField(record, "type") orelse continue;
        if (!std.mem.eql(u8, record_kind, "turn/end")) continue;
        const data = objectField(record, "data") orelse record;
        const reason = objectField(data, "reason") orelse continue;
        const kind = stringField(reason, "kind") orelse continue;
        turn_kind = try allocator.dupe(u8, kind);
        break;
    }

    return .{
        .cursor = cursor,
        .record_count = record_count,
        .turn_kind = turn_kind,
    };
}

// ---------------------------------------------------------------------------
// WebSocket stream frames (shapes verified against the dsh web client)
// ---------------------------------------------------------------------------

/// Open one `session/follow` stream on `/api/remote.mux`.
pub fn buildFollowOpen(
    allocator: Allocator,
    stream_id: []const u8,
    session_id: []const u8,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .type = "open",
        .streamId = stream_id,
        .endpoint = "session/follow",
        .payload = .{ .args = .{ .request = .{
            .address = .{ .kind = "session", .sessionId = session_id },
            .assistantStream = true,
        } } },
    }, .{});
}

/// Open the `$events` stream that carries waterfall requests such as approvals.
pub fn buildEventsOpen(allocator: Allocator, stream_id: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"type\":\"open\",\"streamId\":");
    try appendJsonString(allocator, &out, stream_id);
    try out.appendSlice(allocator, ",\"endpoint\":\"$events\",\"payload\":{\"args\":{}}}");
    return try out.toOwnedSlice(allocator);
}

/// Arguments for the `$events/result` RPC answering a waterfall request.
pub fn buildApprovalResultArgs(
    allocator: Allocator,
    client_id: []const u8,
    event_id: []const u8,
    outcome_value: []const u8,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .clientId = client_id,
        .eventId = event_id,
        .outcome = .{ .kind = "result", .value = outcome_value },
    }, .{});
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

fn asObject(value: Value) ?ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn objectField(object: ObjectMap, key: []const u8) ?ObjectMap {
    const value = object.get(key) orelse return null;
    return asObject(value);
}

fn stringField(object: ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn intField(object: ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn boolField(object: ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn stringifyValue(allocator: Allocator, value: Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn freeChunk(allocator: Allocator, chunk: Chunk) void {
    switch (chunk) {
        .text_delta => |text| allocator.free(text.text),
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
    }
}

fn freeServerEvent(allocator: Allocator, event: ServerEvent) void {
    switch (event) {
        .assistant_chunk => |chunk| freeChunk(allocator, chunk),
        .turn_end => |turn| {
            allocator.free(turn.kind);
            if (turn.reason_kind) |kind| allocator.free(kind);
        },
        .approval_request => |request| {
            allocator.free(request.tool_name);
            allocator.free(request.call_id);
            if (request.display_reason) |reason| allocator.free(reason);
        },
        .ignored => |kind| allocator.free(kind),
        .unknown => |raw| allocator.free(raw),
    }
}

test "parseBootUrl extracts the token URL only" {
    const stdout = "booting\n\x1b[32mdsh web: http://127.0.0.1:4123/?token=test-token\x1b[0m\n";
    const url = parseBootUrl(stdout) orelse return error.TestExpectedUrl;
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:4123/?token=test-token",
        url,
    );

    try std.testing.expectEqual(@as(?[]const u8, null), parseBootUrl("nothing here"));
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        parseBootUrl("dsh web: http://127.0.0.1:4123/without-token\n"),
    );
}

test "ownerCookieFromSetCookie keeps pairs and drops attributes" {
    const allocator = std.testing.allocator;
    const headers = [_][]const u8{
        "dsh_owner=test-cookie; Path=/; HttpOnly; SameSite=Lax",
        "theme=dark; Max-Age=3600",
        "Secure",
        "=malformed",
    };
    const cookie = try ownerCookieFromSetCookie(allocator, &headers);
    defer allocator.free(cookie);
    try std.testing.expectEqualStrings("dsh_owner=test-cookie; theme=dark", cookie);

    const only_attributes = [_][]const u8{ "Path=/", "HttpOnly", "Secure", "=bad" };
    const empty = try ownerCookieFromSetCookie(allocator, &only_attributes);
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "buildRpcBody emits the client-request envelope" {
    const allocator = std.testing.allocator;
    const body = try buildRpcBody(
        allocator,
        "rpc-1",
        "session/create",
        "{\"request\":{\"cwd\":\"/tmp/ws\"}}",
    );
    defer allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"type\":\"client-request\",\"rpcId\":\"rpc-1\",\"method\":\"session/create\"," ++
            "\"payload\":{\"args\":{\"request\":{\"cwd\":\"/tmp/ws\"}}}}",
        body,
    );

    const escaped = try buildRpcBody(allocator, "rpc\"1", "session/cancel", "{}");
    defer allocator.free(escaped);
    var parsed = try std.json.parseFromSlice(Value, allocator, escaped, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("rpc\"1", parsed.value.object.get("rpcId").?.string);
}

test "parseRpcBody reads ok and error replies" {
    const allocator = std.testing.allocator;

    const ok = try parseRpcBody(
        allocator,
        "{\"result\":{\"ok\":true,\"value\":{\"sessionId\":\"session-test\"}}}",
    );
    defer {
        allocator.free(ok.value_json);
        if (ok.error_json) |value| allocator.free(value);
    }
    try std.testing.expect(ok.ok);
    try std.testing.expectEqualStrings("{\"sessionId\":\"session-test\"}", ok.value_json);
    try std.testing.expectEqual(@as(?[]const u8, null), ok.error_json);

    const failed = try parseRpcBody(
        allocator,
        "{\"result\":{\"ok\":false,\"error\":{\"code\":\"bad-request\"}}}",
    );
    defer {
        allocator.free(failed.value_json);
        if (failed.error_json) |value| allocator.free(value);
    }
    try std.testing.expect(!failed.ok);
    try std.testing.expectEqualStrings("{\"code\":\"bad-request\"}", failed.error_json.?);

    try std.testing.expectError(
        error.InvalidRpcReply,
        parseRpcBody(allocator, "{\"nope\":true}"),
    );
    try std.testing.expectError(
        error.InvalidRpcReply,
        parseRpcBody(allocator, "{\"result\":{\"ok\":\"yes\"}}"),
    );
    try std.testing.expectError(error.InvalidJson, parseRpcBody(allocator, "{\"result\":"));
}

test "parseServerFrame handles wrapped text-delta chunks" {
    const allocator = std.testing.allocator;
    const frame =
        "{\"type\":\"item\",\"streamId\":\"f1\",\"value\":{\"type\":\"assistant-stream\"," ++
        "\"frame\":{\"type\":\"chunk\",\"index\":0,\"attemptId\":\"attempt-1\",\"revision\":1," ++
        "\"chunk\":{\"type\":\"text-delta\",\"index\":0,\"text\":\"slow-12 \"}}}}";
    const event = try parseServerFrame(allocator, frame);
    defer freeServerEvent(allocator, event);
    switch (event) {
        .assistant_chunk => |chunk| switch (chunk) {
            .text_delta => |text| {
                try std.testing.expectEqual(@as(u32, 0), text.index);
                try std.testing.expectEqualStrings("slow-12 ", text.text);
            },
            else => return error.TestUnexpectedChunk,
        },
        else => return error.TestUnexpectedEvent,
    }
}

test "parseServerFrame accepts server-event and bare assistant-stream envelopes" {
    const allocator = std.testing.allocator;
    const server_event =
        "{\"type\":\"server-event\",\"sessionId\":\"session-test\",\"event\":{\"type\":\"assistant-stream\"," ++
        "\"data\":{\"type\":\"text-delta\",\"index\":2,\"text\":\"hello\"}}}";
    const first = try parseServerFrame(allocator, server_event);
    defer freeServerEvent(allocator, first);
    switch (first) {
        .assistant_chunk => |chunk| switch (chunk) {
            .text_delta => |text| {
                try std.testing.expectEqual(@as(u32, 2), text.index);
                try std.testing.expectEqualStrings("hello", text.text);
            },
            else => return error.TestUnexpectedChunk,
        },
        else => return error.TestUnexpectedEvent,
    }

    const bare = "{\"type\":\"assistant-stream\",\"data\":{\"type\":\"text-delta\",\"index\":1,\"text\":\"x\"}}";
    const second = try parseServerFrame(allocator, bare);
    defer freeServerEvent(allocator, second);
    switch (second) {
        .assistant_chunk => |chunk| switch (chunk) {
            .text_delta => |text| try std.testing.expectEqualStrings("x", text.text),
            else => return error.TestUnexpectedChunk,
        },
        else => return error.TestUnexpectedEvent,
    }

    const malformed_text = "{\"type\":\"server-event\",\"event\":{\"type\":\"assistant-stream\"," ++
        "\"data\":{\"type\":\"text-delta\",\"index\":0}}}";
    try std.testing.expectError(
        error.InvalidFrame,
        parseServerFrame(allocator, malformed_text),
    );
}

test "parseServerFrame maps tool call and tool result events" {
    const allocator = std.testing.allocator;
    const call =
        "{\"type\":\"item\",\"streamId\":\"f1\",\"value\":{\"type\":\"event\",\"event\":{" ++
        "\"type\":\"tool/call\",\"seq\":12,\"data\":{\"turn\":1,\"step\":1,\"callId\":\"call-1\"," ++
        "\"name\":\"bash\",\"arguments\":{\"command\":\"echo hi\"}}}}}";
    const call_event = try parseServerFrame(allocator, call);
    defer freeServerEvent(allocator, call_event);
    switch (call_event) {
        .assistant_chunk => |chunk| switch (chunk) {
            .tool_call => |tool| {
                try std.testing.expectEqualStrings("call-1", tool.call_id);
                try std.testing.expectEqualStrings("bash", tool.name);
                try std.testing.expectEqualStrings("{\"command\":\"echo hi\"}", tool.arguments_json);
            },
            else => return error.TestUnexpectedChunk,
        },
        else => return error.TestUnexpectedEvent,
    }

    const result =
        "{\"type\":\"event\",\"event\":{\"type\":\"tool/result\",\"seq\":13,\"data\":{" ++
        "\"turn\":1,\"step\":1,\"message\":{\"callId\":\"call-1\"," ++
        "\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"isError\":false}}}}";
    const result_event = try parseServerFrame(allocator, result);
    defer freeServerEvent(allocator, result_event);
    switch (result_event) {
        .assistant_chunk => |chunk| switch (chunk) {
            .tool_result => |tool| {
                try std.testing.expectEqualStrings("call-1", tool.call_id);
                try std.testing.expectStringStartsWith(tool.content_json, "[{\"type\":\"text\"");
                try std.testing.expect(!tool.is_error);
            },
            else => return error.TestUnexpectedChunk,
        },
        else => return error.TestUnexpectedEvent,
    }
}

test "parseServerFrame keeps uninterpreted chunks verbatim" {
    const allocator = std.testing.allocator;
    const frame =
        "{\"type\":\"item\",\"value\":{\"type\":\"assistant-stream\",\"frame\":{\"type\":\"chunk\"," ++
        "\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\"hmm\"}}}}";
    const event = try parseServerFrame(allocator, frame);
    defer freeServerEvent(allocator, event);
    switch (event) {
        .assistant_chunk => |chunk| switch (chunk) {
            .other => |raw| try std.testing.expectEqualStrings(
                "{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\"hmm\"}",
                raw,
            ),
            else => return error.TestUnexpectedChunk,
        },
        else => return error.TestUnexpectedEvent,
    }
}

test "parseServerFrame: turn/end kind and nested abort reason" {
    const allocator = std.testing.allocator;
    const completed =
        "{\"type\":\"item\",\"streamId\":\"f1\",\"value\":{\"type\":\"event\",\"event\":{" ++
        "\"type\":\"turn/end\",\"seq\":33,\"time\":1792516383660,\"data\":{\"turn\":1," ++
        "\"reason\":{\"kind\":\"completed\"}}}}}";
    const completed_event = try parseServerFrame(allocator, completed);
    defer freeServerEvent(allocator, completed_event);
    switch (completed_event) {
        .turn_end => |turn| {
            try std.testing.expectEqualStrings("completed", turn.kind);
            try std.testing.expectEqual(@as(?[]const u8, null), turn.reason_kind);
        },
        else => return error.TestUnexpectedEvent,
    }

    const aborted =
        "{\"type\":\"event\",\"event\":{\"type\":\"turn/end\",\"seq\":40,\"data\":{\"turn\":2," ++
        "\"reason\":{\"kind\":\"aborted\",\"reason\":{\"kind\":\"user\"}}}}}";
    const aborted_event = try parseServerFrame(allocator, aborted);
    defer freeServerEvent(allocator, aborted_event);
    switch (aborted_event) {
        .turn_end => |turn| {
            try std.testing.expectEqualStrings("aborted", turn.kind);
            try std.testing.expectEqualStrings("user", turn.reason_kind.?);
        },
        else => return error.TestUnexpectedEvent,
    }

    const missing_reason =
        "{\"type\":\"event\",\"event\":{\"type\":\"turn/end\",\"data\":{\"turn\":2}}}";
    const unknown = try parseServerFrame(allocator, missing_reason);
    defer freeServerEvent(allocator, unknown);
    try std.testing.expect(unknown == .unknown);
}

test "parseServerFrame maps approval waterfalls" {
    const allocator = std.testing.allocator;
    const frame =
        "{\"type\":\"item\",\"streamId\":\"ev\",\"value\":{\"type\":\"waterfall\"," ++
        "\"event\":\"approval/request\",\"eventId\":\"evt-1\",\"agentId\":\"agent-1\"," ++
        "\"request\":{\"toolName\":\"bash\",\"callId\":\"call-2\"," ++
        "\"reason\":\"needs write\",\"displayReason\":\"Run bash outside workspace\"}}}";
    const event = try parseServerFrame(allocator, frame);
    defer freeServerEvent(allocator, event);
    switch (event) {
        .approval_request => |request| {
            try std.testing.expectEqualStrings("bash", request.tool_name);
            try std.testing.expectEqualStrings("call-2", request.call_id);
            try std.testing.expectEqualStrings("Run bash outside workspace", request.display_reason.?);
        },
        else => return error.TestUnexpectedEvent,
    }

    const other_waterfall =
        "{\"type\":\"item\",\"value\":{\"type\":\"waterfall\",\"event\":\"question/request\"," ++
        "\"request\":{\"prompt\":\"Continue?\"}}}";
    const unknown = try parseServerFrame(allocator, other_waterfall);
    defer freeServerEvent(allocator, unknown);
    try std.testing.expect(unknown == .unknown);
}

test "parseServerFrame ignores bookkeeping events and preserves unknown frames" {
    const allocator = std.testing.allocator;
    const title =
        "{\"type\":\"item\",\"value\":{\"type\":\"event\",\"event\":{" ++
        "\"type\":\"session/title\",\"data\":{\"title\":\"Test\"}}}}";
    const title_event = try parseServerFrame(allocator, title);
    defer freeServerEvent(allocator, title_event);
    switch (title_event) {
        .ignored => |kind| try std.testing.expectEqualStrings("session/title", kind),
        else => return error.TestUnexpectedEvent,
    }

    const spliced =
        "{\"type\":\"item\",\"value\":{\"type\":\"event\",\"event\":{" ++
        "\"type\":\"agent/inbox/spliced\",\"data\":{}}}}";
    const spliced_event = try parseServerFrame(allocator, spliced);
    defer freeServerEvent(allocator, spliced_event);
    switch (spliced_event) {
        .ignored => |kind| try std.testing.expectEqualStrings("agent/inbox/spliced", kind),
        else => return error.TestUnexpectedEvent,
    }

    const future =
        "{\"type\":\"item\",\"value\":{\"type\":\"event\",\"event\":{" ++
        "\"type\":\"future/event\",\"seq\":99,\"data\":{\"keep\":true}}}}";
    const future_event = try parseServerFrame(allocator, future);
    defer freeServerEvent(allocator, future_event);
    switch (future_event) {
        .unknown => |raw| {
            try std.testing.expect(std.mem.indexOf(u8, raw, "future/event") != null);
            try std.testing.expect(std.mem.indexOf(u8, raw, "\"keep\":true") != null);
        },
        else => return error.TestUnexpectedEvent,
    }

    try std.testing.expectError(error.InvalidJson, parseServerFrame(allocator, "{\"type\":"));
}

test "parseSnapshot reads cursor, record count and turn state" {
    const allocator = std.testing.allocator;
    const snapshot =
        "{\"type\":\"snapshot\",\"header\":{\"id\":\"session-test\"},\"cursor\":60," ++
        "\"records\":[" ++
        "{\"type\":\"event\",\"event\":{\"type\":\"turn/end\",\"data\":{\"turn\":4," ++
        "\"reason\":{\"kind\":\"completed\"}}}}," ++
        "{\"type\":\"event\",\"event\":{\"type\":\"assistant/message\",\"data\":{}}}" ++
        "],\"hasMore\":false,\"projections\":{\"asOfSeq\":60,\"values\":{}}}";
    const parsed = try parseSnapshot(allocator, snapshot);
    defer if (parsed.turn_kind) |kind| allocator.free(kind);
    try std.testing.expectEqual(@as(?u64, 60), parsed.cursor);
    try std.testing.expectEqual(@as(u32, 2), parsed.record_count);
    try std.testing.expectEqualStrings("completed", parsed.turn_kind.?);

    const kind_form =
        "{\"kind\":\"snapshot\",\"cursor\":5,\"records\":[]}";
    const empty = try parseSnapshot(allocator, kind_form);
    try std.testing.expectEqual(@as(?u64, 5), empty.cursor);
    try std.testing.expectEqual(@as(u32, 0), empty.record_count);
    try std.testing.expectEqual(@as(?[]const u8, null), empty.turn_kind);

    try std.testing.expectError(error.InvalidSnapshot, parseSnapshot(allocator, "{}"));
    try std.testing.expectError(error.InvalidJson, parseSnapshot(allocator, "{\"records\":"));
}

test "WS stream frame builders match the web client wire shapes" {
    const allocator = std.testing.allocator;

    const follow = try buildFollowOpen(allocator, "f1", "session-test");
    defer allocator.free(follow);
    try std.testing.expectEqualStrings(
        "{\"type\":\"open\",\"streamId\":\"f1\",\"endpoint\":\"session/follow\",\"payload\":{" ++
            "\"args\":{\"request\":{\"address\":{\"kind\":\"session\",\"sessionId\":\"session-test\"}," ++
            "\"assistantStream\":true}}}}",
        follow,
    );

    const events = try buildEventsOpen(allocator, "ev");
    defer allocator.free(events);
    try std.testing.expectEqualStrings(
        "{\"type\":\"open\",\"streamId\":\"ev\",\"endpoint\":\"$events\",\"payload\":{\"args\":{}}}",
        events,
    );

    const approval = try buildApprovalResultArgs(allocator, "client-1", "evt-1", "allowed-once");
    defer allocator.free(approval);
    try std.testing.expectEqualStrings(
        "{\"clientId\":\"client-1\",\"eventId\":\"evt-1\",\"outcome\":{\"kind\":\"result\"," ++
            "\"value\":\"allowed-once\"}}",
        approval,
    );
}
