//! Slash-command registry and the builtins (design §1.9 B36-B37).
//!
//! Mirrors dsh 0.2.1-rc.2:
//! - `packages/interaction/commands/src/index.ts:125-132` (`parseCommand`),
//!   `:360-431` (`command/run` before the handler, `command/done` after it);
//! - `packages/interaction/commands/src/types.ts:93-118` (payloads: `args` is
//!   the verbatim `rawInput`, absent for `recordInput:false`);
//! - `packages/compaction/command-compact/src/index.ts:58-110`;
//! - `packages/interaction/permission-presets/src/index.ts:125-145,256-273`
//!   (differential knob writes; snapshot `web/permission-policy-context`);
//! - `packages/feedback/command-feedback/src/index.ts:48-121`;
//! - `packages/session-query/session-log-export/src/index.ts:68-90`;
//! - `packages/plan/plan-mode/src/index.ts:230-275` (`/plan`).
//!
//! Pure module: it owns no log. `handleLocalCommand` returns the ordered
//! events (`command/run`, domain events, `command/done`) with `seq`/`time_ms`
//! left at zero for the caller to stamp while appending, plus the settlement
//! text. `null` means the line belongs to the host: unknown names and host
//! commands are never claimed. `/goal` is claimed through the wired goal seam;
//! its `goal/change` events come from the goal domain and its lifecycle
//! payloads are `recordInput:false`, so neither event carries `args`. `/plan`
//! carries the user's verbatim args, returns its selection decision so the
//! harness can queue a pre-step commit (`plan.zig`), and returns the trimmed
//! non-`off` input for the harness to steer as a user message.
//!
//! `/compact` delegates the transaction to an injected seam; the harness plugs
//! in `compaction.zig`. When the seam reports no useful range, the command
//! settles `No compactable history yet.` with no domain events, so no fake
//! summary is written. The seam's events must be the four-event transaction
//! (`compaction/start`, `compaction/summary`, replacement `user/message`,
//! `compaction/end`); the summary event is located by index so the settlement
//! can carry its future `sourceEventSeq`.

const std = @import("std");
const generated = @import("generated/interaction.zig");
const plan = @import("plan.zig");
const types = @import("types.zig");
const context = @import("context.zig");

const Allocator = std.mem.Allocator;

pub const SandboxMode = context.SandboxMode;
pub const ApprovalPolicy = context.ApprovalPolicy;

/// Command-line whitespace (`parseCommand` regex boundary + JS trim subset).
const whitespace = " \t\n\r";

// ── registry ────────────────────────────────────────────────────────────────

/// Metadata dsh calls a `CommandDefinition` (`commands/src/types.ts:63-76`).
pub const Definition = struct {
    name: []const u8,
    description: []const u8,
    input_hint: ?[]const u8 = null,
    /// Whether `command/run` records `args`. Defaults to true; a command whose
    /// domain event owns the payload sets this false.
    record_input: bool = true,
};

pub const builtins = [_]Definition{
    .{ .name = "compact", .description = "Compact older conversation history" },
    .{
        .name = "permission",
        .description = "Switch the permission preset (sandbox mode + approval policy)",
        .input_hint = "<preset>",
    },
    .{
        .name = "feedback",
        .description = "Record feedback about this session",
        .input_hint = "<text>",
        .record_input = false,
    },
    .{ .name = "export", .description = "Export this Session log" },
    .{
        .name = "goal",
        .description = "Set or view the goal for a long-running task",
        .input_hint = "[<objective>|clear|edit <objective>|pause|resume]",
        .record_input = false,
    },
    .{
        .name = generated.plan_mode.command_name,
        .description = generated.plan_mode.command_description,
        .input_hint = generated.plan_mode.command_hint,
    },
};

pub fn findDefinition(name: []const u8) ?Definition {
    for (builtins) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return definition;
    }
    return null;
}

pub const Parsed = struct {
    name: []const u8,
    /// Text after the name verbatim, separator whitespace included.
    raw_input: []const u8,
};

/// `^\/([a-z][a-z0-9_-]*)(?=$|[\t\n\r ])` (`commands/src/index.ts:125-132`).
pub fn parseCommand(line: []const u8) ?Parsed {
    if (line.len == 0 or line[0] != '/') return null;
    var i: usize = 1;
    if (i == line.len or !isNameStart(line[i])) return null;
    i += 1;
    while (i < line.len and isNameChar(line[i])) : (i += 1) {}
    if (i < line.len) {
        const boundary = line[i];
        if (boundary != '\t' and boundary != '\n' and boundary != '\r' and boundary != ' ') return null;
    }
    return .{ .name = line[1..i], .raw_input = line[i..] };
}

fn isNameStart(byte: u8) bool {
    return byte >= 'a' and byte <= 'z';
}

fn isNameChar(byte: u8) bool {
    return isNameStart(byte) or (byte >= '0' and byte <= '9') or byte == '_' or byte == '-';
}

// ── permission presets ──────────────────────────────────────────────────────

pub const Preset = struct {
    name: []const u8,
    sandbox: SandboxMode,
    approval: ApprovalPolicy,
};

/// The design's three presets (B37). dsh's default table only contains the
/// latter two; read-only is added here as the design requires.
pub const presets = [_]Preset{
    .{ .name = "read-only", .sandbox = .read_only, .approval = .ask },
    .{ .name = "workspace-write", .sandbox = .workspace_write, .approval = .ask },
    .{ .name = "danger-full-access", .sandbox = .danger_full_access, .approval = .never },
};

const available_names = blk: {
    var names: []const u8 = "";
    for (presets, 0..) |preset, index| {
        names = names ++ (if (index == 0) "" else ", ") ++ preset.name;
    }
    break :blk names;
};

pub fn findPreset(name: []const u8) ?Preset {
    for (presets) |preset| {
        if (std.mem.eql(u8, preset.name, name)) return preset;
    }
    return null;
}

