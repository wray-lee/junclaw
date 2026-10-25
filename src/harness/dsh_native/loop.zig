//! Turn/step driver kernel: events, inbox timing, typed end reasons, abort,
//! max-tokens and the request checkpoint (design §1.2 B7/B8/B9/B10/B11/B12,
//! §3.1 `loop.zig`; dsh `packages/core/agent-loop/src/agent.ts:298-560`,
//! `tool-calls.ts`).
//!
//! Pure kernel: it owns the inbox and the turn/step state machine, and calls
//! host callbacks for everything durable or environment-specific (event sink,
//! system prompt projection, pre-step gate, provider stream, tool dispatch).
//! Tests drive it synchronously; nothing here reads a clock, a file or the
//! session log. P1a never produces `interrupted` or `forked` end reasons.
//!
//! Event order per step (B6/B8):
//!   step/start -> system/message* -> user/message* -> request/start
//!   -> assistant/stream* -> assistant/message -> tool/call -> tool/result
//!   -> step/end
//! and `turn/start` / `turn/end` bracket the turn. Input claimed for a step is
//! fixed before request/start, so a steer arriving mid-stream is never part of
//! the in-flight request: it is claimed by the next step (Z4). Abort discards
//! pending input, settles the visible prefix and closes the step before
//! `turn/end {kind:"aborted"}`; it writes no synthetic user message (B10).

const std = @import("std");
const inbox = @import("inbox.zig");
const request = @import("request.zig");
const stream = @import("stream.zig");
const scheduler = @import("tools/scheduler.zig");
const registry = @import("tools/registry.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

/// Kept identical to the native adapter's failed-turn marker.
const failure_closer_text = "[No assistant reply was produced for this turn.]";

pub const Position = struct { turn: u64, step: u64 };

/// One projected system message. dsh logs these through
/// SystemPromptProjection; the host owns add/remove/series bookkeeping.
pub const SystemMessage = struct {
    id: []const u8,
    text: []const u8,
};

/// One model-visible user message. `json` is the lossless dsh user/message
/// payload (id/role/content/source) so the log adapter can append it verbatim.
pub const UserMessage = struct {
    json: []const u8,
    /// Surface operation for the appended event; null keeps `append`. The
    /// agent-instructions baseline uses `replace` when its file set changes.
    surface_op: ?types.SurfaceOp = null,
    source_event_seqs: ?[]const u64 = null,
};

/// Durable event vocabulary produced by the kernel. Payload slices borrow
/// module arenas and are only valid for the duration of `Host.emit`.
pub const Event = union(enum) {
    turn_start: struct { turn: u64 },
    step_start: Position,
    system_message: struct { position: Position, message: SystemMessage },
    user_message: struct { position: Position, message: UserMessage },
    /// Request boundary. `header` is the `request.zig` decision; the adapter
    /// writes `request/header` only when `header.append` is true.
    request_start: struct {
        position: Position,
        attempt: u32,
        header: request.HeaderDecision,
    },
    /// One live provider event (`agent/assistant-stream` in dsh).
    assistant_stream: struct {
        position: Position,
        attempt: u32,
        event: stream.Event,
    },
    /// Settled assistant message (`surfaceOp: append`).
    assistant_message: struct {
        position: Position,
        settlement: stream.Settlement,
    },
    /// Failed/interrupted attempt without visible content.
    assistant_attempt: struct {
        position: Position,
        settlement: stream.Settlement,
    },
    /// Synthetic assistant message that closes a turn whose provider call
    /// failed. It joins the surface but not `turn_text`: the host renders the
    /// user-visible error itself.
    assistant_closer: struct {
        position: Position,
        message: types.Message,
    },
    tool_call: struct { position: Position, call: types.ToolCall },
    tool_result: struct { position: Position, result: registry.ToolResult },
    step_end: Position,
    turn_end: struct { turn: u64, reason: types.EndReason },
};

/// The input claimed for one step (`inbox.Claim` split by queue).
pub const Claimed = struct {
    next_step: []const inbox.Entry,
    next_turn: []const inbox.Entry,

    pub fn count(self: Claimed) usize {
        return self.next_step.len + self.next_turn.len;
    }
};

pub const PreStepKind = enum { enter, reject, pause };

/// `agent/pre-step` outcome. `reject` ends the turn as `blocked`; `pause`
/// keeps the claimed batch under its inbox token until `Loop.resumeTurn`.
pub const PreStepDecision = struct {
    kind: PreStepKind = .enter,
    starts_request_series: bool = false,
};

pub const RequestView = struct {
    position: Position,
    attempt: u32,
    provider: []const u8,
    model: []const u8,
    header: request.HeaderDecision,
};

/// One model attempt source. The host builds request messages from its own
/// surface; the kernel only owns timing and the event boundary.
pub const Provider = struct {
    context: *anyopaque,
    /// Start one attempt after `request/start` was emitted.
    begin: *const fn (context: *anyopaque, view: RequestView) anyerror!void,
    /// Next provider event; `null` ends the attempt. Events after a `done`
    /// event are not pulled (the kernel cancels the attempt instead).
    next: *const fn (context: *anyopaque) anyerror!?stream.Event,
    /// Release a finished/aborted attempt.
    cancel: ?*const fn (context: *anyopaque) void = null,
};

/// Fixed compaction plugin layer (design §1.6 B29-B31). The kernel calls these
/// host callbacks and never imports `compaction.zig`; the wiring lives in
/// `harness.zig` so the dependency arrow stays kernel <- host.
pub const CompactionHook = struct {
    context: *anyopaque,
    /// `agent/pre-step` pressure probe. `true` means the host rewrote the
    /// surface, so this step opens a new request series.
    pressure: *const fn (context: *anyopaque, allocator: Allocator, position: Position) anyerror!bool,
    /// Provider-confirmed context overflow. `true` means one compaction ran and
    /// the failed attempt may be retried.
    overflow: *const fn (context: *anyopaque, allocator: Allocator, position: Position) anyerror!bool,
    /// dsh `maxOverflowRetries` (`config.ts:106`).
    max_overflow_retries: u32 = 1,
};

pub const Host = struct {
    context: *anyopaque,
    /// Append one durable event and return its sequence number.
    emit: *const fn (context: *anyopaque, event: Event) anyerror!u64,
    /// Fill the system messages committed before this step's request.
    system_messages: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        position: Position,
        out: *std.ArrayListUnmanaged(SystemMessage),
    ) anyerror!void,
    /// `agent/pre-step`: inspect the claimed batch, optionally append runtime
    /// context messages, and enter/reject/pause.
    pre_step: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        position: Position,
        claimed: Claimed,
        out: *std.ArrayListUnmanaged(UserMessage),
    ) anyerror!PreStepDecision,
    /// Serialize a `types.Message` as lossless user/message JSON (used for
    /// tool `additionalContexts`).
    serialize_message: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        message: types.Message,
    ) anyerror![]u8,
    /// `agent/turn-stopping` gate. Returning false keeps the turn open only
    /// when the host also queued next-step input.
    can_turn_end: ?*const fn (context: *anyopaque, turn: u64) anyerror!bool = null,
    /// Null keeps the kernel's pre-compaction behaviour.
    compaction: ?CompactionHook = null,
    provider: Provider,
    classifier: scheduler.Classifier,
    dispatcher: scheduler.Dispatcher,
};

pub const Config = struct {
    provider: []const u8,
    model: []const u8,
    reasoning_effort: ?[]const u8 = null,
    max_tokens: ?u32 = null,
    tools: ?[]const request.ToolSchema = null,
    max_parallel_tools: usize = scheduler.DEFAULT_MAX_PARALLEL_TOOL_CALLS,
    /// Last header in force when this loop instance starts (resume).
    baseline: ?request.Header = null,
    /// Surface content generation at instance start (`agent.ts:128`).
    initial_surface_generation: u64 = 0,
    /// Deterministic stream-record clock. Defaults to 0 (no wall clock).
    now_ms: ?*const fn (context: ?*anyopaque) i64 = null,
    clock_context: ?*anyopaque = null,
};

pub const Outcome = union(enum) {
    ended: types.EndReason,
    paused,
};

const Phase = enum { idle, running, paused };

const StepResult = union(enum) {
    /// `null` means the step ended without a turn reason (continue).
    end: ?types.EndReason,
    aborted,
    failure: types.Failure,
};

const ToolsResult = union(enum) {
    aborted,
    failure: types.Failure,
    concluded,
    continue_turn,
};

