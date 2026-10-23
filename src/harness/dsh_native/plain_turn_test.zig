//! P0 consistency test: drive a tool-less plain turn through the dsh-native
//! session log, then compare the normalized v4 JSONL with the T1 fixture.
//!
//! Fixture: test/fixtures/dsh_native/plain-turn (see manifest.json).
//! `zig build test` runs test binaries with the build root as cwd, so the
//! fixture path is relative to the repository root.
//!
//! Comparison layers (design §4.2): event type sequence, event data minus the
//! manifest's volatile fields and declared tokens, then the folded surface
//! projection (role/content/source).

const std = @import("std");
const compat = @import("compat");
const fs_compat = @import("../../fs_compat.zig");
const fixture_compare = @import("fixture_compare.zig");
const replay_provider = @import("replay_provider.zig");
const session_log = @import("session_log.zig");
const surface = @import("surface.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Obj = std.json.ObjectMap;

/// P0 replay route identity. The fixture is a fake route, so its expected
/// request/context and assistant source carry the same neutral values.
const test_provider = "fake";
const test_model = "fake";
const session_id = "dsh-native-p0-plain-turn";
const user_message_id = "msg-p0-user";
const system_message_id = "msg-p0-system";
const assistant_message_id = "msg-p0-assistant";
const system_prompt = "dsh-native P0 system prompt";
/// Volatile by the manifest; normalization zeroes createdAt on both sides.
const created_at_ms: i64 = 1_700_000_000_000;
const first_event_time_ms: i64 = 1_700_000_000_001;

const InputFile = struct {
    steps: []const Step = &.{},

    const Step = struct {
        op: []const u8 = "",
        text: ?[]const u8 = null,
    };
};

const DriverResult = struct {
    arena: std.heap.ArenaAllocator,
    events: []const types.Event,
    /// Surface as of the model request (system + user), kept alive because the
    /// replay provider borrows its messages.
    request_fold: surface.Fold,

    fn deinit(self: *DriverResult) void {
        self.request_fold.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

const Driver = struct {
    arena: Allocator,
    log: *session_log.Log,
    events: *std.ArrayListUnmanaged(types.Event),
    clock: *i64,

    fn append(self: Driver, event_type: []const u8, data: Value, surface_op: ?types.SurfaceOp) !void {
        const time_ms = self.clock.*;
        const seq = try self.log.append(event_type, data, .{ .time_ms = time_ms, .surface_op = surface_op });
        try self.events.append(self.arena, .{
            .event_type = event_type,
            .seq = seq,
            .time_ms = time_ms,
            .data = data,
            .surface_op = surface_op,
        });
        self.clock.* += 1;
    }
};

/// Drive initialize -> newSession -> prompt as the fixture's input.json asks,
/// writing the P0 event order to `log_path`.
fn drivePlainTurn(
    allocator: Allocator,
    log_path: []const u8,
    cwd: []const u8,
    prompt: []const u8,
    provider: *replay_provider.ReplayProvider,
) !DriverResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const header = types.Header{
        .id = session_id,
        .created_at = created_at_ms,
        .cwd = cwd,
        .is_seeded = false,
        .delegation_depth = 0,
    };
    var log = try session_log.Log.create(allocator, log_path, header);
    errdefer log.close();

    var events: std.ArrayListUnmanaged(types.Event) = .empty;
    var clock: i64 = first_event_time_ms;
    const driver = Driver{ .arena = arena, .log = &log, .events = &events, .clock = &clock };

    const user_json = try userMessageJson(arena, user_message_id, prompt);
    const user_value = try parseJson(arena, user_json);
    const system_json = try systemMessageJson(arena, system_message_id, system_prompt);

    try driver.append("permission/preset", try parseJson(arena, "{\"preset\":\"workspace-write\"}"), null);
    try driver.append("sandbox/mode", try parseJson(arena, "{\"mode\":\"workspace-write\"}"), null);
    try driver.append("approval/policy", try parseJson(arena, "{\"policy\":\"ask\"}"), null);
    try driver.append("agent/inbox/spliced", try parseJson(arena, try std.fmt.allocPrint(
        arena,
        "{{\"target\":\"next-turn\",\"start\":0,\"inserted\":[{s}]}}",
        .{user_json},
    )), null);
    try driver.append("turn/start", try parseJson(arena, "{\"turn\":1}"), null);
    try driver.append(
        "agent/inbox/spliced",
        try parseJson(arena, "{\"target\":\"next-turn\",\"start\":0,\"removedCount\":1,\"inserted\":[]}"),
        null,
    );
    try driver.append("step/start", try parseJson(arena, "{\"turn\":1,\"step\":1}"), null);
    try driver.append("system/message", try parseJson(arena, try std.fmt.allocPrint(
        arena,
        "{{\"turn\":1,\"step\":1,\"message\":{s}}}",
        .{system_json},
    )), .append);
    try driver.append("user/message", user_value, .append);
    // P0 advertises no tools, so the header omits `tools` (agent.ts:629).
    try driver.append(
        "request/header",
        try parseJson(arena, "{\"header\":{\"config\":{\"provider\":\"fake\",\"model\":\"fake\"}},\"reason\":\"initial\"}"),
        null,
    );
    try driver.append("request/context", try parseJson(arena, "{\"provider\":\"fake\",\"model\":\"fake\"}"), null);

    var request_fold = try surface.fold(allocator, events.items);
    errdefer request_fold.deinit();
    const messages = try arena.alloc(types.Message, request_fold.nodes.len);
    for (request_fold.nodes, 0..) |node, index| messages[index] = node.message;
    const stream = try provider.complete(.{
        .provider = test_provider,
        .model = test_model,
        .messages = messages,
    });

    const reply = try streamText(arena, stream);
    const assistant_json = try assistantMessageJson(arena, assistant_message_id, reply);
    const stream_json = try std.json.Stringify.valueAlloc(arena, try streamValue(arena, stream), .{});
    try driver.append("assistant/message", try parseJson(arena, try std.fmt.allocPrint(
        arena,
        "{{\"turn\":1,\"step\":1,\"message\":{s},\"stream\":{s}}}",
        .{ assistant_json, stream_json },
    )), .append);
    try driver.append("step/end", try parseJson(arena, "{\"turn\":1,\"step\":1}"), null);
    try driver.append("turn/end", try parseJson(arena, "{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}"), null);

    const event_slice = try events.toOwnedSlice(arena);
    log.close();
    return .{ .arena = arena_state, .events = event_slice, .request_fold = request_fold };
}

/// Concatenate the text carried by packed `text-chunks` records.
fn streamText(allocator: Allocator, stream: []const Value) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    for (stream) |record| {
        const object = switch (record) {
            .object => |object| object,
            else => return error.InvalidReplayStream,
        };
        const kind = try requiredString(object, "type");
        if (std.mem.eql(u8, kind, "text-chunks")) {
            const texts = object.get("texts") orelse return error.InvalidReplayStream;
            switch (texts) {
                .array => |array| for (array.items) |text| {
                    try out.writer.writeAll(try asString(text));
                },
                else => return error.InvalidReplayStream,
            }
        } else if (!std.mem.eql(u8, kind, "chunk")) {
            // shortcut: only text-chunks/finish records are expanded; add tool-call-chunks when P1 enables tools.
            return error.UnsupportedReplayChunk;
        }
    }
    return out.toOwnedSlice();
}

fn streamValue(allocator: Allocator, stream: []const Value) !Value {
    var array = std.json.Array.init(allocator);
    try array.ensureTotalCapacity(stream.len);
    for (stream) |record| array.appendAssumeCapacity(record);
    return .{ .array = array };
}

fn userMessageJson(allocator: Allocator, id: []const u8, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"source\":{{\"kind\":\"user\"}},\"role\":\"user\",\"id\":{s}}}",
        .{ try quote(allocator, text), try quote(allocator, id) },
    );
}

