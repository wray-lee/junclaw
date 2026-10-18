const std = @import("std");
const json_util = @import("../json_util.zig");
const providers = @import("../providers/root.zig");

// Slack's streaming Web API methods are tiered per minute, so tiny deltas must
// be coalesced before they turn into HTTP calls:
//   chat.startStream  — Tier 2 (20+/min)
//   chat.appendStream — Tier 4 (100+/min)
//   chat.stopStream   — Tier 2 (20+/min)
//   chat.update       — Tier 3 (50+/min)   (fallback path)
//   chat.postMessage  — ~1 message/second/channel (fallback path)
// A one-second floor keeps every method comfortably inside its tier while still
// looking live to a human reader.
pub const STREAM_FLUSH_MIN_INTERVAL_MS: i64 = std.time.ms_per_s;
pub const STREAM_FLUSH_MIN_DELTA_BYTES: usize = 128;

/// `markdown_text` cap accepted by chat.startStream/chat.appendStream/chat.stopStream.
pub const STREAM_MARKDOWN_MAX_BYTES: usize = 12_000;
/// Cumulative `markdown_text` budget for one streamed turn. Slack caps the whole
/// streamed message, not just each chat.appendStream call, and answers
/// `msg_too_long` once the accumulated text passes that undocumented cap, which
/// a per-call split (STREAM_MARKDOWN_MAX_BYTES) cannot prevent. Past this budget
/// the native stream is closed and the rest of the turn finishes on the
/// edited-message transport (chat.update + thread follow-ups).
///
/// The value is a conservative proxy: Slack documents the 12,000-char per-call
/// cap but not the cumulative one, so the per-call cap is reused as the budget
/// (a lower real cap only means an earlier, safe switch). It is not the sole
/// trigger — an actual `msg_too_long` from chat.appendStream also closes the
/// stream (see `publishStreamFlushLocked`), so a wrong constant cannot leak the
/// error to the user.
pub const STREAM_TOTAL_MAX_BYTES: usize = STREAM_MARKDOWN_MAX_BYTES;

/// Slack counts the text after escaping `&`, `<`, and `>` for mrkdwn. Counting
/// those expansions here keeps byte-bounded previews and stream chunks below
/// Slack's character limits while remaining a conservative UTF-8 upper bound.
pub fn slackEscapedLen(text: []const u8) usize {
    var len: usize = 0;
    for (text) |c| {
        len += switch (c) {
            '&' => 5, // &amp;
            '<', '>' => 4, // &lt; / &gt;
            else => 1,
        };
    }
    return len;
}

/// True when appending `suffix_len` more raw bytes to the already-streamed
/// text would push the escaped native stream past Slack's cumulative cap.
pub fn finalAppendOverflowsEscapedBudget(sent: []const u8, suffix: []const u8) bool {
    return slackEscapedLen(sent) + slackEscapedLen(suffix) > STREAM_TOTAL_MAX_BYTES;
}

/// True when appending `suffix_len` more bytes to the already-streamed
/// `sent_len` would push the native stream past Slack's cumulative message cap.
/// The caller must then finish on the edited-message transport instead of
/// issuing a chat.appendStream that would answer `msg_too_long`.
pub fn finalAppendOverflowsBudget(sent_len: usize, suffix_len: usize) bool {
    return sent_len + suffix_len > STREAM_TOTAL_MAX_BYTES;
}

/// `text` cap accepted by chat.update; Slack answers `msg_too_long` above this.
pub const STREAM_UPDATE_MAX_BYTES: usize = 4_000;
/// Prefix shown when a live preview had to drop its oldest text to fit the
/// chat.update cap.
pub const PREVIEW_TRUNCATED_MARKER = "\u{2026} (earlier text truncated)\n\n";
/// Upper bound on follow-up messages posted when the final reply overflows.
pub const STREAM_MAX_FOLLOWUPS: usize = 8;
/// Short marker appended when follow-up messages hit STREAM_MAX_FOLLOWUPS.
pub const FINAL_TRUNCATED_MARKER = "\n\n(reply truncated)";

/// Append the truncation marker to `chunk`, trimming chunk if necessary so that
/// the escaped mrkdwn length fits within `limit`.
pub fn appendTruncationMarker(allocator: std.mem.Allocator, chunk: []const u8, limit: usize) ![]u8 {
    const marker = FINAL_TRUNCATED_MARKER;
    const marker_cost = slackEscapedLen(marker);
    if (limit <= marker_cost) {
        return allocator.dupe(u8, marker);
    }
    const max_chunk_budget = limit - marker_cost;
    var cost: usize = 0;
    var cut: usize = 0;
    var i: usize = 0;
    while (i < chunk.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(chunk[i]) catch 1;
        const next = @min(chunk.len, i + cp_len);
        const cp_cost = switch (chunk[i]) {
            '&' => 5,
            '<', '>' => 4,
            else => next - i,
        };
        if (cost + cp_cost > max_chunk_budget) break;
        cost += cp_cost;
        cut = next;
        i = next;
    }
    var result = try allocator.alloc(u8, cut + marker.len);
    @memcpy(result[0..cut], chunk[0..cut]);
    @memcpy(result[cut..], marker);
    return result;
}
/// How long a finalized target keeps ignoring `.chunk` events. The daemon
/// publishes the final reply on the durable outbox worker while the outbound
/// dispatcher may still be draining deltas of the same turn; without this the
/// leftovers would open a second stream for a turn that already ended.
pub const STREAM_LATE_CHUNK_GRACE_MS: i64 = 5 * std.time.ms_per_s;
/// Above this many tracked targets the channel sweeps finalized entries.
pub const STREAM_MAX_TRACKED_TARGETS: usize = 64;

pub const StreamMode = enum {
    /// chat.startStream / chat.appendStream / chat.stopStream.
    native,
    /// chat.postMessage + chat.update edits of a single message.
    fallback,
};

/// A Slack outbound target is either a bare channel id or "channel_id:thread_ts".
pub const StreamTarget = struct {
    channel_id: []const u8,
    thread_ts: ?[]const u8 = null,
};

/// Slack only accepts a stream inside a thread, and an app without the
/// Agents & AI Apps feature can never stream at all. Everything else uses
/// chat.postMessage + chat.update edits.
pub fn chooseTurnTransport(has_thread: bool, native_disabled: bool) StreamMode {
    if (native_disabled or !has_thread) return .fallback;
    return .native;
}

/// Split "channel_id:thread_ts" into its parts. Slack channel ids never contain
/// a colon, so the first colon is always the separator.
pub fn resolveStreamTarget(target: []const u8) StreamTarget {
    const idx = std.mem.indexOfScalar(u8, target, ':') orelse
        return .{ .channel_id = target };
    const thread_ts = target[idx + 1 ..];
    if (thread_ts.len == 0) return .{ .channel_id = target[0..idx] };
    return .{ .channel_id = target[0..idx], .thread_ts = thread_ts };
}

