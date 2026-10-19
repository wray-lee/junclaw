const std = @import("std");
const json_miniparse = @import("../json_miniparse.zig");

// Per-turn tool-progress state for live channel previews.
//
// Modelled on OpenClaw's Telegram progress draft
// (openclaw/openclaw fead50a35107ed73cbb1f34b93c21716a0583f98:
// extensions/telegram/src/progress-draft-preview.ts and
// bot-message-dispatch-progress.ts, docs/channels/telegram/messaging.md
// "Tool-progress lines"): while a turn runs tools and has produced no answer
// text yet, the preview shows elapsed time, how many tool calls have run, and a
// short rolling log. Hints are deliberately conservative so a tool call can
// never leak its raw command into a chat.

/// Max codepoints in one rendered progress line.
pub const LINE_MAX_CHARS: usize = 60;
/// How many tool lines the rendered block shows.
pub const MAX_VISIBLE_LINES: usize = 5;
/// Truncation budget for a `web_search` query hint.
pub const QUERY_MAX_CHARS: usize = 40;
/// Hard cap on retained lines so a very tool-heavy turn cannot grow unbounded.
pub const MAX_STORED_LINES: usize = 32;

pub const Phase = enum { start, end };

/// What one progress update describes.
pub const Kind = enum { tool, retry };

/// Retry attempt numbers carried by `.retry` updates.
pub const RetryInfo = struct {
    /// 1-based retry number; 0 clears the indicator.
    attempt: u32 = 0,
    /// Total retries allowed by the provider wrapper.
    max: u32 = 0,
};

/// One progress event as it arrives from the agent loop.
pub const Update = struct {
    kind: Kind = .tool,
    /// Tool name as reported by the agent (never the raw command).
    tool: []const u8 = "",
    /// Raw JSON arguments of the call. Only a few safe fields are read to build
    /// a short hint; the raw blob itself is never rendered.
    arguments_json: ?[]const u8 = null,
    phase: Phase = .start,
    success: bool = true,
    /// Retry numbers for `.retry` updates.
    retry: RetryInfo = .{},
};

/// One stored progress line. `text` is owned by the state.
pub const Line = struct {
    text: []u8,
    failed: bool,
};

