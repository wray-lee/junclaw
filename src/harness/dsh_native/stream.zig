//! Assistant provider stream normalization: chunk/done events become one
//! assistant/message settlement with compact stream records and usage.
//!
//! Mirrors dsh 0.2.1-rc.2:
//! - `packages/llm/llm/src/assistant-stream.ts:100-200` (compact records)
//! - `packages/llm/llm/src/assembler.ts:45-235` (block assembly, max-token truncation)
//! - `packages/llm/llm/src/message.ts:260-271` (assistant message source)
//! - `packages/core/agent-loop/src/agent.ts:452-560` (interrupted settlement)
//!
//! Every stored string and raw chunk is copied into the accumulator arena;
//! `Settlement` views stay valid until `Accumulator.deinit`.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Terminal reason reported by the provider. Provider errors settle as
/// `assistant/attempt` outside this module.
pub const Finish = enum {
    stop,
    tool_calls,
    max_tokens,

    fn jsonKind(self: Finish) []const u8 {
        return switch (self) {
            .stop => "stop",
            .tool_calls => "tool-calls",
            .max_tokens => "max-tokens",
        };
    }
};

/// Map the provider's finish_reason string onto the durable reason.
pub fn finishFromProvider(reason: []const u8) Finish {
    if (std.mem.eql(u8, reason, "tool_calls") or
        std.mem.eql(u8, reason, "tool-calls") or
        std.mem.eql(u8, reason, "tool_use"))
    {
        return .tool_calls;
    }
    if (std.mem.eql(u8, reason, "length") or
        std.mem.eql(u8, reason, "max_tokens") or
        std.mem.eql(u8, reason, "max-tokens"))
    {
        return .max_tokens;
    }
    return .stop;
}

/// Provider usage keys. A missing (`null`) key normalizes to zero.
pub const ProviderUsage = struct {
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
};

/// prompt/completion/total -> inputTokens/outputTokens/totalTokens, null -> 0.
pub fn normalizeUsage(input: ProviderUsage) types.Usage {
    return .{
        .input_tokens = input.prompt_tokens orelse 0,
        .output_tokens = input.completion_tokens orelse 0,
        .total_tokens = input.total_tokens orelse 0,
    };
}

pub const TextDelta = struct {
    index: u32,
    text: []const u8,
};

pub const ToolCallDelta = struct {
    index: u32,
    id: []const u8,
    name: ?[]const u8 = null,
    arguments_delta: []const u8 = "",
};

pub const BlockStart = struct {
    index: u32,
    block_type: []const u8,
};

pub const BlockEnd = struct {
    index: u32,
    block: types.ContentBlock,
};

/// One normalized provider chunk (the durable dsh StreamChunk vocabulary).
pub const Chunk = union(enum) {
    text_delta: TextDelta,
    reasoning_delta: TextDelta,
    tool_call_delta: ToolCallDelta,
    block_start: BlockStart,
    block_end: BlockEnd,
    usage: types.Usage,
    finish: Finish,
};

/// End of one provider attempt.
pub const Done = struct {
    finish: Finish = .stop,
    /// `null` means the provider reported no usage at all.
    usage: ?ProviderUsage = null,
    interrupted: bool = false,
    /// Delta-less providers report tool calls only here; they are synthesized
    /// as tool-call chunks before the finish record.
    tool_calls: []const types.ToolCall = &.{},
};

pub const Event = union(enum) {
    chunk: Chunk,
    done: Done,
};

/// Compact stream records embedded in assistant/message.
pub const TextRun = struct {
    index: u32,
    time0: i64,
    dt: []const i64,
    texts: []const []const u8,
};

pub const ToolCallRun = struct {
    index: u32,
    time0: i64,
    dt: []const i64,
    id: []const u8,
    name: ?[]const u8,
    args: []const []const u8,
};

pub const RawChunk = struct {
    time: i64,
    chunk: Chunk,
};

pub const StreamRecord = union(enum) {
    text_chunks: TextRun,
    reasoning_chunks: TextRun,
    tool_call_chunks: ToolCallRun,
    chunk: RawChunk,
};

/// The parts of an assistant/message payload this module owns. The caller
/// adds `turn`/`step` and appends it with `surfaceOp: "append"`.
pub const Settlement = struct {
    message: types.Message,
    usage: ?types.Usage,
    stream: []const StreamRecord,
    interrupted: bool,
    finish: Finish,
};

const BlockType = enum { text, reasoning, tool_call, other };

const Partial = struct {
    block_type: BlockType,
    texts: std.ArrayListUnmanaged([]const u8) = .empty,
    tool_id: []const u8 = "",
    tool_name: []const u8 = "",
    args: std.ArrayListUnmanaged([]const u8) = .empty,
    closed: ?types.ContentBlock = null,
};

const MutableTextRun = struct {
    index: u32,
    time0: i64,
    last_time: i64,
    dt: std.ArrayListUnmanaged(i64) = .empty,
    texts: std.ArrayListUnmanaged([]const u8) = .empty,
};

const MutableToolCallRun = struct {
    index: u32,
    time0: i64,
    last_time: i64,
    id: []const u8,
    name: ?[]const u8,
    dt: std.ArrayListUnmanaged(i64) = .empty,
    args: std.ArrayListUnmanaged([]const u8) = .empty,
};

const RecordTag = enum { text_chunks, reasoning_chunks, tool_call_chunks, chunk };

