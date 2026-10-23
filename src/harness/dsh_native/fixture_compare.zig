//! Shared fixture helpers: JSON/JSONL loading and the normalized v4 log
//! comparison used by the plain-turn and replay-driven P1 fixtures.
//!
//! Comparison layers (design §4.2): event type sequence, event data minus the
//! manifest's declared tokens/volatile fields, and the typed surface fold.
//!
//! Path convention: fixture paths are always written with '/' separators.
//! Implementations emit native separators (dsh/node `path.relative`), so this
//! Normalizer is the only place that reconciles them: path values (`cwd`,
//! `meta.path`) map every separator to '/', and text maps separators only
//! inside `<path>...</path>` segments. All other text is compared
//! byte-for-byte, so a '\\' there still fails.

const std = @import("std");
const compat = @import("compat");
const fs_compat = @import("../../fs_compat.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
pub const Value = std.json.Value;
pub const Obj = std.json.ObjectMap;

pub fn quote(allocator: Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, Value{ .string = text }, .{});
}

pub fn parseJson(allocator: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, allocator, text, .{ .allocate = .alloc_always });
}

pub fn parseJsonl(allocator: Allocator, bytes: []const u8) ![]Value {
    var records: std.ArrayListUnmanaged(Value) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try records.append(allocator, try parseJson(allocator, trimmed));
    }
    return records.toOwnedSlice(allocator);
}

pub fn readFixture(allocator: Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);
    return fs_compat.readFileAlloc(compat.fs.cwd(), allocator, path, 1 << 20);
}

pub fn loadDeclaredTokens(
    allocator: Allocator,
    manifest: Value,
    declared: *std.StringHashMapUnmanaged(void),
    ordinal: *std.StringHashMapUnmanaged(void),
) !void {
    const root = switch (manifest) {
        .object => |object| object,
        else => return error.FixtureMismatch,
    };
    const normalization = switch (root.get("normalization") orelse return error.FixtureMismatch) {
        .object => |object| object,
        else => return error.FixtureMismatch,
    };
    try addTokens(allocator, declared, normalization.get("tokens") orelse return error.FixtureMismatch, null);
    try addTokens(allocator, declared, normalization.get("fixtureOrdinalTokens") orelse return error.FixtureMismatch, ordinal);
    try addTokens(allocator, declared, normalization.get("comparisonMask") orelse return error.FixtureMismatch, null);
}

fn addTokens(
    allocator: Allocator,
    declared: *std.StringHashMapUnmanaged(void),
    list: Value,
    ordinal: ?*std.StringHashMapUnmanaged(void),
) !void {
    const items = switch (list) {
        .array => |array| array.items,
        else => return error.FixtureMismatch,
    };
    for (items) |item| {
        const object = switch (item) {
            .object => |object| object,
            else => return error.FixtureMismatch,
        };
        const token = try requiredString(object, "token");
        try declared.put(allocator, token, {});
        if (ordinal) |ordinal_tokens| try ordinal_tokens.put(allocator, token, {});
    }
}

pub fn asString(value: Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.FixtureMismatch,
    };
}

pub fn requiredString(object: Obj, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.FixtureMismatch;
    return asString(value);
}

/// Turn the expected JSONL records (which omit seq/time) into typed events for
/// the surface fold. Seqs follow log order, matching the written log.
pub fn eventsFromRecords(allocator: Allocator, records: []const Value) ![]types.Event {
    if (records.len == 0) return error.FixtureMismatch;
    var events: std.ArrayListUnmanaged(types.Event) = .empty;
    try events.ensureTotalCapacity(allocator, records.len - 1);
    for (records[1..], 0..) |record, index| {
        const object = switch (record) {
            .object => |object| object,
            else => return error.FixtureMismatch,
        };
        var surface_op: ?types.SurfaceOp = null;
        if (object.get("surfaceOp")) |op_value| {
            const op = try asString(op_value);
            if (std.mem.eql(u8, op, "append")) {
                surface_op = .append;
            } else {
                return error.UnsupportedSurfaceOp;
            }
        }
        events.appendAssumeCapacity(.{
            .event_type = try requiredString(object, "type"),
            .seq = @intCast(index),
            .time_ms = 0,
            .data = object.get("data") orelse return error.FixtureMismatch,
            .surface_op = surface_op,
        });
    }
    return events.toOwnedSlice(allocator);
}

