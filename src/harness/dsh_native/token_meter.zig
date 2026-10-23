//! Fixed-density token estimate plus provider-usage anchor for compaction
//! pressure checks (design B28).
//!
//! Mirrors dsh 0.2.1-rc.2 `packages/llm/token-meter/src/estimate.ts` and the
//! anchor selection in `src/index.ts:146-190`. JavaScript `String.length`
//! counts UTF-16 code units, so every text measure goes through
//! `json.utf16CodeUnitCount`; counting UTF-8 bytes would drift on non-ASCII.

const std = @import("std");
const json = @import("json.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Fixed text density (`packages/llm/token-meter/src/estimate.ts:13`).
pub const CHARS_PER_TOKEN: u64 = 4;
/// Per-block JSON framing (`estimate.ts:16`).
pub const BLOCK_OVERHEAD: u64 = 4;
/// Per-message role framing (`estimate.ts:19`).
pub const ROLE_OVERHEAD: u64 = 4;

fn ceilDiv(numerator: u64, denominator: u64) u64 {
    return (numerator + denominator - 1) / denominator;
}

fn utf16Units(text: []const u8) u64 {
    return @intCast(json.utf16CodeUnitCount(text));
}

/// Price one block list (`estimate.ts:42-61`). Text and reasoning use their
/// UTF-16 length; tool calls price name and raw argument text; every other
/// block prices its JSON structure.
pub fn estimateContent(allocator: Allocator, blocks: []const types.ContentBlock) !u64 {
    var tokens: u64 = 0;
    for (blocks) |block| {
        switch (block) {
            .text, .reasoning => |text| {
                tokens += ceilDiv(utf16Units(text), CHARS_PER_TOKEN) + BLOCK_OVERHEAD;
            },
            .tool_call => |call| {
                tokens += ceilDiv(utf16Units(call.name), CHARS_PER_TOKEN) +
                    ceilDiv(utf16Units(call.arguments), CHARS_PER_TOKEN) +
                    BLOCK_OVERHEAD;
            },
            .raw => |value| {
                const units = try structuralJsonUnits(allocator, value);
                tokens += ceilDiv(units, CHARS_PER_TOKEN) + BLOCK_OVERHEAD;
            },
        }
    }
    return tokens;
}

/// Price the rendered system prompt (`estimate.ts:73-82`): text density plus
/// role framing only, with no per-block overhead. Empty content means "no
/// system prompt" and prices 0.
pub fn estimateSystemMessage(allocator: Allocator, message: types.Message) !u64 {
    if (message.content.len == 0) return 0;
    var characters: u64 = 0;
    for (message.content) |block| {
        switch (block) {
            .text => |text| characters += utf16Units(text),
            else => characters += try blockJsonUnits(allocator, block),
        }
    }
    return ceilDiv(characters, CHARS_PER_TOKEN) + ROLE_OVERHEAD;
}

/// Price one model-visible message (`estimate.ts:88-92`).
pub fn estimateMessage(allocator: Allocator, message: types.Message) !u64 {
    if (message.role == .system) return estimateSystemMessage(allocator, message);
    const content = try estimateContent(allocator, message.content);
    return content + ROLE_OVERHEAD;
}

/// Disjoint provider buckets (`packages/llm/token-meter/src/index.ts:71-76`);
/// cache fields are optional and reasoning output is already inside
/// `outputTokens`.
pub fn usageTokens(usage: types.Usage) u64 {
    return usage.input_tokens +|
        (usage.cache_read_tokens orelse 0) +|
        (usage.cache_write_tokens orelse 0) +|
        usage.output_tokens;
}

/// Current compaction pressure. `anchor` is the provider usage of the latest
/// successful request, when the caller has one; `total_tokens` is then that
/// usage total, otherwise the fixed-heuristic price of `messages`.
pub const Measurement = struct {
    anchor: ?types.Usage = null,
    total_tokens: u64,
};

/// `index.ts:146-190` reduced to the message surface: provider usage anchors
/// the measurement and the heuristic stands in only when no anchor exists.
pub fn measure(
    allocator: Allocator,
    messages: []const types.Message,
    provider_usage: ?types.Usage,
) !Measurement {
    if (provider_usage) |usage| {
        return .{ .anchor = usage, .total_tokens = usageTokens(usage) };
    }
    var total: u64 = 0;
    for (messages) |message| {
        total += try estimateMessage(allocator, message);
    }
    return .{ .total_tokens = total };
}

/// Write one content block exactly as dsh's `JSON.stringify(block)`: text and
/// reasoning `{type,text}`, tool calls `{type,id,name,arguments}` (field order
/// from `packages/llm/llm/src/types.ts:62-135`), raw blocks in stored order.
pub fn writeBlock(w: *Writer, block: types.ContentBlock) !void {
    switch (block) {
        .text => |text| {
            try w.writeAll("{\"type\":\"text\",\"text\":");
            try std.json.Stringify.value(text, .{}, w);
            try w.writeByte('}');
        },
        .reasoning => |text| {
            try w.writeAll("{\"type\":\"reasoning\",\"text\":");
            try std.json.Stringify.value(text, .{}, w);
            try w.writeByte('}');
        },
        .tool_call => |call| {
            try w.writeAll("{\"type\":\"tool-call\",\"id\":");
            try std.json.Stringify.value(call.id, .{}, w);
            try w.writeAll(",\"name\":");
            try std.json.Stringify.value(call.name, .{}, w);
            try w.writeAll(",\"arguments\":");
            try std.json.Stringify.value(call.arguments, .{}, w);
            try w.writeByte('}');
        },
        .raw => |value| try std.json.Stringify.value(value, .{}, w),
    }
}

/// dsh has no standalone TokenUsage serializer: the session log stringifies
/// the adapter-built object. Use the declared field order from
/// `packages/llm/llm/src/types.ts:175-189` (the same order `stream.zig` writes).
pub fn writeUsage(w: *Writer, usage: types.Usage) !void {
    try w.writeAll("{\"inputTokens\":");
    try w.print("{d}", .{usage.input_tokens});
    try w.writeAll(",\"outputTokens\":");
    try w.print("{d}", .{usage.output_tokens});
    if (usage.total_tokens) |value| {
        try w.writeAll(",\"totalTokens\":");
        try w.print("{d}", .{value});
    }
    if (usage.cache_read_tokens) |value| {
        try w.writeAll(",\"cacheReadTokens\":");
        try w.print("{d}", .{value});
    }
    if (usage.cache_write_tokens) |value| {
        try w.writeAll(",\"cacheWriteTokens\":");
        try w.print("{d}", .{value});
    }
    if (usage.reasoning_tokens) |value| {
        try w.writeAll(",\"reasoningTokens\":");
        try w.print("{d}", .{value});
    }
    try w.writeByte('}');
}

fn blockJsonUnits(allocator: Allocator, block: types.ContentBlock) !u64 {
    var buffer = Writer.Allocating.init(allocator);
    defer buffer.deinit();
    try writeBlock(&buffer.writer, block);
    return utf16Units(buffer.written());
}

/// `estimate.ts:29-35`: an image reference is priced without its `offloaded`
/// marker (route pricing owns that placeholder); every other raw block is
/// priced whole.
fn structuralJsonUnits(allocator: Allocator, value: std.json.Value) !u64 {
    var buffer = Writer.Allocating.init(allocator);
    defer buffer.deinit();
    if (rawType(value)) |kind| {
        if (std.mem.eql(u8, kind, "image")) {
            try writeObjectWithoutKey(&buffer.writer, value, "offloaded");
            return utf16Units(buffer.written());
        }
    }
    try std.json.Stringify.value(value, .{}, &buffer.writer);
    return utf16Units(buffer.written());
}

fn rawType(value: std.json.Value) ?[]const u8 {
    switch (value) {
        .object => |object| {
            const kind = object.get("type") orelse return null;
            return switch (kind) {
                .string => |text| text,
                else => null,
            };
        },
        else => return null,
    }
}

fn writeObjectWithoutKey(w: *Writer, value: std.json.Value, skip: []const u8) !void {
    try w.writeByte('{');
    var first = true;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, skip)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
        try w.writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
    }
    try w.writeByte('}');
}

