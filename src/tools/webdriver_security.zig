//! Security boundary for the Firefox/WebDriver backend.
//!
//! URL policy mirrors `WebFetchTool`: HTTPS only (AGENTS.md policy), the
//! optional allowlist is checked before any DNS lookup, and non-allowlisted
//! hosts must resolve to a globally routable address through
//! `net_security.resolveConnectHost`. Firefox follows redirects itself, so the
//! URL it actually landed on is checked again after every navigation and
//! before every snapshot; a violation closes the page and marks the session
//! stale so the manager rebuilds it.
//!
//! Known limits (see docs/browser.md): Firefox resolves DNS for its own
//! subresources, so this is a per-navigation check, not a network sandbox.
//! DNS rebinding between our lookup and Firefox's own is not covered; run the
//! browser behind network isolation when the LAN must stay unreachable.
const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const net_security = @import("../root.zig").net_security;
const WebDriverClient = @import("webdriver_client.zig").WebDriverClient;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.browser);

pub const UrlCheckError = error{
    InsecureScheme,
    UnsupportedScheme,
    MalformedUrl,
    InvalidUrl,
    HostNotAllowed,
    BlockedAddress,
    HostResolutionFailed,
    OutOfMemory,
};

/// Message for `ToolResult.fail`; a failed WebDriver command or URL check is
/// returned as a tool error, never as a panic that could take down the agent.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InsecureScheme, error.UnsupportedScheme, error.MalformedUrl => "Only HTTPS URLs are allowed for security",
        error.InvalidUrl => "Invalid URL: cannot extract host",
        error.HostNotAllowed => "Host is not in browser.allowed_domains",
        error.BlockedAddress => "Blocked local/private/metadata address",
        error.HostResolutionFailed => "URL host could not be resolved",
        error.OutOfMemory => "Out of memory",
        else => "Browser operation failed",
    };
}

