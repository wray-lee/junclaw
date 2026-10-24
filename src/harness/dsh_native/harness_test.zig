//! Adapter-level tests for `harness.zig`: a scripted provider drives the
//! kernel through the real `port.Harness` surface.
//!
//! Fixtures use `std.testing.tmpDir`; every path is built with
//! `std.fs.path.join` so the suite runs unchanged on Windows. Nothing here
//! reads a wall clock or races: the scripted provider decides each call.

const std = @import("std");
const compat = @import("compat");
const config_types = @import("../../config_types.zig");
const fs_compat = @import("../../fs_compat.zig");
const providers = @import("../../providers/root.zig");
const port = @import("../port.zig");
const harness_mod = @import("harness.zig");
const bridge = @import("tools/bridge.zig");
const goal_mod = @import("goal.zig");
const session_log = @import("session_log.zig");
const session_store = @import("session_store.zig");
const types = @import("types.zig");
const SecurityPolicy = @import("../../security/policy.zig").SecurityPolicy;
const generated = @import("generated/interaction.zig");
const generated_system_prompt = @import("generated/system_prompt.zig");
const tool_schemas = @import("generated/tool_schemas.zig");

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
    /// The call fails; compaction's summarizer propagates this.
    fail: bool = false,
    /// The call reports provider-confirmed context overflow.
    overflow: bool = false,
    /// Provider-returned reasoning/thinking text.
    reasoning: ?[]const u8 = null,
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
    /// Test seam: runs while the call is in flight, after the request was
    /// recorded, so a command can land mid-turn.
    on_call: ?*const fn (ctx: *anyopaque) void = null,
    call_context: ?*anyopaque = null,

    /// Owned copy of what the adapter sent, so assertions stay valid after
    /// the adapter's per-call arena is reset.
    const Request = struct {
        contents: []const []const u8,
        roles: []const providers.Role,
        model: []const u8,
        reasoning_effort: ?[]const u8,
        include_reasoning: ?bool,
    };

    fn init(allocator: Allocator, replies: []const Reply) FakeProvider {
        return .{ .replies = replies, .allocator = allocator };
    }

    fn deinit(self: *FakeProvider) void {
        for (self.requests.items) |request| {
            for (request.contents) |content| self.allocator.free(content);
            self.allocator.free(request.contents);
            self.allocator.free(request.roles);
            self.allocator.free(request.model);
            if (request.reasoning_effort) |effort| self.allocator.free(effort);
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
        const roles = try self.allocator.alloc(providers.Role, request.messages.len);
        for (request.messages, 0..) |message, index| {
            contents[index] = try self.allocator.dupe(u8, message.content);
            roles[index] = message.role;
        }
        try self.requests.append(self.allocator, .{
            .contents = contents,
            .roles = roles,
            .model = try self.allocator.dupe(u8, request.model),
            .reasoning_effort = if (request.reasoning_effort) |effort|
                try self.allocator.dupe(u8, effort)
            else
                null,
            .include_reasoning = request.include_reasoning,
        });
        if (self.next >= self.replies.len) return error.UnscriptedCall;
        const reply = self.replies[self.next];
        self.next += 1;
        if (self.on_call) |hook| hook(self.call_context.?);
        if (reply.fail) return error.ScriptedFailure;
        if (reply.overflow) return error.ContextLengthExceeded;
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
            .reasoning_content = if (reply.reasoning) |reasoning|
                try allocator.dupe(u8, reasoning)
            else
                null,
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

/// Wraps a child allocator (here the testing allocator) and fills every freed
/// allocation with 0xAA. A use-after-free then reads poison instead of
/// whatever the still-mapped page happens to hold, so the assertion after the
/// read fails on every host, not only where the freed page is unmapped.
pub const PoisonAllocator = struct {
    child: Allocator,
    /// Releases that passed through the poison hook; tests assert this to
    /// prove an arena reset really poisoned its bytes.
    free_calls: usize = 0,

    pub fn allocator(self: *PoisonAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        @memset(memory, 0xAA);
        self.free_calls += 1;
        self.child.rawFree(memory, alignment, ret_addr);
    }
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
    approval_policy: config_types.DshApprovalPolicy = .ask,
    sandbox: config_types.DshSandbox = .workspace_write,
    context_window: u64 = 0,
    compaction_threshold_ratio: ?f64 = null,
    compaction_retain_ratio: ?f64 = null,
    compaction_headroom_tokens: ?u64 = null,
    question_timeout_s: i32 = 120,
    host_tools: []const bridge.HostTool = &.{},
    host_executor: ?bridge.HostExecutor = null,
    policy: ?*const SecurityPolicy = null,
    allowed_paths: []const []const u8 = &.{},
    now_ms_fn: *const fn (?*anyopaque) i64 = fixedClock,
    clock_context: ?*anyopaque = null,
    /// Production sessions inject the pre-step context; compaction mechanics
    /// tests can turn it off to keep their token budgets stable.
    inject_model_context: bool = true,

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
            .approval_policy = self.approval_policy,
            .sandbox = self.sandbox,
            .now_ms = self.now_ms_fn,
            .clock_context = self.clock_context,
            .inject_model_context = self.inject_model_context,
            .context_window = self.context_window,
            .compaction_threshold_ratio = self.compaction_threshold_ratio,
            .compaction_retain_ratio = self.compaction_retain_ratio,
            .compaction_headroom_tokens = self.compaction_headroom_tokens,
            .question_timeout_s = self.question_timeout_s,
            .host_tools = self.host_tools,
            .host_executor = self.host_executor,
            .policy = self.policy,
            .allowed_paths = self.allowed_paths,
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

const MutableClock = struct {
    now_ms: i64,

    fn now(ctx: ?*anyopaque) i64 {
        const self: *MutableClock = @ptrCast(@alignCast(ctx.?));
        return self.now_ms;
    }
};

fn writeWorkspaceFile(allocator: Allocator, workspace: []const u8, name: []const u8, content: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ workspace, name });
    defer allocator.free(path);
    const file = try fs_compat.createPath(path, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Concatenated user-role contents of one recorded request.
fn requestText(allocator: Allocator, request: FakeProvider.Request) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (request.roles, request.contents) |role, content| {
        if (role != .user) continue;
        if (out.items.len > 0) try out.appendSlice(allocator, "\n---\n");
        try out.appendSlice(allocator, content);
    }
    return out.toOwnedSlice(allocator);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |found| {
        count += 1;
        index = found + needle.len;
    }
    return count;
}

/// Text of the last logged user message with the given `source.kind`.
fn lastUserMessageText(events: []const types.Event, kind: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (events) |event| {
        if (!std.mem.eql(u8, event.event_type, "user/message")) continue;
        if (!std.mem.eql(u8, userMessageKind(event), kind)) continue;
        found = event.data.object.get("content").?.array.items[0].object.get("text").?.string;
    }
    return found;
}

fn countUserMessagesOfKind(events: []const types.Event, kind: []const u8) usize {
    var count: usize = 0;
    for (events) |event| {
        if (!std.mem.eql(u8, event.event_type, "user/message")) continue;
        if (std.mem.eql(u8, userMessageKind(event), kind)) count += 1;
    }
    return count;
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

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// The prompt in force for a request: the last system message sent.
fn lastSystemContent(request: FakeProvider.Request) []const u8 {
    var found: []const u8 = "";
    for (request.roles, request.contents) |role, content| {
        if (role == .system) found = content;
    }
    return found;
}

fn headerHasTool(event: types.Event, name: []const u8) bool {
    const data = event.data.object;
    const header = data.get("header").?.object;
    const tools = header.get("tools") orelse return false;
    for (tools.array.items) |item| {
        if (std.mem.eql(u8, item.object.get("name").?.string, name)) return true;
    }
    return false;
}

fn eventIndex(events: []const types.Event, event_type: []const u8, from: usize) ?usize {
    var index = from;
    while (index < events.len) : (index += 1) {
        if (std.mem.eql(u8, events[index].event_type, event_type)) return index;
    }
    return null;
}

fn eventCount(events: []const types.Event, event_type: []const u8) usize {
    var count: usize = 0;
    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, event_type)) count += 1;
    }
    return count;
}

fn toolResultText(event: types.Event) []const u8 {
    const message = event.data.object.get("message").?.object;
    return message.get("content").?.array.items[0].object.get("text").?.string;
}

fn toolResultFailed(event: types.Event) bool {
    const message = event.data.object.get("message").?.object;
    return message.get("isError").?.bool;
}

const BridgeFake = struct {
    calls: usize = 0,
    last_name: []const u8 = "",
    output: []const u8 = "",
    success: bool = true,

    fn executor(self: *BridgeFake) bridge.HostExecutor {
        return .{ .context = @ptrCast(self), .call = call };
    }

    fn call(context: *anyopaque, allocator: Allocator, name: []const u8, args: std.json.Value) anyerror!bridge.HostResult {
        _ = allocator;
        _ = args;
        const self: *BridgeFake = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.last_name = name;
        return .{ .success = self.success, .output = self.output };
    }
};

fn userMessageText(event: types.Event) []const u8 {
    return event.data.object.get("content").?.array.items[0].object.get("text").?.string;
}

fn userMessageKind(event: types.Event) []const u8 {
    return event.data.object.get("source").?.object.get("kind").?.string;
}

fn messageContains(message: types.Message, needle: []const u8) bool {
    for (message.content) |block| switch (block) {
        .text => |text| if (std.mem.indexOf(u8, text, needle) != null) return true,
        else => {},
    };
    return false;
}

fn dataArray(value: std.json.Value, key: []const u8) ![]const std.json.Value {
    const object = switch (value) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    };
    return switch (object.get(key) orelse return error.TestUnexpectedResult) {
        .array => |array| array.items,
        else => return error.TestUnexpectedResult,
    };
}

