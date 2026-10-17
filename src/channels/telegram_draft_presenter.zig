const std = @import("std");
const providers = @import("../providers/root.zig");
const tool_progress = @import("tool_progress.zig");

// Telegram draft previews are easy to rate-limit if we flush tiny deltas too
// aggressively. Use noticeably coarser thresholds so users still see progress
// without hammering sendMessageDraft on every token burst.
pub const DRAFT_FLUSH_MIN_DELTA_BYTES: usize = 512;
pub const DRAFT_FLUSH_MIN_INTERVAL_MS: i64 = 4 * std.time.ms_per_s;
pub const DRAFT_HEARTBEAT_INTERVAL_MS: i64 = 12 * std.time.ms_per_s;
pub const DRAFT_TRANSPORT_MAX_BYTES: usize = 3000;

const DRAFT_TRIM_BYTES = " \t\r\n";
const DRAFT_PROGRESS_PREFIX = "Processing request...\n";
const DRAFT_PROGRESS_TAIL_LABEL = "\n\nLatest excerpt:\n";
const DRAFT_PROGRESS_HEARTBEAT_ONLY = "Interim result is still being prepared.";

pub const DraftState = struct {
    draft_id: u64,
    /// True while a turn still owns this draft (it has begun a draft turn and
    /// has not finished it). A later inbound message must not reset/rotate a
    /// draft another turn is still streaming into.
    active: bool = false,
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    last_flush_len: usize = 0,
    last_flush_time: i64 = 0,
    started_at_ms: i64 = 0,
    suppress_until_ms: i64 = 0,
    /// Per-turn tool activity shown while the draft has no visible answer text.
    tool_progress: tool_progress.ToolProgress = .{},

    pub fn deinit(self: *DraftState, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        self.tool_progress.deinit(allocator);
    }
};