/// HTTPS-only URL policy shared by the initial navigation, redirect targets and
/// post-snapshot rechecks. Same order and trade-offs as `WebFetchTool`: the
/// allowlist is consulted before DNS, and allowlisted hosts are operator-trusted
/// (they may point at a private service, see #393).
pub fn validateUrl(
    allocator: Allocator,
    url: []const u8,
    allowed_domains: []const []const u8,
) UrlCheckError!void {
    net_security.validateOutboundUrl(url) catch |err| return switch (err) {
        error.InsecureScheme => error.InsecureScheme,
        error.UnsupportedScheme => error.UnsupportedScheme,
        error.MalformedUrl => error.MalformedUrl,
    };

    const uri = std.Uri.parse(url) catch return error.MalformedUrl;
    const host = net_security.extractHost(url) orelse return error.InvalidUrl;

    if (allowed_domains.len > 0) {
        if (!net_security.hostMatchesAllowlist(host, allowed_domains)) return error.HostNotAllowed;
        return;
    }

    const port: u16 = uri.port orelse 443;
    const resolved = net_security.resolveConnectHost(allocator, host, port) catch |err| return switch (err) {
        error.LocalAddressBlocked => error.BlockedAddress,
        error.HostResolutionFailed => error.HostResolutionFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
    allocator.free(resolved);
}

/// Validate, navigate, then recheck the final URL so a redirect into a private,
/// loopback, link-local or metadata address is rejected. Blocking closes the
/// page; the lifecycle process-group kill is the fallback if the driver refuses.
pub fn navigateChecked(
    allocator: Allocator,
    client: *WebDriverClient,
    url: []const u8,
    allowed_domains: []const []const u8,
) !void {
    try validateUrl(allocator, url, allowed_domains);
    try client.navigate(url);
    try checkCurrentUrl(allocator, client, allowed_domains);
}

/// Recheck the URL Firefox actually landed on (redirect target or the page a
/// snapshot is read from). A final URL that cannot be read fails closed.
pub fn checkCurrentUrl(
    allocator: Allocator,
    client: *WebDriverClient,
    allowed_domains: []const []const u8,
) !void {
    const final_url = client.getCurrentUrl(allocator) catch |err| {
        client.stale = true;
        return err;
    };
    defer allocator.free(final_url);
    validateUrl(allocator, final_url, allowed_domains) catch |err| {
        client.closeWindow() catch {};
        client.stale = true;
        return err;
    };
}

// ── One-shot Firefox profile ────────────────────────────────────────

/// Prefs written to `<profile>/user.js` before Firefox starts. These are the
/// outbound calls a browsing tool must never make on its own: telemetry,
/// update checks, crash/breakpad reports, studies, region and captive-portal
/// probes. Keep this list in sync with docs/{en,zh}/browser.md.
pub const user_js_prefs =
    \\user_pref("toolkit.telemetry.enabled", false);
    \\user_pref("toolkit.telemetry.unified", false);
    \\user_pref("toolkit.telemetry.archive.enabled", false);
    \\user_pref("toolkit.telemetry.server", "");
    \\user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
    \\user_pref("toolkit.telemetry.shutdownPingSender.enabled", false);
    \\user_pref("datareporting.healthreport.uploadEnabled", false);
    \\user_pref("datareporting.policy.dataSubmissionEnabled", false);
    \\user_pref("app.update.enabled", false);
    \\user_pref("app.update.auto", false);
    \\user_pref("app.update.disabledForTesting", true);
    \\user_pref("browser.search.update", false);
    \\user_pref("browser.crashReports.unsubmittedCheck.enabled", false);
    \\user_pref("browser.tabs.crashReporting.sendReport", false);
    \\user_pref("breakpad.reportURL", "");
    \\user_pref("browser.newtabpage.activity-stream.telemetry", false);
    \\user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
    \\user_pref("browser.ping-centre.telemetry", false);
    \\user_pref("app.normandy.enabled", false);
    \\user_pref("app.shield.optoutstudies.enabled", false);
    \\user_pref("browser.discovery.enabled", false);
    \\user_pref("extensions.getAddons.cache.enabled", false);
    \\user_pref("extensions.pocket.enabled", false);
    \\user_pref("identity.fxaccounts.enabled", false);
    \\user_pref("network.captive-portal-service.enabled", false);
    \\user_pref("network.connectivity-service.enabled", false);
    \\user_pref("browser.region.update.enabled", false);
    \\user_pref("browser.region.network.url", "");
    \\user_pref("browser.safebrowsing.downloads.remote.enabled", false);
;

/// Complete user.js for a profile whose downloads land in `download_dir`.
/// The directory lives inside the profile, so shutdown deletes it with the rest.
pub fn userJsAlloc(allocator: Allocator, download_dir: []const u8) ![]u8 {
    const escaped = try escapeUserJsPath(allocator, download_dir);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(
        allocator,
        "{s}" ++
            "user_pref(\"browser.download.folderList\", 2);\n" ++
            "user_pref(\"browser.download.dir\", \"{s}\");\n" ++
            "user_pref(\"browser.download.useDownloadDir\", true);\n" ++
            "user_pref(\"browser.download.always_ask_before_handling_new_types\", false);\n" ++
            "user_pref(\"browser.download.manager.showWhenStarting\", false);\n" ++
            "user_pref(\"browser.helperApps.neverAsk.saveToDisk\", \"\");\n",
        .{ user_js_prefs, escaped },
    );
}

/// Windows separators are not valid unescaped inside a JS string; Firefox
/// accepts forward slashes for every profile path.
fn escapeUserJsPath(allocator: Allocator, path: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, path.len);
    for (path, 0..) |c, i| out[i] = if (c == '\\') '/' else c;
    return out;
}

