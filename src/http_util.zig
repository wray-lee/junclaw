//! Shared HTTP utilities.
//!
//! Buffered std.http calls share proxy setup through `ProxyHttpClient`. Legacy
//! and Android curl paths share one executor; URL, proxy, and caller headers are
//! stored in mode-0600 temporary files instead of process argv. Android uses
//! curl because Termux lacks the resolver configuration Zig expects.

const std = @import("std");
const builtin = @import("builtin");
const std_compat = @import("compat");
const Allocator = std.mem.Allocator;
const AtomicBool = std.atomic.Value(bool);
const net_security = @import("net_security.zig");
const platform = @import("platform.zig");
const tls_ca = @import("tls/ca.zig");

const log = std.log.scoped(.http_util);
threadlocal var thread_interrupt_flag: ?*const AtomicBool = null;
pub const DEFAULT_CURL_GET_MAX_BYTES: usize = 4 * 1024 * 1024;
const DEFAULT_CURL_POST_MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_CURL_STDERR_BYTES: usize = 16 * 1024;
const MAX_CURL_RESPONSE_HEADERS_BYTES: usize = 64 * 1024;
const STD_HTTP_USER_AGENT_HEADER = "User-Agent: zig/" ++ builtin.zig_version_string ++ " (std.http)";
const STD_HTTP_ACCEPT_ENCODING_HEADER = "Accept-Encoding: gzip, deflate";
pub const CredentialedCurlArgError = error{CredentialedCurlArgRejected};

fn classifyCurlExitCode(code: u8) []const u8 {
    return switch (code) {
        6 => "dns",
        7 => "connect",
        28 => "timeout",
        35, 51, 58, 60 => "tls",
        else => "other",
    };
}

pub fn mapCurlExitCodeToError(code: u8) anyerror {
    return switch (code) {
        2, 3, 4, 5 => error.CurlPreSendError,
        6 => error.CurlDnsError,
        7 => error.CurlConnectError,
        28 => error.CurlTimeout,
        35, 51, 58, 60 => error.CurlTlsError,
        else => error.CurlFailed,
    };
}

pub fn isCurlTransportError(err: anyerror) bool {
    return switch (err) {
        error.CurlPreSendError,
        error.CurlDnsError,
        error.CurlConnectError,
        error.CurlTimeout,
        error.CurlTlsError,
        error.CurlReadError,
        error.CurlWriteError,
        error.CurlWaitError,
        error.CurlFailed,
        error.CurlInterrupted,
        => true,
        else => false,
    };
}

pub fn preserveCurlTransportError(err: anyerror, fallback: anyerror) anyerror {
    // Gateway uncertainty is not a curl exit, but it must keep its identity so
    // the channel guards can treat it like the other indeterminate outcomes.
    return if (isCurlTransportError(err) or err == error.HttpStatusIndeterminate) err else fallback;
}

/// Gateway statuses a proxy can return after it already forwarded the request:
/// 502 (bad gateway) and 504 (gateway timeout). The send outcome is unknown, so
/// senders must not resend. Other 4xx/5xx — including Telegram's own API
/// rejections and 429/503 — stay `HttpStatusError` and keep the existing
/// fallback/retry behavior.
pub fn isIndeterminateHttpStatus(status_code: u16) bool {
    return status_code == 502 or status_code == 504;
}

/// Map a non-2xx response to the shared send-boundary error identity.
pub fn httpStatusError(status_code: u16) error{ HttpStatusError, HttpStatusIndeterminate } {
    return if (isIndeterminateHttpStatus(status_code)) error.HttpStatusIndeterminate else error.HttpStatusError;
}

/// Reads keep the old `HttpStatusError` identity; only mutating requests can
/// have an indeterminate delivery outcome.
fn sendErrorForMethod(method: std.http.Method, status_code: u16) error{ HttpStatusError, HttpStatusIndeterminate } {
    return if (method != .GET and method != .HEAD and isIndeterminateHttpStatus(status_code))
        error.HttpStatusIndeterminate
    else
        error.HttpStatusError;
}

/// Transport errors where the request may already have reached the service:
/// a curl timeout, a broken/partial response, an empty reply, or a child.wait
/// failure after curl started. Re-sending after one of these — in another
/// format, by the channel, or by the outbox/dispatch retry layers — can deliver
/// the same message twice, so callers count it as one best-effort attempt. A
/// definite pre-send failure (malformed URL, unresolvable proxy, DNS/connect/
/// TLS) is not in this set and can still be retried.
pub fn isIndeterminateSendError(err: anyerror) bool {
    return switch (err) {
        error.CurlTimeout,
        error.CurlReadError,
        error.CurlWriteError,
        // child.wait failed after curl was spawned: the request may have gone
        // out even though its output stream is already closed.
        error.CurlWaitError,
        // exit 16/18/52/55/56/92 (partial or interrupted transfer, empty
        // reply, send/receive failure) and unknown exit codes: the request may
        // have been delivered, so a resend is not safe.
        error.CurlFailed,
        // A gateway answered after forwarding the request (see
        // `isIndeterminateHttpStatus`).
        error.HttpStatusIndeterminate,
        => true,
        else => false,
    };
}

const StderrCapture = struct {
    file: ?std_compat.fs.File = null,
    buffer: [MAX_CURL_STDERR_BYTES]u8 = undefined,
    len: usize = 0,

    fn trimmed(self: *const StderrCapture) ?[]const u8 {
        const bytes = std.mem.trim(u8, self.buffer[0..self.len], " \t\r\n");
        if (bytes.len == 0) return null;
        return bytes;
    }
};

fn stderrCaptureMain(ctx: *StderrCapture) void {
    const file = ctx.file orelse return;
    defer file.close();
    while (ctx.len < ctx.buffer.len) {
        const n = file.read(ctx.buffer[ctx.len..]) catch return;
        if (n == 0) return;
        ctx.len += n;
    }

    // Keep draining after the retained buffer is full so a noisy child cannot
    // block forever on a full stderr pipe while the parent waits on stdout.
    var discard: [1024]u8 = undefined;
    while (true) {
        const n = file.read(&discard) catch return;
        if (n == 0) return;
    }
}

fn startStderrCapture(child: *std_compat.process.Child, capture: *StderrCapture) ?std.Thread {
    capture.* = .{ .file = child.stderr };
    if (capture.file == null) return null;
    child.stderr = null;
    return std.Thread.spawn(.{}, stderrCaptureMain, .{capture}) catch {
        capture.file.?.close();
        capture.file = null;
        return null;
    };
}

fn finishStderrCapture(thread_opt: *?std.Thread, capture: *const StderrCapture) ?[]const u8 {
    if (thread_opt.*) |thread| {
        thread.join();
        thread_opt.* = null;
    }
    return capture.trimmed();
}

fn logCurlExitFailure(op: []const u8, code: u8, stderr_msg: ?[]const u8) void {
    if (stderr_msg) |msg| {
        log.warn("curl {s} failed: exit_code={d} class={s} stderr={s}", .{ op, code, classifyCurlExitCode(code), msg });
    } else {
        log.warn("curl {s} failed: exit_code={d} class={s}", .{ op, code, classifyCurlExitCode(code) });
    }
}

fn logCurlWaitFailure(op: []const u8, err: anyerror, stderr_msg: ?[]const u8) void {
    if (stderr_msg) |msg| {
        log.err("curl {s} child.wait failed: {} stderr={s}", .{ op, err, msg });
    } else {
        log.err("curl {s} child.wait failed: {}", .{ op, err });
    }
}

pub fn setThreadInterruptFlag(flag: ?*const AtomicBool) void {
    thread_interrupt_flag = flag;
}

pub fn currentThreadInterruptFlag() ?*const AtomicBool {
    return thread_interrupt_flag;
}

pub const CancelWatcherCtx = struct {
    child: *std_compat.process.Child,
    cancel_flag: *const AtomicBool,
    done: *AtomicBool,
};

pub fn cancelWatcherMain(ctx: *CancelWatcherCtx) void {
    while (!ctx.done.load(.acquire)) {
        if (ctx.cancel_flag.load(.acquire)) {
            if (comptime @import("builtin").os.tag == .windows) {
                _ = ctx.child.kill() catch {};
            } else {
                std.posix.kill(ctx.child.id, std.posix.SIG.TERM) catch {};
            }
            break;
        }
        std_compat.thread.sleep(20 * std.time.ns_per_ms);
    }
}

pub fn stopCancelWatcher(done: *AtomicBool, watcher: *?std.Thread) void {
    done.store(true, .release);
    if (watcher.*) |thread| {
        thread.join();
        watcher.* = null;
    }
}

/// Spawn the watcher that kills `child` when the current thread's agent
/// interrupt flag (installed by the agent around a provider call) is raised.
///
/// `done`, `watcher`, and `ctx` are caller-owned storage that must outlive the
/// watcher; pair with `stopCancelWatcher`. A no-op leaving `watcher` null when
/// no interrupt flag is installed on this thread.
pub fn spawnCancelWatcher(
    child: *std_compat.process.Child,
    done: *AtomicBool,
    watcher: *?std.Thread,
    ctx: *CancelWatcherCtx,
) void {
    const flag = thread_interrupt_flag orelse return;
    ctx.* = .{ .child = child, .cancel_flag = flag, .done = done };
    watcher.* = std.Thread.spawn(.{}, cancelWatcherMain, .{ctx}) catch null;
}

/// True when the agent /stop raised the interrupt flag on this thread. The curl
/// transports check it between stream deltas so a stop aborts the in-flight
/// request instead of draining everything the provider already buffered.
pub fn interruptRequested() bool {
    const flag = thread_interrupt_flag orelse return false;
    return flag.load(.acquire);
}

/// Stop the cancel watcher, then kill and reap the curl child. The watcher must
/// be joined before `wait()` clears `child.id`, or a reused PID could be
/// signalled.
pub fn stopCancelWatcherAndReap(
    child: *std_compat.process.Child,
    done: *AtomicBool,
    watcher: *?std.Thread,
) void {
    stopCancelWatcher(done, watcher);
    _ = child.kill() catch {};
    _ = child.wait() catch {};
}

fn abortCurlChild(
    child: *std_compat.process.Child,
    cancel_done: *AtomicBool,
    cancel_watcher: *?std.Thread,
    stderr_thread: *?std.Thread,
    stderr_capture: *const StderrCapture,
) void {
    stopCancelWatcher(cancel_done, cancel_watcher);
    _ = child.kill() catch {};
    _ = finishStderrCapture(stderr_thread, stderr_capture);
    _ = child.wait() catch {};
}

pub const HttpResponse = struct {
    status_code: u16,
    body: []u8,
};

pub const HttpResponseWithHeaders = struct {
    status_code: u16,
    headers: []u8,
    body: []u8,
    /// Only set by `truncate_response` requests: the body was cut at the cap.
    truncated: bool = false,
};

fn headerName(header: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, header, ':') orelse return header;
    return std.mem.trim(u8, header[0..colon], " \t\r\n");
}

fn isCredentialHeader(header: []const u8) bool {
    const name = headerName(header);
    return std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "x-api-key") or
        std.ascii.eqlIgnoreCase(name, "api-key") or
        std.ascii.eqlIgnoreCase(name, "x-goog-api-key") or
        std.ascii.eqlIgnoreCase(name, "anthropic-api-key") or
        std.ascii.eqlIgnoreCase(name, "cookie");
}

fn hasCredentialedCurlArgs(url: []const u8, headers: []const []const u8) bool {
    if (hasSensitiveUrlToken(url)) return true;
    for (headers) |header| {
        if (isCredentialHeader(header)) return true;
    }
    return false;
}

fn hasSensitiveUrlToken(url: []const u8) bool {
    const query_start = std.mem.indexOfScalar(u8, url, '?') orelse return false;
    var query = url[query_start + 1 ..];
    while (query.len > 0) {
        const amp = std.mem.indexOfScalar(u8, query, '&') orelse query.len;
        const pair = query[0..amp];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = pair[0..eq];
        if (std.ascii.eqlIgnoreCase(key, "key") or
            std.ascii.eqlIgnoreCase(key, "api_key") or
            std.ascii.eqlIgnoreCase(key, "apikey") or
            std.ascii.eqlIgnoreCase(key, "access_token") or
            std.ascii.eqlIgnoreCase(key, "token") or
            std.ascii.eqlIgnoreCase(key, "auth_token"))
        {
            return true;
        }
        if (amp >= query.len) break;
        query = query[amp + 1 ..];
    }
    return false;
}

pub fn validateNoCredentialedCurlArgs(url: []const u8, headers: []const []const u8) CredentialedCurlArgError!void {
    if (hasSensitiveUrlToken(url)) return error.CredentialedCurlArgRejected;
    for (headers) |header| {
        if (isCredentialHeader(header)) return error.CredentialedCurlArgRejected;
    }
}

pub const CurlHeaderArg = struct {
    arg: ?[]const u8 = null,
    temp_path_buf: [std_compat.fs.max_path_bytes]u8 = undefined,
    temp_path_len: usize = 0,
    uses_temp_file: bool = false,

    pub fn deinit(self: *const CurlHeaderArg, allocator: Allocator) void {
        if (!self.uses_temp_file) return;
        std_compat.fs.deleteFileAbsolute(self.temp_path_buf[0..self.temp_path_len]) catch {};
        if (self.arg) |arg| allocator.free(arg);
    }
};

fn validateCurlHeaderLine(header: []const u8) !void {
    if (std.mem.indexOfAny(u8, header, "\r\n\x00") != null) return error.InvalidHeader;
}

pub fn prepareCurlHeaderArg(allocator: Allocator, headers: []const []const u8) !CurlHeaderArg {
    if (headers.len == 0) return .{};

    var prepared: CurlHeaderArg = .{};
    const tmp_dir_path = platform.getTempDir(allocator) catch return error.TempDirNotFound;
    defer allocator.free(tmp_dir_path);

    var tmp_dir = std_compat.fs.openDirAbsolute(tmp_dir_path, .{}) catch return error.TempDirNotFound;
    defer tmp_dir.close();

    var tmp_file = blk: {
        var attempt: u8 = 0;
        while (attempt < 8) : (attempt += 1) {
            const header_path = std.fmt.bufPrint(
                &prepared.temp_path_buf,
                "{s}{s}curl_headers_{x}.tmp",
                .{ tmp_dir_path, std_compat.fs.path.sep_str, std_compat.crypto.random.int(u64) },
            ) catch return error.PathTooLong;
            prepared.temp_path_len = header_path.len;

            break :blk tmp_dir.createFile(
                header_path[tmp_dir_path.len + 1 ..],
                .{ .truncate = true, .exclusive = true, .permissions = std_compat.fs.permissionsFromMode(0o600) },
            ) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return error.TempFileCreateFailed,
            };
        }
        return error.TempFileCreateFailed;
    };
    errdefer std_compat.fs.deleteFileAbsolute(prepared.temp_path_buf[0..prepared.temp_path_len]) catch {};

    for (headers) |header| {
        validateCurlHeaderLine(header) catch {
            tmp_file.close();
            return error.InvalidHeader;
        };
        tmp_file.writeAll(header) catch {
            tmp_file.close();
            return error.TempFileWriteFailed;
        };
        tmp_file.writeAll("\n") catch {
            tmp_file.close();
            return error.TempFileWriteFailed;
        };
    }
    tmp_file.close();

    for (prepared.temp_path_buf[0..prepared.temp_path_len]) |*c| {
        if (c.* == '\\') c.* = '/';
    }

    prepared.arg = try std.fmt.allocPrint(allocator, "@{s}", .{prepared.temp_path_buf[0..prepared.temp_path_len]});
    prepared.uses_temp_file = true;
    return prepared;
}

const CurlTempPath = struct {
    path_buf: [std_compat.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    fn path(self: *const CurlTempPath) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn deinit(self: *CurlTempPath) void {
        if (self.path_len == 0) return;
        std_compat.fs.deleteFileAbsolute(self.path()) catch {};
        self.path_len = 0;
    }
};

fn createSecureCurlTempFile(
    allocator: Allocator,
    prepared: *CurlTempPath,
    prefix: []const u8,
) !std_compat.fs.File {
    const tmp_dir_path = platform.getTempDir(allocator) catch return error.TempDirNotFound;
    defer allocator.free(tmp_dir_path);

    var tmp_dir = std_compat.fs.openDirAbsolute(tmp_dir_path, .{}) catch return error.TempDirNotFound;
    defer tmp_dir.close();

    var attempt: u8 = 0;
    while (attempt < 8) : (attempt += 1) {
        const path = std.fmt.bufPrint(
            &prepared.path_buf,
            "{s}{s}{s}_{x}.tmp",
            .{ tmp_dir_path, std_compat.fs.path.sep_str, prefix, std_compat.crypto.random.int(u64) },
        ) catch return error.PathTooLong;
        prepared.path_len = path.len;

        return tmp_dir.createFile(
            path[tmp_dir_path.len + 1 ..],
            .{ .truncate = true, .exclusive = true, .permissions = std_compat.fs.permissionsFromMode(0o600) },
        ) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return error.TempFileCreateFailed,
        };
    }
    prepared.path_len = 0;
    return error.TempFileCreateFailed;
}

fn validateHttpUrl(url: []const u8) !std.Uri {
    if (std.mem.indexOfScalar(u8, url, 0) != null or std.mem.indexOfAny(u8, url, "\r\n") != null) {
        return error.InvalidUrl;
    }
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        return error.UnsupportedUriScheme;
    }
    if (uri.host == null) return error.InvalidUrl;
    return uri;
}

fn writeCurlConfigQuoted(file: std_compat.fs.File, value: []const u8) !void {
    try file.writeAll("\"");
    for (value) |c| {
        switch (c) {
            '\\', '"' => {
                const escaped = [_]u8{ '\\', c };
                try file.writeAll(&escaped);
            },
            0...0x1f, 0x7f => return error.InvalidCurlConfigValue,
            else => {
                const byte = [_]u8{c};
                try file.writeAll(&byte);
            },
        }
    }
    try file.writeAll("\"");
}

pub const ProtectedCurlConfig = struct {
    temp: CurlTempPath = .{},

    pub fn path(self: *const ProtectedCurlConfig) []const u8 {
        return self.temp.path();
    }

    pub fn deinit(self: *ProtectedCurlConfig) void {
        self.temp.deinit();
    }
};

fn prepareCurlConfig(
    allocator: Allocator,
    url: []const u8,
    proxy: ?[]const u8,
    force_proxy: bool,
) !ProtectedCurlConfig {
    _ = try validateHttpUrl(url);

    var prepared: ProtectedCurlConfig = .{};
    var file = try createSecureCurlTempFile(allocator, &prepared.temp, "curl_request");
    errdefer prepared.deinit();
    defer file.close();

    // Config URLs still participate in curl glob expansion unless disabled.
    // One request must never fan out because a signed URL contains [] or {}.
    try file.writeAll("globoff\nurl = ");
    try writeCurlConfigQuoted(file, url);
    try file.writeAll("\n");
    if (proxy) |proxy_url| {
        try file.writeAll("proxy = ");
        try writeCurlConfigQuoted(file, proxy_url);
        try file.writeAll("\n");
        if (force_proxy) try file.writeAll("noproxy = \"\"\n");
    }
    return prepared;
}

/// Store a validated HTTP(S) URL and optional proxy outside process argv.
/// The returned mode-0600 config file must outlive curl and be deinitialized.
pub fn prepareProtectedCurlConfig(
    allocator: Allocator,
    url: []const u8,
    proxy: ?[]const u8,
) !ProtectedCurlConfig {
    return prepareCurlConfig(allocator, url, proxy, false);
}

/// Store a URL with the effective process proxy policy. Environment proxies
/// continue to honor NO_PROXY; an explicit process-wide config override does
/// not, matching ProxyHttpClient semantics.
pub fn prepareProtectedCurlConfigFromEnvironment(
    allocator: Allocator,
    url: []const u8,
) !ProtectedCurlConfig {
    var selected_proxy = try getProxyForUrl(allocator, url);
    defer selected_proxy.deinit(allocator);
    return prepareCurlConfig(allocator, url, selected_proxy.value, selected_proxy.force);
}

