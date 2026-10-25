//! Crash repair for a persisted v4 log: close an open tail turn.
//!
//! Mirrors `packages/core/session/src/repair.ts` of dsh 0.2.1-rc.2. A writer
//! killed mid-turn leaves `turn/start` without `turn/end`, possibly with an
//! assistant tool call that never received a `tool/result`. The next reader
//! cannot invent the missing work, but it can close the step and turn and
//! answer the dangling calls with cause-tagged error results, so the resumed
//! transcript is balanced and later requests never replay a dangling call.
//!
//! Everything returned is owned by the caller's allocator; the scan itself
//! takes short-lived views of `events`.

const std = @import("std");
const surface = @import("surface.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// `ToolOutcomeUnknownError` code: the call was durably started.
pub const tool_outcome_unknown = "TOOL_OUTCOME_UNKNOWN";
/// `ToolNotStartedError` code: the assistant asked, no call record followed.
pub const tool_not_started = "TOOL_NOT_STARTED";

/// Model-visible wording, verbatim from dsh repair.ts.
const outcome_unknown_text =
    "The tool call was interrupted after it was recorded, but no result was durably recorded. " ++
    "Its outcome is unknown. Decide whether to retry from the tool semantics: retry only if " ++
    "the operation is read-only or idempotent; if it may have side effects, first verify " ++
    "external state or ask the user. Do not retry blindly.";
const not_started_text =
    "The tool call was interrupted before the Harness recorded it as started. " ++
    "Retry it if it is still needed.";

const Pending = struct {
    call_id: []const u8,
    turn: u64,
    step: u64,
    call_seq: ?u64 = null,
};

/// Synthetic events that balance a log whose tail turn is still open, in
/// append order: one error `tool/result` per unanswered call, then `step/end`
/// (when a step was open) and `turn/end {kind:"interrupted"}`. Empty when the
/// log is balanced. Sequences continue the log; every closer reuses the last
/// real event's timestamp.
pub fn openTurnClosers(allocator: Allocator, events: []const types.Event) ![]types.Event {
    if (events.len == 0) return &.{};

    var pending: std.ArrayListUnmanaged(Pending) = .empty;
    defer pending.deinit(allocator);
    var open_turn: ?u64 = null;
    var open_step: ?u64 = null;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    for (events) |event| {
        _ = scratch.reset(.retain_capacity);
        if (std.mem.eql(u8, event.event_type, "turn/start")) {
            pending.clearRetainingCapacity();
            open_step = null;
            open_turn = try numberField(event.data, "turn");
        } else if (std.mem.eql(u8, event.event_type, "turn/end")) {
            pending.clearRetainingCapacity();
            open_step = null;
            open_turn = null;
        } else if (std.mem.eql(u8, event.event_type, "step/start")) {
            open_step = try numberField(event.data, "step");
        } else if (std.mem.eql(u8, event.event_type, "step/end")) {
            pending.clearRetainingCapacity();
            open_step = null;
        } else if (std.mem.eql(u8, event.event_type, "assistant/message")) {
            const message = try surface.messageFromEvent(scratch.allocator(), event);
            const turn = (try numberField(event.data, "turn")) orelse 0;
            const step = (try numberField(event.data, "step")) orelse 0;
            for (message.content) |block| switch (block) {
                .tool_call => |call| try addPending(allocator, &pending, call.id, turn, step),
                else => {},
            };
        } else if (std.mem.eql(u8, event.event_type, "tool/call")) {
            const call_id = try stringField(event.data, "callId");
            for (pending.items) |*entry| {
                if (std.mem.eql(u8, entry.call_id, call_id)) entry.call_seq = event.seq;
            }
        } else if (std.mem.eql(u8, event.event_type, "tool/result")) {
            // Only an appended result settles the call; a replacement is a
            // rewrite, not the outcome the crashed step awaited.
            const appended = if (event.surface_op) |op| switch (op) {
                .append => true,
                else => false,
            } else false;
            if (!appended) continue;
            const message = try surface.messageFromEvent(scratch.allocator(), event);
            const call_id = switch (message.source) {
                .tool => |tool| tool.call_id,
                else => continue,
            };
            const turn = (try numberField(event.data, "turn")) orelse 0;
            const step = (try numberField(event.data, "step")) orelse 0;
            for (pending.items, 0..) |entry, index| {
                if (!std.mem.eql(u8, entry.call_id, call_id)) continue;
                if (entry.turn != turn or entry.step != step) continue;
                _ = pending.orderedRemove(index);
                break;
            }
        }
    }

    const turn = open_turn orelse return &.{};
    const last = events[events.len - 1];
    var out: std.ArrayListUnmanaged(types.Event) = .empty;
    errdefer out.deinit(allocator);

    var seq = last.seq + 1;
    for (pending.items) |entry| {
        const started = entry.call_seq != null;
        const message_id = try std.fmt.allocPrint(
            allocator,
            "interrupted-tool-result-{s}-{d}",
            .{ entry.call_id, seq },
        );
        const data = try resultData(allocator, entry, message_id, started);
        const source_seqs = if (entry.call_seq) |call_seq| blk: {
            const seqs = try allocator.alloc(u64, 1);
            seqs[0] = call_seq;
            break :blk seqs;
        } else null;
        try out.append(allocator, .{
            .event_type = "tool/result",
            .seq = seq,
            .time_ms = last.time_ms,
            .data = data,
            .surface_op = .append,
            .source_event_seqs = source_seqs,
        });
        seq += 1;
    }

    if (open_step) |step| {
        var data: std.json.ObjectMap = .empty;
        try data.put(allocator, "turn", .{ .integer = @intCast(turn) });
        try data.put(allocator, "step", .{ .integer = @intCast(step) });
        try out.append(allocator, .{
            .event_type = "step/end",
            .seq = seq,
            .time_ms = last.time_ms,
            .data = .{ .object = data },
        });
        seq += 1;
    }

    var end_data: std.json.ObjectMap = .empty;
    try end_data.put(allocator, "turn", .{ .integer = @intCast(turn) });
    var reason: std.json.ObjectMap = .empty;
    try reason.put(allocator, "kind", .{ .string = "interrupted" });
    try end_data.put(allocator, "reason", .{ .object = reason });
    try out.append(allocator, .{
        .event_type = "turn/end",
        .seq = seq,
        .time_ms = last.time_ms,
        .data = .{ .object = end_data },
    });
    return out.toOwnedSlice(allocator);
}

fn addPending(
    allocator: Allocator,
    pending: *std.ArrayListUnmanaged(Pending),
    call_id: []const u8,
    turn: u64,
    step: u64,
) !void {
    for (pending.items) |*entry| {
        if (std.mem.eql(u8, entry.call_id, call_id)) {
            entry.turn = turn;
            entry.step = step;
            entry.call_seq = null;
            return;
        }
    }
    try pending.append(allocator, .{ .call_id = call_id, .turn = turn, .step = step });
}

fn resultData(allocator: Allocator, entry: Pending, message_id: []const u8, started: bool) !Value {
    var content: std.json.ObjectMap = .empty;
    try content.put(allocator, "type", .{ .string = "text" });
    try content.put(allocator, "text", .{ .string = if (started) outcome_unknown_text else not_started_text });
    const blocks = try allocator.alloc(Value, 1);
    blocks[0] = .{ .object = content };
    var content_array = std.json.Array.init(allocator);
    try content_array.ensureTotalCapacity(blocks.len);
    for (blocks) |block| content_array.appendAssumeCapacity(block);

    var source: std.json.ObjectMap = .empty;
    try source.put(allocator, "kind", .{ .string = "tool" });
    try source.put(allocator, "callId", .{ .string = entry.call_id });

    var message: std.json.ObjectMap = .empty;
    try message.put(allocator, "id", .{ .string = message_id });
    try message.put(allocator, "role", .{ .string = "tool" });
    try message.put(allocator, "toolCallId", .{ .string = entry.call_id });
    try message.put(allocator, "isError", .{ .bool = true });
    try message.put(allocator, "source", .{ .object = source });
    try message.put(allocator, "content", .{ .array = content_array });

    var error_object: std.json.ObjectMap = .empty;
    try error_object.put(allocator, "name", .{ .string = if (started) "ToolOutcomeUnknownError" else "ToolNotStartedError" });
    try error_object.put(allocator, "code", .{ .string = if (started) tool_outcome_unknown else tool_not_started });

    var data: std.json.ObjectMap = .empty;
    try data.put(allocator, "turn", .{ .integer = @intCast(entry.turn) });
    try data.put(allocator, "step", .{ .integer = @intCast(entry.step) });
    try data.put(allocator, "message", .{ .object = message });
    try data.put(allocator, "error", .{ .object = error_object });
    return .{ .object = data };
}

fn numberField(value: Value, key: []const u8) !?u64 {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const field = object.get(key) orelse return null;
    if (field != .integer or field.integer < 0) return null;
    return @intCast(field.integer);
}

fn stringField(value: Value, key: []const u8) ![]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidMessage,
    };
    const field = object.get(key) orelse return error.InvalidMessage;
    if (field != .string) return error.InvalidMessage;
    return field.string;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn parseEvent(arena: Allocator, json_text: []const u8) !types.Event {
    const value = try std.json.parseFromSliceLeaky(Value, arena, json_text, .{ .allocate = .alloc_always });
    const object = value.object;
    const event_type = object.get("type").?.string;
    const seq: u64 = @intCast(object.get("seq").?.integer);
    const time_ms: i64 = object.get("time").?.integer;
    var op: ?types.SurfaceOp = null;
    if (object.get("surfaceOp")) |raw| {
        if (raw == .string and std.mem.eql(u8, raw.string, "append")) op = .append;
    }
    return .{
        .event_type = event_type,
        .seq = seq,
        .time_ms = time_ms,
        .data = object.get("data").?,
        .surface_op = op,
    };
}