/// Folded `permission/preset` + `sandbox/mode` + `approval/policy` state.
/// String slices borrow the log events; they are only read during execution.
pub const PermissionState = struct {
    preset: ?[]const u8 = null,
    sandbox: ?SandboxMode = null,
    approval: ?ApprovalPolicy = null,

    /// Last whole-value write of each knob wins (`permission-presets/src/index.ts:133-146`).
    pub fn fold(events: []const types.Event) PermissionState {
        var state = PermissionState{};
        for (events) |event| {
            const object = switch (event.data) {
                .object => |object| object,
                else => continue,
            };
            if (std.mem.eql(u8, event.event_type, "permission/preset")) {
                if (jsonString(object, "preset")) |preset| state.preset = preset;
            } else if (std.mem.eql(u8, event.event_type, "sandbox/mode")) {
                if (jsonString(object, "mode")) |mode| state.sandbox = sandboxFromName(mode) orelse state.sandbox;
            } else if (std.mem.eql(u8, event.event_type, "approval/policy")) {
                if (jsonString(object, "policy")) |policy| state.approval = approvalFromName(policy) orelse state.approval;
            }
        }
        return state;
    }
};

/// Composition defaults for knobs with no override (`ctx.shell.sandboxMode`,
/// `ctx.approval.config.policy`). The web composition defaults to
/// workspace-write/ask.
pub const PermissionDefaults = struct {
    sandbox: SandboxMode = .workspace_write,
    approval: ApprovalPolicy = .ask,
};

fn currentPreset(state: PermissionState, defaults: PermissionDefaults) []const u8 {
    if (state.preset) |preset| return preset;
    const sandbox = state.sandbox orelse defaults.sandbox;
    const approval = state.approval orelse defaults.approval;
    for (presets) |preset| {
        if (preset.sandbox == sandbox and preset.approval == approval) return preset.name;
    }
    return "custom";
}

fn sandboxName(mode: SandboxMode) []const u8 {
    return switch (mode) {
        .read_only => "read-only",
        .workspace_write => "workspace-write",
        .danger_full_access => "danger-full-access",
    };
}

fn sandboxFromName(name: []const u8) ?SandboxMode {
    for ([_]SandboxMode{ .read_only, .workspace_write, .danger_full_access }) |mode| {
        if (std.mem.eql(u8, sandboxName(mode), name)) return mode;
    }
    return null;
}

fn approvalName(policy: ApprovalPolicy) []const u8 {
    return switch (policy) {
        .ask => "ask",
        .never => "never",
    };
}

fn approvalFromName(name: []const u8) ?ApprovalPolicy {
    for ([_]ApprovalPolicy{ .ask, .never }) |policy| {
        if (std.mem.eql(u8, approvalName(policy), name)) return policy;
    }
    return null;
}

// ── compaction seam ─────────────────────────────────────────────────────────

pub const CompactRequest = struct {
    /// Pairing id of the `command/run` already in the log.
    command_id: []const u8,
    /// Seq the caller assigns to `command/run`, so the seam can record the
    /// start/summary seqs in the checkpoint's `sourceEventSeqs`.
    next_seq: ?u64 = null,
};

pub const Compacted = struct {
    /// Domain events in log order: compaction/start, compaction/summary, the
    /// replacement user/message, compaction/end. Allocated with the allocator
    /// passed to the seam.
    events: []const types.Event,
    shadowed_item_count: u64,
    shadowed_token_count: u64,
    /// Index in `events` of the `compaction/summary` event.
    summary_event_index: usize,
};

/// Expected manual-compaction failures (`ManualCompactionErrorCode`).
pub const CompactFailure = enum { busy, cancelled, changed, summary, commit, persistence };

/// A failure plus the failed transaction already written for it. `events` is
/// the `compaction/start` + `compaction/end{error}` pair when summarization
/// began; it is empty when nothing was recorded (`busy`).
pub const CompactFailureOutcome = struct {
    failure: CompactFailure,
    events: []const types.Event = &.{},
};

pub const CompactOutcome = union(enum) {
    /// No safe useful range exists; append nothing.
    no_history,
    compacted: Compacted,
    failed: CompactFailureOutcome,
};

pub const Compaction = struct {
    context: ?*anyopaque = null,
    call: ?*const fn (?*anyopaque, Allocator, CompactRequest) anyerror!CompactOutcome = null,
};

// ── goal seam ───────────────────────────────────────────────────────────────

/// The goal domain's settlement plus the `goal/change` events it recorded, in
/// order. An empty list is normal (`/goal` show, a no-op clear, a failure).
pub const GoalOutcome = struct {
    kind: Kind,
    text: []const u8,
    events: []const types.Event = &.{},
};

pub const Goal = struct {
    context: ?*anyopaque = null,
    call: ?*const fn (?*anyopaque, Allocator, []const u8) anyerror!GoalOutcome = null,
};

// ── execution ───────────────────────────────────────────────────────────────

pub const Kind = enum { success, @"error" };

