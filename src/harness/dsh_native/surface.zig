//! Surface fold and message derivation for the dsh-native harness (P0).
//!
//! Mirrors `packages/core/session/src/surface.ts:63-105,120-220` and the
//! `SurfaceOp` vocabulary in `types.ts:440-479` of dsh 0.2.1-rc.2.
//! Covers the append path and replacement fold (compaction checkpoints and the
//! pruner's shadowed nodes).

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Event types that join the model-visible surface (surface.ts:55-61).
pub const surface_event_types = [_][]const u8{
    "system/message",
    "developer/message",
    "user/message",
    "assistant/message",
    "tool/result",
};

pub fn isSurfaceType(event_type: []const u8) bool {
    for (surface_event_types) |candidate| {
        if (std.mem.eql(u8, candidate, event_type)) return true;
    }
    return false;
}

/// One node of the folded surface, in model-visible order.
pub const Node = struct {
    /// Seq of the log event that produced the node.
    seq: u64,
    message: types.Message,
};

pub const Fold = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []Node,

    pub fn deinit(self: *Fold) void {
        self.arena.deinit();
    }
};

/// Fold the surface events of a log, validating surface metadata.
///
/// `events` must stay alive while the returned fold is used: message strings
/// borrow the event payloads.
pub fn fold(allocator: Allocator, events: []const types.Event) !Fold {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    errdefer nodes.deinit(arena_allocator);

    for (events) |event| {
        if (!isSurfaceType(event.event_type)) {
            // Unknown ignorable rows stay opaque and never change the surface.
            if (event.ignorable) continue;
            if (event.surface_op != null or event.source_event_seqs != null) {
                return error.UnexpectedSurfaceMetadata;
            }
            continue;
        }

        if (event.source_event_seqs != null and std.mem.eql(u8, event.event_type, "assistant/message")) {
            return error.InvalidSourceEventSeqs;
        }

        const op = event.surface_op orelse return error.MissingSurfaceOp;
        switch (op) {
            .append => try nodes.append(arena_allocator, .{
                .seq = event.seq,
                .message = try messageFromEvent(arena_allocator, event),
            }),
            .replace => |range| {
                // dsh locates the range in the current surface, not the log
                // (`surface.ts` `replacementRange`), so a replacement may
                // shadow a node an earlier replacement introduced.
                if (range.start_seq >= event.seq or range.end_seq >= event.seq) {
                    return error.InvalidSurfaceRange;
                }
                const start_idx = indexOfNode(nodes.items, 0, range.start_seq) orelse
                    return error.UnknownSurfaceRange;
                const end_idx = indexOfNode(nodes.items, start_idx, range.end_seq) orelse
                    return error.UnknownSurfaceRange;
                // When present, sourceEventSeqs must name every shadowed node
                // (`assertSourceEventReferences`).
                if (event.source_event_seqs) |sources| {
                    for (nodes.items[start_idx .. end_idx + 1]) |node| {
                        if (!containsSeq(sources, node.seq)) return error.InvalidSourceEventSeqs;
                    }
                }
                const replacement: Node = .{
                    .seq = event.seq,
                    .message = try messageFromEvent(arena_allocator, event),
                };
                try nodes.replaceRange(arena_allocator, start_idx, end_idx - start_idx + 1, &.{replacement});
            },
        }
    }

    const node_slice = try nodes.toOwnedSlice(arena_allocator);
    return .{ .arena = arena, .nodes = node_slice };
}

fn indexOfNode(nodes: []const Node, from: usize, seq: u64) ?usize {
    for (nodes[from..], from..) |node, index| {
        if (node.seq == seq) return index;
    }
    return null;
}

fn containsSeq(seqs: []const u64, seq: u64) bool {
    for (seqs) |candidate| {
        if (candidate == seq) return true;
    }
    return false;
}

/// Derive the message a surface event projects.
///
/// `user/message` stores the message in `data`; the other surface events store
/// it in `data.message` (core/session/src/types.ts:289-350).
pub fn messageFromEvent(allocator: Allocator, event: types.Event) !types.Message {
    const data = switch (event.data) {
        .object => |object| object,
        else => return error.InvalidMessage,
    };
    const message_value = if (std.mem.eql(u8, event.event_type, "user/message"))
        event.data
    else
        data.get("message") orelse return error.MissingMessage;
    const message_object = switch (message_value) {
        .object => |object| object,
        else => return error.InvalidMessage,
    };

    const role_name = try requiredString(message_object, "role");
    const role = std.meta.stringToEnum(types.MessageRole, role_name) orelse
        return error.InvalidMessageRole;
    if (!roleMatchesEvent(role, event.event_type)) return error.InvalidMessageRole;

    var message = types.Message{
        .id = try requiredString(message_object, "id"),
        .role = role,
        .content = try parseContent(allocator, message_object.get("content") orelse return error.MissingMessage),
        .source = try parseSource(message_object.get("source") orelse return error.MissingMessage),
    };
    if (message_object.get("toolCallId")) |value| {
        message.tool_call_id = try asString(value);
    }
    if (message_object.get("isError")) |value| {
        if (value != .bool) return error.InvalidMessage;
        message.is_error = value.bool;
    }
    return message;
}

