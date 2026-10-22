//! Append-only dsh v4 session log.
//!
//! Layout: one newline-terminated header record, then one newline-terminated
//! event envelope per line (`{type,seq,time,data,...}`). `seq` is dense from
//! zero. A final record without its newline is a torn tail: it is never
//! interpreted, and the writer truncates it before the first new append.
//!
//! Corruption policy follows the design's fail-closed decision (#7/#8): only
//! format version 4 is read, unknown event types must carry `ignorable: true`,
//! and nothing is silently skipped. v3 logs must be migrated with dsh.

const std = @import("std");
const compat = @import("compat");
const fs_compat = @import("../../fs_compat.zig");
const json = @import("json.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

/// Refuse logs larger than this instead of allocating unbounded memory.
pub const max_log_bytes: usize = 256 * 1024 * 1024;

pub const AppendOptions = struct {
    /// Fixed event time; production callers omit it to use the wall clock.
    time_ms: ?i64 = null,
    surface_op: ?types.SurfaceOp = null,
    source_event_seqs: ?[]const u64 = null,
    ignorable: bool = false,
};

/// One decoded log. All strings and JSON values are owned by `arena`.
pub const ReadResult = struct {
    arena: std.heap.ArenaAllocator,
    header: types.Header,
    events: []types.Event,
    /// Byte offset of an uncommitted final record, when the file was torn.
    torn_truncate_to: ?u64,

    pub fn deinit(self: *ReadResult) void {
        self.arena.deinit();
    }
};

/// An open writer holding the session directory's kernel write lock.
pub const Log = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    file: compat.fs.File,
    lock_file: compat.fs.File,
    header: types.Header,
    next_seq: u64,
    path: []const u8,

    /// Create a new log, refusing an existing artifact or a held lock.
    pub fn create(allocator: Allocator, path: []const u8, header: types.Header) !Log {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const path_copy = try arena_allocator.dupe(u8, path);
        const dir = std.fs.path.dirname(path_copy) orelse ".";
        try fs_compat.makePath(dir);

        const lock_file = try acquireLock(arena_allocator, dir);
        errdefer lock_file.close();

        const file = fs_compat.createPath(path_copy, .{ .read = true, .truncate = false, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.SessionExists,
            else => return err,
        };
        errdefer file.close();

        const line = try json.headerLineAlloc(allocator, header);
        defer allocator.free(line);
        try file.writeAll(line);
        try file.sync();

        return .{
            .allocator = allocator,
            .arena = arena,
            .file = file,
            .lock_file = lock_file,
            .header = try copyHeader(arena_allocator, header),
            .next_seq = 0,
            .path = path_copy,
        };
    }

    /// Reopen an existing log: validate, repair a torn tail, continue appending.
    pub fn open(allocator: Allocator, path: []const u8) !Log {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const path_copy = try arena_allocator.dupe(u8, path);
        const dir = std.fs.path.dirname(path_copy) orelse ".";
        const lock_file = try acquireLock(arena_allocator, dir);
        errdefer lock_file.close();

        var result = try readLog(allocator, path_copy);
        defer result.deinit();
        if (result.torn_truncate_to) |offset| {
            try truncateFile(path_copy, offset);
        }

        const file = try fs_compat.openPath(path_copy, .{ .mode = .read_write });
        errdefer file.close();
        try file.seekFromEnd(0);

        return .{
            .allocator = allocator,
            .arena = arena,
            .file = file,
            .lock_file = lock_file,
            .header = try copyHeader(arena_allocator, result.header),
            .next_seq = @intCast(result.events.len),
            .path = path_copy,
        };
    }

    /// Append one event, fsync it, and return its sequence number.
    pub fn append(self: *Log, event_type: []const u8, data: std.json.Value, opts: AppendOptions) !u64 {
        if (!isKnownEventType(event_type) and !opts.ignorable) return error.UnsupportedEventType;
        const event = types.Event{
            .event_type = event_type,
            .seq = self.next_seq,
            .time_ms = opts.time_ms orelse compat.time.milliTimestamp(),
            .data = data,
            .surface_op = opts.surface_op,
            .source_event_seqs = opts.source_event_seqs,
            .ignorable = opts.ignorable,
        };
        try validateSurface(self.allocator, event);

        const line = try json.eventLineAlloc(self.allocator, event);
        defer self.allocator.free(line);
        try self.file.writeAll(line);
        try self.file.sync();
        self.next_seq += 1;
        return event.seq;
    }

    pub fn close(self: *Log) void {
        self.file.close();
        self.lock_file.close();
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Read and validate a log without taking the write lock.
pub fn readLog(allocator: Allocator, path: []const u8) !ReadResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const bytes = try fs_compat.readFileAlloc(compat.fs.cwd(), arena_allocator, path, max_log_bytes);
    const scanned = try scan(arena_allocator, bytes);
    return .{
        .arena = arena,
        .header = scanned.header,
        .events = scanned.events,
        .torn_truncate_to = scanned.torn_truncate_to,
    };
}

/// Truncate an uncommitted final record, returning whether anything was cut.
/// Callers must hold the session write lock when racing a writer.
pub fn repairTornTail(allocator: Allocator, path: []const u8) !bool {
    var result = try readLog(allocator, path);
    defer result.deinit();
    const offset = result.torn_truncate_to orelse return false;
    try truncateFile(path, offset);
    return true;
}

/// Human-readable refusal text for callers that surface errors to users.
pub fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedSessionFormatVersion => "unsupported session format version (only v4 is readable); migrate older logs with dsh first",
        error.UnsupportedEventType => "session log contains an unknown event type without the ignorable marker",
        error.SequenceGap => "session log sequence numbers are not contiguous",
        error.CorruptLog => "session log is corrupt",
        error.SessionLocked => "session log is already held by another writer",
        error.SessionExists => "session log already exists",
        else => @errorName(err),
    };
}

