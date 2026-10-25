//! DshHarness tests against the in-process dsh mock (no Node, no real dsh).

const std = @import("std");
const builtin = @import("builtin");
const std_compat = @import("compat");
const fs_compat = @import("../../fs_compat.zig");
const config_types = @import("../../config_types.zig");
const port = @import("../port.zig");
const harness_mod = @import("harness.zig");
const client_mod = @import("client.zig");
const mock_mod = @import("mock.zig");
const sidecar_mod = @import("sidecar.zig");
const profile_mod = @import("profile.zig");

const Allocator = std.mem.Allocator;
const DshEngine = harness_mod.DshEngine;
const DshHarness = harness_mod.DshHarness;
const MockDsh = mock_mod.MockDsh;

const test_cwd = "/workspace";

fn bootUrl(allocator: Allocator, mock: *MockDsh) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/?token={s}",
        .{ mock.port(), mock_mod.test_token },
    );
}

fn newEngine(
    allocator: Allocator,
    boot_url: []const u8,
    session_file: ?[]const u8,
) !*DshEngine {
    const engine = try allocator.create(DshEngine);
    engine.* = DshEngine.init(allocator, .{
        .sidecar = .{ .bin_js = "unused", .workspace = test_cwd, .dsh_home = "/tmp/dsh-home" },
        .boot_url = boot_url,
        .session_file = session_file,
        .turn_timeout_ms = 5_000,
        .cancel_timeout_ms = 5_000,
    });
    return engine;
}

fn freeEngine(engine: *DshEngine) void {
    const allocator = engine.allocator;
    engine.deinit();
    allocator.destroy(engine);
}

/// Test seam standing in for the sidecar process: each call "boots" the mock
/// and returns its URL. Tests script failures to model a crash loop.
const SpawnCtl = struct {
    mock: *MockDsh,
    /// Successful and failed spawn calls, including the initial boot.
    calls: u32 = 0,
    /// Fail this many recovery calls (never the initial boot).
    fail_calls: u32 = 0,

    fn spawn(ctx: ?*anyopaque, allocator: Allocator) anyerror![]u8 {
        const self: *SpawnCtl = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        if (self.calls > 1) {
            if (self.fail_calls > 0) {
                self.fail_calls -= 1;
                return error.ConnectionRefused;
            }
            self.mock.revive();
        }
        return std.fmt.allocPrint(
            allocator,
            "http://127.0.0.1:{d}/?token={s}",
            .{ self.mock.port(), mock_mod.test_token },
        );
    }
};

/// Engine that owns a (simulated) sidecar, so crash recovery is enabled.
fn newManagedEngine(
    allocator: Allocator,
    ctl: *SpawnCtl,
    session_file: ?[]const u8,
) !*DshEngine {
    const engine = try allocator.create(DshEngine);
    engine.* = DshEngine.init(allocator, .{
        .sidecar = .{ .bin_js = "unused", .workspace = test_cwd, .dsh_home = "/tmp/dsh-home" },
        .session_file = session_file,
        .turn_timeout_ms = 5_000,
        .cancel_timeout_ms = 5_000,
    });
    engine.spawn_override = SpawnCtl.spawn;
    engine.spawn_ctx = ctl;
    return engine;
}

/// Absolute path inside a test tmp dir, so the harness can create the file.
fn tempSessionFile(allocator: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const dir = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "session.json" });
}

/// The per-key mapping path the harness derives (`{dir}/{Wyhash(key)}.json`).
fn keySessionFile(allocator: Allocator, base_file: []const u8, key: []const u8) ![]u8 {
    const dir = std_compat.fs.path.dirname(base_file) orelse ".";
    return std.fmt.allocPrint(allocator, "{s}/{x}.json", .{
        dir,
        std.hash.Wyhash.hash(0, key),
    });
}

/// Run one turn for `key`, the way the host sets `session_key` first.
fn runOneTurn(h: *DshHarness, message: []const u8) !port.TurnResult {
    return h.harness().runTurn(.{ .user_message = message });
}

fn endFrame(allocator: Allocator, kind: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"item\",\"streamId\":\"follow\",\"value\":{{\"type\":\"event\"," ++
            "\"event\":{{\"type\":\"turn/end\",\"data\":{{\"reason\":{{\"kind\":\"{s}\"}}}}}}}}}}",
        .{kind},
    );
}

/// The dsh error shape: `reason.error.message`.
fn errorEndFrame(allocator: Allocator, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"item\",\"streamId\":\"follow\",\"value\":{{\"type\":\"event\"," ++
            "\"event\":{{\"type\":\"turn/end\",\"data\":{{\"reason\":{{\"kind\":\"error\"," ++
            "\"error\":{{\"message\":{f}}}}}}}}}}}}}",
        .{std.json.fmt(message, .{})},
    );
}

/// Script the frames streamed after the next prompt: text deltas in order,
/// then a terminal `turn/end` when `end_kind` is non-null.
fn setTurnFrames(
    mock: *MockDsh,
    allocator: Allocator,
    texts: []const []const u8,
    end_kind: ?[]const u8,
) !void {
    var frames: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (frames.items) |frame| allocator.free(frame);
        frames.deinit(allocator);
    }
    for (texts, 0..) |text, index| {
        try frames.append(allocator, try mock_mod.textDeltaFrame(allocator, @intCast(index), text));
    }
    if (end_kind) |kind| try frames.append(allocator, try endFrame(allocator, kind));
    try mock.setTurnFrames(frames.items);
}

/// Copies deltas (the port's payload is borrowed only inside emit) and can hold
/// the turn inside a delta until the test releases it.
const RecordingSink = struct {
    buffer: [1024]u8 = undefined,
    len: std.atomic.Value(usize) = .init(0),
    progress: std.atomic.Value(u32) = .init(0),
    block_after: usize = std.math.maxInt(usize),
    released: std.atomic.Value(bool) = .init(true),

    fn sink(self: *RecordingSink) port.Sink {
        return .{ .ctx = @ptrCast(self), .emit = emit };
    }

    fn emit(ctx: *anyopaque, event: port.Event) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        switch (event) {
            .delta => |chunk| {
                const start = self.len.load(.monotonic);
                const n = @min(chunk.delta.len, self.buffer.len - start);
                @memcpy(self.buffer[start .. start + n], chunk.delta[0..n]);
                self.len.store(start + n, .release);
                if (start + n >= self.block_after) {
                    while (!self.released.load(.acquire)) {
                        std_compat.thread.sleep(std.time.ns_per_ms);
                    }
                }
            },
            .progress => _ = self.progress.fetchAdd(1, .monotonic),
            .usage => {},
            else => {},
        }
    }

    fn text(self: *const RecordingSink) []const u8 {
        return self.buffer[0..self.len.load(.acquire)];
    }
};

const TurnThread = struct {
    harness: *DshHarness,
    input: port.TurnInput,
    result: ?port.TurnResult = null,
    failure: ?anyerror = null,

    fn main(self: *TurnThread) void {
        if (self.harness.harness().runTurn(self.input)) |result| {
            self.result = result;
        } else |err| {
            self.failure = err;
        }
    }
};

/// Hang guard, never asserted: returns after 5s even if no delta arrived.
fn waitForSink(sink: *RecordingSink, at_least: usize) void {
    const deadline = std_compat.time.milliTimestamp() + 5_000;
    while (sink.len.load(.acquire) < at_least and std_compat.time.milliTimestamp() < deadline) {
        std_compat.thread.sleep(std.time.ns_per_ms);
    }
}

/// Hang guard, never asserted: returns after 5s even if no prompt arrived.
fn waitForPrompt(mock: *MockDsh, at_least: u32) void {
    const deadline = std_compat.time.milliTimestamp() + 5_000;
    while (mock.promptCount() < at_least and std_compat.time.milliTimestamp() < deadline) {
        std_compat.thread.sleep(std.time.ns_per_ms);
    }
}

/// Hang guard, never asserted: waits until the subscription has queued frames.
fn waitForQueued(sub: *client_mod.Subscription, at_least: usize) void {
    const deadline = std_compat.time.milliTimestamp() + 5_000;
    while (sub.queuedCount() < at_least and std_compat.time.milliTimestamp() < deadline) {
        std_compat.thread.sleep(std.time.ns_per_ms);
    }
}

test "dsh harness adopts a persisted session on the key's first turn" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session_file = try tempSessionFile(allocator, &tmp);
    defer allocator.free(session_file);
    const mapping = try keySessionFile(allocator, session_file, "test-key");
    defer allocator.free(mapping);
    try sidecar_mod.saveSessionId(mapping, mock_mod.session_id);

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);

    const engine = try newEngine(allocator, boot_url, session_file);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    // Adoption is lazy: no WS until the key's first turn.
    try std.testing.expectEqual(@as(u32, 0), mock.wsConnections());

    try setTurnFrames(mock, allocator, &.{"resumed"}, "completed");
    const result = try runOneTurn(&h, "hi");
    defer allocator.free(result.reply);
    try std.testing.expectEqualStrings("resumed", result.reply);
    try std.testing.expectEqual(@as(u32, 0), mock.createCount());
    try std.testing.expectEqual(@as(u32, 1), mock.wsConnections());
    const prompted = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(prompted);
    try std.testing.expectEqualStrings(mock_mod.session_id, prompted);
}

test "dsh harness streams ordered deltas and completes" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    try setTurnFrames(mock, allocator, &.{ "alpha ", "beta ", "gamma" }, "completed");
    var sink = RecordingSink{};
    const result = try h.harness().runTurn(.{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    });
    defer allocator.free(result.reply);

    try std.testing.expectEqualStrings("alpha beta gamma", sink.text());
    try std.testing.expectEqualStrings("alpha beta gamma", result.reply);
    try std.testing.expectEqual(port.EndReason.completed, result.end_reason);
    try std.testing.expectEqual(@as(u32, 1), mock.createCount());
}

test "dsh committed assistant/message is the turn reply" {
    // Regression: committed assistant/message was parsed as .unknown and dropped.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    const committed = try mock_mod.committedMessageFrame(allocator, "final answer", false);
    defer allocator.free(committed);
    const end = try endFrame(allocator, "completed");
    defer allocator.free(end);
    try mock.setTurnFrames(&.{ committed, end });

    var sink = RecordingSink{};
    const result = try h.harness().runTurn(.{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    });
    defer allocator.free(result.reply);

    try std.testing.expectEqualStrings("final answer", result.reply);
    try std.testing.expectEqualStrings("", sink.text());
    try std.testing.expectEqual(port.EndReason.completed, result.end_reason);
}

test "dsh delta and committed reply exactly once" {
    // Regression: committed assistant/message was parsed as .unknown and dropped.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    const delta = try mock_mod.textDeltaFrame(allocator, 0, "alpha ");
    defer allocator.free(delta);
    const committed = try mock_mod.committedMessageFrame(allocator, "alpha beta", false);
    defer allocator.free(committed);
    const end = try endFrame(allocator, "completed");
    defer allocator.free(end);
    try mock.setTurnFrames(&.{ delta, committed, end });

    var sink = RecordingSink{};
    const result = try h.harness().runTurn(.{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    });
    defer allocator.free(result.reply);

    try std.testing.expectEqualStrings("alpha ", sink.text());
    try std.testing.expectEqualStrings("alpha beta", result.reply);
    try std.testing.expectEqual(port.EndReason.completed, result.end_reason);
}

