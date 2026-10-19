//! Rewrite GFM tables as display-width-aligned pipe tables inside a fenced
//! code block. Telegram and Slack have no native table on their default
//! markdown path, so without this the raw `|` rows reach the user verbatim.
//! This mirrors OpenClaw's default `tableMode=code`.

const std = @import("std");

/// Oversized tables are fenced as-is instead of measured, which bounds the
/// work done on hostile input.
const max_table_rows = 200;
const max_table_columns = 40;

/// Replace every top-level GFM table in `md` with an aligned fenced block.
/// Lines inside ``` fences are left untouched; all other lines are preserved.
pub fn markdownTablesToCodeBlocks(allocator: std.mem.Allocator, md: []const u8) ![]u8 {
    var lines_buf: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines_buf.deinit(allocator);
    var line_iter = std.mem.splitScalar(u8, md, '\n');
    while (line_iter.next()) |line| try lines_buf.append(allocator, line);
    const lines = lines_buf.items;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var in_fence = false;
    var i: usize = 0;
    while (i < lines.len) {
        const trimmed = std.mem.trim(u8, lines[i], " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            try appendLine(&out, allocator, lines[i], i + 1 < lines.len);
            i += 1;
            continue;
        }
        if (!in_fence) {
            if (tableBlockEnd(lines, i)) |end| {
                try appendCodeTable(&out, allocator, lines[i..end]);
                if (end < lines.len) try out.append(allocator, '\n');
                i = end;
                continue;
            }
        }
        try appendLine(&out, allocator, lines[i], i + 1 < lines.len);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// True when `md` contains at least one GFM table outside of fenced code blocks.
/// Scans line by line without allocating.
pub fn hasMarkdownTable(md: []const u8) bool {
    var in_fence = false;
    var prev_was_table_row = false;
    var line_iter = std.mem.splitScalar(u8, md, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            prev_was_table_row = false;
            continue;
        }
        if (in_fence) {
            prev_was_table_row = false;
            continue;
        }
        if (prev_was_table_row and isDelimiterRow(trimmed)) {
            return true;
        }
        prev_was_table_row = isTableRow(trimmed);
    }
    return false;
}

fn appendLine(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    line: []const u8,
    trailing_newline: bool,
) !void {
    try out.appendSlice(allocator, line);
    if (trailing_newline) try out.append(allocator, '\n');
}

/// If a GFM table block starts at `lines[start]` (header row immediately
/// followed by a delimiter row), return the exclusive end index of the block.
fn tableBlockEnd(lines: []const []const u8, start: usize) ?usize {
    if (start + 1 >= lines.len) return null;
    if (!isTableRow(std.mem.trim(u8, lines[start], " \t\r"))) return null;
    if (!isDelimiterRow(std.mem.trim(u8, lines[start + 1], " \t\r"))) return null;
    var end = start + 2;
    while (end < lines.len and isTableRow(std.mem.trim(u8, lines[end], " \t\r"))) : (end += 1) {}
    return end;
}

/// GFM allows the leading pipe to be omitted, so any line containing a `|`
/// can be a row; the delimiter row is what actually marks a table.
fn isTableRow(trimmed: []const u8) bool {
    return std.mem.indexOfScalar(u8, trimmed, '|') != null;
}

/// True for a GFM delimiter row (`| --- | :--: |` or `--- | ---`).
fn isDelimiterRow(trimmed: []const u8) bool {
    var pipes: usize = 0;
    var dashes: usize = 0;
    for (trimmed) |c| switch (c) {
        '|' => pipes += 1,
        '-' => dashes += 1,
        ':', ' ', '\t', '\r' => {},
        else => return false,
    };
    return pipes >= 1 and dashes >= 1;
}

fn appendCodeTable(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    block: []const []const u8,
) !void {
    var cells: [max_table_columns + 1][]const u8 = undefined;
    var widths = [_]usize{0} ** max_table_columns;
    var columns: usize = 0;
    var row_count: usize = 0;

    for (block, 0..) |line, index| {
        if (index == 1) continue; // delimiter row is regenerated
        row_count += 1;
        const count = splitCells(line, &cells);
        if (count > max_table_columns) return appendRawFenced(out, allocator, block);
        columns = @max(columns, count);
        for (cells[0..count], 0..) |cell, col| {
            widths[col] = @max(widths[col], displayWidth(cell));
        }
    }
    if (row_count > max_table_rows or columns == 0) {
        return appendRawFenced(out, allocator, block);
    }

    for (widths[0..columns]) |*width| width.* = @max(width.*, 3);

    try out.appendSlice(allocator, "```\n");
    for (block, 0..) |line, index| {
        if (index == 1) {
            try appendDivider(out, allocator, widths[0..columns]);
            continue;
        }
        const count = splitCells(line, &cells);
        try appendRow(out, allocator, widths[0..columns], cells[0..count]);
    }
    try out.appendSlice(allocator, "```");
}

fn appendRawFenced(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    block: []const []const u8,
) !void {
    try out.appendSlice(allocator, "```\n");
    for (block, 0..) |line, index| {
        try out.appendSlice(allocator, line);
        if (index + 1 < block.len) try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, "\n```");
}

fn appendRow(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    widths: []const usize,
    cells: []const []const u8,
) !void {
    try out.append(allocator, '|');
    for (widths, 0..) |width, col| {
        const cell = if (col < cells.len) cells[col] else "";
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, cell);
        var pad = width - displayWidth(cell);
        while (pad > 0) : (pad -= 1) try out.append(allocator, ' ');
        try out.appendSlice(allocator, " |");
    }
    try out.append(allocator, '\n');
}