pub const Context = struct {
    /// Pairing id shared by `command/run` and `command/done`; unique per call.
    command_id: []const u8,
    /// Seq the caller assigns to the first returned event. When present,
    /// `/compact` fills `command/done.sourceEventSeq` from the summary index.
    next_seq: ?u64 = null,
    session_id: []const u8 = "",
    /// Stable anonymous user id shown in the feedback acknowledgement; the
    /// line is omitted when empty (junclaw has no anonymous-id store).
    anonymous_user_id: []const u8 = "",
    permissions: PermissionState = .{},
    permission_defaults: PermissionDefaults = .{},
    compaction: Compaction = .{},
    goal: Goal = .{},
    /// Logged plan mode plus any queued selection (`plan.zig`).
    plan: plan.View = .{},
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    /// command/run -> domain events -> command/done, with `seq`/`time_ms` 0.
    events: []const types.Event,
    kind: Kind,
    /// Settlement text returned to the dispatching surface (`command/done.text`).
    text: []const u8,
    /// `/plan` selection for the harness to apply to its plan state. An
    /// immediate `plan/mode` event is already in `events`; a queued target
    /// carries `queue`.
    plan_decision: ?plan.Decision = null,
    /// `/plan <message>` input the harness steers into the session as a user
    /// message (dsh `agent.steer`).
    steer: ?[]const u8 = null,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Claim and execute one builtin. Returns null when the line is not a builtin
/// command line (unknown name or a non-command line), so the harness can fall
/// back to the host's own slash commands.
pub fn handleLocalCommand(allocator: Allocator, line: []const u8, ctx: Context) !?Result {
    const parsed = parseCommand(line) orelse return null;
    const definition = findDefinition(parsed.name) orelse return null;
    if (ctx.command_id.len == 0) return error.InvalidCommandId;
    return try assemble(allocator, ctx, definition, parsed);
}

const Settlement = struct {
    kind: Kind,
    text: []const u8,
    source_event_seq: ?u64 = null,
    domain: []const types.Event = &.{},
    plan: ?plan.Decision = null,
    steer: ?[]const u8 = null,
};

fn assemble(allocator: Allocator, ctx: Context, definition: Definition, parsed: Parsed) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const settlement = try execute(a, ctx, definition, parsed);
    var events: std.ArrayListUnmanaged(types.Event) = .empty;
    try events.append(a, try runEvent(a, ctx, definition, parsed.raw_input));
    try events.appendSlice(a, settlement.domain);
    try events.append(a, try doneEvent(a, ctx.command_id, settlement));
    const list = try events.toOwnedSlice(a);
    try assertLifecycle(list);

    return .{
        .arena = arena,
        .events = list,
        .kind = settlement.kind,
        .text = settlement.text,
        .plan_decision = settlement.plan,
        .steer = settlement.steer,
    };
}

fn execute(allocator: Allocator, ctx: Context, definition: Definition, parsed: Parsed) !Settlement {
    if (std.mem.eql(u8, definition.name, "compact")) return executeCompact(allocator, ctx, parsed.raw_input);
    if (std.mem.eql(u8, definition.name, "permission")) return executePermission(allocator, ctx, parsed.raw_input);
    if (std.mem.eql(u8, definition.name, "feedback")) return executeFeedback(allocator, ctx, parsed.raw_input);
    if (std.mem.eql(u8, definition.name, "goal")) return executeGoal(allocator, ctx, parsed.raw_input);
    if (std.mem.eql(u8, definition.name, generated.plan_mode.command_name))
        return executePlan(allocator, ctx, parsed.raw_input);
    return executeExport(parsed.raw_input);
}

fn executeGoal(allocator: Allocator, ctx: Context, raw_input: []const u8) !Settlement {
    const call = ctx.goal.call orelse
        return .{ .kind = .@"error", .text = "The /goal command is unavailable." };
    const outcome = call(ctx.goal.context, allocator, raw_input) catch |err| {
        // Same settlement `Goal.dispatch` writes for a failed invocation.
        const text = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
        return .{ .kind = .@"error", .text = text };
    };
    return .{ .kind = outcome.kind, .text = outcome.text, .domain = outcome.events };
}

/// `/plan [off|message]`: dsh treats only the exact word `off` as an exit;
/// every other input (including `on` and a bare `/plan`) selects plan mode and
/// steers the trimmed input into the session as a user message.
fn executePlan(allocator: Allocator, ctx: Context, raw_input: []const u8) !Settlement {
    const text = generated.plan_mode;
    const message = std.mem.trim(u8, raw_input, whitespace);
    const target = !std.mem.eql(u8, message, "off");
    const decision = plan.decide(ctx.plan, target);
    const settlement = if (target) switch (decision.outcome) {
        .committed, .cancelled => text.on_committed,
        .queued => text.on_queued,
        .noop => if (ctx.plan.active) text.on_committed else text.on_queued,
    } else switch (decision.outcome) {
        .committed => text.off_committed,
        .queued => text.off_queued,
        .cancelled => text.off_cancelled,
        .noop => if (ctx.plan.active) text.off_queued else text.off_already_inactive,
    };

    var domain: []const types.Event = &.{};
    if (decision.emit) |active| {
        const events = try allocator.alloc(types.Event, 1);
        events[0] = try boolEvent(allocator, "plan/mode", "active", active);
        domain = events;
    }
    return .{
        .kind = .success,
        .text = settlement,
        .domain = domain,
        .plan = decision,
        .steer = if (target and message.len != 0) try allocator.dupe(u8, message) else null,
    };
}

fn executeCompact(allocator: Allocator, ctx: Context, raw_input: []const u8) !Settlement {
    if (std.mem.trim(u8, raw_input, whitespace).len != 0) {
        return .{ .kind = .@"error", .text = "Usage: /compact (no arguments)" };
    }
    const call = ctx.compaction.call orelse
        return .{ .kind = .@"error", .text = "Compaction is unavailable." };

    const outcome = call(ctx.compaction.context, allocator, .{
        .command_id = ctx.command_id,
        .next_seq = ctx.next_seq,
    }) catch |err| {
        const text = try std.fmt.allocPrint(allocator, "Compaction failed: {s}.", .{@errorName(err)});
        return .{ .kind = .@"error", .text = text };
    };

    return switch (outcome) {
        .no_history => .{ .kind = .success, .text = "No compactable history yet." },
        .failed => |failure| .{
            .kind = .@"error",
            .text = failureText(failure.failure, failure.events.len != 0),
            .domain = failure.events,
        },
        .compacted => |compacted| {
            if (compacted.events.len == 0 or compacted.summary_event_index >= compacted.events.len or
                !std.mem.eql(u8, compacted.events[compacted.summary_event_index].event_type, "compaction/summary"))
            {
                return .{ .kind = .@"error", .text = "Compaction failed: malformed compaction transaction." };
            }
            const text = try std.fmt.allocPrint(
                allocator,
                "Compacted {d} history items (~{d} tokens).",
                .{ compacted.shadowed_item_count, compacted.shadowed_token_count },
            );
            const source_event_seq = if (ctx.next_seq) |first|
                first + 1 + @as(u64, @intCast(compacted.summary_event_index))
            else
                null;
            return .{
                .kind = .success,
                .text = text,
                .source_event_seq = source_event_seq,
                .domain = compacted.events,
            };
        },
    };
}