pub fn isKnownEventType(event_type: []const u8) bool {
    return known_event_types.get(event_type) != null;
}

const known_event_types = std.StaticStringMap(void).initComptime(.{
    .{ "agent-preset/selected", {} },
    .{ "agent/inbox/spliced", {} },
    .{ "approval/asked", {} },
    .{ "approval/decided", {} },
    .{ "approval/policy", {} },
    .{ "assistant/attempt", {} },
    .{ "assistant/message", {} },
    .{ "command/done", {} },
    .{ "command/run", {} },
    .{ "compaction/end", {} },
    .{ "compaction/prune", {} },
    .{ "compaction/start", {} },
    .{ "compaction/summary", {} },
    .{ "deliverables/presented", {} },
    .{ "developer/message", {} },
    .{ "feedback/message-delete", {} },
    .{ "feedback/message-put", {} },
    .{ "feedback/record", {} },
    .{ "goal/change", {} },
    .{ "hook/invoked", {} },
    .{ "hook/result", {} },
    .{ "image/offload", {} },
    .{ "job/registered", {} },
    .{ "job/settled", {} },
    .{ "llm/retry", {} },
    .{ "llm/retry-started", {} },
    .{ "model/selection", {} },
    .{ "permission/preset", {} },
    .{ "plan/mode", {} },
    .{ "request/context", {} },
    .{ "request/header", {} },
    .{ "sandbox/mode", {} },
    .{ "schedule/change", {} },
    .{ "session-log-deepseek/delivery-accepted", {} },
    .{ "session/end-seed", {} },
    .{ "session/title", {} },
    .{ "session/title-llm-request", {} },
    .{ "step/end", {} },
    .{ "step/start", {} },
    .{ "subagent/catalog", {} },
    .{ "subagent/descriptor", {} },
    .{ "subagent/model-selection-policy", {} },
    .{ "system/message", {} },
    .{ "team/member", {} },
    .{ "team/message/delivered", {} },
    .{ "team/message/queued", {} },
    .{ "team/task", {} },
    .{ "todo/write", {} },
    .{ "tool-workflow/agent-end", {} },
    .{ "tool-workflow/agent-start", {} },
    .{ "tool-workflow/run-end", {} },
    .{ "tool-workflow/run-start", {} },
    .{ "tool/call", {} },
    .{ "tool/ptc-dispatch", {} },
    .{ "tool/ptc-dispatch-start", {} },
    .{ "tool/result", {} },
    .{ "turn/end", {} },
    .{ "turn/start", {} },
    .{ "user/message", {} },
    .{ "web/deepseek-search-llm-request", {} },
    .{ "working-directory/change", {} },
    .{ "workspace/changes", {} },
});