fn appendDivider(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    widths: []const usize,
) !void {
    try out.append(allocator, '|');
    for (widths) |width| {
        try out.append(allocator, ' ');
        var dashes = width;
        while (dashes > 0) : (dashes -= 1) try out.append(allocator, '-');
        try out.appendSlice(allocator, " |");
    }
    try out.append(allocator, '\n');
}

/// Split a row into trimmed cells. Pipes inside inline code spans are not
/// separators, so a cell like `` `a|b` `` stays one cell. Returns
/// `cells.len + 1` when the row has more cells than the buffer holds.
fn splitCells(line: []const u8, cells: [][]const u8) usize {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    var count: usize = 0;
    var start: usize = if (trimmed.len > 0 and trimmed[0] == '|') 1 else 0;
    var i = start;
    while (i < trimmed.len) {
        if (trimmed[i] == '`') {
            var run: usize = 0;
            while (i + run < trimmed.len and trimmed[i + run] == '`') run += 1;
            if (findBacktickRun(trimmed, i + run, run)) |close| {
                i = close + run;
            } else {
                i += run;
            }
            continue;
        }
        if (trimmed[i] == '|') {
            if (count == cells.len) return cells.len + 1;
            cells[count] = std.mem.trim(u8, trimmed[start..i], " \t");
            count += 1;
            start = i + 1;
        }
        i += 1;
    }
    if (count == cells.len) return cells.len + 1;
    cells[count] = std.mem.trim(u8, trimmed[start..], " \t");
    count += 1;
    if (count > 0 and cells[count - 1].len == 0) count -= 1; // trailing pipe
    return count;
}

fn findBacktickRun(line: []const u8, from: usize, run_len: usize) ?usize {
    var i = from;
    while (i < line.len) {
        if (line[i] == '`') {
            var run: usize = 0;
            while (i + run < line.len and line[i + run] == '`') run += 1;
            if (run == run_len) return i;
            i += run;
        } else {
            i += 1;
        }
    }
    return null;
}

/// Non-ASCII scalars occupy two columns (CJK, emoji); ASCII controls none.
fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + len, text.len);
        if (text[i] >= 0x20 and text[i] != 0x7f) {
            width += if (end - i == 1) 1 else 2;
        }
        i = end;
    }
    return width;
}

// Regression: Markdown tables rendered as raw pipes on the default Telegram path
test "markdownTablesToCodeBlocks aligns a two-column table inside a fence" {
    const out = try markdownTablesToCodeBlocks(
        std.testing.allocator,
        "| Name | Value |\n| --- | --- |\n| a | 1 |",
    );
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "```\n| Name | Value |\n| ---- | ----- |\n| a    | 1     |\n```",
        out,
    );
}

// Regression: Markdown tables rendered as raw pipes on the default Telegram path
test "markdownTablesToCodeBlocks keeps pipes inside inline code in one cell" {
    const out = try markdownTablesToCodeBlocks(
        std.testing.allocator,
        "| Code | Note |\n| --- | --- |\n| `a|b` | x |",
    );
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "```\n| Code  | Note |\n| ----- | ---- |\n| `a|b` | x    |\n```",
        out,
    );
}

