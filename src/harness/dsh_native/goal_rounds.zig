//! Same-session automatic goal continuation (design §1.7 B32; dsh
//! `packages/goal/goal-round-driver/src/index.ts` and `prompt.ts`).
//!
//! The driver reserves at most one `<goal_round>` followup per round. The
//! durable counter stays in `goal.Store`: it advances only when the harness
//! folds the admitted `user/message` whose source kind is `goal`, so a dropped
//! followup never inflates `roundsStarted`. Driving stops on any non-active
//! phase and at the configured cap, where dsh blocks the goal with `round-limit`.

const std = @import("std");
const generated = @import("generated/tool_render.zig");
const goal = @import("goal.zig");
const inbox = @import("inbox.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// dsh `round-limit` blocked reason code.
pub const round_limit_code = "round-limit";

/// One queued round, kept until the durable fold admits it.
const Reservation = struct {
    revision: u32,
    round: u32,
};

pub const Driver = struct {
    store: *goal.Store,
    pending: ?Reservation = null,

    /// Reserve the next continuation prompt, or null when the goal must stop.
    ///
    /// An outstanding reservation suppresses a second followup for the same
    /// round, so a claim/splice/pause that leaves the message queued cannot
    /// duplicate it. A stale reservation (the goal was paused, resumed or
    /// edited meanwhile) is dropped: the resumed goal starts a fresh round.
    pub fn next(self: *Driver, allocator: Allocator) !?inbox.Message {
        const snapshot = self.store.find();
        if (self.pending) |reserved| {
            if (self.store.rounds_started >= reserved.round) {
                self.pending = null;
            } else if (snapshot) |current| {
                if (current.revision == reserved.revision and current.phase == .active and self.store.activation == .armed) {
                    return null;
                }
                self.pending = null;
            } else {
                self.pending = null;
            }
        }

        const current = snapshot orelse return null;
        if (current.phase != .active or self.store.activation != .armed) return null;
        if (self.store.rounds_started >= current.max_goal_rounds) {
            _ = try self.store.block(
                .{ .id = current.id, .revision = current.revision },
                round_limit_code,
                try std.fmt.allocPrint(
                    allocator,
                    "Goal reached its configured limit of {d} rounds.",
                    .{current.max_goal_rounds},
                ),
            );
            return null;
        }

        const round = self.store.rounds_started + 1;
        const message = try renderRound(allocator, current, round);
        self.pending = .{ .revision = current.revision, .round = round };
        return message;
    }
};

/// dsh `renderGoalRoundPrompt`: one text block with the JSON-quoted objective
/// and the admitted round's `user/message` source.
pub fn renderRound(allocator: Allocator, snapshot: goal.Snapshot, round: u32) !inbox.Message {
    const objective = try std.json.Stringify.valueAlloc(allocator, snapshot.objective, .{});
    const text = try std.fmt.allocPrint(allocator, generated.goal.round_prompt, .{
        objective,
        round,
        snapshot.max_goal_rounds,
    });
    const id = try std.fmt.allocPrint(allocator, "goal-round-{s}-{d}-{d}", .{
        snapshot.id,
        snapshot.revision,
        round,
    });

    var buffer: Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    const w = &buffer.writer;
    try w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, w);
    try w.writeAll("}],\"source\":{\"kind\":\"goal\",\"goalId\":");
    try std.json.Stringify.value(snapshot.id, .{}, w);
    try w.print(",\"revision\":{d},\"round\":{d}}},\"role\":\"user\",\"id\":", .{
        snapshot.revision,
        round,
    });
    try std.json.Stringify.value(id, .{}, w);
    try w.writeByte('}');
    return .{
        .id = try allocator.dupe(u8, id),
        .data = try buffer.toOwnedSlice(),
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const Value = std.json.Value;

fn fixedClock(context: ?*anyopaque) i64 {
    const value: *const i64 = @ptrCast(@alignCast(context.?));
    return value.*;
}

fn testStore(allocator: Allocator, at: *i64) goal.Store {
    var store = goal.Store.init(allocator);
    store.clock = .{ .context = at, .now = fixedClock };
    return store;
}

fn roundOf(allocator: Allocator, message: inbox.Message) !i64 {
    const data = try std.json.parseFromSliceLeaky(Value, allocator, message.data, .{});
    return data.object.get("source").?.object.get("round").?.integer;
}

test "goal round driver renders the generated prompt and reserves one round" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var at: i64 = 100;
    var store = testStore(testing.allocator, &at);
    defer store.deinit();
    _ = try store.create("ship it", 3);

    var driver = Driver{ .store = &store };
    const message = (try driver.next(allocator)).?;

    const data = try std.json.parseFromSliceLeaky(Value, allocator, message.data, .{});
    const object = data.object;
    const text = object.get("content").?.array.items[0].object.get("text").?.string;
    const objective = try std.json.Stringify.valueAlloc(allocator, "ship it", .{});
    const expected = try std.fmt.allocPrint(allocator, generated.goal.round_prompt, .{
        objective,
        1,
        3,
    });
    try testing.expectEqualStrings(expected, text);
    try testing.expectEqualStrings("user", object.get("role").?.string);
    const source = object.get("source").?.object;
    try testing.expectEqualStrings("goal", source.get("kind").?.string);
    try testing.expectEqualStrings("goal-1", source.get("goalId").?.string);
    try testing.expectEqual(@as(i64, 1), source.get("revision").?.integer);
    try testing.expectEqual(@as(i64, 1), source.get("round").?.integer);

    // Exactly once: the outstanding reservation is not queued twice.
    try testing.expect((try driver.next(allocator)) == null);
    try store.applyUserMessageValue("goal-1", 1, 1);
    try testing.expectEqual(@as(u32, 1), store.rounds_started);
    const second = (try driver.next(allocator)).?;
    try testing.expectEqual(@as(i64, 2), try roundOf(allocator, second));
}

test "goal rounds advance the shared counter only for goal-sourced user messages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var at: i64 = 100;
    var store = testStore(testing.allocator, &at);
    defer store.deinit();
    _ = try store.create("objective", 4);

    const human = try std.json.parseFromSliceLeaky(
        Value,
        allocator,
        "{\"id\":\"m1\",\"role\":\"user\",\"content\":[],\"source\":{\"kind\":\"user\"}}",
        .{},
    );
    try store.applyEvent(.{ .event_type = "user/message", .seq = 1, .time_ms = 0, .data = human });
    try testing.expectEqual(@as(u32, 0), store.rounds_started);

    const round = try std.json.parseFromSliceLeaky(
        Value,
        allocator,
        "{\"id\":\"m2\",\"role\":\"user\",\"content\":[],\"source\":{\"kind\":\"goal\",\"goalId\":\"goal-1\",\"revision\":1,\"round\":1}}",
        .{},
    );
    try store.applyEvent(.{ .event_type = "user/message", .seq = 2, .time_ms = 0, .data = round });
    try testing.expectEqual(@as(u32, 1), store.rounds_started);
}

