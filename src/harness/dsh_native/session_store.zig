//! DSH_HOME path encoding and session mapping files.
//!
//! The path rules mirror dsh's `session-persistence-jsonl` so both harnesses
//! read the same artifacts:
//!   $DSH_HOME/sessions/--<project-key>--/<encoded-session-id>/session.v4.jsonl
//! Project keys and session ids are single safe path segments: `[A-Za-z0-9._-]`
//! stays literal, everything else becomes `~XXXX` per UTF-16 code unit.
//! `session.lock` in the session directory is the cross-process write lease.

const std = @import("std");
const compat = @import("compat");
const fs_compat = @import("../../fs_compat.zig");
const json = @import("json.zig");
const session_log = @import("session_log.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const log_basename = "session.v4.jsonl";
pub const lock_basename = "session.lock";

/// `$DSH_HOME/sessions`.
pub fn sessionRootAlloc(allocator: Allocator, dsh_home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ dsh_home, "sessions" });
}

/// Encode one arbitrary string as a single safe path segment (dsh's
/// `encodeSegment`). Empty input is refused; `.` and `..` are escaped.
pub fn encodeSegmentAlloc(allocator: Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0) return error.EmptySegment;
    if (std.mem.eql(u8, raw, ".")) return allocator.dupe(u8, "~002E");
    if (std.mem.eql(u8, raw, "..")) return allocator.dupe(u8, "~002E~002E");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var units = json.Utf16CodeUnits{ .bytes = raw };
    while (units.next()) |unit| {
        if (isSafeUnit(unit)) {
            try out.append(allocator, @intCast(unit));
        } else {
            try appendEscapedUnit(allocator, &out, unit);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Human-navigable project directory key (dsh's `projectKey`): separators and
/// drive colons collapse to `-`, unsafe units escape as `~XXXX`, leading `-`
/// is stripped, and the slug is bounded to 251 units.
pub fn projectKeyAlloc(allocator: Allocator, cwd: ?[]const u8) ![]u8 {
    if (cwd == null) return allocator.dupe(u8, "_no-cwd");

    var readable: std.ArrayListUnmanaged(u8) = .empty;
    defer readable.deinit(allocator);
    var separator_run = false;
    var units = json.Utf16CodeUnits{ .bytes = cwd.? };
    while (units.next()) |unit| {
        if (unit == '/' or unit == '\\' or unit == ':') {
            if (!separator_run) try readable.append(allocator, '-');
            separator_run = true;
        } else {
            if (isSafeUnit(unit)) {
                try readable.append(allocator, @intCast(unit));
            } else {
                try appendEscapedUnit(allocator, &readable, unit);
            }
            separator_run = false;
        }
    }

    var slug: []const u8 = readable.items;
    while (slug.len > 0 and slug[0] == '-') slug = slug[1..];
    if (slug.len > 251) slug = slug[0..251];
    if (slug.len == 0) slug = "root";
    return std.fmt.allocPrint(allocator, "--{s}--", .{slug});
}

/// `$DSH_HOME/sessions/<project-key>/<encoded-id>`.
pub fn sessionDirAlloc(allocator: Allocator, dsh_home: []const u8, cwd: ?[]const u8, id: []const u8) ![]u8 {
    const root = try sessionRootAlloc(allocator, dsh_home);
    defer allocator.free(root);
    const project = try projectKeyAlloc(allocator, cwd);
    defer allocator.free(project);
    const segment = try encodeSegmentAlloc(allocator, id);
    defer allocator.free(segment);
    return std.fs.path.join(allocator, &.{ root, project, segment });
}

/// Current generation's append target.
pub fn logPathAlloc(allocator: Allocator, dsh_home: []const u8, cwd: ?[]const u8, id: []const u8) ![]u8 {
    const dir = try sessionDirAlloc(allocator, dsh_home, cwd, id);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, log_basename });
}

/// Create a session log under DSH_HOME and take its single-writer lease.
pub fn createLog(allocator: Allocator, dsh_home: []const u8, cwd: ?[]const u8, id: []const u8, header: types.Header) !session_log.Log {
    const path = try logPathAlloc(allocator, dsh_home, cwd, id);
    defer allocator.free(path);
    return session_log.Log.create(allocator, path, header);
}

/// Reopen a session log under DSH_HOME, repairing a torn tail if needed.
pub fn openLog(allocator: Allocator, dsh_home: []const u8, cwd: ?[]const u8, id: []const u8) !session_log.Log {
    const path = try logPathAlloc(allocator, dsh_home, cwd, id);
    defer allocator.free(path);
    return session_log.Log.open(allocator, path);
}

/// Write `{"sessionId":"…"}` (same shape the dsh sidecar persists).
pub fn saveMapping(allocator: Allocator, path: []const u8, session_id: []const u8) !void {
    const contents = try std.json.Stringify.valueAlloc(allocator, .{ .sessionId = session_id }, .{});
    defer allocator.free(contents);
    const file = try fs_compat.createPath(path, .{});
    defer file.close();
    try file.writeAll(contents);
    try file.sync();
}

/// Load a mapping file; null when it is absent.
pub fn loadMapping(allocator: Allocator, path: []const u8) !?[]u8 {
    const contents = fs_compat.readFileAlloc(compat.fs.cwd(), allocator, path, 4096) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(contents);

    const Persisted = struct { sessionId: []const u8 };
    const parsed = std.json.parseFromSlice(Persisted, allocator, contents, .{}) catch
        return error.InvalidMappingFile;
    defer parsed.deinit();
    return try allocator.dupe(u8, parsed.value.sessionId);
}

fn isSafeUnit(unit: u16) bool {
    return (unit >= 'A' and unit <= 'Z') or
        (unit >= 'a' and unit <= 'z') or
        (unit >= '0' and unit <= '9') or
        unit == '.' or unit == '_' or unit == '-';
}

fn appendEscapedUnit(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), unit: u16) !void {
    var buffer: [6]u8 = undefined;
    const escaped = std.fmt.bufPrint(&buffer, "~{X:0>4}", .{unit}) catch unreachable;
    try out.appendSlice(allocator, escaped);
}

