//! Golden trace for the streaming turn path.
//!
//! Every expected value here is a literal: the point is that a later refactor
//! (routing the turn through a port) must reproduce these exact sequences.
//! `processMessageStreamingWithSteerSink` is the host entry point under test.

const std = @import("std");
const scripted = @import("test_provider.zig");
const session_mod = @import("../session.zig");
const agent_mod = @import("../agent/root.zig");
const streaming = @import("../streaming.zig");
const memory_mod = @import("../memory/root.zig");
const tools_mod = @import("../tools/root.zig");
const observability = @import("../observability.zig");
const config_mod = @import("../config.zig");

const SessionManager = session_mod.SessionManager;
const Config = config_mod.Config;
const Tool = tools_mod.Tool;

fn testConfig() Config {
    return .{
        .workspace_dir = "/tmp/junclaw_harness_test",
        .config_path = "/tmp/junclaw_harness_test/config.json",
        .default_model = "test/scripted-model",
        .allocator = std.testing.allocator,
    };
}

fn initManager(
    cfg: *const Config,
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

fn expectRoles(record: *const scripted.CallRecord, expected: []const scripted.Role) !void {
    try std.testing.expectEqual(expected.len, record.message_count);
    const recorded = record.recordedMessages();
    try std.testing.expectEqual(expected.len, recorded.len);
    for (expected, 0..) |role, i| try std.testing.expectEqual(role, recorded[i].role);
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
};

const ObserverRecorder = struct {
    const Kind = enum {
        agent_start,
        llm_request,
        llm_response,
        tool_call_start,
        tool_call,
        turn_complete,
        agent_end,
        other,
    };

    const Record = struct {
        kind: Kind,
        success: bool = true,
        len: usize = 0,
        buf: [32]u8 = undefined,

        fn text(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };

    records: [32]Record = undefined,
    count: usize = 0,
    event_count: usize = 0,

    fn observer(self: *ObserverRecorder) observability.Observer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = observability.Observer.VTable{
        .record_event = recordEvent,
        .record_metric = recordMetric,
        .flush = flush,
        .name = name,
        .get_trace_id = getTraceId,
        .set_trace_id = setTraceId,
    };

    fn recordEvent(ctx: *anyopaque, event: *const observability.ObserverEvent) void {
        const self: *ObserverRecorder = @ptrCast(@alignCast(ctx));
        self.event_count += 1;
        if (self.count >= self.records.len) return;
        const record = &self.records[self.count];
        self.count += 1;
        record.* = .{ .kind = .other };
        record.kind = switch (event.*) {
            .agent_start => .agent_start,
            .llm_request => .llm_request,
            .llm_response => |e| blk: {
                record.success = e.success;
                break :blk .llm_response;
            },
            .tool_call_start => |e| blk: {
                copyText(record, e.tool);
                break :blk .tool_call_start;
            },
            .tool_call => |e| blk: {
                copyText(record, e.tool);
                record.success = e.success;
                break :blk .tool_call;
            },
            .turn_complete => .turn_complete,
            .agent_end => .agent_end,
            else => .other,
        };
    }

    fn copyText(record: *Record, text: []const u8) void {
        record.len = @min(text.len, record.buf.len);
        @memcpy(record.buf[0..record.len], text[0..record.len]);
    }

    fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn flush(_: *anyopaque) void {}
    fn name(_: *anyopaque) []const u8 {
        return "golden";
    }
    fn getTraceId(_: *anyopaque) ?[32]u8 {
        return null;
    }
    fn setTraceId(_: *anyopaque, _: [32]u8) void {}

    fn at(self: *const ObserverRecorder, index: usize) *const Record {
        return &self.records[index];
    }
};

// ── Recording session store ─────────────────────────────────────────

const RecordingStore = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    inject: ?*InjectCtx = null,

    const Row = struct {
        role: []u8,
        content: []u8,
    };

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
        // Persistence runs after the primary turn and before the post-turn
        // drain, so firing here reproduces a message arriving in that window.
        if (self.inject) |ctx| ctx.fire();
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
    /// Optional stop hook: runs inside execute(), like a /stop landing mid-tool.
    manager: ?*SessionManager = null,
    session_key: []const u8 = "",
    injected: ?SessionManager.InboundRouteAction = null,

    pub const tool_name = "probe";
    pub const tool_description = "Golden-trace probe tool";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
    const vtable = tools_mod.ToolVTable(@This());

    fn tool(self: *@This()) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *@This(), allocator: std.mem.Allocator, _: tools_mod.JsonObjectMap) !tools_mod.ToolResult {
        self.executions += 1;
        if (self.manager) |manager| {
            self.injected = manager.routeInbound(self.session_key, "steered while busy");
            var interrupt = manager.requestTurnInterrupt(self.session_key);
            interrupt.deinit(manager.allocator);
        }
        return .{ .success = true, .output = try allocator.dupe(u8, "probe ok") };
    }
};