fn parseEvents(arena: Allocator, text: []const u8) ![]types.Event {
    var out: std.ArrayListUnmanaged(types.Event) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try out.append(arena, try parseEvent(arena, line));
    }
    return out.toOwnedSlice(arena);
}

test "a balanced log needs no closers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = try parseEvents(arena.allocator(),
        \\{"type":"turn/start","seq":0,"time":10,"data":{"turn":1}}
        \\{"type":"step/start","seq":1,"time":11,"data":{"turn":1,"step":1}}
        \\{"type":"turn/end","seq":2,"time":12,"data":{"turn":1,"reason":{"kind":"completed"}}}
    );
    const closers = try openTurnClosers(arena.allocator(), events);
    try testing.expectEqual(@as(usize, 0), closers.len);
}

test "an open step closes before its interrupted turn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = try parseEvents(arena.allocator(),
        \\{"type":"turn/start","seq":5,"time":40,"data":{"turn":2}}
        \\{"type":"step/start","seq":6,"time":41,"data":{"turn":2,"step":3}}
    );
    const closers = try openTurnClosers(arena.allocator(), events);
    try testing.expectEqual(@as(usize, 2), closers.len);
    try testing.expectEqualStrings("step/end", closers[0].event_type);
    try testing.expectEqual(@as(u64, 7), closers[0].seq);
    try testing.expectEqual(@as(i64, 41), closers[0].time_ms);
    try testing.expectEqualStrings("turn/end", closers[1].event_type);
    try testing.expectEqual(@as(u64, 8), closers[1].seq);
    try testing.expectEqual(@as(i64, 41), closers[1].time_ms);
    const reason = closers[1].data.object.get("reason").?.object;
    try testing.expectEqualStrings("interrupted", reason.get("kind").?.string);
}

