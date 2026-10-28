//! WebDriver action layer for the browser tool (backend = "webdriver").
//!
//! Split from `browser.zig` so the agent-browser path stays untouched. All
//! script execution is internal: `snapshot` assigns `data-junclaw-ref="N"`
//! attributes to visible interactive elements and `click`/`type` look those
//! numbers up with a plain W3C find-element, so numbering stays stable until
//! the next snapshot and no arbitrary JS is exposed as a model action.
//!
//! Output limits follow the existing `read` convention: 8 KB cap plus the
//! `[Content truncated to 8 KB]` marker. Screenshots go through the existing
//! `[IMAGE:<path>]` attachment marker read by outbound channels; the base64
//! payload never reaches the model.
const std = @import("std");
const compat = @import("compat");
const root = @import("root.zig");
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const WebDriverClient = @import("webdriver_client.zig").WebDriverClient;
const security = @import("webdriver_security.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.browser);

/// Same cap as the curl `read` path in browser.zig.
pub const MAX_OUTPUT_BYTES: usize = 8192;
/// Page text gets half the budget so the numbered element list stays visible.
const MAX_TEXT_BYTES: usize = MAX_OUTPUT_BYTES / 2;
/// Keep in sync with `const limit = 100;` in `snapshot_script`.
const MAX_ELEMENTS: usize = 100;
const truncation_marker = "\n\n[Content truncated to 8 KB]";

pub const Context = struct {
    workspace_dir: []const u8 = "",
    /// BrowserConfig.allowed_domains; empty means "any globally routable host".
    allowed_domains: []const []const u8 = &.{},
};

pub const known_actions = [_][]const u8{
    "open", "read", "snapshot", "click", "type", "scroll", "screenshot", "close",
};

pub fn isKnownAction(action: []const u8) bool {
    for (known_actions) |name| {
        if (std.mem.eql(u8, action, name)) return true;
    }
    return false;
}

/// Argument-only check, run before the browser is started so a malformed call
/// never spawns Firefox. Returns a static message for `ToolResult.fail`.
pub fn validate(action: []const u8, args: JsonObjectMap) ?[]const u8 {
    if (std.mem.eql(u8, action, "open") or std.mem.eql(u8, action, "read")) {
        if (root.getString(args, "url") == null) return "Missing 'url' parameter for the open/read action";
        return null;
    }
    if (std.mem.eql(u8, action, "click") or std.mem.eql(u8, action, "type")) {
        const has_index = args.get("index") != null;
        const has_selector = root.getString(args, "selector") != null;
        if (!has_index and !has_selector) {
            return "Missing 'index' (number from snapshot) or 'selector' parameter";
        }
        if (has_index and parseIndex(args) == null) {
            return "Invalid 'index' parameter: expected a non-negative integer";
        }
        if (std.mem.eql(u8, action, "type") and root.getString(args, "text") == null) {
            return "Missing 'text' parameter for the type action";
        }
        return null;
    }
    if (std.mem.eql(u8, action, "scroll")) {
        if (root.getString(args, "direction")) |direction| {
            if (!isDirection(direction)) return "Invalid 'direction': expected up, down, left or right";
        }
        if (args.get("amount")) |_| {
            if (parseAmount(args) == null) return "Invalid 'amount': expected an integer between 1 and 100000";
        }
    }
    return null;
}

pub fn run(
    allocator: Allocator,
    client: *WebDriverClient,
    ctx: Context,
    action: []const u8,
    args: JsonObjectMap,
) !ToolResult {
    if (std.mem.eql(u8, action, "open")) return executeOpen(allocator, client, ctx, args);
    if (std.mem.eql(u8, action, "read")) return executeRead(allocator, client, ctx, args);
    if (std.mem.eql(u8, action, "snapshot")) return executeSnapshot(allocator, client, ctx);
    if (std.mem.eql(u8, action, "click")) return executeClick(allocator, client, ctx, args);
    if (std.mem.eql(u8, action, "type")) return executeType(allocator, client, ctx, args);
    if (std.mem.eql(u8, action, "scroll")) return executeScroll(allocator, client, ctx, args);
    if (std.mem.eql(u8, action, "screenshot")) return executeScreenshot(allocator, client, ctx);
    return error.UnknownBrowserAction;
}

/// Defense in depth for F4: an action can open extra tabs/windows
/// (`target=_blank`, `window.open`, form targets) that the URL checks never
/// see. After a successful action keep the current window, close the rest and
/// append what was closed to the result. Best effort: a driver that cannot
/// enumerate or close windows is logged and never fails the action.
pub fn closeExtraWindows(allocator: Allocator, client: *WebDriverClient, result: *ToolResult) void {
    if (!result.success) return;
    const record = convergeWindows(allocator, client) catch |err| {
        log.debug("browser window cleanup skipped: {s}", .{@errorName(err)});
        return;
    };
    const line = record orelse return;
    defer allocator.free(line);
    // Success outputs from this module are heap-allocated; failures are not
    // converged, so an empty literal is never freed here.
    const output = std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ result.output, line }) catch |err| {
        log.debug("browser window cleanup record dropped: {s}", .{@errorName(err)});
        return;
    };
    if (result.output.len > 0) allocator.free(result.output);
    result.output = output;
}