/// A throwaway Firefox profile. Never points at the host profile, so no host
/// cookies or logins are loaded; `deinit` removes the whole tree.
pub const Profile = struct {
    allocator: Allocator,
    path: []u8,

    pub fn create(allocator: Allocator) !Profile {
        const base = try tempBase(allocator);
        defer allocator.free(base);
        return createIn(allocator, base);
    }

    /// `base` must already exist (tests pass a tmpDir path).
    pub fn createIn(allocator: Allocator, base: []const u8) !Profile {
        const name = try std.fmt.allocPrint(allocator, "nullclaw-wd-{x}", .{compat.crypto.random.int(u64)});
        defer allocator.free(name);
        const path = try compat.fs.path.join(allocator, &.{ base, name });
        errdefer allocator.free(path);

        try compat.fs.makeDirAbsolute(path);
        errdefer compat.fs.deleteTreeAbsolute(path) catch {};

        const downloads = try compat.fs.path.join(allocator, &.{ path, "downloads" });
        defer allocator.free(downloads);
        try compat.fs.makeDirAbsolute(downloads);

        const user_js = try userJsAlloc(allocator, downloads);
        defer allocator.free(user_js);
        const user_js_path = try compat.fs.path.join(allocator, &.{ path, "user.js" });
        defer allocator.free(user_js_path);
        const file = try compat.fs.createFileAbsolute(user_js_path, .{});
        defer file.close();
        try file.writeAll(user_js);

        return .{ .allocator = allocator, .path = path };
    }

    /// Best effort: a locked file must not turn shutdown into an agent failure.
    pub fn deinit(self: *Profile) void {
        compat.fs.deleteTreeAbsolute(self.path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("failed to remove webdriver profile {s}: {s}", .{
                self.path,
                @errorName(err),
            }),
        };
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

fn tempBase(allocator: Allocator) ![]u8 {
    const names: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "TEMP", "TMP" }
    else
        &.{"TMPDIR"};
    for (names) |name| {
        const value = compat.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => continue,
            else => |e| return e,
        };
        if (value.len > 0) return value;
        allocator.free(value);
    }
    return allocator.dupe(u8, if (builtin.os.tag == .windows) "." else "/tmp");
}

// ── Tests ───────────────────────────────────────────────────────────

const fake = @import("webdriver_fake_server.zig");

test "url policy rejects non-https schemes" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InsecureScheme, validateUrl(allocator, "http://example.com/", &.{}));
    try std.testing.expectError(error.UnsupportedScheme, validateUrl(allocator, "file:///etc/passwd", &.{}));
    try std.testing.expectError(error.MalformedUrl, validateUrl(allocator, "not-a-url", &.{}));
}

test "url policy blocks loopback, private, link-local and metadata literals" {
    const allocator = std.testing.allocator;
    const blocked = [_][]const u8{
        "https://127.0.0.1/",
        "https://10.0.0.1/",
        "https://172.16.0.1/",
        "https://192.168.1.1/",
        "https://169.254.169.254/latest/meta-data/",
        "https://[::1]/",
        "https://2130706433/",
    };
    for (blocked) |url| {
        try std.testing.expectError(error.BlockedAddress, validateUrl(allocator, url, &.{}));
    }
}

test "url policy allows global literals and trusts allowlisted hosts" {
    const allocator = std.testing.allocator;
    try validateUrl(allocator, "https://8.8.8.8/", &.{});

    const domains = [_][]const u8{ "internal.example.com", "*.example.org" };
    // Allowlisted hosts skip DNS, the same operator-trust trade-off as web_fetch.
    try validateUrl(allocator, "https://internal.example.com/app", &domains);
    try validateUrl(allocator, "https://api.example.org/", &domains);
    try std.testing.expectError(
        error.HostNotAllowed,
        validateUrl(allocator, "https://other.example.net/", &domains),
    );
}

test "navigateChecked blocks a redirect to a metadata address" {
    const allocator = std.testing.allocator;
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\"}}" },
        .{ .method = "POST", .path = "/session/fake-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://169.254.169.254/latest/meta-data/\"}" },
        .{ .method = "POST", .path = "/session/fake-session/window/close", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base_url = try server.url(allocator);
    defer allocator.free(base_url);

    var client = try WebDriverClient.init(allocator, base_url);
    defer client.deinit();
    try client.newSession(.{});

    try std.testing.expectError(
        error.BlockedAddress,
        navigateChecked(allocator, &client, "https://8.8.8.8/", &.{}),
    );
    try std.testing.expect(client.stale);

    server.stopAndJoin();
    try std.testing.expectEqual(@as(usize, 4), server.request_count);
    try std.testing.expectEqualStrings("/session/fake-session/window/close", server.requests[3].path);
}

test "checkCurrentUrl blocks a private final URL and closes the page" {
    const allocator = std.testing.allocator;
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\"}}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://10.0.0.7/admin\"}" },
        .{ .method = "POST", .path = "/session/fake-session/window/close", .body = "{\"value\":null}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base_url = try server.url(allocator);
    defer allocator.free(base_url);

    var client = try WebDriverClient.init(allocator, base_url);
    defer client.deinit();
    try client.newSession(.{});

    try std.testing.expectError(error.BlockedAddress, checkCurrentUrl(allocator, &client, &.{}));
    try std.testing.expect(client.stale);

    server.stopAndJoin();
    try std.testing.expectEqual(@as(usize, 3), server.request_count);
    try std.testing.expectEqualStrings("/session/fake-session/window/close", server.requests[2].path);
}

