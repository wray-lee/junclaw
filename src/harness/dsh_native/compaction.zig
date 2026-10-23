//! Automatic and manual compaction core (design §1.6 B29-B31).
//!
//! Mirrors dsh 0.2.1-rc.2:
//! - `packages/compaction/compaction-basic/src/config.ts:20-23,75,106,153-217`
//!   (threshold/retention spec and validation);
//! - `.../compaction-basic/src/index.ts:286-347` (prune first, remeasure,
//!   threshold, range choice) and `:383-416` (manual `/compact`);
//! - `.../compaction-basic/src/region.ts:107-156` (range), `:301-334,566-600`
//!   (durable lock), `:160-163` (four-event transaction contract);
//! - `.../compaction-basic/src/summarizer.ts:21-40,70-71,188-194,213-221`
//!   (instruction, checkpoint framing, text-only summary);
//! - `packages/compaction/compaction/src/tool-pairing.ts` (safe cuts);
//! - `packages/compaction/compaction-tool-result-pruner/src/{config,index}.ts`
//!   (model-free tool-result pass).
//!
//! The module is deliberately pure: it owns no log and performs no provider
//! call. `check` is the pressure probe for an agent/pre-step hook or request
//! assembly; `run` performs one pruner pass, range selection, and exactly one
//! summarization transaction whose four events are adjacent by contract.
//! Callers map the returned nodes/events onto the session log.
//!
//! Two dsh behaviours are intentionally not reproduced here:
//! - `compactionRetries` (the dsh default is 1 retry after a summary that
//!   still exceeds the threshold); callers may invoke `run` again.
//! - image offload (`compaction-image-offload`): explicitly out of scope.

const std = @import("std");
const request = @import("request.zig");
const token_meter = @import("token_meter.zig");
const types = @import("types.zig");
const generated = @import("generated/root.zig");

const Allocator = std.mem.Allocator;
const compaction_text = generated.compaction;

/// Threshold and retention policy (`BasicCompactionConfig` defaults).
pub const Options = struct {
    /// `DEFAULT_THRESHOLD_RATIO` (config.ts:20).
    threshold_ratio: f64 = 0.8,
    /// `headroomTokens` default (config.ts:75).
    headroom_tokens: u64 = 65_536,
    /// `DEFAULT_RETAIN_RATIO` (config.ts:23).
    retain_ratio: f64 = 0.16,
    /// Explicit `retainTokens` override (config.ts:195-197).
    retain_tokens: ?u64 = null,
    /// `maxOverflowRetries` default (config.ts:106).
    max_overflow_retries: u32 = 1,
    prune: PruneConfig = .{},
};

/// Tool-result pruner budgets (`compaction-tool-result-pruner/src/config.ts:10-14`).
pub const PruneConfig = struct {
    /// `DEFAULTS.thresholdChars` (config.ts:11).
    threshold_chars: usize = 8192,
    /// `DEFAULTS.headChars` (config.ts:12).
    head_chars: usize = 4096,
    /// `DEFAULTS.tailChars` (config.ts:13).
    tail_chars: usize = 1024,
};

/// Concrete budgets for one routed model (`ResolvedCompactSpec`).
pub const Spec = struct {
    threshold_tokens: u64,
    retain_tokens: u64,
};

/// Largest window whose f64 products stay exact, mirroring JS safe integers.
const max_exact_window: u64 = 1 << 53;

/// Scale the policy for one model (`config.ts:153-217`).
///
/// dsh source, verbatim:
/// - `messageBudgetTokens = contextWindow - reservedCompletionTokens` (:172)
/// - `pressureBudgetTokens = messageBudgetTokens - headroomTokens` (:181)
/// - `thresholdTokens = Math.floor(Math.min(contextWindow * thresholdRatio,
///   pressureBudgetTokens))` (:191-194). The ratio branch scales the **context
///   window**, not the message budget; the design's `0.8 * messageBudget`
///   wording does not match the checked-out dsh source.
/// - `retainTokens = Math.floor(messageBudgetTokens * retainRatio)` unless
///   configured explicitly (:195-197).
pub fn resolveSpec(options: Options, context_window: u64, reserved_completion_tokens: u64) !Spec {
    if (context_window == 0 or context_window > max_exact_window) return error.InvalidContextWindow;
    if (!std.math.isFinite(options.threshold_ratio) or options.threshold_ratio < 0)
        return error.InvalidThresholdRatio;
    if (!std.math.isFinite(options.retain_ratio) or options.retain_ratio < 0)
        return error.InvalidRetainRatio;
    // config.ts:172-179: a request with no message budget cannot be compacted.
    if (reserved_completion_tokens >= context_window) return error.NoMessageBudget;
    const message_budget = context_window - reserved_completion_tokens;
    // config.ts:181-190.
    if (options.headroom_tokens >= message_budget) return error.NoPressureBudget;
    const pressure_budget = message_budget - options.headroom_tokens;

    const window_f: f64 = @floatFromInt(context_window);
    const pressure_f: f64 = @floatFromInt(pressure_budget);
    const threshold_f = @floor(@min(window_f * options.threshold_ratio, pressure_f));
    if (!(threshold_f >= 0 and threshold_f <= @as(f64, @floatFromInt(max_exact_window))))
        return error.InvalidThresholdRatio;
    const threshold_tokens: u64 = @intFromFloat(threshold_f);
    const retain_tokens = options.retain_tokens orelse blk: {
        const budget_f: f64 = @floatFromInt(message_budget);
        const retain_f = @floor(budget_f * options.retain_ratio);
        if (!(retain_f >= 0 and retain_f <= @as(f64, @floatFromInt(max_exact_window))))
            return error.InvalidRetainRatio;
        break :blk @as(u64, @intFromFloat(retain_f));
    };
    // config.ts:198-206.
    if (retain_tokens >= threshold_tokens) return error.RetainNotBelowThreshold;
    return .{ .threshold_tokens = threshold_tokens, .retain_tokens = retain_tokens };
}

/// One current surface node: the log seq of its event plus the derived message.
pub const Node = struct {
    seq: u64,
    message: types.Message,
};

/// Result of a pressure probe.
pub const Check = struct {
    total_tokens: u64,
    threshold_tokens: u64,
    retain_tokens: u64,
    /// dsh compacts when `totalTokens >= thresholdTokens` (`index.ts:319`).
    pressured: bool,
};