test "encodeSegment mirrors dsh path escaping" {
    const allocator = std.testing.allocator;

    const plain = try encodeSegmentAlloc(allocator, "sess-1.a_b");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("sess-1.a_b", plain);

    const dots = try encodeSegmentAlloc(allocator, "..");
    defer allocator.free(dots);
    try std.testing.expectEqualStrings("~002E~002E", dots);

    // Only the exact segments "." and ".." are special-cased; dots inside a
    // longer segment stay literal, exactly like dsh's encodeSegment.
    const traversal = try encodeSegmentAlloc(allocator, "../x~y");
    defer allocator.free(traversal);
    try std.testing.expectEqualStrings("..~002Fx~007Ey", traversal);

    const bmp = try encodeSegmentAlloc(allocator, "é");
    defer allocator.free(bmp);
    try std.testing.expectEqualStrings("~00E9", bmp);

    const astral = try encodeSegmentAlloc(allocator, "😀");
    defer allocator.free(astral);
    try std.testing.expectEqualStrings("~D83D~DE00", astral);
}

test "projectKey mirrors dsh directory naming" {
    const allocator = std.testing.allocator;

    const none = try projectKeyAlloc(allocator, null);
    defer allocator.free(none);
    try std.testing.expectEqualStrings("_no-cwd", none);

    const posix = try projectKeyAlloc(allocator, "/home/user/project");
    defer allocator.free(posix);
    try std.testing.expectEqualStrings("--home-user-project--", posix);

    const windows = try projectKeyAlloc(allocator, "C:\\work\\example.com");
    defer allocator.free(windows);
    try std.testing.expectEqualStrings("--C-work-example.com--", windows);

    const separators_only = try projectKeyAlloc(allocator, "///");
    defer allocator.free(separators_only);
    try std.testing.expectEqualStrings("--root--", separators_only);
}

test "store creates and reopens a log under DSH_HOME" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(home);

    const header = types.Header{
        .id = "session-1",
        .created_at = 1_700_000_000_000,
        .cwd = "/work/example.com",
    };
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"turn\":1}", .{});
    defer parsed.deinit();

    var log = try createLog(allocator, home, header.cwd, header.id, header);
    _ = try log.append("turn/start", parsed.value, .{ .time_ms = 1 });
    log.close();

    var reopened = try openLog(allocator, home, header.cwd, header.id);
    try std.testing.expectEqual(@as(u64, 1), reopened.next_seq);
    _ = try reopened.append("turn/end", parsed.value, .{ .time_ms = 2 });
    reopened.close();

    const path = try logPathAlloc(allocator, home, header.cwd, header.id);
    defer allocator.free(path);
    const file = try fs_compat.openPath(path, .{});
    file.close();
}

test "log path and mapping file round-trip" {
    const allocator = std.testing.allocator;

    const path = try logPathAlloc(allocator, "/tmp/dsh-home", "/work/example.com", "session-1");
    defer allocator.free(path);
    try std.testing.expectEqualStrings(
        "/tmp/dsh-home/sessions/--work-example.com--/session-1/session.v4.jsonl",
        path,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const mapping = try std.fs.path.join(allocator, &.{ base, "session.json" });
    defer allocator.free(mapping);

    try saveMapping(allocator, mapping, "session-1");
    const loaded = try loadMapping(allocator, mapping);
    defer if (loaded) |value| allocator.free(value);
    try std.testing.expectEqualStrings("session-1", loaded.?);

    const missing = try std.fs.path.join(allocator, &.{ base, "missing.json" });
    defer allocator.free(missing);
    try std.testing.expect((try loadMapping(allocator, missing)) == null);
}