fn seqListContains(items: []const std.json.Value, seq: u64) bool {
    for (items) |item| switch (item) {
        .integer => |value| if (value == @as(i64, @intCast(seq))) return true,
        else => {},
    };
    return false;
}

fn summaryRange(data: std.json.Value) !struct { start: u64, end: u64 } {
    const object = switch (data) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    };
    const range = switch (object.get("shadowedRange") orelse return error.TestUnexpectedResult) {
        .object => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const start = switch (range.get("start") orelse return error.TestUnexpectedResult) {
        .integer => |value| @as(u64, @intCast(value)),
        else => return error.TestUnexpectedResult,
    };
    const end = switch (range.get("end") orelse return error.TestUnexpectedResult) {
        .integer => |value| @as(u64, @intCast(value)),
        else => return error.TestUnexpectedResult,
    };
    return .{ .start = start, .end = end };
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
    // Regression: restore handed the arena-owned mapped id to
    // openExistingSession, whose closeSession freed that arena before
    // arena.dupe read it (Linux/macOS CI: SIGABRT in memcpy). Poisoning freed
    // bytes makes that read produce a garbage id here.
    var poison = PoisonAllocator{ .child = testing.allocator };
    const allocator = poison.allocator();
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

    // The lifecycle copies the id before closeSession frees its source; the
    // leak checker must still see every byte of that temporary returned.
    h.reset();
    try h.restore(.{ .messages = &.{} });
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

test "dsh-native adapter: a restored session keeps the goal and runs the next round" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        // Turn 1: create the goal, then round 1 reports blocked.
        .{ .tool_calls = &.{.{ .id = "call-1", .name = "create_goal", .arguments = "{\"objective\":\"ship it\",\"max_goal_rounds\":4}" }} },
        .{ .text = "goal created" },
        .{ .tool_calls = &.{.{ .id = "call-2", .name = "update_goal", .arguments = "{\"goal_id\":\"goal-1\",\"revision\":1,\"action\":\"blocked\",\"blocked_reason\":\"waiting on the registry\"}" }} },
        .{ .text = "blocked after round one" },
        // After restore: the human resumes, then round 2 completes the goal.
        .{ .tool_calls = &.{.{ .id = "call-3", .name = "update_goal", .arguments = "{\"goal_id\":\"goal-1\",\"revision\":2,\"action\":\"resume\"}" }} },
        .{ .text = "resumed" },
        .{ .tool_calls = &.{.{ .id = "call-4", .name = "update_goal", .arguments = "{\"goal_id\":\"goal-1\",\"revision\":3,\"action\":\"complete\"}" }} },
        .{ .text = "finished after restore" },
    });
    defer fx.deinit();

    const first_id = blk: {
        var engine = try fx.harness();
        defer engine.deinit(allocator);
        engine.goal_tools.?.blocked_after = 1;
        const result = try engine.harness().runTurn(turnInput("start the goal"));
        allocator.free(result.reply);
        try testing.expectEqual(goal_mod.Phase.blocked, engine.goal_store.?.find().?.phase);
        try testing.expectEqual(@as(u32, 1), engine.goal_store.?.rounds_started);
        try testing.expectEqual(@as(u32, 2), engine.goal_store.?.find().?.revision);
        break :blk try allocator.dupe(u8, engine.session_id);
    };
    defer allocator.free(first_id);

    // A fresh process: the goal projection and the surface both come from the
    // JSONL through the public restore path.
    var restored = try fx.harness();
    defer restored.deinit(allocator);
    try restored.harness().restore(.{ .messages = &.{} });
    try testing.expectEqualStrings(first_id, restored.session_id);
    const replayed = restored.goal_store.?.find().?;
    try testing.expectEqual(goal_mod.Phase.blocked, replayed.phase);
    try testing.expectEqual(@as(u32, 2), replayed.revision);
    try testing.expectEqual(@as(u32, 1), restored.goal_store.?.rounds_started);
    try testing.expectEqual(goal_mod.Activation.disarmed, restored.goal_store.?.activation);

    const result = try restored.harness().runTurn(turnInput("resume and finish"));
    defer allocator.free(result.reply);
    try testing.expectEqualStrings("finished after restore", result.persisted_reply.?);
    try testing.expect(requestContains(fx.provider.requests.items[6], "Round: 2/4"));
    try testing.expect(requestContains(fx.provider.requests.items[4], "blocked after round one"));

    const done = restored.goal_store.?.find().?;
    try testing.expectEqual(goal_mod.Phase.complete, done.phase);
    try testing.expectEqual(@as(u32, 2), restored.goal_store.?.rounds_started);
    try testing.expectEqual(@as(u32, 4), done.revision);
}

test "dsh-native adapter: an unreplayable goal projection follows on_corrupt" {
    // Regression: the same restore use-after-free; where the freed page stayed
    // mapped the garbage id silently turned the corrupt log into a
    // FileNotFound fallback instead of following on_corrupt.
    var poison = PoisonAllocator{ .child = testing.allocator };
    const allocator = poison.allocator();
    var fx = try Fixture.init(allocator, &.{
        .{ .tool_calls = &.{.{ .id = "call-1", .name = "create_goal", .arguments = "{\"objective\":\"ship it\",\"max_goal_rounds\":1}" }} },
        .{ .text = "goal created" },
        .{ .text = "still working" },
    });
    defer fx.deinit();

    const first_id = blk: {
        var engine = try fx.harness();
        defer engine.deinit(allocator);
        const result = try engine.harness().runTurn(turnInput("start the goal"));
        defer allocator.free(result.reply);
        try testing.expect(result.@"error" == null);
        break :blk try allocator.dupe(u8, engine.session_id);
    };
    defer allocator.free(first_id);

    // Simulate the pre-fix pollution: a goal round the projection rejects.
    const path = try fx.logPath(allocator, first_id);
    defer allocator.free(path);
    {
        var log = try session_log.Log.open(allocator, path);
        defer log.close();
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"stale\"}],\"source\":{\"kind\":\"goal\",\"goalId\":\"goal-1\",\"revision\":9,\"round\":1},\"id\":\"stale\"}",
            .{},
        );
        defer parsed.deinit();
        _ = try log.append("user/message", parsed.value, .{ .surface_op = .append });
    }

    // Default policy stays fail-closed.
    {
        var strict = try DshNativeHarness.init(allocator, fx.options());
        defer strict.deinit(allocator);
        try testing.expectError(error.GoalInvalidChange, strict.harness().restore(.{ .messages = &.{} }));
    }

    var opts = fx.options();
    opts.on_corrupt = .native;
    var restored = try DshNativeHarness.init(allocator, opts);
    defer restored.deinit(allocator);
    try restored.harness().restore(.{ .messages = &.{} });
    try testing.expect(!std.mem.eql(u8, first_id, restored.session_id));
    try testing.expect(restored.goal_store.?.find() == null);

    // The mapping follows the fresh session, so the next restart resumes it.
    const mapping = try fx.mappingPath(allocator);
    defer allocator.free(mapping);
    const text = try readLogText(allocator, mapping);
    defer allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, restored.session_id) != null);
}

test "dsh-native adapter: builtin commands are claimed and other lines fall back" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{.{ .text = "hello" }});
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    // Open a session without a turn so `/compact` sees an empty surface.
    try h.restore(.{ .messages = &.{} });

    // Not command lines / commands this engine does not own: host fallback.
    try testing.expectEqual(@as(?[]const u8, null), try h.handleLocalCommand("hello"));
    try testing.expectEqual(@as(?[]const u8, null), try h.handleLocalCommand("/new"));
    try testing.expectEqual(@as(?[]const u8, null), try h.handleLocalCommand("/not-a-command"));
    // `/goal` is claimed; showing the empty projection creates nothing.
    try testing.expect(std.mem.indexOf(
        u8,
        (try h.handleLocalCommand("/goal")).?,
        "No goal is currently set.",
    ) != null);
    try testing.expectEqualStrings("No compactable history yet.", (try h.handleLocalCommand("/compact")).?);

    const first = try h.runTurn(turnInput("hi"));
    defer allocator.free(first.reply);

    // A claimed builtin writes its lifecycle + domain events.
    const feedback = (try h.handleLocalCommand("/feedback nice work")).?;
    try testing.expect(std.mem.indexOf(u8, feedback, "Feedback recorded") != null);

    // 64KB+ command payload: the suite runs under testing.allocator, so this
    // also covers the new wiring's release path.
    const big = try allocator.alloc(u8, 70_000);
    defer allocator.free(big);
    @memset(big, 'f');
    const line = try std.fmt.allocPrint(allocator, "/feedback {s}", .{big});
    defer allocator.free(line);
    const ack = (try h.handleLocalCommand(line)).?;
    try testing.expect(std.mem.indexOf(u8, ack, "Feedback recorded") != null);

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    const log_text = try readLogText(allocator, path);
    defer allocator.free(log_text);
    try testing.expect(std.mem.indexOf(u8, log_text, "\"command/run\"") != null);
    try testing.expect(std.mem.indexOf(u8, log_text, "\"feedback/record\"") != null);
    try testing.expect(std.mem.indexOf(u8, log_text, "\"command/done\"") != null);
}

