//! `ask_user_question` tool (design §1.6 B27).
//!
//! Model-visible name, description and input schema are the generated dsh
//! constants (`generated/interaction.zig`). The handler delegates the blocking
//! wait to `questions.ask`, so it never sleeps and fails closed without a host
//! channel. The caller sets `Context.call_id` before each invocation; the
//! pending result echoes it.

const std = @import("std");
const generated = @import("../generated/root.zig");
const port = @import("../../port.zig");
const questions = @import("../questions.zig");
const registry = @import("registry.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ask_text = generated.interaction.ask_user_question;

/// Per-call tool state. `call_id` is the current tool call identity; the
/// harness must set it before dispatching the handler.
pub const Context = struct {
    interaction: ?port.Interaction = null,
    options: questions.Options = .{},
    call_id: []const u8 = "",
};

/// Register the tool in the registry map.
///
/// `registry.register` canonicalizes against the six core schemas, so this
/// later schema is inserted directly; `Registry.get` resolution stays
/// core-only until B27 wiring teaches the registry the extra name.
pub fn register(context: *Context, reg: *registry.Registry, allocator: Allocator) !void {
    if (reg.tools.contains(ask_text.name)) return error.DuplicateTool;
    try reg.tools.put(allocator, ask_text.name, .{
        .name = ask_text.name,
        .description = ask_text.description,
        .input_schema_json = ask_text.input_schema_json,
        .handler = .{ .context = @ptrCast(context), .call = handle },
    });
}

fn handle(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const self: *Context = @ptrCast(@alignCast(context.?));
    const asked = questions.parseQuestions(allocator, args) catch |err| return parseFailure(allocator, err);
    defer questions.freeQuestions(allocator, asked);
    const result = try questions.ask(allocator, self.interaction, .{
        .call_id = self.call_id,
        .questions = asked,
    }, self.options);
    return switch (result) {
        .answered => |json| success(allocator, json),
        .pending => |json| success(allocator, json),
        .failed => |failure| errorResult(allocator, failure.code, failure.text),
    };
}

fn parseFailure(allocator: Allocator, err: anyerror) !registry.ToolResult {
    const text: []const u8 = switch (err) {
        error.EmptyQuestions => "ask_user_question requires at least one question",
        error.DuplicateQuestionId => "question ids must be unique within a call",
        error.BadIntent => "a plan-review intent must carry the plan in detail and name one of its own options in approve",
        else => "invalid ask_user_question arguments",
    };
    return errorResult(allocator, "INVALID_ARGUMENT", text);
}

fn success(allocator: Allocator, text: []const u8) !registry.ToolResult {
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = text };
    return .{ .success = .{ .content = blocks } };
}

fn errorResult(allocator: Allocator, code: []const u8, text: []const u8) !registry.ToolResult {
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = text };
    return .{ .failure = .{
        .error_info = .{ .name = "Error", .code = code, .reason = text },
        .content = blocks,
    } };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const Clock = struct {
    now: i64 = 0,
};

fn readClock(context: ?*anyopaque) i64 {
    const clock: *Clock = @ptrCast(@alignCast(context.?));
    return clock.now;
}

fn noApproval(context: ?*anyopaque, request: port.ApprovalRequest) anyerror!port.ApprovalDecision {
    _ = context;
    _ = request;
    return .rejected;
}

const Channel = struct {
    answers: []const port.Answer = &.{},
    clock: ?*Clock = null,
    advance_ms: i64 = 0,

    fn interaction(self: *Channel) port.Interaction {
        return .{
            .ctx = self,
            .requestApproval = noApproval,
            .askQuestions = askFn,
            .planReview = planFn,
        };
    }

    fn askFn(context: ?*anyopaque, asked: []const port.Question) anyerror![]const port.Answer {
        _ = asked;
        const self: *Channel = @ptrCast(@alignCast(context.?));
        if (self.clock) |clock| clock.now += self.advance_ms;
        return self.answers;
    }

    fn planFn(context: ?*anyopaque, plan: []const u8) anyerror!bool {
        _ = context;
        _ = plan;
        return false;
    }
};