fn roleMatchesEvent(role: types.MessageRole, event_type: []const u8) bool {
    const expected: types.MessageRole = if (std.mem.eql(u8, event_type, "system/message"))
        .system
    else if (std.mem.eql(u8, event_type, "developer/message"))
        .developer
    else if (std.mem.eql(u8, event_type, "user/message"))
        .user
    else if (std.mem.eql(u8, event_type, "assistant/message"))
        .assistant
    else if (std.mem.eql(u8, event_type, "tool/result"))
        .tool
    else
        return false;
    return role == expected;
}

fn parseContent(allocator: Allocator, value: Value) ![]types.ContentBlock {
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidMessage,
    };
    const blocks = try allocator.alloc(types.ContentBlock, items.len);
    for (items, 0..) |item, index| {
        const object = switch (item) {
            .object => |object| object,
            else => return error.InvalidMessage,
        };
        const kind = try requiredString(object, "type");
        if (std.mem.eql(u8, kind, "text")) {
            blocks[index] = .{ .text = try requiredString(object, "text") };
        } else if (std.mem.eql(u8, kind, "reasoning")) {
            blocks[index] = .{ .reasoning = try requiredString(object, "text") };
        } else if (std.mem.eql(u8, kind, "tool-call")) {
            blocks[index] = .{ .tool_call = .{
                .id = try requiredString(object, "id"),
                .name = try requiredString(object, "name"),
                .arguments = try requiredString(object, "arguments"),
            } };
        } else {
            // image / file / tool-addition / tool-removal and plugin blocks.
            blocks[index] = .{ .raw = item };
        }
    }
    return blocks;
}

fn parseSource(value: Value) !types.MessageSource {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidMessage,
    };
    const kind = try requiredString(object, "kind");
    if (std.mem.eql(u8, kind, "user")) return .user;
    if (std.mem.eql(u8, kind, "system-prompt")) return .system_prompt;
    if (std.mem.eql(u8, kind, "model")) return .{ .model = .{
        .provider = try requiredString(object, "provider"),
        .model = try requiredString(object, "model"),
    } };
    if (std.mem.eql(u8, kind, "tool")) return .{ .tool = .{
        .call_id = try requiredString(object, "callId"),
    } };
    return .{ .other = value };
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidMessage;
    return asString(value);
}

fn asString(value: Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.InvalidMessage,
    };
}

test "surface fold appends message events and derives messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const events = try allocator.alloc(types.Event, 3);
    events[0] = .{
        .event_type = "system/message",
        .seq = 0,
        .time_ms = 0,
        .data = try std.json.parseFromSliceLeaky(
            Value,
            allocator,
            "{\"turn\":1,\"step\":1,\"message\":{\"role\":\"system\",\"content\":[{\"type\":\"text\",\"text\":\"sys\"}],\"source\":{\"kind\":\"system-prompt\"},\"id\":\"m1\"}}",
            .{ .allocate = .alloc_always },
        ),
        .surface_op = .append,
    };
    events[1] = .{
        .event_type = "user/message",
        .seq = 1,
        .time_ms = 0,
        .data = try std.json.parseFromSliceLeaky(
            Value,
            allocator,
            "{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}],\"source\":{\"kind\":\"user\"},\"role\":\"user\",\"id\":\"m2\"}",
            .{ .allocate = .alloc_always },
        ),
        .surface_op = .append,
    };
    events[2] = .{
        .event_type = "turn/start",
        .seq = 2,
        .time_ms = 0,
        .data = try std.json.parseFromSliceLeaky(Value, allocator, "{\"turn\":1}", .{ .allocate = .alloc_always }),
    };

    var folded = try fold(std.testing.allocator, events);
    defer folded.deinit();

    try std.testing.expectEqual(@as(usize, 2), folded.nodes.len);
    try std.testing.expectEqual(@as(u64, 0), folded.nodes[0].seq);
    try std.testing.expectEqual(types.MessageRole.system, folded.nodes[0].message.role);
    try std.testing.expectEqualStrings("sys", folded.nodes[0].message.content[0].text);
    try std.testing.expectEqualStrings("hello", folded.nodes[1].message.content[0].text);

    events[0].surface_op = null;
    try std.testing.expectError(error.MissingSurfaceOp, fold(std.testing.allocator, events));

    events[0].surface_op = .{ .replace = .{ .start_seq = 0, .end_seq = 0 } };
    try std.testing.expectError(error.InvalidSurfaceRange, fold(std.testing.allocator, events));

    events[0].surface_op = .append;
    events[2].surface_op = .append;
    try std.testing.expectError(error.UnexpectedSurfaceMetadata, fold(std.testing.allocator, events));
}

