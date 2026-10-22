//! Recorded model provider for dsh-native harness tests (P0 prototype).
//!
//! A fixture supplies the packed assistant stream for each model call
//! (`test/fixtures/dsh_native/plain-turn/replay.json`). The provider returns
//! that stream verbatim, including its terminal `finish` chunk; it never
//! synthesizes chunks. The driver writes the returned records into
//! `assistant/message.data.stream`.
//!
//! The provider also records each request so a test can compare what the
//! harness would have sent with the fixture's expected surface.

const std = @import("std");
const stream = @import("stream.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// One model call as seen by the provider.
pub const Request = struct {
    provider: []const u8,
    model: []const u8,
    /// Borrowed from the caller's surface fold; keep the fold alive while
    /// inspecting `recordedRequests()`.
    messages: []const types.Message,
};

const ReplayFile = struct {
    calls: []const Call = &.{},

    const Call = struct {
        index: u64 = 0,
        stream: []const Value = &.{},
    };
};

pub const ReplayProvider = struct {
    arena: std.heap.ArenaAllocator,
    calls: []const ReplayFile.Call,
    next_call: usize = 0,
    requests: std.ArrayListUnmanaged(Request) = .empty,
    /// Expanded events of the call currently being replayed by the loop.
    events: []const stream.Event = &.{},
    next_event: usize = 0,

    /// Parse a replay script. Calls must be numbered 1..N with non-empty
    /// streams; the fixture's first model call is call 1.
    pub fn initFromJson(allocator: Allocator, bytes: []const u8) !ReplayProvider {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const parsed = try std.json.parseFromSliceLeaky(ReplayFile, arena.allocator(), bytes, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        if (parsed.calls.len == 0) return error.InvalidReplay;
        for (parsed.calls, 0..) |call, index| {
            if (call.index != index + 1) return error.InvalidReplay;
            if (call.stream.len == 0) return error.InvalidReplay;
        }

        return .{ .arena = arena, .calls = parsed.calls };
    }

    pub fn deinit(self: *ReplayProvider) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Return the recorded packed stream for the next model call.
    pub fn complete(self: *ReplayProvider, request: Request) ![]const Value {
        if (self.next_call >= self.calls.len) return error.ReplayExhausted;
        try self.requests.append(self.arena.allocator(), request);
        const recorded = self.calls[self.next_call].stream;
        self.next_call += 1;
        return recorded;
    }

    pub fn recordedRequests(self: *const ReplayProvider) []const Request {
        return self.requests.items;
    }

    /// Prepare the next recorded call for the loop's provider callbacks.
    pub fn startCall(self: *ReplayProvider, request: Request) !void {
        if (self.next_call >= self.calls.len) return error.ReplayExhausted;
        try self.requests.append(self.arena.allocator(), request);
        const call = self.calls[self.next_call];
        self.next_call += 1;
        const allocator = self.arena.allocator();
        const recorded = call.stream;
        const events = try allocator.alloc(stream.Event, recorded.len);
        for (recorded, 0..) |record, index| {
            events[index] = try eventFromRecord(allocator, record);
        }
        self.events = events;
        self.next_event = 0;
    }

    /// Next expanded event of the active call; `null` after the recorded end.
    pub fn nextEvent(self: *ReplayProvider) !?stream.Event {
        if (self.next_event >= self.events.len) return null;
        const event = self.events[self.next_event];
        self.next_event += 1;
        return event;
    }

    pub fn endCall(self: *ReplayProvider) void {
        self.events = &.{};
        self.next_event = 0;
    }

    pub fn callCount(self: *const ReplayProvider) usize {
        return self.calls.len;
    }
};

fn eventFromRecord(allocator: Allocator, record: Value) !stream.Event {
    const object = switch (record) {
        .object => |object| object,
        else => return error.InvalidReplay,
    };
    const record_type = try stringField(object, "type");
    if (std.mem.eql(u8, record_type, "text-chunks") or
        std.mem.eql(u8, record_type, "reasoning-chunks"))
    {
        const run = stream.TextRun{
            .index = try indexField(object, "index"),
            .time0 = try intField(object, "time0"),
            .dt = try i64ArrayField(allocator, object, "dt"),
            .texts = try stringArrayField(allocator, object, "texts"),
        };
        return .{ .record = if (std.mem.eql(u8, record_type, "text-chunks"))
            .{ .text_chunks = run }
        else
            .{ .reasoning_chunks = run } };
    }
    if (std.mem.eql(u8, record_type, "tool-call-chunks")) {
        return .{ .record = .{ .tool_call_chunks = .{
            .index = try indexField(object, "index"),
            .time0 = try intField(object, "time0"),
            .dt = try i64ArrayField(allocator, object, "dt"),
            .id = try stringField(object, "id"),
            .name = try optionalStringField(object, "name"),
            .args = try stringArrayField(allocator, object, "args"),
        } } };
    }
    if (!std.mem.eql(u8, record_type, "chunk")) return error.InvalidReplay;

    const time = try intField(object, "time");
    const chunk_object = try objectField(object, "chunk");
    if (std.mem.eql(u8, try stringField(chunk_object, "type"), "finish")) {
        const reason = try objectField(chunk_object, "reason");
        return .{ .done = .{ .finish = stream.finishFromProvider(try stringField(reason, "kind")) } };
    }
    return .{ .record = .{ .chunk = .{
        .time = time,
        .chunk = try chunkFromObject(chunk_object),
    } } };
}

fn chunkFromObject(object: std.json.ObjectMap) !stream.Chunk {
    const chunk_type = try stringField(object, "type");
    if (std.mem.eql(u8, chunk_type, "text-delta")) {
        return .{ .text_delta = .{
            .index = try indexField(object, "index"),
            .text = try stringField(object, "text"),
        } };
    }
    if (std.mem.eql(u8, chunk_type, "reasoning-delta")) {
        return .{ .reasoning_delta = .{
            .index = try indexField(object, "index"),
            .text = try stringField(object, "text"),
        } };
    }
    if (std.mem.eql(u8, chunk_type, "tool-call-delta")) {
        return .{ .tool_call_delta = .{
            .index = try indexField(object, "index"),
            .id = try stringField(object, "id"),
            .name = try optionalStringField(object, "name"),
            .arguments_delta = try stringField(object, "argumentsDelta"),
        } };
    }
    if (std.mem.eql(u8, chunk_type, "block-start")) {
        return .{ .block_start = .{
            .index = try indexField(object, "index"),
            .block_type = try stringField(object, "blockType"),
        } };
    }
    if (std.mem.eql(u8, chunk_type, "block-end")) {
        return .{ .block_end = .{
            .index = try indexField(object, "index"),
            .block = try contentBlock(.{ .object = try objectField(object, "block") }),
        } };
    }
    if (std.mem.eql(u8, chunk_type, "usage")) {
        const usage = try objectField(object, "usage");
        return .{ .usage = .{
            .input_tokens = @intCast(try intField(usage, "inputTokens")),
            .output_tokens = @intCast(try intField(usage, "outputTokens")),
            .total_tokens = if (try optionalIntField(usage, "totalTokens")) |value| @intCast(value) else null,
        } };
    }
    return error.InvalidReplay;
}

fn contentBlock(value: Value) !types.ContentBlock {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidReplay,
    };
    const block_type = try stringField(object, "type");
    if (std.mem.eql(u8, block_type, "text")) return .{ .text = try stringField(object, "text") };
    if (std.mem.eql(u8, block_type, "reasoning")) return .{ .reasoning = try stringField(object, "text") };
    if (std.mem.eql(u8, block_type, "tool-call")) {
        return .{ .tool_call = .{
            .id = try stringField(object, "id"),
            .name = try stringField(object, "name"),
            .arguments = try stringField(object, "arguments"),
        } };
    }
    return .{ .raw = value };
}

fn objectField(object: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return switch (object.get(key) orelse return error.InvalidReplay) {
        .object => |value| value,
        else => error.InvalidReplay,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (object.get(key) orelse return error.InvalidReplay) {
        .string => |value| value,
        else => error.InvalidReplay,
    };
}

fn optionalStringField(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        .null => null,
        else => error.InvalidReplay,
    };
}

fn intField(object: std.json.ObjectMap, key: []const u8) !i64 {
    return switch (object.get(key) orelse return error.InvalidReplay) {
        .integer => |value| value,
        else => error.InvalidReplay,
    };
}

fn optionalIntField(object: std.json.ObjectMap, key: []const u8) !?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .null => null,
        else => error.InvalidReplay,
    };
}

