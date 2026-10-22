//! Stable JSON encoding for the dsh v4 session log.
//!
//! Key order is fixed here rather than derived from reflection, matching dsh's
//! physical v4 rows:
//!   header: type, version, id, createdAt, cwd?, parentSession?, isSeeded,
//!           origin?, delegationDepth, agentPreset?
//!   event:  type, seq, time, data, sourceEventSeqs?, surfaceOp?, ignorable?
//! JSONL writers append exactly one newline per record.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn writeHeader(w: *Writer, header: types.Header) !void {
    try w.writeAll("{\"type\":\"session\",\"version\":");
    try w.print("{d}", .{types.SESSION_FORMAT_VERSION});
    try w.writeAll(",\"id\":");
    try std.json.Stringify.value(header.id, .{}, w);
    try w.print(",\"createdAt\":{d}", .{header.created_at});
    if (header.cwd) |cwd| {
        try w.writeAll(",\"cwd\":");
        try std.json.Stringify.value(cwd, .{}, w);
    }
    if (header.parent_session) |parent| {
        try w.writeAll(",\"parentSession\":");
        try std.json.Stringify.value(parent, .{}, w);
    }
    try w.writeAll(",\"isSeeded\":");
    try w.writeAll(if (header.is_seeded) "true" else "false");
    if (header.origin) |origin| {
        try w.writeAll(",\"origin\":");
        try std.json.Stringify.value(origin, .{}, w);
    }
    try w.print(",\"delegationDepth\":{d}", .{header.delegation_depth});
    if (header.agent_preset) |preset| {
        try w.writeAll(",\"agentPreset\":");
        try std.json.Stringify.value(preset, .{}, w);
    }
    try w.writeByte('}');
}

pub fn writeEvent(w: *Writer, event: types.Event) !void {
    try w.writeAll("{\"type\":");
    try std.json.Stringify.value(event.event_type, .{}, w);
    try w.print(",\"seq\":{d},\"time\":{d},\"data\":", .{ event.seq, event.time_ms });
    try std.json.Stringify.value(event.data, .{}, w);
    if (event.source_event_seqs) |seqs| {
        try w.writeAll(",\"sourceEventSeqs\":");
        try writeSeqRanges(w, seqs);
    }
    if (event.surface_op) |op| {
        try w.writeAll(",\"surfaceOp\":");
        switch (op) {
            .append => try std.json.Stringify.value("append", .{}, w),
            .replace => |replacement| try w.print(
                "{{\"op\":\"replace\",\"startSeq\":{d},\"endSeq\":{d}}}",
                .{ replacement.start_seq, replacement.end_seq },
            ),
        }
    }
    if (event.ignorable) try w.writeAll(",\"ignorable\":true");
    try w.writeByte('}');
}

pub fn headerLineAlloc(allocator: Allocator, header: types.Header) ![]u8 {
    var buffer = Writer.Allocating.init(allocator);
    errdefer buffer.deinit();
    try writeHeader(&buffer.writer, header);
    try buffer.writer.writeByte('\n');
    return buffer.toOwnedSlice();
}

pub fn eventLineAlloc(allocator: Allocator, event: types.Event) ![]u8 {
    var buffer = Writer.Allocating.init(allocator);
    errdefer buffer.deinit();
    try writeEvent(&buffer.writer, event);
    try buffer.writer.writeByte('\n');
    return buffer.toOwnedSlice();
}

/// Write `sourceEventSeqs` in dsh's lossless storage form: consecutive runs of
/// three or more become inclusive `[start,end]` pairs, everything else a plain
/// number. Unsorted input is written verbatim as numbers.
pub fn writeSeqRanges(w: *Writer, seqs: []const u64) !void {
    try w.writeByte('[');
    var first = true;
    if (isStrictlyIncreasing(seqs)) {
        var start: usize = 0;
        while (start < seqs.len) {
            var end = start;
            while (end + 1 < seqs.len and seqs[end + 1] == seqs[end] + 1) end += 1;
            if (end - start >= 2) {
                if (!first) try w.writeByte(',');
                first = false;
                try w.print("[{d},{d}]", .{ seqs[start], seqs[end] });
            } else {
                var index = start;
                while (index <= end) : (index += 1) {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.print("{d}", .{seqs[index]});
                }
            }
            start = end + 1;
        }
    } else {
        for (seqs) |seq| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{d}", .{seq});
        }
    }
    try w.writeByte(']');
}

