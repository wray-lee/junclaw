//! Request assembly: `request/header` snapshots and model-request messages
//! (design §1.2 B4/B13/B14/B20; dsh `agent.ts:616-705`,
//! `session/src/types.ts:241-274`, `session/src/request-header.ts`).
//!
//! Pure module: callers pass the folded surface items and the last header in
//! force; nothing here reads or writes the session log.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

/// Provider/model call configuration carried by a request header.
pub const CallConfig = struct {
    provider: []const u8,
    model: []const u8,
    reasoning_effort: ?[]const u8 = null,
    max_tokens: ?u32 = null,
};

/// Config fields materialized from the adapter rather than proposed by a
/// caller (`EpochHeader.adapterDefaults`).
pub const AdapterDefaults = struct {
    reasoning_effort: bool = false,
    max_tokens: bool = false,
};

/// One assembled tool schema. `parameters_json` is the canonical JSON text of
/// the input schema; dsh compares schemas with `JSON.stringify`, so schemas
/// assembled through the same path compare byte-for-byte.
pub const ToolSchema = struct {
    name: []const u8,
    description: []const u8 = "",
    parameters_json: []const u8,
};

/// The request header snapshot (`EpochHeader`).
pub const Header = struct {
    config: CallConfig,
    adapter_defaults: ?AdapterDefaults = null,
    /// Absent for a tool-less request; an empty list canonicalizes to absent.
    tools: ?[]const ToolSchema = null,
};

/// Canonical header form: empty tools become absent and all-false adapter
/// defaults are dropped (`request-header.ts:canonicalHeader`).
pub fn canonical(header: Header) Header {
    var out = header;
    if (out.adapter_defaults) |defaults| {
        if (!defaults.reasoning_effort and !defaults.max_tokens) out.adapter_defaults = null;
    }
    if (out.tools) |tools| {
        if (tools.len == 0) out.tools = null;
    }
    return out;
}

/// Deterministic hash of the assembled tool list, used as the fast path of
/// header change detection. Null and an empty list hash differently; canonical
/// headers never carry an empty list.
pub fn toolsHash(tools: ?[]const ToolSchema) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const list = tools orelse return hasher.final();
    var count: [8]u8 = undefined;
    std.mem.writeInt(u64, &count, list.len, .little);
    hasher.update(&count);
    for (list) |tool| {
        hashField(&hasher, tool.name);
        hashField(&hasher, tool.description);
        hashField(&hasher, tool.parameters_json);
    }
    return hasher.final();
}

fn hashField(hasher: *std.hash.Wyhash, field: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, field.len, .little);
    hasher.update(&len);
    hasher.update(field);
}

/// Field-wise header equality (`request-header.ts:headerEquals`): config,
/// adapter defaults and tools in order.
pub fn headerEquals(a: Header, b: Header) bool {
    const ca = canonical(a);
    const cb = canonical(b);
    if (!callConfigEquals(ca.config, cb.config)) return false;
    if (!adapterDefaultsEqual(ca.adapter_defaults, cb.adapter_defaults)) return false;
    const at = ca.tools orelse return cb.tools == null;
    const bt = cb.tools orelse return false;
    if (at.len != bt.len) return false;
    if (toolsHash(ca.tools) != toolsHash(cb.tools)) return false;
    for (at, bt) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        if (!std.mem.eql(u8, x.description, y.description)) return false;
        if (!std.mem.eql(u8, x.parameters_json, y.parameters_json)) return false;
    }
    return true;
}

fn callConfigEquals(a: CallConfig, b: CallConfig) bool {
    return std.mem.eql(u8, a.provider, b.provider) and std.mem.eql(u8, a.model, b.model) and optionalStringEquals(a.reasoning_effort, b.reasoning_effort) and a.max_tokens == b.max_tokens;
}

fn optionalStringEquals(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn adapterDefaultsEqual(a: ?AdapterDefaults, b: ?AdapterDefaults) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.reasoning_effort == b.?.reasoning_effort and a.?.max_tokens == b.?.max_tokens;
}

/// Why a header snapshot is appended (`RequestHeaderReason`).
pub const HeaderReason = enum { initial, @"resume", change, series };