const testing = std.testing;

fn textBlock(value: []const u8) types.ContentBlock {
    return .{ .text = value };
}

fn userMessage(content: []const types.ContentBlock) types.Message {
    return .{ .id = "m1", .role = .user, .content = content, .source = .user };
}

fn systemMessage(content: []const types.ContentBlock) types.Message {
    return .{ .id = "m0", .role = .system, .content = content, .source = .system_prompt };
}

fn objectValue(allocator: Allocator, entries: []const struct { []const u8, std.json.Value }) !std.json.ObjectMap {
    var object: std.json.ObjectMap = .empty;
    for (entries) |entry| try object.put(allocator, entry[0], entry[1]);
    return object;
}

fn repeatAlloc(allocator: Allocator, pattern: []const u8, count: usize) ![]u8 {
    const out = try allocator.alloc(u8, pattern.len * count);
    errdefer allocator.free(out);
    for (0..count) |index| {
        @memcpy(out[index * pattern.len ..][0..pattern.len], pattern);
    }
    return out;
}

test "non-ASCII text prices by UTF-16 code units" {
    // Expected values produced by the dsh reference implementation:
    //   bun run /tmp/p2a-token/expected.ts
    // which imports packages/llm/token-meter/src/estimate.ts (0.2.1-rc.2).
    // cjk 5/9, emoji 6/10, mixed 6/10 (content/message).
    const cjk = [_]types.ContentBlock{textBlock("中文测试")};
    try testing.expectEqual(@as(u64, 5), try estimateContent(testing.allocator, &cjk));
    try testing.expectEqual(@as(u64, 9), try estimateMessage(testing.allocator, userMessage(&cjk)));

    const emoji = [_]types.ContentBlock{textBlock("😀😀😀")};
    try testing.expectEqual(@as(u64, 6), try estimateContent(testing.allocator, &emoji));
    try testing.expectEqual(@as(u64, 10), try estimateMessage(testing.allocator, userMessage(&emoji)));

    const mixed = [_]types.ContentBlock{textBlock("a😀é中")};
    try testing.expectEqual(@as(u64, 6), try estimateContent(testing.allocator, &mixed));
    try testing.expectEqual(@as(u64, 10), try estimateMessage(testing.allocator, userMessage(&mixed)));
}

