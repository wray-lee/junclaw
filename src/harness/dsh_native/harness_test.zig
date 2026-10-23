//! Adapter-level tests for `harness.zig`: a scripted provider drives the
//! kernel through the real `port.Harness` surface.
//!
//! Fixtures use `std.testing.tmpDir`; every path is built with
//! `std.fs.path.join` so the suite runs unchanged on Windows. Nothing here
//! reads a wall clock or races: the scripted provider decides each call.

const std = @import("std");
const compat = @import("compat");
const fs_compat = @import("../../fs_compat.zig");
const providers = @import("../../providers/root.zig");
const port = @import("../port.zig");
const harness_mod = @import("harness.zig");
const goal_mod = @import("goal.zig");
const session_log = @import("session_log.zig");
const session_store = @import("session_store.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const DshNativeHarness = harness_mod.DshNativeHarness;

/// One scripted model call.
const Reply = struct {
    text: []const u8 = "",
    tool_calls: []const providers.ToolCall = &.{},
    prompt_tokens: u32 = 10,
    completion_tokens: u32 = 5,
    /// The provider aborts the running turn from inside `chat`, which is how a
    /// `/stop` reaches a blocking provider.
    abort: bool = false,
};

const FakeProvider = struct {
    replies: []const Reply,
    next: usize = 0,
    requests: std.ArrayListUnmanaged(Request) = .empty,
    allocator: Allocator,
    /// Test seam: runs while the "blocking" call is in flight, so it can fire
    /// a stop exactly where a real one would arrive.
    on_abort: ?*const fn (ctx: *anyopaque) void = null,
    abort_context: ?*anyopaque = null,

    /// Owned copy of what the adapter sent, so assertions stay valid after
    /// the adapter's per-call arena is reset.
    const Request = struct {
        contents: []const []const u8,
    };

    fn init(allocator: Allocator, replies: []const Reply) FakeProvider {
        return .{ .replies = replies, .allocator = allocator };
    }

    fn deinit(self: *FakeProvider) void {
        for (self.requests.items) |request| {
            for (request.contents) |content| self.allocator.free(content);
            self.allocator.free(request.contents);
        }
        self.requests.deinit(self.allocator);
    }

    fn provider(self: *FakeProvider) providers.Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = providers.Provider.VTable{
        .chatWithSystem = chatWithSystem,
        .chat = chat,
        .supportsNativeTools = supportsNativeTools,
        .getName = getName,
        .deinit = deinitFn,
    };

    fn chatWithSystem(_: *anyopaque, allocator: Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
        return allocator.dupe(u8, "");
    }

    fn chat(ptr: *anyopaque, allocator: Allocator, request: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        const contents = try self.allocator.alloc([]const u8, request.messages.len);
        for (request.messages, 0..) |message, index| {
            contents[index] = try self.allocator.dupe(u8, message.content);
        }
        try self.requests.append(self.allocator, .{ .contents = contents });
        if (self.next >= self.replies.len) return error.UnscriptedCall;
        const reply = self.replies[self.next];
        self.next += 1;
        if (reply.abort) {
            // The adapter aborts its own loop; this test seam reaches it
            // through the provider the same way a `/stop` would.
            if (self.on_abort) |hook| hook(self.abort_context.?);
            return .{
                .content = try allocator.dupe(u8, ""),
                .usage = .{ .prompt_tokens = reply.prompt_tokens, .completion_tokens = reply.completion_tokens },
            };
        }
        const calls = try allocator.alloc(providers.ToolCall, reply.tool_calls.len);
        for (reply.tool_calls, 0..) |call, index| {
            calls[index] = .{
                .id = try allocator.dupe(u8, call.id),
                .name = try allocator.dupe(u8, call.name),
                .arguments = try allocator.dupe(u8, call.arguments),
            };
        }
        return .{
            .content = try allocator.dupe(u8, reply.text),
            .tool_calls = calls,
            .usage = .{
                .prompt_tokens = reply.prompt_tokens,
                .completion_tokens = reply.completion_tokens,
                .total_tokens = reply.prompt_tokens + reply.completion_tokens,
            },
        };
    }

    fn supportsNativeTools(_: *anyopaque) bool {
        return true;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "scripted";
    }

    fn deinitFn(_: *anyopaque) void {}
};

/// Shared fixture: a temp workspace, a dsh home under it, and a harness.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    workspace: []const u8,
    dsh_home: []const u8,
    session_dir: []const u8,
    allocator: Allocator,
    provider: FakeProvider,

    fn init(allocator: Allocator, replies: []const Reply) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
        errdefer allocator.free(root);
        const workspace = try std.fs.path.join(allocator, &.{ root, "workspace" });
        errdefer allocator.free(workspace);
        try fs_compat.makePath(workspace);
        const dsh_home = try std.fs.path.join(allocator, &.{ root, "dsh-home" });
        errdefer allocator.free(dsh_home);
        try fs_compat.makePath(dsh_home);
        const session_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
        errdefer allocator.free(session_dir);
        try fs_compat.makePath(session_dir);
        return .{
            .tmp = tmp,
            .root = root,
            .workspace = workspace,
            .dsh_home = dsh_home,
            .session_dir = session_dir,
            .allocator = allocator,
            .provider = FakeProvider.init(allocator, replies),
        };
    }

    fn deinit(self: *Fixture) void {
        self.provider.deinit();
        self.allocator.free(self.workspace);
        self.allocator.free(self.dsh_home);
        self.allocator.free(self.session_dir);
        self.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn options(self: *Fixture) harness_mod.Options {
        return .{
            .session_key = "test-session-key",
            .dsh_home = self.dsh_home,
            .session_dir = self.session_dir,
            .workspace_dir = self.workspace,
            .provider = self.provider.provider(),
            .provider_name = "scripted",
            .model = "test-model",
            .persona = "",
            .now_ms = fixedClock,
        };
    }

    fn harness(self: *Fixture) !DshNativeHarness {
        return DshNativeHarness.init(self.allocator, self.options());
    }

    /// The JSONL path for `session_id`, built the same way `session_store`
    /// does it, so the assertion works on every separator.
    fn logPath(self: *Fixture, allocator: Allocator, session_id: []const u8) ![]u8 {
        return session_store.logPathAlloc(allocator, self.dsh_home, self.workspace, session_id);
    }

    fn mappingPath(self: *Fixture, allocator: Allocator) ![]u8 {
        const name = try std.fmt.allocPrint(allocator, "{x}.json", .{std.hash.Wyhash.hash(0, "test-session-key")});
        defer allocator.free(name);
        return std.fs.path.join(allocator, &.{ self.session_dir, name });
    }
};