pub const CurlRequestOptions = struct {
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8 = null,
    headers: []const []const u8 = &.{},
    content_type: ?[]const u8 = null,
    proxy: ?[]const u8 = null,
    max_time: ?[]const u8 = null,
    max_response_bytes: usize = std.math.maxInt(usize),
    max_redirects: ?u16 = null,
    resolve_entry: ?[]const u8 = null,
    accept_compression: bool = false,
    discard_response_body: bool = false,
    response_writer: ?*std.Io.Writer = null,
    std_http_defaults: bool = false,
    generated_redirect_headers_only: bool = false,
    fail_on_http_error: bool = false,
    /// Return the first `max_response_bytes` of an oversized body instead of
    /// `error.CurlReadError`. Only web_fetch opts in; every other caller keeps
    /// the reject-on-oversize contract.
    truncate_response: bool = false,
};

const CurlRequestSpec = CurlRequestOptions;

const CurlCommand = struct {
    argv: [40][]const u8 = undefined,
    argc: usize = 0,

    fn append(self: *CurlCommand, arg: []const u8) !void {
        if (self.argc >= self.argv.len) return error.CurlArgsOverflow;
        self.argv[self.argc] = arg;
        self.argc += 1;
    }

    fn slice(self: *const CurlCommand) []const []const u8 {
        return self.argv[0..self.argc];
    }
};

fn buildSecureCurlCommand(
    spec: CurlRequestSpec,
    config_path: []const u8,
    header_arg: ?[]const u8,
    response_headers_path: []const u8,
    max_redirects: ?[]const u8,
    ca_path: ?[]const u8,
) !CurlCommand {
    var command: CurlCommand = .{};
    try command.append("curl");
    // Must be curl's first option so a user-controlled .curlrc cannot weaken
    // protocol or TLS behavior or redirect request data elsewhere.
    try command.append("-q");
    try command.append("--silent");
    try command.append("--show-error");
    try command.append("--globoff");
    try command.append("--proto");
    try command.append("=http,https");
    try command.append("--proto-redir");
    try command.append("=http,https");
    if (spec.fail_on_http_error) try command.append("--fail");
    if (spec.accept_compression) try command.append("--compressed");
    try command.append("--request");
    try command.append(@tagName(spec.method));

    if (spec.method == .HEAD) try command.append("--head");
    if (header_arg) |arg| {
        try command.append("--header");
        try command.append(arg);
    }
    try command.append("--dump-header");
    try command.append(response_headers_path);

    if (max_redirects) |redirects| {
        try command.append("--location");
        try command.append("--max-redirs");
        try command.append(redirects);
    }
    if (spec.resolve_entry) |entry| {
        try command.append("--resolve");
        try command.append(entry);
    }
    // Android has no usable default CA store for curl; verify against the same
    // embedded Mozilla bundle the in-process TLS paths use.
    if (ca_path) |path| {
        try command.append("--cacert");
        try command.append(path);
    }
    if (spec.max_time) |max_time| {
        try command.append("--max-time");
        try command.append(max_time);
    }
    if (spec.body != null) {
        try command.append("--data-binary");
        try command.append("@-");
    }
    if (spec.discard_response_body or spec.method == .HEAD) {
        try command.append("--output");
        try command.append(if (comptime builtin.os.tag == .windows) "NUL" else "/dev/null");
    }
    try command.append("--config");
    try command.append(config_path);
    return command;
}

fn finalResponseHeaders(raw: []const u8) []const u8 {
    var start: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, raw, search_from, "HTTP/")) |candidate| {
        if (candidate == 0 or raw[candidate - 1] == '\n') start = candidate;
        search_from = candidate + "HTTP/".len;
    }
    const remaining = raw[start..];
    const crlf_end = std.mem.indexOf(u8, remaining, "\r\n\r\n");
    const lf_end = std.mem.indexOf(u8, remaining, "\n\n");
    const end = if (crlf_end) |pos| pos else if (lf_end) |pos| pos else remaining.len;
    return remaining[0..end];
}

fn responseStatusCode(headers: []const u8) !u16 {
    const line_end = std.mem.indexOfScalar(u8, headers, '\n') orelse headers.len;
    const status_line = std.mem.trim(u8, headers[0..line_end], " \t\r\n");
    var fields = std.mem.tokenizeScalar(u8, status_line, ' ');
    const protocol = fields.next() orelse return error.CurlParseError;
    if (!std.mem.startsWith(u8, protocol, "HTTP/")) return error.CurlParseError;
    const status_raw = fields.next() orelse return error.CurlParseError;
    if (status_raw.len != 3) return error.CurlParseError;
    return std.fmt.parseInt(u16, status_raw, 10) catch error.CurlParseError;
}

fn safeCurlMaxRedirects(spec: CurlRequestSpec) ?u16 {
    if (spec.method != .GET or spec.body != null or spec.content_type != null) return null;
    if (spec.headers.len != 0 and !spec.generated_redirect_headers_only) return null;
    return spec.max_redirects;
}

const CappedBody = struct {
    body: []u8,
    truncated: bool,
};

/// Longest prefix of the input that ends on a UTF-8 sequence boundary. The cap
/// may split a multi-byte code point; it is dropped whole so the returned slice
/// stays valid UTF-8 for the tool result.
fn trimToUtf8Prefix(bytes: []const u8) usize {
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] & 0xC0) == 0x80) end -= 1;
    if (end == 0) return 0;
    const lead = end - 1;
    const need = std.unicode.utf8ByteSequenceLength(bytes[lead]) catch return lead;
    // Keep the code point whole when the cap did not cut it, otherwise drop it.
    return if (lead + need <= bytes.len) lead + need else lead;
}

fn readCapped(
    allocator: Allocator,
    file: std_compat.fs.File,
    max_bytes: usize,
    truncate: bool,
) !CappedBody {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [8192]u8 = undefined;
    var truncated = false;
    while (true) {
        const n = file.read(&buf) catch return error.CurlReadError;
        if (n == 0) break;
        // Keep draining after the cut so curl never blocks on a full pipe.
        // shortcut: the rest of an oversized body is still downloaded, not
        // aborted; upgrade if bandwidth becomes a concern.
        if (truncated) continue;
        if (n > max_bytes - out.items.len) {
            if (!truncate) return error.CurlReadError;
            try out.appendSlice(allocator, buf[0 .. max_bytes - out.items.len]);
            truncated = true;
            continue;
        }
        try out.appendSlice(allocator, buf[0..n]);
    }
    const owned = try out.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    if (!truncated) return .{ .body = owned, .truncated = false };
    const end = trimToUtf8Prefix(owned);
    if (end == owned.len) return .{ .body = owned, .truncated = true };
    return .{ .body = try allocator.realloc(owned, end), .truncated = true };
}

fn streamCurlStdout(file: std_compat.fs.File, writer: ?*std.Io.Writer, max_bytes: usize) !void {
    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = file.read(&buf) catch return error.CurlReadError;
        if (n == 0) return;
        if (n > max_bytes -| total) return error.CurlReadError;
        total += n;
        if (writer) |output| try output.writeAll(buf[0..n]);
    }
}

fn maxTimeDeadlineMs(max_time: ?[]const u8) ?i64 {
    const text = max_time orelse return null;
    const secs = std.fmt.parseInt(u64, text, 10) catch return null;
    if (secs == 0) return null;
    const ms = std.math.mul(u64, secs, std.time.ms_per_s) catch std.math.maxInt(u64);
    return std_compat.time.milliTimestamp() +| @as(i64, @intCast(@min(ms, @as(u64, std.math.maxInt(i64)))));
}

fn responseBodyReader(
    allocator: Allocator,
    req: *std.http.Client.Request,
    response: *std.http.Client.Response,
    transfer_buffer: []u8,
    decompress: *std.http.Decompress,
    decompress_buffer: *[]u8,
) !*std.Io.Reader {
    switch (response.head.content_encoding) {
        .identity => return req.reader.bodyReader(transfer_buffer, response.head.transfer_encoding, response.head.content_length),
        .zstd => {
            decompress_buffer.* = try allocator.alloc(u8, std.compress.zstd.default_window_len);
            return response.readerDecompressing(transfer_buffer, decompress, decompress_buffer.*);
        },
        .deflate, .gzip => {
            decompress_buffer.* = try allocator.alloc(u8, std.compress.flate.max_window_len);
            return response.readerDecompressing(transfer_buffer, decompress, decompress_buffer.*);
        },
        .compress => return error.UnsupportedCompressionMethod,
    }
}

/// True when the body reader can make progress without touching the socket.
/// HTTP framing (chunk sizes) or TLS records may sit in the connection reader
/// while the body reader reports no decoded bytes yet.
fn bodyBuffered(req: *std.http.Client.Request, reader: *std.Io.Reader) bool {
    if (reader.bufferedLen() > 0) return true;
    const conn = req.connection orelse return false;
    return conn.reader().bufferedLen() > 0;
}

/// HTTP bodies that are known empty before reading: HEAD/TRACE responses and
/// 204/304 statuses end at the head, and `Content-Length: 0` frames no bytes.
/// Reading them would otherwise poll a socket that never becomes readable.
fn hasResponseBody(
    method: std.http.Method,
    status: std.http.Status,
    transfer_encoding: std.http.TransferEncoding,
    content_length: ?u64,
) bool {
    if (!method.responseHasBody()) return false;
    if (status == .no_content or status == .not_modified) return false;
    if (transfer_encoding == .none) {
        if (content_length) |len| return len != 0;
    }
    return true;
}

fn waitBodyReadable(
    req: *std.http.Client.Request,
    reader: *std.Io.Reader,
    timeout_ms: i32,
) anyerror!bool {
    if (bodyBuffered(req, reader)) return true;
    const conn = req.connection orelse return error.ConnectionClosed;
    if (comptime builtin.os.tag == .windows) {
        if (timeout_ms > 0) std_compat.thread.sleep(@as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms);
        return bodyBuffered(req, reader);
    }
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = conn.stream_reader.stream.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = undefined,
    }};
    const events = std.posix.poll(&poll_fds, timeout_ms) catch return error.CurlReadError;
    if (events == 0) return false;
    const revents = poll_fds[0].revents;
    if (revents & std.posix.POLL.IN != 0) return true;
    if (revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
        return error.CurlReadError;
    }
    return false;
}

fn bodyReadError(response: *std.http.Client.Response, err: anyerror) anyerror {
    if (interruptRequested()) return error.CurlInterrupted;
    if (response.bodyErr()) |body_err| {
        if (body_err == error.Timeout) return error.CurlTimeout;
    }
    return switch (err) {
        error.Canceled => error.CurlInterrupted,
        else => error.CurlReadError,
    };
}

const StdHttpBodyResult = struct {
    body: []u8,
    truncated: bool,
};

/// Read a std.http body with the curl executor's limits: `max_response_bytes`
/// is a hard cap unless `truncate_response`, `max_time` bounds the whole read,
/// `/stop` aborts between chunks, and `response_writer` streams instead of
/// buffering.
fn readStdHttpBody(
    allocator: Allocator,
    req: *std.http.Client.Request,
    response: *std.http.Client.Response,
    spec: CurlRequestSpec,
    deadline_ms: ?i64,
) !StdHttpBodyResult {
    if (!hasResponseBody(
        spec.method,
        response.head.status,
        response.head.transfer_encoding,
        response.head.content_length,
    )) {
        return .{ .body = try allocator.dupe(u8, ""), .truncated = false };
    }
    var transfer_buffer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buffer: []u8 = &.{};
    defer if (decompress_buffer.len != 0) allocator.free(decompress_buffer);
    const reader = try responseBodyReader(allocator, req, response, &transfer_buffer, &decompress, &decompress_buffer);

    const discard = spec.discard_response_body or spec.method == .HEAD;
    const cap = spec.max_response_bytes;
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    var total: usize = 0;
    var truncated = false;

    while (true) {
        if (interruptRequested()) return error.CurlInterrupted;
        if (reader.bufferedLen() > 0) {
            const chunk = reader.take(@min(reader.bufferedLen(), 8192)) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return bodyReadError(response, err),
            };
            if (chunk.len == 0) break;
            if (discard) continue;
            if (chunk.len > cap - total) {
                if (!spec.truncate_response) return error.CurlReadError;
                truncated = true;
                try emitStdHttpChunk(allocator, spec, &output, chunk[0 .. cap - total]);
                total = cap;
                break;
            }
            try emitStdHttpChunk(allocator, spec, &output, chunk);
            total += chunk.len;
            continue;
        }

        var poll_ms: i32 = 1000;
        if (deadline_ms) |deadline| {
            const remaining = deadline - std_compat.time.milliTimestamp();
            if (remaining <= 0) return error.CurlTimeout;
            poll_ms = @intCast(@min(remaining, 1000));
        }
        const readable = try waitBodyReadable(req, reader, poll_ms);
        if (!readable) {
            if (deadline_ms) |deadline| {
                if (std_compat.time.milliTimestamp() >= deadline) return error.CurlTimeout;
            }
            continue;
        }
        const first = reader.take(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return bodyReadError(response, err),
        };
        if (first.len == 0) break;
        if (discard) continue;
        if (total == cap) {
            if (!spec.truncate_response) return error.CurlReadError;
            truncated = true;
            break;
        }
        try emitStdHttpChunk(allocator, spec, &output, first);
        total += first.len;
    }

    return .{
        .body = if (spec.response_writer != null or discard)
            try allocator.dupe(u8, "")
        else
            try output.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

fn emitStdHttpChunk(
    allocator: Allocator,
    spec: CurlRequestSpec,
    output: *std.ArrayListUnmanaged(u8),
    chunk: []const u8,
) !void {
    if (spec.response_writer) |writer| {
        try writer.writeAll(chunk);
    } else {
        try output.appendSlice(allocator, chunk);
    }
}

/// Common byte source for provider SSE loops: curl stdout off Android, an
/// std.http response body on Android. `finish` implements the post-EOF status
/// mapping each transport needs; `abort` stops an in-flight transfer.
pub const ByteStream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Set by curl sources; Codex maps specific exit codes to transport errors.
    exit_code: ?*const ?u8 = null,

    pub const VTable = struct {
        read: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,
        abort: *const fn (ptr: *anyopaque) void,
        finish: *const fn (ptr: *anyopaque) anyerror!void,
    };

    pub fn read(self: ByteStream, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ptr, buf);
    }

    pub fn abort(self: ByteStream) void {
        self.vtable.abort(self.ptr);
    }

    pub fn finish(self: ByteStream) anyerror!void {
        return self.vtable.finish(self.ptr);
    }
};

/// ByteStream over a spawned curl child's stdout. Keeps the interrupt watcher
/// semantics of the existing provider loops.
pub const CurlByteStream = struct {
    child: *std_compat.process.Child,
    cancel_done: AtomicBool = .init(false),
    cancel_watcher: ?std.Thread = null,
    cancel_ctx: CancelWatcherCtx = undefined,
    exit_code: ?u8 = null,

    pub fn init(self: *CurlByteStream, child: *std_compat.process.Child) void {
        self.* = .{ .child = child };
        spawnCancelWatcher(child, &self.cancel_done, &self.cancel_watcher, &self.cancel_ctx);
    }

    pub fn deinit(self: *CurlByteStream) void {
        stopCancelWatcher(&self.cancel_done, &self.cancel_watcher);
    }

    pub fn stream(self: *CurlByteStream) ByteStream {
        return .{ .ptr = self, .vtable = &vtable, .exit_code = &self.exit_code };
    }

    const vtable: ByteStream.VTable = .{
        .read = read,
        .abort = abortPtr,
        .finish = finish,
    };

    fn read(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *CurlByteStream = @ptrCast(@alignCast(ptr));
        return self.child.stdout.?.read(buf);
    }

    pub fn abort(self: *CurlByteStream) void {
        abortPtr(self);
    }

    fn abortPtr(ptr: *anyopaque) void {
        const self: *CurlByteStream = @ptrCast(@alignCast(ptr));
        stopCancelWatcherAndReap(self.child, &self.cancel_done, &self.cancel_watcher);
    }

    fn finish(ptr: *anyopaque) anyerror!void {
        const self: *CurlByteStream = @ptrCast(@alignCast(ptr));
        stopCancelWatcher(&self.cancel_done, &self.cancel_watcher);
        const term = self.child.wait() catch return error.CurlWaitError;
        switch (term) {
            .exited => |code| {
                self.exit_code = code;
                if (code == 0) return;
            },
            else => {},
        }
        return error.CurlFailed;
    }
};

const STREAM_IDLE_TIMEOUT_MS: i64 = 60_000;

/// std.http streaming POST used by provider SSE loops on Android. Buffered
/// variants use `stdHttpRequest`; this keeps the body unread so callers parse
/// deltas as they arrive. Poll-based reads preserve `timeout_secs` and the
/// 60-second stall bound curl had, and check the agent interrupt flag.
pub const HttpStream = struct {
    allocator: Allocator,
    http: ProxyHttpClient,
    request: std.http.Client.Request,
    reader: *std.Io.Reader,
    transfer_buffer: [4096]u8,
    decompress: std.http.Decompress,
    decompress_buffer: []u8,
    headers: std.ArrayListUnmanaged(std.http.Header) = .empty,
    status_code: u16,
    body_available: bool = true,
    deadline_ms: ?i64,
    idle_deadline_ms: i64,
    failed: ?anyerror = null,

    pub fn open(
        allocator: Allocator,
        url: []const u8,
        headers: []const []const u8,
        body: []const u8,
        timeout_secs: u64,
    ) !*HttpStream {
        _ = try validateHttpUrl(url);
        try validateStdProxyForUrl(allocator, url, null);
        const self = try allocator.create(HttpStream);
        errdefer allocator.destroy(self);
        const now = std_compat.time.milliTimestamp();
        self.* = .{
            .allocator = allocator,
            .http = try ProxyHttpClient.init(allocator),
            .request = undefined,
            .reader = undefined,
            .transfer_buffer = undefined,
            .decompress = undefined,
            .decompress_buffer = &.{},
            .status_code = 0,
            .deadline_ms = if (timeout_secs == 0) null else now +| @as(i64, @intCast(@min(
                std.math.mul(u64, timeout_secs, std.time.ms_per_s) catch std.math.maxInt(u64),
                @as(u64, std.math.maxInt(i64)),
            ))),
            .idle_deadline_ms = now +| STREAM_IDLE_TIMEOUT_MS,
        };
        errdefer self.http.deinit();
        errdefer self.headers.deinit(allocator);

        for (headers) |header| {
            try validateCurlHeaderLine(header);
            try self.headers.append(allocator, parseHeader(header) orelse return error.InvalidHeader);
        }

        const uri = try std.Uri.parse(url);
        self.request = try self.http.client.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            // curl's SSE calls did not request compression; keep the body
            // unframed by a decompressor.
            .headers = .{ .accept_encoding = .omit },
            .extra_headers = self.headers.items,
        });
        errdefer self.request.deinit();

        self.request.transfer_encoding = .{ .content_length = body.len };
        var request_body = try self.request.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(body);
        try request_body.end();
        try self.request.connection.?.flush();

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try self.request.receiveHead(&redirect_buffer);
        self.status_code = @intFromEnum(response.head.status);
        self.body_available = hasResponseBody(
            .POST,
            response.head.status,
            response.head.transfer_encoding,
            response.head.content_length,
        );
        errdefer if (self.decompress_buffer.len != 0) allocator.free(self.decompress_buffer);
        self.reader = try responseBodyReader(
            allocator,
            &self.request,
            &response,
            &self.transfer_buffer,
            &self.decompress,
            &self.decompress_buffer,
        );
        return self;
    }

    pub fn deinit(self: *HttpStream) void {
        self.request.deinit();
        self.http.deinit();
        self.headers.deinit(self.allocator);
        if (self.decompress_buffer.len != 0) self.allocator.free(self.decompress_buffer);
        self.allocator.destroy(self);
    }

    pub fn stream(self: *HttpStream) ByteStream {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: ByteStream.VTable = .{
        .read = read,
        .abort = abort,
        .finish = finish,
    };

    fn read(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *HttpStream = @ptrCast(@alignCast(ptr));
        if (buf.len == 0) return 0;
        if (!self.body_available) return 0;
        while (true) {
            if (interruptRequested()) return self.fail(error.Interrupted);
            if (self.reader.bufferedLen() > 0) {
                const n = @min(buf.len, self.reader.bufferedLen());
                const chunk = self.reader.take(n) catch |err| return self.fail(err);
                if (chunk.len == 0) return 0;
                @memcpy(buf[0..chunk.len], chunk);
                self.touch();
                return chunk.len;
            }

            var poll_ms: i32 = 1000;
            if (self.deadline_ms) |deadline| {
                const remaining = deadline - std_compat.time.milliTimestamp();
                if (remaining <= 0) return self.fail(error.CurlTimeout);
                poll_ms = @intCast(@min(remaining, 1000));
            }
            const idle_remaining = self.idle_deadline_ms - std_compat.time.milliTimestamp();
            if (idle_remaining <= 0) return self.fail(error.CurlTimeout);
            poll_ms = @min(poll_ms, @as(i32, @intCast(@max(idle_remaining, 1))));

            const readable = waitBodyReadable(&self.request, self.reader, poll_ms) catch |err| return self.fail(err);
            if (!readable) continue;

            const first = self.reader.take(1) catch |err| switch (err) {
                error.EndOfStream => return 0,
                else => return self.fail(err),
            };
            if (first.len == 0) return 0;
            buf[0] = first[0];
            var n: usize = 1;
            while (n < buf.len and self.reader.bufferedLen() > 0) {
                const chunk = self.reader.take(@min(buf.len - n, self.reader.bufferedLen())) catch break;
                if (chunk.len == 0) break;
                @memcpy(buf[n..][0..chunk.len], chunk);
                n += chunk.len;
            }
            self.touch();
            return n;
        }
    }

    fn abort(_: *anyopaque) void {}

    fn finish(ptr: *anyopaque) anyerror!void {
        const self: *HttpStream = @ptrCast(@alignCast(ptr));
        if (self.failed) |err| return switch (err) {
            error.CurlTimeout => error.CurlTimeout,
            error.Interrupted => error.Interrupted,
            else => error.CurlFailed,
        };
        if (self.status_code >= 400) return error.CurlFailed;
    }

    fn touch(self: *HttpStream) void {
        self.idle_deadline_ms = std_compat.time.milliTimestamp() +| STREAM_IDLE_TIMEOUT_MS;
    }

    fn fail(self: *HttpStream, err: anyerror) anyerror {
        const mapped = switch (err) {
            error.Canceled, error.Interrupted => error.Interrupted,
            error.Timeout, error.CurlTimeout => error.CurlTimeout,
            else => error.CurlReadError,
        };
        self.failed = mapped;
        return mapped;
    }
};