test "dsh /stop keeps a committed partial with no deltas" {
    // Regression: committed assistant/message was parsed as .unknown and dropped.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    // No terminal frame from the prompt: the turn stays in flight until /stop;
    // cancelling then commits the delivered prefix before the aborted turn/end.
    const partial = try mock_mod.committedMessageFrame(allocator, "partial answer", true);
    defer allocator.free(partial);
    try mock.setCancelFrames(&.{partial});

    var sink = RecordingSink{};
    var turn = TurnThread{ .harness = &h, .input = .{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    } };
    const thread = try std.Thread.spawn(.{}, TurnThread.main, .{&turn});

    waitForPrompt(mock, 1);
    const ack = try h.harness().handleLocalCommand("/stop");
    try std.testing.expectEqualStrings("No active background task to stop.", ack.?);

    thread.join();
    try std.testing.expect(turn.failure == null);
    const result = turn.result.?;
    defer allocator.free(result.reply);

    try std.testing.expectEqualStrings("partial answer", result.reply);
    try std.testing.expectEqual(port.EndReason.interrupted, result.end_reason);
    try std.testing.expectEqual(@as(u32, 1), mock.cancelCount());
}

test "dsh /stop racing a finished turn keeps the streamed reply" {
    // Regression: when the turn ended between the /stop flag and the RPC, dsh
    // answered session/not-found; cancelOn turned that into error.RpcFailed and
    // runTurn's errdefer dropped the reply the user had already seen.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    // The turn streams one delta and completes; the sink holds the turn thread
    // after the delta, so /stop lands while the terminal frame is already out.
    const delta = try mock_mod.textDeltaFrame(allocator, 0, "partial");
    defer allocator.free(delta);
    const end = try endFrame(allocator, "completed");
    defer allocator.free(end);
    try mock.setTurnFrames(&.{ delta, end });
    // By the time the cancel RPC arrives the agent is detached.
    mock.setCancelNotFound(true);

    var sink = RecordingSink{
        .block_after = 0,
        .released = std.atomic.Value(bool).init(false),
    };
    var turn = TurnThread{ .harness = &h, .input = .{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    } };
    const thread = try std.Thread.spawn(.{}, TurnThread.main, .{&turn});

    waitForSink(&sink, 1);
    const ack = try h.harness().handleLocalCommand("/stop");
    try std.testing.expectEqualStrings("No active background task to stop.", ack.?);
    sink.released.store(true, .release);

    thread.join();
    try std.testing.expect(turn.failure == null);
    const result = turn.result.?;
    defer allocator.free(result.reply);
    try std.testing.expectEqualStrings("partial", result.reply);
    try std.testing.expectEqual(port.EndReason.interrupted, result.end_reason);
    try std.testing.expectEqual(@as(u32, 1), mock.cancelCount());
}

test "dsh turn/end kinds map to port end reasons" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    const cases = [_]struct { kind: []const u8, want: port.EndReason }{
        .{ .kind = "completed", .want = .completed },
        .{ .kind = "interrupted", .want = .interrupted },
        .{ .kind = "aborted", .want = .interrupted },
        .{ .kind = "error", .want = .failed },
        .{ .kind = "blocked", .want = .blocked },
        .{ .kind = "max-tokens", .want = .max_tokens },
        .{ .kind = "forked", .want = .completed },
    };

    for (cases) |case| {
        try setTurnFrames(mock, allocator, &.{"x"}, case.kind);
        const result = try h.harness().runTurn(.{ .user_message = "hi" });
        defer allocator.free(result.reply);
        try std.testing.expectEqual(case.want, result.end_reason);
        try std.testing.expectEqualStrings("x", result.reply);
    }
}

test "dsh turn/end error carries the failure message" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    const frame = try errorEndFrame(allocator, "provider exploded");
    defer allocator.free(frame);
    try mock.setTurnFrames(&.{frame});

    const result = try h.harness().runTurn(.{ .user_message = "hi" });
    defer allocator.free(result.reply);
    defer if (result.@"error") |message| allocator.free(message);
    try std.testing.expectEqual(port.EndReason.failed, result.end_reason);
    try std.testing.expectEqualStrings("provider exploded", result.@"error".?);
}

test "dsh /stop cancels mid-stream and keeps partial text" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    // No terminal frame: the turn stays in flight until /stop lands.
    try setTurnFrames(mock, allocator, &.{ "part one ", "part two" }, null);

    var sink = RecordingSink{};
    var turn = TurnThread{ .harness = &h, .input = .{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    } };
    const thread = try std.Thread.spawn(.{}, TurnThread.main, .{&turn});

    waitForSink(&sink, 1);
    const ack = try h.harness().handleLocalCommand("/stop");
    try std.testing.expectEqualStrings("No active background task to stop.", ack.?);

    thread.join();
    try std.testing.expect(turn.failure == null);
    const result = turn.result.?;
    defer allocator.free(result.reply);

    try std.testing.expectEqualStrings("part one part two", result.reply);
    try std.testing.expectEqual(port.EndReason.interrupted, result.end_reason);
    try std.testing.expectEqual(@as(u32, 1), mock.cancelCount());
}

test "dsh idle /stop acks without cancelling the next turn" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session_file = try tempSessionFile(allocator, &tmp);
    defer allocator.free(session_file);

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, session_file);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    // Regression: an idle /stop armed the interrupt flag, so the next prompt
    // was answered with an empty interrupted reply instead of being sent.
    const ack = try h.harness().handleLocalCommand("/stop");
    try std.testing.expectEqualStrings("No active background task to stop.", ack.?);

    try setTurnFrames(mock, allocator, &.{"after"}, "completed");
    const result = try h.harness().runTurn(.{ .user_message = "hi" });
    defer allocator.free(result.reply);
    try std.testing.expectEqualStrings("after", result.reply);
    try std.testing.expectEqual(port.EndReason.completed, result.end_reason);
    try std.testing.expectEqual(@as(u32, 1), mock.promptCount());
    try std.testing.expectEqual(@as(u32, 0), mock.cancelCount());
}

test "dsh /new starts a fresh dsh session for its key" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session_file = try tempSessionFile(allocator, &tmp);
    defer allocator.free(session_file);
    const mapping = try keySessionFile(allocator, session_file, "test-key");
    defer allocator.free(mapping);

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, session_file);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    try setTurnFrames(mock, allocator, &.{"first"}, "completed");
    const first = try runOneTurn(&h, "one");
    defer allocator.free(first.reply);
    try std.testing.expectEqual(@as(u32, 1), mock.createCount());

    // /new closes this key's session and eagerly creates its replacement, the
    // same single-key behavior the host already expects.
    const ack = try h.harness().handleLocalCommand("/new");
    try std.testing.expectEqualStrings("Session cleared.", ack.?);
    try std.testing.expectEqual(@as(u32, 2), mock.createCount());
    try std.testing.expectEqual(@as(u32, 1), mock.closeCount());
    try std.testing.expect(mock.wasClosed("mock-sess-1"));

    try setTurnFrames(mock, allocator, &.{"second"}, "completed");
    const second = try runOneTurn(&h, "two");
    defer allocator.free(second.reply);
    try std.testing.expectEqualStrings("second", second.reply);
    try std.testing.expectEqual(@as(u32, 2), mock.createCount());

    const prompted = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(prompted);
    try std.testing.expectEqualStrings("mock-sess-2", prompted);
    const persisted = (try sidecar_mod.loadSessionId(allocator, mapping)).?;
    defer allocator.free(persisted);
    try std.testing.expectEqualStrings("mock-sess-2", persisted);
}

test "dsh second runTurn queues after the active turn" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    try setTurnFrames(mock, allocator, &.{"answer"}, "completed");

    // The first turn holds the harness (and the single in-flight prompt slot)
    // inside its delta until the second runTurn is waiting on the mutex.
    var first_sink = RecordingSink{ .block_after = 1, .released = .init(false) };
    var second_sink = RecordingSink{};
    var first = TurnThread{ .harness = &h, .input = .{
        .user_message = "first",
        .sink = first_sink.sink(),
        .live_stream = true,
    } };
    var second = TurnThread{ .harness = &h, .input = .{
        .user_message = "second",
        .sink = second_sink.sink(),
        .live_stream = true,
    } };

    const first_thread = try std.Thread.spawn(.{}, TurnThread.main, .{&first});
    waitForSink(&first_sink, 1);
    const second_thread = try std.Thread.spawn(.{}, TurnThread.main, .{&second});
    std_compat.thread.sleep(20 * std.time.ns_per_ms);
    first_sink.released.store(true, .release);

    first_thread.join();
    second_thread.join();

    try std.testing.expect(first.failure == null);
    try std.testing.expect(second.failure == null);
    const first_result = first.result.?;
    defer allocator.free(first_result.reply);
    const second_result = second.result.?;
    defer allocator.free(second_result.reply);

    try std.testing.expectEqualStrings("answer", first_result.reply);
    try std.testing.expectEqualStrings("answer", second_result.reply);
    try std.testing.expectEqual(port.EndReason.completed, first_result.end_reason);
    try std.testing.expectEqual(port.EndReason.completed, second_result.end_reason);
    try std.testing.expectEqual(@as(u32, 2), mock.promptCount());
    try std.testing.expectEqual(@as(u32, 1), mock.createCount());
}

test "dsh reuses the session mapping and resumes it after a restart" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session_file = try tempSessionFile(allocator, &tmp);
    defer allocator.free(session_file);

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);

    {
        const engine = try newEngine(allocator, boot_url, session_file);
        defer freeEngine(engine);
        var h = try DshHarness.init(engine, "test-key-a");
        defer h.deinit();

        var index: u32 = 0;
        while (index < 2) : (index += 1) {
            try setTurnFrames(mock, allocator, &.{"same"}, "completed");
            const result = try runOneTurn(&h, "hi");
            defer allocator.free(result.reply);
            try std.testing.expectEqualStrings("same", result.reply);
        }

        try std.testing.expectEqual(@as(u32, 1), mock.createCount());
        try std.testing.expectEqual(@as(u32, 2), mock.promptCount());
    }

    // Simulated restart: a new engine over the same mapping file connects to
    // the persisted session instead of creating another one.
    const restarted_engine = try newEngine(allocator, boot_url, session_file);
    defer freeEngine(restarted_engine);
    var restarted = try DshHarness.init(restarted_engine, "test-key-a");
    defer restarted.deinit();
    try std.testing.expectEqual(@as(u32, 1), mock.createCount());

    try setTurnFrames(mock, allocator, &.{"resumed"}, "completed");
    const result = try runOneTurn(&restarted, "again");
    defer allocator.free(result.reply);
    try std.testing.expectEqualStrings("resumed", result.reply);
    // The resumed key opened its fresh WS only when its turn began.
    try std.testing.expectEqual(@as(u32, 2), mock.wsConnections());

    const prompted = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(prompted);
    try std.testing.expectEqualStrings(mock_mod.session_id, prompted);
    try std.testing.expectEqual(@as(u32, 1), mock.createCount());
    try std.testing.expectEqual(@as(u32, 3), mock.promptCount());
}

