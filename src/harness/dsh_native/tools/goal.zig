//! Model-facing `get_goal`, `create_goal`, and `update_goal` tools over the
//! persisted same-session goal domain (design §1.7 B32).
//!
//! Names, descriptions and input schemas come from `generated/tool_schemas.zig`
//! (extracted from dsh `tool-goal/src/index.ts`); semantics mirror
//! `tool-goal/src/index.ts`, including its argument-combination rules and
//! `HarnessError` codes. Execution authority mirrors `authority.ts`: create,
//! edit, pause and resume need a direct human turn; complete and blocked also
//! accept the current goal round.
//!
//! The harness supplies `authority` per turn: direct human for user turns, and
//! the admitted goal snapshot for automatic rounds (`goal_rounds.Driver`).

const std = @import("std");
const generated = @import("../generated/tool_schemas.zig");
const render = @import("../generated/tool_render.zig");
const goal = @import("../goal.zig");
const registry = @import("registry.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Writer = std.Io.Writer;

/// dsh `blockedAfterConsecutiveRounds` default.
pub const blocked_after_consecutive_rounds: u32 = 3;

/// Hard authority granted to one state-changing call (`authority.ts`).
pub const Authority = struct {
    /// Host-attested direct human input in the open top-level turn.
    direct_human: bool = true,
    /// Exact goal revision whose admitted round is the open turn, if any.
    goal_round: ?goal.Snapshot = null,
};

pub const Context = struct {
    store: *goal.Store,
    authority: Authority = .{},
    blocked_after: u32 = blocked_after_consecutive_rounds,

    pub fn register(self: *Context, reg: *registry.Registry, allocator: Allocator) !void {
        const context: ?*anyopaque = @ptrCast(self);
        try reg.register(allocator, .{
            .name = generated.get_goal.name,
            .description = generated.get_goal.description,
            .input_schema_json = generated.get_goal.input_schema_json,
            .handler = .{ .context = context, .call = getGoal },
        });
        try reg.register(allocator, .{
            .name = generated.create_goal.name,
            .description = generated.create_goal.description,
            .input_schema_json = generated.create_goal.input_schema_json,
            .handler = .{ .context = context, .call = createGoal },
        });
        try reg.register(allocator, .{
            .name = generated.update_goal.name,
            .description = generated.update_goal.description,
            .input_schema_json = generated.update_goal.input_schema_json,
            .handler = .{ .context = context, .call = updateGoal },
        });
    }
};

fn contextOf(context: ?*anyopaque) *Context {
    return @ptrCast(@alignCast(context.?));
}

// ── handlers ───────────────────────────────────────────────────────────────

fn getGoal(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    _ = args;
    const self = contextOf(context);
    return success(allocator, try renderValue(allocator, self.store));
}

fn createGoal(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const self = contextOf(context);
    if (!self.authority.direct_human) return authorityFailure(allocator);
    const objective = optionalString(args, "objective") orelse "";
    const cap = roundCap(optionalInteger(args, "max_goal_rounds")) catch |err|
        return failureFor(allocator, self.store, err, "create");
    _ = self.store.create(objective, cap) catch |err|
        return failureFor(allocator, self.store, err, "create");
    return success(allocator, try renderValue(allocator, self.store));
}

fn updateGoal(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const self = contextOf(context);
    const goal_id = optionalString(args, "goal_id") orelse "";
    const revision_value = optionalInteger(args, "revision") orelse 0;
    const action_text = optionalString(args, "action") orelse "";
    const trimmed_id = std.mem.trim(u8, goal_id, " \t\r\n");
    if (goal_id.len == 0 or !std.mem.eql(u8, trimmed_id, goal_id) or revision_value < 1 or revision_value > std.math.maxInt(u32)) {
        return failure(allocator, "GOAL_TOOL_INVALID_UPDATE", "goal_id must be non-empty and revision must be a positive safe integer");
    }
    const action = parseAction(action_text) orelse
        return failure(allocator, "GOAL_TOOL_INVALID_UPDATE", "action must be edit, pause, resume, complete, or blocked");
    const ref = goal.Ref{ .id = goal_id, .revision = @intCast(revision_value) };
    const objective = optionalText(args, "objective");
    const max_rounds = optionalRound(args, "max_goal_rounds");
    const blocked_reason = optionalText(args, "blocked_reason");
    var wrapup: ?types.Message = null;

    switch (action) {
        .edit => {
            if (!self.authority.direct_human) return authorityFailure(allocator);
            if (blocked_reason != null) {
                return failure(allocator, "GOAL_TOOL_INVALID_UPDATE", "blocked_reason is valid only with action blocked");
            }
            const cap = roundCap(max_rounds) catch |err|
                return failureFor(allocator, self.store, err, "edit");
            _ = self.store.edit(ref, objective, cap) catch |err|
                return failureFor(allocator, self.store, err, "edit");
        },
        .pause, .@"resume" => {
            if (!self.authority.direct_human) return authorityFailure(allocator);
            if (objective != null or max_rounds != null or blocked_reason != null) {
                return failure(
                    allocator,
                    "GOAL_TOOL_INVALID_UPDATE",
                    "objective and max_goal_rounds are valid only with action edit; blocked_reason is valid only with action blocked",
                );
            }
            if (action == .@"resume") {
                if (self.store.find()) |current| {
                    if (std.mem.eql(u8, current.id, ref.id) and current.revision == ref.revision and current.phase == .paused) {
                        return failure(allocator, "GOAL_TOOL_RESUME_PAUSED", "the model cannot resume a paused goal; the user must resume it");
                    }
                }
            }
            const snapshot = if (action == .pause)
                self.store.pause(ref) catch |err| return failureFor(allocator, self.store, err, "pause")
            else
                self.store.@"resume"(ref) catch |err| return failureFor(allocator, self.store, err, "resume");
            _ = snapshot;
        },
        .complete, .blocked => {
            const round_authority: ?u32 = if (self.authority.goal_round) |round_goal| blk: {
                if (!std.mem.eql(u8, round_goal.id, ref.id) or round_goal.revision != ref.revision or round_goal.phase != .active) {
                    break :blk null;
                }
                break :blk self.store.rounds_started;
            } else null;
            if (!self.authority.direct_human and round_authority == null) {
                return failure(
                    allocator,
                    "GOAL_TOOL_AUTHORITY_REQUIRED",
                    "complete and blocked require a direct human turn or the current goal round",
                );
            }
            if (objective != null or max_rounds != null) {
                return failure(allocator, "GOAL_TOOL_INVALID_UPDATE", "objective and max_goal_rounds are valid only with action edit");
            }
            if (action == .complete and blocked_reason != null) {
                return failure(allocator, "GOAL_TOOL_INVALID_UPDATE", "blocked_reason is valid only with action blocked");
            }
            if (action == .blocked and blocked_reason == null) {
                return failure(allocator, "GOAL_TOOL_INVALID_UPDATE", "blocked_reason is required with action blocked");
            }
            if (action == .blocked) {
                if (round_authority) |rounds| {
                    if (rounds < self.blocked_after) {
                        const message = try std.fmt.allocPrint(
                            allocator,
                            "blocked requires at least {d} consecutive goal rounds; current round is {d}",
                            .{ self.blocked_after, rounds },
                        );
                        return failure(allocator, "GOAL_TOOL_BLOCK_THRESHOLD", message);
                    }
                }
                const snapshot = self.store.block(ref, "model-reported", blocked_reason.?) catch |err|
                    return failureFor(allocator, self.store, err, "block");
                if (round_authority != null) {
                    wrapup = try wrapupContext(allocator, snapshot, blocked_reason.?);
                }
            } else {
                const snapshot = self.store.complete(ref) catch |err|
                    return failureFor(allocator, self.store, err, "complete");
                if (round_authority != null) {
                    wrapup = try wrapupContext(allocator, snapshot, null);
                }
            }
        },
    }
    var result = try success(allocator, try renderValue(allocator, self.store));
    if (wrapup) |message| {
        const contexts = try allocator.alloc(types.Message, 1);
        contexts[0] = message;
        result.success.additional_contexts = contexts;
    }
    return result;
}

/// dsh `renderWrapupContext`: the closing-message instruction deferred as a
/// `tool-goal` notice after an autonomous terminal update. The objective and
/// blocked reason are JSON-quoted, exactly as `JSON.stringify` renders them.
fn wrapupContext(
    allocator: Allocator,
    snapshot: goal.Snapshot,
    blocked_reason: ?[]const u8,
) !types.Message {
    const objective = try std.json.Stringify.valueAlloc(allocator, snapshot.objective, .{});
    const text = if (blocked_reason) |reason| blk: {
        const encoded = try std.json.Stringify.valueAlloc(allocator, reason, .{});
        break :blk try std.fmt.allocPrint(allocator, render.goal.blocked_wrapup, .{
            objective,
            encoded,
        });
    } else try std.fmt.allocPrint(allocator, render.goal.complete_wrapup, .{objective});
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = text };
    var source: std.json.ObjectMap = .empty;
    try source.put(allocator, "kind", .{ .string = "tool-goal" });
    try source.put(allocator, "form", .{ .string = "notice" });
    return .{
        .id = try std.fmt.allocPrint(allocator, "goal-wrapup-{s}-{d}", .{
            snapshot.id,
            snapshot.revision,
        }),
        .role = .user,
        .content = content,
        .source = .{ .other = .{ .object = source } },
    };
}

