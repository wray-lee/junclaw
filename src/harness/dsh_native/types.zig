//! dsh native harness data model (P0 subset of the dsh v4 session vocabulary).
//!
//! Mirrors `packages/core/session/src/types.ts` and
//! `packages/llm/llm/src/{types,message}.ts` of DeepSeek Harness 0.2.1-rc.2.
//! `Event.data` stays lossless JSON: the append-only log is the source of truth,
//! so P0 validates envelopes but does not interpret event payloads.

const std = @import("std");

/// On-disk session format generation written and read by this build.
pub const SESSION_FORMAT_VERSION: u32 = 4;

/// One model-facing content block. Blocks not modeled in P0 stay raw JSON.
pub const ContentBlock = union(enum) {
    text: []const u8,
    reasoning: []const u8,
    tool_call: ToolCall,
    /// image / file / tool-addition / tool-removal and plugin blocks.
    raw: std.json.Value,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    /// Raw JSON string as produced by the model; dsh keeps it unparsed.
    arguments: []const u8,
};

pub const MessageRole = enum { system, developer, user, assistant, tool };

pub const MessageSource = union(enum) {
    user,
    system_prompt,
    model: struct { provider: []const u8, model: []const u8 },
    tool: struct { call_id: []const u8 },
    /// Plugin-defined source kinds.
    other: std.json.Value,
};

pub const Message = struct {
    id: []const u8,
    role: MessageRole,
    content: []const ContentBlock,
    source: MessageSource,
    /// Present on tool-role messages.
    tool_call_id: ?[]const u8 = null,
    is_error: ?bool = null,
};

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: ?u64 = null,
    cache_read_tokens: ?u64 = null,
    cache_write_tokens: ?u64 = null,
    reasoning_tokens: ?u64 = null,
};

pub const AbortCause = union(enum) {
    user,
    parent,
    hook: []const u8,
    disposed,
    legacy,
};

pub const Failure = struct {
    message: []const u8,
    code: []const u8,
};

/// Why a turn ended (`TurnEndReasonMap`); merge-extensible in dsh.
pub const EndReason = union(enum) {
    completed,
    aborted: AbortCause,
    blocked,
    /// dsh's `error` variant.
    failure: Failure,
    max_tokens,
    interrupted,
    forked,
};

/// How a surface event entered the ordered model-visible surface.
pub const SurfaceOp = union(enum) {
    append,
    replace: struct { start_seq: u64, end_seq: u64 },
};

/// One immutable log entry; `seq` is contiguous from zero.
pub const Event = struct {
    event_type: []const u8,
    seq: u64,
    time_ms: i64,
    data: std.json.Value,
    surface_op: ?SurfaceOp = null,
    source_event_seqs: ?[]const u64 = null,
    ignorable: bool = false,
};

/// Immutable session metadata stored as the first JSONL record.
pub const Header = struct {
    id: []const u8,
    created_at: i64,
    cwd: ?[]const u8 = null,
    parent_session: ?[]const u8 = null,
    is_seeded: bool = false,
    origin: ?[]const u8 = null,
    delegation_depth: u32 = 0,
    agent_preset: ?[]const u8 = null,
};

test "types carry dsh message and event fields" {
    const blocks = [_]ContentBlock{
        .{ .text = "hello" },
        .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments = "{\"path\":\"a.txt\"}" } },
    };
    const message = Message{
        .id = "msg-1",
        .role = .assistant,
        .content = &blocks,
        .source = .{ .model = .{ .provider = "junclaw", .model = "test-model" } },
    };
    try std.testing.expectEqual(MessageRole.assistant, message.role);
    try std.testing.expectEqualStrings("read", message.content[1].tool_call.name);

    const usage = Usage{ .input_tokens = 3, .output_tokens = 4, .total_tokens = 7 };
    try std.testing.expectEqual(@as(u64, 7), usage.total_tokens.?);

    const reason = EndReason{ .aborted = .{ .hook = "policy" } };
    try std.testing.expectEqualStrings("policy", reason.aborted.hook);

    const event = Event{
        .event_type = "turn/start",
        .seq = 0,
        .time_ms = 1_700_000_000_000,
        .data = .{ .integer = 1 },
    };
    try std.testing.expectEqual(@as(u64, 0), event.seq);
    try std.testing.expect(event.surface_op == null);
}
