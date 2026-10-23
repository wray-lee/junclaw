//! Same-session goal domain: event-sourced state, compare-and-set mutations,
//! and the strictly validated `goal/change` fold (design §1.7 B32).
//!
//! Every durable mutation appends one `goal/change` event; `rebuild` replays a
//! session log into the same projection a live store holds, so a reopened
//! session resumes with the exact pre-restart goal. Round admission is derived
//! from `user/message` events whose source kind is `goal` (B32).

const std = @import("std");
const compat = @import("compat");
const session_log = @import("session_log.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Durable payload version of `goal/change` (dsh `GOAL_CHANGE_VERSION`).
pub const CHANGE_VERSION: i64 = 1;
pub const default_max_goal_rounds: u32 = 256;

pub const Phase = enum { active, paused, blocked, complete };

/// Process-local continuation state; never persisted, always disarmed on load.
pub const Activation = enum { armed, disarmed };

pub const BlockedReason = struct {
    code: []const u8,
    message: []const u8,
};

pub const Snapshot = struct {
    id: []const u8,
    revision: u32,
    objective: []const u8,
    phase: Phase,
    blocked_reason: ?BlockedReason = null,
    max_goal_rounds: u32,
};

/// Compare-and-set identity for one exact revision.
pub const Ref = struct {
    id: []const u8,
    revision: u32,
};

pub const Error = error{
    GoalNotFound,
    GoalAlreadyExists,
    GoalStaleRevision,
    GoalInvalidTransition,
    GoalInvalidObjective,
    GoalInvalidMaxRounds,
    GoalInvalidEdit,
    GoalInvalidBlockReason,
    GoalInvalidChange,
    GoalRoundsExhausted,
    GoalLogWriteFailed,
    OutOfMemory,
};

pub const Clock = struct {
    context: ?*anyopaque = null,
    now: *const fn (?*anyopaque) i64 = wallClock,
};

fn wallClock(_: ?*anyopaque) i64 {
    return compat.time.milliTimestamp();
}

/// Live goal state plus the append-only log it mutates.
///
/// All state strings are arena-owned; moving the Store value is safe because
/// nothing points back into the struct.
pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    current: ?Snapshot = null,
    rounds_started: u32 = 0,
    created_at: i64 = 0,
    updated_at: i64 = 0,
    activation: Activation = .disarmed,
    log: ?*session_log.Log = null,
    default_max_goal_rounds: u32 = default_max_goal_rounds,
    clock: Clock = .{},
    seen: std.ArrayListUnmanaged([]const u8) = .empty,
    next_goal_number: u64 = 1,

    pub fn init(child_allocator: Allocator) Store {
        return .{ .arena = std.heap.ArenaAllocator.init(child_allocator) };
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
    }

    /// Drop all durable and process-local state, keeping the configured clock.
    pub fn reset(self: *Store) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(child);
        self.current = null;
        self.rounds_started = 0;
        self.created_at = 0;
        self.updated_at = 0;
        self.activation = .disarmed;
        self.seen = .empty;
        self.next_goal_number = 1;
    }

    pub fn attachLog(self: *Store, log: ?*session_log.Log) void {
        self.log = log;
    }

    fn allocator(self: *Store) Allocator {
        return self.arena.allocator();
    }

    fn now(self: *Store) i64 {
        return self.clock.now(self.clock.context);
    }

    fn mutationTime(self: *Store, previous: i64) i64 {
        return @max(self.now(), previous);
    }

    pub fn find(self: *const Store) ?Snapshot {
        return self.current;
    }

    // ── mutations (dsh goal-service semantics) ─────────────────────────────

    pub fn create(self: *Store, objective: []const u8, max_rounds: ?u32) Error!Snapshot {
        const normalized = try self.normalizeObjective(objective);
        const cap = max_rounds orelse self.default_max_goal_rounds;
        if (cap == 0) return error.GoalInvalidMaxRounds;
        if (self.current) |current| {
            if (current.phase != .complete) return error.GoalAlreadyExists;
        }
        const a = self.allocator();
        // Allocate the whole next snapshot before the append touches state.
        const id = try std.fmt.allocPrint(a, "goal-{d}", .{self.next_goal_number});
        const owned_objective = try a.dupe(u8, normalized);
        const snapshot = Snapshot{
            .id = id,
            .revision = 1,
            .objective = owned_objective,
            .phase = .active,
            .max_goal_rounds = cap,
        };
        const at = self.now();
        try self.commitSnapshot(.create, snapshot, 0, at, at, .armed);
        self.next_goal_number += 1;
        return self.current.?;
    }

    pub fn edit(self: *Store, ref: Ref, objective: ?[]const u8, max_rounds: ?u32) Error!Snapshot {
        const current = try self.expectCurrent(ref);
        if (objective == null and max_rounds == null) return error.GoalInvalidEdit;
        var next = current;
        next.revision = current.revision + 1;
        if (objective) |value| {
            const normalized = try self.normalizeObjective(value);
            next.objective = try self.allocator().dupe(u8, normalized);
        }
        if (max_rounds) |cap| {
            if (cap == 0) return error.GoalInvalidMaxRounds;
            next.max_goal_rounds = cap;
        }
        try self.commitSnapshot(.edit, next, self.rounds_started, self.created_at, self.mutationTime(self.updated_at), self.activation);
        return self.current.?;
    }

    pub fn pause(self: *Store, ref: Ref) Error!Snapshot {
        const current = try self.expectCurrent(ref);
        if (current.phase != .active) return error.GoalInvalidTransition;
        return self.transition(current, .paused, .disarmed);
    }

    pub fn @"resume"(self: *Store, ref: Ref) Error!Snapshot {
        const current = try self.expectCurrent(ref);
        if (current.phase == .complete) return error.GoalInvalidTransition;
        if (self.rounds_started >= current.max_goal_rounds) return error.GoalRoundsExhausted;
        return self.transition(current, .active, .armed);
    }

    pub fn complete(self: *Store, ref: Ref) Error!Snapshot {
        const current = try self.expectCurrent(ref);
        if (current.phase == .complete) return error.GoalInvalidTransition;
        return self.transition(current, .complete, .disarmed);
    }

    pub fn block(self: *Store, ref: Ref, code: []const u8, message: []const u8) Error!Snapshot {
        const current = try self.expectCurrent(ref);
        if (current.phase != .active) return error.GoalInvalidTransition;
        if (!isLowerKebab(code)) return error.GoalInvalidBlockReason;
        const normalized = std.mem.trim(u8, message, " \t\r\n");
        if (normalized.len == 0) return error.GoalInvalidBlockReason;
        const a = self.allocator();
        var next = current;
        next.revision = current.revision + 1;
        next.phase = .blocked;
        next.blocked_reason = .{
            .code = try a.dupe(u8, code),
            .message = try a.dupe(u8, normalized),
        };
        try self.commitSnapshot(.block, next, self.rounds_started, self.created_at, self.mutationTime(self.updated_at), .disarmed);
        return self.current.?;
    }

    /// Clear the current goal and return its durable tombstone ref.
    pub fn clear(self: *Store, ref: Ref) Error!Ref {
        const current = try self.expectCurrent(ref);
        const tombstone = Ref{ .id = current.id, .revision = current.revision + 1 };
        const cleared_at = self.mutationTime(self.updated_at);
        const data = try encodeClear(self.allocator(), tombstone, cleared_at);
        try self.append("goal/change", data);
        self.current = null;
        self.rounds_started = 0;
        self.created_at = 0;
        self.updated_at = 0;
        self.activation = .disarmed;
        return tombstone;
    }

    fn transition(self: *Store, current: Snapshot, phase: Phase, activation: Activation) Error!Snapshot {
        var next = current;
        next.revision = current.revision + 1;
        next.phase = phase;
        next.blocked_reason = null;
        try self.commitSnapshot(operationFor(phase), next, self.rounds_started, self.created_at, self.mutationTime(self.updated_at), activation);
        return self.current.?;
    }

    fn commitSnapshot(
        self: *Store,
        operation: Operation,
        snapshot: Snapshot,
        rounds: u32,
        created_at: i64,
        updated_at: i64,
        activation: Activation,
    ) Error!void {
        // Reserve the seen-id slot before the append commits the event, so a
        // later allocation failure cannot log a create the state rejects.
        if (operation == .create) try self.seen.ensureUnusedCapacity(self.allocator(), 1);
        const data = try encodeSnapshot(self.allocator(), operation, snapshot, rounds, created_at, updated_at);
        try self.append("goal/change", data);
        if (operation == .create) self.seen.appendAssumeCapacity(snapshot.id);
        self.current = snapshot;
        self.rounds_started = rounds;
        self.created_at = created_at;
        self.updated_at = updated_at;
        self.activation = activation;
    }

    fn append(self: *Store, event_type: []const u8, data: Value) Error!void {
        if (self.log) |log| {
            _ = log.append(event_type, data, .{}) catch return error.GoalLogWriteFailed;
        }
    }

    fn expectCurrent(self: *Store, ref: Ref) Error!Snapshot {
        const current = self.current orelse return error.GoalNotFound;
        if (!std.mem.eql(u8, ref.id, current.id) or ref.revision != current.revision) return error.GoalStaleRevision;
        return current;
    }

    fn normalizeObjective(self: *Store, objective: []const u8) Error![]const u8 {
        _ = self;
        const normalized = std.mem.trim(u8, objective, " \t\r\n");
        if (normalized.len == 0) return error.GoalInvalidObjective;
        return normalized;
    }

    // ── replay / projection ────────────────────────────────────────────────

    /// Rebuild the projection from a contiguous session log; disarmed on load.
    pub fn rebuild(self: *Store, events: []const types.Event) Error!void {
        self.reset();
        for (events) |event| try self.applyEvent(event);
    }

    pub fn applyEvent(self: *Store, event: types.Event) Error!void {
        if (std.mem.eql(u8, event.event_type, "goal/change")) return self.applyChange(event.data);
        if (std.mem.eql(u8, event.event_type, "user/message")) return self.applyUserMessage(event.data);
    }

    fn applyChange(self: *Store, data: Value) Error!void {
        const change = try objectOf(data);
        const kind = try stringField(change, "kind");
        if (!std.mem.eql(u8, kind, "goal/change")) return error.GoalInvalidChange;
        if (try integerField(change, "version", 0) != CHANGE_VERSION) return error.GoalInvalidChange;
        const operation = try stringField(change, "operation");
        if (std.mem.eql(u8, operation, "clear")) return self.applyClear(change);
        const op = parseOperation(operation) orelse return error.GoalInvalidChange;
        const goal = try decodeSnapshot(self.allocator(), change);
        const rounds = try integerField(change, "roundsStarted", 0);
        if (rounds > std.math.maxInt(u32)) return error.GoalInvalidChange;
        const created_at = try integerField(change, "createdAt", 0);
        const updated_at = try integerField(change, "updatedAt", 0);
        const rounds_u32: u32 = @intCast(rounds);
        if (updated_at < created_at) return error.GoalInvalidChange;

        if (op == .create) {
            if (goal.revision != 1 or goal.phase != .active or rounds_u32 != 0) return error.GoalInvalidChange;
            if (self.current) |current| {
                if (current.phase != .complete) return error.GoalInvalidChange;
            }
            if (self.isSeen(goal.id)) return error.GoalInvalidChange;
            try self.seen.append(self.allocator(), goal.id);
            self.noteGoalId(goal.id);
        } else {
            const current = self.current orelse return error.GoalInvalidChange;
            if (!std.mem.eql(u8, goal.id, current.id) or goal.revision != current.revision + 1) return error.GoalInvalidChange;
            if (created_at != self.created_at or updated_at < self.updated_at or rounds_u32 != self.rounds_started) {
                return error.GoalInvalidChange;
            }
            switch (op) {
                .edit => {
                    if (goal.phase != current.phase or !sameBlockedReason(goal.blocked_reason, current.blocked_reason)) {
                        return error.GoalInvalidChange;
                    }
                },
                .pause => {
                    if (!sameDefinition(goal, current) or current.phase != .active or goal.phase != .paused) return error.GoalInvalidChange;
                },
                .@"resume" => {
                    if (!sameDefinition(goal, current) or current.phase == .complete or goal.phase != .active) return error.GoalInvalidChange;
                    if (rounds_u32 >= goal.max_goal_rounds) return error.GoalInvalidChange;
                },
                .complete => {
                    if (!sameDefinition(goal, current) or current.phase == .complete or goal.phase != .complete) return error.GoalInvalidChange;
                },
                .block => {
                    if (!sameDefinition(goal, current) or current.phase != .active or goal.phase != .blocked) return error.GoalInvalidChange;
                    if (goal.blocked_reason == null) return error.GoalInvalidChange;
                },
                .create, .clear => unreachable,
            }
        }

        self.current = goal;
        self.rounds_started = rounds_u32;
        self.created_at = created_at;
        self.updated_at = updated_at;
    }

    fn applyClear(self: *Store, change: std.json.ObjectMap) Error!void {
        const cleared = try objectOf(try field(change, "cleared"));
        const id = try stringField(cleared, "id");
        if (id.len == 0) return error.GoalInvalidChange;
        const revision = try integerField(cleared, "revision", 1);
        if (revision > std.math.maxInt(u32)) return error.GoalInvalidChange;
        const cleared_at = try integerField(change, "clearedAt", 0);
        const current = self.current orelse return error.GoalInvalidChange;
        if (!std.mem.eql(u8, id, current.id) or @as(u32, @intCast(revision)) != current.revision + 1) return error.GoalInvalidChange;
        if (cleared_at < self.updated_at) return error.GoalInvalidChange;
        self.current = null;
        self.rounds_started = 0;
        self.created_at = 0;
        self.updated_at = 0;
        self.activation = .disarmed;
    }

    fn applyUserMessage(self: *Store, data: Value) Error!void {
        const message = try objectOf(data);
        const source_value = message.get("source") orelse return;
        const source = switch (source_value) {
            .object => |object| object,
            else => return,
        };
        const kind_value = source.get("kind") orelse return;
        const kind = switch (kind_value) {
            .string => |text| text,
            else => return,
        };
        if (!std.mem.eql(u8, kind, "goal")) return;
        const goal_id = try stringField(source, "goalId");
        const revision = try integerField(source, "revision", 1);
        const round = try integerField(source, "round", 1);
        const current = self.current orelse return error.GoalInvalidChange;
        if (current.phase != .active or !std.mem.eql(u8, goal_id, current.id)) return error.GoalInvalidChange;
        if (revision > std.math.maxInt(u32) or round > std.math.maxInt(u32)) return error.GoalInvalidChange;
        if (@as(u32, @intCast(revision)) != current.revision) return error.GoalInvalidChange;
        if (@as(u32, @intCast(round)) != self.rounds_started + 1 or @as(u32, @intCast(round)) > current.max_goal_rounds) {
            return error.GoalInvalidChange;
        }
        self.rounds_started = @intCast(round);
    }

    fn isSeen(self: *const Store, id: []const u8) bool {
        for (self.seen.items) |seen| if (std.mem.eql(u8, seen, id)) return true;
        return false;
    }

    fn noteGoalId(self: *Store, id: []const u8) void {
        const prefix = "goal-";
        if (!std.mem.startsWith(u8, id, prefix)) return;
        const number = std.fmt.parseInt(u64, id[prefix.len..], 10) catch return;
        if (number >= self.next_goal_number) self.next_goal_number = number + 1;
    }

    /// Test/helper entry point for one admitted goal round message.
    pub fn applyUserMessageValue(self: *Store, goal_id: []const u8, revision: u32, round: u32) Error!void {
        var source = std.json.ObjectMap.empty;
        try source.put(self.allocator(), "kind", .{ .string = "goal" });
        try source.put(self.allocator(), "goalId", .{ .string = goal_id });
        try source.put(self.allocator(), "revision", .{ .integer = revision });
        try source.put(self.allocator(), "round", .{ .integer = round });
        var message = std.json.ObjectMap.empty;
        try message.put(self.allocator(), "source", .{ .object = source });
        try self.applyUserMessage(.{ .object = message });
    }
};