const Action = enum { edit, pause, @"resume", complete, blocked };

fn parseAction(text: []const u8) ?Action {
    inline for (@typeInfo(Action).@"enum".fields) |member| {
        if (std.mem.eql(u8, text, member.name)) return @enumFromInt(member.value);
    }
    return null;
}

// ── result rendering ───────────────────────────────────────────────────────

fn renderValue(allocator: Allocator, store: *goal.Store) ![]const u8 {
    var writer: Writer.Allocating = .init(allocator);
    defer writer.deinit();
    const w = &writer.writer;
    if (store.find()) |snapshot| {
        try w.writeAll("{\"goal\":{\"id\":");
        try std.json.Stringify.value(snapshot.id, .{}, w);
        try w.print(",\"revision\":{d},\"objective\":", .{snapshot.revision});
        try std.json.Stringify.value(snapshot.objective, .{}, w);
        try w.print(",\"phase\":\"{s}\",\"roundsStarted\":{d},\"maxGoalRounds\":{d}", .{
            goal.phaseName(snapshot.phase),
            store.rounds_started,
            snapshot.max_goal_rounds,
        });
        if (snapshot.blocked_reason) |reason| {
            try w.writeAll(",\"blockedReason\":{\"code\":");
            try std.json.Stringify.value(reason.code, .{}, w);
            try w.writeAll(",\"message\":");
            try std.json.Stringify.value(reason.message, .{}, w);
            try w.writeByte('}');
        }
        try w.print("}},\"activation\":\"{s}\"}}", .{goal.activationName(store.activation)});
    } else {
        try w.writeAll("{\"goal\":null}");
    }
    return writer.toOwnedSlice();
}