test "dsh-native adapter: /goal commands change the projection and survive restart" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{});
    defer fx.deinit();

    const session_id = blk: {
        var engine = try fx.harness();
        defer engine.deinit(allocator);
        const h = engine.harness();
        try h.restore(.{ .messages = &.{} });

        try testing.expect(std.mem.indexOf(
            u8,
            (try h.handleLocalCommand("/goal ship the release")).?,
            "Goal created",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            (try h.handleLocalCommand("/goal edit ship the release safely")).?,
            "Goal updated",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            (try h.handleLocalCommand("/goal pause")).?,
            "Goal paused",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            (try h.handleLocalCommand("/goal resume")).?,
            "Goal resumed",
        ) != null);
        const live = engine.goal_store.?.find().?;
        try testing.expectEqualStrings("ship the release safely", live.objective);
        try testing.expectEqual(goal_mod.Phase.active, live.phase);

        // Each invocation is command/run -> goal/change -> command/done, and
        // recordInput:false leaves both lifecycle payloads without `args`.
        const path = try fx.logPath(allocator, engine.session_id);
        defer allocator.free(path);
        var read = try session_log.readLog(allocator, path);
        defer read.deinit();
        var goal_runs: usize = 0;
        for (read.events, 0..) |event, index| {
            if (!std.mem.eql(u8, event.event_type, "command/run")) continue;
            const run = switch (event.data) {
                .object => |object| object,
                else => continue,
            };
            const name = switch (run.get("name") orelse continue) {
                .string => |text| text,
                else => continue,
            };
            if (!std.mem.eql(u8, name, "goal")) continue;
            try testing.expect(run.get("args") == null);
            try testing.expect(index + 2 < read.events.len);
            try testing.expectEqualStrings("goal/change", read.events[index + 1].event_type);
            try testing.expectEqualStrings("command/done", read.events[index + 2].event_type);
            const done = switch (read.events[index + 2].data) {
                .object => |object| object,
                else => return error.TestUnexpectedResult,
            };
            try testing.expect(done.get("args") == null);
            goal_runs += 1;
        }
        try testing.expectEqual(@as(usize, 4), goal_runs);

        break :blk try allocator.dupe(u8, engine.session_id);
    };
    defer allocator.free(session_id);

    // A new harness restores the projection from the log alone.
    var restored = try fx.harness();
    defer restored.deinit(allocator);
    try restored.harness().restore(.{ .messages = &.{} });
    try testing.expectEqualStrings(session_id, restored.session_id);
    const rebuilt = restored.goal_store.?.find() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("ship the release safely", rebuilt.objective);
    try testing.expectEqual(goal_mod.Phase.active, rebuilt.phase);

    try testing.expectEqualStrings(
        "Goal cleared.",
        (try restored.harness().handleLocalCommand("/goal clear")).?,
    );
    try testing.expect(restored.goal_store.?.find() == null);

    // 64KB+ objective: the suite allocator catches a leak on this path.
    const big = try allocator.alloc(u8, 70_000);
    defer allocator.free(big);
    @memset(big, 'g');
    const line = try std.fmt.allocPrint(allocator, "/goal {s}", .{big});
    defer allocator.free(line);
    try testing.expect(std.mem.indexOf(
        u8,
        (try restored.harness().handleLocalCommand(line)).?,
        "Goal created",
    ) != null);
    _ = (try restored.harness().handleLocalCommand("/goal clear")).?;
}

test "dsh-native adapter: sandbox escalation fails closed without an approval channel" {
    const allocator = testing.allocator;
    const bash_args =
        "{\"description\":\"d\",\"command\":\"echo hi\"," ++
        "\"sandbox_permissions\":\"workspace-write\",\"justification\":\"needed\"}";
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "", .tool_calls = &.{.{ .id = "call-1", .name = "bash", .arguments = bash_args }} },
        .{ .text = "done" },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();
    const result = try h.runTurn(turnInput("run it"));
    defer allocator.free(result.reply);
    try testing.expectEqualStrings("done", result.reply);

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    const log_text = try readLogText(allocator, path);
    defer allocator.free(log_text);
    // The ask/decide audit pair exists and the tool result is the denial.
    try testing.expect(std.mem.indexOf(u8, log_text, "\"approval/asked\"") != null);
    try testing.expect(std.mem.indexOf(u8, log_text, "\"approval/decided\"") != null);
    try testing.expect(std.mem.indexOf(u8, log_text, "ToolApprovalError") != null);
    try testing.expect(std.mem.indexOf(u8, log_text, "APPROVAL_DENIED") != null);
}

test "dsh-native adapter: pre-step pressure compacts and rewrites the surface" {
    const allocator = testing.allocator;
    const big_a = try allocator.alloc(u8, 70_000);
    defer allocator.free(big_a);
    const big_b = try allocator.alloc(u8, 70_000);
    defer allocator.free(big_b);
    @memset(big_a, 'x');
    @memset(big_b, 'y');
    const first_text = try std.fmt.allocPrint(allocator, "marker-one {s}", .{big_a});
    defer allocator.free(first_text);
    const second_text = try std.fmt.allocPrint(allocator, "marker-two {s}", .{big_b});
    defer allocator.free(second_text);

    var fx = try Fixture.init(allocator, &.{
        .{ .text = "a", .prompt_tokens = 900, .completion_tokens = 10 },
        .{ .text = "b", .prompt_tokens = 900, .completion_tokens = 10 },
        // The auxiliary summary call.
        .{ .text = "condensed history", .prompt_tokens = 900, .completion_tokens = 10 },
        .{ .text = "c" },
    });
    defer fx.deinit();
    fx.context_window = 1000;
    fx.compaction_headroom_tokens = 10;
    // Keep the pressure math on the message payloads under test.
    fx.inject_model_context = false;

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    const one = try h.runTurn(turnInput(first_text));
    defer allocator.free(one.reply);
    const two = try h.runTurn(turnInput(second_text));
    defer allocator.free(two.reply);
    const three = try h.runTurn(turnInput("third"));
    defer allocator.free(three.reply);

    // a, b, the summary call, c.
    try testing.expectEqual(@as(usize, 4), fx.provider.requests.items.len);
    // The checkpoint replaced the first exchange; the retained tail survives.
    try testing.expect(!requestContains(fx.provider.requests.items[3], "marker-one"));
    try testing.expect(requestContains(fx.provider.requests.items[3], "marker-two"));

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    const log_text = try readLogText(allocator, path);
    defer allocator.free(log_text);
    try testing.expect(std.mem.indexOf(u8, log_text, "\"compaction/start\"") != null);
    try testing.expect(std.mem.indexOf(u8, log_text, "\"compaction/summary\"") != null);
    try testing.expect(std.mem.indexOf(u8, log_text, "\"compaction/end\"") != null);
    try testing.expect(std.mem.indexOf(u8, log_text, "compact-checkpoint") != null);
}

test "dsh-native adapter: a pruned result shadowed by the summary keeps the replacement seq" {
    // Regression: the pruner rewrote a tool result in place but kept its old
    // seq, so compaction/summary.shadowedSeqs and the checkpoint's
    // sourceEventSeqs named a seq the log had already replaced.
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .tool_calls = &.{.{ .id = "call-big", .name = "read", .arguments = "{\"file_path\":\"big.txt\"}" }} },
        .{ .text = "first done" },
        .{ .text = "condensed history", .prompt_tokens = 900, .completion_tokens = 10 },
        .{ .text = "second done" },
        .{ .text = "third done" },
    });
    defer fx.deinit();
    fx.context_window = 1000;
    fx.compaction_headroom_tokens = 10;
    // Keep only the newest message so the pruned result lands in the range.
    fx.compaction_retain_ratio = 0.01;

    const big_path = try std.fs.path.join(allocator, &.{ fx.workspace, "big.txt" });
    defer allocator.free(big_path);
    const big = try allocator.alloc(u8, 60_000);
    defer allocator.free(big);
    @memset(big, 'x');
    for (big, 0..) |*byte, index| {
        if (index % 80 == 79) byte.* = '\n';
    }
    {
        const file = try fs_compat.createPath(big_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(big);
    }

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();
    const one = try h.runTurn(turnInput("read big.txt"));
    defer allocator.free(one.reply);
    const two = try h.runTurn(turnInput("second"));
    defer allocator.free(two.reply);
    const three = try h.runTurn(turnInput("third"));
    defer allocator.free(three.reply);

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var log = try session_log.readLog(allocator, path);
    defer log.arena.deinit();

    var pruned_seq: ?u64 = null;
    var replacement_seq: ?u64 = null;
    var summary: ?types.Event = null;
    var checkpoint: ?types.Event = null;
    for (log.events) |event| {
        if (std.mem.eql(u8, event.event_type, "compaction/prune")) {
            const seqs = try dataArray(event.data, "shadowedSeqs");
            try testing.expectEqual(@as(usize, 1), seqs.len);
            pruned_seq = @intCast(seqs[0].integer);
        } else if (std.mem.eql(u8, event.event_type, "tool/result")) {
            if (event.surface_op) |op| switch (op) {
                .replace => |range| {
                    if (pruned_seq) |seq| {
                        if (range.start_seq == seq) replacement_seq = event.seq;
                    }
                },
                .append => {},
            };
        } else if (std.mem.eql(u8, event.event_type, "compaction/summary")) {
            summary = event;
        } else if (std.mem.eql(u8, event.event_type, "user/message")) {
            if (event.source_event_seqs != null) checkpoint = event;
        }
    }

    const old_seq = pruned_seq orelse return error.TestUnexpectedResult;
    const new_seq = replacement_seq orelse return error.TestUnexpectedResult;
    const summary_event = summary orelse return error.TestUnexpectedResult;
    const checkpoint_event = checkpoint orelse return error.TestUnexpectedResult;

    const shadowed = try dataArray(summary_event.data, "shadowedSeqs");
    try testing.expect(!seqListContains(shadowed, old_seq));
    try testing.expect(seqListContains(shadowed, new_seq));

    const range = try summaryRange(summary_event.data);
    const replace = switch (checkpoint_event.surface_op.?) {
        .replace => |value| value,
        .append => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(range.start, replace.start_seq);
    try testing.expectEqual(range.end, replace.end_seq);

    const source = checkpoint_event.source_event_seqs.?;
    try testing.expectEqual(@as(usize, 2 + shadowed.len), source.len);
    try testing.expectEqual(summary_event.seq - 1, source[0]);
    try testing.expectEqual(summary_event.seq, source[1]);
    for (shadowed, 0..) |seq, index| {
        try testing.expectEqual(@as(u64, @intCast(seq.integer)), source[2 + index]);
    }
    try testing.expect(seqListContains(shadowed, new_seq));
}

test "dsh-native adapter: restore folds a compacted surface" {
    // Regression: /compact writes a `surfaceOp: replace` checkpoint row, and
    // reopening the session aborted the fold with error.UnsupportedSurfaceOp,
    // so a compacted session could never be resumed. Poisoning freed bytes
    // makes a stale arena read after restore fail here, not only on hosts
    // where the page is unmapped.
    var poison = PoisonAllocator{ .child = testing.allocator };
    const allocator = poison.allocator();
    const big = try allocator.alloc(u8, 2_000);
    defer allocator.free(big);
    @memset(big, 'x');
    const first_text = try std.fmt.allocPrint(allocator, "marker {s}", .{big});
    defer allocator.free(first_text);
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "First reply." },
        .{ .text = "condensed history" },
    });
    defer fx.deinit();

    var before_seqs: []u64 = &.{};
    defer allocator.free(before_seqs);
    const session_id = blk: {
        var engine = try fx.harness();
        defer engine.deinit(allocator);
        const h = engine.harness();
        const first = try h.runTurn(turnInput(first_text));
        defer allocator.free(first.reply);
        _ = (try h.handleLocalCommand("/compact")) orelse return error.CommandNotClaimed;
        before_seqs = try allocator.dupe(u64, engine.surface_seqs.items);
        break :blk try allocator.dupe(u8, engine.session_id);
    };
    defer allocator.free(session_id);

    var restored = try fx.harness();
    defer restored.deinit(allocator);
    try restored.harness().restore(.{ .messages = &.{} });
    try testing.expectEqualStrings(session_id, restored.session_id);
    try testing.expectEqualSlices(u64, before_seqs, restored.surface_seqs.items);
    // System prompt, the checkpoint that replaced the user message, and the
    // retained assistant reply.
    try testing.expectEqual(@as(usize, 3), restored.messages.items.len);
    const checkpoint = restored.messages.items[1];
    try testing.expectEqual(types.MessageRole.user, checkpoint.role);
    try testing.expect(messageContains(checkpoint, "condensed history"));
}

