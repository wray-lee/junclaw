//! Built-in filesystem tools: `read`, `write`, `edit`, `grep`, `glob`
//! (design §1.2 B25b).
//!
//! Model-visible names, descriptions and input schemas come from
//! `generated/tool_schemas.zig`; result text comes from
//! `generated/tool_render.zig`. Paths resolve against the session cwd; the
//! mutating tools additionally refuse a resolved path outside it (approval is
//! P2, but the containment check is not optional).
//!
//! Bounded deviations from dsh, all documented at their sites: `grep` matches
//! literal text instead of a regex/ripgrep process, file reads buffer the whole
//! file (64 MiB cap), and the walker approximates ripgrep's ignore/symlink
//! defaults.

const std = @import("std");
const compat = @import("compat");
const fs_compat = @import("../../../fs_compat.zig");
const generated = @import("../generated/tool_schemas.zig");
const render = @import("../generated/tool_render.zig");
const registry = @import("registry.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const read_limit: usize = 2000;
pub const read_max_line_length: usize = 2000;
pub const read_max_bytes: usize = 50 * 1024;
pub const grep_max_matches: usize = 250;
pub const grep_max_line_bytes: usize = 2000;
pub const glob_max_results: usize = 100;

/// One buffered read; larger files fail with `FS_TOO_LARGE` instead of
/// streaming. shortcut: whole-file buffering, upgrade to a streaming reader
/// when multi-hundred-MB reads are expected.
const max_file_bytes: usize = 64 * 1024 * 1024;

/// dsh spill markers this build mirrors (`spill-local`).
const spill_retrieval_hint = "Use read with offset/limit, or grep this path to search within it.";
const vcs_dir_names = [_][]const u8{ ".git", ".svn", ".hg", ".bzr", ".jj", ".sl" };

/// Session-scoped tool context. `cwd` must be absolute; `spill_dir` is where
/// over-cap search results are saved (created on demand, best effort).
pub const Builtins = struct {
    cwd: []const u8,
    spill_dir: []const u8,
    spill_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub const Handlers = struct {
        read: registry.Handler,
        write: registry.Handler,
        edit: registry.Handler,
        grep: registry.Handler,
        glob: registry.Handler,
    };

    /// Handlers borrow `self`; keep the Builtins value pinned for their lifetime.
    pub fn handlers(self: *Builtins) Handlers {
        const context: ?*anyopaque = @ptrCast(self);
        return .{
            .read = .{ .context = context, .call = readHandler },
            .write = .{ .context = context, .call = writeHandler },
            .edit = .{ .context = context, .call = editHandler },
            .grep = .{ .context = context, .call = grepHandler },
            .glob = .{ .context = context, .call = globHandler },
        };
    }

    /// Register the five filesystem tools under their generated dsh names.
    /// `bash` is a separate built-in and is not registered here.
    pub fn register(self: *Builtins, reg: *registry.Registry, allocator: Allocator) !void {
        const h = self.handlers();
        try reg.register(allocator, .{
            .name = generated.read.name,
            .description = generated.read.description,
            .input_schema_json = generated.read.input_schema_json,
            .handler = h.read,
        });
        try reg.register(allocator, .{
            .name = generated.write.name,
            .description = generated.write.description,
            .input_schema_json = generated.write.input_schema_json,
            .handler = h.write,
        });
        try reg.register(allocator, .{
            .name = generated.edit.name,
            .description = generated.edit.description,
            .input_schema_json = generated.edit.input_schema_json,
            .handler = h.edit,
        });
        try reg.register(allocator, .{
            .name = generated.grep.name,
            .description = generated.grep.description,
            .input_schema_json = generated.grep.input_schema_json,
            .handler = h.grep,
        });
        try reg.register(allocator, .{
            .name = generated.glob.name,
            .description = generated.glob.description,
            .input_schema_json = generated.glob.input_schema_json,
            .handler = h.glob,
        });
    }
};

// ---------------------------------------------------------------------------
// Handler entry points

fn readHandler(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const self: *Builtins = @ptrCast(@alignCast(context.?));
    return runRead(self, allocator, args);
}

fn writeHandler(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const self: *Builtins = @ptrCast(@alignCast(context.?));
    return runWrite(self, allocator, args);
}

fn editHandler(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const self: *Builtins = @ptrCast(@alignCast(context.?));
    return runEdit(self, allocator, args);
}

fn grepHandler(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const self: *Builtins = @ptrCast(@alignCast(context.?));
    return runGrep(self, allocator, args);
}

fn globHandler(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const self: *Builtins = @ptrCast(@alignCast(context.?));
    return runGlob(self, allocator, args);
}

// ---------------------------------------------------------------------------
// Result and argument helpers

fn successText(allocator: Allocator, text: []const u8) !registry.ToolResult {
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = text };
    return .{ .success = .{ .content = blocks } };
}

fn failure(allocator: Allocator, name: []const u8, code: []const u8, text: []const u8) !registry.ToolResult {
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = text };
    return .{ .failure = .{
        .error_info = .{ .name = name, .code = code, .reason = text },
        .content = blocks,
    } };
}

fn invalidArg(allocator: Allocator, text: []const u8) !registry.ToolResult {
    return failure(allocator, "Error", "INVALID_ARGUMENT", text);
}

fn fsFailure(allocator: Allocator, code: []const u8, text: []const u8) !registry.ToolResult {
    return failure(allocator, "FsError", code, text);
}

fn fsFailureFor(allocator: Allocator, verb: []const u8, path: []const u8, err: anyerror) !registry.ToolResult {
    const detail: []const u8 = switch (err) {
        error.FileNotFound => "not found",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.NotDir => "not a directory",
        else => @errorName(err),
    };
    const text = try std.fmt.allocPrint(allocator, "cannot {s} \"{s}\": {s}", .{ verb, path, detail });
    return fsFailure(allocator, fsCodeFor(err), text);
}

fn fsCodeFor(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "FS_NOT_FOUND",
        error.AccessDenied, error.PermissionDenied => "FS_PERMISSION_DENIED",
        error.StreamTooLong => "FS_TOO_LARGE",
        error.IsDir, error.NotDir => "FS_NOT_REGULAR_FILE",
        else => "FS_IO_ERROR",
    };
}

fn field(args: Value, name: []const u8) ?Value {
    return switch (args) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn stringField(args: Value, name: []const u8) ?[]const u8 {
    const value = field(args, name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn boolField(args: Value, name: []const u8) ?bool {
    const value = field(args, name) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn positiveArg(args: Value, name: []const u8, default: u64) ?u64 {
    const value = field(args, name) orelse return default;
    return switch (value) {
        .integer => |number| if (number >= 1) @intCast(number) else null,
        .float => |number| if (std.math.isFinite(number) and number >= 1 and number <= @as(f64, @floatFromInt(std.math.maxInt(u64))) and @floor(number) == number)
            @intFromFloat(number)
        else
            null,
        else => null,
    };
}

fn blank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len == 0;
}

// ---------------------------------------------------------------------------
// Path helpers

fn resolvePath(allocator: Allocator, cwd: []const u8, input: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(input)) return std.fs.path.resolve(allocator, &.{input});
    return std.fs.path.resolve(allocator, &.{ cwd, input });
}

/// Lexical containment: the resolved path must sit inside the session cwd.
/// shortcut: symlinks inside the cwd can still point outside; realpath-based
/// confinement belongs to the P2 sandbox/approval layer.
fn insideCwd(cwd: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, cwd, path)) return true;
    if (!std.mem.startsWith(u8, path, cwd)) return false;
    if (path.len <= cwd.len) return false;
    return std.fs.path.isSep(path[cwd.len]);
}