fn fixedClock(_: ?*anyopaque) i64 {
    return 1_700_000_000_000;
}

fn turnInput(message: []const u8) port.TurnInput {
    return .{ .user_message = message };
}

fn readLogText(allocator: Allocator, path: []const u8) ![]u8 {
    return fs_compat.readFileAlloc(compat.fs.cwd(), allocator, path, 16 * 1024 * 1024);
}

/// Lets a test assert what the model saw without depending on message roles.
fn requestContains(request: FakeProvider.Request, needle: []const u8) bool {
    for (request.contents) |content| {
        if (std.mem.indexOf(u8, content, needle) != null) return true;
    }
    return false;
}

test "dsh-native adapter: plain text turn completes and persists" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{.{ .text = "hello there" }});
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    const result = try h.runTurn(turnInput("hi"));
    defer allocator.free(result.reply);

    try testing.expectEqualStrings("hello there", result.reply);
    try testing.expectEqualStrings("hello there", result.persisted_reply.?);
    try testing.expectEqual(port.EndReason.completed, result.end_reason);
    try testing.expectEqual(@as(u64, 1), result.turn_count);
    try testing.expectEqual(@as(u64, 15), result.total_tokens);
    try testing.expectEqualStrings(engine.session_id, result.dsh_session_id.?);

    // The user message reached the provider.
    try testing.expect(fx.provider.requests.items.len == 1);
    try testing.expect(requestContains(fx.provider.requests.items[0], "hi"));

    // The JSONL is a v4 log with the turn envelope.
    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    const text = try readLogText(allocator, path);
    defer allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"version\":4") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"type\":\"turn/end\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"completed\"") != null);

    var verified = try session_log.readLog(allocator, path);
    defer verified.deinit();
    try testing.expectEqualStrings(engine.session_id, verified.header.id);
}