pub const StreamState = struct {
    /// Raw markdown deltas accumulated for this turn.
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    /// Last snapshot handed to the transport (owned). Used to compute the
    /// incremental suffix for chat.appendStream.
    sent: []u8 = &.{},
    last_flush_time: i64 = 0,
    started_at_ms: i64 = 0,
    /// Streaming message ts returned by chat.startStream / chat.postMessage.
    message_ts: []u8 = &.{},
    /// Transport chosen for this turn; switches to `.fallback` if the native
    /// start call is rejected.
    mode: StreamMode = .native,
    /// A live update failed; stop flushing this turn and let the final reply
    /// reconcile the message.
    send_failed: bool = false,
    /// Current escaped preview budget. Slack may reject a nominally bounded
    /// update, so the fallback retries with a smaller bound for this turn.
    preview_limit: usize = STREAM_UPDATE_MAX_BYTES,
    /// A reasoning block was rendered into this turn's stream. The final reply
    /// never contains the thinking, so the streamed snapshot cannot be a prefix
    /// of it; the final pass rewrites the message in place instead of posting a
    /// second copy.
    rendered_reasoning: bool = false,
    /// Set when the final reply was delivered for this target.
    finished_at_ms: i64 = 0,

    pub fn deinit(self: *StreamState, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        if (self.sent.len > 0) allocator.free(self.sent);
        if (self.message_ts.len > 0) allocator.free(self.message_ts);
        self.* = .{};
    }

    /// Release the per-turn buffers and mark the turn finished. The entry stays
    /// in the channel map so late deltas of the same turn are recognised.
    pub fn finishTurn(self: *StreamState, allocator: std.mem.Allocator, now_ms: i64) void {
        self.buffer.deinit(allocator);
        self.buffer = .empty;
        if (self.sent.len > 0) allocator.free(self.sent);
        self.sent = &.{};
        if (self.message_ts.len > 0) allocator.free(self.message_ts);
        self.message_ts = &.{};
        self.last_flush_time = 0;
        self.started_at_ms = 0;
        self.send_failed = false;
        self.preview_limit = STREAM_UPDATE_MAX_BYTES;
        self.rendered_reasoning = false;
        self.finished_at_ms = now_ms;
    }

    /// True while `.chunk` events for this target belong to a turn that already
    /// delivered its final reply.
    pub fn isLateChunk(self: *const StreamState, now_ms: i64) bool {
        if (self.finished_at_ms == 0) return false;
        return now_ms - self.finished_at_ms < STREAM_LATE_CHUNK_GRACE_MS;
    }

    pub fn setMessageTs(self: *StreamState, allocator: std.mem.Allocator, ts: []const u8) !void {
        const owned = try allocator.dupe(u8, ts);
        if (self.message_ts.len > 0) allocator.free(self.message_ts);
        self.message_ts = owned;
    }
};

/// Result of a throttled flush: `text` is the full cleaned snapshot for this
/// turn and `text[delta_start..]` is the part that has not been sent yet.
pub const StreamFlush = struct {
    text: []u8,
    delta_start: usize,
    /// True when the snapshot no longer extends what was already sent, so the
    /// caller must replace the message rather than append the whole snapshot.
    /// Set when an orphan reasoning closer drops the leaked draft from earlier
    /// bytes, or a late `<think>` rewrite moves them.
    rewrite: bool = false,
    /// True when the accumulated snapshot has grown past STREAM_TOTAL_MAX_BYTES,
    /// so extending the native stream would make Slack answer `msg_too_long`.
    /// The caller closes the stream and finishes on the edited-message
    /// transport.
    native_full: bool = false,

    pub fn deinit(self: *StreamFlush, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.text = &.{};
    }

    pub fn delta(self: *const StreamFlush) []const u8 {
        return self.text[self.delta_start..];
    }
};

pub fn hasVisibleStreamText(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len != 0;
}

fn shouldFlush(state: *const StreamState, now_ms: i64) bool {
    const pending = state.buffer.items.len - state.sent.len;
    if (pending == 0) return false;
    if (now_ms - state.last_flush_time >= STREAM_FLUSH_MIN_INTERVAL_MS) return true;
    // Only the first flush of a turn may open the stream before the interval,
    // and only once a meaningful amount of text has accumulated. Every later
    // flush waits the full interval, so a fast token stream can no longer turn
    // one turn into a burst of synchronous Slack calls.
    return state.sent.len == 0 and pending >= STREAM_FLUSH_MIN_DELTA_BYTES;
}

/// Snapshot the buffered stream for the wire.
///
/// `<think>` blocks only arrive when the daemon forwards them, which it does
/// solely for `reasoning_mode == .stream`; every other mode already had them
/// stripped upstream, so the quote rendering is a no-op there.
fn snapshotStreamText(allocator: std.mem.Allocator, state: *const StreamState) ![]u8 {
    const rendered = try providers.quoteThinkBlocks(allocator, state.buffer.items);
    defer allocator.free(rendered);
    return allocator.dupe(u8, rendered);
}

/// Append a delta and return a flush when the coalescing window has elapsed.
/// Reasoning blocks are rendered as quotes here as well as upstream, and the
/// final reply always goes through `stripThinkBlocks`, so the delivered message
/// never carries the thinking.
pub fn appendStreamChunk(
    allocator: std.mem.Allocator,
    state: *StreamState,
    chunk: []const u8,
    now_ms: i64,
) !?StreamFlush {
    if (chunk.len == 0) return null;
    // A delta this long after the previous turn finished belongs to a new turn.
    if (state.finished_at_ms != 0 and !state.isLateChunk(now_ms)) state.finished_at_ms = 0;
    if (state.started_at_ms == 0) {
        // Start the coalescing window on the first delta so a short reply never
        // opens a stream just to close it immediately (each start/stop pair
        // costs a Tier-2 call).
        state.started_at_ms = now_ms;
        state.last_flush_time = now_ms;
    }

    try state.buffer.appendSlice(allocator, chunk);
    // Checked on the accumulated buffer: a reasoning tag split across chunks is
    // only complete once both halves have arrived. Any reasoning tag (including
    // a namespaced or orphan closer) makes the snapshot diverge from the final
    // reply, which never carries the reasoning.
    if (providers.hasReasoningTag(state.buffer.items)) state.rendered_reasoning = true;
    if (!shouldFlush(state, now_ms)) return null;

    const text = try snapshotStreamText(allocator, state);
    errdefer allocator.free(text);

    if (!hasVisibleStreamText(text)) {
        allocator.free(text);
        return null;
    }

    // Normally the snapshot extends what we already sent. If a late `<think>`
    // rewrite, or an orphan closer dropping the leaked draft, moved earlier
    // bytes, the whole snapshot must replace the message instead of a suffix
    // that would drop text (or an append that would duplicate it).
    const extends_sent = std.mem.startsWith(u8, text, state.sent);
    const rewrite = !extends_sent and state.sent.len > 0;
    const delta_start = if (extends_sent) state.sent.len else 0;

    const sent_copy = try allocator.dupe(u8, text);
    if (state.sent.len > 0) allocator.free(state.sent);
    state.sent = sent_copy;
    state.last_flush_time = now_ms;

    return .{
        .text = text,
        .delta_start = delta_start,
        .rewrite = rewrite,
        .native_full = slackEscapedLen(text) > STREAM_TOTAL_MAX_BYTES,
    };
}

