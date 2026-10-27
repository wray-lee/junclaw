const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const net_security = @import("../root.zig").net_security;
const http_util = @import("../http_util.zig");
const BrowserConfig = @import("../config_types.zig").BrowserConfig;
const WebDriverManager = @import("webdriver_lifecycle.zig").WebDriverManager;
const webdriver_security = @import("webdriver_security.zig");
const browser_webdriver = @import("browser_webdriver.zig");

/// Maximum response body size for the "read" action (8 KB).
const MAX_READ_BYTES: usize = 8192;
/// Maximum raw fetch size passed to curl (64 KB, then truncated to MAX_READ_BYTES).
const MAX_FETCH_BYTES: usize = 65536;

/// Browser tool. With `backend = "webdriver"` every action is served by the
/// process-wide, lazily started geckodriver/Firefox manager shared with every
/// other BrowserTool instance; the default `agent_browser` backend keeps the
/// system-browser `open` and curl `read` behavior.
pub const BrowserTool = struct {
    pub const tool_name = "browser";
    pub const tool_description = "Browse web pages. Actions: open, read, snapshot, click, type, scroll, screenshot, close. Snapshot returns page text plus numbered interactive elements for click/type. The webdriver backend (browser.backend=\"webdriver\") supports all actions; the default agent_browser backend supports open and read. screenshot returns an [IMAGE:path] marker: include it verbatim to send the picture.";
    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["open","read","snapshot","click","type","scroll","screenshot","close"],"description":"Browser action to perform"},"url":{"type":"string","description":"URL to open or read"},"index":{"type":"integer","description":"Element number from the last snapshot (click/type)"},"selector":{"type":"string","description":"CSS selector fallback for click/type"},"text":{"type":"string","description":"Text to type"},"direction":{"type":"string","enum":["up","down","left","right"],"description":"Scroll direction (default down)"},"amount":{"type":"integer","description":"Pixels to scroll (default 500)"}},"required":["action"]}
    ;

    workspace_dir: []const u8 = "",
    config: BrowserConfig = .{},
    /// External WebDriver endpoint instead of spawning geckodriver. Used by
    /// tests; production leaves this null and gets the lifecycled browser.
    webdriver_url: ?[]const u8 = null,
    /// Shared manager used by this tool's last action. Not owned here: every
    /// BrowserTool in the process borrows the same instance.
    manager: ?*WebDriverManager = null,

    const vtable = blk: {
        var base = root.ToolVTable(@This());
        base.deinit = &toolDeinit;
        break :blk base;
    };

    fn toolDeinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *BrowserTool = @ptrCast(@alignCast(ptr));
        self.shutdown();
        allocator.destroy(self);
    }

    pub fn tool(self: *BrowserTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// Close the process-wide browser shared by every BrowserTool. The next
    /// WebDriver action starts a fresh one; safe to call repeatedly.
    pub fn shutdown(self: *BrowserTool) void {
        _ = WebDriverManager.sharedShutdown();
        self.manager = null;
    }

    pub fn execute(self: *BrowserTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing 'action' parameter");

        if (std.mem.eql(u8, self.config.backend, "webdriver")) {
            return self.executeWebDriver(allocator, action, args);
        }
        return executeAgentBrowser(allocator, action, args);
    }

    fn executeWebDriver(self: *BrowserTool, allocator: std.mem.Allocator, action: []const u8, args: JsonObjectMap) !ToolResult {
        if (std.mem.eql(u8, action, "close")) {
            const was_running = WebDriverManager.sharedShutdown();
            self.manager = null;
            return ToolResult.ok(if (was_running) "Browser closed" else "Browser is not running");
        }
        if (!browser_webdriver.isKnownAction(action)) {
            const msg = try std.fmt.allocPrint(allocator, "Unknown browser action '{s}'", .{action});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }
        // Argument errors must not spawn Firefox.
        if (browser_webdriver.validate(action, args)) |message| return ToolResult.fail(message);

        const manager = try WebDriverManager.sharedAcquire(.{
            .driver_url = self.webdriver_url,
            .geckodriver_path = self.config.webdriver_geckodriver_path orelse "geckodriver",
            .headless = self.config.native_headless,
            .idle_timeout_ms = self.config.webdriver_idle_timeout_ms,
            .allowed_domains = self.config.allowed_domains,
        });
        self.manager = manager;
        defer WebDriverManager.sharedRelease();
        const client = manager.acquire() catch |err|
            return webDriverFailure(allocator, action, err, manager.lastErrorMessage());
        defer manager.release();

        var result = browser_webdriver.run(allocator, client, .{
            .workspace_dir = self.workspace_dir,
            .allowed_domains = self.config.allowed_domains,
        }, action, args) catch |err| {
            // Only driver/transport failures carry a fresh message; other
            // errors would otherwise report a message left by an older call.
            const detail = switch (err) {
                error.CommandFailed, error.Transport, error.SessionLost => client.lastErrorMessage(),
                else => "",
            };
            return webDriverFailure(allocator, action, err, detail);
        };
        // F4 depth: tabs/windows a page opened during the action must not
        // survive it. Best effort, so this cannot fail a successful action.
        browser_webdriver.closeExtraWindows(allocator, client, &result);
        return result;
    }

    /// Backend `agent_browser`: system-browser open, curl read, and explicit
    /// errors for the actions only the WebDriver backend can serve.
    fn executeAgentBrowser(allocator: std.mem.Allocator, action: []const u8, args: JsonObjectMap) !ToolResult {
        if (std.mem.eql(u8, action, "open")) {
            return executeOpen(allocator, args);
        } else if (std.mem.eql(u8, action, "read")) {
            return executeRead(allocator, args);
        } else if (std.mem.eql(u8, action, "close")) {
            return ToolResult.ok("Nothing to close: the agent_browser backend does not manage a browser process");
        } else if (std.mem.eql(u8, action, "snapshot")) {
            return ToolResult.fail("Snapshot requires the WebDriver backend (set browser.backend = \"webdriver\")");
        } else if (std.mem.eql(u8, action, "screenshot")) {
            return ToolResult.fail("Use the screenshot tool instead");
        } else if (std.mem.eql(u8, action, "click") or
            std.mem.eql(u8, action, "type") or
            std.mem.eql(u8, action, "scroll"))
        {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Browser action '{s}' requires CDP (Chrome DevTools Protocol) which is not available. Use 'open' to launch in system browser or 'read' to fetch page content.",
                .{action},
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        } else {
            const msg = try std.fmt.allocPrint(allocator, "Unknown browser action '{s}'", .{action});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }
    }

    /// "open" — launch URL in the platform's default browser.
    fn executeOpen(allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const url = root.getString(args, "url") orelse
            return ToolResult.fail("Missing 'url' parameter for open action");

        net_security.validateOutboundUrl(url) catch {
            return ToolResult.fail("Only https:// URLs are supported for security");
        };

        // On Windows cmd.exe /c start interprets shell metacharacters in the URL.
        // On Unix, open/xdg-open receives the URL as a separate argv element (execvp),
        // so metacharacters like & (query params) and % (percent-encoding) are safe.
        if (comptime builtin.os.tag == .windows) {
            for (url) |c| {
                if (c == '&' or c == '|' or c == ';' or c == '"' or c == '\'' or
                    c == '<' or c == '>' or c == '`' or c == '(' or c == ')' or
                    c == '^' or c == '%' or c == '!' or c == '\n' or c == '\r')
                {
                    return ToolResult.fail("URL contains shell metacharacters — open manually for safety");
                }
            }
        }

        // In test mode, skip actual browser spawn to avoid opening windows during CI/tests.
        if (builtin.is_test) {
            const msg = try std.fmt.allocPrint(allocator, "Opened {s} in system browser", .{url});
            return ToolResult{ .success = true, .output = msg };
        }

        const proc = @import("process_util.zig");
        const argv: []const []const u8 = if (comptime builtin.os.tag == .windows)
            &.{ "cmd.exe", "/c", "start", url }
        else
            &.{ comptime if (builtin.os.tag == .macos) "open" else "xdg-open", url };

        const result = proc.run(allocator, argv, .{ .max_output_bytes = 4096 }) catch {
            return ToolResult.fail("Failed to spawn browser open command");
        };
        result.deinit(allocator);

        if (!result.success) {
            if (result.exit_code) |code| {
                const msg = try std.fmt.allocPrint(allocator, "Browser open command exited with code {d}", .{code});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            }
            return ToolResult{ .success = false, .output = "", .error_msg = "Browser open command terminated by signal" };
        }

        const msg = try std.fmt.allocPrint(allocator, "Opened {s} in system browser", .{url});
        return ToolResult{ .success = true, .output = msg };
    }

    /// "read" — fetch URL content via curl and return body text (truncated to 8 KB).
    fn executeRead(allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const url = root.getString(args, "url") orelse
            return ToolResult.fail("Missing 'url' parameter for read action");

        if (url.len > 0 and url[0] == '-') {
            return ToolResult.fail("Invalid URL for read action");
        }
        net_security.validateOutboundUrl(url) catch {
            return ToolResult.fail("Only https:// URLs are supported for security");
        };
        const uri = std.Uri.parse(url) catch
            return ToolResult.fail("Invalid URL format");

        const host = net_security.extractHost(url) orelse
            return ToolResult.fail("Invalid URL: cannot extract host");
        const resolved_port: u16 = uri.port orelse 443;
        const connect_host = net_security.resolveConnectHost(allocator, host, resolved_port) catch |err| switch (err) {
            error.LocalAddressBlocked => return ToolResult.fail("Blocked local/private host"),
            else => return ToolResult.fail("Unable to verify host safety"),
        };
        defer allocator.free(connect_host);

        var resolve_entry: ?[]u8 = null;
        defer if (resolve_entry) |entry| allocator.free(entry);
        if (shouldUseCurlResolve(host)) {
            resolve_entry = try buildCurlResolveEntry(allocator, host, resolved_port, connect_host);
        }

        // Do not auto-follow redirects: every destination needs its own DNS and
        // private-address validation, otherwise a public URL can redirect curl
        // into loopback/RFC1918 space.
        const response = http_util.curlRequestWithStatusAndHeaders(allocator, .{
            .method = .GET,
            .url = url,
            .max_time = "10",
            .max_response_bytes = MAX_FETCH_BYTES,
            .resolve_entry = resolve_entry,
        }) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "curl request failed: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer allocator.free(response.headers);
        defer allocator.free(response.body);

        if (isRedirectStatus(response.status_code)) {
            return ToolResult.fail("Redirect not followed: destination requires a separate security check");
        }
        if (response.body.len == 0) {
            const msg = try allocator.dupe(u8, "Page returned empty response");
            return ToolResult{ .success = true, .output = msg };
        }

        const truncated = response.body.len > MAX_READ_BYTES;
        const body_len = if (truncated) MAX_READ_BYTES else response.body.len;
        const suffix: []const u8 = if (truncated) "\n\n[Content truncated to 8 KB]" else "";
        const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ response.body[0..body_len], suffix });
        return ToolResult{ .success = true, .output = output };
    }
};