fn relativeDisplay(allocator: Allocator, cwd: []const u8, absolute: []const u8) ![]const u8 {
    const rel = compat.fs.path.relative(allocator, cwd, absolute) catch return absolute;
    if (rel.len == 0) return ".";
    if (std.mem.eql(u8, rel, "..")) return absolute;
    if (std.mem.startsWith(u8, rel, ".." ++ std.fs.path.sep_str)) return absolute;
    return rel;
}

fn childPath(allocator: Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ dir, name });
}

fn fileKind(path: []const u8) !?std.Io.File.Kind {
    const file = fs_compat.openPath(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.IsDir => return .directory,
        else => return err,
    };
    defer file.close();
    const stat = try file.stat();
    return stat.kind;
}

// ---------------------------------------------------------------------------
// read

fn runRead(self: *Builtins, allocator: Allocator, args: Value) !registry.ToolResult {
    const file_path = stringField(args, "file_path") orelse
        return invalidArg(allocator, render.edit.error_empty_path);
    if (blank(file_path)) return invalidArg(allocator, render.edit.error_empty_path);

    const offset = positiveArg(args, "offset", 1) orelse
        return invalidArg(allocator, try std.fmt.allocPrint(allocator, render.read.error_positive_integer, .{"offset"}));
    const limit = positiveArg(args, "limit", read_limit) orelse
        return invalidArg(allocator, try std.fmt.allocPrint(allocator, render.read.error_positive_integer, .{"limit"}));
    if (limit > read_limit) {
        return invalidArg(allocator, try std.fmt.allocPrint(allocator, render.read.error_limit_max, .{read_limit}));
    }

    const cwd = try std.fs.path.resolve(allocator, &.{self.cwd});
    const absolute = try resolvePath(allocator, cwd, file_path);
    const kind = fileKind(absolute) catch |err| return fsFailureFor(allocator, "read", absolute, err);
    if (kind == null) {
        return fsFailure(allocator, "FS_NOT_FOUND", try std.fmt.allocPrint(allocator, "cannot read \"{s}\": not found", .{absolute}));
    }
    if (kind.? != .file) {
        return fsFailure(allocator, "FS_NOT_REGULAR_FILE", try std.fmt.allocPrint(allocator, "cannot read \"{s}\": not a regular file", .{absolute}));
    }

    const file = fs_compat.openPath(absolute, .{}) catch |err|
        return fsFailureFor(allocator, "read", absolute, err);
    defer file.close();
    const data = file.readToEndAlloc(allocator, max_file_bytes) catch |err| switch (err) {
        error.StreamTooLong => return fsFailure(allocator, "FS_TOO_LARGE", try std.fmt.allocPrint(allocator, "cannot read \"{s}\": file is larger than {d} bytes", .{ absolute, max_file_bytes })),
        else => return fsFailureFor(allocator, "read", absolute, err),
    };
    if (!std.unicode.utf8ValidateSlice(data)) {
        return fsFailure(allocator, "FS_NOT_TEXT", try std.fmt.allocPrint(allocator, "cannot read \"{s}\": file is not valid UTF-8 text", .{absolute}));
    }

    var body: std.ArrayListUnmanaged(u8) = .empty;
    var total_lines: usize = 0;
    var selected: usize = 0;
    var output_bytes: usize = 0;
    var truncated_by_bytes = false;
    var last_number: usize = @intCast(offset - 1);

    var line_start: usize = 0;
    while (line_start < data.len) {
        const newline = std.mem.indexOfScalarPos(u8, data, line_start, '\n');
        const line_end = newline orelse data.len;
        var line = data[line_start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        total_lines += 1;

        if (!truncated_by_bytes and total_lines >= offset and selected < limit) {
            const text = try truncateLine(allocator, line, read_max_line_length);
            const bytes = text.len + (if (selected > 0) @as(usize, 1) else 0);
            if (output_bytes + bytes > read_max_bytes) {
                truncated_by_bytes = true;
            } else {
                output_bytes += bytes;
                if (selected > 0) try body.append(allocator, '\n');
                try body.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}: {s}", .{ total_lines, text }));
                selected += 1;
                last_number = total_lines;
            }
        }

        if (newline == null) break;
        line_start = line_end + 1;
    }

    if (!truncated_by_bytes and offset > total_lines and !(total_lines == 0 and offset == 1)) {
        return fsFailure(allocator, "FS_NOT_FOUND", try std.fmt.allocPrint(allocator, render.read.out_of_range, .{ offset, absolute, total_lines }));
    }

    const footer = if (truncated_by_bytes)
        try std.fmt.allocPrint(allocator, render.read.capped_footer, .{ offset, last_number, last_number + 1 })
    else if (last_number < total_lines)
        try std.fmt.allocPrint(allocator, render.read.showing_footer, .{ offset, last_number, total_lines, last_number + 1 })
    else
        try std.fmt.allocPrint(allocator, render.read.eof_footer, .{total_lines});

    if (body.items.len > 0) try body.appendSlice(allocator, "\n\n");
    try body.appendSlice(allocator, footer);

    return successText(allocator, try std.fmt.allocPrint(allocator, render.read.envelope, .{ absolute, body.items }));
}

/// Truncate to `max_chars` Unicode scalar values, appending dsh's suffix.
fn truncateLine(allocator: Allocator, line: []const u8, max_chars: usize) ![]const u8 {
    var count: usize = 0;
    var index: usize = 0;
    while (index < line.len) {
        if (count == max_chars) {
            return std.fmt.allocPrint(allocator, render.read.line_truncated, .{ line[0..index], max_chars });
        }
        const length = std.unicode.utf8ByteSequenceLength(line[index]) catch 1;
        index += length;
        count += 1;
    }
    return line;
}

// ---------------------------------------------------------------------------
// write

