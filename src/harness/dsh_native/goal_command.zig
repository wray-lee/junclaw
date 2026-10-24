//! Human-facing `/goal` command over the persisted same-session goal domain
//! (design §1.7 B32, B36; dsh `command-goal/src/index.ts`).
//!
//! `dispatch` owns the B36 lifecycle: `command/run` -> optional `goal/change`
//! (written by the domain) -> `command/done`. `executeCaptured` runs the same
//! business logic for `commands.zig`, which owns the lifecycle instead.
//! `register`/`find`/`run` are the registration surface a future `commands.zig`
//! registry can call without this module owning a global registry.

const std = @import("std");
const compat = @import("compat");
const goal = @import("goal.zig");
const session_log = @import("session_log.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const usage = "Usage: /goal [<objective>|clear|edit <objective>|pause|resume]";

pub const Kind = enum { success, failure };

pub const Result = struct {
    kind: Kind,
    text: []const u8,
};

/// One `execute` outcome plus the `goal/change` events it recorded, for a
/// command framework that owns the surrounding `command/run`/`command/done`.
/// Payloads borrow the store's arena, so consume them before it is reset.
pub const Outcome = struct {
    result: Result,
    events: []const types.Event,
};

/// One slash command as registered by a future command registry.
pub const Command = struct {
    name: []const u8,
    description: []const u8,
    input_hint: []const u8,
    context: ?*anyopaque,
    run: *const fn (?*anyopaque, Allocator, []const u8) anyerror!Result,
};

/// Append one command; duplicate names are a registration bug.
pub fn register(commands: *std.ArrayListUnmanaged(Command), allocator: Allocator, command: Command) !void {
    for (commands.items) |existing| {
        if (std.mem.eql(u8, existing.name, command.name)) return error.DuplicateCommand;
    }
    try commands.append(allocator, command);
}

pub fn find(commands: []const Command, name: []const u8) ?Command {
    for (commands) |command| {
        if (std.mem.eql(u8, command.name, name)) return command;
    }
    return null;
}

pub fn run(command: Command, allocator: Allocator, raw_input: []const u8) anyerror!Result {
    return command.run(command.context, allocator, raw_input);
}

pub const Goal = struct {
    store: *goal.Store,
    next_command_id: u64 = 1,

    pub fn command(self: *Goal) Command {
        return .{
            .name = "goal",
            .description = "Set or view the goal for a long-running task",
            .input_hint = "[<objective>|clear|edit <objective>|pause|resume]",
            .context = @ptrCast(self),
            .run = runHandler,
        };
    }

    /// Write the B36 lifecycle around one invocation.
    pub fn dispatch(self: *Goal, allocator: Allocator, raw_input: []const u8) anyerror!Result {
        const command_id = try std.fmt.allocPrint(allocator, "goal-cmd-{d}", .{self.next_command_id});
        self.next_command_id += 1;
        try self.appendRun(allocator, command_id, raw_input);
        const result = self.execute(allocator, raw_input) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
            self.appendDone(allocator, command_id, .failure, message) catch {};
            return err;
        };
        try self.appendDone(allocator, command_id, result.kind, result.text);
        return result;
    }

    fn appendRun(self: *Goal, allocator: Allocator, command_id: []const u8, raw_input: []const u8) !void {
        const log = self.store.log orelse return;
        var source = std.json.ObjectMap.empty;
        try source.put(allocator, "kind", .{ .string = "user" });
        var data = std.json.ObjectMap.empty;
        try data.put(allocator, "commandId", .{ .string = command_id });
        try data.put(allocator, "name", .{ .string = "goal" });
        try data.put(allocator, "args", .{ .string = raw_input });
        try data.put(allocator, "source", .{ .object = source });
        _ = try log.append("command/run", .{ .object = data }, .{});
    }

    fn appendDone(self: *Goal, allocator: Allocator, command_id: []const u8, kind: Kind, text: []const u8) !void {
        const log = self.store.log orelse return;
        var data = std.json.ObjectMap.empty;
        try data.put(allocator, "commandId", .{ .string = command_id });
        try data.put(allocator, "kind", .{ .string = switch (kind) {
            .success => "success",
            .failure => "error",
        } });
        try data.put(allocator, "text", .{ .string = text });
        _ = try log.append("command/done", .{ .object = data }, .{});
    }

    /// Execute one parsed human command without writing lifecycle events.
    pub fn execute(self: *Goal, allocator: Allocator, raw_input: []const u8) anyerror!Result {
        const parsed = parse(raw_input);
        const current = self.store.find();
        switch (parsed) {
            .show => {
                if (current) |snapshot| return renderGoal(allocator, "Goal", snapshot, self.store);
                return .{ .kind = .success, .text = try std.fmt.allocPrint(allocator, "No goal is currently set.\n{s}", .{usage}) };
            },
            .invalid_edit => return errorResult(allocator, "Goal editing requires a replacement objective.\n{s}", .{usage}),
            .create => |objective| {
                if (current) |snapshot| {
                    if (snapshot.phase != .complete) {
                        return errorResult(
                            allocator,
                            "A goal is already {s}. Use /goal edit <objective> to change it or /goal clear before replacing it.",
                            .{goal.phaseName(snapshot.phase)},
                        );
                    }
                }
                _ = self.store.create(objective, null) catch |err| return storeError(allocator, self.store, err, "create");
                return renderGoal(allocator, "Goal created", self.store.find().?, self.store);
            },
            .edit => |objective| {
                const snapshot = current orelse return missingGoal(allocator, "edit");
                if (snapshot.phase == .complete) {
                    _ = self.store.create(objective, null) catch |err| return storeError(allocator, self.store, err, "create");
                    return renderGoal(allocator, "Goal created", self.store.find().?, self.store);
                }
                _ = self.store.edit(refOf(snapshot), objective, null) catch |err|
                    return storeError(allocator, self.store, err, "edit");
                return renderGoal(allocator, "Goal updated", self.store.find().?, self.store);
            },
            .pause => {
                const snapshot = current orelse return missingGoal(allocator, "pause");
                _ = self.store.pause(refOf(snapshot)) catch |err| return storeError(allocator, self.store, err, "pause");
                return renderGoal(allocator, "Goal paused", self.store.find().?, self.store);
            },
            .@"resume" => {
                const snapshot = current orelse return missingGoal(allocator, "resume");
                _ = self.store.@"resume"(refOf(snapshot)) catch |err| return storeError(allocator, self.store, err, "resume");
                return renderGoal(allocator, "Goal resumed", self.store.find().?, self.store);
            },
            .clear => {
                const snapshot = current orelse return .{ .kind = .success, .text = "No goal to clear." };
                _ = self.store.clear(refOf(snapshot)) catch |err| return storeError(allocator, self.store, err, "clear");
                return .{ .kind = .success, .text = "Goal cleared." };
            },
        }
    }

    /// `commands.zig` seam: execute without owning the lifecycle. The
    /// domain's durable mutations are returned as events for the caller to
    /// append between its own `command/run` and `command/done`.
    pub fn executeCaptured(self: *Goal, allocator: Allocator, raw_input: []const u8) !Outcome {
        var events: std.ArrayListUnmanaged(types.Event) = .empty;
        self.store.capture = .{ .allocator = allocator, .events = &events };
        defer self.store.capture = null;
        const result = try self.execute(allocator, raw_input);
        return .{ .result = result, .events = try events.toOwnedSlice(allocator) };
    }
};