const ToolHookState = struct {
    loop: *Loop,
    position: Position,
    call_seqs: []?u64,
    result_seqs: []?u64,
    committed: usize = 0,
    err: ?anyerror = null,

    fn onDispatch(context: ?*anyopaque, index: usize, call: types.ToolCall) void {
        const state: *ToolHookState = @ptrCast(@alignCast(context.?));
        if (state.err != null) return;
        const seq = state.loop.emit(.{
            .tool_call = .{ .position = state.position, .call = call },
        }) catch |err| {
            state.err = err;
            return;
        };
        state.call_seqs[index] = seq;
    }

    fn onCommit(context: ?*anyopaque, index: usize, result: *const registry.ToolResult) void {
        const state: *ToolHookState = @ptrCast(@alignCast(context.?));
        if (state.err != null) return;
        const seq = state.loop.emit(.{
            .tool_result = .{ .position = state.position, .result = result.* },
        }) catch |err| {
            state.err = err;
            return;
        };
        state.result_seqs[index] = seq;
        state.committed = index + 1;
    }
};

/// Turn/step driver. Allocate the arena first, allocate anything long-lived
/// through `arena.allocator()` while it is still at its final address, and
/// only then move it into `init` (arena red line: allocate before move).
pub const Loop = struct {
    arena: std.heap.ArenaAllocator,
    /// Allocator behind `arena`, captured before the arena moves. Owns inbox
    /// entries and claims, which outlive per-turn arena resets.
    backing: Allocator,
    inbox: inbox.Inbox,
    config: Config,
    host: Host,
    tracker: request.HeaderTracker = .{},
    last_header: ?request.Header = null,
    surface_generation: u64 = 0,
    turn: u64 = 0,
    step: u64 = 0,
    turn_ends: ?types.EndReason = null,
    phase: Phase = .idle,
    abort_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    abort_cause: ?types.AbortCause = null,
    paused_claim: ?inbox.Claim = null,
    paused_extras: std.ArrayListUnmanaged(UserMessage) = .empty,
    checkpoint: request.Checkpoint = .{},

    pub fn init(arena: std.heap.ArenaAllocator, config: Config, host: Host) Loop {
        var tracker = request.HeaderTracker{};
        tracker.request_generation = config.initial_surface_generation;
        return .{
            .backing = arena.child_allocator,
            .arena = arena,
            .inbox = inbox.Inbox.init(arena.child_allocator),
            .config = config,
            .host = host,
            .tracker = tracker,
            .last_header = config.baseline,
            .surface_generation = config.initial_surface_generation,
        };
    }

    pub fn deinit(self: *Loop) void {
        if (self.paused_claim) |*claim| claim.deinit(self.backing);
        self.paused_claim = null;
        self.inbox.deinit();
        self.arena.deinit();
    }

    pub fn allocator(self: *Loop) Allocator {
        return self.arena.allocator();
    }

    /// `followup`: queued for the next turn, wakes the driver.
    pub fn followup(self: *Loop, message: inbox.Message) !inbox.Wake {
        return self.inbox.followup(message);
    }

    /// `steer`: queued for the next step boundary, wakes the driver.
    pub fn steer(self: *Loop, message: inbox.Message) !inbox.Wake {
        return self.inbox.steer(message);
    }

    /// `inject`: queued for the next step boundary without waking.
    pub fn inject(self: *Loop, message: inbox.Message) !inbox.Wake {
        return self.inbox.inject(message);
    }

    /// Tool result context: spliced into next-step as a user message.
    pub fn additionalContext(self: *Loop, message: inbox.Message) !inbox.Wake {
        return self.inbox.additionalContext(message);
    }

    /// Abort the running turn. Safe to call from host callbacks and from tool
    /// workers; the flag is consumed by the stream pump and tool scheduler.
    pub fn abort(self: *Loop, cause: types.AbortCause) void {
        if (self.abort_cause == null) self.abort_cause = cause;
        self.abort_flag.store(true, .release);
    }

    pub fn isAborted(self: *const Loop) bool {
        return self.abort_flag.load(.acquire);
    }

    /// Drop an abort that no turn consumed (a /stop delivered after the turn
    /// ended). Refuses while running or paused: those turns own the flag.
    pub fn clearAbort(self: *Loop) void {
        if (self.phase != .idle) return;
        self.abort_flag.store(false, .release);
        self.abort_cause = null;
    }

    /// Checkpoint of the most recent request attempt (B22).
    pub fn lastCheckpoint(self: *const Loop) request.Checkpoint {
        return self.checkpoint;
    }

    /// Claim token held while paused, for ownership serialization tests.
    pub fn pausedToken(self: *const Loop) ?u64 {
        if (self.paused_claim) |claim| return claim.token;
        return null;
    }

    /// Drive one turn to its end. Claims input, emits every event and returns
    /// the typed reason. A `paused` pre-step returns `.paused`; call `resumeTurn`.
    pub fn runTurn(self: *Loop) anyerror!Outcome {
        if (self.phase != .idle) return error.LoopBusy;
        if (self.isAborted()) {
            const cause = self.abort_cause orelse types.AbortCause{ .user = {} };
            self.resetRun();
            return .{ .ended = .{ .aborted = cause } };
        }
        self.turn += 1;
        self.step = 0;
        self.turn_ends = null;
        self.phase = .running;
        _ = try self.emit(.{ .turn_start = .{ .turn = self.turn } });
        return self.driveTurn();
    }

    /// Continue a turn paused by a `pre_step` pause decision, reusing the
    /// claimed batch under its original inbox token.
    pub fn resumeTurn(self: *Loop) anyerror!Outcome {
        if (self.phase != .paused) return error.NotPaused;
        self.phase = .running;
        return self.driveTurn();
    }

    fn resetRun(self: *Loop) void {
        self.phase = .idle;
        self.turn_ends = null;
        self.step = 0;
        self.abort_flag.store(false, .release);
        self.abort_cause = null;
        self.paused_extras = .empty;
    }

    fn emit(self: *Loop, event: Event) anyerror!u64 {
        // dsh bumps `contentGeneration` only for replace/project surface
        // operations, not for appends (session/src/surface.ts:572-578).
        return self.host.emit(self.host.context, event);
    }

    fn now(self: *Loop) i64 {
        if (self.config.now_ms) |clock| return clock(self.config.clock_context);
        return 0;
    }

    fn claimFor(self: *Loop, target: inbox.Target) !inbox.Claim {
        return switch (target) {
            .next_turn => self.inbox.claimNextTurn(self.turn),
            .next_step => self.inbox.claimNextStep(self.turn),
        };
    }

    fn endTurn(self: *Loop, reason: types.EndReason) anyerror!Outcome {
        _ = try self.emit(.{ .turn_end = .{ .turn = self.turn, .reason = reason } });
        self.resetRun();
        return .{ .ended = reason };
    }

    /// Close an aborted turn: discard pending input (discard-on-interrupt),
    /// close the step if one started, then `turn/end {kind:"aborted"}`. dsh
    /// writes no synthetic user message here (B10, agent.ts:452-503).
    fn abortTurn(self: *Loop, step_started: bool) anyerror!Outcome {
        _ = self.inbox.cancel(false);
        if (step_started) {
            _ = try self.emit(.{ .step_end = .{ .turn = self.turn, .step = self.step } });
        }
        return self.endTurn(.{ .aborted = self.abort_cause orelse types.AbortCause{ .user = {} } });
    }

    fn driveTurn(self: *Loop) anyerror!Outcome {
        var target: inbox.Target = if (self.step == 0) .next_turn else .next_step;
        var carried: ?inbox.Claim = null;
        var carried_extras: std.ArrayListUnmanaged(UserMessage) = .empty;
        if (self.paused_claim) |claim| {
            carried = claim;
            carried_extras = self.paused_extras;
            self.paused_claim = null;
            self.paused_extras = .empty;
            target = claim.target;
        }

        while (true) {
            if (self.isAborted()) {
                if (carried) |*claim| {
                    claim.deinit(self.backing);
                    carried = null;
                }
                return self.abortTurn(false);
            }

            var claim: inbox.Claim = undefined;
            var claim_owned = false;
            // Regression: a pressure/pre-step hook error returned before the
            // claim was settled, leaking the claimed inbox batch.
            errdefer {
                if (claim_owned) claim.deinit(self.backing);
            }
            var extras: std.ArrayListUnmanaged(UserMessage) = .empty;
            var decision = PreStepDecision{};
            if (carried) |held| {
                claim = held;
                claim_owned = true;
                carried = null;
                extras = carried_extras;
                carried_extras = .empty;
            } else {
                claim = try self.claimFor(target);
                claim_owned = true;
                // Pressure runs before the host's pre-step gate, like dsh's
                // `agent/pre-step` compaction hook (index.ts:319-341).
                const compacted = if (self.host.compaction) |hook|
                    try hook.pressure(hook.context, self.allocator(), .{
                        .turn = self.turn,
                        .step = self.step + 1,
                    })
                else
                    false;
                decision = try self.host.pre_step(
                    self.host.context,
                    self.allocator(),
                    .{ .turn = self.turn, .step = self.step + 1 },
                    .{ .next_step = claim.next_step, .next_turn = claim.next_turn },
                    &extras,
                );
                if (compacted) decision.starts_request_series = true;
            }

            switch (decision.kind) {
                .pause => {
                    if (self.isAborted()) {
                        claim.deinit(self.backing);
                        claim_owned = false;
                        return self.abortTurn(false);
                    }
                    self.paused_claim = claim;
                    claim_owned = false;
                    self.paused_extras = extras;
                    self.phase = .paused;
                    return .paused;
                },
                .reject => {
                    claim.deinit(self.backing);
                    claim_owned = false;
                    return self.endTurn(.blocked);
                },
                .enter => {},
            }

            if (self.isAborted()) {
                claim.deinit(self.backing);
                claim_owned = false;
                return self.abortTurn(false);
            }

            const count = claim.count() + extras.items.len;
            if (self.turn_ends != null and count == 0) {
                claim.deinit(self.backing);
                claim_owned = false;
                break;
            }
            if (self.step == 0 and count == 0) {
                claim.deinit(self.backing);
                claim_owned = false;
                return self.endTurn(.completed);
            }

            self.step += 1;
            const position = Position{ .turn = self.turn, .step = self.step };
            _ = try self.emit(.{ .step_start = position });

            // Header bookkeeping is taken before this step's surface appends,
            // like dsh prepareRequest (agent.ts:632-667).
            const header = self.currentHeader();
            const header_decision = self.tracker.beginRequest(
                self.last_header,
                header,
                self.surface_generation,
                decision.starts_request_series,
            );
            if (header_decision.append) self.last_header = header_decision.header;

            var system_messages: std.ArrayListUnmanaged(SystemMessage) = .empty;
            try self.host.system_messages(
                self.host.context,
                self.allocator(),
                position,
                &system_messages,
            );
            for (system_messages.items) |message| {
                _ = try self.emit(.{
                    .system_message = .{ .position = position, .message = message },
                });
            }

            // Checkpoint: an abort before the request boundary writes no
            // partial assistant message (B22).
            if (self.isAborted()) {
                claim.deinit(self.backing);
                claim_owned = false;
                return self.abortTurn(true);
            }

            for (claim.next_step) |entry| try self.emitEntry(position, entry);
            for (claim.next_turn) |entry| try self.emitEntry(position, entry);
            for (extras.items) |message| {
                _ = try self.emit(.{
                    .user_message = .{ .position = position, .message = message },
                });
            }
            claim.deinit(self.backing);
            claim_owned = false;

            if (self.isAborted()) return self.abortTurn(true);

            const step_result = self.runStep(position, header_decision) catch |err| return err;
            switch (step_result) {
                .aborted => return self.abortTurn(true),
                .failure => |failure| return self.endTurn(.{ .failure = failure }),
                .end => |maybe_reason| {
                    // dsh agent.ts:343 assigns the step ending unconditionally:
                    // a null (tool calls still pending) clears an earlier
                    // completed, and only max-tokens stays sticky.
                    const sticky = if (self.turn_ends) |turn_end|
                        switch (turn_end) {
                            .max_tokens => true,
                            else => false,
                        }
                    else
                        false;
                    if (!sticky) self.turn_ends = maybe_reason;
                },
            }

            if (self.turn_ends != null and self.inbox.nextStep().len == 0) {
                // `agent/turn-stopping` may queue next-step input and veto the
                // close; a veto only keeps the turn open with input to run.
                const allowed = if (self.host.can_turn_end) |gate|
                    try gate(self.host.context, self.turn)
                else
                    true;
                if (allowed or self.inbox.nextStep().len == 0) break;
            }
            target = .next_step;
        }

        return self.endTurn(self.turn_ends orelse .completed);
    }

    fn emitEntry(self: *Loop, position: Position, entry: inbox.Entry) !void {
        _ = try self.emit(.{
            .user_message = .{
                .position = position,
                .message = .{
                    .json = entry.data,
                    .source_event_seqs = if (entry.source_event_seqs.len == 0) null else entry.source_event_seqs,
                },
            },
        });
    }

    fn currentHeader(self: *const Loop) request.Header {
        return .{
            .config = .{
                .provider = self.config.provider,
                .model = self.config.model,
                .reasoning_effort = self.config.reasoning_effort,
                .max_tokens = self.config.max_tokens,
            },
            .tools = self.config.tools,
        };
    }

    /// One forced compaction-and-retry after a provider context overflow
    /// (`compaction-basic/src/index.ts:193-235`). `attempt` is 1-based.
    fn retryOverflow(self: *Loop, attempt: *u32, position: Position) anyerror!bool {
        const hook = self.host.compaction orelse return false;
        if (attempt.* - 1 >= hook.max_overflow_retries) return false;
        if (!try hook.overflow(hook.context, self.allocator(), position)) return false;
        attempt.* += 1;
        // A replacement rewrites the surface; the next request must observe a
        // new generation, like dsh's contentGeneration bump.
        self.surface_generation +%= 1;
        return true;
    }

    fn runStep(self: *Loop, position: Position, header_decision: request.HeaderDecision) anyerror!StepResult {
        var accumulator = stream.Accumulator.init(self.allocator());
        defer accumulator.deinit();

        var saw_chunk = false;
        var stream_error: ?anyerror = null;
        var aborted = false;
        var done = false;

        var attempt: u32 = 1;
        var header = header_decision;
        while (true) {
            self.checkpoint = .{};
            if (attempt > 1) {
                // Retry after compaction: the surface changed, so re-decide the
                // header and start a new series (dsh agent.ts:632-667).
                header = self.tracker.beginRequest(
                    self.last_header,
                    self.currentHeader(),
                    self.surface_generation,
                    true,
                );
                if (header.append) self.last_header = header.header;
            }
            const request_seq = try self.emit(.{
                .request_start = .{ .position = position, .attempt = attempt, .header = header },
            });
            if (header.append) self.checkpoint.header_seq = request_seq;

            self.host.provider.begin(self.host.provider.context, .{
                .position = position,
                .attempt = attempt,
                .provider = self.config.provider,
                .model = self.config.model,
                .header = header,
            }) catch |err| {
                if (self.isAborted()) return .aborted;
                if (err == error.ContextLengthExceeded and try self.retryOverflow(&attempt, position))
                    continue;
                try self.emitFailureCloser(position);
                _ = try self.emit(.{ .step_end = position });
                return .{ .failure = .{
                    .message = "provider request failed to start",
                    .code = @errorName(err),
                } };
            };
            self.checkpoint.request_started = true;
            break;
        }
        while (!done) {
            if (self.isAborted()) {
                aborted = true;
                // An abort stops new provider work, but deltas the transport
                // already delivered are pending and must settle: the host
                // draft showed them (native's interruptedReply keeps the same
                // prefix). They are not new stream events; the settlement
                // records them, so no assistant/stream is emitted here.
                while (self.host.provider.next(self.host.provider.context) catch null) |event| {
                    const keep = try accumulator.push(self.now(), event);
                    if (!keep) break;
                }
                break;
            }
            const maybe_event = self.host.provider.next(self.host.provider.context) catch |err| {
                if (self.isAborted()) {
                    aborted = true;
                } else {
                    stream_error = err;
                }
                break;
            };
            const event = maybe_event orelse break;
            _ = try self.emit(.{
                .assistant_stream = .{ .position = position, .attempt = attempt, .event = event },
            });
            switch (event) {
                .chunk, .record => saw_chunk = true,
                .done => done = true,
            }
            const keep = try accumulator.push(self.now(), event);
            if (!keep) done = true;
        }
        if (self.host.provider.cancel) |cancel| cancel(self.host.provider.context);
        if (self.isAborted()) aborted = true;

        if (aborted) {
            accumulator.interrupted = true;
            try self.emitSettlement(position, &accumulator);
            return .aborted;
        }
        if (stream_error) |err| {
            if (!saw_chunk) {
                accumulator.interrupted = true;
                try self.emitSettlement(position, &accumulator);
            } else {
                // dsh agent.ts:462-511: a non-aborted provider failure settles
                // assistant/attempt (never an interrupted message) and
                // rethrows into turn/end {kind:"error"}.
                const id = try std.fmt.allocPrint(
                    self.allocator(),
                    "assistant-{d}-{d}",
                    .{ position.turn, position.step },
                );
                const settlement = try accumulator.settle(id, self.config.provider, self.config.model);
                _ = try self.emit(.{
                    .assistant_attempt = .{ .position = position, .settlement = settlement },
                });
            }
            try self.emitFailureCloser(position);
            _ = try self.emit(.{ .step_end = position });
            return .{ .failure = .{
                .message = "assistant stream failed",
                .code = @errorName(err),
            } };
        }

        const id = try std.fmt.allocPrint(
            self.allocator(),
            "assistant-{d}-{d}",
            .{ position.turn, position.step },
        );
        const settlement = try accumulator.settle(id, self.config.provider, self.config.model);
        try self.emitSettlementValue(position, settlement);

        if (settlement.finish == .max_tokens) {
            _ = try self.emit(.{ .step_end = position });
            return .{ .end = .max_tokens };
        }
        if (settlement.interrupted) {
            _ = try self.emit(.{ .step_end = position });
            return .{ .end = .completed };
        }

        const calls = try self.collectToolCalls(settlement.message.content);
        if (calls.len == 0) {
            _ = try self.emit(.{ .step_end = position });
            return .{ .end = .completed };
        }

        const tools_result = try self.runTools(position, calls);
        switch (tools_result) {
            .aborted => return .aborted,
            .failure => |failure| {
                _ = try self.emit(.{ .step_end = position });
                return .{ .failure = failure };
            },
            .concluded => {
                _ = try self.emit(.{ .step_end = position });
                return .{ .end = .completed };
            },
            .continue_turn => {
                _ = try self.emit(.{ .step_end = position });
                return .{ .end = null };
            },
        }
    }

    fn emitSettlement(self: *Loop, position: Position, accumulator: *stream.Accumulator) !void {
        const id = try std.fmt.allocPrint(
            self.allocator(),
            "assistant-{d}-{d}",
            .{ position.turn, position.step },
        );
        const settlement = try accumulator.settle(id, self.config.provider, self.config.model);
        try self.emitSettlementValue(position, settlement);
    }

    fn emitSettlementValue(self: *Loop, position: Position, settlement: stream.Settlement) !void {
        if (settlement.interrupted and settlement.message.content.len == 0) {
            _ = try self.emit(.{
                .assistant_attempt = .{ .position = position, .settlement = settlement },
            });
        } else {
            _ = try self.emit(.{
                .assistant_message = .{ .position = position, .settlement = settlement },
            });
        }
    }

    /// A provider failure exits the step with user/tool rows as the surface
    /// tail. Junclaw channels require an assistant reply in history, so close
    /// the round with a neutral marker (the provider error text stays with
    /// the host and never enters model context).
    fn emitFailureCloser(self: *Loop, position: Position) !void {
        const arena = self.allocator();
        const blocks = try arena.alloc(types.ContentBlock, 1);
        blocks[0] = .{ .text = failure_closer_text };
        _ = try self.emit(.{ .assistant_closer = .{
            .position = position,
            .message = .{
                .id = try std.fmt.allocPrint(arena, "assistant-{d}-{d}", .{ position.turn, position.step }),
                .role = .assistant,
                .content = blocks,
                .source = .{ .model = .{ .provider = self.config.provider, .model = self.config.model } },
            },
        } });
    }

    fn collectToolCalls(self: *Loop, content: []const types.ContentBlock) ![]const types.ToolCall {
        var calls: std.ArrayListUnmanaged(types.ToolCall) = .empty;
        for (content) |block| switch (block) {
            .tool_call => |call| try calls.append(self.allocator(), call),
            else => {},
        };
        return calls.toOwnedSlice(self.allocator());
    }

    fn runTools(self: *Loop, position: Position, calls: []const types.ToolCall) !ToolsResult {
        const arena_allocator = self.allocator();
        var hooks = ToolHookState{
            .loop = self,
            .position = position,
            .call_seqs = try arena_allocator.alloc(?u64, calls.len),
            .result_seqs = try arena_allocator.alloc(?u64, calls.len),
        };
        @memset(hooks.call_seqs, null);
        @memset(hooks.result_seqs, null);

        var batch = scheduler.schedule(
            arena_allocator,
            calls,
            self.host.classifier,
            self.host.dispatcher,
            .{ .flag = &self.abort_flag },
            .{ .max_parallel = self.config.max_parallel_tools },
            .{
                .context = &hooks,
                .on_dispatch = ToolHookState.onDispatch,
                .on_commit = ToolHookState.onCommit,
            },
        ) catch |err| {
            if (self.isAborted()) return .aborted;
            return .{ .failure = .{
                .message = "tool scheduling failed",
                .code = @errorName(err),
            } };
        };
        defer batch.deinit(arena_allocator);

        if (hooks.err) |err| return err;

        // Results after the last commit (abort synthetics and scheduler
        // recovery) are not behind on_commit. Unstarted calls need their
        // synthetic tool/call first on abort, but not after a scheduler
        // failure (scheduler.zig Batch contract).
        var index = hooks.committed;
        while (index < batch.results.len) : (index += 1) {
            if (batch.aborted and !batch.started[index]) {
                _ = try self.emit(.{
                    .tool_call = .{ .position = position, .call = calls[index] },
                });
            }
            _ = try self.emit(.{
                .tool_result = .{ .position = position, .result = batch.results[index] },
            });
        }

        for (batch.results, 0..) |result, result_index| {
            const contexts = switch (result) {
                .success => |success| success.additional_contexts,
                .failure => |failure| failure.additional_contexts,
            };
            for (contexts) |message| {
                const json = try self.host.serialize_message(
                    self.host.context,
                    arena_allocator,
                    message,
                );
                var seq_buffer: [2]u64 = undefined;
                var seq_count: usize = 0;
                if (hooks.call_seqs[result_index]) |seq| {
                    seq_buffer[seq_count] = seq;
                    seq_count += 1;
                }
                if (hooks.result_seqs[result_index]) |seq| {
                    seq_buffer[seq_count] = seq;
                    seq_count += 1;
                }
                const seqs = if (seq_count == 0)
                    &.{}
                else
                    try arena_allocator.dupe(u64, seq_buffer[0..seq_count]);
                _ = try self.inbox.additionalContext(.{
                    .id = message.id,
                    .data = json,
                    .source_event_seqs = seqs,
                });
            }
        }

        if (batch.aborted or self.isAborted()) return .aborted;
        if (batch.failure) |err| {
            return .{ .failure = .{
                .message = "tool dispatch failed",
                .code = @errorName(err),
            } };
        }
        if (batch.concluded) return .concluded;
        return .continue_turn;
    }
};

