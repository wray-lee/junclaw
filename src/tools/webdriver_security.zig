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
const platform = @import("../platform.zig");
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
/// probes. The lower block closes every name-resolution and transport path
/// that would leave without the filtering proxy: DoH/TRR, DNS prefetch,
/// speculative/prefetch connections, HTTP3/Alt-Svc and WebRTC. Safe Browsing,
/// OCSP and Remote Settings are off for the same reason; the browser holds no
/// user credentials. Keep this list in sync with docs/{en,zh}/browser.md.
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
    \\user_pref("browser.safebrowsing.malware.enabled", false);
    \\user_pref("browser.safebrowsing.phishing.enabled", false);
    \\user_pref("browser.safebrowsing.downloads.enabled", false);
    \\user_pref("security.OCSP.enabled", 0);
    \\user_pref("security.OCSP.require", false);
    \\user_pref("security.remote_settings.crlite_filters.enabled", false);
    \\user_pref("security.remote_settings.intermediates.enabled", false);
    \\user_pref("services.settings.server", "data:,");
    \\user_pref("network.trr.mode", 5);
    \\user_pref("network.trr.uri", "");
    \\user_pref("network.trr.custom_uri", "");
    \\user_pref("network.dns.disablePrefetch", true);
    \\user_pref("network.dns.disablePrefetchFromHTTPS", true);
    \\user_pref("network.prefetch-next", false);
    \\user_pref("network.http.speculative-parallel-limit", 0);
    \\user_pref("network.predictor.enabled", false);
    \\user_pref("network.predictor.enable-prefetch", false);
    \\user_pref("network.http.http3.enable", false);
    \\user_pref("network.http.altsvc.enabled", false);
    \\user_pref("browser.urlbar.speculativeConnect.enabled", false);
    \\user_pref("media.peerconnection.enabled", false);
    \\user_pref("media.peerconnection.ice.proxy_only", true);
    \\user_pref("browser.search.suggest.enabled", false);
    \\user_pref("extensions.update.enabled", false);
    \\user_pref("extensions.systemAddon.update.enabled", false);
    \\user_pref("geo.enabled", false);
    \\user_pref("geo.provider.network.url", "");
    \\user_pref("browser.send_pings", false);
;

/// Manual-proxy prefs written only while the in-process filtering proxy is
/// running; `{d}` is its loopback port (http and ssl). failover_direct=false
/// and allow_hijacking_localhost=true are load-bearing: the first stops
/// Firefox from silently going direct when the proxy is down, the second
/// stops it from bypassing the proxy for localhost/loopback targets.
const proxy_js_prefs =
    \\user_pref("network.proxy.type", 1);
    \\user_pref("network.proxy.http", "127.0.0.1");
    \\user_pref("network.proxy.http_port", {d});
    \\user_pref("network.proxy.ssl", "127.0.0.1");
    \\user_pref("network.proxy.ssl_port", {d});
    \\user_pref("network.proxy.ftp", "");
    \\user_pref("network.proxy.socks", "");
    \\user_pref("network.proxy.socks_remote_dns", true);
    \\user_pref("network.proxy.no_proxies_on", "");
    \\user_pref("network.proxy.allow_hijacking_localhost", true);
    \\user_pref("network.proxy.failover_direct", false);
    \\user_pref("network.proxy.autoconfig_url", "");
;

/// Complete user.js for a profile whose downloads land in `download_dir`.
/// The directory lives inside the profile, so shutdown deletes it with the rest.
/// `proxy_port` is null only for externally managed WebDriver endpoints
/// (`Options.driver_url`), which have no proxy of ours to point at.
pub fn userJsAlloc(allocator: Allocator, proxy_port: ?u16, download_dir: []const u8) ![]u8 {
    const escaped = try escapeUserJsPath(allocator, download_dir);
    defer allocator.free(escaped);
    const proxy_prefs = if (proxy_port) |port|
        try std.fmt.allocPrint(allocator, proxy_js_prefs, .{ port, port })
    else
        try allocator.dupe(u8, "");
    defer allocator.free(proxy_prefs);
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}" ++
            "user_pref(\"browser.download.folderList\", 2);\n" ++
            "user_pref(\"browser.download.dir\", \"{s}\");\n" ++
            "user_pref(\"browser.download.useDownloadDir\", true);\n" ++
            "user_pref(\"browser.download.always_ask_before_handling_new_types\", false);\n" ++
            "user_pref(\"browser.download.manager.showWhenStarting\", false);\n" ++
            "user_pref(\"browser.helperApps.neverAsk.saveToDisk\", \"\");\n",
        .{ proxy_prefs, user_js_prefs, escaped },
    );
}