fn systemMessageJson(allocator: Allocator, id: []const u8, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"role\":\"system\",\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"source\":{{\"kind\":\"system-prompt\"}},\"id\":{s}}}",
        .{ try quote(allocator, text), try quote(allocator, id) },
    );
}

fn assistantMessageJson(allocator: Allocator, id: []const u8, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"role\":\"assistant\",\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"source\":{{\"kind\":\"model\",\"provider\":{s},\"model\":{s}}},\"id\":{s}}}",
        .{
            try quote(allocator, text),
            try quote(allocator, test_provider),
            try quote(allocator, test_model),
            try quote(allocator, id),
        },
    );
}

fn quote(allocator: Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, Value{ .string = text }, .{});
}

fn parseJson(allocator: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, allocator, text, .{ .allocate = .alloc_always });
}

fn parseJsonl(allocator: Allocator, bytes: []const u8) ![]Value {
    var records: std.ArrayListUnmanaged(Value) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try records.append(allocator, try parseJson(allocator, trimmed));
    }
    return records.toOwnedSlice(allocator);
}

fn readFixture(allocator: Allocator, name: []const u8) ![]u8 {
    // Components keep the path native on every platform; tests run with the
    // build root as cwd.
    const path = try std.fs.path.join(allocator, &.{ "test", "fixtures", "dsh_native", "plain-turn", name });
    defer allocator.free(path);
    return fs_compat.readFileAlloc(compat.fs.cwd(), allocator, path, 1 << 20);
}