/// Close every window except the current one and return a one-line record of
/// the closed handles (null when there was nothing extra).
fn convergeWindows(allocator: Allocator, client: *WebDriverClient) anyerror!?[]u8 {
    const handles = try client.getWindowHandles(allocator);
    defer {
        for (handles) |handle| allocator.free(handle);
        allocator.free(handles);
    }
    if (handles.len < 2) return null;
    const current = try client.getWindowHandle(allocator);
    defer allocator.free(current);

    var closed: std.ArrayList(u8) = .empty;
    defer closed.deinit(allocator);
    var closed_count: usize = 0;
    for (handles) |handle| {
        if (std.mem.eql(u8, handle, current)) continue;
        client.switchToWindow(handle) catch continue;
        client.closeWindow() catch continue;
        if (closed_count > 0) try closed.appendSlice(allocator, ", ");
        try closed.appendSlice(allocator, handle);
        closed_count += 1;
    }
    // A failed switch or close can leave another window current.
    client.switchToWindow(current) catch {};
    if (closed_count == 0) return null;
    const line = try std.fmt.allocPrint(allocator, "Closed {d} extra browser window(s): {s}", .{ closed_count, closed.items });
    return line;
}

fn executeOpen(allocator: Allocator, client: *WebDriverClient, ctx: Context, args: JsonObjectMap) !ToolResult {
    const url = root.getString(args, "url").?;
    try security.navigateChecked(allocator, client, url, ctx.allowed_domains);
    const output = try std.fmt.allocPrint(allocator, "Opened {s} in the WebDriver browser", .{url});
    return .{ .success = true, .output = output };
}

fn executeRead(allocator: Allocator, client: *WebDriverClient, ctx: Context, args: JsonObjectMap) !ToolResult {
    const url = root.getString(args, "url").?;
    try security.navigateChecked(allocator, client, url, ctx.allowed_domains);

    const json = try client.executeScript(allocator, read_script, noArgs(allocator));
    defer allocator.free(json);
    // The page can navigate while the script runs; recheck before using the
    // output so private content never leaves the browser.
    try security.checkCurrentUrl(allocator, client, ctx.allowed_domains);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return ToolResult.fail("Browser returned an unreadable page document");
    defer parsed.deinit();
    const page = jsonObject(parsed.value) orelse return ToolResult.fail("Browser returned an unreadable page document");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendHeader(&out, allocator, page);
    const text = jsonString(page, "text") orelse "";
    const text_cap = MAX_OUTPUT_BYTES -| out.items.len -| truncation_marker.len;
    if (try appendTruncated(&out, allocator, text, text_cap)) {
        try out.appendSlice(allocator, truncation_marker);
    }
    return .{ .success = true, .output = try out.toOwnedSlice(allocator) };
}