pub const HeaderDecision = struct {
    /// Append a `request/header` event before sending.
    append: bool,
    reason: HeaderReason = .initial,
    /// Write `startsSeries: true`. `series` implies a new series and dsh logs
    /// that reason without the flag (`agent.ts:649-650`).
    starts_series: bool = false,
    /// Canonical snapshot to log.
    header: Header,
};

/// Per-loop-instance header bookkeeping (`agent.ts:632-667`).
pub const HeaderTracker = struct {
    /// Whether this loop instance appended its first header.
    logged: bool = false,
    /// Surface content generation at the last request. Initialize to the
    /// session's current generation when the loop instance starts
    /// (`agent.ts:128`).
    request_generation: u64 = 0,

    /// Decide whether this request appends a header.
    ///
    /// `baseline` is the header currently in force (the last header in the
    /// log), read fresh per request like `session.requestHeader()`.
    pub fn beginRequest(
        self: *HeaderTracker,
        baseline: ?Header,
        header: Header,
        surface_generation: u64,
        starts_request_series: bool,
    ) HeaderDecision {
        const snapshot = canonical(header);
        const starts_series = starts_request_series or self.request_generation != surface_generation;
        var decision = HeaderDecision{ .append = false, .header = snapshot };

        if (!self.logged) {
            decision.append = true;
            decision.reason = if (baseline == null) .initial else .@"resume";
            decision.starts_series = starts_series;
        } else if (baseline == null or !headerEquals(baseline.?, snapshot)) {
            decision.append = true;
            decision.reason = .change;
            decision.starts_series = starts_series;
        } else if (starts_series) {
            decision.append = true;
            decision.reason = .series;
        }

        self.logged = true;
        self.request_generation = surface_generation;
        return decision;
    }
};

/// Whether a retry may reuse the header already in force instead of appending
/// another snapshot. A request that failed before starting still wrote its
/// header (header-only), so a retry with the same header is continuous (B13).
pub fn retryContinuesHeader(baseline: ?Header, header: Header) bool {
    const current = baseline orelse return false;
    return headerEquals(current, header);
}

/// Durable request markers used by the loop. `header_seq` is set when
/// `request/header` is appended; `request_started` is set when the request is
/// handed to the provider.
pub const Checkpoint = struct {
    header_seq: ?u64 = null,
    request_started: bool = false,

    pub const Phase = enum {
        /// Aborted before the header and before the request started: no
        /// checkpoint was written, so there is nothing to repair (B22).
        abort_before_send,
        /// Header is durable but the request never started: a retry reuses it
        /// through `retryContinuesHeader` (B13).
        header_only,
        sent,
    };

    pub fn phase(self: Checkpoint) Phase {
        if (self.request_started) return .sent;
        return if (self.header_seq != null) .header_only else .abort_before_send;
    }
};

/// One folded surface item (a `surface.Node` plus its series marker).
pub const Item = struct {
    /// Surface event seq.
    seq: u64,
    message: types.Message,
    /// This item begins a new message series; an assistant entry opened before
    /// it can no longer receive tool results.
    starts_series: bool = false,
};

/// Request-side filters. Filtered content stays in the surface and session
/// log; only the provider request excludes it.
pub const Filter = struct {
    /// `filterCutoff`: items below this surface seq are excluded.
    filter_cutoff: ?u64 = null,
    /// Tool uses end at this surface seq: assistant items at or after it keep
    /// their text/reasoning but lose every `tool_call` block, and those calls'
    /// results are excluded with them.
    tool_use_end: ?u64 = null,
};

/// Built request messages. Messages borrow strings and block contents from the
/// input items, so keep `items` alive while this is in use.
pub const Built = struct {
    arena: std.heap.ArenaAllocator,
    messages: []types.Message,

    pub fn deinit(self: *Built) void {
        self.arena.deinit();
    }
};

const OpenAssistant = struct {
    /// Index of the assistant message in the output list.
    message_index: usize,
    calls: []const Call,
    /// Result per call, in model order; null while still missing.
    results: []?types.Message,

    const Call = struct {
        id: []const u8,
        block_index: usize,
    };
};