test "goal round driver blocks at the configured cap and stops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var at: i64 = 100;
    var store = testStore(testing.allocator, &at);
    defer store.deinit();
    _ = try store.create("cap", 1);
    try store.applyUserMessageValue("goal-1", 1, 1);

    var driver = Driver{ .store = &store };
    try testing.expect((try driver.next(allocator)) == null);

    const blocked = store.find().?;
    try testing.expectEqual(goal.Phase.blocked, blocked.phase);
    try testing.expectEqualStrings(round_limit_code, blocked.blocked_reason.?.code);
    const expected = try std.fmt.allocPrint(allocator, "Goal reached its configured limit of {d} rounds.", .{1});
    try testing.expectEqualStrings(expected, blocked.blocked_reason.?.message);
    try testing.expectEqual(@as(u32, 1), store.rounds_started);
    // Already blocked: a second attempt neither drives nor mutates again.
    try testing.expect((try driver.next(allocator)) == null);
    try testing.expectEqual(@as(u32, 1), store.rounds_started);
}

test "goal round driver stops while paused, blocked, or complete" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var at: i64 = 100;

    var paused_store = testStore(testing.allocator, &at);
    defer paused_store.deinit();
    _ = try paused_store.create("paused", 4);
    _ = try paused_store.pause(.{ .id = "goal-1", .revision = 1 });
    var paused_driver = Driver{ .store = &paused_store };
    try testing.expect((try paused_driver.next(allocator)) == null);
    // Resume re-arms and invalidates the previous reservation.
    _ = try paused_store.@"resume"(.{ .id = "goal-1", .revision = 2 });
    try testing.expect((try paused_driver.next(allocator)) != null);

    var blocked_store = testStore(testing.allocator, &at);
    defer blocked_store.deinit();
    _ = try blocked_store.create("blocked", 4);
    _ = try blocked_store.block(.{ .id = "goal-1", .revision = 1 }, "model-reported", "no access");
    var blocked_driver = Driver{ .store = &blocked_store };
    try testing.expect((try blocked_driver.next(allocator)) == null);

    var complete_store = testStore(testing.allocator, &at);
    defer complete_store.deinit();
    _ = try complete_store.create("complete", 4);
    _ = try complete_store.complete(.{ .id = "goal-1", .revision = 1 });
    var complete_driver = Driver{ .store = &complete_store };
    try testing.expect((try complete_driver.next(allocator)) == null);
}