// ---------------------------------------------------------------------------
// Tests: deterministic host, no wall clock, no races.

const testing = std.testing;

const RecKind = enum {
    turn_start,
    step_start,
    system_message,
    user_message,
    request_start,
    assistant_stream,
    assistant_message,
    assistant_attempt,
    assistant_closer,
    tool_call,
    tool_result,
    step_end,
    turn_end,
};

const Record = struct {
    kind: RecKind,
    turn: u64 = 0,
    step: u64 = 0,
    text: []const u8 = "",
    interrupted: bool = false,
    finish: ?stream.Finish = null,
    reason: ?types.EndReason = null,
    header_append: bool = false,
    header_reason: ?request.HeaderReason = null,
    header_starts_series: bool = false,
    attempt: u32 = 0,
    call_name: []const u8 = "",
    result_code: ?[]const u8 = null,
    source_seq_count: usize = 0,
};

const Attempt = struct {
    events: []const stream.Event,
    index: usize = 0,
    fail_at: ?usize = null,
    fail_err: anyerror = error.StreamBroken,
};

const Harness = struct {
    const HookOrder = enum { none, pressure, pre_step };

    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    records: std.ArrayListUnmanaged(Record) = .empty,
    attempts: std.ArrayListUnmanaged(Attempt) = .empty,
    requests: std.ArrayListUnmanaged(RequestView) = .empty,
    next_seq: u64 = 0,
    started: usize = 0,
    current: usize = 0,
    cancels: usize = 0,
    pre_calls: usize = 0,
    gate_calls: usize = 0,
    loop: ?*Loop = null,
    system_text: []const u8 = "system prompt",
    system_once: bool = true,
    system_hook: ?*const fn (h: *Harness) void = null,
    system_abort_cause: ?types.AbortCause = null,
    pre_kind: PreStepKind = .enter,
    pre_kind_once: bool = false,
    pre_hook: ?*const fn (h: *Harness) void = null,
    on_event: ?*const fn (h: *Harness, attempt: usize, index: usize) void = null,
    on_start: ?*const fn (h: *Harness) void = null,
    begin_error: ?anyerror = null,
    begin_errors: []const ?anyerror = &.{},
    pressure_calls: usize = 0,
    overflow_calls: usize = 0,
    pressure_compacts: bool = false,
    pressure_error: ?anyerror = null,
    pre_error: ?anyerror = null,
    overflow_compacts: bool = false,
    last_hook: HookOrder = .none,
    dispatches: usize = 0,
    dispatch_hook: ?*const fn (h: *Harness, allocator: Allocator, call: types.ToolCall) anyerror!registry.ToolResult = null,
    parallel: bool = true,
    allow_turn_end: bool = true,
    gate_hook: ?*const fn (h: *Harness) void = null,

    fn init(allocator: Allocator) Harness {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *Harness) void {
        self.records.deinit(self.allocator);
        self.attempts.deinit(self.allocator);
        self.requests.deinit(self.allocator);
        self.arena.deinit();
    }

    fn host(self: *Harness) Host {
        return .{
            .context = self,
            .emit = emitEvent,
            .system_messages = systemMessages,
            .pre_step = preStep,
            .serialize_message = serializeMessage,
            .can_turn_end = canTurnEnd,
            .compaction = .{
                .context = self,
                .pressure = compactionPressure,
                .overflow = compactionOverflow,
                .max_overflow_retries = 1,
            },
            .provider = .{
                .context = self,
                .begin = providerBegin,
                .next = providerNext,
                .cancel = providerCancel,
            },
            .classifier = .{ .context = self, .is_concurrency_safe = classify },
            .dispatcher = .{ .context = self, .dispatch = dispatch },
        };
    }

    fn script(self: *Harness, attempts: []const Attempt) !void {
        try self.attempts.appendSlice(self.allocator, attempts);
    }

    fn attempt(events: []const stream.Event) Attempt {
        return .{ .events = events };
    }

    fn expectKinds(self: *Harness, expected: []const RecKind) !void {
        try testing.expectEqual(expected.len, self.records.items.len);
        for (expected, 0..) |kind, index| {
            try testing.expectEqual(kind, self.records.items[index].kind);
        }
    }

    fn find(self: *Harness, kind: RecKind) ?*Record {
        for (self.records.items) |*record| {
            if (record.kind == kind) return record;
        }
        return null;
    }

    fn count(self: *Harness, kind: RecKind) usize {
        var total: usize = 0;
        for (self.records.items) |record| {
            if (record.kind == kind) total += 1;
        }
        return total;
    }

    fn dup(self: *Harness, text: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, text);
    }
};