/// Suffix of `final_text` that still has to be streamed so the message content
/// ends up equal to `final_text`. Returns null when the streamed prefix is not
/// a prefix of the final text (the caller must then deliver a fresh message).
pub fn pendingFinalSuffix(final_text: []const u8, sent: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, final_text, sent)) return null;
    return final_text[sent.len..];
}

pub fn clearStreamState(
    allocator: std.mem.Allocator,
    states: *std.StringHashMapUnmanaged(StreamState),
    target: []const u8,
) void {
    if (states.fetchRemove(target)) |entry| {
        allocator.free(entry.key);
        var state = entry.value;
        state.deinit(allocator);
    }
}

pub fn deinitStreamStates(
    allocator: std.mem.Allocator,
    states: *std.StringHashMapUnmanaged(StreamState),
) void {
    var it = states.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    states.deinit(allocator);
    states.* = .empty;
}

// ---------------------------------------------------------------------------
// Request bodies
// ---------------------------------------------------------------------------

pub fn buildStartStreamBody(
    allocator: std.mem.Allocator,
    channel_id: []const u8,
    thread_ts: ?[]const u8,
    markdown_text: []const u8,
) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);

    try body.appendSlice(allocator, "{\"channel\":");
    try json_util.appendJsonString(&body, allocator, channel_id);
    if (thread_ts) |ts| {
        try body.appendSlice(allocator, ",\"thread_ts\":");
        try json_util.appendJsonString(&body, allocator, ts);
    }
    try body.appendSlice(allocator, ",\"markdown_text\":");
    try json_util.appendJsonString(&body, allocator, markdown_text);
    try body.append(allocator, '}');
    return body.toOwnedSlice(allocator);
}

pub fn buildAppendStreamBody(
    allocator: std.mem.Allocator,
    channel_id: []const u8,
    ts: []const u8,
    markdown_text: []const u8,
) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);

    try body.appendSlice(allocator, "{\"channel\":");
    try json_util.appendJsonString(&body, allocator, channel_id);
    try body.appendSlice(allocator, ",\"ts\":");
    try json_util.appendJsonString(&body, allocator, ts);
    try body.appendSlice(allocator, ",\"markdown_text\":");
    try json_util.appendJsonString(&body, allocator, markdown_text);
    try body.append(allocator, '}');
    return body.toOwnedSlice(allocator);
}

/// `chat.stopStream` only finalizes; the content was already sent through
/// start/append. Passing `markdown_text` here would append it a second time.
pub fn buildStopStreamBody(
    allocator: std.mem.Allocator,
    channel_id: []const u8,
    ts: []const u8,
) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);

    try body.appendSlice(allocator, "{\"channel\":");
    try json_util.appendJsonString(&body, allocator, channel_id);
    try body.appendSlice(allocator, ",\"ts\":");
    try json_util.appendJsonString(&body, allocator, ts);
    try body.append(allocator, '}');
    return body.toOwnedSlice(allocator);
}

pub fn buildUpdateBody(
    allocator: std.mem.Allocator,
    channel_id: []const u8,
    ts: []const u8,
    text: []const u8,
) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);

    try body.appendSlice(allocator, "{\"channel\":");
    try json_util.appendJsonString(&body, allocator, channel_id);
    try body.appendSlice(allocator, ",\"ts\":");
    try json_util.appendJsonString(&body, allocator, ts);
    try body.appendSlice(allocator, ",\"text\":");
    try json_util.appendJsonString(&body, allocator, text);
    try body.append(allocator, '}');
    return body.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Failure classification
// ---------------------------------------------------------------------------

pub const StreamFailure = enum {
    /// This turn cannot stream natively; retry the API on a later turn.
    abandon_turn,
    /// This workspace/app/channel can never stream natively; stop trying for
    /// the lifetime of the account.
    disable_native,
};

const native_disabling_codes = [_][]const u8{
    // The method itself is unavailable to this app or channel type.
    "channel_type_not_supported",
    "method_not_supported_for_channel_type",
    "unknown_method",
    "not_allowed",
    "invalid_thread_ts",
    "restricted_action_thread_only_channel",
    "restricted_action_non_threadable_channel",
    "restricted_action_thread_locked",
    // Credential/feature gating: Agents & AI Apps toggle or assistant scopes.
    "missing_scope",
    "not_allowed_token_type",
    "no_permission",
    "restricted_action",
    "invalid_arguments",
    "missing_recipient_user_id",
    "missing_recipient_team_id",
};

/// Map a Slack `error` string to a retry policy. Unknown codes are treated as
/// transient so a new Slack error never permanently disables streaming.
pub fn classifyStreamFailure(code: []const u8) StreamFailure {
    for (native_disabling_codes) |known| {
        if (std.mem.eql(u8, code, known)) return .disable_native;
    }
    return .abandon_turn;
}

// ---------------------------------------------------------------------------
// Length handling
// ---------------------------------------------------------------------------

fn utf8SafeCut(text: []const u8, limit: usize) usize {
    var cut = @min(limit, text.len);
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    return cut;
}

/// Start index of the newest `max_bytes` bytes of `text`, moved forward past
/// UTF-8 continuation bytes so the tail starts on a codepoint boundary.
fn utf8SafeTailStart(text: []const u8, max_bytes: usize) usize {
    if (text.len <= max_bytes) return 0;
    var start = text.len - max_bytes;
    while (start < text.len and (text[start] & 0xC0) == 0x80) start += 1;
    return start;
}

/// Return the newest UTF-8-safe tail whose escaped Slack length fits `limit`.
fn escapedSafeTailStart(text: []const u8, limit: usize) usize {
    var cost: usize = 0;
    var start = text.len;
    var i = text.len;
    while (i > 0) {
        var cp_start = i - 1;
        while (cp_start > 0 and (text[cp_start] & 0xC0) == 0x80) cp_start -= 1;
        const cp_cost = switch (text[cp_start]) {
            '&' => 5,
            '<', '>' => 4,
            else => i - cp_start,
        };
        if (cost + cp_cost > limit) break;
        cost += cp_cost;
        start = cp_start;
        i = cp_start;
    }
    return start;
}