pub const DraftFlush = struct {
    draft_id: u64,
    text: []u8,
    started_at_ms: i64,
    /// True when `text` is already HTML for Telegram's parse_mode, so the caller
    /// must not run it through the Markdown renderer (which would double-escape).
    html: bool = false,

    pub fn deinit(self: *DraftFlush, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

fn trimmedDraftText(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, DRAFT_TRIM_BYTES);
}

pub fn hasVisibleDraftText(text: []const u8) bool {
    return trimmedDraftText(text).len != 0;
}

/// True when the draft already shows answer text. A streamed reasoning quote is
/// not answer text: it renders as a `>` quote with the answer below it, so a
/// reasoning-only draft is still combined with the tool-progress block while
/// tools run (otherwise the draft freezes on the last reasoning quote and the
/// user cannot tell "calling tools" from "stuck").
fn hasVisibleAnswerText(allocator: std.mem.Allocator, text: []const u8) !bool {
    if (!hasVisibleDraftText(text)) return false;
    const stripped = try providers.stripThinkBlocks(allocator, text);
    defer allocator.free(stripped);
    return hasVisibleDraftText(stripped);
}

fn bytesSinceLastFlush(state: *const DraftState) usize {
    return state.buffer.items.len - state.last_flush_len;
}

fn millisSinceLastFlush(state: *const DraftState, now_ms: i64) i64 {
    return now_ms - state.last_flush_time;
}

fn flushDeltaReached(state: *const DraftState) bool {
    return bytesSinceLastFlush(state) >= DRAFT_FLUSH_MIN_DELTA_BYTES;
}

fn flushIntervalElapsed(state: *const DraftState, now_ms: i64) bool {
    return millisSinceLastFlush(state, now_ms) >= DRAFT_FLUSH_MIN_INTERVAL_MS;
}

fn draftSuppressed(state: *const DraftState, now_ms: i64) bool {
    return state.suppress_until_ms > now_ms;
}

fn shouldFlushDraft(state: *const DraftState, now_ms: i64) bool {
    if (draftSuppressed(state, now_ms)) return false;
    return flushDeltaReached(state) or flushIntervalElapsed(state, now_ms);
}

fn hasPendingVisibleDraft(state: *const DraftState) bool {
    if (state.buffer.items.len <= state.last_flush_len) return false;
    return hasVisibleDraftText(state.buffer.items[state.last_flush_len..]);
}

/// Snapshot the buffered draft for the wire.
///
/// `<think>` blocks only reach a channel when the daemon forwards them, which
/// it does solely for `reasoning_mode == .stream`; in every other mode they are
/// already stripped upstream, so quoting them here is a no-op and `.off`/`.on`
/// drafts stay exactly as they were.
fn snapshotDraftText(allocator: std.mem.Allocator, state: *const DraftState) ![]u8 {
    const rendered = try providers.quoteThinkBlocks(allocator, state.buffer.items);
    defer allocator.free(rendered);
    return allocator.dupe(u8, rendered);
}

fn alignUtf8Start(text: []const u8, start: usize) usize {
    var idx = @min(start, text.len);
    while (idx < text.len and (text[idx] & 0xC0) == 0x80) : (idx += 1) {}
    return idx;
}

fn draftTailSlice(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    const raw_start = text.len - max_bytes;
    return text[alignUtf8Start(text, raw_start)..];
}

fn appendElapsedSummary(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, started_at_ms: i64, now_ms: i64) !void {
    const elapsed_ms = if (started_at_ms > 0 and now_ms > started_at_ms) now_ms - started_at_ms else 0;
    const elapsed_secs = @divFloor(elapsed_ms, std.time.ms_per_s);
    try buf.print(allocator, "Elapsed: {d}s", .{elapsed_secs});
}

/// Start index of the newest `budget` bytes of `text`, aligned to a UTF-8
/// boundary. Used to tail-truncate a reasoning excerpt so the combined draft
/// stays under DRAFT_TRANSPORT_MAX_BYTES.
fn boundedTailStart(text: []const u8, budget: usize) usize {
    if (text.len <= budget) return 0;
    return alignUtf8Start(text, text.len - budget);
}

/// Move `start` past an escaped HTML entity (`&amp;`, `&lt;`, ...) that the
/// tail cut landed in the middle of, so Telegram never receives a broken
/// entity. `start` is already on a UTF-8 boundary.
fn alignHtmlTailStart(text: []const u8, start_in: usize) usize {
    var start = alignUtf8Start(text, start_in);
    var look = start;
    const floor = start -| 6;
    while (look > floor) {
        look -= 1;
        if (text[look] != '&') continue;
        // The entity already ended before `start`: nothing to skip.
        if (std.mem.indexOfScalar(u8, text[look..start], ';') == null) {
            if (std.mem.indexOfScalarPos(u8, text, start, ';')) |semi| start = semi + 1;
        }
        break;
    }
    return alignUtf8Start(text, start);
}

/// Tool-progress block plus the reasoning streamed so far.
///
/// The reasoning is kept above the progress block: replacing the draft with the
/// progress block alone made `/reasoning stream` lose the thinking as soon as a
/// tool ran. The reasoning is escaped because it is model output, and only its
/// newest bytes are kept so the whole draft fits the transport cap (the tool
/// block is at the end, where the transport compaction would otherwise cut it).
fn buildProgressText(allocator: std.mem.Allocator, state: *const DraftState, now_ms: i64) ![]u8 {
    const progress = try state.tool_progress.renderBlockHtml(allocator, now_ms);
    var progress_owned = true;
    defer if (progress_owned) allocator.free(progress);

    const quoted = try snapshotDraftText(allocator, state);
    defer allocator.free(quoted);
    if (!hasVisibleDraftText(quoted)) {
        progress_owned = false;
        return progress;
    }

    const escaped = try tool_progress.escapeHtml(allocator, quoted);
    defer allocator.free(escaped);

    const separator = "\n\n";
    if (progress.len + separator.len >= DRAFT_TRANSPORT_MAX_BYTES) {
        progress_owned = false;
        return progress;
    }
    const budget = DRAFT_TRANSPORT_MAX_BYTES - progress.len - separator.len;
    const start = alignHtmlTailStart(escaped, boundedTailStart(escaped, budget));
    if (start >= escaped.len) {
        progress_owned = false;
        return progress;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, escaped[start..]);
    try out.appendSlice(allocator, separator);
    try out.appendSlice(allocator, progress);
    return out.toOwnedSlice(allocator);
}

/// Build the draft text shown while a turn has no visible answer text yet.
///
/// When the turn has already run tools, this is the tool-progress block
/// (elapsed seconds, tool-call count, last tool lines) preceded by the
/// reasoning streamed so far; otherwise it is the plain elapsed-time heartbeat.
/// Both are HTML for Telegram's parse_mode.
pub fn buildHeartbeatText(allocator: std.mem.Allocator, state: *const DraftState, now_ms: i64) ![]u8 {
    if (state.tool_progress.hasContent()) {
        return buildProgressText(allocator, state, now_ms);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, DRAFT_PROGRESS_PREFIX);
    try appendElapsedSummary(&out, allocator, state.started_at_ms, now_ms);
    try out.appendSlice(allocator, "\n");
    try out.appendSlice(allocator, DRAFT_PROGRESS_HEARTBEAT_ONLY);
    return out.toOwnedSlice(allocator);
}

pub fn buildTransportText(
    allocator: std.mem.Allocator,
    text: []const u8,
    started_at_ms: i64,
    now_ms: i64,
) ![]u8 {
    const stripped = try providers.stripThinkBlocks(allocator, text);
    defer allocator.free(stripped);

    if (stripped.len <= DRAFT_TRANSPORT_MAX_BYTES) return allocator.dupe(u8, stripped);

    var prefix: std.ArrayListUnmanaged(u8) = .empty;
    defer prefix.deinit(allocator);
    try prefix.appendSlice(allocator, DRAFT_PROGRESS_PREFIX);
    try appendElapsedSummary(&prefix, allocator, started_at_ms, now_ms);
    try prefix.appendSlice(allocator, DRAFT_PROGRESS_TAIL_LABEL);

    if (prefix.items.len >= DRAFT_TRANSPORT_MAX_BYTES) {
        return allocator.dupe(u8, prefix.items[0..DRAFT_TRANSPORT_MAX_BYTES]);
    }

    const tail_budget = DRAFT_TRANSPORT_MAX_BYTES - prefix.items.len;
    const tail = draftTailSlice(stripped, tail_budget);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, prefix.items);
    try out.appendSlice(allocator, tail);
    return out.toOwnedSlice(allocator);
}