fn harnessOf(context: *anyopaque) *Harness {
    return @ptrCast(@alignCast(context));
}

fn emitEvent(context: *anyopaque, event: Event) anyerror!u64 {
    const h = harnessOf(context);
    var record = Record{ .kind = undefined };
    switch (event) {
        .turn_start => |payload| {
            record = .{ .kind = .turn_start, .turn = payload.turn };
        },
        .step_start => |position| {
            record = .{ .kind = .step_start, .turn = position.turn, .step = position.step };
        },
        .system_message => |payload| {
            record = .{
                .kind = .system_message,
                .turn = payload.position.turn,
                .step = payload.position.step,
                .text = try h.dup(payload.message.text),
            };
        },
        .user_message => |payload| {
            record = .{
                .kind = .user_message,
                .turn = payload.position.turn,
                .step = payload.position.step,
                .text = try h.dup(payload.message.json),
                .source_seq_count = if (payload.message.source_event_seqs) |seqs| seqs.len else 0,
            };
        },
        .request_start => |payload| {
            record = .{
                .kind = .request_start,
                .turn = payload.position.turn,
                .step = payload.position.step,
                .header_append = payload.header.append,
                .header_reason = payload.header.reason,
                .header_starts_series = payload.header.starts_series,
                .attempt = payload.attempt,
            };
        },
        .assistant_stream => |payload| {
            record = .{ .kind = .assistant_stream, .turn = payload.position.turn, .step = payload.position.step };
            switch (payload.event) {
                .chunk => |chunk| switch (chunk) {
                    .text_delta => |delta| record.text = try h.dup(delta.text),
                    else => {},
                },
                .done, .record => {},
            }
        },
        .assistant_message => |payload| {
            record = .{
                .kind = .assistant_message,
                .turn = payload.position.turn,
                .step = payload.position.step,
                .interrupted = payload.settlement.interrupted,
                .finish = payload.settlement.finish,
                .text = try h.dup(firstText(payload.settlement.message.content)),
            };
        },
        .assistant_attempt => |payload| {
            record = .{
                .kind = .assistant_attempt,
                .turn = payload.position.turn,
                .step = payload.position.step,
                .interrupted = payload.settlement.interrupted,
                .finish = payload.settlement.finish,
            };
        },
        .assistant_closer => |payload| {
            record = .{
                .kind = .assistant_closer,
                .turn = payload.position.turn,
                .step = payload.position.step,
                .text = try h.dup(firstText(payload.message.content)),
            };
        },
        .tool_call => |payload| {
            record = .{
                .kind = .tool_call,
                .turn = payload.position.turn,
                .step = payload.position.step,
                .call_name = try h.dup(payload.call.name),
            };
        },
        .tool_result => |payload| {
            record = .{
                .kind = .tool_result,
                .turn = payload.position.turn,
                .step = payload.position.step,
                .text = try h.dup(firstText(payload.result.content())),
                .result_code = switch (payload.result) {
                    .failure => |failure| try h.dup(failure.error_info.code),
                    .success => null,
                },
            };
        },
        .step_end => |position| {
            record = .{ .kind = .step_end, .turn = position.turn, .step = position.step };
        },
        .turn_end => |payload| {
            record = .{ .kind = .turn_end, .turn = payload.turn, .reason = payload.reason };
        },
    }
    try h.records.append(h.allocator, record);
    const seq = h.next_seq;
    h.next_seq += 1;
    return seq;
}

