//! Differential proof: the ported path must be indistinguishable from the
//! direct one.
//!
//! Each test drives the SAME scripted provider twice:
//!   (a) DIRECT   — `Agent.turn` with the callbacks installed exactly as
//!                  `src/session.zig` did before the port (reproduced verbatim
//!                  in `DirectRunner` below).
//!   (b) PORTED   — `NativeHarness.runTurn`.
//! and asserts the two produce identical stream events, progress hints,
//! drain-injection points, reply text, total_tokens and persisted rows.
//!
//! This is the zero-behavior-change gate for the port: if a field of the
//! install block is ever moved wrongly, these fail.

const std = @import("std");
const scripted = @import("test_provider.zig");
const session_mod = @import("../session.zig");
const agent_mod = @import("../agent/root.zig");
const native = @import("native.zig");
const port = @import("port.zig");
const streaming = @import("../streaming.zig");
const prompt = @import("../agent/prompt.zig");
const memory_mod = @import("../memory/root.zig");
const tools_mod = @import("../tools/root.zig");
const observability = @import("../observability.zig");
const turn_persistence = @import("../agent/turn_persistence.zig");

const SessionManager = session_mod.SessionManager;
const Agent = agent_mod.Agent;
const Tool = tools_mod.Tool;
const NativeHarness = native.NativeHarness;

fn testConfig() @import("../config.zig").Config {
    return .{
        .workspace_dir = "/tmp/junclaw_harness_diff",
        .config_path = "/tmp/junclaw_harness_diff/config.json",
        .default_model = "test/scripted-model",
        .allocator = std.testing.allocator,
    };
}

fn initManager(
    cfg: *const @import("../config.zig").Config,
    provider: *scripted.ScriptedProvider,
    tools: []const Tool,
    store: ?memory_mod.SessionStore,
    observer: observability.Observer,
) SessionManager {
    return SessionManager.init(
        std.testing.allocator,
        cfg,
        provider.provider(),
        tools,
        null,
        observer,
        store,
        null,
    );
}

// ── Recording sinks ─────────────────────────────────────────────────

const stream_copy_len = 64;