test "dsh-native adapter: a failed manual summary records the failure transaction" {
    // Regression: a summarize failure returned before any compaction event was
    // written, while the /compact settlement said the attempt was recorded.
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "first" },
        .{ .fail = true },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();
    const first = try h.runTurn(turnInput("first"));
    defer allocator.free(first.reply);
    const settlement = (try h.handleLocalCommand("/compact")) orelse return error.CommandNotClaimed;
    try testing.expect(std.mem.indexOf(u8, settlement, "attempt is recorded in the session log") != null);

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.arena.deinit();
    try testing.expectEqual(@as(usize, 1), eventCount(read.events, "compaction/start"));
    try testing.expectEqual(@as(usize, 1), eventCount(read.events, "compaction/end"));
    try testing.expectEqual(@as(usize, 0), eventCount(read.events, "compaction/summary"));
    const start_index = eventIndex(read.events, "compaction/start", 0) orelse return error.TestUnexpectedResult;
    const end_index = eventIndex(read.events, "compaction/end", start_index + 1) orelse return error.TestUnexpectedResult;
    const run_index = eventIndex(read.events, "command/run", 0) orelse return error.TestUnexpectedResult;
    const done_index = eventIndex(read.events, "command/done", end_index + 1) orelse return error.TestUnexpectedResult;
    try testing.expect(run_index < start_index);
    try testing.expect(end_index < done_index);
    const start_data = read.events[start_index].data.object;
    const end_data = read.events[end_index].data.object;
    try testing.expectEqualStrings(
        start_data.get("compactionId").?.string,
        end_data.get("compactionId").?.string,
    );
    try testing.expectEqualStrings("ScriptedFailure", end_data.get("error").?.string);
    try testing.expect(end_data.get("sourceCommandId") != null);
}

test "dsh-native adapter: a failed automatic summary records the failure transaction" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "a" },
        // The request overflows, the forced compaction's summary then fails.
        .{ .overflow = true },
        .{ .fail = true },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();
    const first = try h.runTurn(turnInput("first"));
    defer allocator.free(first.reply);
    try testing.expectError(error.ScriptedFailure, h.runTurn(turnInput("second")));

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.arena.deinit();
    try testing.expectEqual(@as(usize, 1), eventCount(read.events, "compaction/start"));
    try testing.expectEqual(@as(usize, 1), eventCount(read.events, "compaction/end"));
    try testing.expectEqual(@as(usize, 0), eventCount(read.events, "compaction/summary"));
    const end_index = eventIndex(read.events, "compaction/end", 0) orelse return error.TestUnexpectedResult;
    const end_data = read.events[end_index].data.object;
    try testing.expectEqualStrings("ScriptedFailure", end_data.get("error").?.string);
    try testing.expectEqual(@as(i64, 2), end_data.get("turn").?.integer);
    try testing.expect(end_data.get("sourceCommandId") == null);
}

/// Highest `prefix<digits>` counter anywhere in the raw log text.
fn maxCounterSuffix(text: []const u8, prefix: []const u8) !u64 {
    var max: u64 = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, prefix)) |found| {
        var end = found + prefix.len;
        while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
        if (end > found + prefix.len) {
            const value = std.fmt.parseInt(u64, text[found + prefix.len .. end], 10) catch 0;
            if (value > max) max = value;
        }
        index = @max(end, found + 1);
    }
    return max;
}

test "dsh-native adapter: restore seeds ids past the session log" {
    // Regression: ids are process-local counters, so a resumed session minted
    // command-1, compaction-1 and approval-1 again instead of continuing past
    // the ids already in the log.
    var poison = PoisonAllocator{ .child = testing.allocator };
    const allocator = poison.allocator();
    const big = try allocator.alloc(u8, 2_000);
    defer allocator.free(big);
    @memset(big, 'x');
    const first_text = try std.fmt.allocPrint(allocator, "marker {s}", .{big});
    defer allocator.free(first_text);
    const bash_args =
        "{\"description\":\"d\",\"command\":\"echo hi\"," ++
        "\"sandbox_permissions\":\"workspace-write\",\"justification\":\"needed\"}";
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "one" },
        .{ .text = "condensed history" },
        .{ .text = "", .tool_calls = &.{.{ .id = "call-1", .name = "bash", .arguments = bash_args }} },
        .{ .text = "done" },
        // The restored session continues with these replies.
        .{ .text = "condensed again" },
        .{ .text = "", .tool_calls = &.{.{ .id = "call-2", .name = "bash", .arguments = bash_args }} },
        .{ .text = "done again" },
    });
    defer fx.deinit();

    var before_command: u64 = 0;
    var before_compaction: u64 = 0;
    var before_approval: u64 = 0;
    const session_id = blk: {
        var engine = try fx.harness();
        defer engine.deinit(allocator);
        const h = engine.harness();
        try h.restore(.{ .messages = &.{} });
        const first = try h.runTurn(turnInput(first_text));
        defer allocator.free(first.reply);
        const compact = (try h.handleLocalCommand("/compact")) orelse return error.CommandNotClaimed;
        try testing.expect(std.mem.startsWith(u8, compact, "Compacted"));
        const escalation = try h.runTurn(turnInput("escalate"));
        defer allocator.free(escalation.reply);
        _ = (try h.handleLocalCommand("/feedback seed")) orelse return error.CommandNotClaimed;

        const path = try fx.logPath(allocator, engine.session_id);
        defer allocator.free(path);
        const text = try readLogText(allocator, path);
        defer allocator.free(text);
        before_command = try maxCounterSuffix(text, "command-");
        before_compaction = try maxCounterSuffix(text, "compaction-");
        before_approval = try maxCounterSuffix(text, "approval-");
        break :blk try allocator.dupe(u8, engine.session_id);
    };
    defer allocator.free(session_id);
    try testing.expect(before_command > 0);
    try testing.expect(before_compaction > 0);
    try testing.expect(before_approval > 0);

    var restored = try fx.harness();
    defer restored.deinit(allocator);
    const h = restored.harness();
    try h.restore(.{ .messages = &.{} });
    try testing.expectEqualStrings(session_id, restored.session_id);

    const compact = (try h.handleLocalCommand("/compact")) orelse return error.CommandNotClaimed;
    try testing.expect(std.mem.startsWith(u8, compact, "Compacted"));
    const escalation = try h.runTurn(turnInput("escalate again"));
    defer allocator.free(escalation.reply);
    _ = (try h.handleLocalCommand("/feedback restored")) orelse return error.CommandNotClaimed;

    const path = try fx.logPath(allocator, session_id);
    defer allocator.free(path);
    const text = try readLogText(allocator, path);
    defer allocator.free(text);
    try testing.expect(try maxCounterSuffix(text, "command-") > before_command);
    try testing.expect(try maxCounterSuffix(text, "compaction-") > before_compaction);
    try testing.expect(try maxCounterSuffix(text, "approval-") > before_approval);
}