/// std.http replacement for the curl executor on Android. The curl-specific
/// fields (resolve pinning, generated redirect headers) do not apply: Android
/// has no curl binary, and `compat.net.httpIo` resolves every hop through
/// bionic. The URL was already validated by net_security at the call site.
fn stdHttpRequest(allocator: Allocator, spec: CurlRequestSpec) !HttpResponseWithHeaders {
    _ = try validateHttpUrl(spec.url);
    try validateStdProxyForUrl(allocator, spec.url, spec.proxy);
    const uri = try std.Uri.parse(spec.url);

    var header_list: std.ArrayListUnmanaged(std.http.Header) = .empty;
    defer header_list.deinit(allocator);
    if (spec.content_type) |content_type| {
        if (content_type.len == 0 or std.mem.indexOfAny(u8, content_type, "\r\n\x00") != null) return error.InvalidHeader;
        try header_list.append(allocator, .{ .name = "Content-Type", .value = content_type });
    }
    for (spec.headers) |header| {
        try validateCurlHeaderLine(header);
        try header_list.append(allocator, parseHeader(header) orelse return error.InvalidHeader);
    }

    var client = try initProxyClientWithOptionalProxy(allocator, spec.proxy);
    defer client.deinit();

    const redirect_behavior: std.http.Client.Request.RedirectBehavior =
        if (spec.max_redirects) |max| @enumFromInt(max) else .unhandled;
    var req = try client.client.request(spec.method, uri, .{
        .redirect_behavior = redirect_behavior,
        .headers = .{ .accept_encoding = if (spec.accept_compression) .default else .omit },
        .extra_headers = header_list.items,
    });
    defer req.deinit();

    if (spec.body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var request_body = try req.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(payload);
        try request_body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const status_code: u16 = @intFromEnum(response.head.status);
    if (spec.fail_on_http_error and status_code >= 400) return error.CurlFailed;
    const response_headers = try allocator.dupe(u8, response.head.bytes);
    errdefer allocator.free(response_headers);

    const result = try readStdHttpBody(allocator, &req, &response, spec, maxTimeDeadlineMs(spec.max_time));
    errdefer allocator.free(result.body);
    if (spec.response_writer) |writer| try writer.flush();

    return .{
        .status_code = status_code,
        .headers = response_headers,
        .body = result.body,
        .truncated = result.truncated,
    };
}

fn secureCurlRequestWithStatusAndHeaders(
    allocator: Allocator,
    spec: CurlRequestSpec,
) !HttpResponseWithHeaders {
    if (comptime stdHttpTransport(builtin.abi)) return stdHttpRequest(allocator, spec);

    _ = try validateHttpUrl(spec.url);

    var all_headers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_headers.deinit(allocator);
    var content_type_header: ?[]u8 = null;
    defer if (content_type_header) |header| allocator.free(header);
    var has_content_type = false;

    if (spec.std_http_defaults) {
        try all_headers.append(allocator, STD_HTTP_USER_AGENT_HEADER);
        try all_headers.append(allocator, STD_HTTP_ACCEPT_ENCODING_HEADER);
    }

    if (spec.content_type) |content_type| {
        if (content_type.len == 0 or std.mem.indexOfAny(u8, content_type, "\r\n\x00") != null) {
            return error.InvalidHeader;
        }
        content_type_header = try std.fmt.allocPrint(allocator, "Content-Type: {s}", .{content_type});
        try all_headers.append(allocator, content_type_header.?);
        has_content_type = true;
    }
    for (spec.headers) |header| {
        try validateCurlHeaderLine(header);
        const parsed = parseHeader(header) orelse return error.InvalidHeader;
        has_content_type = has_content_type or std.ascii.eqlIgnoreCase(parsed.name, "content-type");
        try all_headers.append(allocator, header);
    }
    // curl otherwise invents application/x-www-form-urlencoded for --data-binary,
    // while std.http sends no Content-Type when the caller leaves it at default.
    if (spec.body != null and !has_content_type) try all_headers.append(allocator, "Content-Type:");

    var selected_proxy = if (spec.proxy == null) try getProxyForUrl(allocator, spec.url) else ProxySelection{};
    defer selected_proxy.deinit(allocator);
    const effective_proxy = spec.proxy orelse selected_proxy.value;

    var config = try prepareCurlConfig(allocator, spec.url, effective_proxy, spec.proxy != null or selected_proxy.force);
    defer config.deinit();

    var prepared_headers = try prepareCurlHeaderArg(allocator, all_headers.items);
    defer prepared_headers.deinit(allocator);

    var response_headers_temp: CurlTempPath = .{};
    var response_headers_file = try createSecureCurlTempFile(allocator, &response_headers_temp, "curl_response_headers");
    response_headers_file.close();
    defer response_headers_temp.deinit();

    var redirects_buf: [5]u8 = undefined;
    const redirects_arg = if (safeCurlMaxRedirects(spec)) |max_redirects|
        try std.fmt.bufPrint(&redirects_buf, "{d}", .{max_redirects})
    else
        null;
    // curl only takes a CA bundle by path, and Android's default store is not
    // usable, so spill the embedded bundle to a 0600 temp file per request.
    var ca_temp: CurlTempPath = .{};
    defer ca_temp.deinit();
    const ca_path: ?[]const u8 = if (comptime builtin.abi == .android) ca_file: {
        var file = try createSecureCurlTempFile(allocator, &ca_temp, "curl_ca_bundle");
        defer file.close();
        try file.writeAll(tls_ca.embeddedPem());
        break :ca_file ca_temp.path();
    } else null;
    const command = try buildSecureCurlCommand(
        spec,
        config.path(),
        prepared_headers.arg,
        response_headers_temp.path(),
        redirects_arg,
        ca_path,
    );

    var child = std_compat.process.Child.init(command.slice(), allocator);
    if (spec.body != null) child.stdin_behavior = .Pipe;
    // Keep a pipe even when curl writes the body to /dev/null. Draining it to
    // EOF lets us stop the cancellation watcher before child.wait() touches id.
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const cancel_flag = thread_interrupt_flag;
    var cancel_done = AtomicBool.init(false);
    var cancel_watcher: ?std.Thread = null;
    var watcher_ctx: CancelWatcherCtx = undefined;
    if (cancel_flag) |flag| {
        watcher_ctx = .{ .child = &child, .cancel_flag = flag, .done = &cancel_done };
        cancel_watcher = std.Thread.spawn(.{}, cancelWatcherMain, .{&watcher_ctx}) catch null;
    }
    defer stopCancelWatcher(&cancel_done, &cancel_watcher);

    var stderr_capture = StderrCapture{};
    var stderr_thread = startStderrCapture(&child, &stderr_capture);
    defer if (stderr_thread) |thread| thread.join();

    if (spec.body) |body| {
        if (child.stdin) |stdin_file| {
            stdin_file.writeAll(body) catch {
                stdin_file.close();
                child.stdin = null;
                abortCurlChild(&child, &cancel_done, &cancel_watcher, &stderr_thread, &stderr_capture);
                return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWriteError;
            };
            stdin_file.close();
            child.stdin = null;
        } else {
            abortCurlChild(&child, &cancel_done, &cancel_watcher, &stderr_thread, &stderr_capture);
            return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWriteError;
        }
    }

    var buffered_body: ?[]u8 = null;
    var response_truncated = false;
    errdefer if (buffered_body) |body| allocator.free(body);
    if (spec.discard_response_body or spec.method == .HEAD) {
        streamCurlStdout(child.stdout.?, null, 0) catch |err| {
            abortCurlChild(&child, &cancel_done, &cancel_watcher, &stderr_thread, &stderr_capture);
            return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else err;
        };
    } else {
        if (spec.response_writer) |writer| {
            streamCurlStdout(child.stdout.?, writer, spec.max_response_bytes) catch |err| {
                abortCurlChild(&child, &cancel_done, &cancel_watcher, &stderr_thread, &stderr_capture);
                return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else err;
            };
        } else {
            // Regression: readToEndAlloc(allocator, .limited(n)) reported
            // StreamTooLong for a body exactly n bytes long; read one byte at a
            // time through readCapped so a body at the cap succeeds.
            const capped = readCapped(
                allocator,
                child.stdout.?,
                spec.max_response_bytes,
                spec.truncate_response,
            ) catch |err| {
                abortCurlChild(&child, &cancel_done, &cancel_watcher, &stderr_thread, &stderr_capture);
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else err;
            };
            buffered_body = capped.body;
            response_truncated = capped.truncated;
        }
    }

    // Both output pipes reached EOF, so curl has closed them and is exiting.
    // Join their readers and the watcher before wait() can clear/reuse child.id.
    const stderr_msg = finishStderrCapture(&stderr_thread, &stderr_capture);
    stopCancelWatcher(&cancel_done, &cancel_watcher);
    const term = child.wait() catch |err| {
        _ = child.kill() catch {};
        // curl diagnostics may echo credentialed proxy/URL values. Keep the
        // captured bytes only for synchronization; never write them to logs.
        _ = stderr_msg;
        logCurlWaitFailure(@tagName(spec.method), err, null);
        return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWaitError;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            logCurlExitFailure(@tagName(spec.method), code, null);
            return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else mapCurlExitCodeToError(code);
        },
        else => return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlFailed,
    }

    const headers_file = try std_compat.fs.openFileAbsolute(response_headers_temp.path(), .{});
    defer headers_file.close();
    const raw_headers = try headers_file.readToEndAlloc(allocator, MAX_CURL_RESPONSE_HEADERS_BYTES);
    defer allocator.free(raw_headers);
    const final_headers = finalResponseHeaders(raw_headers);
    const status_code = try responseStatusCode(final_headers);
    const response_headers = try allocator.dupe(u8, final_headers);
    errdefer allocator.free(response_headers);
    const response_body = buffered_body orelse try allocator.dupe(u8, "");
    buffered_body = null;

    return .{
        .status_code = status_code,
        .headers = response_headers,
        .body = response_body,
        .truncated = response_truncated,
    };
}

/// Execute a buffered curl request with URL, proxy, and headers kept out of
/// process argv. Automatic redirects are restricted to header-free GETs.
pub fn curlRequestWithStatusAndHeaders(
    allocator: Allocator,
    options: CurlRequestOptions,
) !HttpResponseWithHeaders {
    return secureCurlRequestWithStatusAndHeaders(allocator, options);
}

/// Whether HTTP transport on `abi` uses std.http instead of the curl
/// subprocess. Android embeds no curl binary: phase 1 supplied a libc DNS hook
/// (compat.net) and embedded Mozilla CAs, so provider, OAuth, embedding, and
/// tool requests all go through std.http there. Other ABIs keep curl.
pub fn stdHttpTransport(comptime abi: std.Target.Abi) bool {
    return abi == .android;
}

/// True when curl subprocesses remain the transport for `abi`. On Android the
/// secure executor swaps its body for `stdHttpRequest`, so every caller keeps
/// its timeout, size cap, and credential handling without a curl binary.
pub fn usesCurlTransport(comptime abi: std.Target.Abi) bool {
    return !stdHttpTransport(abi);
}

fn credentialedCurlUsesHttpFallbackFor(
    comptime abi: std.Target.Abi,
    url: []const u8,
    headers: []const []const u8,
    resolve_entry: ?[]const u8,
) bool {
    // Android's Android-branch in secureCurlRequestWithStatusAndHeaders keeps
    // the full spec (timeouts, caps); do not divert to the lossier wrapper.
    if (!usesCurlTransport(abi)) return false;
    return hasCredentialedCurlArgs(url, headers) and resolve_entry == null;
}

fn credentialedCurlUsesHttpFallback(url: []const u8, headers: []const []const u8, resolve_entry: ?[]const u8) bool {
    return credentialedCurlUsesHttpFallbackFor(builtin.abi, url, headers, resolve_entry);
}

fn parseHeader(header: []const u8) ?std.http.Header {
    const colon = std.mem.indexOfScalar(u8, header, ':') orelse return null;
    const name = std.mem.trim(u8, header[0..colon], " \t\r\n");
    const value = std.mem.trim(u8, header[colon + 1 ..], " \t\r\n");
    if (name.len == 0) return null;
    return .{ .name = name, .value = value };
}

fn contentTypeHeaderValue(header: []const u8) ?[]const u8 {
    const parsed = parseHeader(header) orelse return null;
    if (!std.ascii.eqlIgnoreCase(parsed.name, "content-type")) return null;
    return parsed.value;
}

/// std.http understands HTTP(S) proxies only. Android has no curl fallback, so
/// fail instead of silently connecting direct when the configured proxy (flag,
/// config override, or environment) uses another scheme such as socks5.
pub fn validateStdProxyForUrl(allocator: Allocator, url: []const u8, explicit: ?[]const u8) !void {
    if (explicit) |proxy| return validateStdProxyScheme(proxy);
    var selected = try getProxyForUrl(allocator, url);
    defer selected.deinit(allocator);
    if (selected.value) |proxy| try validateStdProxyScheme(proxy);
}

fn validateStdProxyScheme(proxy: []const u8) !void {
    const uri = std.Uri.parse(proxy) catch return error.UnsupportedProxyScheme;
    if (std.http.Client.Protocol.fromScheme(uri.scheme) == null) return error.UnsupportedProxyScheme;
}

fn validateFetchProxy(allocator: Allocator, location: std.http.Client.FetchOptions.Location) !void {
    switch (location) {
        .url => |url| try validateStdProxyForUrl(allocator, url, null),
        .uri => |uri| {
            var writer: std.Io.Writer.Allocating = .init(allocator);
            defer writer.deinit();
            try uri.format(&writer.writer);
            try validateStdProxyForUrl(allocator, writer.writer.buffer[0..writer.writer.end], null);
        },
    }
}

fn initProxyClientWithOptionalProxy(allocator: Allocator, proxy: ?[]const u8) !ProxyHttpClient {
    var proxy_client = try ProxyHttpClient.init(allocator);
    if (proxy == null) return proxy_client;

    proxy_client.deinit();
    var proxy_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer proxy_arena.deinit();
    var client: std.http.Client = .{ .allocator = allocator, .io = std_compat.net.httpIo() };
    errdefer client.deinit();
    try tls_ca.configureHttpClient(&client, allocator);
    var env_map = std_compat.process.EnvMap.init(proxy_arena.allocator());
    try env_map.put("HTTPS_PROXY", proxy.?);
    try env_map.put("https_proxy", proxy.?);
    try env_map.put("HTTP_PROXY", proxy.?);
    try env_map.put("http_proxy", proxy.?);
    try client.initDefaultProxies(proxy_arena.allocator(), &env_map);
    return .{ .proxy_arena = proxy_arena, .client = client };
}

pub fn httpRequestWithStatusAndHeaders(
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    headers: []const []const u8,
    content_type: ?[]const u8,
    proxy: ?[]const u8,
) !HttpResponseWithHeaders {
    if (comptime stdHttpTransport(builtin.abi)) {
        try validateStdProxyForUrl(allocator, url, proxy);
    }
    var header_buf: [20]std.http.Header = undefined;
    var header_count: usize = 0;
    if (content_type) |ct| {
        if (ct.len == 0 or std.mem.indexOfAny(u8, ct, "\r\n\x00") != null) return error.InvalidHeader;
        header_buf[header_count] = .{ .name = "Content-Type", .value = ct };
        header_count += 1;
    }
    for (headers) |header| {
        if (header_count >= header_buf.len) return error.TooManyHeaders;
        try validateCurlHeaderLine(header);
        header_buf[header_count] = parseHeader(header) orelse return error.InvalidHeader;
        header_count += 1;
    }

    const uri = try std.Uri.parse(url);
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        return error.UnsupportedUriScheme;
    }

    var client = try initProxyClientWithOptionalProxy(allocator, proxy);
    defer client.deinit();

    const redirect_behavior: std.http.Client.Request.RedirectBehavior =
        if (body == null) @enumFromInt(3) else .unhandled;
    var req = try client.client.request(method, uri, .{
        .redirect_behavior = redirect_behavior,
        .headers = .{ .accept_encoding = .default },
        .extra_headers = header_buf[0..header_count],
    });
    defer req.deinit();

    if (body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var request_body = try req.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(payload);
        try request_body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const response_headers = try allocator.dupe(u8, response.head.bytes);
    errdefer allocator.free(response_headers);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (response.head.content_encoding != .identity) allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    const response_body = aw.writer.buffer[0..aw.writer.end];
    return .{
        .status_code = @as(u16, @intFromEnum(response.head.status)),
        .headers = response_headers,
        .body = try allocator.dupe(u8, response_body),
    };
}

pub fn httpRequestWithStatus(
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    headers: []const []const u8,
    content_type: ?[]const u8,
    proxy: ?[]const u8,
) !HttpResponse {
    const resp = try httpRequestWithStatusAndHeaders(allocator, method, url, body, headers, content_type, proxy);
    allocator.free(resp.headers);
    return .{
        .status_code = resp.status_code,
        .body = resp.body,
    };
}

pub fn httpRequest(
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    headers: []const []const u8,
    content_type: ?[]const u8,
    proxy: ?[]const u8,
) ![]u8 {
    const resp = try httpRequestWithStatus(allocator, method, url, body, headers, content_type, proxy);
    errdefer allocator.free(resp.body);
    if (resp.status_code < 200 or resp.status_code >= 300) return sendErrorForMethod(method, resp.status_code);
    return resp.body;
}