test "dsh-native adapter: tool turn runs the read tool and feeds the result back" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .tool_calls = &.{.{ .id = "call-1", .name = "read", .arguments = "{\"file_path\":\"note.txt\"}" }} },
        .{ .text = "the file says alpha" },
    });
    defer fx.deinit();

    const note = try std.fs.path.join(allocator, &.{ fx.workspace, "note.txt" });
    defer allocator.free(note);
    {
        const file = try fs_compat.createPath(note, .{ .truncate = true });
        defer file.close();
        try file.writeAll("alpha\n");
    }

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    const result = try h.runTurn(turnInput("read note.txt"));
    defer allocator.free(result.reply);

    try testing.expectEqualStrings("the file says alpha", result.reply);
    try testing.expectEqual(port.EndReason.completed, result.end_reason);
    try testing.expectEqual(@as(u64, 2), result.turn_count);
    try testing.expectEqual(@as(usize, 2), fx.provider.requests.items.len);

    // The second request carries the tool result and the `<tool_call>` the
    // model must answer (junclaw's provider interface has no tool_calls array).
    const second = fx.provider.requests.items[1];
    try testing.expect(requestContains(second, "[Tool results]"));
    try testing.expect(requestContains(second, "alpha"));
    try testing.expect(requestContains(second, "<tool_call>"));
    try testing.expect(requestContains(second, "read"));

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var verified = try session_log.readLog(allocator, path);
    defer verified.deinit();
    var saw_call = false;
    var saw_result = false;
    for (verified.events) |event| {
        if (std.mem.eql(u8, event.event_type, "tool/call")) saw_call = true;
        if (std.mem.eql(u8, event.event_type, "tool/result")) saw_result = true;
    }
    try testing.expect(saw_call and saw_result);
}

test "dsh-native adapter: requestInterrupt ends the turn aborted" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{.{ .text = "never seen", .abort = true }});
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    // Wire the scripted provider to the engine's own interrupt entry point,
    // exactly what `/stop` does while a blocking call is in flight.
    fx.provider.on_abort = struct {
        fn hook(ctx: *anyopaque) void {
            const target: *DshNativeHarness = @ptrCast(@alignCast(ctx));
            target.harness().requestInterrupt();
        }
    }.hook;
    fx.provider.abort_context = @ptrCast(&engine);

    const result = try h.runTurn(turnInput("do work"));
    defer allocator.free(result.reply);

    try testing.expectEqual(port.EndReason.aborted, result.end_reason);
    try testing.expectEqualStrings("user", result.abort_cause.?);
    try testing.expectEqualStrings("", result.reply);

    // The next turn is not poisoned by the consumed interrupt: it reaches the
    // provider again (which has no second reply scripted) instead of aborting
    // before the call.
    const second = try h.runTurn(turnInput("again"));
    defer allocator.free(second.reply);
    defer if (second.@"error") |text| allocator.free(text);
    try testing.expectEqual(port.EndReason.@"error", second.end_reason);
    try testing.expectEqualStrings("UnscriptedCall", second.error_code.?);
    try testing.expectEqual(@as(usize, 2), fx.provider.requests.items.len);
}

test "dsh-native adapter: clearInterrupt drops a stop that landed after the turn" {
    // Regression: a /stop delivered while the reply was being delivered set
    // the kernel abort flag after `runTurn` had reset it; `clearInterrupt`
    // only cleared the adapter flag, so the next turn returned `.aborted`
    // without ever calling the provider.
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{.{ .text = "first" }});
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    const first = try h.runTurn(turnInput("hello"));
    defer allocator.free(first.reply);
    try testing.expectEqual(port.EndReason.completed, first.end_reason);

    // Arrives only after the turn ended, while the host is delivering it.
    h.requestInterrupt();
    h.clearInterrupt();
    try testing.expect(!engine.interruptPending());

    const second = try h.runTurn(turnInput("again"));
    defer allocator.free(second.reply);
    defer if (second.@"error") |text| allocator.free(text);
    try testing.expectEqual(port.EndReason.@"error", second.end_reason);
    try testing.expectEqualStrings("UnscriptedCall", second.error_code.?);
    try testing.expectEqual(@as(usize, 2), fx.provider.requests.items.len);
}