fn executeSnapshot(allocator: Allocator, client: *WebDriverClient, ctx: Context) !ToolResult {
    // Redirects can happen after `open`; recheck the URL Firefox is on now.
    try security.checkCurrentUrl(allocator, client, ctx.allowed_domains);

    const json = try client.executeScript(allocator, snapshot_script, noArgs(allocator));
    defer allocator.free(json);
    // Same recheck after the script: the DOM it read may be a private page.
    try security.checkCurrentUrl(allocator, client, ctx.allowed_domains);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return ToolResult.fail("Browser returned an unreadable page snapshot");
    defer parsed.deinit();
    const page = jsonObject(parsed.value) orelse return ToolResult.fail("Browser returned an unreadable page snapshot");
    const elements: ?std.json.Array = if (page.get("elements")) |value|
        (if (value == .array) value.array else null)
    else
        null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var truncated = false;
    try appendHeader(&out, allocator, page);

    const text = jsonString(page, "text") orelse "";
    const text_cap = @min(MAX_TEXT_BYTES, MAX_OUTPUT_BYTES -| out.items.len);
    if (try appendTruncated(&out, allocator, text, text_cap)) truncated = true;

    try out.appendSlice(allocator, "\n\nInteractive elements (use the number as 'index' with click/type):\n");
    var shown: usize = 0;
    if (elements) |list| {
        // The DOM ref written by the script equals the array position, so the
        // displayed number is the position, not the number of printed lines.
        for (list.items, 0..) |item, index| {
            if (index >= MAX_ELEMENTS) {
                truncated = true;
                break;
            }
            const element = jsonObject(item) orelse continue;
            const tag = jsonString(element, "tag") orelse "?";
            const label = jsonString(element, "label") orelse "";
            const detail = jsonString(element, "detail") orelse "";
            const line = try std.fmt.allocPrint(allocator, "[{d}] <{s}> {s}{s}{s}\n", .{
                index,
                tag,
                label,
                if (detail.len > 0) " " else "",
                detail,
            });
            defer allocator.free(line);
            if (out.items.len + line.len + truncation_marker.len > MAX_OUTPUT_BYTES) {
                truncated = true;
                break;
            }
            try out.appendSlice(allocator, line);
            shown += 1;
        }
    }
    if (shown == 0) try out.appendSlice(allocator, "(none)\n");
    switch (page.get("more") orelse .null) {
        .bool => |more| truncated = truncated or more,
        else => {},
    }
    if (truncated) try out.appendSlice(allocator, truncation_marker);
    return .{ .success = true, .output = try out.toOwnedSlice(allocator) };
}

fn executeClick(allocator: Allocator, client: *WebDriverClient, ctx: Context, args: JsonObjectMap) !ToolResult {
    try security.checkCurrentUrl(allocator, client, ctx.allowed_domains);
    const target = try resolveTarget(allocator, args);
    defer target.deinit(allocator);

    const element_id = try client.findElement(allocator, target.selector);
    defer allocator.free(element_id);
    try client.click(element_id);
    const output = try std.fmt.allocPrint(allocator, "Clicked {s}", .{target.label});
    return .{ .success = true, .output = output };
}

fn executeType(allocator: Allocator, client: *WebDriverClient, ctx: Context, args: JsonObjectMap) !ToolResult {
    try security.checkCurrentUrl(allocator, client, ctx.allowed_domains);
    const target = try resolveTarget(allocator, args);
    defer target.deinit(allocator);
    const text = root.getString(args, "text").?;

    const element_id = try client.findElement(allocator, target.selector);
    defer allocator.free(element_id);
    try client.sendKeys(element_id, text);
    const output = try std.fmt.allocPrint(allocator, "Typed {d} characters into {s}", .{ text.len, target.label });
    return .{ .success = true, .output = output };
}

fn executeScroll(allocator: Allocator, client: *WebDriverClient, ctx: Context, args: JsonObjectMap) !ToolResult {
    try security.checkCurrentUrl(allocator, client, ctx.allowed_domains);
    const direction = root.getString(args, "direction") orelse "down";
    const amount: i64 = @intCast(parseAmount(args) orelse 500);
    const dx: i64 = if (std.mem.eql(u8, direction, "left")) -amount else if (std.mem.eql(u8, direction, "right")) amount else 0;
    const dy: i64 = if (std.mem.eql(u8, direction, "up")) -amount else if (std.mem.eql(u8, direction, "down")) amount else 0;

    const script = try std.fmt.allocPrint(allocator, "window.scrollBy({d}, {d});", .{ dx, dy });
    defer allocator.free(script);
    const result = try client.executeScript(allocator, script, noArgs(allocator));
    allocator.free(result);
    const output = try std.fmt.allocPrint(allocator, "Scrolled {s} by {d} pixels", .{ direction, amount });
    return .{ .success = true, .output = output };
}

