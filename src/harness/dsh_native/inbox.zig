//! Inbox: FIFO next-turn/next-step queues with splice, claim ownership tokens,
//! and discard-on-interrupt (design §3.1; dsh packages/core/agent-loop/src/inbox.ts).
//!
//! Pure data structure: callers own IO and event logging. Every mutation returns
//! the normalized splice coordinates so the loop can append `agent/inbox/spliced`.
//! Claiming transfers exclusive ownership of the batch (all `next-step` entries
//! plus, at a turn boundary, one `next-turn` entry), matching dsh `claim`.
//!
//! `pause`/`resumeClaim`/`discardClaim` keep a claimed batch addressable by its
//! plain-u64 token while a turn is suspended; `cancel(false)` discards both the
//! queues and paused claims (discard-on-interrupt), while `cancel(true)` keeps
//! them for a later resume.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Target = enum { next_turn, next_step };

pub const EntryKind = enum { followup, steer, inject, additional_context };

/// Whether enqueueing this input may wake the driver (dsh `send` wakeup).
/// A waking send submitted after an aborted activity must be routed to
/// `next_turn` and must not wake; that phase check belongs to the loop.
pub const Wake = enum { wake, none };

/// Borrowed message input. `data` is the lossless JSON of a dsh `user/message`
/// payload (id/role/content/source); the inbox copies every slice.
pub const Message = struct {
    id: []const u8,
    data: []const u8,
    /// Tool call/result seqs an additionalContext cites (`sourceEventSeqs`).
    source_event_seqs: []const u64 = &.{},
};

pub const Insert = struct {
    kind: EntryKind,
    message: Message,
};

/// Owned pending entry. All slices use the inbox allocator.
pub const Entry = struct {
    kind: EntryKind,
    id: []u8,
    data: []u8,
    source_event_seqs: []const u64,

    pub fn deinit(self: *Entry, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.data);
        if (self.source_event_seqs.len != 0) allocator.free(self.source_event_seqs);
    }
};

pub const Outcome = enum { canceled };

pub const SpliceInfo = struct {
    target: Target,
    /// Normalized start, using JS `Array#splice` coordinates.
    start: usize,
    removed_count: usize,
    inserted_count: usize,
    /// Set when removed entries were discarded, matching dsh
    /// `agent/inbox/spliced.outcome: "canceled"`.
    outcome: ?Outcome = null,

    pub fn isNoop(self: SpliceInfo) bool {
        return self.removed_count == 0 and self.inserted_count == 0;
    }
};

pub const SpliceTaken = struct {
    info: SpliceInfo,
    /// Removed entries owned by the caller; free each with `Entry.deinit` and
    /// the slice with the inbox allocator.
    removed: []Entry,
};

/// Exclusive ownership of one claimed batch. `token` is a plain u64 so a paused
/// claim can be named across a suspend/resume serialization boundary.
pub const Claim = struct {
    token: u64,
    turn: u64,
    target: Target,
    /// All `next-step` entries, in FIFO order.
    next_step: []Entry,
    /// At most one `next-turn` entry (dsh claims one turn per turn boundary).
    next_turn: []Entry,

    pub fn count(self: Claim) usize {
        return self.next_step.len + self.next_turn.len;
    }

    pub fn deinit(self: *Claim, allocator: Allocator) void {
        for (self.next_step) |*entry| entry.deinit(allocator);
        allocator.free(self.next_step);
        for (self.next_turn) |*entry| entry.deinit(allocator);
        allocator.free(self.next_turn);
    }
};

