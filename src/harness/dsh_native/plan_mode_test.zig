//! Deterministic use-after-free checks for plan command and tool arenas.
//!
//! The harness resets a per-step arena after a tool batch. The plan state must
//! keep only values and static generated text across that reset. These tests
//! back the arena with `harness_test.zig`'s `PoisonAllocator`, so a retained
//! arena pointer reads 0xAA instead of passing on hosts where the page stays
//! mapped (see `.scratch/dsh-uaf-detection.md`).

const std = @import("std");
const commands = @import("commands.zig");
const generated = @import("generated/root.zig");
const plan = @import("plan.zig");
const port = @import("../port.zig");
const exit_plan = @import("tools/exit_plan.zig");
const testing = std.testing;
const PoisonAllocator = @import("harness_test.zig").PoisonAllocator;

test "plan command settlement and narration survive a poisoned arena release" {
    var poison = PoisonAllocator{ .child = testing.allocator };
    var result = (try commands.handleLocalCommand(poison.allocator(), "/plan on", .{
        .command_id = "cmd-1",
        .plan = .{ .active = false, .active_at_last_header = false },
    })).?;
    const settlement = result.text;
    const narration = result.plan_decision.?.narration.?;
    result.deinit();

    try testing.expect(poison.free_calls > 0);
    // Both strings are generated constants, not arena-owned.
    try testing.expectEqualStrings(generated.interaction.plan_mode.on_committed, settlement);
    try testing.expectEqualStrings(generated.interaction.plan_mode.narration_on, narration);
}

test "exit_plan_mode queues only values across a poisoned step arena reset" {
    var poison = PoisonAllocator{ .child = testing.allocator };
    var arena = std.heap.ArenaAllocator.init(poison.allocator());
    const a = arena.allocator();

    var plan_session = plan.Session{};
    plan_session.state.active = true;
    var channel = Channel{};
    var context = exit_plan.Context{ .plan = &plan_session, .interaction = channel.interaction() };

    var object: std.json.ObjectMap = .empty;
    try object.put(a, "plan", .{ .string = "# Ship it" });
    const result = try exit_plan.handle(&context, a, .{ .object = object });
    try testing.expect(!result.isError());
    try testing.expectEqual(@as(?bool, false), plan_session.pending.?.active);

    arena.deinit();
    try testing.expect(poison.free_calls > 0);
    // The queued selection and logged mode are plain values; no arena pointer
    // is retained, so the next pre-step still reports the exit.
    try testing.expectEqual(@as(?bool, false), plan_session.pending.?.active);
    try testing.expect(plan_session.state.active);
    const boundary = plan_session.preStep();
    try testing.expectEqual(@as(?bool, false), boundary.emit);
}

const Channel = struct {
    fn interaction(self: *Channel) port.Interaction {
        return .{
            .ctx = self,
            .requestApproval = noApproval,
            .askQuestions = noQuestions,
            .planReview = approve,
        };
    }
};

fn approve(context: *anyopaque, plan_text: []const u8) anyerror!bool {
    _ = context;
    _ = plan_text;
    return true;
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
