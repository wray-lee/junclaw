//! The one dsh profile-patch entry junclaw owns.
//!
//! `$DSH_HOME/profiles/web/cordis.patch.yml` is the user's own patch layer:
//! it may hold any number of entries, including their own `llm-pi-ai` routes
//! and an `agent-default-model` they chose. Boot rewrites only two things in
//! it — `providers.junclaw` and the `agent-default-model` selection — and
//! copies every other line through byte for byte.
//!
//! The route id and the credential env name are constants on purpose. The id
//! is the dictionary key `agent-default-model` stores and old session logs
//! reference; deriving it from junclaw's provider/model names would orphan
//! both whenever the user renames a provider.

const std = @import("std");
const std_compat = @import("compat");
const fs_compat = @import("../../fs_compat.zig");

const Allocator = std.mem.Allocator;

/// Permanent dsh provider route id. Never derive this from junclaw config.
pub const route_id = "junclaw";
/// Permanent credential reference; `buildEnvMap` supplies this variable.
pub const api_key_env = "JUNCLAW_DSH_API_KEY";
pub const profile_name = "web";

/// pi-ai model metadata defaults for routes whose model is not in the
/// installed catalog (a junclaw provider is by definition not).
pub const context_window: u32 = 32_768;
pub const max_tokens: u32 = 4_096;

pub const Route = struct {
    /// Endpoint the route speaks, without a request-path suffix.
    base_url: []const u8,
    /// pi-ai wire protocol: `openai-completions`, `openai-responses`, or
    /// `anthropic-messages`.
    api: []const u8 = "openai-completions",
    /// Model ids advertised on the junclaw route.
    models: []const []const u8,
    /// Model `agent-default-model` points at.
    default_model: []const u8,
    /// Key injected as `api_key_env`; null leaves the variable unset.
    api_key: ?[]const u8 = null,
};

pub fn patchPath(allocator: Allocator, dsh_home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ dsh_home, "profiles", profile_name, "cordis.patch.yml" });
}

/// Read the profile patch, rewrite the junclaw-owned keys, and replace it
/// atomically (tmp + rename in the same directory). A no-op when the rendered
/// text is unchanged, so repeated boots do not churn the file.
pub fn write(allocator: Allocator, dsh_home: []const u8, route: Route) !void {
    const path = try patchPath(allocator, dsh_home);
    defer allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse ".";
    try fs_compat.makePath(dir);

    const existing = fs_compat.readFileAlloc(std_compat.fs.cwd(), allocator, path, 4 << 20) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    const rendered = try render(allocator, existing, route);
    defer allocator.free(rendered);
    if (std.mem.eql(u8, rendered, existing)) return;
    try fs_compat.writeFileAtomicSecure(path, rendered);
}

/// Rewrite `providers.<route_id>` and the `agent-default-model` selection in
/// an existing patch document, preserving all other entries and keys.
pub fn render(allocator: Allocator, existing: []const u8, route: Route) ![]u8 {
    if (route.models.len == 0) return error.EmptyModelCatalog;

    var line_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer line_list.deinit(allocator);
    var line_it = std.mem.splitScalar(u8, existing, '\n');
    while (line_it.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try line_list.append(allocator, line);
    }
    // A trailing newline yields one empty tail slice; drop it and re-add the
    // newline when joining.
    if (line_list.items.len > 0 and line_list.items[line_list.items.len - 1].len == 0) {
        _ = line_list.pop();
    }
    const lines = line_list.items;

    const llm = findEntry(lines, "llm-pi-ai");
    const agent = findEntry(lines, "agent-default-model");
    // The dsh template ships an empty top-level array (`[]`); appending a
    // block entry after it is invalid YAML. Drop the placeholder once we are
    // about to add entries, but leave a document we do not modify untouched.
    const append_entries = llm == null or agent == null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < lines.len) {
        if (llm != null and i == llm.?.start) {
            try renderLlmEntry(&out, allocator, lines, llm.?.start, llm.?.end, route);
            i = llm.?.end;
            continue;
        }
        if (agent != null and i == agent.?.start) {
            try renderAgentEntry(&out, allocator, lines, agent.?.start, agent.?.end, route);
            i = agent.?.end;
            continue;
        }
        if (append_entries and indentOf(lines[i]) == 0 and std.mem.eql(u8, trimmed(lines[i]), "[]")) {
            i += 1;
            continue;
        }
        try out.appendSlice(allocator, lines[i]);
        try out.append(allocator, '\n');
        i += 1;
    }

    if (llm == null) {
        try entrySeparator(&out, allocator);
        try newLlmEntry(&out, allocator, route);
    }
    if (agent == null) {
        try entrySeparator(&out, allocator);
        try newAgentEntry(&out, allocator, route);
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Entry discovery
// ---------------------------------------------------------------------------

const Span = struct { start: usize, end: usize };

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') : (n += 1) {}
    return n;
}

