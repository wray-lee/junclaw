//! Shared per-turn MCP tool exposure filter.
//!
//! The native agent and the in-process dsh engine both call `toolExposed`, so
//! one `agent.tool_filter_groups` configuration yields one model-visible tool
//! set on both engines.
//!
//! Semantics:
//!   - no groups configured: every tool is exposed;
//!   - a name that does not start with `mcp_`: always exposed;
//!   - an `always` group whose glob matches: exposed;
//!   - a `dynamic` group whose glob matches: exposed only when this turn's
//!     user message contains one of the group's keywords. Matching is an ASCII
//!     case-insensitive byte-substring search, so non-ASCII keywords (CJK)
//!     match their raw UTF-8 bytes.

const std = @import("std");
const config_types = @import("config_types.zig");

/// Whether `name` is exposed to the model for a turn whose user message is
/// `user_message`. Pass an empty message for prompt paths that only carry
/// `always` groups: no dynamic keyword matches the empty message.
pub fn toolExposed(
    groups: []const config_types.ToolFilterGroup,
    name: []const u8,
    user_message: []const u8,
) bool {
    if (groups.len == 0) return true;
    if (!std.mem.startsWith(u8, name, "mcp_")) return true;

    for (groups) |group| {
        var pattern_matched = false;
        for (group.tools) |pattern| {
            if (globMatch(pattern, name)) {
                pattern_matched = true;
                break;
            }
        }
        if (!pattern_matched) continue;

        switch (group.mode) {
            .always => return true,
            .dynamic => for (group.keywords) |keyword| {
                if (containsAsciiIgnoreCase(user_message, keyword)) return true;
            },
        }
    }
    return false;
}

/// Simple `*` glob: the wildcard matches any sequence, including none, and the
/// pattern carries at most one wildcard (prefix/suffix/infix).
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse {
        return std.mem.eql(u8, pattern, name);
    };
    const prefix = pattern[0..star];
    const suffix = pattern[star + 1 ..];
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    if (suffix.len == 0) return true;
    if (name.len < prefix.len + suffix.len) return false;
    return std.mem.endsWith(u8, name, suffix);
}

/// ASCII case-insensitive byte-substring search. Bytes >= 0x80 only compare
/// equal to themselves, so a CJK keyword matches the same UTF-8 bytes.
pub fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

const testing = std.testing;

fn always(tools: []const []const u8) config_types.ToolFilterGroup {
    return .{ .mode = .always, .tools = tools };
}

fn dynamic(tools: []const []const u8, keywords: []const []const u8) config_types.ToolFilterGroup {
    return .{ .mode = .dynamic, .tools = tools, .keywords = keywords };
}

test "toolExposed without groups exposes every name" {
    try testing.expect(toolExposed(&.{}, "mcp_jira_list", ""));
    try testing.expect(toolExposed(&.{}, "shell", ""));
}

test "toolExposed keeps non-MCP tools regardless of groups" {
    const groups = [_]config_types.ToolFilterGroup{dynamic(&.{"mcp_*"}, &.{"never-said"})};
    try testing.expect(toolExposed(&groups, "shell", "hello"));
    try testing.expect(!toolExposed(&groups, "mcp_jira_list", "hello"));
}

test "toolExposed exposes always groups without a keyword" {
    const groups = [_]config_types.ToolFilterGroup{always(&.{"mcp_jira_*"})};
    try testing.expect(toolExposed(&groups, "mcp_jira_list", ""));
    try testing.expect(!toolExposed(&groups, "mcp_filesystem_read", ""));
}

test "toolExposed dynamic groups follow the turn message" {
    const groups = [_]config_types.ToolFilterGroup{
        always(&.{"mcp_filesystem_*"}),
        dynamic(&.{"mcp_jira_*"}, &.{ "ticket", "jira" }),
    };
    try testing.expect(toolExposed(&groups, "mcp_filesystem_read", "hello"));
    try testing.expect(!toolExposed(&groups, "mcp_jira_list", "hello"));
    try testing.expect(toolExposed(&groups, "mcp_jira_list", "open a JIRA issue"));
    try testing.expect(toolExposed(&groups, "mcp_jira_list", "file a ticket"));
}

test "toolExposed dynamic keyword matches a CJK byte substring" {
    const groups = [_]config_types.ToolFilterGroup{dynamic(&.{"mcp_browser_*"}, &.{"网页"})};
    try testing.expect(!toolExposed(&groups, "mcp_browser_goto", "打开页面"));
    try testing.expect(toolExposed(&groups, "mcp_browser_goto", "帮我打开网页"));
}

test "toolExposed checks every matching group after a dynamic miss" {
    const groups = [_]config_types.ToolFilterGroup{
        dynamic(&.{"mcp_*"}, &.{"missing"}),
        always(&.{"mcp_jira_*"}),
    };
    try testing.expect(toolExposed(&groups, "mcp_jira_list", "hello"));
    try testing.expect(toolExposed(&groups, "mcp_other_call", "say missing"));
}

test "toolExposed ignores an empty dynamic keyword" {
    const groups = [_]config_types.ToolFilterGroup{dynamic(&.{"mcp_*"}, &.{""})};
    try testing.expect(!toolExposed(&groups, "mcp_jira_list", "anything"));
}

test "globMatch supports one prefix, suffix or infix wildcard" {
    try testing.expect(globMatch("*", "anything"));
    try testing.expect(globMatch("mcp_jira_*", "mcp_jira_list"));
    try testing.expect(globMatch("*_list", "mcp_jira_list"));
    try testing.expect(globMatch("mcp_*_list", "mcp_jira_list"));
    try testing.expect(!globMatch("mcp_jira_*", "mcp_filesystem_list"));
    try testing.expect(!globMatch("mcp_jira_list", "mcp_jira_list_extra"));
}