fn acquireLock(allocator: Allocator, dir: []const u8) !compat.fs.File {
    const lock_path = try std.fs.path.join(allocator, &.{ dir, "session.lock" });
    return fs_compat.createPath(lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => error.SessionLocked,
        else => err,
    };
}

fn truncateFile(path: []const u8, length: u64) !void {
    const file = try fs_compat.openPath(path, .{ .mode = .read_write });
    defer file.close();
    try file.toInner().setLength(compat.io(), length);
    try file.sync();
}

fn copyHeader(allocator: Allocator, header: types.Header) !types.Header {
    return .{
        .id = try allocator.dupe(u8, header.id),
        .created_at = header.created_at,
        .cwd = if (header.cwd) |value| try allocator.dupe(u8, value) else null,
        .parent_session = if (header.parent_session) |value| try allocator.dupe(u8, value) else null,
        .is_seeded = header.is_seeded,
        .origin = if (header.origin) |value| try allocator.dupe(u8, value) else null,
        .delegation_depth = header.delegation_depth,
        .agent_preset = if (header.agent_preset) |value| try allocator.dupe(u8, value) else null,
    };
}

const Scan = struct {
    header: types.Header,
    events: []types.Event,
    torn_truncate_to: ?u64,
};

fn scan(allocator: Allocator, bytes: []const u8) !Scan {
    const header_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse return error.CorruptLog;
    if (header_end == 0) return error.CorruptLog;
    const header = try parseHeader(try parseJson(allocator, bytes[0..header_end]));

    var events: std.ArrayListUnmanaged(types.Event) = .empty;
    errdefer events.deinit(allocator);

    var position: usize = header_end + 1;
    var torn: ?u64 = null;
    while (position < bytes.len) {
        const relative_end = std.mem.indexOfScalar(u8, bytes[position..], '\n') orelse {
            torn = @intCast(position);
            break;
        };
        const line = bytes[position .. position + relative_end];
        position += relative_end + 1;
        if (line.len == 0) return error.CorruptLog;
        const value = try parseJson(allocator, line);
        try events.append(allocator, try parseEvent(allocator, value, @intCast(events.items.len)));
    }

    return .{
        .header = header,
        .events = try events.toOwnedSlice(allocator),
        .torn_truncate_to = torn,
    };
}

fn parseJson(allocator: Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CorruptLog,
    };
}

fn parseHeader(header_value: std.json.Value) !types.Header {
    const object = switch (header_value) {
        .object => |object| object,
        else => return error.CorruptLog,
    };

    // Refuse a foreign version before validating this build's header shape.
    const version = object.get("version") orelse return error.CorruptLog;
    if (version != .integer) return error.CorruptLog;
    if (version.integer != types.SESSION_FORMAT_VERSION) return error.UnsupportedSessionFormatVersion;

    const required = [_][]const u8{ "type", "version", "id", "createdAt", "isSeeded", "delegationDepth" };
    const optional = [_][]const u8{ "cwd", "parentSession", "origin", "agentPreset" };
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!contains(&required, key) and !contains(&optional, key)) return error.CorruptLog;
    }
    for (required) |key| {
        if (!object.contains(key)) return error.CorruptLog;
    }

    const kind = object.get("type").?;
    if (kind != .string or !std.mem.eql(u8, kind.string, "session")) return error.CorruptLog;
    const id = object.get("id").?;
    if (id != .string) return error.CorruptLog;
    const created_at = object.get("createdAt").?;
    if (created_at != .integer or !isCount(created_at.integer)) return error.CorruptLog;
    const is_seeded = object.get("isSeeded").?;
    if (is_seeded != .bool) return error.CorruptLog;
    const delegation_depth = object.get("delegationDepth").?;
    if (delegation_depth != .integer or !isCount(delegation_depth.integer)) return error.CorruptLog;

    const origin: ?[]const u8 = if (object.get("origin")) |value| blk: {
        if (value != .string or !std.mem.eql(u8, value.string, "subagent")) return error.CorruptLog;
        break :blk value.string;
    } else null;

    return .{
        .id = id.string,
        .created_at = created_at.integer,
        .cwd = try optionalString(object, "cwd"),
        .parent_session = try optionalString(object, "parentSession"),
        .is_seeded = is_seeded.bool,
        .origin = origin,
        .delegation_depth = @intCast(delegation_depth.integer),
        .agent_preset = try optionalString(object, "agentPreset"),
    };
}

