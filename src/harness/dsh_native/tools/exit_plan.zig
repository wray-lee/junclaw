//! `exit_plan_mode` tool (design §1.8 B35).
//!
//! Mirrors dsh 0.2.1-rc.2 `packages/plan/plan-mode/src/index.ts:277-372`:
//! the plan must start with a `#` heading, review goes through the
//! user-questions channel, approval returns `{"approved":true}` and queues a
//! silent `plan/mode=false` for the next in-turn pre-step, and any failure is
//! a model-visible error result (fail-closed without a channel). The tool stays
//! registered while plan mode is inactive, matching dsh's stable tool catalog.
//!
//! The host's `port.Interaction.planReview` returns only a boolean, so the
//! keep-planning feedback text is unavailable; the no-feedback dsh wording is
//! returned instead.

const std = @import("std");
const generated = @import("../generated/root.zig");
const plan = @import("../plan.zig");
const port = @import("../../port.zig");
const questions = @import("../questions.zig");
const registry = @import("registry.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const schema = generated.tool_schemas.exit_plan_mode;
const text = generated.interaction.plan_mode;
const approved_json = "{\"approved\":true}";

/// Per-call tool state. The harness owns the plan session and the optional
/// interaction channel.
pub const Context = struct {
    plan: *plan.Session,
    interaction: ?port.Interaction = null,
};

/// Register the tool in the registry map.
///
/// `registry.register` canonicalizes against the core schemas, so this later
/// schema is inserted directly; `Registry.get` resolution stays core-only
/// until the harness wiring teaches the registry the extra name.
pub fn register(context: *Context, reg: *registry.Registry, allocator: Allocator) !void {
    if (reg.tools.contains(schema.name)) return error.DuplicateTool;
    try reg.tools.put(allocator, schema.name, .{
        .name = schema.name,
        .description = schema.description,
        .input_schema_json = schema.input_schema_json,
        .handler = .{ .context = @ptrCast(context), .call = handle },
    });
}

pub fn handle(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const pointer = context orelse return failureFormat(allocator, "NO_AGENT", text.exit_requires_agent, .{schema.name});
    const self: *Context = @ptrCast(@alignCast(pointer));

    if (!self.plan.state.active) {
        return failureFormat(allocator, "PLAN_MODE_INACTIVE", text.exit_requires_plan_mode, .{schema.name});
    }

    const plan_text = planArgument(args) orelse
        return failureFormat(allocator, "INVALID_PLAN", text.exit_requires_heading, .{schema.name});
    if (!validHeading(plan_text)) {
        return failureFormat(allocator, "INVALID_PLAN", text.exit_requires_heading, .{schema.name});
    }

    const approved = questions.reviewPlan(self.interaction, plan_text) catch |err| {
        if (err == error.NoChannel) return failureLiteral(allocator, "NO_CHANNEL", text.exit_no_channel);
        return failureFormat(allocator, "REVIEW_FAILED", "plan review failed: {s}", .{@errorName(err)});
    };
    if (!approved) return failureLiteral(allocator, "PLAN_NOT_APPROVED", text.exit_keep_planning);

    const owned = try allocator.dupe(u8, approved_json);
    errdefer allocator.free(owned);
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = owned };
    // The event is written at the next accepted in-turn pre-step, so the rest
    // of this tool batch still sees plan mode active.
    self.plan.queueExit();
    return .{ .success = .{ .content = blocks } };
}

fn planArgument(args: Value) ?[]const u8 {
    return switch (args) {
        .object => |object| switch (object.get("plan") orelse return null) {
            .string => |value| value,
            else => null,
        },
        else => null,
    };
}

/// dsh `/^#\s+\S/` over the trimmed plan: one `#`, then whitespace, then text.
fn validHeading(plan_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, plan_text, " \t\n\r");
    if (trimmed.len < 3 or trimmed[0] != '#') return false;
    var index: usize = 1;
    if (!std.ascii.isWhitespace(trimmed[index])) return false;
    while (index < trimmed.len and std.ascii.isWhitespace(trimmed[index])) : (index += 1) {}
    return index < trimmed.len;
}

fn failureOwned(allocator: Allocator, code: []const u8, owned: []const u8) !registry.ToolResult {
    errdefer allocator.free(owned);
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = owned };
    return .{ .failure = .{
        .error_info = .{ .name = "Error", .code = code, .reason = owned },
        .content = blocks,
    } };
}

fn failureLiteral(allocator: Allocator, code: []const u8, message: []const u8) !registry.ToolResult {
    const owned = try allocator.dupe(u8, message);
    return failureOwned(allocator, code, owned);
}

fn failureFormat(allocator: Allocator, code: []const u8, comptime format: []const u8, args: anytype) !registry.ToolResult {
    const owned = try std.fmt.allocPrint(allocator, format, args);
    return failureOwned(allocator, code, owned);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const Channel = struct {
    approve: bool = true,
    calls: usize = 0,
};

fn approveFn(context: *anyopaque, plan_text: []const u8) anyerror!bool {
    const self: *Channel = @ptrCast(@alignCast(context));
    _ = plan_text;
    self.calls += 1;
    return self.approve;
}

fn noApproval(context: *anyopaque, request: port.ApprovalRequest) anyerror!port.ApprovalDecision {
    _ = context;
    _ = request;
    return .rejected;
}

fn noQuestions(context: *anyopaque, asked: []const port.Question) anyerror![]const port.Answer {
    _ = context;
    _ = asked;
    return &.{};
}

fn interaction(channel: *Channel) port.Interaction {
    return .{
        .ctx = channel,
        .requestApproval = noApproval,
        .askQuestions = noQuestions,
        .planReview = approveFn,
    };
}

fn planArgs(allocator: Allocator, plan_text: []const u8) !Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "plan", .{ .string = plan_text });
    return .{ .object = object };
}

