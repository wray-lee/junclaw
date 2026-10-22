//! P1 fixture replay: drive `input.json` through the real loop/tool scheduler,
//! replay `replay.json` through the provider callback, write the v4 session log
//! and compare its normalized JSONL with `expected.v4.jsonl`.
//!
//! Fixtures are ground truth; see test/fixtures/dsh_native/manifest.json.

const std = @import("std");
const builtins_mod = @import("tools/builtins.zig");
const compat = @import("compat");
const fixture_compare = @import("fixture_compare.zig");
const fs_compat = @import("../../fs_compat.zig");
const inbox = @import("inbox.zig");
const loop_mod = @import("loop.zig");
const prompt = @import("prompt.zig");
const registry = @import("tools/registry.zig");
const replay_provider = @import("replay_provider.zig");
const request = @import("request.zig");
const scheduler = @import("tools/scheduler.zig");
const session_log = @import("session_log.zig");
const stream = @import("stream.zig");
const surface = @import("surface.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Obj = std.json.ObjectMap;

const fixture_root = "test/fixtures/dsh_native";
const test_provider = "fake";
const test_model = "fake";
/// Headless persona used by the recording (manifest openIssues).
const headless_persona = "You are a coding agent powered by the fake model.";
const session_created_at: i64 = 200;

const InputFile = struct {
    steps: []const Step = &.{},

    const Step = struct {
        op: []const u8 = "",
        text: ?[]const u8 = null,
        workspace: ?Value = null,
        config: ?SessionConfig = null,
        when: ?When = null,
        cause: ?[]const u8 = null,
    };

    const SessionConfig = struct {
        maxParallelToolCalls: ?usize = null,
    };

    const When = struct {
        kind: []const u8 = "",
        callId: []const u8 = "",
    };
};

const TriggerOp = enum { steer, abort };
const TriggerKind = enum { tool_started, tool_result };

const Trigger = struct {
    op: TriggerOp,
    kind: TriggerKind,
    call_id: []const u8,
    text: []const u8 = "",
    cause: []const u8 = "user",
};

const Gate = struct {
    mutex: compat.sync.Mutex = .{},
    condition: compat.sync.Condition = .{},
    open: bool = false,

    fn release(self: *Gate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.open = true;
        self.condition.broadcast();
    }

    fn wait(self: *Gate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.open) self.condition.wait(&self.mutex);
    }
};

const PendingCall = struct {
    call: types.ToolCall,
    seq: u64,
};

const Driver = struct {
    arena: Allocator,
    log: *session_log.Log,
    provider: *replay_provider.ReplayProvider,
    registry: *registry.Registry,
    max_parallel: usize,
    system_prompt: []const u8,
    tools: []const request.ToolSchema,
    triggers: []const Trigger,
    loop: ?*loop_mod.Loop = null,
    next_message: u64 = 0,
    first_request: bool = true,
    expected_calls: usize = 0,
    classified: usize = 0,
    gate: Gate = .{},
    surface_messages: std.ArrayListUnmanaged(types.Message) = .empty,
    pending_calls: std.ArrayListUnmanaged(PendingCall) = .empty,

    fn nextId(self: *Driver) ![]const u8 {
        self.next_message += 1;
        return std.fmt.allocPrint(self.arena, "msg-{d}", .{self.next_message});
    }

    fn append(self: *Driver, event_type: []const u8, data: Value, surface_op: ?types.SurfaceOp) !u64 {
        return self.log.append(event_type, data, .{ .time_ms = 0, .surface_op = surface_op });
    }
};

// ---------------------------------------------------------------------------
// Host callbacks
// ---------------------------------------------------------------------------