/// Measure the surface and compare it with the routed model's threshold.
/// Pass `provider_usage` from the latest successful request when available;
/// otherwise the fixed heuristic in `token_meter` prices the messages.
pub fn check(
    allocator: Allocator,
    nodes: []const Node,
    options: Options,
    context_window: u64,
    reserved_completion_tokens: u64,
    provider_usage: ?types.Usage,
) !Check {
    const spec = try resolveSpec(options, context_window, reserved_completion_tokens);
    const prices = try allocator.alloc(u64, nodes.len);
    defer allocator.free(prices);
    var total = try priceNodes(allocator, nodes, prices);
    if (provider_usage) |usage| total = token_meter.usageTokens(usage);
    return .{
        .total_tokens = total,
        .threshold_tokens = spec.threshold_tokens,
        .retain_tokens = spec.retain_tokens,
        .pressured = total >= spec.threshold_tokens,
    };
}

pub const Trigger = enum {
    /// `agent/pre-step` pressure (`index.ts:319-341`).
    pressure,
    /// Provider-confirmed context overflow (`index.ts:294-302`): bypasses the
    /// threshold and retention, and always uses a zero-token tail.
    context_overflow,
    /// Explicit `/compact` (`index.ts:383-416`): one useful reduction below
    /// the threshold, zero-token tail, no pruner pass.
    manual,
};

/// Durable compaction lock state (`region.ts:301-334,566-600`).
///
/// dsh never auto-closes a torn transaction. On load an unmatched
/// `compaction/start` keeps the lock active (new attempts fail `busy`) unless a
/// later `session/end-seed` proves it belongs to an earlier lifecycle. The
/// successful path (see `snapshots/session/compaction-recovery/session.v4.jsonl`)
/// is always start -> summary -> replacement user/message -> end, adjacent.
pub const LockState = struct {
    locked_start_seq: ?u64 = null,
};

pub fn scanLock(events: []const types.Event) LockState {
    var latest_seed: ?u64 = null;
    var latest_marker: ?struct { seq: u64, start: bool } = null;
    var index = events.len;
    while (index > 0) {
        index -= 1;
        const event = events[index];
        if (latest_seed == null and std.mem.eql(u8, event.event_type, "session/end-seed")) {
            latest_seed = event.seq;
        }
        if (latest_marker == null) {
            if (std.mem.eql(u8, event.event_type, "compaction/start")) {
                latest_marker = .{ .seq = event.seq, .start = true };
            } else if (std.mem.eql(u8, event.event_type, "compaction/end")) {
                latest_marker = .{ .seq = event.seq, .start = false };
            }
        }
    }
    const marker = latest_marker orelse return .{};
    if (!marker.start) return .{};
    if (latest_seed) |seed| {
        if (seed > marker.seq) return .{};
    }
    return .{ .locked_start_seq = marker.seq };
}

pub fn assertInactive(lock: LockState) !void {
    if (lock.locked_start_seq != null) return error.CompactionLocked;
}

/// `maxOverflowRetries` state machine (`index.ts:193-235`).
pub const OverflowGuard = struct {
    max_retries: u32 = 1,
    attempts: u32 = 0,

    /// Call when a request reports `CONTEXT_WINDOW_EXCEEDED`. Returns normally
    /// only when one compaction-and-retry is allowed; the next overflow fails.
    pub fn onOverflow(self: *OverflowGuard) !void {
        if (self.attempts >= self.max_retries) return error.ContextWindowExceeded;
        self.attempts += 1;
    }

    /// A successful assistant message or an idle agent starts a fresh sequence.
    pub fn onSuccess(self: *OverflowGuard) void {
        self.attempts = 0;
    }
};

/// Exact request messages for the auxiliary summary call: the conversation's
/// system head, the shadowed region in surface order, then the compaction
/// instruction as the final user message (`region.ts:544-560`,
/// `summarizer.ts:120-140`).
pub const SummaryInput = struct {
    messages: []const types.Message,
    tools: []const request.ToolSchema,
};

/// Result of the auxiliary summarization call.
pub const SummaryOutput = struct {
    /// Model output blocks; only text blocks land in the checkpoint.
    blocks: []const types.ContentBlock,
    /// Full raw output recorded in `compaction/summary`; defaults to `blocks`.
    raw_output: ?[]const types.ContentBlock = null,
    provider: []const u8 = "",
    model: []const u8 = "",
    max_tokens: ?u32 = null,
    usage: ?types.Usage = null,
};

/// Host seam for the provider call. Text slices are copied into the result;
/// `raw_output` values are borrowed for the lifetime of the returned result.
pub const Summarizer = struct {
    context: ?*anyopaque = null,
    call: *const fn (?*anyopaque, Allocator, SummaryInput) anyerror!SummaryOutput,
};

pub const EventTag = enum { start, summary, replacement, end };

pub const StartEvent = struct {
    compaction_id: []const u8,
    turn: ?u64,
};

pub const SummaryEvent = struct {
    compaction_id: []const u8,
    summary: []const types.ContentBlock,
    raw_output: []const types.ContentBlock,
    shadowed_start_seq: u64,
    shadowed_end_seq: u64,
    shadowed_seqs: []const u64,
    shadowed_token_count: u64,
    provider: []const u8,
    model: []const u8,
    max_tokens: ?u32,
    usage: ?types.Usage,
};

pub const ReplacementEvent = struct {
    /// `<checkpoint preamble>\n\n<compacted-summary>` + summary + close tag.
    message: types.Message,
    /// Covers the shadowed nodes; wiring may prepend the auxiliary call seqs
    /// as dsh's recorded `sourceEventSeqs` does.
    source_event_seqs: []const u64,
};

pub const EndEvent = struct {
    compaction_id: []const u8,
    turn: ?u64,
    failure: ?[]const u8 = null,
};

/// The contractual transaction: `compaction/start` -> `compaction/summary` ->
/// `user/message` replacement -> `compaction/end`, with nothing between.
pub const Event = union(EventTag) {
    start: StartEvent,
    summary: SummaryEvent,
    replacement: ReplacementEvent,
    end: EndEvent,
};

