//! Tool batch scheduler: parallel pool, exclusive barriers, model-order commit
//! and deterministic abort/recovery results (design §1.2 B22/B23, §4.1 P1).
//!
//! Mirrors dsh `packages/core/agent-loop/src/tool-calls.ts:488-680`:
//! parallel calls roll through a pool of `max_parallel` (dsh default 10); an
//! exclusive call — decided before start, so it can be reclassified from its
//! arguments — is a barrier that runs only after the current pool drains and
//! commits; results commit strictly in assistant/model order, never completion
//! order. Abort stops replenishment, drains and commits started calls, then
//! synthesizes `ABORTED_BEFORE_DISPATCH` for calls whose body never started.
//! An internal dispatch failure stops replenishment, drains started calls and
//! synthesizes `TOOL_OUTCOME_UNKNOWN` (started) / `TOOL_NOT_STARTED` (never
//! started) for every call without a committed outcome, using the exact
//! `core/session/src/repair.ts` wording.
//!
//! Concurrency ownership: every worker gets a private arena. The caller's
//! allocator is only reached through `LockedAllocator`, and the arenas are
//! freed only after all workers have been joined (`Batch.deinit`), so the
//! scheduler never hands the caller's step arena to a worker.

const std = @import("std");
const compat = @import("compat");
const registry = @import("registry.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;

/// dsh `constants.ts:6` / `maxParallelToolCalls` default.
pub const DEFAULT_MAX_PARALLEL_TOOL_CALLS: usize = 10;

/// Canonical dsh error codes for synthetic results.
pub const TOOL_ABORTED = "ABORTED";
pub const TOOL_ABORTED_BEFORE_DISPATCH = "ABORTED_BEFORE_DISPATCH";
pub const TOOL_OUTCOME_UNKNOWN = "TOOL_OUTCOME_UNKNOWN";
pub const TOOL_NOT_STARTED = "TOOL_NOT_STARTED";

const aborted_text = "Error: tool call aborted";
const aborted_before_dispatch_text = "Error: tool call aborted before dispatch";

// `CLOSER_TEXT.interrupted` from dsh `core/session/src/repair.ts:15-19`.
const outcome_unknown_text =
    "The tool call was interrupted after it was recorded, but no result was durably recorded. Its outcome is unknown. " ++
    "Decide whether to retry from the tool semantics: retry only if the operation is read-only or idempotent; " ++
    "if it may have side effects, first verify external state or ask the user. Do not retry blindly.";
const not_started_text =
    "The tool call was interrupted before the Harness recorded it as started. Retry it if it is still needed.";

const aborted_content = [_]types.ContentBlock{.{ .text = aborted_text }};
const aborted_before_dispatch_content = [_]types.ContentBlock{.{ .text = aborted_before_dispatch_text }};
const outcome_unknown_content = [_]types.ContentBlock{.{ .text = outcome_unknown_text }};
const not_started_content = [_]types.ContentBlock{.{ .text = not_started_text }};

const aborted_result: registry.ToolResult = .{ .failure = .{
    .error_info = .{ .name = "AbortError", .code = TOOL_ABORTED },
    .content = &aborted_content,
} };
const aborted_before_dispatch_result: registry.ToolResult = .{ .failure = .{
    .error_info = .{ .name = "AbortError", .code = TOOL_ABORTED_BEFORE_DISPATCH },
    .content = &aborted_before_dispatch_content,
} };
const outcome_unknown_result: registry.ToolResult = .{ .failure = .{
    .error_info = .{ .name = "ToolOutcomeUnknownError", .code = TOOL_OUTCOME_UNKNOWN },
    .content = &outcome_unknown_content,
} };
const not_started_result: registry.ToolResult = .{ .failure = .{
    .error_info = .{ .name = "ToolNotStartedError", .code = TOOL_NOT_STARTED },
    .content = &not_started_content,
} };

/// Abort signal shared with dispatchers, so a running tool can stop early.
pub const Signal = struct {
    flag: *const std.atomic.Value(bool),

    pub fn isAborted(self: Signal) bool {
        return self.flag.load(.acquire);
    }
};

/// Fail-closed scheduling classification: only an exact `true` is parallel.
/// Undeclared or throwing classifiers are exclusive in dsh; a Zig callback
/// cannot throw, and a null classifier is treated as exclusive.
pub const Classifier = struct {
    context: *anyopaque,
    is_concurrency_safe: *const fn (context: *anyopaque, call: types.ToolCall) bool,
};

/// Executes one call. `dispatch` runs on a worker thread; `allocator` is that
/// call's private arena and must not be used after it returns. A cancellation-
/// aware body should return `error.Aborted` once `signal` is set; the scheduler
/// then commits the canonical `AbortError`/`ABORTED` result instead of treating
/// it as a scheduler failure.
pub const Dispatcher = struct {
    context: *anyopaque,
    dispatch: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        call: types.ToolCall,
        signal: Signal,
    ) anyerror!registry.ToolResult,
};

/// Caller hooks, all called on the scheduler thread.
pub const Hooks = struct {
    context: ?*anyopaque = null,
    /// Write `tool/call` before the body starts (model order).
    on_dispatch: ?*const fn (context: ?*anyopaque, index: usize, call: types.ToolCall) void = null,
    /// Write `tool/result` when the result commits (strict model order).
    on_commit: ?*const fn (context: ?*anyopaque, index: usize, result: *const registry.ToolResult) void = null,
    /// Called immediately before the scheduler blocks for a completion. It is a
    /// deterministic rendezvous for tests (and an idle telemetry point).
    on_wait: ?*const fn (context: ?*anyopaque) void = null,
};

pub const Options = struct {
    /// dsh `maxParallelToolCalls`, validated to a minimum of 1.
    max_parallel: usize = DEFAULT_MAX_PARALLEL_TOOL_CALLS,
};

pub const ScheduleError = error{ OutOfMemory, InvalidMaxParallel };

/// One result per input call, in model order, plus the flags the owning step
/// needs. Synthetic results never allocate: their content points at
/// module-level constants.
pub const Batch = struct {
    results: []registry.ToolResult,
    /// Whether a `tool/call` was recorded and the body could have run. On
    /// abort, false entries need a synthetic `tool/call` before their
    /// synthetic result (dsh `appendSkippedToolCall`); on scheduler failure,
    /// repair appends only the recovery result.
    started: []bool,
    /// A committed result had `concludesTurn: true`: end the turn after this
    /// batch, do not start another step.
    concluded: bool,
    aborted: bool,
    /// First dispatch failure in model order. The call and every uncommitted
    /// started call carry `TOOL_OUTCOME_UNKNOWN`; calls that never started
    /// carry `TOOL_NOT_STARTED`.
    failure: ?anyerror,

    arenas: []std.heap.ArenaAllocator,
    locked: *LockedAllocator,

    /// Free all results. The results are invalid afterwards; pass the same
    /// allocator that was given to `schedule`.
    pub fn deinit(self: *Batch, allocator: Allocator) void {
        // All workers have been joined by `schedule`; nobody touches the
        // arenas or the locked child allocator anymore.
        for (self.arenas) |*arena| arena.deinit();
        allocator.destroy(self.locked);
        allocator.free(self.arenas);
        allocator.free(self.results);
        allocator.free(self.started);
    }
};