/// Fence state carried across chunks: the language tag of an open ``` block.
const FenceState = struct {
    lang: ?[]const u8 = null,
};

/// Advance the fence state over the complete lines in `text[from..to]`. A
/// newline at `to` also completes the line. `next_pos` receives the start of
/// the first line left unscanned; the caller passes it back as `from`.
fn advanceFenceState(
    state_in: FenceState,
    text: []const u8,
    from: usize,
    to: usize,
    next_pos: *usize,
) FenceState {
    var state = state_in;
    var pos = from;
    var end = to;
    if (end < text.len and text[end] == '\n') end += 1;
    while (pos < end) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse break;
        if (nl >= end) break;
        const trimmed = std.mem.trimStart(u8, text[pos..nl], " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            state.lang = if (state.lang == null)
                std.mem.trim(u8, trimmed[3..], " \t\r")
            else
                null;
        }
        pos = nl + 1;
    }
    next_pos.* = pos;
    return state;
}

/// True when the chunk window can touch a fence line, so the chunker reserves
/// room for a closing/reopening fence. No chunk consumes more than `limit`.
fn windowMayContainFence(state: FenceState, rest: []const u8, limit: usize) bool {
    return state.lang != null or
        std.mem.indexOf(u8, rest[0..@min(rest.len, limit)], "```") != null;
}

/// Build one chunk, reopening `reopen_lang` at the start and closing the block
/// at the end when the cut falls inside a fence.
fn buildFencedChunk(
    allocator: std.mem.Allocator,
    body: []const u8,
    reopen_lang: ?[]const u8,
    close_fence: bool,
) ![]u8 {
    const prefix_len: usize = if (reopen_lang) |lang| 3 + lang.len + 1 else 0;
    const needs_newline = close_fence and (body.len == 0 or body[body.len - 1] != '\n');
    const close_len: usize = if (close_fence) 3 + @as(usize, @intFromBool(needs_newline)) else 0;
    const out = try allocator.alloc(u8, prefix_len + body.len + close_len);
    var w: usize = 0;
    if (reopen_lang) |lang| {
        @memcpy(out[w..][0..3], "```");
        w += 3;
        @memcpy(out[w..][0..lang.len], lang);
        w += lang.len;
        out[w] = '\n';
        w += 1;
    }
    @memcpy(out[w..][0..body.len], body);
    w += body.len;
    if (close_fence) {
        if (needs_newline) {
            out[w] = '\n';
            w += 1;
        }
        @memcpy(out[w..][0..3], "```");
        w += 3;
    }
    std.debug.assert(w == out.len);
    return out;
}

/// Split text so each chunk's escaped mrkdwn length fits Slack's limit.
/// A code fence open at a cut is closed at the end of the chunk and reopened
/// with the same language tag at the start of the next one.
pub fn splitForSlackLimit(
    allocator: std.mem.Allocator,
    text: []const u8,
    limit: usize,
) ![][]const u8 {
    std.debug.assert(limit > 0);
    var chunks: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (chunks.items) |chunk| allocator.free(chunk);
        chunks.deinit(allocator);
    }
    var rest = text;
    var fence = FenceState{};
    var scan_pos: usize = 0;
    var reopen_lang: ?[]const u8 = null;
    while (true) {
        const prefix_len: usize = if (reopen_lang) |lang| 3 + lang.len + 1 else 0;
        if (slackEscapedLen(rest) + prefix_len <= limit) break;
        const reserve: usize = prefix_len + (if (windowMayContainFence(fence, rest, limit)) @as(usize, 4) else 0);
        const budget = if (limit > reserve) limit - reserve else limit;
        var cost: usize = 0;
        var cut: usize = 0;
        var i: usize = 0;
        while (i < rest.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(rest[i]) catch 1;
            const next = @min(rest.len, i + cp_len);
            const cp_cost = switch (rest[i]) {
                '&' => 5,
                '<', '>' => 4,
                else => next - i,
            };
            if (cost + cp_cost > budget) break;
            cost += cp_cost;
            cut = next;
            i = next;
        }
        if (cut == 0) return error.TextCannotFitSlackLimit;
        if (std.mem.lastIndexOfScalar(u8, rest[0..cut], '\n')) |nl| {
            // Keep the boundary newline: native append and final delivery must
            // preserve code lines as well as every byte of the answer.
            cut = nl + 1;
        }
        const base = text.len - rest.len;
        var next_scan_pos: usize = undefined;
        fence = advanceFenceState(fence, text, scan_pos, base + cut, &next_scan_pos);
        scan_pos = next_scan_pos;
        try chunks.append(allocator, try buildFencedChunk(allocator, rest[0..cut], reopen_lang, fence.lang != null));
        reopen_lang = fence.lang;
        rest = rest[cut..];
    }
    if (rest.len > 0 or chunks.items.len == 0) {
        try chunks.append(allocator, try buildFencedChunk(allocator, rest, reopen_lang, false));
    }
    return chunks.toOwnedSlice(allocator);
}

/// Bound a live preview to Slack's chat.update cap.
///
/// A preview that grows past the cap is truncated from the front so the message
/// keeps showing the newest text instead of freezing on its first 4,000 bytes,
/// and the omission is marked. The cut never splits a UTF-8 codepoint. This only
/// bounds the in-place preview; the authoritative final reply is still delivered
/// complete through `splitForLimit` and thread follow-ups.
pub fn boundUpdatePreview(allocator: std.mem.Allocator, text: []const u8, limit: usize) ![]u8 {
    if (slackEscapedLen(text) <= limit) return allocator.dupe(u8, text);

    if (limit <= slackEscapedLen(PREVIEW_TRUNCATED_MARKER)) {
        return allocator.dupe(u8, text[escapedSafeTailStart(text, limit)..]);
    }

    const budget = limit - slackEscapedLen(PREVIEW_TRUNCATED_MARKER);
    const start = escapedSafeTailStart(text, budget);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, PREVIEW_TRUNCATED_MARKER);
    try out.appendSlice(allocator, text[start..]);
    return out.toOwnedSlice(allocator);
}

