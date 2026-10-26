//! Opt-in MCP stdio integration: a real `tools/list` / `tools/call` exchange
//! against `scripts/mcp-stdio-fake-server.py`, bridged into the in-process dsh
//! engine. Skipped unless `JUNCLAW_MCP_STDIO_SERVER` names the fake server, so
//! the default CI test set never spawns a subprocess. Drive it with
//! `scripts/mcp-stdio-smoke.sh` in WSL/Docker (see that script for usage).
//!
//! Covered here, against the production `mcp.zig` client and `bridge.zig`:
//! allowlist at registration, `mcp_fake_<tool>` bridge names, per-turn
//! `tool_filter_groups`, success/failure/timeout/abort results, and the
//! 64 KB tail + spill retention rule.

const std = @import("std");
const compat = @import("compat");
const mcp = @import("../../mcp.zig");
const config_types = @import("../../config_types.zig");
const providers = @import("../../providers/root.zig");
const tools_mod = @import("../../tools/root.zig");
const fs_compat = @import("../../fs_compat.zig");
const port = @import("../port.zig");
const scripted = @import("../test_provider.zig");
const harness_mod = @import("harness.zig");
const bridge = @import("tools/bridge.zig");
const session_log = @import("session_log.zig");
const session_store = @import("session_store.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const DshNativeHarness = harness_mod.DshNativeHarness;

/// Runs an MCP tool for the bridge exactly as `session.hostToolCall` does:
/// argument object in, model-facing text out (failure text is `error_msg`).
const McpHost = struct {
    tools: []const tools_mod.Tool,

    fn executor(self: *McpHost) bridge.HostExecutor {
        return .{ .context = @ptrCast(self), .call = call };
    }

    fn call(context: *anyopaque, allocator: Allocator, name: []const u8, args: std.json.Value) anyerror!bridge.HostResult {
        const self: *McpHost = @ptrCast(@alignCast(context));
        const args_json = try std.json.Stringify.valueAlloc(allocator, args, .{});
        defer allocator.free(args_json);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch {
            return .{ .success = false, .output = "Invalid arguments JSON" };
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return .{ .success = false, .output = "Arguments must be a JSON object" },
        };
        for (self.tools) |tool| {
            if (!std.ascii.eqlIgnoreCase(tool.name(), name)) continue;
            const result = tool.execute(allocator, object) catch |err| {
                return .{ .success = false, .output = @errorName(err) };
            };
            return .{
                .success = result.success,
                .output = if (result.success) result.output else (result.error_msg orelse result.output),
            };
        }
        return .{ .success = false, .output = "Unknown tool" };
    }
};

fn toolSpecNamed(engine: *const DshNativeHarness, name: []const u8) bool {
    for (engine.tool_specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return true;
    }
    return false;
}

fn headerHasTool(event: types.Event, name: []const u8) bool {
    const header = switch (event.data) {
        .object => |object| object.get("header") orelse return false,
        else => return false,
    };
    const tools = switch (header) {
        .object => |object| object.get("tools") orelse return false,
        else => return false,
    };
    const items = switch (tools) {
        .array => |array| array.items,
        else => return false,
    };
    for (items) |item| {
        const tool_name = switch (item) {
            .object => |object| object.get("name") orelse continue,
            else => continue,
        };
        switch (tool_name) {
            .string => |value| if (std.mem.eql(u8, value, name)) return true,
            else => {},
        }
    }
    return false;
}

const ToolResultView = struct {
    text: []const u8 = "",
    is_error: bool = false,
    error_code: []const u8 = "",
};

fn toolResults(allocator: Allocator, events: []const types.Event) ![]ToolResultView {
    var results: std.ArrayListUnmanaged(ToolResultView) = .empty;
    for (events) |event| {
        if (!std.mem.eql(u8, event.event_type, "tool/result")) continue;
        const object = switch (event.data) {
            .object => |value| value,
            else => continue,
        };
        var view = ToolResultView{};
        if (object.get("message")) |message_value| {
            if (message_value == .object) {
                if (message_value.object.get("content")) |content_value| {
                    if (content_value == .array and content_value.array.items.len > 0) {
                        if (content_value.array.items[0] == .object) {
                            if (content_value.array.items[0].object.get("text")) |text_value| {
                                if (text_value == .string) view.text = text_value.string;
                            }
                        }
                    }
                }
                if (message_value.object.get("isError")) |flag| {
                    if (flag == .bool) view.is_error = flag.bool;
                }
            }
        }
        if (object.get("error")) |error_value| {
            if (error_value == .object) {
                if (error_value.object.get("code")) |code_value| {
                    if (code_value == .string) view.error_code = code_value.string;
                }
            }
        }
        try results.append(allocator, view);
    }
    return results.toOwnedSlice(allocator);
}

fn readEvents(allocator: Allocator, dsh_home: []const u8, workspace: []const u8, session_id: []const u8) !session_log.ReadResult {
    const path = try session_store.logPathAlloc(allocator, dsh_home, workspace, session_id);
    defer allocator.free(path);
    return session_log.readLog(allocator, path);
}

fn spillContains(allocator: Allocator, spill_dir: []const u8, needle: []const u8) !bool {
    var dir = compat.fs.openDirAbsolute(spill_dir, .{ .iterate = true }) catch return false;
    defer dir.close();
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ spill_dir, entry.name });
        defer allocator.free(path);
        const content = fs_compat.readFileAlloc(compat.fs.cwd(), allocator, path, 1 << 20) catch continue;
        defer allocator.free(content);
        if (std.mem.indexOf(u8, content, needle) != null) return true;
    }
    return false;
}