/// Serializes every worker arena allocation through one mutex, so the caller
/// may pass a step arena even though workers allocate concurrently.
const LockedAllocator = struct {
    child: Allocator,
    mutex: compat.sync.Mutex = .{},

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *LockedAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

/// Manual-reset event used for worker-completion wakeups and test gates.
const Event = struct {
    mutex: compat.sync.Mutex = .{},
    condition: compat.sync.Condition = .{},
    signaled: bool = false,

    fn set(self: *Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.signaled = true;
        self.condition.broadcast();
    }

    fn wait(self: *Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.signaled) self.condition.wait(&self.mutex);
    }

    /// Block until set, then consume the signal.
    fn take(self: *Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.signaled) self.condition.wait(&self.mutex);
        self.signaled = false;
    }
};

const State = struct {
    call: types.ToolCall,
    result: ?registry.ToolResult = null,
    failure: ?anyerror = null,
    started: bool = false,
    /// Only the scheduler thread writes this: the completion was observed.
    observed: bool = false,
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
};

fn worker(
    state: *State,
    arena: *std.heap.ArenaAllocator,
    dispatcher: Dispatcher,
    signal: Signal,
    completion: *Event,
) void {
    if (dispatcher.dispatch(dispatcher.context, arena.allocator(), state.call, signal)) |result| {
        state.result = result;
    } else |err| {
        // A tool body reporting cancellation is a committed abort result
        // (dsh AbortError/ABORTED), not a scheduler failure.
        if (err == error.Aborted) {
            state.result = aborted_result;
        } else {
            state.failure = err;
        }
    }
    state.finished.store(true, .release);
    completion.set();
}

fn isParallel(classifier: ?Classifier, call: types.ToolCall) bool {
    const cls = classifier orelse return false;
    return cls.is_concurrency_safe(cls.context, call);
}

/// Start one call on its own worker. Returns a spawn failure, which is a
/// scheduler failure after the `tool/call` point.
fn start(
    state: *State,
    arena: *std.heap.ArenaAllocator,
    index: usize,
    dispatcher: Dispatcher,
    signal: Signal,
    completion: *Event,
    hooks: Hooks,
) ?anyerror {
    if (hooks.on_dispatch) |hook| hook(hooks.context, index, state.call);
    state.thread = std.Thread.spawn(.{}, worker, .{
        state,
        arena,
        dispatcher,
        signal,
        completion,
    }) catch |err| {
        state.failure = err;
        state.finished.store(true, .release);
        state.observed = true; // never counted as in flight
        return err;
    };
    // Only a live worker counts as started; a spawn failure stays
    // TOOL_NOT_STARTED (the tool body never ran).
    state.started = true;
    return null;
}

fn scanSettled(states: []State, in_flight: *usize, failure: *?anyerror) void {
    for (states) |*state| {
        if (!state.started or state.observed) continue;
        if (!state.finished.load(.acquire)) continue;
        state.observed = true;
        std.debug.assert(in_flight.* > 0);
        in_flight.* -= 1;
        if (state.failure) |err| {
            if (failure.* == null) failure.* = err;
        }
    }
}

fn commitReady(
    states: []State,
    results: []registry.ToolResult,
    committed: *usize,
    concluded: *bool,
    failure: *?anyerror,
    hooks: Hooks,
) void {
    while (committed.* < states.len) {
        const state = &states[committed.*];
        if (!state.started) break;
        if (!state.finished.load(.acquire)) break;
        if (state.failure) |err| {
            if (failure.* == null) failure.* = err;
            break;
        }
        const maybe_result = state.result;
        if (maybe_result == null) {
            if (failure.* == null) failure.* = error.SchedulerMissingResult;
            break;
        }
        results[committed.*] = maybe_result.?;
        if (hooks.on_commit) |hook| hook(hooks.context, committed.*, &results[committed.*]);
        switch (maybe_result.?) {
            .success => |success| {
                if (success.concludes_turn) concluded.* = true;
            },
            .failure => {},
        }
        committed.* += 1;
    }
}