/// Split `text` into pieces of at most `limit` bytes, preferring a newline
/// boundary so code blocks and lists stay readable. Caller frees each piece
/// and the returned slice via `freeChunks`. Code fences are closed and
/// reopened across cuts the same way as `splitForSlackLimit`.
pub fn splitForLimit(
    allocator: std.mem.Allocator,
    text: []const u8,
    limit: usize,
) ![][]const u8 {
    std.debug.assert(limit > 0);
    var chunks: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (chunks.items) |chunk| allocator.free(chunk);
        chunks.deinit(allocator);
    }

    var rest = text;
    var fence = FenceState{};
    var scan_pos: usize = 0;
    var reopen_lang: ?[]const u8 = null;
    while (true) {
        const prefix_len: usize = if (reopen_lang) |lang| 3 + lang.len + 1 else 0;
        if (rest.len + prefix_len <= limit) break;
        const reserve: usize = prefix_len + (if (windowMayContainFence(fence, rest, limit)) @as(usize, 4) else 0);
        const budget = if (limit > reserve) limit - reserve else limit;
        var cut = utf8SafeCut(rest, budget);
        if (std.mem.lastIndexOfScalar(u8, rest[0..cut], '\n')) |nl| {
            if (nl > 0) cut = nl;
        }
        if (cut == 0) cut = @min(std.unicode.utf8ByteSequenceLength(rest[0]) catch 1, rest.len);
        const base = text.len - rest.len;
        var next_scan_pos: usize = undefined;
        fence = advanceFenceState(fence, text, scan_pos, base + cut, &next_scan_pos);
        scan_pos = next_scan_pos;
        try chunks.append(allocator, try buildFencedChunk(allocator, rest[0..cut], reopen_lang, fence.lang != null));
        reopen_lang = fence.lang;
        rest = rest[cut..];
        // Drop the boundary newline so the next chunk does not start blank.
        if (rest.len > 0 and rest[0] == '\n') rest = rest[1..];
    }
    if (rest.len > 0) try chunks.append(allocator, try buildFencedChunk(allocator, rest, reopen_lang, false));
    return chunks.toOwnedSlice(allocator);
}

pub fn freeChunks(allocator: std.mem.Allocator, chunks: [][]const u8) void {
    for (chunks) |chunk| allocator.free(chunk);
    allocator.free(chunks);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "chooseTurnTransport requires a thread and an enabled app" {
    try std.testing.expect(chooseTurnTransport(true, false) == .native);
    try std.testing.expect(chooseTurnTransport(true, true) == .fallback);
    try std.testing.expect(chooseTurnTransport(false, false) == .fallback);
    try std.testing.expect(chooseTurnTransport(false, true) == .fallback);
}

test "resolveStreamTarget splits channel and thread" {
    const threaded = resolveStreamTarget("C123:1700000000.000100");
    try std.testing.expectEqualStrings("C123", threaded.channel_id);
    try std.testing.expectEqualStrings("1700000000.000100", threaded.thread_ts.?);

    const plain = resolveStreamTarget("C123");
    try std.testing.expectEqualStrings("C123", plain.channel_id);
    try std.testing.expect(plain.thread_ts == null);

    const empty_thread = resolveStreamTarget("C123:");
    try std.testing.expectEqualStrings("C123", empty_thread.channel_id);
    try std.testing.expect(empty_thread.thread_ts == null);

    const dm = resolveStreamTarget("D123:1700000000.000100");
    try std.testing.expectEqualStrings("D123", dm.channel_id);
    try std.testing.expectEqualStrings("1700000000.000100", dm.thread_ts.?);
}

test "appendStreamChunk keeps short deltas buffered inside the window" {
    var state = StreamState{};
    defer state.deinit(std.testing.allocator);

    try std.testing.expect((try appendStreamChunk(std.testing.allocator, &state, "hi", 1_000)) == null);
    try std.testing.expect((try appendStreamChunk(std.testing.allocator, &state, " there", 1_500)) == null);
    try std.testing.expectEqual(@as(usize, 0), state.sent.len);
}

test "appendStreamChunk flushes after the minimum interval" {
    var state = StreamState{};
    defer state.deinit(std.testing.allocator);

    try std.testing.expect((try appendStreamChunk(std.testing.allocator, &state, "hello", 1_000)) == null);

    var flush = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        " world",
        1_000 + STREAM_FLUSH_MIN_INTERVAL_MS,
    )) orelse return error.TestUnexpectedResult;
    defer flush.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello world", flush.text);
    try std.testing.expectEqual(@as(usize, 0), flush.delta_start);
    try std.testing.expectEqualStrings("hello world", flush.delta());
}

test "appendStreamChunk does not open a stream for a reply inside the window" {
    var state = StreamState{};
    defer state.deinit(std.testing.allocator);

    try std.testing.expect((try appendStreamChunk(std.testing.allocator, &state, "ok", 1_000)) == null);
    try std.testing.expect((try appendStreamChunk(
        std.testing.allocator,
        &state,
        " thanks!",
        1_000 + STREAM_FLUSH_MIN_INTERVAL_MS - 1,
    )) == null);
}

test "appendStreamChunk flushes on the minimum delta before the interval" {
    var state = StreamState{};
    defer state.deinit(std.testing.allocator);

    const big = "x" ** (STREAM_FLUSH_MIN_DELTA_BYTES + 1);
    var flush = (try appendStreamChunk(std.testing.allocator, &state, big, 1_000)) orelse
        return error.TestUnexpectedResult;
    defer flush.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(big, flush.text);
}

test "appendStreamChunk throttles a sustained delta stream to one flush per interval" {
    var state = StreamState{};
    defer state.deinit(std.testing.allocator);

    // The first burst opens the stream.
    var first = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        "a" ** STREAM_FLUSH_MIN_DELTA_BYTES,
        1_000,
    )) orelse return error.TestUnexpectedResult;
    defer first.deinit(std.testing.allocator);

    // Regression: a fast token stream used to flush on every delta >=
    // STREAM_FLUSH_MIN_DELTA_BYTES, turning one turn into dozens of synchronous
    // Slack calls. Inside the window only the first flush may happen.
    try std.testing.expect((try appendStreamChunk(
        std.testing.allocator,
        &state,
        "b" ** STREAM_FLUSH_MIN_DELTA_BYTES,
        1_100,
    )) == null);
    try std.testing.expect((try appendStreamChunk(
        std.testing.allocator,
        &state,
        "c" ** STREAM_FLUSH_MIN_DELTA_BYTES,
        1_900,
    )) == null);

    var next = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        "d" ** STREAM_FLUSH_MIN_DELTA_BYTES,
        2_000,
    )) orelse return error.TestUnexpectedResult;
    defer next.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, STREAM_FLUSH_MIN_DELTA_BYTES * 4), next.text.len);
    try std.testing.expectEqual(@as(usize, STREAM_FLUSH_MIN_DELTA_BYTES), next.delta_start);
}

test "appendStreamChunk returns only the unsent suffix on later flushes" {
    var state = StreamState{ .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer state.deinit(std.testing.allocator);

    var first = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        "alpha",
        1_000 + STREAM_FLUSH_MIN_INTERVAL_MS,
    )) orelse return error.TestUnexpectedResult;
    defer first.deinit(std.testing.allocator);

    var second = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        " beta",
        1_000 + 2 * STREAM_FLUSH_MIN_INTERVAL_MS,
    )) orelse return error.TestUnexpectedResult;
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("alpha beta", second.text);
    try std.testing.expectEqualStrings(" beta", second.delta());
}