fn failureText(failure: CompactFailure, recorded: bool) []const u8 {
    return switch (failure) {
        .busy => "Compaction is unavailable because this process has an active compaction, or the agent is not idle.",
        .cancelled => "Compaction cancelled.",
        .changed => if (recorded)
            "The history selected for compaction changed before it could be replaced. The attempt is recorded in the session log."
        else
            "The history selected for compaction changed before it could be replaced.",
        .summary => if (recorded)
            "Compaction could not produce a useful summary. The attempt is recorded in the session log."
        else
            "Compaction could not produce a useful summary.",
        .commit => "Compaction did not finish cleanly; some session history may have changed. Inspect the current session state before retrying.",
        .persistence => "Compaction finished, but the session could not be saved.",
    };
}

fn executePermission(allocator: Allocator, ctx: Context, raw_input: []const u8) !Settlement {
    const name = std.mem.trim(u8, raw_input, whitespace);
    if (name.len == 0) {
        const text = try std.fmt.allocPrint(
            allocator,
            "current preset {s} (available: {s})",
            .{ currentPreset(ctx.permissions, ctx.permission_defaults), available_names },
        );
        return .{ .kind = .success, .text = text };
    }
    const preset = findPreset(name) orelse {
        const text = try std.fmt.allocPrint(
            allocator,
            "unknown preset \"{s}\" (available: {s})",
            .{ name, available_names },
        );
        return .{ .kind = .@"error", .text = text };
    };

    var domain: std.ArrayListUnmanaged(types.Event) = .empty;
    if (!std.mem.eql(u8, currentPreset(ctx.permissions, ctx.permission_defaults), preset.name)) {
        try domain.append(allocator, try fieldEvent(allocator, "permission/preset", "preset", preset.name));
    }
    const sandbox = ctx.permissions.sandbox orelse ctx.permission_defaults.sandbox;
    if (sandbox != preset.sandbox) {
        try domain.append(allocator, try fieldEvent(allocator, "sandbox/mode", "mode", sandboxName(preset.sandbox)));
    }
    const approval = ctx.permissions.approval orelse ctx.permission_defaults.approval;
    if (approval != preset.approval) {
        try domain.append(allocator, try fieldEvent(allocator, "approval/policy", "policy", approvalName(preset.approval)));
    }
    const text = try std.fmt.allocPrint(allocator, "preset {s}", .{preset.name});
    return .{
        .kind = .success,
        .text = text,
        .domain = try domain.toOwnedSlice(allocator),
    };
}

fn executeFeedback(allocator: Allocator, ctx: Context, raw_input: []const u8) !Settlement {
    const text = std.mem.trim(u8, raw_input, whitespace);
    if (text.len == 0) {
        return .{ .kind = .@"error", .text = "Feedback text is required. Usage: /feedback <text>" };
    }
    const reply = if (ctx.anonymous_user_id.len == 0)
        try std.fmt.allocPrint(allocator, "Feedback recorded for session {s}.", .{ctx.session_id})
    else
        try std.fmt.allocPrint(
            allocator,
            "Feedback recorded for session {s}\nAnonymous user: {s}.",
            .{ ctx.session_id, ctx.anonymous_user_id },
        );
    const event = try fieldEvent(allocator, "feedback/record", "text", text);
    const domain = try allocator.alloc(types.Event, 1);
    domain[0] = event;
    return .{ .kind = .success, .text = reply, .domain = domain };
}

fn executeExport(raw_input: []const u8) Settlement {
    if (std.mem.trim(u8, raw_input, whitespace).len != 0) {
        return .{ .kind = .@"error", .text = "The Web /export command does not accept a path." };
    }
    // dsh's Web host serves the ZIP itself; junclaw has no download route, so
    // do not claim one was requested.
    return .{ .kind = .@"error", .text = "Session log export is not available in this client." };
}

fn runEvent(allocator: Allocator, ctx: Context, definition: Definition, raw_input: []const u8) !types.Event {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "commandId", .{ .string = try allocator.dupe(u8, ctx.command_id) });
    try object.put(allocator, "name", .{ .string = definition.name });
    if (definition.record_input) {
        try object.put(allocator, "args", .{ .string = try allocator.dupe(u8, raw_input) });
    }
    var source: std.json.ObjectMap = .empty;
    try source.put(allocator, "kind", .{ .string = "user" });
    try object.put(allocator, "source", .{ .object = source });
    return .{ .event_type = "command/run", .seq = 0, .time_ms = 0, .data = .{ .object = object } };
}

fn doneEvent(allocator: Allocator, command_id: []const u8, settlement: Settlement) !types.Event {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "commandId", .{ .string = try allocator.dupe(u8, command_id) });
    try object.put(allocator, "kind", .{ .string = kindName(settlement.kind) });
    try object.put(allocator, "text", .{ .string = settlement.text });
    if (settlement.kind == .success) {
        if (settlement.source_event_seq) |seq| {
            const value = std.math.cast(i64, seq) orelse return error.SequenceOutOfRange;
            try object.put(allocator, "sourceEventSeq", .{ .integer = value });
        }
    }
    return .{ .event_type = "command/done", .seq = 0, .time_ms = 0, .data = .{ .object = object } };
}

fn kindName(kind: Kind) []const u8 {
    return switch (kind) {
        .success => "success",
        .@"error" => "error",
    };
}

/// One event with a single string field: the shape of the permission knobs,
/// `feedback/record`, and the other one-key domain payloads.
fn fieldEvent(allocator: Allocator, event_type: []const u8, key: []const u8, value: []const u8) !types.Event {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, key, .{ .string = try allocator.dupe(u8, value) });
    return .{ .event_type = event_type, .seq = 0, .time_ms = 0, .data = .{ .object = object } };
}

/// One event with a single boolean field (`plan/mode`).
fn boolEvent(allocator: Allocator, event_type: []const u8, key: []const u8, value: bool) !types.Event {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, key, .{ .bool = value });
    return .{ .event_type = event_type, .seq = 0, .time_ms = 0, .data = .{ .object = object } };
}