const Operation = enum { create, edit, pause, @"resume", complete, block, clear };

fn parseOperation(text: []const u8) ?Operation {
    inline for (@typeInfo(Operation).@"enum".fields) |member| {
        if (std.mem.eql(u8, text, member.name)) return @enumFromInt(member.value);
    }
    return null;
}

fn operationFor(phase: Phase) Operation {
    return switch (phase) {
        .active => .@"resume",
        .paused => .pause,
        .blocked => .block,
        .complete => .complete,
    };
}

pub fn phaseName(phase: Phase) []const u8 {
    return @tagName(phase);
}

pub fn activationName(activation: Activation) []const u8 {
    return @tagName(activation);
}

/// Stable machine-routable failure code (dsh `GoalError.code`).
pub fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.GoalNotFound => "GOAL_NOT_FOUND",
        error.GoalAlreadyExists => "GOAL_ALREADY_EXISTS",
        error.GoalStaleRevision => "GOAL_STALE_REVISION",
        error.GoalInvalidTransition => "GOAL_INVALID_TRANSITION",
        error.GoalRoundsExhausted => "GOAL_INVALID_TRANSITION",
        error.GoalInvalidObjective => "GOAL_INVALID_OBJECTIVE",
        error.GoalInvalidMaxRounds => "GOAL_INVALID_MAX_ROUNDS",
        error.GoalInvalidEdit => "GOAL_INVALID_EDIT",
        error.GoalInvalidBlockReason => "GOAL_INVALID_BLOCK_REASON",
        error.GoalInvalidChange => "GOAL_INVALID_CHANGE",
        error.GoalLogWriteFailed => "GOAL_LOG_WRITE_FAILED",
        else => "GOAL_INTERNAL",
    };
}