fn success(allocator: Allocator, text: []const u8) !registry.ToolResult {
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = text };
    return .{ .success = .{ .content = blocks } };
}

fn failure(allocator: Allocator, code: []const u8, message: []const u8) !registry.ToolResult {
    const text = try std.fmt.allocPrint(allocator, "Error: {s}", .{message});
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = text };
    return .{ .failure = .{
        .error_info = .{ .name = "HarnessError", .code = code, .reason = message },
        .content = blocks,
    } };
}

fn failureFor(allocator: Allocator, store: *goal.Store, err: anyerror, action: []const u8) !registry.ToolResult {
    const message = try goal.describeError(store, allocator, err, action);
    return failure(allocator, goal.errorCode(err), message);
}

fn authorityFailure(allocator: Allocator) !registry.ToolResult {
    return failure(allocator, "GOAL_TOOL_AUTHORITY_REQUIRED", "this goal operation requires a direct human turn on a top-level agent");
}

// ── argument helpers ───────────────────────────────────────────────────────

fn optionalString(args: Value, name: []const u8) ?[]const u8 {
    const object = switch (args) {
        .object => |value| value,
        else => return null,
    };
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn optionalInteger(args: Value, name: []const u8) ?i64 {
    const object = switch (args) {
        .object => |value| value,
        else => return null,
    };
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

/// dsh `hasText`: undefined and the empty strict-schema filler are absent.
fn optionalText(args: Value, name: []const u8) ?[]const u8 {
    const text = optionalString(args, name) orelse return null;
    return if (text.len == 0) null else text;
}

/// dsh `hasRoundCap`: zero is the strict-schema filler and means absent.
fn optionalRound(args: Value, name: []const u8) ?i64 {
    const number = optionalInteger(args, name) orelse return null;
    return if (number == 0) null else number;
}

fn roundCap(value: ?i64) goal.Error!?u32 {
    const number = value orelse return null;
    if (number < 1 or number > std.math.maxInt(u32)) return error.GoalInvalidMaxRounds;
    return @intCast(number);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn fixedClock(context: ?*anyopaque) i64 {
    const value: *const i64 = @ptrCast(@alignCast(context.?));
    return value.*;
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    store: goal.Store,
    context: Context,

    /// Heap-pinned: the handler context points at `self.store`.
    fn init(allocator: Allocator) !*Fixture {
        const self = try allocator.create(Fixture);
        errdefer allocator.destroy(self);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .store = goal.Store.init(allocator),
            .context = undefined,
        };
        const now = try self.arena.allocator().create(i64);
        now.* = 100;
        self.store.clock = .{ .context = now, .now = fixedClock };
        self.context = .{ .store = &self.store };
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.store.deinit();
        self.arena.deinit();
        testing.allocator.destroy(self);
    }

    fn args(self: *Fixture, text: []const u8) !Value {
        return std.json.parseFromSliceLeaky(Value, self.arena.allocator(), text, .{});
    }

    fn call(
        self: *Fixture,
        handler: *const fn (?*anyopaque, Allocator, Value) anyerror!registry.ToolResult,
        value: Value,
    ) !registry.ToolResult {
        return handler(@ptrCast(&self.context), self.arena.allocator(), value);
    }
};

fn textOf(result: registry.ToolResult) []const u8 {
    const content = result.content();
    return switch (content[0]) {
        .text => |text| text,
        else => unreachable,
    };
}

test "goal tools register the three generated schemas" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var reg = registry.Registry.init();
    defer reg.deinit(testing.allocator);
    try fixture.context.register(&reg, testing.allocator);
    try testing.expect(reg.get("get_goal") != null);
    try testing.expect(reg.get("create_goal") != null);
    try testing.expect(reg.get("update_goal") != null);
    try testing.expectEqualStrings("Update the current goal.", reg.get("update_goal").?.description);
}

test "get_goal returns null before creation and the canonical value after" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    const empty = try fixture.call(getGoal, try fixture.args("{}"));
    try testing.expect(empty == .success);
    try testing.expectEqualStrings("{\"goal\":null}", textOf(empty));

    _ = try fixture.call(createGoal, try fixture.args("{\"objective\":\"ship it\",\"max_goal_rounds\":5}"));
    const value = try fixture.call(getGoal, try fixture.args("{}"));
    const parsed = try std.json.parseFromSliceLeaky(
        Value,
        fixture.arena.allocator(),
        textOf(value),
        .{},
    );
    const object = parsed.object;
    const goal_value = object.get("goal").?.object;
    try testing.expectEqualStrings("goal-1", goal_value.get("id").?.string);
    try testing.expectEqual(@as(i64, 1), goal_value.get("revision").?.integer);
    try testing.expectEqualStrings("ship it", goal_value.get("objective").?.string);
    try testing.expectEqualStrings("active", goal_value.get("phase").?.string);
    try testing.expectEqual(@as(i64, 0), goal_value.get("roundsStarted").?.integer);
    try testing.expectEqual(@as(i64, 5), goal_value.get("maxGoalRounds").?.integer);
    try testing.expectEqualStrings("armed", object.get("activation").?.string);
}