fn executeScreenshot(allocator: Allocator, client: *WebDriverClient, ctx: Context) !ToolResult {
    if (ctx.workspace_dir.len == 0) {
        return ToolResult.fail("Browser screenshot requires a workspace directory");
    }
    try security.checkCurrentUrl(allocator, client, ctx.allowed_domains);

    const encoded = try client.screenshot(allocator);
    defer allocator.free(encoded);
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch
        return ToolResult.fail("WebDriver returned an invalid screenshot payload");
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    decoder.decode(bytes, encoded) catch
        return ToolResult.fail("WebDriver returned an invalid screenshot payload");
    if (bytes.len == 0) return ToolResult.fail("WebDriver returned an empty screenshot");
    // Recheck after capture: do not write private pixels into the workspace.
    try security.checkCurrentUrl(allocator, client, ctx.allowed_domains);

    const name = try std.fmt.allocPrint(allocator, "browser-screenshot-{x}.png", .{compat.crypto.random.int(u32)});
    defer allocator.free(name);
    const path = try compat.fs.path.join(allocator, &.{ ctx.workspace_dir, name });
    defer allocator.free(path);
    compat.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes }) catch
        return ToolResult.fail("Failed to save the browser screenshot in the workspace");

    // Existing media path: channels turn [IMAGE:path] in the assistant reply
    // into an attachment. Never return the base64 payload to the model.
    const output = try std.fmt.allocPrint(allocator, "[IMAGE:{s}]", .{path});
    return .{ .success = true, .output = output };
}

const Target = struct {
    selector: []u8,
    label: []u8,

    fn deinit(self: Target, allocator: Allocator) void {
        allocator.free(self.selector);
        allocator.free(self.label);
    }
};

fn resolveTarget(allocator: Allocator, args: JsonObjectMap) !Target {
    if (parseIndex(args)) |index| {
        const selector = try std.fmt.allocPrint(allocator, "[data-junclaw-ref=\"{d}\"]", .{index});
        errdefer allocator.free(selector);
        return .{
            .selector = selector,
            .label = try std.fmt.allocPrint(allocator, "element {d} from the last snapshot", .{index}),
        };
    }
    const raw = root.getString(args, "selector").?;
    const selector = try allocator.dupe(u8, raw);
    errdefer allocator.free(selector);
    return .{
        .selector = selector,
        .label = try std.fmt.allocPrint(allocator, "selector '{s}'", .{raw}),
    };
}

fn parseIndex(args: JsonObjectMap) ?usize {
    const value = args.get("index") orelse return null;
    return switch (value) {
        .integer => |i| if (i >= 0) std.math.cast(usize, i) else null,
        // Models sometimes send numbers as strings; accept both.
        .string => |s| std.fmt.parseInt(usize, s, 10) catch null,
        else => null,
    };
}

fn parseAmount(args: JsonObjectMap) ?u32 {
    const value = args.get("amount") orelse return null;
    const amount: i64 = switch (value) {
        .integer => |i| i,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch return null,
        else => return null,
    };
    if (amount < 1 or amount > 100_000) return null;
    return @intCast(amount);
}

fn isDirection(direction: []const u8) bool {
    return std.mem.eql(u8, direction, "up") or
        std.mem.eql(u8, direction, "down") or
        std.mem.eql(u8, direction, "left") or
        std.mem.eql(u8, direction, "right");
}