fn markDraftFlushed(state: *DraftState, now_ms: i64) void {
    state.last_flush_len = state.buffer.items.len;
    state.last_flush_time = now_ms;
}

pub fn appendDraftChunk(
    allocator: std.mem.Allocator,
    state: *DraftState,
    chunk: []const u8,
    now_ms: i64,
) !?DraftFlush {
    if (chunk.len == 0) return null;

    try state.buffer.appendSlice(allocator, chunk);
    if (!shouldFlushDraft(state, now_ms)) return null;
    if (!hasVisibleDraftText(state.buffer.items)) return null;

    const text = try snapshotDraftText(allocator, state);
    markDraftFlushed(state, now_ms);
    return .{
        .draft_id = state.draft_id,
        .text = text,
        .started_at_ms = state.started_at_ms,
    };
}

pub fn heartbeatDraft(
    allocator: std.mem.Allocator,
    state: *DraftState,
    now_ms: i64,
) !?DraftFlush {
    if (draftSuppressed(state, now_ms)) return null;

    const since_last_flush = millisSinceLastFlush(state, now_ms);

    // A tool event that landed inside the chunk flush throttle stays dirty and
    // is retried on every typing tick. Waiting for the 12s heartbeat starved it:
    // streamed reasoning/answer chunks reset `last_flush_time` every ≤4s, so the
    // 12s gate never opened and the tool block never reached the draft.
    if (state.tool_progress.dirty and since_last_flush >= DRAFT_FLUSH_MIN_INTERVAL_MS) {
        if (try hasVisibleAnswerText(allocator, state.buffer.items)) {
            // The answer text owns the draft now; tool lines must not cover it.
            state.tool_progress.markRendered();
        } else {
            const text = try buildHeartbeatText(allocator, state, now_ms);
            state.tool_progress.markRendered();
            markDraftFlushed(state, now_ms);
            return .{
                .draft_id = state.draft_id,
                .text = text,
                .started_at_ms = state.started_at_ms,
                .html = true,
            };
        }
    }

    if (since_last_flush < DRAFT_HEARTBEAT_INTERVAL_MS) return null;

    if (hasPendingVisibleDraft(state)) {
        // While tools run, a pending reasoning excerpt is rendered together with
        // the tool block. Sending the reasoning-only snapshot would hide the
        // tool lines that are already on screen.
        const with_tools = state.tool_progress.hasContent() and
            !(try hasVisibleAnswerText(allocator, state.buffer.items));
        const text = if (with_tools)
            try buildHeartbeatText(allocator, state, now_ms)
        else
            try snapshotDraftText(allocator, state);
        if (state.tool_progress.hasContent()) state.tool_progress.markRendered();
        markDraftFlushed(state, now_ms);
        return .{
            .draft_id = state.draft_id,
            .text = text,
            .started_at_ms = state.started_at_ms,
            .html = with_tools,
        };
    }

    if (hasVisibleDraftText(state.buffer.items)) {
        // Answer text is on screen: never replace it with a heartbeat.
        if (try hasVisibleAnswerText(allocator, state.buffer.items)) return null;
        // A streamed reasoning quote is on screen but no answer text yet: keep
        // it, together with the progress block when tools have run.
        if (!state.tool_progress.hasContent()) return null;
    }

    state.last_flush_time = now_ms;
    return .{
        .draft_id = state.draft_id,
        .text = try buildHeartbeatText(allocator, state, now_ms),
        .started_at_ms = state.started_at_ms,
        .html = true,
    };
}

/// Refresh the draft when a new tool event arrives sooner than the heartbeat
/// interval. Only fires while the draft has no visible answer text: once real
/// text streams, the draft shows the text exactly as before.
///
/// The first tool event of a turn bypasses the flush throttle (OpenClaw's
/// `startImmediately`), so the user sees which tool started even when no
/// text/reasoning has streamed yet. Later events in a parallel batch honour the
/// throttle so they cannot rate-limit sendMessageDraft; they stay dirty and are
/// retried by the next heartbeat instead of being dropped.
pub fn progressDraft(
    allocator: std.mem.Allocator,
    state: *DraftState,
    now_ms: i64,
) !?DraftFlush {
    if (draftSuppressed(state, now_ms)) return null;
    if (!state.tool_progress.hasContent()) return null;
    if (try hasVisibleAnswerText(allocator, state.buffer.items)) return null;

    const first_render = !state.tool_progress.rendered;
    if (!first_render and millisSinceLastFlush(state, now_ms) < DRAFT_FLUSH_MIN_INTERVAL_MS) return null;

    const text = try buildHeartbeatText(allocator, state, now_ms);
    state.tool_progress.markRendered();
    // Marking the reasoning as flushed too: the progress draft already carries
    // it, so a later heartbeat must not fall back to a reasoning-only snapshot
    // that would hide the tool block.
    markDraftFlushed(state, now_ms);
    return .{
        .draft_id = state.draft_id,
        .text = text,
        .started_at_ms = state.started_at_ms,
        .html = true,
    };
}