fn firstText(content: []const types.ContentBlock) []const u8 {
    for (content) |block| switch (block) {
        .text => |text| return text,
        else => {},
    };
    return "";
}

fn systemMessages(context: *anyopaque, allocator: Allocator, position: Position, out: *std.ArrayListUnmanaged(SystemMessage)) !void {
    const h = harnessOf(context);
    if (h.system_once and position.step != 1) return;
    try out.append(allocator, .{ .id = "s1", .text = h.system_text });
    if (h.system_hook) |hook| hook(h);
    if (h.system_abort_cause) |cause| h.loop.?.abort(cause);
}

fn preStep(
    context: *anyopaque,
    allocator: Allocator,
    position: Position,
    claimed: Claimed,
    out: *std.ArrayListUnmanaged(UserMessage),
) !PreStepDecision {
    _ = allocator;
    _ = position;
    _ = claimed;
    _ = out;
    const h = harnessOf(context);
    h.pre_calls += 1;
    h.last_hook = .pre_step;
    if (h.pre_error) |err| return err;
    if (h.pre_hook) |hook| hook(h);
    const decision = h.pre_kind;
    if (h.pre_kind_once) h.pre_kind = .enter;
    return .{ .kind = decision };
}

fn serializeMessage(context: *anyopaque, allocator: Allocator, message: types.Message) ![]u8 {
    _ = context;
    return std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"text\":\"{s}\"}}",
        .{ message.id, firstText(message.content) },
    );
}

fn canTurnEnd(context: *anyopaque, turn: u64) !bool {
    _ = turn;
    const h = harnessOf(context);
    h.gate_calls += 1;
    if (h.gate_hook) |hook| hook(h);
    return h.allow_turn_end;
}

fn compactionPressure(context: *anyopaque, allocator: Allocator, position: Position) !bool {
    _ = allocator;
    _ = position;
    const h = harnessOf(context);
    h.pressure_calls += 1;
    h.last_hook = .pressure;
    if (h.pressure_error) |err| return err;
    return h.pressure_compacts;
}

fn compactionOverflow(context: *anyopaque, allocator: Allocator, position: Position) !bool {
    _ = allocator;
    _ = position;
    const h = harnessOf(context);
    h.overflow_calls += 1;
    return h.overflow_compacts;
}

fn providerBegin(context: *anyopaque, view: RequestView) !void {
    const h = harnessOf(context);
    try h.requests.append(h.allocator, view);
    h.current = h.started;
    h.started += 1;
    if (h.current < h.begin_errors.len) {
        if (h.begin_errors[h.current]) |err| return err;
    }
    if (h.begin_error) |err| return err;
    if (h.started > h.attempts.items.len) return error.NoScriptedAttempt;
    h.attempts.items[h.current].index = 0;
    if (h.on_start) |hook| hook(h);
}

fn providerNext(context: *anyopaque) !?stream.Event {
    const h = harnessOf(context);
    if (h.current >= h.attempts.items.len) return error.NoScriptedAttempt;
    const attempt = &h.attempts.items[h.current];
    if (attempt.fail_at) |fail_at| {
        if (attempt.index == fail_at) {
            attempt.index += 1;
            return attempt.fail_err;
        }
    }
    if (attempt.index >= attempt.events.len) return null;
    const index = attempt.index;
    attempt.index += 1;
    if (h.on_event) |hook| hook(h, h.current, index);
    return attempt.events[index];
}

fn providerCancel(context: *anyopaque) void {
    const h = harnessOf(context);
    h.cancels += 1;
}

fn classify(context: *anyopaque, call: types.ToolCall) bool {
    _ = call;
    return harnessOf(context).parallel;
}

fn dispatch(
    context: *anyopaque,
    allocator: Allocator,
    call: types.ToolCall,
    signal: scheduler.Signal,
) anyerror!registry.ToolResult {
    _ = signal;
    const h = harnessOf(context);
    h.dispatches += 1;
    if (h.dispatch_hook) |hook| return hook(h, allocator, call);
    return successResult(allocator, "ok");
}