pub const ToolProgress = struct {
    started_at_ms: i64 = 0,
    tool_calls: u32 = 0,
    lines: std.ArrayListUnmanaged(Line) = .empty,
    /// The visible log changed since the last draft render. A presenter that
    /// cannot flush right now (chunk throttle) leaves this set and retries on
    /// the next heartbeat, so a tool event is never dropped.
    dirty: bool = false,
    /// The tool block has been rendered at least once this turn. The first
    /// render bypasses the chunk throttle (OpenClaw's `startImmediately`), so
    /// the first tool call is visible as soon as it starts.
    rendered: bool = false,
    /// Latest provider-retry indicator. Replaced in place so the block shows a
    /// single line no matter how many retries run; null hides it.
    retry: ?RetryInfo = null,
    /// A retry indicator was cleared but the draft still shows it. Lets
    /// `progressDraft` refresh the draft even though the block is now empty.
    needs_clear: bool = false,

    pub fn deinit(self: *ToolProgress, allocator: std.mem.Allocator) void {
        for (self.lines.items) |line| allocator.free(line.text);
        self.lines.deinit(allocator);
        self.* = .{};
    }

    /// Drop all per-turn state and restart the elapsed clock.
    pub fn reset(self: *ToolProgress, allocator: std.mem.Allocator, now_ms: i64) void {
        self.deinit(allocator);
        self.started_at_ms = now_ms;
    }

    pub fn hasContent(self: *const ToolProgress) bool {
        return self.lines.items.len > 0 or self.retry != null;
    }

    /// Mark the current log as rendered. Clears `dirty` so the heartbeat stops
    /// retrying it; also records that the first (throttle-bypassing) render has
    /// happened.
    pub fn markRendered(self: *ToolProgress) void {
        self.dirty = false;
        self.rendered = true;
        self.needs_clear = false;
    }

    /// Record one tool event. Returns true when the visible log changed (a
    /// start line, or a failure line); a successful `.end` is a no-op so callers
    /// can skip a redundant draft re-render.
    pub fn record(self: *ToolProgress, allocator: std.mem.Allocator, update: Update, now_ms: i64) !bool {
        if (self.started_at_ms == 0) self.started_at_ms = now_ms;

        if (update.kind == .retry) {
            if (update.retry.attempt == 0) {
                if (self.retry == null) return false;
                self.retry = null;
                self.needs_clear = true;
            } else {
                if (self.retry) |current| {
                    if (current.attempt == update.retry.attempt and current.max == update.retry.max) {
                        return false;
                    }
                }
                self.retry = .{ .attempt = update.retry.attempt, .max = update.retry.max };
            }
            self.dirty = true;
            return true;
        }

        // A real tool event means the retried call resumed; drop a stale
        // indicator so the draft does not claim a retry is still running.
        const had_retry = self.retry != null;
        self.retry = null;
        if (had_retry) self.needs_clear = true;

        switch (update.phase) {
            .start => {
                self.tool_calls +|= 1;
                const line = try buildStartLine(allocator, update.tool, update.arguments_json);
                errdefer allocator.free(line);
                try self.appendLine(allocator, .{ .text = line, .failed = false });
                self.dirty = true;
                return true;
            },
            .end => {
                // Successes stay as their start line; only failures add a line,
                // so the log reads like the OpenClaw tool-progress log.
                if (update.success) return had_retry;
                const line = try buildFailureLine(allocator, update.tool);
                errdefer allocator.free(line);
                try self.appendLine(allocator, .{ .text = line, .failed = true });
                self.dirty = true;
                return true;
            },
        }
    }

    fn appendLine(self: *ToolProgress, allocator: std.mem.Allocator, line: Line) !void {
        try self.lines.append(allocator, line);
        while (self.lines.items.len > MAX_STORED_LINES) {
            // Prefer to forget an old success over a failure.
            var drop: usize = 0;
            for (self.lines.items, 0..) |entry, idx| {
                if (!entry.failed) {
                    drop = idx;
                    break;
                }
            }
            const removed = self.lines.orderedRemove(drop);
            allocator.free(removed.text);
        }
    }

    /// Render the progress block as plain text (no HTML escaping).
    pub fn renderBlock(self: *const ToolProgress, allocator: std.mem.Allocator, now_ms: i64) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        const elapsed_ms = if (self.started_at_ms > 0 and now_ms > self.started_at_ms)
            now_ms - self.started_at_ms
        else
            0;
        const elapsed_secs = @divFloor(elapsed_ms, std.time.ms_per_s);
        const calls = self.tool_calls;
        try out.print(allocator, "\u{23F3} {d}s \u{00B7} {d} tool call{s}", .{
            elapsed_secs,
            calls,
            if (calls == 1) "" else "s",
        });

        if (self.lines.items.len == 0) {
            if (self.retry) |retry| {
                try out.print(allocator, " \u{00B7} Retrying ({d}/{d})\u{2026}", .{ retry.attempt, retry.max });
            }
            return out.toOwnedSlice(allocator);
        }

        var selected: [MAX_VISIBLE_LINES]usize = undefined;
        const count = self.selectVisible(&selected);
        for (selected[0..count]) |idx| {
            try out.append(allocator, '\n');
            try out.appendSlice(allocator, self.lines.items[idx].text);
        }
        if (self.retry) |retry| {
            try out.print(allocator, "\nRetrying ({d}/{d})\u{2026}", .{ retry.attempt, retry.max });
        }
        return out.toOwnedSlice(allocator);
    }

    /// Render the progress block as HTML for Telegram drafts (parse_mode HTML).
    pub fn renderBlockHtml(self: *const ToolProgress, allocator: std.mem.Allocator, now_ms: i64) ![]u8 {
        const plain = try self.renderBlock(allocator, now_ms);
        defer allocator.free(plain);
        return escapeHtml(allocator, plain);
    }

    /// Newest `MAX_VISIBLE_LINES` lines, keeping failures visible over successes
    /// when trimming, returned in chronological order.
    fn selectVisible(self: *const ToolProgress, out: *[MAX_VISIBLE_LINES]usize) usize {
        var count: usize = 0;
        var i = self.lines.items.len;
        while (i > 0 and count < MAX_VISIBLE_LINES) {
            i -= 1;
            if (self.lines.items[i].failed) {
                out[count] = i;
                count += 1;
            }
        }
        i = self.lines.items.len;
        while (i > 0 and count < MAX_VISIBLE_LINES) {
            i -= 1;
            if (!self.lines.items[i].failed) {
                out[count] = i;
                count += 1;
            }
        }
        std.mem.sort(usize, out[0..count], {}, std.sort.asc(usize));
        return count;
    }
};