const MutableRecord = union(RecordTag) {
    text_chunks: MutableTextRun,
    reasoning_chunks: MutableTextRun,
    tool_call_chunks: MutableToolCallRun,
    chunk: RawChunk,
};

/// Folds one model attempt into compact stream records plus an assistant
/// message. Chunks arriving after a done event are ignored.
pub const Accumulator = struct {
    arena: std.heap.ArenaAllocator,
    partials: std.AutoHashMapUnmanaged(u32, Partial) = .empty,
    order: std.ArrayListUnmanaged(u32) = .empty,
    records: std.ArrayListUnmanaged(MutableRecord) = .empty,
    usage: ?types.Usage = null,
    finish: Finish = .stop,
    interrupted: bool = false,
    ended: bool = false,
    saw_usage_chunk: bool = false,
    next_index: u32 = 0,

    pub fn init(allocator: Allocator) Accumulator {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Accumulator) void {
        self.arena.deinit();
    }

    /// Feed one event. Returns false when the attempt already settled; such
    /// late chunks contribute nothing to content, stream, or usage.
    pub fn push(self: *Accumulator, time_ms: i64, event: Event) !bool {
        if (self.ended) return false;
        switch (event) {
            .chunk => |chunk| try self.pushChunk(time_ms, chunk),
            .done => |done| try self.pushDone(time_ms, done),
        }
        return true;
    }

    fn pushChunk(self: *Accumulator, time_ms: i64, chunk: Chunk) !void {
        const allocator = self.arena.allocator();
        switch (chunk) {
            .text_delta => |delta| {
                const text = try allocator.dupe(u8, delta.text);
                const partial = try self.ensure(delta.index, .text);
                if (partial.closed == null) try partial.texts.append(allocator, text);
                try self.packText(.text_chunks, time_ms, delta.index, text);
            },
            .reasoning_delta => |delta| {
                const text = try allocator.dupe(u8, delta.text);
                const partial = try self.ensure(delta.index, .reasoning);
                if (partial.closed == null) try partial.texts.append(allocator, text);
                try self.packText(.reasoning_chunks, time_ms, delta.index, text);
            },
            .tool_call_delta => |delta| {
                const id = try allocator.dupe(u8, delta.id);
                const name = if (delta.name) |raw_name| try allocator.dupe(u8, raw_name) else null;
                const args = try allocator.dupe(u8, delta.arguments_delta);
                const partial = try self.ensure(delta.index, .tool_call);
                if (partial.closed == null) {
                    partial.tool_id = id;
                    if (name) |value| {
                        if (value.len > 0) partial.tool_name = value;
                    }
                    try partial.args.append(allocator, args);
                }
                try self.packToolCall(time_ms, delta.index, id, name, args);
            },
            .block_start => |start| {
                _ = try self.ensure(start.index, mapBlockType(start.block_type));
                try self.appendRaw(time_ms, chunk);
            },
            .block_end => |end| {
                const partial = try self.ensure(end.index, blockTypeOf(end.block));
                if (partial.closed == null) partial.closed = try self.cloneBlock(end.block);
                try self.appendRaw(time_ms, chunk);
            },
            .usage => |usage| {
                const normalized = zeroUsage(usage);
                self.usage = normalized;
                self.saw_usage_chunk = true;
                try self.appendRaw(time_ms, .{ .usage = normalized });
            },
            .finish => |finish| {
                self.finish = finish;
                try self.appendRaw(time_ms, chunk);
            },
        }
    }

    fn pushDone(self: *Accumulator, time_ms: i64, done: Done) !void {
        self.finish = done.finish;
        if (done.interrupted) {
            // dsh settles the safe prefix and no terminal finish chunk on abort.
            self.interrupted = true;
            if (done.usage) |usage| self.usage = normalizeUsage(usage);
            self.ended = true;
            return;
        }
        for (done.tool_calls) |call| {
            if (self.hasToolCallId(call.id)) continue;
            const index = self.next_index;
            self.next_index = std.math.add(u32, index, 1) catch std.math.maxInt(u32);
            try self.pushChunk(time_ms, .{ .block_start = .{
                .index = index,
                .block_type = "tool-call",
            } });
            try self.pushChunk(time_ms, .{ .tool_call_delta = .{
                .index = index,
                .id = call.id,
                .name = call.name,
                .arguments_delta = call.arguments,
            } });
            try self.pushChunk(time_ms, .{ .block_end = .{
                .index = index,
                .block = .{ .tool_call = call },
            } });
        }
        if (done.usage) |usage| {
            const normalized = normalizeUsage(usage);
            self.usage = normalized;
            if (!self.saw_usage_chunk) {
                try self.appendRaw(time_ms, .{ .usage = normalized });
                self.saw_usage_chunk = true;
            }
        }
        try self.appendRaw(time_ms, .{ .finish = done.finish });
        self.ended = true;
    }

    fn hasToolCallId(self: *Accumulator, id: []const u8) bool {
        if (id.len == 0) return false;
        var iterator = self.partials.valueIterator();
        while (iterator.next()) |partial| {
            if (partial.block_type == .tool_call and std.mem.eql(u8, partial.tool_id, id)) return true;
        }
        return false;
    }

    fn ensure(self: *Accumulator, index: u32, block_type: BlockType) !*Partial {
        if (self.partials.getPtr(index)) |partial| return partial;
        const allocator = self.arena.allocator();
        try self.partials.put(allocator, index, .{ .block_type = block_type });
        try self.order.append(allocator, index);
        self.next_index = @max(self.next_index, std.math.add(u32, index, 1) catch std.math.maxInt(u32));
        return self.partials.getPtr(index).?;
    }

    fn packText(
        self: *Accumulator,
        comptime tag: RecordTag,
        time_ms: i64,
        index: u32,
        text: []const u8,
    ) !void {
        const allocator = self.arena.allocator();
        if (self.records.items.len > 0) {
            const last = &self.records.items[self.records.items.len - 1];
            switch (last.*) {
                .text_chunks => |*run| {
                    if (tag == .text_chunks and run.index == index) {
                        if (safeGap(run.last_time, time_ms)) |gap| {
                            try run.dt.append(allocator, gap);
                            try run.texts.append(allocator, text);
                            run.last_time = time_ms;
                            return;
                        }
                    }
                },
                .reasoning_chunks => |*run| {
                    if (tag == .reasoning_chunks and run.index == index) {
                        if (safeGap(run.last_time, time_ms)) |gap| {
                            try run.dt.append(allocator, gap);
                            try run.texts.append(allocator, text);
                            run.last_time = time_ms;
                            return;
                        }
                    }
                },
                else => {},
            }
        }
        var run = MutableTextRun{
            .index = index,
            .time0 = time_ms,
            .last_time = time_ms,
        };
        try run.texts.append(allocator, text);
        switch (tag) {
            .text_chunks => try self.records.append(allocator, .{ .text_chunks = run }),
            .reasoning_chunks => try self.records.append(allocator, .{ .reasoning_chunks = run }),
            else => unreachable,
        }
    }

    fn packToolCall(
        self: *Accumulator,
        time_ms: i64,
        index: u32,
        id: []const u8,
        name: ?[]const u8,
        args: []const u8,
    ) !void {
        // dsh leaves empty-identity deltas as raw chunks.
        if (id.len == 0 or (name != null and name.?.len == 0)) {
            try self.appendRaw(time_ms, .{ .tool_call_delta = .{
                .index = index,
                .id = id,
                .name = name,
                .arguments_delta = args,
            } });
            return;
        }
        const allocator = self.arena.allocator();
        if (self.records.items.len > 0) {
            const last = &self.records.items[self.records.items.len - 1];
            switch (last.*) {
                .tool_call_chunks => |*run| {
                    if (run.index == index and
                        std.mem.eql(u8, run.id, id) and
                        sameName(run.name, name))
                    {
                        if (safeGap(run.last_time, time_ms)) |gap| {
                            try run.dt.append(allocator, gap);
                            try run.args.append(allocator, args);
                            run.last_time = time_ms;
                            return;
                        }
                    }
                },
                else => {},
            }
        }
        var run = MutableToolCallRun{
            .index = index,
            .time0 = time_ms,
            .last_time = time_ms,
            .id = id,
            .name = name,
        };
        try run.args.append(allocator, args);
        try self.records.append(allocator, .{ .tool_call_chunks = run });
    }

    fn appendRaw(self: *Accumulator, time_ms: i64, chunk: Chunk) !void {
        const allocator = self.arena.allocator();
        try self.records.append(allocator, .{ .chunk = .{
            .time = time_ms,
            .chunk = try self.cloneChunk(chunk),
        } });
    }

    fn cloneChunk(self: *Accumulator, chunk: Chunk) !Chunk {
        const allocator = self.arena.allocator();
        return switch (chunk) {
            .text_delta => |delta| .{ .text_delta = .{
                .index = delta.index,
                .text = try allocator.dupe(u8, delta.text),
            } },
            .reasoning_delta => |delta| .{ .reasoning_delta = .{
                .index = delta.index,
                .text = try allocator.dupe(u8, delta.text),
            } },
            .tool_call_delta => |delta| .{ .tool_call_delta = .{
                .index = delta.index,
                .id = try allocator.dupe(u8, delta.id),
                .name = if (delta.name) |name| try allocator.dupe(u8, name) else null,
                .arguments_delta = try allocator.dupe(u8, delta.arguments_delta),
            } },
            .block_start => |start| .{ .block_start = .{
                .index = start.index,
                .block_type = try allocator.dupe(u8, start.block_type),
            } },
            .block_end => |end| .{ .block_end = .{
                .index = end.index,
                .block = try self.cloneBlock(end.block),
            } },
            .usage => |usage| .{ .usage = zeroUsage(usage) },
            .finish => |finish| .{ .finish = finish },
        };
    }

    fn cloneBlock(self: *Accumulator, block: types.ContentBlock) !types.ContentBlock {
        const allocator = self.arena.allocator();
        return switch (block) {
            .text => |text| .{ .text = try allocator.dupe(u8, text) },
            .reasoning => |text| .{ .reasoning = try allocator.dupe(u8, text) },
            .tool_call => |call| .{ .tool_call = .{
                .id = try allocator.dupe(u8, call.id),
                .name = try allocator.dupe(u8, call.name),
                .arguments = try allocator.dupe(u8, call.arguments),
            } },
            .raw => |value| .{ .raw = try cloneValue(allocator, value) },
        };
    }

    /// Assemble the assistant message content: all blocks on success, tool
    /// calls dropped on max-token truncation, visible prefix on interruption.
    fn assembleContent(self: *Accumulator, interrupted: bool) ![]const types.ContentBlock {
        const allocator = self.arena.allocator();
        const out = try allocator.alloc(types.ContentBlock, self.order.items.len);
        var len: usize = 0;
        for (self.order.items) |index| {
            const partial = self.partials.getPtr(index).?;
            if (interrupted and !isVisibleInterrupted(partial)) continue;
            const block = try self.assemblePartial(partial, index);
            if (!interrupted and self.finish == .max_tokens) {
                switch (block) {
                    .tool_call => continue,
                    else => {},
                }
            }
            out[len] = block;
            len += 1;
        }
        return out[0..len];
    }

    fn assemblePartial(self: *Accumulator, partial: *const Partial, index: u32) !types.ContentBlock {
        if (partial.closed) |block| return block;
        const allocator = self.arena.allocator();
        return switch (partial.block_type) {
            .text => .{ .text = try concatParts(allocator, partial.texts.items) },
            .reasoning => .{ .reasoning = try concatParts(allocator, partial.texts.items) },
            .tool_call => .{ .tool_call = .{
                .id = if (partial.tool_id.len > 0)
                    try allocator.dupe(u8, partial.tool_id)
                else
                    try std.fmt.allocPrint(allocator, "call-{d}", .{index}),
                .name = try allocator.dupe(u8, partial.tool_name),
                .arguments = try concatParts(allocator, partial.args.items),
            } },
            .other => return error.UnsupportedBlockType,
        };
    }

    fn freezeRecords(self: *Accumulator) ![]const StreamRecord {
        const allocator = self.arena.allocator();
        const out = try allocator.alloc(StreamRecord, self.records.items.len);
        for (self.records.items, 0..) |record, position| {
            out[position] = switch (record) {
                .text_chunks => |run| .{ .text_chunks = .{
                    .index = run.index,
                    .time0 = run.time0,
                    .dt = try allocator.dupe(i64, run.dt.items),
                    .texts = try allocator.dupe([]const u8, run.texts.items),
                } },
                .reasoning_chunks => |run| .{ .reasoning_chunks = .{
                    .index = run.index,
                    .time0 = run.time0,
                    .dt = try allocator.dupe(i64, run.dt.items),
                    .texts = try allocator.dupe([]const u8, run.texts.items),
                } },
                .tool_call_chunks => |run| .{ .tool_call_chunks = .{
                    .index = run.index,
                    .time0 = run.time0,
                    .dt = try allocator.dupe(i64, run.dt.items),
                    .id = run.id,
                    .name = run.name,
                    .args = try allocator.dupe([]const u8, run.args.items),
                } },
                .chunk => |raw| .{ .chunk = raw },
            };
        }
        return out;
    }

    /// Build the finalized assistant message and its embedded compact stream.
    /// `id`, `provider`, and `model` are copied into the arena.
    pub fn settle(
        self: *Accumulator,
        id: []const u8,
        provider: []const u8,
        model: []const u8,
    ) !Settlement {
        const allocator = self.arena.allocator();
        const content = try self.assembleContent(self.interrupted);
        const stream = try self.freezeRecords();
        return .{
            .message = .{
                .id = try allocator.dupe(u8, id),
                .role = .assistant,
                .content = content,
                .source = .{ .model = .{
                    .provider = try allocator.dupe(u8, provider),
                    .model = try allocator.dupe(u8, model),
                } },
            },
            .usage = self.usage,
            .stream = stream,
            .interrupted = self.interrupted,
            .finish = self.finish,
        };
    }
};

