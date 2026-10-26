//! Minimal W3C WebDriver (HTTP+JSON) client for the Firefox/geckodriver
//! backend. Only the commands the browser tool needs are exposed; arbitrary
//! script execution stays internal (`executeScript` is not a model action).
//!
//! The client owns only its base URL, session id and last error message.
//! Transport goes through `http_util` (curl), so a hung driver is bounded by
//! `command_timeout_s` instead of stalling the agent.
const std = @import("std");
const http_util = @import("../http_util.zig");

const Allocator = std.mem.Allocator;

/// W3C element identifier key in find-element responses.
const ELEMENT_KEY = "element-6066-11e4-a52e-4f735466cecf";
/// Hard per-request bound; Firefox navigation on a slow page still fits.
const command_timeout_s = "60";
/// Deleting a session must not delay agent shutdown on a wedged driver.
const delete_timeout_s = "5";
/// Cap for the retained error message; driver stack traces are not useful.
const max_error_bytes: usize = 512;

pub const SessionOptions = struct {
    headless: bool = true,
    /// One-shot profile created by `webdriver_security.Profile`. Firefox reads
    /// `<profile>/user.js`, so security prefs apply without the host profile.
    profile_path: ?[]const u8 = null,
};

pub const WebDriverClient = struct {
    allocator: Allocator,
    base_url: []u8,
    session_id: ?[]u8 = null,
    last_error: ?[]u8 = null,
    /// Set after a transport failure or a "session is gone" driver error.
    /// The lifecycle manager uses it to rebuild the session on the next call.
    stale: bool = false,

    pub fn init(allocator: Allocator, base_url: []const u8) !WebDriverClient {
        const trimmed = std.mem.trimEnd(u8, base_url, "/");
        if (trimmed.len == 0) return error.InvalidBaseUrl;
        return .{
            .allocator = allocator,
            .base_url = try allocator.dupe(u8, trimmed),
        };
    }

    /// Release client memory. Does not delete the remote session: call
    /// `deleteSession` first so geckodriver shuts Firefox down.
    pub fn deinit(self: *WebDriverClient) void {
        if (self.session_id) |id| self.allocator.free(id);
        if (self.last_error) |msg| self.allocator.free(msg);
        self.allocator.free(self.base_url);
        self.* = undefined;
    }

    pub fn hasSession(self: *const WebDriverClient) bool {
        return self.session_id != null;
    }

    pub fn lastErrorMessage(self: *const WebDriverClient) []const u8 {
        return self.last_error orelse "";
    }

    pub fn newSession(self: *WebDriverClient, options: SessionOptions) !void {
        if (self.session_id != null) return error.SessionAlreadyOpen;
        var args_buf: [3][]const u8 = undefined;
        var arg_count: usize = 0;
        if (options.headless) {
            args_buf[arg_count] = "-headless";
            arg_count += 1;
        }
        if (options.profile_path) |profile| {
            args_buf[arg_count] = "-profile";
            arg_count += 1;
            args_buf[arg_count] = profile;
            arg_count += 1;
        }
        const args: []const []const u8 = args_buf[0..arg_count];
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .capabilities = .{ .alwaysMatch = .{
                .browserName = "firefox",
                .@"moz:firefoxOptions" = .{ .args = args },
            } },
        }, .{});
        defer self.allocator.free(body);

        var parsed = try self.request(.POST, "/session", body);
        defer parsed.deinit();
        const value = try responseValue(parsed.value);
        if (value != .object) return error.Protocol;
        const session_id = value.object.get("sessionId") orelse return error.Protocol;
        if (session_id != .string) return error.Protocol;
        self.session_id = try self.allocator.dupe(u8, session_id.string);
    }

    pub fn deleteSession(self: *WebDriverClient) !void {
        const id = self.session_id orelse return error.NoSession;
        defer {
            self.allocator.free(id);
            self.session_id = null;
        }
        const path = try std.fmt.allocPrint(self.allocator, "/session/{s}", .{id});
        defer self.allocator.free(path);
        var parsed = try self.requestWithTimeout(.DELETE, path, null, delete_timeout_s);
        parsed.deinit();
    }

    pub fn navigate(self: *WebDriverClient, url: []const u8) !void {
        const path = try self.sessionPath("/url");
        defer self.allocator.free(path);
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{ .url = url }, .{});
        defer self.allocator.free(body);
        var parsed = try self.request(.POST, path, body);
        parsed.deinit();
    }

    pub fn getSource(self: *WebDriverClient, allocator: Allocator) ![]u8 {
        return self.getSessionString(allocator, "/source");
    }

    pub fn getTitle(self: *WebDriverClient, allocator: Allocator) ![]u8 {
        return self.getSessionString(allocator, "/title");
    }

    pub fn getCurrentUrl(self: *WebDriverClient, allocator: Allocator) ![]u8 {
        return self.getSessionString(allocator, "/url");
    }

    /// Find one element by CSS selector and return its W3C element id.
    pub fn findElement(self: *WebDriverClient, allocator: Allocator, selector: []const u8) ![]u8 {
        const path = try self.sessionPath("/element");
        defer self.allocator.free(path);
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .using = "css selector",
            .value = selector,
        }, .{});
        defer self.allocator.free(body);

        var parsed = try self.request(.POST, path, body);
        defer parsed.deinit();
        const value = try responseValue(parsed.value);
        return try elementId(allocator, value);
    }

    /// Find all matching elements; caller frees the slice and each id.
    pub fn findElements(self: *WebDriverClient, allocator: Allocator, selector: []const u8) ![][]u8 {
        const path = try self.sessionPath("/elements");
        defer self.allocator.free(path);
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .using = "css selector",
            .value = selector,
        }, .{});
        defer self.allocator.free(body);

        var parsed = try self.request(.POST, path, body);
        defer parsed.deinit();
        const value = try responseValue(parsed.value);
        if (value != .array) return error.Protocol;

        const ids = try allocator.alloc([]u8, value.array.items.len);
        var filled: usize = 0;
        errdefer {
            for (ids[0..filled]) |id| allocator.free(id);
            allocator.free(ids);
        }
        for (value.array.items, 0..) |item, i| {
            ids[i] = try elementId(allocator, item);
            filled = i + 1;
        }
        return ids;
    }

    pub fn click(self: *WebDriverClient, element_id: []const u8) !void {
        const path = try self.elementPath(element_id, "/click");
        defer self.allocator.free(path);
        var parsed = try self.request(.POST, path, "{}");
        parsed.deinit();
    }

    pub fn sendKeys(self: *WebDriverClient, element_id: []const u8, text: []const u8) !void {
        const path = try self.elementPath(element_id, "/value");
        defer self.allocator.free(path);
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{ .text = text }, .{});
        defer self.allocator.free(body);
        var parsed = try self.request(.POST, path, body);
        parsed.deinit();
    }

    /// Internal-only script execution (element/text extraction). Never expose
    /// this as a model action. Returns the driver's `value` field as JSON text.
    pub fn executeScript(
        self: *WebDriverClient,
        allocator: Allocator,
        script: []const u8,
        args: std.json.Value,
    ) ![]u8 {
        const path = try self.sessionPath("/execute/sync");
        defer self.allocator.free(path);
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .script = script,
            .args = args,
        }, .{});
        defer self.allocator.free(body);

        var parsed = try self.request(.POST, path, body);
        defer parsed.deinit();
        const value = try responseValue(parsed.value);
        return std.json.Stringify.valueAlloc(allocator, value, .{});
    }

    pub fn scroll(self: *WebDriverClient, x: i64, y: i64) !void {
        const script = try std.fmt.allocPrint(self.allocator, "window.scrollTo({d}, {d});", .{ x, y });
        defer self.allocator.free(script);
        const no_args = std.json.Value{ .array = std.json.Array.init(self.allocator) };
        const result = try self.executeScript(self.allocator, script, no_args);
        self.allocator.free(result);
    }

    /// W3C screenshot: returns the base64 payload (caller decodes/forwards it).
    pub fn screenshot(self: *WebDriverClient, allocator: Allocator) ![]u8 {
        return self.getSessionString(allocator, "/screenshot");
    }

    pub fn closeWindow(self: *WebDriverClient) !void {
        const path = try self.sessionPath("/window/close");
        defer self.allocator.free(path);
        var parsed = try self.request(.POST, path, "{}");
        parsed.deinit();
    }

    /// GET /status; true when the driver reports it can accept new sessions.
    pub fn statusReady(self: *WebDriverClient) bool {
        var parsed = self.request(.GET, "/status", null) catch return false;
        defer parsed.deinit();
        const value = responseValue(parsed.value) catch return false;
        if (value != .object) return false;
        const ready = value.object.get("ready") orelse return false;
        return ready == .bool and ready.bool;
    }

    fn getSessionString(self: *WebDriverClient, allocator: Allocator, suffix: []const u8) ![]u8 {
        const path = try self.sessionPath(suffix);
        defer self.allocator.free(path);
        var parsed = try self.request(.GET, path, null);
        defer parsed.deinit();
        const value = try responseValue(parsed.value);
        if (value != .string) return error.Protocol;
        return allocator.dupe(u8, value.string);
    }

    fn sessionPath(self: *WebDriverClient, suffix: []const u8) ![]u8 {
        const id = self.session_id orelse return error.NoSession;
        return std.fmt.allocPrint(self.allocator, "/session/{s}{s}", .{ id, suffix });
    }

    fn elementPath(self: *WebDriverClient, element_id: []const u8, suffix: []const u8) ![]u8 {
        const id = self.session_id orelse return error.NoSession;
        return std.fmt.allocPrint(self.allocator, "/session/{s}/element/{s}{s}", .{ id, element_id, suffix });
    }

    fn request(
        self: *WebDriverClient,
        method: std.http.Method,
        path: []const u8,
        body: ?[]const u8,
    ) !std.json.Parsed(std.json.Value) {
        return self.requestWithTimeout(method, path, body, command_timeout_s);
    }

    fn requestWithTimeout(
        self: *WebDriverClient,
        method: std.http.Method,
        path: []const u8,
        body: ?[]const u8,
        timeout_s: []const u8,
    ) !std.json.Parsed(std.json.Value) {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
        defer self.allocator.free(url);

        const response = http_util.httpRequestWithStatusTimeout(
            self.allocator,
            method,
            url,
            body,
            &.{},
            if (body != null) "application/json" else null,
            null,
            timeout_s,
        ) catch |err| {
            self.setLastError(std.fmt.allocPrint(self.allocator, "webdriver transport error: {s}", .{@errorName(err)}) catch null);
            self.stale = true;
            return error.Transport;
        };
        defer self.allocator.free(response.body);

        if (response.status_code < 200 or response.status_code >= 300) {
            self.setErrorFromBody(response.body);
            if (isSessionGone(response.body)) {
                self.stale = true;
                return error.SessionLost;
            }
            return error.CommandFailed;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{
            .allocate = .alloc_always,
        }) catch return error.Protocol;
        self.stale = false;
        return parsed;
    }

    fn setErrorFromBody(self: *WebDriverClient, body: []const u8) void {
        // Copy out of the parsed arena: deinit runs before allocPrint below.
        var owned_message: ?[]u8 = null;
        if (std.json.parseFromSlice(std.json.Value, self.allocator, body, .{})) |parsed_const| {
            var parsed = parsed_const;
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("value")) |value| {
                    const message: ?std.json.Value = if (value == .object)
                        value.object.get("message")
                    else if (value == .string)
                        value
                    else
                        null;
                    if (message) |msg| {
                        if (msg == .string) {
                            owned_message = self.allocator.dupe(u8, msg.string) catch null;
                        }
                    }
                }
            }
        } else |_| {}

        const message = owned_message orelse body;
        const capped = message[0..@min(message.len, max_error_bytes)];
        self.setLastError(std.fmt.allocPrint(self.allocator, "webdriver: {s}", .{capped}) catch null);
        if (owned_message) |value| self.allocator.free(value);
    }

    fn setLastError(self: *WebDriverClient, owned: ?[]u8) void {
        if (self.last_error) |old| self.allocator.free(old);
        self.last_error = owned;
    }
};