fn parseEvent(allocator: Allocator, value: std.json.Value, expected_seq: u64) !types.Event {
    const object = switch (value) {
        .object => |object| object,
        else => return error.CorruptLog,
    };

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!isEnvelopeKey(entry.key_ptr.*)) return error.CorruptLog;
    }

    const kind = object.get("type") orelse return error.CorruptLog;
    if (kind != .string) return error.CorruptLog;
    const event_type = kind.string;

    const seq_value = object.get("seq") orelse return error.CorruptLog;
    if (seq_value != .integer or !isCount(seq_value.integer)) return error.CorruptLog;
    const seq: u64 = @intCast(seq_value.integer);
    if (seq != expected_seq) return error.SequenceGap;

    const time_value = object.get("time") orelse return error.CorruptLog;
    if (time_value != .integer or !isSafeInteger(time_value.integer)) return error.CorruptLog;

    const data = object.get("data") orelse return error.CorruptLog;

    var ignorable = false;
    if (object.get("ignorable")) |value_ignorable| {
        if (value_ignorable != .bool or !value_ignorable.bool) return error.CorruptLog;
        ignorable = true;
    }

    const known = isKnownEventType(event_type);
    if (!known and !ignorable) return error.UnsupportedEventType;

    // Unknown ignorable rows are retained opaquely: their surface metadata is
    // not interpreted (dsh keeps those references unvalidated).
    var surface_op: ?types.SurfaceOp = null;
    var source_event_seqs: ?[]const u64 = null;
    if (known) {
        if (object.get("surfaceOp")) |value_surface| {
            surface_op = parseSurfaceOp(value_surface) catch return error.CorruptLog;
            switch (surface_op.?) {
                .append => {},
                .replace => |replacement| {
                    if (replacement.end_seq >= seq) return error.CorruptLog;
                },
            }
        }
        if (object.get("sourceEventSeqs")) |value_seqs| {
            const seqs = json.decodeSeqRanges(allocator, value_seqs, seq) catch return error.CorruptLog;
            try requireUnique(allocator, seqs);
            if (seqs.len == 0 and !std.mem.eql(u8, event_type, "assistant/message")) return error.CorruptLog;
            source_event_seqs = seqs;
        }
        if (std.mem.eql(u8, event_type, "assistant/message") and source_event_seqs != null) return error.CorruptLog;
        if ((surface_op != null or source_event_seqs != null) and !isSurfaceType(event_type)) return error.CorruptLog;
    }

    return .{
        .event_type = event_type,
        .seq = seq,
        .time_ms = time_value.integer,
        .data = data,
        .surface_op = surface_op,
        .source_event_seqs = source_event_seqs,
        .ignorable = ignorable,
    };
}

