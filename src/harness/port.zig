//! The turn port: the one seam the host uses to talk to a turn engine.
//!
//! A turn is four layers in this repo (Agent.turn loop, SessionManager
//! lifecycle, ReliableProvider retries, channel transport) but the host already
//! treats a single boundary as an interface: it installs the stream/progress/
//! drain callbacks, calls the turn, and gets one owned reply back. This file
//! names that boundary so a second engine can sit behind it.
//!
//! Phase 1 capabilities this must be able to CARRY (not implement) later:
//! - streaming of every text segment: `Event.delta` already carries each
//!   `StreamChunk`; only `live_stream`/`sink` gating has to change.
//! - steer semantics: `Event.progress` carries each `ProgressHint`; the host's
//!   queue policy stays in `Session`, `drain` stays the injection seam.
//! - parallel tools / approvals / ask_user_question: they need new `Event`
//!   variants and `TurnInput` fields, which is why `Event` is a union and
//!   `TurnInput` is a struct rather than positional arguments.
//! - typed end reasons: `EndReason` (from dsh, trimmed to five) replaces the
//!   host guessing from `last_turn_interrupted`.

const std = @import("std");
const providers = @import("../providers/root.zig");
const agent_mod = @import("../agent/root.zig");
const prompt = @import("../agent/prompt.zig");
const memory_mod = @import("../memory/root.zig");
const config_types = @import("../config_types.zig");
const redaction = @import("../redaction.zig");

/// One thing a turn reports while it runs.
///
/// Every payload is BORROWED for the duration of `emit`: the sink may read it
/// but must not free it or store it past the call. That is the same contract
/// as `Agent`'s stream/progress callbacks, so existing sinks need no copy.
pub const Event = union(enum) {
    /// A provider text chunk. Borrowed; `.delta` is only valid inside emit().
    delta: providers.StreamChunk,
    /// A progress hint. Borrowed; `arguments_json` is sensitive and must not
    /// be rendered raw by the sink.
    progress: agent_mod.ProgressHint,
    /// One LLM response's token usage. Borrowed.
    ///
    /// The host does NOT wire this today: `usage_record_callback` is installed
    /// once at session creation and writes the usage ledger, and a second
    /// receiver must not disturb it. It exists so a ported engine can report
    /// usage without the host reaching past the
    usage: agent_mod.Agent.UsageRecord,
};

/// Where the engine delivers `Event`s. `ctx` is owned by the host.
pub const Sink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, event: Event) void,

    pub fn send(self: Sink, event: Event) void {
        self.emit(self.ctx, event);
    }
};

/// What the host hands the engine for one turn.
pub const TurnInput = struct {
    user_message: []const u8,
    /// Channel attribution for this turn; borrowed, same lifetime as the call.
    conversation_context: ?prompt.ConversationContext = null,
    /// Memory scope key; borrowed (owned by the Session).
    memory_session_id: ?[]const u8 = null,
    /// Mirrors today's `stream_callback != null`: the host has a live draft to
    /// feed, so the engine may run the provider in streaming mode. False keeps
    /// the blocking provider path.
    live_stream: bool = false,
    /// Where to emit `Event`s. Null means "no observer this turn"; the engine
    /// must then install nothing and leave the agent's callbacks alone.
    sink: ?Sink = null,
    /// Mid-turn injection drain, installed per turn. Reuses
    /// `Agent.DrainCallback` so the existing `SteerDrainContext` keeps working.
    drain: ?agent_mod.DrainCallback = null,
    drain_ctx: ?*anyopaque = null,
};

/// Why a turn ended. dsh has seven; only these three are reachable in phase 0.
pub const EndReason = enum {
    completed,
    /// A /stop landed and the agent halted the turn (`last_turn_interrupted`).
    interrupted,
    /// The turn was refused before the provider ran (approvals, policy).
    /// Reserved for phase 1; the native adapter never produces it.
    blocked,
    /// The turn returned an error. The error is ALSO still propagated as the
    /// Zig error, so the host's existing error path is unchanged; this is
    /// informational only.
    failed,
    /// The model hit its output cap. Reserved for phase 1.
    max_tokens,
};

/// What the engine returns. `reply` is owned by the engine's allocator and the
/// host frees it with that same allocator — identical to `Agent.turn` today.
pub const TurnResult = struct {
    reply: []const u8,
    /// The text that belongs in the session store (no /usage footer, no
    /// reasoning block). Borrowed from the engine's history.
    persisted_reply: ?[]const u8 = null,
    total_tokens: u64 = 0,
    end_reason: EndReason = .completed,
    /// True when this turn compacted the history.
    compacted: bool = false,
};

/// What the host hands the engine to rebuild a session after a restart.
pub const RestoreInput = struct {
    messages: []const memory_mod.MessageEntry,
    total_tokens: u64 = 0,
    compaction_count: u64 = 0,
};