/// Assert the four events are adjacent and correlated (`compaction/src/types.ts:28-33`,
/// `region.ts:160-163`). Returns `error.CompactionEventsNotAdjacent` otherwise.
pub fn assertAdjacent(events: []const Event) !void {
    if (events.len != 4) return error.CompactionEventsNotAdjacent;
    switch (events[0]) {
        .start => {},
        else => return error.CompactionEventsNotAdjacent,
    }
    switch (events[1]) {
        .summary => {},
        else => return error.CompactionEventsNotAdjacent,
    }
    switch (events[2]) {
        .replacement => {},
        else => return error.CompactionEventsNotAdjacent,
    }
    switch (events[3]) {
        .end => {},
        else => return error.CompactionEventsNotAdjacent,
    }
    const start = events[0].start;
    const summary = events[1].summary;
    const replacement = events[2].replacement;
    const end = events[3].end;
    if (!std.mem.eql(u8, start.compaction_id, summary.compaction_id) or
        !std.mem.eql(u8, start.compaction_id, end.compaction_id)) return error.CompactionEventsNotAdjacent;
    if (start.turn != end.turn) return error.CompactionEventsNotAdjacent;
    if (summary.shadowed_start_seq > summary.shadowed_end_seq) return error.CompactionEventsNotAdjacent;
    if (!std.mem.eql(u64, replacement.source_event_seqs, summary.shadowed_seqs))
        return error.CompactionEventsNotAdjacent;
}

/// One tool result rewritten by the model-free pass.
pub const PrunedNode = struct {
    seq: u64,
    message: types.Message,
};

pub const RunOptions = struct {
    /// Routed model capacity. Required (and validated) for `.pressure` only;
    /// manual and overflow triggers do not consult the threshold policy.
    context_window: u64 = 0,
    policy: Options = .{},
    reserved_completion_tokens: u64 = 0,
    /// Provider usage from the latest successful request, when available.
    provider_usage: ?types.Usage = null,
    trigger: Trigger = .pressure,
    /// Result of `scanLock` on the opened log. Refuses to compact under a torn
    /// transaction's still-active lock.
    recovery: LockState = .{},
    compaction_id: []const u8 = "compaction-1",
    replacement_message_id: []const u8 = "compaction-checkpoint-1",
    /// Open turn for automatic triggers; null for standalone manual compaction.
    turn: ?u64 = null,
    tools: []const request.ToolSchema = &.{},
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    /// Rewritten tool results, in surface order. Empty when nothing changed.
    pruned: []const PrunedNode = &.{},
    /// Exactly four adjacent events when a summary ran; empty otherwise.
    events: []const Event = &.{},
    /// Measured pressure after pruning (or the initial probe when no prune ran).
    total_tokens: u64 = 0,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

/// One compaction pass. The caller owns the log and the provider; this builds
/// the pruner replacements, the selected range, the auxiliary request, and the
/// four-event transaction. Returns no events when no summary was needed or no
/// safe range exists.
pub fn run(
    allocator: Allocator,
    nodes: []const Node,
    options: RunOptions,
    summarizer: Summarizer,
) !Result {
    try assertInactive(options.recovery);
    const spec: ?Spec = if (options.trigger == .pressure)
        try resolveSpec(options.policy, options.context_window, options.reserved_completion_tokens)
    else
        null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const current = try a.dupe(Node, nodes);
    const prices = try a.alloc(u64, current.len);
    var total = try priceNodes(a, current, prices);
    if (options.provider_usage) |usage| total = token_meter.usageTokens(usage);

    var pruned: []const PrunedNode = &.{};
    switch (options.trigger) {
        .pressure => {
            const pressure_spec = spec.?;
            if (total < pressure_spec.threshold_tokens)
                return .{ .arena = arena, .total_tokens = total };
            pruned = try pruneNodes(a, current, options.policy.prune);
            if (pruned.len > 0) {
                // A surface rewrite invalidates the provider-usage anchor; dsh
                // reprices through the singleton fold (`index.ts:321-327`).
                total = try priceNodes(a, current, prices);
                if (total < pressure_spec.threshold_tokens)
                    return .{ .arena = arena, .pruned = pruned, .total_tokens = total };
            }
        },
        .context_overflow => {
            pruned = try pruneNodes(a, current, options.policy.prune);
            if (pruned.len > 0) total = try priceNodes(a, current, prices);
        },
        .manual => {},
    }

    const retain_tokens: u64 = if (spec) |resolved| resolved.retain_tokens else 0;
    const maybe_selection = try selectRange(a, current, prices, retain_tokens);
    const selection = maybe_selection orelse
        return .{ .arena = arena, .pruned = pruned, .total_tokens = total };

    const input = try buildSummaryInput(a, current, selection, options.tools);
    const output = try summarizer.call(summarizer.context, a, input);

    var filtered: std.ArrayListUnmanaged(types.ContentBlock) = .empty;
    for (output.blocks) |block| {
        if (isImageBlock(block)) return error.SummaryContainsImage;
        switch (block) {
            .text => |text| try filtered.append(a, .{ .text = try a.dupe(u8, text) }),
            else => {},
        }
    }
    if (!hasNonBlankText(filtered.items)) return error.EmptySummary;
    const summary_blocks = try filtered.toOwnedSlice(a);

    var framed = try a.alloc(types.ContentBlock, summary_blocks.len + 2);
    framed[0] = .{ .text = compaction_text.replacement_prefix };
    @memcpy(framed[1 .. 1 + summary_blocks.len], summary_blocks);
    framed[framed.len - 1] = .{ .text = compaction_text.summary_close_tag };

    const compaction_id = try a.dupe(u8, options.compaction_id);
    const replacement = types.Message{
        .id = try a.dupe(u8, options.replacement_message_id),
        .role = .user,
        .content = framed,
        .source = .{ .other = try checkpointSource(a, compaction_id) },
    };
    // Never land a checkpoint that does not shrink the selected span
    // (`region.ts:414-421`).
    const replacement_tokens = try token_meter.estimateMessage(a, replacement);
    if (replacement_tokens >= selection.shadowed_tokens) return error.SummaryNotSmaller;

    const events = try a.alloc(Event, 4);
    events[0] = .{ .start = .{ .compaction_id = compaction_id, .turn = options.turn } };
    events[1] = .{ .summary = .{
        .compaction_id = compaction_id,
        .summary = summary_blocks,
        .raw_output = try a.dupe(types.ContentBlock, output.raw_output orelse output.blocks),
        .shadowed_start_seq = selection.start_seq,
        .shadowed_end_seq = selection.end_seq,
        .shadowed_seqs = selection.shadowed_seqs,
        .shadowed_token_count = selection.shadowed_tokens,
        .provider = try a.dupe(u8, output.provider),
        .model = try a.dupe(u8, output.model),
        .max_tokens = output.max_tokens,
        .usage = output.usage,
    } };
    events[2] = .{ .replacement = .{
        .message = replacement,
        .source_event_seqs = selection.shadowed_seqs,
    } };
    events[3] = .{ .end = .{ .compaction_id = compaction_id, .turn = options.turn } };
    try assertAdjacent(events);

    return .{ .arena = arena, .pruned = pruned, .events = events, .total_tokens = total };
}

const Selection = struct {
    first_idx: usize,
    last_idx: usize,
    start_seq: u64,
    end_seq: u64,
    shadowed_seqs: []const u64,
    shadowed_tokens: u64,
};

/// Choose the range dsh chooses (`region.ts:107-156`): start at the first
/// non-system node, retain the recent tail until `retain_tokens`, then walk the
/// cut backwards until no assistant tool call is left without its result.
fn selectRange(
    allocator: Allocator,
    nodes: []const Node,
    prices: []const u64,
    retain_tokens: u64,
) !?Selection {
    if (nodes.len == 0 or prices.len != nodes.len) return null;
    const first_idx: usize = if (nodes[0].message.role == .system) 1 else 0;

    // `cut_balanced[i]` says the cut before node i leaves no open tool call
    // (`tool-pairing.ts:40-72`).
    const cut_balanced = try allocator.alloc(bool, nodes.len + 1);
    var pending: i64 = 0;
    cut_balanced[0] = true;
    for (nodes, 0..) |current_node, index| {
        pending += toolDelta(current_node.message);
        if (pending < 0) return error.CorruptSurface;
        cut_balanced[index + 1] = pending == 0;
    }

    var accumulated: u64 = 0;
    var keep_from: usize = nodes.len;
    var index = nodes.len;
    while (index > 0) {
        index -= 1;
        accumulated += prices[index];
        keep_from = index;
        if (accumulated >= retain_tokens) break;
    }
    if (keep_from <= first_idx) return null;

    while (keep_from > first_idx and !cut_balanced[keep_from]) keep_from -= 1;
    if (keep_from <= first_idx) return null;

    const shadowed = nodes[first_idx..keep_from];
    const seqs = try allocator.alloc(u64, shadowed.len);
    var shadowed_tokens: u64 = 0;
    for (shadowed, 0..) |node, offset| {
        seqs[offset] = node.seq;
        shadowed_tokens += prices[first_idx + offset];
    }
    return .{
        .first_idx = first_idx,
        .last_idx = keep_from - 1,
        .start_seq = nodes[first_idx].seq,
        .end_seq = nodes[keep_from - 1].seq,
        .shadowed_seqs = seqs,
        .shadowed_tokens = shadowed_tokens,
    };
}

fn toolDelta(message: types.Message) i64 {
    if (message.role == .tool) return -1;
    if (message.role != .assistant) return 0;
    var calls: i64 = 0;
    for (message.content) |block| switch (block) {
        .tool_call => {
            calls += 1;
        },
        else => {},
    };
    return calls;
}

fn buildSummaryInput(
    allocator: Allocator,
    nodes: []const Node,
    selection: Selection,
    tools: []const request.ToolSchema,
) !SummaryInput {
    var messages: std.ArrayListUnmanaged(types.Message) = .empty;
    if (nodes.len > 0 and nodes[0].message.role == .system)
        try messages.append(allocator, nodes[0].message);
    for (nodes[selection.first_idx .. selection.last_idx + 1]) |node|
        try messages.append(allocator, node.message);
    const instruction_blocks = try allocator.alloc(types.ContentBlock, 1);
    instruction_blocks[0] = .{ .text = compaction_text.instruction };
    try messages.append(allocator, .{
        .id = "compaction-instruction",
        .role = .user,
        .content = instruction_blocks,
        .source = .user,
    });
    return .{ .messages = try messages.toOwnedSlice(allocator), .tools = tools };
}

fn checkpointSource(allocator: Allocator, compaction_id: []const u8) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "kind", .{ .string = "compact-checkpoint" });
    try object.put(allocator, "compactionId", .{ .string = try allocator.dupe(u8, compaction_id) });
    return .{ .object = object };
}