fn webDriverFailure(allocator: std.mem.Allocator, action: []const u8, err: anyerror, detail: []const u8) !ToolResult {
    const message = if (detail.len > 0)
        try std.fmt.allocPrint(allocator, "Browser {s} failed: {s}", .{ action, detail })
    else
        try std.fmt.allocPrint(allocator, "Browser {s} failed: {s}", .{ action, webdriver_security.errorMessage(err) });
    return .{ .success = false, .output = "", .error_msg = message };
}

fn isRedirectStatus(status_code: u16) bool {
    return status_code >= 300 and status_code < 400;
}

fn shouldUseCurlResolve(host: []const u8) bool {
    return std.mem.indexOfScalar(u8, net_security.stripHostBrackets(host), ':') == null;
}

fn buildCurlResolveEntry(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    connect_host: []const u8,
) ![]u8 {
    const host_for_resolve = net_security.stripHostBrackets(host);
    const connect_target = if (std.mem.indexOfScalar(u8, connect_host, ':') != null)
        try std.fmt.allocPrint(allocator, "[{s}]", .{connect_host})
    else
        try allocator.dupe(u8, connect_host);
    defer allocator.free(connect_target);

    return std.fmt.allocPrint(allocator, "{s}:{d}:{s}", .{ host_for_resolve, port, connect_target });
}