/// Human-readable failure message, using the current goal for context.
pub fn describeError(self: *const Store, allocator: Allocator, err: anyerror, action: []const u8) ![]const u8 {
    return switch (err) {
        error.GoalNotFound => try allocator.dupe(u8, "no current goal"),
        error.GoalAlreadyExists => if (self.current) |current|
            try std.fmt.allocPrint(allocator, "goal \"{s}\" already exists with phase \"{s}\"", .{ current.id, phaseName(current.phase) })
        else
            try allocator.dupe(u8, "a goal already exists"),
        error.GoalStaleRevision => if (self.current) |current|
            try std.fmt.allocPrint(allocator, "stale goal ref; current is \"{s}\" revision {d}", .{ current.id, current.revision })
        else
            try allocator.dupe(u8, "stale goal ref; no current goal"),
        error.GoalInvalidTransition => if (self.current) |current|
            try std.fmt.allocPrint(
                allocator,
                "cannot {s} goal \"{s}\" from phase \"{s}\"; expected a valid source phase",
                .{ action, current.id, phaseName(current.phase) },
            )
        else
            try std.fmt.allocPrint(allocator, "cannot {s} without a current goal", .{action}),
        error.GoalRoundsExhausted => if (self.current) |current|
            try std.fmt.allocPrint(
                allocator,
                "goal \"{s}\" exhausted {d} goal rounds; increase maxGoalRounds before resuming",
                .{ current.id, current.max_goal_rounds },
            )
        else
            try allocator.dupe(u8, "goal round budget exhausted"),
        error.GoalInvalidObjective => try allocator.dupe(u8, "goal objective must be a non-empty string"),
        error.GoalInvalidMaxRounds => try allocator.dupe(u8, "maxGoalRounds must be a positive safe integer"),
        error.GoalInvalidEdit => try allocator.dupe(u8, "goal edit requires objective and/or maxGoalRounds"),
        error.GoalInvalidBlockReason => try allocator.dupe(u8, "goal block reason requires a lower-kebab-case code and a non-empty message"),
        error.GoalInvalidChange => try allocator.dupe(u8, "goal change is invalid"),
        error.GoalLogWriteFailed => try allocator.dupe(u8, "goal change could not be persisted"),
        else => try allocator.dupe(u8, @errorName(err)),
    };
}