/// Live read-only view of the engine's configuration. NOT a snapshot: every
/// slice is borrowed from the engine and stays valid only while it is alive.
/// (Design C's copied snapshot was rejected: two copies of the same truth
/// diverge, and the host needs `/model` changes to be visible immediately.)
pub const Info = struct {
    provider_name: []const u8,
    model_name: []const u8,
    workspace_dir: []const u8,
    allowed_paths: []const []const u8,
    has_own_autonomy: bool,
    queue_mode: config_types.QueueMode,
    reasoning_mode: config_types.ReasoningMode,
    redactor: ?*redaction.Redactor,
};

/// A turn engine. `ptr` points at the implementation's state.
pub const Harness = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        runTurn: *const fn (ptr: *anyopaque, input: TurnInput) anyerror!TurnResult,
        requestInterrupt: *const fn (ptr: *anyopaque) void,
        clearInterrupt: *const fn (ptr: *anyopaque) void,
        activeToolName: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8,
        restore: *const fn (ptr: *anyopaque, input: RestoreInput) anyerror!void,
        reset: *const fn (ptr: *anyopaque) void,
        invalidatePrompt: *const fn (ptr: *anyopaque) void,
        info: *const fn (ptr: *anyopaque) Info,
        /// Host-side slash pre-routing. Optional: an engine that cannot answer
        /// local commands itself leaves it null and the host runs them.
        handleLocalCommand: ?*const fn (ptr: *anyopaque, content: []const u8) anyerror!?[]u8 = null,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn runTurn(self: Harness, input: TurnInput) anyerror!TurnResult {
        return self.vtable.runTurn(self.ptr, input);
    }

    pub fn requestInterrupt(self: Harness) void {
        self.vtable.requestInterrupt(self.ptr);
    }

    pub fn clearInterrupt(self: Harness) void {
        self.vtable.clearInterrupt(self.ptr);
    }

    pub fn activeToolName(self: Harness, allocator: std.mem.Allocator) anyerror!?[]u8 {
        return self.vtable.activeToolName(self.ptr, allocator);
    }

    pub fn restore(self: Harness, input: RestoreInput) anyerror!void {
        return self.vtable.restore(self.ptr, input);
    }

    pub fn reset(self: Harness) void {
        self.vtable.reset(self.ptr);
    }

    pub fn invalidatePrompt(self: Harness) void {
        self.vtable.invalidatePrompt(self.ptr);
    }

    pub fn info(self: Harness) Info {
        return self.vtable.info(self.ptr);
    }

    pub fn handleLocalCommand(self: Harness, content: []const u8) anyerror!?[]u8 {
        const f = self.vtable.handleLocalCommand orelse return null;
        return f(self.ptr, content);
    }

    pub fn deinit(self: Harness, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// A fake engine that records what it was given and what it emitted, so the
/// interface's own ownership rules can be pinned without an Agent.
const FakeHarness = struct {
    const Self = @This();

    /// Set by a test to make runTurn fail.
    fail: bool = false,
    last_live_stream: bool = false,
    last_had_sink: bool = false,
    last_drain: bool = false,
    last_message: []const u8 = "",
    restored: usize = 0,
    resets: usize = 0,
    invalidations: usize = 0,
    interrupts_requested: usize = 0,
    interrupts_cleared: usize = 0,
    usage: agent_mod.Agent.UsageRecord = undefined,
    model_name: []const u8 = "fake-model",
    workspace_dir: []const u8 = "/tmp/fake-workspace",
    provider_name: []const u8 = "fake-provider",
    allowed_paths: []const []const u8 = &.{"."},

    fn runTurn(ptr: *anyopaque, input: TurnInput) anyerror!TurnResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.last_live_stream = input.live_stream;
        self.last_had_sink = input.sink != null;
        self.last_drain = input.drain != null and input.drain_ctx != null;
        self.last_message = input.user_message;
        if (self.fail) return error.Boom;

        if (input.sink) |sink| {
            sink.send(.{ .delta = .textDelta("hi ") });
            sink.send(.{ .progress = .{ .kind = .tool, .text = "probe" } });
            self.usage = .{
                .ts = 0,
                .provider = "fake-provider",
                .model = "fake-model",
                .usage = .{ .prompt_tokens = 3, .completion_tokens = 2, .total_tokens = 5 },
                .success = true,
            };
            sink.send(.{ .usage = self.usage });
        }
        return .{ .reply = "ok", .total_tokens = 5 };
    }

    fn requestInterrupt(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.interrupts_requested += 1;
    }

    fn clearInterrupt(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.interrupts_cleared += 1;
    }

    fn activeToolName(_: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
        return try allocator.dupe(u8, "probe");
    }

    fn restore(ptr: *anyopaque, input: RestoreInput) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.restored = input.messages.len;
    }

    fn reset(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.resets += 1;
    }

    fn invalidatePrompt(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.invalidations += 1;
    }

    fn info(ptr: *anyopaque) Info {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return .{
            .provider_name = self.provider_name,
            .model_name = self.model_name,
            .workspace_dir = self.workspace_dir,
            .allowed_paths = self.allowed_paths,
            .has_own_autonomy = false,
            .queue_mode = .steer,
            .reasoning_mode = .off,
            .redactor = null,
        };
    }

    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

    const vtable = Harness.VTable{
        .runTurn = runTurn,
        .requestInterrupt = requestInterrupt,
        .clearInterrupt = clearInterrupt,
        .activeToolName = activeToolName,
        .restore = restore,
        .reset = reset,
        .invalidatePrompt = invalidatePrompt,
        .info = info,
        .deinit = deinit,
    };

    fn harness(self: *Self) Harness {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

const EventSink = struct {
    deltas: usize = 0,
    hints: usize = 0,
    usages: usize = 0,
    last_total_tokens: u32 = 0,

    fn emit(ctx: *anyopaque, event: Event) void {
        const self: *EventSink = @ptrCast(@alignCast(ctx));
        switch (event) {
            .delta => self.deltas += 1,
            .progress => self.hints += 1,
            .usage => |u| {
                self.usages += 1;
                self.last_total_tokens = u.usage.total_tokens;
            },
        }
    }

    fn sink(self: *EventSink) Sink {
        return .{ .ctx = @ptrCast(self), .emit = emit };
    }
};

test "port: runTurn forwards delta, progress and usage to the sink" {
    var fake = FakeHarness{};
    var sink_ctx = EventSink{};
    const result = try fake.harness().runTurn(.{
        .user_message = "hello",
        .live_stream = true,
        .sink = sink_ctx.sink(),
    });
    try testing.expectEqualStrings("ok", result.reply);
    try testing.expectEqual(@as(usize, 1), sink_ctx.deltas);
    try testing.expectEqual(@as(usize, 1), sink_ctx.hints);
    try testing.expectEqual(@as(usize, 1), sink_ctx.usages);
    try testing.expectEqual(@as(u32, 5), sink_ctx.last_total_tokens);
    try testing.expectEqual(@as(u64, 5), result.total_tokens);
    try testing.expect(fake.last_live_stream);
    try testing.expect(fake.last_had_sink);
}

test "port: a null sink installs nothing and suppresses events" {
    var fake = FakeHarness{};
    const result = try fake.harness().runTurn(.{ .user_message = "hello" });
    try testing.expectEqualStrings("ok", result.reply);
    try testing.expect(!fake.last_live_stream);
    try testing.expect(!fake.last_had_sink);
    try testing.expect(!fake.last_drain);
}

test "port: a runTurn error propagates unchanged" {
    var fake = FakeHarness{ .fail = true };
    try testing.expectError(error.Boom, fake.harness().runTurn(.{ .user_message = "hello" }));
}

test "port: TurnResult defaults pin end_reason and compacted" {
    const result = TurnResult{ .reply = "x" };
    try testing.expectEqual(EndReason.completed, result.end_reason);
    try testing.expect(!result.compacted);
    try testing.expectEqual(@as(?[]const u8, null), result.persisted_reply);
    try testing.expectEqual(@as(u64, 0), result.total_tokens);
}

test "port: lifecycle methods dispatch through the vtable" {
    var fake = FakeHarness{};
    const h = fake.harness();
    h.requestInterrupt();
    h.clearInterrupt();
    h.reset();
    h.invalidatePrompt();
    try h.restore(.{ .messages = &.{} });
    const tool = try h.activeToolName(testing.allocator);
    defer if (tool) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("probe", tool.?);

    const got = h.info();
    try testing.expectEqualStrings("fake-model", got.model_name);
    try testing.expectEqualStrings("fake-provider", got.provider_name);
    try testing.expectEqual(config_types.QueueMode.steer, got.queue_mode);
    try testing.expectEqual(config_types.ReasoningMode.off, got.reasoning_mode);
    try testing.expectEqual(@as(?*redaction.Redactor, null), got.redactor);

    try testing.expectEqual(@as(usize, 1), fake.interrupts_requested);
    try testing.expectEqual(@as(usize, 1), fake.interrupts_cleared);
    try testing.expectEqual(@as(usize, 1), fake.resets);
    try testing.expectEqual(@as(usize, 1), fake.invalidations);
    try testing.expectEqual(@as(usize, 0), fake.restored);
}

test "port: handleLocalCommand is optional and null by default" {
    var fake = FakeHarness{};
    try testing.expect(fake.harness().vtable.handleLocalCommand == null);
    try testing.expect((try fake.harness().handleLocalCommand("/help")) == null);
}

test "port: info returns live values, not a snapshot" {
    var fake = FakeHarness{};
    const first = fake.harness().info();
    try testing.expectEqualStrings("fake-model", first.model_name);
    fake.model_name = "changed-model";
    const second = fake.harness().info();
    try testing.expectEqualStrings("changed-model", second.model_name);
}