fn hasNonBlankText(blocks: []const types.ContentBlock) bool {
    for (blocks) |block| switch (block) {
        .text => |text| if (std.mem.trim(u8, text, " \t\r\n").len > 0) return true,
        else => {},
    };
    return false;
}

fn isImageBlock(block: types.ContentBlock) bool {
    return switch (block) {
        .raw => |value| switch (value) {
            .object => |object| if (object.get("type")) |kind| switch (kind) {
                .string => |text| std.mem.eql(u8, text, "image"),
                else => false,
            } else false,
            else => false,
        },
        else => false,
    };
}

fn priceNodes(allocator: Allocator, nodes: []const Node, prices: []u64) !u64 {
    var total: u64 = 0;
    for (nodes, 0..) |node, index| {
        const price = try token_meter.estimateMessage(allocator, node.message);
        prices[index] = price;
        total += price;
    }
    return total;
}

/// Validate the pruner budgets (`pruner/config.ts:36-72`).
pub fn validatePruneConfig(config: PruneConfig) !void {
    if (config.threshold_chars == 0) return error.InvalidPruneConfig;
    const marker_chars = try codePointLength(compaction_text.prune_marker);
    const emitted = config.head_chars +| marker_chars +| config.tail_chars;
    if (emitted > config.threshold_chars) return error.InvalidPruneConfig;
}

fn pruneNodes(allocator: Allocator, nodes: []Node, config: PruneConfig) ![]const PrunedNode {
    try validatePruneConfig(config);
    var out: std.ArrayListUnmanaged(PrunedNode) = .empty;
    for (nodes) |*node| {
        if (node.message.role != .tool) continue;
        const content = try pruneContent(allocator, node.message.content, config) orelse continue;
        node.message.content = content;
        try out.append(allocator, .{ .seq = node.seq, .message = node.message });
    }
    return out.toOwnedSlice(allocator);
}