/// Build the provider request messages from folded surface items.
///
/// History follows surface order. A tool result joins the request only when an
/// assistant entry with a matching call is open in the current series; results
/// are emitted in the assistant's model order, not arrival order (B20). A call
/// left without a result is removed from the assistant content so the request
/// never carries a dangling `tool_use`.
pub fn buildMessages(allocator: Allocator, items: []const Item, filter: Filter) !Built {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var out: std.ArrayListUnmanaged(types.Message) = .empty;
    errdefer out.deinit(arena_allocator);

    var open: ?OpenAssistant = null;

    for (items) |item| {
        if (item.starts_series) {
            if (open) |*current| {
                try flushOpen(arena_allocator, &out, current);
                open = null;
            }
        }
        if (filter.filter_cutoff) |cutoff| {
            if (item.seq < cutoff) {
                // Filtered content stays in the surface but still shapes the
                // request: a non-tool item closes the open assistant even when
                // it is itself excluded.
                if (item.message.role != .tool) {
                    if (open) |*current| {
                        try flushOpen(arena_allocator, &out, current);
                        open = null;
                    }
                }
                continue;
            }
        }

        switch (item.message.role) {
            .assistant => {
                if (open) |*current| {
                    try flushOpen(arena_allocator, &out, current);
                    open = null;
                }

                const keep_tool_uses = if (filter.tool_use_end) |end|
                    item.seq < end
                else
                    true;

                var calls: std.ArrayListUnmanaged(OpenAssistant.Call) = .empty;
                var content = item.message.content;
                if (keep_tool_uses) {
                    for (item.message.content, 0..) |block, block_index| {
                        switch (block) {
                            .tool_call => |call| try calls.append(arena_allocator, .{
                                .id = call.id,
                                .block_index = block_index,
                            }),
                            else => {},
                        }
                    }
                } else {
                    var blocks: std.ArrayListUnmanaged(types.ContentBlock) = .empty;
                    for (item.message.content) |block| {
                        switch (block) {
                            .tool_call => {},
                            else => try blocks.append(arena_allocator, block),
                        }
                    }
                    content = try blocks.toOwnedSlice(arena_allocator);
                }

                // dsh never injects a content-less assistant turn.
                if (content.len == 0) continue;

                var message = item.message;
                message.content = content;
                try out.append(arena_allocator, message);
                const message_index = out.items.len - 1;

                if (calls.items.len == 0) {
                    open = null;
                } else {
                    const results = try arena_allocator.alloc(?types.Message, calls.items.len);
                    @memset(results, null);
                    open = .{
                        .message_index = message_index,
                        .calls = try calls.toOwnedSlice(arena_allocator),
                        .results = results,
                    };
                }
            },
            .tool => {
                if (open) |*current| {
                    const call_id = item.message.tool_call_id orelse continue;
                    for (current.calls, 0..) |call, index| {
                        if (std.mem.eql(u8, call.id, call_id)) {
                            if (current.results[index] == null) {
                                current.results[index] = item.message;
                            }
                            break;
                        }
                    }
                }
            },
            .system, .developer, .user => {
                if (open) |*current| {
                    try flushOpen(arena_allocator, &out, current);
                    open = null;
                }
                // dsh drops empty system/developer nodes; a user message is
                // always part of the transcript.
                if (item.message.role != .user and item.message.content.len == 0) continue;
                try out.append(arena_allocator, item.message);
            },
        }
    }

    if (open) |*current| try flushOpen(arena_allocator, &out, current);

    const messages = try out.toOwnedSlice(arena_allocator);
    return .{ .arena = arena, .messages = messages };
}