test "dsh two keys run their own sessions on one engine" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var ha = try DshHarness.init(engine, "test-key-a");
    defer ha.deinit();
    var hb = try DshHarness.init(engine, "test-key-b");
    defer hb.deinit();

    try setTurnFrames(mock, allocator, &.{"alpha"}, "completed");
    const first = try runOneTurn(&ha, "hi");
    defer allocator.free(first.reply);
    const first_session = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(first_session);

    try setTurnFrames(mock, allocator, &.{"beta"}, "completed");
    const second = try runOneTurn(&hb, "hi");
    defer allocator.free(second.reply);
    const second_session = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(second_session);

    try std.testing.expectEqualStrings("alpha", first.reply);
    try std.testing.expectEqualStrings("beta", second.reply);
    try std.testing.expectEqual(@as(u32, 2), mock.createCount());
    // One process-wide engine: two keys share a single boot/connect and the
    // one WebSocket dsh admits for this API token.
    try std.testing.expectEqual(@as(u32, 1), mock.connectCount());
    try std.testing.expectEqual(@as(u32, 1), mock.wsConnections());
    try std.testing.expectEqual(@as(u32, 0), mock.wsRejections());
    // Each prompt landed on the session the key created for itself.
    try std.testing.expectEqualStrings("mock-sess-1", first_session);
    try std.testing.expectEqualStrings("mock-sess-2", second_session);
}

test "dsh three keys stream over one admitted WebSocket" {
    // Regression: dsh admits one WS per authenticated peer (rpc-host.ts
    // admitConnection answers 409 to a second socket). The old per-key client
    // opened a second WS, got 409 Conflict, and that key's turn failed with
    // WsHandshakeFailed and an empty reply.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var ha = try DshHarness.init(engine, "test-key-a");
    defer ha.deinit();
    var hb = try DshHarness.init(engine, "test-key-b");
    defer hb.deinit();
    var hc = try DshHarness.init(engine, "test-key-c");
    defer hc.deinit();

    try setTurnFrames(mock, allocator, &.{"alpha"}, "completed");
    const first = try runOneTurn(&ha, "hi");
    defer allocator.free(first.reply);
    try setTurnFrames(mock, allocator, &.{"beta"}, "completed");
    const second = try runOneTurn(&hb, "hi");
    defer allocator.free(second.reply);
    try setTurnFrames(mock, allocator, &.{"gamma"}, "completed");
    const third = try runOneTurn(&hc, "hi");
    defer allocator.free(third.reply);

    try std.testing.expectEqualStrings("alpha", first.reply);
    try std.testing.expectEqualStrings("beta", second.reply);
    try std.testing.expectEqualStrings("gamma", third.reply);
    try std.testing.expectEqual(@as(u32, 3), mock.createCount());
    try std.testing.expectEqual(@as(u32, 1), mock.connectCount());
    try std.testing.expectEqual(@as(u32, 1), mock.wsConnections());
    try std.testing.expectEqual(@as(u32, 0), mock.wsRejections());
}

test "dsh key switch reuses its session and leaves the other key open" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var ha = try DshHarness.init(engine, "test-key-a");
    defer ha.deinit();
    var hb = try DshHarness.init(engine, "test-key-b");
    defer hb.deinit();

    try setTurnFrames(mock, allocator, &.{"one"}, "completed");
    const first = try runOneTurn(&ha, "hi");
    defer allocator.free(first.reply);

    try setTurnFrames(mock, allocator, &.{"two"}, "completed");
    const second = try runOneTurn(&hb, "hi");
    defer allocator.free(second.reply);

    try setTurnFrames(mock, allocator, &.{"three"}, "completed");
    const third = try runOneTurn(&ha, "hi");
    defer allocator.free(third.reply);
    const prompted = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(prompted);

    // Regression: a key switch called startFreshSession, which closed the
    // previous key's dsh session and created a new one for the new key.
    try std.testing.expectEqualStrings("mock-sess-1", prompted);
    try std.testing.expectEqual(@as(u32, 2), mock.createCount());
    try std.testing.expectEqual(@as(u32, 0), mock.closeCount());
    // Both keys follow over the one admitted mux socket.
    try std.testing.expectEqual(@as(u32, 1), mock.wsConnections());
    try std.testing.expectEqual(@as(u32, 0), mock.wsRejections());
}

test "dsh /new closes only its key's session" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session_file = try tempSessionFile(allocator, &tmp);
    defer allocator.free(session_file);
    const mapping_a = try keySessionFile(allocator, session_file, "test-key-a");
    defer allocator.free(mapping_a);
    const mapping_b = try keySessionFile(allocator, session_file, "test-key-b");
    defer allocator.free(mapping_b);

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, session_file);
    defer freeEngine(engine);
    var ha = try DshHarness.init(engine, "test-key-a");
    defer ha.deinit();
    var hb = try DshHarness.init(engine, "test-key-b");
    defer hb.deinit();

    try setTurnFrames(mock, allocator, &.{"one"}, "completed");
    const first = try runOneTurn(&ha, "hi");
    defer allocator.free(first.reply);

    try setTurnFrames(mock, allocator, &.{"two"}, "completed");
    const second = try runOneTurn(&hb, "hi");
    defer allocator.free(second.reply);

    // Regression: /new reset the single shared session, so another key's
    // session was closed and its next turn started from scratch.
    const ack = try ha.harness().handleLocalCommand("/new");
    try std.testing.expectEqualStrings("Session cleared.", ack.?);
    try std.testing.expectEqual(@as(u32, 1), mock.closeCount());
    try std.testing.expect(mock.wasClosed("mock-sess-1"));
    try std.testing.expect(!mock.wasClosed("mock-sess-2"));

    // Only A's mapping moved to its replacement; B's still names its session.
    const replaced = (try sidecar_mod.loadSessionId(allocator, mapping_a)).?;
    defer allocator.free(replaced);
    try std.testing.expectEqualStrings("mock-sess-3", replaced);
    const kept = (try sidecar_mod.loadSessionId(allocator, mapping_b)).?;
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("mock-sess-2", kept);

    // B keeps working on its original session.
    try setTurnFrames(mock, allocator, &.{"still mine"}, "completed");
    const after = try runOneTurn(&hb, "hi");
    defer allocator.free(after.reply);
    try std.testing.expectEqualStrings("still mine", after.reply);
    const b_prompted = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(b_prompted);
    try std.testing.expectEqualStrings("mock-sess-2", b_prompted);

    // A's next turn runs on the replacement session.
    try setTurnFrames(mock, allocator, &.{"fresh"}, "completed");
    const fresh = try runOneTurn(&ha, "hi");
    defer allocator.free(fresh.reply);
    try std.testing.expectEqualStrings("fresh", fresh.reply);
    try std.testing.expectEqual(@as(u32, 3), mock.createCount());
    const a_prompted = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(a_prompted);
    try std.testing.expectEqualStrings("mock-sess-3", a_prompted);
}

/// Two-thread start barrier for concurrency tests.
const StartGate = struct {
    mutex: std_compat.sync.Mutex = .{},
    cond: std_compat.sync.Condition = .{},
    ready: u8 = 0,
    go: bool = false,

    fn arrive(self: *StartGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ready += 1;
        self.cond.broadcast();
        while (!self.go) self.cond.wait(&self.mutex);
    }

    fn releaseBoth(self: *StartGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.ready < 2) self.cond.wait(&self.mutex);
        self.go = true;
        self.cond.broadcast();
    }
};

const BootThread = struct {
    engine: *DshEngine,
    start: *StartGate,
    failure: ?anyerror = null,

    fn main(self: *BootThread) void {
        self.start.arrive();
        self.engine.ensureBooted() catch |err| {
            self.failure = err;
        };
    }
};

test "dsh engine concurrent first use boots once" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var gate = mock_mod.ConnectGate{};
    mock.setConnectGate(&gate);

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);

    var start = StartGate{};
    var first = BootThread{ .engine = engine, .start = &start };
    var second = BootThread{ .engine = engine, .start = &start };
    const first_thread = try std.Thread.spawn(.{}, BootThread.main, .{&first});
    const second_thread = try std.Thread.spawn(.{}, BootThread.main, .{&second});

    start.releaseBoth();
    // First entrant parks inside the mock's /connect; the other waits on the
    // engine's boot mutex, so no second connect may start.
    gate.waitEntered();
    try std.testing.expectEqual(@as(u32, 1), mock.connectCount());
    gate.open();

    first_thread.join();
    second_thread.join();
    try std.testing.expect(first.failure == null);
    try std.testing.expect(second.failure == null);
    try std.testing.expectEqual(@as(u32, 1), mock.connectCount());
}

test "dsh engine retries a failed boot without leaking" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);

    mock.failNextConnect();
    try std.testing.expectError(error.OwnerConnectRejected, engine.ensureBooted());
    try std.testing.expectEqual(@as(u32, 1), mock.connectCount());

    // A failed boot leaves no state behind; the next attempt succeeds.
    try engine.ensureBooted();
    try std.testing.expectEqual(@as(u32, 2), mock.connectCount());

    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();
    try setTurnFrames(mock, allocator, &.{"after retry"}, "completed");
    const result = try runOneTurn(&h, "hi");
    defer allocator.free(result.reply);
    try std.testing.expectEqualStrings("after retry", result.reply);
}

test "dsh concurrent turns keep their own session key" {
    // Regression: 共享 DshHarness 时 session_key 被另一个会话覆盖
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();
    mock.setEchoPrompts(true);

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var ha = try DshHarness.init(engine, "test-key-a");
    defer ha.deinit();
    var hb = try DshHarness.init(engine, "test-key-b");
    defer hb.deinit();

    var first = TurnThread{ .harness = &ha, .input = .{ .user_message = "alpha" } };
    var second = TurnThread{ .harness = &hb, .input = .{ .user_message = "beta" } };
    const first_thread = try std.Thread.spawn(.{}, TurnThread.main, .{&first});
    const second_thread = try std.Thread.spawn(.{}, TurnThread.main, .{&second});
    first_thread.join();
    second_thread.join();

    try std.testing.expect(first.failure == null);
    try std.testing.expect(second.failure == null);
    const first_result = first.result.?;
    defer allocator.free(first_result.reply);
    const second_result = second.result.?;
    defer allocator.free(second_result.reply);
    // The old shared handle retargeted both turns at one key; each handle must
    // answer with the prompt it owns.
    try std.testing.expectEqualStrings("alpha", first_result.reply);
    try std.testing.expectEqualStrings("beta", second_result.reply);
    try std.testing.expectEqual(@as(u32, 2), mock.promptCount());
    try std.testing.expectEqual(@as(u32, 2), mock.createCount());
    try std.testing.expectEqual(@as(u32, 1), mock.connectCount());
    // Concurrent first turns must still open exactly one mux socket: the
    // 409-on-second-socket mock would fail one of the turns otherwise.
    try std.testing.expectEqual(@as(u32, 1), mock.wsConnections());
    try std.testing.expectEqual(@as(u32, 0), mock.wsRejections());
}