fn freeResult(allocator: Allocator, result: registry.ToolResult) void {
    const blocks = result.content();
    if (blocks.len == 0) return;
    allocator.free(blocks[0].text);
    allocator.free(blocks);
}

test "exit_plan_mode requires a level-one heading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var plan_session = plan.Session{};
    plan_session.state.active = true;
    var channel = Channel{};
    var context = Context{ .plan = &plan_session, .interaction = interaction(&channel) };

    const heading_error = try std.fmt.allocPrint(a, text.exit_requires_heading, .{schema.name});
    for ([_][]const u8{ "no heading", "## Second level", "#", "# \n", "" }) |invalid| {
        var result = try handle(&context, a, try planArgs(a, invalid));
        defer freeResult(a, result);
        try testing.expect(result.isError());
        try testing.expectEqualStrings(heading_error, result.content()[0].text);
    }
    try testing.expectEqual(@as(usize, 0), channel.calls);

    const valid = try handle(&context, a, try planArgs(a, "  \n# Ship it\n\nBody"));
    defer freeResult(a, valid);
    try testing.expect(!valid.isError());
    try testing.expectEqual(@as(usize, 1), channel.calls);
}

test "exit_plan_mode approval queues the silent mode change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var plan_session = plan.Session{};
    plan_session.state.active = true;
    var channel = Channel{ .approve = true };
    var context = Context{ .plan = &plan_session, .interaction = interaction(&channel) };

    var result = try handle(&context, a, try planArgs(a, "# Ship it\n\nSteps"));
    defer freeResult(a, result);
    try testing.expect(!result.isError());
    try testing.expectEqualStrings(approved_json, result.content()[0].text);
    try testing.expectEqual(@as(?bool, false), plan_session.pending.?.active);
    try testing.expect(!plan_session.pending.?.narrate);

    const boundary = plan_session.preStep();
    try testing.expectEqual(@as(?bool, false), boundary.emit);
    try testing.expectEqual(@as(?[]const u8, null), boundary.narration);
    try testing.expect(plan_session.state.active);
}

test "exit_plan_mode rejection keeps plan mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var plan_session = plan.Session{};
    plan_session.state.active = true;
    var channel = Channel{ .approve = false };
    var context = Context{ .plan = &plan_session, .interaction = interaction(&channel) };

    var result = try handle(&context, a, try planArgs(a, "# Ship it"));
    defer freeResult(a, result);
    try testing.expect(result.isError());
    try testing.expectEqualStrings(text.exit_keep_planning, result.content()[0].text);
    try testing.expect(plan_session.pending == null);
    try testing.expect(plan_session.state.active);
    try testing.expect(plan_session.projection().active);
}

test "exit_plan_mode fails closed without an interaction channel" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var plan_session = plan.Session{};
    plan_session.state.active = true;
    var context = Context{ .plan = &plan_session };

    var result = try handle(&context, a, try planArgs(a, "# Ship it"));
    defer freeResult(a, result);
    try testing.expect(result.isError());
    try testing.expectEqualStrings(text.exit_no_channel, result.content()[0].text);
    try testing.expect(plan_session.pending == null);
}

test "exit_plan_mode is unavailable outside plan mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var plan_session = plan.Session{};
    var channel = Channel{};
    var context = Context{ .plan = &plan_session, .interaction = interaction(&channel) };

    var result = try handle(&context, a, try planArgs(a, "# Ship it"));
    defer freeResult(a, result);
    try testing.expect(result.isError());
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, text.exit_requires_plan_mode, .{schema.name}),
        result.content()[0].text,
    );
    try testing.expectEqual(@as(usize, 0), channel.calls);
}

test "exit_plan_mode reports a review transport failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var plan_session = plan.Session{};
    plan_session.state.active = true;
    var channel = Channel{};
    // A non-null channel whose callback throws must not be treated as approval.
    var context = Context{ .plan = &plan_session, .interaction = .{
        .ctx = &channel,
        .requestApproval = noApproval,
        .askQuestions = noQuestions,
        .planReview = failingReview,
    } };

    var result = try handle(&context, a, try planArgs(a, "# Ship it"));
    defer freeResult(a, result);
    try testing.expect(result.isError());
    try testing.expect(std.mem.startsWith(u8, result.content()[0].text, "plan review failed: "));
    try testing.expect(plan_session.pending == null);
}

fn failingReview(context: *anyopaque, plan_text: []const u8) anyerror!bool {
    _ = context;
    _ = plan_text;
    return error.HostFailure;
}

test "exit_plan_mode accepts a 64 KiB plan without leaking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var plan_session = plan.Session{};
    plan_session.state.active = true;
    var channel = Channel{};
    var context = Context{ .plan = &plan_session, .interaction = interaction(&channel) };

    const size = 64 * 1024;
    const plan_text = try a.alloc(u8, size);
    @memcpy(plan_text[0..2], "# ");
    @memset(plan_text[2..], 'x');

    var result = try handle(&context, a, try planArgs(a, plan_text));
    defer freeResult(a, result);
    try testing.expect(!result.isError());
    try testing.expectEqualStrings(approved_json, result.content()[0].text);
    try testing.expectEqual(@as(usize, 1), channel.calls);
}

test "register binds the generated exit_plan_mode schema" {
    var reg = registry.Registry.init();
    defer reg.deinit(testing.allocator);

    var plan_session = plan.Session{};
    var context = Context{ .plan = &plan_session };
    try register(&context, &reg, testing.allocator);
    const tool = reg.tools.get(schema.name).?;
    try testing.expectEqualStrings(schema.description, tool.description);
    try testing.expectEqualStrings(schema.input_schema_json, tool.input_schema_json);
}