test "empty, single and multi-block boundaries" {
    // Expected values from the same dsh reference run:
    // empty_text 4/8, empty_content 0/4, single 5/9, two_blocks 10/14,
    // three_blocks 15/19, multi_message 18.
    const empty_text = [_]types.ContentBlock{textBlock("")};
    try testing.expectEqual(@as(u64, 4), try estimateContent(testing.allocator, &empty_text));
    try testing.expectEqual(@as(u64, 8), try estimateMessage(testing.allocator, userMessage(&empty_text)));

    const empty = [_]types.ContentBlock{};
    try testing.expectEqual(@as(u64, 0), try estimateContent(testing.allocator, &empty));
    try testing.expectEqual(@as(u64, 4), try estimateMessage(testing.allocator, userMessage(&empty)));

    const single = [_]types.ContentBlock{textBlock("abcd")};
    try testing.expectEqual(@as(u64, 5), try estimateContent(testing.allocator, &single));
    try testing.expectEqual(@as(u64, 9), try estimateMessage(testing.allocator, userMessage(&single)));

    const two = [_]types.ContentBlock{ textBlock("abcd"), textBlock("中文") };
    try testing.expectEqual(@as(u64, 10), try estimateContent(testing.allocator, &two));
    try testing.expectEqual(@as(u64, 14), try estimateMessage(testing.allocator, userMessage(&two)));

    const three = [_]types.ContentBlock{ textBlock("abcd"), textBlock("中文"), textBlock("😀") };
    try testing.expectEqual(@as(u64, 15), try estimateContent(testing.allocator, &three));
    try testing.expectEqual(@as(u64, 19), try estimateMessage(testing.allocator, userMessage(&three)));

    const one = [_]types.ContentBlock{textBlock("中文")};
    const messages = [_]types.Message{ userMessage(&single), userMessage(&one) };
    try testing.expectEqual(@as(u64, 18), (try measure(testing.allocator, &messages, null)).total_tokens);
}

