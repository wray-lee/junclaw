//! Integration tests for the WebDriver browser backend, driven through
//! `BrowserTool` against a scripted loopback driver. No real geckodriver or
//! Firefox is started. Every fake server is stopped and joined on all exits,
//! and the idle test drives an injected clock instead of sleeping.
const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const root = @import("root.zig");
const browser_mod = @import("browser.zig");
const lifecycle = @import("webdriver_lifecycle.zig");
const fake = @import("webdriver_fake_server.zig");

const testing = std.testing;
const allocator = testing.allocator;

const snapshot_body =
    "{\"value\":{\"title\":\"Example\",\"url\":\"https://example.com/page\",\"text\":\"hello page\"," ++
    "\"elements\":[{\"tag\":\"button\",\"label\":\"Go\",\"detail\":\"\"}],\"more\":false}}";

fn webdriverTool(base: []const u8, allowed_domains: []const []const u8) browser_mod.BrowserTool {
    return .{
        .config = .{
            .enabled = true,
            .backend = "webdriver",
            .allowed_domains = allowed_domains,
        },
        .webdriver_url = base,
    };
}

fn execute(bt: *browser_mod.BrowserTool, json: []const u8) !root.ToolResult {
    var parsed = try root.parseTestArgs(json);
    defer parsed.deinit();
    return bt.execute(allocator, parsed.value.object);
}