fn runWrite(self: *Builtins, allocator: Allocator, args: Value) !registry.ToolResult {
    const file_path = stringField(args, "file_path") orelse
        return invalidArg(allocator, render.edit.error_empty_path);
    if (blank(file_path)) return invalidArg(allocator, render.edit.error_empty_path);
    const content = stringField(args, "content") orelse
        return invalidArg(allocator, "content must be a string");

    const cwd = try std.fs.path.resolve(allocator, &.{self.cwd});
    const absolute = try resolvePath(allocator, cwd, file_path);
    if (!insideCwd(cwd, absolute)) {
        return fsFailure(allocator, "FS_SANDBOX_DENIED", try std.fmt.allocPrint(allocator, "cannot write \"{s}\": resolved path is outside the session working directory", .{absolute}));
    }

    const existed = blk: {
        const kind = fileKind(absolute) catch |err| return fsFailureFor(allocator, "write", absolute, err) catch return err;
        if (kind == null) break :blk false;
        if (kind.? != .file) {
            return fsFailure(allocator, "FS_NOT_REGULAR_FILE", try std.fmt.allocPrint(allocator, "cannot write \"{s}\": not a regular file", .{absolute}));
        }
        break :blk true;
    };

    if (std.fs.path.dirname(absolute)) |parent| {
        fs_compat.makePath(parent) catch |err| return fsFailureFor(allocator, "write", absolute, err);
    }

    const file = fs_compat.createPath(absolute, .{ .truncate = true }) catch |err|
        return fsFailureFor(allocator, "write", absolute, err);
    defer file.close();
    file.writeAll(content) catch |err| return fsFailureFor(allocator, "write", absolute, err);
    file.sync() catch |err| return fsFailureFor(allocator, "write", absolute, err);

    const verb = if (existed) render.write.updated_verb else render.write.created_verb;
    return successText(allocator, try std.fmt.allocPrint(allocator, render.write.output_envelope, .{ absolute, verb }));
}

// ---------------------------------------------------------------------------
// edit

fn runEdit(self: *Builtins, allocator: Allocator, args: Value) !registry.ToolResult {
    const file_path = stringField(args, "file_path") orelse
        return invalidArg(allocator, render.edit.error_empty_path);
    if (blank(file_path)) return invalidArg(allocator, render.edit.error_empty_path);
    const old_string = stringField(args, "old_string") orelse
        return invalidArg(allocator, render.edit.error_empty_old);
    if (old_string.len == 0) return invalidArg(allocator, render.edit.error_empty_old);
    const new_string = stringField(args, "new_string") orelse
        return invalidArg(allocator, "new_string must be a string");
    if (std.mem.eql(u8, old_string, new_string)) return invalidArg(allocator, render.edit.error_equal);
    const replace_all = boolField(args, "replace_all") orelse false;

    const cwd = try std.fs.path.resolve(allocator, &.{self.cwd});
    const absolute = try resolvePath(allocator, cwd, file_path);
    if (!insideCwd(cwd, absolute)) {
        return fsFailure(allocator, "FS_SANDBOX_DENIED", try std.fmt.allocPrint(allocator, "cannot edit \"{s}\": resolved path is outside the session working directory", .{absolute}));
    }

    const file = fs_compat.openPath(absolute, .{}) catch |err| switch (err) {
        error.FileNotFound => return fsFailure(allocator, "FS_NOT_FOUND", try std.fmt.allocPrint(allocator, "cannot edit \"{s}\": not found", .{absolute})),
        else => return fsFailureFor(allocator, "edit", absolute, err),
    };
    defer file.close();
    const stat = file.stat() catch |err| return fsFailureFor(allocator, "edit", absolute, err);
    if (stat.kind != .file) {
        return fsFailure(allocator, "FS_NOT_REGULAR_FILE", try std.fmt.allocPrint(allocator, "cannot edit \"{s}\": not a regular file", .{absolute}));
    }
    const raw = file.readToEndAlloc(allocator, max_file_bytes) catch |err| switch (err) {
        error.StreamTooLong => return fsFailure(allocator, "FS_TOO_LARGE", try std.fmt.allocPrint(allocator, "cannot edit \"{s}\": file is larger than {d} bytes", .{ absolute, max_file_bytes })),
        else => return fsFailureFor(allocator, "edit", absolute, err),
    };
    if (!std.unicode.utf8ValidateSlice(raw)) {
        return fsFailure(allocator, "FS_NOT_TEXT", try std.fmt.allocPrint(allocator, "cannot edit \"{s}\": file is not valid UTF-8 text", .{absolute}));
    }

    const crlf = std.mem.indexOf(u8, raw, "\r\n") != null;
    const content = try normalizeCrlf(allocator, raw);
    const old_norm = try normalizeCrlf(allocator, old_string);
    const new_norm = try normalizeCrlf(allocator, new_string);
    if (old_norm.len == 0) return invalidArg(allocator, render.edit.error_empty_old);

    const matches = countOccurrences(content, old_norm);
    if (matches == 0) {
        return fsFailure(allocator, "FS_EDIT_NOT_FOUND", try std.fmt.allocPrint(allocator, "old_string was not found in \"{s}\"", .{absolute}));
    }
    if (!replace_all and matches > 1) {
        return fsFailure(allocator, "FS_AMBIGUOUS_EDIT", try std.fmt.allocPrint(allocator, "old_string matched {d} times in \"{s}\"; provide a more specific old_string or set replace_all to true", .{ matches, absolute }));
    }

    const replaced = if (replace_all)
        try replaceEvery(allocator, content, old_norm, new_norm)
    else
        try replaceFirst(allocator, content, old_norm, new_norm);
    const output = if (crlf) try restoreCrlf(allocator, replaced) else replaced;
    try writeAtomic(allocator, absolute, output);

    const text = if (replace_all)
        try std.fmt.allocPrint(allocator, render.edit.success_all, .{absolute})
    else
        try std.fmt.allocPrint(allocator, render.edit.success_single, .{absolute});
    return successText(allocator, text);
}

fn normalizeCrlf(allocator: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, "\r\n") == null) return text;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\r' and index + 1 < text.len and text[index + 1] == '\n') {
            try out.append(allocator, '\n');
            index += 2;
        } else {
            try out.append(allocator, text[index]);
            index += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn restoreCrlf(allocator: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (text) |byte| {
        if (byte == '\n') try out.append(allocator, '\r');
        try out.append(allocator, byte);
    }
    return out.toOwnedSlice(allocator);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |position| {
        count += 1;
        index = position + needle.len;
    }
    return count;
}

fn replaceFirst(allocator: Allocator, content: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    const position = std.mem.indexOf(u8, content, old).?;
    var out = try allocator.alloc(u8, content.len - old.len + new.len);
    @memcpy(out[0..position], content[0..position]);
    @memcpy(out[position..][0..new.len], new);
    @memcpy(out[position + new.len ..], content[position + old.len ..]);
    return out;
}

fn replaceEvery(allocator: Allocator, content: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, content, index, old)) |position| {
        try out.appendSlice(allocator, content[index..position]);
        try out.appendSlice(allocator, new);
        index = position + old.len;
    }
    try out.appendSlice(allocator, content[index..]);
    return out.toOwnedSlice(allocator);
}

/// Write beside the target then rename over it, so a failed write cannot
/// truncate the original.
fn writeAtomic(allocator: Allocator, path: []const u8, bytes: []const u8) !void {
    const directory = std.fs.path.dirname(path) orelse ".";
    const temp_name = try std.fmt.allocPrint(allocator, "dsh-edit-{x}.tmp", .{compat.crypto.random.int(u64)});
    const temp_path = try std.fs.path.join(allocator, &.{ directory, temp_name });
    {
        const file = try fs_compat.createPath(temp_path, .{ .truncate = true });
        errdefer fs_compat.deletePath(temp_path) catch {};
        defer file.close();
        try file.writeAll(bytes);
        try file.sync();
    }
    fs_compat.renamePath(temp_path, path) catch |err| {
        fs_compat.deletePath(temp_path) catch {};
        return err;
    };
}