/// Assert `command/run` and `command/done` are the first and last events, share
/// a commandId, and enclose only domain events (B36 adjacency).
pub fn assertLifecycle(events: []const types.Event) !void {
    if (events.len < 2) return error.CommandEventsNotAdjacent;
    const run = events[0];
    const done = events[events.len - 1];
    if (!std.mem.eql(u8, run.event_type, "command/run")) return error.CommandEventsNotAdjacent;
    if (!std.mem.eql(u8, done.event_type, "command/done")) return error.CommandEventsNotAdjacent;
    const run_id = eventString(run, "commandId") orelse return error.CommandEventsNotAdjacent;
    const done_id = eventString(done, "commandId") orelse return error.CommandEventsNotAdjacent;
    if (!std.mem.eql(u8, run_id, done_id)) return error.CommandEventsNotAdjacent;
    for (events[1 .. events.len - 1]) |event| {
        if (std.mem.eql(u8, event.event_type, "command/run") or
            std.mem.eql(u8, event.event_type, "command/done"))
        {
            return error.CommandEventsNotAdjacent;
        }
    }
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn eventString(event: types.Event, key: []const u8) ?[]const u8 {
    return switch (event.data) {
        .object => |object| jsonString(object, key),
        else => null,
    };
}

fn eventBool(event: types.Event, key: []const u8) ?bool {
    return switch (event.data) {
        .object => |object| switch (object.get(key) orelse return null) {
            .bool => |value| value,
            else => null,
        },
        else => null,
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

fn expectTypes(events: []const types.Event, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, events.len);
    for (expected, 0..) |want, index| {
        try std.testing.expectEqualStrings(want, events[index].event_type);
    }
}

fn stringField(event: types.Event, key: []const u8) []const u8 {
    return eventString(event, key).?;
}

fn claimed(line: []const u8, ctx: Context) !Result {
    return (try handleLocalCommand(std.testing.allocator, line, ctx)) orelse error.NotClaimed;
}

fn expectUnclaimed(line: []const u8) !void {
    if (try handleLocalCommand(std.testing.allocator, line, .{ .command_id = "cmd-1" })) |value| {
        var result = value;
        result.deinit();
        return error.ExpectedUnclaimed;
    }
}

const CompactStub = struct {
    calls: usize = 0,
    seen_command_id: ?[]const u8 = null,
    scenario: enum { history, no_history, failed, failed_recorded, thrown, malformed } = .history,
    failure: CompactFailure = .busy,

    fn seam(self: *CompactStub) Compaction {
        return .{ .context = self, .call = call };
    }

    fn call(context_ptr: ?*anyopaque, allocator: Allocator, request: CompactRequest) anyerror!CompactOutcome {
        const self: *CompactStub = @ptrCast(@alignCast(context_ptr.?));
        self.calls += 1;
        self.seen_command_id = request.command_id;
        return switch (self.scenario) {
            .history => .{ .compacted = try transaction(allocator, 1) },
            .no_history => .no_history,
            .failed => .{ .failed = .{ .failure = self.failure } },
            .failed_recorded => .{ .failed = .{
                .failure = .summary,
                .events = try failureTransaction(allocator),
            } },
            .thrown => error.HostFailure,
            .malformed => .{ .compacted = try transaction(allocator, 9) },
        };
    }
};

fn failureTransaction(allocator: Allocator) ![]const types.Event {
    const event_types = [_][]const u8{ "compaction/start", "compaction/end" };
    const events = try allocator.alloc(types.Event, event_types.len);
    for (events, 0..) |*event, index| {
        event.* = .{
            .event_type = event_types[index],
            .seq = 0,
            .time_ms = 0,
            .data = .{ .integer = @intCast(index) },
        };
    }
    return events;
}

fn transaction(allocator: Allocator, summary_index: usize) !Compacted {
    const event_types = [_][]const u8{
        "compaction/start",
        "compaction/summary",
        "user/message",
        "compaction/end",
    };
    const events = try allocator.alloc(types.Event, event_types.len);
    for (events, 0..) |*event, index| {
        event.* = .{
            .event_type = event_types[index],
            .seq = 0,
            .time_ms = 0,
            .data = .{ .integer = @intCast(index) },
        };
    }
    return .{
        .events = events,
        .shadowed_item_count = 3,
        .shadowed_token_count = 42,
        .summary_event_index = summary_index,
    };
}

test "/compact runs one useful compaction transaction between the lifecycle pair" {
    var stub = CompactStub{};
    var result = try claimed("/compact", .{
        .command_id = "cmd-1",
        .next_seq = 7,
        .compaction = stub.seam(),
    });
    defer result.deinit();

    try expectTypes(result.events, &.{
        "command/run",
        "compaction/start",
        "compaction/summary",
        "user/message",
        "compaction/end",
        "command/done",
    });
    try assertLifecycle(result.events);
    try std.testing.expectEqual(Kind.success, result.kind);
    try std.testing.expectEqualStrings("Compacted 3 history items (~42 tokens).", result.text);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
    try std.testing.expectEqualStrings("cmd-1", stub.seen_command_id.?);
    try std.testing.expectEqualStrings("", stringField(result.events[0], "args"));
    try std.testing.expectEqualStrings("user", jsonString(result.events[0].data.object.get("source").?.object, "kind").?);
    // run = 7, start = 8, summary = 9.
    try std.testing.expectEqual(@as(i64, 9), result.events[5].data.object.get("sourceEventSeq").?.integer);
}

test "/compact reports no compactable history without writing a summary" {
    var stub = CompactStub{ .scenario = .no_history };
    var result = try claimed("/compact", .{ .command_id = "cmd-2", .compaction = stub.seam() });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqualStrings("No compactable history yet.", result.text);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
    try std.testing.expect(result.events[1].data.object.get("sourceEventSeq") == null);
}

test "/compact rejects arguments before calling the seam" {
    var stub = CompactStub{};
    var result = try claimed("/compact now", .{ .command_id = "cmd-3", .compaction = stub.seam() });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try std.testing.expectEqual(Kind.@"error", result.kind);
    try std.testing.expectEqualStrings("Usage: /compact (no arguments)", result.text);
    try std.testing.expectEqual(@as(usize, 0), stub.calls);
    try std.testing.expectEqualStrings(" now", stringField(result.events[0], "args"));
}

test "/compact renders every expected manual-compaction failure" {
    const cases = [_]struct { failure: CompactFailure, text: []const u8 }{
        .{
            .failure = .busy,
            .text = "Compaction is unavailable because this process has an active compaction, or the agent is not idle.",
        },
        .{ .failure = .cancelled, .text = "Compaction cancelled." },
        .{
            .failure = .changed,
            .text = "The history selected for compaction changed before it could be replaced.",
        },
        .{
            .failure = .summary,
            .text = "Compaction could not produce a useful summary.",
        },
        .{
            .failure = .commit,
            .text = "Compaction did not finish cleanly; some session history may have changed. Inspect the current session state before retrying.",
        },
        .{
            .failure = .persistence,
            .text = "Compaction finished, but the session could not be saved.",
        },
    };
    for (cases) |case| {
        var stub = CompactStub{ .scenario = .failed, .failure = case.failure };
        var result = try claimed("/compact", .{ .command_id = "cmd-4", .compaction = stub.seam() });
        defer result.deinit();
        try expectTypes(result.events, &.{ "command/run", "command/done" });
        try assertLifecycle(result.events);
        try std.testing.expectEqual(Kind.@"error", result.kind);
        try std.testing.expectEqualStrings(case.text, result.text);
    }
}

test "/compact settles a recorded failure between the lifecycle pair" {
    var stub = CompactStub{ .scenario = .failed_recorded };
    var result = try claimed("/compact", .{ .command_id = "cmd-4b", .compaction = stub.seam() });
    defer result.deinit();

    try expectTypes(result.events, &.{
        "command/run",
        "compaction/start",
        "compaction/end",
        "command/done",
    });
    try assertLifecycle(result.events);
    try std.testing.expectEqual(Kind.@"error", result.kind);
    try std.testing.expectEqualStrings(failureText(.summary, true), result.text);
}

test "/compact keeps the lifecycle pair when the seam throws" {
    var stub = CompactStub{ .scenario = .thrown };
    var result = try claimed("/compact", .{ .command_id = "cmd-5", .compaction = stub.seam() });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqualStrings("Compaction failed: HostFailure.", result.text);
}

test "/compact refuses a malformed compaction transaction" {
    var stub = CompactStub{ .scenario = .malformed };
    var result = try claimed("/compact", .{ .command_id = "cmd-6", .compaction = stub.seam() });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqualStrings("Compaction failed: malformed compaction transaction.", result.text);
}

test "/compact without a seam fails closed but keeps the lifecycle pair" {
    var result = try claimed("/compact", .{ .command_id = "cmd-7" });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqualStrings("Compaction is unavailable.", result.text);
}

test "/permission danger-full-access writes the preset and both changed knobs" {
    var result = try claimed("/permission danger-full-access", .{ .command_id = "cmd-8" });
    defer result.deinit();

    try expectTypes(result.events, &.{
        "command/run",
        "permission/preset",
        "sandbox/mode",
        "approval/policy",
        "command/done",
    });
    try assertLifecycle(result.events);
    try std.testing.expectEqualStrings("preset danger-full-access", result.text);
    try std.testing.expectEqualStrings(" danger-full-access", stringField(result.events[0], "args"));
    try std.testing.expectEqualStrings("danger-full-access", stringField(result.events[1], "preset"));
    try std.testing.expectEqualStrings("danger-full-access", stringField(result.events[2], "mode"));
    try std.testing.expectEqualStrings("never", stringField(result.events[3], "policy"));
}

test "/permission read-only skips the unchanged approval knob" {
    var result = try claimed("/permission read-only", .{
        .command_id = "cmd-9",
        .permissions = .{ .preset = "workspace-write", .sandbox = .workspace_write, .approval = .ask },
    });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "permission/preset", "sandbox/mode", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqualStrings("read-only", stringField(result.events[1], "preset"));
    try std.testing.expectEqualStrings("read-only", stringField(result.events[2], "mode"));
    try std.testing.expectEqualStrings("preset read-only", result.text);
}

test "/permission re-selecting the effective preset appends no domain events" {
    var result = try claimed("/permission workspace-write", .{
        .command_id = "cmd-10",
        .permissions = .{ .preset = "workspace-write", .sandbox = .workspace_write, .approval = .ask },
    });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqualStrings("preset workspace-write", result.text);
}

test "/permission with no argument reports the current or custom preset" {
    {
        var result = try claimed("/permission", .{ .command_id = "cmd-11" });
        defer result.deinit();
        try expectTypes(result.events, &.{ "command/run", "command/done" });
        try std.testing.expectEqualStrings(
            "current preset workspace-write (available: read-only, workspace-write, danger-full-access)",
            result.text,
        );
        try std.testing.expectEqualStrings("", stringField(result.events[0], "args"));
    }
    {
        var result = try claimed("/permission", .{
            .command_id = "cmd-12",
            .permissions = .{ .sandbox = .danger_full_access, .approval = .ask },
        });
        defer result.deinit();
        try std.testing.expectEqualStrings(
            "current preset custom (available: read-only, workspace-write, danger-full-access)",
            result.text,
        );
    }
}

test "/permission rejects an unknown preset without domain events" {
    var result = try claimed("/permission chaos", .{ .command_id = "cmd-13" });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqual(Kind.@"error", result.kind);
    try std.testing.expectEqualStrings(
        "unknown preset \"chaos\" (available: read-only, workspace-write, danger-full-access)",
        result.text,
    );
}

test "permission state folds the last whole-value writes of all three knobs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const events = [_]types.Event{
        try fieldEvent(a, "permission/preset", "preset", "read-only"),
        try fieldEvent(a, "sandbox/mode", "mode", "read-only"),
        try fieldEvent(a, "approval/policy", "policy", "ask"),
        try fieldEvent(a, "sandbox/mode", "mode", "danger-full-access"),
        .{ .event_type = "user/message", .seq = 0, .time_ms = 0, .data = .{ .integer = 1 } },
    };

    const state = PermissionState.fold(&events);
    try std.testing.expectEqualStrings("read-only", state.preset.?);
    try std.testing.expectEqual(SandboxMode.danger_full_access, state.sandbox.?);
    try std.testing.expectEqual(ApprovalPolicy.ask, state.approval.?);
}