fn trimmed(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn isIgnorable(line: []const u8) bool {
    const t = trimmed(line);
    return t.len == 0 or t[0] == '#';
}

fn keyMatches(line: []const u8, key: []const u8) bool {
    const t = trimmed(line);
    return t.len > key.len and std.mem.startsWith(u8, t, key) and t[key.len] == ':';
}

fn scalar(raw: []const u8) []const u8 {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len >= 2 and ((t[0] == '"' and t[t.len - 1] == '"') or (t[0] == '\'' and t[t.len - 1] == '\''))) {
        return t[1 .. t.len - 1];
    }
    return t;
}

/// Locate a top-level `- id: <id>` entry (or `-` followed by an `id:` line).
fn findEntry(lines: []const []const u8, id: []const u8) ?Span {
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        if (indentOf(lines[i]) != 0) continue;
        const t = trimmed(lines[i]);
        if (t.len == 0 or t[0] != '-') continue;

        var end = lines.len;
        var j = i + 1;
        while (j < lines.len) : (j += 1) {
            if (indentOf(lines[j]) == 0 and std.mem.startsWith(u8, trimmed(lines[j]), "-")) {
                end = j;
                break;
            }
        }

        var found: ?[]const u8 = null;
        const after_dash = std.mem.trimStart(u8, t[1..], " \t");
        if (std.mem.startsWith(u8, after_dash, "id:")) {
            found = scalar(after_dash["id:".len..]);
        } else {
            var k = i + 1;
            while (k < end) : (k += 1) {
                if (keyMatches(lines[k], "id")) {
                    const line = trimmed(lines[k]);
                    found = scalar(line["id:".len..]);
                    break;
                }
            }
        }
        if (found) |entry_id| {
            if (std.mem.eql(u8, entry_id, id)) return .{ .start = i, .end = end };
        }
        i = end - 1;
    }
    return null;
}

/// Indentation of an entry's keys (`- id: x` -> 2).
fn contentIndent(lines: []const []const u8, start: usize, end: usize) usize {
    const dash_indent = indentOf(lines[start]);
    const after = std.mem.trimStart(u8, lines[start][dash_indent + 1 ..], " \t");
    if (after.len > 0) return dash_indent + 2;
    var i = start + 1;
    while (i < end) : (i += 1) {
        if (isIgnorable(lines[i])) continue;
        return indentOf(lines[i]);
    }
    return dash_indent + 2;
}

fn idLine(lines: []const []const u8, start: usize, end: usize) usize {
    const dash_indent = indentOf(lines[start]);
    const after = std.mem.trimStart(u8, lines[start][dash_indent + 1 ..], " \t");
    if (after.len > 0) return start;
    var i = start + 1;
    while (i < end) : (i += 1) {
        if (keyMatches(lines[i], "id")) return i;
    }
    return start;
}

/// End of the block opened at `parent` (first non-blank line indented <= it).
fn blockEnd(lines: []const []const u8, from: usize, to: usize, parent_indent: usize) usize {
    var i = from;
    while (i < to) : (i += 1) {
        if (isIgnorable(lines[i])) continue;
        if (indentOf(lines[i]) <= parent_indent) return i;
    }
    return to;
}

fn firstChildIndent(lines: []const []const u8, from: usize, to: usize, parent_indent: usize) ?usize {
    var i = from;
    while (i < to) : (i += 1) {
        if (isIgnorable(lines[i])) continue;
        const indent = indentOf(lines[i]);
        if (indent <= parent_indent) return null;
        return indent;
    }
    return null;
}

fn childKeyIndex(
    lines: []const []const u8,
    from: usize,
    to: usize,
    parent_indent: usize,
    key: []const u8,
) ?usize {
    const child_indent = firstChildIndent(lines, from, to, parent_indent) orelse return null;
    var i = from;
    while (i < to) : (i += 1) {
        if (isIgnorable(lines[i])) continue;
        if (indentOf(lines[i]) != child_indent) continue;
        if (keyMatches(lines[i], key)) return i;
    }
    return null;
}

