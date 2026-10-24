//! Plan-mode state machine (design §1.8 B34).
//!
//! Mirrors dsh 0.2.1-rc.2:
//! - `packages/plan/plan-mode/src/index.ts:120-168` (PlanUnitState fold and
//!   the PlanProjection wire view);
//! - `:425-470` (selection queue, pre-step commit and narration).
//!
//! The module owns no log and performs no I/O. `foldEvent`/`replay` derive the
//! logged state from an existing session log; `set` decides whether a user
//! selection is written now or queued until the next accepted in-turn
//! pre-step; `preStep` reports the queued selection and its narration;
//! `pendingCommitted` clears the queue only after the caller appended the
//! event, so a failed write stays retryable.
//!
//! `UnitState.running.command_id` borrows from the folded event payload.

const std = @import("std");
const generated = @import("generated/interaction.zig");
const types = @import("types.zig");

const whitespace = " \t\n\r";

/// Host state used to derive `Projection` (dsh `PlanUnitState`).
pub const UnitState = struct {
    /// Logged plan mode; inactive before the first `plan/mode`.
    active: bool = false,
    /// Target of the last settled plan command; null when none is outstanding.
    wanted: ?bool = null,
    /// Latest plan command awaiting its paired settlement.
    running: ?Running = null,
    /// Active state recorded by the latest `request/header`, or null.
    active_at_last_header: ?bool = null,
};

pub const Running = struct {
    command_id: []const u8,
    wanted: bool,
};

/// Wire value of the `plan` projection (dsh `PlanProjection`).
pub const Projection = struct {
    active: bool,
    /// A logged selection targets a state other than `active` and has not
    /// settled through its paired `command/done` or a later `plan/mode`.
    pending: bool,
};

/// Selection awaiting the next accepted in-turn pre-step.
pub const Pending = struct {
    active: bool,
    /// User selections narrate; the exit tool does not (its result narrates).
    narrate: bool,
};

/// What a `/plan` selection did (dsh `set` return value).
pub const Outcome = enum { committed, queued, cancelled, noop };

/// Read-only command context: the current logged state, any queued target, and
/// whether a turn is open.
pub const View = struct {
    active: bool = false,
    pending: ?bool = null,
    active_at_last_header: ?bool = null,
    turn_open: bool = false,
};

/// One selection decision. `emit` is the `plan/mode` payload to append now;
/// `queue` is the target to store when the selection waits for a pre-step.
pub const Decision = struct {
    outcome: Outcome,
    emit: ?bool = null,
    /// Narration to inject after a successful immediate commit.
    narration: ?[]const u8 = null,
    queue: ?bool = null,
    clear_pending: bool = false,
};

/// One pre-step boundary decision. The pending selection is retained until the
/// caller appends `emit` successfully and calls `pendingCommitted`.
pub const PreStep = struct {
    emit: ?bool = null,
    narration: ?[]const u8 = null,
};

/// Narration for a user switch, or null when the last request header already
/// described the target mode (dsh `narration`).
pub fn narrationFor(active_at_last_header: ?bool, target: bool) ?[]const u8 {
    const told = active_at_last_header orelse return null;
    if (told == target) return null;
    return if (target)
        generated.plan_mode.narration_on
    else
        generated.plan_mode.narration_off;
}

/// Decide one `/plan` selection without mutating any state.
pub fn decide(view: View, active: bool) Decision {
    const target = view.pending orelse view.active;
    if (active == target) return .{ .outcome = .noop };
    if (view.turn_open) {
        return .{
            .outcome = if (view.active == active) .cancelled else .queued,
            .queue = active,
        };
    }
    if (view.active == active) return .{ .outcome = .cancelled, .clear_pending = true };
    return .{
        .outcome = .committed,
        .emit = active,
        .narration = narrationFor(view.active_at_last_header, active),
        .clear_pending = true,
    };
}