test "create_goal maps argument and authority failures to dsh codes" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    const missing = try fixture.call(createGoal, try fixture.args("{}"));
    try testing.expect(missing == .failure);
    try testing.expectEqualStrings("GOAL_INVALID_OBJECTIVE", missing.failure.error_info.code);

    const zero = try fixture.call(createGoal, try fixture.args("{\"objective\":\"x\",\"max_goal_rounds\":0}"));
    try testing.expect(zero == .failure);
    try testing.expectEqualStrings("GOAL_INVALID_MAX_ROUNDS", zero.failure.error_info.code);

    fixture.context.authority.direct_human = false;
    const denied = try fixture.call(createGoal, try fixture.args("{\"objective\":\"x\"}"));
    try testing.expect(denied == .failure);
    try testing.expectEqualStrings("GOAL_TOOL_AUTHORITY_REQUIRED", denied.failure.error_info.code);
}

test "update_goal supports edit, pause, resume, complete, and blocked" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    _ = try fixture.call(createGoal, try fixture.args("{\"objective\":\"first\",\"max_goal_rounds\":4}"));

    const edited = try fixture.call(updateGoal, try fixture.args(
        "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"edit\",\"objective\":\"second\",\"max_goal_rounds\":4}",
    ));
    try testing.expect(edited == .success);
    try testing.expect(std.mem.indexOf(u8, textOf(edited), "\"phase\":\"active\"") != null);

    const paused = try fixture.call(updateGoal, try fixture.args(
        "{\"goal_id\":\"goal-1\",\"revision\":2,\"action\":\"pause\"}",
    ));
    try testing.expect(paused == .success);
    try testing.expect(std.mem.indexOf(u8, textOf(paused), "\"phase\":\"paused\"") != null);

    const blocked_resume = try fixture.call(updateGoal, try fixture.args(
        "{\"goal_id\":\"goal-1\",\"revision\":3,\"action\":\"resume\"}",
    ));
    try testing.expect(blocked_resume == .failure);
    try testing.expectEqualStrings("GOAL_TOOL_RESUME_PAUSED", blocked_resume.failure.error_info.code);

    // A host human command resumes a paused goal; the model may then continue.
    _ = try fixture.store.@"resume"(.{ .id = "goal-1", .revision = 3 });

    const completed = try fixture.call(updateGoal, try fixture.args(
        "{\"goal_id\":\"goal-1\",\"revision\":4,\"action\":\"complete\"}",
    ));
    try testing.expect(completed == .success);
    try testing.expect(std.mem.indexOf(u8, textOf(completed), "\"phase\":\"complete\"") != null);

    // `/goal clear` owns clearing; update_goal's five dsh actions stop here.
}