test "dsh-native adapter: reset mints a new id, log and mapping" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "one" },
        .{ .text = "two" },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    const first = try h.runTurn(turnInput("first"));
    defer allocator.free(first.reply);
    const first_id = try allocator.dupe(u8, engine.session_id);
    defer allocator.free(first_id);
    const first_path = try fx.logPath(allocator, first_id);
    defer allocator.free(first_path);

    h.reset();
    try testing.expect(!std.mem.eql(u8, first_id, engine.session_id));

    const second_path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(second_path);
    try testing.expect(!std.mem.eql(u8, first_path, second_path));
    const second_bytes = try readLogText(allocator, second_path);
    defer allocator.free(second_bytes);
    try testing.expect(std.mem.indexOf(u8, second_bytes, "\"version\":4") != null);

    // Mapping: `{dir}/{Wyhash(key)}.json`, `{"sessionId":"<id>"}`, atomically
    // readable (the temp file never survives the rename).
    const mapping = try fx.mappingPath(allocator);
    defer allocator.free(mapping);
    const loaded = try session_store.loadMapping(allocator, mapping);
    defer if (loaded) |value| allocator.free(value);
    try testing.expectEqualStrings(engine.session_id, loaded.?);
    const raw = try readLogText(allocator, mapping);
    defer allocator.free(raw);
    const expected = try std.fmt.allocPrint(allocator, "{{\"sessionId\":\"{s}\"}}", .{engine.session_id});
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, raw);

    const second = try h.runTurn(turnInput("second"));
    defer allocator.free(second.reply);
    try testing.expectEqualStrings("two", second.reply);
}

test "dsh-native adapter: restore reopens the same JSONL and replays the surface" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "answer one" },
        .{ .text = "answer two" },
    });
    defer fx.deinit();

    const first_id = blk: {
        var engine = try fx.harness();
        defer engine.deinit(allocator);
        const h = engine.harness();
        const result = try h.runTurn(turnInput("question one"));
        allocator.free(result.reply);
        break :blk try allocator.dupe(u8, engine.session_id);
    };
    defer allocator.free(first_id);

    const path = try fx.logPath(allocator, first_id);
    defer allocator.free(path);
    const before = try readLogText(allocator, path);
    defer allocator.free(before);

    // A fresh process: no in-memory state, only the mapping on disk.
    var restored = try fx.harness();
    defer restored.deinit(allocator);
    const h = restored.harness();
    try h.restore(.{ .messages = &.{} });
    try testing.expectEqualStrings(first_id, restored.session_id);

    const second = try h.runTurn(turnInput("question two"));
    defer allocator.free(second.reply);
    try testing.expectEqualStrings("answer two", second.reply);

    // Same file, appended in place: the old prefix is unchanged and the new
    // turn is in it. Resuming therefore never forks a second JSONL.
    const after = try readLogText(allocator, path);
    defer allocator.free(after);
    try testing.expect(after.len > before.len);
    try testing.expect(std.mem.startsWith(u8, after, before));
    try testing.expect(std.mem.indexOf(u8, after, "question two") != null);

    // The replayed surface reached the model: the second request knows the
    // first question and answer.
    try testing.expect(fx.provider.requests.items.len == 2);
    try testing.expect(requestContains(fx.provider.requests.items[1], "question one"));
    try testing.expect(requestContains(fx.provider.requests.items[1], "answer one"));
}

test "dsh-native adapter: usage accumulates across turns" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "a", .prompt_tokens = 10, .completion_tokens = 5 },
        .{ .text = "b", .prompt_tokens = 20, .completion_tokens = 5 },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    const first = try h.runTurn(turnInput("one"));
    defer allocator.free(first.reply);
    try testing.expectEqual(@as(u64, 15), first.total_tokens);

    const second = try h.runTurn(turnInput("two"));
    defer allocator.free(second.reply);
    try testing.expectEqual(@as(u64, 40), second.total_tokens);
}