test "dsh-native adapter: restore reapplies the logged approval policy" {
    // Regression: after `/permission` switched the policy to ask, a restart
    // kept the configured never policy, so an escalation was rejected without
    // an approval prompt instead of failing closed for a missing channel.
    var poison = PoisonAllocator{ .child = testing.allocator };
    const allocator = poison.allocator();
    const bash_args =
        "{\"description\":\"d\",\"command\":\"echo hi\"," ++
        "\"sandbox_permissions\":\"workspace-write\",\"justification\":\"needed\"}";
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "ready" },
        .{ .text = "", .tool_calls = &.{.{ .id = "call-1", .name = "bash", .arguments = bash_args }} },
        .{ .text = "done" },
    });
    defer fx.deinit();
    fx.approval_policy = .never;

    const session_id = blk: {
        var engine = try fx.harness();
        defer engine.deinit(allocator);
        const h = engine.harness();
        const first = try h.runTurn(turnInput("hello"));
        defer allocator.free(first.reply);
        _ = (try h.handleLocalCommand("/permission workspace-write")) orelse return error.CommandNotClaimed;
        break :blk try allocator.dupe(u8, engine.session_id);
    };
    defer allocator.free(session_id);

    var restored = try fx.harness();
    defer restored.deinit(allocator);
    const h = restored.harness();
    try h.restore(.{ .messages = &.{} });
    try testing.expectEqualStrings(session_id, restored.session_id);
    const result = try h.runTurn(turnInput("escalate"));
    defer allocator.free(result.reply);

    const path = try fx.logPath(allocator, session_id);
    defer allocator.free(path);
    const log_text = try readLogText(allocator, path);
    defer allocator.free(log_text);
    try testing.expect(std.mem.indexOf(u8, log_text, "no approval channel is available") != null);
}

test "dsh-native adapter: /permission sandbox mode reaches the runtime context" {
    // Regression: sandboxMode() and the runtime-context sentence read only
    // the configured value, so `/permission workspace-write` and a restored
    // `sandbox/mode` never became visible to the model.
    var poison = PoisonAllocator{ .child = testing.allocator };
    const allocator = poison.allocator();
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "ready" },
        .{ .text = "again" },
        .{ .text = "escalated" },
    });
    defer fx.deinit();
    fx.sandbox = .read_only;

    const session_id = blk: {
        var engine = try fx.harness();
        defer engine.deinit(allocator);
        const h = engine.harness();
        const first = try h.runTurn(turnInput("hello"));
        defer allocator.free(first.reply);
        // The live policy is a pre-step runtime-context message, not part of
        // the verbatim dsh system prompt (design B15).
        try testing.expect(requestContains(fx.provider.requests.items[0], "Current DSH file policy: read-only"));
        try testing.expect(std.mem.indexOf(u8, engine.system_prompt, "Current DSH file policy") == null);
        const notice = (try h.handleLocalCommand("/permission workspace-write")) orelse
            return error.CommandNotClaimed;
        try testing.expect(std.mem.indexOf(u8, notice, "preset workspace-write") != null);
        const second = try h.runTurn(turnInput("again"));
        defer allocator.free(second.reply);
        try testing.expect(requestContains(fx.provider.requests.items[1], "Current DSH file policy: workspace-write"));
        break :blk try allocator.dupe(u8, engine.session_id);
    };
    defer allocator.free(session_id);

    var restored = try fx.harness();
    defer restored.deinit(allocator);
    try restored.harness().restore(.{ .messages = &.{} });
    try testing.expectEqualStrings(session_id, restored.session_id);
    try testing.expect(std.mem.indexOf(u8, restored.system_prompt, "Current DSH file policy") == null);
    const third = try restored.harness().runTurn(turnInput("escalate"));
    defer allocator.free(third.reply);
    try testing.expect(requestContains(fx.provider.requests.items[2], "Current DSH file policy: workspace-write"));

    // The latest retained snapshot is the workspace-write one; the earlier
    // read-only snapshot stays in history, superseded by the newer text.
    const path = try fx.logPath(allocator, session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();
    var last_runtime_context: []const u8 = "";
    for (read.events) |event| {
        if (!std.mem.eql(u8, event.event_type, "user/message")) continue;
        if (!std.mem.eql(u8, userMessageKind(event), "runtime-context")) continue;
        last_runtime_context = event.data.object.get("content").?.array.items[0].object.get("text").?.string;
    }
    try testing.expect(std.mem.indexOf(u8, last_runtime_context, "Current DSH file policy: workspace-write") != null);
    try testing.expect(std.mem.indexOf(u8, last_runtime_context, "Current DSH file policy: read-only") == null);
}

// ── plan mode ───────────────────────────────────────────────────────────────

const ReviewChannel = struct {
    approve: bool,
    calls: usize = 0,
    plan_len: usize = 0,

    fn interaction(self: *ReviewChannel) port.Interaction {
        return .{
            .ctx = self,
            .requestApproval = rejectApproval,
            .askQuestions = noAnswers,
            .planReview = reviewPlan,
        };
    }

    fn rejectApproval(_: *anyopaque, _: port.ApprovalRequest) anyerror!port.ApprovalDecision {
        return .rejected;
    }

    fn noAnswers(_: *anyopaque, _: []const port.Question) anyerror![]const port.Answer {
        return &.{};
    }

    fn reviewPlan(ctx: *anyopaque, plan_text: []const u8) anyerror!bool {
        const self: *ReviewChannel = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.plan_len = plan_text.len;
        return self.approve;
    }
};

const PlanOffHook = struct {
    harness: port.Harness,
    engine: *DshNativeHarness,
    calls: usize = 0,
    reply: ?[]const u8 = null,
    projection_pending: bool = false,
};

fn planOffDuringCall(ctx: *anyopaque) void {
    const self: *PlanOffHook = @ptrCast(@alignCast(ctx));
    self.calls += 1;
    if (self.calls != 1) return;
    self.reply = self.harness.handleLocalCommand("/plan off") catch null;
    self.projection_pending = self.engine.plan_session.projection().pending;
}

fn exitPlanArgs(allocator: Allocator, plan_text: []const u8) ![]u8 {
    var object = std.json.ObjectMap.empty;
    try object.put(allocator, "plan", .{ .string = plan_text });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{});
}

test "dsh-native adapter: plan mode toggles the policy section and exit_plan_mode" {
    const allocator = testing.allocator;
    // Regression: before the harness wiring, /plan changed only the log; every
    // request kept the base prompt and tool catalog.
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "one" },
        .{ .text = "two" },
        .{ .text = "three" },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    const first = try h.runTurn(turnInput("start"));
    allocator.free(first.reply);
    try testing.expectEqual(port.EndReason.completed, first.end_reason);

    try testing.expectEqualStrings(generated.plan_mode.on_committed, (try h.handleLocalCommand("/plan on")).?);

    const second = try h.runTurn(turnInput("plan it"));
    allocator.free(second.reply);
    try testing.expect(contains(
        lastSystemContent(fx.provider.requests.items[1]),
        generated_system_prompt.plan_policy_text,
    ));

    try testing.expectEqualStrings(generated.plan_mode.off_committed, (try h.handleLocalCommand("/plan off")).?);

    const third = try h.runTurn(turnInput("implement it"));
    allocator.free(third.reply);
    try testing.expect(!contains(
        lastSystemContent(fx.provider.requests.items[2]),
        generated_system_prompt.plan_policy_text,
    ));

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();

    var headers: [3]?types.Event = .{ null, null, null };
    var header_count: usize = 0;
    var on_narrations: usize = 0;
    var off_narrations: usize = 0;
    for (read.events) |event| {
        if (std.mem.eql(u8, event.event_type, "request/header")) {
            if (header_count < headers.len) headers[header_count] = event;
            header_count += 1;
        } else if (std.mem.eql(u8, event.event_type, "user/message")) {
            if (!std.mem.eql(u8, userMessageKind(event), "plan-mode")) continue;
            const text = userMessageText(event);
            if (std.mem.eql(u8, text, generated.plan_mode.narration_on)) on_narrations += 1;
            if (std.mem.eql(u8, text, generated.plan_mode.narration_off)) off_narrations += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), header_count);
    try testing.expect(headerHasTool(headers[0].?, tool_schemas.todo_write.name));
    try testing.expect(!headerHasTool(headers[0].?, tool_schemas.exit_plan_mode.name));
    try testing.expect(headerHasTool(headers[1].?, tool_schemas.exit_plan_mode.name));
    try testing.expect(headerHasTool(headers[1].?, tool_schemas.todo_write.name));
    try testing.expect(!headerHasTool(headers[2].?, tool_schemas.exit_plan_mode.name));
    try testing.expectEqual(@as(usize, 1), on_narrations);
    try testing.expectEqual(@as(usize, 1), off_narrations);
}