test "appendStreamChunk ignores empty and whitespace-only buffers" {
    var state = StreamState{};
    defer state.deinit(std.testing.allocator);

    try std.testing.expect((try appendStreamChunk(std.testing.allocator, &state, "", 5_000)) == null);
    try std.testing.expect((try appendStreamChunk(
        std.testing.allocator,
        &state,
        "  \n\t",
        5_000 + STREAM_FLUSH_MIN_INTERVAL_MS,
    )) == null);
    try std.testing.expectEqual(@as(usize, 0), state.sent.len);
}

test "appendStreamChunk renders streamed reasoning as a Slack quote" {
    var state = StreamState{ .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer state.deinit(std.testing.allocator);

    var flush = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        "<think>private reasoning</think>Visible answer",
        1_000 + STREAM_FLUSH_MIN_INTERVAL_MS,
    )) orelse return error.TestUnexpectedResult;
    defer flush.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("> private reasoning\n\nVisible answer", flush.text);
    try std.testing.expect(state.rendered_reasoning);
}

test "appendStreamChunk leaves drafts without reasoning untouched" {
    var state = StreamState{ .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer state.deinit(std.testing.allocator);

    // reasoning_mode off/on: the daemon strips think blocks before the channel
    // sees them, so the streamed text is exactly the visible answer.
    var flush = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        "Visible answer",
        1_000 + STREAM_FLUSH_MIN_INTERVAL_MS,
    )) orelse return error.TestUnexpectedResult;
    defer flush.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Visible answer", flush.text);
    try std.testing.expect(!state.rendered_reasoning);
}

test "appendStreamChunk resends the snapshot when a late think block rewrites it" {
    var state = StreamState{ .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer state.deinit(std.testing.allocator);

    // The first flush ends mid-tag, so "<thi" is still literal text.
    var first = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        "a<thi",
        1_000 + STREAM_FLUSH_MIN_INTERVAL_MS,
    )) orelse return error.TestUnexpectedResult;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a<thi", first.text);

    // The rest of the tag arrives later: the rendered snapshot no longer
    // extends what was already sent, so the whole snapshot is resent.
    var second = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        "nk>b</think>c",
        1_000 + 2 * STREAM_FLUSH_MIN_INTERVAL_MS,
    )) orelse return error.TestUnexpectedResult;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a\n> b\n\nc", second.text);
    try std.testing.expectEqual(@as(usize, 0), second.delta_start);
    try std.testing.expect(second.rewrite);
    try std.testing.expect(state.rendered_reasoning);
}

test "appendStreamChunk flags a rewrite when an orphan closer drops the draft" {
    var state = StreamState{ .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer state.deinit(std.testing.allocator);

    // The leaked draft streams first (no opener, so nothing flags it yet).
    var first = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        "Draft answer.",
        1_000 + STREAM_FLUSH_MIN_INTERVAL_MS,
    )) orelse return error.TestUnexpectedResult;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Draft answer.", first.text);
    try std.testing.expect(!first.rewrite);

    // The orphan closer arrives: the snapshot drops the draft, so the caller
    // must replace the message rather than append the real answer after it.
    var second = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        "</ifm|think>\nReal answer.",
        1_000 + 2 * STREAM_FLUSH_MIN_INTERVAL_MS,
    )) orelse return error.TestUnexpectedResult;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Real answer.", second.text);
    try std.testing.expectEqual(@as(usize, 0), second.delta_start);
    try std.testing.expect(second.rewrite);
    try std.testing.expect(state.rendered_reasoning);
}

test "finalAppendOverflowsBudget guards the closing append" {
    try std.testing.expect(!finalAppendOverflowsBudget(0, STREAM_TOTAL_MAX_BYTES));
    try std.testing.expect(finalAppendOverflowsBudget(1, STREAM_TOTAL_MAX_BYTES));
    try std.testing.expect(finalAppendOverflowsBudget(STREAM_TOTAL_MAX_BYTES - 5, 10));
}

test "appendStreamChunk does not flag a short snapshot full" {
    var state = StreamState{ .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer state.deinit(std.testing.allocator);

    var flush = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        "hello world",
        1_000 + STREAM_FLUSH_MIN_INTERVAL_MS,
    )) orelse return error.TestUnexpectedResult;
    defer flush.deinit(std.testing.allocator);
    try std.testing.expect(!flush.native_full);
}

test "appendStreamChunk flags the native stream full once the turn crosses the budget" {
    var state = StreamState{ .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer state.deinit(std.testing.allocator);

    // Slack caps the whole streamed message, not each call. Two flushes that
    // each stay under the per-call cap must trip the flag once their sum does.
    const part = "x" ** 7_000;
    var first = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        part,
        1_000 + STREAM_FLUSH_MIN_INTERVAL_MS,
    )) orelse return error.TestUnexpectedResult;
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(!first.native_full);

    var second = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        part,
        1_000 + 2 * STREAM_FLUSH_MIN_INTERVAL_MS,
    )) orelse return error.TestUnexpectedResult;
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second.native_full);
    try std.testing.expectEqual(@as(usize, 14_000), second.text.len);
}

test "pendingFinalSuffix returns the unsent remainder for a prefix reply" {
    try std.testing.expectEqualStrings(" world", pendingFinalSuffix("hello world", "hello").?);
    try std.testing.expectEqualStrings("", pendingFinalSuffix("hello", "hello").?);
    try std.testing.expect(pendingFinalSuffix("other", "hello") == null);
}

test "classifyStreamFailure disables native streaming for feature gating codes" {
    try std.testing.expect(classifyStreamFailure("missing_scope") == .disable_native);
    try std.testing.expect(classifyStreamFailure("channel_type_not_supported") == .disable_native);
    try std.testing.expect(classifyStreamFailure("invalid_thread_ts") == .disable_native);
    try std.testing.expect(classifyStreamFailure("not_allowed") == .disable_native);
    try std.testing.expect(classifyStreamFailure("restricted_action_thread_only_channel") == .disable_native);
    try std.testing.expect(classifyStreamFailure("missing_recipient_user_id") == .disable_native);
}

test "classifyStreamFailure keeps transient errors retryable" {
    try std.testing.expect(classifyStreamFailure("ratelimited") == .abandon_turn);
    try std.testing.expect(classifyStreamFailure("internal_error") == .abandon_turn);
    try std.testing.expect(classifyStreamFailure("service_unavailable") == .abandon_turn);
    try std.testing.expect(classifyStreamFailure("message_not_in_streaming_state") == .abandon_turn);
    try std.testing.expect(classifyStreamFailure("some_new_slack_error") == .abandon_turn);
}