test "system, reasoning and tool-call arms" {
    // Expected values from the same dsh reference run:
    // system_empty 0, system_cjk 5, system_text 6, system_two_blocks 6,
    // reasoning 5/9, tool_call 8/12.
    const empty = [_]types.ContentBlock{};
    try testing.expectEqual(@as(u64, 0), try estimateMessage(testing.allocator, systemMessage(&empty)));

    const cjk = [_]types.ContentBlock{textBlock("系统提示")};
    try testing.expectEqual(@as(u64, 5), try estimateMessage(testing.allocator, systemMessage(&cjk)));

    const plain = [_]types.ContentBlock{textBlock("system")};
    try testing.expectEqual(@as(u64, 6), try estimateMessage(testing.allocator, systemMessage(&plain)));

    const two = [_]types.ContentBlock{ textBlock("abcd"), textBlock("中文") };
    try testing.expectEqual(@as(u64, 6), try estimateMessage(testing.allocator, systemMessage(&two)));

    const reasoning = [_]types.ContentBlock{.{ .reasoning = "思考中" }};
    try testing.expectEqual(@as(u64, 5), try estimateContent(testing.allocator, &reasoning));
    try testing.expectEqual(@as(u64, 9), try estimateMessage(testing.allocator, userMessage(&reasoning)));

    const call = [_]types.ContentBlock{.{ .tool_call = .{
        .id = "call-1",
        .name = "read",
        .arguments = "{\"path\":\"x\"}",
    } }};
    try testing.expectEqual(@as(u64, 8), try estimateContent(testing.allocator, &call));
    try testing.expectEqual(@as(u64, 12), try estimateMessage(testing.allocator, userMessage(&call)));
}

test "raw blocks price the same JSON dsh stringifies" {
    // Expected values from the same dsh reference run:
    // image_offloaded 14/18, unknown_block 14/18.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const image = [_]types.ContentBlock{.{ .raw = .{ .object = try objectValue(allocator, &.{
        .{ "type", .{ .string = "image" } },
        .{ "attachment", .{ .string = "img-1" } },
        .{ "offloaded", .{ .bool = true } },
    }) } }};
    try testing.expectEqual(@as(u64, 14), try estimateContent(testing.allocator, &image));
    try testing.expectEqual(@as(u64, 18), try estimateMessage(testing.allocator, userMessage(&image)));

    const unknown = [_]types.ContentBlock{.{ .raw = .{ .object = try objectValue(allocator, &.{
        .{ "type", .{ .string = "tool-addition" } },
        .{ "toolName", .{ .string = "x" } },
    }) } }};
    try testing.expectEqual(@as(u64, 14), try estimateContent(testing.allocator, &unknown));
    try testing.expectEqual(@as(u64, 18), try estimateMessage(testing.allocator, userMessage(&unknown)));
}