/// Process-local plan state: the logged fold plus the pending selection queue.
pub const Session = struct {
    state: UnitState = .{},
    pending: ?Pending = null,

    pub fn view(self: *const Session, turn_open: bool) View {
        return .{
            .active = self.state.active,
            .pending = if (self.pending) |pending| pending.active else null,
            .active_at_last_header = self.state.active_at_last_header,
            .turn_open = turn_open,
        };
    }

    /// Select a target mode. Mutates only the pending queue; the caller folds
    /// the emitted `plan/mode` event after a successful append.
    pub fn set(self: *Session, active: bool, turn_open: bool) Decision {
        const decision = decide(self.view(turn_open), active);
        self.applyDecision(decision);
        return decision;
    }

    /// Apply a decision produced by `decide` (for a command framework that
    /// owns the lifecycle and returns the decision to its caller).
    pub fn applyDecision(self: *Session, decision: Decision) void {
        if (decision.queue) |target| self.pending = .{ .active = target, .narrate = true };
        if (decision.clear_pending) self.pending = null;
    }

    /// Queue the exit tool's silent selection (dsh sets `narrate: false`).
    pub fn queueExit(self: *Session) void {
        self.pending = .{ .active = false, .narrate = false };
    }

    /// Next accepted, non-aborted pre-step: report the selection to append. A
    /// target equal to the logged mode needs no event and is dropped here.
    pub fn preStep(self: *Session) PreStep {
        const pending = self.pending orelse return .{};
        // dsh narrates before onBoundary, so a cancelled pending selection can
        // still carry a switch notice when the last header described the
        // other mode.
        const narration = if (pending.narrate)
            narrationFor(self.state.active_at_last_header, pending.active)
        else
            null;
        if (pending.active == self.state.active) {
            self.pending = null;
            return .{ .narration = narration };
        }
        return .{ .emit = pending.active, .narration = narration };
    }

    /// Clear the pending selection after its `plan/mode` event was appended.
    pub fn pendingCommitted(self: *Session) void {
        self.pending = null;
    }

    /// dsh wire projection: `running.wanted` wins over the settled `wanted`.
    pub fn projection(self: *const Session) Projection {
        const wanted = if (self.state.running) |running| running.wanted else self.state.wanted;
        return .{
            .active = self.state.active,
            .pending = wanted != null and wanted.? != self.state.active,
        };
    }

    /// Fold one session event. The payload is validated; unknown event types
    /// leave the state unchanged.
    pub fn foldEvent(self: *Session, event: types.Event) !void {
        if (std.mem.eql(u8, event.event_type, "command/run")) {
            const object = try eventObject(event);
            if (!std.mem.eql(u8, try stringField(object, "name"), generated.plan_mode.command_name)) return;
            // dsh treats a missing args field as a non-plan invocation.
            const value = object.get("args") orelse return;
            const raw_input = switch (value) {
                .string => |text| text,
                else => return error.InvalidPlanEvent,
            };
            self.state.running = .{
                .command_id = try stringField(object, "commandId"),
                .wanted = !std.mem.eql(u8, std.mem.trim(u8, raw_input, whitespace), "off"),
            };
            return;
        }
        if (std.mem.eql(u8, event.event_type, "command/done")) {
            const running = self.state.running orelse return;
            const object = try eventObject(event);
            if (!std.mem.eql(u8, try stringField(object, "commandId"), running.command_id)) return;
            const kind = try stringField(object, "kind");
            self.state.wanted = if (std.mem.eql(u8, kind, "success") and running.wanted != self.state.active)
                running.wanted
            else
                null;
            self.state.running = null;
            return;
        }
        if (std.mem.eql(u8, event.event_type, "plan/mode")) {
            const object = try eventObject(event);
            self.state.active = try boolField(object, "active");
            self.state.wanted = null;
            return;
        }
        if (std.mem.eql(u8, event.event_type, "request/header")) {
            self.state.active_at_last_header = self.state.active;
        }
    }

    /// Rebuild a session projection by replaying a log (resume/fork).
    pub fn replay(events: []const types.Event) !Session {
        var session = Session{};
        for (events) |event| try session.foldEvent(event);
        return session;
    }
};