/// Schedule one assistant step's tool calls.
///
/// Every input call gets exactly one result in `Batch.results`, in model
/// order: a real committed result, a synthetic abort result, or a conservative
/// recovery result. A dispatch failure is reported via `Batch.failure`, not as
/// a Zig error, so the caller can still write the recovery results.
pub fn schedule(
    allocator: Allocator,
    calls: []const types.ToolCall,
    classifier: ?Classifier,
    dispatcher: Dispatcher,
    signal: Signal,
    options: Options,
    hooks: Hooks,
) ScheduleError!Batch {
    if (options.max_parallel < 1) return error.InvalidMaxParallel;

    const n = calls.len;
    const states = try allocator.alloc(State, n);
    errdefer allocator.free(states);
    const arenas = try allocator.alloc(std.heap.ArenaAllocator, n);
    errdefer allocator.free(arenas);
    const results = try allocator.alloc(registry.ToolResult, n);
    errdefer allocator.free(results);
    const started = try allocator.alloc(bool, n);
    errdefer allocator.free(started);
    const locked = try allocator.create(LockedAllocator);
    errdefer allocator.destroy(locked);
    locked.* = .{ .child = allocator };

    for (calls, 0..) |call, i| {
        states[i] = .{ .call = call };
        arenas[i] = std.heap.ArenaAllocator.init(locked.allocator());
    }

    var completion = Event{};
    var next_to_start: usize = 0;
    var group_start: usize = 0;
    var group_parallel = false;
    var committed: usize = 0;
    var in_flight: usize = 0;
    var aborted = signal.isAborted();
    var failure: ?anyerror = null;
    var concluded = false;

    while (committed < n) {
        if (failure == null and !aborted) {
            // Fill the current parallel pool, or start one exclusive call.
            // A later call reclassified as exclusive remains for the next
            // barrier; the current pool drains and commits first.
            fill: while (next_to_start < n) {
                if (in_flight == 0) {
                    group_start = next_to_start;
                    group_parallel = isParallel(classifier, calls[next_to_start]);
                }
                if (group_parallel) {
                    if (next_to_start > group_start and !isParallel(classifier, calls[next_to_start])) break :fill;
                    if (in_flight >= options.max_parallel) break :fill;
                } else if (in_flight > 0) {
                    break :fill;
                }

                if (signal.isAborted()) {
                    aborted = true;
                    break :fill;
                }
                if (start(
                    &states[next_to_start],
                    &arenas[next_to_start],
                    next_to_start,
                    dispatcher,
                    signal,
                    &completion,
                    hooks,
                )) |spawn_error| {
                    failure = spawn_error;
                    break :fill;
                }
                in_flight += 1;
                next_to_start += 1;
                commitReady(states, results, &committed, &concluded, &failure, hooks);
                if (failure != null) break :fill;
                if (signal.isAborted()) {
                    aborted = true;
                    break :fill;
                }
            }
        }

        if (committed == n) break;
        if (failure != null) break;
        if (aborted and in_flight == 0) break;
        if (in_flight == 0) {
            // Not aborted, no failure, nothing running: all calls were
            // started, so commitReady must be able to finish them.
            if (next_to_start >= n) {
                commitReady(states, results, &committed, &concluded, &failure, hooks);
                if (committed == n) break;
                if (failure == null) failure = error.SchedulerDidNotCommit;
                break;
            }
            continue;
        }

        if (hooks.on_wait) |hook| hook(hooks.context);
        completion.take();
        scanSettled(states, &in_flight, &failure);
        if (failure == null) {
            commitReady(states, results, &committed, &concluded, &failure, hooks);
        }
        if (signal.isAborted()) aborted = true;
    }

    // A dispatch failure stops commits immediately; drain the workers whose
    // results will be replaced by conservative recovery results.
    if (failure != null) {
        while (in_flight > 0) {
            if (hooks.on_wait) |hook| hook(hooks.context);
            completion.take();
            scanSettled(states, &in_flight, &failure);
        }
    }

    for (states) |*state| {
        if (state.thread) |thread| thread.join();
    }

    if (failure != null) {
        for (committed..n) |i| {
            results[i] = if (states[i].started) outcome_unknown_result else not_started_result;
        }
    } else if (aborted) {
        // Started calls were drained and committed above; anything left never
        // had a body, so it needs the replay-valid abort result.
        for (committed..n) |i| {
            results[i] = if (states[i].started) outcome_unknown_result else aborted_before_dispatch_result;
        }
    } else if (committed < n) {
        // Defensive: keep the replay contract (one result per call) if the
        // loop ever exits without a committed outcome for every call.
        failure = error.SchedulerDidNotCommit;
        for (committed..n) |i| {
            results[i] = if (states[i].started) outcome_unknown_result else not_started_result;
        }
    }

    for (states, 0..) |state, i| started[i] = state.started;

    // Results are values; their slices point into `arenas`, which the Batch
    // owns. No state pointer escapes.
    allocator.free(states);

    return .{
        .results = results,
        .started = started,
        .concluded = concluded,
        .aborted = aborted,
        .failure = failure,
        .arenas = arenas,
        .locked = locked,
    };
}

// ---------------------------------------------------------------------------
// Tests
//
// Every concurrency test is deterministic: workers block on explicit events,
// and the scheduler exposes `on_wait`, so the test thread is never racing the
// scheduler. There are no wall-clock assertions and no sleeps.
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestMode = enum { success, fail, abort_error };

const TestCall = struct {
    gate: Event = .{},
    entered: Event = .{},
    mode: TestMode = .success,
    text: []const u8 = "ok",
    big_len: usize = 0,
    concludes_turn: bool = false,
};

const ExecLog = struct {
    allocator: Allocator,
    mutex: compat.sync.Mutex = .{},
    entered: std.ArrayListUnmanaged(usize) = .empty,
    exited: std.ArrayListUnmanaged(usize) = .empty,

    fn deinit(self: *ExecLog) void {
        self.entered.deinit(self.allocator);
        self.exited.deinit(self.allocator);
    }

    fn recordEntered(self: *ExecLog, index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entered.append(self.allocator, index) catch @panic("test allocator failed");
    }

    fn recordExited(self: *ExecLog, index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.exited.append(self.allocator, index) catch @panic("test allocator failed");
    }

    fn enteredCount(self: *ExecLog) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entered.items.len;
    }

    fn exitedAt(self: *ExecLog, index: usize) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.exited.items[index];
    }

    fn exitedCount(self: *ExecLog) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.exited.items.len;
    }
};

const ExecCtx = struct {
    calls: []TestCall,
    ids: []const []const u8,
    log: *ExecLog,

    fn indexOf(self: *ExecCtx, id: []const u8) ?usize {
        for (self.ids, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, id)) return i;
        }
        return null;
    }
};

fn testDispatch(
    context: *anyopaque,
    allocator: Allocator,
    call: types.ToolCall,
    signal: Signal,
) anyerror!registry.ToolResult {
    const self: *ExecCtx = @ptrCast(@alignCast(context));
    const index = self.indexOf(call.id) orelse return error.UnknownTestCall;
    const test_call = &self.calls[index];

    self.log.recordEntered(index);
    test_call.entered.set();
    test_call.gate.wait();
    self.log.recordExited(index);

    // A real abort-aware tool observes the shared signal. The scheduler maps
    // `error.Aborted` to the canonical AbortError/ABORTED result.
    if (signal.isAborted()) return error.Aborted;

    switch (test_call.mode) {
        .fail => return error.TestDispatchFailed,
        .abort_error => return error.Aborted,
        .success => {},
    }

    const text = if (test_call.big_len > 0) blk: {
        const buffer = try allocator.alloc(u8, test_call.big_len);
        @memset(buffer, 'x');
        break :blk buffer;
    } else test_call.text;

    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = text };
    return .{ .success = .{
        .content = content,
        .concludes_turn = test_call.concludes_turn,
    } };
}

const ClassifierCtx = struct {
    ids: []const []const u8,
    parallel: []const bool,
};

fn testClassifier(context: *anyopaque, call: types.ToolCall) bool {
    const self: *ClassifierCtx = @ptrCast(@alignCast(context));
    for (self.ids, 0..) |id, i| {
        if (std.mem.eql(u8, id, call.id)) return self.parallel[i];
    }
    return false;
}