fn hostEmit(context: *anyopaque, event: loop_mod.Event) anyerror!u64 {
    const d: *Driver = @ptrCast(@alignCast(context));
    const allocator = d.arena;
    switch (event) {
        .turn_start => |payload| {
            return d.append("turn/start", .{ .object = try objectValue(allocator, &.{
                .{ "turn", .{ .integer = @intCast(payload.turn) } },
            }) }, null);
        },
        .step_start => |position| {
            return d.append("step/start", .{ .object = try positionValue(allocator, position) }, null);
        },
        .system_message => |payload| {
            var message: Obj = .empty;
            try message.put(allocator, "role", .{ .string = "system" });
            try message.put(allocator, "content", try textBlocks(allocator, payload.message.text));
            try message.put(allocator, "source", .{ .object = try objectValue(allocator, &.{
                .{ "kind", .{ .string = "system-prompt" } },
            }) });
            try message.put(allocator, "id", .{ .string = payload.message.id });
            var data = try positionValue(allocator, payload.position);
            try data.put(allocator, "message", .{ .object = message });
            return d.append("system/message", .{ .object = data }, .append);
        },
        .user_message => |payload| {
            const data = try fixture_compare.parseJson(allocator, payload.message.json);
            return d.append("user/message", data, .append);
        },
        .request_start => |payload| {
            var seq: u64 = 0;
            if (payload.header.append) {
                var data: Obj = .empty;
                try data.put(allocator, "header", try headerValue(allocator, payload.header.header));
                try data.put(allocator, "reason", .{ .string = headerReasonName(payload.header.reason) });
                seq = try d.append("request/header", .{ .object = data }, null);
            }
            if (d.first_request) {
                d.first_request = false;
                const context_data = try objectValue(allocator, &.{
                    .{ "provider", .{ .string = test_provider } },
                    .{ "model", .{ .string = test_model } },
                });
                _ = try d.append("request/context", .{ .object = context_data }, null);
            }
            return seq;
        },
        .assistant_stream => return 0,
        .assistant_message => |payload| {
            d.expected_calls = 0;
            for (payload.settlement.message.content) |block| {
                if (block == .tool_call) d.expected_calls += 1;
            }
            try d.surface_messages.append(allocator, try cloneMessage(allocator, payload.settlement.message));
            var data = try positionValue(allocator, payload.position);
            try data.put(allocator, "message", try messageValue(allocator, payload.settlement.message));
            if (payload.settlement.usage) |usage| {
                try data.put(allocator, "usage", try usageValue(allocator, usage));
            }
            try data.put(allocator, "stream", try streamArray(allocator, payload.settlement.stream));
            if (payload.settlement.interrupted) try data.put(allocator, "interrupted", .{ .bool = true });
            return d.append("assistant/message", .{ .object = data }, .append);
        },
        .assistant_attempt => return error.UnsupportedEvent,
        .tool_call => |payload| {
            var data = try positionValue(allocator, payload.position);
            try data.put(allocator, "callId", .{ .string = payload.call.id });
            try data.put(allocator, "name", .{ .string = payload.call.name });
            try data.put(allocator, "arguments", .{ .string = payload.call.arguments });
            const seq = try d.append("tool/call", .{ .object = data }, null);
            try d.pending_calls.append(allocator, .{ .call = payload.call, .seq = seq });
            for (d.triggers) |trigger| {
                if (trigger.op == .abort and trigger.kind == .tool_started and
                    std.mem.eql(u8, trigger.call_id, payload.call.id))
                {
                    if (d.loop) |l| l.abort(abortCause(trigger.cause));
                }
            }
            return seq;
        },
        .tool_result => |payload| {
            if (d.pending_calls.items.len == 0) return error.UnexpectedEvent;
            const pending = d.pending_calls.orderedRemove(0);
            const call = pending.call;
            const id = try d.nextId();
            const message = try toolResultMessage(allocator, id, call, payload.result);
            try d.surface_messages.append(allocator, try cloneMessage(allocator, .{
                .id = id,
                .role = .tool,
                .content = payload.result.content(),
                .source = .{ .tool = .{ .call_id = call.id } },
                .tool_call_id = call.id,
                .is_error = payload.result.isError(),
            }));
            var data = try positionValue(allocator, payload.position);
            try data.put(allocator, "message", message);
            switch (payload.result) {
                .success => |success| {
                    if (success.meta) |meta| try data.put(allocator, "meta", meta);
                },
                .failure => |failure| {
                    var error_value: Obj = .empty;
                    try error_value.put(allocator, "name", .{ .string = failure.error_info.name });
                    try error_value.put(allocator, "code", .{ .string = failure.error_info.code });
                    if (failure.error_info.reason) |reason| {
                        try error_value.put(allocator, "reason", .{ .string = reason });
                    }
                    try data.put(allocator, "error", .{ .object = error_value });
                    if (failure.meta) |meta| try data.put(allocator, "meta", meta);
                },
            }
            const source_seqs = [_]u64{pending.seq};
            const seq = try d.log.append("tool/result", .{ .object = data }, .{
                .time_ms = 0,
                .surface_op = .append,
                .source_event_seqs = &source_seqs,
            });
            for (d.triggers) |trigger| {
                if (trigger.op == .steer and trigger.kind == .tool_result and
                    std.mem.eql(u8, trigger.call_id, call.id))
                {
                    try queueSteer(d, trigger.text);
                }
            }
            return seq;
        },
        .step_end => |position| {
            return d.append("step/end", .{ .object = try positionValue(allocator, position) }, null);
        },
        .turn_end => |payload| {
            var data = try objectValue(allocator, &.{
                .{ "turn", .{ .integer = @intCast(payload.turn) } },
            });
            try data.put(allocator, "reason", try endReasonValue(allocator, payload.reason));
            return d.append("turn/end", .{ .object = data }, null);
        },
    }
}

fn hostSystemMessages(
    context: *anyopaque,
    allocator: Allocator,
    position: loop_mod.Position,
    out: *std.ArrayListUnmanaged(loop_mod.SystemMessage),
) anyerror!void {
    if (position.step != 1) return;
    const d: *Driver = @ptrCast(@alignCast(context));
    const id = try std.fmt.allocPrint(allocator, "system-{d}", .{position.turn});
    try out.append(allocator, .{ .id = id, .text = d.system_prompt });
}

