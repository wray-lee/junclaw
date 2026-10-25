//! User questions service core (design §1.6 B27).
//!
//! Mirrors dsh 0.2.1-rc.2:
//! - `packages/interaction/user-questions/src/types.ts:12-210` (question,
//!   option, plan-review intent and answer shapes);
//! - `packages/interaction/user-questions/src/index.ts:287-330` (empty batch,
//!   plan-review intent and one-answer-per-question validation);
//! - `packages/interaction/tool-ask-user/src/timed.ts:25-200` (timed wait,
//!   pending notice and the model-visible result JSON).
//!
//! The blocking wait is the host's `port.Interaction.askQuestions`; this module
//! never sleeps and reads time only through the injected clock. The host returns
//! an empty batch when its foreground wait ended without an answer: at or after
//! the deadline that is a timed `pending` result, otherwise the channel is
//! unavailable. The port carries only id/question/detail, so header, options,
//! multiSelect and intent stay in this module until a later port revision.
//! Plan mode is B35/P2b: `reviewPlan` only forwards to the host callback.

const std = @import("std");
const port = @import("../port.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// dsh timed-tool default (`tool-ask-user/src/index.ts:22`).
pub const default_timeout_s: i32 = 120;
/// dsh accepts -1 or 1..2147483 seconds (`tool-ask-user/src/index.ts:24-26`).
pub const max_timeout_s: i32 = 2_147_483;

pub const no_provider_text = "no user-questions answerer accepted the request";

/// dsh `pendingNotice` (`tool-ask-user/src/timed.ts:39-42`). Model-facing, so it
/// is kept byte-identical; the generator does not own it yet.
pub const pending_notice = "No answer batch arrived before the timeout. This is pending, not a skipped answer. " ++
    "Continue useful independent work. The user can still answer; their reply will be a user message " ++
    "identified as answer_to_pending_question with this callId and the original questions. " ++
    "Do not treat this as permission.";

pub const Option = struct {
    label: []const u8,
    description: []const u8 = "",
};

pub const PlanReview = struct {
    /// Option label that approves the plan; every other option declines it.
    approve: []const u8,
    /// Logged tool call whose arguments hold the reviewed plan.
    call_id: ?[]const u8 = null,
};

/// Presentation intent; an unknown tag means the generic option list.
pub const Intent = union(enum) {
    plan_review: PlanReview,
};

pub const Question = struct {
    id: []const u8,
    question: []const u8,
    detail: []const u8 = "",
    header: []const u8 = "",
    options: []const Option = &.{},
    multi_select: bool = false,
    intent: ?Intent = null,
};

/// Service-level request; `call_id` is the tool call the pending result names.
pub const Request = struct {
    call_id: []const u8 = "",
    questions: []const Question,
};

pub const Options = struct {
    /// Foreground wait in seconds; -1 waits without a deadline.
    timeout_s: i32 = default_timeout_s,
    /// Injected clock, same shape as `loop.Config.now_ms`. Never a wall clock.
    now_ms: ?*const fn (context: ?*anyopaque) i64 = null,
    clock_context: ?*anyopaque = null,

    fn now(self: Options) i64 {
        return if (self.now_ms) |clock| clock(self.clock_context) else 0;
    }

    fn expired(self: Options, elapsed_ms: i64) bool {
        if (self.timeout_s == -1) return false;
        return elapsed_ms >= @as(i64, self.timeout_s) * 1000;
    }
};

pub const Failure = struct {
    code: []const u8,
    text: []const u8,
};

/// `answered`/`pending` carry the dsh-shaped model-visible JSON; the caller
/// owns it. `failed` maps to a tool error result.
pub const Result = union(enum) {
    answered: []const u8,
    pending: []const u8,
    failed: Failure,
};

/// Parse the model's `questions[]` argument. Slices borrow `args`; options are
/// allocated from `allocator` and released by the caller with `freeQuestions`.
pub fn parseQuestions(allocator: Allocator, args: Value) ![]Question {
    const object = switch (args) {
        .object => |object| object,
        else => return error.InvalidArguments,
    };
    const raw = object.get("questions") orelse return error.InvalidArguments;
    const array = switch (raw) {
        .array => |array| array,
        else => return error.InvalidArguments,
    };
    if (array.items.len == 0) return error.EmptyQuestions;

    const parsed = try allocator.alloc(Question, array.items.len);
    var count: usize = 0;
    errdefer {
        for (parsed[0..count]) |question| freeQuestion(allocator, question);
        allocator.free(parsed);
    }
    for (array.items) |item| {
        const question = try parseQuestion(allocator, item);
        // dsh answer items are keyed by id, so a duplicate id cannot be
        // answered exactly once.
        for (parsed[0..count]) |prior| {
            if (std.mem.eql(u8, prior.id, question.id)) {
                freeQuestion(allocator, question);
                return error.DuplicateQuestionId;
            }
        }
        parsed[count] = question;
        count += 1;
    }
    return parsed;
}

pub fn freeQuestions(allocator: Allocator, questions: []Question) void {
    for (questions) |question| freeQuestion(allocator, question);
    allocator.free(questions);
}

fn freeQuestion(allocator: Allocator, question: Question) void {
    if (question.options.len != 0) allocator.free(question.options);
}

fn parseQuestion(allocator: Allocator, raw: Value) !Question {
    const object = switch (raw) {
        .object => |object| object,
        else => return error.InvalidArguments,
    };
    var question: Question = .{
        .id = try requiredString(object, "id"),
        .question = try requiredString(object, "question"),
        .detail = try optionalString(object, "detail"),
        .header = try optionalString(object, "header"),
    };
    // The generated schema spells it `multi_select`; the service types use
    // `multiSelect`, so accept both on the model boundary.
    if (object.get("multi_select") orelse object.get("multiSelect")) |value| {
        question.multi_select = switch (value) {
            .bool => |flag| flag,
            else => return error.InvalidArguments,
        };
    }
    if (object.get("options")) |value| {
        const array = switch (value) {
            .array => |array| array,
            else => return error.InvalidArguments,
        };
        const options = try allocator.alloc(Option, array.items.len);
        errdefer allocator.free(options);
        for (array.items, 0..) |item, index| {
            const option_object = switch (item) {
                .object => |option| option,
                else => return error.InvalidArguments,
            };
            options[index] = .{
                .label = try requiredString(option_object, "label"),
                .description = try optionalString(option_object, "description"),
            };
        }
        question.options = options;
    }
    errdefer freeQuestion(allocator, question);
    if (object.get("intent")) |value| {
        question.intent = try parseIntent(value, question);
    }
    return question;
}

fn parseIntent(raw: Value, question: Question) !?Intent {
    const object = switch (raw) {
        .object => |object| object,
        else => return error.InvalidArguments,
    };
    const kind = try requiredString(object, "kind");
    // Presentation-only: an unknown tag falls back to the generic option list.
    if (!std.mem.eql(u8, kind, "plan-review")) return null;
    const approve = try requiredString(object, "approve");
    // dsh rejects a plan-review whose approve names no option of its question,
    // and requires the plan markdown in `detail`.
    if (question.detail.len == 0) return error.BadIntent;
    for (question.options) |option| {
        if (std.mem.eql(u8, option.label, approve)) {
            const call_id: ?[]const u8 = if (object.get("callId") == null)
                null
            else
                try optionalString(object, "callId");
            return .{ .plan_review = .{ .approve = approve, .call_id = call_id } };
        }
    }
    return error.BadIntent;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidArguments;
    const text = switch (value) {
        .string => |text| text,
        else => return error.InvalidArguments,
    };
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InvalidArguments;
    return text;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return "";
    return switch (value) {
        .string => |text| text,
        else => return error.InvalidArguments,
    };
}

/// Blocking ask. Never sleeps, never reads a wall clock, and never waits when
/// no channel exists.
pub fn ask(
    allocator: Allocator,
    interaction: ?port.Interaction,
    request: Request,
    options: Options,
) !Result {
    if (request.questions.len == 0) {
        return failed("EMPTY_QUESTIONS", "ask_user_question requires at least one question");
    }
    if (!validTimeout(options.timeout_s)) {
        return failed("BAD_TIMEOUT", "timeout must be -1 or a positive integer up to 2147483 seconds");
    }
    const host = interaction orelse return failed("NO_PROVIDER", no_provider_text);

    const asked = try allocator.alloc(port.Question, request.questions.len);
    defer allocator.free(asked);
    for (request.questions, 0..) |question, index| {
        asked[index] = .{
            .id = question.id,
            .question = question.question,
            .detail = question.detail,
        };
    }

    const started = options.now();
    // A host error and an empty reply both mean "no answer this time"; only the
    // injected clock decides whether that was the timed wait expiring.
    const answers = host.askQuestions(host.ctx, asked) catch
        return failed("NO_PROVIDER", no_provider_text);
    const elapsed = options.now() - started;
    if (answers.len == 0) {
        if (options.expired(elapsed)) {
            return .{ .pending = try pendingJsonAlloc(allocator, request.call_id) };
        }
        return failed("NO_PROVIDER", no_provider_text);
    }
    return .{ .answered = answersJsonAlloc(allocator, request, answers) catch |err| switch (err) {
        error.BadAnswer => return failed(
            "BAD_ANSWER",
            "the answer batch must name each of its questions exactly once",
        ),
        else => return err,
    } };
}

fn validTimeout(timeout_s: i32) bool {
    return timeout_s == -1 or (timeout_s >= 1 and timeout_s <= max_timeout_s);
}

fn failed(code: []const u8, text: []const u8) Result {
    return .{ .failed = .{ .code = code, .text = text } };
}

/// Encode dsh's answer shape: `{"answers":[{"id","selected":[],"custom"?}]}`.
/// A text equal to one of the question's option labels is a selection;
/// anything else is custom input. Empty text is a submitted skip.
pub fn answersJsonAlloc(
    allocator: Allocator,
    request: Request,
    answers: []const port.Answer,
) ![]u8 {
    if (answers.len != request.questions.len) return error.BadAnswer;
    for (request.questions) |question| {
        var count: usize = 0;
        for (answers) |answer| {
            if (std.mem.eql(u8, answer.id, question.id)) count += 1;
        }
        if (count != 1) return error.BadAnswer;
    }

    var buffer = std.Io.Writer.Allocating.init(allocator);
    errdefer buffer.deinit();
    const writer = &buffer.writer;
    try writer.writeAll("{\"answers\":[");
    for (request.questions, 0..) |question, index| {
        if (index != 0) try writer.writeByte(',');
        const answer = findAnswer(answers, question.id) orelse return error.BadAnswer;
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.value(question.id, .{}, writer);
        try writer.writeAll(",\"selected\":[");
        const selected = matchesOption(question, answer.text);
        if (selected) try std.json.Stringify.value(answer.text, .{}, writer);
        try writer.writeByte(']');
        if (!selected and answer.text.len != 0) {
            try writer.writeAll(",\"custom\":");
            try std.json.Stringify.value(answer.text, .{}, writer);
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
    return buffer.toOwnedSlice();
}

/// Encode dsh's timed result: `{"pending":true,"callId","message"}`.
pub fn pendingJsonAlloc(allocator: Allocator, call_id: []const u8) ![]u8 {
    var buffer = std.Io.Writer.Allocating.init(allocator);
    errdefer buffer.deinit();
    const writer = &buffer.writer;
    try writer.writeAll("{\"pending\":true,\"callId\":");
    try std.json.Stringify.value(call_id, .{}, writer);
    try writer.writeAll(",\"message\":");
    try std.json.Stringify.value(pending_notice, .{}, writer);
    try writer.writeByte('}');
    return buffer.toOwnedSlice();
}

fn findAnswer(answers: []const port.Answer, id: []const u8) ?port.Answer {
    for (answers) |answer| {
        if (std.mem.eql(u8, answer.id, id)) return answer;
    }
    return null;
}

fn matchesOption(question: Question, text: []const u8) bool {
    for (question.options) |option| {
        if (std.mem.eql(u8, option.label, text)) return true;
    }
    return false;
}

/// Plan-review bridge reserved for B35/P2b. This module owns no plan state; it
/// only exposes the host callback. `false` keeps the plan active.
pub fn reviewPlan(interaction: ?port.Interaction, plan: []const u8) !bool {
    const host = interaction orelse return error.NoChannel;
    return host.planReview(host.ctx, plan);
}

/// Detailed plan review (P3-G additive): prefers the host's
/// `planReviewDetailed` callback so keep-planning feedback reaches the model,
/// and falls back to the boolean `planReview` for hosts that do not set it.
pub fn reviewPlanDetailed(interaction: ?port.Interaction, plan: []const u8) !port.PlanReview {
    const host = interaction orelse return error.NoChannel;
    if (host.planReviewDetailed) |review| return review(host.ctx, plan);
    return .{ .approved = try host.planReview(host.ctx, plan) };
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
    calls: usize = 0,
    answers: []const port.Answer = &.{},
    fail: bool = false,
    plan_answer: bool = false,
    plan_feedback: []const u8 = "",
    detailed_review: bool = false,
    last_plan: []const u8 = "",
    seen_questions: usize = 0,
    clock: ?*Clock = null,
    advance_ms: i64 = 0,

    fn interaction(self: *Channel) port.Interaction {
        return .{
            .ctx = self,
            .requestApproval = noApproval,
            .askQuestions = askFn,
            .planReview = planFn,
            .planReviewDetailed = if (self.detailed_review) detailedPlanFn else null,
        };
    }

    fn askFn(context: ?*anyopaque, questions: []const port.Question) anyerror![]const port.Answer {
        const self: *Channel = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.seen_questions = questions.len;
        if (self.clock) |clock| clock.now += self.advance_ms;
        if (self.fail) return error.HostFailure;
        return self.answers;
    }

    fn planFn(context: ?*anyopaque, plan: []const u8) anyerror!bool {
        const self: *Channel = @ptrCast(@alignCast(context.?));
        self.last_plan = plan;
        return self.plan_answer;
    }

    fn detailedPlanFn(context: ?*anyopaque, plan: []const u8) anyerror!port.PlanReview {
        const self: *Channel = @ptrCast(@alignCast(context.?));
        self.last_plan = plan;
        return .{ .approved = self.plan_answer, .feedback = self.plan_feedback };
    }
};

fn parseArgs(arena: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

fn expectAnswered(result: Result) ![]const u8 {
    return switch (result) {
        .answered => |json| json,
        else => error.ExpectedAnswer,
    };
}

fn expectPending(result: Result) ![]const u8 {
    return switch (result) {
        .pending => |json| json,
        else => error.ExpectedPending,
    };
}

fn expectFailure(result: Result, code: []const u8) !Failure {
    return switch (result) {
        .failed => |failure| if (std.mem.eql(u8, failure.code, code)) failure else error.WrongFailureCode,
        else => error.ExpectedFailure,
    };
}

const sample_request = Request{
    .call_id = "call-7",
    .questions = &.{
        .{
            .id = "mode",
            .question = "Which mode?",
            .options = &.{ .{ .label = "A" }, .{ .label = "B" } },
        },
        .{ .id = "note", .question = "Anything else?" },
    },
};

test "question arguments parse the full dsh shape including a plan-review intent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(),
        \\{"questions":[{"id":"q1","question":"Pick one","detail":"the plan",
        \\"header":"Choose","options":[{"label":"A","description":"first"},{"label":"B"}],
        \\"multiSelect":true,"intent":{"kind":"plan-review","approve":"A","callId":"call-9"}}]}
    );
    const parsed = try parseQuestions(testing.allocator, args);
    defer freeQuestions(testing.allocator, parsed);

    try testing.expectEqual(@as(usize, 1), parsed.len);
    try testing.expectEqualStrings("q1", parsed[0].id);
    try testing.expectEqualStrings("Pick one", parsed[0].question);
    try testing.expectEqualStrings("the plan", parsed[0].detail);
    try testing.expectEqualStrings("Choose", parsed[0].header);
    try testing.expect(parsed[0].multi_select);
    try testing.expectEqual(@as(usize, 2), parsed[0].options.len);
    try testing.expectEqualStrings("A", parsed[0].options[0].label);
    try testing.expectEqualStrings("first", parsed[0].options[0].description);

    const intent = parsed[0].intent orelse return error.MissingIntent;
    try testing.expectEqual(Intent.plan_review, std.meta.activeTag(intent));
    try testing.expectEqualStrings("A", intent.plan_review.approve);
    try testing.expectEqualStrings("call-9", intent.plan_review.call_id.?);
}

test "question arguments reject empty, duplicate and bad-intent batches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const empty = try parseArgs(arena.allocator(), "{\"questions\":[]}");
    try testing.expectError(error.EmptyQuestions, parseQuestions(testing.allocator, empty));

    const duplicate = try parseArgs(arena.allocator(),
        \\{"questions":[{"id":"same","question":"one"},{"id":"same","question":"two"}]}
    );
    try testing.expectError(error.DuplicateQuestionId, parseQuestions(testing.allocator, duplicate));

    const bad_intent = try parseArgs(arena.allocator(),
        \\{"questions":[{"id":"q","question":"approve?","detail":"plan",
        \\"options":[{"label":"Yes"}],"intent":{"kind":"plan-review","approve":"No"}}]}
    );
    try testing.expectError(error.BadIntent, parseQuestions(testing.allocator, bad_intent));
}

test "a full answer batch encodes selections and custom text" {
    var clock = Clock{};
    const answers = [_]port.Answer{
        .{ .id = "note", .text = "hello" },
        .{ .id = "mode", .text = "A" },
    };
    var channel = Channel{ .answers = &answers };
    const result = try ask(testing.allocator, channel.interaction(), sample_request, .{
        .now_ms = readClock,
        .clock_context = &clock,
    });
    const json = try expectAnswered(result);
    defer testing.allocator.free(json);

    try testing.expectEqual(@as(usize, 1), channel.calls);
    try testing.expectEqual(@as(usize, 2), channel.seen_questions);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try parseArgs(arena.allocator(), json);
    const answers_value = parsed.object.get("answers").?.array;
    try testing.expectEqual(@as(usize, 2), answers_value.items.len);
    // Emitted in question order even though the host answered out of order.
    const first = answers_value.items[0].object;
    try testing.expectEqualStrings("mode", first.get("id").?.string);
    try testing.expectEqualStrings("A", first.get("selected").?.array.items[0].string);
    const second = answers_value.items[1].object;
    try testing.expectEqualStrings("note", second.get("id").?.string);
    try testing.expectEqual(@as(usize, 0), second.get("selected").?.array.items.len);
    try testing.expectEqualStrings("hello", second.get("custom").?.string);
}

test "an incomplete or extra answer batch is a BAD_ANSWER failure" {
    const missing = [_]port.Answer{.{ .id = "mode", .text = "A" }};
    var missing_channel = Channel{ .answers = &missing };
    const missing_result = try ask(
        testing.allocator,
        missing_channel.interaction(),
        sample_request,
        .{},
    );
    _ = try expectFailure(missing_result, "BAD_ANSWER");

    const extra = [_]port.Answer{
        .{ .id = "mode", .text = "A" },
        .{ .id = "note", .text = "" },
        .{ .id = "other", .text = "x" },
    };
    var extra_channel = Channel{ .answers = &extra };
    const extra_result = try ask(
        testing.allocator,
        extra_channel.interaction(),
        sample_request,
        .{},
    );
    _ = try expectFailure(extra_result, "BAD_ANSWER");
}

test "no interaction channel fails closed instead of waiting" {
    const result = try ask(testing.allocator, null, sample_request, .{});
    const failure = try expectFailure(result, "NO_PROVIDER");
    try testing.expectEqualStrings(no_provider_text, failure.text);
}

test "a host error fails closed" {
    var channel = Channel{ .fail = true };
    const result = try ask(testing.allocator, channel.interaction(), sample_request, .{});
    _ = try expectFailure(result, "NO_PROVIDER");
    try testing.expectEqual(@as(usize, 1), channel.calls);
}

test "the injected clock alone decides a timed pending result" {
    var clock = Clock{ .now = 1_000 };
    var channel = Channel{ .clock = &clock, .advance_ms = 120_000 };
    const result = try ask(testing.allocator, channel.interaction(), sample_request, .{
        .timeout_s = 120,
        .now_ms = readClock,
        .clock_context = &clock,
    });
    const json = try expectPending(result);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"pending\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"callId\":\"call-7\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, pending_notice) != null);
}

test "an empty batch before the deadline is unavailable, not pending" {
    var clock = Clock{};
    var channel = Channel{ .clock = &clock, .advance_ms = 119_999 };
    const result = try ask(testing.allocator, channel.interaction(), sample_request, .{
        .timeout_s = 120,
        .now_ms = readClock,
        .clock_context = &clock,
    });
    _ = try expectFailure(result, "NO_PROVIDER");
}

test "-1 disables the deadline" {
    var clock = Clock{};
    var channel = Channel{ .clock = &clock, .advance_ms = 10_000_000 };
    const result = try ask(testing.allocator, channel.interaction(), sample_request, .{
        .timeout_s = -1,
        .now_ms = readClock,
        .clock_context = &clock,
    });
    _ = try expectFailure(result, "NO_PROVIDER");
}

test "invalid timeouts are rejected before the host is asked" {
    var channel = Channel{};
    const result = try ask(testing.allocator, channel.interaction(), sample_request, .{
        .timeout_s = 0,
    });
    _ = try expectFailure(result, "BAD_TIMEOUT");
    try testing.expectEqual(@as(usize, 0), channel.calls);
}

test "reviewPlan exposes the host plan-review callback" {
    var channel = Channel{ .plan_answer = true };
    try testing.expect(try reviewPlan(channel.interaction(), "the plan"));
    try testing.expectEqualStrings("the plan", channel.last_plan);
    try testing.expectError(error.NoChannel, reviewPlan(null, "the plan"));
}

test "reviewPlanDetailed prefers the feedback callback and falls back to planReview" {
    var detailed = Channel{
        .plan_answer = false,
        .plan_feedback = "make it shorter",
        .detailed_review = true,
    };
    const review = try reviewPlanDetailed(detailed.interaction(), "the plan");
    try testing.expect(!review.approved);
    try testing.expectEqualStrings("make it shorter", review.feedback);
    try testing.expectEqualStrings("the plan", detailed.last_plan);

    var legacy = Channel{ .plan_answer = true };
    const fallback = try reviewPlanDetailed(legacy.interaction(), "the plan");
    try testing.expect(fallback.approved);
    try testing.expectEqualStrings("", fallback.feedback);
    try testing.expectError(error.NoChannel, reviewPlanDetailed(null, "the plan"));
}

test "large question and answer JSON is built without leaks" {
    const size = 70_000;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const big = try arena.allocator().alloc(u8, size);
    @memset(big, 'x');

    const args_text = try std.fmt.allocPrint(
        arena.allocator(),
        "{{\"questions\":[{{\"id\":\"q\",\"question\":\"{s}\",\"detail\":\"{s}\"}}]}}",
        .{ big, big },
    );
    const args = try parseArgs(arena.allocator(), args_text);
    const parsed = try parseQuestions(testing.allocator, args);
    defer freeQuestions(testing.allocator, parsed);

    const answers = [_]port.Answer{.{ .id = "q", .text = big }};
    var channel = Channel{ .answers = &answers };
    const result = try ask(
        testing.allocator,
        channel.interaction(),
        .{ .call_id = "call-big", .questions = parsed },
        .{},
    );
    const json = try expectAnswered(result);
    defer testing.allocator.free(json);

    try testing.expect(json.len >= size);
    try testing.expect(std.mem.indexOf(u8, json, big) != null);
}