pub const Inbox = struct {
    allocator: Allocator,
    next_turn: std.ArrayListUnmanaged(Entry) = .empty,
    next_step: std.ArrayListUnmanaged(Entry) = .empty,
    paused: std.ArrayListUnmanaged(Claim) = .empty,
    next_token: u64 = 1,

    pub fn init(allocator: Allocator) Inbox {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Inbox) void {
        for (self.next_turn.items) |*entry| entry.deinit(self.allocator);
        self.next_turn.deinit(self.allocator);
        for (self.next_step.items) |*entry| entry.deinit(self.allocator);
        self.next_step.deinit(self.allocator);
        for (self.paused.items) |*held| held.deinit(self.allocator);
        self.paused.deinit(self.allocator);
    }

    /// Whether either queue holds work. Paused claims are in flight, not pending.
    pub fn hasPending(self: *const Inbox) bool {
        return self.next_turn.items.len != 0 or self.next_step.items.len != 0;
    }

    pub fn nextTurn(self: *const Inbox) []const Entry {
        return self.next_turn.items;
    }

    pub fn nextStep(self: *const Inbox) []const Entry {
        return self.next_step.items;
    }

    /// `followup`: queued for the next turn, wakes the driver.
    pub fn followup(self: *Inbox, message: Message) !Wake {
        try self.appendEntry(.next_turn, .{ .kind = .followup, .message = message });
        return .wake;
    }

    /// `steer`: queued for the next step boundary, wakes the driver.
    pub fn steer(self: *Inbox, message: Message) !Wake {
        try self.appendEntry(.next_step, .{ .kind = .steer, .message = message });
        return .wake;
    }

    /// `inject`: queued for the next step boundary without waking.
    pub fn inject(self: *Inbox, message: Message) !Wake {
        try self.appendEntry(.next_step, .{ .kind = .inject, .message = message });
        return .none;
    }

    /// Tool result context: a user message spliced into `next-step` with the
    /// tool call/result seqs it cites. Never wakes.
    pub fn additionalContext(self: *Inbox, message: Message) !Wake {
        try self.appendEntry(.next_step, .{ .kind = .additional_context, .message = message });
        return .none;
    }

    /// Claim at a turn boundary: all `next-step` input, then one `next-turn`.
    pub fn claimNextTurn(self: *Inbox, turn: u64) !Claim {
        return self.claim(.next_turn, turn);
    }

    /// Claim at a mid-turn step boundary: all `next-step` input.
    pub fn claimNextStep(self: *Inbox, turn: u64) !Claim {
        return self.claim(.next_step, turn);
    }

    /// Remove and return the complete batch proposed for one step.
    ///
    /// The dsh `next-turn` queue is one prompt per turn, so at most one entry
    /// leaves it; any remaining prompts stay queued for later turns.
    pub fn claim(self: *Inbox, target: Target, turn: u64) !Claim {
        const step_count = self.next_step.items.len;
        const turn_count: usize = if (target == .next_turn)
            @min(self.next_turn.items.len, 1)
        else
            0;

        // Allocate both outputs before moving either queue, so an OOM cannot
        // strand entries between the queue and the claim.
        const step_out: []Entry = if (step_count == 0)
            &.{}
        else
            try self.allocator.alloc(Entry, step_count);
        errdefer self.allocator.free(step_out);
        const turn_out: []Entry = if (turn_count == 0)
            &.{}
        else
            try self.allocator.alloc(Entry, turn_count);
        errdefer self.allocator.free(turn_out);

        @memcpy(step_out, self.next_step.items);
        @memcpy(turn_out, self.next_turn.items[0..turn_count]);
        self.next_step.clearRetainingCapacity();
        if (turn_count != 0) self.next_turn.replaceRangeAssumeCapacity(0, turn_count, &.{});

        const token = self.next_token;
        self.next_token +%= 1;
        if (self.next_token == 0) self.next_token = 1;

        return .{
            .token = token,
            .turn = turn,
            .target = target,
            .next_step = step_out,
            .next_turn = turn_out,
        };
    }

    /// dsh public splice: removed entries are discarded (`outcome: canceled`).
    pub fn splice(
        self: *Inbox,
        target: Target,
        start: i64,
        delete_count: i64,
        inserted: []const Insert,
    ) !SpliceInfo {
        return (try self.spliceInternal(target, start, delete_count, inserted, false)).info;
    }

    /// dsh internal `mutate(..., discardRemoved: false)`: the caller owns the
    /// removed entries (used by `claim` and by callers that must report them).
    pub fn spliceTake(
        self: *Inbox,
        target: Target,
        start: i64,
        delete_count: i64,
        inserted: []const Insert,
    ) !SpliceTaken {
        const outcome = try self.spliceInternal(target, start, delete_count, inserted, true);
        return .{ .info = outcome.info, .removed = outcome.removed };
    }

    /// Suspend a claim under its ownership token. On success the inbox owns the
    /// batch; the caller must not deinit it. On error the caller keeps it.
    pub fn pause(self: *Inbox, batch: Claim) !void {
        try self.paused.append(self.allocator, batch);
    }

    /// Recover a paused batch, or null when the token is unknown or discarded.
    pub fn resumeClaim(self: *Inbox, token: u64) ?Claim {
        for (self.paused.items, 0..) |held, index| {
            if (held.token == token) return self.paused.orderedRemove(index);
        }
        return null;
    }

    /// Discard one paused batch (discard-on-interrupt for a single claim).
    pub fn discardClaim(self: *Inbox, token: u64) bool {
        for (self.paused.items, 0..) |held, index| {
            if (held.token == token) {
                var discarded = self.paused.orderedRemove(index);
                discarded.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    /// Drop all pending input, clearing `next-step` before `next-turn` as dsh
    /// does. Returns the two cancellation splices for the caller to log.
    pub fn clear(self: *Inbox) [2]SpliceInfo {
        const step_removed = self.next_step.items.len;
        const turn_removed = self.next_turn.items.len;
        for (self.next_step.items) |*entry| entry.deinit(self.allocator);
        self.next_step.clearRetainingCapacity();
        for (self.next_turn.items) |*entry| entry.deinit(self.allocator);
        self.next_turn.clearRetainingCapacity();
        return .{
            .{
                .target = .next_step,
                .start = 0,
                .removed_count = step_removed,
                .inserted_count = 0,
                .outcome = if (step_removed != 0) .canceled else null,
            },
            .{
                .target = .next_turn,
                .start = 0,
                .removed_count = turn_removed,
                .inserted_count = 0,
                .outcome = if (turn_removed != 0) .canceled else null,
            },
        };
    }

    /// dsh `cancel(cause, {keepInbox})` inbox half: `keepInbox` preserves both
    /// queues and paused claims; otherwise everything pending is discarded.
    pub fn cancel(self: *Inbox, keep_inbox: bool) void {
        if (keep_inbox) return;
        _ = self.clear();
        for (self.paused.items) |*held| held.deinit(self.allocator);
        self.paused.clearRetainingCapacity();
    }

    fn appendEntry(self: *Inbox, target: Target, item: Insert) !void {
        _ = try self.splice(target, @intCast(self.list(target).items.len), 0, &.{item});
    }

    fn list(self: *Inbox, target: Target) *std.ArrayListUnmanaged(Entry) {
        return switch (target) {
            .next_turn => &self.next_turn,
            .next_step => &self.next_step,
        };
    }

    fn otherList(self: *Inbox, target: Target) *std.ArrayListUnmanaged(Entry) {
        return switch (target) {
            .next_turn => &self.next_step,
            .next_step => &self.next_turn,
        };
    }

    const SpliceOutcome = struct {
        info: SpliceInfo,
        removed: []Entry,
    };

    fn spliceInternal(
        self: *Inbox,
        target: Target,
        start: i64,
        delete_count: i64,
        inserted: []const Insert,
        take_removed: bool,
    ) !SpliceOutcome {
        const queue = self.list(target);
        const norm = normalize(start, delete_count, queue.items.len);

        // Clone every inserted entry before touching the queue.
        var clones: std.ArrayListUnmanaged(Entry) = .empty;
        defer clones.deinit(self.allocator);
        errdefer for (clones.items) |*entry| entry.deinit(self.allocator);
        for (inserted) |item| {
            if (item.message.id.len == 0) return error.InvalidMessageId;
            if (item.message.data.len == 0) return error.InvalidMessage;
            var entry = try cloneEntry(self.allocator, item);
            clones.append(self.allocator, entry) catch |err| {
                entry.deinit(self.allocator);
                return err;
            };
        }

        // dsh rejects duplicate message ids across both queues, ignoring the
        // range this splice replaces.
        for (clones.items, 0..) |entry, index| {
            for (clones.items[0..index]) |earlier| {
                if (std.mem.eql(u8, entry.id, earlier.id)) return error.DuplicateMessageId;
            }
            if (listHasId(queue.items, entry.id, norm.start, norm.count)) {
                return error.DuplicateMessageId;
            }
            if (listHasId(self.otherList(target).items, entry.id, 0, 0)) {
                return error.DuplicateMessageId;
            }
        }

        try queue.ensureTotalCapacity(self.allocator, queue.items.len - norm.count + clones.items.len);

        var removed: []Entry = &.{};
        errdefer self.allocator.free(removed);
        if (take_removed and norm.count != 0) removed = try self.allocator.alloc(Entry, norm.count);

        const doomed = queue.items[norm.start .. norm.start + norm.count];
        if (take_removed) {
            @memcpy(removed, doomed);
        } else {
            for (doomed) |*entry| entry.deinit(self.allocator);
        }
        queue.replaceRangeAssumeCapacity(norm.start, norm.count, clones.items);

        return .{
            .info = .{
                .target = target,
                .start = norm.start,
                .removed_count = norm.count,
                .inserted_count = clones.items.len,
                .outcome = if (!take_removed and norm.count != 0) .canceled else null,
            },
            .removed = removed,
        };
    }
};

fn cloneEntry(allocator: Allocator, item: Insert) !Entry {
    const id = try allocator.dupe(u8, item.message.id);
    errdefer allocator.free(id);
    const data = try allocator.dupe(u8, item.message.data);
    errdefer allocator.free(data);
    const seqs = if (item.message.source_event_seqs.len == 0)
        @as([]const u64, &.{})
    else
        try allocator.dupe(u64, item.message.source_event_seqs);
    return .{
        .kind = item.kind,
        .id = id,
        .data = data,
        .source_event_seqs = seqs,
    };
}

fn listHasId(items: []const Entry, id: []const u8, skip_start: usize, skip_len: usize) bool {
    const skip_end = skip_start + skip_len;
    for (items, 0..) |entry, index| {
        if (index >= skip_start and index < skip_end) continue;
        if (std.mem.eql(u8, entry.id, id)) return true;
    }
    return false;
}

/// JS `Array#splice` coordinate normalization: negative starts count from the
/// end, out-of-range starts clamp, and delete counts clamp to the remainder.
fn normalize(start: i64, delete_count: i64, len: usize) struct { start: usize, count: usize } {
    const len_i: i128 = @intCast(len);
    const raw_start: i128 = start;
    const position: i128 = if (raw_start < 0) len_i + raw_start else raw_start;
    const clamped_start: usize = if (position <= 0)
        0
    else if (position >= len_i)
        len
    else
        @intCast(position);
    const remaining: i128 = len_i - @as(i128, @intCast(clamped_start));
    const count: usize = if (delete_count <= 0)
        0
    else if (@as(i128, delete_count) >= remaining)
        @intCast(remaining)
    else
        @intCast(delete_count);
    return .{ .start = clamped_start, .count = count };
}

const testing = std.testing;

fn makeInsert(kind: EntryKind, id: []const u8) Insert {
    return .{ .kind = kind, .message = .{ .id = id, .data = "{}" } };
}

fn makeMessage(id: []const u8) Message {
    return .{ .id = id, .data = "{}" };
}

fn freeTaken(allocator: Allocator, taken: SpliceTaken) void {
    for (taken.removed) |*entry| entry.deinit(allocator);
    allocator.free(taken.removed);
}

test "helpers route followup to next-turn and steer/inject/context to next-step in FIFO order" {
    var inbox = Inbox.init(testing.allocator);
    defer inbox.deinit();

    try testing.expectEqual(Wake.wake, try inbox.followup(makeMessage("f1")));
    try testing.expectEqual(Wake.wake, try inbox.followup(makeMessage("f2")));
    try testing.expectEqual(Wake.wake, try inbox.steer(makeMessage("s1")));
    try testing.expectEqual(Wake.none, try inbox.inject(makeMessage("i1")));
    try testing.expectEqual(Wake.none, try inbox.additionalContext(.{
        .id = "c1",
        .data = "{\"id\":\"c1\",\"role\":\"user\"}",
        .source_event_seqs = &.{ 7, 8 },
    }));

    try testing.expectEqual(@as(usize, 2), inbox.nextTurn().len);
    try testing.expectEqualStrings("f1", inbox.nextTurn()[0].id);
    try testing.expectEqualStrings("f2", inbox.nextTurn()[1].id);
    try testing.expectEqual(EntryKind.followup, inbox.nextTurn()[1].kind);

    try testing.expectEqual(@as(usize, 3), inbox.nextStep().len);
    try testing.expectEqualStrings("s1", inbox.nextStep()[0].id);
    try testing.expectEqualStrings("i1", inbox.nextStep()[1].id);
    try testing.expectEqualStrings("c1", inbox.nextStep()[2].id);
    try testing.expectEqual(EntryKind.steer, inbox.nextStep()[0].kind);
    try testing.expectEqual(EntryKind.inject, inbox.nextStep()[1].kind);
    try testing.expectEqual(EntryKind.additional_context, inbox.nextStep()[2].kind);
    try testing.expectEqualSlices(u64, &.{ 7, 8 }, inbox.nextStep()[2].source_event_seqs);
    try testing.expect(inbox.hasPending());
}

test "claim at a turn boundary takes all next-step then one next-turn" {
    var inbox = Inbox.init(testing.allocator);
    defer inbox.deinit();

    _ = try inbox.followup(makeMessage("t1"));
    _ = try inbox.followup(makeMessage("t2"));
    _ = try inbox.steer(makeMessage("s1"));
    _ = try inbox.inject(makeMessage("s2"));

    var turn_claim = try inbox.claimNextTurn(5);
    defer turn_claim.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), turn_claim.count());
    try testing.expectEqual(@as(u64, 5), turn_claim.turn);
    try testing.expectEqual(Target.next_turn, turn_claim.target);
    try testing.expectEqual(@as(usize, 2), turn_claim.next_step.len);
    try testing.expectEqualStrings("s1", turn_claim.next_step[0].id);
    try testing.expectEqualStrings("s2", turn_claim.next_step[1].id);
    try testing.expectEqual(@as(usize, 1), turn_claim.next_turn.len);
    try testing.expectEqualStrings("t1", turn_claim.next_turn[0].id);

    try testing.expectEqual(@as(usize, 1), inbox.nextTurn().len);
    try testing.expectEqualStrings("t2", inbox.nextTurn()[0].id);
    try testing.expectEqual(@as(usize, 0), inbox.nextStep().len);

    var step_claim = try inbox.claimNextStep(6);
    defer step_claim.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), step_claim.count());
    try testing.expectEqual(@as(usize, 1), inbox.nextTurn().len);
    try testing.expect(turn_claim.token != step_claim.token);

    var last_claim = try inbox.claimNextTurn(7);
    defer last_claim.deinit(testing.allocator);
    try testing.expectEqualStrings("t2", last_claim.next_turn[0].id);
    try testing.expect(!inbox.hasPending());
}