test "unanswered calls get cause-tagged error results in assistant order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = try parseEvents(arena.allocator(),
        \\{"type":"turn/start","seq":0,"time":10,"data":{"turn":1}}
        \\{"type":"step/start","seq":1,"time":11,"data":{"turn":1,"step":1}}
        \\{"type":"assistant/message","seq":2,"time":12,"surfaceOp":"append","data":{"turn":1,"step":1,"message":{"id":"a1","role":"assistant","source":{"kind":"model","provider":"p","model":"m"},"content":[{"type":"tool-call","id":"call-1","name":"read","arguments":"{}"},{"type":"tool-call","id":"call-2","name":"write","arguments":"{}"}]}}}
        \\{"type":"tool/call","seq":3,"time":13,"data":{"turn":1,"step":1,"callId":"call-1","name":"read","arguments":"{}"}}
    );
    const closers = try openTurnClosers(arena.allocator(), events);
    try testing.expectEqual(@as(usize, 4), closers.len);

    const started = closers[0];
    try testing.expectEqualStrings("tool/result", started.event_type);
    try testing.expectEqual(@as(u64, 4), started.seq);
    try testing.expectEqual(@as(i64, 13), started.time_ms);
    try testing.expectEqual(@as(usize, 1), started.source_event_seqs.?.len);
    try testing.expectEqual(@as(u64, 3), started.source_event_seqs.?[0]);
    try testing.expectEqualStrings(
        "ToolOutcomeUnknownError",
        started.data.object.get("error").?.object.get("name").?.string,
    );
    try testing.expectEqualStrings(
        tool_outcome_unknown,
        started.data.object.get("error").?.object.get("code").?.string,
    );
    try testing.expectEqualStrings(
        outcome_unknown_text,
        started.data.object.get("message").?.object.get("content").?.array.items[0].object.get("text").?.string,
    );

    const not_started = closers[1];
    try testing.expectEqual(@as(u64, 5), not_started.seq);
    try testing.expect(not_started.source_event_seqs == null);
    try testing.expectEqualStrings(
        "ToolNotStartedError",
        not_started.data.object.get("error").?.object.get("name").?.string,
    );
    try testing.expectEqualStrings(
        not_started_text,
        not_started.data.object.get("message").?.object.get("content").?.array.items[0].object.get("text").?.string,
    );

    try testing.expectEqualStrings("step/end", closers[2].event_type);
    try testing.expectEqual(@as(u64, 6), closers[2].seq);
    try testing.expectEqualStrings("turn/end", closers[3].event_type);
    try testing.expectEqual(@as(u64, 7), closers[3].seq);
}