// ── Tests ───────────────────────────────────────────────────────────

test "browser read returns redirects for separate security validation" {
    // Regression: following a redirect after validating only the first host can
    // reach loopback/private networks through an attacker-controlled 30x.
    try std.testing.expect(isRedirectStatus(301));
    try std.testing.expect(isRedirectStatus(308));
    try std.testing.expect(!isRedirectStatus(200));
    try std.testing.expect(!isRedirectStatus(404));
}

test "browser tool name" {
    var bt = BrowserTool{};
    const t = bt.tool();
    try std.testing.expectEqualStrings("browser", t.name());
}

test "browser open launches system browser" {
    var bt = BrowserTool{};
    const t = bt.tool();
    // In test mode, spawn is skipped; verify the output message is correct.
    const parsed = try root.parseTestArgs("{\"action\": \"open\", \"url\": \"https://example.com\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "stub") == null);
}

test "browser open rejects http" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"open\", \"url\": \"http://example.com\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "https") != null);
}

test "browser screenshot redirects to screenshot tool" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"screenshot\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "screenshot tool") != null);
}

// ── Additional browser tests ────────────────────────────────────

test "browser missing action parameter" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "action") != null);
}

test "browser open missing url" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"open\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "url") != null);
}

test "browser click action requires CDP" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"click\", \"selector\": \"#btn\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "CDP") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "click") != null);
}