/// Emit the open assistant's results in model order. Calls whose result never
/// arrived (filtered, orphaned, or dropped at a series boundary) are removed
/// from the assistant content.
fn flushOpen(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(types.Message),
    open: *const OpenAssistant,
) !void {
    var missing = false;
    for (open.results) |result| {
        if (result == null) {
            missing = true;
            break;
        }
    }

    if (missing) {
        var blocks: std.ArrayListUnmanaged(types.ContentBlock) = .empty;
        for (out.items[open.message_index].content, 0..) |block, block_index| {
            if (block == .tool_call) {
                var keep = false;
                for (open.calls, open.results) |call, result| {
                    if (call.block_index == block_index and result != null) {
                        keep = true;
                        break;
                    }
                }
                if (!keep) continue;
            }
            try blocks.append(allocator, block);
        }
        if (blocks.items.len == 0) {
            _ = out.pop();
            return;
        }
        out.items[open.message_index].content = try blocks.toOwnedSlice(allocator);
    }

    for (open.calls, open.results) |call, result| {
        _ = call;
        if (result) |message| try out.append(allocator, message);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_config = CallConfig{
    .provider = "test-provider",
    .model = "test-model",
};

fn headerWith(config: CallConfig) Header {
    return .{ .config = config };
}

fn userMessage(id: []const u8, blocks: []const types.ContentBlock) types.Message {
    return .{ .id = id, .role = .user, .content = blocks, .source = .user };
}

fn assistantMessage(id: []const u8, blocks: []const types.ContentBlock) types.Message {
    return .{
        .id = id,
        .role = .assistant,
        .content = blocks,
        .source = .{ .model = .{ .provider = "test-provider", .model = "test-model" } },
    };
}

fn toolMessage(id: []const u8, call_id: []const u8, blocks: []const types.ContentBlock) types.Message {
    return .{
        .id = id,
        .role = .tool,
        .content = blocks,
        .source = .{ .tool = .{ .call_id = call_id } },
        .tool_call_id = call_id,
    };
}

fn messageIds(messages: []const types.Message, ids: []const []const u8) !void {
    try testing.expectEqual(ids.len, messages.len);
    for (messages, ids) |message, expected| {
        try testing.expectEqualStrings(expected, message.id);
    }
}

test "header reasons: initial, resume, change, series" {
    var fresh = HeaderTracker{};
    const initial = fresh.beginRequest(null, headerWith(test_config), 0, false);
    try testing.expect(initial.append);
    try testing.expectEqual(HeaderReason.initial, initial.reason);
    try testing.expect(!initial.starts_series);
    try testing.expectEqualStrings("initial", @tagName(initial.reason));

    // A loop instance over a log that already has a header resumes it.
    var resumed = HeaderTracker{};
    const resumed_decision = resumed.beginRequest(headerWith(test_config), headerWith(test_config), 0, false);
    try testing.expect(resumed_decision.append);
    try testing.expectEqual(HeaderReason.@"resume", resumed_decision.reason);

    var tracker = HeaderTracker{};
    _ = tracker.beginRequest(null, headerWith(test_config), 0, false);
    const unchanged = tracker.beginRequest(headerWith(test_config), headerWith(test_config), 0, false);
    try testing.expect(!unchanged.append);

    const changed_config = CallConfig{
        .provider = "test-provider",
        .model = "other-model",
    };
    const change = tracker.beginRequest(headerWith(test_config), headerWith(changed_config), 0, false);
    try testing.expect(change.append);
    try testing.expectEqual(HeaderReason.change, change.reason);
    try testing.expect(!change.starts_series);

    // Same header, but the caller explicitly opens a new series.
    var series_tracker = HeaderTracker{};
    _ = series_tracker.beginRequest(null, headerWith(test_config), 0, false);
    const series = series_tracker.beginRequest(headerWith(test_config), headerWith(test_config), 0, true);
    try testing.expect(series.append);
    try testing.expectEqual(HeaderReason.series, series.reason);
    try testing.expect(!series.starts_series);

    // A surface replacement also opens a series (generation moved).
    var generation_tracker = HeaderTracker{ .request_generation = 3 };
    _ = generation_tracker.beginRequest(null, headerWith(test_config), 3, false);
    const generation = generation_tracker.beginRequest(headerWith(test_config), headerWith(test_config), 4, false);
    try testing.expect(generation.append);
    try testing.expectEqual(HeaderReason.series, generation.reason);

    // `startsSeries` rides along with initial/resume/change when requested.
    var first_series = HeaderTracker{};
    const initial_series = first_series.beginRequest(null, headerWith(test_config), 0, true);
    try testing.expectEqual(HeaderReason.initial, initial_series.reason);
    try testing.expect(initial_series.starts_series);

    var change_series = HeaderTracker{};
    _ = change_series.beginRequest(null, headerWith(test_config), 0, false);
    const changed_series = change_series.beginRequest(
        headerWith(test_config),
        headerWith(changed_config),
        0,
        true,
    );
    try testing.expectEqual(HeaderReason.change, changed_series.reason);
    try testing.expect(changed_series.starts_series);
}

test "header change detection: config, adapter defaults and tools hash" {
    const read_schema = ToolSchema{
        .name = "read",
        .description = "Read a file",
        .parameters_json = "{\"type\":\"object\"}",
    };
    const grep_schema = ToolSchema{
        .name = "grep",
        .description = "Search files",
        .parameters_json = "{\"type\":\"object\"}",
    };
    const tools = [_]ToolSchema{ read_schema, grep_schema };
    const changed_tools = [_]ToolSchema{ read_schema, .{
        .name = "grep",
        .description = "Search files",
        .parameters_json = "{\"type\":\"object\",\"required\":[]}",
    } };

    const base = Header{ .config = test_config, .tools = &tools };
    const changed = Header{ .config = test_config, .tools = &changed_tools };

    try testing.expect(headerEquals(base, base));
    try testing.expect(!headerEquals(base, changed));
    try testing.expectEqual(toolsHash(&tools), toolsHash(&tools));
    try testing.expect(toolsHash(&tools) != toolsHash(&changed_tools));
    try testing.expect(toolsHash(null) != toolsHash(&tools));

    // Empty tools and all-false adapter defaults canonicalize away.
    const no_tools = [_]ToolSchema{};
    try testing.expect(headerEquals(.{ .config = test_config, .tools = &no_tools }, .{ .config = test_config }));
    try testing.expect(headerEquals(
        .{ .config = test_config, .adapter_defaults = .{ .reasoning_effort = false, .max_tokens = false } },
        .{ .config = test_config },
    ));
    try testing.expect(!headerEquals(
        .{ .config = test_config, .adapter_defaults = .{ .max_tokens = true } },
        .{ .config = test_config },
    ));

    // Every config field participates in change detection.
    const effort = CallConfig{ .provider = "test-provider", .model = "test-model", .reasoning_effort = "high" };
    const budget = CallConfig{ .provider = "test-provider", .model = "test-model", .max_tokens = 1024 };
    try testing.expect(!headerEquals(headerWith(test_config), headerWith(effort)));
    try testing.expect(!headerEquals(headerWith(test_config), headerWith(budget)));

    // A tools-only change is a `change`, and the snapshot is canonical.
    var tracker = HeaderTracker{};
    _ = tracker.beginRequest(null, base, 0, false);
    const decision = tracker.beginRequest(base, changed, 0, false);
    try testing.expect(decision.append);
    try testing.expectEqual(HeaderReason.change, decision.reason);
    try testing.expectEqual(@as(usize, 2), decision.header.tools.?.len);
}

test "tool results attach to the open assistant in model order" {
    const user_blocks = [_]types.ContentBlock{.{ .text = "run the tools" }};
    const assistant_blocks = [_]types.ContentBlock{
        .{ .text = "working" },
        .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments = "{}" } },
        .{ .tool_call = .{ .id = "call-2", .name = "grep", .arguments = "{}" } },
    };
    const result_1_blocks = [_]types.ContentBlock{.{ .text = "first" }};
    const result_2_blocks = [_]types.ContentBlock{.{ .text = "second" }};

    const items = [_]Item{
        .{ .seq = 0, .message = userMessage("u1", &user_blocks) },
        .{ .seq = 1, .message = assistantMessage("a1", &assistant_blocks) },
        // Results arrive in reverse order; the request keeps model order.
        .{ .seq = 2, .message = toolMessage("r2", "call-2", &result_2_blocks) },
        .{ .seq = 3, .message = toolMessage("r1", "call-1", &result_1_blocks) },
    };

    var built = try buildMessages(testing.allocator, &items, .{});
    defer built.deinit();

    try messageIds(built.messages, &.{ "u1", "a1", "r1", "r2" });
    try testing.expectEqual(types.MessageRole.tool, built.messages[2].role);
    try testing.expectEqualStrings("call-1", built.messages[2].tool_call_id.?);
    try testing.expectEqualStrings("call-2", built.messages[3].tool_call_id.?);

    // An orphan result is excluded, and its unmatched call is removed from
    // the assistant content so the request stays provider-valid.
    const orphan_blocks = [_]types.ContentBlock{.{ .text = "late" }};
    const orphan_items = [_]Item{
        .{ .seq = 0, .message = assistantMessage("a1", &assistant_blocks) },
        .{ .seq = 1, .message = toolMessage("r2", "call-2", &result_2_blocks) },
        .{ .seq = 2, .message = userMessage("u2", &user_blocks) },
        .{ .seq = 3, .message = toolMessage("late", "call-1", &orphan_blocks) },
    };

    var orphan = try buildMessages(testing.allocator, &orphan_items, .{});
    defer orphan.deinit();

    try messageIds(orphan.messages, &.{ "a1", "r2", "u2" });
    try testing.expectEqual(@as(usize, 2), orphan.messages[0].content.len);
    try testing.expectEqualStrings("call-2", orphan.messages[0].content[1].tool_call.id);
}