fn hostPreStep(
    context: *anyopaque,
    allocator: Allocator,
    position: loop_mod.Position,
    claimed: loop_mod.Claimed,
    out: *std.ArrayListUnmanaged(loop_mod.UserMessage),
) anyerror!loop_mod.PreStepDecision {
    _ = allocator;
    _ = out;
    const d: *Driver = @ptrCast(@alignCast(context));
    _ = position;
    if (claimed.next_turn.len > 0) {
        const data = try objectValue(d.arena, &.{
            .{ "target", .{ .string = "next-turn" } },
            .{ "start", .{ .integer = 0 } },
            .{ "removedCount", .{ .integer = @intCast(claimed.next_turn.len) } },
            .{ "inserted", try emptyArray(d.arena) },
        });
        _ = try d.append("agent/inbox/spliced", .{ .object = data }, null);
    }
    if (claimed.next_step.len > 0) {
        const data = try objectValue(d.arena, &.{
            .{ "target", .{ .string = "next-step" } },
            .{ "start", .{ .integer = 0 } },
            .{ "removedCount", .{ .integer = @intCast(claimed.next_step.len) } },
            .{ "inserted", try emptyArray(d.arena) },
        });
        _ = try d.append("agent/inbox/spliced", .{ .object = data }, null);
    }
    return .{};
}

fn hostSerializeMessage(
    context: *anyopaque,
    allocator: Allocator,
    message: types.Message,
) anyerror![]u8 {
    _ = context;
    const value = try messageValue(allocator, message);
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn providerBegin(context: *anyopaque, view: loop_mod.RequestView) anyerror!void {
    const d: *Driver = @ptrCast(@alignCast(context));
    const messages = try d.arena.dupe(types.Message, d.surface_messages.items);
    try d.provider.startCall(.{
        .provider = view.provider,
        .model = view.model,
        .messages = messages,
    });
}

fn providerNext(context: *anyopaque) anyerror!?stream.Event {
    const d: *Driver = @ptrCast(@alignCast(context));
    return d.provider.nextEvent();
}

fn providerCancel(context: *anyopaque) void {
    const d: *Driver = @ptrCast(@alignCast(context));
    d.provider.endCall();
}

fn classifierIsSafe(context: *anyopaque, call: types.ToolCall) bool {
    const d: *Driver = @ptrCast(@alignCast(context));
    const safe = d.max_parallel > 1 and isReadOnly(call.name);
    d.classified += 1;
    if (!safe or d.classified >= d.expected_calls) d.gate.release();
    return safe;
}

fn dispatcherCall(
    context: *anyopaque,
    allocator: Allocator,
    call: types.ToolCall,
    signal: scheduler.Signal,
) anyerror!registry.ToolResult {
    const d: *Driver = @ptrCast(@alignCast(context));
    if (signal.isAborted()) return error.Aborted;
    if (d.max_parallel > 1 and isReadOnly(call.name)) d.gate.wait();
    if (signal.isAborted()) return error.Aborted;
    const args = try std.json.parseFromSliceLeaky(Value, allocator, call.arguments, .{
        .allocate = .alloc_always,
    });
    return d.registry.invoke(allocator, call.name, args);
}

fn isReadOnly(name: []const u8) bool {
    return std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "grep") or
        std.mem.eql(u8, name, "glob");
}

fn abortCause(name: []const u8) types.AbortCause {
    if (std.mem.eql(u8, name, "parent")) return .parent;
    if (std.mem.eql(u8, name, "hook")) return .{ .hook = "fixture" };
    if (std.mem.eql(u8, name, "disposed")) return .disposed;
    if (std.mem.eql(u8, name, "legacy")) return .legacy;
    return .user;
}

// ---------------------------------------------------------------------------
// Queueing
// ---------------------------------------------------------------------------

fn queueSteer(d: *Driver, text: []const u8) !void {
    const id = try d.nextId();
    const json = try userMessageJson(d.arena, id, text);
    try d.surface_messages.append(d.arena, .{
        .id = id,
        .role = .user,
        .content = &.{.{ .text = text }},
        .source = .user,
    });
    const data = try objectValue(d.arena, &.{
        .{ "target", .{ .string = "next-step" } },
        .{ "start", .{ .integer = 0 } },
        .{ "inserted", try messageArray(d.arena, &.{try fixture_compare.parseJson(d.arena, json)}) },
    });
    _ = try d.append("agent/inbox/spliced", .{ .object = data }, null);
    if (d.loop) |l| _ = try l.steer(.{ .id = id, .data = json });
}

fn queuePrompt(d: *Driver, text: []const u8) !void {
    const id = try d.nextId();
    const json = try userMessageJson(d.arena, id, text);
    try d.surface_messages.append(d.arena, .{
        .id = id,
        .role = .user,
        .content = &.{.{ .text = text }},
        .source = .user,
    });
    const data = try objectValue(d.arena, &.{
        .{ "target", .{ .string = "next-turn" } },
        .{ "start", .{ .integer = 0 } },
        .{ "inserted", try messageArray(d.arena, &.{try fixture_compare.parseJson(d.arena, json)}) },
    });
    _ = try d.append("agent/inbox/spliced", .{ .object = data }, null);
    if (d.loop) |l| _ = try l.followup(.{ .id = id, .data = json });
}

// ---------------------------------------------------------------------------
// Value builders
// ---------------------------------------------------------------------------

fn objectValue(allocator: Allocator, entries: []const struct { []const u8, Value }) !Obj {
    var object: Obj = .empty;
    for (entries) |entry| try object.put(allocator, entry[0], entry[1]);
    return object;
}

fn emptyArray(allocator: Allocator) !Value {
    return .{ .array = std.json.Array.init(allocator) };
}

fn messageArray(allocator: Allocator, items: []const Value) !Value {
    var array = std.json.Array.init(allocator);
    try array.ensureTotalCapacity(items.len);
    for (items) |item| array.appendAssumeCapacity(item);
    return .{ .array = array };
}