/// Engine whose boot rewrites a junclaw-owned profile route.
fn newProfileEngine(
    allocator: Allocator,
    boot_url: []const u8,
    session_file: ?[]const u8,
    dsh_home: []const u8,
    route: profile_mod.Route,
) !*DshEngine {
    const engine = try allocator.create(DshEngine);
    engine.* = DshEngine.init(allocator, .{
        .sidecar = .{
            .bin_js = "unused",
            .workspace = test_cwd,
            .dsh_home = dsh_home,
            .profile = route,
        },
        .boot_url = boot_url,
        .session_file = session_file,
        .turn_timeout_ms = 5_000,
        .cancel_timeout_ms = 5_000,
    });
    return engine;
}

fn readProfilePatch(allocator: Allocator, dsh_home: []const u8) ![]u8 {
    const path = try profile_mod.patchPath(allocator, dsh_home);
    defer allocator.free(path);
    return fs_compat.readFileAlloc(std_compat.fs.cwd(), allocator, path, 1 << 20);
}

fn seedProfilePatch(allocator: Allocator, dsh_home: []const u8, contents: []const u8) !void {
    const path = try profile_mod.patchPath(allocator, dsh_home);
    defer allocator.free(path);
    try fs_compat.makePath(std.fs.path.dirname(path).?);
    const file = try fs_compat.createPath(path, .{});
    defer file.close();
    try file.writeAll(contents);
}

fn countOwnedRoute(text: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " "), profile_mod.route_id ++ ":")) count += 1;
    }
    return count;
}

const seeded_profile_patch =
    \\- id: llm-pi-ai
    \\  config:
    \\    providers:
    \\      user-route:
    \\        api: openai-completions
    \\        baseURL: https://user.example.com/v1
    \\        apiKeyEnv: USER_KEY
    \\        models:
    \\          - id: user-model
    \\            name: User Model
    \\- id: agent-default-model
    \\  config:
    \\    provider: user-route
    \\    model: user-model
    \\    reasoningEffort: high
    \\- id: some-plugin
    \\  config:
    \\    answer: 42
    \\
;