const StreamRecorder = struct {
    const Record = struct {
        stage: streaming.OutboundStage,
        len: usize = 0,
        buf: [stream_copy_len]u8 = undefined,

        fn text(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };

    records: [16]Record = undefined,
    count: usize = 0,

    fn sink(self: *StreamRecorder) streaming.Sink {
        return .{ .callback = onEvent, .ctx = @ptrCast(self) };
    }

    fn onEvent(ctx: *anyopaque, event: streaming.Event) void {
        const self: *StreamRecorder = @ptrCast(@alignCast(ctx));
        if (self.count >= self.records.len) return;
        const record = &self.records[self.count];
        self.count += 1;
        record.stage = event.stage;
        record.len = @min(event.text.len, stream_copy_len);
        @memcpy(record.buf[0..record.len], event.text[0..record.len]);
    }

    fn at(self: *const StreamRecorder, index: usize) *const Record {
        return &self.records[index];
    }

    /// Compare against another recorder's whole ordered sequence.
    fn sameAs(self: *const StreamRecorder, other: *const StreamRecorder) !void {
        try std.testing.expectEqual(self.count, other.count);
        for (0..self.count) |i| {
            try std.testing.expectEqual(self.at(i).stage, other.at(i).stage);
            try std.testing.expectEqualStrings(self.at(i).text(), other.at(i).text());
        }
    }
};

const progress_copy_len = 64;

const ProgressRecorder = struct {
    const Record = struct {
        kind: agent_mod.ProgressKind,
        phase: agent_mod.ProgressPhase,
        success: bool,
        has_arguments: bool,
        len: usize = 0,
        buf: [progress_copy_len]u8 = undefined,

        fn text(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };

    records: [16]Record = undefined,
    count: usize = 0,

    fn sink(self: *ProgressRecorder) agent_mod.ProgressSink {
        return .{ .callback = onEvent, .ctx = @ptrCast(self) };
    }

    fn onEvent(ctx: *anyopaque, hint: agent_mod.ProgressHint) void {
        const self: *ProgressRecorder = @ptrCast(@alignCast(ctx));
        if (self.count >= self.records.len) return;
        const record = &self.records[self.count];
        self.count += 1;
        record.kind = hint.kind;
        record.phase = hint.phase;
        record.success = hint.success;
        record.has_arguments = hint.arguments_json != null;
        record.len = @min(hint.text.len, progress_copy_len);
        @memcpy(record.buf[0..record.len], hint.text[0..record.len]);
    }

    fn at(self: *const ProgressRecorder, index: usize) *const Record {
        return &self.records[index];
    }

    fn sameAs(self: *const ProgressRecorder, other: *const ProgressRecorder) !void {
        try std.testing.expectEqual(self.count, other.count);
        for (0..self.count) |i| {
            const a = self.at(i);
            const b = other.at(i);
            try std.testing.expectEqual(a.kind, b.kind);
            try std.testing.expectEqual(a.phase, b.phase);
            try std.testing.expectEqual(a.success, b.success);
            try std.testing.expectEqual(a.has_arguments, b.has_arguments);
            try std.testing.expectEqualStrings(a.text(), b.text());
        }
    }
};

const UsageRecorder = struct {
    records: [8]agent_mod.Agent.UsageRecord = undefined,
    count: usize = 0,

    fn callback(ctx: *anyopaque, record: agent_mod.Agent.UsageRecord) void {
        const self: *UsageRecorder = @ptrCast(@alignCast(ctx));
        if (self.count >= self.records.len) return;
        // `provider`/`model` are arena-borrowed by the agent, so copy them:
        // the real ledger writes them to a file before the arena resets.
        self.records[self.count] = record;
        self.records[self.count].provider = std.testing.allocator.dupe(u8, record.provider) catch return;
        self.records[self.count].model = std.testing.allocator.dupe(u8, record.model) catch return;
        self.count += 1;
    }

    fn deinit(self: *UsageRecorder) void {
        for (self.records[0..self.count]) |record| {
            std.testing.allocator.free(record.provider);
            std.testing.allocator.free(record.model);
        }
    }
};

// ── Recording session store ─────────────────────────────────────────

const RecordingStore = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayListUnmanaged(Row) = .empty,

    const Row = struct { role: []u8, content: []u8 };

    fn store(self: *RecordingStore) memory_mod.SessionStore {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = memory_mod.SessionStore.VTable{
        .saveMessage = saveMessage,
        .loadMessages = loadMessages,
        .clearMessages = clearMessages,
        .clearAutoSaved = clearAutoSaved,
    };

    fn saveMessage(ptr: *anyopaque, _: []const u8, role: []const u8, content: []const u8) anyerror!void {
        const self: *RecordingStore = @ptrCast(@alignCast(ptr));
        try self.rows.append(self.allocator, .{
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
        });
    }

    fn loadMessages(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror![]memory_mod.MessageEntry {
        return &.{};
    }

    fn clearMessages(ptr: *anyopaque, _: []const u8) anyerror!void {
        const self: *RecordingStore = @ptrCast(@alignCast(ptr));
        self.freeRows();
    }

    fn clearAutoSaved(_: *anyopaque, _: ?[]const u8) anyerror!void {}

    fn freeRows(self: *RecordingStore) void {
        for (self.rows.items) |row| {
            self.allocator.free(row.role);
            self.allocator.free(row.content);
        }
        self.rows.clearRetainingCapacity();
    }

    fn deinit(self: *RecordingStore) void {
        self.freeRows();
        self.rows.deinit(self.allocator);
    }

    fn expectRows(self: *const RecordingStore, expected: []const struct { role: []const u8, content: []const u8 }) !void {
        try std.testing.expectEqual(expected.len, self.rows.items.len);
        for (expected, self.rows.items) |want, got| {
            try std.testing.expectEqualStrings(want.role, got.role);
            try std.testing.expectEqualStrings(want.content, got.content);
        }
    }
};

// ── Probe tool ──────────────────────────────────────────────────────

const ProbeTool = struct {
    executions: usize = 0,

    pub const tool_name = "probe";
    pub const tool_description = "Differential probe tool";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
    const vtable = tools_mod.ToolVTable(@This());

    fn tool(self: *@This()) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *@This(), allocator: std.mem.Allocator, _: tools_mod.JsonObjectMap) !tools_mod.ToolResult {
        self.executions += 1;
        return .{ .success = true, .output = try allocator.dupe(u8, "probe ok") };
    }
};

const probe_call = scripted.ToolCallSpec{
    .id = "call-probe",
    .name = ProbeTool.tool_name,
    .arguments = "{}",
};

// ── The DIRECT runner ───────────────────────────────────────────────
// Verbatim reproduction of the install block src/session.zig:2739-2794 had
// before the port, so the differential compares against the ORIGINAL behavior
// rather than against my own adapter.

const DirectRunner = struct {
    session_key: []const u8,
    conversation_context: ?prompt.ConversationContext = null,
    stream_sink: ?streaming.Sink = null,
    progress_sink: ?agent_mod.ProgressSink = null,

    const StreamAdapterCtx = struct {
        sink: streaming.Sink,
        suppress_live: bool = false,
    };

    fn streamChunkForwarder(ctx_ptr: *anyopaque, chunk: @import("../providers/root.zig").StreamChunk) void {
        const adapter: *StreamAdapterCtx = @ptrCast(@alignCast(ctx_ptr));
        if (adapter.suppress_live and !chunk.is_final) return;
        streaming.forwardProviderChunk(adapter.sink, chunk);
    }

    fn shouldRehydrateDisplay(key: []const u8, ctx_: ?prompt.ConversationContext) bool {
        const channel = if (ctx_) |c| c.channel else null;
        const is_group = if (ctx_) |c| c.is_group else null;
        return @import("../governance.zig").shouldRehydrateDisplay(key, channel, is_group);
    }

    fn shouldSuppressLiveForRedaction(r: ?*@import("../redaction.zig").Redactor, content: []const u8, allowed: bool) bool {
        if (!allowed) return false;
        const red = r orelse return false;
        return red.wouldRehydrate() or (red.config.record_originals and red.wouldRedact(content));
    }

    fn run(
        self: DirectRunner,
        agent: *Agent,
        content: []const u8,
        drain_cb: ?agent_mod.DrainCallback,
        drain_ctx: ?*anyopaque,
    ) ![]const u8 {
        const prev_stream_callback = agent.stream_callback;
        const prev_stream_ctx = agent.stream_ctx;
        defer {
            agent.stream_callback = prev_stream_callback;
            agent.stream_ctx = prev_stream_ctx;
        }

        const display_rehydrate_allowed = shouldRehydrateDisplay(self.session_key, self.conversation_context);

        var stream_adapter: StreamAdapterCtx = undefined;
        if (self.stream_sink) |sink| {
            const suppress_live = shouldSuppressLiveForRedaction(agent.redactor, content, display_rehydrate_allowed);
            stream_adapter = .{ .sink = sink, .suppress_live = suppress_live };
            agent.stream_callback = streamChunkForwarder;
            agent.stream_ctx = @ptrCast(&stream_adapter);
        } else {
            agent.stream_callback = null;
            agent.stream_ctx = null;
        }

        const prev_progress_callback = agent.progress_callback;
        const prev_progress_ctx = agent.progress_ctx;
        defer {
            agent.progress_callback = prev_progress_callback;
            agent.progress_ctx = prev_progress_ctx;
        }
        if (self.progress_sink) |ps| {
            agent.progress_callback = ps.callback;
            agent.progress_ctx = ps.ctx;
        } else {
            agent.progress_callback = null;
            agent.progress_ctx = null;
        }

        // Kept from src/session.zig:2773-2780.
        const start_event = observability.ObserverEvent{ .agent_start = .{
            .provider = agent.provider.getName(),
            .model = agent.model_name,
            .channel = if (self.conversation_context) |ctx| ctx.channel else null,
            .bot_account = if (self.conversation_context) |ctx| ctx.account_id else null,
        } };
        agent.observer.recordEvent(&start_event);

        const prev_drain_callback = agent.drain_injection_cb;
        const prev_drain_ctx = agent.drain_injection_ctx;
        defer {
            agent.drain_injection_cb = prev_drain_callback;
            agent.drain_injection_ctx = prev_drain_ctx;
        }
        if (drain_cb) |cb| {
            agent.drain_injection_cb = cb;
            agent.drain_injection_ctx = drain_ctx;
        } else {
            agent.drain_injection_cb = null;
            agent.drain_injection_ctx = null;
        }

        return agent.turn(content);
    }
};

// ── Drain-injection recording ───────────────────────────────────────
// A drain callback that records what the agent asked for at each boundary.

const DrainLog = struct {
    messages: [8][]const u8 = undefined,
    count: usize = 0,
    allocator: std.mem.Allocator,
    /// Text handed back on each drain; the test drives the injection timing.
    replies: []const []const u8 = &.{},
    index: usize = 0,

    fn callback(ctx: *anyopaque, agent_allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *DrainLog = @ptrCast(@alignCast(ctx));
        // A boundary was reached: record that the agent asked.
        if (self.count < self.messages.len) {
            self.messages[self.count] = "";
            self.count += 1;
        }
        if (self.index >= self.replies.len) return null;
        const text = self.replies[self.index];
        self.index += 1;
        return try agent_allocator.dupe(u8, text);
    }
};

// ── Test 1: identical stream/progress/reply/tokens for a tool turn ───

test "differential: ported and direct produce identical stream, progress and reply" {
    const script = [_]scripted.Response{
        .{ .text = "calling probe", .tool_calls = &.{probe_call}, .chunks = &.{ "calling ", "probe" } },
        .{ .text = "final answer", .chunks = &.{ "final ", "answer" } },
    };

    const cfg = testConfig();
    var noop = observability.NoopObserver{};

    // (a) direct
    var direct_provider = scripted.ScriptedProvider{ .responses = &script };
    var direct_probe = ProbeTool{};
    var direct_tools = [_]Tool{direct_probe.tool()};
    var direct_sm = initManager(&cfg, &direct_provider, &direct_tools, null, noop.observer());
    defer direct_sm.deinit();
    const direct_session = try direct_sm.getOrCreate("diff:direct");
    direct_session.turn_running.store(true, .release);
    defer direct_session.turn_running.store(false, .release);

    var direct_stream = StreamRecorder{};
    var direct_progress = ProgressRecorder{};
    var direct_runner = DirectRunner{
        .session_key = "diff:direct",
        .stream_sink = direct_stream.sink(),
        .progress_sink = direct_progress.sink(),
    };
    const direct_reply = try direct_runner.run(&direct_session.agent, "run the probe", null, null);
    defer std.testing.allocator.free(direct_reply);

    // (b) ported
    var ported_provider = scripted.ScriptedProvider{ .responses = &script };
    var ported_probe = ProbeTool{};
    var ported_tools = [_]Tool{ported_probe.tool()};
    var ported_sm = initManager(&cfg, &ported_provider, &ported_tools, null, noop.observer());
    defer ported_sm.deinit();
    const ported_session = try ported_sm.getOrCreate("diff:ported");
    ported_session.turn_running.store(true, .release);
    defer ported_session.turn_running.store(false, .release);

    var ported_stream = StreamRecorder{};
    var ported_progress = ProgressRecorder{};
    var dual_ctx = DualSink{ .stream = ported_stream.sink(), .progress = ported_progress.sink() };
    var adapter = NativeHarness.init(&ported_session.agent);
    adapter.session_key = "diff:ported";
    const ported_result = try adapter.harness().runTurn(.{
        .user_message = "run the probe",
        .live_stream = true,
        .sink = .{ .ctx = @ptrCast(&dual_ctx), .emit = DualSink.emit },
    });
    defer std.testing.allocator.free(ported_result.reply);

    // Identical results.
    try std.testing.expectEqualStrings(direct_reply, ported_result.reply);
    // Golden redetermined after origin/main 5ae2741c: the interim text of a
    // tool round is now part of the reply.
    try std.testing.expectEqualStrings("calling probe\n\nfinal answer", ported_result.reply);
    try std.testing.expectEqual(direct_session.agent.total_tokens, ported_result.total_tokens);
    try std.testing.expectEqual(@as(usize, 1), direct_probe.executions);
    try std.testing.expectEqual(@as(usize, 1), ported_probe.executions);
    try direct_stream.sameAs(&ported_stream);
    try direct_progress.sameAs(&ported_progress);
    try std.testing.expectEqual(direct_provider.call_count, ported_provider.call_count);
    try std.testing.expectEqual(port.EndReason.completed, ported_result.end_reason);
    try std.testing.expect(!ported_result.compacted);

    // The adapter must not leave callbacks installed after the turn.
    try std.testing.expect(ported_session.agent.stream_callback == null);
    try std.testing.expect(ported_session.agent.stream_ctx == null);
    try std.testing.expect(ported_session.agent.progress_callback == null);
    try std.testing.expect(ported_session.agent.progress_ctx == null);
    try std.testing.expect(ported_session.agent.drain_injection_cb == null);
    try std.testing.expect(ported_session.agent.drain_injection_ctx == null);
}

/// A port sink that fans one Event out to the host's two sinks, exactly as
/// `session.PortEventSink` does.
const DualSink = struct {
    stream: streaming.Sink,
    progress: agent_mod.ProgressSink,

    fn emit(ctx: *anyopaque, event: port.Event) void {
        const self: *DualSink = @ptrCast(@alignCast(ctx));
        switch (event) {
            .delta => |chunk| streaming.forwardProviderChunk(self.stream, chunk),
            .progress => |hint| self.progress.emit(hint),
            .usage => {},
            else => {},
        }
    }
};

// ── Test 2: no sink installs nothing (the non-streaming path) ────────

test "differential: a null sink installs no callbacks on either path" {
    const script = [_]scripted.Response{.{ .text = "plain answer", .chunks = &.{ "plain ", "answer" } }};
    const cfg = testConfig();
    var noop = observability.NoopObserver{};

    var direct_provider = scripted.ScriptedProvider{ .responses = &script };
    var direct_sm = initManager(&cfg, &direct_provider, &.{}, null, noop.observer());
    defer direct_sm.deinit();
    const direct_session = try direct_sm.getOrCreate("diff:nosink-direct");
    direct_session.turn_running.store(true, .release);
    defer direct_session.turn_running.store(false, .release);
    var direct_runner = DirectRunner{ .session_key = "diff:nosink-direct" };
    const direct_reply = try direct_runner.run(&direct_session.agent, "hello", null, null);
    defer std.testing.allocator.free(direct_reply);

    var ported_provider = scripted.ScriptedProvider{ .responses = &script };
    var ported_sm = initManager(&cfg, &ported_provider, &.{}, null, noop.observer());
    defer ported_sm.deinit();
    const ported_session = try ported_sm.getOrCreate("diff:nosink-ported");
    ported_session.turn_running.store(true, .release);
    defer ported_session.turn_running.store(false, .release);
    var adapter = NativeHarness.init(&ported_session.agent);
    const ported_result = try adapter.harness().runTurn(.{ .user_message = "hello" });
    defer std.testing.allocator.free(ported_result.reply);

    try std.testing.expectEqualStrings(direct_reply, ported_result.reply);
    try std.testing.expectEqualStrings("plain answer", ported_result.reply);
    try std.testing.expectEqual(direct_session.agent.total_tokens, ported_result.total_tokens);
    try std.testing.expectEqual(@as(usize, 1), direct_provider.call_count);
    try std.testing.expectEqual(@as(usize, 1), ported_provider.call_count);

    // Neither path leaves a stream callback behind.
    try std.testing.expect(direct_session.agent.stream_callback == null);
    try std.testing.expect(ported_session.agent.stream_callback == null);
    // The provider is asked for streaming on neither path.
    try std.testing.expectEqual(direct_provider.call(0).message_count, ported_provider.call(0).message_count);
}

// ── CLI / subagent call-site parity ─────────────────────────────────
// CLI and subagent turns now go through NativeHarness too. Neither ever sent
// `agent_start`, and neither has session/conversation context, so these tests
// reproduce their exact install shape and assert the ported call is identical.

const CliSinkCtx = struct {
    recorder: *StreamRecorder,
    sink: streaming.Sink = undefined,
    suppress_live: bool = false,
    emitted_text: bool = false,

    fn rawSink(self: *CliSinkCtx) streaming.Sink {
        return .{ .callback = onEvent, .ctx = @ptrCast(self) };
    }

    fn onEvent(ctx_ptr: *anyopaque, event: streaming.Event) void {
        const self: *CliSinkCtx = @ptrCast(@alignCast(ctx_ptr));
        if (event.stage != .chunk or event.text.len == 0) return;
        if (self.suppress_live) return;
        self.emitted_text = true;
        StreamRecorder.onEvent(@ptrCast(self.recorder), event);
    }
};

/// Verbatim `src/agent/cli.zig` install: the callback exists only when the
/// provider supports streaming, and it feeds `stream_ctx.sink`.
fn cliDirectTurn(agent: *Agent, text: []const u8, supports_streaming: bool, stream_ctx: *CliSinkCtx) ![]const u8 {
    stream_ctx.emitted_text = false;
    if (supports_streaming) {
        agent.stream_callback = cliChunkForwarder;
        agent.stream_ctx = @ptrCast(stream_ctx);
    }
    defer {
        agent.stream_callback = null;
        agent.stream_ctx = null;
    }
    return agent.turn(text);
}

fn cliChunkForwarder(ctx_ptr: *anyopaque, chunk: @import("../providers/root.zig").StreamChunk) void {
    const stream_ctx: *CliSinkCtx = @ptrCast(@alignCast(ctx_ptr));
    streaming.forwardProviderChunk(stream_ctx.sink, chunk);
}

fn cliPortedTurn(agent: *Agent, text: []const u8, supports_streaming: bool, stream_ctx: *CliSinkCtx) ![]const u8 {
    stream_ctx.emitted_text = false;
    var adapter = NativeHarness.init(agent);
    adapter.emit_start_event = false;
    const result = try adapter.harness().runTurn(.{
        .user_message = text,
        .live_stream = supports_streaming,
        .sink = if (supports_streaming) port.Sink{
            .ctx = @ptrCast(stream_ctx),
            .emit = cliPortEmit,
        } else null,
    });
    return result.reply;
}

fn cliPortEmit(ctx_ptr: *anyopaque, event: port.Event) void {
    const stream_ctx: *CliSinkCtx = @ptrCast(@alignCast(ctx_ptr));
    switch (event) {
        .delta => |chunk| streaming.forwardProviderChunk(stream_ctx.sink, chunk),
        else => {},
    }
}

const EventRecorder = struct {
    agent_start: usize = 0,
    total: usize = 0,

    const vtable = observability.Observer.VTable{
        .record_event = recordEvent,
        .record_metric = recordMetric,
        .flush = flush,
        .name = name,
        .get_trace_id = getTraceId,
        .set_trace_id = setTraceId,
    };

    fn observer(self: *EventRecorder) observability.Observer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn recordEvent(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
        const self: *EventRecorder = @ptrCast(@alignCast(ptr));
        self.total += 1;
        switch (event.*) {
            .agent_start => self.agent_start += 1,
            else => {},
        }
    }

    fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn flush(_: *anyopaque) void {}
    fn name(_: *anyopaque) []const u8 {
        return "event-recorder";
    }
    fn getTraceId(_: *anyopaque) ?[32]u8 {
        return null;
    }
    fn setTraceId(_: *anyopaque, _: [32]u8) void {}
};

fn expectSameHistory(a: *const Agent, b: *const Agent) !void {
    try std.testing.expectEqual(a.history.items.len, b.history.items.len);
    for (a.history.items, b.history.items) |left, right| {
        try std.testing.expectEqual(left.role, right.role);
        try std.testing.expectEqualStrings(left.content, right.content);
    }
}

fn cliSinkChain(recorder: *StreamRecorder, ctx: *CliSinkCtx, passthrough: bool, filter: *streaming.TagFilter, think: *streaming.ThinkPassthroughFilter) streaming.Sink {
    ctx.recorder = recorder;
    if (passthrough) {
        think.* = streaming.ThinkPassthroughFilter.init(ctx.rawSink());
        think.filter.orphan_think_closer = .suppress;
        ctx.sink = think.sink();
    } else {
        filter.* = streaming.TagFilter.init(ctx.rawSink());
        filter.orphan_think_closer = .suppress;
        ctx.sink = filter.sink();
    }
    return ctx.sink;
}

fn runCliDiff(comptime supports_streaming: bool, comptime passthrough: bool, text: []const u8, script: []const scripted.Response) !void {
    const cfg = testConfig();
    const no_tools = [_]Tool{};

    var direct_obs = EventRecorder{};
    var direct_provider = scripted.ScriptedProvider{ .responses = script };
    var direct_sm = initManager(&cfg, &direct_provider, &no_tools, null, direct_obs.observer());
    defer direct_sm.deinit();
    const direct_session = try direct_sm.getOrCreate("cli:direct");

    var direct_recorder = StreamRecorder{};
    var direct_ctx = CliSinkCtx{ .recorder = &direct_recorder };
    var direct_filter = streaming.TagFilter{};
    var direct_think = streaming.ThinkPassthroughFilter{};
    _ = cliSinkChain(&direct_recorder, &direct_ctx, passthrough, &direct_filter, &direct_think);
    const direct_reply = try cliDirectTurn(&direct_session.agent, text, supports_streaming, &direct_ctx);
    defer std.testing.allocator.free(direct_reply);

    var ported_obs = EventRecorder{};
    var ported_provider = scripted.ScriptedProvider{ .responses = script };
    var ported_sm = initManager(&cfg, &ported_provider, &no_tools, null, ported_obs.observer());
    defer ported_sm.deinit();
    const ported_session = try ported_sm.getOrCreate("cli:ported");

    var ported_recorder = StreamRecorder{};
    var ported_ctx = CliSinkCtx{ .recorder = &ported_recorder };
    var ported_filter = streaming.TagFilter{};
    var ported_think = streaming.ThinkPassthroughFilter{};
    _ = cliSinkChain(&ported_recorder, &ported_ctx, passthrough, &ported_filter, &ported_think);
    const ported_reply = try cliPortedTurn(&ported_session.agent, text, supports_streaming, &ported_ctx);
    defer std.testing.allocator.free(ported_reply);

    // Observable output: reply, stream event sequence, history, call count.
    try std.testing.expectEqualStrings(direct_reply, ported_reply);
    try direct_recorder.sameAs(&ported_recorder);
    try std.testing.expectEqual(direct_ctx.emitted_text, ported_ctx.emitted_text);
    try expectSameHistory(&direct_session.agent, &ported_session.agent);
    try std.testing.expectEqual(direct_provider.call_count, ported_provider.call_count);
    try std.testing.expectEqual(direct_provider.call(0).message_count, ported_provider.call(0).message_count);

    // Neither path may emit `agent_start` (the direct callers never did).
    try std.testing.expectEqual(@as(usize, 0), direct_obs.agent_start);
    try std.testing.expectEqual(@as(usize, 0), ported_obs.agent_start);
    try std.testing.expect(direct_obs.total > 0);
    try std.testing.expect(ported_obs.total > 0);

    if (!supports_streaming) {
        try std.testing.expectEqual(@as(usize, 0), ported_recorder.count);
        try std.testing.expect(!ported_ctx.emitted_text);
        try std.testing.expect(ported_session.agent.stream_callback == null);
    }
}

test "differential: CLI streaming turn matches direct agent.turn" {
    const script = [_]scripted.Response{
        .{ .text = "streamed answer", .chunks = &.{ "streamed ", "answer" } },
    };
    try runCliDiff(true, false, "hello", &script);
}

test "differential: CLI turn without streaming support installs no callback" {
    const script = [_]scripted.Response{
        .{ .text = "plain answer", .chunks = &.{ "plain ", "answer" } },
    };
    try runCliDiff(false, false, "hello", &script);
}

test "differential: CLI reasoning passthrough turn matches direct agent.turn" {
    const script = [_]scripted.Response{
        .{ .text = "answer", .chunks = &.{ "<think>plan</think>", "answer" } },
    };
    try runCliDiff(true, true, "hello", &script);
}

test "differential: CLI redactor suppression gate matches direct agent.turn" {
    const script = [_]scripted.Response{
        .{ .text = "sent to [EMAIL_1]", .chunks = &.{ "sent to ", "[EMAIL_1]" } },
        .{ .text = "second answer", .chunks = &.{ "second ", "answer" } },
    };
    const cfg = testConfig();
    const no_tools = [_]Tool{};
    var noop = observability.NoopObserver{};

    var direct_provider = scripted.ScriptedProvider{ .responses = &script };
    var direct_sm = initManager(&cfg, &direct_provider, &no_tools, null, noop.observer());
    defer direct_sm.deinit();
    const direct_session = try direct_sm.getOrCreate("cli:redact:direct");
    // Warm-up records the placeholder, so wouldRehydrate() is true and the
    // CLI sink suppresses the live draft exactly as it does in production.
    const direct_warm = try direct_session.agent.turn("email alice@example.com");
    defer std.testing.allocator.free(direct_warm);
    try std.testing.expect(direct_session.agent.redactor.?.wouldRehydrate());

    const direct_suppress = direct_session.agent.redactor.?.wouldRehydrate();
    try std.testing.expect(direct_suppress);
    var direct_recorder = StreamRecorder{};
    var direct_ctx = CliSinkCtx{ .recorder = &direct_recorder, .suppress_live = direct_suppress };
    var direct_filter = streaming.TagFilter{};
    var direct_think = streaming.ThinkPassthroughFilter{};
    _ = cliSinkChain(&direct_recorder, &direct_ctx, false, &direct_filter, &direct_think);
    const direct_reply = try cliDirectTurn(&direct_session.agent, "hello", true, &direct_ctx);
    defer std.testing.allocator.free(direct_reply);

    var ported_provider = scripted.ScriptedProvider{ .responses = &script };
    var ported_sm = initManager(&cfg, &ported_provider, &no_tools, null, noop.observer());
    defer ported_sm.deinit();
    const ported_session = try ported_sm.getOrCreate("cli:redact:ported");
    const ported_warm = try ported_session.agent.turn("email alice@example.com");
    defer std.testing.allocator.free(ported_warm);
    try std.testing.expect(ported_session.agent.redactor.?.wouldRehydrate());

    const ported_suppress = ported_session.agent.redactor.?.wouldRehydrate();
    try std.testing.expect(ported_suppress);
    var ported_recorder = StreamRecorder{};
    var ported_ctx = CliSinkCtx{ .recorder = &ported_recorder, .suppress_live = ported_suppress };
    var ported_filter = streaming.TagFilter{};
    var ported_think = streaming.ThinkPassthroughFilter{};
    _ = cliSinkChain(&ported_recorder, &ported_ctx, false, &ported_filter, &ported_think);
    const ported_reply = try cliPortedTurn(&ported_session.agent, "hello", true, &ported_ctx);
    defer std.testing.allocator.free(ported_reply);

    try std.testing.expectEqualStrings(direct_reply, ported_reply);
    try direct_recorder.sameAs(&ported_recorder);
    try std.testing.expectEqual(@as(usize, 0), direct_recorder.count);
    try std.testing.expectEqual(@as(usize, 0), ported_recorder.count);
    try std.testing.expect(!direct_ctx.emitted_text);
    try std.testing.expect(!ported_ctx.emitted_text);
    try expectSameHistory(&direct_session.agent, &ported_session.agent);
}

test "differential: subagent bare turn matches direct agent.turn" {
    const script = [_]scripted.Response{
        .{ .text = "subagent answer" },
    };
    const cfg = testConfig();
    const no_tools = [_]Tool{};

    var direct_obs = EventRecorder{};
    var direct_provider = scripted.ScriptedProvider{ .responses = &script };
    var direct_sm = initManager(&cfg, &direct_provider, &no_tools, null, direct_obs.observer());
    defer direct_sm.deinit();
    const direct_session = try direct_sm.getOrCreate("subagent:direct");
    const direct_reply = try direct_session.agent.turn("do the task");
    defer std.testing.allocator.free(direct_reply);

    var ported_obs = EventRecorder{};
    var ported_provider = scripted.ScriptedProvider{ .responses = &script };
    var ported_sm = initManager(&cfg, &ported_provider, &no_tools, null, ported_obs.observer());
    defer ported_sm.deinit();
    const ported_session = try ported_sm.getOrCreate("subagent:ported");
    var adapter = NativeHarness.init(&ported_session.agent);
    adapter.emit_start_event = false;
    const ported_result = try adapter.harness().runTurn(.{ .user_message = "do the task" });
    defer std.testing.allocator.free(ported_result.reply);

    try std.testing.expectEqualStrings(direct_reply, ported_result.reply);
    try std.testing.expectEqualStrings("subagent answer", ported_result.reply);
    try expectSameHistory(&direct_session.agent, &ported_session.agent);
    try std.testing.expectEqual(direct_provider.call_count, ported_provider.call_count);
    try std.testing.expectEqual(direct_provider.call(0).message_count, ported_provider.call(0).message_count);

    // Bare turn: no agent_start, no callback left installed, blocking path used.
    try std.testing.expectEqual(@as(usize, 0), direct_obs.agent_start);
    try std.testing.expectEqual(@as(usize, 0), ported_obs.agent_start);
    try std.testing.expect(ported_session.agent.stream_callback == null);
    try std.testing.expect(ported_session.agent.progress_callback == null);
    try std.testing.expect(ported_session.agent.drain_injection_cb == null);
}

// ── Test 2b: a progress-only sink (the channel_loop/daemon shape) ────

test "differential: a progress-only sink installs progress but not the stream" {
    const script = [_]scripted.Response{
        .{ .text = "calling probe", .tool_calls = &.{probe_call} },
        .{ .text = "final answer" },
    };
    const cfg = testConfig();
    var noop = observability.NoopObserver{};

    // (a) direct: progress installed, stream left null.
    var direct_probe = ProbeTool{};
    var direct_tools = [_]Tool{direct_probe.tool()};
    var direct_provider = scripted.ScriptedProvider{ .responses = &script };
    var direct_sm = initManager(&cfg, &direct_provider, &direct_tools, null, noop.observer());
    defer direct_sm.deinit();
    const direct_session = try direct_sm.getOrCreate("diff:progress-only-direct");
    direct_session.turn_running.store(true, .release);
    defer direct_session.turn_running.store(false, .release);

    var direct_progress = ProgressRecorder{};
    var direct_runner = DirectRunner{
        .session_key = "diff:progress-only-direct",
        .progress_sink = direct_progress.sink(),
    };
    const direct_reply = try direct_runner.run(&direct_session.agent, "run the probe", null, null);
    defer std.testing.allocator.free(direct_reply);

    // (b) ported: the host passes a sink but live_stream stays false.
    var ported_probe = ProbeTool{};
    var ported_tools = [_]Tool{ported_probe.tool()};
    var ported_provider = scripted.ScriptedProvider{ .responses = &script };
    var ported_sm = initManager(&cfg, &ported_provider, &ported_tools, null, noop.observer());
    defer ported_sm.deinit();
    const ported_session = try ported_sm.getOrCreate("diff:progress-only-ported");
    ported_session.turn_running.store(true, .release);
    defer ported_session.turn_running.store(false, .release);

    var ported_progress = ProgressRecorder{};
    var dual_ctx = DualSink{ .stream = undefined, .progress = ported_progress.sink() };
    var adapter = NativeHarness.init(&ported_session.agent);
    const ported_result = try adapter.harness().runTurn(.{
        .user_message = "run the probe",
        // No live draft: this is the heartbeat-only shape.
        .live_stream = false,
        .sink = .{ .ctx = @ptrCast(&dual_ctx), .emit = DualSink.emit },
    });
    defer std.testing.allocator.free(ported_result.reply);

    try std.testing.expectEqualStrings(direct_reply, ported_result.reply);
    // Golden redetermined after origin/main 5ae2741c: the interim text of a
    // tool round is now part of the reply.
    try std.testing.expectEqualStrings("calling probe\n\nfinal answer", ported_result.reply);
    try direct_progress.sameAs(&ported_progress);
    try std.testing.expect(ported_progress.count > 0);
    // Progress was observed on both paths, streaming was not.
    try std.testing.expect(ported_session.agent.stream_callback == null);
    try std.testing.expect(ported_session.agent.stream_ctx == null);
    // And the callbacks are restored afterwards.
    try std.testing.expect(ported_session.agent.progress_callback == null);
    try std.testing.expect(ported_session.agent.progress_ctx == null);
}

// ── Test 3: the drain injection point is identical ──────────────────

test "differential: drain injection points and history are identical" {
    const script = [_]scripted.Response{
        .{ .text = "calling probe", .tool_calls = &.{probe_call} },
        .{ .text = "final answer" },
    };
    const cfg = testConfig();
    var noop = observability.NoopObserver{};

    var direct_probe = ProbeTool{};
    var direct_tools = [_]Tool{direct_probe.tool()};
    var direct_provider = scripted.ScriptedProvider{ .responses = &script };
    var direct_sm = initManager(&cfg, &direct_provider, &direct_tools, null, noop.observer());
    defer direct_sm.deinit();
    const direct_session = try direct_sm.getOrCreate("diff:drain-direct");
    direct_session.turn_running.store(true, .release);
    defer direct_session.turn_running.store(false, .release);

    var direct_drain = DrainLog{ .allocator = std.testing.allocator, .replies = &.{"mid-turn note"} };
    var direct_runner = DirectRunner{ .session_key = "diff:drain-direct" };
    const direct_reply = try direct_runner.run(
        &direct_session.agent,
        "run the probe",
        DrainLog.callback,
        @ptrCast(&direct_drain),
    );
    defer std.testing.allocator.free(direct_reply);

    var ported_probe = ProbeTool{};
    var ported_tools = [_]Tool{ported_probe.tool()};
    var ported_provider = scripted.ScriptedProvider{ .responses = &script };
    var ported_sm = initManager(&cfg, &ported_provider, &ported_tools, null, noop.observer());
    defer ported_sm.deinit();
    const ported_session = try ported_sm.getOrCreate("diff:drain-ported");
    ported_session.turn_running.store(true, .release);
    defer ported_session.turn_running.store(false, .release);

    var ported_drain = DrainLog{ .allocator = std.testing.allocator, .replies = &.{"mid-turn note"} };
    var adapter = NativeHarness.init(&ported_session.agent);
    const ported_result = try adapter.harness().runTurn(.{
        .user_message = "run the probe",
        .drain = DrainLog.callback,
        .drain_ctx = @ptrCast(&ported_drain),
    });
    defer std.testing.allocator.free(ported_result.reply);

    try std.testing.expectEqualStrings(direct_reply, ported_result.reply);
    // Golden redetermined after origin/main 5ae2741c: the interim text of a
    // tool round is now part of the reply.
    try std.testing.expectEqualStrings("calling probe\n\nfinal answer", ported_result.reply);
    // Same number of drain boundaries, same provider call count.
    try std.testing.expectEqual(direct_drain.count, ported_drain.count);
    try std.testing.expectEqual(direct_provider.call_count, ported_provider.call_count);
    try std.testing.expectEqual(@as(usize, 2), ported_provider.call_count);
    // The drain is asked at every tool boundary (and once more after the final
    // response), and both paths must ask the same number of times.
    try std.testing.expect(ported_drain.count > 0);
    try std.testing.expectEqual(direct_drain.count, ported_drain.count);
    // The injection is drained at the top of the next tool-loop iteration, so
    // it is visible to the second provider call — as a user message, not as the
    // tool-result text.
    try std.testing.expect(providerCallHasUserText(direct_provider.call(1), "mid-turn note"));
    try std.testing.expect(providerCallHasUserText(ported_provider.call(1), "mid-turn note"));

    // Identical history shape.
    const direct_history = try direct_session.agent.getHistory(std.testing.allocator);
    defer std.testing.allocator.free(direct_history);
    const ported_history = try ported_session.agent.getHistory(std.testing.allocator);
    defer std.testing.allocator.free(ported_history);
    try std.testing.expectEqual(direct_history.len, ported_history.len);
    for (direct_history, ported_history) |d, p| {
        try std.testing.expectEqualStrings(d.role, p.role);
        try std.testing.expectEqualStrings(d.content, p.content);
    }
}

/// True when any user message in a recorded provider call is exactly `text`.
fn providerCallHasUserText(record: *const scripted.CallRecord, text: []const u8) bool {
    for (record.recordedMessages()) |msg| {
        if (msg.role == .user and std.mem.eql(u8, msg.text(), text)) return true;
    }
    return false;
}

// ── Test 4: usage_record_callback still fires exactly once per call ──

test "differential: usage ledger callback fires once per provider call through the port" {
    const script = [_]scripted.Response{
        .{ .text = "calling probe", .tool_calls = &.{probe_call} },
        .{ .text = "final answer" },
    };
    const cfg = testConfig();
    var noop = observability.NoopObserver{};

    var probe = ProbeTool{};
    var tools = [_]Tool{probe.tool()};
    var provider = scripted.ScriptedProvider{ .responses = &script };
    var sm = initManager(&cfg, &provider, &tools, null, noop.observer());
    defer sm.deinit();
    const session = try sm.getOrCreate("diff:usage");
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    // The adapter must NOT install or replace this. Session creation installs
    // it once (src/session.zig:1919) when the ledger is enabled; here it is
    // installed by hand to stand in for that one-time install.
    var usage = UsageRecorder{};
    defer usage.deinit();
    session.agent.usage_record_callback = UsageRecorder.callback;
    session.agent.usage_record_ctx = @ptrCast(&usage);

    var adapter = NativeHarness.init(&session.agent);
    const result = try adapter.harness().runTurn(.{ .user_message = "run the probe" });
    defer std.testing.allocator.free(result.reply);

    // Exactly one usage row per provider call, and the callback is untouched.
    try std.testing.expectEqual(@as(usize, 2), usage.count);
    try std.testing.expectEqual(UsageRecorder.callback, session.agent.usage_record_callback);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&usage)), session.agent.usage_record_ctx);
    // Both rows report the same live provider/model as the turn used.
    for (usage.records[0..usage.count]) |record| {
        try std.testing.expectEqualStrings("scripted", record.provider);
        try std.testing.expectEqualStrings(session.agent.model_name, record.model);
        try std.testing.expect(record.success);
    }
    // total_tokens advanced by exactly the two responses' usage.
    try std.testing.expectEqual(
        usage.records[0].usage.total_tokens + usage.records[1].usage.total_tokens,
        result.total_tokens,
    );
}