const native_probe_call = scripted.ToolCallSpec{
    .id = "call-probe",
    .name = ProbeTool.tool_name,
    .arguments = "{}",
};

// ── Trace 1: stream event order ─────────────────────────────────────

test "golden: stream events for one text turn" {
    var provider = scripted.ScriptedProvider{
        .responses = &.{.{
            .text = "Hello, world!",
            .chunks = &.{ "Hello, ", "world!" },
        }},
    };
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    var sm = initManager(&cfg, &provider, &.{}, null, noop.observer());
    defer sm.deinit();

    var events = StreamRecorder{};
    const reply = try sm.processMessageStreamingWithSteerSink(
        "golden:stream",
        "say hello",
        null,
        events.sink(),
        null,
        null,
    );
    defer std.testing.allocator.free(reply);

    const Expected = struct { stage: streaming.OutboundStage, text: []const u8 };
    const expected = [_]Expected{
        .{ .stage = .chunk, .text = "Hello, " },
        .{ .stage = .chunk, .text = "world!" },
        .{ .stage = .final, .text = "" },
    };

    try std.testing.expectEqualStrings("Hello, world!", reply);
    try std.testing.expectEqual(expected.len, events.count);
    for (expected, 0..) |want, i| {
        try std.testing.expectEqual(want.stage, events.at(i).stage);
        try std.testing.expectEqualStrings(want.text, events.at(i).text());
    }
}

// ── Trace 2: progress + observer order for a tool turn ──────────────

test "golden: progress hints and observer events for one tool turn" {
    var provider = scripted.ScriptedProvider{
        .responses = &.{
            .{ .text = "calling probe", .tool_calls = &.{native_probe_call} },
            .{ .text = "final answer" },
        },
    };
    const cfg = testConfig();
    var recorder = ObserverRecorder{};
    var probe = ProbeTool{};
    var tools = [_]Tool{probe.tool()};
    var sm = initManager(&cfg, &provider, &tools, null, recorder.observer());
    defer sm.deinit();

    var progress = ProgressRecorder{};
    const reply = try sm.processMessageStreamingWithSteerSink(
        "golden:tool",
        "run the probe",
        null,
        null,
        progress.sink(),
        null,
    );
    defer std.testing.allocator.free(reply);

    // Golden redetermined after origin/main 5ae2741c: the interim text of a
    // tool round is now part of the reply.
    try std.testing.expectEqualStrings("calling probe\n\nfinal answer", reply);
    try std.testing.expectEqual(@as(usize, 1), probe.executions);
    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
    // Tools stay offered to the provider after a tool result.
    try std.testing.expectEqual(@as(usize, 1), provider.call(0).tool_spec_count);
    try std.testing.expectEqual(@as(usize, 1), provider.call(1).tool_spec_count);

    const ExpectedHint = struct {
        kind: agent_mod.ProgressKind,
        phase: agent_mod.ProgressPhase,
        text: []const u8,
        success: bool,
        has_arguments: bool,
    };
    const expected_hints = [_]ExpectedHint{
        .{ .kind = .tool, .phase = .start, .text = "probe", .success = true, .has_arguments = true },
        .{ .kind = .tool, .phase = .end, .text = "probe", .success = true, .has_arguments = false },
    };
    try std.testing.expectEqual(expected_hints.len, progress.count);
    for (expected_hints, 0..) |want, i| {
        try std.testing.expectEqual(want.kind, progress.at(i).kind);
        try std.testing.expectEqual(want.phase, progress.at(i).phase);
        try std.testing.expectEqualStrings(want.text, progress.at(i).text());
        try std.testing.expectEqual(want.success, progress.at(i).success);
        try std.testing.expectEqual(want.has_arguments, progress.at(i).has_arguments);
    }

    const ExpectedEvent = struct {
        kind: ObserverRecorder.Kind,
        text: []const u8 = "",
        success: bool = true,
    };
    const expected_events = [_]ExpectedEvent{
        .{ .kind = .agent_start },
        .{ .kind = .llm_request },
        .{ .kind = .llm_response },
        .{ .kind = .tool_call_start, .text = "probe" },
        .{ .kind = .tool_call, .text = "probe" },
        .{ .kind = .llm_request },
        .{ .kind = .llm_response },
        .{ .kind = .turn_complete },
    };
    try std.testing.expectEqual(expected_events.len, recorder.event_count);
    for (expected_events, 0..) |want, i| {
        try std.testing.expectEqual(want.kind, recorder.at(i).kind);
        try std.testing.expectEqualStrings(want.text, recorder.at(i).text());
        try std.testing.expectEqual(want.success, recorder.at(i).success);
    }
}