fn noArgs(allocator: Allocator) std.json.Value {
    return .{ .array = std.json.Array.init(allocator) };
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return if (value == .object) value.object else null;
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn appendHeader(out: *std.ArrayList(u8), allocator: Allocator, page: std.json.ObjectMap) !void {
    const title = utf8Cut(jsonString(page, "title") orelse "", 200);
    const url = utf8Cut(jsonString(page, "url") orelse "", 300);
    const heading = try std.fmt.allocPrint(allocator, "Title: {s}\nURL: {s}\n\n", .{ title, url });
    defer allocator.free(heading);
    try out.appendSlice(allocator, heading);
}

/// Longest prefix of `text` no longer than `max` that ends on a UTF-8 boundary.
fn utf8Cut(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var cut = max;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    return text[0..cut];
}

/// Appends at most `max` bytes without splitting a UTF-8 sequence; returns
/// true when the input did not fit. The caller adds the truncation marker.
fn appendTruncated(out: *std.ArrayList(u8), allocator: Allocator, text: []const u8, max: usize) !bool {
    try out.appendSlice(allocator, utf8Cut(text, max));
    return text.len > max;
}

/// Internal only (never a model action). The tag/role selector, visibility
/// filter and 100-element cap bound both the response size and the numbering.
const snapshot_script =
    \\const limit = 100;
    \\const elements = [];
    \\let more = false;
    \\if (document.body) {
    \\  document.querySelectorAll('[data-junclaw-ref]').forEach(function(el) { el.removeAttribute('data-junclaw-ref'); });
    \\  const selector = 'a[href],button,input,select,textarea,summary,[role="button"],[role="link"],[role="checkbox"],[role="radio"],[role="tab"],[onclick],[contenteditable="true"]';
    \\  const nodes = Array.prototype.slice.call(document.querySelectorAll(selector));
    \\  for (const el of nodes) {
    \\    if (elements.length >= limit) { more = true; break; }
    \\    const rect = el.getBoundingClientRect();
    \\    const style = window.getComputedStyle(el);
    \\    if (rect.width <= 0 || rect.height <= 0 || style.visibility === 'hidden' || style.display === 'none') continue;
    \\    if (el.disabled) continue;
    \\    el.setAttribute('data-junclaw-ref', String(elements.length));
    \\    let label = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('title') || el.name || '').replace(/\s+/g, ' ').trim();
    \\    if (label.length > 80) label = label.slice(0, 80);
    \\    const bits = [];
    \\    if (el.id) bits.push('#' + el.id);
    \\    const type = el.getAttribute('type');
    \\    if (type) bits.push('type=' + type);
    \\    if (el.name) bits.push('name=' + el.name);
    \\    const href = el.getAttribute('href');
    \\    if (href) bits.push('href=' + (href.length > 100 ? href.slice(0, 100) : href));
    \\    if (el.checked) bits.push('checked');
    \\    elements.push({ tag: el.tagName.toLowerCase(), label: label, detail: bits.join(' ').replace(/\s+/g, ' ') });
    \\  }
    \\}
    \\return {
    \\  title: document.title || '',
    \\  url: location.href,
    \\  text: document.body ? (document.body.innerText || '').slice(0, 20000) : '',
    \\  elements: elements,
    \\  more: more
    \\};
;

const read_script =
    \\return {
    \\  title: document.title || '',
    \\  url: location.href,
    \\  text: (document.body ? (document.body.innerText || '') : (document.documentElement ? (document.documentElement.innerText || '') : '')).slice(0, 20000)
    \\};
;

// ── tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const FakeServer = @import("webdriver_fake_server.zig").Server;
const Route = @import("webdriver_fake_server.zig").Route;
const ELEMENT_KEY = "element-6066-11e4-a52e-4f735466cecf";

fn testArgs(parsed: *std.json.Parsed(std.json.Value)) JsonObjectMap {
    return parsed.value.object;
}

fn urlRoute(body: []const u8) Route {
    return .{ .method = "GET", .path = "/session/fake-session/url", .body = body };
}