// ── Test 5: persisted rows are identical ────────────────────────────

test "differential: persisted rows are identical through the port" {
    const script = [_]scripted.Response{.{ .text = "pong" }};
    const cfg = testConfig();
    var noop = observability.NoopObserver{};

    var direct_provider = scripted.ScriptedProvider{ .responses = &script };
    var direct_store = RecordingStore{ .allocator = std.testing.allocator };
    defer direct_store.deinit();
    var direct_sm = initManager(&cfg, &direct_provider, &.{}, direct_store.store(), noop.observer());
    defer direct_sm.deinit();
    const direct_session = try direct_sm.getOrCreate("diff:persist-direct");
    direct_session.turn_running.store(true, .release);
    defer direct_session.turn_running.store(false, .release);
    var direct_runner = DirectRunner{ .session_key = "diff:persist-direct" };
    const direct_reply = try direct_runner.run(&direct_session.agent, "ping", null, null);
    defer std.testing.allocator.free(direct_reply);

    var ported_provider = scripted.ScriptedProvider{ .responses = &script };
    var ported_store = RecordingStore{ .allocator = std.testing.allocator };
    defer ported_store.deinit();
    var ported_sm = initManager(&cfg, &ported_provider, &.{}, ported_store.store(), noop.observer());
    defer ported_sm.deinit();
    const ported_session = try ported_sm.getOrCreate("diff:persist-ported");
    ported_session.turn_running.store(true, .release);
    defer ported_session.turn_running.store(false, .release);
    var adapter = NativeHarness.init(&ported_session.agent);
    const ported_result = try adapter.harness().runTurn(.{ .user_message = "ping" });
    defer std.testing.allocator.free(ported_result.reply);

    // Both turn results carry the same persisted_reply.
    const expected_persisted = turn_persistence.persistedAssistantReply(direct_session.agent.history.items, direct_reply);
    try std.testing.expectEqualStrings(expected_persisted, ported_result.persisted_reply.?);

    // Writing both through the shared persistTurn produces identical rows.
    turn_persistence.persistTurn(direct_store.store(), .{
        .history = direct_session.agent.history.items,
        .total_tokens = direct_session.agent.total_tokens,
    }, "diff:persist-direct", "ping", direct_reply);
    turn_persistence.persistTurn(ported_store.store(), .{
        .history = ported_session.agent.history.items,
        .total_tokens = ported_session.agent.total_tokens,
    }, "diff:persist-ported", "ping", ported_result.persisted_reply);

    try direct_store.expectRows(&.{
        .{ .role = "user", .content = "ping" },
        .{ .role = "assistant", .content = "pong" },
    });
    try ported_store.expectRows(&.{
        .{ .role = "user", .content = "ping" },
        .{ .role = "assistant", .content = "pong" },
    });
}