test "browser read missing url" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"read\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "url") != null);
}

test "browser read rejects http" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"read\", \"url\": \"http://example.com\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "https") != null);
}

test "browser read accepts uppercase https scheme before SSRF checks" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"read\", \"url\": \"HTTPS://127.0.0.1/\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "local") != null);
}

test "browser open accepts uppercase https scheme" {
    // Regression: executeOpen previously used `std.mem.startsWith(u8, url, "https://")`
    // which rejected `HTTPS://...` even though the scheme is valid per RFC 3986
    // (case-insensitive). The fix routes through `validateOutboundUrl`. This test
    // pairs with the same change in browser_open.zig / http_request.zig / web_fetch.zig
    // and was missing from the original commit.
    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"open\", \"url\": \"HTTPS://example.com\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "example.com") != null);
}

test "webdriver backend rejects bad arguments before starting a browser" {
    var bt = BrowserTool{
        .config = .{ .enabled = true, .backend = "webdriver" },
    };
    var parsed = try root.parseTestArgs("{\"action\":\"click\"}");
    defer parsed.deinit();
    const result = try bt.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings(
        "Missing 'index' (number from snapshot) or 'selector' parameter",
        result.error_msg.?,
    );
    // A malformed call must not spawn geckodriver/Firefox.
    try std.testing.expect(!WebDriverManager.sharedActiveForTest());
}

test "webdriver backend serves snapshot and close stops the manager" {
    const fake = @import("webdriver_fake_server.zig");
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\",\"capabilities\":{}}}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/\"}" },
        .{ .method = "POST", .path = "/session/fake-session/execute/sync", .body = "{\"value\":{\"title\":\"T\",\"url\":\"https://example.com/\",\"text\":\"body text\",\"elements\":[{\"tag\":\"button\",\"label\":\"Go\",\"detail\":\"\"}],\"more\":false}}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/\"}" },
        .{ .method = "GET", .path = "/session/fake-session/window/handles", .body = "{\"value\":[\"main\"]}" },
        .{ .method = "DELETE", .path = "/session/fake-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(std.testing.allocator, &routes);
    defer server.deinit();
    const base = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(base);

    var bt = BrowserTool{
        .config = .{ .enabled = true, .backend = "webdriver", .allowed_domains = &.{"example.com"} },
        .webdriver_url = base,
    };
    defer bt.shutdown();

    var parsed = try root.parseTestArgs("{\"action\":\"snapshot\"}");
    defer parsed.deinit();
    const result = try bt.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "body text") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[0] <button> Go") != null);
    try std.testing.expect(WebDriverManager.sharedActiveForTest());

    var close_args = try root.parseTestArgs("{\"action\":\"close\"}");
    defer close_args.deinit();
    const closed = try bt.execute(std.testing.allocator, close_args.value.object);
    try std.testing.expect(closed.success);
    try std.testing.expectEqualStrings("Browser closed", closed.output);
    try std.testing.expect(!WebDriverManager.sharedActiveForTest());
}