pub fn suppressDraft(state: *DraftState, now_ms: i64, retry_after_secs: u32) void {
    const retry_after_ms = @as(i64, @intCast(retry_after_secs)) * std.time.ms_per_s;
    suppressDraftUntilMs(state, now_ms + retry_after_ms);
}

pub fn suppressDraftUntilMs(state: *DraftState, suppress_until_ms: i64) void {
    if (suppress_until_ms > state.suppress_until_ms) {
        state.suppress_until_ms = suppress_until_ms;
    }
}

pub fn clearDraftForTarget(
    allocator: std.mem.Allocator,
    draft_buffers: *std.StringHashMapUnmanaged(DraftState),
    target: []const u8,
) void {
    if (draft_buffers.fetchRemove(target)) |entry| {
        allocator.free(entry.key);
        var draft = entry.value;
        draft.deinit(allocator);
    }
}

pub fn deinitDraftBuffers(
    allocator: std.mem.Allocator,
    draft_buffers: *std.StringHashMapUnmanaged(DraftState),
) void {
    var it = draft_buffers.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    draft_buffers.deinit(allocator);
    draft_buffers.* = .empty;
}

test "appendDraftChunk ignores empty chunks" {
    var draft: DraftState = .{ .draft_id = 1 };
    defer draft.deinit(std.testing.allocator);

    try std.testing.expect((try appendDraftChunk(std.testing.allocator, &draft, "", 0)) == null);
    try std.testing.expectEqual(@as(usize, 0), draft.buffer.items.len);
}

test "appendDraftChunk keeps whitespace-only drafts local" {
    var draft: DraftState = .{ .draft_id = 7 };
    defer draft.deinit(std.testing.allocator);

    try std.testing.expect((try appendDraftChunk(std.testing.allocator, &draft, "   \n\t", DRAFT_FLUSH_MIN_INTERVAL_MS)) == null);
    try std.testing.expectEqual(@as(usize, 5), draft.buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), draft.last_flush_len);
}

test "appendDraftChunk flushes visible content after interval" {
    var draft: DraftState = .{ .draft_id = 3 };
    defer draft.deinit(std.testing.allocator);

    const flush = (try appendDraftChunk(std.testing.allocator, &draft, "hello", DRAFT_FLUSH_MIN_INTERVAL_MS + 1)) orelse
        return error.TestUnexpectedResult;
    defer {
        var tmp = flush;
        tmp.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(u64, 3), flush.draft_id);
    try std.testing.expectEqualStrings("hello", flush.text);
    try std.testing.expectEqual(@as(i64, 0), flush.started_at_ms);
    try std.testing.expectEqual(@as(usize, 5), draft.last_flush_len);
}