fn runHandler(context: ?*anyopaque, allocator: Allocator, raw_input: []const u8) anyerror!Result {
    const self: *Goal = @ptrCast(@alignCast(context.?));
    return self.dispatch(allocator, raw_input);
}

const Parsed = union(enum) {
    show,
    invalid_edit,
    create: []const u8,
    edit: []const u8,
    pause,
    @"resume",
    clear,
};

/// Parse only the grammar `/goal` owns; arbitrary other input is an objective.
fn parse(raw_input: []const u8) Parsed {
    const input = std.mem.trim(u8, raw_input, " \t\r\n");
    if (input.len == 0) return .show;
    if (eqlIgnoreCase(input, "clear")) return .clear;
    if (eqlIgnoreCase(input, "pause")) return .pause;
    if (eqlIgnoreCase(input, "resume")) return .@"resume";
    if (eqlIgnoreCase(input, "edit")) return .invalid_edit;
    if (input.len > 4 and eqlIgnoreCase(input[0..4], "edit") and std.ascii.isWhitespace(input[4])) {
        return .{ .edit = std.mem.trim(u8, input[4..], " \t\r\n") };
    }
    return .{ .create = input };
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn refOf(snapshot: goal.Snapshot) goal.Ref {
    return .{ .id = snapshot.id, .revision = snapshot.revision };
}

fn renderGoal(allocator: Allocator, title: []const u8, snapshot: goal.Snapshot, store: *goal.Store) !Result {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    const w = &writer.writer;
    try w.print("{s}\nStatus: {s}\n", .{ title, goal.phaseName(snapshot.phase) });
    if (snapshot.blocked_reason) |reason| {
        try w.print("Blocker: {s}: {s}\n", .{ reason.code, reason.message });
    }
    try w.print("Objective: {s}\nRounds: {d}/{d}\nActivation: {s}\n\nCommands: {s}", .{
        snapshot.objective,
        store.rounds_started,
        snapshot.max_goal_rounds,
        goal.activationName(store.activation),
        commandHint(snapshot, store.activation),
    });
    return .{ .kind = .success, .text = try writer.toOwnedSlice() };
}

fn commandHint(snapshot: goal.Snapshot, activation: goal.Activation) []const u8 {
    if (snapshot.phase == .active) {
        return if (activation == .armed)
            "/goal edit <objective>, /goal pause, /goal clear"
        else
            "/goal edit <objective>, /goal resume, /goal clear";
    }
    return switch (snapshot.phase) {
        .paused, .blocked => "/goal edit <objective>, /goal resume, /goal clear",
        .complete => "/goal <objective>, /goal clear",
        .active => unreachable,
    };
}

fn missingGoal(allocator: Allocator, action: []const u8) !Result {
    return errorResult(allocator, "No goal is currently set; /goal {s} requires one. {s}", .{ action, usage });
}

fn storeError(allocator: Allocator, store: *goal.Store, err: anyerror, action: []const u8) !Result {
    const message = try goal.describeError(store, allocator, err, action, null);
    return .{ .kind = .failure, .text = message };
}

fn errorResult(allocator: Allocator, comptime format: []const u8, args: anytype) !Result {
    return .{ .kind = .failure, .text = try std.fmt.allocPrint(allocator, format, args) };
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

fn eventTypes(allocator: Allocator, path: []const u8) ![][]const u8 {
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();
    const names = try allocator.alloc([]const u8, read.events.len);
    for (read.events, 0..) |event, index| names[index] = try allocator.dupe(u8, event.event_type);
    return names;
}

test "goal command writes command/run, goal/change, command/done in order" {
    var session = try TestSession.init(testing.allocator);
    defer session.deinit(testing.allocator);
    var store = goal.Store.init(testing.allocator);
    defer store.deinit();
    store.attachLog(&session.log);
    var command = Goal{ .store = &store };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try command.dispatch(arena.allocator(), " build the release");
    try testing.expectEqual(Kind.success, result.kind);
    try testing.expect(std.mem.indexOf(u8, result.text, "Goal created") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "Status: active") != null);

    const types_seen = try eventTypes(testing.allocator, session.path);
    defer {
        for (types_seen) |name| testing.allocator.free(name);
        testing.allocator.free(types_seen);
    }
    try testing.expectEqual(@as(usize, 3), types_seen.len);
    try testing.expectEqualStrings("command/run", types_seen[0]);
    try testing.expectEqualStrings("goal/change", types_seen[1]);
    try testing.expectEqualStrings("command/done", types_seen[2]);
}

test "goal command event payloads carry args, outcome, and goal ref" {
    var session = try TestSession.init(testing.allocator);
    defer session.deinit(testing.allocator);
    var store = goal.Store.init(testing.allocator);
    defer store.deinit();
    store.attachLog(&session.log);
    var command = Goal{ .store = &store };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try command.dispatch(arena.allocator(), " example objective");
    var read = try session_log.readLog(testing.allocator, session.path);
    defer read.deinit();
    const run_event = read.events[0].data.object;
    try testing.expectEqualStrings("goal", run_event.get("name").?.string);
    try testing.expectEqualStrings(" example objective", run_event.get("args").?.string);
    try testing.expectEqualStrings("user", run_event.get("source").?.object.get("kind").?.string);
    const change = read.events[1].data.object;
    try testing.expectEqualStrings("goal/change", change.get("kind").?.string);
    try testing.expectEqualStrings("create", change.get("operation").?.string);
    try testing.expectEqualStrings("example objective", change.get("goal").?.object.get("objective").?.string);
    const done = read.events[2].data.object;
    try testing.expectEqualStrings("success", done.get("kind").?.string);
    try testing.expectEqualStrings(run_event.get("commandId").?.string, done.get("commandId").?.string);
}

test "goal command shows, edits, pauses, resumes, and clears" {
    var session = try TestSession.init(testing.allocator);
    defer session.deinit(testing.allocator);
    var store = goal.Store.init(testing.allocator);
    defer store.deinit();
    store.attachLog(&session.log);
    var command = Goal{ .store = &store };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const empty_show = try command.execute(a, "");
    try testing.expectEqual(Kind.success, empty_show.kind);
    try testing.expect(std.mem.indexOf(u8, empty_show.text, "No goal is currently set.") != null);

    _ = try command.execute(a, " first objective");
    const edited = try command.execute(a, " edit second objective");
    try testing.expectEqual(Kind.success, edited.kind);
    try testing.expect(std.mem.indexOf(u8, edited.text, "Goal updated") != null);
    try testing.expect(std.mem.indexOf(u8, edited.text, "Objective: second objective") != null);

    const paused = try command.execute(a, " pause");
    try testing.expect(std.mem.indexOf(u8, paused.text, "Goal paused") != null);
    const resumed = try command.execute(a, " resume");
    try testing.expect(std.mem.indexOf(u8, resumed.text, "Goal resumed") != null);

    const shown = try command.execute(a, " ");
    try testing.expect(std.mem.indexOf(u8, shown.text, "Status: active") != null);
    try testing.expect(std.mem.indexOf(u8, shown.text, "Activation: armed") != null);

    const cleared = try command.execute(a, " clear");
    try testing.expectEqual(Kind.success, cleared.kind);
    try testing.expectEqualStrings("Goal cleared.", cleared.text);
    try testing.expect(store.find() == null);
    const cleared_again = try command.execute(a, " clear");
    try testing.expectEqualStrings("No goal to clear.", cleared_again.text);
}

test "goal command reports grammar and state errors" {
    var session = try TestSession.init(testing.allocator);
    defer session.deinit(testing.allocator);
    var store = goal.Store.init(testing.allocator);
    defer store.deinit();
    store.attachLog(&session.log);
    var command = Goal{ .store = &store };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const invalid_edit = try command.execute(a, "edit");
    try testing.expectEqual(Kind.failure, invalid_edit.kind);
    try testing.expect(std.mem.indexOf(u8, invalid_edit.text, "requires a replacement objective") != null);

    const missing_pause = try command.execute(a, "pause");
    try testing.expectEqual(Kind.failure, missing_pause.kind);
    try testing.expect(std.mem.indexOf(u8, missing_pause.text, "No goal is currently set; /goal pause requires one.") != null);

    _ = try command.execute(a, " long objective");
    const duplicate = try command.execute(a, " another objective");
    try testing.expectEqual(Kind.failure, duplicate.kind);
    try testing.expect(std.mem.indexOf(u8, duplicate.text, "A goal is already active.") != null);

    // command/done pairs an error outcome with the failing command.
    const result = try command.dispatch(a, "edit");
    try testing.expectEqual(Kind.failure, result.kind);
    var read = try session_log.readLog(testing.allocator, session.path);
    defer read.deinit();
    var last_done: ?std.json.ObjectMap = null;
    for (read.events) |event| {
        if (std.mem.eql(u8, event.event_type, "command/done")) last_done = event.data.object;
    }
    try testing.expectEqualStrings("error", last_done.?.get("kind").?.string);
}

test "goal command creates a replacement after completion" {
    var session = try TestSession.init(testing.allocator);
    defer session.deinit(testing.allocator);
    var store = goal.Store.init(testing.allocator);
    defer store.deinit();
    store.attachLog(&session.log);
    var command = Goal{ .store = &store };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try command.execute(a, " first");
    const snapshot = store.find().?;
    _ = try store.complete(.{ .id = snapshot.id, .revision = snapshot.revision });
    const replaced = try command.execute(a, " edit replacement");
    try testing.expectEqual(Kind.success, replaced.kind);
    try testing.expect(std.mem.indexOf(u8, replaced.text, "Goal created") != null);
    try testing.expect(std.mem.indexOf(u8, replaced.text, "Objective: replacement") != null);
    try testing.expectEqualStrings("goal-2", store.find().?.id);
}

test "goal command registers once and resolves by exact name" {
    var session = try TestSession.init(testing.allocator);
    defer session.deinit(testing.allocator);
    var store = goal.Store.init(testing.allocator);
    defer store.deinit();
    store.attachLog(&session.log);
    var command = Goal{ .store = &store };
    var commands: std.ArrayListUnmanaged(Command) = .empty;
    defer commands.deinit(testing.allocator);
    try register(&commands, testing.allocator, command.command());
    try testing.expectError(error.DuplicateCommand, register(&commands, testing.allocator, command.command()));
    const found = find(commands.items, "goal").?;
    try testing.expectEqualStrings("goal", found.name);
    try testing.expect(find(commands.items, "compact") == null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try run(found, arena.allocator(), " objective");
    try testing.expectEqual(Kind.success, result.kind);
}