/// Deterministic head/marker/tail rewrite (`pruner/index.ts:69-122`).
/// Lengths are Unicode code points, not UTF-16 units and not bytes.
fn pruneContent(
    allocator: Allocator,
    blocks: []const types.ContentBlock,
    config: PruneConfig,
) !?[]const types.ContentBlock {
    try validatePruneConfig(config);
    var total_chars: usize = 0;
    for (blocks) |block| switch (block) {
        .text => |text| {
            total_chars += try codePointLength(text);
        },
        else => {},
    };
    if (total_chars <= config.threshold_chars) return null;

    const removed_start = config.head_chars;
    const removed_end = total_chars - config.tail_chars;
    var pruned: std.ArrayListUnmanaged(types.ContentBlock) = .empty;
    var consumed: usize = 0;
    var marker_inserted = false;

    for (blocks) |block| switch (block) {
        .text => |text| {
            const points = try codePointLength(text);
            const block_start = consumed;
            const block_end = block_start + points;
            const head_end = @min(points, removed_start -| block_start);
            const tail_start = @min(points, removed_end -| block_start);
            const intersects = block_start < removed_end and block_end > removed_start;
            const marker = if (intersects and !marker_inserted) compaction_text.prune_marker else "";
            if (marker.len > 0) marker_inserted = true;
            const head_bytes = try codePointOffset(text, head_end);
            const tail_bytes = try codePointOffset(text, tail_start);
            if (head_bytes + marker.len + (text.len - tail_bytes) > 0) {
                var rewritten: std.ArrayListUnmanaged(u8) = .empty;
                try rewritten.appendSlice(allocator, text[0..head_bytes]);
                try rewritten.appendSlice(allocator, marker);
                try rewritten.appendSlice(allocator, text[tail_bytes..]);
                try pruned.append(allocator, .{ .text = try rewritten.toOwnedSlice(allocator) });
            }
            consumed = block_end;
        },
        else => try pruned.append(allocator, block),
    };
    if (!marker_inserted) return error.PruneFailed;

    var after_chars: usize = 0;
    for (pruned.items) |block| switch (block) {
        .text => |text| {
            after_chars += try codePointLength(text);
        },
        else => {},
    };
    if (after_chars > config.threshold_chars or after_chars >= total_chars) return error.PruneFailed;
    return try pruned.toOwnedSlice(allocator);
}

fn codePointLength(text: []const u8) !usize {
    var index: usize = 0;
    var count: usize = 0;
    while (index < text.len) : (count += 1) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return error.InvalidUtf8;
        if (index + length > text.len) return error.InvalidUtf8;
        _ = std.unicode.utf8Decode(text[index .. index + length]) catch return error.InvalidUtf8;
        index += length;
    }
    return count;
}

fn codePointOffset(text: []const u8, target: usize) !usize {
    var offset: usize = 0;
    var count: usize = 0;
    while (count < target) : (count += 1) {
        if (offset >= text.len) return error.InvalidUtf8;
        const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch return error.InvalidUtf8;
        if (offset + length > text.len) return error.InvalidUtf8;
        _ = std.unicode.utf8Decode(text[offset .. offset + length]) catch return error.InvalidUtf8;
        offset += length;
    }
    return offset;
}

const testing = std.testing;

fn textBlock(text: []const u8) types.ContentBlock {
    return .{ .text = text };
}

fn userMessage(id: []const u8, content: []const types.ContentBlock) types.Message {
    return .{ .id = id, .role = .user, .content = content, .source = .user };
}

fn systemMessage(id: []const u8, content: []const types.ContentBlock) types.Message {
    return .{ .id = id, .role = .system, .content = content, .source = .system_prompt };
}

fn assistantMessage(id: []const u8, content: []const types.ContentBlock) types.Message {
    return .{
        .id = id,
        .role = .assistant,
        .content = content,
        .source = .{ .model = .{ .provider = "test-provider", .model = "test-model" } },
    };
}

fn toolMessage(id: []const u8, call_id: []const u8, content: []const types.ContentBlock) types.Message {
    return .{
        .id = id,
        .role = .tool,
        .content = content,
        .source = .{ .tool = .{ .call_id = call_id } },
        .tool_call_id = call_id,
    };
}

fn surfaceNode(seq: u64, message: types.Message) Node {
    return .{ .seq = seq, .message = message };
}

fn repeatPattern(allocator: Allocator, pattern: []const u8, count: usize) ![]u8 {
    const out = try allocator.alloc(u8, pattern.len * count);
    for (0..count) |index| @memcpy(out[index * pattern.len ..][0..pattern.len], pattern);
    return out;
}

fn plainEvent(seq: u64, event_type: []const u8) types.Event {
    return .{ .event_type = event_type, .seq = seq, .time_ms = 0, .data = .{ .null = {} } };
}

const TestSummary = struct {
    calls: usize = 0,
    saw_system: bool = false,
    saw_instruction: bool = false,
    tools: usize = 0,

    fn call(context: ?*anyopaque, allocator: Allocator, input: SummaryInput) anyerror!SummaryOutput {
        _ = allocator;
        if (context) |raw| {
            const self: *TestSummary = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.tools = input.tools.len;
            self.saw_system = input.messages.len > 0 and input.messages[0].role == .system;
            const last = input.messages[input.messages.len - 1];
            self.saw_instruction = last.role == .user and last.content.len == 1 and
                std.mem.eql(u8, last.content[0].text, compaction_text.instruction);
        }
        return .{
            .blocks = &.{textBlock("ok")},
            .provider = "test-provider",
            .model = "test-model",
            .max_tokens = 64,
        };
    }
};

const EmptySummary = struct {
    fn call(_: ?*anyopaque, _: Allocator, _: SummaryInput) anyerror!SummaryOutput {
        return .{ .blocks = &.{textBlock("   ")} };
    }
};

const OversizedSummary = struct {
    fn call(_: ?*anyopaque, allocator: Allocator, _: SummaryInput) anyerror!SummaryOutput {
        const text = try repeatPattern(allocator, "x", 400);
        return .{ .blocks = &.{textBlock(text)} };
    }
};

test "compact spec matches the dsh threshold and retention formulas" {
    // contextWindow 100000, reserved 0: messageBudget 100000, pressureBudget
    // 34464; threshold = min(floor(0.8*100000), 34464); retain = floor(0.16*100000).
    const defaults = try resolveSpec(.{}, 100_000, 0);
    try testing.expectEqual(@as(u64, 34_464), defaults.threshold_tokens);
    try testing.expectEqual(@as(u64, 16_000), defaults.retain_tokens);
    const option_defaults = Options{};
    try testing.expectEqual(@as(f64, 0.8), option_defaults.threshold_ratio);
    try testing.expectEqual(@as(f64, 0.16), option_defaults.retain_ratio);
    try testing.expectEqual(@as(u64, 65_536), option_defaults.headroom_tokens);
    try testing.expectEqual(@as(u32, 1), option_defaults.max_overflow_retries);

    // The ratio branch wins when headroom < 0.2 * contextWindow.
    const ratio_branch = try resolveSpec(.{ .headroom_tokens = 10_000 }, 100_000, 0);
    try testing.expectEqual(@as(u64, 80_000), ratio_branch.threshold_tokens);

    // Equality of both branches still picks the same floor.
    const tied = try resolveSpec(.{ .headroom_tokens = 20_000 }, 100_000, 0);
    try testing.expectEqual(@as(u64, 80_000), tied.threshold_tokens);

    // Reserved completion tokens shrink the retention base but not the ratio
    // branch: threshold = min(80000, 75000-10000), retain = floor(0.16*75000).
    const reserved = try resolveSpec(.{ .headroom_tokens = 10_000 }, 100_000, 25_000);
    try testing.expectEqual(@as(u64, 65_000), reserved.threshold_tokens);
    try testing.expectEqual(@as(u64, 12_000), reserved.retain_tokens);

    // Non-integral products floor toward zero.
    const floored = try resolveSpec(.{ .headroom_tokens = 0 }, 7, 0);
    try testing.expectEqual(@as(u64, 5), floored.threshold_tokens);
    try testing.expectEqual(@as(u64, 1), floored.retain_tokens);

    const explicit = try resolveSpec(.{ .retain_tokens = 123 }, 100_000, 0);
    try testing.expectEqual(@as(u64, 123), explicit.retain_tokens);
}