test "spliceTake normalizes JS splice coordinates and returns removed entries" {
    var inbox = Inbox.init(testing.allocator);
    defer inbox.deinit();

    _ = try inbox.steer(makeMessage("a"));
    _ = try inbox.steer(makeMessage("b"));
    _ = try inbox.steer(makeMessage("c"));

    const tail = try inbox.spliceTake(.next_step, -1, 1, &.{makeInsert(.steer, "x")});
    defer freeTaken(testing.allocator, tail);
    try testing.expectEqual(@as(usize, 2), tail.info.start);
    try testing.expectEqual(@as(usize, 1), tail.info.removed_count);
    try testing.expectEqual(@as(usize, 1), tail.info.inserted_count);
    try testing.expect(tail.info.outcome == null);
    try testing.expectEqualStrings("c", tail.removed[0].id);
    try testing.expectEqual(@as(usize, 3), inbox.nextStep().len);
    try testing.expectEqualStrings("a", inbox.nextStep()[0].id);
    try testing.expectEqualStrings("b", inbox.nextStep()[1].id);
    try testing.expectEqualStrings("x", inbox.nextStep()[2].id);

    // A start past the end appends; a negative delete count inserts only.
    const appended = try inbox.spliceTake(.next_step, 99, -4, &.{makeInsert(.inject, "y")});
    defer freeTaken(testing.allocator, appended);
    try testing.expectEqual(@as(usize, 3), appended.info.start);
    try testing.expectEqual(@as(usize, 0), appended.info.removed_count);
    try testing.expectEqual(@as(usize, 0), appended.removed.len);

    // A negative start below zero clamps to zero.
    const front = try inbox.spliceTake(.next_step, -99, 1, &.{makeInsert(.steer, "z")});
    defer freeTaken(testing.allocator, front);
    try testing.expectEqual(@as(usize, 0), front.info.start);
    try testing.expectEqualStrings("a", front.removed[0].id);
    try testing.expectEqualStrings("z", inbox.nextStep()[0].id);

    // An oversized delete count clamps to the remainder.
    const all = try inbox.spliceTake(.next_step, 0, 99, &.{});
    defer freeTaken(testing.allocator, all);
    try testing.expectEqual(@as(usize, 4), all.info.removed_count);
    try testing.expectEqual(@as(usize, 0), inbox.nextStep().len);
}