test "appendDraftChunk renders streamed reasoning as a quote" {
    var draft: DraftState = .{ .draft_id = 31 };
    defer draft.deinit(std.testing.allocator);

    const flush = (try appendDraftChunk(
        std.testing.allocator,
        &draft,
        "<think>private</think>Visible answer",
        DRAFT_FLUSH_MIN_INTERVAL_MS + 1,
    )) orelse return error.TestUnexpectedResult;
    defer {
        var tmp = flush;
        tmp.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("> private\n\nVisible answer", flush.text);
}

test "appendDraftChunk leaves drafts without reasoning untouched" {
    var draft: DraftState = .{ .draft_id = 32 };
    defer draft.deinit(std.testing.allocator);

    // reasoning_mode off/on: the daemon strips think blocks before they reach
    // the channel, so the draft is exactly the visible answer.
    const flush = (try appendDraftChunk(
        std.testing.allocator,
        &draft,
        "Visible answer",
        DRAFT_FLUSH_MIN_INTERVAL_MS + 1,
    )) orelse return error.TestUnexpectedResult;
    defer {
        var tmp = flush;
        tmp.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("Visible answer", flush.text);
}

test "appendDraftChunk stays quiet while suppressed" {
    var draft: DraftState = .{ .draft_id = 11 };
    defer draft.deinit(std.testing.allocator);

    suppressDraft(&draft, 1000, 5);
    try std.testing.expect((try appendDraftChunk(std.testing.allocator, &draft, "hello world", 2000)) == null);
    try std.testing.expectEqual(@as(usize, 11), draft.buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), draft.last_flush_len);
}

test "buildTransportText compacts long draft into progress preview" {
    const long_text = "abcdef" ** 700;
    const compact = try buildTransportText(std.testing.allocator, long_text, 1_000, 16_000);
    defer std.testing.allocator.free(compact);

    try std.testing.expect(compact.len <= DRAFT_TRANSPORT_MAX_BYTES);
    try std.testing.expect(std.mem.startsWith(u8, compact, DRAFT_PROGRESS_PREFIX));
    try std.testing.expect(std.mem.indexOf(u8, compact, "Latest excerpt:") != null);
    try std.testing.expect(std.mem.endsWith(u8, compact, long_text[long_text.len - 32 ..]));
}

test "buildTransportText strips think blocks from compact excerpt" {
    const long_text = ("a" ** 2900) ++ "<think>private</think>" ++ ("b" ** 400);
    const compact = try buildTransportText(std.testing.allocator, long_text, 1_000, 16_000);
    defer std.testing.allocator.free(compact);

    try std.testing.expect(std.mem.indexOf(u8, compact, "<think>") == null);
    try std.testing.expect(std.mem.indexOf(u8, compact, "private") == null);
}

test "buildHeartbeatText emits visible progress status without a size line" {
    var draft: DraftState = .{ .draft_id = 1, .started_at_ms = 5_000 };
    defer draft.deinit(std.testing.allocator);

    const heartbeat = try buildHeartbeatText(std.testing.allocator, &draft, 17_500);
    defer std.testing.allocator.free(heartbeat);

    try std.testing.expect(hasVisibleDraftText(heartbeat));
    try std.testing.expect(std.mem.indexOf(u8, heartbeat, "Elapsed: 12s") != null);
    try std.testing.expect(std.mem.indexOf(u8, heartbeat, "Current size") == null);
    try std.testing.expect(std.mem.indexOf(u8, heartbeat, "Interim result is still being prepared.") != null);
}

test "buildHeartbeatText shows the tool-progress block once tools run" {
    var draft: DraftState = .{ .draft_id = 1, .started_at_ms = 0 };
    defer draft.deinit(std.testing.allocator);
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "web_search" }, 1_000);
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "web_fetch", .arguments_json = "{\"url\":\"https://example.com\"}" }, 1_000);

    const heartbeat = try buildHeartbeatText(std.testing.allocator, &draft, 1_000 + 121 * std.time.ms_per_s);
    defer std.testing.allocator.free(heartbeat);

    try std.testing.expect(std.mem.indexOf(u8, heartbeat, "121s") != null);
    try std.testing.expect(std.mem.indexOf(u8, heartbeat, "2 tool calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, heartbeat, "web_fetch example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, heartbeat, "Interim result is still being prepared.") == null);
}

test "progressDraft flushes the first tool event and throttles later ones" {
    var draft: DraftState = .{ .draft_id = 9, .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer draft.deinit(std.testing.allocator);

    // No tool content yet: nothing to show.
    try std.testing.expect((try progressDraft(std.testing.allocator, &draft, 1_000 + DRAFT_FLUSH_MIN_INTERVAL_MS)) == null);

    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);

    // The first tool event of a turn bypasses the chunk throttle.
    const first = (try progressDraft(std.testing.allocator, &draft, 1_000)) orelse
        return error.TestUnexpectedResult;
    defer {
        var tmp = first;
        tmp.deinit(std.testing.allocator);
    }
    try std.testing.expect(first.html);
    try std.testing.expect(std.mem.indexOf(u8, first.text, "shell") != null);
    try std.testing.expect(!draft.tool_progress.dirty);

    // A later event inside the throttle window is deferred, not dropped.
    _ = try draft.tool_progress.record(std.testing.allocator, .{
        .tool = "web_fetch",
        .arguments_json = "{\"url\":\"https://example.com\"}",
    }, 1_000);
    try std.testing.expect((try progressDraft(std.testing.allocator, &draft, 1_000 + DRAFT_FLUSH_MIN_INTERVAL_MS - 1)) == null);
    try std.testing.expect(draft.tool_progress.dirty);

    const later = (try progressDraft(std.testing.allocator, &draft, 1_000 + DRAFT_FLUSH_MIN_INTERVAL_MS)) orelse
        return error.TestUnexpectedResult;
    defer {
        var tmp = later;
        tmp.deinit(std.testing.allocator);
    }
    try std.testing.expect(std.mem.indexOf(u8, later.text, "shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, later.text, "web_fetch") != null);
}

test "progressDraft stays quiet once answer text is visible" {
    var draft: DraftState = .{ .draft_id = 9, .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer draft.deinit(std.testing.allocator);
    try draft.buffer.appendSlice(std.testing.allocator, "real answer");
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);

    try std.testing.expect((try progressDraft(std.testing.allocator, &draft, 1_000 + DRAFT_FLUSH_MIN_INTERVAL_MS)) == null);
}

test "progressDraft shows tools even when only reasoning has streamed" {
    var draft: DraftState = .{ .draft_id = 9, .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer draft.deinit(std.testing.allocator);
    // `/reasoning stream` puts the thinking in the draft before any tool runs.
    try draft.buffer.appendSlice(std.testing.allocator, "<think>pondering</think>");
    draft.last_flush_len = draft.buffer.items.len;
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);

    const flush = (try progressDraft(std.testing.allocator, &draft, 1_000 + DRAFT_FLUSH_MIN_INTERVAL_MS)) orelse
        return error.TestUnexpectedResult;
    defer {
        var tmp = flush;
        tmp.deinit(std.testing.allocator);
    }
    try std.testing.expect(std.mem.indexOf(u8, flush.text, "shell") != null);
}

test "progressDraft keeps the streamed reasoning above the tool block" {
    // Regression: the tool-progress block replaced the draft outright, so a
    // turn that ran tools lost the reasoning it had just streamed under
    // `/reasoning stream`.
    var draft: DraftState = .{ .draft_id = 9, .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer draft.deinit(std.testing.allocator);
    try draft.buffer.appendSlice(std.testing.allocator, "<think>pondering the options</think>");
    draft.last_flush_len = draft.buffer.items.len;
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);

    var flush = (try progressDraft(std.testing.allocator, &draft, 1_000 + DRAFT_FLUSH_MIN_INTERVAL_MS)) orelse
        return error.TestUnexpectedResult;
    defer flush.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, flush.text, "pondering the options") != null);
    try std.testing.expect(std.mem.indexOf(u8, flush.text, "shell") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, flush.text, "pondering the options").? <
            std.mem.indexOf(u8, flush.text, "shell").?,
    );
}