fn buildStartLine(allocator: std.mem.Allocator, tool: []const u8, arguments_json: ?[]const u8) ![]u8 {
    // The tool name is model-controlled, so strip control bytes from it too: a
    // newline in a name would otherwise inject an extra line into the block.
    const safe_tool = try clean(allocator, tool);
    defer allocator.free(safe_tool);

    const hint = try hintForTool(allocator, safe_tool, arguments_json);
    defer allocator.free(hint);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "\u{1F527} ");
    try out.appendSlice(allocator, safe_tool);
    if (hint.len > 0 and !std.mem.eql(u8, hint, safe_tool)) {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, hint);
    }

    const clamped = try clampUtf8(allocator, out.items, LINE_MAX_CHARS);
    out.deinit(allocator);
    return clamped;
}

fn buildFailureLine(allocator: std.mem.Allocator, tool: []const u8) ![]u8 {
    const safe_tool = try clean(allocator, tool);
    defer allocator.free(safe_tool);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "\u{274C} {s} failed", .{safe_tool});
    const clamped = try clampUtf8(allocator, out.items, LINE_MAX_CHARS);
    out.deinit(allocator);
    return clamped;
}

/// Build a short, conservative hint for a tool call. Never returns the raw
/// command: shell/exec and unknown tools fall back to the tool name alone.
fn hintForTool(allocator: std.mem.Allocator, tool: []const u8, arguments_json: ?[]const u8) ![]u8 {
    if (isFileTool(tool)) {
        if (rawField(arguments_json, "path")) |path| {
            const cleaned = try clean(allocator, path);
            defer allocator.free(cleaned);
            return clampUtf8(allocator, basename(cleaned), LINE_MAX_CHARS);
        }
    } else if (isUrlTool(tool)) {
        if (rawField(arguments_json, "url")) |url| {
            const cleaned = try clean(allocator, url);
            defer allocator.free(cleaned);
            return clampUtf8(allocator, hostFromUrl(cleaned), LINE_MAX_CHARS);
        }
    } else if (std.mem.eql(u8, tool, "web_search")) {
        if (rawField(arguments_json, "query")) |query| {
            const cleaned = try clean(allocator, query);
            defer allocator.free(cleaned);
            return clampUtf8(allocator, cleaned, QUERY_MAX_CHARS);
        }
    }
    // Unknown tools (and any tool whose safe hint we could not derive) fall
    // back to the cleaned tool name alone -- never the raw arguments.
    return clean(allocator, tool);
}

fn isFileTool(tool: []const u8) bool {
    const names = [_][]const u8{
        "file_read",   "file_write",       "file_edit",        "file_append",
        "file_delete", "file_read_hashed", "file_edit_hashed",
    };
    for (names) |name| {
        if (std.mem.eql(u8, tool, name)) return true;
    }
    return false;
}

fn isUrlTool(tool: []const u8) bool {
    return std.mem.eql(u8, tool, "web_fetch") or std.mem.eql(u8, tool, "http_request");
}

fn rawField(arguments_json: ?[]const u8, key: []const u8) ?[]const u8 {
    const json = arguments_json orelse return null;
    return json_miniparse.parseStringField(json, key);
}

/// Drop ASCII control bytes so a hint cannot inject newlines or terminal codes.
fn clean(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (raw) |c| {
        if (c < 0x20 or c == 0x7f) continue;
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

fn basename(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const idx = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[idx + 1 ..];
}

/// Extract just the host from a URL, without scheme, userinfo, port or path.
fn hostFromUrl(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |scheme| rest = rest[scheme + 3 ..];
    var end = rest.len;
    for (rest, 0..) |c, i| {
        if (c == '/' or c == '?' or c == '#') {
            end = i;
            break;
        }
    }
    var host = rest[0..end];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (host.len > 0 and host[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return host;
        return host[0 .. close + 1];
    }
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    return host;
}

pub fn clampUtf8(allocator: std.mem.Allocator, text: []const u8, max_chars: usize) ![]u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len and count < max_chars) {
        const len: usize = @intCast(std.unicode.utf8ByteSequenceLength(text[i]) catch 1);
        i += @min(len, text.len - i);
        count += 1;
    }
    return allocator.dupe(u8, text[0..i]);
}

pub fn escapeHtml(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "record counts starts and renders elapsed with tool count" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    _ = try state.record(std.testing.allocator, .{ .tool = "web_search" }, 1_000);
    _ = try state.record(std.testing.allocator, .{ .tool = "web_fetch", .arguments_json = "{\"url\":\"https://example.com/page\"}" }, 2_000);

    const block = try state.renderBlock(std.testing.allocator, 1_000 + 121 * std.time.ms_per_s);
    defer std.testing.allocator.free(block);

    try std.testing.expect(std.mem.startsWith(u8, block, "\u{23F3} 121s \u{00B7} 2 tool calls"));
    try std.testing.expect(std.mem.indexOf(u8, block, "\u{1F527} web_search") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "\u{1F527} web_fetch example.com") != null);
}