// ---------------------------------------------------------------------------
// grep

const GrepMatch = struct {
    path: []const u8,
    line_number: usize,
    line: []const u8,
};

const GrepWalk = struct {
    allocator: Allocator,
    cwd: []const u8,
    pattern: []const u8,
    include: []const []const u8,
    matches: *std.ArrayListUnmanaged(GrepMatch),
};

fn runGrep(self: *Builtins, allocator: Allocator, args: Value) !registry.ToolResult {
    const pattern = stringField(args, "pattern") orelse
        return invalidArg(allocator, "pattern must be a non-empty string");
    if (pattern.len == 0) return invalidArg(allocator, "pattern must be a non-empty string");
    const path_arg = stringField(args, "path");
    if (path_arg) |path| {
        if (blank(path)) return invalidArg(allocator, "path must be a non-empty string when given");
    }
    const include_arg = stringField(args, "include");
    if (include_arg) |include| {
        if (blank(include)) return invalidArg(allocator, "include must be a non-empty glob when given");
    }

    const cwd = try std.fs.path.resolve(allocator, &.{self.cwd});
    const root = try resolvePath(allocator, cwd, path_arg orelse ".");
    const root_kind = fileKind(root) catch |err| return fsFailureFor(allocator, "search", root, err);
    if (root_kind == null) {
        return fsFailure(allocator, "FS_NOT_FOUND", try std.fmt.allocPrint(allocator, "cannot search \"{s}\": not found", .{root}));
    }

    var include_patterns: std.ArrayListUnmanaged([]const u8) = .empty;
    if (include_arg) |include| try expandBraces(allocator, include, &include_patterns);

    var matches: std.ArrayListUnmanaged(GrepMatch) = .empty;
    var walk = GrepWalk{
        .allocator = allocator,
        .cwd = cwd,
        .pattern = pattern,
        .include = include_patterns.items,
        .matches = &matches,
    };
    if (root_kind.? == .file) {
        try grepFile(&walk, root);
    } else {
        try grepWalk(&walk, root);
    }

    return successText(allocator, try formatGrep(self, allocator, matches.items));
}

fn grepWalk(walk: *GrepWalk, dir_abs: []const u8) !void {
    var dir = fs_compat.openDirPath(dir_abs, .{ .iterate = true }) catch return;
    defer dir.close();
    var iterator = dir.iterate();
    var children: std.ArrayListUnmanaged(Child) = .empty;
    while (try iterator.next()) |entry| {
        if (entry.kind != .file and entry.kind != .directory) continue;
        // ripgrep default: hidden entries are not searched.
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        try children.append(walk.allocator, .{
            .name = try walk.allocator.dupe(u8, entry.name),
            .is_dir = entry.kind == .directory,
        });
    }
    std.mem.sort(Child, children.items, {}, lessThanChild);
    for (children.items) |child| {
        const absolute = try childPath(walk.allocator, dir_abs, child.name);
        if (child.is_dir) {
            try grepWalk(walk, absolute);
        } else {
            try grepFile(walk, absolute);
        }
    }
}

fn grepFile(walk: *GrepWalk, absolute: []const u8) !void {
    const display = try relativeDisplay(walk.allocator, walk.cwd, absolute);
    if (walk.include.len > 0 and !try includeMatches(walk.allocator, walk.include, display)) return;

    const data = fs_compat.readFileAlloc(compat.fs.cwd(), walk.allocator, absolute, max_file_bytes) catch return;
    if (std.mem.indexOfScalar(u8, data, 0) != null) return; // binary
    if (!std.unicode.utf8ValidateSlice(data)) return; // shortcut: non-UTF-8 files are skipped, not partly rendered

    var line_start: usize = 0;
    var line_number: usize = 0;
    while (line_start < data.len) {
        const newline = std.mem.indexOfScalarPos(u8, data, line_start, '\n');
        const line_end = newline orelse data.len;
        var line = data[line_start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line_number += 1;
        if (std.mem.indexOf(u8, line, walk.pattern) != null) {
            try walk.matches.append(walk.allocator, .{
                .path = display,
                .line_number = line_number,
                .line = try previewLine(walk.allocator, line, grep_max_line_bytes),
            });
        }
        if (newline == null) break;
        line_start = line_end + 1;
    }
}

fn previewLine(allocator: Allocator, line: []const u8, max_bytes: usize) ![]const u8 {
    if (line.len <= max_bytes) return line;
    var end = max_bytes;
    while (end > 0 and (line[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(allocator, "{s} (line truncated)", .{line[0..end]});
}

fn includeMatches(allocator: Allocator, patterns: []const []const u8, display: []const u8) !bool {
    for (patterns) |pattern| {
        const target = if (std.mem.indexOfScalar(u8, pattern, '/') != null)
            try toMatchPath(allocator, display)
        else
            std.fs.path.basename(display);
        if (globMatch(pattern, target)) return true;
    }
    return false;
}

fn formatGrep(self: *Builtins, allocator: Allocator, matches: []const GrepMatch) ![]const u8 {
    if (matches.len == 0) return render.grep.no_matches;

    const kept = @min(matches.len, grep_max_matches);
    const truncated = matches.len > kept;
    const noun = if (matches.len == 1) render.grep.match_singular else render.grep.match_plural;

    var body: std.ArrayListUnmanaged(u8) = .empty;
    try appendGrepBody(allocator, &body, matches[0..kept]);

    const header = if (truncated)
        try std.fmt.allocPrint(allocator, render.grep.header_truncated, .{ kept, matches.len })
    else
        try std.fmt.allocPrint(allocator, render.grep.header_found, .{ matches.len, noun });

    if (!truncated) return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ header, body.items });

    var complete: std.ArrayListUnmanaged(u8) = .empty;
    try appendGrepBody(allocator, &complete, matches);
    const full_header = try std.fmt.allocPrint(allocator, render.grep.header_found, .{ matches.len, noun });
    const spill_content = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ full_header, complete.items });
    const locator = saveSpill(self, allocator, "grep", spill_content) catch null;
    const recovery = if (locator) |path|
        try std.fmt.allocPrint(allocator, render.grep.recovery_saved, .{ path, spill_retrieval_hint })
    else
        render.grep.recovery_unsaved;

    return std.fmt.allocPrint(allocator, "{s}\n\n{s}\n\n({s})", .{ header, body.items, recovery });
}

fn appendGrepBody(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), matches: []const GrepMatch) !void {
    var index: usize = 0;
    while (index < matches.len) {
        const path = matches[index].path;
        if (out.items.len > 0) try out.appendSlice(allocator, "\n\n");
        try out.appendSlice(allocator, path);
        while (index < matches.len and std.mem.eql(u8, matches[index].path, path)) : (index += 1) {
            try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\nLine {d}: {s}", .{ matches[index].line_number, matches[index].line }));
        }
    }
}