fn mapBlockType(name: []const u8) BlockType {
    if (std.mem.eql(u8, name, "text")) return .text;
    if (std.mem.eql(u8, name, "reasoning")) return .reasoning;
    if (std.mem.eql(u8, name, "tool-call")) return .tool_call;
    return .other;
}

fn blockTypeOf(block: types.ContentBlock) BlockType {
    return switch (block) {
        .text => .text,
        .reasoning => .reasoning,
        .tool_call => .tool_call,
        .raw => .other,
    };
}

fn zeroUsage(usage: types.Usage) types.Usage {
    var out = usage;
    out.total_tokens = usage.total_tokens orelse 0;
    return out;
}

fn safeGap(previous: i64, next: i64) ?i64 {
    const gap = std.math.sub(i64, next, previous) catch return null;
    const round_trip = std.math.add(i64, previous, gap) catch return null;
    if (round_trip != next) return null;
    return gap;
}

fn sameName(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn concatParts(allocator: Allocator, parts: []const []const u8) ![]const u8 {
    var total: usize = 0;
    for (parts) |part| total += part.len;
    const out = try allocator.alloc(u8, total);
    var position: usize = 0;
    for (parts) |part| {
        @memcpy(out[position..][0..part.len], part);
        position += part.len;
    }
    return out;
}

fn hasNonWhitespace(text: []const u8) bool {
    // shortcut: ASCII whitespace only; dsh's \S also covers Unicode spaces.
    for (text) |byte| {
        if (!std.ascii.isWhitespace(byte)) return true;
    }
    return false;
}

fn hasNonWhitespaceParts(parts: []const []const u8) bool {
    for (parts) |part| {
        if (hasNonWhitespace(part)) return true;
    }
    return false;
}

fn isVisibleInterrupted(partial: *const Partial) bool {
    if (partial.closed) |block| {
        return switch (block) {
            .text => |text| hasNonWhitespace(text),
            .reasoning => |text| hasNonWhitespace(text),
            else => false,
        };
    }
    return switch (partial.block_type) {
        .text, .reasoning => hasNonWhitespaceParts(partial.texts.items),
        else => false,
    };
}

fn cloneValue(allocator: Allocator, value: std.json.Value) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{ .allocate = .alloc_always });
}