pub fn httpPostJsonWithProxy(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    proxy: ?[]const u8,
) ![]u8 {
    return httpRequest(allocator, .POST, url, body, headers, "application/json", proxy);
}

pub fn httpGetWithProxy(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    proxy: ?[]const u8,
) ![]u8 {
    return httpRequest(allocator, .GET, url, null, headers, null, proxy);
}

/// HTTP POST JSON with a hard `--max-time` bound, via the curl subprocess.
///
/// The `std.http` path has no client-side socket timeout in Zig 0.16, so a
/// request whose TCP connection is silently dropped (no FIN/RST) parks the
/// reader until the kernel's TCP keepalive fires - the incident where
/// Telegram's 30s `getUpdates` long poll froze the polling thread for the rest
/// of the process lifetime. curl's `--max-time` turns that stall into
/// `error.CurlTimeout`, which the caller can retry. `max_time` is a decimal
/// seconds string (e.g. `"45"`).
pub fn httpPostJsonWithProxyTimeout(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    proxy: ?[]const u8,
    max_time: []const u8,
) ![]u8 {
    return httpRequestWithTimeout(allocator, .POST, url, body, headers, "application/json", proxy, max_time);
}

/// Response-size cap for a bounded GET that streams large media. Telegram's
/// `getFile` serves documents up to ~20 MB (a self-hosted Bot API server more),
/// so `DEFAULT_CURL_GET_MAX_BYTES` (4 MiB) would silently drop them.
pub const DEFAULT_CURL_DOWNLOAD_MAX_BYTES: usize = 64 * 1024 * 1024;

/// HTTP GET with a hard `--max-time` bound and an explicit response-size cap,
/// via the curl subprocess. See `httpPostJsonWithProxyTimeout` for why the
/// poller path must not use the untimed `std.http` client.
///
/// Unlike `curlGetWithProxy` this neither falls back to the untimed std.http
/// client for a credentialed request nor sets curl `--fail`: the bound must
/// always hold, and a non-2xx stays `error.HttpStatusError` (matching
/// `httpRequest`) instead of curl exit 22's `error.CurlFailed`.
pub fn httpGetWithProxyTimeout(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    proxy: ?[]const u8,
    max_time: []const u8,
    max_bytes: usize,
) ![]u8 {
    const resp = try secureCurlRequestWithStatusAndHeaders(allocator, .{
        .method = .GET,
        .url = url,
        .headers = headers,
        .proxy = proxy,
        .max_time = max_time,
        .max_response_bytes = max_bytes,
    });
    allocator.free(resp.headers);
    errdefer allocator.free(resp.body);
    if (resp.status_code < 200 or resp.status_code >= 300) return error.HttpStatusError;
    return resp.body;
}

/// HTTP request with an explicit content type and a hard `--max-time` bound,
/// via the curl subprocess. Mirrors `httpRequest` (non-2xx is an error) but
/// cannot block indefinitely on a stalled socket.
pub fn httpRequestWithTimeout(
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    headers: []const []const u8,
    content_type: ?[]const u8,
    proxy: ?[]const u8,
    max_time: []const u8,
) ![]u8 {
    const resp = try curlRequestWithStatusAndHeaders(allocator, .{
        .method = method,
        .url = url,
        .body = body,
        .headers = headers,
        .content_type = content_type,
        .proxy = proxy,
        .max_time = max_time,
    });
    allocator.free(resp.headers);
    errdefer allocator.free(resp.body);
    // Mirror `httpRequest` exactly: a non-2xx response is an error, not curl
    // --fail's error.CurlFailed, so callers see the same error identity.
    if (resp.status_code < 200 or resp.status_code >= 300) return sendErrorForMethod(method, resp.status_code);
    return resp.body;
}

/// HTTP request with a hard `--max-time` bound that returns the status code and
/// body instead of failing on a non-2xx. Mirrors `httpRequestWithStatus` (used
/// by channels that inspect the body for an error payload) but goes through the
/// bounded curl path, so it neither blocks on a stalled socket nor drops the
/// bound through `curlRequestWithProxy`'s credentialed std.http fallback.
pub fn httpRequestWithStatusTimeout(
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    headers: []const []const u8,
    content_type: ?[]const u8,
    proxy: ?[]const u8,
    max_time: []const u8,
) !HttpResponse {
    const resp = try curlRequestWithStatusAndHeaders(allocator, .{
        .method = method,
        .url = url,
        .body = body,
        .headers = headers,
        .content_type = content_type,
        .proxy = proxy,
        .max_time = max_time,
    });
    allocator.free(resp.headers);
    return .{ .status_code = resp.status_code, .body = resp.body };
}

const proxy_env_var_names = [_][]const u8{
    "http_proxy",
    "HTTP_PROXY",
    "https_proxy",
    "HTTPS_PROXY",
    "all_proxy",
    "ALL_PROXY",
};
const http_proxy_env_var_names = [_][]const u8{
    "http_proxy",
    "HTTP_PROXY",
    "all_proxy",
    "ALL_PROXY",
};
const https_proxy_env_var_names = [_][]const u8{
    "https_proxy",
    "HTTPS_PROXY",
    "all_proxy",
    "ALL_PROXY",
};

fn appendOwnedFetchHeader(
    allocator: Allocator,
    headers: *std.ArrayListUnmanaged([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, ":\r\n\x00") != null or
        std.mem.indexOfAny(u8, value, "\r\n\x00") != null)
    {
        return error.InvalidHeader;
    }
    const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, value });
    errdefer allocator.free(line);
    try headers.append(allocator, line);
}

fn appendFetchHeaderValue(
    allocator: Allocator,
    headers: *std.ArrayListUnmanaged([]const u8),
    name: []const u8,
    value: std.http.Client.Request.Headers.Value,
    default_value: ?[]const u8,
) !void {
    switch (value) {
        .default => if (default_value) |default| try appendOwnedFetchHeader(allocator, headers, name, default),
        .override => |override| try appendOwnedFetchHeader(allocator, headers, name, override),
        .omit => try appendOwnedFetchHeader(allocator, headers, name, ""),
    }
}

fn fetchHasCallerHeaders(options: std.http.Client.FetchOptions) bool {
    return options.extra_headers.len > 0 or
        options.privileged_headers.len > 0 or
        options.headers.host != .default or
        options.headers.authorization != .default or
        options.headers.user_agent != .default or
        options.headers.connection != .default or
        options.headers.accept_encoding != .default or
        options.headers.content_type != .default;
}

fn fetchCurlMaxRedirects(options: std.http.Client.FetchOptions) ?u16 {
    const method = options.method orelse if (options.payload != null) std.http.Method.POST else .GET;
    if (method != .GET) return null;
    const redirect_behavior = options.redirect_behavior orelse
        if (options.payload == null) @as(std.http.Client.Request.RedirectBehavior, @enumFromInt(3)) else .unhandled;
    if (redirect_behavior == .unhandled) return null;
    if (redirect_behavior == .not_allowed) return 0;
    if (fetchHasCallerHeaders(options)) return null;
    return @intFromEnum(redirect_behavior);
}

pub const ProxyHttpClient = struct {
    proxy_arena: std.heap.ArenaAllocator,
    client: std.http.Client,

    pub fn init(allocator: Allocator) !ProxyHttpClient {
        var proxy_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer proxy_arena.deinit();

        var client: std.http.Client = .{ .allocator = allocator, .io = std_compat.net.httpIo() };
        errdefer client.deinit();
        try tls_ca.configureHttpClient(&client, allocator);

        try initClientDefaultProxies(&client, proxy_arena.allocator());

        return .{
            .proxy_arena = proxy_arena,
            .client = client,
        };
    }

    pub fn deinit(self: *ProxyHttpClient) void {
        self.client.deinit();
        self.proxy_arena.deinit();
        self.* = undefined;
    }

    pub fn fetch(self: *ProxyHttpClient, options: std.http.Client.FetchOptions) !std.http.Client.FetchResult {
        if (comptime stdHttpTransport(builtin.abi)) {
            try validateFetchProxy(self.client.allocator, options.location);
        }
        return self.client.fetch(options);
    }

    fn fetchWithCurl(self: *ProxyHttpClient, options: std.http.Client.FetchOptions) !std.http.Client.FetchResult {
        const allocator = self.client.allocator;
        var uri_writer: std.Io.Writer.Allocating = .init(allocator);
        defer uri_writer.deinit();
        const url: []const u8 = switch (options.location) {
            .url => |value| value,
            .uri => |uri| blk: {
                try uri.format(&uri_writer.writer);
                break :blk uri_writer.writer.buffer[0..uri_writer.writer.end];
            },
        };

        const method = options.method orelse if (options.payload != null) std.http.Method.POST else .GET;
        // Unlike std.http, curl cannot strip arbitrary custom headers only on
        // a cross-origin hop or reproduce every non-GET 303 rewrite. Return
        // those redirects for caller handling.
        const max_redirects = fetchCurlMaxRedirects(options);

        var request_headers: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (request_headers.items) |header| allocator.free(header);
            request_headers.deinit(allocator);
        }

        try appendFetchHeaderValue(allocator, &request_headers, "Host", options.headers.host, null);
        try appendFetchHeaderValue(allocator, &request_headers, "Authorization", options.headers.authorization, null);
        const default_user_agent = try std.fmt.allocPrint(allocator, "zig/{s} (std.http)", .{builtin.zig_version_string});
        defer allocator.free(default_user_agent);
        try appendFetchHeaderValue(allocator, &request_headers, "User-Agent", options.headers.user_agent, default_user_agent);
        try appendFetchHeaderValue(
            allocator,
            &request_headers,
            "Connection",
            options.headers.connection,
            if (options.keep_alive) "keep-alive" else "close",
        );
        try appendFetchHeaderValue(allocator, &request_headers, "Accept-Encoding", options.headers.accept_encoding, "gzip, deflate");
        try appendFetchHeaderValue(allocator, &request_headers, "Content-Type", options.headers.content_type, null);
        for (options.extra_headers) |header| {
            try appendOwnedFetchHeader(allocator, &request_headers, header.name, header.value);
        }
        for (options.privileged_headers) |header| {
            try appendOwnedFetchHeader(allocator, &request_headers, header.name, header.value);
        }

        const response = try secureCurlRequestWithStatusAndHeaders(allocator, .{
            .method = method,
            .url = url,
            .body = options.payload,
            .headers = request_headers.items,
            .max_redirects = max_redirects,
            .accept_compression = options.headers.accept_encoding != .omit,
            .discard_response_body = options.response_writer == null,
            .response_writer = options.response_writer,
            .generated_redirect_headers_only = !fetchHasCallerHeaders(options),
        });
        defer allocator.free(response.headers);
        defer allocator.free(response.body);

        return .{ .status = @enumFromInt(@as(u10, @intCast(response.status_code))) };
    }
};

pub const SafeResolveEntryError = Allocator.Error || error{
    InvalidUrl,
    HostResolutionFailed,
    LocalAddressBlocked,
};

fn defaultPortForScheme(uri: std.Uri) ?u16 {
    if (uri.port) |port| return port;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    return null;
}

fn shouldUseCurlResolve(host: []const u8) bool {
    return std.mem.indexOfScalar(u8, net_security.stripHostBrackets(host), ':') == null;
}

fn shouldUsePinnedResolve(host: []const u8, connect_host: []const u8) bool {
    return shouldUseCurlResolve(host) and !std.mem.eql(u8, host, connect_host);
}

fn buildCurlResolveEntry(
    allocator: Allocator,
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

/// Build an optional curl `--resolve` entry for remote provider requests.
/// Direct connections are pinned to a concrete globally-routable address;
/// explicit local/private hosts are left untouched so intentional local
/// providers still work. A configured proxy is a separate trust boundary:
/// curl may delegate the proxy's upstream DNS lookup despite `--resolve`.
///
/// DNS resolution failures are fail-closed. Falling back to curl's resolver would
/// bypass the single resolved-address check and weaken SSRF protection against
/// DNS answers that resolve to local/private networks.
pub fn buildSafeResolveEntryForRemoteUrl(
    allocator: Allocator,
    url: []const u8,
) SafeResolveEntryError!?[]u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const port = defaultPortForScheme(uri) orelse return error.InvalidUrl;
    const host = net_security.extractHost(url) orelse return error.InvalidUrl;

    if (net_security.isLocalHost(host)) return null;

    const connect_host = net_security.resolveConnectHost(allocator, host, port) catch |err|
        return mapResolveConnectHostError(host, err);
    defer allocator.free(connect_host);

    if (!shouldUsePinnedResolve(host, connect_host)) return null;
    return try buildCurlResolveEntry(allocator, host, port, connect_host);
}

fn mapResolveConnectHostError(host: []const u8, err: net_security.ResolveConnectHostError) SafeResolveEntryError {
    return switch (err) {
        error.HostResolutionFailed => blk: {
            log.debug("host resolution unavailable for {s}; failing closed", .{host});
            break :blk error.HostResolutionFailed;
        },
        error.LocalAddressBlocked => error.LocalAddressBlocked,
        error.OutOfMemory => error.OutOfMemory,
    };
}

pub fn appendCurlResolveArgs(argv_buf: []([]const u8), argc: *usize, resolve_entry: ?[]const u8) void {
    if (resolve_entry) |entry| {
        argv_buf[argc.*] = "--resolve";
        argc.* += 1;
        argv_buf[argc.*] = entry;
        argc.* += 1;
    }
}

/// HTTP POST via curl subprocess with optional proxy and timeout.
///
/// `headers` is a slice of header strings (e.g. `"Authorization: Bearer xxx"`).
/// `proxy` is an optional proxy URL (e.g. `"socks5://host:port"`).
/// `max_time` is an optional --max-time value as a string (e.g. `"300"`).
/// Returns the response body. Caller owns returned memory.
pub fn curlPostWithProxy(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    proxy: ?[]const u8,
    max_time: ?[]const u8,
) ![]u8 {
    return curlPostWithProxyAndResolve(allocator, url, body, headers, proxy, max_time, null);
}

pub fn curlPostWithProxyAndResolve(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    proxy: ?[]const u8,
    max_time: ?[]const u8,
    resolve_entry: ?[]const u8,
) ![]u8 {
    return curlRequestWithProxy(
        allocator,
        "POST",
        "Content-Type: application/json",
        url,
        body,
        headers,
        proxy,
        max_time,
        resolve_entry,
    );
}

/// HTTP POST with application/x-www-form-urlencoded body via curl subprocess,
/// with optional proxy and timeout.
pub fn curlPostFormWithProxy(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    proxy: ?[]const u8,
    max_time: ?[]const u8,
) ![]u8 {
    return curlPostFormWithProxyAndResolve(allocator, url, body, proxy, max_time, null);
}

pub fn curlPostFormWithProxyAndResolve(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    proxy: ?[]const u8,
    max_time: ?[]const u8,
    resolve_entry: ?[]const u8,
) ![]u8 {
    return curlRequestWithProxy(
        allocator,
        "POST",
        "Content-Type: application/x-www-form-urlencoded",
        url,
        body,
        &.{},
        proxy,
        max_time,
        resolve_entry,
    );
}

fn curlRequestWithProxy(
    allocator: Allocator,
    method: []const u8,
    content_type_header: []const u8,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    proxy: ?[]const u8,
    max_time: ?[]const u8,
    resolve_entry: ?[]const u8,
) ![]u8 {
    const method_enum = std.meta.stringToEnum(std.http.Method, method) orelse return error.UnsupportedHttpMethod;
    const content_type = contentTypeHeaderValue(content_type_header) orelse return error.InvalidHeader;
    if (credentialedCurlUsesHttpFallback(url, headers, resolve_entry)) {
        const response = try httpRequestWithStatus(allocator, method_enum, url, body, headers, content_type, proxy);
        errdefer allocator.free(response.body);
        if (isIndeterminateHttpStatus(response.status_code)) return error.HttpStatusIndeterminate;
        return response.body;
    }
    const response = try secureCurlRequestWithStatusAndHeaders(allocator, .{
        .method = method_enum,
        .url = url,
        .body = body,
        .headers = headers,
        .content_type = content_type,
        .proxy = proxy,
        .max_time = max_time,
        .max_response_bytes = DEFAULT_CURL_POST_MAX_BYTES,
        .resolve_entry = resolve_entry,
    });
    allocator.free(response.headers);
    errdefer allocator.free(response.body);
    // A gateway that answers 502/504 may already have forwarded the request.
    // Other statuses keep returning the body so callers can parse API errors.
    if (isIndeterminateHttpStatus(response.status_code)) return error.HttpStatusIndeterminate;
    return response.body;
}

/// HTTP POST of a raw body with an explicit `Content-Type`.
///
/// Slack's external upload URL takes the file bytes directly, so the JSON
/// helper above cannot be used. `body` is streamed over curl's stdin and never
/// becomes part of the process argv.
pub fn curlPostRawWithContentType(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    content_type: []const u8,
    headers: []const []const u8,
    max_time: ?[]const u8,
) ![]u8 {
    const content_type_header = try std.fmt.allocPrint(allocator, "Content-Type: {s}", .{content_type});
    defer allocator.free(content_type_header);
    return curlRequestWithProxy(
        allocator,
        "POST",
        content_type_header,
        url,
        body,
        headers,
        null,
        max_time,
        null,
    );
}

/// HTTP POST via curl subprocess (no proxy, no timeout).
pub fn curlPost(allocator: Allocator, url: []const u8, body: []const u8, headers: []const []const u8) ![]u8 {
    return curlPostWithProxy(allocator, url, body, headers, null, null);
}

/// HTTP POST with application/x-www-form-urlencoded body via curl subprocess.
///
/// `body` must already be percent-encoded form data (e.g. `"key=val&key2=val2"`).
/// Returns the response body. Caller owns returned memory.
pub fn curlPostForm(allocator: Allocator, url: []const u8, body: []const u8) ![]u8 {
    return curlPostFormWithProxy(allocator, url, body, null, null);
}

/// HTTP POST via curl subprocess and include HTTP status code in response.
/// Caller owns `response.body`.
pub fn curlPostWithStatus(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
) !HttpResponse {
    return curlPostWithStatusAndTimeout(allocator, url, body, headers, null);
}

pub fn curlGetWithStatus(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
) !HttpResponse {
    return curlGetWithStatusAndTimeout(allocator, url, headers, null);
}

/// HTTP POST via curl subprocess and include HTTP status code in response,
/// with optional --max-time timeout.
/// Caller owns `response.body`.
pub fn curlPostWithStatusAndTimeout(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    max_time: ?[]const u8,
) !HttpResponse {
    return curlPostWithStatusAndTimeoutAndResolve(allocator, url, body, headers, max_time, null);
}

pub fn curlPostWithStatusAndTimeoutAndResolve(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    max_time: ?[]const u8,
    resolve_entry: ?[]const u8,
) !HttpResponse {
    if (credentialedCurlUsesHttpFallback(url, headers, resolve_entry)) {
        return httpRequestWithStatus(allocator, .POST, url, body, headers, "application/json", null);
    }
    const response = try secureCurlRequestWithStatusAndHeaders(allocator, .{
        .method = .POST,
        .url = url,
        .body = body,
        .headers = headers,
        .content_type = "application/json",
        .max_time = max_time,
        .max_response_bytes = DEFAULT_CURL_POST_MAX_BYTES,
        .resolve_entry = resolve_entry,
    });
    allocator.free(response.headers);
    return .{ .status_code = response.status_code, .body = response.body };
}

/// HTTP POST via curl subprocess and include HTTP status code and response headers,
/// with optional --max-time timeout.
/// Caller owns `response.headers` and `response.body`.
pub fn curlPostWithStatusHeadersAndTimeout(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    max_time: ?[]const u8,
) !HttpResponseWithHeaders {
    return curlPostWithStatusHeadersAndTimeoutAndResolve(allocator, url, body, headers, max_time, null);
}