// ---------------------------------------------------------------------------
// glob

const GlobEntry = struct {
    display: []const u8,
    mtime: i128,
};

const GlobWalk = struct {
    allocator: Allocator,
    cwd: []const u8,
    root: []const u8,
    patterns: []const []const u8,
    pattern_has_separator: bool,
    entries: *std.ArrayListUnmanaged(GlobEntry),
};

fn runGlob(self: *Builtins, allocator: Allocator, args: Value) !registry.ToolResult {
    const pattern = stringField(args, "pattern") orelse
        return invalidArg(allocator, "pattern must be a non-empty string");
    if (blank(pattern)) return invalidArg(allocator, "pattern must be a non-empty string");
    const path_arg = stringField(args, "path");
    if (path_arg) |path| {
        if (blank(path)) return invalidArg(allocator, "path must be a non-empty string when given");
    }

    const cwd = try std.fs.path.resolve(allocator, &.{self.cwd});
    const root = try resolvePath(allocator, cwd, path_arg orelse ".");
    const root_kind = fileKind(root) catch |err| return fsFailureFor(allocator, "search", root, err);
    if (root_kind == null) {
        return fsFailure(allocator, "FS_NOT_FOUND", try std.fmt.allocPrint(allocator, "cannot search \"{s}\": not found", .{root}));
    }
    if (root_kind.? != .directory) {
        return fsFailure(allocator, "FS_NOT_DIRECTORY", try std.fmt.allocPrint(allocator, "cannot search \"{s}\": not a directory", .{root}));
    }

    var patterns: std.ArrayListUnmanaged([]const u8) = .empty;
    try expandBraces(allocator, pattern, &patterns);

    var entries: std.ArrayListUnmanaged(GlobEntry) = .empty;
    var walk = GlobWalk{
        .allocator = allocator,
        .cwd = cwd,
        .root = root,
        .patterns = patterns.items,
        .pattern_has_separator = std.mem.indexOfAny(u8, pattern, "/\\") != null,
        .entries = &entries,
    };
    try globWalk(&walk, root);

    std.mem.sort(GlobEntry, entries.items, {}, lessThanEntry);
    return successText(allocator, try formatGlob(self, allocator, entries.items));
}

fn globWalk(walk: *GlobWalk, dir_abs: []const u8) !void {
    var dir = fs_compat.openDirPath(dir_abs, .{ .iterate = true }) catch return;
    defer dir.close();
    var iterator = dir.iterate();
    var children: std.ArrayListUnmanaged(Child) = .empty;
    while (try iterator.next()) |entry| {
        if (entry.kind != .file and entry.kind != .directory) continue;
        if (entry.kind == .directory and isVcsDir(entry.name)) continue;
        try children.append(walk.allocator, .{
            .name = try walk.allocator.dupe(u8, entry.name),
            .is_dir = entry.kind == .directory,
        });
    }
    std.mem.sort(Child, children.items, {}, lessThanChild);
    for (children.items) |child| {
        const absolute = try childPath(walk.allocator, dir_abs, child.name);
        if (child.is_dir) {
            try globWalk(walk, absolute);
            continue;
        }
        const target = if (walk.pattern_has_separator) blk: {
            const relative = compat.fs.path.relative(walk.allocator, walk.root, absolute) catch break :blk null;
            break :blk try toMatchPath(walk.allocator, relative);
        } else child.name;
        if (target == null) continue;
        if (!matchesAny(walk.patterns, target.?)) continue;

        const stat = statFile(absolute) catch continue;
        try walk.entries.append(walk.allocator, .{
            .display = try relativeDisplay(walk.allocator, walk.cwd, absolute),
            .mtime = stat.mtime,
        });
    }
}

fn statFile(path: []const u8) !compat.fs.File.Stat {
    const file = try fs_compat.openPath(path, .{});
    defer file.close();
    return file.stat();
}

fn formatGlob(self: *Builtins, allocator: Allocator, entries: []const GlobEntry) ![]const u8 {
    if (entries.len == 0) return render.glob.no_files;

    if (entries.len <= glob_max_results) return joinDisplayPaths(allocator, entries, entries.len);

    const page = try joinDisplayPaths(allocator, entries, glob_max_results);
    const complete = try joinDisplayPaths(allocator, entries, entries.len);
    const locator = saveSpill(self, allocator, "glob", complete) catch null;
    const recovery = if (locator) |path|
        try std.fmt.allocPrint(allocator, render.glob.recovery_saved, .{ path, spill_retrieval_hint })
    else
        render.glob.recovery_unsaved;
    return std.fmt.allocPrint(allocator, render.glob.page, .{ page, glob_max_results, entries.len, ".", recovery });
}

fn joinDisplayPaths(allocator: Allocator, entries: []const GlobEntry, count: usize) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (entries[0..count], 0..) |entry, index| {
        if (index > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, entry.display);
    }
    return out.toOwnedSlice(allocator);
}

fn isVcsDir(name: []const u8) bool {
    for (vcs_dir_names) |vcs| {
        if (std.mem.eql(u8, name, vcs)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Shared walking / globbing

const Child = struct {
    name: []const u8,
    is_dir: bool,
};

fn lessThanChild(_: void, a: Child, b: Child) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn lessThanEntry(_: void, a: GlobEntry, b: GlobEntry) bool {
    if (a.mtime != b.mtime) return a.mtime > b.mtime; // modification-time order, newest first
    return std.mem.lessThan(u8, a.display, b.display);
}

fn toMatchPath(allocator: Allocator, path: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*byte| {
        if (byte.* == std.fs.path.sep) byte.* = '/';
    }
    return out;
}

fn matchesAny(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |pattern| {
        if (globMatch(pattern, path)) return true;
    }
    return false;
}

/// Expand `{a,b}` alternation once per search, so the matcher stays allocation
/// free. Nested braces expand recursively; a missing `}` leaves the pattern as
/// written.
fn expandBraces(allocator: Allocator, pattern: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var depth: usize = 0;
    var open: ?usize = null;
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        switch (pattern[index]) {
            '{' => {
                if (depth == 0) open = index;
                depth += 1;
            },
            '}' => {
                if (depth == 0) continue;
                depth -= 1;
                if (depth != 0) continue;
                const start = open.?;
                const inner = pattern[start + 1 .. index];
                const prefix = pattern[0..start];
                const suffix = pattern[index + 1 ..];
                var alt_start: usize = 0;
                var nested: usize = 0;
                var cursor: usize = 0;
                while (cursor <= inner.len) : (cursor += 1) {
                    const at_comma = cursor < inner.len and inner[cursor] == ',' and nested == 0;
                    if (cursor == inner.len or at_comma) {
                        const alternative = inner[alt_start..cursor];
                        const combined = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, alternative, suffix });
                        try expandBraces(allocator, combined, out);
                        alt_start = cursor + 1;
                    } else if (inner[cursor] == '{') {
                        nested += 1;
                    } else if (inner[cursor] == '}') {
                        if (nested > 0) nested -= 1;
                    }
                }
                return;
            },
            else => {},
        }
    }
    try out.append(allocator, try allocator.dupe(u8, pattern));
}

