//! Approval service core (design §1.6 B26).
//!
//! Mirrors dsh 0.2.1-rc.2:
//! - `packages/interaction/user-approval/src/types.ts:13-59` (closed outcome
//!   vocabulary and the `approval/asked` / `approval/decided` audit pair);
//! - `packages/interaction/user-approval/src/index.ts:215-315` (the policy
//!   gate runs before any answerer, missing answerers fail closed, and every
//!   request appends exactly one ask/decide pair);
//! - `packages/core/tools/src/index.ts:1724-1776` (outcome -> model-visible
//!   deny reason).
//!
//! The module is pure: it owns no log and does not check the open-turn
//! precondition. `request` returns the decision plus the two audit events for
//! the caller to append. The pair is closed on every path: `never` policy,
//! whitelist grant, missing channel, host error, and host cancellation.
//! `assertPaired` checks the pairing invariant over an event list.
//!
//! Differences from dsh, per design B26: a host-configured `allowed_once` tool
//! whitelist grants without prompting, and the policy fold (`approval/policy`)
//! belongs to the caller.

const std = @import("std");
const port = @import("../port.zig");
const config_types = @import("../../config_types.zig");
const generated = @import("generated/root.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const approval_text = generated.interaction.approval;

/// The session approval policy (`agent.dsh_approval_policy`).
pub const Policy = config_types.DshApprovalPolicy;

pub const Options = struct {
    policy: Policy = .ask,
    /// Tool names the host grants `allowed_once` without prompting.
    /// The `never` policy is checked first: it rejects every ask.
    allowed_once: []const []const u8 = &.{},
};

pub const Request = struct {
    tool_name: []const u8,
    call_id: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

/// Closed approval outcomes (`user-approval/src/types.ts:32`).
pub const Outcome = port.ApprovalDecision;

/// Payload of one `approval/asked` event (`types.ts:44-49`).
pub const Asked = struct {
    id: []const u8,
    tool_name: []const u8,
    call_id: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

/// Payload of one `approval/decided` event (`types.ts:55-58`).
pub const Decided = struct {
    id: []const u8,
    outcome: Outcome,
};

pub const Event = union(enum) {
    asked: Asked,
    decided: Decided,
};

/// One resolved approval: the outcome, its model-visible denial text (`null`
/// only for `allowed_once`), and the ask/decide pair the caller appends.
pub const Decision = struct {
    arena: std.heap.ArenaAllocator,
    outcome: Outcome,
    denial_reason: ?[]const u8,
    /// `[approval/asked, approval/decided]`, in that order.
    events: [2]Event,

    pub fn deinit(self: *Decision) void {
        self.arena.deinit();
    }
};

pub const Service = struct {
    options: Options,
    /// Audit ids are `<next_id>`-based; a restoring caller seeds this past the
    /// ids already present in the session log.
    next_id: u64 = 1,

    pub fn init(options: Options) Service {
        return .{ .options = options };
    }

    /// Resolve one approval request. The only blocking point is the host
    /// callback; a missing channel returns immediately (fail closed).
    pub fn request(
        self: *Service,
        allocator: Allocator,
        interaction: ?port.Interaction,
        req: Request,
    ) !Decision {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const id = try std.fmt.allocPrint(arena, "approval-{d}", .{self.next_id});
        self.next_id += 1;
        const asked = Asked{
            .id = id,
            .tool_name = req.tool_name,
            .call_id = req.call_id,
            .reason = req.reason,
        };

        // Policy first (index.ts:270-275), then the junclaw whitelist, then
        // the host channel. Every branch produces a closed outcome.
        const outcome: Outcome = if (self.options.policy == .never)
            .rejected
        else if (self.isAllowedOnce(req.tool_name))
            .allowed_once
        else if (interaction) |channel|
            channel.requestApproval(channel.ctx, .{
                .id = id,
                .call_id = req.call_id orelse "",
                .tool_name = req.tool_name,
                .reason = req.reason orelse "",
            }) catch .unavailable
        else
            .unavailable;

        const decided = Decided{ .id = id, .outcome = outcome };
        // Allocate before moving `arena_state` into the result: the arena's
        // allocator points at this local, so a later allocation would land in
        // the local copy instead of the returned one.
        const denial_reason = try self.denialReason(arena, outcome, req.tool_name);
        return .{
            .arena = arena_state,
            .outcome = outcome,
            .denial_reason = denial_reason,
            .events = .{ .{ .asked = asked }, .{ .decided = decided } },
        };
    }

    fn isAllowedOnce(self: *const Service, tool_name: []const u8) bool {
        for (self.options.allowed_once) |allowed| {
            if (std.mem.eql(u8, allowed, tool_name)) return true;
        }
        return false;
    }

    fn denialReason(
        self: *const Service,
        allocator: Allocator,
        outcome: Outcome,
        tool_name: []const u8,
    ) !?[]const u8 {
        return switch (outcome) {
            .allowed_once => null,
            // The deterministic `never` reject carries the runtime-context
            // sentence so the model sees why the call was refused.
            .rejected => if (self.options.policy == .never)
                approval_text.never_sentence
            else
                try std.fmt.allocPrint(allocator, approval_text.deny_rejected, .{tool_name}),
            .cancelled => try std.fmt.allocPrint(allocator, approval_text.deny_cancelled, .{tool_name}),
            .unavailable => try std.fmt.allocPrint(allocator, approval_text.deny_no_channel, .{tool_name}),
        };
    }
};

/// Assert each `approval/asked` has exactly one later `approval/decided` with
/// the same id, and each decided event belongs to exactly one earlier ask.
pub fn assertPaired(events: []const Event) !void {
    for (events, 0..) |event, index| {
        switch (event) {
            .asked => |asked| {
                for (events[0..index]) |prior| {
                    if (isAskedWithId(prior, asked.id)) return error.DuplicateAsk;
                }
                var decided_count: usize = 0;
                for (events[index + 1 ..]) |later| {
                    if (isDecidedWithId(later, asked.id)) decided_count += 1;
                }
                if (decided_count == 0) return error.MissingDecision;
                if (decided_count > 1) return error.DuplicateDecision;
            },
            .decided => |decided| {
                var asked_count: usize = 0;
                for (events[0..index]) |prior| {
                    if (isAskedWithId(prior, decided.id)) asked_count += 1;
                    if (isDecidedWithId(prior, decided.id)) return error.DuplicateDecision;
                }
                if (asked_count == 0) return error.DecisionWithoutAsk;
                for (events[index + 1 ..]) |later| {
                    if (isDecidedWithId(later, decided.id)) return error.DuplicateDecision;
                }
            },
        }
    }
}

fn isAskedWithId(event: Event, id: []const u8) bool {
    return switch (event) {
        .asked => |asked| std.mem.eql(u8, asked.id, id),
        .decided => false,
    };
}

fn isDecidedWithId(event: Event, id: []const u8) bool {
    return switch (event) {
        .decided => |decided| std.mem.eql(u8, decided.id, id),
        .asked => false,
    };
}

/// Write the event's session-log `data` object (`json.writeEvent` wraps it in
/// the `type`/`seq`/`time` envelope). Field order matches dsh's literals.
pub fn writeData(event: Event, writer: *Writer) !void {
    switch (event) {
        .asked => |asked| {
            try writer.writeAll("{\"id\":");
            try std.json.Stringify.value(asked.id, .{}, writer);
            try writer.writeAll(",\"toolName\":");
            try std.json.Stringify.value(asked.tool_name, .{}, writer);
            if (asked.call_id) |call_id| {
                try writer.writeAll(",\"callId\":");
                try std.json.Stringify.value(call_id, .{}, writer);
            }
            if (asked.reason) |reason| {
                try writer.writeAll(",\"reason\":");
                try std.json.Stringify.value(reason, .{}, writer);
            }
            try writer.writeByte('}');
        },
        .decided => |decided| {
            try writer.writeAll("{\"id\":");
            try std.json.Stringify.value(decided.id, .{}, writer);
            try writer.writeAll(",\"outcome\":");
            try std.json.Stringify.value(outcomeSlice(decided.outcome), .{}, writer);
            try writer.writeByte('}');
        },
    }
}

pub fn dataJsonAlloc(event: Event, allocator: Allocator) ![]u8 {
    var buffer = std.Io.Writer.Allocating.init(allocator);
    errdefer buffer.deinit();
    try writeData(event, &buffer.writer);
    return buffer.toOwnedSlice();
}

fn outcomeSlice(outcome: Outcome) []const u8 {
    return switch (outcome) {
        .allowed_once => "allowed-once",
        .rejected => "rejected",
        .cancelled => "cancelled",
        .unavailable => "unavailable",
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

fn noQuestions(ctx: *anyopaque, questions: []const port.Question) anyerror![]const port.Answer {
    _ = ctx;
    _ = questions;
    return &.{};
}

fn noPlanReview(ctx: *anyopaque, plan: []const u8) anyerror!bool {
    _ = ctx;
    _ = plan;
    return false;
}

const Channel = struct {
    calls: usize = 0,
    outcome: Outcome = .rejected,
    fail: bool = false,
    last: ?port.ApprovalRequest = null,

    fn interaction(self: *Channel) port.Interaction {
        return .{
            .ctx = self,
            .requestApproval = request,
            .askQuestions = noQuestions,
            .planReview = noPlanReview,
        };
    }

    fn request(ctx: *anyopaque, req: port.ApprovalRequest) anyerror!Outcome {
        const self: *Channel = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last = req;
        if (self.fail) return error.HostFailure;
        return self.outcome;
    }
};

fn expectDenial(decision: *const Decision, comptime template: []const u8, tool_name: []const u8) !void {
    const expected = try std.fmt.allocPrint(std.testing.allocator, template, .{tool_name});
    defer std.testing.allocator.free(expected);
    try std.testing.expect(decision.denial_reason != null);
    try std.testing.expectEqualStrings(expected, decision.denial_reason.?);
}

test "ask policy maps all four host outcomes and closes the pair" {
    const outcomes = [_]Outcome{ .allowed_once, .rejected, .cancelled, .unavailable };
    for (outcomes) |host_outcome| {
        var service = Service.init(.{});
        var channel = Channel{ .outcome = host_outcome };
        var decision = try service.request(std.testing.allocator, channel.interaction(), .{
            .tool_name = "bash",
            .call_id = "call-1",
            .reason = "example.com",
        });
        defer decision.deinit();

        try std.testing.expectEqual(@as(usize, 1), channel.calls);
        try std.testing.expectEqual(host_outcome, decision.outcome);
        try assertPaired(&decision.events);

        const asked = decision.events[0].asked;
        const decided = decision.events[1].decided;
        try std.testing.expectEqualStrings(asked.id, decided.id);
        try std.testing.expectEqualStrings("bash", asked.tool_name);
        try std.testing.expectEqualStrings("call-1", asked.call_id.?);
        try std.testing.expectEqualStrings("example.com", asked.reason.?);

        try std.testing.expectEqualStrings(asked.id, channel.last.?.id);
        try std.testing.expectEqualStrings("bash", channel.last.?.tool_name);
        try std.testing.expectEqualStrings("call-1", channel.last.?.call_id);
        try std.testing.expectEqualStrings("example.com", channel.last.?.reason);

        switch (host_outcome) {
            .allowed_once => try std.testing.expect(decision.denial_reason == null),
            .rejected => try expectDenial(&decision, approval_text.deny_rejected, "bash"),
            .cancelled => try expectDenial(&decision, approval_text.deny_cancelled, "bash"),
            .unavailable => try expectDenial(&decision, approval_text.deny_no_channel, "bash"),
        }
    }
}

test "never policy rejects before the whitelist and channel" {
    var service = Service.init(.{ .policy = .never, .allowed_once = &.{"bash"} });
    var channel = Channel{ .outcome = .allowed_once };
    var decision = try service.request(std.testing.allocator, channel.interaction(), .{
        .tool_name = "bash",
    });
    defer decision.deinit();

    try std.testing.expectEqual(Outcome.rejected, decision.outcome);
    try std.testing.expectEqual(@as(usize, 0), channel.calls);
    try std.testing.expectEqualStrings(approval_text.never_sentence, decision.denial_reason.?);
    try std.testing.expect(std.mem.startsWith(u8, decision.denial_reason.?, "Approval prompts are disabled"));
    try assertPaired(&decision.events);
}

test "allowed-once whitelist grants without prompting" {
    var service = Service.init(.{ .allowed_once = &.{"bash"} });
    var channel = Channel{ .outcome = .rejected };

    var granted = try service.request(std.testing.allocator, channel.interaction(), .{
        .tool_name = "bash",
    });
    defer granted.deinit();
    try std.testing.expectEqual(Outcome.allowed_once, granted.outcome);
    try std.testing.expectEqual(@as(usize, 0), channel.calls);
    try std.testing.expect(granted.denial_reason == null);
    try assertPaired(&granted.events);

    var asked = try service.request(std.testing.allocator, channel.interaction(), .{
        .tool_name = "edit",
    });
    defer asked.deinit();
    try std.testing.expectEqual(Outcome.rejected, asked.outcome);
    try std.testing.expectEqual(@as(usize, 1), channel.calls);
    try assertPaired(&asked.events);
}

test "missing interaction fails closed without blocking" {
    var service = Service.init(.{});
    var decision = try service.request(std.testing.allocator, null, .{ .tool_name = "bash" });
    defer decision.deinit();

    try std.testing.expectEqual(Outcome.unavailable, decision.outcome);
    try expectDenial(&decision, approval_text.deny_no_channel, "bash");
    try assertPaired(&decision.events);
}

test "host callback error fails closed and still closes the pair" {
    var service = Service.init(.{});
    var channel = Channel{ .fail = true };
    var decision = try service.request(std.testing.allocator, channel.interaction(), .{
        .tool_name = "bash",
    });
    defer decision.deinit();

    try std.testing.expectEqual(@as(usize, 1), channel.calls);
    try std.testing.expectEqual(Outcome.unavailable, decision.outcome);
    try expectDenial(&decision, approval_text.deny_no_channel, "bash");
    try assertPaired(&decision.events);
}

test "blocking host answer is injected through a deterministic gate" {
    const Gate = struct {
        entered: std.atomic.Value(bool),
        release: std.atomic.Value(bool),
        answer: std.atomic.Value(u8),
        seen_id: []const u8 = "",
        seen_tool: []const u8 = "",
        seen_call_id: []const u8 = "",
        seen_reason: []const u8 = "",

        fn init() @This() {
            return .{
                .entered = std.atomic.Value(bool).init(false),
                .release = std.atomic.Value(bool).init(false),
                .answer = std.atomic.Value(u8).init(@intFromEnum(Outcome.rejected)),
            };
        }

        fn interaction(self: *@This()) port.Interaction {
            return .{
                .ctx = self,
                .requestApproval = request,
                .askQuestions = noQuestions,
                .planReview = noPlanReview,
            };
        }

        fn request(ctx: *anyopaque, req: port.ApprovalRequest) anyerror!Outcome {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.seen_id = req.id;
            self.seen_tool = req.tool_name;
            self.seen_call_id = req.call_id;
            self.seen_reason = req.reason;
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
            return @enumFromInt(self.answer.load(.acquire));
        }
    };

    const Worker = struct {
        service: *Service,
        interaction: port.Interaction,
        decision: ?Decision = null,
        err: ?anyerror = null,
        done: std.atomic.Value(bool),

        fn init(service: *Service, interaction: port.Interaction) @This() {
            return .{
                .service = service,
                .interaction = interaction,
                .done = std.atomic.Value(bool).init(false),
            };
        }

        fn run(self: *@This()) void {
            self.decision = self.service.request(std.heap.page_allocator, self.interaction, .{
                .tool_name = "bash",
                .call_id = "call-1",
                .reason = "example.com",
            }) catch |err| {
                self.err = err;
                self.done.store(true, .release);
                return;
            };
            self.done.store(true, .release);
        }
    };

    var service = Service.init(.{});
    var gate = Gate.init();
    var worker = Worker.init(&service, gate.interaction());
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    var joined = false;
    errdefer if (!joined) {
        gate.release.store(true, .release);
        thread.join();
    };

    try waitFor(&gate.entered);
    // The callback is blocked inside requestApproval, so no answer exists yet.
    try std.testing.expect(!worker.done.load(.acquire));
    try std.testing.expect(gate.seen_id.len > 0);
    try std.testing.expectEqualStrings("bash", gate.seen_tool);
    try std.testing.expectEqualStrings("call-1", gate.seen_call_id);
    try std.testing.expectEqualStrings("example.com", gate.seen_reason);

    gate.answer.store(@intFromEnum(Outcome.cancelled), .release);
    gate.release.store(true, .release);
    thread.join();
    joined = true;

    try std.testing.expect(worker.err == null);
    var decision = worker.decision.?;
    defer decision.deinit();
    try std.testing.expectEqual(Outcome.cancelled, decision.outcome);
    try std.testing.expectEqualStrings(gate.seen_id, decision.events[0].asked.id);
    try assertPaired(&decision.events);
}

fn waitFor(flag: *const std.atomic.Value(bool)) !void {
    var spins: usize = 0;
    while (!flag.load(.acquire)) {
        if (spins >= 100_000_000) return error.TestWaitTimedOut;
        spins += 1;
        if (spins % 1024 == 0) std.Thread.yield() catch {};
        std.atomic.spinLoopHint();
    }
}

test "pairing invariant rejects malformed audit sequences" {
    const asked_one = Event{ .asked = .{ .id = "approval-a", .tool_name = "bash" } };
    const decided_one = Event{ .decided = .{ .id = "approval-a", .outcome = .allowed_once } };

    const valid = [_]Event{ asked_one, decided_one };
    try assertPaired(&valid);

    const empty = [_]Event{};
    try assertPaired(&empty);

    const missing = [_]Event{asked_one};
    try std.testing.expectError(error.MissingDecision, assertPaired(&missing));

    const orphan = [_]Event{decided_one};
    try std.testing.expectError(error.DecisionWithoutAsk, assertPaired(&orphan));

    const duplicate_ask = [_]Event{ asked_one, asked_one, decided_one };
    try std.testing.expectError(error.DuplicateAsk, assertPaired(&duplicate_ask));

    const duplicate_decision = [_]Event{ asked_one, decided_one, decided_one };
    try std.testing.expectError(error.DuplicateDecision, assertPaired(&duplicate_decision));

    const inverted = [_]Event{ decided_one, asked_one };
    try std.testing.expectError(error.DecisionWithoutAsk, assertPaired(&inverted));
}

test "asked audit JSON handles >=64KB input without leaking" {
    const allocator = std.testing.allocator;
    const big = try allocator.alloc(u8, 70_000);
    defer allocator.free(big);
    @memset(big, 'x');

    const event = Event{ .asked = .{
        .id = "approval-1",
        .tool_name = "bash",
        .call_id = "call-1",
        .reason = big,
    } };
    const json = try dataJsonAlloc(event, allocator);
    defer allocator.free(json);

    try std.testing.expect(json.len > 64 * 1024);
    try std.testing.expect(std.mem.startsWith(
        u8,
        json,
        "{\"id\":\"approval-1\",\"toolName\":\"bash\",\"callId\":\"call-1\",\"reason\":\"",
    ));
    try std.testing.expect(std.mem.endsWith(u8, json, "\"}"));

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const reason = parsed.value.object.get("reason") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(big, reason.string);
}

test "decided audit JSON uses the dsh outcome spelling" {
    const allocator = std.testing.allocator;
    const event = Event{ .decided = .{ .id = "approval-1", .outcome = .allowed_once } };
    const json = try dataJsonAlloc(event, allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"id\":\"approval-1\",\"outcome\":\"allowed-once\"}", json);
}
