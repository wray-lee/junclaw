//! System prompt assembly: fixed identity, deployment persona slots, ordered
//! tool guidance, and tool-schema ordering (design §3.5, B15; dsh
//! `packages/core/system-prompt/src/index.ts` `renderPrompt`/`orderTools`).
//!
//! Model-visible text comes verbatim from `generated/system_prompt.zig`.
//! Rendering matches dsh: sections sort by order then name, empty sections are
//! dropped, and the rest join with a blank line.

const std = @import("std");
const generated = @import("generated/system_prompt.zig");

const Allocator = std.mem.Allocator;

/// Built-in tools with a system-prompt guidance section.
pub const Tool = enum {
    bash,
    read,
    write,
    edit,
    glob,
    grep,

    /// Every built-in tool, in dsh section order.
    pub const all = [_]Tool{ .bash, .read, .write, .edit, .glob, .grep };

    fn sectionOrder(self: Tool) i32 {
        return switch (self) {
            .bash => generated.section_orders.TOOL_BASH,
            .read => generated.section_orders.TOOL_READ,
            .write => generated.section_orders.TOOL_WRITE,
            .edit => generated.section_orders.TOOL_EDIT,
            .glob => generated.section_orders.TOOL_GLOB,
            .grep => generated.section_orders.TOOL_GREP,
        };
    }

    fn sectionName(self: Tool) []const u8 {
        return switch (self) {
            .bash => "tool:bash",
            .read => "tool:read",
            .write => "tool:write",
            .edit => "tool:edit",
            .glob => "tool:glob",
            .grep => "tool:grep",
        };
    }

    fn prompt(self: Tool) []const u8 {
        return switch (self) {
            .bash => generated.bash_prompt,
            .read => generated.read_prompt,
            .write => generated.write_prompt,
            .edit => generated.edit_prompt,
            .glob => generated.glob_prompt,
            .grep => generated.grep_prompt,
        };
    }
};

pub const Options = struct {
    /// Tools visible in this scope; only these contribute a guidance section.
    tools: []const Tool = &Tool.all,
    /// `deployment:persona-prefix` text; empty text drops the section.
    persona_prefix: []const u8 = generated.persona_prefix_default,
    /// `deployment:persona-suffix` text; empty text drops the section.
    persona_suffix: []const u8 = generated.persona_suffix_default,
};

const Section = struct {
    order: i32,
    name: []const u8,
    text: []const u8,
};