fn positionValue(allocator: Allocator, position: loop_mod.Position) !Obj {
    var object: Obj = .empty;
    try object.put(allocator, "turn", .{ .integer = @intCast(position.turn) });
    try object.put(allocator, "step", .{ .integer = @intCast(position.step) });
    return object;
}

fn textBlocks(allocator: Allocator, text: []const u8) !Value {
    const block = try objectValue(allocator, &.{
        .{ "type", .{ .string = "text" } },
        .{ "text", .{ .string = text } },
    });
    return messageArray(allocator, &.{.{ .object = block }});
}

fn cloneMessage(allocator: Allocator, message: types.Message) !types.Message {
    const blocks = try allocator.alloc(types.ContentBlock, message.content.len);
    for (message.content, 0..) |block, index| {
        blocks[index] = switch (block) {
            .text => |text| .{ .text = try allocator.dupe(u8, text) },
            .reasoning => |text| .{ .reasoning = try allocator.dupe(u8, text) },
            .tool_call => |call| .{ .tool_call = .{
                .id = try allocator.dupe(u8, call.id),
                .name = try allocator.dupe(u8, call.name),
                .arguments = try allocator.dupe(u8, call.arguments),
            } },
            .raw => |value| .{ .raw = try std.json.parseFromSliceLeaky(
                Value,
                allocator,
                try std.json.Stringify.valueAlloc(allocator, value, .{}),
                .{ .allocate = .alloc_always },
            ) },
        };
    }
    return .{
        .id = try allocator.dupe(u8, message.id),
        .role = message.role,
        .content = blocks,
        .source = switch (message.source) {
            .user => .user,
            .system_prompt => .system_prompt,
            .model => |source| .{ .model = .{
                .provider = try allocator.dupe(u8, source.provider),
                .model = try allocator.dupe(u8, source.model),
            } },
            .tool => |source| .{ .tool = .{ .call_id = try allocator.dupe(u8, source.call_id) } },
            .other => |value| .{ .other = try std.json.parseFromSliceLeaky(
                Value,
                allocator,
                try std.json.Stringify.valueAlloc(allocator, value, .{}),
                .{ .allocate = .alloc_always },
            ) },
        },
        .tool_call_id = if (message.tool_call_id) |call_id| try allocator.dupe(u8, call_id) else null,
        .is_error = message.is_error,
    };
}

fn userMessageJson(allocator: Allocator, id: []const u8, text: []const u8) ![]u8 {
    var message: Obj = .empty;
    try message.put(allocator, "content", try textBlocks(allocator, text));
    try message.put(allocator, "source", .{ .object = try objectValue(allocator, &.{
        .{ "kind", .{ .string = "user" } },
    }) });
    try message.put(allocator, "role", .{ .string = "user" });
    try message.put(allocator, "id", .{ .string = id });
    return std.json.Stringify.valueAlloc(allocator, Value{ .object = message }, .{});
}

fn contentBlockValue(allocator: Allocator, block: types.ContentBlock) !Value {
    switch (block) {
        .text => |text| return .{ .object = try objectValue(allocator, &.{
            .{ "type", .{ .string = "text" } },
            .{ "text", .{ .string = text } },
        }) },
        .reasoning => |text| return .{ .object = try objectValue(allocator, &.{
            .{ "type", .{ .string = "reasoning" } },
            .{ "text", .{ .string = text } },
        }) },
        .tool_call => |call| return .{ .object = try objectValue(allocator, &.{
            .{ "type", .{ .string = "tool-call" } },
            .{ "id", .{ .string = call.id } },
            .{ "name", .{ .string = call.name } },
            .{ "arguments", .{ .string = call.arguments } },
        }) },
        .raw => |value| return value,
    }
}

fn messageValue(allocator: Allocator, message: types.Message) !Value {
    var object: Obj = .empty;
    try object.put(allocator, "role", .{ .string = @tagName(message.role) });
    const blocks = try allocator.alloc(Value, message.content.len);
    for (message.content, 0..) |block, index| blocks[index] = try contentBlockValue(allocator, block);
    try object.put(allocator, "content", try messageArray(allocator, blocks));
    const source_value: Value = switch (message.source) {
        .user => .{ .object = try objectValue(allocator, &.{.{ "kind", .{ .string = "user" } }}) },
        .system_prompt => .{ .object = try objectValue(allocator, &.{.{ "kind", .{ .string = "system-prompt" } }}) },
        .model => |source| .{ .object = try objectValue(allocator, &.{
            .{ "kind", .{ .string = "model" } },
            .{ "provider", .{ .string = source.provider } },
            .{ "model", .{ .string = source.model } },
        }) },
        .tool => |source| .{ .object = try objectValue(allocator, &.{
            .{ "kind", .{ .string = "tool" } },
            .{ "callId", .{ .string = source.call_id } },
        }) },
        .other => |value| value,
    };
    try object.put(allocator, "source", source_value);
    try object.put(allocator, "id", .{ .string = message.id });
    if (message.tool_call_id) |call_id| {
        try object.put(allocator, "toolCallId", .{ .string = call_id });
    }
    if (message.is_error) |is_error| {
        try object.put(allocator, "isError", .{ .bool = is_error });
    }
    return .{ .object = object };
}