fn looksLikeToken(text: []const u8) bool {
    return text.len >= 4 and std.mem.startsWith(u8, text, "{{") and std.mem.endsWith(u8, text, "}}");
}

/// Map every separator in a path value to '/'. Fixtures store paths with '/';
/// implementations emit the platform separator.
fn normalizePath(allocator: Allocator, text: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, text);
    for (out) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return out;
}

/// Map separators to '/' inside `<path>...</path>` segments only. The
/// surrounding text keeps its separators significant.
fn normalizePathMarkers(allocator: Allocator, text: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, text);
    const open = "<path>";
    const close = "</path>";
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, out, index, open)) |start| {
        const body_start = start + open.len;
        const body_end = std.mem.indexOfPos(u8, out, body_start, close) orelse break;
        for (out[body_start..body_end]) |*byte| {
            if (byte.* == '\\') byte.* = '/';
        }
        index = body_end + close.len;
    }
    return out;
}

fn isWholeValueToken(declared: *const std.StringHashMapUnmanaged(void), value: Value) bool {
    if (value != .string) return false;
    return std.mem.eql(u8, value.string, "{{tools}}") and declared.contains(value.string);
}

fn expectZeroedIntegerArray(expected: Value, actual: Value) !void {
    const expected_array = switch (expected) {
        .array => |array| array,
        else => return error.FixtureMismatch,
    };
    const actual_array = switch (actual) {
        .array => |array| array,
        else => return error.FixtureMismatch,
    };
    try std.testing.expectEqual(expected_array.items.len, actual_array.items.len);
    for (expected_array.items, actual_array.items) |expected_item, actual_item| {
        if (expected_item != .integer or actual_item != .integer) return error.FixtureMismatch;
    }
}

