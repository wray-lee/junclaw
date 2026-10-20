//! Scripted provider for golden traces: deterministic, no network, and it
//! records the requests the host made so a refactor can be diffed call by call.

const std = @import("std");
const providers = @import("../providers/root.zig");

pub const Role = providers.Role;
pub const Provider = providers.Provider;

const max_recorded_calls = 8;
const max_recorded_messages = 8;
const message_copy_len = 128;

pub const ToolCallSpec = struct {
    id: []const u8 = "call-1",
    name: []const u8,
    arguments: []const u8 = "{}",
};

pub const Response = struct {
    text: []const u8 = "",
    tool_calls: []const ToolCallSpec = &.{},
    /// Emitted as deltas, in order, when the provider runs in streaming mode.
    chunks: []const []const u8 = &.{},
};

pub const RecordedMessage = struct {
    role: Role,
    len: usize = 0,
    buf: [message_copy_len]u8 = undefined,

    pub fn text(self: *const RecordedMessage) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const CallRecord = struct {
    message_count: usize = 0,
    tool_spec_count: usize = 0,
    temperature: f64 = 0,
    model_len: usize = 0,
    model_buf: [64]u8 = undefined,
    /// First `max_recorded_messages` messages, in request order.
    messages: [max_recorded_messages]RecordedMessage = undefined,

    pub fn model(self: *const CallRecord) []const u8 {
        return self.model_buf[0..self.model_len];
    }

    pub fn recordedMessages(self: *const CallRecord) []const RecordedMessage {
        return self.messages[0..@min(self.message_count, max_recorded_messages)];
    }

    pub fn lastUserText(self: *const CallRecord) []const u8 {
        var i = self.recordedMessages().len;
        while (i > 0) {
            i -= 1;
            if (self.messages[i].role == .user) return self.messages[i].text();
        }
        return "";
    }
};

pub const ScriptedProvider = struct {
    responses: []const Response,
    /// Test hook invoked at the start of every chat/streamChat call, so a test
    /// can inject a message while the provider request is in flight.
    on_chat: ?*const fn (ctx: *anyopaque) void = null,
    on_chat_ctx: ?*anyopaque = null,
    calls: [max_recorded_calls]CallRecord = [_]CallRecord{.{}} ** max_recorded_calls,
    call_count: usize = 0,

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystem,
        .chat = chat,
        .supportsNativeTools = supportsNativeTools,
        .getName = getName,
        .deinit = deinitFn,
        .supports_streaming = supportsStreaming,
        .stream_chat = streamChat,
    };

    pub fn provider(self: *ScriptedProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn call(self: *const ScriptedProvider, index: usize) *const CallRecord {
        return &self.calls[index];
    }

    fn nextResponse(self: *ScriptedProvider) Response {
        if (self.responses.len == 0) return .{};
        const index = if (self.call_count == 0) 0 else @min(self.call_count - 1, self.responses.len - 1);
        return self.responses[index];
    }

    fn record(self: *ScriptedProvider, request: providers.ChatRequest, model: []const u8, temperature: f64) void {
        const index = self.call_count;
        self.call_count += 1;
        if (index >= max_recorded_calls) return;
        const record_call = &self.calls[index];
        record_call.message_count = request.messages.len;
        record_call.tool_spec_count = if (request.tools) |specs| specs.len else 0;
        record_call.temperature = temperature;
        record_call.model_len = @min(model.len, record_call.model_buf.len);
        @memcpy(record_call.model_buf[0..record_call.model_len], model[0..record_call.model_len]);
        for (request.messages[0..@min(request.messages.len, max_recorded_messages)], 0..) |message, i| {
            const len = @min(message.content.len, message_copy_len);
            @memcpy(record_call.messages[i].buf[0..len], message.content[0..len]);
            record_call.messages[i].len = len;
            record_call.messages[i].role = message.role;
        }
    }

    fn fireHook(self: *ScriptedProvider) void {
        if (self.on_chat) |hook| {
            if (self.on_chat_ctx) |ctx| hook(ctx);
        }
    }

    fn copyToolCalls(self: *ScriptedProvider, allocator: std.mem.Allocator) ![]providers.ToolCall {
        const specs = self.nextResponse().tool_calls;
        if (specs.len == 0) return &.{};
        const calls = try allocator.alloc(providers.ToolCall, specs.len);
        for (specs, 0..) |spec, i| {
            calls[i] = .{
                .id = try allocator.dupe(u8, spec.id),
                .name = try allocator.dupe(u8, spec.name),
                .arguments = try allocator.dupe(u8, spec.arguments),
            };
        }
        return calls;
    }

    fn chatWithSystem(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *ScriptedProvider = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, self.nextResponse().text);
    }

    fn chat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: providers.ChatRequest,
        model: []const u8,
        temperature: f64,
    ) anyerror!providers.ChatResponse {
        const self: *ScriptedProvider = @ptrCast(@alignCast(ptr));
        self.record(request, model, temperature);
        self.fireHook();
        return .{
            .content = try allocator.dupe(u8, self.nextResponse().text),
            .tool_calls = try self.copyToolCalls(allocator),
            .model = try allocator.dupe(u8, model),
        };
    }

    fn streamChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: providers.ChatRequest,
        model: []const u8,
        temperature: f64,
        callback: providers.StreamCallback,
        callback_ctx: *anyopaque,
    ) anyerror!providers.StreamChatResult {
        const self: *ScriptedProvider = @ptrCast(@alignCast(ptr));
        self.record(request, model, temperature);
        self.fireHook();
        const response = self.nextResponse();
        for (response.chunks) |chunk| callback(callback_ctx, providers.StreamChunk.textDelta(chunk));
        callback(callback_ctx, providers.StreamChunk.finalChunk());
        return .{
            .content = try allocator.dupe(u8, response.text),
            .tool_calls = try self.copyToolCalls(allocator),
            .model = try allocator.dupe(u8, model),
        };
    }

    fn supportsNativeTools(_: *anyopaque) bool {
        return true;
    }

    fn supportsStreaming(_: *anyopaque) bool {
        return true;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "scripted";
    }

    fn deinitFn(_: *anyopaque) void {}
};