test "validate rejects missing url, index, text and bad scroll" {
    {
        var parsed = try root.parseTestArgs("{\"action\":\"open\"}");
        defer parsed.deinit();
        try testing.expectEqualStrings("Missing 'url' parameter for the open/read action", validate("open", testArgs(&parsed)).?);
    }
    {
        var parsed = try root.parseTestArgs("{\"action\":\"click\"}");
        defer parsed.deinit();
        try testing.expectEqualStrings(
            "Missing 'index' (number from snapshot) or 'selector' parameter",
            validate("click", testArgs(&parsed)).?,
        );
    }
    {
        var parsed = try root.parseTestArgs("{\"action\":\"click\",\"index\":-1}");
        defer parsed.deinit();
        try testing.expect(validate("click", testArgs(&parsed)) != null);
    }
    {
        var parsed = try root.parseTestArgs("{\"action\":\"type\",\"index\":0}");
        defer parsed.deinit();
        try testing.expectEqualStrings("Missing 'text' parameter for the type action", validate("type", testArgs(&parsed)).?);
    }
    {
        var parsed = try root.parseTestArgs("{\"action\":\"click\",\"index\":\"3\"}");
        defer parsed.deinit();
        try testing.expect(validate("click", testArgs(&parsed)) == null);
    }
    {
        var parsed = try root.parseTestArgs("{\"action\":\"click\",\"selector\":\"#go\"}");
        defer parsed.deinit();
        try testing.expect(validate("click", testArgs(&parsed)) == null);
    }
    {
        var parsed = try root.parseTestArgs("{\"action\":\"scroll\",\"direction\":\"sideways\"}");
        defer parsed.deinit();
        try testing.expect(validate("scroll", testArgs(&parsed)) != null);
    }
    {
        var parsed = try root.parseTestArgs("{\"action\":\"scroll\",\"amount\":0}");
        defer parsed.deinit();
        try testing.expect(validate("scroll", testArgs(&parsed)) != null);
    }
    {
        var parsed = try root.parseTestArgs("{\"action\":\"scroll\",\"direction\":\"up\",\"amount\":250}");
        defer parsed.deinit();
        try testing.expect(validate("scroll", testArgs(&parsed)) == null);
    }
}

test "webdriver open and read navigate and return page text" {
    const routes = [_]Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\",\"capabilities\":{}}}" },
        .{ .method = "POST", .path = "/session/fake-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "POST", .path = "/session/fake-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://example.com/page\"}" },
        .{ .method = "POST", .path = "/session/fake-session/execute/sync", .body = "{\"value\":{\"title\":\"Example\",\"url\":\"https://example.com/page\",\"text\":\"hello page\"}}" },
        urlRoute("{\"value\":\"https://example.com/page\"}"),
    };
    const server = try FakeServer.start(testing.allocator, &routes);
    defer server.deinit();
    const base = try server.url(testing.allocator);
    defer testing.allocator.free(base);

    var client = try WebDriverClient.init(testing.allocator, base);
    defer client.deinit();
    try client.newSession(.{});

    const ctx = Context{ .workspace_dir = "", .allowed_domains = &.{"example.com"} };

    var open_args = try root.parseTestArgs("{\"action\":\"open\",\"url\":\"https://example.com/page\"}");
    defer open_args.deinit();
    const opened = try run(testing.allocator, &client, ctx, "open", testArgs(&open_args));
    defer testing.allocator.free(opened.output);
    try testing.expect(opened.success);
    try testing.expect(std.mem.indexOf(u8, opened.output, "Opened https://example.com/page") != null);

    var read_args = try root.parseTestArgs("{\"action\":\"read\",\"url\":\"https://example.com/page\"}");
    defer read_args.deinit();
    const read = try run(testing.allocator, &client, ctx, "read", testArgs(&read_args));
    defer testing.allocator.free(read.output);
    try testing.expect(read.success);
    try testing.expect(std.mem.indexOf(u8, read.output, "hello page") != null);
    try testing.expect(std.mem.indexOf(u8, read.output, "https://example.com/page") != null);
}

test "snapshot numbers elements and marks truncation" {
    const routes = [_]Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\",\"capabilities\":{}}}" },
        urlRoute("{\"value\":\"https://example.com/\"}"),
        .{ .method = "POST", .path = "/session/fake-session/execute/sync", .body = "{\"value\":{\"title\":\"Example\",\"url\":\"https://example.com/\",\"text\":\"short text\",\"elements\":[{\"tag\":\"a\",\"label\":\"Home\",\"detail\":\"href=/\"},{\"tag\":\"button\",\"label\":\"Go\",\"detail\":\"type=submit\"}],\"more\":true}}" },
        urlRoute("{\"value\":\"https://example.com/\"}"),
    };
    const server = try FakeServer.start(testing.allocator, &routes);
    defer server.deinit();
    const base = try server.url(testing.allocator);
    defer testing.allocator.free(base);

    var client = try WebDriverClient.init(testing.allocator, base);
    defer client.deinit();
    try client.newSession(.{});

    var args = try root.parseTestArgs("{\"action\":\"snapshot\"}");
    defer args.deinit();
    const result = try run(
        testing.allocator,
        &client,
        .{ .allowed_domains = &.{"example.com"} },
        "snapshot",
        testArgs(&args),
    );
    defer testing.allocator.free(result.output);
    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "short text") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "[0] <a> Home href=/") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "[1] <button> Go type=submit") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "[Content truncated to 8 KB]") != null);
    // The snapshot script is what makes later click/type by index work.
    try testing.expect(std.mem.indexOf(u8, server.requests[2].body, "data-junclaw-ref") != null);
}