fn responseValue(root: std.json.Value) !std.json.Value {
    if (root != .object) return error.Protocol;
    return root.object.get("value") orelse error.Protocol;
}

fn elementId(allocator: Allocator, value: std.json.Value) ![]u8 {
    if (value != .object) return error.Protocol;
    const id = value.object.get(ELEMENT_KEY) orelse return error.Protocol;
    if (id != .string) return error.Protocol;
    return allocator.dupe(u8, id.string);
}

fn isSessionGone(body: []const u8) bool {
    // geckodriver reports a dead Firefox this way; "no such window" covers a
    // closed window. Plain "no such element" is a normal command failure.
    return std.mem.indexOf(u8, body, "invalid session id") != null or
        std.mem.indexOf(u8, body, "no such window") != null or
        std.mem.indexOf(u8, body, "Failed to decode response from marionette") != null;
}

// ── Tests (fake WebDriver over loopback HTTP) ───────────────────────

test "client establishes and deletes a session" {
    const fake = @import("webdriver_fake_server.zig");
    const allocator = std.testing.allocator;

    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\"}}" },
        .{ .method = "DELETE", .path = "/session/fake-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();

    const base_url = try server.url(allocator);
    defer allocator.free(base_url);

    var client = try WebDriverClient.init(allocator, base_url);
    defer client.deinit();

    try client.newSession(.{ .headless = true });
    try std.testing.expect(client.hasSession());
    try client.deleteSession();
    try std.testing.expect(!client.hasSession());

    server.stopAndJoin();
    try std.testing.expectEqual(@as(usize, 2), server.request_count);
    try std.testing.expectEqualStrings("POST", server.requests[0].method);
    try std.testing.expectEqualStrings("/session", server.requests[0].path);
    try std.testing.expect(std.mem.indexOf(u8, server.requests[0].body, "\"browserName\":\"firefox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, server.requests[0].body, "\"-headless\"") != null);
    try std.testing.expectEqualStrings("DELETE", server.requests[1].method);
}