/// End of the subtree rooted at `start` (indent > key_indent), including
/// blank lines that sit inside it.
fn subtreeEnd(lines: []const []const u8, start: usize, end: usize, key_indent: usize) usize {
    var i = start + 1;
    while (i < end) {
        if (isIgnorable(lines[i])) {
            var j = i;
            while (j < end and isIgnorable(lines[j])) : (j += 1) {}
            if (j < end and indentOf(lines[j]) > key_indent) {
                i = j;
                continue;
            }
            return i;
        }
        if (indentOf(lines[i]) <= key_indent) return i;
        i += 1;
    }
    return end;
}

fn findConfig(lines: []const []const u8, start: usize, end: usize) ?usize {
    const dash_indent = indentOf(lines[start]);
    var i = start + 1;
    while (i < end) : (i += 1) {
        if (isIgnorable(lines[i])) continue;
        if (indentOf(lines[i]) <= dash_indent) break;
        if (keyMatches(lines[i], "config")) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// llm-pi-ai entry
// ---------------------------------------------------------------------------

fn renderLlmEntry(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    lines: []const []const u8,
    start: usize,
    end: usize,
    route: Route,
) !void {
    const config_idx = findConfig(lines, start, end);
    if (config_idx == null) {
        const insert_after = idLine(lines, start, end);
        const indent = contentIndent(lines, start, end);
        var i = start;
        while (i <= insert_after) : (i += 1) {
            try out.appendSlice(allocator, lines[i]);
            try out.append(allocator, '\n');
        }
        try appendIndented(out, allocator, indent, "config:\n");
        try appendIndented(out, allocator, indent + 2, "providers:\n");
        try appendRoute(out, allocator, indent + 4, route);
        while (i < end) : (i += 1) {
            try out.appendSlice(allocator, lines[i]);
            try out.append(allocator, '\n');
        }
        return;
    }

    const config_line = config_idx.?;
    const config_indent = indentOf(lines[config_line]);
    const config_end = blockEnd(lines, config_line + 1, end, config_indent);
    const providers_idx = childKeyIndex(lines, config_line + 1, config_end, config_indent, "providers");

    if (providers_idx == null) {
        var i = start;
        while (i <= config_line) : (i += 1) {
            try out.appendSlice(allocator, lines[i]);
            try out.append(allocator, '\n');
        }
        try appendIndented(out, allocator, config_indent + 2, "providers:\n");
        try appendRoute(out, allocator, config_indent + 4, route);
        while (i < end) : (i += 1) {
            try out.appendSlice(allocator, lines[i]);
            try out.append(allocator, '\n');
        }
        return;
    }

    const providers_line = providers_idx.?;
    const providers_indent = indentOf(lines[providers_line]);
    const providers_end = blockEnd(lines, providers_line + 1, end, providers_indent);
    const child_indent = firstChildIndent(lines, providers_line + 1, providers_end, providers_indent) orelse
        providers_indent + 2;
    const route_idx = childKeyIndex(lines, providers_line + 1, providers_end, providers_indent, route_id);

    var i = start;
    if (route_idx) |route_line| {
        while (i < route_line) : (i += 1) {
            try out.appendSlice(allocator, lines[i]);
            try out.append(allocator, '\n');
        }
        try appendRoute(out, allocator, child_indent, route);
        i = subtreeEnd(lines, route_line, end, child_indent);
    } else {
        while (i <= providers_line) : (i += 1) {
            try out.appendSlice(allocator, lines[i]);
            try out.append(allocator, '\n');
        }
        try appendRoute(out, allocator, child_indent, route);
    }
    while (i < end) : (i += 1) {
        try out.appendSlice(allocator, lines[i]);
        try out.append(allocator, '\n');
    }
}

fn appendRoute(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, indent: usize, route: Route) !void {
    try appendIndented(out, allocator, indent, route_id ++ ":\n");
    const child = indent + 2;
    try appendIndented(out, allocator, child, "api: ");
    try out.appendSlice(allocator, route.api);
    try out.append(allocator, '\n');
    try appendIndented(out, allocator, child, "baseURL: ");
    try appendScalar(out, allocator, route.base_url);
    try out.append(allocator, '\n');
    try appendIndented(out, allocator, child, "apiKeyEnv: " ++ api_key_env ++ "\n");
    try appendIndented(out, allocator, child, "models:\n");
    for (route.models) |model| {
        try appendIndented(out, allocator, child + 2, "- id: ");
        try appendScalar(out, allocator, model);
        try out.append(allocator, '\n');
        try appendIndented(out, allocator, child + 4, "name: ");
        try appendScalar(out, allocator, model);
        try out.append(allocator, '\n');
        try appendIndented(out, allocator, child + 4, "contextWindow: ");
        try appendFmt(out, allocator, "{d}\n", .{context_window});
        try appendIndented(out, allocator, child + 4, "maxTokens: ");
        try appendFmt(out, allocator, "{d}\n", .{max_tokens});
        try appendIndented(out, allocator, child + 4, "input: [text]\n");
    }
}

fn newLlmEntry(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, route: Route) !void {
    try out.appendSlice(allocator, "- id: llm-pi-ai\n");
    try appendIndented(out, allocator, 2, "config:\n");
    try appendIndented(out, allocator, 4, "providers:\n");
    try appendRoute(out, allocator, 6, route);
}

// ---------------------------------------------------------------------------
// agent-default-model entry
// ---------------------------------------------------------------------------

fn renderAgentEntry(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    lines: []const []const u8,
    start: usize,
    end: usize,
    route: Route,
) !void {
    const config_idx = findConfig(lines, start, end);
    if (config_idx == null) {
        const insert_after = idLine(lines, start, end);
        const indent = contentIndent(lines, start, end);
        var i = start;
        while (i <= insert_after) : (i += 1) {
            try out.appendSlice(allocator, lines[i]);
            try out.append(allocator, '\n');
        }
        try appendIndented(out, allocator, indent, "config:\n");
        try appendSelection(out, allocator, indent + 2, route);
        while (i < end) : (i += 1) {
            try out.appendSlice(allocator, lines[i]);
            try out.append(allocator, '\n');
        }
        return;
    }

    const config_line = config_idx.?;
    const config_indent = indentOf(lines[config_line]);
    const child_indent = firstChildIndent(lines, config_line + 1, end, config_indent) orelse config_indent + 2;
    const provider_idx = childKeyIndex(lines, config_line + 1, end, config_indent, "provider");
    const model_idx = childKeyIndex(lines, config_line + 1, end, config_indent, "model");

    var i = start;
    while (i < end) : (i += 1) {
        if (i == provider_idx) {
            try appendIndented(out, allocator, child_indent, "provider: " ++ route_id ++ "\n");
            continue;
        }
        if (i == model_idx) {
            try appendIndented(out, allocator, child_indent, "model: ");
            try appendScalar(out, allocator, route.default_model);
            try out.append(allocator, '\n');
            continue;
        }
        try out.appendSlice(allocator, lines[i]);
        try out.append(allocator, '\n');
        if (i == config_line) {
            if (provider_idx == null) {
                try appendIndented(out, allocator, child_indent, "provider: " ++ route_id ++ "\n");
            }
            if (model_idx == null) {
                try appendIndented(out, allocator, child_indent, "model: ");
                try appendScalar(out, allocator, route.default_model);
                try out.append(allocator, '\n');
            }
        }
    }
}

fn newAgentEntry(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, route: Route) !void {
    try out.appendSlice(allocator, "- id: agent-default-model\n");
    try appendIndented(out, allocator, 2, "config:\n");
    try appendSelection(out, allocator, 4, route);
}

fn appendSelection(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, indent: usize, route: Route) !void {
    try appendIndented(out, allocator, indent, "provider: " ++ route_id ++ "\n");
    try appendIndented(out, allocator, indent, "model: ");
    try appendScalar(out, allocator, route.default_model);
    try out.append(allocator, '\n');
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

fn appendIndented(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, indent: usize, text: []const u8) !void {
    try out.appendNTimes(allocator, ' ', indent);
    try out.appendSlice(allocator, text);
}

fn appendFmt(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendScalar(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: []const u8) !void {
    if (!needsQuote(value)) {
        try out.appendSlice(allocator, value);
        return;
    }
    const quoted = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
    defer allocator.free(quoted);
    try out.appendSlice(allocator, quoted);
}

fn needsQuote(value: []const u8) bool {
    if (value.len == 0) return true;
    switch (value[0]) {
        ' ', '-', '?', ':', '#', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`', '{', '[' => return true,
        else => {},
    }
    if (value[value.len - 1] == ' ') return true;
    for (value, 0..) |ch, i| {
        switch (ch) {
            '\n', '\r', '\t', '#', '"', '\'', '{', '}', '[', ']', ',', '&', '*', '!', '|', '>', '@', '%', '`' => return true,
            ':' => if (i + 1 == value.len or value[i + 1] == ' ' or value[i + 1] == '\t') return true,
            else => {},
        }
    }
    return false;
}

fn entrySeparator(out: *std.ArrayListUnmanaged(u8), allocator: Allocator) !void {
    if (out.items.len == 0) return;
    if (out.items.len >= 2 and out.items[out.items.len - 1] == '\n' and out.items[out.items.len - 2] == '\n') return;
    try out.append(allocator, '\n');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "profile render creates the owned entries and is idempotent" {
    const allocator = std.testing.allocator;
    const route: Route = .{
        .base_url = "https://api.example.com/v1",
        .models = &.{ "model-a", "model-b" },
        .default_model = "model-b",
        .api_key = "test-key",
    };

    const first = try render(allocator, "", route);
    defer allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "- id: llm-pi-ai\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "      junclaw:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "        api: openai-completions\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "        baseURL: https://api.example.com/v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "        apiKeyEnv: JUNCLAW_DSH_API_KEY\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "          - id: model-a\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "- id: agent-default-model\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "    provider: junclaw\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "    model: model-b\n") != null);

    const second = try render(allocator, first, route);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);

    // Changing the catalog rewrites only our route and the selection.
    const changed_route: Route = .{
        .base_url = "https://api.example.com/v1",
        .models = &.{"model-c"},
        .default_model = "model-c",
    };
    const changed = try render(allocator, first, changed_route);
    defer allocator.free(changed);
    try std.testing.expect(std.mem.indexOf(u8, changed, "junclaw:") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "model-a") == null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "model-c") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "model: model-c\n") != null);
}