test "/feedback records trimmed text and omits args from command/run" {
    var result = try claimed("/feedback   the diff view is unreadable  ", .{
        .command_id = "cmd-14",
        .session_id = "session-1",
        .anonymous_user_id = "anon-1",
    });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "feedback/record", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqualStrings("feedback", stringField(result.events[0], "name"));
    try std.testing.expect(result.events[0].data.object.get("args") == null);
    try std.testing.expectEqualStrings("the diff view is unreadable", stringField(result.events[1], "text"));
    try std.testing.expectEqualStrings(
        "Feedback recorded for session session-1\nAnonymous user: anon-1.",
        result.text,
    );
}

test "/feedback without text settles an error and records nothing" {
    var result = try claimed("/feedback  \t ", .{
        .command_id = "cmd-15",
        .session_id = "session-1",
    });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqual(Kind.@"error", result.kind);
    try std.testing.expectEqualStrings("Feedback text is required. Usage: /feedback <text>", result.text);
}

test "/feedback without an anonymous id omits that acknowledgement line" {
    var result = try claimed("/feedback useful", .{
        .command_id = "cmd-16",
        .session_id = "session-2",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Feedback recorded for session session-2.", result.text);
}

test "/export records empty args without promising a download" {
    var result = try claimed("/export", .{ .command_id = "cmd-17" });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqualStrings("", stringField(result.events[0], "args"));
    try std.testing.expectEqual(Kind.@"error", result.kind);
    try std.testing.expectEqualStrings("Session log export is not available in this client.", result.text);
    try std.testing.expectEqualStrings("Export this Session log", findDefinition("export").?.description);
}

test "/export rejects a path without domain events" {
    var result = try claimed("/export /tmp/log.zip", .{ .command_id = "cmd-18" });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqual(Kind.@"error", result.kind);
    try std.testing.expectEqualStrings("The Web /export command does not accept a path.", result.text);
    try std.testing.expectEqualStrings(" /tmp/log.zip", stringField(result.events[0], "args"));
}

test "the registry exposes the P2a builtins, goal and plan" {
    try std.testing.expectEqual(@as(usize, 6), builtins.len);
    for ([_][]const u8{ "compact", "permission", "feedback", "export", "goal", "plan" }) |name| {
        try std.testing.expect(findDefinition(name) != null);
    }
    try std.testing.expect(!findDefinition("feedback").?.record_input);
    try std.testing.expect(!findDefinition("goal").?.record_input);
    try std.testing.expect(findDefinition("plan").?.record_input);
    try std.testing.expectEqualStrings(
        "[<objective>|clear|edit <objective>|pause|resume]",
        findDefinition("goal").?.input_hint.?,
    );
    try std.testing.expectEqualStrings("<preset>", findDefinition("permission").?.input_hint.?);
    try std.testing.expectEqualStrings(generated.plan_mode.command_hint, findDefinition("plan").?.input_hint.?);
}

test "unknown and host command lines are not claimed" {
    // `/plan` is claimed by dsh-native; `/new` remains a host command.
    const lines = [_][]const u8{
        "/new",
        "/help",
        "/compactx",
        "/",
        "hello",
        "/Compact",
    };
    for (lines) |line| try expectUnclaimed(line);
}

const GoalStub = struct {
    raw_input: []const u8 = "",
    calls: usize = 0,
    kind: Kind = .success,
    text: []const u8 = "Goal created",

    fn seam(self: *GoalStub) Goal {
        return .{ .context = self, .call = call };
    }

    fn call(context_ptr: ?*anyopaque, allocator: Allocator, raw_input: []const u8) anyerror!GoalOutcome {
        const self: *GoalStub = @ptrCast(@alignCast(context_ptr.?));
        self.calls += 1;
        self.raw_input = raw_input;
        if (self.kind == .@"error") return .{ .kind = self.kind, .text = self.text };
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "kind", .{ .string = "goal/change" });
        return .{
            .kind = self.kind,
            .text = self.text,
            .events = try allocator.dupe(types.Event, &.{.{
                .event_type = "goal/change",
                .seq = 0,
                .time_ms = 0,
                .data = .{ .object = object },
            }}),
        };
    }
};

test "/goal delegates to the goal seam with a recordInput:false lifecycle" {
    var stub = GoalStub{};
    var result = try claimed("/goal ship it", .{ .command_id = "cmd-20", .goal = stub.seam() });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "goal/change", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqualStrings("Goal created", result.text);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
    try std.testing.expectEqualStrings(" ship it", stub.raw_input);
    try std.testing.expect(eventString(result.events[0], "args") == null);
    try std.testing.expect(eventString(result.events[2], "args") == null);
}

test "/goal settles a domain failure without inventing domain events" {
    var stub = GoalStub{ .kind = .@"error", .text = "GoalInvalidTransition" };
    var result = try claimed("/goal pause", .{ .command_id = "cmd-21", .goal = stub.seam() });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqual(Kind.@"error", result.kind);
    try std.testing.expectEqualStrings("GoalInvalidTransition", result.text);
}

test "/goal without a wired seam settles as unavailable" {
    var result = try claimed("/goal", .{ .command_id = "cmd-22" });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try std.testing.expectEqual(Kind.@"error", result.kind);
    try std.testing.expectEqualStrings("The /goal command is unavailable.", result.text);
}

test "/plan on commits plan/mode in the command lifecycle" {
    var result = try claimed("/plan on", .{ .command_id = "cmd-30" });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "plan/mode", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqual(Kind.success, result.kind);
    try std.testing.expectEqualStrings(generated.plan_mode.on_committed, result.text);
    try std.testing.expectEqualStrings(" on", stringField(result.events[0], "args"));
    try std.testing.expectEqual(true, eventBool(result.events[1], "active").?);
    try std.testing.expectEqual(plan.Outcome.committed, result.plan_decision.?.outcome);
    try std.testing.expectEqual(@as(?bool, true), result.plan_decision.?.emit);
    // dsh parses only the exact word "off"; every other input, including
    // "on", is also steered into the session as a user message.
    try std.testing.expectEqualStrings("on", result.steer.?);
}

test "/plan <message> steers the trimmed message into the session" {
    var result = try claimed("/plan   focus on the parser  ", .{
        .command_id = "cmd-40",
        .plan = .{ .active = false },
    });
    defer result.deinit();

    try std.testing.expectEqual(Kind.success, result.kind);
    try std.testing.expectEqualStrings("focus on the parser", result.steer.?);

    var bare = try claimed("/plan", .{
        .command_id = "cmd-41",
        .plan = .{ .active = false },
    });
    defer bare.deinit();
    try std.testing.expect(bare.steer == null);
}

test "/plan off commits plan/mode=false" {
    var result = try claimed("/plan off", .{ .command_id = "cmd-31", .plan = .{ .active = true } });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "plan/mode", "command/done" });
    try assertLifecycle(result.events);
    try std.testing.expectEqualStrings(generated.plan_mode.off_committed, result.text);
    try std.testing.expectEqualStrings(" off", stringField(result.events[0], "args"));
    try std.testing.expectEqual(false, eventBool(result.events[1], "active").?);
    try std.testing.expectEqual(plan.Outcome.committed, result.plan_decision.?.outcome);
    try std.testing.expect(result.steer == null);
}