test "dsh-native adapter: a mid-turn /plan off commits at the next pre-step" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "start" },
        .{ .tool_calls = &.{.{ .id = "call-1", .name = "read", .arguments = "{\"file_path\":\"note.txt\"}" }} },
        .{ .text = "done" },
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

    const first = try h.runTurn(turnInput("start"));
    allocator.free(first.reply);
    try testing.expectEqualStrings(generated.plan_mode.on_committed, (try h.handleLocalCommand("/plan on")).?);

    var hook = PlanOffHook{ .harness = h, .engine = &engine };
    fx.provider.on_call = planOffDuringCall;
    fx.provider.call_context = &hook;

    const second = try h.runTurn(turnInput("read note.txt"));
    allocator.free(second.reply);
    try testing.expectEqual(port.EndReason.completed, second.end_reason);
    try testing.expectEqualStrings(generated.plan_mode.off_queued, hook.reply.?);
    // Regression: the live plan projection ignored the queued command's
    // `command/run` and `command/done`, so it reported pending=false while the
    // turn was open (dsh reports true until the pre-step commits).
    try testing.expect(hook.projection_pending);
    try testing.expect(contains(
        lastSystemContent(fx.provider.requests.items[1]),
        generated_system_prompt.plan_policy_text,
    ));
    try testing.expect(!contains(
        lastSystemContent(fx.provider.requests.items[2]),
        generated_system_prompt.plan_policy_text,
    ));

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();

    var off_command: ?usize = null;
    var command_runs: usize = 0;
    var tool_call: ?usize = null;
    var tool_result: ?usize = null;
    var plan_off: ?usize = null;
    var narration: ?usize = null;
    var headers: [3]?types.Event = .{ null, null, null };
    var header_indexes: [3]usize = undefined;
    var header_count: usize = 0;
    for (read.events, 0..) |event, index| {
        if (std.mem.eql(u8, event.event_type, "command/run")) {
            command_runs += 1;
            if (command_runs == 2) off_command = index;
        } else if (std.mem.eql(u8, event.event_type, "tool/call")) {
            tool_call = index;
        } else if (std.mem.eql(u8, event.event_type, "tool/result")) {
            tool_result = index;
        } else if (std.mem.eql(u8, event.event_type, "plan/mode")) {
            plan_off = index;
        } else if (std.mem.eql(u8, event.event_type, "request/header")) {
            if (header_count < headers.len) {
                headers[header_count] = event;
                header_indexes[header_count] = index;
            }
            header_count += 1;
        } else if (std.mem.eql(u8, event.event_type, "user/message")) {
            if (std.mem.eql(u8, userMessageKind(event), "plan-mode") and
                std.mem.eql(u8, userMessageText(event), generated.plan_mode.narration_off))
                narration = index;
        }
    }
    try testing.expectEqual(@as(usize, 3), header_count);
    try testing.expect(off_command.? < tool_call.?);
    try testing.expect(tool_call.? < tool_result.?);
    try testing.expect(tool_result.? < plan_off.?);
    try testing.expect(plan_off.? < header_indexes[2]);
    try testing.expect(plan_off.? < narration.?);
    try testing.expect(headerHasTool(headers[1].?, tool_schemas.exit_plan_mode.name));
    try testing.expect(!headerHasTool(headers[2].?, tool_schemas.exit_plan_mode.name));
}

test "dsh-native adapter: exit_plan_mode approval defers plan/mode to the pre-step" {
    const allocator = testing.allocator;
    var data_arena = std.heap.ArenaAllocator.init(allocator);
    defer data_arena.deinit();
    const a = data_arena.allocator();
    // 64KB+ plan text: the tool-arg and review path must not leak or truncate.
    const filler = try a.alloc(u8, 64 * 1024);
    @memset(filler, 'x');
    const plan_text = try std.fmt.allocPrint(a, "# Big plan\n{s}", .{filler});
    const args = try exitPlanArgs(a, plan_text);
    const calls = [_]providers.ToolCall{.{
        .id = "call-1",
        .name = tool_schemas.exit_plan_mode.name,
        .arguments = args,
    }};
    var replies = [_]Reply{
        .{ .text = "start" },
        .{ .tool_calls = &calls },
        .{ .text = "done" },
    };
    var fx = try Fixture.init(allocator, &replies);
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    const first = try h.runTurn(turnInput("start"));
    allocator.free(first.reply);
    try testing.expectEqualStrings(generated.plan_mode.on_committed, (try h.handleLocalCommand("/plan on")).?);

    var channel = ReviewChannel{ .approve = true };
    var input = turnInput("present the plan");
    input.interaction = channel.interaction();
    const second = try h.runTurn(input);
    allocator.free(second.reply);
    try testing.expectEqual(port.EndReason.completed, second.end_reason);
    try testing.expectEqual(@as(usize, 1), channel.calls);
    try testing.expectEqual(plan_text.len, channel.plan_len);
    try testing.expect(!engine.plan_session.state.active);
    try testing.expect(engine.plan_session.pending == null);

    // The approval step kept the plan prompt; the next pre-step dropped it.
    try testing.expect(contains(
        lastSystemContent(fx.provider.requests.items[1]),
        generated_system_prompt.plan_policy_text,
    ));
    try testing.expect(!contains(
        lastSystemContent(fx.provider.requests.items[2]),
        generated_system_prompt.plan_policy_text,
    ));

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();

    var tool_result: ?usize = null;
    var plan_off: ?usize = null;
    var off_narration = false;
    var headers: [3]?types.Event = .{ null, null, null };
    var header_indexes: [3]usize = undefined;
    var header_count: usize = 0;
    for (read.events, 0..) |event, index| {
        if (std.mem.eql(u8, event.event_type, "tool/result")) {
            tool_result = index;
            try testing.expect(!toolResultFailed(event));
            try testing.expectEqualStrings("{\"approved\":true}", toolResultText(event));
        } else if (std.mem.eql(u8, event.event_type, "plan/mode")) {
            plan_off = index;
        } else if (std.mem.eql(u8, event.event_type, "request/header")) {
            if (header_count < headers.len) {
                headers[header_count] = event;
                header_indexes[header_count] = index;
            }
            header_count += 1;
        } else if (std.mem.eql(u8, event.event_type, "user/message")) {
            if (std.mem.eql(u8, userMessageKind(event), "plan-mode") and
                std.mem.eql(u8, userMessageText(event), generated.plan_mode.narration_off))
                off_narration = true;
        }
    }
    try testing.expectEqual(@as(usize, 3), header_count);
    try testing.expect(tool_result.? < plan_off.?);
    try testing.expect(plan_off.? < header_indexes[2]);
    try testing.expect(headerHasTool(headers[1].?, tool_schemas.exit_plan_mode.name));
    try testing.expect(!headerHasTool(headers[2].?, tool_schemas.exit_plan_mode.name));
    try testing.expect(!off_narration);
}

test "dsh-native adapter: exit_plan_mode rejection keeps plan mode and returns the feedback" {
    const allocator = testing.allocator;
    var data_arena = std.heap.ArenaAllocator.init(allocator);
    defer data_arena.deinit();
    const a = data_arena.allocator();
    const args = try exitPlanArgs(a, "# Plan\n\nSteps");
    const calls = [_]providers.ToolCall{.{
        .id = "call-1",
        .name = tool_schemas.exit_plan_mode.name,
        .arguments = args,
    }};
    var replies = [_]Reply{
        .{ .text = "start" },
        .{ .tool_calls = &calls },
        .{ .text = "done" },
    };
    var fx = try Fixture.init(allocator, &replies);
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    const first = try h.runTurn(turnInput("start"));
    allocator.free(first.reply);
    try testing.expectEqualStrings(generated.plan_mode.on_committed, (try h.handleLocalCommand("/plan on")).?);

    var channel = ReviewChannel{ .approve = false };
    var input = turnInput("present the plan");
    input.interaction = channel.interaction();
    const second = try h.runTurn(input);
    allocator.free(second.reply);
    try testing.expect(engine.plan_session.state.active);
    try testing.expect(engine.plan_session.pending == null);
    try testing.expect(contains(
        lastSystemContent(fx.provider.requests.items[2]),
        generated_system_prompt.plan_policy_text,
    ));

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();

    const keep_planning = try std.fmt.allocPrint(
        allocator,
        "Error: {s}",
        .{generated.plan_mode.exit_keep_planning},
    );
    defer allocator.free(keep_planning);
    var saw_result = false;
    for (read.events) |event| {
        if (!std.mem.eql(u8, event.event_type, "tool/result")) continue;
        saw_result = true;
        try testing.expect(toolResultFailed(event));
        try testing.expectEqualStrings(keep_planning, toolResultText(event));
    }
    try testing.expect(saw_result);
    try testing.expectEqual(@as(usize, 1), eventCount(read.events, "plan/mode"));
}

test "dsh-native adapter: exit_plan_mode fails closed without an interaction channel" {
    const allocator = testing.allocator;
    var data_arena = std.heap.ArenaAllocator.init(allocator);
    defer data_arena.deinit();
    const a = data_arena.allocator();
    const args = try exitPlanArgs(a, "# Plan\n\nSteps");
    const calls = [_]providers.ToolCall{.{
        .id = "call-1",
        .name = tool_schemas.exit_plan_mode.name,
        .arguments = args,
    }};
    var replies = [_]Reply{
        .{ .text = "start" },
        .{ .tool_calls = &calls },
        .{ .text = "done" },
    };
    var fx = try Fixture.init(allocator, &replies);
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    const first = try h.runTurn(turnInput("start"));
    allocator.free(first.reply);
    try testing.expectEqualStrings(generated.plan_mode.on_committed, (try h.handleLocalCommand("/plan on")).?);

    const second = try h.runTurn(turnInput("present the plan"));
    allocator.free(second.reply);
    try testing.expect(engine.plan_session.state.active);
    try testing.expect(engine.plan_session.pending == null);

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();

    const no_channel = try std.fmt.allocPrint(
        allocator,
        "Error: {s}",
        .{generated.plan_mode.exit_no_channel},
    );
    defer allocator.free(no_channel);
    var saw_result = false;
    for (read.events) |event| {
        if (!std.mem.eql(u8, event.event_type, "tool/result")) continue;
        saw_result = true;
        try testing.expect(toolResultFailed(event));
        try testing.expectEqualStrings(no_channel, toolResultText(event));
    }
    try testing.expect(saw_result);
    try testing.expectEqual(@as(usize, 1), eventCount(read.events, "plan/mode"));
}

test "dsh-native adapter: todo_write is a core tool with a live handler" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "start" },
        .{ .tool_calls = &.{.{ .id = "call-1", .name = "todo_write", .arguments = "{\"todos\":[{\"content\":\"ship it\",\"status\":\"pending\"}]}" }} },
        .{ .text = "done" },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    const first = try h.runTurn(turnInput("start"));
    allocator.free(first.reply);
    const second = try h.runTurn(turnInput("write the list"));
    allocator.free(second.reply);
    try testing.expectEqual(port.EndReason.completed, second.end_reason);

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();

    var saw_result = false;
    for (read.events) |event| {
        if (std.mem.eql(u8, event.event_type, "tool/result")) {
            saw_result = true;
            try testing.expect(!toolResultFailed(event));
            try testing.expect(contains(toolResultText(event), "Updated todo list: 1 pending, 0 in progress, 0 completed."));
        }
    }
    try testing.expect(saw_result);
    try testing.expectEqual(@as(usize, 1), eventCount(read.events, "todo/write"));
}