test "block and usage JSON keep dsh key order" {
    // JSON strings below are dsh's JSON.stringify output from the reference
    // run; usage order follows the TokenUsage declaration (no dsh serializer).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "{\"type\":\"text\",\"text\":\"中文😀\"}",
        try renderBlock(allocator, .{ .text = "中文😀" }),
    );
    try testing.expectEqualStrings(
        "{\"type\":\"reasoning\",\"text\":\"思考\"}",
        try renderBlock(allocator, .{ .reasoning = "思考" }),
    );
    try testing.expectEqualStrings(
        "{\"type\":\"tool-call\",\"id\":\"call-1\",\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"x\\\"}\"}",
        try renderBlock(allocator, .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments = "{\"path\":\"x\"}" } }),
    );

    var buffer = Writer.Allocating.init(allocator);
    try writeUsage(&buffer.writer, .{ .input_tokens = 7, .output_tokens = 3 });
    try testing.expectEqualStrings("{\"inputTokens\":7,\"outputTokens\":3}", buffer.written());

    buffer.clearRetainingCapacity();
    try writeUsage(&buffer.writer, .{
        .input_tokens = 7,
        .output_tokens = 3,
        .total_tokens = 10,
        .cache_read_tokens = 2,
        .cache_write_tokens = 1,
        .reasoning_tokens = 1,
    });
    try testing.expectEqualStrings(
        "{\"inputTokens\":7,\"outputTokens\":3,\"totalTokens\":10,\"cacheReadTokens\":2,\"cacheWriteTokens\":1,\"reasoningTokens\":1}",
        buffer.written(),
    );
}

test "provider usage anchors measurement ahead of the heuristic" {
    const blocks = [_]types.ContentBlock{textBlock("中文测试")};
    const messages = [_]types.Message{userMessage(&blocks)};

    const anchored = try measure(testing.allocator, &messages, .{
        .input_tokens = 100,
        .output_tokens = 20,
        .total_tokens = 999,
        .cache_read_tokens = 30,
        .cache_write_tokens = 5,
        .reasoning_tokens = 7,
    });
    // index.ts:71-76 sums input + cacheRead + cacheWrite + output and ignores
    // totalTokens/reasoningTokens.
    try testing.expectEqual(@as(u64, 155), anchored.total_tokens);
    try testing.expectEqual(@as(u64, 100), anchored.anchor.?.input_tokens);

    const estimated = try measure(testing.allocator, &messages, null);
    try testing.expectEqual(@as(u64, 9), estimated.total_tokens);
    try testing.expect(estimated.anchor == null);
}

test "64KB+ text and raw JSON paths estimate without leaking" {
    // Expected values from /tmp/p2a-token/expected-long.ts on the dsh
    // reference: long_cjk 5508, long_mixed 20488, long_raw 16405 with a
    // 65588-code-unit serialized JSON.
    const cjk = try repeatAlloc(testing.allocator, "中", 22000);
    defer testing.allocator.free(cjk);
    const cjk_blocks = [_]types.ContentBlock{textBlock(cjk)};
    try testing.expectEqual(@as(u64, 5504), try estimateContent(testing.allocator, &cjk_blocks));
    try testing.expectEqual(@as(u64, 5508), try estimateMessage(testing.allocator, userMessage(&cjk_blocks)));

    const mixed = try repeatAlloc(testing.allocator, "a😀é中", 16384);
    defer testing.allocator.free(mixed);
    const mixed_blocks = [_]types.ContentBlock{textBlock(mixed)};
    try testing.expectEqual(@as(u64, 20484), try estimateContent(testing.allocator, &mixed_blocks));
    try testing.expectEqual(@as(u64, 20488), try estimateMessage(testing.allocator, userMessage(&mixed_blocks)));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload = try repeatAlloc(allocator, "a", 65536);
    const raw = [_]types.ContentBlock{.{ .raw = .{ .object = try objectValue(allocator, &.{
        .{ "type", .{ .string = "tool-addition" } },
        .{ "toolName", .{ .string = "x" } },
        .{ "payload", .{ .string = payload } },
    }) } }};
    try testing.expectEqual(@as(u64, 16401), try estimateContent(testing.allocator, &raw));
    try testing.expectEqual(@as(u64, 16405), try estimateMessage(testing.allocator, userMessage(&raw)));

    var buffer = Writer.Allocating.init(testing.allocator);
    defer buffer.deinit();
    try writeBlock(&buffer.writer, raw[0]);
    try testing.expectEqual(@as(usize, 65588), buffer.written().len);
}

fn renderBlock(allocator: Allocator, block: types.ContentBlock) ![]u8 {
    var buffer = Writer.Allocating.init(allocator);
    errdefer buffer.deinit();
    try writeBlock(&buffer.writer, block);
    return buffer.toOwnedSlice();
}