test "navigateChecked accepts a global final URL" {
    const allocator = std.testing.allocator;
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\"}}" },
        .{ .method = "POST", .path = "/session/fake-session/url", .body = "{\"value\":null}" },
        .{ .method = "GET", .path = "/session/fake-session/url", .body = "{\"value\":\"https://8.8.8.8/landing\"}" },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base_url = try server.url(allocator);
    defer allocator.free(base_url);

    var client = try WebDriverClient.init(allocator, base_url);
    defer client.deinit();
    try client.newSession(.{});

    try navigateChecked(allocator, &client, "https://8.8.8.8/", &.{});
    try std.testing.expect(!client.stale);

    server.stopAndJoin();
    try std.testing.expectEqual(@as(usize, 3), server.request_count);
}

test "navigateChecked fails closed when the final URL cannot be read" {
    const allocator = std.testing.allocator;
    const routes = [_]fake.Route{
        .{ .method = "POST", .path = "/session", .body = "{\"value\":{\"sessionId\":\"fake-session\"}}" },
        .{ .method = "POST", .path = "/session/fake-session/url", .body = "{\"value\":null}" },
        .{
            .method = "GET",
            .path = "/session/fake-session/url",
            .status = 500,
            .body = "{\"value\":{\"error\":\"unknown error\",\"message\":\"boom\",\"stacktrace\":\"\"}}",
        },
    };
    const server = try fake.Server.start(allocator, &routes);
    defer server.deinit();
    const base_url = try server.url(allocator);
    defer allocator.free(base_url);

    var client = try WebDriverClient.init(allocator, base_url);
    defer client.deinit();
    try client.newSession(.{});

    try std.testing.expectError(
        error.CommandFailed,
        navigateChecked(allocator, &client, "https://8.8.8.8/", &.{}),
    );
    try std.testing.expect(client.stale);

    server.stopAndJoin();
    try std.testing.expectEqual(@as(usize, 3), server.request_count);
}

test "one-shot profile writes user.js prefs and is removed on deinit" {
    const allocator = std.testing.allocator;
    var profile = try Profile.create(allocator);
    var alive = true;
    defer if (alive) profile.deinit();
    const profile_path = try allocator.dupe(u8, profile.path);
    defer allocator.free(profile_path);

    const downloads = try compat.fs.path.join(allocator, &.{ profile_path, "downloads" });
    defer allocator.free(downloads);
    try compat.fs.accessAbsolute(downloads, .{});

    const user_js_path = try compat.fs.path.join(allocator, &.{ profile_path, "user.js" });
    defer allocator.free(user_js_path);
    const file = try compat.fs.openFileAbsolute(user_js_path, .{});
    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    file.close();
    defer allocator.free(content);

    const required = [_][]const u8{
        "toolkit.telemetry.enabled",
        "toolkit.telemetry.server",
        "datareporting.policy.dataSubmissionEnabled",
        "app.update.enabled",
        "browser.crashReports.unsubmittedCheck.enabled",
        "breakpad.reportURL",
        "browser.download.folderList",
        "browser.download.dir",
    };
    for (required) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, content, needle) != null);
    }

    const normalized_downloads = try escapeUserJsPath(allocator, downloads);
    defer allocator.free(normalized_downloads);
    try std.testing.expect(std.mem.indexOf(u8, content, normalized_downloads) != null);

    profile.deinit();
    alive = false;
    try std.testing.expectError(error.FileNotFound, compat.fs.accessAbsolute(profile_path, .{}));
}

test "one-shot profiles use distinct directories" {
    const allocator = std.testing.allocator;
    var first = try Profile.create(allocator);
    defer first.deinit();
    var second = try Profile.create(allocator);
    defer second.deinit();
    try std.testing.expect(!std.mem.eql(u8, first.path, second.path));
}

test "user.js normalizes Windows download paths" {
    const js = try userJsAlloc(std.testing.allocator, "C:\\Temp\\wd\\downloads");
    defer std.testing.allocator.free(js);
    try std.testing.expect(std.mem.indexOf(
        u8,
        js,
        "user_pref(\"browser.download.dir\", \"C:/Temp/wd/downloads\");",
    ) != null);
}