test "webdriver integration runs the full session, snapshot, click, type and close sequence" {
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\",\"capabilities\":{}}}" },
        .{ .method = "POST", .path = "/session/fake-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "GET", .path = "/session/fake-session/window/handles", .body = "{\"value\":[\"main\"]}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "POST", .path = "/session/fake-session/execute/sync", .body = snapshot_body },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "GET", .path = "/session/fake-session/window/handles", .body = "{\"value\":[\"main\"]}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "POST", .path = "/session/fake-session/element", .body = "{\"value\":{\"element-6066-11e4-a52e-4f735466cecf\":\"el-1\"}}" },
        .{ .method = "POST", .path = "/session/fake-session/element/el-1/click", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/fake-session/window/handles", .body = "{\"value\":[\"main\"]}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "POST", .path = "/session/fake-session/element", .body = "{\"value\":{\"element-6066-11e4-a52e-4f735466cecf\":\"el-2\"}}" },
        .{ .method = "POST", .path = "/session/fake-session/element/el-2/value", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/fake-session/window/handles", .body = "{\"value\":[\"main\"]}" },
        .{ .method = "DELETE", .path = "/session/fake-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base = try server.url(allocator);
    defer allocator.free(base);

    var bt = webdriverTool(base, &.{"example.com"});
    defer bt.shutdown();

    const opened = try execute(&bt, "{\"action\":\"open\",\"url\":\"https://example.com/page\"}");
    defer allocator.free(opened.output);
    try testing.expect(opened.success);

    const snapshot = try execute(&bt, "{\"action\":\"snapshot\"}");
    defer allocator.free(snapshot.output);
    try testing.expect(snapshot.success);
    try testing.expect(std.mem.indexOf(u8, snapshot.output, "[0] <button> Go") != null);

    const clicked = try execute(&bt, "{\"action\":\"click\",\"index\":0}");
    defer allocator.free(clicked.output);
    try testing.expect(clicked.success);

    const typed = try execute(&bt, "{\"action\":\"type\",\"index\":1,\"text\":\"hello\"}");
    defer allocator.free(typed.output);
    try testing.expect(typed.success);

    // `close` returns a static string, so its output must not be freed.
    const closed = try execute(&bt, "{\"action\":\"close\"}");
    try testing.expect(closed.success);
    try testing.expect(bt.manager == null);

    server.stopAndJoin();
    try testing.expectEqual(routes.len, server.request_count);

    try testing.expectEqualStrings("POST", server.requests[0].method);
    try testing.expectEqualStrings("/session", server.requests[0].path);
    try testing.expect(std.mem.indexOf(u8, server.requests[0].body, "\"browserName\":\"firefox\"") != null);

    try testing.expectEqualStrings("POST", server.requests[1].method);
    try testing.expectEqualStrings("/session/fake-session/url", server.requests[1].path);
    try testing.expect(std.mem.indexOf(u8, server.requests[1].body, "https://example.com/page") != null);
    try testing.expectEqualStrings("GET", server.requests[2].method);
    try testing.expectEqualStrings("/session/fake-session/url", server.requests[2].path);
    try testing.expectEqualStrings("GET", server.requests[3].method);
    try testing.expectEqualStrings("/session/fake-session/window/handles", server.requests[3].path);

    try testing.expectEqualStrings("GET", server.requests[4].method);
    try testing.expectEqualStrings("/session/fake-session/url", server.requests[4].path);
    try testing.expectEqualStrings("/session/fake-session/execute/sync", server.requests[5].path);
    try testing.expect(std.mem.indexOf(u8, server.requests[5].body, "data-junclaw-ref") != null);

    // Snapshot post-script recheck, then its window sweep, then the click
    // pre-check.
    try testing.expectEqualStrings("GET", server.requests[6].method);
    try testing.expectEqualStrings("/session/fake-session/url", server.requests[6].path);
    try testing.expectEqualStrings("/session/fake-session/window/handles", server.requests[7].path);
    try testing.expectEqualStrings("GET", server.requests[8].method);
    try testing.expectEqualStrings("/session/fake-session/url", server.requests[8].path);
    try testing.expectEqualStrings("/session/fake-session/element", server.requests[9].path);
    try testing.expect(std.mem.indexOf(u8, server.requests[9].body, "data-junclaw-ref=\\\"0\\\"") != null);
    try testing.expectEqualStrings("/session/fake-session/element/el-1/click", server.requests[10].path);

    try testing.expectEqualStrings("/session/fake-session/window/handles", server.requests[11].path);
    try testing.expectEqualStrings("GET", server.requests[12].method);
    try testing.expectEqualStrings("/session/fake-session/url", server.requests[12].path);
    try testing.expectEqualStrings("/session/fake-session/element", server.requests[13].path);
    try testing.expect(std.mem.indexOf(u8, server.requests[13].body, "data-junclaw-ref=\\\"1\\\"") != null);
    try testing.expectEqualStrings("/session/fake-session/element/el-2/value", server.requests[14].path);
    try testing.expect(std.mem.indexOf(u8, server.requests[14].body, "\"text\":\"hello\"") != null);
    try testing.expectEqualStrings("/session/fake-session/window/handles", server.requests[15].path);

    try testing.expectEqualStrings("DELETE", server.requests[16].method);
    try testing.expectEqualStrings("/session/fake-session", server.requests[16].path);

    var session_posts: usize = 0;
    for (server.requests) |request| {
        if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/session")) session_posts += 1;
    }
    try testing.expectEqual(@as(usize, 1), session_posts);
}

// F4 depth: an action can open tabs/windows the URL checks never see; after
// every successful action the extra windows are closed and recorded.
test "webdriver integration closes extra windows after an action and keeps the current one" {
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"popup-session\",\"capabilities\":{}}}" },
        .{ .method = "POST", .path = "/session/popup-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/popup-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "GET", .path = "/session/popup-session/window/handles", .body = "{\"value\":[\"main-handle\",\"popup-handle\"]}" },
        .{ .method = "GET", .path = "/session/popup-session/window", .body = "{\"value\":\"main-handle\"}" },
        .{ .method = "POST", .path = "/session/popup-session/window", .body = "{\"value\":null}" },
        .{ .method = "POST", .path = "/session/popup-session/window/close", .body = "{\"value\":null}" },
        .{ .method = "POST", .path = "/session/popup-session/window", .body = "{\"value\":null}" },
        .{ .method = "DELETE", .path = "/session/popup-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base = try server.url(allocator);
    defer allocator.free(base);

    var bt = webdriverTool(base, &.{"example.com"});
    defer bt.shutdown();

    const opened = try execute(&bt, "{\"action\":\"open\",\"url\":\"https://example.com/page\"}");
    defer allocator.free(opened.output);
    try testing.expect(opened.success);
    try testing.expect(std.mem.indexOf(u8, opened.output, "Closed 1 extra browser window(s): popup-handle") != null);

    bt.shutdown();
    server.stopAndJoin();
    try testing.expectEqual(routes.len, server.request_count);
    try testing.expectEqualStrings("GET", server.requests[3].method);
    try testing.expectEqualStrings("/session/popup-session/window/handles", server.requests[3].path);
    try testing.expectEqualStrings("GET", server.requests[4].method);
    try testing.expectEqualStrings("/session/popup-session/window", server.requests[4].path);
    // Close the extra window, then put the original window back in front.
    try testing.expectEqualStrings("/session/popup-session/window", server.requests[5].path);
    try testing.expect(std.mem.indexOf(u8, server.requests[5].body, "\"handle\":\"popup-handle\"") != null);
    try testing.expectEqualStrings("/session/popup-session/window/close", server.requests[6].path);
    try testing.expectEqualStrings("/session/popup-session/window", server.requests[7].path);
    try testing.expect(std.mem.indexOf(u8, server.requests[7].body, "\"handle\":\"main-handle\"") != null);
}

test "webdriver integration keeps a successful action when window cleanup fails" {
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"nowindow-session\",\"capabilities\":{}}}" },
        .{ .method = "POST", .path = "/session/nowindow-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/nowindow-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "GET", .path = "/session/nowindow-session/window/handles", .status = 500, .body = "{\"value\":{\"error\":\"unknown error\",\"message\":\"unsupported command\"}}" },
        .{ .method = "DELETE", .path = "/session/nowindow-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base = try server.url(allocator);
    defer allocator.free(base);

    var bt = webdriverTool(base, &.{"example.com"});
    defer bt.shutdown();

    const opened = try execute(&bt, "{\"action\":\"open\",\"url\":\"https://example.com/page\"}");
    defer allocator.free(opened.output);
    try testing.expect(opened.success);
    try testing.expect(std.mem.indexOf(u8, opened.output, "Closed") == null);
    try testing.expect(std.mem.indexOf(u8, opened.output, "https://example.com/page") != null);

    bt.shutdown();
    server.stopAndJoin();
    try testing.expectEqual(routes.len, server.request_count);
}

test "webdriver integration rebuilds the session after Firefox dies" {
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"dead-session\",\"capabilities\":{}}}" },
        .{ .method = "POST", .path = "/session/dead-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/dead-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "GET", .path = "/session/dead-session/window/handles", .body = "{\"value\":[\"main\"]}" },
        .{ .method = "GET", .path = "/session/dead-session/url", .status = 404, .body = "{\"value\":{\"error\":\"invalid session id\",\"message\":\"session deleted\"}}" },
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"live-session\",\"capabilities\":{}}}" },
        .{ .method = "POST", .path = "/session/live-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/live-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "GET", .path = "/session/live-session/window/handles", .body = "{\"value\":[\"main\"]}" },
        .{ .method = "DELETE", .path = "/session/live-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base = try server.url(allocator);
    defer allocator.free(base);

    var bt = webdriverTool(base, &.{"example.com"});
    defer bt.shutdown();

    const opened = try execute(&bt, "{\"action\":\"open\",\"url\":\"https://example.com/page\"}");
    defer allocator.free(opened.output);
    try testing.expect(opened.success);

    const failed = try execute(&bt, "{\"action\":\"snapshot\"}");
    defer allocator.free(failed.error_msg.?);
    try testing.expect(!failed.success);
    try testing.expect(std.mem.indexOf(u8, failed.error_msg.?, "session deleted") != null);
    // The stale session was dropped; the next call must start a new one.
    try testing.expect(bt.manager != null);
    try testing.expect(bt.manager.?.running == null);

    const recovered = try execute(&bt, "{\"action\":\"open\",\"url\":\"https://example.com/page\"}");
    defer allocator.free(recovered.output);
    try testing.expect(recovered.success);

    bt.shutdown();
    server.stopAndJoin();
    try testing.expectEqual(routes.len, server.request_count);
    try testing.expectEqualStrings("/session", server.requests[5].path);
    try testing.expectEqualStrings("DELETE", server.requests[9].method);
    try testing.expectEqualStrings("/session/live-session", server.requests[9].path);
}

test "webdriver integration blocks a redirect to a metadata address and closes the page" {
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"redirect-session\",\"capabilities\":{}}}" },
        .{ .method = "POST", .path = "/session/redirect-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/redirect-session/url", .body = "{\"value\":\"https://169.254.169.254/latest/meta-data/\"}" },
        .{ .method = "POST", .path = "/session/redirect-session/window/close", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base = try server.url(allocator);
    defer allocator.free(base);

    var bt = webdriverTool(base, &.{});
    defer bt.shutdown();

    // A public IP literal skips DNS for the initial URL; the driver then
    // "redirects" to the link-local metadata address.
    const result = try execute(&bt, "{\"action\":\"open\",\"url\":\"https://8.8.8.8/landing\"}");
    defer allocator.free(result.error_msg.?);
    try testing.expect(!result.success);
    try testing.expectEqualStrings(
        "Browser open failed: Blocked local/private/metadata address",
        result.error_msg.?,
    );
    try testing.expect(bt.manager != null);
    try testing.expect(bt.manager.?.running == null);

    server.stopAndJoin();
    try testing.expectEqual(routes.len, server.request_count);
    try testing.expectEqualStrings("POST", server.requests[3].method);
    try testing.expectEqualStrings("/session/redirect-session/window/close", server.requests[3].path);
}

// Regression: the snapshot only checked the URL before running its script, so
// a page that navigated to a metadata address afterwards still returned its
// content (F1 in the phase-2 security review).
test "webdriver integration blocks a page that navigates away after the snapshot check" {
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"race-session\",\"capabilities\":{}}}" },
        .{ .method = "POST", .path = "/session/race-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/race-session/url", .body = "{\"value\":\"https://8.8.8.8/page\"}" },
        .{ .method = "GET", .path = "/session/race-session/window/handles", .body = "{\"value\":[\"main\"]}" },
        .{ .method = "GET", .path = "/session/race-session/url", .body = "{\"value\":\"https://8.8.8.8/page\"}" },
        .{ .method = "POST", .path = "/session/race-session/execute/sync", .body = snapshot_body },
        .{ .method = "GET", .path = "/session/race-session/url", .body = "{\"value\":\"https://169.254.169.254/latest/meta-data/\"}" },
        .{ .method = "POST", .path = "/session/race-session/window/close", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base = try server.url(allocator);
    defer allocator.free(base);

    var bt = webdriverTool(base, &.{});
    defer bt.shutdown();

    // Public IP literals keep the URL checks offline; the driver reports the
    // metadata address only on the post-script recheck.
    const opened = try execute(&bt, "{\"action\":\"open\",\"url\":\"https://8.8.8.8/landing\"}");
    defer allocator.free(opened.output);
    try testing.expect(opened.success);

    const result = try execute(&bt, "{\"action\":\"snapshot\"}");
    defer allocator.free(result.error_msg.?);
    try testing.expect(!result.success);
    try testing.expectEqualStrings(
        "Browser snapshot failed: Blocked local/private/metadata address",
        result.error_msg.?,
    );
    try testing.expect(bt.manager.?.running == null);

    server.stopAndJoin();
    try testing.expectEqual(routes.len, server.request_count);
    try testing.expectEqualStrings("GET", server.requests[6].method);
    try testing.expectEqualStrings("/session/race-session/url", server.requests[6].path);
    try testing.expectEqualStrings("/session/race-session/window/close", server.requests[7].path);
}

test "webdriver integration reports a missing geckodriver without failing the host" {
    var bt = browser_mod.BrowserTool{
        .config = .{
            .enabled = true,
            .backend = "webdriver",
            .webdriver_geckodriver_path = "junclaw-test-missing-geckodriver",
        },
    };
    defer bt.shutdown();

    const result = try execute(&bt, "{\"action\":\"open\",\"url\":\"https://example.com/\"}");
    defer allocator.free(result.error_msg.?);
    try testing.expect(!result.success);
    try testing.expect(std.mem.indexOf(u8, result.error_msg.?, "failed to start geckodriver") != null);
    try testing.expect(std.mem.indexOf(u8, result.error_msg.?, "junclaw-test-missing-geckodriver") != null);
    try testing.expect(bt.manager != null);
    try testing.expect(bt.manager.?.running == null);

    // A tool result instead of a crash: the same instance can be retried.
    const retried = try execute(&bt, "{\"action\":\"open\",\"url\":\"https://example.com/\"}");
    defer allocator.free(retried.error_msg.?);
    try testing.expect(!retried.success);
    try testing.expect(std.mem.indexOf(u8, retried.error_msg.?, "failed to start geckodriver") != null);
    try testing.expect(bt.manager.?.running == null);
}

var idle_test_clock_ms = std.atomic.Value(i64).init(0);

fn idleTestClock() i64 {
    return idle_test_clock_ms.load(.acquire);
}

test "webdriver integration idle timeout closes and restarts the browser" {
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"idle-1\",\"capabilities\":{}}}" },
        .{ .method = "DELETE", .path = "/session/idle-1", .body = "{\"value\":null}" },
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"idle-2\",\"capabilities\":{}}}" },
        .{ .method = "DELETE", .path = "/session/idle-2", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base = try server.url(allocator);
    defer allocator.free(base);

    idle_test_clock_ms.store(1_000, .release);
    var manager = lifecycle.WebDriverManager.init(allocator, .{
        .driver_url = base,
        .idle_timeout_ms = 500,
        .clock = &idleTestClock,
    });
    defer manager.deinit();

    {
        _ = try manager.acquire();
        manager.release();
    }
    try testing.expect(manager.running != null);

    // Advance the injected clock past the bound; the sweep must issue the
    // session DELETE instead of waiting on wall time.
    idle_test_clock_ms.store(2_000, .release);
    manager.reapIdleOnce();
    try testing.expect(manager.running == null);

    // The next call lazily starts a new browser session.
    idle_test_clock_ms.store(3_000, .release);
    {
        _ = try manager.acquire();
        manager.release();
    }
    try testing.expect(manager.running != null);
    manager.shutdown();

    server.stopAndJoin();
    try testing.expectEqual(routes.len, server.request_count);
    try testing.expectEqualStrings("DELETE", server.requests[1].method);
    try testing.expectEqualStrings("/session", server.requests[2].path);
    try testing.expectEqualStrings("DELETE", server.requests[3].method);
}

/// Stand-in for the geckodriver/Firefox process: alive until the manager's
/// group TERM/KILL + wait path reaps it.
fn spawnFakeBrowserChild() !compat.process.Child {
    var child = compat.process.Child.init(&.{ "sleep", "300" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;
    try child.spawn();
    return child;
}

/// A reaped pid no longer accepts a signal; a zombie still does.
fn expectProcessReaped(pid: std.posix.pid_t) !void {
    switch (builtin.os.tag) {
        .windows, .wasi => return,
        else => {},
    }
    std.posix.kill(pid, std.posix.SIG.TERM) catch |err| switch (err) {
        error.ProcessNotFound => return,
        else => return err,
    };
    return error.ProcessStillRunning;
}

test "webdriver integration close reaps the browser child process" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"child-session\",\"capabilities\":{}}}" },
        .{ .method = "POST", .path = "/session/child-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/child-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "GET", .path = "/session/child-session/window/handles", .body = "{\"value\":[\"main\"]}" },
        .{ .method = "DELETE", .path = "/session/child-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base = try server.url(allocator);
    defer allocator.free(base);

    var bt = webdriverTool(base, &.{"example.com"});
    defer bt.shutdown();

    const opened = try execute(&bt, "{\"action\":\"open\",\"url\":\"https://example.com/page\"}");
    defer allocator.free(opened.output);
    try testing.expect(opened.success);

    const child = try spawnFakeBrowserChild();
    const pid = child.id;
    try testing.expect(bt.manager != null);
    try testing.expect(bt.manager.?.running != null);
    bt.manager.?.running.?.child = child;

    const closed = try execute(&bt, "{\"action\":\"close\"}");
    try testing.expect(closed.success);
    try testing.expect(bt.manager == null);
    try expectProcessReaped(pid);

    server.stopAndJoin();
    try testing.expectEqual(routes.len, server.request_count);
    try testing.expectEqualStrings("DELETE", server.requests[4].method);
}

test "webdriver integration reaps the browser child after a failed action" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fail-session\",\"capabilities\":{}}}" },
        .{ .method = "POST", .path = "/session/fail-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/fail-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "GET", .path = "/session/fail-session/window/handles", .body = "{\"value\":[\"main\"]}" },
        .{ .method = "GET", .path = "/session/fail-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "POST", .path = "/session/fail-session/element", .status = 500, .body = "{\"value\":{\"error\":\"unknown error\",\"message\":\"driver crashed\"}}" },
        .{ .method = "DELETE", .path = "/session/fail-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base = try server.url(allocator);
    defer allocator.free(base);

    var bt = webdriverTool(base, &.{"example.com"});
    defer bt.shutdown();

    const opened = try execute(&bt, "{\"action\":\"open\",\"url\":\"https://example.com/page\"}");
    defer allocator.free(opened.output);
    try testing.expect(opened.success);

    const child = try spawnFakeBrowserChild();
    const pid = child.id;
    bt.manager.?.running.?.child = child;

    // A plain command failure (find-element 500) keeps the session alive, so
    // the later shutdown must DELETE the session and reap the child.
    const failed = try execute(&bt, "{\"action\":\"click\",\"index\":0}");
    defer allocator.free(failed.error_msg.?);
    try testing.expect(!failed.success);
    try testing.expect(std.mem.indexOf(u8, failed.error_msg.?, "driver crashed") != null);
    try testing.expect(bt.manager.?.running != null);

    bt.shutdown();
    try testing.expect(bt.manager == null);
    try expectProcessReaped(pid);

    server.stopAndJoin();
    try testing.expectEqual(routes.len, server.request_count);
    try testing.expectEqualStrings("DELETE", server.requests[6].method);
}