fn parseArgs(arena: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

fn freeResult(allocator: Allocator, result: registry.ToolResult) void {
    const blocks = result.content();
    if (blocks.len == 0) return;
    // Success content is the allocator-owned result JSON; failure text is static.
    switch (result) {
        .success => allocator.free(blocks[0].text),
        .failure => {},
    }
    allocator.free(blocks);
}

test "register binds the generated ask_user_question schema" {
    var reg = registry.Registry.init();
    defer reg.deinit(testing.allocator);
    var context = Context{};
    try register(&context, &reg, testing.allocator);

    const tool = reg.tools.get(ask_text.name) orelse return error.MissingTool;
    try testing.expectEqualStrings(ask_text.name, tool.name);
    try testing.expectEqualStrings(ask_text.description, tool.description);
    try testing.expectEqualStrings(ask_text.input_schema_json, tool.input_schema_json);
    // The generated constant itself is stored, not a copy.
    try testing.expectEqual(@intFromPtr(ask_text.input_schema_json.ptr), @intFromPtr(tool.input_schema_json.ptr));
    try testing.expect(tool.handler.call == handle);

    try testing.expectError(error.DuplicateTool, register(&context, &reg, testing.allocator));
}

test "handler fails closed without a host channel" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(),
        \\{"questions":[{"id":"q","question":"Proceed?"}]}
    );
    var context = Context{ .call_id = "call-1" };
    const result = try handle(@ptrCast(&context), testing.allocator, args);
    defer freeResult(testing.allocator, result);

    try testing.expect(result.isError());
    switch (result) {
        .failure => |failure| {
            try testing.expectEqualStrings("NO_PROVIDER", failure.error_info.code);
            try testing.expectEqualStrings(questions.no_provider_text, failure.error_info.reason.?);
        },
        else => return error.ExpectedFailure,
    }
}

test "handler returns the dsh answer JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(),
        \\{"questions":[{"id":"q","question":"Proceed?","options":[{"label":"Yes"}]}]}
    );
    const answers = [_]port.Answer{.{ .id = "q", .text = "Yes" }};
    var channel = Channel{ .answers = &answers };
    var context = Context{ .interaction = channel.interaction(), .call_id = "call-1" };
    const result = try handle(@ptrCast(&context), testing.allocator, args);
    defer freeResult(testing.allocator, result);

    try testing.expect(!result.isError());
    const text = result.content()[0].text;
    try testing.expect(std.mem.indexOf(u8, text, "\"answers\":[") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"selected\":[\"Yes\"]") != null);
}

test "handler returns a pending result when the injected clock expires" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(),
        \\{"questions":[{"id":"q","question":"Proceed?"}]}
    );
    var clock = Clock{};
    var channel = Channel{ .clock = &clock, .advance_ms = 120_000 };
    var context = Context{
        .interaction = channel.interaction(),
        .call_id = "call-1",
        .options = .{ .now_ms = readClock, .clock_context = &clock },
    };
    const result = try handle(@ptrCast(&context), testing.allocator, args);
    defer freeResult(testing.allocator, result);

    try testing.expect(!result.isError());
    const text = result.content()[0].text;
    try testing.expect(std.mem.indexOf(u8, text, "\"pending\":true") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"callId\":\"call-1\"") != null);
}

test "handler reports malformed questions as INVALID_ARGUMENT" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(), "{\"questions\":[]}");
    var context = Context{};
    const result = try handle(@ptrCast(&context), testing.allocator, args);
    defer freeResult(testing.allocator, result);

    try testing.expect(result.isError());
    switch (result) {
        .failure => |failure| try testing.expectEqualStrings("INVALID_ARGUMENT", failure.error_info.code),
        else => return error.ExpectedFailure,
    }
}