test "goal round followup survives claim, splice, and pause/resume exactly once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var at: i64 = 100;
    var store = testStore(testing.allocator, &at);
    defer store.deinit();
    _ = try store.create("objective", 3);

    var driver = Driver{ .store = &store };
    const message = (try driver.next(allocator)).?;

    var box = inbox.Inbox.init(testing.allocator);
    defer box.deinit();
    _ = try box.followup(message);
    _ = try box.steer(.{
        .id = "steer-1",
        .data = "{\"id\":\"steer-1\",\"role\":\"user\",\"content\":[],\"source\":{\"kind\":\"user\"}}",
    });

    const claim = try box.claimNextTurn(1);
    const token = claim.token;
    try testing.expectEqual(@as(usize, 1), claim.next_turn.len);
    try testing.expectEqual(@as(usize, 1), claim.next_step.len);
    try testing.expectEqualStrings("goal-round-goal-1-1-1", claim.next_turn[0].id);
    try box.pause(claim);

    // Pause/resume owns the same batch; the round neither duplicates nor moves.
    var resumed = box.resumeClaim(token).?;
    defer resumed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), resumed.next_turn.len);
    try testing.expectEqualStrings("goal-round-goal-1-1-1", resumed.next_turn[0].id);

    // While the message is outstanding the driver must not reserve it again.
    try testing.expect((try driver.next(allocator)) == null);
    // Admission advances the shared counter once; the next round is 2.
    try store.applyUserMessageValue("goal-1", 1, 1);
    const second = (try driver.next(allocator)).?;
    try testing.expectEqual(@as(i64, 2), try roundOf(allocator, second));
}

test "goal round prompt handles a 64 KiB objective without leaks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var at: i64 = 100;
    var store = testStore(testing.allocator, &at);
    defer store.deinit();

    const objective = try allocator.alloc(u8, 64 * 1024);
    @memset(objective, 'x');
    _ = try store.create(objective, 2);

    var driver = Driver{ .store = &store };
    const message = (try driver.next(allocator)).?;
    try testing.expect(message.data.len >= 64 * 1024);
    try testing.expect(std.mem.indexOf(u8, message.data, "<goal_round>") != null);
}