fn parseSurfaceOp(value: std.json.Value) !types.SurfaceOp {
    switch (value) {
        .string => |text| {
            if (std.mem.eql(u8, text, "append")) return .append;
            return error.InvalidSurfaceOp;
        },
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                if (!std.mem.eql(u8, key, "op") and
                    !std.mem.eql(u8, key, "start") and
                    !std.mem.eql(u8, key, "end")) return error.InvalidSurfaceOp;
            }
            const op = object.get("op") orelse return error.InvalidSurfaceOp;
            if (op != .string or !std.mem.eql(u8, op.string, "replace")) return error.InvalidSurfaceOp;
            const start = object.get("start") orelse return error.InvalidSurfaceOp;
            const end = object.get("end") orelse return error.InvalidSurfaceOp;
            if (start != .integer or end != .integer) return error.InvalidSurfaceOp;
            if (start.integer < 0 or end.integer < start.integer) return error.InvalidSurfaceOp;
            return .{ .replace = .{
                .start_seq = @intCast(start.integer),
                .end_seq = @intCast(end.integer),
            } };
        },
        else => return error.InvalidSurfaceOp,
    }
}

fn validateSurface(allocator: Allocator, event: types.Event) !void {
    if (event.surface_op) |op| {
        switch (op) {
            .append => {},
            .replace => |replacement| {
                if (replacement.start_seq > replacement.end_seq) return error.InvalidEvent;
                if (replacement.end_seq >= event.seq) return error.InvalidEvent;
            },
        }
    }
    if (event.source_event_seqs) |seqs| {
        if (std.mem.eql(u8, event.event_type, "assistant/message")) return error.InvalidEvent;
        if (seqs.len == 0) return error.InvalidEvent;
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer seen.deinit(allocator);
        for (seqs) |seq| {
            if (seq >= event.seq) return error.InvalidEvent;
            if (seen.contains(seq)) return error.InvalidEvent;
            try seen.put(allocator, seq, {});
        }
    }
}

fn requireUnique(allocator: Allocator, seqs: []const u64) !void {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(allocator);
    for (seqs) |seq| {
        if (seen.contains(seq)) return error.CorruptLog;
        try seen.put(allocator, seq, {});
    }
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return error.CorruptLog;
    return value.string;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

/// JavaScript's largest exactly representable integer.
const max_safe_integer: i64 = 9_007_199_254_740_991;

fn isCount(value: i64) bool {
    return value >= 0 and value <= max_safe_integer;
}

fn isSafeInteger(value: i64) bool {
    return value >= -max_safe_integer and value <= max_safe_integer;
}

fn isSurfaceType(event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, "system/message") or
        std.mem.eql(u8, event_type, "user/message") or
        std.mem.eql(u8, event_type, "assistant/message") or
        std.mem.eql(u8, event_type, "tool/result");
}

fn isEnvelopeKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "type") or
        std.mem.eql(u8, key, "seq") or
        std.mem.eql(u8, key, "time") or
        std.mem.eql(u8, key, "data") or
        std.mem.eql(u8, key, "surfaceOp") or
        std.mem.eql(u8, key, "sourceEventSeqs") or
        std.mem.eql(u8, key, "ignorable");
}

// ---------------------------------------------------------------- tests

const TestPaths = struct {
    allocator: Allocator,
    base: []u8,
    log: []u8,

    fn init(allocator: Allocator, tmp: *std.testing.TmpDir) !TestPaths {
        const base = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
        errdefer allocator.free(base);
        const log = try std.fs.path.join(allocator, &.{ base, "session.v4.jsonl" });
        return .{ .allocator = allocator, .base = base, .log = log };
    }

    fn deinit(self: *TestPaths) void {
        self.allocator.free(self.log);
        self.allocator.free(self.base);
    }
};

fn testHeader() types.Header {
    return .{
        .id = "session-1",
        .created_at = 1_700_000_000_000,
        .cwd = "/work/example.com",
        .is_seeded = false,
        .delegation_depth = 0,
    };
}

fn testData(allocator: Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{ .allocate = .alloc_always });
}

fn expectJsonEqual(expected: std.json.Value, actual: std.json.Value) !void {
    const expected_text = try std.json.Stringify.valueAlloc(std.testing.allocator, expected, .{});
    defer std.testing.allocator.free(expected_text);
    const actual_text = try std.json.Stringify.valueAlloc(std.testing.allocator, actual, .{});
    defer std.testing.allocator.free(actual_text);
    try std.testing.expectEqualStrings(expected_text, actual_text);
}