test "buildStartStreamBody includes thread_ts when threaded" {
    const body = try buildStartStreamBody(std.testing.allocator, "C123", "1700.1", "hello *world*");
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("C123", parsed.value.object.get("channel").?.string);
    try std.testing.expectEqualStrings("1700.1", parsed.value.object.get("thread_ts").?.string);
    try std.testing.expectEqualStrings("hello *world*", parsed.value.object.get("markdown_text").?.string);
}

test "buildStartStreamBody omits thread_ts for top-level streams" {
    const body = try buildStartStreamBody(std.testing.allocator, "C123", null, "hi");
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("thread_ts") == null);
}

test "buildAppendStreamBody carries channel ts and markdown_text" {
    const body = try buildAppendStreamBody(std.testing.allocator, "C123", "1700.1", "more \"text\"");
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("C123", parsed.value.object.get("channel").?.string);
    try std.testing.expectEqualStrings("1700.1", parsed.value.object.get("ts").?.string);
    try std.testing.expectEqualStrings("more \"text\"", parsed.value.object.get("markdown_text").?.string);
}

test "buildStopStreamBody sends only channel and ts" {
    const body = try buildStopStreamBody(std.testing.allocator, "C123", "1700.1");
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.count());
    try std.testing.expect(parsed.value.object.get("markdown_text") == null);
}

test "buildUpdateBody carries the replacement text" {
    const body = try buildUpdateBody(std.testing.allocator, "C123", "1700.1", "*final*");
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("C123", parsed.value.object.get("channel").?.string);
    try std.testing.expectEqualStrings("1700.1", parsed.value.object.get("ts").?.string);
    try std.testing.expectEqualStrings("*final*", parsed.value.object.get("text").?.string);
}

test "buildStartStreamBody escapes quotes and newlines" {
    const body = try buildStartStreamBody(std.testing.allocator, "C123", "1700.1", "a\"b\nc");
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\"b\nc", parsed.value.object.get("markdown_text").?.string);
}

test "splitForLimit keeps short text intact" {
    const chunks = try splitForLimit(std.testing.allocator, "short", 100);
    defer freeChunks(std.testing.allocator, chunks);
    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqualStrings("short", chunks[0]);
}

test "splitForLimit splits long text and prefers newline boundaries" {
    const text = ("a" ** 40) ++ "\n" ++ ("b" ** 40);
    const chunks = try splitForLimit(std.testing.allocator, text, 50);
    defer freeChunks(std.testing.allocator, chunks);
    try std.testing.expectEqual(@as(usize, 2), chunks.len);
    try std.testing.expectEqualStrings("a" ** 40, chunks[0]);
    try std.testing.expectEqualStrings("b" ** 40, chunks[1]);
}

test "splitForLimit never cuts a multibyte character" {
    const text = "é" ** 60; // 2 bytes each = 120 bytes
    const chunks = try splitForLimit(std.testing.allocator, text, 7);
    defer freeChunks(std.testing.allocator, chunks);
    for (chunks) |chunk| {
        try std.testing.expect(chunk.len % 2 == 0);
        try std.testing.expect(std.unicode.utf8ValidateSlice(chunk));
    }
}

test "splitForLimit handles text without newlines" {
    const chunks = try splitForLimit(std.testing.allocator, "x" ** 25, 10);
    defer freeChunks(std.testing.allocator, chunks);
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    try std.testing.expectEqual(@as(usize, 10), chunks[0].len);
    try std.testing.expectEqual(@as(usize, 5), chunks[2].len);
}

test "splitForSlackLimit closes and reopens a code fence across chunks" {
    // Regression: a single-line fenced code block longer than the cap was cut
    // mid-block, so the chunk rendered as plain text and the next chunk lost
    // its language tag.
    const text = "```zig\n" ++ ("x" ** 3696) ++ "\n```";
    const limit = 1_000;
    const chunks = try splitForSlackLimit(std.testing.allocator, text, limit);
    defer freeChunks(std.testing.allocator, chunks);

    try std.testing.expect(chunks.len > 2);
    try std.testing.expect(std.mem.startsWith(u8, chunks[0], "```zig\n"));
    for (chunks) |chunk| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(chunk));
        try std.testing.expect(slackEscapedLen(chunk) <= limit);
    }
    for (chunks[0 .. chunks.len - 1]) |chunk| {
        try std.testing.expect(std.mem.endsWith(u8, chunk, "```"));
    }
    for (chunks[1..]) |chunk| {
        try std.testing.expect(std.mem.startsWith(u8, chunk, "```zig\n"));
    }
    try std.testing.expect(std.mem.endsWith(u8, chunks[chunks.len - 1], "```"));
}

test "splitForLimit closes and reopens a code fence across chunks" {
    const text = "```zig\n" ++ ("x" ** 3696) ++ "\n```";
    const limit = 1_000;
    const chunks = try splitForLimit(std.testing.allocator, text, limit);
    defer freeChunks(std.testing.allocator, chunks);

    try std.testing.expect(chunks.len > 2);
    for (chunks) |chunk| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(chunk));
        try std.testing.expect(chunk.len <= limit);
    }
    for (chunks[0 .. chunks.len - 1]) |chunk| {
        try std.testing.expect(std.mem.endsWith(u8, chunk, "```"));
    }
    for (chunks[1..]) |chunk| {
        try std.testing.expect(std.mem.startsWith(u8, chunk, "```zig\n"));
    }
}

test "splitForSlackLimit keeps fences balanced around multi-chunk code and prose" {
    const text = "Intro\n```python\n" ++ ("y" ** 2500) ++ "\n```\nOutro " ++ ("z" ** 2000);
    const limit = 600;
    const chunks = try splitForSlackLimit(std.testing.allocator, text, limit);
    defer freeChunks(std.testing.allocator, chunks);

    try std.testing.expect(chunks.len > 4);
    for (chunks) |chunk| try std.testing.expect(std.unicode.utf8ValidateSlice(chunk));
    // Only the original language tag is ever used to reopen a block.
    for (chunks[1..]) |chunk| {
        if (std.mem.startsWith(u8, chunk, "```")) {
            try std.testing.expect(std.mem.startsWith(u8, chunk, "```python\n"));
        }
    }
    // Prose after the closed block never grows a fence.
    const last = chunks[chunks.len - 1];
    try std.testing.expect(!std.mem.startsWith(u8, last, "```"));
    try std.testing.expect(std.mem.endsWith(u8, last, "z"));
}

test "splitForSlackLimit leaves already-closed fences untouched" {
    const code_block = "```js\n" ++ ("a" ** 20) ++ "\n```\n";
    const text = code_block ++ ("b" ** 100);
    const chunks = try splitForSlackLimit(std.testing.allocator, text, 60);
    defer freeChunks(std.testing.allocator, chunks);

    try std.testing.expectEqualStrings(code_block, chunks[0]);
    for (chunks[1..]) |chunk| try std.testing.expect(!std.mem.startsWith(u8, chunk, "```"));
}