test "public splice discards removed entries and marks the outcome canceled" {
    var inbox = Inbox.init(testing.allocator);
    defer inbox.deinit();

    _ = try inbox.steer(makeMessage("a"));
    _ = try inbox.steer(makeMessage("b"));

    const info = try inbox.splice(.next_step, 0, 1, &.{makeInsert(.inject, "c")});
    try testing.expectEqual(@as(usize, 1), info.removed_count);
    try testing.expectEqual(@as(usize, 1), info.inserted_count);
    try testing.expectEqual(Outcome.canceled, info.outcome.?);
    try testing.expectEqualStrings("c", inbox.nextStep()[0].id);
    try testing.expectEqualStrings("b", inbox.nextStep()[1].id);

    const noop = try inbox.splice(.next_step, 99, 0, &.{});
    try testing.expect(noop.isNoop());
    try testing.expect(noop.outcome == null);
    try testing.expectEqual(@as(usize, 2), inbox.nextStep().len);
}

test "duplicate ids across either queue are rejected without mutating" {
    var inbox = Inbox.init(testing.allocator);
    defer inbox.deinit();

    _ = try inbox.followup(makeMessage("m1"));
    try testing.expectError(error.DuplicateMessageId, inbox.steer(makeMessage("m1")));
    try testing.expectEqual(@as(usize, 1), inbox.nextTurn().len);
    try testing.expectEqual(@as(usize, 0), inbox.nextStep().len);

    try testing.expectError(
        error.DuplicateMessageId,
        inbox.splice(.next_step, 0, 0, &.{ makeInsert(.steer, "d"), makeInsert(.inject, "d") }),
    );
    try testing.expectEqual(@as(usize, 0), inbox.nextStep().len);

    // Replacing an entry with the same id is allowed.
    const replaced = try inbox.splice(.next_turn, 0, 1, &.{makeInsert(.followup, "m1")});
    try testing.expectEqual(@as(usize, 1), replaced.removed_count);
    try testing.expectEqualStrings("m1", inbox.nextTurn()[0].id);
}