// ── Test 6: end_reason is interrupted for a /stop-interrupted turn ───

test "differential: end_reason is interrupted after a /stop and completed otherwise" {
    const script = [_]scripted.Response{.{ .text = "calling probe", .tool_calls = &.{probe_call} }};
    const cfg = testConfig();
    var noop = observability.NoopObserver{};

    var probe = ProbeTool{};
    var tools = [_]Tool{probe.tool()};
    var provider = scripted.ScriptedProvider{ .responses = &script };
    var sm = initManager(&cfg, &provider, &tools, null, noop.observer());
    defer sm.deinit();
    const session = try sm.getOrCreate("diff:stop");
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    var adapter = NativeHarness.init(&session.agent);
    // The /stop flag is set the way the host sets it before the turn runs.
    session.agent.requestInterrupt();
    const result = try adapter.harness().runTurn(.{ .user_message = "stop me" });
    defer std.testing.allocator.free(result.reply);

    try std.testing.expectEqual(port.EndReason.interrupted, result.end_reason);
    try std.testing.expect(session.agent.last_turn_interrupted);
    // The provider is never called: the interrupt is honored at the top.
    try std.testing.expectEqual(@as(usize, 0), provider.call_count);
    // Regression: the interrupted reply must not be dropped.
    try std.testing.expect(std.mem.indexOf(u8, result.reply, "Interrupted by /stop") != null);

    // A second, uninterrupted turn is `completed`.
    var probe2 = ProbeTool{};
    var tools2 = [_]Tool{probe2.tool()};
    var provider2 = scripted.ScriptedProvider{ .responses = &.{.{ .text = "answered" }} };
    var sm2 = initManager(&cfg, &provider2, &tools2, null, noop.observer());
    defer sm2.deinit();
    const session2 = try sm2.getOrCreate("diff:clean");
    session2.turn_running.store(true, .release);
    defer session2.turn_running.store(false, .release);
    var adapter2 = NativeHarness.init(&session2.agent);
    const result2 = try adapter2.harness().runTurn(.{ .user_message = "hello" });
    defer std.testing.allocator.free(result2.reply);
    try std.testing.expectEqual(port.EndReason.completed, result2.end_reason);
    try std.testing.expect(!session2.agent.last_turn_interrupted);
}