test "dsh-native adapter: plan state survives a poisoned restore and reset" {
    const allocator = testing.allocator;
    var poison = PoisonAllocator{ .child = allocator };
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "one" },
        .{ .text = "two" },
        .{ .text = "three" },
        .{ .text = "four" },
    });
    defer fx.deinit();

    var engine = try harness_mod.DshNativeHarness.init(poison.allocator(), fx.options());
    defer engine.deinit(poison.allocator());
    const h = engine.harness();

    const first = try h.runTurn(turnInput("start"));
    allocator.free(first.reply);
    try testing.expectEqualStrings(generated.plan_mode.on_committed, (try h.handleLocalCommand("/plan on")).?);

    const second = try h.runTurn(turnInput("plan it"));
    allocator.free(second.reply);
    try testing.expect(contains(engine.system_prompt, generated_system_prompt.plan_policy_text));

    try h.restore(.{ .messages = &.{} });
    try testing.expect(contains(engine.system_prompt, generated_system_prompt.plan_policy_text));
    const third = try h.runTurn(turnInput("after restore"));
    allocator.free(third.reply);
    try testing.expect(contains(
        lastSystemContent(fx.provider.requests.items[2]),
        generated_system_prompt.plan_policy_text,
    ));

    h.reset();
    try testing.expect(!contains(engine.system_prompt, generated_system_prompt.plan_policy_text));
    const fourth = try h.runTurn(turnInput("after reset"));
    allocator.free(fourth.reply);
    try testing.expect(!contains(
        lastSystemContent(fx.provider.requests.items[3]),
        generated_system_prompt.plan_policy_text,
    ));
    try testing.expect(poison.free_calls > 0);
}

test "dsh-native adapter: bridged junclaw tools are model-visible and execute" {
    const allocator = testing.allocator;
    const search_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}";
    var fake = BridgeFake{ .output = "two results" };
    var fx = try Fixture.init(allocator, &.{
        .{ .tool_calls = &.{.{ .id = "call-1", .name = "web_search", .arguments = "{\"query\":\"x\"}" }} },
        .{ .text = "done" },
    });
    defer fx.deinit();
    fx.host_tools = &.{
        .{ .name = "web_search", .description = "Search the web for pages", .input_schema_json = search_schema, .concurrency_safe = true },
        // A host tool may not shadow a dsh tool, even one registered later in
        // buildTools (the bridge registers after all dsh tools for this).
        .{ .name = "bash", .description = "shadowed bash", .input_schema_json = "{}" },
    };
    fx.host_executor = fake.executor();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    // Name, description and schema reach the model exactly as junclaw has them.
    var found = false;
    for (engine.tool_schemas) |schema| {
        if (!std.mem.eql(u8, schema.name, "web_search")) continue;
        found = true;
        try testing.expectEqualStrings("Search the web for pages", schema.description);
        try testing.expectEqualStrings(search_schema, schema.parameters_json);
    }
    try testing.expect(found);
    // Regression: the bridge used to register before dsh's bash, so a host
    // "bash" entered the host map and received every bash call.
    try testing.expect(engine.registry.hostMeta("bash") == null);
    try testing.expect(engine.registry.hostMeta("web_search") != null);
    for (engine.tool_schemas) |schema| {
        if (!std.mem.eql(u8, schema.name, tool_schemas.bash.name)) continue;
        try testing.expectEqualStrings(tool_schemas.bash.description, schema.description);
    }

    const result = try h.runTurn(turnInput("search"));
    defer allocator.free(result.reply);
    try testing.expectEqualStrings("done", result.reply);
    try testing.expectEqual(@as(usize, 1), fake.calls);
    try testing.expectEqualStrings("web_search", fake.last_name);

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();
    var saw_header = false;
    var saw_result = false;
    for (read.events) |event| {
        if (std.mem.eql(u8, event.event_type, "request/header")) {
            try testing.expect(headerHasTool(event, "web_search"));
            // dsh's own file tools are not duplicated by junclaw's.
            try testing.expect(!headerHasTool(event, "file_read"));
            try testing.expect(!headerHasTool(event, "shell"));
            saw_header = true;
        } else if (std.mem.eql(u8, event.event_type, "tool/result")) {
            try testing.expect(!toolResultFailed(event));
            try testing.expectEqualStrings("two results", toolResultText(event));
            saw_result = true;
        }
    }
    try testing.expect(saw_header);
    try testing.expect(saw_result);
}

test "dsh-native adapter: bridged tool fails closed without an interaction channel" {
    const allocator = testing.allocator;
    var fake = BridgeFake{ .output = "should not run" };
    var fx = try Fixture.init(allocator, &.{
        .{ .tool_calls = &.{.{ .id = "call-1", .name = "needs_user", .arguments = "{}" }} },
        .{ .text = "done" },
    });
    defer fx.deinit();
    fx.host_tools = &.{.{ .name = "needs_user", .description = "Ask the user", .input_schema_json = "{}", .requires_interaction = true }};
    fx.host_executor = fake.executor();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();

    // `turnInput` installs no interaction channel, so the gate must refuse the
    // call before the executor runs.
    const result = try h.runTurn(turnInput("ask"));
    defer allocator.free(result.reply);
    try testing.expectEqualStrings("done", result.reply);
    try testing.expectEqual(@as(usize, 0), fake.calls);

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();
    var saw_result = false;
    for (read.events) |event| {
        if (!std.mem.eql(u8, event.event_type, "tool/result")) continue;
        try testing.expect(toolResultFailed(event));
        try testing.expect(std.mem.indexOf(u8, toolResultText(event), "interactive channel") != null);
        saw_result = true;
    }
    try testing.expect(saw_result);
}

test "dsh-native adapter: junclaw policy denies out-of-workspace reads and high-risk commands" {
    const allocator = testing.allocator;
    // The allowlist is checked before the risk tier, so `rm` must be allowed
    // explicitly for the high-risk branch to be the one under test.
    const policy = SecurityPolicy{ .allowed_commands = &.{ "rm", "ls", "cat" } };
    var fx = try Fixture.init(allocator, &.{
        .{ .tool_calls = &.{
            .{ .id = "call-1", .name = "read", .arguments = "{\"file_path\":\"../outside.txt\"}" },
            .{ .id = "call-2", .name = "bash", .arguments = "{\"description\":\"remove\",\"command\":\"rm -rf /tmp/dsh-p3-policy-nope\"}" },
        } },
        .{ .text = "done" },
    });
    defer fx.deinit();
    fx.policy = &policy;
    // Fixture.workspace is `<root>/workspace`, so this file is outside it.
    const outside = try std.fs.path.join(allocator, &.{ fx.root, "outside.txt" });
    defer allocator.free(outside);
    {
        const file = try fs_compat.createPath(outside, .{ .truncate = true });
        defer file.close();
        try file.writeAll("secret\n");
    }

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const result = try engine.harness().runTurn(turnInput("probe"));
    defer allocator.free(result.reply);
    try testing.expectEqualStrings("done", result.reply);

    // Regression: before the policy bridge, dsh read could open any path and
    // dsh bash ran any command the model asked for.
    try testing.expectEqual(@as(usize, 2), fx.provider.requests.items.len);
    const feedback = fx.provider.requests.items[1];
    try testing.expect(requestContains(feedback, "outside the session working directory"));
    try testing.expect(requestContains(feedback, "High-risk command blocked by security policy"));
}

test "dsh-native adapter: read-only autonomy denies dsh tool calls" {
    const allocator = testing.allocator;
    const policy = SecurityPolicy{ .autonomy = .read_only };
    var fx = try Fixture.init(allocator, &.{
        .{ .tool_calls = &.{.{ .id = "call-1", .name = "read", .arguments = "{\"file_path\":\"note.txt\"}" }} },
        .{ .text = "done" },
    });
    defer fx.deinit();
    fx.policy = &policy;

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const result = try engine.harness().runTurn(turnInput("probe"));
    defer allocator.free(result.reply);
    try testing.expectEqualStrings("done", result.reply);
    try testing.expectEqual(@as(usize, 2), fx.provider.requests.items.len);
    // Regression: dsh tool calls used to bypass junclaw autonomy entirely, so
    // a read_only agent could still run tools through the dsh engine.
    try testing.expect(requestContains(fx.provider.requests.items[1], "read-only mode"));
}

test "dsh-native adapter: /permission read-only reaches the file tools" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "ready" },
        .{ .tool_calls = &.{.{ .id = "call-1", .name = "write", .arguments = "{\"file_path\":\"blocked.txt\",\"content\":\"x\"}" }} },
        .{ .text = "done" },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();
    const first = try h.runTurn(turnInput("hello"));
    defer allocator.free(first.reply);
    // Regression: `/permission` only rewrote the prompt and the JSONL; the
    // file tools kept accepting writes.
    _ = (try h.handleLocalCommand("/permission read-only")) orelse return error.CommandNotClaimed;
    const result = try h.runTurn(turnInput("write"));
    defer allocator.free(result.reply);
    try testing.expectEqualStrings("done", result.reply);
    try testing.expectEqual(@as(usize, 3), fx.provider.requests.items.len);
    try testing.expect(requestContains(fx.provider.requests.items[2], "sandbox policy is read-only"));

    const written = try std.fs.path.join(allocator, &.{ fx.workspace, "blocked.txt" });
    defer allocator.free(written);
    try testing.expectError(error.FileNotFound, fs_compat.openPath(written, .{}));
}