test "heartbeatDraft keeps the reasoning quote next to the tool block" {
    // Regression: the 12s heartbeat wrote the progress block over the draft,
    // hiding the reasoning that was already on screen.
    var draft: DraftState = .{ .draft_id = 9, .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer draft.deinit(std.testing.allocator);
    try draft.buffer.appendSlice(std.testing.allocator, "<think>thinking it through</think>");
    draft.last_flush_len = draft.buffer.items.len;
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "web_search" }, 1_000);

    var flush = (try heartbeatDraft(std.testing.allocator, &draft, 1_000 + DRAFT_HEARTBEAT_INTERVAL_MS + 1)) orelse
        return error.TestUnexpectedResult;
    defer flush.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, flush.text, "thinking it through") != null);
    try std.testing.expect(std.mem.indexOf(u8, flush.text, "web_search") != null);
}

test "buildProgressText bounds the reasoning tail and keeps the tool block" {
    // Regression: the progress block replaced the draft, hiding the newest
    // streamed reasoning; the tail bound keeps it without overrunning the
    // transport cap and cutting off the tool block at the end.
    var draft: DraftState = .{ .draft_id = 1, .started_at_ms = 0 };
    defer draft.deinit(std.testing.allocator);
    try draft.buffer.appendSlice(std.testing.allocator, "<think>");
    try draft.buffer.appendSlice(std.testing.allocator, "old " ** 2_000);
    try draft.buffer.appendSlice(std.testing.allocator, "LATEST-REASONING</think>");
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);

    const text = try buildHeartbeatText(std.testing.allocator, &draft, 1_000);
    defer std.testing.allocator.free(text);

    try std.testing.expect(text.len <= DRAFT_TRANSPORT_MAX_BYTES);
    try std.testing.expect(std.mem.indexOf(u8, text, "LATEST-REASONING") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "shell") != null);
    // The oldest reasoning is dropped, not the tool block at the end.
    try std.testing.expect(!std.mem.startsWith(u8, text, "&gt; old"));
}

test "buildProgressText never cuts a multibyte reasoning character" {
    var draft: DraftState = .{ .draft_id = 1, .started_at_ms = 0 };
    defer draft.deinit(std.testing.allocator);
    try draft.buffer.appendSlice(std.testing.allocator, "<think>x");
    try draft.buffer.appendSlice(std.testing.allocator, "\u{20AC}" ** 2_000);
    try draft.buffer.appendSlice(std.testing.allocator, "</think>");
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "web_search" }, 1_000);
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "web_fetch" }, 1_000);

    // The ASCII prefix makes the raw tail cut land on a continuation byte of a
    // 3-byte codepoint: without UTF-8 alignment the draft HTML would be invalid.
    const progress = try draft.tool_progress.renderBlockHtml(std.testing.allocator, 1_000);
    defer std.testing.allocator.free(progress);
    const budget = DRAFT_TRANSPORT_MAX_BYTES - progress.len - "\n\n".len;
    const quoted = try snapshotDraftText(std.testing.allocator, &draft);
    defer std.testing.allocator.free(quoted);
    const escaped = try tool_progress.escapeHtml(std.testing.allocator, quoted);
    defer std.testing.allocator.free(escaped);
    try std.testing.expect((escaped[escaped.len - budget] & 0xC0) == 0x80);

    const text = try buildHeartbeatText(std.testing.allocator, &draft, 1_000);
    defer std.testing.allocator.free(text);

    try std.testing.expect(text.len <= DRAFT_TRANSPORT_MAX_BYTES);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    try std.testing.expect(std.mem.indexOf(u8, text, "web_search") != null);
}