/// Shell-style glob: `*` stays inside one path segment, `**` crosses
/// separators, `?` is one non-separator byte, `[a-z]`/`[!a-z]` are classes.
/// shortcut: byte-oriented, exponential backtracking on adversarial patterns.
fn globMatch(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;

    if (std.mem.startsWith(u8, pattern, "**")) {
        var rest = pattern[2..];
        if (rest.len > 0 and rest[0] == '/') {
            rest = rest[1..];
            if (globMatch(rest, path)) return true;
            var index: usize = 0;
            while (index < path.len) : (index += 1) {
                if (path[index] == '/' and globMatch(rest, path[index + 1 ..])) return true;
            }
            return false;
        }
        var index: usize = 0;
        while (true) {
            if (globMatch(rest, path[index..])) return true;
            if (index == path.len) return false;
            index += 1;
        }
    }

    switch (pattern[0]) {
        '*' => {
            var index: usize = 0;
            while (true) {
                if (globMatch(pattern[1..], path[index..])) return true;
                if (index == path.len or path[index] == '/') return false;
                index += 1;
            }
        },
        '?' => {
            return path.len > 0 and path[0] != '/' and globMatch(pattern[1..], path[1..]);
        },
        '[' => {
            const close = std.mem.indexOfScalar(u8, pattern, ']') orelse
                return path.len > 0 and pattern[0] == path[0] and globMatch(pattern[1..], path[1..]);
            if (path.len == 0 or path[0] == '/') return false;
            const class = pattern[1..close];
            var negate = false;
            var index: usize = 0;
            if (class.len > 0 and (class[0] == '!' or class[0] == '^')) {
                negate = true;
                index = 1;
            }
            var matched = false;
            while (index < class.len) {
                if (index + 2 < class.len and class[index + 1] == '-') {
                    if (path[0] >= class[index] and path[0] <= class[index + 2]) matched = true;
                    index += 3;
                } else {
                    if (class[index] == path[0]) matched = true;
                    index += 1;
                }
            }
            if (matched == negate) return false;
            return globMatch(pattern[close + 1 ..], path[1..]);
        },
        else => {
            return path.len > 0 and pattern[0] == path[0] and globMatch(pattern[1..], path[1..]);
        },
    }
}

// ---------------------------------------------------------------------------
// Spill

fn saveSpill(self: *Builtins, allocator: Allocator, kind: []const u8, content: []const u8) ![]const u8 {
    const directory = try resolvePath(allocator, self.cwd, self.spill_dir);
    try fs_compat.makePath(directory);
    const sequence = self.spill_seq.fetchAdd(1, .monotonic);
    const name = try std.fmt.allocPrint(allocator, "{s}-results-{d}.txt", .{ kind, sequence });
    const path = try std.fs.path.join(allocator, &.{ directory, name });
    const file = try fs_compat.createPath(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
    try file.sync();
    return path;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const TestTools = struct {
    allocator: Allocator,
    base: []const u8,
    spill: []const u8,
    builtins: Builtins,

    fn init(allocator: Allocator, tmp: *std.testing.TmpDir) !TestTools {
        const base = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
        const spill = try std.fs.path.join(allocator, &.{ base, "spill dir" });
        return .{
            .allocator = allocator,
            .base = base,
            .spill = spill,
            .builtins = .{ .cwd = base, .spill_dir = spill },
        };
    }

    fn writeFile(self: *TestTools, relative: []const u8, bytes: []const u8) ![]const u8 {
        const path = try std.fs.path.join(self.allocator, &.{ self.base, relative });
        if (std.fs.path.dirname(path)) |parent| try fs_compat.makePath(parent);
        const file = try fs_compat.createPath(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
        return path;
    }

    fn readFile(self: *TestTools, relative: []const u8) ![]const u8 {
        const path = try std.fs.path.join(self.allocator, &.{ self.base, relative });
        return fs_compat.readFileAlloc(compat.fs.cwd(), self.allocator, path, max_file_bytes);
    }

    fn readFileAbsolute(self: *TestTools, path: []const u8) ![]const u8 {
        return fs_compat.readFileAlloc(compat.fs.cwd(), self.allocator, path, max_file_bytes);
    }

    fn setMtime(self: *TestTools, relative: []const u8, nanos: i128) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.base, relative });
        const file = try fs_compat.openPath(path, .{});
        defer file.close();
        try file.updateTimes(nanos, nanos);
    }
};

fn objectWith(allocator: Allocator, pairs: []const struct { []const u8, Value }) !Value {
    var object: std.json.ObjectMap = .empty;
    for (pairs) |pair| try object.put(allocator, pair[0], pair[1]);
    return .{ .object = object };
}

fn argsFilePath(allocator: Allocator, path: []const u8) !Value {
    return objectWith(allocator, &.{.{ "file_path", .{ .string = path } }});
}

fn resultText(result: registry.ToolResult) []const u8 {
    return switch (result) {
        .success => |value| value.content[0].text,
        .failure => |value| value.content[0].text,
    };
}

fn expectSuccess(result: registry.ToolResult) ![]const u8 {
    try testing.expect(!result.isError());
    return resultText(result);
}

fn expectFailure(result: registry.ToolResult, code: []const u8) ![]const u8 {
    const failure_result = switch (result) {
        .failure => |value| value,
        .success => return error.ExpectedToolFailure,
    };
    try testing.expectEqualStrings(code, failure_result.error_info.code);
    return resultText(result);
}

fn callRead(tools: *Builtins, allocator: Allocator, args: Value) !registry.ToolResult {
    return readHandler(@ptrCast(tools), allocator, args);
}

fn callWrite(tools: *Builtins, allocator: Allocator, args: Value) !registry.ToolResult {
    return writeHandler(@ptrCast(tools), allocator, args);
}

fn callEdit(tools: *Builtins, allocator: Allocator, args: Value) !registry.ToolResult {
    return editHandler(@ptrCast(tools), allocator, args);
}

fn callGrep(tools: *Builtins, allocator: Allocator, args: Value) !registry.ToolResult {
    return grepHandler(@ptrCast(tools), allocator, args);
}

fn callGlob(tools: *Builtins, allocator: Allocator, args: Value) !registry.ToolResult {
    return globHandler(@ptrCast(tools), allocator, args);
}

test "builtins register the five generated filesystem schemas" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tools = try TestTools.init(arena, &tmp);

    var reg = registry.Registry.init();
    defer reg.deinit(testing.allocator);
    try tools.builtins.register(&reg, testing.allocator);

    try testing.expectEqualStrings(generated.read.name, reg.get("read").?.name);
    try testing.expectEqualStrings(generated.read.description, reg.get("read").?.description);
    try testing.expectEqualStrings(generated.write.input_schema_json, reg.get("write").?.input_schema_json);
    try testing.expectEqualStrings(generated.edit.description, reg.get("edit").?.description);
    try testing.expectEqualStrings(generated.grep.name, reg.get("grep").?.name);
    try testing.expectEqualStrings(generated.glob.input_schema_json, reg.get("glob").?.input_schema_json);
    try testing.expect(reg.get("bash") == null);
}