fn toolResultMessage(
    allocator: Allocator,
    id: []const u8,
    call: types.ToolCall,
    result: registry.ToolResult,
) !Value {
    return messageValue(allocator, .{
        .id = id,
        .role = .tool,
        .content = result.content(),
        .source = .{ .tool = .{ .call_id = call.id } },
        .tool_call_id = call.id,
        .is_error = result.isError(),
    });
}

fn usageValue(allocator: Allocator, usage: types.Usage) !Value {
    var object: Obj = .empty;
    try object.put(allocator, "inputTokens", .{ .integer = @intCast(usage.input_tokens) });
    try object.put(allocator, "outputTokens", .{ .integer = @intCast(usage.output_tokens) });
    if (usage.total_tokens) |value| {
        try object.put(allocator, "totalTokens", .{ .integer = @intCast(value) });
    }
    if (usage.cache_read_tokens) |value| {
        try object.put(allocator, "cacheReadTokens", .{ .integer = @intCast(value) });
    }
    if (usage.cache_write_tokens) |value| {
        try object.put(allocator, "cacheWriteTokens", .{ .integer = @intCast(value) });
    }
    if (usage.reasoning_tokens) |value| {
        try object.put(allocator, "reasoningTokens", .{ .integer = @intCast(value) });
    }
    return .{ .object = object };
}

fn chunkValue(allocator: Allocator, chunk: stream.Chunk) !Value {
    switch (chunk) {
        .text_delta => |delta| return .{ .object = try objectValue(allocator, &.{
            .{ "type", .{ .string = "text-delta" } },
            .{ "index", .{ .integer = @intCast(delta.index) } },
            .{ "text", .{ .string = delta.text } },
        }) },
        .reasoning_delta => |delta| return .{ .object = try objectValue(allocator, &.{
            .{ "type", .{ .string = "reasoning-delta" } },
            .{ "index", .{ .integer = @intCast(delta.index) } },
            .{ "text", .{ .string = delta.text } },
        }) },
        .tool_call_delta => |delta| {
            var object = try objectValue(allocator, &.{
                .{ "type", .{ .string = "tool-call-delta" } },
                .{ "index", .{ .integer = @intCast(delta.index) } },
                .{ "id", .{ .string = delta.id } },
                .{ "argumentsDelta", .{ .string = delta.arguments_delta } },
            });
            if (delta.name) |name| try object.put(allocator, "name", .{ .string = name });
            return .{ .object = object };
        },
        .block_start => |start| return .{ .object = try objectValue(allocator, &.{
            .{ "type", .{ .string = "block-start" } },
            .{ "index", .{ .integer = @intCast(start.index) } },
            .{ "blockType", .{ .string = start.block_type } },
        }) },
        .block_end => |end| return .{ .object = try objectValue(allocator, &.{
            .{ "type", .{ .string = "block-end" } },
            .{ "index", .{ .integer = @intCast(end.index) } },
            .{ "block", try contentBlockValue(allocator, end.block) },
        }) },
        .usage => |usage| return .{ .object = try objectValue(allocator, &.{
            .{ "type", .{ .string = "usage" } },
            .{ "usage", try usageValue(allocator, usage) },
        }) },
        .finish => |finish| return .{ .object = try objectValue(allocator, &.{
            .{ "type", .{ .string = "finish" } },
            .{ "reason", .{ .object = try objectValue(allocator, &.{
                .{ "kind", .{ .string = finishName(finish) } },
            }) } },
        }) },
    }
}

fn finishName(finish: stream.Finish) []const u8 {
    return switch (finish) {
        .stop => "stop",
        .tool_calls => "tool-calls",
        .max_tokens => "max-tokens",
    };
}

fn streamRecordValue(allocator: Allocator, record: stream.StreamRecord) !Value {
    switch (record) {
        .text_chunks => |run| return .{ .object = try textRunValue(allocator, "text-chunks", run) },
        .reasoning_chunks => |run| return .{ .object = try textRunValue(allocator, "reasoning-chunks", run) },
        .tool_call_chunks => |run| {
            var object = try objectValue(allocator, &.{
                .{ "type", .{ .string = "tool-call-chunks" } },
                .{ "time0", .{ .integer = run.time0 } },
                .{ "index", .{ .integer = @intCast(run.index) } },
                .{ "dt", try i64Array(allocator, run.dt) },
                .{ "id", .{ .string = run.id } },
            });
            if (run.name) |name| try object.put(allocator, "name", .{ .string = name });
            try object.put(allocator, "args", try stringArray(allocator, run.args));
            return .{ .object = object };
        },
        .chunk => |raw| return .{ .object = try objectValue(allocator, &.{
            .{ "type", .{ .string = "chunk" } },
            .{ "time", .{ .integer = raw.time } },
            .{ "chunk", try chunkValue(allocator, raw.chunk) },
        }) },
    }
}

fn textRunValue(allocator: Allocator, kind: []const u8, run: stream.TextRun) !Obj {
    return objectValue(allocator, &.{
        .{ "type", .{ .string = kind } },
        .{ "time0", .{ .integer = run.time0 } },
        .{ "index", .{ .integer = @intCast(run.index) } },
        .{ "dt", try i64Array(allocator, run.dt) },
        .{ "texts", try stringArray(allocator, run.texts) },
    });
}