// ── Test 7: interrupt clear / activeToolName / lifecycle mapping ────

test "differential: lifecycle methods map to the agent's own state" {
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    var provider = scripted.ScriptedProvider{ .responses = &.{} };
    var sm = initManager(&cfg, &provider, &.{}, null, noop.observer());
    defer sm.deinit();
    const session = try sm.getOrCreate("diff:lifecycle");
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    var adapter = NativeHarness.init(&session.agent);
    const h = adapter.harness();

    h.requestInterrupt();
    try std.testing.expect(session.agent.interrupt_requested.load(.acquire));
    h.clearInterrupt();
    try std.testing.expect(!session.agent.interrupt_requested.load(.acquire));

    // activeToolName is empty before a tool runs.
    const tool = try h.activeToolName(std.testing.allocator);
    defer if (tool) |t| std.testing.allocator.free(t);
    try std.testing.expect(tool == null);

    // info() reads live agent values.
    const info = h.info();
    try std.testing.expectEqualStrings(session.agent.model_name, info.model_name);
    try std.testing.expectEqualStrings("scripted", info.provider_name);
    try std.testing.expectEqualStrings(session.agent.workspace_dir, info.workspace_dir);
    try std.testing.expectEqual(session.agent.queue_mode, info.queue_mode);
    try std.testing.expectEqual(session.agent.reasoning_mode, info.reasoning_mode);
    try std.testing.expectEqual(session.agent.has_own_autonomy, info.has_own_autonomy);
    try std.testing.expectEqual(session.agent.redactor, info.redactor);

    // invalidatePrompt clears the prompt fingerprint flag.
    session.agent.has_system_prompt = true;
    h.invalidatePrompt();
    try std.testing.expect(!session.agent.has_system_prompt);

    // reset() clears history, tokens and pending exec state.
    session.agent.total_tokens = 123;
    h.reset();
    try std.testing.expectEqual(@as(u64, 0), session.agent.total_tokens);
    try std.testing.expectEqual(@as(usize, 0), session.agent.history.items.len);

    // restore() replays runtime-command rows as commands and the rest as history.
    const entries = [_]memory_mod.MessageEntry{
        .{ .role = "user", .content = "restored question" },
        .{ .role = "assistant", .content = "restored answer" },
        .{ .role = memory_mod.RUNTIME_COMMAND_ROLE, .content = "/usage tokens" },
    };
    try h.restore(.{ .messages = &entries, .total_tokens = 77, .compaction_count = 3 });
    try std.testing.expectEqual(@as(u64, 77), session.agent.total_tokens);
    try std.testing.expectEqual(@as(u64, 3), session.agent.compaction_count);
    const history = try session.agent.getHistory(std.testing.allocator);
    defer std.testing.allocator.free(history);
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqualStrings("restored question", history[0].content);
    try std.testing.expectEqualStrings("restored answer", history[1].content);
}