fn sameDefinition(a: Snapshot, b: Snapshot) bool {
    return std.mem.eql(u8, a.objective, b.objective) and a.max_goal_rounds == b.max_goal_rounds;
}

fn sameBlockedReason(a: ?BlockedReason, b: ?BlockedReason) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?.code, b.?.code) and std.mem.eql(u8, a.?.message, b.?.message);
}

fn isLowerKebab(text: []const u8) bool {
    if (text.len == 0 or text[0] < 'a' or text[0] > 'z') return false;
    var segment_empty = false;
    for (text[1..]) |c| {
        if (c == '-') {
            if (segment_empty) return false;
            segment_empty = true;
            continue;
        }
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'))) return false;
        segment_empty = false;
    }
    return !segment_empty;
}

// ── change encoding ────────────────────────────────────────────────────────

fn encodeSnapshot(
    a: Allocator,
    operation: Operation,
    snapshot: Snapshot,
    rounds: u32,
    created_at: i64,
    updated_at: i64,
) Error!Value {
    var goal = std.json.ObjectMap.empty;
    try goal.put(a, "id", .{ .string = snapshot.id });
    try goal.put(a, "revision", .{ .integer = snapshot.revision });
    try goal.put(a, "objective", .{ .string = snapshot.objective });
    try goal.put(a, "phase", .{ .string = phaseName(snapshot.phase) });
    try goal.put(a, "maxGoalRounds", .{ .integer = snapshot.max_goal_rounds });
    if (snapshot.blocked_reason) |reason| {
        var blocked = std.json.ObjectMap.empty;
        try blocked.put(a, "code", .{ .string = reason.code });
        try blocked.put(a, "message", .{ .string = reason.message });
        try goal.put(a, "blockedReason", .{ .object = blocked });
    }
    var data = std.json.ObjectMap.empty;
    try data.put(a, "kind", .{ .string = "goal/change" });
    try data.put(a, "version", .{ .integer = CHANGE_VERSION });
    try data.put(a, "operation", .{ .string = @tagName(operation) });
    try data.put(a, "goal", .{ .object = goal });
    try data.put(a, "roundsStarted", .{ .integer = rounds });
    try data.put(a, "createdAt", .{ .integer = created_at });
    try data.put(a, "updatedAt", .{ .integer = updated_at });
    return .{ .object = data };
}