test "/plan queues a mode switch while a turn is open" {
    var on = try claimed("/plan on", .{
        .command_id = "cmd-32",
        .plan = .{ .active = false, .turn_open = true },
    });
    defer on.deinit();
    try expectTypes(on.events, &.{ "command/run", "command/done" });
    try assertLifecycle(on.events);
    try std.testing.expectEqualStrings(generated.plan_mode.on_queued, on.text);
    try std.testing.expectEqual(plan.Outcome.queued, on.plan_decision.?.outcome);
    try std.testing.expectEqual(@as(?bool, true), on.plan_decision.?.queue);

    var off = try claimed("/plan off", .{
        .command_id = "cmd-33",
        .plan = .{ .active = true, .turn_open = true },
    });
    defer off.deinit();
    try expectTypes(off.events, &.{ "command/run", "command/done" });
    try std.testing.expectEqualStrings(generated.plan_mode.off_queued, off.text);
    try std.testing.expectEqual(plan.Outcome.queued, off.plan_decision.?.outcome);
    try std.testing.expectEqual(@as(?bool, false), off.plan_decision.?.queue);
}

test "/plan off is idempotent when plan mode is inactive" {
    var result = try claimed("/plan off", .{ .command_id = "cmd-34" });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try std.testing.expectEqualStrings(generated.plan_mode.off_already_inactive, result.text);
    try std.testing.expectEqual(plan.Outcome.noop, result.plan_decision.?.outcome);
    try std.testing.expect(result.steer == null);
}