/// Write the assistant/message data object (`message`, optional `usage`,
/// `stream`, optional `interrupted`). The caller adds `turn`/`step` and must
/// not add `sourceEventSeqs`.
pub fn writeData(w: *Writer, settlement: Settlement) !void {
    try w.writeAll("{\"message\":");
    try writeMessage(w, settlement.message);
    if (settlement.usage) |usage| {
        try w.writeAll(",\"usage\":");
        try writeUsage(w, usage);
    }
    try w.writeAll(",\"stream\":[");
    for (settlement.stream, 0..) |record, position| {
        if (position > 0) try w.writeByte(',');
        try writeStreamRecord(w, record);
    }
    try w.writeByte(']');
    if (settlement.interrupted) try w.writeAll(",\"interrupted\":true");
    try w.writeByte('}');
}

fn writeMessage(w: *Writer, message: types.Message) !void {
    try w.writeAll("{\"role\":");
    try std.json.Stringify.value(@tagName(message.role), .{}, w);
    try w.writeAll(",\"content\":[");
    for (message.content, 0..) |block, position| {
        if (position > 0) try w.writeByte(',');
        try writeContentBlock(w, block);
    }
    try w.writeAll("],\"source\":");
    try writeSource(w, message.source);
    try w.writeAll(",\"id\":");
    try std.json.Stringify.value(message.id, .{}, w);
    try w.writeByte('}');
}