// ── Test 8: the host seam routes through the port ───────────────────

test "differential: SessionManager turns go through the port vtable" {
    const script = [_]scripted.Response{.{ .text = "pong", .chunks = &.{"pong"} }};
    const cfg = testConfig();
    var noop = observability.NoopObserver{};

    var provider = scripted.ScriptedProvider{ .responses = &script };
    var sm = initManager(&cfg, &provider, &.{}, null, noop.observer());
    defer sm.deinit();

    // The host entry point is unchanged; the seam now runs through the port.
    var stream = StreamRecorder{};
    const reply = try sm.processMessageStreamingWithSteerSink(
        "diff:seam",
        "ping",
        null,
        stream.sink(),
        null,
        null,
    );
    defer std.testing.allocator.free(reply);

    try std.testing.expectEqualStrings("pong", reply);
    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expectEqual(@as(usize, 2), stream.count);
    try std.testing.expectEqual(streaming.OutboundStage.chunk, stream.at(0).stage);
    try std.testing.expectEqualStrings("pong", stream.at(0).text());
    try std.testing.expectEqual(streaming.OutboundStage.final, stream.at(1).stage);

    const session = try sm.getOrCreate("diff:seam");
    try std.testing.expect(session.nativeAgent() == &session.agent);
    try std.testing.expect(session.agent.history.items.len >= 3);
}