fn indexField(object: std.json.ObjectMap, key: []const u8) !u32 {
    return @intCast(try intField(object, key));
}

fn i64ArrayField(allocator: Allocator, object: std.json.ObjectMap, key: []const u8) ![]i64 {
    const items = switch (object.get(key) orelse return error.InvalidReplay) {
        .array => |array| array.items,
        else => return error.InvalidReplay,
    };
    const out = try allocator.alloc(i64, items.len);
    for (items, 0..) |item, index| {
        out[index] = switch (item) {
            .integer => |value| value,
            else => return error.InvalidReplay,
        };
    }
    return out;
}

fn stringArrayField(allocator: Allocator, object: std.json.ObjectMap, key: []const u8) ![][]const u8 {
    const items = switch (object.get(key) orelse return error.InvalidReplay) {
        .array => |array| array.items,
        else => return error.InvalidReplay,
    };
    const out = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, index| {
        out[index] = switch (item) {
            .string => |value| value,
            else => return error.InvalidReplay,
        };
    }
    return out;
}

test "replay provider returns recorded streams and records requests" {
    var provider = try ReplayProvider.initFromJson(
        std.testing.allocator,
        \\{"calls":[{"index":1,"stream":[{"type":"text-chunks","time0":0,"index":0,"dt":[],"texts":["hi"]}]}]}
        ,
    );
    defer provider.deinit();

    const request = Request{ .provider = "fake", .model = "fake", .messages = &.{} };
    const recorded = try provider.complete(request);
    try std.testing.expectEqual(@as(usize, 1), recorded.len);
    try std.testing.expectEqualStrings("text-chunks", recorded[0].object.get("type").?.string);

    const requests = provider.recordedRequests();
    try std.testing.expectEqual(@as(usize, 1), requests.len);
    try std.testing.expectEqualStrings("fake", requests[0].provider);

    try std.testing.expectError(error.ReplayExhausted, provider.complete(request));
    try std.testing.expectError(error.InvalidReplay, ReplayProvider.initFromJson(
        std.testing.allocator,
        \\{"calls":[{"index":2,"stream":[{"type":"chunk"}]}]}
        ,
    ));
}