test "dsh boot rewrites only the junclaw route and follows model changes" {
    // Regression: 修复前 boot 不写 profile，dsh 没有 junclaw 路由/默认模型。
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();
    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const dsh_home = try std.fs.path.join(allocator, &.{ root, "dsh" });
    defer allocator.free(dsh_home);
    try seedProfilePatch(allocator, dsh_home, seeded_profile_patch);

    {
        const engine = try newProfileEngine(allocator, boot_url, null, dsh_home, .{
            .base_url = "https://api.example.com/v1",
            .models = &.{"model-a"},
            .default_model = "model-a",
            .api_key = "test-key",
        });
        defer freeEngine(engine);
        try engine.ensureBooted();
    }

    const first = try readProfilePatch(allocator, dsh_home);
    defer allocator.free(first);
    try std.testing.expectEqual(@as(usize, 1), countOwnedRoute(first));
    try std.testing.expect(std.mem.indexOf(u8, first, "      junclaw:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "          - id: model-a\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "    provider: junclaw\n    model: model-a\n") != null);
    // The user's route, entry and key survive the rewrite.
    try std.testing.expect(std.mem.indexOf(u8, first, "user-route:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "baseURL: https://user.example.com/v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "apiKeyEnv: USER_KEY\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "reasoningEffort: high\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "    answer: 42\n") != null);

    const second_route: profile_mod.Route = .{
        .base_url = "https://api.example.com/v1",
        .models = &.{ "model-b", "model-c" },
        .default_model = "model-c",
        .api_key = "test-key",
    };
    {
        const engine = try newProfileEngine(allocator, boot_url, null, dsh_home, second_route);
        defer freeEngine(engine);
        try engine.ensureBooted();
    }

    const second = try readProfilePatch(allocator, dsh_home);
    defer allocator.free(second);
    // Same permanent route key; catalog and default moved with the config.
    try std.testing.expectEqual(@as(usize, 1), countOwnedRoute(second));
    try std.testing.expect(std.mem.indexOf(u8, second, "- id: model-a\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, second, "          - id: model-b\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "          - id: model-c\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "    provider: junclaw\n    model: model-c\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "baseURL: https://user.example.com/v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "apiKeyEnv: USER_KEY\n") != null);

    // Idempotent: rewriting the same config leaves the bytes untouched.
    try profile_mod.write(allocator, dsh_home, second_route);
    const third = try readProfilePatch(allocator, dsh_home);
    defer allocator.free(third);
    try std.testing.expectEqualStrings(second, third);
}

test "dsh resumed session switches an unavailable model to the current default" {
    // Regression: 修复前恢复旧会话直接 prompt，记录模型已下架时整轮报错。
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const dsh_home = try std.fs.path.join(allocator, &.{ root, "dsh" });
    defer allocator.free(dsh_home);
    const session_file = try tempSessionFile(allocator, &tmp);
    defer allocator.free(session_file);
    const mapping = try keySessionFile(allocator, session_file, "test-key");
    defer allocator.free(mapping);
    try sidecar_mod.saveSessionId(mapping, mock_mod.session_id);

    // The session last ran on model-a; the host now only offers model-b.
    try mock.setModelCatalog(
        \\{"default":{"provider":"junclaw","model":"model-b"},"routableProviders":["junclaw"],
        \\"groups":[{"id":"junclaw","name":"junclaw","models":[{"id":"model-b","name":"model-b"}]}],"failures":[]}
    );
    try mock.setProjection(
        \\{"kind":"sequenced","asOfSeq":3,"values":{"modelSelection":
        \\{"lastUsed":{"provider":"junclaw","model":"model-a"},"next":null}}}
    );

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newProfileEngine(allocator, boot_url, session_file, dsh_home, .{
        .base_url = "https://api.example.com/v1",
        .models = &.{"model-b"},
        .default_model = "model-b",
        .api_key = "test-key",
    });
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    try setTurnFrames(mock, allocator, &.{"answered on model-b"}, "completed");
    const result = try runOneTurn(&h, "hi");
    defer allocator.free(result.reply);
    try std.testing.expectEqualStrings("answered on model-b", result.reply);

    try std.testing.expectEqual(@as(usize, 1), mock.selectModelCount());
    const select_body = (try mock.lastSelectModel(allocator)).?;
    defer allocator.free(select_body);
    try std.testing.expect(std.mem.indexOf(u8, select_body, "\"sessionId\":\"" ++ mock_mod.session_id ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, select_body, "\"provider\":\"junclaw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, select_body, "\"model\":\"model-b\"") != null);
}

test "dsh engine surfaces an RPC timeout and the next turn recovers" {
    // Regression: a wedged sidecar parked session/create forever, so a turn
    // never returned and the engine could not recover.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    try engine.ensureBooted();

    var gate = mock_mod.ConnectGate{};
    defer gate.open();
    mock.setRpcGate(&gate, "session/create");

    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    engine.opts.rpc_timeout_ms = 1;
    try std.testing.expectError(error.RpcTimeout, runOneTurn(&h, "hi"));

    // The failed acquire left no entry behind; the next turn creates one.
    engine.opts.rpc_timeout_ms = 5_000;
    gate.open();
    try setTurnFrames(mock, allocator, &.{"recovered"}, "completed");
    const result = try runOneTurn(&h, "hi");
    defer allocator.free(result.reply);
    try std.testing.expectEqualStrings("recovered", result.reply);
    // The released first request still runs in the mock, so only require that
    // the recovered turn created a session of its own.
    try std.testing.expect(mock.createCount() >= 1);
}

test "dsh turn timeout cancels and drains before reporting" {
    // Regression: TurnTimeout returned without session/cancel, so the dsh turn
    // kept running and its frames landed in the next turn.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    engine.opts.turn_timeout_ms = 5;
    engine.opts.cancel_timeout_ms = 5_000;
    // The cancel streams text and the turn only ends with its aborted frame.
    const late = try mock_mod.textDeltaFrame(allocator, 0, "late");
    defer allocator.free(late);
    try mock.setTurnFrames(&.{});
    try mock.setCancelFrames(&.{late});

    try std.testing.expectError(error.TurnTimeout, runOneTurn(&h, "one"));
    // The engine cancelled and drained the aborted turn/end before returning.
    try std.testing.expectEqual(@as(u32, 1), mock.cancelCount());

    try setTurnFrames(mock, allocator, &.{"second"}, "completed");
    const result = try runOneTurn(&h, "two");
    defer allocator.free(result.reply);
    try std.testing.expectEqualStrings("second", result.reply);
    try std.testing.expectEqual(port.EndReason.completed, result.end_reason);
}

test "dsh turn timeout without a cancel ack returns partial text" {
    // Regression: CancelTimeout propagated as an error, dropping the text the
    // turn had already streamed to the user.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    // Generous enough that the prompt's delta is parked in the sink before the
    // deadline; the sink then holds the loop until the test releases it.
    engine.opts.turn_timeout_ms = 500;
    engine.opts.cancel_timeout_ms = 5;
    // The cancel acks but never ends the turn.
    mock.setCancelEndsTurn(false);
    try setTurnFrames(mock, allocator, &.{"partial"}, null);

    // Hold the loop inside the delta so the deadline passes with text already
    // accumulated: the sink gates the ordering, no wall-clock assertion.
    var sink = RecordingSink{
        .block_after = 0,
        .released = std.atomic.Value(bool).init(false),
    };
    var turn = TurnThread{ .harness = &h, .input = .{
        .user_message = "one",
        .sink = sink.sink(),
        .live_stream = true,
    } };
    const thread = try std.Thread.spawn(.{}, TurnThread.main, .{&turn});

    waitForSink(&sink, 1);
    try std.testing.expectEqualStrings("partial", sink.text());
    sink.released.store(true, .release);
    thread.join();

    try std.testing.expect(turn.failure == null);
    const result = turn.result.?;
    defer allocator.free(result.reply);
    try std.testing.expectEqualStrings("partial", result.reply);
    try std.testing.expectEqual(port.EndReason.failed, result.end_reason);
    try std.testing.expectEqual(@as(u32, 1), mock.cancelCount());
}

test "dsh cancel timeout drops the old turn's frames before the next prompt" {
    // Regression: a cancel that acked but never ended the turn left the old
    // turn's delta/committed/turn_end in the per-session queue; the next turn
    // consumed them as its own reply instead of the new turn's frames.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    // The turn stays in flight; the cancel acks and gives up at once, then the
    // still-running turn's frames arrive in the persistent subscription queue.
    engine.opts.cancel_timeout_ms = 0;
    mock.setCancelEndsTurn(false);
    try mock.setTurnFrames(&.{});
    const stale_delta = try mock_mod.textDeltaFrame(allocator, 0, "stale ");
    defer allocator.free(stale_delta);
    const stale_committed = try mock_mod.committedMessageFrame(allocator, "stale answer", true);
    defer allocator.free(stale_committed);
    const stale_end = try endFrame(allocator, "completed");
    defer allocator.free(stale_end);
    try mock.setCancelFrames(&.{ stale_delta, stale_committed, stale_end });

    var turn = TurnThread{ .harness = &h, .input = .{ .user_message = "one" } };
    const thread = try std.Thread.spawn(.{}, TurnThread.main, .{&turn});
    waitForPrompt(mock, 1);
    const ack = try h.harness().handleLocalCommand("/stop");
    try std.testing.expectEqualStrings("No active background task to stop.", ack.?);
    thread.join();
    try std.testing.expect(turn.failure == null);
    const first = turn.result.?;
    defer allocator.free(first.reply);
    try std.testing.expectEqual(port.EndReason.interrupted, first.end_reason);

    // The old turn's frames land after runTurn returned; the next turn must
    // ignore them and answer only from its own frames.
    const entry = engine.acquireExisting("test-key").?;
    defer engine.releaseEntry(entry);
    waitForQueued(entry.sub, 3);
    try std.testing.expect(entry.sub.queuedCount() >= 3);

    try setTurnFrames(mock, allocator, &.{"second"}, "completed");
    const result = try runOneTurn(&h, "two");
    defer allocator.free(result.reply);
    try std.testing.expectEqualStrings("second", result.reply);
    try std.testing.expectEqual(port.EndReason.completed, result.end_reason);
    try std.testing.expectEqual(@as(u32, 1), mock.cancelCount());
}

test "dsh turn timeout consumes a stop armed during the cancel drain" {
    // Regression: a /stop armed while the timeout cancel drained stayed set
    // and cancelled the next prompt instead of ending with the timed-out turn.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    engine.opts.turn_timeout_ms = 5;
    engine.opts.cancel_timeout_ms = 5_000;
    try mock.setTurnFrames(&.{});
    var gate = mock_mod.ConnectGate{};
    mock.setRpcGate(&gate, "session/cancel");

    var turn = TurnThread{ .harness = &h, .input = .{ .user_message = "one" } };
    const thread = try std.Thread.spawn(.{}, TurnThread.main, .{&turn});
    gate.waitEntered();
    // The turn still holds its mutex, so this stop targets the timed-out turn.
    h.harness().requestInterrupt();
    gate.open();
    thread.join();

    try std.testing.expectEqual(error.TurnTimeout, turn.failure.?);
    try std.testing.expectEqual(@as(u32, 1), mock.cancelCount());

    // The stop was consumed by the timed-out turn; it must not cancel this
    // prompt pre-emptively.
    try setTurnFrames(mock, allocator, &.{"second"}, "completed");
    const result = try runOneTurn(&h, "two");
    defer allocator.free(result.reply);
    try std.testing.expectEqualStrings("second", result.reply);
    try std.testing.expectEqual(port.EndReason.completed, result.end_reason);
}

test "dsh port reset starts a fresh dsh session for its key" {
    // Regression: reset() was a no-op, so /new through the port hook kept
    // prompting the old dsh session.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session_file = try tempSessionFile(allocator, &tmp);
    defer allocator.free(session_file);
    const mapping = try keySessionFile(allocator, session_file, "test-key");
    defer allocator.free(mapping);

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, session_file);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    try setTurnFrames(mock, allocator, &.{"first"}, "completed");
    const first = try runOneTurn(&h, "one");
    defer allocator.free(first.reply);
    try std.testing.expectEqualStrings("first", first.reply);
    try std.testing.expectEqual(@as(u32, 1), mock.createCount());

    h.harness().reset();
    try std.testing.expectEqual(@as(u32, 2), mock.createCount());
    try std.testing.expectEqual(@as(u32, 1), mock.closeCount());
    try std.testing.expect(mock.wasClosed("mock-sess-1"));

    try setTurnFrames(mock, allocator, &.{"second"}, "completed");
    const second = try runOneTurn(&h, "two");
    defer allocator.free(second.reply);
    try std.testing.expectEqualStrings("second", second.reply);

    const prompted = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(prompted);
    try std.testing.expectEqualStrings("mock-sess-2", prompted);
    const persisted = (try sidecar_mod.loadSessionId(allocator, mapping)).?;
    defer allocator.free(persisted);
    try std.testing.expectEqualStrings("mock-sess-2", persisted);
}

test "dsh failed reset makes the next turn report instead of reusing the old session" {
    // Regression: a failed /new left the key on the old dsh session, so the
    // next turn silently continued the cleared conversation.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session_file = try tempSessionFile(allocator, &tmp);
    defer allocator.free(session_file);
    const map_a = try keySessionFile(allocator, session_file, "key-a");
    defer allocator.free(map_a);
    const map_b = try keySessionFile(allocator, session_file, "key-b");
    defer allocator.free(map_b);

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, session_file);
    defer freeEngine(engine);
    var ha = try DshHarness.init(engine, "key-a");
    defer ha.deinit();
    var hb = try DshHarness.init(engine, "key-b");
    defer hb.deinit();

    mock.setEchoPrompts(true);
    const first_a = try runOneTurn(&ha, "one");
    defer allocator.free(first_a.reply);
    const first_b = try runOneTurn(&hb, "one");
    defer allocator.free(first_b.reply);
    try std.testing.expectEqual(@as(u32, 2), mock.promptCount());

    // Rewriting the mapping fails when its path is a directory: the eager
    // create succeeds, so the swap is half done and must not be reused.
    try fs_compat.deletePath(map_a);
    try std_compat.fs.makeDirAbsolute(map_a);
    try fs_compat.deletePath(map_b);
    try std_compat.fs.makeDirAbsolute(map_b);

    // handleLocalCommand path: the error reaches the caller.
    try std.testing.expectError(error.IsDir, ha.harness().handleLocalCommand("/new"));
    // Port path: void, so the failure only surfaces on the next turn.
    hb.harness().reset();

    try std.testing.expectError(error.SessionResetFailed, runOneTurn(&ha, "after"));
    try std.testing.expectError(error.SessionResetFailed, runOneTurn(&hb, "after"));
    // Neither turn prompted dsh with the old session.
    try std.testing.expectEqual(@as(u32, 2), mock.promptCount());
}

test "dsh /new after an idle sidecar crash recovers instead of bricking the key" {
    // Regression: resetKeySession used the dead client directly and set
    // reset_failed; runTurn then reported SessionResetFailed on every later
    // turn, and nothing ever recovered the key.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session_file = try tempSessionFile(allocator, &tmp);
    defer allocator.free(session_file);

    var ctl = SpawnCtl{ .mock = mock };
    const engine = try newManagedEngine(allocator, &ctl, session_file);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    try setTurnFrames(mock, allocator, &.{"first"}, "completed");
    const first = try runOneTurn(&h, "one");
    defer allocator.free(first.reply);

    // Idle crash, and the first recovery spawn also fails: /new reports the
    // error and marks the key instead of silently reusing the old session.
    mock.kill();
    ctl.fail_calls = 1;
    try std.testing.expectError(error.ConnectionRefused, h.harness().handleLocalCommand("/new"));
    try std.testing.expectError(error.SessionResetFailed, runOneTurn(&h, "blocked"));

    // A retried /new recovers the sidecar, swaps the session and clears the
    // flag; the key is usable again.
    try setTurnFrames(mock, allocator, &.{"after"}, "completed");
    const ack = try h.harness().handleLocalCommand("/new");
    try std.testing.expectEqualStrings("Session cleared.", ack.?);
    const second = try runOneTurn(&h, "two");
    defer allocator.free(second.reply);
    try std.testing.expectEqualStrings("after", second.reply);
    try std.testing.expectEqual(@as(u32, 2), mock.createCount());
    try std.testing.expectEqual(@as(u32, 1), mock.reviveCount());
    // One boot, one failed recovery, one successful recovery.
    try std.testing.expectEqual(@as(u32, 3), ctl.calls);
}

test "dsh sidecar crash restarts and resumes the same session" {
    // Regression: a dead sidecar only surfaced as an error; nothing restarted
    // it and the conversation was never resumed.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var ctl = SpawnCtl{ .mock = mock };
    const engine = try newManagedEngine(allocator, &ctl, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    try setTurnFrames(mock, allocator, &.{"before"}, "completed");
    const first = try runOneTurn(&h, "one");
    defer allocator.free(first.reply);
    try std.testing.expectEqualStrings("before", first.reply);
    const session = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(session);
    try std.testing.expectEqual(@as(u32, 1), mock.createCount());

    mock.kill();
    try setTurnFrames(mock, allocator, &.{"after"}, "completed");
    const second = try runOneTurn(&h, "two");
    defer allocator.free(second.reply);
    try std.testing.expectEqualStrings("after", second.reply);

    // One restart; re-attach is `session/follow` (session/resume is not a
    // Remote method and the mock 404s it), and the prompt landed on the same
    // dsh session.
    try std.testing.expectEqual(@as(u32, 1), mock.reviveCount());
    const prompted = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(prompted);
    try std.testing.expectEqualStrings(session, prompted);
    try std.testing.expectEqual(@as(u32, 1), mock.createCount());
    // A successful recovery resets the consecutive-failure count.
    try std.testing.expectEqual(@as(u32, 0), engine.restart_attempts);
}

test "dsh prompt retry after a crash reuses the requestId" {
    // Regression: every retry minted a fresh requestId, so dsh inserted the
    // same user message twice instead of returning the original acceptance.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var ctl = SpawnCtl{ .mock = mock };
    const engine = try newManagedEngine(allocator, &ctl, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    mock.setEchoPrompts(true);
    const first = try runOneTurn(&h, "one");
    defer allocator.free(first.reply);

    // The sidecar admits the prompt, then dies before answering: the client
    // sees a connection error and resends after the restart.
    mock.dropNextPromptReply();
    const retried = try runOneTurn(&h, "retry-me");
    defer allocator.free(retried.reply);
    try std.testing.expectEqualStrings("retry-me", retried.reply);

    // Index 0 is the first turn; the dropped prompt and its retry follow.
    try std.testing.expectEqual(@as(u32, 3), mock.promptCount());
    const dropped_id = (try mock.promptRequestIdAt(allocator, 1)).?;
    defer allocator.free(dropped_id);
    const retry_id = (try mock.promptRequestIdAt(allocator, 2)).?;
    defer allocator.free(retry_id);
    try std.testing.expectEqualStrings(dropped_id, retry_id);
}

test "dsh sidecar restart attempts grow on failure and reset on success" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var ctl = SpawnCtl{ .mock = mock };
    const engine = try newManagedEngine(allocator, &ctl, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    try setTurnFrames(mock, allocator, &.{"first"}, "completed");
    const first = try runOneTurn(&h, "one");
    defer allocator.free(first.reply);

    // Two recovery spawns fail before the third one works.
    ctl.fail_calls = 2;
    mock.kill();
    try std.testing.expectError(error.ConnectionRefused, runOneTurn(&h, "two"));
    try std.testing.expectEqual(@as(u32, 1), engine.restart_attempts);
    try std.testing.expectError(error.ConnectionRefused, runOneTurn(&h, "three"));
    try std.testing.expectEqual(@as(u32, 2), engine.restart_attempts);
    try std.testing.expectEqual(@as(u32, 0), mock.reviveCount());

    try setTurnFrames(mock, allocator, &.{"recovered"}, "completed");
    const fourth = try runOneTurn(&h, "four");
    defer allocator.free(fourth.reply);
    try std.testing.expectEqualStrings("recovered", fourth.reply);
    try std.testing.expectEqual(@as(u32, 0), engine.restart_attempts);
    try std.testing.expectEqual(@as(u32, 1), mock.reviveCount());
    // One boot plus three recovery attempts.
    try std.testing.expectEqual(@as(u32, 4), ctl.calls);
}

test "dsh sidecar crash loop reports a clear error and stops restarting" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var ctl = SpawnCtl{ .mock = mock };
    const engine = try newManagedEngine(allocator, &ctl, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    try setTurnFrames(mock, allocator, &.{"first"}, "completed");
    const first = try runOneTurn(&h, "one");
    defer allocator.free(first.reply);

    ctl.fail_calls = 100;
    mock.kill();
    // max_restart_attempts failed recoveries...
    for (0..3) |_| {
        try std.testing.expectError(error.ConnectionRefused, runOneTurn(&h, "again"));
    }
    try std.testing.expectEqual(@as(u32, 3), engine.restart_attempts);
    // ...then the next turn reports instead of spawning another process.
    try std.testing.expectError(error.SidecarCrashLoop, runOneTurn(&h, "again"));
    try std.testing.expectEqual(@as(u32, 4), ctl.calls);
    try std.testing.expectEqual(@as(u32, 0), mock.reviveCount());
}

test "dsh crash loop counts crashes after a successful boot and handshake" {
    // Regression: restartSidecarLocked cleared restart_attempts as soon as
    // connectClient succeeded, so a sidecar that booted and then died on its
    // first RPC restarted forever instead of tripping the crash-loop limit.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var ctl = SpawnCtl{ .mock = mock };
    const engine = try newManagedEngine(allocator, &ctl, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    try setTurnFrames(mock, allocator, &.{"first"}, "completed");
    const first = try runOneTurn(&h, "one");
    defer allocator.free(first.reply);

    // Every restart now boots and handshakes, then dies on the prompt.
    mock.dropAllPromptReplies();
    for (0..3) |_| {
        const outcome = runOneTurn(&h, "again");
        if (outcome) |result| {
            allocator.free(result.reply);
            if (result.@"error") |message| allocator.free(message);
            return error.TestUnexpectedResult;
        } else |err| {
            try std.testing.expect(client_mod.isConnectionError(err));
        }
    }
    try std.testing.expectEqual(@as(u32, 3), engine.restart_attempts);
    // The fourth crash must not spawn another process.
    try std.testing.expectError(error.SidecarCrashLoop, runOneTurn(&h, "again"));
    try std.testing.expectEqual(@as(u32, 4), ctl.calls);
    try std.testing.expectEqual(@as(u32, 3), mock.reviveCount());
}

test "dsh stale turn does not restart a sidecar another turn recovered" {
    // Regression: recovery compared a global generation counter. A turn that
    // still held the old client read the counter after another turn's restart,
    // saw it unchanged, and restarted a second time -- killing the fresh
    // sidecar and the turn attached to it.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var ctl = SpawnCtl{ .mock = mock };
    const engine = try newManagedEngine(allocator, &ctl, null);
    defer freeEngine(engine);
    var ha = try DshHarness.init(engine, "key-a");
    defer ha.deinit();
    var hb = try DshHarness.init(engine, "key-b");
    defer hb.deinit();

    mock.setEchoPrompts(true);
    const first_a = try runOneTurn(&ha, "a-one");
    defer allocator.free(first_a.reply);
    const first_b = try runOneTurn(&hb, "b-one");
    defer allocator.free(first_b.reply);

    // Key A is mid-turn (one delta, no terminal frame) when the sidecar dies.
    // Key B then runs from A's sink while the mock is dead: B recovers to a
    // fresh client. When control returns to A, its old subscription fails.
    mock.setEchoPrompts(false);
    try setTurnFrames(mock, allocator, &.{"partial"}, null);

    const ReentrantCrash = struct {
        allocator: Allocator,
        mock: *MockDsh,
        harness: *DshHarness,
        fired: bool = false,
        failure: ?anyerror = null,
        reply: ?[]const u8 = null,

        fn sink(self: *@This()) port.Sink {
            return .{ .ctx = @ptrCast(self), .emit = emit };
        }

        fn emit(ctx: *anyopaque, event: port.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.fired) return;
            switch (event) {
                .delta => {},
                else => return,
            }
            self.fired = true;
            self.mock.kill();
            setTurnFrames(self.mock, self.allocator, &.{"b-after"}, "completed") catch |err| {
                self.failure = err;
                return;
            };
            const result = runOneTurn(self.harness, "b-crash") catch |err| {
                self.failure = err;
                return;
            };
            self.reply = result.reply;
            if (result.@"error") |message| self.allocator.free(message);
        }
    };

    var reentrant = ReentrantCrash{ .allocator = allocator, .mock = mock, .harness = &hb };
    const slow = try ha.harness().runTurn(.{ .user_message = "slow-a", .sink = reentrant.sink() });
    defer allocator.free(slow.reply);

    try std.testing.expect(reentrant.failure == null);
    try std.testing.expect(reentrant.reply != null);
    defer allocator.free(reentrant.reply.?);
    try std.testing.expectEqualStrings("b-after", reentrant.reply.?);

    // A kept the text it had already streamed and re-attached to the client B
    // recovered, without a second restart.
    try std.testing.expectEqualStrings("partial", slow.reply);
    try std.testing.expectEqual(port.EndReason.failed, slow.end_reason);
    try std.testing.expectEqual(@as(u32, 1), mock.reviveCount());
    try std.testing.expectEqual(@as(u32, 2), ctl.calls);
    try std.testing.expectEqual(@as(u32, 2), mock.wsConnections());
    try std.testing.expectEqual(@as(u32, 0), mock.wsRejections());
}

test "dsh crash mid-turn keeps partial text and reattaches every key" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var ctl = SpawnCtl{ .mock = mock };
    const engine = try newManagedEngine(allocator, &ctl, null);
    defer freeEngine(engine);
    var ha = try DshHarness.init(engine, "key-a");
    defer ha.deinit();
    var hb = try DshHarness.init(engine, "key-b");
    defer hb.deinit();

    mock.setEchoPrompts(true);
    const first_a = try runOneTurn(&ha, "a-one");
    defer allocator.free(first_a.reply);
    const a_session = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(a_session);
    const first_b = try runOneTurn(&hb, "b-one");
    defer allocator.free(first_b.reply);
    const b_session = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(b_session);
    try std.testing.expect(!std.mem.eql(u8, a_session, b_session));

    // Key A has a turn in flight (one delta, no terminal frame) when the
    // sidecar dies.
    mock.setEchoPrompts(false);
    try setTurnFrames(mock, allocator, &.{"partial"}, null);
    var sink = RecordingSink{};
    var turn = TurnThread{
        .harness = &ha,
        .input = .{ .user_message = "slow", .sink = sink.sink() },
    };
    const thread = try std.Thread.spawn(.{}, TurnThread.main, .{&turn});
    waitForSink(&sink, 1);
    mock.kill();
    thread.join();

    // The turn reports the text the user already saw, not an error that drops
    // it (and not a retry that would duplicate it).
    try std.testing.expect(turn.failure == null);
    try std.testing.expect(turn.result != null);
    const slow = turn.result.?;
    defer allocator.free(slow.reply);
    try std.testing.expectEqualStrings("partial", slow.reply);
    try std.testing.expectEqual(port.EndReason.failed, slow.end_reason);

    // One restart re-attached both live sessions over `session/follow`.
    try std.testing.expectEqual(@as(u32, 1), mock.reviveCount());

    // The other key continues on its original session without a restart.
    mock.setEchoPrompts(true);
    const second_b = try runOneTurn(&hb, "b-two");
    defer allocator.free(second_b.reply);
    try std.testing.expectEqualStrings("b-two", second_b.reply);
    const prompted_b = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(prompted_b);
    try std.testing.expectEqualStrings(b_session, prompted_b);

    // The interrupted key also resumes its own conversation.
    const second_a = try runOneTurn(&ha, "a-two");
    defer allocator.free(second_a.reply);
    try std.testing.expectEqualStrings("a-two", second_a.reply);
    const prompted_a = (try mock.lastPromptSession(allocator)).?;
    defer allocator.free(prompted_a);
    try std.testing.expectEqualStrings(a_session, prompted_a);
    try std.testing.expectEqual(@as(u32, 1), mock.reviveCount());
    // One boot + one restart, and no turn rebuilt a second mux: dsh would
    // answer a concurrent second WebSocket with 409.
    try std.testing.expectEqual(@as(u32, 2), mock.wsConnections());
    try std.testing.expectEqual(@as(u32, 0), mock.wsRejections());
}

test "dsh two in-flight turns share one restart" {
    // Two keys are mid-turn when the sidecar dies. Both recover through the
    // single recovery lock: one restart, one WebSocket, two resumes.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var ctl = SpawnCtl{ .mock = mock };
    const engine = try newManagedEngine(allocator, &ctl, null);
    defer freeEngine(engine);
    var ha = try DshHarness.init(engine, "key-a");
    defer ha.deinit();
    var hb = try DshHarness.init(engine, "key-b");
    defer hb.deinit();

    mock.setEchoPrompts(true);
    const first_a = try runOneTurn(&ha, "a-one");
    defer allocator.free(first_a.reply);
    const first_b = try runOneTurn(&hb, "b-one");
    defer allocator.free(first_b.reply);

    mock.setEchoPrompts(false);
    try setTurnFrames(mock, allocator, &.{"partial"}, null);
    var sink_a = RecordingSink{};
    var sink_b = RecordingSink{};
    var turn_a = TurnThread{
        .harness = &ha,
        .input = .{ .user_message = "slow-a", .sink = sink_a.sink() },
    };
    var turn_b = TurnThread{
        .harness = &hb,
        .input = .{ .user_message = "slow-b", .sink = sink_b.sink() },
    };
    const thread_a = try std.Thread.spawn(.{}, TurnThread.main, .{&turn_a});
    const thread_b = try std.Thread.spawn(.{}, TurnThread.main, .{&turn_b});
    waitForSink(&sink_a, 1);
    waitForSink(&sink_b, 1);
    mock.kill();
    thread_a.join();
    thread_b.join();

    for ([_]*TurnThread{ &turn_a, &turn_b }) |turn| {
        try std.testing.expect(turn.failure == null);
        try std.testing.expect(turn.result != null);
        defer allocator.free(turn.result.?.reply);
        try std.testing.expectEqualStrings("partial", turn.result.?.reply);
        try std.testing.expectEqual(port.EndReason.failed, turn.result.?.end_reason);
    }
    try std.testing.expectEqual(@as(u32, 1), mock.reviveCount());
    try std.testing.expectEqual(@as(u32, 2), mock.wsConnections());
    try std.testing.expectEqual(@as(u32, 0), mock.wsRejections());
}

test "dsh injected boot_url is not restarted after a crash" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    mock.setEchoPrompts(true);
    const first = try runOneTurn(&h, "one");
    defer allocator.free(first.reply);
    mock.kill();

    if (runOneTurn(&h, "two")) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(client_mod.isConnectionError(err));
    }
    // The owner manages this sidecar; the engine must not reconnect on its own.
    try std.testing.expectEqual(@as(u32, 1), mock.wsConnections());
    mock.revive();
}

test "dsh crash recovery keeps a large payload leak-free" {
    // Leak regression for the restart path: the retired client, the owned
    // launch URL and the resumed follow stream must all be released, even
    // when the turn carries more than 64KB.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    var ctl = SpawnCtl{ .mock = mock };
    const engine = try newManagedEngine(allocator, &ctl, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    mock.setEchoPrompts(true);
    const first = try runOneTurn(&h, "one");
    defer allocator.free(first.reply);

    mock.kill();
    const big = try allocator.alloc(u8, 70 * 1024);
    defer allocator.free(big);
    @memset(big, 'x');
    const second = try runOneTurn(&h, big);
    defer allocator.free(second.reply);
    try std.testing.expectEqual(big.len, second.reply.len);
    try std.testing.expectEqual(@as(u32, 1), mock.reviveCount());
}

const HarnessReapCtl = struct { calls: u32 = 0, last_exclude: ?i32 = null };

fn countHarnessReap(ctx: ?*anyopaque, _: *const sidecar_mod.Options, exclude_pid: ?i32) void {
    const ctl: *HarnessReapCtl = @ptrCast(@alignCast(ctx.?));
    ctl.calls += 1;
    ctl.last_exclude = exclude_pid;
}

test "dsh writer-held prompt reaps leftovers and retries the same session" {
    // Regression: an orphaned sidecar holding session.lock made dsh answer
    // session/writer-held; the harness folded it into error.RpcFailed and the
    // turn failed without clearing the leftover writer.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var ctl = HarnessReapCtl{};
    engine.opts.sidecar.reap = countHarnessReap;
    engine.opts.sidecar.reap_ctx = &ctl;

    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    mock.setPromptWriterHeld(1);
    try setTurnFrames(mock, allocator, &.{"resumed after reap"}, "completed");

    const result = try runOneTurn(&h, "hi");
    defer allocator.free(result.reply);
    try std.testing.expectEqualStrings("resumed after reap", result.reply);
    try std.testing.expectEqual(@as(u32, 1), ctl.calls);
    try std.testing.expectEqual(@as(?i32, null), ctl.last_exclude);
    try std.testing.expectEqual(@as(u32, 2), mock.promptCount());
}

test "persistent writer-held returns SessionWriterHeld after one reap" {
    // The turn must fail with the real cause, not retry forever and not fall
    // back to a fresh session (which would drop the conversation history).
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var ctl = HarnessReapCtl{};
    engine.opts.sidecar.reap = countHarnessReap;
    engine.opts.sidecar.reap_ctx = &ctl;

    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();

    mock.setPromptWriterHeld(std.math.maxInt(u32));
    try setTurnFrames(mock, allocator, &.{"unreachable"}, "completed");

    try std.testing.expectError(error.SessionWriterHeld, runOneTurn(&h, "hi"));
    try std.testing.expectEqual(@as(u32, 1), ctl.calls);
    try std.testing.expectEqual(@as(u32, 2), mock.promptCount());
}

const ProcKillLog = struct {
    allocator: Allocator,
    root: []const u8,
    pids: std.ArrayListUnmanaged(i32) = .empty,
};

fn recordProcKill(ctx: ?*anyopaque, pid: i32) void {
    const log: *ProcKillLog = @ptrCast(@alignCast(ctx.?));
    log.pids.append(log.allocator, pid) catch {};
    var name_buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}", .{pid}) catch return;
    var dir = std_compat.fs.openDirAbsolute(log.root, .{}) catch return;
    defer dir.close();
    dir.deleteTree(name) catch {};
}

fn ignoreReap(_: ?*anyopaque, _: *const sidecar_mod.Options, _: ?i32) void {}

fn writeFakeProc(dir: std_compat.fs.Dir, name: []const u8, cmdline: []const u8, environ: []const u8) !void {
    try dir.makeDir(name);
    var entry = try dir.openDir(name, .{});
    defer entry.close();
    try entry.writeFile(.{ .sub_path = "cmdline", .data = cmdline });
    try entry.writeFile(.{ .sub_path = "environ", .data = environ });
}

test "empty configured bin resolves from env and the sweep spares the gateway" {
    // Regression: the production constructor leaves bin_js empty and the
    // resolved path lived only in ensureBooted's local copy. The writer-held
    // sweep then ran with an empty needle, matched every process, and killed
    // the gateway itself.
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const c = @cImport({
        @cInclude("stdlib.h");
    });
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const raw = std_compat.fs.Dir.wrap(tmp.dir);
    const root = try raw.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const home = try std.fs.path.join(allocator, &.{ root, "dsh-home" });
    defer allocator.free(home);
    const bin = try std.fs.path.join(allocator, &.{ root, "bin.js" });
    defer allocator.free(bin);

    const key_z = try allocator.dupeZ(u8, "NULLCLAW_DSH_BIN");
    defer allocator.free(key_z);
    const bin_z = try allocator.dupeZ(u8, bin);
    defer allocator.free(bin_z);
    try std.testing.expectEqual(@as(c_int, 0), c.setenv(key_z.ptr, bin_z.ptr, 1));
    defer _ = c.unsetenv(key_z.ptr);

    const engine = try allocator.create(DshEngine);
    engine.* = DshEngine.init(allocator, .{
        .sidecar = .{
            .node_exe = "/bin/false",
            .bin_js = "",
            .workspace = root,
            .dsh_home = home,
            .boot_timeout_ms = 2_000,
            .reap = ignoreReap,
        },
    });
    defer {
        engine.deinit();
        allocator.destroy(engine);
    }

    try std.testing.expectError(error.SidecarBootFailed, engine.ensureBooted());
    // The resolved path must outlive the failed boot for the sweep.
    try std.testing.expectEqualStrings(bin, engine.opts.sidecar.bin_js);

    const environ = try std.fmt.allocPrint(allocator, "DSH_HOME={s}\x00", .{home});
    defer allocator.free(environ);
    const dsh_cmdline = try std.fmt.allocPrint(allocator, "node\x00{s}\x00", .{bin});
    defer allocator.free(dsh_cmdline);
    // The gateway's own argv ("nullclaw") plus a real leftover dsh.
    try writeFakeProc(raw, "100", "nullclaw\x00", environ);
    try writeFakeProc(raw, "101", dsh_cmdline, environ);

    var log = ProcKillLog{ .allocator = allocator, .root = root };
    defer log.pids.deinit(allocator);
    sidecar_mod.reapOrphansIn(allocator, root, engine.opts.sidecar.bin_js, engine.opts.sidecar.dsh_home, null, recordProcKill, &log);

    try std.testing.expectEqualSlices(i32, &.{101}, log.pids.items);
}

// ── P4b: sidecar reasoning display ──────────────────────────────────────────

test "dsh reasoning streams inline think tags before visible text" {
    // Regression: reasoning-delta chunks were left as `.other`, so the sidecar
    // dropped every trace and Info.reasoning_mode was hardcoded to off.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();
    h.setCallConfig("dsh", null, .stream);
    try std.testing.expectEqual(config_types.ReasoningMode.stream, h.harness().info().reasoning_mode);

    const first = try mock_mod.reasoningDeltaFrame(allocator, 0, "trace ");
    defer allocator.free(first);
    const second = try mock_mod.reasoningDeltaFrame(allocator, 1, "more");
    defer allocator.free(second);
    const text = try mock_mod.textDeltaFrame(allocator, 2, "answer");
    defer allocator.free(text);
    const end = try endFrame(allocator, "completed");
    defer allocator.free(end);
    try mock.setTurnFrames(&.{ first, second, text, end });

    var sink = RecordingSink{};
    const result = try h.harness().runTurn(.{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    });
    defer allocator.free(result.reply);

    try std.testing.expectEqualStrings("<think>trace more</think>answer", sink.text());
    try std.testing.expectEqualStrings("answer", result.reply);
    try std.testing.expectEqualStrings("answer", result.persisted_reply.?);
    try std.testing.expectEqual(port.EndReason.completed, result.end_reason);
}

test "dsh closes each reasoning block before the next one and before its text" {
    // Regression: the sidecar had no reasoning state machine, so multiple
    // reasoning-delta blocks could never be framed as separate tags.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();
    h.setCallConfig("dsh", null, .stream);

    const r1 = try mock_mod.reasoningDeltaFrame(allocator, 0, "first");
    defer allocator.free(r1);
    const t1 = try mock_mod.textDeltaFrame(allocator, 1, "a");
    defer allocator.free(t1);
    const r2 = try mock_mod.reasoningDeltaFrame(allocator, 2, "second");
    defer allocator.free(r2);
    const t2 = try mock_mod.textDeltaFrame(allocator, 3, "b");
    defer allocator.free(t2);
    const end = try endFrame(allocator, "completed");
    defer allocator.free(end);
    try mock.setTurnFrames(&.{ r1, t1, r2, t2, end });

    var sink = RecordingSink{};
    const result = try h.harness().runTurn(.{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    });
    defer allocator.free(result.reply);

    try std.testing.expectEqualStrings("<think>first</think>a<think>second</think>b", sink.text());
    try std.testing.expectEqualStrings("ab", result.reply);
    try std.testing.expectEqualStrings("ab", result.persisted_reply.?);
}

test "dsh abort mid-reasoning closes the think tag" {
    // Regression: abort/timeout returned the partial reply without closing a
    // tag the relay had already opened, leaving the channel draft unbalanced.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();
    h.setCallConfig("dsh", null, .stream);

    const r1 = try mock_mod.reasoningDeltaFrame(allocator, 0, "trace");
    defer allocator.free(r1);
    try mock.setTurnFrames(&.{r1});

    // Park the turn inside the opening tag emit until the test has seen it and
    // armed /stop, so the abort cannot race the first reasoning delta.
    var sink = RecordingSink{ .block_after = "<think>".len, .released = std.atomic.Value(bool).init(false) };
    var turn = TurnThread{ .harness = &h, .input = .{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    } };
    const thread = try std.Thread.spawn(.{}, TurnThread.main, .{&turn});

    waitForPrompt(mock, 1);
    waitForSink(&sink, "<think>".len);
    _ = (try h.harness().handleLocalCommand("/stop")).?;
    sink.released.store(true, .release);

    thread.join();
    try std.testing.expect(turn.failure == null);
    const result = turn.result.?;
    defer allocator.free(result.reply);

    try std.testing.expectEqualStrings("<think>trace</think>", sink.text());
    try std.testing.expectEqualStrings("", result.reply);
    try std.testing.expectEqualStrings("", result.persisted_reply.?);
    try std.testing.expectEqual(port.EndReason.interrupted, result.end_reason);
}

test "dsh failed turn mid-reasoning closes the think tag" {
    // Regression: the error turn/end path returned before closing an open
    // block, unlike the completed path.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();
    h.setCallConfig("dsh", null, .stream);

    const r1 = try mock_mod.reasoningDeltaFrame(allocator, 0, "trace");
    defer allocator.free(r1);
    const fail = try errorEndFrame(allocator, "boom");
    defer allocator.free(fail);
    try mock.setTurnFrames(&.{ r1, fail });

    var sink = RecordingSink{};
    const result = try h.harness().runTurn(.{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    });
    defer allocator.free(result.reply);
    defer allocator.free(result.@"error".?);

    try std.testing.expectEqualStrings("<think>trace</think>", sink.text());
    try std.testing.expectEqual(port.EndReason.failed, result.end_reason);
    try std.testing.expectEqualStrings("boom", result.@"error".?);
    try std.testing.expectEqualStrings("", result.reply);
}

test "dsh socket death mid-reasoning closes the think tag" {
    // Regression: a reader/socket failure returned before closing an open
    // block, so the channel kept rendering the rest of the turn as thinking.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();
    h.setCallConfig("dsh", null, .stream);

    const r1 = try mock_mod.reasoningDeltaFrame(allocator, 0, "trace");
    defer allocator.free(r1);
    try mock.setTurnFrames(&.{r1});

    var sink = RecordingSink{ .block_after = "<think>".len, .released = std.atomic.Value(bool).init(false) };
    var turn = TurnThread{ .harness = &h, .input = .{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    } };
    const thread = try std.Thread.spawn(.{}, TurnThread.main, .{&turn});

    waitForPrompt(mock, 1);
    waitForSink(&sink, "<think>".len);
    mock.kill();
    sink.released.store(true, .release);

    thread.join();
    try std.testing.expect(turn.failure != null);
    try std.testing.expectEqualStrings("<think>trace</think>", sink.text());
}

test "dsh reasoning_mode off filters every reasoning delta" {
    // Regression: Info.reasoning_mode was hardcoded off while traces were
    // dropped unconditionally, so no test proved off really filtered.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();
    h.setCallConfig("dsh", null, .off);
    try std.testing.expectEqual(config_types.ReasoningMode.off, h.harness().info().reasoning_mode);

    const r1 = try mock_mod.reasoningDeltaFrame(allocator, 0, "hidden");
    defer allocator.free(r1);
    const text = try mock_mod.textDeltaFrame(allocator, 1, "answer");
    defer allocator.free(text);
    const end = try endFrame(allocator, "completed");
    defer allocator.free(end);
    try mock.setTurnFrames(&.{ r1, text, end });

    var sink = RecordingSink{};
    const result = try h.harness().runTurn(.{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    });
    defer allocator.free(result.reply);

    try std.testing.expectEqualStrings("answer", sink.text());
    try std.testing.expectEqualStrings("answer", result.reply);
    try std.testing.expectEqualStrings("answer", result.persisted_reply.?);
}

test "dsh reasoning_mode on quotes the trace and keeps persisted text clean" {
    // Regression: `.on` fell through to the off path, so the sidecar never
    // produced the native `Reasoning:` block.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();
    h.setCallConfig("dsh", null, .on);
    try std.testing.expectEqual(config_types.ReasoningMode.on, h.harness().info().reasoning_mode);

    const r1 = try mock_mod.reasoningDeltaFrame(allocator, 0, "hidden\n");
    defer allocator.free(r1);
    const r2 = try mock_mod.reasoningDeltaFrame(allocator, 1, "trace");
    defer allocator.free(r2);
    const text = try mock_mod.textDeltaFrame(allocator, 2, "answer");
    defer allocator.free(text);
    const end = try endFrame(allocator, "completed");
    defer allocator.free(end);
    try mock.setTurnFrames(&.{ r1, r2, text, end });

    var sink = RecordingSink{};
    const result = try h.harness().runTurn(.{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    });
    defer allocator.free(result.reply);

    try std.testing.expectEqualStrings("<think>hidden\ntrace</think>answer", sink.text());
    try std.testing.expectEqualStrings("Reasoning:\n> hidden\n> trace\n\n\nanswer", result.reply);
    try std.testing.expectEqualStrings("answer", result.persisted_reply.?);
    try std.testing.expect(std.mem.indexOf(u8, result.reply, "<think>") == null);
}

test "dsh empty reasoning deltas create no think tags or quotes" {
    // Regression: an empty delta would have opened a tag (and an empty
    // Reasoning block) if the state machine keyed on any reasoning event.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();
    h.setCallConfig("dsh", null, .on);

    const empty1 = try mock_mod.reasoningDeltaFrame(allocator, 0, "");
    defer allocator.free(empty1);
    const empty2 = try mock_mod.reasoningDeltaFrame(allocator, 1, "");
    defer allocator.free(empty2);
    const text = try mock_mod.textDeltaFrame(allocator, 2, "answer");
    defer allocator.free(text);
    const end = try endFrame(allocator, "completed");
    defer allocator.free(end);
    try mock.setTurnFrames(&.{ empty1, empty2, text, end });

    var sink = RecordingSink{};
    const result = try h.harness().runTurn(.{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = true,
    });
    defer allocator.free(result.reply);

    try std.testing.expectEqualStrings("answer", sink.text());
    try std.testing.expectEqualStrings("answer", result.reply);
    try std.testing.expect(std.mem.indexOf(u8, result.reply, "Reasoning:") == null);
}

test "dsh reasoning mode is per session key and per turn" {
    // Regression: a process-wide engine mode would have let one key filter or
    // quote another key on the same shared sidecar.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h1 = try DshHarness.init(engine, "key-a");
    defer h1.deinit();
    var h2 = try DshHarness.init(engine, "key-b");
    defer h2.deinit();
    h1.setCallConfig("dsh", null, .stream);
    h2.setCallConfig("dsh", null, .off);
    try std.testing.expectEqual(config_types.ReasoningMode.stream, h1.harness().info().reasoning_mode);
    try std.testing.expectEqual(config_types.ReasoningMode.off, h2.harness().info().reasoning_mode);

    const r1 = try mock_mod.reasoningDeltaFrame(allocator, 0, "one");
    defer allocator.free(r1);
    const t1 = try mock_mod.textDeltaFrame(allocator, 1, "1");
    defer allocator.free(t1);
    const e1 = try endFrame(allocator, "completed");
    defer allocator.free(e1);
    try mock.setTurnFrames(&.{ r1, t1, e1 });
    var sink1 = RecordingSink{};
    const first = try h1.harness().runTurn(.{
        .user_message = "hi",
        .sink = sink1.sink(),
        .live_stream = true,
    });
    defer allocator.free(first.reply);
    try std.testing.expectEqualStrings("<think>one</think>1", sink1.text());

    const r2 = try mock_mod.reasoningDeltaFrame(allocator, 0, "two");
    defer allocator.free(r2);
    const t2 = try mock_mod.textDeltaFrame(allocator, 1, "2");
    defer allocator.free(t2);
    const e2 = try endFrame(allocator, "completed");
    defer allocator.free(e2);
    try mock.setTurnFrames(&.{ r2, t2, e2 });
    var sink2 = RecordingSink{};
    const second = try h2.harness().runTurn(.{
        .user_message = "hi",
        .sink = sink2.sink(),
        .live_stream = true,
    });
    defer allocator.free(second.reply);
    try std.testing.expectEqualStrings("2", sink2.text());

    // Switch key-a to `.on` for its next turn; key-b keeps `.off`.
    h1.setCallConfig("dsh", null, .on);
    try mock.setTurnFrames(&.{ r1, t1, e1 });
    var sink3 = RecordingSink{};
    const third = try h1.harness().runTurn(.{
        .user_message = "hi",
        .sink = sink3.sink(),
        .live_stream = true,
    });
    defer allocator.free(third.reply);
    try std.testing.expectEqualStrings("<think>one</think>1", sink3.text());
    try std.testing.expectEqualStrings("Reasoning:\n> one\n\n\n1", third.reply);
    try std.testing.expectEqual(config_types.ReasoningMode.off, h2.harness().info().reasoning_mode);
}

test "dsh reasoning tags require a live stream and a sink" {
    // Regression: a closer must never appear when no tag was opened (no sink
    // or a progress-only sink with live_stream=false).
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();
    h.setCallConfig("dsh", null, .stream);

    const r1 = try mock_mod.reasoningDeltaFrame(allocator, 0, "trace");
    defer allocator.free(r1);
    const text = try mock_mod.textDeltaFrame(allocator, 1, "answer");
    defer allocator.free(text);
    const end = try endFrame(allocator, "completed");
    defer allocator.free(end);
    try mock.setTurnFrames(&.{ r1, text, end });

    var sink = RecordingSink{};
    const no_live = try h.harness().runTurn(.{
        .user_message = "hi",
        .sink = sink.sink(),
        .live_stream = false,
    });
    defer allocator.free(no_live.reply);
    try std.testing.expectEqualStrings("answer", sink.text());
    try std.testing.expect(std.mem.indexOf(u8, sink.text(), "</think>") == null);

    try mock.setTurnFrames(&.{ r1, text, end });
    const no_sink = try h.harness().runTurn(.{ .user_message = "hi" });
    defer allocator.free(no_sink.reply);
    try std.testing.expectEqualStrings("answer", no_sink.reply);
    try std.testing.expectEqualStrings("answer", no_sink.persisted_reply.?);
}

test "dsh 64 KiB reasoning trace is released and stays out of persisted text" {
    // A large trace must not leak (testing allocator) and `.on` must quote it
    // without putting a byte of it into `persisted_reply`.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = try MockDsh.init(allocator);
    defer mock.deinit();

    const boot_url = try bootUrl(allocator, mock);
    defer allocator.free(boot_url);
    const engine = try newEngine(allocator, boot_url, null);
    defer freeEngine(engine);
    var h = try DshHarness.init(engine, "test-key");
    defer h.deinit();
    h.setCallConfig("dsh", null, .on);

    const trace = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(trace);
    @memset(trace, 'r');
    const r1 = try mock_mod.reasoningDeltaFrame(allocator, 0, trace);
    defer allocator.free(r1);
    const text = try mock_mod.textDeltaFrame(allocator, 1, "answer");
    defer allocator.free(text);
    const end = try endFrame(allocator, "completed");
    defer allocator.free(end);
    try mock.setTurnFrames(&.{ r1, text, end });

    const result = try h.harness().runTurn(.{ .user_message = "hi" });
    defer allocator.free(result.reply);

    try std.testing.expect(result.reply.len > 64 * 1024);
    try std.testing.expect(std.mem.startsWith(u8, result.reply, "Reasoning:\n> "));
    try std.testing.expectEqualStrings("answer", result.persisted_reply.?);
}