pub fn curlPostWithStatusHeadersAndTimeoutAndResolve(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    max_time: ?[]const u8,
    resolve_entry: ?[]const u8,
) !HttpResponseWithHeaders {
    if (credentialedCurlUsesHttpFallback(url, headers, resolve_entry)) {
        return httpRequestWithStatusAndHeaders(allocator, .POST, url, body, headers, "application/json", null);
    }
    return secureCurlRequestWithStatusAndHeaders(allocator, .{
        .method = .POST,
        .url = url,
        .body = body,
        .headers = headers,
        .content_type = "application/json",
        .max_time = max_time,
        .max_response_bytes = DEFAULT_CURL_POST_MAX_BYTES,
        .resolve_entry = resolve_entry,
    });
}

pub fn curlGetWithStatusAndTimeout(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    max_time: ?[]const u8,
) !HttpResponse {
    return curlGetWithStatusAndTimeoutAndResolve(allocator, url, headers, max_time, null);
}

pub fn curlGetWithStatusAndTimeoutAndResolve(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    max_time: ?[]const u8,
    resolve_entry: ?[]const u8,
) !HttpResponse {
    if (credentialedCurlUsesHttpFallback(url, headers, resolve_entry)) {
        return httpRequestWithStatus(allocator, .GET, url, null, headers, null, null);
    }
    const response = try secureCurlRequestWithStatusAndHeaders(allocator, .{
        .method = .GET,
        .url = url,
        .headers = headers,
        .max_time = max_time,
        .max_response_bytes = DEFAULT_CURL_GET_MAX_BYTES,
        .resolve_entry = resolve_entry,
    });
    allocator.free(response.headers);
    return .{ .status_code = response.status_code, .body = response.body };
}

/// HTTP PUT via curl subprocess (no proxy, no timeout).
pub fn curlPut(allocator: Allocator, url: []const u8, body: []const u8, headers: []const []const u8) ![]u8 {
    return curlRequestWithProxy(
        allocator,
        "PUT",
        "Content-Type: application/json",
        url,
        body,
        headers,
        null,
        null,
        null,
    );
}

/// HTTP GET via curl subprocess with optional proxy.
///
/// `headers` is a slice of header strings (e.g. `"Authorization: Bearer xxx"`).
/// `timeout_secs` sets --max-time. Returns the response body. Caller owns returned memory.
fn curlGetWithProxyAndResolve(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    proxy: ?[]const u8,
    resolve_entry: ?[]const u8,
    max_bytes: usize,
) ![]u8 {
    if (credentialedCurlUsesHttpFallback(url, headers, resolve_entry)) {
        return httpRequest(allocator, .GET, url, null, headers, null, proxy);
    }
    const response = try secureCurlRequestWithStatusAndHeaders(allocator, .{
        .method = .GET,
        .url = url,
        .headers = headers,
        .proxy = proxy,
        .max_time = timeout_secs,
        .max_response_bytes = max_bytes,
        .resolve_entry = resolve_entry,
        .fail_on_http_error = true,
    });
    allocator.free(response.headers);
    return response.body;
}

/// HTTP GET via curl subprocess with optional proxy.
///
/// `headers` is a slice of header strings (e.g. `"Authorization: Bearer xxx"`).
/// `timeout_secs` sets --max-time. Returns the response body. Caller owns returned memory.
pub fn curlGetWithProxy(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    proxy: ?[]const u8,
) ![]u8 {
    return curlGetWithProxyAndResolve(allocator, url, headers, timeout_secs, proxy, null, DEFAULT_CURL_GET_MAX_BYTES);
}

/// HTTP GET via curl subprocess with a pinned host mapping.
///
/// `resolve_entry` must be in curl `--resolve` format: `host:port:address`.
pub fn curlGetWithResolve(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    resolve_entry: []const u8,
) ![]u8 {
    return curlGetWithProxyAndResolve(allocator, url, headers, timeout_secs, null, resolve_entry, DEFAULT_CURL_GET_MAX_BYTES);
}

/// HTTP GET via curl subprocess (no proxy).
pub fn curlGet(allocator: Allocator, url: []const u8, headers: []const []const u8, timeout_secs: []const u8) ![]u8 {
    return curlGetWithProxy(allocator, url, headers, timeout_secs, null);
}

/// GET for web_fetch. Unlike `curlGetWithResolve` it keeps non-2xx responses
/// (no curl `--fail`) and returns the status line, so the caller can name the
/// failure, and it truncates oversized bodies instead of rejecting them.
/// Redirects stay unfollowed, matching `curlGet`: no `--location` is passed.
pub fn curlGetForWebFetch(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    resolve_entry: ?[]const u8,
    max_bytes: usize,
) !HttpResponseWithHeaders {
    return secureCurlRequestWithStatusAndHeaders(allocator, .{
        .method = .GET,
        .url = url,
        .headers = headers,
        .max_time = timeout_secs,
        .max_response_bytes = max_bytes,
        .resolve_entry = resolve_entry,
        .truncate_response = true,
    });
}

/// HTTP GET via curl subprocess with a caller-provided response size cap.
pub fn curlGetMaxBytes(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    max_bytes: usize,
) ![]u8 {
    return curlGetWithProxyAndResolve(allocator, url, headers, timeout_secs, null, null, max_bytes);
}

/// Read proxy URL from standard environment variables.
/// Checks https_proxy/HTTPS_PROXY first, then http_proxy/HTTP_PROXY,
/// then all_proxy/ALL_PROXY.
/// Returns null if no proxy is set.
/// Caller owns returned memory.
var proxy_override_value: ?[]u8 = null;
var proxy_override_mutex: std_compat.sync.Mutex = .{};

pub const ProxyOverrideError = error{OutOfMemory};

/// Set process-wide proxy override from config.
/// When set, this value has higher priority than proxy environment variables.
pub fn setProxyOverride(proxy: ?[]const u8) ProxyOverrideError!void {
    proxy_override_mutex.lock();
    defer proxy_override_mutex.unlock();

    if (proxy_override_value) |existing| {
        std.heap.page_allocator.free(existing);
        proxy_override_value = null;
    }

    if (proxy) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return;
        proxy_override_value = try std.heap.page_allocator.dupe(u8, trimmed);
    }
}

fn normalizeProxyEnvValue(allocator: Allocator, val: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn applyProxyOverrideToEnvMap(env_map: *std_compat.process.EnvMap) !bool {
    proxy_override_mutex.lock();
    defer proxy_override_mutex.unlock();

    const override = proxy_override_value orelse return false;
    for (proxy_env_var_names) |key| {
        try env_map.put(key, override);
    }
    return true;
}

fn putProxyEnvVarFromProcess(
    env_map: *std_compat.process.EnvMap,
    allocator: Allocator,
    key: []const u8,
) !void {
    if (std_compat.process.getEnvVarOwned(allocator, key)) |raw_value| {
        defer allocator.free(raw_value);
        if (try normalizeProxyEnvValue(allocator, raw_value)) |proxy| {
            defer allocator.free(proxy);
            try env_map.put(key, proxy);
        }
    } else |_| {}
}

fn buildProxyEnvMapFromProcess(allocator: Allocator) !std_compat.process.EnvMap {
    var env_map = std_compat.process.EnvMap.init(allocator);
    errdefer env_map.deinit();

    for (proxy_env_var_names) |key| {
        try putProxyEnvVarFromProcess(&env_map, allocator, key);
    }
    _ = try applyProxyOverrideToEnvMap(&env_map);

    return env_map;
}

fn getProxyFromEnvMap(
    allocator: Allocator,
    env_map: *const std_compat.process.EnvMap,
    env_vars: []const []const u8,
) !?[]const u8 {
    for (env_vars) |var_name| {
        const raw_value = env_map.get(var_name) orelse continue;
        if (try normalizeProxyEnvValue(allocator, raw_value)) |proxy| {
            return proxy;
        }
    }
    return null;
}

const ProxySelection = struct {
    value: ?[]const u8 = null,
    force: bool = false,

    fn deinit(self: *ProxySelection, allocator: Allocator) void {
        if (self.value) |value| allocator.free(value);
        self.* = .{};
    }
};

fn getProxyOverrideOwned(allocator: Allocator) !?[]u8 {
    proxy_override_mutex.lock();
    defer proxy_override_mutex.unlock();
    const value = proxy_override_value orelse return null;
    return try allocator.dupe(u8, value);
}

fn initClientDefaultProxiesFromEnvMap(
    client: *std.http.Client,
    arena: Allocator,
    env_map: *const std_compat.process.EnvMap,
) !void {
    var merged_env_map = try env_map.clone(arena);
    _ = try applyProxyOverrideToEnvMap(&merged_env_map);
    try client.initDefaultProxies(arena, &merged_env_map);
}

pub fn initClientDefaultProxies(client: *std.http.Client, arena: Allocator) !void {
    var env_map = try buildProxyEnvMapFromProcess(arena);
    try client.initDefaultProxies(arena, &env_map);
}

pub fn getProxyFromEnv(allocator: Allocator) !?[]const u8 {
    var env_map = try buildProxyEnvMapFromProcess(allocator);
    defer env_map.deinit();

    if (try getProxyFromEnvMap(allocator, &env_map, &https_proxy_env_var_names)) |proxy| {
        return proxy;
    }
    return try getProxyFromEnvMap(allocator, &env_map, &http_proxy_env_var_names);
}

fn getProxyForUrl(allocator: Allocator, url: []const u8) !ProxySelection {
    const uri = try validateHttpUrl(url);
    if (try getProxyOverrideOwned(allocator)) |override| {
        return .{ .value = override, .force = true };
    }

    var env_map = std_compat.process.EnvMap.init(allocator);
    defer env_map.deinit();
    for (proxy_env_var_names) |key| try putProxyEnvVarFromProcess(&env_map, allocator, key);

    const names = if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        &https_proxy_env_var_names
    else
        &http_proxy_env_var_names;
    return .{ .value = try getProxyFromEnvMap(allocator, &env_map, names) };
}

/// HTTP GET via curl for SSE (Server-Sent Events).
///
/// Uses -N (--no-buffer) to disable output buffering, allowing
/// SSE events to be received in real-time. Also sends Accept: text/event-stream.
pub fn curlGetSSE(
    allocator: Allocator,
    url: []const u8,
    timeout_secs: []const u8,
) ![]u8 {
    if (comptime stdHttpTransport(builtin.abi)) {
        const response = try stdHttpRequest(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{"Accept: text/event-stream"},
            .max_time = timeout_secs,
            .max_response_bytes = DEFAULT_CURL_GET_MAX_BYTES,
            .fail_on_http_error = true,
        });
        allocator.free(response.headers);
        return response.body;
    }
    var config = try prepareProtectedCurlConfig(allocator, url, null);
    defer config.deinit();
    var argv_buf: [40][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-q";
    argc += 1;
    argv_buf[argc] = "-sf";
    argc += 1;
    argv_buf[argc] = "-N";
    argc += 1;
    argv_buf[argc] = "--proto";
    argc += 1;
    argv_buf[argc] = "=http,https";
    argc += 1;
    argv_buf[argc] = "--max-time";
    argc += 1;
    argv_buf[argc] = timeout_secs;
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "Accept: text/event-stream";
    argc += 1;
    argv_buf[argc] = "--config";
    argc += 1;
    argv_buf[argc] = config.path();
    argc += 1;

    var child = std_compat.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        log.err("curl GET-SSE spawn failed: {}", .{err});
        return error.CurlFailed;
    };
    const cancel_flag = thread_interrupt_flag;
    var cancel_done = AtomicBool.init(false);
    var cancel_watcher: ?std.Thread = null;
    var watcher_ctx: CancelWatcherCtx = undefined;
    if (cancel_flag) |flag| {
        watcher_ctx = .{ .child = &child, .cancel_flag = flag, .done = &cancel_done };
        cancel_watcher = std.Thread.spawn(.{}, cancelWatcherMain, .{&watcher_ctx}) catch null;
    }
    defer stopCancelWatcher(&cancel_done, &cancel_watcher);
    var stderr_capture = StderrCapture{};
    var stderr_thread = startStderrCapture(&child, &stderr_capture);
    defer if (stderr_thread) |thread| thread.join();

    const stdout = child.stdout.?.readToEndAlloc(allocator, 4 * 1024 * 1024) catch {
        abortCurlChild(&child, &cancel_done, &cancel_watcher, &stderr_thread, &stderr_capture);
        return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlReadError;
    };
    errdefer allocator.free(stdout);

    _ = finishStderrCapture(&stderr_thread, &stderr_capture);
    stopCancelWatcher(&cancel_done, &cancel_watcher);
    const term = child.wait() catch |err| {
        _ = child.kill() catch {};
        logCurlWaitFailure("GET-SSE", err, null);
        return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWaitError;
    };
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                // Exit code 28 = timeout. This is expected for SSE when no data arrives,
                // but curl may have received some data before timing out - return it.
                // For other exit codes, treat as error.
                if (code != 28) {
                    logCurlExitFailure("GET-SSE", code, null);
                    return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else mapCurlExitCodeToError(code);
                }
                // Timeout (code 28) - return any data we received
            }
        },
        else => return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlFailed,
    }

    return stdout;
}

// ── Tests ───────────────────────────────────────────────────────────

test "isIndeterminateSendError keeps definite pre-send failures resendable" {
    try std.testing.expect(isIndeterminateSendError(error.CurlTimeout));
    try std.testing.expect(isIndeterminateSendError(error.CurlReadError));
    try std.testing.expect(isIndeterminateSendError(error.CurlWriteError));
    try std.testing.expect(isIndeterminateSendError(error.CurlWaitError));
    try std.testing.expect(isIndeterminateSendError(error.CurlFailed));
    try std.testing.expect(isIndeterminateSendError(error.HttpStatusIndeterminate));
    try std.testing.expect(!isIndeterminateSendError(error.CurlDnsError));
    try std.testing.expect(!isIndeterminateSendError(error.CurlConnectError));
    try std.testing.expect(!isIndeterminateSendError(error.CurlTlsError));
    try std.testing.expect(!isIndeterminateSendError(error.CurlPreSendError));
    try std.testing.expect(!isIndeterminateSendError(error.HttpStatusError));
}

test "gateway uncertainty keeps its identity through channel error wrapping" {
    try std.testing.expectEqual(
        error.HttpStatusIndeterminate,
        preserveCurlTransportError(error.HttpStatusIndeterminate, error.SlackApiError),
    );
}

test "gateway statuses map to the shared indeterminate send error" {
    try std.testing.expectEqual(error.HttpStatusIndeterminate, httpStatusError(502));
    try std.testing.expectEqual(error.HttpStatusIndeterminate, httpStatusError(504));
    try std.testing.expectEqual(error.HttpStatusError, httpStatusError(500));
    try std.testing.expectEqual(error.HttpStatusError, httpStatusError(503));
    try std.testing.expectEqual(error.HttpStatusError, httpStatusError(429));
    try std.testing.expectEqual(error.HttpStatusError, httpStatusError(400));
}

test "credentialed curl argv validation rejects authorization header" {
    try std.testing.expectError(
        error.CredentialedCurlArgRejected,
        validateNoCredentialedCurlArgs("https://example.com/v1", &.{"Authorization: Bearer test-token"}),
    );
}

test "credentialed curl argv validation rejects token query" {
    try std.testing.expectError(
        error.CredentialedCurlArgRejected,
        validateNoCredentialedCurlArgs("https://example.com/v1?access_token=test-token", &.{}),
    );
}

test "credentialed curl args route to std http fallback" {
    try std.testing.expect(hasCredentialedCurlArgs("https://example.com/v1", &.{"Authorization: Bearer test-token"}));
    try std.testing.expect(hasCredentialedCurlArgs("https://example.com/v1?access_token=test-token", &.{}));
    try std.testing.expect(!hasCredentialedCurlArgs("https://example.com/v1", &.{"User-Agent: nullclaw-test"}));
}

// Regression: aarch64-linux-android (Termux) — std.http.Client could not
// resolve names, so every request was forced through a curl subprocess that
// the APK does not ship. compat.net's libc lookup now backs std.http on
// Android, so both credentialed and plain requests must select it.
test "android routes all curl helpers to std http" {
    const cred_headers = [_][]const u8{"Authorization: Bearer test-token"};
    const plain_headers = [_][]const u8{"User-Agent: nullclaw-test"};
    try std.testing.expect(stdHttpTransport(.android));
    try std.testing.expect(!usesCurlTransport(.android));
    // Android never diverts to the lossy wrapper: the secure executor keeps
    // the spec and swaps its transport internally.
    try std.testing.expect(!credentialedCurlUsesHttpFallbackFor(.android, "https://example.com/v1", &cred_headers, null));
    try std.testing.expect(!credentialedCurlUsesHttpFallbackFor(.android, "https://example.com/v1", &plain_headers, null));
    // Non-Android keeps the existing split: credentialed args use std.http to
    // stay out of argv, everything else stays on curl.
    try std.testing.expect(!stdHttpTransport(.gnu));
    try std.testing.expect(usesCurlTransport(.gnu));
    try std.testing.expect(credentialedCurlUsesHttpFallbackFor(.gnu, "https://example.com/v1", &cred_headers, null));
    try std.testing.expect(!credentialedCurlUsesHttpFallbackFor(.gnu, "https://example.com/v1", &plain_headers, null));
}

test "secure curl command preserves methods and keeps secrets out of argv" {
    // Regression: the Android fallback must not collapse PATCH/PUT to POST or
    // DELETE/HEAD to GET, and no opaque caller data may enter process argv.
    const methods = [_]std.http.Method{ .GET, .HEAD, .DELETE, .POST, .PUT, .PATCH, .OPTIONS };
    const secret_url = "https://example.com/bot-test-token/action?session=query-secret";
    const secret_header = "X-Custom-Key: header-secret";
    const secret_proxy = "http://user:proxy-secret@proxy.example:8080";
    for (methods) |method| {
        const body: ?[]const u8 = switch (method) {
            .POST, .PUT, .PATCH => "request-body",
            else => null,
        };
        const spec: CurlRequestSpec = .{
            .method = method,
            .url = secret_url,
            .body = body,
            .headers = &.{secret_header},
            .content_type = "multipart/form-data; boundary=test-boundary",
            .proxy = secret_proxy,
        };
        const command = try buildSecureCurlCommand(
            spec,
            "/tmp/curl-config",
            "@/tmp/curl-headers",
            "/tmp/curl-response-headers",
            null,
            null,
        );

        try std.testing.expectEqualStrings("curl", command.argv[0]);
        try std.testing.expectEqualStrings("-q", command.argv[1]);
        var saw_method = false;
        var saw_head = false;
        var saw_stdin_body = false;
        var saw_location = false;
        for (command.slice(), 0..) |arg, index| {
            try std.testing.expect(std.mem.indexOf(u8, arg, "test-token") == null);
            try std.testing.expect(std.mem.indexOf(u8, arg, "query-secret") == null);
            try std.testing.expect(std.mem.indexOf(u8, arg, "header-secret") == null);
            try std.testing.expect(std.mem.indexOf(u8, arg, "proxy-secret") == null);
            if (std.mem.eql(u8, arg, "--request") and index + 1 < command.argc) {
                try std.testing.expectEqualStrings(@tagName(method), command.argv[index + 1]);
                saw_method = true;
            }
            saw_head = saw_head or std.mem.eql(u8, arg, "--head");
            saw_stdin_body = saw_stdin_body or std.mem.eql(u8, arg, "@-");
            saw_location = saw_location or std.mem.eql(u8, arg, "--location");
        }
        try std.testing.expect(saw_method);
        try std.testing.expectEqual(method == .HEAD, saw_head);
        try std.testing.expectEqual(body != null, saw_stdin_body);
        try std.testing.expect(!saw_location);
    }
}

test "secure curl config contains URL and proxy only in protected file" {
    var config = try prepareCurlConfig(
        std.testing.allocator,
        "https://example.com/api?session=test-token",
        "http://user:proxy-secret@proxy.example:8080",
        true,
    );
    defer config.deinit();

    const file = try std_compat.fs.openFileAbsolute(config.path(), .{});
    defer file.close();
    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        const stat = try file.stat();
        try std.testing.expectEqual(@as(std_compat.fs.File.Mode, 0), stat.mode & 0o077);
        try std.testing.expect((stat.mode & 0o600) == 0o600);
    }
    const content = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.startsWith(u8, content, "globoff\n"));
    try std.testing.expect(std.mem.indexOf(u8, content, "session=test-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "proxy-secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "noproxy = \"\"") != null);
}