const HookCtx = struct {
    allocator: Allocator,
    mutex: compat.sync.Mutex = .{},
    dispatch_log: std.ArrayListUnmanaged(usize) = .empty,
    commit_log: std.ArrayListUnmanaged(usize) = .empty,
    waiting: Event = .{},
    allow: Event = .{},
    /// Tests turn this off in their cleanup defer so a failed assertion can
    /// never leave the scheduler blocked in `on_wait`.
    rendezvous: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    fn deinit(self: *HookCtx) void {
        self.dispatch_log.deinit(self.allocator);
        self.commit_log.deinit(self.allocator);
    }

    fn onDispatch(context: ?*anyopaque, index: usize, call: types.ToolCall) void {
        _ = call;
        const self: *HookCtx = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.dispatch_log.append(self.allocator, index) catch @panic("test allocator failed");
    }

    fn onCommit(context: ?*anyopaque, index: usize, result: *const registry.ToolResult) void {
        _ = result;
        const self: *HookCtx = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.commit_log.append(self.allocator, index) catch @panic("test allocator failed");
    }

    fn onWait(context: ?*anyopaque) void {
        const self: *HookCtx = @ptrCast(@alignCast(context.?));
        if (!self.rendezvous.load(.acquire)) return;
        self.waiting.set();
        self.allow.take();
    }

    fn dispatchCount(self: *HookCtx) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.dispatch_log.items.len;
    }

    fn dispatchAt(self: *HookCtx, index: usize) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.dispatch_log.items[index];
    }

    fn commitCount(self: *HookCtx) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.commit_log.items.len;
    }

    fn commitAt(self: *HookCtx, index: usize) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.commit_log.items[index];
    }

    fn expectWaiting(self: *HookCtx) void {
        self.waiting.take();
    }

    fn release(self: *HookCtx) void {
        self.allow.set();
    }
};

const RunCtx = struct {
    allocator: Allocator,
    calls: []const types.ToolCall,
    classifier: ?Classifier,
    dispatcher: Dispatcher,
    signal: Signal,
    options: Options,
    hooks: Hooks,
    batch: ?Batch = null,
    err: ?anyerror = null,

    fn run(self: *RunCtx) void {
        self.batch = schedule(
            self.allocator,
            self.calls,
            self.classifier,
            self.dispatcher,
            self.signal,
            self.options,
            self.hooks,
        ) catch |err| {
            self.err = err;
            return;
        };
    }
};

fn resultText(result: registry.ToolResult) ?[]const u8 {
    const content = result.content();
    if (content.len == 0) return null;
    return switch (content[0]) {
        .text => |text| text,
        else => null,
    };
}

fn resultFailureName(result: registry.ToolResult) []const u8 {
    return switch (result) {
        .failure => |failure| failure.error_info.name,
        .success => "",
    };
}

fn resultFailureCode(result: registry.ToolResult) []const u8 {
    return switch (result) {
        .failure => |failure| failure.error_info.code,
        .success => "",
    };
}

test "scheduler rejects a parallel pool below one" {
    var abort_flag = std.atomic.Value(bool).init(false);
    const result = schedule(
        testing.allocator,
        &.{},
        null,
        .{ .context = undefined, .dispatch = unusedDispatch },
        .{ .flag = &abort_flag },
        .{ .max_parallel = 0 },
        .{},
    );
    try testing.expectError(error.InvalidMaxParallel, result);
}

fn unusedDispatch(
    context: *anyopaque,
    allocator: Allocator,
    call: types.ToolCall,
    signal: Signal,
) anyerror!registry.ToolResult {
    _ = context;
    _ = allocator;
    _ = call;
    _ = signal;
    return error.UnusedDispatcher;
}

test "scheduler accepts an empty call batch" {
    var abort_flag = std.atomic.Value(bool).init(false);
    var batch = try schedule(
        testing.allocator,
        &.{},
        null,
        .{ .context = undefined, .dispatch = unusedDispatch },
        .{ .flag = &abort_flag },
        .{},
        .{},
    );
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), batch.results.len);
    try testing.expectEqual(@as(usize, 0), batch.started.len);
    try testing.expect(!batch.aborted);
    try testing.expect(batch.failure == null);
}

test "default parallel pool is ten" {
    try testing.expectEqual(@as(usize, 10), DEFAULT_MAX_PARALLEL_TOOL_CALLS);
    try testing.expectEqual(@as(usize, 10), (Options{}).max_parallel);
}

test "parallel pool never exceeds max_parallel and rolls after a commit" {
    const allocator = testing.allocator;
    const ids = [_][]const u8{ "p0", "p1", "p2" };
    var calls: [3]types.ToolCall = undefined;
    for (&calls, 0..) |*call, i| call.* = .{ .id = ids[i], .name = "test", .arguments = "{}" };
    var test_calls = [_]TestCall{.{}} ** 3;
    for (&test_calls, 0..) |*test_call, i| test_call.text = ids[i];
    var log = ExecLog{ .allocator = allocator };
    defer log.deinit();
    var exec = ExecCtx{ .calls = &test_calls, .ids = &ids, .log = &log };
    const parallel = [_]bool{ true, true, true };
    var classifier_ctx = ClassifierCtx{ .ids = &ids, .parallel = &parallel };
    var hook = HookCtx{ .allocator = allocator };
    defer hook.deinit();
    var abort_flag = std.atomic.Value(bool).init(false);

    var run = RunCtx{
        .allocator = allocator,
        .calls = &calls,
        .classifier = .{ .context = &classifier_ctx, .is_concurrency_safe = testClassifier },
        .dispatcher = .{ .context = &exec, .dispatch = testDispatch },
        .signal = .{ .flag = &abort_flag },
        .options = .{ .max_parallel = 2 },
        .hooks = .{
            .context = &hook,
            .on_dispatch = HookCtx.onDispatch,
            .on_commit = HookCtx.onCommit,
            .on_wait = HookCtx.onWait,
        },
    };
    var runner: ?std.Thread = try std.Thread.spawn(.{}, RunCtx.run, .{&run});
    defer {
        hook.rendezvous.store(false, .release);
        hook.allow.set();
        for (&test_calls) |*test_call| test_call.gate.set();
        if (runner) |thread| thread.join();
        runner = null;
        if (run.batch) |*batch| {
            batch.deinit(allocator);
            run.batch = null;
        }
    }

    // Initial fill: exactly two dispatches, the pool limit.
    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 2), hook.dispatchCount());
    try testing.expectEqual(@as(usize, 0), hook.commitCount());
    hook.release();

    // Completing p0 commits it and replenishes the pool with p2.
    test_calls[0].gate.set();
    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 3), hook.dispatchCount());
    try testing.expectEqual(@as(usize, 1), hook.commitCount());
    try testing.expectEqual(@as(usize, 0), hook.commitAt(0));
    hook.release();

    // The pool is full again; p1's completion does not dispatch anything new.
    test_calls[1].gate.set();
    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 3), hook.dispatchCount());
    try testing.expectEqual(@as(usize, 2), hook.commitCount());
    try testing.expectEqual(@as(usize, 1), hook.commitAt(1));
    hook.release();

    test_calls[2].gate.set();
    runner.?.join();
    runner = null;

    try testing.expect(run.err == null);
    const batch = &run.batch.?;
    try testing.expectEqual(@as(usize, 3), batch.results.len);
    for (batch.results, 0..) |result, i| {
        try testing.expectEqualStrings(ids[i], resultText(result).?);
    }
    try testing.expect(!batch.aborted);
    try testing.expect(batch.failure == null);
}