test "client passes the one-shot profile to Firefox" {
    const fake = @import("webdriver_fake_server.zig");
    const allocator = std.testing.allocator;

    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\"}}" },
        .{ .method = "DELETE", .path = "/session/fake-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base_url = try server.url(allocator);
    defer allocator.free(base_url);

    var client = try WebDriverClient.init(allocator, base_url);
    defer client.deinit();

    try client.newSession(.{ .headless = true, .profile_path = "/tmp/wd-profile-test" });
    try client.deleteSession();

    server.stopAndJoin();
    try std.testing.expect(std.mem.indexOf(
        u8,
        server.requests[0].body,
        "\"-profile\",\"/tmp/wd-profile-test\"",
    ) != null);
}

test "client encodes commands and decodes responses" {
    const fake = @import("webdriver_fake_server.zig");
    const allocator = std.testing.allocator;

    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\"}}" },
        .{ .method = "POST", .path = "/session/fake-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/fake-session/source", .body = "{\"value\":\"<html>page</html>\"}" },
        .{ .method = "GET", .path = "/session/fake-session/title", .body = "{\"value\":\"Example\"}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/\"}" },
        .{ .method = "POST", .path = "/session/fake-session/element", .body = "{\"value\":{\"element-6066-11e4-a52e-4f735466cecf\":\"el-1\"}}" },
        .{ .method = "POST", .path = "/session/fake-session/elements", .body = "{\"value\":[{\"element-6066-11e4-a52e-4f735466cecf\":\"el-1\"},{\"element-6066-11e4-a52e-4f735466cecf\":\"el-2\"}]}" },
        .{ .method = "POST", .path = "/session/fake-session/element/el-1/click", .body = "{\"value\":null}" },
        .{ .method = "POST", .path = "/session/fake-session/element/el-1/value", .body = "{\"value\":null}" },
        .{ .method = "POST", .path = "/session/fake-session/execute/sync", .body = "{\"value\":{\"text\":\"hello\"}}" },
        .{ .method = "POST", .path = "/session/fake-session/execute/sync", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/fake-session/screenshot", .body = "{\"value\":\"iVBORw0KGgo=\"}" },
        .{ .method = "POST", .path = "/session/fake-session/window/close", .body = "{\"value\":[]}" },
        .{ .method = "DELETE", .path = "/session/fake-session", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();

    const base_url = try server.url(allocator);
    defer allocator.free(base_url);
    var client = try WebDriverClient.init(allocator, base_url);
    defer client.deinit();

    try client.newSession(.{ .headless = false });
    try client.navigate("https://example.com/");

    const source = try client.getSource(allocator);
    defer allocator.free(source);
    try std.testing.expectEqualStrings("<html>page</html>", source);

    const title = try client.getTitle(allocator);
    defer allocator.free(title);
    try std.testing.expectEqualStrings("Example", title);

    const url = try client.getCurrentUrl(allocator);
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://example.com/", url);

    const element = try client.findElement(allocator, "#go");
    defer allocator.free(element);
    try std.testing.expectEqualStrings("el-1", element);

    const elements = try client.findElements(allocator, "a");
    defer {
        for (elements) |id| allocator.free(id);
        allocator.free(elements);
    }
    try std.testing.expectEqual(@as(usize, 2), elements.len);
    try std.testing.expectEqualStrings("el-2", elements[1]);

    try client.click("el-1");
    try client.sendKeys("el-1", "hello");
    const no_args = std.json.Value{ .array = std.json.Array.init(allocator) };
    const script_result = try client.executeScript(allocator, "return document.body.innerText", no_args);
    defer allocator.free(script_result);
    try std.testing.expectEqualStrings("{\"text\":\"hello\"}", script_result);

    try client.scroll(0, 1200);
    const shot = try client.screenshot(allocator);
    defer allocator.free(shot);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", shot);
    try client.closeWindow();
    try client.deleteSession();

    server.stopAndJoin();
    try std.testing.expectEqual(routes.len, server.request_count);
    try std.testing.expectEqualStrings("/session/fake-session/url", server.requests[1].path);
    try std.testing.expect(std.mem.indexOf(u8, server.requests[1].body, "\"url\":\"https://example.com/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, server.requests[5].body, "\"using\":\"css selector\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, server.requests[5].body, "\"value\":\"#go\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, server.requests[8].body, "\"text\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, server.requests[10].body, "window.scrollTo(0, 1200)") != null);
    try std.testing.expect(std.mem.indexOf(u8, server.requests[0].body, "\"-headless\"") == null);
}

test "client reports a lost session distinctly" {
    const fake = @import("webdriver_fake_server.zig");
    const allocator = std.testing.allocator;

    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\"}}" },
        .{
            .method = "GET",
            .path = "/session/fake-session/title",
            .status = 404,
            .body = "{\"value\":{\"error\":\"invalid session id\",\"message\":\"session deleted\",\"stacktrace\":\"\"}}",
        },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();

    const base_url = try server.url(allocator);
    defer allocator.free(base_url);
    var client = try WebDriverClient.init(allocator, base_url);
    defer client.deinit();

    try client.newSession(.{});
    try std.testing.expectError(error.SessionLost, client.getTitle(allocator));
    try std.testing.expect(client.stale);
    try std.testing.expect(std.mem.indexOf(u8, client.lastErrorMessage(), "session deleted") != null);
    server.stopAndJoin();
}

test "client reads driver readiness" {
    const fake = @import("webdriver_fake_server.zig");
    const allocator = std.testing.allocator;

    const routes = [_]fake.Route{
        .{ .method = "GET", .path = "/status", .body = "{\"value\":{\"ready\":true,\"message\":\"\"}}" },
        .{ .method = "GET", .path = "/status", .body = "{\"value\":{\"ready\":false,\"message\":\"\"}}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base_url = try server.url(allocator);
    defer allocator.free(base_url);

    var client = try WebDriverClient.init(allocator, base_url);
    defer client.deinit();
    try std.testing.expect(client.statusReady());
    try std.testing.expect(!client.statusReady());
    server.stopAndJoin();
    try std.testing.expectEqual(routes.len, server.request_count);
}

test "session-gone detection ignores ordinary command failures" {
    try std.testing.expect(isSessionGone("{\"value\":{\"error\":\"invalid session id\"}}"));
    try std.testing.expect(isSessionGone("{\"value\":{\"error\":\"no such window\"}}"));
    try std.testing.expect(!isSessionGone("{\"value\":{\"error\":\"no such element\"}}"));
}