test "dsh-native adapter: steer enters the kernel inbox at a step boundary" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .tool_calls = &.{.{ .id = "call-1", .name = "glob", .arguments = "{\"pattern\":\"*.txt\"}" }} },
        .{ .text = "done after steer" },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    const Drain = struct {
        provider: *FakeProvider,
        provided: bool = false,

        fn callback(ctx: *anyopaque, arena: Allocator) anyerror!?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // Deterministic gate: the steer only exists once the model has
            // answered the first step, so it can only be claimed at the next
            // step boundary, never inside the in-flight request.
            if (self.provided or self.provider.next == 0) return null;
            self.provided = true;
            return try arena.dupe(u8, "steer: also check subdirs");
        }
    };
    var drain = Drain{ .provider = &fx.provider };

    var input = turnInput("list files");
    input.drain = Drain.callback;
    input.drain_ctx = @ptrCast(&drain);

    const result = try h.runTurn(input);
    defer allocator.free(result.reply);

    try testing.expectEqualStrings("done after steer", result.reply);
    try testing.expect(drain.provided);
    try testing.expect(fx.provider.requests.items.len == 2);
    // Step 1's request predates the steer; step 2's carries it.
    try testing.expect(!requestContains(fx.provider.requests.items[0], "also check subdirs"));
    try testing.expect(requestContains(fx.provider.requests.items[1], "also check subdirs"));
}

test "dsh-native adapter: a 64KB+ prompt round-trips without leaking" {
    // Regression: an adapter that borrows the host's input across turns keeps
    // the caller's buffer alive; testing.allocator fails the test if anything
    // allocated here is not freed.
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{.{ .text = "big ok" }});
    defer fx.deinit();

    const big = try allocator.alloc(u8, 130 * 1024);
    defer allocator.free(big);
    @memset(big, 'x');

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    const result = try h.runTurn(turnInput(big));
    defer allocator.free(result.reply);
    try testing.expectEqualStrings("big ok", result.reply);

    // And the whole 130KB reached the log intact.
    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    const text = try readLogText(allocator, path);
    defer allocator.free(text);
    try testing.expect(text.len > big.len);
    var run: usize = 0;
    var best: usize = 0;
    for (text) |byte| {
        if (byte == 'x') {
            run += 1;
            best = @max(best, run);
        } else run = 0;
    }
    try testing.expectEqual(big.len, best);
}

test "dsh-native adapter: session paths are built with the native separator" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{.{ .text = "ok" }});
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const result = try engine.harness().runTurn(turnInput("path probe"));
    defer allocator.free(result.reply);

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);

    try testing.expect(std.fs.path.isAbsolute(path));
    try testing.expect(std.mem.startsWith(u8, path, fx.dsh_home));
    try testing.expect(std.mem.endsWith(u8, path, session_store.log_basename));
    // The joined path must not contain a separator that the platform does not
    // use (a hardcoded '/' would fail this on Windows).
    if (std.fs.path.sep != '/') {
        try testing.expect(std.mem.indexOfScalar(u8, path, '/') == null);
    }

    const mapping = try fx.mappingPath(allocator);
    defer allocator.free(mapping);
    try testing.expect(std.mem.startsWith(u8, mapping, fx.session_dir));
    try testing.expect(std.mem.endsWith(u8, mapping, ".json"));
}