test "max_parallel one serializes calls deterministically" {
    const allocator = testing.allocator;
    const ids = [_][]const u8{ "p0", "p1" };
    var calls: [2]types.ToolCall = undefined;
    for (&calls, 0..) |*call, i| call.* = .{ .id = ids[i], .name = "test", .arguments = "{}" };
    var test_calls = [_]TestCall{.{}} ** 2;
    for (&test_calls, 0..) |*test_call, i| test_call.text = ids[i];
    var log = ExecLog{ .allocator = allocator };
    defer log.deinit();
    var exec = ExecCtx{ .calls = &test_calls, .ids = &ids, .log = &log };
    const parallel = [_]bool{ true, true };
    var classifier_ctx = ClassifierCtx{ .ids = &ids, .parallel = &parallel };
    var hook = HookCtx{ .allocator = allocator };
    defer hook.deinit();
    var abort_flag = std.atomic.Value(bool).init(false);

    var run = RunCtx{
        .allocator = allocator,
        .calls = &calls,
        .classifier = .{ .context = &classifier_ctx, .is_concurrency_safe = testClassifier },
        .dispatcher = .{ .context = &exec, .dispatch = testDispatch },
        .signal = .{ .flag = &abort_flag },
        .options = .{ .max_parallel = 1 },
        .hooks = .{
            .context = &hook,
            .on_dispatch = HookCtx.onDispatch,
            .on_commit = HookCtx.onCommit,
            .on_wait = HookCtx.onWait,
        },
    };
    var runner: ?std.Thread = try std.Thread.spawn(.{}, RunCtx.run, .{&run});
    defer {
        hook.rendezvous.store(false, .release);
        hook.allow.set();
        for (&test_calls) |*test_call| test_call.gate.set();
        if (runner) |thread| thread.join();
        runner = null;
        if (run.batch) |*batch| {
            batch.deinit(allocator);
            run.batch = null;
        }
    }

    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 1), hook.dispatchCount());
    hook.release();

    test_calls[0].gate.set();
    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 2), hook.dispatchCount());
    try testing.expectEqual(@as(usize, 1), hook.commitCount());
    hook.release();

    test_calls[1].gate.set();
    runner.?.join();
    runner = null;

    try testing.expect(run.err == null);
    const batch = &run.batch.?;
    try testing.expectEqual(@as(usize, 2), hook.commitCount());
    try testing.expectEqualStrings(ids[0], resultText(batch.results[0]).?);
    try testing.expectEqualStrings(ids[1], resultText(batch.results[1]).?);
}

test "exclusive call is a barrier behind the committed pool" {
    const allocator = testing.allocator;
    const ids = [_][]const u8{ "p0", "p1", "exclusive", "p3" };
    var calls: [4]types.ToolCall = undefined;
    for (&calls, 0..) |*call, i| call.* = .{ .id = ids[i], .name = "test", .arguments = "{}" };
    var test_calls = [_]TestCall{.{}} ** 4;
    for (&test_calls, 0..) |*test_call, i| test_call.text = ids[i];
    var log = ExecLog{ .allocator = allocator };
    defer log.deinit();
    var exec = ExecCtx{ .calls = &test_calls, .ids = &ids, .log = &log };
    const parallel = [_]bool{ true, true, false, true };
    var classifier_ctx = ClassifierCtx{ .ids = &ids, .parallel = &parallel };
    var hook = HookCtx{ .allocator = allocator };
    defer hook.deinit();
    var abort_flag = std.atomic.Value(bool).init(false);

    var run = RunCtx{
        .allocator = allocator,
        .calls = &calls,
        .classifier = .{ .context = &classifier_ctx, .is_concurrency_safe = testClassifier },
        .dispatcher = .{ .context = &exec, .dispatch = testDispatch },
        .signal = .{ .flag = &abort_flag },
        .options = .{},
        .hooks = .{
            .context = &hook,
            .on_dispatch = HookCtx.onDispatch,
            .on_commit = HookCtx.onCommit,
            .on_wait = HookCtx.onWait,
        },
    };
    var runner: ?std.Thread = try std.Thread.spawn(.{}, RunCtx.run, .{&run});
    defer {
        hook.rendezvous.store(false, .release);
        hook.allow.set();
        for (&test_calls) |*test_call| test_call.gate.set();
        if (runner) |thread| thread.join();
        runner = null;
        if (run.batch) |*batch| {
            batch.deinit(allocator);
            run.batch = null;
        }
    }

    // p0 and p1 fill the pool; the exclusive call is not dispatched.
    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 2), hook.dispatchCount());
    try testing.expectEqual(@as(usize, 0), hook.dispatchAt(0));
    try testing.expectEqual(@as(usize, 1), hook.dispatchAt(1));
    hook.release();

    // p0 commits, but p1 keeps the barrier closed.
    test_calls[0].gate.set();
    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 2), hook.dispatchCount());
    try testing.expectEqual(@as(usize, 1), hook.commitCount());
    try testing.expectEqual(@as(usize, 0), hook.commitAt(0));
    hook.release();

    // Only after p1 commits does the exclusive call start, alone.
    test_calls[1].gate.set();
    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 3), hook.dispatchCount());
    try testing.expectEqual(@as(usize, 2), hook.dispatchAt(2));
    try testing.expectEqual(@as(usize, 2), hook.commitCount());
    try testing.expectEqual(@as(usize, 1), hook.commitAt(1));
    hook.release();

    test_calls[2].gate.set();
    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 4), hook.dispatchCount());
    try testing.expectEqual(@as(usize, 3), hook.commitCount());
    try testing.expectEqual(@as(usize, 2), hook.commitAt(2));
    hook.release();

    test_calls[3].gate.set();
    runner.?.join();
    runner = null;

    try testing.expect(run.err == null);
    const batch = &run.batch.?;
    try testing.expectEqual(@as(usize, 4), hook.commitCount());
    try testing.expectEqual(@as(usize, 3), hook.commitAt(3));
    for (batch.results, 0..) |result, i| {
        try testing.expectEqualStrings(ids[i], resultText(result).?);
    }
}