test "slackEscapedLen counts mrkdwn entity expansion" {
    // Regression: the old byte bound let chat.update reject a 4,000-byte
    // preview after Slack expanded shell operators and URLs.
    try std.testing.expectEqual(@as(usize, 1), slackEscapedLen("x"));
}

test "boundUpdatePreview respects Slack escaped length" {
    const text = ("<&>" ** 1_500) ++ "LATEST";
    const preview = try boundUpdatePreview(std.testing.allocator, text, STREAM_UPDATE_MAX_BYTES);
    defer std.testing.allocator.free(preview);
    try std.testing.expect(slackEscapedLen(preview) <= STREAM_UPDATE_MAX_BYTES);
    try std.testing.expect(std.mem.endsWith(u8, preview, "LATEST"));
}

test "splitForSlackLimit keeps escaped chunks under the cap" {
    const text = "<&>" ** 2_000;
    const chunks = try splitForSlackLimit(std.testing.allocator, text, 400);
    defer freeChunks(std.testing.allocator, chunks);
    for (chunks) |chunk| try std.testing.expect(slackEscapedLen(chunk) <= 400);
}

test "boundUpdatePreview keeps a growing preview under the chat.update cap" {
    // Regression: updateStreamMessage sent only the head chunk (chunks[0]) of
    // splitForLimit, so a growing DM preview froze on its oldest 4,000 bytes.
    // `msg_too_long` is the error the chat.update cap would raise; the bound
    // keeps the newest text instead of the oldest.
    const text = ("x" ** 5_000) ++ "LATEST";
    const preview = try boundUpdatePreview(std.testing.allocator, text, STREAM_UPDATE_MAX_BYTES);
    defer std.testing.allocator.free(preview);

    try std.testing.expect(preview.len <= STREAM_UPDATE_MAX_BYTES);
    try std.testing.expect(std.mem.startsWith(u8, preview, PREVIEW_TRUNCATED_MARKER));
    try std.testing.expect(std.mem.endsWith(u8, preview, "LATEST"));
}

test "boundUpdatePreview never cuts a multibyte character" {
    // One ASCII byte shifts the tail cut onto a continuation byte of a 3-byte
    // codepoint, so a naive `text.len - max_bytes` cut would emit invalid UTF-8.
    const text = "x" ++ "\u{20AC}" ** 2_000; // 6,001 bytes
    const budget = STREAM_UPDATE_MAX_BYTES - PREVIEW_TRUNCATED_MARKER.len;
    try std.testing.expect((text[text.len - budget] & 0xC0) == 0x80);

    const preview = try boundUpdatePreview(std.testing.allocator, text, STREAM_UPDATE_MAX_BYTES);
    defer std.testing.allocator.free(preview);

    try std.testing.expect(preview.len <= STREAM_UPDATE_MAX_BYTES);
    try std.testing.expect(std.unicode.utf8ValidateSlice(preview));
    try std.testing.expect(std.mem.startsWith(u8, preview, PREVIEW_TRUNCATED_MARKER));
    // The cut resumed on the next full codepoint, keeping the newest text.
    try std.testing.expectEqual(@as(u8, 0xE2), preview[PREVIEW_TRUNCATED_MARKER.len]);
    try std.testing.expect(std.mem.endsWith(u8, preview, "\u{20AC}"));
}

test "boundUpdatePreview leaves a short preview untouched" {
    const preview = try boundUpdatePreview(std.testing.allocator, "short", STREAM_UPDATE_MAX_BYTES);
    defer std.testing.allocator.free(preview);
    try std.testing.expectEqualStrings("short", preview);
}

test "finishTurn clears per-turn state and marks the target finished" {
    var state = StreamState{ .started_at_ms = 1_000, .last_flush_time = 1_000 };
    defer state.deinit(std.testing.allocator);

    var flush = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        "hello",
        1_000 + STREAM_FLUSH_MIN_INTERVAL_MS,
    )) orelse return error.TestUnexpectedResult;
    flush.deinit(std.testing.allocator);
    try state.setMessageTs(std.testing.allocator, "1700.1");

    state.finishTurn(std.testing.allocator, 9_000);

    try std.testing.expectEqual(@as(usize, 0), state.buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.sent.len);
    try std.testing.expectEqual(@as(usize, 0), state.message_ts.len);
    try std.testing.expect(state.isLateChunk(9_000));
}

test "isLateChunk expires after the grace window" {
    var state = StreamState{};
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(!state.isLateChunk(1_000));

    state.finishTurn(std.testing.allocator, 1_000);
    try std.testing.expect(state.isLateChunk(1_000 + STREAM_LATE_CHUNK_GRACE_MS - 1));
    try std.testing.expect(!state.isLateChunk(1_000 + STREAM_LATE_CHUNK_GRACE_MS));
}

test "appendStreamChunk starts a fresh turn after the grace window" {
    var state = StreamState{};
    defer state.deinit(std.testing.allocator);

    state.finishTurn(std.testing.allocator, 1_000);

    const big = "n" ** (STREAM_FLUSH_MIN_DELTA_BYTES + 1);
    var flush = (try appendStreamChunk(
        std.testing.allocator,
        &state,
        big,
        1_000 + STREAM_LATE_CHUNK_GRACE_MS,
    )) orelse return error.TestUnexpectedResult;
    defer flush.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(big, flush.text);
    try std.testing.expectEqual(@as(i64, 0), state.finished_at_ms);
}

test "clearStreamState frees the target entry" {
    var states: std.StringHashMapUnmanaged(StreamState) = .empty;
    defer deinitStreamStates(std.testing.allocator, &states);

    const key = try std.testing.allocator.dupe(u8, "C123");
    try states.put(std.testing.allocator, key, StreamState{});
    try states.getPtr("C123").?.setMessageTs(std.testing.allocator, "1700.1");

    clearStreamState(std.testing.allocator, &states, "C123");
    try std.testing.expect(states.count() == 0);
}

test "appendTruncationMarker appends marker within limit" {
    const alloc = std.testing.allocator;
    const short_chunk = "Hello world";
    const marked = try appendTruncationMarker(alloc, short_chunk, 100);
    defer alloc.free(marked);
    try std.testing.expect(std.mem.endsWith(u8, marked, FINAL_TRUNCATED_MARKER));
    try std.testing.expect(slackEscapedLen(marked) <= 100);

    const long_chunk = "<&>" ** 500;
    const marked_long = try appendTruncationMarker(alloc, long_chunk, 200);
    defer alloc.free(marked_long);
    try std.testing.expect(std.mem.endsWith(u8, marked_long, FINAL_TRUNCATED_MARKER));
    try std.testing.expect(slackEscapedLen(marked_long) <= 200);
}