fn writeSource(w: *Writer, source: types.MessageSource) !void {
    switch (source) {
        .model => |model| {
            try w.writeAll("{\"kind\":\"model\",\"provider\":");
            try std.json.Stringify.value(model.provider, .{}, w);
            try w.writeAll(",\"model\":");
            try std.json.Stringify.value(model.model, .{}, w);
            try w.writeByte('}');
        },
        .user => try w.writeAll("{\"kind\":\"user\"}"),
        .system_prompt => try w.writeAll("{\"kind\":\"system-prompt\"}"),
        .tool => |tool| {
            try w.writeAll("{\"kind\":\"tool\",\"callId\":");
            try std.json.Stringify.value(tool.call_id, .{}, w);
            try w.writeByte('}');
        },
        .other => |value| try std.json.Stringify.value(value, .{}, w),
    }
}

fn writeContentBlock(w: *Writer, block: types.ContentBlock) !void {
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

fn writeUsage(w: *Writer, usage: types.Usage) !void {
    try w.writeAll("{\"inputTokens\":");
    try w.print("{d}", .{usage.input_tokens});
    try w.writeAll(",\"outputTokens\":");
    try w.print("{d}", .{usage.output_tokens});
    try w.writeAll(",\"totalTokens\":");
    try w.print("{d}", .{usage.total_tokens orelse 0});
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

fn writeStreamRecord(w: *Writer, record: StreamRecord) !void {
    switch (record) {
        .text_chunks => |run| try writeTextRun(w, "text-chunks", run),
        .reasoning_chunks => |run| try writeTextRun(w, "reasoning-chunks", run),
        .tool_call_chunks => |run| {
            try w.writeAll("{\"type\":\"tool-call-chunks\",\"time0\":");
            try w.print("{d}", .{run.time0});
            try w.writeAll(",\"index\":");
            try w.print("{d}", .{run.index});
            try w.writeAll(",\"dt\":[");
            try writeI64Array(w, run.dt);
            try w.writeAll("],\"id\":");
            try std.json.Stringify.value(run.id, .{}, w);
            if (run.name) |name| {
                try w.writeAll(",\"name\":");
                try std.json.Stringify.value(name, .{}, w);
            }
            try w.writeAll(",\"args\":[");
            for (run.args, 0..) |argument, position| {
                if (position > 0) try w.writeByte(',');
                try std.json.Stringify.value(argument, .{}, w);
            }
            try w.writeAll("]}");
        },
        .chunk => |raw| {
            try w.writeAll("{\"type\":\"chunk\",\"time\":");
            try w.print("{d}", .{raw.time});
            try w.writeAll(",\"chunk\":");
            try writeChunk(w, raw.chunk);
            try w.writeByte('}');
        },
    }
}

fn writeTextRun(w: *Writer, kind: []const u8, run: TextRun) !void {
    try w.writeAll("{\"type\":\"");
    try w.writeAll(kind);
    try w.writeAll("\",\"time0\":");
    try w.print("{d}", .{run.time0});
    try w.writeAll(",\"index\":");
    try w.print("{d}", .{run.index});
    try w.writeAll(",\"dt\":[");
    try writeI64Array(w, run.dt);
    try w.writeAll("],\"texts\":[");
    for (run.texts, 0..) |text, position| {
        if (position > 0) try w.writeByte(',');
        try std.json.Stringify.value(text, .{}, w);
    }
    try w.writeAll("]}");
}

fn writeI64Array(w: *Writer, values: []const i64) !void {
    for (values, 0..) |value, position| {
        if (position > 0) try w.writeByte(',');
        try w.print("{d}", .{value});
    }
}

fn writeChunk(w: *Writer, chunk: Chunk) !void {
    switch (chunk) {
        .text_delta => |delta| {
            try w.writeAll("{\"type\":\"text-delta\",\"index\":");
            try w.print("{d}", .{delta.index});
            try w.writeAll(",\"text\":");
            try std.json.Stringify.value(delta.text, .{}, w);
            try w.writeByte('}');
        },
        .reasoning_delta => |delta| {
            try w.writeAll("{\"type\":\"reasoning-delta\",\"index\":");
            try w.print("{d}", .{delta.index});
            try w.writeAll(",\"text\":");
            try std.json.Stringify.value(delta.text, .{}, w);
            try w.writeByte('}');
        },
        .tool_call_delta => |delta| {
            try w.writeAll("{\"type\":\"tool-call-delta\",\"index\":");
            try w.print("{d}", .{delta.index});
            try w.writeAll(",\"id\":");
            try std.json.Stringify.value(delta.id, .{}, w);
            if (delta.name) |name| {
                try w.writeAll(",\"name\":");
                try std.json.Stringify.value(name, .{}, w);
            }
            try w.writeAll(",\"argumentsDelta\":");
            try std.json.Stringify.value(delta.arguments_delta, .{}, w);
            try w.writeByte('}');
        },
        .block_start => |start| {
            try w.writeAll("{\"type\":\"block-start\",\"index\":");
            try w.print("{d}", .{start.index});
            try w.writeAll(",\"blockType\":");
            try std.json.Stringify.value(start.block_type, .{}, w);
            try w.writeByte('}');
        },
        .block_end => |end| {
            try w.writeAll("{\"type\":\"block-end\",\"index\":");
            try w.print("{d}", .{end.index});
            try w.writeAll(",\"block\":");
            try writeContentBlock(w, end.block);
            try w.writeByte('}');
        },
        .usage => |usage| {
            try w.writeAll("{\"type\":\"usage\",\"usage\":");
            try writeUsage(w, usage);
            try w.writeByte('}');
        },
        .finish => |finish| {
            try w.writeAll("{\"type\":\"finish\",\"reason\":{\"kind\":");
            try std.json.Stringify.value(finish.jsonKind(), .{}, w);
            try w.writeAll("}}");
        },
    }
}

const testing = std.testing;

fn pushText(acc: *Accumulator, time_ms: i64, index: u32, text: []const u8) !void {
    _ = try acc.push(time_ms, .{ .chunk = .{ .text_delta = .{ .index = index, .text = text } } });
}

fn renderData(allocator: Allocator, settlement: Settlement) ![]u8 {
    var buffer = Writer.Allocating.init(allocator);
    errdefer buffer.deinit();
    try writeData(&buffer.writer, settlement);
    return buffer.toOwnedSlice();
}

test "provider finish reasons normalize" {
    try testing.expectEqual(Finish.stop, finishFromProvider("stop"));
    try testing.expectEqual(Finish.tool_calls, finishFromProvider("tool_calls"));
    try testing.expectEqual(Finish.tool_calls, finishFromProvider("tool_use"));
    try testing.expectEqual(Finish.max_tokens, finishFromProvider("length"));
    try testing.expectEqual(Finish.max_tokens, finishFromProvider("max_tokens"));
}

test "usage maps prompt/completion/total and nulls to zero" {
    const partial = normalizeUsage(.{
        .prompt_tokens = 7,
        .completion_tokens = null,
        .total_tokens = null,
    });
    try testing.expectEqual(@as(u64, 7), partial.input_tokens);
    try testing.expectEqual(@as(u64, 0), partial.output_tokens);
    try testing.expectEqual(@as(u64, 0), partial.total_tokens.?);

    const zero = normalizeUsage(.{});
    try testing.expectEqual(@as(u64, 0), zero.input_tokens);
    try testing.expectEqual(@as(u64, 0), zero.output_tokens);
    try testing.expectEqual(@as(u64, 0), zero.total_tokens.?);

    const full = normalizeUsage(.{
        .prompt_tokens = 1,
        .completion_tokens = 2,
        .total_tokens = 3,
    });
    try testing.expectEqual(@as(u64, 1), full.input_tokens);
    try testing.expectEqual(@as(u64, 2), full.output_tokens);
    try testing.expectEqual(@as(u64, 3), full.total_tokens.?);
}

test "done stop settles one assistant message with packed text chunks" {
    var acc = Accumulator.init(testing.allocator);
    defer acc.deinit();

    try pushText(&acc, 10, 0, "he");
    try pushText(&acc, 12, 0, "llo");
    try pushText(&acc, 15, 0, " world");
    _ = try acc.push(16, .{ .done = .{
        .finish = .stop,
        .usage = .{ .prompt_tokens = 7, .completion_tokens = 3 },
    } });

    const settlement = try acc.settle("message-1", "test-provider", "test-model");
    try testing.expectEqual(types.MessageRole.assistant, settlement.message.role);
    try testing.expectEqualStrings("message-1", settlement.message.id);
    try testing.expectEqualStrings("test-provider", settlement.message.source.model.provider);
    try testing.expectEqualStrings("test-model", settlement.message.source.model.model);
    try testing.expectEqual(@as(usize, 1), settlement.message.content.len);
    switch (settlement.message.content[0]) {
        .text => |text| try testing.expectEqualStrings("hello world", text),
        else => return error.UnexpectedBlock,
    }
    try testing.expectEqual(@as(u64, 7), settlement.usage.?.input_tokens);
    try testing.expectEqual(@as(u64, 3), settlement.usage.?.output_tokens);
    try testing.expectEqual(@as(u64, 0), settlement.usage.?.total_tokens.?);
    try testing.expect(!settlement.interrupted);
    try testing.expectEqual(Finish.stop, settlement.finish);

    try testing.expectEqual(@as(usize, 3), settlement.stream.len);
    switch (settlement.stream[0]) {
        .text_chunks => |run| {
            try testing.expectEqual(@as(i64, 10), run.time0);
            try testing.expectEqualSlices(i64, &.{ 2, 3 }, run.dt);
            try testing.expectEqual(@as(usize, 3), run.texts.len);
            try testing.expectEqualStrings("he", run.texts[0]);
            try testing.expectEqualStrings("llo", run.texts[1]);
            try testing.expectEqualStrings(" world", run.texts[2]);
        },
        else => return error.UnexpectedRecord,
    }
    switch (settlement.stream[1]) {
        .chunk => |raw| switch (raw.chunk) {
            .usage => |usage| try testing.expectEqual(@as(u64, 7), usage.input_tokens),
            else => return error.UnexpectedChunk,
        },
        else => return error.UnexpectedRecord,
    }
    switch (settlement.stream[2]) {
        .chunk => |raw| switch (raw.chunk) {
            .finish => |finish| try testing.expectEqual(Finish.stop, finish),
            else => return error.UnexpectedChunk,
        },
        else => return error.UnexpectedRecord,
    }

    const json_text = try renderData(testing.allocator, settlement);
    defer testing.allocator.free(json_text);
    try testing.expect(std.mem.indexOf(u8, json_text, "\"role\":\"assistant\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_text, "\"provider\":\"test-provider\"") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        json_text,
        "\"usage\":{\"inputTokens\":7,\"outputTokens\":3,\"totalTokens\":0}",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json_text, "sourceEventSeqs") == null);
    try testing.expect(std.mem.indexOf(u8, json_text, "\"interrupted\"") == null);
}

test "interrupted done keeps only visible text and ignores late chunks" {
    var acc = Accumulator.init(testing.allocator);
    defer acc.deinit();

    try pushText(&acc, 1, 0, "partial answer");
    _ = try acc.push(2, .{ .chunk = .{ .tool_call_delta = .{
        .index = 1,
        .id = "call-test",
        .name = "read",
        .arguments_delta = "{}",
    } } });
    _ = try acc.push(3, .{ .chunk = .{ .reasoning_delta = .{ .index = 2, .text = "thinking" } } });
    _ = try acc.push(4, .{ .done = .{ .finish = .stop, .interrupted = true } });

    const accepted = try acc.push(5, .{ .chunk = .{
        .text_delta = .{ .index = 0, .text = " late" },
    } });
    try testing.expect(!accepted);

    const settlement = try acc.settle("message-2", "test-provider", "test-model");
    try testing.expect(settlement.interrupted);
    try testing.expectEqual(@as(usize, 2), settlement.message.content.len);
    switch (settlement.message.content[0]) {
        .text => |text| try testing.expectEqualStrings("partial answer", text),
        else => return error.UnexpectedBlock,
    }
    switch (settlement.message.content[1]) {
        .reasoning => |text| try testing.expectEqualStrings("thinking", text),
        else => return error.UnexpectedBlock,
    }

    // The lossless stream keeps the tool call but has no terminal finish and
    // no late text.
    try testing.expectEqual(@as(usize, 3), settlement.stream.len);
    switch (settlement.stream[1]) {
        .tool_call_chunks => |run| try testing.expectEqualStrings("call-test", run.id),
        else => return error.UnexpectedRecord,
    }
    for (settlement.stream) |record| {
        switch (record) {
            .chunk => |raw| switch (raw.chunk) {
                .finish => return error.UnexpectedFinish,
                else => {},
            },
            else => {},
        }
    }

    const json_text = try renderData(testing.allocator, settlement);
    defer testing.allocator.free(json_text);
    try testing.expect(std.mem.indexOf(u8, json_text, "\"interrupted\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json_text, "late") == null);
}

test "max-tokens truncation drops tool calls from message content" {
    var acc = Accumulator.init(testing.allocator);
    defer acc.deinit();

    _ = try acc.push(1, .{ .chunk = .{ .block_start = .{ .index = 0, .block_type = "tool-call" } } });
    _ = try acc.push(2, .{ .chunk = .{ .tool_call_delta = .{
        .index = 0,
        .id = "call-test",
        .name = "read",
        .arguments_delta = "{\"file_path\":\"a.txt\"}",
    } } });
    _ = try acc.push(3, .{ .chunk = .{ .block_end = .{ .index = 0, .block = .{ .tool_call = .{
        .id = "call-test",
        .name = "read",
        .arguments = "{\"file_path\":\"a.txt\"}",
    } } } } });
    try pushText(&acc, 4, 1, "truncated");
    _ = try acc.push(5, .{ .done = .{ .finish = .max_tokens } });

    const settlement = try acc.settle("message-3", "test-provider", "test-model");
    try testing.expectEqual(Finish.max_tokens, settlement.finish);
    try testing.expectEqual(@as(usize, 1), settlement.message.content.len);
    switch (settlement.message.content[0]) {
        .text => |text| try testing.expectEqualStrings("truncated", text),
        else => return error.UnexpectedBlock,
    }

    // The stream is lossless: the dropped tool call and the terminal
    // max-tokens finish record remain.
    try testing.expectEqual(@as(usize, 5), settlement.stream.len);
    switch (settlement.stream[4]) {
        .chunk => |raw| switch (raw.chunk) {
            .finish => |finish| try testing.expectEqual(Finish.max_tokens, finish),
            else => return error.UnexpectedChunk,
        },
        else => return error.UnexpectedRecord,
    }
}

test "block-end is authoritative and later deltas stay out of content" {
    var acc = Accumulator.init(testing.allocator);
    defer acc.deinit();

    _ = try acc.push(1, .{ .chunk = .{ .block_start = .{ .index = 0, .block_type = "text" } } });
    try pushText(&acc, 2, 0, "draft");
    _ = try acc.push(3, .{ .chunk = .{ .block_end = .{
        .index = 0,
        .block = .{ .text = "final" },
    } } });
    try pushText(&acc, 4, 0, "ignored");
    _ = try acc.push(5, .{ .done = .{ .finish = .stop } });

    const settlement = try acc.settle("message-4", "test-provider", "test-model");
    try testing.expectEqual(@as(usize, 1), settlement.message.content.len);
    switch (settlement.message.content[0]) {
        .text => |text| try testing.expectEqualStrings("final", text),
        else => return error.UnexpectedBlock,
    }

    var streamed_texts: usize = 0;
    for (settlement.stream) |record| {
        switch (record) {
            .text_chunks => |run| streamed_texts += run.texts.len,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 2), streamed_texts);
}

test "done tool calls are synthesized for delta-less providers" {
    var acc = Accumulator.init(testing.allocator);
    defer acc.deinit();

    const calls = [_]types.ToolCall{
        .{ .id = "call-test", .name = "read", .arguments = "{\"file_path\":\"a.txt\"}" },
    };
    _ = try acc.push(1, .{ .done = .{
        .finish = .tool_calls,
        .tool_calls = &calls,
    } });

    const settlement = try acc.settle("message-5", "test-provider", "test-model");
    try testing.expectEqual(Finish.tool_calls, settlement.finish);
    try testing.expectEqual(@as(usize, 1), settlement.message.content.len);
    switch (settlement.message.content[0]) {
        .tool_call => |call| {
            try testing.expectEqualStrings("call-test", call.id);
            try testing.expectEqualStrings("read", call.name);
            try testing.expectEqualStrings("{\"file_path\":\"a.txt\"}", call.arguments);
        },
        else => return error.UnexpectedBlock,
    }
    try testing.expectEqual(@as(usize, 4), settlement.stream.len);
    switch (settlement.stream[1]) {
        .tool_call_chunks => |run| {
            try testing.expectEqualStrings("call-test", run.id);
            try testing.expectEqualStrings("read", run.name.?);
        },
        else => return error.UnexpectedRecord,
    }
}

test "usage zero and absent normalize as specified" {
    var acc = Accumulator.init(testing.allocator);
    defer acc.deinit();
    try pushText(&acc, 1, 0, "x");
    _ = try acc.push(2, .{ .done = .{ .usage = .{} } });
    const with_zero = try acc.settle("message-6", "test-provider", "test-model");
    try testing.expectEqual(@as(u64, 0), with_zero.usage.?.input_tokens);
    try testing.expectEqual(@as(u64, 0), with_zero.usage.?.output_tokens);
    try testing.expectEqual(@as(u64, 0), with_zero.usage.?.total_tokens.?);

    var absent = Accumulator.init(testing.allocator);
    defer absent.deinit();
    try pushText(&absent, 1, 0, "y");
    _ = try absent.push(2, .{ .done = .{ .finish = .stop } });
    const without_usage = try absent.settle("message-7", "test-provider", "test-model");
    try testing.expect(without_usage.usage == null);

    const json_text = try renderData(testing.allocator, without_usage);
    defer testing.allocator.free(json_text);
    try testing.expect(std.mem.indexOf(u8, json_text, "\"usage\"") == null);
}

fn buildBigAccumulator(allocator: Allocator, text: []const u8) !Accumulator {
    var acc = Accumulator.init(allocator);
    errdefer acc.deinit();
    try pushText(&acc, 1, 0, text);
    return acc;
}

test "arena allocations survive moving the accumulator and free over 64 KiB" {
    const big = try testing.allocator.alloc(u8, 70 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    // Build in a helper and return by value: the arena state moves after the
    // >64 KiB copy was allocated.
    var acc = try buildBigAccumulator(testing.allocator, big);
    defer acc.deinit();
    _ = try acc.push(2, .{ .done = .{ .finish = .stop } });

    const settlement = try acc.settle("message-big", "test-provider", "test-model");
    try testing.expectEqual(@as(usize, 1), settlement.message.content.len);
    switch (settlement.message.content[0]) {
        .text => |text| {
            try testing.expectEqual(big.len, text.len);
            try testing.expect(std.mem.eql(u8, big, text));
        },
        else => return error.UnexpectedBlock,
    }
}