test "update_goal blocking needs the round threshold and a reason" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    _ = try fixture.call(createGoal, try fixture.args("{\"objective\":\"work\"}"));
    fixture.context.authority.direct_human = false;
    fixture.context.authority.goal_round = fixture.store.find().?;
    try fixture.store.applyUserMessageValue("goal-1", 1, 1);

    const too_early = try fixture.call(updateGoal, try fixture.args(
        "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"blocked\",\"blocked_reason\":\"waiting\"}",
    ));
    try testing.expect(too_early == .failure);
    try testing.expectEqualStrings("GOAL_TOOL_BLOCK_THRESHOLD", too_early.failure.error_info.code);

    try fixture.store.applyUserMessageValue("goal-1", 1, 2);
    try fixture.store.applyUserMessageValue("goal-1", 1, 3);
    const blocked = try fixture.call(updateGoal, try fixture.args(
        "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"blocked\",\"blocked_reason\":\"waiting on example.com\"}",
    ));
    try testing.expect(blocked == .success);
    try testing.expect(std.mem.indexOf(u8, textOf(blocked), "\"phase\":\"blocked\"") != null);
    try testing.expect(std.mem.indexOf(u8, textOf(blocked), "\"code\":\"model-reported\"") != null);
}

test "update_goal rejects invalid argument combinations with dsh codes" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    _ = try fixture.call(createGoal, try fixture.args("{\"objective\":\"work\"}"));

    const cases = [_]struct { args: []const u8, code: []const u8 }{
        .{ .args = "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"edit\",\"blocked_reason\":\"x\"}", .code = "GOAL_TOOL_INVALID_UPDATE" },
        .{ .args = "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"pause\",\"objective\":\"x\"}", .code = "GOAL_TOOL_INVALID_UPDATE" },
        .{ .args = "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"complete\",\"blocked_reason\":\"x\"}", .code = "GOAL_TOOL_INVALID_UPDATE" },
        .{ .args = "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"blocked\"}", .code = "GOAL_TOOL_INVALID_UPDATE" },
        .{ .args = "{\"goal_id\":\" \",\"revision\":1,\"action\":\"pause\"}", .code = "GOAL_TOOL_INVALID_UPDATE" },
        .{ .args = "{\"goal_id\":\"goal-1\",\"revision\":0,\"action\":\"pause\"}", .code = "GOAL_TOOL_INVALID_UPDATE" },
        .{ .args = "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"edit\"}", .code = "GOAL_INVALID_EDIT" },
        .{ .args = "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"edit\",\"objective\":\"\"}", .code = "GOAL_INVALID_EDIT" },
        .{ .args = "{\"goal_id\":\"goal-1\",\"revision\":9,\"action\":\"pause\"}", .code = "GOAL_STALE_REVISION" },
    };
    for (cases) |case| {
        const result = try fixture.call(updateGoal, try fixture.args(case.args));
        try testing.expect(result == .failure);
        try testing.expectEqualStrings(case.code, result.failure.error_info.code);
    }
}