test "compact spec rejects impossible budgets" {
    try testing.expectError(error.NoMessageBudget, resolveSpec(.{}, 100, 100));
    try testing.expectError(error.NoPressureBudget, resolveSpec(.{ .headroom_tokens = 100 }, 100, 0));
    try testing.expectError(
        error.RetainNotBelowThreshold,
        resolveSpec(.{ .headroom_tokens = 0, .retain_tokens = 80 }, 100, 0),
    );
    try testing.expectError(error.InvalidThresholdRatio, resolveSpec(.{ .threshold_ratio = -1 }, 100, 0));
    try testing.expectError(error.InvalidRetainRatio, resolveSpec(.{ .headroom_tokens = 0, .retain_ratio = 1e300 }, 100, 0));
    try testing.expectError(error.InvalidContextWindow, resolveSpec(.{}, 0, 0));
}

test "pruner defaults match dsh and the marker is exact" {
    const config = PruneConfig{};
    try testing.expectEqual(@as(usize, 8192), config.threshold_chars);
    try testing.expectEqual(@as(usize, 4096), config.head_chars);
    try testing.expectEqual(@as(usize, 1024), config.tail_chars);
    try testing.expectEqual(@as(usize, compaction_text.prune_defaults.threshold_chars), config.threshold_chars);
    try testing.expectEqual(@as(usize, compaction_text.prune_defaults.head_chars), config.head_chars);
    try testing.expectEqual(@as(usize, compaction_text.prune_defaults.tail_chars), config.tail_chars);
    try testing.expectEqualStrings("\n\n[... tool result middle pruned ...]\n\n", compaction_text.prune_marker);
    try validatePruneConfig(config);
    try testing.expectError(
        error.InvalidPruneConfig,
        validatePruneConfig(.{ .head_chars = 8000, .tail_chars = 1000 }),
    );
}

test "pruner boundary is exactly 8192/8193 code points" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const at_limit = try repeatPattern(a, "a", 8192);
    const at_blocks = [_]types.ContentBlock{textBlock(at_limit)};
    try testing.expect((try pruneContent(a, &at_blocks, .{})) == null);

    const over = try repeatPattern(a, "a", 8193);
    const over_blocks = [_]types.ContentBlock{textBlock(over)};
    const pruned = (try pruneContent(a, &over_blocks, .{})).?;
    try testing.expectEqual(@as(usize, 1), pruned.len);
    const out = pruned[0].text;
    const marker_chars = try codePointLength(compaction_text.prune_marker);
    try testing.expectEqual(@as(usize, 4096 + marker_chars + 1024), try codePointLength(out));
    try testing.expectEqualStrings(over[0..4096], out[0..4096]);
    try testing.expectEqualStrings(over[8193 - 1024 ..], out[out.len - 1024 ..]);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, compaction_text.prune_marker));
}

test "pruner slices Unicode code points without splitting them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 9000 CJK code points (3 UTF-8 bytes each) exceed the 8192-character budget.
    const text = try repeatPattern(a, "中", 9000);
    const blocks = [_]types.ContentBlock{textBlock(text)};
    const pruned = (try pruneContent(a, &blocks, .{})).?;
    const out = pruned[0].text;
    try testing.expectEqualStrings(text[0 .. 4096 * 3], out[0 .. 4096 * 3]);
    try testing.expectEqualStrings(text[text.len - 1024 * 3 ..], out[out.len - 1024 * 3 ..]);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, compaction_text.prune_marker));
}

test "pruner preserves rich block order and inserts one marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try repeatPattern(a, "a", 5000);
    const second = try repeatPattern(a, "b", 5000);
    const blocks = [_]types.ContentBlock{
        textBlock(first),
        .{ .raw = .{ .string = "keep" } },
        textBlock(second),
    };
    const pruned = (try pruneContent(a, &blocks, .{})).?;
    try testing.expectEqual(@as(usize, 3), pruned.len);
    try testing.expectEqualStrings("keep", pruned[1].raw.string);
    try testing.expectEqualStrings(first[0..4096], pruned[0].text[0..4096]);
    try testing.expectEqualStrings(second[3976..], pruned[2].text);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, pruned[0].text, compaction_text.prune_marker));
}

test "pruner with zero head and tail keeps only the marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try repeatPattern(a, "z", 100);
    const blocks = [_]types.ContentBlock{textBlock(text)};
    const marker_chars = try codePointLength(compaction_text.prune_marker);
    const pruned = (try pruneContent(a, &blocks, .{
        .threshold_chars = marker_chars,
        .head_chars = 0,
        .tail_chars = 0,
    })).?;
    try testing.expectEqual(@as(usize, 1), pruned.len);
    try testing.expectEqualStrings(compaction_text.prune_marker, pruned[0].text);
}

test "range starts after the system head and keeps the retained tail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sys_blocks = [_]types.ContentBlock{textBlock("system")};
    const user_blocks = [_]types.ContentBlock{textBlock("hello")};
    const asst_blocks = [_]types.ContentBlock{textBlock("done")};
    const nodes = [_]Node{
        surfaceNode(0, systemMessage("s", &sys_blocks)),
        surfaceNode(1, userMessage("u", &user_blocks)),
        surfaceNode(2, assistantMessage("a", &asst_blocks)),
    };
    const prices = [_]u64{ 100, 10, 10 };
    const selection = (try selectRange(a, &nodes, &prices, 0)).?;
    try testing.expectEqual(@as(usize, 1), selection.first_idx);
    try testing.expectEqual(@as(usize, 1), selection.last_idx);
    try testing.expectEqual(@as(u64, 1), selection.start_seq);
    try testing.expectEqual(@as(u64, 1), selection.end_seq);
    try testing.expectEqualSlices(u64, &.{1}, selection.shadowed_seqs);
    try testing.expectEqual(@as(u64, 10), selection.shadowed_tokens);
}