fn eventObject(event: types.Event) !std.json.ObjectMap {
    return switch (event.data) {
        .object => |object| object,
        else => error.InvalidPlanEvent,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (object.get(key) orelse return error.InvalidPlanEvent) {
        .string => |text| text,
        else => error.InvalidPlanEvent,
    };
}

fn boolField(object: std.json.ObjectMap, key: []const u8) !bool {
    return switch (object.get(key) orelse return error.InvalidPlanEvent) {
        .bool => |value| value,
        else => error.InvalidPlanEvent,
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const Allocator = std.mem.Allocator;

fn commandRun(allocator: Allocator, command_id: []const u8, args: ?[]const u8) !types.Event {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "commandId", .{ .string = command_id });
    try object.put(allocator, "name", .{ .string = generated.plan_mode.command_name });
    if (args) |text| try object.put(allocator, "args", .{ .string = text });
    return .{ .event_type = "command/run", .seq = 0, .time_ms = 0, .data = .{ .object = object } };
}

fn commandDone(allocator: Allocator, command_id: []const u8, kind: []const u8) !types.Event {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "commandId", .{ .string = command_id });
    try object.put(allocator, "kind", .{ .string = kind });
    return .{ .event_type = "command/done", .seq = 0, .time_ms = 0, .data = .{ .object = object } };
}

fn planMode(allocator: Allocator, active: bool) !types.Event {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "active", .{ .bool = active });
    return .{ .event_type = "plan/mode", .seq = 0, .time_ms = 0, .data = .{ .object = object } };
}

fn requestHeader() types.Event {
    return .{ .event_type = "request/header", .seq = 0, .time_ms = 0, .data = .{ .bool = true } };
}

test "plan projection follows the command lifecycle and mode events" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var session = Session{};
    try session.foldEvent(try commandRun(a, "cmd-1", " on"));
    try testing.expect(session.projection().pending);

    try session.foldEvent(try commandDone(a, "cmd-1", "success"));
    try testing.expect(session.projection().pending);
    try testing.expectEqual(@as(?bool, true), session.state.wanted);

    try session.foldEvent(try planMode(a, true));
    try testing.expect(session.projection().active);
    try testing.expect(!session.projection().pending);

    try session.foldEvent(requestHeader());
    try testing.expectEqual(@as(?bool, true), session.state.active_at_last_header);
}

test "plan projection drops a failed selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var session = Session{};
    try session.foldEvent(try commandRun(a, "cmd-1", " on"));
    try session.foldEvent(try commandDone(a, "cmd-1", "error"));
    try testing.expect(!session.projection().pending);
    try testing.expectEqual(@as(?bool, null), session.state.wanted);
}

test "plan selection commits immediately without an open turn" {
    var session = Session{};
    const decision = session.set(true, false);
    try testing.expectEqual(Outcome.committed, decision.outcome);
    try testing.expectEqual(@as(?bool, true), decision.emit);
    try testing.expectEqual(@as(?[]const u8, null), decision.narration);
    try testing.expect(session.pending == null);
    // The logged state changes when the caller folds the emitted event.
    try testing.expect(!session.state.active);
}

test "plan selection queues during an open turn and commits at the pre-step" {
    var session = Session{};
    const decision = session.set(true, true);
    try testing.expectEqual(Outcome.queued, decision.outcome);
    try testing.expectEqual(@as(?bool, null), decision.emit);
    try testing.expectEqual(@as(?bool, true), session.pending.?.active);

    const boundary = session.preStep();
    try testing.expectEqual(@as(?bool, true), boundary.emit);
    try testing.expect(session.pending != null);
    session.pendingCommitted();
    try testing.expect(session.pending == null);
    try testing.expect(!session.state.active);
}