fn successResult(allocator: Allocator, text: []const u8) !registry.ToolResult {
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = try allocator.dupe(u8, text) };
    return .{ .success = .{ .content = content } };
}

fn testConfig() Config {
    return .{ .provider = "test-provider", .model = "test-model" };
}

fn steerText(h: *Harness, loop: *Loop, id: []const u8, text: []const u8) !void {
    const data = try std.fmt.allocPrint(
        h.allocator,
        "{{\"role\":\"user\",\"id\":\"{s}\",\"text\":\"{s}\"}}",
        .{ id, text },
    );
    defer h.allocator.free(data);
    _ = try loop.steer(.{ .id = id, .data = data });
}

fn isTag(reason: types.EndReason, tag: std.meta.Tag(types.EndReason)) bool {
    return std.meta.activeTag(reason) == tag;
}

fn reasonOf(outcome: Outcome) types.EndReason {
    return switch (outcome) {
        .ended => |reason| reason,
        .paused => unexpectedOutcome(),
    };
}

fn unexpectedOutcome() noreturn {
    @panic("expected an ended outcome");
}

fn newLoop(h: *Harness, config: Config) !Loop {
    var arena = std.heap.ArenaAllocator.init(h.allocator);
    errdefer arena.deinit();
    return Loop.init(arena, config, h.host());
}

test "plain turn emits the B6 event order and completes" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    const events = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "hello" } } },
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{Harness.attempt(events)});
    try steerText(&h, &loop, "m1", "hi");

    const outcome = try loop.runTurn();
    try h.expectKinds(&.{
        .turn_start,
        .step_start,
        .system_message,
        .user_message,
        .request_start,
        .assistant_stream,
        .assistant_stream,
        .assistant_message,
        .step_end,
        .turn_end,
    });
    try testing.expectEqualStrings("hello", h.find(.assistant_message).?.text);
    const request_start = h.find(.request_start).?;
    try testing.expect(request_start.header_append);
    try testing.expectEqual(request.HeaderReason.initial, request_start.header_reason.?);
    try testing.expect(isTag(reasonOf(outcome), .completed));
    try testing.expectEqual(@as(usize, 1), h.cancels);
}

test "tool turn schedules the batch and results land in model order" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var config = testConfig();
    config.max_parallel_tools = 1;
    var loop = try newLoop(&h, config);
    h.loop = &loop;
    defer loop.deinit();

    const calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "tool-a", .arguments = "{}" },
    };
    const first = &[_]stream.Event{
        .{ .done = .{ .finish = .tool_calls, .tool_calls = &calls } },
    };
    const second = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "done" } } },
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{ Harness.attempt(first), Harness.attempt(second) });
    try steerText(&h, &loop, "m1", "run a tool");

    const outcome = try loop.runTurn();
    try h.expectKinds(&.{
        .turn_start,
        .step_start,
        .system_message,
        .user_message,
        .request_start,
        .assistant_stream,
        .assistant_message,
        .tool_call,
        .tool_result,
        .step_end,
        .step_start,
        .request_start,
        .assistant_stream,
        .assistant_stream,
        .assistant_message,
        .step_end,
        .turn_end,
    });
    try testing.expectEqualStrings("tool-a", h.find(.tool_call).?.call_name);
    const result = h.find(.tool_result).?;
    try testing.expectEqualStrings("ok", result.text);
    try testing.expect(result.result_code == null);
    try testing.expect(isTag(reasonOf(outcome), .completed));
}

test "tool-continue step clears the completed turn ending" {
    // Regression: turn_ends stayed completed after a tool-continue step, so the turn closed before the model saw tool results.
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.on_event = struct {
        fn hook(harness: *Harness, attempt: usize, index: usize) void {
            if (attempt != 0 or index != 0) return;
            steerText(harness, harness.loop.?, "m-steer", "continue") catch @panic("steer failed");
        }
    }.hook;

    const calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "tool-a", .arguments = "{}" },
    };
    const first = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "first" } } },
        .{ .done = .{ .finish = .stop } },
    };
    const second = &[_]stream.Event{
        .{ .done = .{ .finish = .tool_calls, .tool_calls = &calls } },
    };
    const third = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "after tools" } } },
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{
        Harness.attempt(first),
        Harness.attempt(second),
        Harness.attempt(third),
    });
    try steerText(&h, &loop, "m1", "start");

    const outcome = try loop.runTurn();
    try h.expectKinds(&.{
        .turn_start,
        .step_start,
        .system_message,
        .user_message,
        .request_start,
        .assistant_stream,
        .assistant_stream,
        .assistant_message,
        .step_end,
        .step_start,
        .user_message,
        .request_start,
        .assistant_stream,
        .assistant_message,
        .tool_call,
        .tool_result,
        .step_end,
        .step_start,
        .request_start,
        .assistant_stream,
        .assistant_stream,
        .assistant_message,
        .step_end,
        .turn_end,
    });
    try testing.expectEqual(@as(usize, 3), h.count(.step_start));
    try testing.expectEqual(@as(usize, 1), h.count(.turn_end));
    try testing.expectEqual(@as(usize, 3), h.requests.items.len);
    // The tool result precedes the third request, so the model sees it.
    try testing.expectEqual(@as(u64, 3), h.records.items[18].step);
    try testing.expectEqual(@as(u64, 2), h.find(.tool_result).?.step);
    try testing.expectEqualStrings("ok", h.find(.tool_result).?.text);
    try testing.expect(isTag(reasonOf(outcome), .completed));
}

test "steer and inject arriving mid-stream join the next step only" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.on_event = struct {
        fn hook(harness: *Harness, attempt: usize, index: usize) void {
            if (attempt != 0 or index != 0) return;
            const l = harness.loop.?;
            steerText(harness, l, "m-steer", "steer") catch @panic("steer failed");
            const data = std.fmt.allocPrint(
                harness.allocator,
                "{{\"role\":\"user\",\"id\":\"m-inject\",\"text\":\"inject\"}}",
                .{},
            ) catch @panic("alloc failed");
            defer harness.allocator.free(data);
            _ = l.inject(.{ .id = "m-inject", .data = data }) catch @panic("inject failed");
        }
    }.hook;

    const first = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "first" } } },
        .{ .done = .{ .finish = .stop } },
    };
    const second = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "second" } } },
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{ Harness.attempt(first), Harness.attempt(second) });
    try steerText(&h, &loop, "m1", "start");

    const outcome = try loop.runTurn();
    try h.expectKinds(&.{
        .turn_start,
        .step_start,
        .system_message,
        .user_message,
        .request_start,
        .assistant_stream,
        .assistant_stream,
        .assistant_message,
        .step_end,
        .step_start,
        .user_message,
        .user_message,
        .request_start,
        .assistant_stream,
        .assistant_stream,
        .assistant_message,
        .step_end,
        .turn_end,
    });
    const records = h.records.items;
    try testing.expectEqual(@as(u64, 1), records[3].step);
    try testing.expectEqual(@as(u64, 2), records[9].step);
    try testing.expectEqual(@as(u64, 2), records[10].step);
    try testing.expect(std.mem.indexOf(u8, records[10].text, "steer") != null);
    try testing.expect(std.mem.indexOf(u8, records[11].text, "inject") != null);
    try testing.expect(isTag(reasonOf(outcome), .completed));
}

test "user abort mid-stream keeps the visible prefix and discards pending input" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.on_event = struct {
        fn hook(harness: *Harness, attempt: usize, index: usize) void {
            if (attempt != 0 or index != 0) return;
            const l = harness.loop.?;
            steerText(harness, l, "m-late", "late") catch @panic("steer failed");
            l.abort(.user);
        }
    }.hook;

    const events = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "partial" } } },
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{Harness.attempt(events)});
    try steerText(&h, &loop, "m1", "start");

    const outcome = try loop.runTurn();
    try h.expectKinds(&.{
        .turn_start,
        .step_start,
        .system_message,
        .user_message,
        .request_start,
        .assistant_stream,
        .assistant_message,
        .step_end,
        .turn_end,
    });
    try testing.expect(h.find(.assistant_message).?.interrupted);
    try testing.expectEqualStrings("partial", h.find(.assistant_message).?.text);
    // B10: abort writes no synthetic user message (dsh 0.2.1-rc.2 ground truth).
    try testing.expectEqual(@as(usize, 1), h.count(.user_message));
    try testing.expectEqual(@as(usize, 0), h.count(.assistant_attempt));
    try testing.expect(!loop.inbox.hasPending());
    const reason = reasonOf(outcome);
    try testing.expect(isTag(reason, .aborted));
    try testing.expect(std.meta.activeTag(reason.aborted) == .user);
}