test "results commit in model order even when later calls finish first" {
    const allocator = testing.allocator;
    const ids = [_][]const u8{ "p0", "p1" };
    var calls: [2]types.ToolCall = undefined;
    for (&calls, 0..) |*call, i| call.* = .{ .id = ids[i], .name = "test", .arguments = "{}" };
    var test_calls = [_]TestCall{.{}} ** 2;
    for (&test_calls, 0..) |*test_call, i| test_call.text = ids[i];
    var log = ExecLog{ .allocator = allocator };
    defer log.deinit();
    var exec = ExecCtx{ .calls = &test_calls, .ids = &ids, .log = &log };
    const parallel = [_]bool{ true, true };
    var classifier_ctx = ClassifierCtx{ .ids = &ids, .parallel = &parallel };
    var hook = HookCtx{ .allocator = allocator };
    defer hook.deinit();
    var abort_flag = std.atomic.Value(bool).init(false);

    var run = RunCtx{
        .allocator = allocator,
        .calls = &calls,
        .classifier = .{ .context = &classifier_ctx, .is_concurrency_safe = testClassifier },
        .dispatcher = .{ .context = &exec, .dispatch = testDispatch },
        .signal = .{ .flag = &abort_flag },
        .options = .{},
        .hooks = .{
            .context = &hook,
            .on_dispatch = HookCtx.onDispatch,
            .on_commit = HookCtx.onCommit,
            .on_wait = HookCtx.onWait,
        },
    };
    var runner: ?std.Thread = try std.Thread.spawn(.{}, RunCtx.run, .{&run});
    defer {
        hook.rendezvous.store(false, .release);
        hook.allow.set();
        for (&test_calls) |*test_call| test_call.gate.set();
        if (runner) |thread| thread.join();
        runner = null;
        if (run.batch) |*batch| {
            batch.deinit(allocator);
            run.batch = null;
        }
    }

    hook.expectWaiting();
    hook.release();

    // p1 finishes before p0, but its result cannot commit yet.
    test_calls[1].gate.set();
    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 0), hook.commitCount());
    try testing.expectEqual(@as(usize, 1), log.exitedCount());
    try testing.expectEqual(@as(usize, 1), log.exitedAt(0));
    hook.release();

    test_calls[0].gate.set();
    runner.?.join();
    runner = null;

    try testing.expect(run.err == null);
    try testing.expectEqual(@as(usize, 2), hook.commitCount());
    try testing.expectEqual(@as(usize, 0), hook.commitAt(0));
    try testing.expectEqual(@as(usize, 1), hook.commitAt(1));
    try testing.expectEqual(@as(usize, 1), log.exitedAt(0));
    try testing.expectEqual(@as(usize, 0), log.exitedAt(1));

    const batch = &run.batch.?;
    try testing.expectEqualStrings(ids[0], resultText(batch.results[0]).?);
    try testing.expectEqualStrings(ids[1], resultText(batch.results[1]).?);
}

test "abort drains the started call and synthesizes ABORTED_BEFORE_DISPATCH" {
    const allocator = testing.allocator;
    const ids = [_][]const u8{ "started", "skipped" };
    var calls: [2]types.ToolCall = undefined;
    for (&calls, 0..) |*call, i| call.* = .{ .id = ids[i], .name = "test", .arguments = "{}" };
    var test_calls = [_]TestCall{.{}} ** 2;
    var log = ExecLog{ .allocator = allocator };
    defer log.deinit();
    var exec = ExecCtx{ .calls = &test_calls, .ids = &ids, .log = &log };
    const parallel = [_]bool{ true, true };
    var classifier_ctx = ClassifierCtx{ .ids = &ids, .parallel = &parallel };
    var hook = HookCtx{ .allocator = allocator };
    defer hook.deinit();
    var abort_flag = std.atomic.Value(bool).init(false);

    var run = RunCtx{
        .allocator = allocator,
        .calls = &calls,
        .classifier = .{ .context = &classifier_ctx, .is_concurrency_safe = testClassifier },
        .dispatcher = .{ .context = &exec, .dispatch = testDispatch },
        .signal = .{ .flag = &abort_flag },
        .options = .{ .max_parallel = 1 },
        .hooks = .{
            .context = &hook,
            .on_dispatch = HookCtx.onDispatch,
            .on_commit = HookCtx.onCommit,
            .on_wait = HookCtx.onWait,
        },
    };
    var runner: ?std.Thread = try std.Thread.spawn(.{}, RunCtx.run, .{&run});
    defer {
        hook.rendezvous.store(false, .release);
        hook.allow.set();
        for (&test_calls) |*test_call| test_call.gate.set();
        if (runner) |thread| thread.join();
        runner = null;
        if (run.batch) |*batch| {
            batch.deinit(allocator);
            run.batch = null;
        }
    }

    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 1), hook.dispatchCount());
    hook.release();

    // Abort while the first body is blocked; it must still write a result.
    abort_flag.store(true, .release);
    test_calls[0].gate.set();
    runner.?.join();
    runner = null;

    try testing.expect(run.err == null);
    const batch = &run.batch.?;
    try testing.expect(batch.aborted);
    try testing.expect(batch.failure == null);
    try testing.expectEqual(@as(usize, 1), hook.dispatchCount());
    try testing.expect(batch.started[0]);
    try testing.expect(!batch.started[1]);
    try testing.expectEqualStrings("AbortError", resultFailureName(batch.results[0]));
    try testing.expectEqualStrings(TOOL_ABORTED, resultFailureCode(batch.results[0]));
    try testing.expectEqualStrings(aborted_text, resultText(batch.results[0]).?);
    try testing.expectEqualStrings("AbortError", resultFailureName(batch.results[1]));
    try testing.expectEqualStrings(TOOL_ABORTED_BEFORE_DISPATCH, resultFailureCode(batch.results[1]));
    try testing.expectEqualStrings(aborted_before_dispatch_text, resultText(batch.results[1]).?);
}