test "protected curl config escapes values and rejects control injection" {
    var config = try prepareProtectedCurlConfig(
        std.testing.allocator,
        "https://example.com/api",
        "http://proxy.example/quote\"slash\\tail",
    );
    defer config.deinit();

    const file = try std_compat.fs.openFileAbsolute(config.path(), .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "quote\\\"slash\\\\tail") != null);

    try std.testing.expectError(
        error.InvalidCurlConfigValue,
        prepareProtectedCurlConfig(
            std.testing.allocator,
            "https://example.com/api",
            "http://proxy.example/ok\nurl = \"https://attacker.example\"",
        ),
    );
}

test "secure curl rejects non-http URLs and header injection before spawning" {
    try std.testing.expectError(
        error.UnsupportedUriScheme,
        prepareCurlConfig(std.testing.allocator, "file:///tmp/test-token", null, false),
    );
    try std.testing.expectError(
        error.InvalidHeader,
        secureCurlRequestWithStatusAndHeaders(std.testing.allocator, .{
            .method = .GET,
            .url = "https://example.com/",
            .headers = &.{"X-Test: ok\r\nX-Injected: bad"},
            .proxy = "",
        }),
    );
}

test "android fetch adapter validates typed headers before spawning" {
    var client = try ProxyHttpClient.init(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectError(
        error.InvalidHeader,
        client.fetchWithCurl(.{
            .location = .{ .url = "https://example.com/" },
            .extra_headers = &.{.{ .name = "X-Test\r\nInjected", .value = "bad" }},
        }),
    );
}

test "android fetch adapter never auto-redirects caller headers" {
    // Regression: curl forwards arbitrary custom headers across origins, so a
    // bodyless request carrying an opaque API key must not use --location.
    const with_secret: std.http.Client.FetchOptions = .{
        .location = .{ .url = "https://example.com/start" },
        .extra_headers = &.{.{ .name = "X-Custom-Key", .value = "test-token" }},
    };
    try std.testing.expect(fetchHasCallerHeaders(with_secret));
    try std.testing.expectEqual(@as(?u16, null), fetchCurlMaxRedirects(with_secret));

    const without_headers: std.http.Client.FetchOptions = .{
        .location = .{ .url = "https://example.com/start" },
    };
    try std.testing.expectEqual(@as(?u16, 3), fetchCurlMaxRedirects(without_headers));
    try std.testing.expectEqual(@as(?u16, 3), safeCurlMaxRedirects(.{
        .method = .GET,
        .url = "https://example.com/start",
        .headers = &.{STD_HTTP_USER_AGENT_HEADER},
        .max_redirects = 3,
        .generated_redirect_headers_only = true,
    }));
    try std.testing.expectEqual(@as(?u16, null), safeCurlMaxRedirects(.{
        .method = .GET,
        .url = "https://example.com/start",
        .headers = &.{"Authorization: Bearer test-token"},
        .max_redirects = 3,
    }));
}

const LegacyCredentialedCurlHelper = enum {
    get_body,
    get_status,
    post_body,
    post_status,
    post_status_headers,
    put_body,
};

const CredentialedCurlFallbackServerCtx = struct {
    server: *std_compat.net.Server,
    expected_method: []const u8,
    saw_request: AtomicBool = AtomicBool.init(false),
    saw_expected_method: AtomicBool = AtomicBool.init(false),
    saw_authorization: AtomicBool = AtomicBool.init(false),
};

fn serveCredentialedCurlFallbackTest(ctx: *CredentialedCurlFallbackServerCtx) void {
    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();

    var buf: [2048]u8 = undefined;
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = conn.stream.read(buf[filled..]) catch return;
        if (n == 0) break;
        filled += n;
        if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n") != null) break;
    }

    const request = buf[0..filled];
    ctx.saw_request.store(true, .release);
    if (std.mem.startsWith(u8, request, ctx.expected_method) and
        request.len > ctx.expected_method.len and
        request[ctx.expected_method.len] == ' ')
    {
        ctx.saw_expected_method.store(true, .release);
    }
    if (std.mem.indexOf(u8, request, "Authorization: Bearer test-token") != null) {
        ctx.saw_authorization.store(true, .release);
    }

    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 11\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "{\"ok\":true}";
    conn.stream.writeAll(response) catch {};
}

const SecureCurlTransportServerCtx = struct {
    server: *std_compat.net.Server,
    expected_method: []const u8,
    expected_body: []const u8,
    expected_content_type: ?[]const u8,
    saw_request: AtomicBool = AtomicBool.init(false),
    saw_expected_method: AtomicBool = AtomicBool.init(false),
    saw_expected_body: AtomicBool = AtomicBool.init(false),
    saw_expected_content_type: AtomicBool = AtomicBool.init(false),
    saw_unexpected_content_type: AtomicBool = AtomicBool.init(false),
    saw_custom_header: AtomicBool = AtomicBool.init(false),
};

fn serveSecureCurlTransportTest(ctx: *SecureCurlTransportServerCtx) void {
    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();

    var buf: [8192]u8 = undefined;
    var filled: usize = 0;
    var request_end: ?usize = null;
    while (filled < buf.len) {
        const n = conn.stream.read(buf[filled..]) catch return;
        if (n == 0) break;
        filled += n;
        if (request_end == null) {
            if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n")) |pos| request_end = pos + 4;
        }
        if (request_end) |end| {
            if (filled >= end + ctx.expected_body.len) break;
        }
    }

    const request = buf[0..filled];
    ctx.saw_request.store(true, .release);
    if (std.mem.startsWith(u8, request, ctx.expected_method) and
        request.len > ctx.expected_method.len and request[ctx.expected_method.len] == ' ')
    {
        ctx.saw_expected_method.store(true, .release);
    }
    if (request_end) |end| {
        if (request.len >= end + ctx.expected_body.len and
            std.mem.eql(u8, request[end .. end + ctx.expected_body.len], ctx.expected_body))
        {
            ctx.saw_expected_body.store(true, .release);
        }
    }
    if (ctx.expected_content_type) |content_type| {
        if (std.mem.indexOf(u8, request, content_type) != null) {
            ctx.saw_expected_content_type.store(true, .release);
        }
    } else {
        ctx.saw_expected_content_type.store(true, .release);
        if (std.mem.indexOf(u8, request, "Content-Type:") != null) {
            ctx.saw_unexpected_content_type.store(true, .release);
        }
    }
    if (std.mem.indexOf(u8, request, "X-Custom-Key: header-secret") != null) {
        ctx.saw_custom_header.store(true, .release);
    }

    const response_head =
        "HTTP/1.1 207 Multi-Status\r\n" ++
        "X-Transport-Test: preserved\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 12\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    conn.stream.writeAll(response_head) catch return;
    if (!std.mem.eql(u8, ctx.expected_method, "HEAD")) {
        conn.stream.writeAll("transport-ok") catch {};
    }
}

fn expectSecureCurlTransport(
    method: std.http.Method,
    body: ?[]const u8,
    content_type: ?[]const u8,
    use_proxy: bool,
    use_writer: bool,
) !void {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    var ctx = SecureCurlTransportServerCtx{
        .server = &server,
        .expected_method = @tagName(method),
        .expected_body = body orelse "",
        .expected_content_type = content_type,
    };
    const url = if (use_proxy)
        try allocator.dupe(u8, "http://target.invalid/bot-test-token/action?session=query-secret")
    else
        try std.fmt.allocPrint(
            allocator,
            "http://127.0.0.1:{d}/bot-test-token/action?session=query-secret",
            .{server.listen_address.in.getPort()},
        );
    defer allocator.free(url);
    const proxy = if (use_proxy)
        try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{server.listen_address.in.getPort()})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(proxy);
    var thread = try std.Thread.spawn(.{}, serveSecureCurlTransportTest, .{&ctx});
    var streamed: std.Io.Writer.Allocating = .init(allocator);
    defer streamed.deinit();
    const response = secureCurlRequestWithStatusAndHeaders(allocator, .{
        .method = method,
        .url = url,
        .body = body,
        .headers = &.{"X-Custom-Key: header-secret"},
        .content_type = content_type,
        .proxy = proxy,
        .max_time = "5",
        .response_writer = if (use_writer) &streamed.writer else null,
    }) catch |err| {
        if (!ctx.saw_request.load(.acquire)) unblockCredentialedCurlFallbackServer(&server);
        thread.join();
        return err;
    };
    defer allocator.free(response.headers);
    defer allocator.free(response.body);
    thread.join();

    try std.testing.expectEqual(@as(u16, 207), response.status_code);
    try std.testing.expect(std.mem.indexOf(u8, response.headers, "X-Transport-Test: preserved") != null);
    if (method == .HEAD or use_writer) {
        try std.testing.expectEqual(@as(usize, 0), response.body.len);
    } else {
        try std.testing.expectEqualStrings("transport-ok", response.body);
    }
    if (use_writer) try std.testing.expectEqualStrings("transport-ok", streamed.writer.buffered());
    try std.testing.expect(ctx.saw_expected_method.load(.acquire));
    try std.testing.expect(ctx.saw_expected_body.load(.acquire));
    try std.testing.expect(ctx.saw_expected_content_type.load(.acquire));
    try std.testing.expect(!ctx.saw_unexpected_content_type.load(.acquire));
    try std.testing.expect(ctx.saw_custom_header.load(.acquire));
}

test "secure curl transport preserves method body content type status and headers" {
    // Regression: these are the exact method classes broken by the original
    // Android GET/POST dispatcher.
    try expectSecureCurlTransport(.PATCH, "patch-body", "multipart/form-data; boundary=test-boundary", true, false);
    try expectSecureCurlTransport(.POST, "untyped-body", null, false, true);
    try expectSecureCurlTransport(.DELETE, null, null, false, false);
    try expectSecureCurlTransport(.HEAD, null, null, false, false);
}

// ── Transport integrity ──────────────────────────────────────────────────────
//
// Regression coverage for the silent response corruption reported in
// nullclaw#1018: on aarch64-linux-android the agent returns scrambled or empty
// text with exit 0, so nothing fails loudly.
//
// `ProxyHttpClient.fetch` routes *every* Android request through
// `fetchWithCurl`, while other platforms keep using std.http — so the adapter
// is Android-only. The curl executor underneath it is shared, which is why these
// assertions run on every host platform: a regression in request or response
// handling flags CI on Linux, macOS and Windows even though only Android
// selects the adapter in production.

const CURL_INTEGRITY_BUFFER_BYTES: usize = 256 * 1024;

const CurlIntegrityServerCtx = struct {
    server: *std_compat.net.Server,
    response_payload: []const u8,
    expected_request_body: []const u8,
    saw_exact_request: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    saw_request: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Case-insensitive `Content-Length` lookup for a raw header block.
fn testContentLength(head: []const u8) ?usize {
    const needle = "content-length:";
    var i: usize = 0;
    while (i + needle.len <= head.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(head[i .. i + needle.len], needle)) continue;
        var j = i + needle.len;
        while (j < head.len and (head[j] == ' ' or head[j] == '\t')) j += 1;
        var value: usize = 0;
        var saw_digit = false;
        while (j < head.len and head[j] >= '0' and head[j] <= '9') : (j += 1) {
            value = value * 10 + (head[j] - '0');
            saw_digit = true;
        }
        return if (saw_digit) value else null;
    }
    return null;
}

/// Read one request, assert the body arrived intact, then return a payload
/// large enough to cross the 8 KiB read boundary that short fixtures never reach.
fn serveCurlIntegrityTest(ctx: *CurlIntegrityServerCtx) void {
    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();

    const buf = std.heap.page_allocator.alloc(u8, CURL_INTEGRITY_BUFFER_BYTES) catch return;
    defer std.heap.page_allocator.free(buf);

    var filled: usize = 0;
    var body_end: ?usize = null;
    while (filled < buf.len) {
        if (body_end) |end| if (filled >= end) break;
        const n = conn.stream.read(buf[filled..]) catch break;
        if (n == 0) break;
        filled += n;
        if (body_end == null) {
            if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n")) |head_end| {
                const content_length = testContentLength(buf[0..head_end]) orelse 0;
                body_end = head_end + 4 + content_length;
            }
        }
    }

    const request = buf[0..filled];
    ctx.saw_request.store(true, .release);
    if (std.mem.indexOf(u8, request, "\r\n\r\n")) |head_end| {
        if (body_end) |end| {
            if (end <= request.len and
                std.mem.eql(u8, request[head_end + 4 .. end], ctx.expected_request_body))
            {
                ctx.saw_exact_request.store(true, .release);
            }
        }
    }

    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/octet-stream\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{ctx.response_payload.len},
    ) catch return;
    conn.stream.writeAll(head) catch return;
    conn.stream.writeAll(ctx.response_payload) catch {};
}

/// Deterministic, position-sensitive filler: any dropped, duplicated or
/// reordered run changes the slice, so equality is a strict integrity check.
fn fillMarkerPattern(buf: []u8, seed: u8) void {
    for (buf, 0..) |*byte, i| {
        byte.* = @truncate(@as(u16, @intCast(i % 256)) *% 31 +% @as(u16, seed));
    }
}

/// Round-trip `response_payload` through the curl executor and assert it comes
/// back byte-identical. When `request_body` is non-empty it is asserted on the
/// server side too, so both directions are covered.
fn expectCurlIntegrity(
    allocator: std.mem.Allocator,
    response_payload: []const u8,
    request_body: []const u8,
    via_android_adapter: bool,
) !void {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    var ctx = CurlIntegrityServerCtx{
        .server = &server,
        .response_payload = response_payload,
        .expected_request_body = request_body,
    };
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/integrity", .{server.listen_address.in.getPort()});
    defer allocator.free(url);

    var thread = try std.Thread.spawn(.{}, serveCurlIntegrityTest, .{&ctx});

    if (via_android_adapter) {
        var client = try ProxyHttpClient.init(allocator);
        defer client.deinit();
        var body_writer: std.Io.Writer.Allocating = .init(allocator);
        defer body_writer.deinit();

        const method: std.http.Method = if (request_body.len > 0) .POST else .GET;
        const result = client.fetchWithCurl(.{
            .location = .{ .url = url },
            .method = method,
            .payload = if (request_body.len > 0) request_body else null,
            .response_writer = &body_writer.writer,
        }) catch |err| {
            if (!ctx.saw_request.load(.acquire)) unblockCredentialedCurlFallbackServer(&server);
            thread.join();
            return err;
        };
        thread.join();
        try std.testing.expectEqual(std.http.Status.ok, result.status);
        try std.testing.expectEqualSlices(u8, response_payload, body_writer.writer.buffered());
    } else {
        const response = secureCurlRequestWithStatusAndHeaders(allocator, .{
            .method = if (request_body.len > 0) .POST else .GET,
            .url = url,
            .body = if (request_body.len > 0) request_body else null,
            .headers = &.{},
            .max_time = "10",
        }) catch |err| {
            if (!ctx.saw_request.load(.acquire)) unblockCredentialedCurlFallbackServer(&server);
            thread.join();
            return err;
        };
        defer allocator.free(response.headers);
        defer allocator.free(response.body);
        thread.join();
        try std.testing.expectEqual(@as(u16, 200), response.status_code);
        try std.testing.expectEqualSlices(u8, response_payload, response.body);
    }

    try std.testing.expect(ctx.saw_request.load(.acquire));
    try std.testing.expect(ctx.saw_exact_request.load(.acquire));
}

test "curl transport round-trips payloads byte-exactly across the 8 KiB boundary" {
    // Regression: nullclaw#1018 — silent corruption. Short fixtures (12 B) never
    // crossed the read boundary, so a truncating reader still passed.
    const allocator = std.testing.allocator;

    for ([_]usize{ 4 * 1024, 8 * 1024, 64 * 1024 }) |size| {
        const payload = try allocator.alloc(u8, size);
        defer allocator.free(payload);
        fillMarkerPattern(payload, @intCast(size / 1024));
        try expectCurlIntegrity(allocator, payload, "", false);
    }
}

test "curl transport preserves a large request body byte-exactly" {
    // Regression: nullclaw#1018 — why a mangled request reads as scrambled output:
    // the model answers a prompt it never received.
    const allocator = std.testing.allocator;

    const request_body = try allocator.alloc(u8, 48 * 1024);
    defer allocator.free(request_body);
    fillMarkerPattern(request_body, 7);

    const response_payload = try allocator.alloc(u8, 32 * 1024);
    defer allocator.free(response_payload);
    fillMarkerPattern(response_payload, 11);

    try expectCurlIntegrity(allocator, response_payload, request_body, false);
}

test "android curl adapter returns the response body byte-exactly" {
    // The adapter is what `ProxyHttpClient.fetch` selects on Android
    // (http_util.zig); until now nothing round-tripped a body through it.
    const allocator = std.testing.allocator;

    const response_payload = try allocator.alloc(u8, 48 * 1024);
    defer allocator.free(response_payload);
    fillMarkerPattern(response_payload, 3);

    try expectCurlIntegrity(allocator, response_payload, "", true);
}

test "curl transport stays byte-exact across repeated calls" {
    // Regression: nullclaw#1018 — corruption was intermittent, the signature of
    // state leaking between transfers rather than a constant misparse.
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const payload = try allocator.alloc(u8, 12 * 1024);
    defer allocator.free(payload);

    for (0..5) |round| {
        fillMarkerPattern(payload, @intCast(round + 1));
        try expectCurlIntegrity(allocator, payload, "", false);
    }
}

fn unblockCredentialedCurlFallbackServer(server: *std_compat.net.Server) void {
    var conn = std_compat.net.tcpConnectToAddress(server.listen_address) catch return;
    conn.close();
}