test "series merge: history accumulates and results cannot cross a boundary" {
    const user_blocks = [_]types.ContentBlock{.{ .text = "go" }};
    const assistant_blocks = [_]types.ContentBlock{
        .{ .text = "calling" },
        .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments = "{}" } },
    };
    const result_blocks = [_]types.ContentBlock{.{ .text = "ok" }};
    const plain_blocks = [_]types.ContentBlock{.{ .text = "done" }};

    const items = [_]Item{
        .{ .seq = 0, .message = userMessage("u1", &user_blocks) },
        .{ .seq = 1, .message = assistantMessage("a1", &assistant_blocks) },
        .{ .seq = 2, .message = toolMessage("r1", "call-1", &result_blocks) },
        // New series: earlier history is kept, not replaced.
        .{ .seq = 3, .message = userMessage("u2", &user_blocks), .starts_series = true },
        .{ .seq = 4, .message = assistantMessage("a2", &plain_blocks) },
        // This result belongs to a1, whose entry closed at the series
        // boundary, so it is not part of the request.
        .{ .seq = 5, .message = toolMessage("r2", "call-1", &result_blocks) },
    };

    var built = try buildMessages(testing.allocator, &items, .{});
    defer built.deinit();

    try messageIds(built.messages, &.{ "u1", "a1", "r1", "u2", "a2" });
    try testing.expectEqualStrings("done", built.messages[4].content[0].text);

    // The same boundary placed before a1's result also drops that result and
    // the now-unmatched call.
    const split_items = [_]Item{
        .{ .seq = 0, .message = userMessage("u1", &user_blocks) },
        .{ .seq = 1, .message = assistantMessage("a1", &assistant_blocks) },
        .{ .seq = 2, .message = toolMessage("r1", "call-1", &result_blocks), .starts_series = true },
    };

    var split = try buildMessages(testing.allocator, &split_items, .{});
    defer split.deinit();

    try messageIds(split.messages, &.{ "u1", "a1" });
    try testing.expectEqual(@as(usize, 1), split.messages[1].content.len);
    try testing.expectEqualStrings("calling", split.messages[1].content[0].text);
}