fn streamArray(allocator: Allocator, records: []const stream.StreamRecord) !Value {
    const items = try allocator.alloc(Value, records.len);
    for (records, 0..) |record, index| items[index] = try streamRecordValue(allocator, record);
    return messageArray(allocator, items);
}

fn i64Array(allocator: Allocator, values: []const i64) !Value {
    const items = try allocator.alloc(Value, values.len);
    for (values, 0..) |value, index| items[index] = .{ .integer = value };
    return messageArray(allocator, items);
}

fn stringArray(allocator: Allocator, values: []const []const u8) !Value {
    const items = try allocator.alloc(Value, values.len);
    for (values, 0..) |value, index| items[index] = .{ .string = value };
    return messageArray(allocator, items);
}

fn headerValue(allocator: Allocator, header: request.Header) !Value {
    var object: Obj = .empty;
    var config: Obj = .empty;
    try config.put(allocator, "provider", .{ .string = header.config.provider });
    try config.put(allocator, "model", .{ .string = header.config.model });
    if (header.config.reasoning_effort) |effort| {
        try config.put(allocator, "reasoningEffort", .{ .string = effort });
    }
    if (header.config.max_tokens) |max_tokens| {
        try config.put(allocator, "maxTokens", .{ .integer = @intCast(max_tokens) });
    }
    try object.put(allocator, "config", .{ .object = config });
    if (header.tools) |tools| {
        const items = try allocator.alloc(Value, tools.len);
        for (tools, 0..) |tool, index| {
            var tool_object: Obj = .empty;
            try tool_object.put(allocator, "name", .{ .string = tool.name });
            try tool_object.put(allocator, "description", .{ .string = tool.description });
            try tool_object.put(allocator, "parameters", try fixture_compare.parseJson(allocator, tool.parameters_json));
            items[index] = .{ .object = tool_object };
        }
        try object.put(allocator, "tools", try messageArray(allocator, items));
    }
    return .{ .object = object };
}

fn headerReasonName(reason: request.HeaderReason) []const u8 {
    return switch (reason) {
        .initial => "initial",
        .@"resume" => "resume",
        .change => "change",
        .series => "series",
    };
}

fn endReasonValue(allocator: Allocator, reason: types.EndReason) !Value {
    switch (reason) {
        .completed => return .{ .object = try objectValue(allocator, &.{
            .{ "kind", .{ .string = "completed" } },
        }) },
        .max_tokens => return .{ .object = try objectValue(allocator, &.{
            .{ "kind", .{ .string = "max-tokens" } },
        }) },
        .blocked => return .{ .object = try objectValue(allocator, &.{
            .{ "kind", .{ .string = "blocked" } },
        }) },
        .interrupted => return .{ .object = try objectValue(allocator, &.{
            .{ "kind", .{ .string = "interrupted" } },
        }) },
        .forked => return .{ .object = try objectValue(allocator, &.{
            .{ "kind", .{ .string = "forked" } },
        }) },
        .aborted => |cause| {
            var object: Obj = .empty;
            try object.put(allocator, "kind", .{ .string = "aborted" });
            try object.put(allocator, "reason", switch (cause) {
                .user => .{ .object = try objectValue(allocator, &.{.{ "kind", .{ .string = "user" } }}) },
                .parent => .{ .object = try objectValue(allocator, &.{.{ "kind", .{ .string = "parent" } }}) },
                .hook => |hook_reason| .{ .object = try objectValue(allocator, &.{
                    .{ "kind", .{ .string = "hook" } },
                    .{ "reason", .{ .string = hook_reason } },
                }) },
                .disposed => .{ .object = try objectValue(allocator, &.{.{ "kind", .{ .string = "disposed" } }}) },
                .legacy => .{ .object = try objectValue(allocator, &.{.{ "kind", .{ .string = "legacy" } }}) },
            });
            return .{ .object = object };
        },
        .failure => |failure| {
            var error_object: Obj = .empty;
            try error_object.put(allocator, "message", .{ .string = failure.message });
            try error_object.put(allocator, "code", .{ .string = failure.code });
            return .{ .object = try objectValue(allocator, &.{
                .{ "kind", .{ .string = "error" } },
                .{ "error", .{ .object = error_object } },
            }) };
        },
    }
}

// ---------------------------------------------------------------------------
// Fixture run
// ---------------------------------------------------------------------------