fn sectionLessThan(_: void, a: Section, b: Section) bool {
    if (a.order != b.order) return a.order < b.order;
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Render the model-visible system prompt. Caller owns the returned string.
pub fn buildSystemPrompt(allocator: Allocator, opts: Options) ![]u8 {
    for (opts.tools, 0..) |tool, i| {
        for (opts.tools[0..i]) |earlier| {
            if (tool == earlier) return error.DuplicateToolSection;
        }
    }

    var sections: [Tool.all.len + 3]Section = undefined;
    var count: usize = 0;
    sections[count] = .{
        .order = generated.section_orders.HARNESS_IDENTITY,
        .name = "harness:identity",
        .text = generated.identity_text,
    };
    count += 1;
    sections[count] = .{
        .order = generated.section_orders.DEPLOYMENT_PERSONA_PREFIX,
        .name = generated.persona_prefix_section,
        .text = opts.persona_prefix,
    };
    count += 1;
    for (opts.tools) |tool| {
        sections[count] = .{
            .order = tool.sectionOrder(),
            .name = tool.sectionName(),
            .text = tool.prompt(),
        };
        count += 1;
    }
    sections[count] = .{
        .order = generated.section_orders.DEPLOYMENT_PERSONA_SUFFIX,
        .name = generated.persona_suffix_section,
        .text = opts.persona_suffix,
    };
    count += 1;

    std.mem.sort(Section, sections[0..count], {}, sectionLessThan);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (sections[0..count]) |section| {
        if (section.text.len == 0) continue;
        if (out.items.len != 0) try out.appendSlice(allocator, "\n\n");
        try out.appendSlice(allocator, section.text);
    }
    return out.toOwnedSlice(allocator);
}

fn containsName(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Apply dsh `toolOrder` semantics to registered tool names: listed names keep
/// their configured position, unlisted names are inserted lexicographically at
/// `<unlisted-tools>`, and `null` sorts everything lexicographically. Returned
/// names alias `registered`; the caller frees the outer slice.
pub fn orderTools(
    allocator: Allocator,
    registered: []const []const u8,
    tool_order: ?[]const []const u8,
) ![][]const u8 {
    if (containsName(registered, generated.tool_order_rest)) return error.ReservedToolName;

    const order = tool_order orelse {
        const sorted = try allocator.dupe([]const u8, registered);
        std.mem.sort([]const u8, sorted, {}, nameLessThan);
        return sorted;
    };

    var has_rest = false;
    for (order, 0..) |name, i| {
        for (order[0..i]) |earlier| {
            if (std.mem.eql(u8, name, earlier)) return error.DuplicateOrderEntry;
        }
        if (std.mem.eql(u8, name, generated.tool_order_rest)) has_rest = true;
    }
    if (!has_rest) return error.MissingRestEntry;
    for (order) |name| {
        if (std.mem.eql(u8, name, generated.tool_order_rest)) continue;
        if (!containsName(registered, name)) return error.UnregisteredTool;
    }

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (order) |name| {
        if (!std.mem.eql(u8, name, generated.tool_order_rest)) {
            try out.append(allocator, name);
            continue;
        }
        var rest: std.ArrayListUnmanaged([]const u8) = .empty;
        defer rest.deinit(allocator);
        for (registered) |candidate| {
            if (!containsName(order, candidate)) try rest.append(allocator, candidate);
        }
        std.mem.sort([]const u8, rest.items, {}, nameLessThan);
        try out.appendSlice(allocator, rest.items);
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "system prompt matches generated sections byte-for-byte" {
    const expected = generated.identity_text ++ "\n\n" ++
        generated.bash_prompt ++ "\n\n" ++
        generated.read_prompt ++ "\n\n" ++
        generated.write_prompt ++ "\n\n" ++
        generated.edit_prompt ++ "\n\n" ++
        generated.glob_prompt ++ "\n\n" ++
        generated.grep_prompt;
    const actual = try buildSystemPrompt(testing.allocator, .{});
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "deployment persona prefix and suffix wrap first-party guidance" {
    const actual = try buildSystemPrompt(testing.allocator, .{
        .tools = &.{},
        .persona_prefix = "You are a test agent.",
        .persona_suffix = "Workspace: example.com.",
    });
    defer testing.allocator.free(actual);
    const expected = generated.identity_text ++ "\n\n" ++
        "You are a test agent.\n\n" ++
        "Workspace: example.com.";
    try testing.expectEqualStrings(expected, actual);
}

test "tool guidance follows dsh section order regardless of input order" {
    const actual = try buildSystemPrompt(testing.allocator, .{
        .tools = &.{ .grep, .bash, .read },
    });
    defer testing.allocator.free(actual);
    const expected = generated.identity_text ++ "\n\n" ++
        generated.bash_prompt ++ "\n\n" ++
        generated.read_prompt ++ "\n\n" ++
        generated.grep_prompt;
    try testing.expectEqualStrings(expected, actual);
}

test "duplicate tool sections are rejected" {
    try testing.expectError(error.DuplicateToolSection, buildSystemPrompt(testing.allocator, .{
        .tools = &.{ .read, .read },
    }));
}

test "tool order inserts unlisted tools at the rest marker" {
    const registered = [_][]const u8{ "bash", "read", "write", "glob", "grep" };
    const order = [_][]const u8{ "write", generated.tool_order_rest, "bash" };
    const ordered = try orderTools(testing.allocator, &registered, &order);
    defer testing.allocator.free(ordered);
    try testing.expectEqualSlices([]const u8, &.{ "write", "glob", "grep", "read", "bash" }, ordered);
}

test "tool order defaults to lexicographic names" {
    const registered = [_][]const u8{ "read", "bash", "edit" };
    const ordered = try orderTools(testing.allocator, &registered, null);
    defer testing.allocator.free(ordered);
    try testing.expectEqualSlices([]const u8, &.{ "bash", "edit", "read" }, ordered);
}

test "invalid tool orders fail loudly" {
    const registered = [_][]const u8{ "bash", "read" };
    const no_rest = [_][]const u8{"bash"};
    const twice_rest = [_][]const u8{ "bash", generated.tool_order_rest, generated.tool_order_rest };
    const unknown = [_][]const u8{ "nope", generated.tool_order_rest };
    try testing.expectError(error.MissingRestEntry, orderTools(testing.allocator, &registered, &no_rest));
    try testing.expectError(error.DuplicateOrderEntry, orderTools(testing.allocator, &registered, &twice_rest));
    try testing.expectError(error.UnregisteredTool, orderTools(testing.allocator, &registered, &unknown));
    try testing.expectError(error.ReservedToolName, orderTools(testing.allocator, &.{generated.tool_order_rest}, null));
}

test "64KB persona assembly releases every allocation" {
    const big = try testing.allocator.alloc(u8, 64 * 1024 + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const actual = try buildSystemPrompt(testing.allocator, .{
        .persona_prefix = big,
        .persona_suffix = big,
    });
    defer testing.allocator.free(actual);
    try testing.expect(actual.len > 2 * big.len);
}