/// Turn the expected JSONL records (which omit seq/time) into typed events for
/// the surface fold. Seqs follow log order, matching the written log.
fn eventsFromRecords(allocator: Allocator, records: []const Value) ![]types.Event {
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

fn loadDeclaredTokens(
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

fn requiredString(object: Obj, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.FixtureMismatch;
    return asString(value);
}

fn asString(value: Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.FixtureMismatch,
    };
}

test "dsh native plain-turn matches normalized v4 fixture" {
    const allocator = std.testing.allocator;

    var fixture_arena = std.heap.ArenaAllocator.init(allocator);
    defer fixture_arena.deinit();
    const fixture_allocator = fixture_arena.allocator();

    const input_bytes = try readFixture(allocator, "input.json");
    defer allocator.free(input_bytes);
    const input = try std.json.parseFromSliceLeaky(InputFile, fixture_allocator, input_bytes, .{
        .ignore_unknown_fields = true,
    });
    try std.testing.expectEqual(@as(usize, 3), input.steps.len);
    try std.testing.expectEqualStrings("initialize", input.steps[0].op);
    try std.testing.expectEqualStrings("newSession", input.steps[1].op);
    try std.testing.expectEqualStrings("prompt", input.steps[2].op);
    const prompt = input.steps[2].text orelse return error.MissingPrompt;

    const replay_bytes = try readFixture(allocator, "replay.json");
    defer allocator.free(replay_bytes);
    var provider = try replay_provider.ReplayProvider.initFromJson(allocator, replay_bytes);
    defer provider.deinit();

    const expected_bytes = try readFixture(allocator, "expected.v4.jsonl");
    defer allocator.free(expected_bytes);
    const expected_records = try parseJsonl(fixture_allocator, expected_bytes);

    const manifest_bytes = try readFixture(allocator, "manifest.json");
    defer allocator.free(manifest_bytes);
    const manifest = try parseJson(fixture_allocator, manifest_bytes);
    var declared_tokens: std.StringHashMapUnmanaged(void) = .empty;
    var ordinal_tokens: std.StringHashMapUnmanaged(void) = .empty;
    try loadDeclaredTokens(fixture_allocator, manifest, &declared_tokens, &ordinal_tokens);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = compat.fs.Dir.wrap(tmp.dir);
    const tmp_path = try tmp_dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const log_path = try std.fs.path.join(allocator, &.{ tmp_path, "session.v4.jsonl" });
    defer allocator.free(log_path);

    var run = try drivePlainTurn(allocator, log_path, tmp_path, prompt, &provider);
    defer run.deinit();

    const actual_bytes = try fs_compat.readFileAlloc(compat.fs.cwd(), allocator, log_path, 1 << 20);
    defer allocator.free(actual_bytes);
    const actual_records = try parseJsonl(fixture_allocator, actual_bytes);
    try std.testing.expectEqual(expected_records.len, actual_records.len);

    var normalizer = fixture_compare.Normalizer{
        .arena = fixture_allocator,
        .declared = &declared_tokens,
        .ordinal = &ordinal_tokens,
    };
    var type_names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (expected_records, actual_records, 0..) |expected, actual, index| {
        try normalizer.compareRecord(expected, actual, index == 0);
        const actual_object = switch (actual) {
            .object => |object| object,
            else => return error.FixtureMismatch,
        };
        try type_names.append(fixture_allocator, try requiredString(actual_object, "type"));
    }

    var log = try session_log.readLog(allocator, log_path);
    defer log.deinit();
    const expected_events = try eventsFromRecords(fixture_allocator, expected_records);
    var expected_fold = try surface.fold(allocator, expected_events);
    defer expected_fold.deinit();
    var actual_fold = try surface.fold(allocator, log.events);
    defer actual_fold.deinit();

    try std.testing.expectEqual(expected_fold.nodes.len, actual_fold.nodes.len);
    for (expected_fold.nodes, actual_fold.nodes) |expected_node, actual_node| {
        try std.testing.expectEqual(expected_node.seq, actual_node.seq);
        try normalizer.expectMessagesMatch(expected_node.message, actual_node.message);
    }

    const requests = provider.recordedRequests();
    try std.testing.expectEqual(@as(usize, 1), requests.len);
    try std.testing.expectEqualStrings(test_provider, requests[0].provider);
    try std.testing.expectEqualStrings(test_model, requests[0].model);
    try std.testing.expectEqual(@as(usize, 2), requests[0].messages.len);
    try std.testing.expect(expected_fold.nodes.len >= 2);
    for (requests[0].messages, expected_fold.nodes[0..2]) |actual_message, expected_node| {
        try normalizer.expectMessagesMatch(expected_node.message, actual_message);
    }

    std.debug.print("dsh_native plain-turn types: {s}\n", .{try std.mem.join(fixture_allocator, ",", type_names.items)});
    std.debug.print(
        "dsh_native plain-turn: lines={d} surface_nodes={d} request_messages={d} declared_tokens={d}\n",
        .{ actual_records.len, actual_fold.nodes.len, requests[0].messages.len, declared_tokens.count() },
    );
}