fn runFixture(scenario: []const u8) !void {
    const allocator = std.testing.allocator;
    const dir = try std.fs.path.join(allocator, &.{ fixture_root, scenario });
    defer allocator.free(dir);

    var fixture_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer fixture_arena_state.deinit();
    const fixture_allocator = fixture_arena_state.allocator();

    const input_bytes = try fixture_compare.readFixture(allocator, dir, "input.json");
    defer allocator.free(input_bytes);
    const input = try std.json.parseFromSliceLeaky(InputFile, fixture_allocator, input_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });

    const replay_bytes = try fixture_compare.readFixture(allocator, dir, "replay.json");
    defer allocator.free(replay_bytes);
    const expected_bytes = try fixture_compare.readFixture(allocator, dir, "expected.v4.jsonl");
    defer allocator.free(expected_bytes);
    const expected_records = try fixture_compare.parseJsonl(fixture_allocator, expected_bytes);
    const manifest_bytes = try fixture_compare.readFixture(allocator, dir, "manifest.json");
    defer allocator.free(manifest_bytes);
    const manifest = try fixture_compare.parseJson(fixture_allocator, manifest_bytes);

    var declared: std.StringHashMapUnmanaged(void) = .empty;
    var ordinal: std.StringHashMapUnmanaged(void) = .empty;
    try fixture_compare.loadDeclaredTokens(allocator, manifest, &declared, &ordinal);
    defer declared.deinit(allocator);
    defer ordinal.deinit(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = compat.fs.Dir.wrap(tmp.dir);
    const root = try tmp_dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const cwd = try std.fs.path.join(allocator, &.{ root, "workspace" });
    defer allocator.free(cwd);
    try fs_compat.makePath(cwd);
    const log_path = try std.fs.path.join(allocator, &.{ root, "session.v4.jsonl" });
    defer allocator.free(log_path);
    const spill_dir = try std.fs.path.join(allocator, &.{ root, "spill" });
    defer allocator.free(spill_dir);

    var max_parallel: usize = scheduler.DEFAULT_MAX_PARALLEL_TOOL_CALLS;
    var prompt_text: ?[]const u8 = null;
    var triggers: std.ArrayListUnmanaged(Trigger) = .empty;
    defer triggers.deinit(fixture_allocator);
    for (input.steps) |step| {
        if (std.mem.eql(u8, step.op, "initialize")) continue;
        if (std.mem.eql(u8, step.op, "newSession")) {
            if (step.config) |config| {
                if (config.maxParallelToolCalls) |value| max_parallel = value;
            }
            if (step.workspace) |workspace_value| {
                const files = switch (workspace_value) {
                    .object => |object| object,
                    else => return error.InvalidWorkspace,
                };
                var iterator = files.iterator();
                while (iterator.next()) |entry| {
                    const content = switch (entry.value_ptr.*) {
                        .string => |text| text,
                        else => return error.InvalidWorkspace,
                    };
                    const path = try std.fs.path.join(allocator, &.{ cwd, entry.key_ptr.* });
                    defer allocator.free(path);
                    if (std.fs.path.dirname(path)) |parent| try fs_compat.makePath(parent);
                    const file = try fs_compat.createPath(path, .{ .truncate = true });
                    defer file.close();
                    try file.writeAll(content);
                }
            }
            continue;
        }
        if (std.mem.eql(u8, step.op, "prompt")) {
            if (prompt_text != null) return error.UnsupportedInput;
            prompt_text = step.text orelse return error.MissingPrompt;
            continue;
        }
        if (std.mem.eql(u8, step.op, "steer") or std.mem.eql(u8, step.op, "abort")) {
            const when = step.when orelse return error.MissingTrigger;
            try triggers.append(fixture_allocator, .{
                .op = if (std.mem.eql(u8, step.op, "steer")) .steer else .abort,
                .kind = if (std.mem.eql(u8, when.kind, "tool-started")) .tool_started else .tool_result,
                .call_id = when.callId,
                .text = step.text orelse "",
                .cause = step.cause orelse "user",
            });
            continue;
        }
        return error.UnsupportedInput;
    }
    const user_prompt = prompt_text orelse return error.MissingPrompt;

    var provider = try replay_provider.ReplayProvider.initFromJson(allocator, replay_bytes);
    defer provider.deinit();

    var builtins = builtins_mod.Builtins{ .cwd = cwd, .spill_dir = spill_dir };
    var tool_registry = registry.Registry.init();
    defer tool_registry.deinit(allocator);
    try builtins.register(&tool_registry, allocator);

    const tools = try orderedToolSchemas(allocator);
    defer allocator.free(tools);

    var log = try session_log.Log.create(allocator, log_path, .{
        .id = "fixture-session",
        .created_at = session_created_at,
        .cwd = cwd,
        .is_seeded = false,
        .delegation_depth = 0,
    });

    var driver = Driver{
        .arena = fixture_allocator,
        .log = &log,
        .provider = &provider,
        .registry = &tool_registry,
        .max_parallel = max_parallel,
        .system_prompt = try prompt.buildSystemPrompt(fixture_allocator, .{
            .persona_prefix = headless_persona,
        }),
        .tools = tools,
        .triggers = triggers.items,
    };
    try appendSessionDefaults(&driver);

    const loop_arena = std.heap.ArenaAllocator.init(allocator);
    var loop = loop_mod.Loop.init(loop_arena, .{
        .provider = test_provider,
        .model = test_model,
        .tools = tools,
        .max_parallel_tools = max_parallel,
    }, .{
        .context = &driver,
        .emit = hostEmit,
        .system_messages = hostSystemMessages,
        .pre_step = hostPreStep,
        .serialize_message = hostSerializeMessage,
        .provider = .{
            .context = &driver,
            .begin = providerBegin,
            .next = providerNext,
            .cancel = providerCancel,
        },
        .classifier = .{ .context = &driver, .is_concurrency_safe = classifierIsSafe },
        .dispatcher = .{ .context = &driver, .dispatch = dispatcherCall },
    });
    defer loop.deinit();
    driver.loop = &loop;

    try queuePrompt(&driver, user_prompt);
    const outcome = try loop.runTurn();
    switch (outcome) {
        .ended => {},
        .paused => return error.UnexpectedPause,
    }
    try std.testing.expectEqual(provider.callCount(), provider.recordedRequests().len);
    for (provider.recordedRequests()) |recorded| {
        try std.testing.expectEqualStrings(test_provider, recorded.provider);
        try std.testing.expectEqualStrings(test_model, recorded.model);
        try std.testing.expect(recorded.messages.len > 0);
    }

    log.close();
    var read = try session_log.readLog(allocator, log_path);
    defer read.deinit();

    const log_bytes = try fs_compat.readFileAlloc(compat.fs.cwd(), fixture_allocator, log_path, 1 << 20);
    const actual_records = try fixture_compare.parseJsonl(fixture_allocator, log_bytes);
    var normalizer = fixture_compare.Normalizer{
        .arena = fixture_allocator,
        .declared = &declared,
        .ordinal = &ordinal,
        .cwd = cwd,
    };
    try normalizer.expectLog(expected_records, actual_records);

    const expected_events = try fixture_compare.eventsFromRecords(fixture_allocator, expected_records);
    var expected_fold = try surface.fold(allocator, expected_events);
    defer expected_fold.deinit();
    var actual_fold = try surface.fold(allocator, read.events);
    defer actual_fold.deinit();
    try std.testing.expectEqual(expected_fold.nodes.len, actual_fold.nodes.len);
    for (expected_fold.nodes, actual_fold.nodes) |expected_node, actual_node| {
        try normalizer.expectMessagesMatch(expected_node.message, actual_node.message);
    }

    try expectWorkspaceEffects(fixture_allocator, expected_records, cwd);
}