test "snapshot caps long page text without splitting UTF-8" {
    var body_buf: [6000]u8 = undefined;
    for (&body_buf, 0..) |*byte, i| byte.* = switch (i % 3) {
        0 => 0xE4,
        1 => 0xB8,
        else => 0xAD,
    };
    const body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"value\":{{\"title\":\"T\",\"url\":\"https://example.com/\",\"text\":\"{s}\",\"elements\":[],\"more\":false}}}}",
        .{body_buf[0..]},
    );
    defer testing.allocator.free(body);

    const routes = [_]Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\",\"capabilities\":{}}}" },
        urlRoute("{\"value\":\"https://example.com/\"}"),
        .{ .method = "POST", .path = "/session/fake-session/execute/sync", .body = body },
        urlRoute("{\"value\":\"https://example.com/\"}"),
    };
    const server = try FakeServer.start(testing.allocator, &routes);
    defer server.deinit();
    const base = try server.url(testing.allocator);
    defer testing.allocator.free(base);

    var client = try WebDriverClient.init(testing.allocator, base);
    defer client.deinit();
    try client.newSession(.{});

    var parsed_args = try root.parseTestArgs("{\"action\":\"snapshot\"}");
    defer parsed_args.deinit();
    const result = try run(testing.allocator, &client, .{ .allowed_domains = &.{"example.com"} }, "snapshot", testArgs(&parsed_args));
    defer testing.allocator.free(result.output);
    try testing.expect(result.success);
    try testing.expect(result.output.len <= MAX_OUTPUT_BYTES + truncation_marker.len);
    try testing.expect(std.mem.indexOf(u8, result.output, truncation_marker) != null);
    try testing.expect(std.unicode.utf8ValidateSlice(result.output));
}

test "click and type reference snapshot indices" {
    const routes = [_]Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\",\"capabilities\":{}}}" },
        urlRoute("{\"value\":\"https://example.com/\"}"),
        .{ .method = "POST", .path = "/session/fake-session/element", .body = "{\"value\":{\"element-6066-11e4-a52e-4f735466cecf\":\"el0\"}}" },
        .{ .method = "POST", .path = "/session/fake-session/element/el0/click", .body = "{\"value\":null}" },
        urlRoute("{\"value\":\"https://example.com/\"}"),
        .{ .method = "POST", .path = "/session/fake-session/element", .body = "{\"value\":{\"element-6066-11e4-a52e-4f735466cecf\":\"el1\"}}" },
        .{ .method = "POST", .path = "/session/fake-session/element/el1/value", .body = "{\"value\":null}" },
    };
    const server = try FakeServer.start(testing.allocator, &routes);
    defer server.deinit();
    const base = try server.url(testing.allocator);
    defer testing.allocator.free(base);

    var client = try WebDriverClient.init(testing.allocator, base);
    defer client.deinit();
    try client.newSession(.{});

    const ctx = Context{ .allowed_domains = &.{"example.com"} };
    var click_args = try root.parseTestArgs("{\"action\":\"click\",\"index\":0}");
    defer click_args.deinit();
    const clicked = try run(testing.allocator, &client, ctx, "click", testArgs(&click_args));
    defer testing.allocator.free(clicked.output);
    try testing.expect(clicked.success);
    try testing.expect(std.mem.indexOf(u8, server.requests[2].body, "[data-junclaw-ref=\\\"0\\\"]") != null);

    var type_args = try root.parseTestArgs("{\"action\":\"type\",\"index\":\"1\",\"text\":\"hello\"}");
    defer type_args.deinit();
    const typed = try run(testing.allocator, &client, ctx, "type", testArgs(&type_args));
    defer testing.allocator.free(typed.output);
    try testing.expect(typed.success);
    try testing.expect(std.mem.indexOf(u8, server.requests[5].body, "[data-junclaw-ref=\\\"1\\\"]") != null);
    try testing.expect(std.mem.indexOf(u8, server.requests[6].body, "\"text\":\"hello\"") != null);
}