test "surface fold replaces shadowed nodes, including earlier replacements" {
    // Regression: a log holding a compaction checkpoint or a pruner
    // replacement aborted the fold with error.UnsupportedSurfaceOp, so a
    // session that had compacted could not be reopened after a restart.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const events = try allocator.alloc(types.Event, 5);
    events[0] = .{
        .event_type = "system/message",
        .seq = 0,
        .time_ms = 0,
        .data = try std.json.parseFromSliceLeaky(
            Value,
            allocator,
            "{\"turn\":1,\"step\":1,\"message\":{\"role\":\"system\",\"content\":[{\"type\":\"text\",\"text\":\"sys\"}],\"source\":{\"kind\":\"system-prompt\"},\"id\":\"m1\"}}",
            .{ .allocate = .alloc_always },
        ),
        .surface_op = .append,
    };
    // 64KB+ input: testing.allocator fails the test if the fold leaks it.
    const big = try allocator.alloc(u8, 70_000);
    @memset(big, 'a');
    const big_json = try std.fmt.allocPrint(
        allocator,
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"source\":{{\"kind\":\"user\"}},\"role\":\"user\",\"id\":\"m2\"}}",
        .{big},
    );
    events[1] = .{
        .event_type = "user/message",
        .seq = 1,
        .time_ms = 0,
        .data = try std.json.parseFromSliceLeaky(Value, allocator, big_json, .{ .allocate = .alloc_always }),
        .surface_op = .append,
    };
    // A checkpoint replaces the user message in place.
    events[2] = .{
        .event_type = "user/message",
        .seq = 2,
        .time_ms = 0,
        .data = try std.json.parseFromSliceLeaky(
            Value,
            allocator,
            "{\"content\":[{\"type\":\"text\",\"text\":\"checkpoint\"}],\"source\":{\"kind\":\"compact-checkpoint\"},\"role\":\"user\",\"id\":\"m3\"}",
            .{ .allocate = .alloc_always },
        ),
        .surface_op = .{ .replace = .{ .start_seq = 1, .end_seq = 1 } },
        .source_event_seqs = try allocator.dupe(u64, &.{1}),
    };
    // A later replacement shadows the checkpoint by its log seq.
    events[3] = .{
        .event_type = "user/message",
        .seq = 3,
        .time_ms = 0,
        .data = try std.json.parseFromSliceLeaky(
            Value,
            allocator,
            "{\"content\":[{\"type\":\"text\",\"text\":\"next\"}],\"source\":{\"kind\":\"user\"},\"role\":\"user\",\"id\":\"m4\"}",
            .{ .allocate = .alloc_always },
        ),
        .surface_op = .{ .replace = .{ .start_seq = 2, .end_seq = 2 } },
        .source_event_seqs = try allocator.dupe(u64, &.{2}),
    };
    // Seq 2 was shadowed by the later replacement, so it is no longer a
    // surface position.
    events[4] = .{
        .event_type = "user/message",
        .seq = 4,
        .time_ms = 0,
        .data = try std.json.parseFromSliceLeaky(
            Value,
            allocator,
            "{\"content\":[{\"type\":\"text\",\"text\":\"missing\"}],\"source\":{\"kind\":\"user\"},\"role\":\"user\",\"id\":\"m5\"}",
            .{ .allocate = .alloc_always },
        ),
        .surface_op = .{ .replace = .{ .start_seq = 2, .end_seq = 2 } },
    };

    var folded = try fold(std.testing.allocator, events[0..4]);
    defer folded.deinit();
    try std.testing.expectEqual(@as(usize, 2), folded.nodes.len);
    try std.testing.expectEqual(@as(u64, 0), folded.nodes[0].seq);
    try std.testing.expectEqual(@as(u64, 3), folded.nodes[1].seq);
    try std.testing.expectEqualStrings("sys", folded.nodes[0].message.content[0].text);
    try std.testing.expectEqualStrings("next", folded.nodes[1].message.content[0].text);

    try std.testing.expectError(error.UnknownSurfaceRange, fold(std.testing.allocator, events));
}