test "hint uses host only for url tools" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    _ = try state.record(std.testing.allocator, .{
        .tool = "web_fetch",
        .arguments_json = "{\"url\":\"https://user:pw@Example.com:8443/a/b?q=1\"}",
    }, 1_000);

    try std.testing.expectEqualStrings("\u{1F527} web_fetch Example.com", state.lines.items[0].text);
}

test "hint uses truncated query for web_search" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    const long_query = "q" ** 100;
    _ = try state.record(std.testing.allocator, .{
        .tool = "web_search",
        .arguments_json = "{\"query\":\"" ++ long_query ++ "\"}",
    }, 1_000);

    const line = state.lines.items[0].text;
    try std.testing.expect(std.mem.startsWith(u8, line, "\u{1F527} web_search "));
    // 40-char query budget plus the "🔧 web_search " prefix.
    try std.testing.expect(line.len <= "\u{1F527} web_search ".len + QUERY_MAX_CHARS);
}

test "hint uses basename for file tools" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    _ = try state.record(std.testing.allocator, .{
        .tool = "file_read",
        .arguments_json = "{\"path\":\"src/deep/nested/config.zig\"}",
    }, 1_000);

    try std.testing.expectEqualStrings("\u{1F527} file_read config.zig", state.lines.items[0].text);
}

test "hint never leaks the raw shell command" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    _ = try state.record(std.testing.allocator, .{
        .tool = "shell",
        .arguments_json = "{\"command\":\"rm -rf /secret\"}",
    }, 1_000);

    try std.testing.expectEqualStrings("\u{1F527} shell", state.lines.items[0].text);
    try std.testing.expect(std.mem.indexOf(u8, state.lines.items[0].text, "rm") == null);
}

test "control bytes in a tool name cannot inject a line" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    // Regression: a model-supplied tool name with a newline used to be appended
    // raw, injecting an extra line into the progress block.
    _ = try state.record(std.testing.allocator, .{ .tool = "evil\nname" }, 1_000);
    try std.testing.expectEqualStrings("\u{1F527} evilname", state.lines.items[0].text);

    _ = try state.record(std.testing.allocator, .{ .tool = "evil\r\nname", .phase = .end, .success = false }, 1_000);
    try std.testing.expectEqualStrings("\u{274C} evilname failed", state.lines.items[1].text);
}

test "failure adds a kept line and successes do not" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    _ = try state.record(std.testing.allocator, .{ .tool = "web_fetch" }, 1_000);
    _ = try state.record(std.testing.allocator, .{ .tool = "web_fetch", .phase = .end, .success = true }, 1_000);
    try std.testing.expectEqual(@as(usize, 1), state.lines.items.len);

    _ = try state.record(std.testing.allocator, .{ .tool = "web_fetch", .phase = .end, .success = false }, 1_000);
    try std.testing.expectEqual(@as(usize, 2), state.lines.items.len);
    try std.testing.expectEqualStrings("\u{274C} web_fetch failed", state.lines.items[1].text);
    try std.testing.expect(state.lines.items[1].failed);
}

test "render keeps failures visible over successes when trimming" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    _ = try state.record(std.testing.allocator, .{ .tool = "s1" }, 1_000);
    _ = try state.record(std.testing.allocator, .{ .tool = "f1", .phase = .end, .success = false }, 1_000);
    _ = try state.record(std.testing.allocator, .{ .tool = "s2" }, 1_000);
    _ = try state.record(std.testing.allocator, .{ .tool = "s3" }, 1_000);
    _ = try state.record(std.testing.allocator, .{ .tool = "s4" }, 1_000);
    _ = try state.record(std.testing.allocator, .{ .tool = "s5" }, 1_000);
    _ = try state.record(std.testing.allocator, .{ .tool = "s6" }, 1_000);

    const block = try state.renderBlock(std.testing.allocator, 1_000);
    defer std.testing.allocator.free(block);

    try std.testing.expect(std.mem.indexOf(u8, block, "f1 failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "s1") == null);
    try std.testing.expect(std.mem.indexOf(u8, block, "s6") != null);
}

test "renderBlockHtml escapes a hostile hint" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    _ = try state.record(std.testing.allocator, .{
        .tool = "web_search",
        .arguments_json = "{\"query\":\"<b>&x</b>\"}",
    }, 1_000);

    const block = try state.renderBlockHtml(std.testing.allocator, 1_000);
    defer std.testing.allocator.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "<b>") == null);
    try std.testing.expect(std.mem.indexOf(u8, block, "&lt;b&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "&amp;x") != null);
}

test "long hints are clamped to the line budget and stay valid UTF-8" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    _ = try state.record(std.testing.allocator, .{
        .tool = "file_read",
        .arguments_json = "{\"path\":\"\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\"}",
    }, 1_000);

    const line = state.lines.items[0].text;
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    var count: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (count += 1) {
        const len: usize = @intCast(std.unicode.utf8ByteSequenceLength(line[i]) catch 1);
        i += len;
    }
    try std.testing.expect(count <= LINE_MAX_CHARS);
}