fn encodeClear(a: Allocator, cleared: Ref, cleared_at: i64) Error!Value {
    var ref = std.json.ObjectMap.empty;
    try ref.put(a, "id", .{ .string = cleared.id });
    try ref.put(a, "revision", .{ .integer = cleared.revision });
    var data = std.json.ObjectMap.empty;
    try data.put(a, "kind", .{ .string = "goal/change" });
    try data.put(a, "version", .{ .integer = CHANGE_VERSION });
    try data.put(a, "operation", .{ .string = "clear" });
    try data.put(a, "cleared", .{ .object = ref });
    try data.put(a, "clearedAt", .{ .integer = cleared_at });
    return .{ .object = data };
}

// ── change decoding ────────────────────────────────────────────────────────

fn objectOf(value: Value) Error!std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.GoalInvalidChange,
    };
}

fn field(object: std.json.ObjectMap, name: []const u8) Error!Value {
    return object.get(name) orelse error.GoalInvalidChange;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) Error![]const u8 {
    return switch (try field(object, name)) {
        .string => |text| text,
        else => error.GoalInvalidChange,
    };
}

fn integerField(object: std.json.ObjectMap, name: []const u8, minimum: i64) Error!i64 {
    const value = switch (try field(object, name)) {
        .integer => |number| number,
        else => return error.GoalInvalidChange,
    };
    if (value < minimum) return error.GoalInvalidChange;
    return value;
}