test "read returns a numbered window with continuation and end-of-file footers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tools = try TestTools.init(arena, &tmp);

    const path = try tools.writeFile("dir with space/file name.txt", "alpha\nbeta\ngamma\n");

    const full = try expectSuccess(try callRead(&tools.builtins, arena, try argsFilePath(arena, "dir with space/file name.txt")));
    const expected_full = try std.fmt.allocPrint(arena, render.read.envelope, .{
        path,
        "1: alpha\n2: beta\n3: gamma\n\n(End of file - total 3 lines)",
    });
    try testing.expectEqualStrings(expected_full, full);

    const window = try expectSuccess(try callRead(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = "dir with space/file name.txt" } },
        .{ "offset", .{ .integer = 2 } },
        .{ "limit", .{ .integer = 1 } },
    })));
    const expected_window = try std.fmt.allocPrint(arena, render.read.envelope, .{
        path,
        "2: beta\n\n(Showing lines 2-2 of 3. Use offset=3 to continue.)",
    });
    try testing.expectEqualStrings(expected_window, window);

    const out_of_range = try expectFailure(try callRead(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = "dir with space/file name.txt" } },
        .{ "offset", .{ .integer = 9 } },
    })), "FS_NOT_FOUND");
    try testing.expect(std.mem.indexOf(u8, out_of_range, "offset 9 is out of range") != null);
    try testing.expect(std.mem.indexOf(u8, out_of_range, "(3 lines)") != null);
}

test "read caps long lines and the 50 KiB output budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tools = try TestTools.init(arena, &tmp);

    const long_line = try arena.alloc(u8, 2100);
    @memset(long_line, 'x');
    const long_text = try std.fmt.allocPrint(arena, "{s}\nshort\n", .{long_line});
    _ = try tools.writeFile("long.txt", long_text);

    const truncated_line = try expectSuccess(try callRead(&tools.builtins, arena, try argsFilePath(arena, "long.txt")));
    try testing.expect(std.mem.indexOf(u8, truncated_line, "... (line truncated to 2000 chars)") != null);
    try testing.expect(std.mem.indexOf(u8, truncated_line, "2: short") != null);
    try testing.expect(std.mem.indexOf(u8, truncated_line, "(End of file - total 2 lines)") != null);

    var big: std.ArrayListUnmanaged(u8) = .empty;
    for (0..1200) |_| try big.appendSlice(arena, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n");
    _ = try tools.writeFile("big.txt", big.items);

    const capped = try expectSuccess(try callRead(&tools.builtins, arena, try argsFilePath(arena, "big.txt")));
    try testing.expect(std.mem.indexOf(u8, capped, "(Output capped. Showing lines 1-") != null);
    try testing.expect(std.mem.indexOf(u8, capped, "Use offset=") != null);
    try testing.expect(std.mem.indexOf(u8, capped, "(End of file") == null);

    const invalid_limit = try expectFailure(try callRead(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = "big.txt" } },
        .{ "limit", .{ .integer = 2001 } },
    })), "INVALID_ARGUMENT");
    try testing.expect(std.mem.indexOf(u8, invalid_limit, "limit must be less than or equal to 2000") != null);
}

test "write creates parents, reports Created/Updated, and rejects escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tools = try TestTools.init(arena, &tmp);

    const relative = "nested dir with space/deeper/file name.txt";
    const created = try expectSuccess(try callWrite(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = relative } },
        .{ "content", .{ .string = "first" } },
    })));
    const created_path = try std.fs.path.join(arena, &.{ tools.base, relative });
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, render.write.output_envelope, .{ created_path, render.write.created_verb }), created);
    try testing.expectEqualStrings("first", try tools.readFile(relative));

    const updated = try expectSuccess(try callWrite(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = relative } },
        .{ "content", .{ .string = "second" } },
    })));
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, render.write.output_envelope, .{ created_path, render.write.updated_verb }), updated);
    try testing.expectEqualStrings("second", try tools.readFile(relative));

    const escaped = try expectFailure(try callWrite(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = "../escape.txt" } },
        .{ "content", .{ .string = "nope" } },
    })), "FS_SANDBOX_DENIED");
    try testing.expect(std.mem.indexOf(u8, escaped, "outside the session working directory") != null);
}

test "edit replaces one exact match, reports ambiguity, and rejects bad arguments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tools = try TestTools.init(arena, &tmp);

    const path = try tools.writeFile("edit me.txt", "hello world\nhello again\n");
    _ = path;

    const single = try expectSuccess(try callEdit(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = "edit me.txt" } },
        .{ "old_string", .{ .string = "hello world" } },
        .{ "new_string", .{ .string = "hi world" } },
    })));
    try testing.expect(std.mem.endsWith(u8, single, "has been updated successfully."));
    try testing.expectEqualStrings("hi world\nhello again\n", try tools.readFile("edit me.txt"));

    _ = try tools.writeFile("edit me.txt", "hello world\nhello again\n");
    const ambiguous = try expectFailure(try callEdit(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = "edit me.txt" } },
        .{ "old_string", .{ .string = "hello" } },
        .{ "new_string", .{ .string = "bye" } },
    })), "FS_AMBIGUOUS_EDIT");
    try testing.expect(std.mem.indexOf(u8, ambiguous, "old_string matched 2 times") != null);
    try testing.expectEqualStrings("hello world\nhello again\n", try tools.readFile("edit me.txt"));

    const missing = try expectFailure(try callEdit(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = "edit me.txt" } },
        .{ "old_string", .{ .string = "absent text" } },
        .{ "new_string", .{ .string = "x" } },
    })), "FS_EDIT_NOT_FOUND");
    try testing.expect(std.mem.indexOf(u8, missing, "old_string was not found in") != null);

    _ = try expectFailure(try callEdit(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = "edit me.txt" } },
        .{ "old_string", .{ .string = "" } },
        .{ "new_string", .{ .string = "x" } },
    })), "INVALID_ARGUMENT");

    _ = try expectFailure(try callEdit(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = "edit me.txt" } },
        .{ "old_string", .{ .string = "same" } },
        .{ "new_string", .{ .string = "same" } },
    })), "INVALID_ARGUMENT");

    const escaped = try expectFailure(try callEdit(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = "../outside.txt" } },
        .{ "old_string", .{ .string = "a" } },
        .{ "new_string", .{ .string = "b" } },
    })), "FS_SANDBOX_DENIED");
    try testing.expect(std.mem.indexOf(u8, escaped, "outside the session working directory") != null);
}

test "edit replace_all rewrites every occurrence and preserves CRLF" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tools = try TestTools.init(arena, &tmp);

    _ = try tools.writeFile("win.txt", "one\r\none\r\n");
    const all = try expectSuccess(try callEdit(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = "win.txt" } },
        .{ "old_string", .{ .string = "one" } },
        .{ "new_string", .{ .string = "two" } },
        .{ "replace_all", .{ .bool = true } },
    })));
    try testing.expect(std.mem.endsWith(u8, all, "All occurrences were successfully replaced."));
    try testing.expectEqualStrings("two\r\ntwo\r\n", try tools.readFile("win.txt"));
}