fn writeRaw(path: []const u8, bytes: []const u8) !void {
    const file = try fs_compat.createPath(path, .{});
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
}

test "session log round-trips header and events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try TestPaths.init(std.testing.allocator, &tmp);
    defer paths.deinit();

    var data_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer data_arena.deinit();
    var log = try Log.create(std.testing.allocator, paths.log, testHeader());
    const turn_data = try testData(data_arena.allocator(), "{\"turn\":1}");
    try std.testing.expectEqual(@as(u64, 0), try log.append("turn/start", turn_data, .{ .time_ms = 1_700_000_000_001 }));
    const user_data = try testData(data_arena.allocator(), "{\"turn\":1,\"step\":1}");
    try std.testing.expectEqual(@as(u64, 1), try log.append("user/message", user_data, .{ .time_ms = 1_700_000_000_002, .surface_op = .append }));
    log.close();

    var result = try readLog(std.testing.allocator, paths.log);
    defer result.deinit();
    try std.testing.expectEqualStrings("session-1", result.header.id);
    try std.testing.expectEqualStrings("/work/example.com", result.header.cwd.?);
    try std.testing.expectEqual(@as(usize, 2), result.events.len);
    try std.testing.expectEqualStrings("turn/start", result.events[0].event_type);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_001), result.events[0].time_ms);
    try expectJsonEqual(turn_data, result.events[0].data);
    try std.testing.expectEqualStrings("user/message", result.events[1].event_type);
    try std.testing.expect(result.events[1].surface_op.? == .append);
    try std.testing.expect(result.torn_truncate_to == null);
}

test "resume reopens the log and keeps seq contiguous" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try TestPaths.init(std.testing.allocator, &tmp);
    defer paths.deinit();

    var data_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer data_arena.deinit();
    var log = try Log.create(std.testing.allocator, paths.log, testHeader());
    const data = try testData(data_arena.allocator(), "{\"turn\":1}");
    _ = try log.append("turn/start", data, .{ .time_ms = 1 });
    _ = try log.append("step/start", data, .{ .time_ms = 2 });
    log.close();

    var resumed = try Log.open(std.testing.allocator, paths.log);
    try std.testing.expectEqual(@as(u64, 2), resumed.next_seq);
    try std.testing.expectEqual(@as(u64, 2), try resumed.append("step/end", data, .{ .time_ms = 3 }));
    try std.testing.expectEqual(@as(u64, 3), try resumed.append("turn/end", data, .{ .time_ms = 4 }));
    resumed.close();

    var result = try readLog(std.testing.allocator, paths.log);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 4), result.events.len);
    for (result.events, 0..) |event, index| {
        try std.testing.expectEqual(@as(u64, @intCast(index)), event.seq);
    }
}

test "torn tail is ignored on read and truncated before resume" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try TestPaths.init(std.testing.allocator, &tmp);
    defer paths.deinit();

    var data_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer data_arena.deinit();
    var log = try Log.create(std.testing.allocator, paths.log, testHeader());
    const data = try testData(data_arena.allocator(), "{\"turn\":1}");
    _ = try log.append("turn/start", data, .{ .time_ms = 1 });
    _ = try log.append("step/start", data, .{ .time_ms = 2 });
    log.close();

    // Simulate a crash in the middle of the next append.
    const partial = "{\"type\":\"step/end\",\"seq\":2,\"time\":3,\"data\":{\"turn\":1";
    const file = try fs_compat.openPathForAppend(paths.log);
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(partial);
    try file.sync();

    var torn = try readLog(std.testing.allocator, paths.log);
    try std.testing.expectEqual(@as(usize, 2), torn.events.len);
    try std.testing.expect(torn.torn_truncate_to != null);
    torn.deinit();

    try std.testing.expect(try repairTornTail(std.testing.allocator, paths.log));

    var resumed = try Log.open(std.testing.allocator, paths.log);
    try std.testing.expectEqual(@as(u64, 2), resumed.next_seq);
    try std.testing.expectEqual(@as(u64, 2), try resumed.append("step/end", data, .{ .time_ms = 3 }));
    resumed.close();

    var result = try readLog(std.testing.allocator, paths.log);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.events.len);
    try std.testing.expectEqualStrings("step/end", result.events[2].event_type);
}