// ── Trace 3: mid-turn injection drained at the next tool boundary ───

const InjectCtx = struct {
    manager: *SessionManager,
    session_key: []const u8,
    text: []const u8,
    fired: bool = false,
    action: ?SessionManager.InboundRouteAction = null,

    fn onChat(ptr: *anyopaque) void {
        const self: *InjectCtx = @ptrCast(@alignCast(ptr));
        if (self.fired) return;
        self.fired = true;
        self.action = self.manager.routeInbound(self.session_key, self.text);
    }

    fn fire(self: *InjectCtx) void {
        onChat(@ptrCast(self));
    }
};

test "golden: mid-turn injection is drained before the next provider call" {
    var provider = scripted.ScriptedProvider{
        .responses = &.{
            .{ .text = "calling probe", .tool_calls = &.{native_probe_call} },
            .{ .text = "final answer" },
        },
    };
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    var probe = ProbeTool{};
    var tools = [_]Tool{probe.tool()};
    var sm = initManager(&cfg, &provider, &tools, null, noop.observer());
    defer sm.deinit();

    var ctx = InjectCtx{
        .manager = &sm,
        .session_key = "golden:drain",
        .text = "mid-turn note",
    };
    provider.on_chat = InjectCtx.onChat;
    provider.on_chat_ctx = @ptrCast(&ctx);

    const reply = try sm.processMessageStreamingWithSteerSink(
        "golden:drain",
        "run the probe",
        null,
        null,
        null,
        null,
    );
    defer std.testing.allocator.free(reply);

    // Golden redetermined after origin/main 5ae2741c: the interim text of a
    // tool round is now part of the reply.
    try std.testing.expectEqualStrings("calling probe\n\nfinal answer", reply);
    try std.testing.expectEqual(SessionManager.InboundRouteAction.steered, ctx.action.?);
    try std.testing.expectEqual(@as(usize, 2), provider.call_count);

    // The injection must be visible to the provider only on the second call.
    const first = provider.call(0);
    const second = provider.call(1);
    try std.testing.expectEqualStrings("run the probe", first.lastUserText());
    try std.testing.expectEqualStrings("mid-turn note", second.lastUserText());
    // The injection is drained at the top of the next tool-loop iteration,
    // after the tool result and immediately before the provider call.
    try std.testing.expectEqual(@as(usize, 2), first.message_count);
    try std.testing.expectEqual(@as(usize, 5), second.message_count);
    try expectRoles(first, &.{ .system, .user });
    try expectRoles(second, &.{ .system, .user, .assistant, .user, .user });

    try std.testing.expectEqual(scripted.Role.user, second.recordedMessages()[second.recordedMessages().len - 1].role);
}