test "a recorded result settles its call; step end discards the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = try parseEvents(arena.allocator(),
        \\{"type":"turn/start","seq":0,"time":10,"data":{"turn":1}}
        \\{"type":"step/start","seq":1,"time":11,"data":{"turn":1,"step":1}}
        \\{"type":"assistant/message","seq":2,"time":12,"surfaceOp":"append","data":{"turn":1,"step":1,"message":{"id":"a1","role":"assistant","source":{"kind":"model","provider":"p","model":"m"},"content":[{"type":"tool-call","id":"call-1","name":"read","arguments":"{}"}]}}}
        \\{"type":"tool/call","seq":3,"time":13,"data":{"turn":1,"step":1,"callId":"call-1","name":"read","arguments":"{}"}}
        \\{"type":"tool/result","seq":4,"time":14,"surfaceOp":"append","data":{"turn":1,"step":1,"message":{"id":"r1","role":"tool","toolCallId":"call-1","source":{"kind":"tool","callId":"call-1"},"content":[{"type":"text","text":"ok"}]}}}
        \\{"type":"step/end","seq":5,"time":15,"data":{"turn":1,"step":1}}
    );
    const closers = try openTurnClosers(arena.allocator(), events);
    try testing.expectEqual(@as(usize, 1), closers.len);
    try testing.expectEqualStrings("turn/end", closers[0].event_type);
    try testing.expectEqual(@as(u64, 6), closers[0].seq);
}