pub const Normalizer = struct {
    arena: Allocator,
    declared: *const std.StringHashMapUnmanaged(void),
    ordinal: *const std.StringHashMapUnmanaged(void),
    /// Absolute workspace path; occurrences in actual strings are rewritten to
    /// the fixture's `{{cwd}}` token.
    cwd: []const u8 = "",
    token_to_actual: std.StringHashMapUnmanaged([]const u8) = .empty,
    actual_to_token: std.StringHashMapUnmanaged([]const u8) = .empty,

    const Context = struct {
        /// Comparing `assistant/message.data`; its `stream` value is a packed
        /// stream array.
        stream_owner: bool = false,
        /// Comparing the packed stream array itself.
        stream_array: bool = false,
        /// Comparing one packed stream record.
        stream_item: bool = false,
        /// Comparing the `meta` object of a tool result.
        meta: bool = false,
        /// Comparing a filesystem path value; separators normalize to '/'.
        path_value: bool = false,
    };

    /// Compare a decoded actual log against the expected JSONL records.
    pub fn expectLog(self: *Normalizer, expected_records: []const Value, actual_records: []const Value) !void {
        try std.testing.expectEqual(expected_records.len, actual_records.len);
        for (expected_records, actual_records, 0..) |expected, actual, index| {
            self.compareRecord(expected, actual, index == 0) catch |err| {
                const expected_text = try std.json.Stringify.valueAlloc(self.arena, expected, .{});
                const actual_text = try std.json.Stringify.valueAlloc(self.arena, actual, .{});
                std.debug.print("fixture mismatch at record {d}: {s}\n  expected {s}\n  actual   {s}\n", .{
                    index,
                    @errorName(err),
                    expected_text,
                    actual_text,
                });
                return err;
            };
        }
    }

    pub fn compareRecord(self: *Normalizer, expected: Value, actual: Value, is_header: bool) !void {
        const expected_object = switch (expected) {
            .object => |object| object,
            else => return error.FixtureMismatch,
        };
        const actual_object = switch (actual) {
            .object => |object| object,
            else => return error.FixtureMismatch,
        };

        const expected_type = try requiredString(expected_object, "type");
        const actual_type = try requiredString(actual_object, "type");
        try std.testing.expectEqualStrings(expected_type, actual_type);

        var iterator = expected_object.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "data")) continue;
            const actual_value = actual_object.get(key) orelse return error.FixtureMismatch;
            if (is_header and std.mem.eql(u8, key, "createdAt")) {
                if (actual_value != .integer or entry.value_ptr.* != .integer) return error.FixtureMismatch;
                continue;
            }
            try self.compareValue(entry.value_ptr.*, actual_value, .{
                .path_value = is_header and std.mem.eql(u8, key, "cwd"),
            });
        }

        var actual_iterator = actual_object.iterator();
        while (actual_iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            if (expected_object.get(key) != null) continue;
            if (!is_header and (std.mem.eql(u8, key, "seq") or std.mem.eql(u8, key, "time"))) continue;
            return error.FixtureMismatch;
        }

        if (is_header) return;
        const expected_data = expected_object.get("data") orelse return error.FixtureMismatch;
        const actual_data = actual_object.get("data") orelse return error.FixtureMismatch;
        try self.compareValue(expected_data, actual_data, .{
            .stream_owner = std.mem.eql(u8, expected_type, "assistant/message"),
        });
    }

    fn compareValue(self: *Normalizer, expected: Value, actual: Value, context: Context) anyerror!void {
        switch (expected) {
            .string => |expected_string| {
                if (self.declared.contains(expected_string)) {
                    if (self.ordinal.contains(expected_string)) {
                        try self.bindOrdinal(try asString(actual), expected_string);
                    }
                    return;
                }
                const actual_string = try asString(actual);
                if (context.path_value) {
                    const substituted = if (std.mem.indexOf(u8, expected_string, "{{cwd}}") != null)
                        try self.substituteCwd(actual_string)
                    else
                        actual_string;
                    try std.testing.expectEqualStrings(
                        try normalizePath(self.arena, expected_string),
                        try normalizePath(self.arena, substituted),
                    );
                    return;
                }
                if (std.mem.indexOf(u8, expected_string, "{{cwd}}") != null) {
                    try self.expectTextMatch(expected_string, actual_string);
                    return;
                }
                if (looksLikeToken(expected_string)) return error.UndeclaredToken;
                try std.testing.expectEqualStrings(expected_string, actual_string);
            },
            .object => |expected_object| {
                const actual_object = switch (actual) {
                    .object => |object| object,
                    else => return error.FixtureMismatch,
                };
                try self.compareObject(expected_object, actual_object, context);
            },
            .array => |expected_array| {
                const actual_array = switch (actual) {
                    .array => |array| array,
                    else => return error.FixtureMismatch,
                };
                try std.testing.expectEqual(expected_array.items.len, actual_array.items.len);
                for (expected_array.items, actual_array.items) |expected_item, actual_item| {
                    try self.compareValue(expected_item, actual_item, .{ .stream_item = context.stream_array });
                }
            },
            .integer => |number| {
                const actual_number = switch (actual) {
                    .integer => |value| value,
                    else => return error.FixtureMismatch,
                };
                try std.testing.expectEqual(number, actual_number);
            },
            .bool => |flag| {
                const actual_flag = switch (actual) {
                    .bool => |value| value,
                    else => return error.FixtureMismatch,
                };
                try std.testing.expectEqual(flag, actual_flag);
            },
            .null => if (actual != .null) return error.FixtureMismatch,
            .float => |number| {
                const actual_number = switch (actual) {
                    .float => |value| value,
                    else => return error.FixtureMismatch,
                };
                try std.testing.expectEqual(number, actual_number);
            },
            .number_string => |number| {
                const actual_number = switch (actual) {
                    .number_string => |value| value,
                    else => return error.FixtureMismatch,
                };
                try std.testing.expectEqualStrings(number, actual_number);
            },
        }
    }

    fn compareObject(self: *Normalizer, expected: Obj, actual: Obj, context: Context) anyerror!void {
        var iterator = expected.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            const expected_value = entry.value_ptr.*;
            if (actual.get(key)) |actual_value| {
                if (context.stream_item and (std.mem.eql(u8, key, "time") or std.mem.eql(u8, key, "time0"))) {
                    if (expected_value != .integer or actual_value != .integer) return error.FixtureMismatch;
                    continue;
                }
                if (context.stream_item and std.mem.eql(u8, key, "dt")) {
                    try expectZeroedIntegerArray(expected_value, actual_value);
                    continue;
                }
                const child_context: Context = if (context.stream_owner and std.mem.eql(u8, key, "stream"))
                    .{ .stream_array = true }
                else if (std.mem.eql(u8, key, "meta"))
                    .{ .meta = true }
                else if (context.meta and std.mem.eql(u8, key, "path"))
                    .{ .path_value = true }
                else
                    .{};
                try self.compareValue(expected_value, actual_value, child_context);
            } else if (isWholeValueToken(self.declared, expected_value)) {
                // {{tools}} stands for the whole tool-schema array; a tool-less
                // request omits the key (manifest openIssues; agent.ts:629).
                continue;
            } else {
                return error.FixtureMismatch;
            }
        }

        var actual_iterator = actual.iterator();
        while (actual_iterator.next()) |entry| {
            if (expected.get(entry.key_ptr.*) == null) return error.FixtureMismatch;
        }
    }

    fn bindOrdinal(self: *Normalizer, actual: []const u8, token: []const u8) !void {
        const backward = try self.token_to_actual.getOrPut(self.arena, token);
        if (!backward.found_existing) {
            backward.value_ptr.* = try self.arena.dupe(u8, actual);
        } else if (!std.mem.eql(u8, backward.value_ptr.*, actual)) {
            return error.TokenIdentityMismatch;
        }

        const forward = try self.actual_to_token.getOrPut(self.arena, actual);
        if (!forward.found_existing) {
            forward.value_ptr.* = try self.arena.dupe(u8, token);
        } else if (!std.mem.eql(u8, forward.value_ptr.*, token)) {
            return error.TokenIdentityMismatch;
        }
    }

    fn expectTokenOrString(self: *Normalizer, expected: []const u8, actual: []const u8) !void {
        if (self.declared.contains(expected)) {
            if (self.ordinal.contains(expected)) {
                const known = self.token_to_actual.get(expected) orelse return error.UnboundOrdinalToken;
                try std.testing.expectEqualStrings(known, actual);
            }
            return;
        }
        try std.testing.expectEqualStrings(expected, actual);
    }

    /// Compare text containing `{{cwd}}`: the workspace prefix is tokenized and
    /// separators normalize only inside `<path>` segments; the rest of the text
    /// stays byte-exact.
    fn expectTextMatch(self: *Normalizer, expected: []const u8, actual: []const u8) !void {
        const substituted = if (std.mem.indexOf(u8, expected, "{{cwd}}") != null)
            try self.substituteCwd(actual)
        else
            actual;
        try std.testing.expectEqualStrings(
            try normalizePathMarkers(self.arena, expected),
            try normalizePathMarkers(self.arena, substituted),
        );
    }

    /// Rewrite the workspace path to `{{cwd}}`. Separator normalization is
    /// separate: `normalizePath` for path values, `normalizePathMarkers` for
    /// text.
    fn substituteCwd(self: *Normalizer, text: []const u8) ![]const u8 {
        std.debug.assert(self.cwd.len > 0);
        return std.mem.replaceOwned(u8, self.arena, text, self.cwd, "{{cwd}}");
    }

    /// Compare a typed message from the surface fold (layer ③).
    pub fn expectMessagesMatch(self: *Normalizer, expected: types.Message, actual: types.Message) !void {
        try std.testing.expectEqual(expected.role, actual.role);
        try self.expectTokenOrString(expected.id, actual.id);
        try std.testing.expectEqual(expected.content.len, actual.content.len);
        for (expected.content, actual.content) |expected_block, actual_block| {
            switch (expected_block) {
                .text => |text| {
                    const actual_text = switch (actual_block) {
                        .text => |value| value,
                        else => return error.FixtureMismatch,
                    };
                    if (std.mem.indexOf(u8, text, "{{cwd}}") != null or std.mem.indexOf(u8, text, "<path>") != null) {
                        try self.expectTextMatch(text, actual_text);
                    } else {
                        try self.expectTokenOrString(text, actual_text);
                    }
                },
                .reasoning => |text| {
                    const actual_text = switch (actual_block) {
                        .reasoning => |value| value,
                        else => return error.FixtureMismatch,
                    };
                    try std.testing.expectEqualStrings(text, actual_text);
                },
                .tool_call => |call| {
                    const actual_call = switch (actual_block) {
                        .tool_call => |value| value,
                        else => return error.FixtureMismatch,
                    };
                    try std.testing.expectEqualStrings(call.id, actual_call.id);
                    try std.testing.expectEqualStrings(call.name, actual_call.name);
                    try std.testing.expectEqualStrings(call.arguments, actual_call.arguments);
                },
                .raw => |value| try self.compareValue(value, switch (actual_block) {
                    .raw => |actual_value| actual_value,
                    else => return error.FixtureMismatch,
                }, .{}),
            }
        }

        switch (expected.source) {
            .user => if (actual.source != .user) return error.FixtureMismatch,
            .system_prompt => if (actual.source != .system_prompt) return error.FixtureMismatch,
            .model => |source| {
                const actual_source = switch (actual.source) {
                    .model => |value| value,
                    else => return error.FixtureMismatch,
                };
                try std.testing.expectEqualStrings(source.provider, actual_source.provider);
                try std.testing.expectEqualStrings(source.model, actual_source.model);
            },
            .tool => |source| {
                const actual_source = switch (actual.source) {
                    .tool => |value| value,
                    else => return error.FixtureMismatch,
                };
                try std.testing.expectEqualStrings(source.call_id, actual_source.call_id);
            },
            .other => |value| {
                const actual_value = switch (actual.source) {
                    .other => |other| other,
                    else => return error.FixtureMismatch,
                };
                try self.compareValue(value, actual_value, .{});
            },
        }

        try std.testing.expectEqual(expected.tool_call_id != null, actual.tool_call_id != null);
        if (expected.tool_call_id) |call_id| {
            try std.testing.expectEqualStrings(call_id, actual.tool_call_id.?);
        }
    }
};