test "abort during a tool batch synthesizes unstarted calls" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var config = testConfig();
    config.max_parallel_tools = 1;
    var loop = try newLoop(&h, config);
    h.loop = &loop;
    defer loop.deinit();

    h.dispatch_hook = struct {
        fn hook(harness: *Harness, allocator: Allocator, call: types.ToolCall) anyerror!registry.ToolResult {
            _ = call;
            harness.loop.?.abort(.user);
            return successResult(allocator, "r1");
        }
    }.hook;

    const calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "tool-a", .arguments = "{}" },
        .{ .id = "call-2", .name = "tool-b", .arguments = "{}" },
    };
    const events = &[_]stream.Event{
        .{ .done = .{ .finish = .tool_calls, .tool_calls = &calls } },
    };
    try h.script(&.{Harness.attempt(events)});
    try steerText(&h, &loop, "m1", "run tools");

    const outcome = try loop.runTurn();
    try h.expectKinds(&.{
        .turn_start,
        .step_start,
        .system_message,
        .user_message,
        .request_start,
        .assistant_stream,
        .assistant_message,
        .tool_call,
        .tool_result,
        .tool_call,
        .tool_result,
        .step_end,
        .turn_end,
    });
    const records = h.records.items;
    try testing.expectEqualStrings("tool-a", records[7].call_name);
    try testing.expectEqualStrings("call-2", "call-2");
    try testing.expectEqualStrings("tool-b", records[9].call_name);
    try testing.expectEqualStrings(scheduler.TOOL_ABORTED_BEFORE_DISPATCH, records[10].result_code.?);
    try testing.expectEqual(@as(usize, 1), h.dispatches);
    // B10: the abort itself adds no user/message between tool results and turn/end.
    try testing.expectEqual(@as(usize, 1), h.count(.user_message));
    try testing.expect(isTag(reasonOf(outcome), .aborted));
}

test "max-tokens is sticky and skips tool calls" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.on_event = struct {
        fn hook(harness: *Harness, attempt: usize, index: usize) void {
            if (attempt != 0 or index != 0) return;
            steerText(harness, harness.loop.?, "m-steer", "continue") catch @panic("steer failed");
        }
    }.hook;

    const calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "tool-a", .arguments = "{}" },
    };
    const first = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "cut" } } },
        .{ .done = .{ .finish = .max_tokens, .tool_calls = &calls } },
    };
    const second = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "more" } } },
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{ Harness.attempt(first), Harness.attempt(second) });
    try steerText(&h, &loop, "m1", "start");

    const outcome = try loop.runTurn();
    try testing.expectEqual(@as(usize, 2), h.count(.step_start));
    try testing.expectEqual(@as(usize, 0), h.count(.tool_call));
    try testing.expectEqual(stream.Finish.max_tokens, h.find(.assistant_message).?.finish.?);
    try testing.expect(isTag(reasonOf(outcome), .max_tokens));
}

test "stream break settles an attempt and ends the turn with an error" {
    // Regression: a non-abort stream break settled an interrupted assistant
    // message and reported the turn completed.
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.on_event = struct {
        fn hook(harness: *Harness, attempt: usize, index: usize) void {
            if (attempt != 0 or index != 0) return;
            steerText(harness, harness.loop.?, "m-resume", "resume") catch @panic("steer failed");
        }
    }.hook;

    const first = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "partial" } } },
    };
    const second = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "full" } } },
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{
        .{ .events = first, .fail_at = 1 },
        Harness.attempt(second),
    });
    try steerText(&h, &loop, "m1", "start");

    const outcome = try loop.runTurn();
    try h.expectKinds(&.{
        .turn_start,
        .step_start,
        .system_message,
        .user_message,
        .request_start,
        .assistant_stream,
        .assistant_attempt,
        .assistant_closer,
        .step_end,
        .turn_end,
    });
    try testing.expect(!h.find(.assistant_attempt).?.interrupted);
    try testing.expectEqual(@as(usize, 0), h.count(.assistant_message));
    try testing.expectEqualStrings(failure_closer_text, h.find(.assistant_closer).?.text);
    try testing.expectEqual(@as(usize, 1), h.requests.items.len);
    const reason = reasonOf(outcome);
    try testing.expect(isTag(reason, .failure));
    try testing.expectEqualStrings("assistant stream failed", reason.failure.message);
    try testing.expectEqualStrings("StreamBroken", reason.failure.code);
}

test "abort before the request boundary writes no partial assistant message" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.system_hook = struct {
        fn hook(harness: *Harness) void {
            harness.loop.?.abort(.{ .hook = "policy" });
        }
    }.hook;

    const events = &[_]stream.Event{
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{Harness.attempt(events)});
    try steerText(&h, &loop, "m1", "start");

    const outcome = try loop.runTurn();
    try h.expectKinds(&.{
        .turn_start,
        .step_start,
        .system_message,
        .step_end,
        .turn_end,
    });
    try testing.expectEqual(@as(usize, 0), h.count(.user_message));
    try testing.expectEqual(@as(usize, 0), h.count(.request_start));
    try testing.expectEqual(@as(usize, 0), h.count(.assistant_stream));
    try testing.expectEqual(@as(usize, 0), h.count(.assistant_message));
    try testing.expectEqual(request.Checkpoint.Phase.abort_before_send, loop.lastCheckpoint().phase());
    try testing.expectEqual(@as(usize, 0), h.requests.items.len);
    const reason = reasonOf(outcome);
    try testing.expect(isTag(reason, .aborted));
    try testing.expectEqualStrings("policy", reason.aborted.hook);
}

test "blocked pre-step closes the turn without a step" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.pre_kind = .reject;
    try steerText(&h, &loop, "m1", "start");

    const outcome = try loop.runTurn();
    try h.expectKinds(&.{
        .turn_start,
        .turn_end,
    });
    try testing.expectEqual(@as(usize, 0), h.count(.step_start));
    try testing.expect(isTag(reasonOf(outcome), .blocked));
}

test "paused claim keeps its inbox token and resumes without duplicate input" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.pre_kind = .pause;
    h.pre_kind_once = true;

    const events = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "hello" } } },
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{Harness.attempt(events)});
    try steerText(&h, &loop, "m1", "start");

    const paused = try loop.runTurn();
    try testing.expect(std.meta.activeTag(paused) == .paused);
    const token = loop.pausedToken() orelse return error.MissingClaimToken;
    try testing.expect(token != 0);
    try h.expectKinds(&.{.turn_start});

    const outcome = try loop.resumeTurn();
    try h.expectKinds(&.{
        .turn_start,
        .step_start,
        .system_message,
        .user_message,
        .request_start,
        .assistant_stream,
        .assistant_stream,
        .assistant_message,
        .step_end,
        .turn_end,
    });
    try testing.expectEqual(@as(usize, 1), h.count(.user_message));
    try testing.expect(isTag(reasonOf(outcome), .completed));
}

test "additional contexts splice into the next step as user messages" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.dispatch_hook = struct {
        fn hook(harness: *Harness, allocator: Allocator, call: types.ToolCall) anyerror!registry.ToolResult {
            _ = harness;
            _ = call;
            const contexts = try allocator.alloc(types.Message, 1);
            const content = try allocator.alloc(types.ContentBlock, 1);
            content[0] = .{ .text = try allocator.dupe(u8, "tool context") };
            contexts[0] = .{
                .id = "ctx-1",
                .role = .user,
                .content = content,
                .source = .user,
            };
            const result_content = try allocator.alloc(types.ContentBlock, 1);
            result_content[0] = .{ .text = try allocator.dupe(u8, "ok") };
            return .{ .success = .{
                .content = result_content,
                .additional_contexts = contexts,
            } };
        }
    }.hook;

    const calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "tool-a", .arguments = "{}" },
    };
    const first = &[_]stream.Event{
        .{ .done = .{ .finish = .tool_calls, .tool_calls = &calls } },
    };
    const second = &[_]stream.Event{
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{ Harness.attempt(first), Harness.attempt(second) });
    try steerText(&h, &loop, "m1", "run a tool");

    const outcome = try loop.runTurn();
    var context_record: ?*Record = null;
    for (h.records.items) |*record| {
        if (record.kind == .user_message and std.mem.indexOf(u8, record.text, "tool context") != null) {
            context_record = record;
        }
    }
    const found = context_record orelse return error.MissingAdditionalContext;
    try testing.expectEqual(@as(u64, 2), found.step);
    try testing.expectEqual(@as(usize, 2), found.source_seq_count);
    try testing.expect(isTag(reasonOf(outcome), .completed));
}