test "dsh-native adapter: goal complete waits for the wrap-up reply" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .tool_calls = &.{.{ .id = "call-1", .name = "create_goal", .arguments = "{\"objective\":\"ship it\",\"max_goal_rounds\":4}" }} },
        .{ .text = "goal created" },
        .{ .tool_calls = &.{.{ .id = "call-2", .name = "update_goal", .arguments = "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"complete\"}" }} },
        .{ .text = "Shipped and verified the whole objective." },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);

    const result = try engine.harness().runTurn(turnInput("ship the goal"));
    defer allocator.free(result.reply);

    try testing.expectEqual(port.EndReason.completed, result.end_reason);
    try testing.expectEqualStrings("Shipped and verified the whole objective.", result.persisted_reply.?);
    try testing.expectEqual(@as(u64, 4), result.turn_count);
    try testing.expectEqual(@as(usize, 4), fx.provider.requests.items.len);
    try testing.expect(requestContains(fx.provider.requests.items[2], "<goal_round>"));
    try testing.expect(requestContains(fx.provider.requests.items[2], "Round: 1/4"));
    try testing.expect(requestContains(fx.provider.requests.items[3], "<goal_complete>"));
    try testing.expect(requestContains(fx.provider.requests.items[3], "Objective: \"ship it\""));

    try testing.expectEqual(goal_mod.Phase.complete, engine.goal_store.?.find().?.phase);
    try testing.expectEqual(@as(u32, 1), engine.goal_store.?.rounds_started);

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();
    var rounds: usize = 0;
    var wrapups: usize = 0;
    var last_turn_end: ?[]const u8 = null;
    for (read.events) |event| {
        if (std.mem.eql(u8, event.event_type, "turn/end")) {
            last_turn_end = event.data.object.get("reason").?.object.get("kind").?.string;
            continue;
        }
        if (!std.mem.eql(u8, event.event_type, "user/message")) continue;
        const message = event.data.object;
        const source = message.get("source").?.object;
        const kind = source.get("kind").?.string;
        if (std.mem.eql(u8, kind, "goal")) {
            rounds += 1;
            try testing.expectEqual(@as(i64, 1), source.get("round").?.integer);
        } else if (std.mem.eql(u8, kind, "tool-goal")) {
            wrapups += 1;
            const text = message.get("content").?.array.items[0].object.get("text").?.string;
            try testing.expect(std.mem.startsWith(u8, text, "<goal_complete>"));
        }
    }
    try testing.expectEqual(@as(usize, 1), rounds);
    try testing.expectEqual(@as(usize, 1), wrapups);
    // The wrap-up reply closed the last kernel turn normally, not by a hard stop.
    try testing.expectEqualStrings("completed", last_turn_end.?);
}

test "dsh-native adapter: goal blocked waits for the wrap-up reply" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .tool_calls = &.{.{ .id = "call-1", .name = "create_goal", .arguments = "{\"objective\":\"ship it\",\"max_goal_rounds\":4}" }} },
        .{ .text = "goal created" },
        .{ .tool_calls = &.{.{ .id = "call-2", .name = "update_goal", .arguments = "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"blocked\",\"blocked_reason\":\"the registry is read-only\"}" }} },
        .{ .text = "Blocked on the registry; tell me how to proceed." },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    engine.goal_tools.?.blocked_after = 1;

    const result = try engine.harness().runTurn(turnInput("ship the goal"));
    defer allocator.free(result.reply);

    try testing.expectEqual(port.EndReason.completed, result.end_reason);
    try testing.expectEqualStrings("Blocked on the registry; tell me how to proceed.", result.persisted_reply.?);
    try testing.expectEqual(@as(usize, 4), fx.provider.requests.items.len);
    try testing.expect(requestContains(fx.provider.requests.items[3], "<goal_blocked>"));
    try testing.expect(requestContains(fx.provider.requests.items[3], "Blocked: \"the registry is read-only\""));

    const blocked = engine.goal_store.?.find().?;
    try testing.expectEqual(goal_mod.Phase.blocked, blocked.phase);
    try testing.expectEqualStrings("model-reported", blocked.blocked_reason.?.code);
    try testing.expectEqual(@as(u32, 1), engine.goal_store.?.rounds_started);
}

test "dsh-native adapter: the goal round cap blocks instead of following up" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .tool_calls = &.{.{ .id = "call-1", .name = "create_goal", .arguments = "{\"objective\":\"ship it\",\"max_goal_rounds\":1}" }} },
        .{ .text = "goal created" },
        .{ .text = "still working" },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);

    const result = try engine.harness().runTurn(turnInput("ship the goal"));
    defer allocator.free(result.reply);

    try testing.expectEqual(port.EndReason.completed, result.end_reason);
    try testing.expectEqualStrings("still working", result.persisted_reply.?);
    // Three model calls total: the two-step human turn and exactly one goal round.
    try testing.expectEqual(@as(usize, 3), fx.provider.requests.items.len);
    try testing.expectEqual(@as(u32, 1), engine.goal_store.?.rounds_started);

    const blocked = engine.goal_store.?.find().?;
    try testing.expectEqual(goal_mod.Phase.blocked, blocked.phase);
    try testing.expectEqualStrings("round-limit", blocked.blocked_reason.?.code);
    try testing.expectEqualStrings(
        "Goal reached its configured limit of 1 rounds.",
        blocked.blocked_reason.?.message,
    );
}