test "profile render replaces the dsh template's empty array" {
    const allocator = std.testing.allocator;
    // The template dsh installs for a new profile.
    const template =
        \\# Your patch layer for this dsh profile, applied after every bundle layer:
        \\# a top-level YAML array of loader patch entries.
        \\[]
        \\
    ;
    const route: Route = .{
        .base_url = "https://api.example.com/v1",
        .api = "anthropic-messages",
        .models = &.{"model-a"},
        .default_model = "model-a",
    };

    const rendered = try render(allocator, template, route);
    defer allocator.free(rendered);

    // Regression: appending "- id:" after the template's "[]" produced YAML
    // that dsh rejected with "Unexpected token".
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\n[]\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "- id: llm-pi-ai\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "        api: anthropic-messages\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "- id: agent-default-model\n") != null);

    const second = try render(allocator, rendered, route);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(rendered, second);
}

test "profile render preserves user routes, entries and keys" {
    const allocator = std.testing.allocator;
    const existing =
        \\- id: llm-pi-ai
        \\  config:
        \\    providers:
        \\      user-route:
        \\        api: openai-completions
        \\        baseURL: https://user.example.com/v1
        \\        apiKeyEnv: USER_KEY
        \\        models:
        \\          - id: user-model
        \\            name: User Model
        \\- id: agent-default-model
        \\  config:
        \\    provider: user-route
        \\    model: user-model
        \\    reasoningEffort: high
        \\- id: some-plugin
        \\  config:
        \\    answer: 42
        \\
    ;
    const route: Route = .{
        .base_url = "https://api.example.com/v1",
        .models = &.{"model-a"},
        .default_model = "model-a",
    };

    const rendered = try render(allocator, existing, route);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "user-route:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "baseURL: https://user.example.com/v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "apiKeyEnv: USER_KEY\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "- id: some-plugin\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "    answer: 42\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "reasoningEffort: high\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "provider: junclaw\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "model: model-a\n") != null);

    // Exactly one junclaw route, and the user route keeps its own key.
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, rendered, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " "), "junclaw:")) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "profile write leaves no temp file when the atomic replace fails" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const dsh_home = try std.fs.path.join(allocator, &.{ root, "dsh" });
    defer allocator.free(dsh_home);
    const patch_dir = try std.fs.path.join(allocator, &.{ dsh_home, "profiles", "web" });
    defer allocator.free(patch_dir);
    try fs_compat.makePath(patch_dir);
    // A directory at the destination makes the final rename fail.
    const patch_path = try patchPath(allocator, dsh_home);
    defer allocator.free(patch_path);
    try fs_compat.makePath(patch_path);

    const route: Route = .{
        .base_url = "https://api.example.com/v1",
        .models = &.{"model-a"},
        .default_model = "model-a",
    };
    if (write(allocator, dsh_home, route)) |_| {
        return error.TestExpectedError;
    } else |_| {}

    var dir = try fs_compat.openDirPath(patch_dir, .{ .iterate = true });
    defer dir.close();
    var walker = dir.iterate();
    while (try walker.next()) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".nullclaw-secure-") == null);
    }
}