fn decodeSnapshot(a: Allocator, change: std.json.ObjectMap) Error!Snapshot {
    const object = try objectOf(try field(change, "goal"));
    const id = try stringField(object, "id");
    if (id.len == 0) return error.GoalInvalidChange;
    const revision = try integerField(object, "revision", 1);
    if (revision > std.math.maxInt(u32)) return error.GoalInvalidChange;
    const objective = try stringField(object, "objective");
    const normalized = std.mem.trim(u8, objective, " \t\r\n");
    if (normalized.len == 0 or !std.mem.eql(u8, normalized, objective)) return error.GoalInvalidChange;
    const phase_text = try stringField(object, "phase");
    const phase = parsePhase(phase_text) orelse return error.GoalInvalidChange;
    const max_rounds = try integerField(object, "maxGoalRounds", 1);
    if (max_rounds > std.math.maxInt(u32)) return error.GoalInvalidChange;
    var snapshot = Snapshot{
        .id = try a.dupe(u8, id),
        .revision = @intCast(revision),
        .objective = try a.dupe(u8, objective),
        .phase = phase,
        .max_goal_rounds = @intCast(max_rounds),
    };
    if (object.get("blockedReason")) |reason_value| {
        if (phase != .blocked) return error.GoalInvalidChange;
        const reason = try objectOf(reason_value);
        const code = try stringField(reason, "code");
        const message = try stringField(reason, "message");
        const trimmed = std.mem.trim(u8, message, " \t\r\n");
        if (!isLowerKebab(code) or trimmed.len == 0 or !std.mem.eql(u8, trimmed, message)) return error.GoalInvalidChange;
        snapshot.blocked_reason = .{
            .code = try a.dupe(u8, code),
            .message = try a.dupe(u8, message),
        };
    } else if (phase == .blocked) {
        return error.GoalInvalidChange;
    }
    return snapshot;
}

fn parsePhase(text: []const u8) ?Phase {
    inline for (@typeInfo(Phase).@"enum".fields) |field_info| {
        if (std.mem.eql(u8, text, field_info.name)) return @enumFromInt(field_info.value);
    }
    return null;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn fixedClock(context: ?*anyopaque) i64 {
    const value: *const i64 = @ptrCast(@alignCast(context.?));
    return value.*;
}

const TestSession = struct {
    tmp: std.testing.TmpDir,
    dir: []const u8,
    path: []const u8,
    log: session_log.Log,

    fn init(allocator: Allocator) !TestSession {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
        errdefer allocator.free(dir);
        const path = try std.fs.path.join(allocator, &.{ dir, "session.jsonl" });
        errdefer allocator.free(path);
        const header = types.Header{ .id = "session-test", .created_at = 1, .cwd = "/work/example.com" };
        const log = try session_log.Log.create(allocator, path, header);
        return .{ .tmp = tmp, .dir = dir, .path = path, .log = log };
    }

    fn deinit(self: *TestSession, allocator: Allocator) void {
        self.log.close();
        allocator.free(self.path);
        allocator.free(self.dir);
        self.tmp.cleanup();
    }
};

fn readEvents(allocator: Allocator, path: []const u8) !session_log.ReadResult {
    return session_log.readLog(allocator, path);
}

fn logGoalRound(log: *session_log.Log, allocator: Allocator, goal_id: []const u8, revision: u32, round: u32) !void {
    var source = std.json.ObjectMap.empty;
    try source.put(allocator, "kind", .{ .string = "goal" });
    try source.put(allocator, "goalId", .{ .string = goal_id });
    try source.put(allocator, "revision", .{ .integer = revision });
    try source.put(allocator, "round", .{ .integer = round });
    var message = std.json.ObjectMap.empty;
    try message.put(allocator, "source", .{ .object = source });
    _ = try log.append("user/message", .{ .object = message }, .{});
}

test "goal create, edit, and phase transitions bump revision monotonically" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var at: i64 = 100;
    store.clock = .{ .context = &at, .now = fixedClock };

    const created = try store.create("  ship the release  ", null);
    try testing.expectEqualStrings("goal-1", created.id);
    try testing.expectEqual(@as(u32, 1), created.revision);
    try testing.expectEqualStrings("ship the release", created.objective);
    try testing.expectEqual(Phase.active, created.phase);
    try testing.expectEqual(@as(u32, 256), created.max_goal_rounds);
    try testing.expectEqual(Activation.armed, store.activation);

    at = 200;
    const edited = try store.edit(.{ .id = created.id, .revision = 1 }, " ship it now ", 4);
    try testing.expectEqual(@as(u32, 2), edited.revision);
    try testing.expectEqualStrings("ship it now", edited.objective);
    try testing.expectEqual(@as(u32, 4), edited.max_goal_rounds);

    const paused = try store.pause(.{ .id = edited.id, .revision = 2 });
    try testing.expectEqual(Phase.paused, paused.phase);
    try testing.expectEqual(Activation.disarmed, store.activation);

    const resumed = try store.@"resume"(.{ .id = paused.id, .revision = 3 });
    try testing.expectEqual(Phase.active, resumed.phase);
    try testing.expectEqual(Activation.armed, store.activation);

    const done = try store.complete(.{ .id = resumed.id, .revision = 4 });
    try testing.expectEqual(Phase.complete, done.phase);
    try testing.expectEqual(Activation.disarmed, store.activation);
    try testing.expectEqual(@as(u32, 5), done.revision);

    const cleared = try store.clear(.{ .id = done.id, .revision = 5 });
    try testing.expectEqualStrings("goal-1", cleared.id);
    try testing.expectEqual(@as(u32, 6), cleared.revision);
    try testing.expect(store.find() == null);
    try testing.expectEqual(@as(u32, 0), store.rounds_started);
}