test "alignHtmlTailStart skips a partial escaped entity" {
    const text = "abc&amp;def";
    // A cut inside "&amp;" must resume after the ';'.
    try std.testing.expectEqual(@as(usize, 8), alignHtmlTailStart(text, 5));
    // A cut on a normal boundary is left alone.
    try std.testing.expectEqual(@as(usize, 8), alignHtmlTailStart(text, 8));
    try std.testing.expectEqual(@as(usize, 0), alignHtmlTailStart(text, 0));
}

test "buildProgressText escapes reasoning instead of injecting HTML" {
    var draft: DraftState = .{ .draft_id = 1, .started_at_ms = 0 };
    defer draft.deinit(std.testing.allocator);
    try draft.buffer.appendSlice(std.testing.allocator, "<think><b>&x</b></think>");
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);

    const text = try buildHeartbeatText(std.testing.allocator, &draft, 1_000);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "<b>") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "&lt;b&gt;") != null);
}

test "heartbeatDraft keeps a reasoning-only draft unless tools have run" {
    var draft: DraftState = .{ .draft_id = 9, .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer draft.deinit(std.testing.allocator);
    try draft.buffer.appendSlice(std.testing.allocator, "<think>pondering</think>");
    draft.last_flush_len = draft.buffer.items.len;

    // No tool lines yet: the reasoning quote stays, no heartbeat replaces it.
    try std.testing.expect((try heartbeatDraft(std.testing.allocator, &draft, 1_000 + DRAFT_HEARTBEAT_INTERVAL_MS + 1)) == null);

    // A tool event produces a block worth replacing the reasoning quote with.
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);
    const flush = (try heartbeatDraft(std.testing.allocator, &draft, 1_000 + DRAFT_HEARTBEAT_INTERVAL_MS + 1)) orelse
        return error.TestUnexpectedResult;
    defer {
        var tmp = flush;
        tmp.deinit(std.testing.allocator);
    }
    try std.testing.expect(std.mem.indexOf(u8, flush.text, "shell") != null);
}

test "heartbeatDraft flushes pending visible text after interval" {
    var draft: DraftState = .{
        .draft_id = 21,
        .started_at_ms = 1_000,
        .last_flush_time = 1_000,
    };
    defer draft.deinit(std.testing.allocator);
    try draft.buffer.appendSlice(std.testing.allocator, "hello");

    const flush = (try heartbeatDraft(std.testing.allocator, &draft, 1_000 + DRAFT_HEARTBEAT_INTERVAL_MS + 1)) orelse
        return error.TestUnexpectedResult;
    defer {
        var tmp = flush;
        tmp.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(u64, 21), flush.draft_id);
    try std.testing.expectEqualStrings("hello", flush.text);
    try std.testing.expectEqual(@as(usize, 5), draft.last_flush_len);
    try std.testing.expectEqual(@as(i64, 1_000 + DRAFT_HEARTBEAT_INTERVAL_MS + 1), draft.last_flush_time);
}

test "heartbeatDraft stays quiet when visible text was already flushed" {
    var draft: DraftState = .{
        .draft_id = 22,
        .started_at_ms = 1_000,
        .last_flush_time = 1_000,
        .last_flush_len = 5,
    };
    defer draft.deinit(std.testing.allocator);
    try draft.buffer.appendSlice(std.testing.allocator, "hello");

    try std.testing.expect((try heartbeatDraft(std.testing.allocator, &draft, 1_000 + DRAFT_HEARTBEAT_INTERVAL_MS + 1)) == null);
}

test "heartbeatDraft emits heartbeat when no visible draft is available" {
    var draft: DraftState = .{
        .draft_id = 23,
        .started_at_ms = 5_000,
        .last_flush_time = 5_000,
    };
    defer draft.deinit(std.testing.allocator);
    try draft.buffer.appendSlice(std.testing.allocator, " \n\t");

    const flush = (try heartbeatDraft(std.testing.allocator, &draft, 5_000 + DRAFT_HEARTBEAT_INTERVAL_MS + 1)) orelse
        return error.TestUnexpectedResult;
    defer {
        var tmp = flush;
        tmp.deinit(std.testing.allocator);
    }

    try std.testing.expect(std.mem.indexOf(u8, flush.text, "Interim result is still being prepared.") != null);
    try std.testing.expectEqual(@as(usize, 0), draft.last_flush_len);
    try std.testing.expectEqual(@as(i64, 5_000 + DRAFT_HEARTBEAT_INTERVAL_MS + 1), draft.last_flush_time);
}