fn expectLegacyCredentialedCurlFallback(helper: LegacyCredentialedCurlHelper, expected_method: []const u8) !void {
    if (comptime @import("builtin").os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    var ctx = CredentialedCurlFallbackServerCtx{
        .server = &server,
        .expected_method = expected_method,
    };
    var thread = try std.Thread.spawn(.{}, serveCredentialedCurlFallbackTest, .{&ctx});

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/legacy", .{server.listen_address.in.getPort()});
    defer allocator.free(url);
    const headers = [_][]const u8{"Authorization: Bearer test-token"};
    var request_err: ?anyerror = null;

    switch (helper) {
        .get_body => {
            const body = curlGet(allocator, url, &headers, "5") catch |err| blk: {
                request_err = err;
                break :blk null;
            };
            if (body) |b| {
                defer allocator.free(b);
                try std.testing.expectEqualStrings("{\"ok\":true}", b);
            }
        },
        .get_status => {
            const resp = curlGetWithStatus(allocator, url, &headers) catch |err| blk: {
                request_err = err;
                break :blk null;
            };
            if (resp) |r| {
                defer allocator.free(r.body);
                try std.testing.expectEqual(@as(u16, 200), r.status_code);
                try std.testing.expectEqualStrings("{\"ok\":true}", r.body);
            }
        },
        .post_body => {
            const body = curlPost(allocator, url, "{\"ping\":true}", &headers) catch |err| blk: {
                request_err = err;
                break :blk null;
            };
            if (body) |b| {
                defer allocator.free(b);
                try std.testing.expectEqualStrings("{\"ok\":true}", b);
            }
        },
        .post_status => {
            const resp = curlPostWithStatus(allocator, url, "{\"ping\":true}", &headers) catch |err| blk: {
                request_err = err;
                break :blk null;
            };
            if (resp) |r| {
                defer allocator.free(r.body);
                try std.testing.expectEqual(@as(u16, 200), r.status_code);
                try std.testing.expectEqualStrings("{\"ok\":true}", r.body);
            }
        },
        .post_status_headers => {
            const resp = curlPostWithStatusHeadersAndTimeout(allocator, url, "{\"ping\":true}", &headers, null) catch |err| blk: {
                request_err = err;
                break :blk null;
            };
            if (resp) |r| {
                defer allocator.free(r.headers);
                defer allocator.free(r.body);
                try std.testing.expectEqual(@as(u16, 200), r.status_code);
                try std.testing.expectEqualStrings("{\"ok\":true}", r.body);
            }
        },
        .put_body => {
            const body = curlPut(allocator, url, "{\"ping\":true}", &headers) catch |err| blk: {
                request_err = err;
                break :blk null;
            };
            if (body) |b| {
                defer allocator.free(b);
                try std.testing.expectEqualStrings("{\"ok\":true}", b);
            }
        },
    }

    if (!ctx.saw_request.load(.acquire)) {
        unblockCredentialedCurlFallbackServer(&server);
    }
    thread.join();

    if (request_err) |err| return err;
    try std.testing.expect(ctx.saw_expected_method.load(.acquire));
    try std.testing.expect(ctx.saw_authorization.load(.acquire));
}

fn expectCredentialedCurlResolveEntry(helper: LegacyCredentialedCurlHelper, expected_method: []const u8) !void {
    if (comptime @import("builtin").os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    var ctx = CredentialedCurlFallbackServerCtx{
        .server = &server,
        .expected_method = expected_method,
    };
    var thread = try std.Thread.spawn(.{}, serveCredentialedCurlFallbackTest, .{&ctx});

    const host = "credentialed-curl.test";
    const port = server.listen_address.in.getPort();
    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/legacy?access_token=test-token", .{ host, port });
    defer allocator.free(url);
    const resolve_entry = try std.fmt.allocPrint(allocator, "{s}:{d}:127.0.0.1", .{ host, port });
    defer allocator.free(resolve_entry);
    const headers = [_][]const u8{"Authorization: Bearer test-token"};
    var request_err: ?anyerror = null;

    switch (helper) {
        .get_body => {
            const body = curlGetWithResolve(allocator, url, &headers, "5", resolve_entry) catch |err| blk: {
                request_err = err;
                break :blk null;
            };
            if (body) |b| {
                defer allocator.free(b);
                try std.testing.expectEqualStrings("{\"ok\":true}", b);
            }
        },
        .get_status => {
            const resp = curlGetWithStatusAndTimeoutAndResolve(allocator, url, &headers, "5", resolve_entry) catch |err| blk: {
                request_err = err;
                break :blk null;
            };
            if (resp) |r| {
                defer allocator.free(r.body);
                try std.testing.expectEqual(@as(u16, 200), r.status_code);
                try std.testing.expectEqualStrings("{\"ok\":true}", r.body);
            }
        },
        .post_body => {
            const body = curlPostWithProxyAndResolve(allocator, url, "{\"ping\":true}", &headers, null, "5", resolve_entry) catch |err| blk: {
                request_err = err;
                break :blk null;
            };
            if (body) |b| {
                defer allocator.free(b);
                try std.testing.expectEqualStrings("{\"ok\":true}", b);
            }
        },
        .post_status => {
            const resp = curlPostWithStatusAndTimeoutAndResolve(allocator, url, "{\"ping\":true}", &headers, "5", resolve_entry) catch |err| blk: {
                request_err = err;
                break :blk null;
            };
            if (resp) |r| {
                defer allocator.free(r.body);
                try std.testing.expectEqual(@as(u16, 200), r.status_code);
                try std.testing.expectEqualStrings("{\"ok\":true}", r.body);
            }
        },
        .post_status_headers => {
            const resp = curlPostWithStatusHeadersAndTimeoutAndResolve(allocator, url, "{\"ping\":true}", &headers, "5", resolve_entry) catch |err| blk: {
                request_err = err;
                break :blk null;
            };
            if (resp) |r| {
                defer allocator.free(r.headers);
                defer allocator.free(r.body);
                try std.testing.expectEqual(@as(u16, 200), r.status_code);
                try std.testing.expectEqualStrings("{\"ok\":true}", r.body);
            }
        },
        .put_body => unreachable,
    }

    if (!ctx.saw_request.load(.acquire)) {
        unblockCredentialedCurlFallbackServer(&server);
    }
    thread.join();

    if (request_err) |err| return err;
    try std.testing.expect(ctx.saw_expected_method.load(.acquire));
    try std.testing.expect(ctx.saw_authorization.load(.acquire));
}

test "credentialed legacy curl body helpers do not reject authorization headers" {
    // Regression: legacy channel code still passes Authorization to curl* helper
    // APIs. These helpers must route through std.http fallback instead of
    // returning CredentialedCurlArgRejected and breaking old channels.
    try expectLegacyCredentialedCurlFallback(.get_body, "GET");
    try expectLegacyCredentialedCurlFallback(.post_body, "POST");
    try expectLegacyCredentialedCurlFallback(.put_body, "PUT");
}

test "credentialed legacy curl status helpers do not reject authorization headers" {
    // Regression: status-returning helpers used by Lark/QQ/OneBot must preserve
    // behavior while keeping Authorization out of curl argv.
    try expectLegacyCredentialedCurlFallback(.get_status, "GET");
    try expectLegacyCredentialedCurlFallback(.post_status, "POST");
    try expectLegacyCredentialedCurlFallback(.post_status_headers, "POST");
}

test "credentialed curl helpers preserve resolve pinning" {
    // Regression: credentialed fallback must not bypass curl --resolve pinning,
    // otherwise provider SSRF/DNS-rebinding protection is weakened.
    try expectCredentialedCurlResolveEntry(.get_body, "GET");
    try expectCredentialedCurlResolveEntry(.post_body, "POST");
    try expectCredentialedCurlResolveEntry(.get_status, "GET");
    try expectCredentialedCurlResolveEntry(.post_status, "POST");
    try expectCredentialedCurlResolveEntry(.post_status_headers, "POST");
}

test "prepareCurlHeaderArg writes headers outside argv" {
    var prepared = try prepareCurlHeaderArg(std.testing.allocator, &.{ "Authorization: Bearer test-token", "X-Test: ok" });
    defer prepared.deinit(std.testing.allocator);

    // Regression: direct curl callers can keep credential headers out of argv.
    try std.testing.expect(prepared.uses_temp_file);
    try std.testing.expect(prepared.arg != null);
    try std.testing.expect(std.mem.startsWith(u8, prepared.arg.?, "@"));

    const file = try std_compat.fs.openFileAbsolute(prepared.arg.?[1..], .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("Authorization: Bearer test-token\nX-Test: ok\n", content);
}

test "prepareCurlHeaderArg rejects newline injection" {
    try std.testing.expectError(
        error.InvalidHeader,
        prepareCurlHeaderArg(std.testing.allocator, &.{"Authorization: Bearer test-token\nX-Injected: bad"}),
    );
}

test "credentialed curl argv validation permits non-secret headers" {
    try validateNoCredentialedCurlArgs("https://example.com/v1", &.{"User-Agent: nullclaw-test"});
}

test "buildSafeResolveEntryForRemoteUrl allows explicit local host without pinning" {
    try std.testing.expect((try buildSafeResolveEntryForRemoteUrl(std.testing.allocator, "http://127.0.0.1:11434/api/chat")) == null);
}

test "buildSafeResolveEntryForRemoteUrl rejects loopback integer alias" {
    try std.testing.expectError(error.LocalAddressBlocked, buildSafeResolveEntryForRemoteUrl(std.testing.allocator, "https://2130706433/v1"));
}

test "buildSafeResolveEntryForRemoteUrl maps resolution failure to fail closed" {
    // Regression: do not silently fall back to curl DNS on resolver failure,
    // because that bypasses private-address screening before --resolve pinning.
    try std.testing.expect(mapResolveConnectHostError("example.com", error.HostResolutionFailed) == error.HostResolutionFailed);
}

test "buildSafeResolveEntryForRemoteUrl rejects malformed URL" {
    try std.testing.expectError(error.InvalidUrl, buildSafeResolveEntryForRemoteUrl(std.testing.allocator, "notaurl"));
}

test "appendCurlResolveArgs appends resolve flag and target" {
    var argv_buf: [4][]const u8 = undefined;
    var argc: usize = 0;
    appendCurlResolveArgs(argv_buf[0..], &argc, "example.com:443:203.0.113.7");
    try std.testing.expectEqual(@as(usize, 2), argc);
    try std.testing.expectEqualStrings("--resolve", argv_buf[0]);
    try std.testing.expectEqualStrings("example.com:443:203.0.113.7", argv_buf[1]);
}

test "appendCurlResolveArgs skips null entry" {
    var argv_buf: [2][]const u8 = undefined;
    var argc: usize = 0;
    appendCurlResolveArgs(argv_buf[0..], &argc, null);
    try std.testing.expectEqual(@as(usize, 0), argc);
}

test "curl post max bytes is increased for large provider responses" {
    try std.testing.expect(DEFAULT_CURL_POST_MAX_BYTES >= 8 * 1024 * 1024);
}

test "curl exit code classification maps key network classes" {
    try std.testing.expectEqualStrings("dns", classifyCurlExitCode(6));
    try std.testing.expectEqualStrings("connect", classifyCurlExitCode(7));
    try std.testing.expectEqualStrings("timeout", classifyCurlExitCode(28));
    try std.testing.expectEqualStrings("tls", classifyCurlExitCode(60));
    try std.testing.expectEqualStrings("other", classifyCurlExitCode(22));
}

test "curl exit code mapping returns specific errors" {
    try std.testing.expect(mapCurlExitCodeToError(6) == error.CurlDnsError);
    try std.testing.expect(mapCurlExitCodeToError(7) == error.CurlConnectError);
    try std.testing.expect(mapCurlExitCodeToError(28) == error.CurlTimeout);
    try std.testing.expect(mapCurlExitCodeToError(60) == error.CurlTlsError);
    try std.testing.expect(mapCurlExitCodeToError(22) == error.CurlFailed);
}

test "curl pre-send failures are not treated as indeterminate sends" {
    // Regression: exit 5 (unresolvable proxy) used to fall through to
    // CurlFailed and count as possibly delivered, silently dropping a reply
    // whose request never left the process.
    try std.testing.expect(mapCurlExitCodeToError(2) == error.CurlPreSendError);
    try std.testing.expect(mapCurlExitCodeToError(3) == error.CurlPreSendError);
    try std.testing.expect(mapCurlExitCodeToError(5) == error.CurlPreSendError);
    try std.testing.expect(!isIndeterminateSendError(error.CurlPreSendError));
    try std.testing.expect(isCurlTransportError(error.CurlPreSendError));
}

test "preserveCurlTransportError preserves curl transport failures" {
    // Regression: provider probes need raw curl transport failures instead of a
    // provider-specific API error so they can report network_error correctly.
    try std.testing.expect(preserveCurlTransportError(error.CurlDnsError, error.ApiError) == error.CurlDnsError);
    try std.testing.expect(preserveCurlTransportError(error.CurlConnectError, error.ApiError) == error.CurlConnectError);
    try std.testing.expect(preserveCurlTransportError(error.CurlTimeout, error.ApiError) == error.CurlTimeout);
    try std.testing.expect(preserveCurlTransportError(error.CurlTlsError, error.ApiError) == error.CurlTlsError);
    try std.testing.expect(preserveCurlTransportError(error.CurlReadError, error.ApiError) == error.CurlReadError);
    try std.testing.expect(preserveCurlTransportError(error.CurlWriteError, error.ApiError) == error.CurlWriteError);
    try std.testing.expect(preserveCurlTransportError(error.CurlWaitError, error.ApiError) == error.CurlWaitError);
    try std.testing.expect(preserveCurlTransportError(error.CurlFailed, error.ApiError) == error.CurlFailed);
    try std.testing.expect(preserveCurlTransportError(error.CurlInterrupted, error.ApiError) == error.CurlInterrupted);
}

test "preserveCurlTransportError returns fallback for non-transport failures" {
    try std.testing.expect(preserveCurlTransportError(error.RateLimited, error.ApiError) == error.ApiError);
    try std.testing.expect(preserveCurlTransportError(error.InvalidUrl, error.ApiError) == error.ApiError);
}

test "StderrCapture returns trimmed stderr" {
    var capture = StderrCapture{};
    const raw = "\n curl: (6) Could not resolve host \n";
    @memcpy(capture.buffer[0..raw.len], raw);
    capture.len = raw.len;

    try std.testing.expectEqualStrings("curl: (6) Could not resolve host", capture.trimmed().?);
}

test "StderrCapture ignores empty stderr" {
    var capture = StderrCapture{};
    const raw = " \n\t ";
    @memcpy(capture.buffer[0..raw.len], raw);
    capture.len = raw.len;

    try std.testing.expect(capture.trimmed() == null);
}

test "normalizeProxyEnvValue trims surrounding whitespace" {
    const alloc = std.testing.allocator;
    const normalized = try normalizeProxyEnvValue(alloc, "  socks5://127.0.0.1:1080 \r\n");
    defer if (normalized) |v| alloc.free(v);
    try std.testing.expect(normalized != null);
    try std.testing.expectEqualStrings("socks5://127.0.0.1:1080", normalized.?);
}

test "normalizeProxyEnvValue rejects empty values" {
    const normalized = try normalizeProxyEnvValue(std.testing.allocator, " \t\r\n");
    try std.testing.expect(normalized == null);
}

test "setProxyOverride applies and clears process-wide override" {
    const override = "  socks5://proxy-override-test.invalid:1080  ";
    const normalized_override = "socks5://proxy-override-test.invalid:1080";

    try setProxyOverride(override);
    defer setProxyOverride(null) catch unreachable;
    const from_override = try getProxyFromEnv(std.testing.allocator);
    defer if (from_override) |v| std.testing.allocator.free(v);
    try std.testing.expect(from_override != null);
    try std.testing.expectEqualStrings(normalized_override, from_override.?);
    var selected = try getProxyForUrl(std.testing.allocator, "https://example.com/");
    defer selected.deinit(std.testing.allocator);
    try std.testing.expect(selected.force);
    try std.testing.expectEqualStrings(normalized_override, selected.value.?);

    // Regression: streaming curl callers must not let inherited NO_PROXY
    // silently bypass an explicit config proxy override.
    var config = try prepareProtectedCurlConfigFromEnvironment(std.testing.allocator, "https://example.com/");
    defer config.deinit();
    const config_file = try std_compat.fs.openFileAbsolute(config.path(), .{});
    defer config_file.close();
    const config_content = try config_file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(config_content);
    try std.testing.expect(std.mem.indexOf(u8, config_content, "noproxy = \"\"") != null);

    try setProxyOverride(null);
    const after_clear = try getProxyFromEnv(std.testing.allocator);
    defer if (after_clear) |v| std.testing.allocator.free(v);
    if (after_clear) |proxy| {
        // Environment may define a proxy; only assert our override no longer leaks.
        try std.testing.expect(!std.mem.eql(u8, proxy, normalized_override));
    }
}

test "setProxyOverride accepts long proxy URLs" {
    const allocator = std.testing.allocator;
    var long_proxy = try allocator.alloc(u8, 1600);
    defer allocator.free(long_proxy);

    @memcpy(long_proxy[0.."http://".len], "http://");
    @memset(long_proxy["http://".len..], 'a');

    try setProxyOverride(long_proxy);
    defer setProxyOverride(null) catch unreachable;

    const from_override = try getProxyFromEnv(allocator);
    defer if (from_override) |v| allocator.free(v);
    try std.testing.expect(from_override != null);
    try std.testing.expectEqual(long_proxy.len, from_override.?.len);
}

test "getProxyFromEnvMap honors lowercase https_proxy before http_proxy" {
    var env_map = std_compat.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put("http_proxy", "http://http-only.example:8080");
    try env_map.put("https_proxy", "https://secure.example:8443");

    const proxy = try getProxyFromEnvMap(std.testing.allocator, &env_map, &https_proxy_env_var_names);
    defer if (proxy) |value| std.testing.allocator.free(value);

    try std.testing.expect(proxy != null);
    try std.testing.expectEqualStrings("https://secure.example:8443", proxy.?);
}

test "applyProxyOverrideToEnvMap overwrites existing proxy values" {
    var env_map = std_compat.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put("HTTPS_PROXY", "https://old.example:9443");
    try setProxyOverride("  socks5://override.example:1080  ");
    defer setProxyOverride(null) catch unreachable;

    try std.testing.expect(try applyProxyOverrideToEnvMap(&env_map));
    try std.testing.expectEqualStrings("socks5://override.example:1080", env_map.get("HTTPS_PROXY").?);
    try std.testing.expectEqualStrings("socks5://override.example:1080", env_map.get("http_proxy").?);
}

test "initClientDefaultProxiesFromEnvMap parses proxy settings" {
    var env_map = std_compat.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put("http_proxy", "http://proxy-http.example:8080");
    try env_map.put("HTTPS_PROXY", "https://proxy-https.example:8443");

    var proxy_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer proxy_arena.deinit();

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    // Regression: Zig 0.16 requires an explicit environ map for initDefaultProxies.
    try initClientDefaultProxiesFromEnvMap(&client, proxy_arena.allocator(), &env_map);

    try std.testing.expect(client.http_proxy != null);
    try std.testing.expect(client.https_proxy != null);
    try std.testing.expectEqual(@as(u16, 8080), client.http_proxy.?.port);
    try std.testing.expectEqual(@as(u16, 8443), client.https_proxy.?.port);
    try std.testing.expect(client.http_proxy.?.host.eql(try std.Io.net.HostName.init("proxy-http.example")));
    try std.testing.expect(client.https_proxy.?.host.eql(try std.Io.net.HostName.init("proxy-https.example")));
}

const StalledSocketCtx = struct {
    server: *std_compat.net.Server,
    accepted: AtomicBool = AtomicBool.init(false),
    release: AtomicBool = AtomicBool.init(false),
};

/// Accept one connection and never reply, holding the socket open. This is the
/// incident's stalled `getUpdates` socket: the peer is gone but no FIN/RST ever
/// arrives, so an untimed read blocks until TCP keepalive (default 2h).
fn serveStalledSocket(ctx: *StalledSocketCtx) void {
    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();
    ctx.accepted.store(true, .release);
    while (!ctx.release.load(.acquire)) std_compat.thread.sleep(5 * std.time.ns_per_ms);
}

// Regression: a Telegram-style long poll whose socket is silently dropped must
// return a timeout error instead of hanging the polling thread forever - the
// untimed `std.http` client has no read timeout in Zig 0.16. The bounded helper
// must enforce curl's `--max-time`.
test "bounded http post times out instead of hanging on a stalled socket" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    var ctx = StalledSocketCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, serveStalledSocket, .{&ctx});

    const url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/bot-test-token/getUpdates",
        .{server.listen_address.in.getPort()},
    );
    defer allocator.free(url);

    const start = std_compat.time.nanoTimestamp();
    const result = httpPostJsonWithProxyTimeout(allocator, url, "{\"timeout\":30}", &.{}, "", "2");
    const elapsed = std_compat.time.nanoTimestamp() - start;

    if (result) |body| {
        allocator.free(body);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(@as(anyerror, error.CurlTimeout), err);
    }
    // The bound must fire long before any TCP retransmit/keepalive timeout.
    try std.testing.expect(elapsed < 10 * std.time.ns_per_s);

    ctx.release.store(true, .release);
    thread.join();
}

const FixedHttpResponseCtx = struct {
    server: *std_compat.net.Server,
    stop: *AtomicBool,
    status_line: []const u8,
    body: []const u8,
};

/// Accept one connection, drain the request, and reply with a fixed status line
/// and body. `Connection: close` lets curl finish the response.
fn serveFixedHttpResponse(ctx: *FixedHttpResponseCtx) void {
    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();
    // The test's stop path connects once to release a blocked accept on
    // Windows; don't answer that wake-up connection.
    if (ctx.stop.load(.acquire)) return;
    var req_buf: [4096]u8 = undefined;
    _ = conn.stream.read(&req_buf) catch {};
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "{s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ ctx.status_line, ctx.body.len }) catch return;
    conn.stream.writeAll(head) catch {};
    conn.stream.writeAll(ctx.body) catch {};
}