test "goal rejects invalid transitions, stale refs, and bad arguments" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var at: i64 = 100;
    store.clock = .{ .context = &at, .now = fixedClock };

    try testing.expectError(error.GoalNotFound, store.pause(.{ .id = "goal-1", .revision = 1 }));

    const created = try store.create("objective", null);
    try testing.expectError(error.GoalAlreadyExists, store.create("second", null));
    try testing.expectError(error.GoalInvalidObjective, store.create("   ", null));
    try testing.expectError(error.GoalInvalidMaxRounds, store.create("objective", 0));
    try testing.expectError(error.GoalStaleRevision, store.edit(.{ .id = created.id, .revision = 9 }, "next", null));
    try testing.expectError(error.GoalInvalidEdit, store.edit(.{ .id = created.id, .revision = 1 }, null, null));
    try testing.expectError(error.GoalInvalidObjective, store.edit(.{ .id = created.id, .revision = 1 }, "  ", null));

    try testing.expectError(error.GoalInvalidBlockReason, store.block(.{ .id = created.id, .revision = 1 }, "Bad Code", "x"));
    try testing.expectError(error.GoalInvalidBlockReason, store.block(.{ .id = created.id, .revision = 1 }, "ok", "   "));
    const blocked = try store.block(.{ .id = created.id, .revision = 1 }, "model-reported", "  stuck on missing input  ");
    try testing.expectEqual(Phase.blocked, blocked.phase);
    try testing.expectEqualStrings("model-reported", blocked.blocked_reason.?.code);
    try testing.expectEqualStrings("stuck on missing input", blocked.blocked_reason.?.message);
    try testing.expectEqual(Activation.disarmed, store.activation);
    try testing.expectError(error.GoalInvalidTransition, store.block(.{ .id = blocked.id, .revision = 2 }, "ok", "x"));

    const resumed = try store.@"resume"(.{ .id = blocked.id, .revision = 2 });
    try testing.expectEqual(Phase.active, resumed.phase);
    const done = try store.complete(.{ .id = resumed.id, .revision = 3 });
    try testing.expectError(error.GoalInvalidTransition, store.pause(.{ .id = done.id, .revision = 4 }));
    try testing.expectError(error.GoalInvalidTransition, store.complete(.{ .id = done.id, .revision = 4 }));
    try testing.expectError(error.GoalInvalidTransition, store.@"resume"(.{ .id = done.id, .revision = 4 }));

    // A completed goal may be replaced by a fresh create.
    const replaced = try store.create("replacement", 2);
    try testing.expectEqualStrings("goal-2", replaced.id);
    try testing.expectEqual(Phase.active, replaced.phase);
}

test "goal resume needs round budget" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var at: i64 = 100;
    store.clock = .{ .context = &at, .now = fixedClock };
    const created = try store.create("budget", 1);
    try store.applyUserMessageValue(created.id, 1, 1);
    try testing.expectEqual(@as(u32, 1), store.rounds_started);
    try testing.expectError(error.GoalRoundsExhausted, store.@"resume"(.{ .id = created.id, .revision = 1 }));
}