// ── model-visible context (P3-D) ────────────────────────────────────────────

test "dsh-native adapter: runtime context is a pre-step user message" {
    // Regression: runtime context used to be appended to the system prompt,
    // so the model saw a non-dsh system message and the context never
    // refreshed per request.
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{.{ .text = "ready" }});
    defer fx.deinit();
    try writeWorkspaceFile(allocator, fx.workspace, "SOUL.md", "Persona baseline");
    try writeWorkspaceFile(allocator, fx.workspace, "MEMORY.md", "Remembered fact");
    try writeWorkspaceFile(allocator, fx.workspace, "AGENTS.md", "Operational rules");

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();
    const result = try h.runTurn(turnInput("hello"));
    defer allocator.free(result.reply);

    // dsh's system prompt stays verbatim: no runtime-context or guide text.
    try testing.expect(std.mem.indexOf(u8, engine.system_prompt, "Current runtime context") == null);
    try testing.expect(std.mem.indexOf(u8, engine.system_prompt, "Current Date & Time") == null);
    try testing.expect(std.mem.indexOf(u8, engine.system_prompt, "Persona baseline") == null);

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();
    const runtime = lastUserMessageText(read.events, "runtime-context") orelse
        return error.MissingRuntimeContext;
    try testing.expect(std.mem.indexOf(u8, runtime, "Current Date & Time") != null);
    try testing.expect(std.mem.indexOf(u8, runtime, "2023-11-14 22:13 UTC") != null);
    try testing.expect(std.mem.indexOf(u8, runtime, "Current working directory:") != null);
    try testing.expect(std.mem.indexOf(u8, runtime, "Current DSH file policy: workspace-write") != null);
    try testing.expect(std.mem.indexOf(u8, runtime, "### SOUL.md") != null);
    try testing.expect(std.mem.indexOf(u8, runtime, "Persona baseline") != null);
    try testing.expect(std.mem.indexOf(u8, runtime, "### MEMORY.md") != null);
    try testing.expect(std.mem.indexOf(u8, runtime, "Remembered fact") != null);
    // AGENTS.md belongs to the instruction baseline, not the guide block.
    try testing.expect(std.mem.indexOf(u8, runtime, "### AGENTS.md") == null);

    var checked_source = false;
    for (read.events) |event| {
        if (!std.mem.eql(u8, event.event_type, "user/message")) continue;
        if (!std.mem.eql(u8, userMessageKind(event), "runtime-context")) continue;
        const source = event.data.object.get("source").?.object;
        try testing.expectEqualStrings("snapshot", source.get("form").?.string);
        var saw_datetime = false;
        var saw_guides = false;
        for (source.get("sections").?.array.items) |section| {
            const name = section.object.get("name").?.string;
            if (std.mem.eql(u8, name, "junclaw:date-time")) saw_datetime = true;
            if (std.mem.eql(u8, name, "junclaw:workspace-guides")) saw_guides = true;
        }
        try testing.expect(saw_datetime);
        try testing.expect(saw_guides);
        checked_source = true;
    }
    try testing.expect(checked_source);

    try testing.expect(requestContains(fx.provider.requests.items[0], "Persona baseline"));
    try testing.expect(requestContains(fx.provider.requests.items[0], "Current Date & Time"));
}

test "dsh-native adapter: runtime context follows the clock and dedupes" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "one" },
        .{ .text = "two" },
        .{ .text = "three" },
    });
    defer fx.deinit();
    var clock = MutableClock{ .now_ms = 1_700_000_000_000 };
    fx.now_ms_fn = MutableClock.now;
    fx.clock_context = &clock;

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();
    const first = try h.runTurn(turnInput("hello"));
    defer allocator.free(first.reply);
    clock.now_ms += 60_000;
    const second = try h.runTurn(turnInput("again"));
    defer allocator.free(second.reply);
    const third = try h.runTurn(turnInput("same minute"));
    defer allocator.free(third.reply);

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();
    // Two snapshots: 22:13 and 22:14. The third turn does not repeat 22:14.
    try testing.expectEqual(@as(usize, 2), countUserMessagesOfKind(read.events, "runtime-context"));
    const latest = lastUserMessageText(read.events, "runtime-context").?;
    try testing.expect(std.mem.indexOf(u8, latest, "2023-11-14 22:14 UTC") != null);
    try testing.expect(requestContains(fx.provider.requests.items[1], "2023-11-14 22:14 UTC"));
}

test "dsh-native adapter: AGENTS.md follows dsh discovery and replaces on change" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "one" },
        .{ .text = "two" },
    });
    defer fx.deinit();
    try writeWorkspaceFile(allocator, fx.workspace, "AGENTS.md", "alpha rules");

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();
    const first = try h.runTurn(turnInput("hello"));
    defer allocator.free(first.reply);
    try writeWorkspaceFile(allocator, fx.workspace, "AGENTS.md", "beta rules");
    const second = try h.runTurn(turnInput("again"));
    defer allocator.free(second.reply);

    // The file body is not part of the verbatim system prompt.
    try testing.expect(std.mem.indexOf(u8, engine.system_prompt, "alpha rules") == null);
    try testing.expect(requestContains(fx.provider.requests.items[0], "alpha rules"));
    // The replacement shadows the first baseline; the old text is gone.
    try testing.expect(requestContains(fx.provider.requests.items[1], "beta rules"));
    try testing.expect(!requestContains(fx.provider.requests.items[1], "alpha rules"));

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();
    var baselines: usize = 0;
    var first_seq: u64 = 0;
    for (read.events) |event| {
        if (!std.mem.eql(u8, event.event_type, "user/message")) continue;
        if (!std.mem.eql(u8, userMessageKind(event), "agent-instructions")) continue;
        if (baselines == 0) {
            first_seq = event.seq;
            const source = event.data.object.get("source").?.object;
            try testing.expectEqualStrings("instructions", source.get("form").?.string);
            try testing.expect(source.get("baseline").?.bool);
            try testing.expectEqual(@as(usize, 64), source.get("baselineIdentity").?.string.len);
        } else {
            const replace = event.surface_op.?.replace;
            try testing.expectEqual(first_seq, replace.start_seq);
            try testing.expectEqual(first_seq, replace.end_seq);
        }
        baselines += 1;
    }
    try testing.expectEqual(@as(usize, 2), baselines);
}

test "dsh-native adapter: host memory recall rides the turn's runtime context" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "one" },
        .{ .text = "two" },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();
    const memory_block = "[Memory context]\n- test-key: remembered value\n\n";
    var with_memory = turnInput("hello");
    with_memory.memory_context = memory_block;
    const first = try h.runTurn(with_memory);
    defer allocator.free(first.reply);
    const second = try h.runTurn(turnInput("no memory this time"));
    defer allocator.free(second.reply);

    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();
    try testing.expectEqual(@as(usize, 2), countUserMessagesOfKind(read.events, "runtime-context"));
    var recalled: usize = 0;
    for (read.events) |event| {
        if (!std.mem.eql(u8, event.event_type, "user/message")) continue;
        if (!std.mem.eql(u8, userMessageKind(event), "runtime-context")) continue;
        const text = event.data.object.get("content").?.array.items[0].object.get("text").?.string;
        recalled += countOccurrences(text, "[Memory context]");
    }
    try testing.expectEqual(@as(usize, 1), recalled);
    try testing.expect(requestContains(fx.provider.requests.items[0], "- test-key: remembered value"));
    // The block stays in history for the next turn but is not recalled twice.
    const second_request = try requestText(allocator, fx.provider.requests.items[1]);
    defer allocator.free(second_request);
    try testing.expectEqual(@as(usize, 1), countOccurrences(second_request, "[Memory context]"));
}

// Regression: reasoning and text shared stream index 0, so the accumulator
// folded the answer into the reasoning block and the reply came back empty.
test "dsh-native adapter: call config updates reach the request and Info" {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, &.{
        .{ .text = "answer", .reasoning = "thinking trace" },
        .{ .text = "second" },
    });
    defer fx.deinit();

    var engine = try fx.harness();
    defer engine.deinit(allocator);
    const h = engine.harness();
    engine.setCallConfig("armbian/sub", "high", .stream);
    const first = try h.runTurn(turnInput("hello"));
    defer allocator.free(first.reply);
    try testing.expectEqualStrings("answer", first.reply);
    try testing.expectEqualStrings("armbian/sub", fx.provider.requests.items[0].model);
    try testing.expectEqualStrings("high", fx.provider.requests.items[0].reasoning_effort.?);
    try testing.expectEqual(true, fx.provider.requests.items[0].include_reasoning.?);
    const info = h.info();
    try testing.expectEqualStrings("armbian/sub", info.model_name);
    try testing.expectEqual(config_types.ReasoningMode.stream, info.reasoning_mode);

    // The reasoning trace is recorded as a reasoning block, not reply text.
    const path = try fx.logPath(allocator, engine.session_id);
    defer allocator.free(path);
    var read = try session_log.readLog(allocator, path);
    defer read.deinit();
    var saw_reasoning_block = false;
    for (read.events) |event| {
        if (!std.mem.eql(u8, event.event_type, "assistant/message")) continue;
        for (event.data.object.get("message").?.object.get("content").?.array.items) |block| {
            if (std.mem.eql(u8, block.object.get("type").?.string, "reasoning")) {
                try testing.expectEqualStrings("thinking trace", block.object.get("text").?.string);
                saw_reasoning_block = true;
            }
        }
    }
    try testing.expect(saw_reasoning_block);

    engine.setCallConfig("test-model", null, .off);
    const second = try h.runTurn(turnInput("again"));
    defer allocator.free(second.reply);
    try testing.expectEqual(false, fx.provider.requests.items[1].include_reasoning.?);
    try testing.expect(fx.provider.requests.items[1].reasoning_effort == null);
}