/// Windows separators are not valid unescaped inside a JS string; Firefox
/// accepts forward slashes for every profile path.
fn escapeUserJsPath(allocator: Allocator, path: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, path.len);
    for (path, 0..) |c, i| out[i] = if (c == '\\') '/' else c;
    return out;
}

/// F8: the profile holds cookies/logins and downloads receive page content, so
/// both directories are owner-only. Windows has no POSIX mode bits; the
/// profile lives under the per-user temp directory and inherits its ACL.
fn restrictProfileDir(path: []const u8) !void {
    if (comptime builtin.os.tag == .windows) return;
    try compat.fs.chmodAbsolute(path, 0o700);
}

/// A throwaway Firefox profile. Never points at the host profile, so no host
/// cookies or logins are loaded; `deinit` removes the whole tree.
pub const Profile = struct {
    allocator: Allocator,
    path: []u8,

    pub fn create(allocator: Allocator, proxy_port: ?u16) !Profile {
        const base = try tempBase(allocator);
        defer allocator.free(base);
        return createIn(allocator, base, proxy_port);
    }

    /// `base` must already exist (tests pass a tmpDir path).
    pub fn createIn(allocator: Allocator, base: []const u8, proxy_port: ?u16) !Profile {
        const name = try std.fmt.allocPrint(allocator, "nullclaw-wd-{x}", .{compat.crypto.random.int(u64)});
        defer allocator.free(name);
        const path = try compat.fs.path.join(allocator, &.{ base, name });
        errdefer allocator.free(path);

        try compat.fs.makeDirAbsolute(path);
        errdefer compat.fs.deleteTreeAbsolute(path) catch {};
        try restrictProfileDir(path);

        const downloads = try compat.fs.path.join(allocator, &.{ path, "downloads" });
        defer allocator.free(downloads);
        try compat.fs.makeDirAbsolute(downloads);
        try restrictProfileDir(downloads);

        const user_js = try userJsAlloc(allocator, proxy_port, downloads);
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

fn readProfileUserJs(allocator: Allocator, profile_path: []const u8) ![]u8 {
    const user_js_path = try compat.fs.path.join(allocator, &.{ profile_path, "user.js" });
    defer allocator.free(user_js_path);
    const file = try compat.fs.openFileAbsolute(user_js_path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024);
}

test "one-shot profile writes user.js prefs and is removed on deinit" {
    const allocator = std.testing.allocator;
    var profile = try Profile.create(allocator, 43111);
    var alive = true;
    defer if (alive) profile.deinit();
    const profile_path = try allocator.dupe(u8, profile.path);
    defer allocator.free(profile_path);

    const downloads = try compat.fs.path.join(allocator, &.{ profile_path, "downloads" });
    defer allocator.free(downloads);
    try compat.fs.accessAbsolute(downloads, .{});

    const content = try readProfileUserJs(allocator, profile_path);
    defer allocator.free(content);

    // Regression: Firefox used to leave directly, with DoH, prefetch,
    // speculative connections and WebRTC open, so redirect hops and
    // sub-resources never reached the filtering proxy or the URL policy.
    const required = [_][]const u8{
        "user_pref(\"toolkit.telemetry.enabled\", false);",
        "user_pref(\"toolkit.telemetry.server\", \"\");",
        "user_pref(\"datareporting.policy.dataSubmissionEnabled\", false);",
        "user_pref(\"app.update.enabled\", false);",
        "user_pref(\"browser.crashReports.unsubmittedCheck.enabled\", false);",
        "user_pref(\"breakpad.reportURL\", \"\");",
        "user_pref(\"browser.download.folderList\", 2);",
        // Manual proxy; failover_direct=false and
        // allow_hijacking_localhost=true close Firefox's two silent bypasses.
        "user_pref(\"network.proxy.type\", 1);",
        "user_pref(\"network.proxy.http\", \"127.0.0.1\");",
        "user_pref(\"network.proxy.http_port\", 43111);",
        "user_pref(\"network.proxy.ssl\", \"127.0.0.1\");",
        "user_pref(\"network.proxy.ssl_port\", 43111);",
        "user_pref(\"network.proxy.ftp\", \"\");",
        "user_pref(\"network.proxy.socks\", \"\");",
        "user_pref(\"network.proxy.socks_remote_dns\", true);",
        "user_pref(\"network.proxy.no_proxies_on\", \"\");",
        "user_pref(\"network.proxy.allow_hijacking_localhost\", true);",
        "user_pref(\"network.proxy.failover_direct\", false);",
        "user_pref(\"network.proxy.autoconfig_url\", \"\");",
        // No DNS/QUIC/prefetch/speculation path of its own.
        "user_pref(\"network.trr.mode\", 5);",
        "user_pref(\"network.trr.uri\", \"\");",
        "user_pref(\"network.dns.disablePrefetch\", true);",
        "user_pref(\"network.dns.disablePrefetchFromHTTPS\", true);",
        "user_pref(\"network.prefetch-next\", false);",
        "user_pref(\"network.http.speculative-parallel-limit\", 0);",
        "user_pref(\"network.predictor.enabled\", false);",
        "user_pref(\"network.http.http3.enable\", false);",
        "user_pref(\"network.http.altsvc.enabled\", false);",
        "user_pref(\"media.peerconnection.enabled\", false);",
        "user_pref(\"media.peerconnection.ice.proxy_only\", true);",
        // Safe Browsing / OCSP / Remote Settings:
        "user_pref(\"browser.safebrowsing.malware.enabled\", false);",
        "user_pref(\"browser.safebrowsing.phishing.enabled\", false);",
        "user_pref(\"browser.safebrowsing.downloads.enabled\", false);",
        "user_pref(\"security.OCSP.enabled\", 0);",
        "user_pref(\"security.OCSP.require\", false);",
        "user_pref(\"security.remote_settings.crlite_filters.enabled\", false);",
        "user_pref(\"services.settings.server\", \"data:,\");",
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

test "one-shot profile and downloads directories are owner-only" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var profile = try Profile.create(allocator, null);
    defer profile.deinit();

    const downloads = try compat.fs.path.join(allocator, &.{ profile.path, "downloads" });
    defer allocator.free(downloads);

    // Regression: both directories used to be created with the default 0777
    // minus umask, so other local users could read cookies and downloads.
    const profile_stat = try compat.fs.Dir.cwd().statFile(profile.path);
    try std.testing.expectEqual(@as(compat.fs.File.Mode, 0o700), profile_stat.mode & 0o777);
    const downloads_stat = try compat.fs.Dir.cwd().statFile(downloads);
    try std.testing.expectEqual(@as(compat.fs.File.Mode, 0o700), downloads_stat.mode & 0o777);
}

test "profile for an external WebDriver endpoint has no proxy prefs" {
    const allocator = std.testing.allocator;
    var profile = try Profile.create(allocator, null);
    defer profile.deinit();

    const content = try readProfileUserJs(allocator, profile.path);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "network.proxy.") == null);
    // The outbound hardening does not depend on the proxy.
    try std.testing.expect(std.mem.indexOf(u8, content, "user_pref(\"network.trr.mode\", 5);") != null);
}

test "one-shot profiles use distinct directories" {
    const allocator = std.testing.allocator;
    var first = try Profile.create(allocator, null);
    defer first.deinit();
    var second = try Profile.create(allocator, null);
    defer second.deinit();
    try std.testing.expect(!std.mem.eql(u8, first.path, second.path));
}

test "user.js normalizes Windows download paths" {
    const js = try userJsAlloc(std.testing.allocator, null, "C:\\Temp\\wd\\downloads");
    defer std.testing.allocator.free(js);
    try std.testing.expect(std.mem.indexOf(
        u8,
        js,
        "user_pref(\"browser.download.dir\", \"C:/Temp/wd/downloads\");",
    ) != null);
}

test "Android webdriver temp base follows the platform fallback chain" {
    // Regression: Android has no writable /tmp, so the Firefox profile was
    // created under /tmp and the browser could not start.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const expected = try compat.fs.path.join(allocator, &.{ root, "tmp" });
    defer allocator.free(expected);
    const base = try platform.androidTempDir(allocator, null, root, null);
    defer allocator.free(base);
    try std.testing.expectEqualStrings(expected, base);
    try compat.fs.accessAbsolute(base, .{});
}