test "range never splits an assistant tool-call from its result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sys_blocks = [_]types.ContentBlock{textBlock("system")};
    const user_blocks = [_]types.ContentBlock{textBlock("go")};
    const call_blocks = [_]types.ContentBlock{
        .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments = "{}" } },
    };
    const result_blocks = [_]types.ContentBlock{textBlock("result")};
    const asst_blocks = [_]types.ContentBlock{textBlock("done")};

    const nodes = [_]Node{
        surfaceNode(0, systemMessage("s", &sys_blocks)),
        surfaceNode(1, userMessage("u1", &user_blocks)),
        surfaceNode(2, assistantMessage("a1", &call_blocks)),
        surfaceNode(3, toolMessage("t1", "call-1", &result_blocks)),
        surfaceNode(4, userMessage("u2", &user_blocks)),
        surfaceNode(5, assistantMessage("a2", &call_blocks)),
        surfaceNode(6, toolMessage("t2", "call-1", &result_blocks)),
        surfaceNode(7, assistantMessage("a3", &asst_blocks)),
    };
    const prices = [_]u64{ 1, 1, 1, 1, 1, 1, 1, 1 };
    // A 2-token tail would cut before node 6, splitting the second call pair;
    // the balance walk moves the cut to before node 5.
    const selection = (try selectRange(a, &nodes, &prices, 2)).?;
    try testing.expectEqual(@as(usize, 1), selection.first_idx);
    try testing.expectEqual(@as(usize, 4), selection.last_idx);
    try testing.expectEqual(@as(u64, 4), selection.end_seq);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, selection.shadowed_seqs);

    // Retaining everything leaves no range.
    try testing.expect((try selectRange(a, &nodes, &prices, 1000)) == null);
    // Empty surfaces have no range.
    try testing.expect((try selectRange(a, &[_]Node{}, &[_]u64{}, 0)) == null);
}

test "range rejects a tool result without a call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sys_blocks = [_]types.ContentBlock{textBlock("system")};
    const user_blocks = [_]types.ContentBlock{textBlock("go")};
    const result_blocks = [_]types.ContentBlock{textBlock("result")};
    const asst_blocks = [_]types.ContentBlock{textBlock("done")};
    const nodes = [_]Node{
        surfaceNode(0, systemMessage("s", &sys_blocks)),
        surfaceNode(1, userMessage("u", &user_blocks)),
        surfaceNode(2, toolMessage("t", "missing", &result_blocks)),
        surfaceNode(3, assistantMessage("a", &asst_blocks)),
    };
    const prices = [_]u64{ 1, 1, 1, 1 };
    try testing.expectError(error.CorruptSurface, selectRange(a, &nodes, &prices, 1));
}

test "check probes pressure with the heuristic and the usage anchor" {
    const a = testing.allocator;
    const sys_blocks = [_]types.ContentBlock{textBlock("system")};
    const big = try repeatPattern(a, "a", 40_000);
    defer a.free(big);
    const big_blocks = [_]types.ContentBlock{textBlock(big)};
    const nodes = [_]Node{
        surfaceNode(0, systemMessage("s", &sys_blocks)),
        surfaceNode(1, userMessage("u", &big_blocks)),
    };
    // contextWindow 10000, headroom 1024 -> threshold min(8000, 8976) = 8000.
    const options = Options{ .headroom_tokens = 1024 };
    const heuristic = try check(a, &nodes, options, 10_000, 0, null);
    try testing.expect(heuristic.pressured);
    try testing.expect(heuristic.total_tokens >= 1000);

    const anchored = try check(a, &nodes, options, 10_000, 0, .{ .input_tokens = 7, .output_tokens = 3 });
    try testing.expectEqual(@as(u64, 10), anchored.total_tokens);
    try testing.expect(!anchored.pressured);
}

test "run prunes first and skips summarization when pressure clears" {
    const a = testing.allocator;
    const sys_blocks = [_]types.ContentBlock{textBlock("system")};
    const big = try repeatPattern(a, "a", 70_000); // >= 64 KiB payload
    defer a.free(big);
    const big_blocks = [_]types.ContentBlock{textBlock(big)};
    const nodes = [_]Node{
        surfaceNode(0, systemMessage("s", &sys_blocks)),
        surfaceNode(1, toolMessage("t", "call-1", &big_blocks)),
    };
    const options = RunOptions{ .context_window = 10_000, .policy = .{ .headroom_tokens = 1024 } };
    var result = try run(a, &nodes, options, .{ .call = TestSummary.call });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.pruned.len);
    try testing.expectEqual(@as(u64, 1), result.pruned[0].seq);
    try testing.expectEqual(@as(usize, 0), result.events.len);
    try testing.expect(result.total_tokens < 8000);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.pruned[0].message.content[0].text, compaction_text.prune_marker));
}

test "run emits the four adjacent transaction events and reuses the prefix" {
    const a = testing.allocator;
    const sys_blocks = [_]types.ContentBlock{textBlock("system prompt")};
    const big = try repeatPattern(a, "a", 40_000);
    defer a.free(big);
    const big_blocks = [_]types.ContentBlock{textBlock(big)};
    const short_blocks = [_]types.ContentBlock{textBlock("ok")};
    const done_blocks = [_]types.ContentBlock{textBlock("done")};
    const nodes = [_]Node{
        surfaceNode(0, systemMessage("s", &sys_blocks)),
        surfaceNode(1, userMessage("u1", &big_blocks)),
        surfaceNode(2, assistantMessage("a1", &short_blocks)),
        surfaceNode(3, userMessage("u2", &short_blocks)),
        surfaceNode(4, assistantMessage("a2", &done_blocks)),
    };
    const tools = [_]request.ToolSchema{.{ .name = "read", .parameters_json = "{}" }};
    var context = TestSummary{};
    var result = try run(a, &nodes, .{
        .context_window = 10_000,
        .policy = .{ .headroom_tokens = 1024, .retain_tokens = 20 },
        .compaction_id = "compact-7",
        .turn = 3,
        .tools = &tools,
    }, .{ .context = &context, .call = TestSummary.call });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), context.calls);
    try testing.expect(context.saw_system);
    try testing.expect(context.saw_instruction);
    try testing.expectEqual(@as(usize, 1), context.tools);
    try testing.expectEqual(@as(usize, 4), result.events.len);
    try assertAdjacent(result.events);

    const start = result.events[0].start;
    try testing.expectEqualStrings("compact-7", start.compaction_id);
    try testing.expectEqual(@as(?u64, 3), start.turn);
    const summary = result.events[1].summary;
    try testing.expectEqual(@as(u64, 1), summary.shadowed_start_seq);
    try testing.expectEqual(@as(u64, 1), summary.shadowed_end_seq);
    try testing.expectEqualSlices(u64, &.{1}, summary.shadowed_seqs);
    try testing.expectEqualStrings("test-provider", summary.provider);

    const replacement = result.events[2].replacement;
    try testing.expectEqual(types.MessageRole.user, replacement.message.role);
    try testing.expectEqual(@as(usize, 3), replacement.message.content.len);
    try testing.expectEqualStrings(compaction_text.replacement_prefix, replacement.message.content[0].text);
    try testing.expectEqualStrings("ok", replacement.message.content[1].text);
    try testing.expectEqualStrings(compaction_text.summary_close_tag, replacement.message.content[2].text);
    switch (replacement.message.source) {
        .other => |value| {
            try testing.expectEqualStrings("compact-checkpoint", value.object.get("kind").?.string);
            try testing.expectEqualStrings("compact-7", value.object.get("compactionId").?.string);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(?u64, 3), result.events[3].end.turn);
}