test "webdriver backend shares one browser across tool instances" {
    // Regression: 两个 BrowserTool 实例曾各自起一个 Firefox
    const fake = @import("webdriver_fake_server.zig");
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\",\"capabilities\":{}}}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/\"}" },
        .{ .method = "POST", .path = "/session/fake-session/execute/sync", .body = "{\"value\":{\"title\":\"T\",\"url\":\"https://example.com/\",\"text\":\"body text\",\"elements\":[],\"more\":false}}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/\"}" },
        .{ .method = "GET", .path = "/session/fake-session/window/handles", .body = "{\"value\":[\"main\"]}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/\"}" },
        .{ .method = "POST", .path = "/session/fake-session/execute/sync", .body = "{\"value\":{\"title\":\"T\",\"url\":\"https://example.com/\",\"text\":\"body text\",\"elements\":[],\"more\":false}}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/\"}" },
        .{ .method = "GET", .path = "/session/fake-session/window/handles", .body = "{\"value\":[\"main\"]}" },
        .{ .method = "DELETE", .path = "/session/fake-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(std.testing.allocator, &routes);
    defer server.deinit();
    const base = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(base);

    var first = BrowserTool{
        .config = .{ .enabled = true, .backend = "webdriver", .allowed_domains = &.{"example.com"} },
        .webdriver_url = base,
    };
    defer first.shutdown();
    var second = BrowserTool{
        .config = .{ .enabled = true, .backend = "webdriver", .allowed_domains = &.{"example.com"} },
        .webdriver_url = base,
    };
    defer second.shutdown();

    var snapshot_args = try root.parseTestArgs("{\"action\":\"snapshot\"}");
    defer snapshot_args.deinit();
    const first_result = try first.execute(std.testing.allocator, snapshot_args.value.object);
    defer std.testing.allocator.free(first_result.output);
    try std.testing.expect(first_result.success);
    try std.testing.expect(std.mem.indexOf(u8, first_result.output, "body text") != null);

    // The second tool must reuse the running session instead of POSTing
    // /session again; the fake driver only has one session route.
    const second_result = try second.execute(std.testing.allocator, snapshot_args.value.object);
    defer std.testing.allocator.free(second_result.output);
    try std.testing.expect(second_result.success);
    try std.testing.expect(std.mem.indexOf(u8, second_result.output, "body text") != null);

    var session_posts: usize = 0;
    for (server.requests[0..server.request_count]) |request| {
        if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/session")) {
            session_posts += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), session_posts);

    var close_args = try root.parseTestArgs("{\"action\":\"close\"}");
    defer close_args.deinit();
    const closed = try second.execute(std.testing.allocator, close_args.value.object);
    try std.testing.expect(closed.success);
    try std.testing.expectEqualStrings("Browser closed", closed.output);
    try std.testing.expect(!WebDriverManager.sharedActiveForTest());

    server.stopAndJoin();
    try std.testing.expectEqual(routes.len, server.request_count);
}

test "browser read rejects option-like url" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"read\", \"url\": \"--help\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid") != null);
}

test "browser read blocks localhost SSRF" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"read\", \"url\": \"https://127.0.0.1/\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Blocked local/private host", result.error_msg.?);
}

test "browser read blocks loopback decimal alias SSRF" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"read\", \"url\": \"https://2130706433/\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Blocked local/private host", result.error_msg.?);
}

test "browser open returns output with URL" {
    var bt = BrowserTool{};
    const t = bt.tool();
    // In test mode, spawn is skipped; verify the "Opened ..." message format.
    const parsed = try root.parseTestArgs("{\"action\": \"open\", \"url\": \"https://docs.example.com/api\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "docs.example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Opened") != null);
}

test "browser schema has enum values" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "screenshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "open") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "click") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "scroll") != null);
}

test "browser description mentions browse" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const desc = t.description();
    try std.testing.expect(std.mem.indexOf(u8, desc, "Browse") != null or std.mem.indexOf(u8, desc, "browse") != null or std.mem.indexOf(u8, desc, "web") != null);
}

test "browser tool schema has url" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "url") != null);
}

test "browser tool schema has action" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "action") != null);
}

test "browser tool execute with empty json" {
    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "browser open rejects URL with shell metacharacters on Windows" {
    // On Windows, cmd.exe /c start interprets metacharacters — they must be blocked.
    // On Unix, open/xdg-open uses execvp so metacharacters in argv are safe.
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    var bt = BrowserTool{};
    const t = bt.tool();

    // & can chain commands in cmd.exe
    const p1 = try root.parseTestArgs("{\"action\": \"open\", \"url\": \"https://example.com&whoami\"}");
    defer p1.deinit();
    const r1 = try t.execute(std.testing.allocator, p1.value.object);
    try std.testing.expect(!r1.success);
    try std.testing.expect(std.mem.indexOf(u8, r1.error_msg.?, "metacharacter") != null);

    // | can pipe in cmd.exe
    const p2 = try root.parseTestArgs("{\"action\": \"open\", \"url\": \"https://example.com|calc\"}");
    defer p2.deinit();
    const r2 = try t.execute(std.testing.allocator, p2.value.object);
    try std.testing.expect(!r2.success);
}

test "browser open allows URL with query params on Unix" {
    // On Unix, & in query strings is safe (passed as argv to open/xdg-open).
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var bt = BrowserTool{};
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"open\", \"url\": \"https://example.com/search?a=1&b=2\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "example.com") != null);
}