/// Stop a one-shot response server even if curl never connected. Windows
/// cannot poll `accept` (see compat/net.zig), so a single connect releases a
/// thread parked in it; joining afterwards is then bounded.
fn stopFixedHttpServer(ctx: *FixedHttpResponseCtx, thread: std.Thread) void {
    ctx.stop.store(true, .release);
    if (std_compat.net.tcpConnectToAddress(ctx.server.listen_address)) |stream| {
        stream.close();
    } else |_| {}
    thread.join();
}

// Regression: the bounded GET must keep `httpRequest`'s error identity - a
// non-2xx is `error.HttpStatusError`, not curl `--fail`'s `error.CurlFailed`.
test "bounded http get maps a non-2xx to HttpStatusError" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    var stop = AtomicBool.init(false);
    var ctx = FixedHttpResponseCtx{ .server = &server, .stop = &stop, .status_line = "HTTP/1.1 404 Not Found", .body = "" };
    const thread = try std.Thread.spawn(.{}, serveFixedHttpResponse, .{&ctx});
    defer stopFixedHttpServer(&ctx, thread);

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/missing", .{server.listen_address.in.getPort()});
    defer allocator.free(url);

    const result = httpGetWithProxyTimeout(allocator, url, &.{}, "", "5", 1024);

    if (result) |body| {
        allocator.free(body);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(@as(anyerror, error.HttpStatusError), err);
    }
}

fn expectBoundedPostError(status_line: []const u8, expected: anyerror) !void {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    var stop = AtomicBool.init(false);
    var ctx = FixedHttpResponseCtx{ .server = &server, .stop = &stop, .status_line = status_line, .body = "" };
    const thread = try std.Thread.spawn(.{}, serveFixedHttpResponse, .{&ctx});
    defer stopFixedHttpServer(&ctx, thread);

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/send", .{server.listen_address.in.getPort()});
    defer allocator.free(url);

    const result = httpRequestWithTimeout(allocator, .POST, url, null, &.{}, null, null, "5");

    if (result) |body| {
        allocator.free(body);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(expected, @as(anyerror, err));
    }
}

test "bounded POST maps gateway 502/504 to an indeterminate send error" {
    try expectBoundedPostError("HTTP/1.1 502 Bad Gateway", error.HttpStatusIndeterminate);
    try expectBoundedPostError("HTTP/1.1 504 Gateway Timeout", error.HttpStatusIndeterminate);
}

test "bounded POST keeps definite 4xx/429/503 as HttpStatusError" {
    try expectBoundedPostError("HTTP/1.1 400 Bad Request", error.HttpStatusError);
    try expectBoundedPostError("HTTP/1.1 429 Too Many Requests", error.HttpStatusError);
    try expectBoundedPostError("HTTP/1.1 503 Service Unavailable", error.HttpStatusError);
}

// Slack's chat.postMessage goes through curlPost, whose credentialed (std)
// backend previously discarded the status before the channel could classify it.
test "curlPost maps gateway 502 to an indeterminate send error" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    var stop = AtomicBool.init(false);
    var ctx = FixedHttpResponseCtx{ .server = &server, .stop = &stop, .status_line = "HTTP/1.1 502 Bad Gateway", .body = "" };
    const thread = try std.Thread.spawn(.{}, serveFixedHttpResponse, .{&ctx});
    defer stopFixedHttpServer(&ctx, thread);

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/chat.postMessage", .{server.listen_address.in.getPort()});
    defer allocator.free(url);

    const result = curlPost(allocator, url, "{}", &.{"Authorization: Bearer test-token"});

    if (result) |body| {
        allocator.free(body);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(@as(anyerror, error.HttpStatusIndeterminate), err);
    }
}

// Regression: the bounded status-preserving request must keep httpRequestWithStatus'
// contract - a non-2xx is returned with its body (not turned into an error) - so
// Weixin can still read the error payload, unlike httpRequestWithTimeout.
test "bounded http request with status preserves a non-2xx body" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    var stop = AtomicBool.init(false);
    var ctx = FixedHttpResponseCtx{ .server = &server, .stop = &stop, .status_line = "HTTP/1.1 401 Unauthorized", .body = "{\"error\":\"nope\"}" };
    const thread = try std.Thread.spawn(.{}, serveFixedHttpResponse, .{&ctx});
    defer stopFixedHttpServer(&ctx, thread);

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/guarded", .{server.listen_address.in.getPort()});
    defer allocator.free(url);

    const resp = httpRequestWithStatusTimeout(allocator, .DELETE, url, null, &.{}, null, "", "5") catch return error.TestUnexpectedResult;
    defer allocator.free(resp.body);

    try std.testing.expectEqual(@as(u16, 401), resp.status_code);
    try std.testing.expectEqualStrings("{\"error\":\"nope\"}", resp.body);
}

// Regression: the bounded GET must enforce its size cap, so a caller that needs
// a larger body (a media download) has to opt into a bigger cap explicitly
// rather than silently truncating.
test "bounded http get enforces the response size cap" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    const big_body = try allocator.alloc(u8, 4096);
    defer allocator.free(big_body);
    @memset(big_body, 'x');

    var stop = AtomicBool.init(false);
    var ctx = FixedHttpResponseCtx{ .server = &server, .stop = &stop, .status_line = "HTTP/1.1 200 OK", .body = big_body };
    const thread = try std.Thread.spawn(.{}, serveFixedHttpResponse, .{&ctx});
    defer stopFixedHttpServer(&ctx, thread);

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/doc", .{server.listen_address.in.getPort()});
    defer allocator.free(url);

    const result = httpGetWithProxyTimeout(allocator, url, &.{}, "", "5", 64);

    if (result) |body| {
        allocator.free(body);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(@as(anyerror, error.CurlReadError), err);
    }
}

// Regression: readToEndAlloc(.limited(n)) returned StreamTooLong for a body
// exactly n bytes long, so a response at the cap surfaced as CurlReadError.
test "bounded http get accepts a body exactly at the size cap" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    const body = try allocator.alloc(u8, 4096);
    defer allocator.free(body);
    @memset(body, 'x');

    var stop = AtomicBool.init(false);
    var ctx = FixedHttpResponseCtx{ .server = &server, .stop = &stop, .status_line = "HTTP/1.1 200 OK", .body = body };
    const thread = try std.Thread.spawn(.{}, serveFixedHttpResponse, .{&ctx});
    defer stopFixedHttpServer(&ctx, thread);

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/doc", .{server.listen_address.in.getPort()});
    defer allocator.free(url);

    const result = httpGetWithProxyTimeout(allocator, url, &.{}, "", "5", body.len);

    const fetched = try result;
    defer allocator.free(fetched);
    try std.testing.expectEqualStrings(body, fetched);
}

// Regression: web_fetch turned a 4 MiB+ page into "Fetch failed:
// error.CurlReadError" instead of returning the content it could read.
test "web fetch get truncates an oversized body at a utf-8 boundary" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    // 1023 ASCII bytes then a 2-byte code point: a 1024-byte cut splits it.
    var body = try allocator.alloc(u8, 2048);
    defer allocator.free(body);
    @memset(body, 'x');
    body[1023] = 0xC3;
    body[1024] = 0xA9;

    var stop = AtomicBool.init(false);
    var ctx = FixedHttpResponseCtx{ .server = &server, .stop = &stop, .status_line = "HTTP/1.1 200 OK", .body = body };
    const thread = try std.Thread.spawn(.{}, serveFixedHttpResponse, .{&ctx});
    defer stopFixedHttpServer(&ctx, thread);

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/large", .{server.listen_address.in.getPort()});
    defer allocator.free(url);

    const response = try curlGetForWebFetch(allocator, url, &.{}, "5", null, 1024);
    defer allocator.free(response.body);
    defer allocator.free(response.headers);

    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expect(response.truncated);
    try std.testing.expectEqual(@as(usize, 1023), response.body.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(response.body));
}

// Regression: complete code points at the cap were cut to a bare lead byte,
// leaving the tool result invalid UTF-8.
test "trimToUtf8Prefix keeps complete code points and drops cut ones" {
    const three = [_]u8{ 'a', 0xE4, 0xB8, 0xAD };
    const three_end = trimToUtf8Prefix(&three);
    try std.testing.expectEqual(@as(usize, 4), three_end);
    try std.testing.expect(std.unicode.utf8ValidateSlice(three[0..three_end]));

    const four = [_]u8{ 'a', 0xF0, 0x9F, 0x98, 0x80 };
    const four_end = trimToUtf8Prefix(&four);
    try std.testing.expectEqual(@as(usize, 5), four_end);
    try std.testing.expect(std.unicode.utf8ValidateSlice(four[0..four_end]));

    const three_cut = [_]u8{ 'a', 0xE4, 0xB8 };
    const three_cut_end = trimToUtf8Prefix(&three_cut);
    try std.testing.expectEqual(@as(usize, 1), three_cut_end);
    try std.testing.expect(std.unicode.utf8ValidateSlice(three_cut[0..three_cut_end]));

    const four_cut = [_]u8{ 'a', 0xF0, 0x9F, 0x98 };
    const four_cut_end = trimToUtf8Prefix(&four_cut);
    try std.testing.expectEqual(@as(usize, 1), four_cut_end);
    try std.testing.expect(std.unicode.utf8ValidateSlice(four_cut[0..four_cut_end]));
}

// Regression: a body ending in four or more continuation bytes was trimmed to
// zero, discarding the entire page instead of keeping the valid prefix.
test "trimToUtf8Prefix keeps the valid prefix when trailing continuations run long" {
    const body = [_]u8{ 'a', 0xE4, 0xB8, 0xAD, 0x80, 0x80, 0x80 };
    const end = trimToUtf8Prefix(&body);
    try std.testing.expectEqual(@as(usize, 4), end);
    try std.testing.expect(std.unicode.utf8ValidateSlice(body[0..end]));
}

// Regression: trimToUtf8Prefix 在完整码点边界截断时留下裸 lead byte，工具结果非法 UTF-8
test "web fetch get keeps a complete code point at the truncation cap" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    // 1021 ASCII bytes then a complete 3-byte code point ending exactly at the cap.
    var body = try allocator.alloc(u8, 2048);
    defer allocator.free(body);
    @memset(body, 'x');
    body[1021] = 0xE4;
    body[1022] = 0xB8;
    body[1023] = 0xAD;

    var stop = AtomicBool.init(false);
    var ctx = FixedHttpResponseCtx{ .server = &server, .stop = &stop, .status_line = "HTTP/1.1 200 OK", .body = body };
    const thread = try std.Thread.spawn(.{}, serveFixedHttpResponse, .{&ctx});
    defer stopFixedHttpServer(&ctx, thread);

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/large", .{server.listen_address.in.getPort()});
    defer allocator.free(url);

    const response = try curlGetForWebFetch(allocator, url, &.{}, "5", null, 1024);
    defer allocator.free(response.body);
    defer allocator.free(response.headers);

    try std.testing.expect(response.truncated);
    try std.testing.expectEqual(@as(usize, 1024), response.body.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(response.body));
    try std.testing.expectEqualSlices(u8, &.{ 0xE4, 0xB8, 0xAD }, response.body[1021..1024]);
}

// Regression: web_fetch only received error.CurlFailed for any 4xx; the status
// and body must survive so the tool can explain the failure.
test "web fetch get keeps a non-2xx status and body" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    var stop = AtomicBool.init(false);
    var ctx = FixedHttpResponseCtx{ .server = &server, .stop = &stop, .status_line = "HTTP/1.1 429 Too Many Requests", .body = "slow down" };
    const thread = try std.Thread.spawn(.{}, serveFixedHttpResponse, .{&ctx});
    defer stopFixedHttpServer(&ctx, thread);

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/limited", .{server.listen_address.in.getPort()});
    defer allocator.free(url);

    const response = try curlGetForWebFetch(allocator, url, &.{}, "5", null, DEFAULT_CURL_GET_MAX_BYTES);
    defer allocator.free(response.body);
    defer allocator.free(response.headers);

    try std.testing.expectEqual(@as(u16, 429), response.status_code);
    try std.testing.expectEqualStrings("slow down", response.body);
    try std.testing.expect(std.mem.indexOf(u8, response.headers, "429 Too Many Requests") != null);
}

// Regression: a stalled web_fetch connection used to end as a generic fetch
// failure; it must stay distinguishable as a timeout.
test "web fetch get reports a timeout" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    var ctx = StalledSocketCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, serveStalledSocket, .{&ctx});

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/stall", .{server.listen_address.in.getPort()});
    defer allocator.free(url);

    const result = curlGetForWebFetch(allocator, url, &.{}, "1", null, DEFAULT_CURL_GET_MAX_BYTES);
    if (result) |response| {
        allocator.free(response.body);
        allocator.free(response.headers);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(@as(anyerror, error.CurlTimeout), err);
    }

    ctx.release.store(true, .release);
    thread.join();
}

const StalledCredentialCtx = struct {
    server: *std_compat.net.Server,
    release: AtomicBool = AtomicBool.init(false),
};

fn serveStalledCredential(ctx: *StalledCredentialCtx) void {
    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();
    const deadline = std_compat.time.nanoTimestamp() + 10 * std.time.ns_per_s;
    while (!ctx.release.load(.acquire) and std_compat.time.nanoTimestamp() < deadline) {
        std_compat.thread.sleep(5 * std.time.ns_per_ms);
    }
}

// Regression: a credentialed request must not silently fall back to the untimed
// std.http client (`curlRequestWithProxy` does exactly that, dropping the bound).
// A stalled socket with an Authorization header must still return error.CurlTimeout.
test "bounded http request keeps the timeout for a credentialed request" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    var ctx = StalledCredentialCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, serveStalledCredential, .{&ctx});

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/join", .{server.listen_address.in.getPort()});
    defer allocator.free(url);

    const headers = [_][]const u8{"Authorization: Bearer secret-token"};
    const start = std_compat.time.nanoTimestamp();
    const result = httpRequestWithTimeout(allocator, .POST, url, "{}", &headers, "application/json", "", "2");
    const elapsed = std_compat.time.nanoTimestamp() - start;

    if (result) |body| {
        allocator.free(body);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(@as(anyerror, error.CurlTimeout), err);
    }
    try std.testing.expect(elapsed < 6 * std.time.ns_per_s);

    ctx.release.store(true, .release);
    thread.join();
}

// Regression: the status-preserving bounded request (the Matrix poller's
// /sync long poll routes through it) must keep the timeout for a credentialed
// GET instead of falling back to the untimed std.http client.
test "bounded status request keeps the timeout for a credentialed get" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    var ctx = StalledCredentialCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, serveStalledCredential, .{&ctx});

    const url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/_matrix/client/v3/sync?timeout=30000",
        .{server.listen_address.in.getPort()},
    );
    defer allocator.free(url);

    const headers = [_][]const u8{"Authorization: Bearer secret-token"};
    const start = std_compat.time.nanoTimestamp();
    const result = httpRequestWithStatusTimeout(allocator, .GET, url, null, &headers, null, null, "2");
    const elapsed = std_compat.time.nanoTimestamp() - start;

    if (result) |resp| {
        allocator.free(resp.body);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(@as(anyerror, error.CurlTimeout), err);
    }
    try std.testing.expect(elapsed < 6 * std.time.ns_per_s);

    ctx.release.store(true, .release);
    thread.join();
}

test "curlPostRawWithContentType rejects header injection before any request" {
    // The raw upload helper is the only caller that builds a Content-Type from
    // data, so a CRLF must be rejected while validating headers.
    try std.testing.expectError(
        error.InvalidHeader,
        curlPostRawWithContentType(
            std.testing.allocator,
            "https://example.com/upload",
            "bytes",
            "image/png\r\nX-Injected: 1",
            &.{},
            null,
        ),
    );
}

const StdHttpTestServerCtx = struct {
    server: *std_compat.net.Server,
    body: []const u8,
    saw_post_body: AtomicBool = AtomicBool.init(false),
};

fn serveStdHttpTest(ctx: *StdHttpTestServerCtx) void {
    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();

    var buf: [8192]u8 = undefined;
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = conn.stream.read(buf[filled..]) catch return;
        if (n == 0) break;
        filled += n;
        if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n") != null) break;
    }
    if (std.mem.indexOf(u8, buf[0..filled], "{\"ping\":true}") != null) {
        ctx.saw_post_body.store(true, .release);
    }

    var head_buf: [256]u8 = undefined;
    const response = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ctx.body.len},
    ) catch return;
    conn.stream.writeAll(response) catch {};
    conn.stream.writeAll(ctx.body) catch {};
}

test "android std http keeps status body headers and post payload" {
    // Windows: the loopback mock server thread does not complete there. The std
    // transport is Android-only; Windows goes through curl (tested elsewhere).
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    const addr = try std_compat.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{});
    var ctx: StdHttpTestServerCtx = .{ .server = &server, .body = "{\"ok\":true}" };
    var thread = try std.Thread.spawn(.{}, serveStdHttpTest, .{&ctx});
    defer thread.join();
    defer server.deinit();

    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/test",
        .{server.listen_address.in.getPort()},
    );
    defer std.testing.allocator.free(url);

    const response = try stdHttpRequest(std.testing.allocator, .{
        .method = .POST,
        .url = url,
        .body = "{\"ping\":true}",
        .headers = &.{"X-Test: yes"},
        .content_type = "application/json",
    });
    defer std.testing.allocator.free(response.headers);
    defer std.testing.allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expectEqualStrings("{\"ok\":true}", response.body);
    try std.testing.expect(std.mem.indexOf(u8, response.headers, "application/json") != null);
    try std.testing.expect(ctx.saw_post_body.load(.acquire));
}

test "android std http response cap rejects and truncates" {
    // Windows: the loopback mock server thread does not complete there. The std
    // transport is Android-only; Windows goes through curl (tested elsewhere).
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    const addr = try std_compat.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{});
    var ctx: StdHttpTestServerCtx = .{ .server = &server, .body = "0123456789" };
    var thread = try std.Thread.spawn(.{}, serveStdHttpTest, .{&ctx});
    defer thread.join();
    defer server.deinit();

    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/cap",
        .{server.listen_address.in.getPort()},
    );
    defer std.testing.allocator.free(url);

    try std.testing.expectError(error.CurlReadError, stdHttpRequest(std.testing.allocator, .{
        .method = .GET,
        .url = url,
        .max_response_bytes = 4,
    }));

    var server2 = try addr.listen(.{});
    var ctx2: StdHttpTestServerCtx = .{ .server = &server2, .body = "0123456789" };
    var thread2 = try std.Thread.spawn(.{}, serveStdHttpTest, .{&ctx2});
    defer thread2.join();
    defer server2.deinit();

    const url2 = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/truncate",
        .{server2.listen_address.in.getPort()},
    );
    defer std.testing.allocator.free(url2);

    const response = try stdHttpRequest(std.testing.allocator, .{
        .method = .GET,
        .url = url2,
        .max_response_bytes = 4,
        .truncate_response = true,
    });
    defer std.testing.allocator.free(response.headers);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqualStrings("0123", response.body);
    try std.testing.expect(response.truncated);
}

test "android std http rejects proxies it cannot honor" {
    try std.testing.expectError(error.UnsupportedProxyScheme, validateStdProxyScheme("socks5://127.0.0.1:1080"));
    try std.testing.expectError(error.UnsupportedProxyScheme, validateStdProxyForUrl(
        std.testing.allocator,
        "https://example.com",
        "socks5://127.0.0.1:1080",
    ));
    try validateStdProxyScheme("http://proxy.example:8080");
    try validateStdProxyScheme("https://proxy.example:8443");
}

test "android std http treats head and empty frames as bodyless" {
    try std.testing.expect(!hasResponseBody(.HEAD, .ok, .none, 12));
    try std.testing.expect(!hasResponseBody(.GET, .no_content, .none, null));
    try std.testing.expect(!hasResponseBody(.DELETE, .not_modified, .none, 4));
    try std.testing.expect(!hasResponseBody(.POST, .ok, .none, 0));
    try std.testing.expect(hasResponseBody(.GET, .ok, .none, 12));
    try std.testing.expect(hasResponseBody(.GET, .ok, .chunked, null));
    try std.testing.expect(hasResponseBody(.GET, .ok, .none, null));
}