test "transaction adjacency assertion rejects a reordered or short list" {
    const a = testing.allocator;
    const sys_blocks = [_]types.ContentBlock{textBlock("s")};
    const big = try repeatPattern(a, "a", 4000);
    defer a.free(big);
    const user_blocks = [_]types.ContentBlock{textBlock(big)};
    const asst_blocks = [_]types.ContentBlock{textBlock("hello there")};
    const nodes = [_]Node{
        surfaceNode(0, systemMessage("s", &sys_blocks)),
        surfaceNode(1, userMessage("u1", &user_blocks)),
        surfaceNode(2, assistantMessage("a1", &asst_blocks)),
        surfaceNode(3, userMessage("u2", &user_blocks)),
    };
    var result = try run(a, &nodes, .{ .trigger = .manual }, .{ .call = TestSummary.call });
    defer result.deinit();
    try assertAdjacent(result.events);

    const short = result.events[0..3];
    try testing.expectError(error.CompactionEventsNotAdjacent, assertAdjacent(short));

    const reordered = [_]Event{ result.events[0], result.events[2], result.events[1], result.events[3] };
    try testing.expectError(error.CompactionEventsNotAdjacent, assertAdjacent(&reordered));
}

test "overflow trigger compacts below the pressure threshold" {
    const a = testing.allocator;
    const sys_blocks = [_]types.ContentBlock{textBlock("s")};
    const big = try repeatPattern(a, "a", 4000);
    defer a.free(big);
    const user_blocks = [_]types.ContentBlock{textBlock(big)};
    const asst_blocks = [_]types.ContentBlock{textBlock("hello there")};
    const nodes = [_]Node{
        surfaceNode(0, systemMessage("s", &sys_blocks)),
        surfaceNode(1, userMessage("u", &user_blocks)),
        surfaceNode(2, assistantMessage("a", &asst_blocks)),
    };
    const probe = try check(a, &nodes, .{ .headroom_tokens = 1024 }, 10_000, 0, null);
    try testing.expect(!probe.pressured);
    var result = try run(a, &nodes, .{ .trigger = .context_overflow }, .{ .call = TestSummary.call });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 4), result.events.len);
    try testing.expectEqual(@as(usize, 1), result.events[1].summary.shadowed_seqs.len);
}

test "overflow retries once and then fails until success resets" {
    const option_defaults = Options{};
    var guard = OverflowGuard{ .max_retries = option_defaults.max_overflow_retries };
    try guard.onOverflow();
    try testing.expectEqual(@as(u32, 1), guard.attempts);
    try testing.expectError(error.ContextWindowExceeded, guard.onOverflow());
    guard.onSuccess();
    try testing.expectEqual(@as(u32, 0), guard.attempts);
    try guard.onOverflow();

    var none = OverflowGuard{ .max_retries = 0 };
    try testing.expectError(error.ContextWindowExceeded, none.onOverflow());
}

test "torn compaction transaction stays locked unless a later lifecycle seed follows" {
    const torn = [_]types.Event{
        plainEvent(0, "turn/start"),
        plainEvent(1, "compaction/start"),
        plainEvent(2, "compaction/summary"),
    };
    const locked = scanLock(&torn);
    try testing.expectEqual(@as(?u64, 1), locked.locked_start_seq);
    try testing.expectError(error.CompactionLocked, assertInactive(locked));

    const closed = [_]types.Event{ plainEvent(1, "compaction/start"), plainEvent(2, "compaction/end") };
    try testing.expectEqual(@as(?u64, null), scanLock(&closed).locked_start_seq);

    const seeded = [_]types.Event{ plainEvent(1, "compaction/start"), plainEvent(2, "session/end-seed") };
    try testing.expectEqual(@as(?u64, null), scanLock(&seeded).locked_start_seq);

    const restarted = [_]types.Event{
        plainEvent(1, "compaction/start"),
        plainEvent(2, "session/end-seed"),
        plainEvent(3, "compaction/start"),
    };
    try testing.expectEqual(@as(?u64, 3), scanLock(&restarted).locked_start_seq);

    // The recovery path refuses a new pass under the active lock.
    const sys_blocks = [_]types.ContentBlock{textBlock("s")};
    const user_blocks = [_]types.ContentBlock{textBlock("hi")};
    const nodes = [_]Node{
        surfaceNode(0, systemMessage("s", &sys_blocks)),
        surfaceNode(1, userMessage("u", &user_blocks)),
    };
    try testing.expectError(error.CompactionLocked, run(testing.allocator, &nodes, .{
        .context_window = 10_000,
        .recovery = locked,
    }, .{ .call = TestSummary.call }));
}

test "summary output must be text-only, non-blank, and smaller than the span" {
    const a = testing.allocator;
    const sys_blocks = [_]types.ContentBlock{textBlock("s")};
    const user_blocks = [_]types.ContentBlock{textBlock("hi")};
    const asst_blocks = [_]types.ContentBlock{textBlock("hello there")};
    const nodes = [_]Node{
        surfaceNode(0, systemMessage("s", &sys_blocks)),
        surfaceNode(1, userMessage("u", &user_blocks)),
        surfaceNode(2, assistantMessage("a", &asst_blocks)),
    };
    try testing.expectError(error.EmptySummary, run(a, &nodes, .{
        .context_window = 10_000,
        .trigger = .manual,
    }, .{ .call = EmptySummary.call }));
    try testing.expectError(error.SummaryNotSmaller, run(a, &nodes, .{
        .context_window = 10_000,
        .trigger = .manual,
    }, .{ .call = OversizedSummary.call }));
}