const AbortAfter = struct {
    target: *DshNativeHarness,
    delay_ns: u64,

    fn run(self: *AbortAfter) void {
        compat.thread.sleep(self.delay_ns);
        self.target.harness().requestInterrupt();
    }
};

test "mcp stdio bridge: allowlist, per-turn filter, calls, timeout, abort, retention" {
    const allocator = testing.allocator;
    const server_path = compat.process.getEnvVarOwned(allocator, "JUNCLAW_MCP_STDIO_SERVER") catch
        return error.SkipZigTest;
    defer allocator.free(server_path);
    if (!std.fs.path.isAbsolute(server_path)) return error.TestUnexpectedResult;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const workspace = try std.fs.path.join(allocator, &.{ root, "workspace" });
    defer allocator.free(workspace);
    const dsh_home = try std.fs.path.join(allocator, &.{ root, "dsh-home" });
    defer allocator.free(dsh_home);
    const session_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
    defer allocator.free(session_dir);
    try fs_compat.makePath(workspace);
    try fs_compat.makePath(dsh_home);
    try fs_compat.makePath(session_dir);

    // A timeout terminates the server process, so the timeout and abort
    // scenarios each get their own server. The fake server advertises `hidden`
    // too; the allowlist must drop it at initMcpTools before the bridge sees it.
    const server_configs = [_]config_types.McpServerConfig{
        .{
            .name = "fake",
            .command = "python3",
            .args = &.{server_path},
            .timeout_ms = 5_000,
            .tools = &.{ "echo", "fail", "big" },
        },
        .{
            .name = "slow",
            .command = "python3",
            .args = &.{server_path},
            .timeout_ms = 800,
            .tools = &.{"slow"},
        },
        .{
            .name = "abort",
            .command = "python3",
            .args = &.{server_path},
            .timeout_ms = 1_500,
            .tools = &.{"slow"},
        },
    };
    // The MCP client allocates every tool result with its own allocator; an
    // arena owns them for the test, and deinit still reaps each child process.
    var mcp_arena = std.heap.ArenaAllocator.init(allocator);
    defer mcp_arena.deinit();
    const mcp_allocator = mcp_arena.allocator();
    const tools = try mcp.initMcpTools(mcp_allocator, &server_configs);
    defer for (tools) |tool| tool.deinit(mcp_allocator);
    try testing.expectEqual(@as(usize, 5), tools.len);

    const host_tools = try allocator.alloc(bridge.HostTool, tools.len);
    defer allocator.free(host_tools);
    for (tools, 0..) |tool, index| {
        const spec = tool.spec();
        try testing.expect(std.mem.startsWith(u8, spec.name, "mcp_"));
        host_tools[index] = .{
            .name = spec.name,
            .description = spec.description,
            .input_schema_json = spec.parameters_json,
        };
    }

    var host = McpHost{ .tools = tools };
    var provider = scripted.ScriptedProvider{ .responses = &.{
        .{ .tool_calls = &.{
            .{ .id = "call-echo", .name = "mcp_fake_echo", .arguments = "{\"msg\":\"hello\"}" },
            .{ .id = "call-fail", .name = "mcp_fake_fail", .arguments = "{}" },
            .{ .id = "call-big", .name = "mcp_fake_big", .arguments = "{}" },
        } },
        .{ .text = "first done" },
        .{ .tool_calls = &.{.{ .id = "call-slow", .name = "mcp_slow_slow", .arguments = "{}" }} },
        .{ .text = "second done" },
        .{ .tool_calls = &.{
            .{ .id = "call-slow-2", .name = "mcp_abort_slow", .arguments = "{}" },
            .{ .id = "call-queued", .name = "mcp_fake_echo", .arguments = "{\"msg\":\"queued\"}" },
        } },
        .{ .text = "third done" },
    } };

    var engine = try DshNativeHarness.init(allocator, .{
        .session_key = "mcp-stdio-smoke",
        .dsh_home = dsh_home,
        .session_dir = session_dir,
        .workspace_dir = workspace,
        .provider = provider.provider(),
        .provider_name = "scripted",
        .model = "test-model",
        .approval_policy = .never,
        .inject_model_context = false,
        .host_tools = host_tools,
        .host_executor = host.executor(),
        .tool_filter_groups = &.{
            // These survive the allowlist unconditionally.
            .{ .mode = .always, .tools = &.{ "mcp_fake_echo", "mcp_fake_fail", "mcp_fake_big" } },
            // The slow servers are keyword-gated; `hidden` matches the glob but
            // was never registered, so no message can resurrect it.
            .{ .mode = .dynamic, .tools = &.{"mcp_*"}, .keywords = &.{"网页"} },
        },
    });
    defer engine.deinit(allocator);
    const h = engine.harness();

    // Turn 1: no CJK keyword, so the dynamic tool stays out.
    const first = try h.runTurn(.{ .user_message = "hello" });
    defer allocator.free(first.reply);
    try testing.expectEqualStrings("first done", first.reply);
    try testing.expect(toolSpecNamed(&engine, "mcp_fake_echo"));
    try testing.expect(toolSpecNamed(&engine, "mcp_fake_fail"));
    try testing.expect(toolSpecNamed(&engine, "mcp_fake_big"));
    try testing.expect(!toolSpecNamed(&engine, "mcp_slow_slow"));
    try testing.expect(!toolSpecNamed(&engine, "mcp_abort_slow"));
    try testing.expect(!toolSpecNamed(&engine, "mcp_fake_hidden"));

    var first_log = try readEvents(allocator, dsh_home, workspace, engine.session_id);
    defer first_log.deinit();
    var first_headers: usize = 0;
    for (first_log.events) |event| {
        if (!std.mem.eql(u8, event.event_type, "request/header")) continue;
        first_headers += 1;
        try testing.expect(headerHasTool(event, "mcp_fake_echo"));
        try testing.expect(!headerHasTool(event, "mcp_slow_slow"));
    }
    try testing.expect(first_headers > 0);

    const first_results = try toolResults(allocator, first_log.events);
    defer allocator.free(first_results);
    try testing.expectEqual(@as(usize, 3), first_results.len);
    try testing.expect(!first_results[0].is_error);
    try testing.expect(std.mem.indexOf(u8, first_results[0].text, "ECHO:hello") != null);
    try testing.expect(first_results[1].is_error);
    try testing.expectEqualStrings("TOOL_FAILED", first_results[1].error_code);
    try testing.expect(std.mem.indexOf(u8, first_results[1].text, "MCP tool 'fail' failed") != null);
    // 70 KB in, 64 KB tail out with the spill notice; the head is not shown.
    try testing.expect(first_results[2].text.len <= 64 * 1024 + 256);
    try testing.expect(std.mem.indexOf(u8, first_results[2].text, "BIG_TAIL_MARKER") != null);
    try testing.expect(std.mem.indexOf(u8, first_results[2].text, "BIG_BEGIN") == null);
    const spill_dir = try std.fs.path.join(allocator, &.{ dsh_home, "spill" });
    defer allocator.free(spill_dir);
    try testing.expect(try spillContains(allocator, spill_dir, "BIG_BEGIN"));

    // Turn 2: the Chinese keyword is matched as raw UTF-8 bytes.
    const second = try h.runTurn(.{ .user_message = "帮我打开网页" });
    defer allocator.free(second.reply);
    try testing.expectEqualStrings("second done", second.reply);
    try testing.expect(toolSpecNamed(&engine, "mcp_slow_slow"));
    try testing.expect(toolSpecNamed(&engine, "mcp_abort_slow"));
    try testing.expect(!toolSpecNamed(&engine, "mcp_fake_hidden"));

    var second_log = try readEvents(allocator, dsh_home, workspace, engine.session_id);
    defer second_log.deinit();
    var saw_slow_header = false;
    for (second_log.events) |event| {
        if (!std.mem.eql(u8, event.event_type, "request/header")) continue;
        if (headerHasTool(event, "mcp_slow_slow")) saw_slow_header = true;
    }
    try testing.expect(saw_slow_header);
    const second_results = try toolResults(allocator, second_log.events);
    defer allocator.free(second_results);
    try testing.expectEqual(@as(usize, 4), second_results.len);
    // The server outlives the 800 ms request timeout; the turn still ends.
    try testing.expect(second_results[3].is_error);
    try testing.expect(std.mem.indexOf(u8, second_results[3].text, "Timeout") != null);

    // Turn 3: /stop while `slow` is in flight. The started call drains on its
    // timeout; the queued call is synthesized as ABORTED_BEFORE_DISPATCH and
    // the turn returns instead of hanging.
    var abort_after = AbortAfter{ .target = &engine, .delay_ns = 200 * std.time.ns_per_ms };
    var abort_thread: ?std.Thread = try std.Thread.spawn(.{}, AbortAfter.run, .{&abort_after});
    defer if (abort_thread) |thread| thread.join();
    const third = try h.runTurn(.{ .user_message = "打开网页" });
    defer allocator.free(third.reply);
    abort_thread.?.join();
    abort_thread = null;
    try testing.expectEqual(port.EndReason.aborted, third.end_reason);

    var final_log = try readEvents(allocator, dsh_home, workspace, engine.session_id);
    defer final_log.deinit();
    const final_results = try toolResults(allocator, final_log.events);
    defer allocator.free(final_results);
    try testing.expectEqual(@as(usize, 6), final_results.len);
    try testing.expect(final_results[4].is_error);
    try testing.expect(final_results[5].is_error);
    try testing.expectEqualStrings("ABORTED_BEFORE_DISPATCH", final_results[5].error_code);
    try testing.expect(std.mem.indexOf(u8, final_results[5].text, "aborted before dispatch") != null);
    // No provider call after the abort.
    try testing.expectEqual(@as(usize, 5), provider.call_count);

    std.debug.print(
        "mcp-stdio-smoke: allowlist=4 tools/list=5 echo=ok fail=ok big_tail=ok timeout=ok abort={s} calls={d}\n",
        .{ final_results[5].error_code, provider.call_count },
    );
}