test "pause holds a claim under its token and resume or discard releases it" {
    var inbox = Inbox.init(testing.allocator);
    defer inbox.deinit();

    _ = try inbox.followup(makeMessage("t1"));
    _ = try inbox.steer(makeMessage("s1"));
    const claim = try inbox.claimNextTurn(3);
    const token = claim.token;
    try testing.expectEqual(@as(usize, 2), claim.count());

    try inbox.pause(claim);
    try testing.expect(!inbox.hasPending());

    var resumed = inbox.resumeClaim(token).?;
    try testing.expectEqual(@as(u64, token), resumed.token);
    try testing.expectEqual(@as(usize, 2), resumed.count());
    try testing.expectEqualStrings("s1", resumed.next_step[0].id);
    try testing.expectEqualStrings("t1", resumed.next_turn[0].id);
    try testing.expect(inbox.resumeClaim(token) == null);
    resumed.deinit(testing.allocator);

    const second = try inbox.claimNextStep(4);
    try inbox.pause(second);
    try testing.expect(inbox.discardClaim(second.token));
    try testing.expect(!inbox.discardClaim(second.token));
    try testing.expect(inbox.resumeClaim(second.token) == null);
}

test "cancel keeps or discards queues and paused claims" {
    var inbox = Inbox.init(testing.allocator);
    defer inbox.deinit();

    _ = try inbox.followup(makeMessage("t1"));
    _ = try inbox.steer(makeMessage("s1"));
    const claim = try inbox.claimNextStep(1);
    try inbox.pause(claim);

    inbox.cancel(true);
    try testing.expectEqual(@as(usize, 1), inbox.nextTurn().len);
    const resumed = inbox.resumeClaim(claim.token).?;
    try testing.expectEqualStrings("s1", resumed.next_step[0].id);

    try inbox.pause(resumed);
    inbox.cancel(false);
    try testing.expect(!inbox.hasPending());
    try testing.expect(inbox.resumeClaim(claim.token) == null);
}