test "path values normalize separators but other text keeps them significant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const declared: std.StringHashMapUnmanaged(void) = .empty;
    const ordinal: std.StringHashMapUnmanaged(void) = .empty;
    var normalizer = Normalizer{
        .arena = allocator,
        .declared = &declared,
        .ordinal = &ordinal,
        .cwd = "C:\\work\\project",
    };

    // Path values: native separators match the fixture's '/' form.
    try normalizer.compareValue(
        .{ .string = "{{cwd}}/src/main.zig" },
        .{ .string = "C:\\work\\project\\src\\main.zig" },
        .{ .path_value = true },
    );
    try normalizer.compareValue(
        .{ .string = "a/b" },
        .{ .string = "a\\b" },
        .{ .path_value = true },
    );

    // Path values still compare the file name.
    try std.testing.expectError(error.TestExpectedEqual, normalizer.compareValue(
        .{ .string = "{{cwd}}/src/main.zig" },
        .{ .string = "C:\\work\\project\\src\\other.zig" },
        .{ .path_value = true },
    ));

    // Non-path text keeps separators significant.
    try std.testing.expectError(error.TestExpectedEqual, normalizer.compareValue(
        .{ .string = "{{cwd}}/src/main.zig" },
        .{ .string = "C:\\work\\project\\src\\main.zig" },
        .{},
    ));

    // Only `<path>` segments normalize; the surrounding text stays exact.
    try normalizer.compareValue(
        .{ .string = "<path>{{cwd}}/a.txt</path>\na/b" },
        .{ .string = "<path>C:\\work\\project\\a.txt</path>\na/b" },
        .{},
    );
    try std.testing.expectError(error.TestExpectedEqual, normalizer.compareValue(
        .{ .string = "<path>{{cwd}}/a.txt</path>\na/b" },
        .{ .string = "<path>C:\\work\\project\\a.txt</path>\na\\b" },
        .{},
    ));
    try std.testing.expectError(error.TestExpectedEqual, normalizer.compareValue(
        .{ .string = "<path>{{cwd}}/a.txt</path>" },
        .{ .string = "<path>C:\\work\\project\\b.txt</path>" },
        .{},
    ));
}

test "path normalization helpers accept 64 KiB inputs without leaking" {
    const allocator = std.testing.allocator;
    const size = 64 * 1024;
    const text = try allocator.alloc(u8, size);
    defer allocator.free(text);
    @memset(text, '\\');
    @memcpy(text[0.."<path>".len], "<path>");
    @memcpy(text[size - "</path>".len ..], "</path>");

    const path = try normalizePath(allocator, text);
    defer allocator.free(path);
    for (path) |byte| try std.testing.expect(byte != '\\');

    const marked = try normalizePathMarkers(allocator, text);
    defer allocator.free(marked);
    try std.testing.expectEqualStrings("<path>", marked[0.."<path>".len]);
    for (marked["<path>".len .. size - "</path>".len]) |byte| {
        try std.testing.expectEqual(@as(u8, '/'), byte);
    }
    try std.testing.expectEqualStrings("</path>", marked[size - "</path>".len ..]);
}