test "progressDraft shows the first tool call immediately after a reasoning flush" {
    // Regression: a tool batch that started right after a streamed reasoning
    // flush landed inside the 4s chunk throttle; progressDraft returned null and
    // the tool block never reached the draft for the rest of the turn.
    var draft: DraftState = .{ .draft_id = 9, .started_at_ms = 0, .last_flush_time = 0 };
    defer draft.deinit(std.testing.allocator);

    const reasoning = "<think>" ++ ("r" ** 600) ++ "</think>";
    var chunk_flush = (try appendDraftChunk(std.testing.allocator, &draft, reasoning, 3_500)) orelse
        return error.TestUnexpectedResult;
    chunk_flush.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 3_500), draft.last_flush_time);

    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "shell" }, 4_000);
    var flush = (try progressDraft(std.testing.allocator, &draft, 4_000)) orelse
        return error.TestUnexpectedResult;
    defer flush.deinit(std.testing.allocator);

    try std.testing.expect(flush.html);
    try std.testing.expect(std.mem.indexOf(u8, flush.text, "shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, flush.text, "1 tool call") != null);
    try std.testing.expect(!draft.tool_progress.dirty);
}

test "heartbeatDraft retries tool events deferred by the chunk throttle" {
    // Regression: the 4s chunk throttle dropped later calls of a parallel batch
    // with no retry, and the 12s heartbeat was starved by continuous reasoning
    // flushes, so only the first tool call ever appeared (if any).
    var draft: DraftState = .{ .draft_id = 9, .started_at_ms = 0, .last_flush_time = 0 };
    defer draft.deinit(std.testing.allocator);

    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);
    var first = (try progressDraft(std.testing.allocator, &draft, 1_000)) orelse
        return error.TestUnexpectedResult;
    first.deinit(std.testing.allocator);

    // Reasoning keeps flushing, keeping last_flush_time fresh.
    const reasoning = "<think>" ++ ("r" ** 600) ++ "</think>";
    var chunk_flush = (try appendDraftChunk(std.testing.allocator, &draft, reasoning, 5_000)) orelse
        return error.TestUnexpectedResult;
    chunk_flush.deinit(std.testing.allocator);

    // Calls 2 and 3 of the batch arrive 500ms after the reasoning flush.
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "web_search", .arguments_json = "{\"query\":\"q\"}" }, 5_500);
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "file_read", .arguments_json = "{\"path\":\"/tmp/a.txt\"}" }, 5_500);
    try std.testing.expect((try progressDraft(std.testing.allocator, &draft, 5_500)) == null);
    try std.testing.expect(draft.tool_progress.dirty);

    // The next typing tick renders them even though the 12s heartbeat gate has
    // not opened (only 4s since the reasoning flush).
    var flush = (try heartbeatDraft(std.testing.allocator, &draft, 9_000)) orelse
        return error.TestUnexpectedResult;
    defer flush.deinit(std.testing.allocator);

    try std.testing.expect(flush.html);
    try std.testing.expect(std.mem.indexOf(u8, flush.text, "web_search") != null);
    try std.testing.expect(std.mem.indexOf(u8, flush.text, "file_read a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, flush.text, "3 tool calls") != null);
    try std.testing.expect(!draft.tool_progress.dirty);
}

test "heartbeatDraft keeps the tool block when reasoning is pending" {
    // Regression: after a progress render, the pending-reasoning branch sent a
    // reasoning-only snapshot and hid the tool lines that were already on
    // screen (progressDraft did not update last_flush_len either).
    var draft: DraftState = .{ .draft_id = 9, .started_at_ms = 0, .last_flush_time = 0 };
    defer draft.deinit(std.testing.allocator);

    try draft.buffer.appendSlice(std.testing.allocator, "<think>pondering");
    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);
    var progress = (try progressDraft(std.testing.allocator, &draft, 4_000)) orelse
        return error.TestUnexpectedResult;
    progress.deinit(std.testing.allocator);
    // The progress draft already carries the reasoning, so it is not pending.
    try std.testing.expectEqual(draft.buffer.items.len, draft.last_flush_len);

    // More reasoning arrives without a flush, then the 12s heartbeat fires.
    try draft.buffer.appendSlice(std.testing.allocator, " more</think>");
    var flush = (try heartbeatDraft(std.testing.allocator, &draft, 16_000)) orelse
        return error.TestUnexpectedResult;
    defer flush.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, flush.text, "shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, flush.text, "pondering") != null);
}

test "tool lines yield to answer text instead of covering it" {
    // Guard for the deferred retry: a pending tool event must never be rendered
    // after the answer text starts streaming; the answer replaces the draft
    // until the turn ends.
    var draft: DraftState = .{ .draft_id = 9, .started_at_ms = 0, .last_flush_time = 0 };
    defer draft.deinit(std.testing.allocator);

    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "shell" }, 1_000);
    var first = (try progressDraft(std.testing.allocator, &draft, 1_000)) orelse
        return error.TestUnexpectedResult;
    first.deinit(std.testing.allocator);

    _ = try draft.tool_progress.record(std.testing.allocator, .{ .tool = "web_fetch" }, 1_500);
    try draft.buffer.appendSlice(std.testing.allocator, "real answer");

    try std.testing.expect((try progressDraft(std.testing.allocator, &draft, 8_000)) == null);
    try std.testing.expect((try heartbeatDraft(std.testing.allocator, &draft, 8_000)) == null);
    // The deferred flag is cleared: no later heartbeat retries the tool block.
    try std.testing.expect(!draft.tool_progress.dirty);
}