test "clear reports next-step before next-turn cancellation splices" {
    var inbox = Inbox.init(testing.allocator);
    defer inbox.deinit();

    _ = try inbox.followup(makeMessage("t1"));
    _ = try inbox.steer(makeMessage("s1"));

    const splices = inbox.clear();
    try testing.expectEqual(Target.next_step, splices[0].target);
    try testing.expectEqual(@as(usize, 1), splices[0].removed_count);
    try testing.expectEqual(Outcome.canceled, splices[0].outcome.?);
    try testing.expectEqual(Target.next_turn, splices[1].target);
    try testing.expectEqual(@as(usize, 1), splices[1].removed_count);
    try testing.expectEqual(Outcome.canceled, splices[1].outcome.?);
    try testing.expect(!inbox.hasPending());
}

test "a 64KB entry is freed through claim, pause, resume and discard" {
    var inbox = Inbox.init(testing.allocator);
    defer inbox.deinit();

    const big = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    _ = try inbox.followup(.{ .id = "big", .data = big });
    const claim = try inbox.claimNextTurn(1);
    try testing.expectEqual(@as(usize, 64 * 1024), claim.next_turn[0].data.len);
    try testing.expectEqual(@as(u8, 'x'), claim.next_turn[0].data[0]);
    try testing.expectEqual(@as(u8, 'x'), claim.next_turn[0].data[claim.next_turn[0].data.len - 1]);

    try inbox.pause(claim);
    const resumed = inbox.resumeClaim(claim.token).?;
    try testing.expectEqual(@as(usize, 64 * 1024), resumed.next_turn[0].data.len);
    try inbox.pause(resumed);
    try testing.expect(inbox.discardClaim(claim.token));

    // A still-queued 64KB entry is freed by deinit.
    _ = try inbox.inject(.{ .id = "big2", .data = big });
    try testing.expectEqual(@as(usize, 1), inbox.nextStep().len);
}