test "plan selection cancels a queued switch back to the logged mode" {
    var session = Session{};
    _ = session.set(true, true);
    const decision = session.set(false, true);
    try testing.expectEqual(Outcome.cancelled, decision.outcome);
    try testing.expectEqual(@as(?bool, false), session.pending.?.active);
}

test "plan selection cancels immediately when no turn is open" {
    var session = Session{};
    session.pending = .{ .active = true, .narrate = true };
    const decision = session.set(false, false);
    try testing.expectEqual(Outcome.cancelled, decision.outcome);
    try testing.expect(session.pending == null);
}

test "plan selection repeats the outstanding target as a no-op" {
    var session = Session{};
    _ = session.set(true, true);
    const decision = session.set(true, true);
    try testing.expectEqual(Outcome.noop, decision.outcome);
    try testing.expectEqual(@as(?bool, true), session.pending.?.active);
}

test "plan pre-step drops a stale pending target" {
    var session = Session{};
    session.pending = .{ .active = false, .narrate = true };
    const boundary = session.preStep();
    try testing.expectEqual(@as(?bool, null), boundary.emit);
    try testing.expect(session.pending == null);
}

test "plan cancelled pending selection still narrates at the pre-step" {
    var session = Session{};
    session.state.active_at_last_header = true;
    session.pending = .{ .active = false, .narrate = true };
    const boundary = session.preStep();
    try testing.expectEqual(@as(?bool, null), boundary.emit);
    try testing.expectEqualStrings(generated.plan_mode.narration_off, boundary.narration.?);
    try testing.expect(session.pending == null);
}

test "plan narration follows the last request header" {
    try testing.expect(narrationFor(null, true) == null);
    try testing.expectEqualStrings(generated.plan_mode.narration_on, narrationFor(false, true).?);
    try testing.expectEqualStrings(generated.plan_mode.narration_off, narrationFor(true, false).?);
    try testing.expect(narrationFor(true, true) == null);
}

test "plan queued narration is computed at the pre-step" {
    var session = Session{};
    session.state.active_at_last_header = false;
    _ = session.set(true, true);
    const boundary = session.preStep();
    try testing.expectEqualStrings(generated.plan_mode.narration_on, boundary.narration.?);
}

test "plan exit selection is silent and applies at the pre-step" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var session = Session{};
    session.state.active = true;
    session.state.active_at_last_header = true;
    session.queueExit();
    try testing.expectEqual(@as(?bool, false), session.pending.?.active);
    try testing.expect(!session.pending.?.narrate);

    const boundary = session.preStep();
    try testing.expectEqual(@as(?bool, false), boundary.emit);
    try testing.expectEqual(@as(?[]const u8, null), boundary.narration);
    // The tool batch keeps the plan section until the event is appended.
    try testing.expect(session.state.active);

    session.pendingCommitted();
    try session.foldEvent(try planMode(a, false));
    try testing.expect(!session.state.active);
}

test "plan replay restores the logged projection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const events = [_]types.Event{
        try commandRun(a, "cmd-1", " on"),
        try planMode(a, true),
        try commandDone(a, "cmd-1", "success"),
        requestHeader(),
    };
    const session = try Session.replay(&events);
    try testing.expect(session.state.active);
    try testing.expectEqual(@as(?bool, true), session.state.active_at_last_header);
    try testing.expect(!session.projection().pending);
}

test "plan fold rejects malformed payloads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var object: std.json.ObjectMap = .empty;
    try object.put(a, "commandId", .{ .string = "cmd-1" });
    try object.put(a, "name", .{ .string = generated.plan_mode.command_name });
    try object.put(a, "args", .{ .integer = 1 });
    const malformed = types.Event{ .event_type = "command/run", .seq = 0, .time_ms = 0, .data = .{ .object = object } };

    var session = Session{};
    try testing.expectError(error.InvalidPlanEvent, session.foldEvent(malformed));
}