test "/plan cancels a queued entry when switched back during the turn" {
    var result = try claimed("/plan off", .{
        .command_id = "cmd-35",
        .plan = .{ .active = false, .pending = true, .turn_open = true },
    });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "command/done" });
    try std.testing.expectEqualStrings(generated.plan_mode.off_cancelled, result.text);
    try std.testing.expectEqual(plan.Outcome.cancelled, result.plan_decision.?.outcome);
    try std.testing.expectEqual(@as(?bool, false), result.plan_decision.?.queue);
}

test "/plan on narrates the switch when the last header saw plan mode off" {
    var result = try claimed("/plan on", .{
        .command_id = "cmd-36",
        .plan = .{ .active = false, .active_at_last_header = false },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(generated.plan_mode.narration_on, result.plan_decision.?.narration.?);
}

test "/plan accepts a 64 KiB message without leaking" {
    const size = 64 * 1024;
    const line = try std.testing.allocator.alloc(u8, size + "/plan ".len);
    defer std.testing.allocator.free(line);
    @memcpy(line[0.."/plan ".len], "/plan ");
    @memset(line["/plan ".len..], 'x');

    var result = try claimed(line, .{ .command_id = "cmd-37" });
    defer result.deinit();

    try expectTypes(result.events, &.{ "command/run", "plan/mode", "command/done" });
    try std.testing.expectEqual(size + 1, stringField(result.events[0], "args").len);
    // `/plan ` leaves one leading space in `raw_input`; the steer is trimmed.
    try std.testing.expectEqual(size, result.steer.?.len);
}

test "parseCommand preserves separator whitespace and enforces the name grammar" {
    const parsed = parseCommand("/permission\t read-only").?;
    try std.testing.expectEqualStrings("permission", parsed.name);
    try std.testing.expectEqualStrings("\t read-only", parsed.raw_input);
    try std.testing.expectEqualStrings("", parseCommand("/compact").?.raw_input);
    try std.testing.expect(parseCommand("/compact-2 now") != null);
    try std.testing.expect(parseCommand("/compactx") != null);
    try std.testing.expect(parseCommand("/Compact") == null);
    try std.testing.expect(parseCommand("compact") == null);
    try std.testing.expect(parseCommand("/") == null);
}

test "assertLifecycle rejects unpaired or reordered lifecycle events" {
    var result = try claimed("/export", .{ .command_id = "cmd-19" });
    defer result.deinit();

    const copy = try std.testing.allocator.dupe(types.Event, result.events);
    defer std.testing.allocator.free(copy);
    try assertLifecycle(copy);
    std.mem.swap(types.Event, &copy[0], &copy[1]);
    try std.testing.expectError(error.CommandEventsNotAdjacent, assertLifecycle(copy));
    std.mem.swap(types.Event, &copy[0], &copy[1]);
    try std.testing.expectError(error.CommandEventsNotAdjacent, assertLifecycle(copy[0..1]));
}

test "a missing command id is rejected before any event is built" {
    try std.testing.expectError(
        error.InvalidCommandId,
        handleLocalCommand(std.testing.allocator, "/compact", .{ .command_id = "" }),
    );
}