test "abort before the first dispatch synthesizes every result" {
    const allocator = testing.allocator;
    const ids = [_][]const u8{ "s0", "s1" };
    var calls: [2]types.ToolCall = undefined;
    for (&calls, 0..) |*call, i| call.* = .{ .id = ids[i], .name = "test", .arguments = "{}" };
    var test_calls = [_]TestCall{.{}} ** 2;
    var log = ExecLog{ .allocator = allocator };
    defer log.deinit();
    var exec = ExecCtx{ .calls = &test_calls, .ids = &ids, .log = &log };
    const parallel = [_]bool{ true, true };
    var classifier_ctx = ClassifierCtx{ .ids = &ids, .parallel = &parallel };
    var hook = HookCtx{ .allocator = allocator };
    defer hook.deinit();
    var abort_flag = std.atomic.Value(bool).init(true);

    var run = RunCtx{
        .allocator = allocator,
        .calls = &calls,
        .classifier = .{ .context = &classifier_ctx, .is_concurrency_safe = testClassifier },
        .dispatcher = .{ .context = &exec, .dispatch = testDispatch },
        .signal = .{ .flag = &abort_flag },
        .options = .{},
        .hooks = .{
            .context = &hook,
            .on_dispatch = HookCtx.onDispatch,
            .on_commit = HookCtx.onCommit,
            .on_wait = HookCtx.onWait,
        },
    };
    var runner: ?std.Thread = try std.Thread.spawn(.{}, RunCtx.run, .{&run});
    defer {
        if (runner) |thread| thread.join();
        runner = null;
        if (run.batch) |*batch| {
            batch.deinit(allocator);
            run.batch = null;
        }
    }

    runner.?.join();
    runner = null;

    try testing.expect(run.err == null);
    const batch = &run.batch.?;
    try testing.expect(batch.aborted);
    try testing.expectEqual(@as(usize, 0), hook.dispatchCount());
    for (batch.results) |result| {
        try testing.expectEqualStrings("AbortError", resultFailureName(result));
        try testing.expectEqualStrings(TOOL_ABORTED_BEFORE_DISPATCH, resultFailureCode(result));
    }
    try testing.expect(!batch.started[0]);
    try testing.expect(!batch.started[1]);
}

test "dispatch failure drains started calls and writes recovery results" {
    const allocator = testing.allocator;
    const ids = [_][]const u8{ "ok", "failed", "unstarted" };
    var calls: [3]types.ToolCall = undefined;
    for (&calls, 0..) |*call, i| call.* = .{ .id = ids[i], .name = "test", .arguments = "{}" };
    var test_calls = [_]TestCall{.{}} ** 3;
    test_calls[1].mode = .fail;
    var log = ExecLog{ .allocator = allocator };
    defer log.deinit();
    var exec = ExecCtx{ .calls = &test_calls, .ids = &ids, .log = &log };
    const parallel = [_]bool{ true, true, true };
    var classifier_ctx = ClassifierCtx{ .ids = &ids, .parallel = &parallel };
    var hook = HookCtx{ .allocator = allocator };
    defer hook.deinit();
    var abort_flag = std.atomic.Value(bool).init(false);

    var run = RunCtx{
        .allocator = allocator,
        .calls = &calls,
        .classifier = .{ .context = &classifier_ctx, .is_concurrency_safe = testClassifier },
        .dispatcher = .{ .context = &exec, .dispatch = testDispatch },
        .signal = .{ .flag = &abort_flag },
        .options = .{ .max_parallel = 1 },
        .hooks = .{
            .context = &hook,
            .on_dispatch = HookCtx.onDispatch,
            .on_commit = HookCtx.onCommit,
            .on_wait = HookCtx.onWait,
        },
    };
    var runner: ?std.Thread = try std.Thread.spawn(.{}, RunCtx.run, .{&run});
    defer {
        hook.rendezvous.store(false, .release);
        hook.allow.set();
        for (&test_calls) |*test_call| test_call.gate.set();
        if (runner) |thread| thread.join();
        runner = null;
        if (run.batch) |*batch| {
            batch.deinit(allocator);
            run.batch = null;
        }
    }

    hook.expectWaiting();
    hook.release();
    test_calls[0].gate.set();

    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 2), hook.dispatchCount());
    try testing.expectEqual(@as(usize, 1), hook.commitCount());
    hook.release();
    test_calls[1].gate.set();

    runner.?.join();
    runner = null;

    try testing.expect(run.err == null);
    const batch = &run.batch.?;
    try testing.expect(batch.failure != null);
    try testing.expect(batch.failure.? == error.TestDispatchFailed);
    try testing.expect(!batch.aborted);
    try testing.expect(batch.started[0]);
    try testing.expect(batch.started[1]);
    try testing.expect(!batch.started[2]);
    try testing.expectEqual(@as(usize, 2), hook.dispatchCount());

    // Committed prefix keeps its real result.
    try testing.expectEqualStrings(ids[0], resultText(batch.results[0]).?);
    // Started but uncommitted: conservative unknown-outcome recovery.
    try testing.expectEqualStrings("ToolOutcomeUnknownError", resultFailureName(batch.results[1]));
    try testing.expectEqualStrings(TOOL_OUTCOME_UNKNOWN, resultFailureCode(batch.results[1]));
    try testing.expectEqualStrings(outcome_unknown_text, resultText(batch.results[1]).?);
    // Never started: retryable not-started recovery.
    try testing.expectEqualStrings("ToolNotStartedError", resultFailureName(batch.results[2]));
    try testing.expectEqualStrings(TOOL_NOT_STARTED, resultFailureCode(batch.results[2]));
    try testing.expectEqualStrings(not_started_text, resultText(batch.results[2]).?);
    // Only the successful prefix committed.
    try testing.expectEqual(@as(usize, 1), hook.commitCount());
}

test "dispatch failure while another call is running does not commit it" {
    const allocator = testing.allocator;
    const ids = [_][]const u8{ "running", "failed", "unstarted" };
    var calls: [3]types.ToolCall = undefined;
    for (&calls, 0..) |*call, i| call.* = .{ .id = ids[i], .name = "test", .arguments = "{}" };
    var test_calls = [_]TestCall{.{}} ** 3;
    test_calls[1].mode = .fail;
    var log = ExecLog{ .allocator = allocator };
    defer log.deinit();
    var exec = ExecCtx{ .calls = &test_calls, .ids = &ids, .log = &log };
    const parallel = [_]bool{ true, true, true };
    var classifier_ctx = ClassifierCtx{ .ids = &ids, .parallel = &parallel };
    var hook = HookCtx{ .allocator = allocator };
    defer hook.deinit();
    var abort_flag = std.atomic.Value(bool).init(false);

    var run = RunCtx{
        .allocator = allocator,
        .calls = &calls,
        .classifier = .{ .context = &classifier_ctx, .is_concurrency_safe = testClassifier },
        .dispatcher = .{ .context = &exec, .dispatch = testDispatch },
        .signal = .{ .flag = &abort_flag },
        .options = .{ .max_parallel = 2 },
        .hooks = .{
            .context = &hook,
            .on_dispatch = HookCtx.onDispatch,
            .on_commit = HookCtx.onCommit,
            .on_wait = HookCtx.onWait,
        },
    };
    var runner: ?std.Thread = try std.Thread.spawn(.{}, RunCtx.run, .{&run});
    defer {
        hook.rendezvous.store(false, .release);
        hook.allow.set();
        for (&test_calls) |*test_call| test_call.gate.set();
        if (runner) |thread| thread.join();
        runner = null;
        if (run.batch) |*batch| {
            batch.deinit(allocator);
            run.batch = null;
        }
    }

    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 2), hook.dispatchCount());
    hook.release();

    // The second call fails while the first is still blocked. The scheduler
    // must stop, drain the first, and commit neither.
    test_calls[1].gate.set();
    hook.expectWaiting();
    try testing.expectEqual(@as(usize, 0), hook.commitCount());
    hook.release();
    test_calls[0].gate.set();

    runner.?.join();
    runner = null;

    try testing.expect(run.err == null);
    const batch = &run.batch.?;
    try testing.expect(batch.failure != null);
    try testing.expectEqual(@as(usize, 0), hook.commitCount());
    try testing.expect(batch.started[0]);
    try testing.expect(batch.started[1]);
    try testing.expect(!batch.started[2]);
    try testing.expectEqualStrings(TOOL_OUTCOME_UNKNOWN, resultFailureCode(batch.results[0]));
    try testing.expectEqualStrings(TOOL_OUTCOME_UNKNOWN, resultFailureCode(batch.results[1]));
    try testing.expectEqualStrings(TOOL_NOT_STARTED, resultFailureCode(batch.results[2]));
}