test "64KB input and tool output are released through the moved arena" {
    var pre_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const big = try pre_arena.allocator().alloc(u8, 80 * 1024);
    @memset(big, 'x');

    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var config = testConfig();
    config.max_parallel_tools = 1;
    var loop = Loop.init(pre_arena, config, h.host());
    h.loop = &loop;
    defer loop.deinit();
    try testing.expect(big.len == 80 * 1024);

    h.dispatch_hook = struct {
        fn hook(harness: *Harness, allocator: Allocator, call: types.ToolCall) anyerror!registry.ToolResult {
            _ = harness;
            _ = call;
            const text = try allocator.alloc(u8, 80 * 1024);
            @memset(text, 'y');
            const content = try allocator.alloc(types.ContentBlock, 1);
            content[0] = .{ .text = text };
            return .{ .success = .{ .content = content } };
        }
    }.hook;

    const calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "tool-a", .arguments = "{}" },
    };
    const first = &[_]stream.Event{
        .{ .done = .{ .finish = .tool_calls, .tool_calls = &calls } },
    };
    const second = &[_]stream.Event{
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{ Harness.attempt(first), Harness.attempt(second) });

    const payload = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'u');
    const data = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"role\":\"user\",\"id\":\"big\",\"text\":\"{s}\"}}",
        .{payload},
    );
    defer std.testing.allocator.free(data);
    _ = try loop.steer(.{ .id = "big", .data = data });

    const outcome = try loop.runTurn();
    try testing.expect(isTag(reasonOf(outcome), .completed));
    const result = h.find(.tool_result).?;
    try testing.expectEqual(@as(usize, 80 * 1024), result.text.len);
    try testing.expectEqual(@as(u8, 'y'), result.text[0]);
    try testing.expect(sharedUserPayloadLen(&h) > 64 * 1024);
    try testing.expect(sharedUserPayloadLen(&h) < 64 * 1024 + 128);
}

test "abort before the first chunk settles an assistant attempt" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.on_start = struct {
        fn hook(harness: *Harness) void {
            harness.loop.?.abort(.user);
        }
    }.hook;

    const events = &[_]stream.Event{
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{Harness.attempt(events)});
    try steerText(&h, &loop, "m1", "start");

    const outcome = try loop.runTurn();
    try h.expectKinds(&.{
        .turn_start,
        .step_start,
        .system_message,
        .user_message,
        .request_start,
        .assistant_attempt,
        .step_end,
        .turn_end,
    });
    try testing.expect(h.find(.assistant_attempt).?.interrupted);
    try testing.expectEqual(@as(usize, 1), h.count(.user_message));
    try testing.expectEqual(@as(usize, 0), h.count(.assistant_message));
    try testing.expect(isTag(reasonOf(outcome), .aborted));
}

test "provider start failure ends the turn with a typed error" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.begin_error = error.ProviderDown;
    try steerText(&h, &loop, "m1", "start");

    const outcome = try loop.runTurn();
    try h.expectKinds(&.{
        .turn_start,
        .step_start,
        .system_message,
        .user_message,
        .request_start,
        .assistant_closer,
        .step_end,
        .turn_end,
    });
    const reason = reasonOf(outcome);
    try testing.expect(isTag(reason, .failure));
    try testing.expectEqualStrings("ProviderDown", reason.failure.code);
    try testing.expectEqual(request.Checkpoint.Phase.header_only, loop.lastCheckpoint().phase());
}

test "every P1a abort cause surfaces in turn/end without a synthetic message" {
    const causes = [_]types.AbortCause{
        .{ .user = {} },
        .{ .parent = {} },
        .{ .hook = "policy" },
        .{ .disposed = {} },
        .{ .legacy = {} },
    };
    for (causes) |cause| {
        var h = Harness.init(std.testing.allocator);
        defer h.deinit();
        var loop = try newLoop(&h, testConfig());
        h.loop = &loop;
        defer loop.deinit();

        h.system_abort_cause = cause;
        try steerText(&h, &loop, "m1", "start");

        const outcome = try loop.runTurn();
        try h.expectKinds(&.{
            .turn_start,
            .step_start,
            .system_message,
            .step_end,
            .turn_end,
        });
        try testing.expectEqual(@as(usize, 0), h.count(.user_message));
        const reason = reasonOf(outcome);
        try testing.expect(isTag(reason, .aborted));
        try testing.expectEqual(std.meta.activeTag(cause), std.meta.activeTag(reason.aborted));
        if (std.meta.activeTag(cause) == .hook) {
            try testing.expectEqualStrings("policy", reason.aborted.hook);
        }
    }
}

test "turn-stopping veto with queued next-step input runs another step" {
    // Regression: a false `agent/turn-stopping` gate was ignored, so the turn
    // ended even though the gate had queued next-step input.
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.allow_turn_end = false;
    h.gate_hook = struct {
        fn hook(harness: *Harness) void {
            if (harness.gate_calls == 1) {
                steerText(harness, harness.loop.?, "m-stop", "one more step") catch @panic("steer failed");
            } else {
                harness.allow_turn_end = true;
            }
        }
    }.hook;

    const first = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "one" } } },
        .{ .done = .{ .finish = .stop } },
    };
    const second = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "two" } } },
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{ Harness.attempt(first), Harness.attempt(second) });
    try steerText(&h, &loop, "m1", "start");

    const outcome = try loop.runTurn();
    try testing.expectEqual(@as(usize, 2), h.count(.step_start));
    try testing.expectEqual(@as(usize, 2), h.gate_calls);
    try testing.expectEqual(@as(usize, 2), h.count(.user_message));
    try testing.expect(isTag(reasonOf(outcome), .completed));
}

fn sharedUserPayloadLen(h: *Harness) usize {
    for (h.records.items) |record| {
        if (record.kind == .user_message and std.mem.indexOf(u8, record.text, "\"id\":\"big\"") != null) {
            return record.text.len;
        }
    }
    return 0;
}

test "pre-step pressure hook runs before the host gate and starts a new series" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.pressure_compacts = true;
    const events = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "after compact" } } },
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{Harness.attempt(events)});
    try steerText(&h, &loop, "m1", "hi");

    const outcome = try loop.runTurn();
    try testing.expectEqual(@as(usize, 1), h.pressure_calls);
    try testing.expectEqual(@as(usize, 1), h.pre_calls);
    try testing.expectEqual(Harness.HookOrder.pre_step, h.last_hook);
    const request_start = h.find(.request_start).?;
    try testing.expect(request_start.header_starts_series);
    try testing.expect(isTag(reasonOf(outcome), .completed));
}

test "a failing pressure or pre-step hook releases the claimed inbox batch" {
    // Regression: a hook error returned before the claim was settled, so the
    // claimed entries leaked instead of being released.
    const failures = [_]enum { pressure, pre_step }{ .pressure, .pre_step };
    for (failures) |failure| {
        var h = Harness.init(std.testing.allocator);
        defer h.deinit();
        var loop = try newLoop(&h, testConfig());
        h.loop = &loop;
        defer loop.deinit();

        switch (failure) {
            .pressure => h.pressure_error = error.PressureBroken,
            .pre_step => h.pre_error = error.PreStepBroken,
        }
        try steerText(&h, &loop, "m1", "hi");
        try testing.expectError(
            if (failure == .pressure) error.PressureBroken else error.PreStepBroken,
            loop.runTurn(),
        );
        try testing.expectEqual(@as(usize, 0), h.started);
    }
}

test "context overflow compacts once and retries the request exactly once" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.overflow_compacts = true;
    h.begin_errors = &.{ error.ContextLengthExceeded, null };
    const events = &[_]stream.Event{
        .{ .chunk = .{ .text_delta = .{ .index = 0, .text = "recovered" } } },
        .{ .done = .{ .finish = .stop } },
    };
    try h.script(&.{ Harness.attempt(events), Harness.attempt(events) });
    try steerText(&h, &loop, "m1", "hi");

    const outcome = try loop.runTurn();
    try testing.expectEqual(@as(usize, 1), h.overflow_calls);
    try testing.expectEqual(@as(usize, 2), h.requests.items.len);
    try testing.expectEqual(@as(u32, 1), h.requests.items[0].attempt);
    try testing.expectEqual(@as(u32, 2), h.requests.items[1].attempt);
    var starts: usize = 0;
    for (h.records.items) |record| {
        if (record.kind != .request_start) continue;
        starts += 1;
        if (starts != 2) continue;
        try testing.expectEqual(@as(u32, 2), record.attempt);
        try testing.expectEqual(request.HeaderReason.series, record.header_reason.?);
    }
    try testing.expectEqual(@as(usize, 2), starts);
    try testing.expectEqualStrings("recovered", h.find(.assistant_message).?.text);
    try testing.expect(isTag(reasonOf(outcome), .completed));
}

test "a second overflow after one retry is a typed failure" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();
    var loop = try newLoop(&h, testConfig());
    h.loop = &loop;
    defer loop.deinit();

    h.overflow_compacts = true;
    h.begin_errors = &.{ error.ContextLengthExceeded, error.ContextLengthExceeded };
    try steerText(&h, &loop, "m1", "hi");

    const outcome = try loop.runTurn();
    try testing.expectEqual(@as(usize, 1), h.overflow_calls);
    try testing.expectEqual(@as(usize, 2), h.requests.items.len);
    const reason = reasonOf(outcome);
    try testing.expect(isTag(reason, .failure));
    try testing.expectEqualStrings("ContextLengthExceeded", reason.failure.code);
}