test "update_goal defers the generated complete wrap-up during a goal round" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    _ = try fixture.call(createGoal, try fixture.args("{\"objective\":\"ship it\",\"max_goal_rounds\":4}"));
    fixture.context.authority = .{ .direct_human = false, .goal_round = fixture.store.find().? };

    const result = try fixture.call(updateGoal, try fixture.args(
        "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"complete\"}",
    ));
    try testing.expect(result == .success);
    try testing.expectEqual(@as(usize, 1), result.success.additional_contexts.len);

    const context = result.success.additional_contexts[0];
    const arena = fixture.arena.allocator();
    try testing.expectEqual(types.MessageRole.user, context.role);
    const objective = try std.json.Stringify.valueAlloc(arena, "ship it", .{});
    const expected = try std.fmt.allocPrint(arena, render.goal.complete_wrapup, .{objective});
    try testing.expectEqualStrings(expected, context.content[0].text);
    try testing.expectEqualStrings("tool-goal", context.source.other.object.get("kind").?.string);
    try testing.expectEqualStrings("notice", context.source.other.object.get("form").?.string);
}

test "update_goal defers the generated blocked wrap-up during a goal round" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    _ = try fixture.call(createGoal, try fixture.args("{\"objective\":\"ship it\",\"max_goal_rounds\":4}"));
    try fixture.store.applyUserMessageValue("goal-1", 1, 1);
    try fixture.store.applyUserMessageValue("goal-1", 1, 2);
    try fixture.store.applyUserMessageValue("goal-1", 1, 3);
    fixture.context.authority = .{ .direct_human = false, .goal_round = fixture.store.find().? };

    const result = try fixture.call(updateGoal, try fixture.args(
        "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"blocked\",\"blocked_reason\":\"registry is read-only\"}",
    ));
    try testing.expect(result == .success);
    try testing.expectEqual(@as(usize, 1), result.success.additional_contexts.len);

    const context = result.success.additional_contexts[0];
    const arena = fixture.arena.allocator();
    const objective = try std.json.Stringify.valueAlloc(arena, "ship it", .{});
    const reason = try std.json.Stringify.valueAlloc(arena, "registry is read-only", .{});
    const expected = try std.fmt.allocPrint(arena, render.goal.blocked_wrapup, .{ objective, reason });
    try testing.expectEqualStrings(expected, context.content[0].text);
}

test "update_goal defers no wrap-up for a direct human turn" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    _ = try fixture.call(createGoal, try fixture.args("{\"objective\":\"ship it\"}"));

    const result = try fixture.call(updateGoal, try fixture.args(
        "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"complete\"}",
    ));
    try testing.expect(result == .success);
    try testing.expectEqual(@as(usize, 0), result.success.additional_contexts.len);
}

test "goal wrap-up handles a 64 KiB objective without leaks" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    const arena = fixture.arena.allocator();
    const objective = try arena.alloc(u8, 64 * 1024);
    @memset(objective, 'x');
    const quoted = try std.json.Stringify.valueAlloc(arena, objective, .{});
    const args_text = try std.fmt.allocPrint(arena, "{{\"objective\":{s},\"max_goal_rounds\":4}}", .{quoted});
    _ = try fixture.call(createGoal, try fixture.args(args_text));
    fixture.context.authority = .{ .direct_human = false, .goal_round = fixture.store.find().? };

    const result = try fixture.call(updateGoal, try fixture.args(
        "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"complete\"}",
    ));
    try testing.expect(result == .success);
    const text = result.success.additional_contexts[0].content[0].text;
    try testing.expect(text.len >= 64 * 1024);
    try testing.expect(std.mem.startsWith(u8, text, "<goal_complete>"));
}

test "goal tools handle a 64 KiB objective without leaks" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    const objective = try fixture.arena.allocator().alloc(u8, 64 * 1024);
    @memset(objective, 'x');
    const quoted = try std.json.Stringify.valueAlloc(fixture.arena.allocator(), objective, .{});
    const args_text = try std.fmt.allocPrint(fixture.arena.allocator(), "{{\"objective\":{s}}}", .{quoted});
    const result = try fixture.call(createGoal, try fixture.args(args_text));
    try testing.expect(result == .success);
    try testing.expect(std.mem.indexOf(u8, textOf(result), objective) != null);
}