test "concludesTurn marks the batch for early turn close" {
    const allocator = testing.allocator;
    const ids = [_][]const u8{ "goal", "after" };
    var calls: [2]types.ToolCall = undefined;
    for (&calls, 0..) |*call, i| call.* = .{ .id = ids[i], .name = "test", .arguments = "{}" };
    var test_calls = [_]TestCall{.{}} ** 2;
    test_calls[0].concludes_turn = true;
    var log = ExecLog{ .allocator = allocator };
    defer log.deinit();
    var exec = ExecCtx{ .calls = &test_calls, .ids = &ids, .log = &log };
    const parallel = [_]bool{ true, true };
    var classifier_ctx = ClassifierCtx{ .ids = &ids, .parallel = &parallel };
    var hook = HookCtx{ .allocator = allocator };
    defer hook.deinit();
    var abort_flag = std.atomic.Value(bool).init(false);

    var run = RunCtx{
        .allocator = allocator,
        .calls = &calls,
        .classifier = .{ .context = &classifier_ctx, .is_concurrency_safe = testClassifier },
        .dispatcher = .{ .context = &exec, .dispatch = testDispatch },
        .signal = .{ .flag = &abort_flag },
        .options = .{},
        .hooks = .{
            .context = &hook,
            .on_dispatch = HookCtx.onDispatch,
            .on_commit = HookCtx.onCommit,
            .on_wait = HookCtx.onWait,
        },
    };
    var runner: ?std.Thread = try std.Thread.spawn(.{}, RunCtx.run, .{&run});
    defer {
        hook.rendezvous.store(false, .release);
        hook.allow.set();
        for (&test_calls) |*test_call| test_call.gate.set();
        if (runner) |thread| thread.join();
        runner = null;
        if (run.batch) |*batch| {
            batch.deinit(allocator);
            run.batch = null;
        }
    }

    hook.expectWaiting();
    // One handshake is enough: a second onWait means a worker is still
    // running, and the gates below are what let it finish.
    hook.rendezvous.store(false, .release);
    hook.release();
    for (&test_calls) |*test_call| test_call.gate.set();

    runner.?.join();
    runner = null;

    try testing.expect(run.err == null);
    const batch = &run.batch.?;
    try testing.expect(batch.concluded);
    try testing.expectEqual(@as(usize, 2), batch.results.len);
    try testing.expectEqual(@as(usize, 2), hook.commitCount());
    // The sibling call still ran and committed; concluded only closes the turn
    // after this batch.
    try testing.expectEqual(@as(usize, 2), log.exitedCount());
}

test "large worker results are freed by Batch.deinit without leaks" {
    const allocator = testing.allocator;
    const big = 80 * 1024; // > 64 KiB, crosses allocator chunk sizes
    const ids = [_][]const u8{ "big0", "big1" };
    var calls: [2]types.ToolCall = undefined;
    for (&calls, 0..) |*call, i| call.* = .{ .id = ids[i], .name = "test", .arguments = "{}" };
    var test_calls = [_]TestCall{.{}} ** 2;
    test_calls[0].big_len = big;
    test_calls[1].big_len = big;
    var log = ExecLog{ .allocator = allocator };
    defer log.deinit();
    var exec = ExecCtx{ .calls = &test_calls, .ids = &ids, .log = &log };
    const parallel = [_]bool{ true, true };
    var classifier_ctx = ClassifierCtx{ .ids = &ids, .parallel = &parallel };
    var hook = HookCtx{ .allocator = allocator };
    defer hook.deinit();
    var abort_flag = std.atomic.Value(bool).init(false);

    var run = RunCtx{
        .allocator = allocator,
        .calls = &calls,
        .classifier = .{ .context = &classifier_ctx, .is_concurrency_safe = testClassifier },
        .dispatcher = .{ .context = &exec, .dispatch = testDispatch },
        .signal = .{ .flag = &abort_flag },
        .options = .{},
        .hooks = .{
            .context = &hook,
            .on_dispatch = HookCtx.onDispatch,
            .on_commit = HookCtx.onCommit,
            .on_wait = HookCtx.onWait,
        },
    };
    var runner: ?std.Thread = try std.Thread.spawn(.{}, RunCtx.run, .{&run});
    var joined = false;
    defer {
        if (!joined) {
            hook.rendezvous.store(false, .release);
            hook.allow.set();
            for (&test_calls) |*test_call| test_call.gate.set();
        }
        if (runner) |thread| thread.join();
        runner = null;
        if (run.batch) |*batch| {
            batch.deinit(allocator);
            run.batch = null;
        }
    }

    hook.expectWaiting();
    // One handshake is enough: a second onWait means a worker is still
    // running, and the gates below are what let it finish.
    hook.rendezvous.store(false, .release);
    hook.release();
    for (&test_calls) |*test_call| test_call.gate.set();

    runner.?.join();
    runner = null;
    joined = true;

    try testing.expect(run.err == null);
    {
        const batch = &run.batch.?;
        try testing.expectEqual(@as(usize, 2), batch.results.len);
        for (batch.results) |result| {
            const text = resultText(result).?;
            try testing.expectEqual(@as(usize, big), text.len);
            try testing.expectEqual(@as(u8, 'x'), text[0]);
            try testing.expectEqual(@as(u8, 'x'), text[big - 1]);
        }
    }

    // Releasing the per-call arenas is what makes the leak checker pass.
    run.batch.?.deinit(allocator);
    run.batch = null;
}