test "goal projection rebuilds from a log and matches the live store" {
    var session = try TestSession.init(testing.allocator);
    defer session.deinit(testing.allocator);
    var at: i64 = 1_000;
    var live = Store.init(testing.allocator);
    defer live.deinit();
    live.clock = .{ .context = &at, .now = fixedClock };
    live.attachLog(&session.log);
    var json_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer json_arena.deinit();

    const created = try live.create("rebuild me", 8);
    at = 1_010;
    _ = try live.edit(.{ .id = created.id, .revision = 1 }, "rebuild me again", null);
    try logGoalRound(&session.log, json_arena.allocator(), "goal-1", 2, 1);
    try live.applyUserMessageValue("goal-1", 2, 1);
    try logGoalRound(&session.log, json_arena.allocator(), "goal-1", 2, 2);
    try live.applyUserMessageValue("goal-1", 2, 2);
    at = 1_030;
    const blocked = try live.block(.{ .id = "goal-1", .revision = 2 }, "model-reported", "waiting on example.com");
    try testing.expectEqual(Phase.blocked, blocked.phase);

    var read = try readEvents(testing.allocator, session.path);
    defer read.deinit();
    var rebuilt = Store.init(testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.rebuild(read.events);

    try testing.expectEqual(live.find().?.revision, rebuilt.find().?.revision);
    try testing.expectEqualStrings("rebuild me again", rebuilt.find().?.objective);
    try testing.expectEqual(@as(u32, 3), rebuilt.find().?.revision);
    try testing.expectEqual(Phase.blocked, rebuilt.find().?.phase);
    try testing.expectEqualStrings("waiting on example.com", rebuilt.find().?.blocked_reason.?.message);
    try testing.expectEqual(@as(u32, 2), rebuilt.rounds_started);
    try testing.expectEqual(live.created_at, rebuilt.created_at);
    try testing.expectEqual(live.updated_at, rebuilt.updated_at);
    try testing.expectEqual(Activation.disarmed, rebuilt.activation);

    // A cleared goal rebuilds to the pre-create null projection.
    at = 1_040;
    _ = try live.clear(.{ .id = "goal-1", .revision = 3 });
    var cleared_read = try readEvents(testing.allocator, session.path);
    defer cleared_read.deinit();
    try rebuilt.rebuild(cleared_read.events);
    try testing.expect(rebuilt.find() == null);
    try testing.expectEqual(@as(u32, 0), rebuilt.rounds_started);
}

test "goal fold rejects malformed goal changes and round mismatches" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var at: i64 = 100;
    store.clock = .{ .context = &at, .now = fixedClock };
    var json_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer json_arena.deinit();

    const bad = try std.json.parseFromSliceLeaky(
        Value,
        json_arena.allocator(),
        "{\"kind\":\"goal/change\",\"version\":1,\"operation\":\"pause\",\"goal\":{\"id\":\"goal-1\",\"revision\":2,\"objective\":\"x\",\"phase\":\"paused\",\"maxGoalRounds\":4},\"roundsStarted\":0,\"createdAt\":0,\"updatedAt\":1}",
        .{},
    );
    try testing.expectError(error.GoalInvalidChange, store.applyChange(bad));

    const created = try store.create("x", 4);
    try testing.expectError(error.GoalInvalidChange, store.applyUserMessageValue(created.id, 1, 2));
    try store.applyUserMessageValue(created.id, 1, 1);
    try testing.expectError(error.GoalInvalidChange, store.applyUserMessageValue(created.id, 1, 3));
    try testing.expectError(error.GoalInvalidChange, store.applyUserMessageValue(created.id, 2, 2));

    const block_without_reason = try std.json.parseFromSliceLeaky(
        Value,
        json_arena.allocator(),
        "{\"kind\":\"goal/change\",\"version\":1,\"operation\":\"block\",\"goal\":{\"id\":\"goal-1\",\"revision\":2,\"objective\":\"x\",\"phase\":\"blocked\",\"maxGoalRounds\":4},\"roundsStarted\":1,\"createdAt\":100,\"updatedAt\":100}",
        .{},
    );
    try testing.expectError(error.GoalInvalidChange, store.applyChange(block_without_reason));
}

test "goal handles a 64 KiB objective without leaks" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var at: i64 = 100;
    store.clock = .{ .context = &at, .now = fixedClock };

    const objective = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(objective);
    @memset(objective, 'x');
    const created = try store.create(objective, 3);
    try testing.expectEqual(@as(usize, 64 * 1024), created.objective.len);
    const edited_objective = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(edited_objective);
    @memset(edited_objective, 'y');
    const edited = try store.edit(.{ .id = created.id, .revision = 1 }, edited_objective, null);
    try testing.expectEqual(@as(usize, 64 * 1024), edited.objective.len);
}