test "stored lines are capped" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < MAX_STORED_LINES * 2) : (i += 1) {
        _ = try state.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);
    }
    try std.testing.expectEqual(@as(usize, MAX_STORED_LINES), state.lines.items.len);
}

test "reset frees lines and restarts the clock" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    _ = try state.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);
    state.reset(std.testing.allocator, 5_000);
    try std.testing.expectEqual(@as(usize, 0), state.lines.items.len);
    try std.testing.expectEqual(@as(u32, 0), state.tool_calls);
    try std.testing.expectEqual(@as(i64, 5_000), state.started_at_ms);
}

test "dirty tracks visible changes until the presenter renders them" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    _ = try state.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);
    try std.testing.expect(state.dirty);
    try std.testing.expect(!state.rendered);

    state.markRendered();
    try std.testing.expect(!state.dirty);
    try std.testing.expect(state.rendered);

    // A successful end changes nothing on screen.
    _ = try state.record(std.testing.allocator, .{ .tool = "shell", .phase = .end, .success = true }, 1_000);
    try std.testing.expect(!state.dirty);

    // A failure adds a line, so it must be rendered.
    _ = try state.record(std.testing.allocator, .{ .tool = "shell", .phase = .end, .success = false }, 1_000);
    try std.testing.expect(state.dirty);

    state.reset(std.testing.allocator, 5_000);
    try std.testing.expect(!state.dirty);
    try std.testing.expect(!state.rendered);
}

test "retry updates render a single replaceable indicator" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    _ = try state.record(std.testing.allocator, .{ .kind = .retry, .retry = .{ .attempt = 1, .max = 3 } }, 1_000);
    _ = try state.record(std.testing.allocator, .{ .kind = .retry, .retry = .{ .attempt = 2, .max = 3 } }, 1_000);

    const block = try state.renderBlock(std.testing.allocator, 1_000 + 5 * std.time.ms_per_s);
    defer std.testing.allocator.free(block);

    try std.testing.expect(std.mem.indexOf(u8, block, "Retrying (2/3)\u{2026}") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "Retrying (1/3)") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, block, "Retrying ("));
}

test "a resumed call clears the retry indicator" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    _ = try state.record(std.testing.allocator, .{ .kind = .retry, .retry = .{ .attempt = 1, .max = 3 } }, 1_000);
    try std.testing.expect(state.hasContent());
    _ = try state.record(std.testing.allocator, .{ .kind = .retry, .retry = .{ .attempt = 0, .max = 0 } }, 1_000);
    try std.testing.expect(!state.hasContent());
    // The clear must be flushed even though the block is now empty.
    try std.testing.expect(state.needs_clear);
    state.markRendered();
    try std.testing.expect(!state.needs_clear);

    // A tool start also clears a stale indicator.
    _ = try state.record(std.testing.allocator, .{ .kind = .retry, .retry = .{ .attempt = 2, .max = 3 } }, 1_000);
    _ = try state.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);
    try std.testing.expect(state.retry == null);
}

test "retry indicator renders after tool lines when tools already ran" {
    var state: ToolProgress = .{};
    defer state.deinit(std.testing.allocator);

    _ = try state.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);
    _ = try state.record(std.testing.allocator, .{ .kind = .retry, .retry = .{ .attempt = 1, .max = 2 } }, 1_000);

    const block = try state.renderBlock(std.testing.allocator, 1_000);
    defer std.testing.allocator.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "1 tool call") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "Retrying (1/2)\u{2026}") != null);
}