test "filter cutoff excludes request content but leaves the surface intact" {
    const user_blocks = [_]types.ContentBlock{.{ .text = "hello" }};
    const assistant_blocks = [_]types.ContentBlock{
        .{ .text = "using a tool" },
        .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments = "{}" } },
    };
    const result_blocks = [_]types.ContentBlock{.{ .text = "contents" }};

    const items = [_]Item{
        .{ .seq = 0, .message = userMessage("u-old", &user_blocks) },
        .{ .seq = 1, .message = assistantMessage("a-old", &assistant_blocks) },
        .{ .seq = 2, .message = toolMessage("r-old", "call-1", &result_blocks) },
        .{ .seq = 3, .message = userMessage("u-new", &user_blocks) },
        .{ .seq = 4, .message = assistantMessage("a-new", &user_blocks) },
    };

    var built = try buildMessages(testing.allocator, &items, .{ .filter_cutoff = 3 });
    defer built.deinit();
    try messageIds(built.messages, &.{ "u-new", "a-new" });

    // The caller's items (the surface) are untouched by the filter.
    try testing.expectEqual(@as(usize, 5), items.len);
    try testing.expectEqualStrings("u-old", items[0].message.id);
    try testing.expectEqualStrings("r-old", items[2].message.id);

    // A cutoff between an assistant and its result leaves the result orphaned,
    // so it is excluded and the unmatched call is removed.
    var split = try buildMessages(testing.allocator, &items, .{ .filter_cutoff = 2 });
    defer split.deinit();
    try messageIds(split.messages, &.{ "u-new", "a-new" });

    // Filtered content still closes the tool window: an excluded user item
    // between an assistant and its result prevents the attachment.
    // Replacement nodes can leave seq order non-monotonic; the filtered
    // boundary still closes the tool window.
    const gap_items = [_]Item{
        .{ .seq = 5, .message = assistantMessage("a1", &assistant_blocks) },
        .{ .seq = 1, .message = userMessage("filtered", &user_blocks), .starts_series = true },
        .{ .seq = 6, .message = toolMessage("r1", "call-1", &result_blocks) },
    };
    var gap = try buildMessages(testing.allocator, &gap_items, .{ .filter_cutoff = 2 });
    defer gap.deinit();
    try messageIds(gap.messages, &.{"a1"});
    try testing.expectEqual(@as(usize, 1), gap.messages[0].content.len);

    // tool_use_end keeps the assistant text but drops its tool calls and the
    // matching results.
    var no_tools = try buildMessages(testing.allocator, &items, .{ .tool_use_end = 1 });
    defer no_tools.deinit();
    try messageIds(no_tools.messages, &.{ "u-old", "a-old", "u-new", "a-new" });
    try testing.expectEqual(@as(usize, 1), no_tools.messages[1].content.len);
    try testing.expectEqualStrings("using a tool", no_tools.messages[1].content[0].text);

    // A tool_use_end after the assistant keeps the call and its result.
    var kept = try buildMessages(testing.allocator, &items, .{ .tool_use_end = 2 });
    defer kept.deinit();
    try messageIds(kept.messages, &.{ "u-old", "a-old", "r-old", "u-new", "a-new" });
}