test "seq gaps fail closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try TestPaths.init(std.testing.allocator, &tmp);
    defer paths.deinit();

    const header = "{\"type\":\"session\",\"version\":4,\"id\":\"session-1\",\"createdAt\":1,\"isSeeded\":false,\"delegationDepth\":0}\n";
    const first = "{\"type\":\"turn/start\",\"seq\":0,\"time\":1,\"data\":{\"turn\":1}}\n";
    const second = "{\"type\":\"step/start\",\"seq\":2,\"time\":2,\"data\":{\"turn\":1,\"step\":1}}\n";
    try writeRaw(paths.log, header ++ first ++ second);

    try std.testing.expectError(error.SequenceGap, readLog(std.testing.allocator, paths.log));
}

test "unknown ignorable events are retained while unknown required events fail closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try TestPaths.init(std.testing.allocator, &tmp);
    defer paths.deinit();

    const header = "{\"type\":\"session\",\"version\":4,\"id\":\"session-1\",\"createdAt\":1,\"isSeeded\":false,\"delegationDepth\":0}\n";
    const known = "{\"type\":\"session/title\",\"seq\":0,\"time\":1,\"data\":{\"title\":\"example.com\"}}\n";
    // Opaque metadata is retained but not interpreted, so even references this
    // build would reject on a known type must not fail the read.
    const opaque_event = "{\"type\":\"plugin/future-thing\",\"seq\":1,\"time\":2,\"data\":{\"x\":1},\"surfaceOp\":{\"op\":\"replace\",\"start\":9,\"end\":1},\"sourceEventSeqs\":[[9,1]],\"ignorable\":true}\n";
    try writeRaw(paths.log, header ++ known ++ opaque_event);

    var result = try readLog(std.testing.allocator, paths.log);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.events.len);
    try std.testing.expect(result.events[1].ignorable);
    try std.testing.expectEqualStrings("plugin/future-thing", result.events[1].event_type);
    try std.testing.expect(result.events[1].surface_op == null);
    try std.testing.expect(result.events[1].source_event_seqs == null);

    const required = "{\"type\":\"plugin/future-thing\",\"seq\":1,\"time\":2,\"data\":{\"x\":1}}\n";
    try writeRaw(paths.log, header ++ known ++ required);
    try std.testing.expectError(error.UnsupportedEventType, readLog(std.testing.allocator, paths.log));
}

test "version 3 headers are refused with a migration hint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try TestPaths.init(std.testing.allocator, &tmp);
    defer paths.deinit();

    const header = "{\"type\":\"session\",\"version\":3,\"id\":\"session-1\",\"createdAt\":1,\"isSeeded\":false,\"delegationDepth\":0}\n";
    try writeRaw(paths.log, header);
    try std.testing.expectError(error.UnsupportedSessionFormatVersion, readLog(std.testing.allocator, paths.log));
    try std.testing.expect(std.mem.indexOf(u8, describeError(error.UnsupportedSessionFormatVersion), "dsh") != null);
}

test "corrupt committed records are not skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try TestPaths.init(std.testing.allocator, &tmp);
    defer paths.deinit();

    const header = "{\"type\":\"session\",\"version\":4,\"id\":\"session-1\",\"createdAt\":1,\"isSeeded\":false,\"delegationDepth\":0}\n";
    try writeRaw(paths.log, header ++ "not json\n");
    try std.testing.expectError(error.CorruptLog, readLog(std.testing.allocator, paths.log));
}

test "a second writer is refused by the session lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try TestPaths.init(std.testing.allocator, &tmp);
    defer paths.deinit();

    var first = try Log.create(std.testing.allocator, paths.log, testHeader());
    defer first.close();
    try std.testing.expectError(error.SessionLocked, Log.create(std.testing.allocator, paths.log, testHeader()));
}
