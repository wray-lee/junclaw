//! DshHarness tests against the in-process dsh mock (no Node, no real dsh).

const std = @import("std");
const builtin = @import("builtin");
const std_compat = @import("compat");
const fs_compat = @import("../../fs_compat.zig");
const port = @import("../port.zig");
const harness_mod = @import("harness.zig");
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
    // One process-wide engine: two keys share a single boot/connect.
    try std.testing.expectEqual(@as(u32, 1), mock.connectCount());
    // Each prompt landed on the session the key created for itself.
    try std.testing.expectEqualStrings("mock-sess-1", first_session);
    try std.testing.expectEqualStrings("mock-sess-2", second_session);
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
    try std.testing.expectEqual(@as(u32, 2), mock.wsConnections());
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