test "header-only failure and retry continuity" {
    var tracker = HeaderTracker{};
    const first = tracker.beginRequest(null, headerWith(test_config), 0, false);
    try testing.expect(first.append);

    // The request failed before it started: only the header is durable.
    const checkpoint = Checkpoint{ .header_seq = 7 };
    try testing.expectEqual(Checkpoint.Phase.header_only, checkpoint.phase());

    // Retrying with the same header reuses it instead of appending `change`.
    try testing.expect(retryContinuesHeader(first.header, headerWith(test_config)));
    const retry = tracker.beginRequest(
        first.header,
        headerWith(test_config),
        0,
        false,
    );
    try testing.expect(!retry.append);

    // A changed header on retry is a change, not a continuation.
    const changed = CallConfig{ .provider = "test-provider", .model = "other-model" };
    try testing.expect(!retryContinuesHeader(first.header, headerWith(changed)));
    const retry_changed = tracker.beginRequest(first.header, headerWith(changed), 0, false);
    try testing.expect(retry_changed.append);
    try testing.expectEqual(HeaderReason.change, retry_changed.reason);

    // Abort before send leaves no header checkpoint to repair.
    const aborted = Checkpoint{};
    try testing.expectEqual(Checkpoint.Phase.abort_before_send, aborted.phase());
    try testing.expectEqual(
        Checkpoint.Phase.sent,
        (Checkpoint{ .header_seq = 7, .request_started = true }).phase(),
    );
    try testing.expect(!retryContinuesHeader(null, headerWith(test_config)));
}

test "buildMessages releases a >=64KB request (leak regression)" {
    const text_blocks = [_]types.ContentBlock{.{ .text = "x" }};
    const count = 2048;
    const items = try testing.allocator.alloc(Item, count);
    defer testing.allocator.free(items);
    for (items, 0..) |*item, index| {
        item.* = .{
            .seq = index,
            .message = userMessage("bulk", &text_blocks),
        };
    }

    var built = try buildMessages(testing.allocator, items, .{});
    defer built.deinit();
    try testing.expectEqual(count, built.messages.len);

    // The arena owns more than 64KB of message metadata; deinit must free it.
    try testing.expect(built.messages.len * @sizeOf(types.Message) >= 64 * 1024);
}