/// Decode a stored `sourceEventSeqs` array back to sorted-in-storage numbers.
/// Every value must be an earlier seq (`< max_exclusive`); a pair must be
/// ascending. Returns `error.InvalidSeqRanges` on malformed input.
pub fn decodeSeqRanges(allocator: Allocator, value: std.json.Value, max_exclusive: u64) ![]u64 {
    if (value != .array) return error.InvalidSeqRanges;
    var out: std.ArrayListUnmanaged(u64) = .empty;
    errdefer out.deinit(allocator);
    for (value.array.items) |item| {
        switch (item) {
            .integer => |number| {
                if (number < 0) return error.InvalidSeqRanges;
                const seq: u64 = @intCast(number);
                if (seq >= max_exclusive) return error.InvalidSeqRanges;
                try out.append(allocator, seq);
            },
            .array => |pair| {
                if (pair.items.len != 2) return error.InvalidSeqRanges;
                if (pair.items[0] != .integer or pair.items[1] != .integer) return error.InvalidSeqRanges;
                if (pair.items[0].integer < 0) return error.InvalidSeqRanges;
                if (pair.items[1].integer < pair.items[0].integer) return error.InvalidSeqRanges;
                const last: u64 = @intCast(pair.items[1].integer);
                if (last >= max_exclusive) return error.InvalidSeqRanges;
                var seq: u64 = @intCast(pair.items[0].integer);
                while (seq <= last) : (seq += 1) try out.append(allocator, seq);
            },
            else => return error.InvalidSeqRanges,
        }
    }
    return out.toOwnedSlice(allocator);
}

fn isStrictlyIncreasing(seqs: []const u64) bool {
    for (seqs, 0..) |seq, index| {
        if (index > 0 and seq <= seqs[index - 1]) return false;
    }
    return true;
}

/// Iterator over UTF-16 code units, mirroring JavaScript `string.length` and
/// `charCodeAt`: astral code points yield a surrogate pair, invalid UTF-8
/// bytes yield U+FFFD (one unit each).
pub const Utf16CodeUnits = struct {
    bytes: []const u8,
    index: usize = 0,
    pending_low: ?u16 = null,

    pub fn next(self: *Utf16CodeUnits) ?u16 {
        if (self.pending_low) |low| {
            self.pending_low = null;
            return low;
        }
        if (self.index >= self.bytes.len) return null;
        const first = self.bytes[self.index];
        const length = std.unicode.utf8ByteSequenceLength(first) catch {
            self.index += 1;
            return 0xFFFD;
        };
        if (self.index + length > self.bytes.len) {
            self.index += 1;
            return 0xFFFD;
        }
        const codepoint = std.unicode.utf8Decode(self.bytes[self.index .. self.index + length]) catch {
            self.index += 1;
            return 0xFFFD;
        };
        self.index += length;
        if (codepoint <= 0xFFFF) return @intCast(codepoint);
        const offset = codepoint - 0x10000;
        self.pending_low = @intCast(0xDC00 + (offset & 0x3FF));
        return @intCast(0xD800 + (offset >> 10));
    }
};

/// JavaScript `.length` of the UTF-8 text decoded as a JS string.
pub fn utf16CodeUnitCount(text: []const u8) usize {
    var units = Utf16CodeUnits{ .bytes = text };
    var count: usize = 0;
    while (units.next() != null) count += 1;
    return count;
}

test "utf16 code unit count matches JavaScript length" {
    try std.testing.expectEqual(@as(usize, 3), utf16CodeUnitCount("abc"));
    try std.testing.expectEqual(@as(usize, 1), utf16CodeUnitCount("é"));
    try std.testing.expectEqual(@as(usize, 1), utf16CodeUnitCount("中"));
    try std.testing.expectEqual(@as(usize, 2), utf16CodeUnitCount("😀"));
    try std.testing.expectEqual(@as(usize, 4), utf16CodeUnitCount("a😀é"));
    try std.testing.expectEqual(@as(usize, 1), utf16CodeUnitCount("\xFF"));
}

test "header and event lines are single stable JSONL records" {
    const allocator = std.testing.allocator;
    const header = types.Header{
        .id = "session-1",
        .created_at = 1_700_000_000_000,
        .cwd = "/work/example.com",
        .is_seeded = false,
        .delegation_depth = 0,
    };
    const header_line = try headerLineAlloc(allocator, header);
    defer allocator.free(header_line);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, header_line, "\n"));
    try std.testing.expectEqual(@as(u8, '\n'), header_line[header_line.len - 1]);
    try std.testing.expect(std.mem.startsWith(u8, header_line, "{\"type\":\"session\",\"version\":4,\"id\":\"session-1\",\"createdAt\":1700000000000,\"cwd\":\"/work/example.com\",\"isSeeded\":false,\"delegationDepth\":0}\n"));

    const event = types.Event{
        .event_type = "user/message",
        .seq = 2,
        .time_ms = 1_700_000_000_001,
        .data = .{ .integer = 7 },
        .source_event_seqs = &.{ 1, 2, 3, 5 },
        .surface_op = .append,
        .ignorable = true,
    };
    const event_line = try eventLineAlloc(allocator, event);
    defer allocator.free(event_line);
    try std.testing.expectEqualStrings(
        "{\"type\":\"user/message\",\"seq\":2,\"time\":1700000000001,\"data\":7,\"sourceEventSeqs\":[[1,3],5],\"surfaceOp\":\"append\",\"ignorable\":true}\n",
        event_line,
    );
}

test "seq ranges decode to the stored numbers" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[[1,3],5]", .{});
    defer parsed.deinit();
    const seqs = try decodeSeqRanges(allocator, parsed.value, 6);
    defer allocator.free(seqs);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 5 }, seqs);

    try std.testing.expectError(error.InvalidSeqRanges, decodeSeqRanges(allocator, parsed.value, 5));
}