test "grep groups matches by file, honors include, and reports no matches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tools = try TestTools.init(arena, &tmp);

    _ = try tools.writeFile("a dir/one.txt", "needle here\nother\nneedle again\n");
    _ = try tools.writeFile("two.log", "needle\n");
    _ = try tools.writeFile("binary.bin", "needle\x00payload");

    const found = try expectSuccess(try callGrep(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "pattern", .{ .string = "needle" } },
    })));
    try testing.expectEqualStrings(
        "Found 3 matches\n\na dir/one.txt\nLine 1: needle here\nLine 3: needle again\n\ntwo.log\nLine 1: needle",
        found,
    );

    const filtered = try expectSuccess(try callGrep(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "pattern", .{ .string = "needle" } },
        .{ "include", .{ .string = "*.log" } },
    })));
    try testing.expectEqualStrings("Found 1 match\n\ntwo.log\nLine 1: needle", filtered);

    const none = try expectSuccess(try callGrep(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "pattern", .{ .string = "missing-token" } },
    })));
    try testing.expectEqualStrings(render.grep.no_matches, none);
}

test "grep caps at 250 matches, previews 2000-byte lines, and spills the complete result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tools = try TestTools.init(arena, &tmp);

    var many: std.ArrayListUnmanaged(u8) = .empty;
    for (0..300) |index| try many.appendSlice(arena, try std.fmt.allocPrint(arena, "hit line {d}\n", .{index}));
    _ = try tools.writeFile("many.txt", many.items);

    const capped = try expectSuccess(try callGrep(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "pattern", .{ .string = "hit" } },
    })));
    try testing.expect(std.mem.indexOf(u8, capped, "Found 250 of 300 matches") != null);
    try testing.expect(std.mem.indexOf(u8, capped, "Full grep result stored at: ") != null);
    try testing.expect(std.mem.indexOf(u8, capped, spill_retrieval_hint) != null);
    try testing.expect(std.mem.endsWith(u8, capped, ")"));

    const spill_path = try std.fs.path.join(arena, &.{ tools.spill, "grep-results-0.txt" });
    const spilled = try tools.readFileAbsolute(spill_path);
    try testing.expect(std.mem.indexOf(u8, spilled, "Found 300 matches") != null);
    try testing.expectEqual(@as(usize, 300), std.mem.count(u8, spilled, "Line "));

    const long_line = try arena.alloc(u8, 2500);
    @memset(long_line, 'q');
    const long_content = try std.fmt.allocPrint(arena, "hit{s}\n", .{long_line});
    _ = try tools.writeFile("longline.txt", long_content);
    const previewed = try expectSuccess(try callGrep(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "pattern", .{ .string = "hit" } },
        .{ "include", .{ .string = "longline.txt" } },
    })));
    try testing.expect(std.mem.indexOf(u8, previewed, "hitqqq") != null);
    try testing.expect(std.mem.indexOf(u8, previewed, " (line truncated)") != null);
    try testing.expect(std.mem.indexOf(u8, previewed, long_line) == null);
}

test "glob matches basenames at any depth and sorts newest first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tools = try TestTools.init(arena, &tmp);

    _ = try tools.writeFile("src/old.zig", "old");
    _ = try tools.writeFile("src/deep/new.zig", "new");
    _ = try tools.writeFile("docs/readme.md", "doc");
    try tools.setMtime("src/old.zig", 1_000);
    try tools.setMtime("src/deep/new.zig", 3_000);
    _ = try tools.writeFile("middle.zig", "mid");
    try tools.setMtime("middle.zig", 2_000);

    const found = try expectSuccess(try callGlob(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "pattern", .{ .string = "*.zig" } },
    })));
    try testing.expectEqualStrings("src/deep/new.zig\nmiddle.zig\nsrc/old.zig", found);

    const anchored = try expectSuccess(try callGlob(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "pattern", .{ .string = "src/*.zig" } },
    })));
    try testing.expectEqualStrings("src/old.zig", anchored);

    const none = try expectSuccess(try callGlob(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "pattern", .{ .string = "*.rs" } },
    })));
    try testing.expectEqualStrings(render.glob.no_files, none);
}

test "glob caps at 100 paths and spills the complete sorted list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tools = try TestTools.init(arena, &tmp);

    for (0..120) |index| {
        const name = try std.fmt.allocPrint(arena, "many dir/f{d:0>3}.txt", .{index});
        _ = try tools.writeFile(name, "x");
    }

    const capped = try expectSuccess(try callGlob(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "pattern", .{ .string = "*.txt" } },
    })));
    try testing.expect(std.mem.indexOf(u8, capped, "(Showing 100 of 120 paths. Full sorted result stored at: ") != null);
    try testing.expect(std.mem.indexOf(u8, capped, spill_retrieval_hint) != null);

    const spill_path = try std.fs.path.join(arena, &.{ tools.spill, "glob-results-0.txt" });
    const spilled = try tools.readFileAbsolute(spill_path);
    try testing.expectEqual(@as(usize, 120), std.mem.count(u8, spilled, ".txt"));
}

test "a 64 KiB write and read round-trips without leaking" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tools = try TestTools.init(arena, &tmp);

    var content: std.ArrayListUnmanaged(u8) = .empty;
    for (0..2048) |index| {
        try content.appendSlice(arena, try std.fmt.allocPrint(arena, "line {d:0>4} of the big file payload\n", .{index}));
    }
    try testing.expect(content.items.len >= 64 * 1024);

    _ = try expectSuccess(try callWrite(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "file_path", .{ .string = "big file.txt" } },
        .{ "content", .{ .string = content.items } },
    })));
    try testing.expectEqual(content.items.len, (try tools.readFile("big file.txt")).len);

    const first = try expectSuccess(try callRead(&tools.builtins, arena, try argsFilePath(arena, "big file.txt")));
    try testing.expect(std.mem.indexOf(u8, first, "1: line 0000") != null);
    try testing.expect(std.mem.indexOf(u8, first, "(Output capped. Showing lines 1-") != null);
}

test "a path argument anchors grep and glob to a subtree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tools = try TestTools.init(arena, &tmp);

    _ = try tools.writeFile("sub/inside.txt", "needle\n");
    _ = try tools.writeFile("outside.txt", "needle\n");

    const grep = try expectSuccess(try callGrep(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "pattern", .{ .string = "needle" } },
        .{ "path", .{ .string = "sub" } },
    })));
    try testing.expectEqualStrings("Found 1 match\n\nsub/inside.txt\nLine 1: needle", grep);

    const glob = try expectSuccess(try callGlob(&tools.builtins, arena, try objectWith(arena, &.{
        .{ "pattern", .{ .string = "*.txt" } },
        .{ "path", .{ .string = "sub" } },
    })));
    try testing.expectEqualStrings("sub/inside.txt", glob);
}