// ── Trace 4: persisted rows ─────────────────────────────────────────

test "golden: one turn persists user then assistant rows" {
    var provider = scripted.ScriptedProvider{ .responses = &.{.{ .text = "pong" }} };
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    var store = RecordingStore{ .allocator = std.testing.allocator };
    defer store.deinit();
    var sm = initManager(&cfg, &provider, &.{}, store.store(), noop.observer());
    defer sm.deinit();

    const reply = try sm.processMessageStreamingWithSteerSink(
        "golden:persist",
        "ping",
        null,
        null,
        null,
        null,
    );
    defer std.testing.allocator.free(reply);

    try std.testing.expectEqualStrings("pong", reply);
    try store.expectRows(&.{
        .{ .role = "user", .content = "ping" },
        .{ .role = "assistant", .content = "pong" },
    });
}

// ── Trace 5: /stop during a tool call ───────────────────────────────

test "golden: /stop during a tool call ends the turn and drops follow-ups" {
    var provider = scripted.ScriptedProvider{
        .responses = &.{
            .{ .text = "calling probe", .tool_calls = &.{native_probe_call} },
            .{ .text = "must not run" },
        },
    };
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    var store = RecordingStore{ .allocator = std.testing.allocator };
    defer store.deinit();
    var probe = ProbeTool{};
    var tools = [_]Tool{probe.tool()};
    const session_key = "golden:stop";
    var sm = initManager(&cfg, &provider, &tools, store.store(), noop.observer());
    defer sm.deinit();
    probe.manager = &sm;
    probe.session_key = session_key;

    const reply = try sm.processMessageStreamingWithSteerSink(
        session_key,
        "stop me",
        null,
        null,
        null,
        null,
    );
    defer std.testing.allocator.free(reply);

    const expected_prefix = "calling probe\n\nInterrupted by /stop. Halting tool execution for this turn.";
    try std.testing.expectEqualStrings(
        "calling probe\n\nInterrupted by /stop. Halting tool execution for this turn.\n\n[Pending message(s) discarded by /stop. Please resend.]",
        reply,
    );
    try std.testing.expectEqual(SessionManager.InboundRouteAction.steered, probe.injected.?);
    // No follow-up turn: the provider ran exactly once.
    try std.testing.expectEqual(@as(usize, 1), provider.call_count);

    try store.expectRows(&.{
        .{ .role = "user", .content = "stop me" },
        .{ .role = "assistant", .content = expected_prefix },
    });
}

// ── Trace 6: post-turn follow-up ────────────────────────────────────

test "golden: late injection runs as a follow-up and replies are combined" {
    var provider = scripted.ScriptedProvider{
        .responses = &.{
            .{ .text = "first reply" },
            .{ .text = "follow-up reply" },
        },
    };
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    var store = RecordingStore{ .allocator = std.testing.allocator };
    defer store.deinit();
    var sm = initManager(&cfg, &provider, &.{}, store.store(), noop.observer());
    defer sm.deinit();

    var ctx = InjectCtx{
        .manager = &sm,
        .session_key = "golden:follow-up",
        .text = "late note",
    };
    store.inject = &ctx;

    const reply = try sm.processMessageStreamingWithSteerSink(
        "golden:follow-up",
        "hello",
        null,
        null,
        null,
        null,
    );
    defer std.testing.allocator.free(reply);

    try std.testing.expectEqualStrings("first reply\n\nfollow-up reply", reply);
    try std.testing.expectEqual(SessionManager.InboundRouteAction.steered, ctx.action.?);
    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
    try std.testing.expectEqualStrings("hello", provider.call(0).lastUserText());
    try std.testing.expectEqualStrings("late note", provider.call(1).lastUserText());
    try expectRoles(provider.call(0), &.{ .system, .user });
    try expectRoles(provider.call(1), &.{ .system, .user, .assistant, .user });

    try store.expectRows(&.{
        .{ .role = "user", .content = "hello" },
        .{ .role = "assistant", .content = "first reply" },
        .{ .role = "user", .content = "late note" },
        .{ .role = "assistant", .content = "follow-up reply" },
    });
}