fn appendSessionDefaults(d: *Driver) !void {
    const allocator = d.arena;
    _ = try d.append("permission/preset", .{ .object = try objectValue(allocator, &.{
        .{ "preset", .{ .string = "workspace-write" } },
    }) }, null);
    _ = try d.append("sandbox/mode", .{ .object = try objectValue(allocator, &.{
        .{ "mode", .{ .string = "workspace-write" } },
    }) }, null);
    _ = try d.append("approval/policy", .{ .object = try objectValue(allocator, &.{
        .{ "policy", .{ .string = "ask" } },
    }) }, null);
}

fn orderedToolSchemas(allocator: Allocator) ![]request.ToolSchema {
    const names = try allocator.alloc([]const u8, registry.core_schemas.len);
    defer allocator.free(names);
    for (registry.core_schemas, 0..) |schema, index| names[index] = schema.name;
    const ordered = try prompt.orderTools(allocator, names, null);
    defer allocator.free(ordered);

    const tools = try allocator.alloc(request.ToolSchema, ordered.len);
    for (ordered, 0..) |name, index| {
        const schema = findSchema(name) orelse return error.MissingToolSchema;
        tools[index] = .{
            .name = schema.name,
            .description = schema.description,
            .parameters_json = schema.input_schema_json,
        };
    }
    return tools;
}

fn findSchema(name: []const u8) ?registry.Schema {
    for (registry.core_schemas) |schema| {
        if (std.mem.eql(u8, schema.name, name)) return schema;
    }
    return null;
}

/// Layer ⑥: every recorded `write` tool call must have left the expected file.
fn expectWorkspaceEffects(allocator: Allocator, records: []const Value, cwd: []const u8) !void {
    for (records) |record| {
        const object = switch (record) {
            .object => |value| value,
            else => continue,
        };
        const record_type = object.get("type") orelse continue;
        if (record_type != .string or !std.mem.eql(u8, record_type.string, "tool/call")) continue;
        const data = switch (object.get("data") orelse continue) {
            .object => |value| value,
            else => continue,
        };
        const name = switch (data.get("name") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, name, "write")) continue;
        const arguments = switch (data.get("arguments") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        const parsed = try fixture_compare.parseJson(allocator, arguments);
        const args = switch (parsed) {
            .object => |value| value,
            else => continue,
        };
        const file_path = switch (args.get("file_path") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        const content = switch (args.get("content") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        const path = if (std.fs.path.isAbsolute(file_path))
            try allocator.dupe(u8, file_path)
        else
            try std.fs.path.join(allocator, &.{ cwd, file_path });
        defer allocator.free(path);
        const written = try fs_compat.readFileAlloc(compat.fs.cwd(), allocator, path, 1 << 20);
        defer allocator.free(written);
        try std.testing.expectEqualStrings(content, written);
    }
}

test "dsh native tool-turn matches normalized v4 fixture" {
    try runFixture("tool-turn");
}

test "dsh native steer matches normalized v4 fixture" {
    try runFixture("steer");
}

test "dsh native abort matches normalized v4 fixture" {
    try runFixture("abort");
}

test "dsh native max-tokens matches normalized v4 fixture" {
    try runFixture("max-tokens");
}

test "dsh native parallel-barrier matches normalized v4 fixture" {
    try runFixture("parallel-barrier");
}

test "hook abort cause serializes as kind hook and reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try endReasonValue(allocator, .{ .aborted = .{ .hook = "policy-hook" } });
    try std.testing.expectEqualStrings("aborted", value.object.get("kind").?.string);
    const reason = value.object.get("reason").?.object;
    try std.testing.expectEqualStrings("hook", reason.get("kind").?.string);
    try std.testing.expectEqualStrings("policy-hook", reason.get("reason").?.string);
    try std.testing.expect(reason.get("name") == null);
}