// Regression: Markdown tables rendered as raw pipes on the default Telegram path
test "markdownTablesToCodeBlocks skips tables inside fenced code" {
    const input = "```\n| A | B |\n| --- | --- |\n```\nAfter | pipe";
    const out = try markdownTablesToCodeBlocks(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

// Regression: Markdown tables rendered as raw pipes on the default Telegram path
test "markdownTablesToCodeBlocks leaves a stray paragraph pipe alone" {
    const input = "Use a | b as a separator.\nNo delimiter row follows.";
    const out = try markdownTablesToCodeBlocks(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

// Regression: Markdown tables rendered as raw pipes on the default Telegram path
test "markdownTablesToCodeBlocks fences an over-wide table without aligning" {
    const allocator = std.testing.allocator;
    var header: std.ArrayListUnmanaged(u8) = .empty;
    defer header.deinit(allocator);
    var delimiter: std.ArrayListUnmanaged(u8) = .empty;
    defer delimiter.deinit(allocator);
    var col: usize = 0;
    while (col <= max_table_columns) : (col += 1) {
        var num_buf: [8]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{col});
        try header.appendSlice(allocator, "| c");
        try header.appendSlice(allocator, num);
        try header.appendSlice(allocator, " ");
        try delimiter.appendSlice(allocator, "| --- ");
    }
    try header.append(allocator, '|');
    try delimiter.append(allocator, '|');

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, header.items);
    try input.append(allocator, '\n');
    try input.appendSlice(allocator, delimiter.items);

    const out = try markdownTablesToCodeBlocks(allocator, input.items);
    defer allocator.free(out);

    var expected: std.ArrayListUnmanaged(u8) = .empty;
    defer expected.deinit(allocator);
    try expected.appendSlice(allocator, "```\n");
    try expected.appendSlice(allocator, header.items);
    try expected.append(allocator, '\n');
    try expected.appendSlice(allocator, delimiter.items);
    try expected.appendSlice(allocator, "\n```");
    try std.testing.expectEqualStrings(expected.items, out);
}

// Regression: Markdown tables rendered as raw pipes on the default Telegram path
test "markdownTablesToCodeBlocks fences an over-tall table without aligning" {
    const allocator = std.testing.allocator;
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, "| A | B |\n| --- | --- |");
    var row: usize = 0;
    while (row <= max_table_rows) : (row += 1) {
        var num_buf: [8]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{row});
        try input.appendSlice(allocator, "\n| ");
        try input.appendSlice(allocator, num);
        try input.appendSlice(allocator, " | x |");
    }

    const out = try markdownTablesToCodeBlocks(allocator, input.items);
    defer allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "```\n| A | B |\n| --- | --- |\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\n| 0 | x |\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\n```"));
}

// Regression: Markdown tables rendered as raw pipes on the default Telegram path
test "markdownTablesToCodeBlocks aligns wide CJK characters" {
    const out = try markdownTablesToCodeBlocks(
        std.testing.allocator,
        "| 名称 | 值 |\n| --- | --- |\n| a | b |",
    );
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "```\n| 名称 | 值  |\n| ---- | --- |\n| a    | b   |\n```",
        out,
    );
}

// Regression: slack final reply stopped rendering markdown tables after the stream finished
test "hasMarkdownTable detects valid GFM table" {
    try std.testing.expect(hasMarkdownTable("| Name | Age |\n| --- | --- |\n| Alice | 30 |"));
    try std.testing.expect(hasMarkdownTable("Header\nName | Age\n---|---\nAlice | 30"));
}

// Regression: slack final reply stopped rendering markdown tables after the stream finished
test "hasMarkdownTable ignores tables inside fenced code" {
    const fenced = "```markdown\n| Name | Age |\n| --- | --- |\n| Alice | 30 |\n```";
    try std.testing.expect(!hasMarkdownTable(fenced));
}

// Regression: slack final reply stopped rendering markdown tables after the stream finished
test "hasMarkdownTable returns false for stray pipes or delimiter-less text" {
    try std.testing.expect(!hasMarkdownTable("Use a | b as separator"));
    try std.testing.expect(!hasMarkdownTable("| only | one | row |"));
    try std.testing.expect(!hasMarkdownTable("plain text without tables"));
    try std.testing.expect(!hasMarkdownTable(""));
}