test "scroll converts direction and amount to scrollBy" {
    const routes = [_]Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\",\"capabilities\":{}}}" },
        urlRoute("{\"value\":\"https://example.com/\"}"),
        .{ .method = "POST", .path = "/session/fake-session/execute/sync", .body = "{\"value\":null}" },
    };
    const server = try FakeServer.start(testing.allocator, &routes);
    defer server.deinit();
    const base = try server.url(testing.allocator);
    defer testing.allocator.free(base);

    var client = try WebDriverClient.init(testing.allocator, base);
    defer client.deinit();
    try client.newSession(.{});

    var args = try root.parseTestArgs("{\"action\":\"scroll\",\"direction\":\"up\",\"amount\":250}");
    defer args.deinit();
    const result = try run(testing.allocator, &client, .{ .allowed_domains = &.{"example.com"} }, "scroll", testArgs(&args));
    defer testing.allocator.free(result.output);
    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, server.requests[2].body, "window.scrollBy(0, -250)") != null);
}

test "screenshot writes a PNG and returns an IMAGE marker" {
    const png = "\x89PNG\r\n\x1a\nfake-png";
    var encoded_buf: [128]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&encoded_buf, png);
    const body = try std.fmt.allocPrint(testing.allocator, "{{\"value\":\"{s}\"}}", .{encoded});
    defer testing.allocator.free(body);

    const routes = [_]Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\",\"capabilities\":{}}}" },
        urlRoute("{\"value\":\"https://example.com/\"}"),
        .{ .method = "GET", .path = "/session/fake-session/screenshot", .body = body },
        urlRoute("{\"value\":\"https://example.com/\"}"),
    };
    const server = try FakeServer.start(testing.allocator, &routes);
    defer server.deinit();
    const base = try server.url(testing.allocator);
    defer testing.allocator.free(base);

    var client = try WebDriverClient.init(testing.allocator, base);
    defer client.deinit();
    try client.newSession(.{});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(workspace);

    var args = try root.parseTestArgs("{\"action\":\"screenshot\"}");
    defer args.deinit();
    const result = try run(testing.allocator, &client, .{ .workspace_dir = workspace, .allowed_domains = &.{"example.com"} }, "screenshot", testArgs(&args));
    defer testing.allocator.free(result.output);
    try testing.expect(result.success);
    try testing.expect(std.mem.startsWith(u8, result.output, "[IMAGE:"));
    try testing.expect(std.mem.indexOf(u8, result.output, encoded) == null);
    try testing.expect(result.output.len < 300);

    const marker_path = result.output["[IMAGE:".len .. result.output.len - 1];
    try testing.expect(std.mem.startsWith(u8, marker_path, workspace));
    const saved = try compat.fs.cwd().readFileAlloc(testing.allocator, marker_path, 1024);
    defer testing.allocator.free(saved);
    try testing.expectEqualSlices(u8, png, saved);
}

test "screenshot reports an explicit error for bad payloads and no workspace" {
    const routes = [_]Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\",\"capabilities\":{}}}" },
        urlRoute("{\"value\":\"https://example.com/\"}"),
        .{ .method = "GET", .path = "/session/fake-session/screenshot", .body = "{\"value\":\"not base64!\"}" },
    };
    const server = try FakeServer.start(testing.allocator, &routes);
    defer server.deinit();
    const base = try server.url(testing.allocator);
    defer testing.allocator.free(base);

    var client = try WebDriverClient.init(testing.allocator, base);
    defer client.deinit();
    try client.newSession(.{});

    var args = try root.parseTestArgs("{\"action\":\"screenshot\"}");
    defer args.deinit();
    const no_workspace = try run(testing.allocator, &client, .{}, "screenshot", testArgs(&args));
    try testing.expect(!no_workspace.success);
    try testing.expectEqualStrings("Browser screenshot requires a workspace directory", no_workspace.error_msg.?);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(workspace);

    const bad = try run(testing.allocator, &client, .{ .workspace_dir = workspace, .allowed_domains = &.{"example.com"} }, "screenshot", testArgs(&args));
    try testing.expect(!bad.success);
    try testing.expectEqualStrings("WebDriver returned an invalid screenshot payload", bad.error_msg.?);
}
