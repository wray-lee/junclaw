//! Model-facing `todo_write` tool over the calling agent's session log
//! (design B25b; dsh `packages/todo/tool-todo/src/index.ts:113-209`).
//!
//! Whole-list replacement: every successful call appends one `todo/write`
//! event carrying the complete canonical list, so replay is last-write-wins
//! and consumers fold the log; this tool keeps no projection of its own.
//! Names, description, input schema and model-facing text are the generated
//! dsh constants. The execute pipeline enforces the argument shape (known item
//! keys, string content, status enum) before the handler runs, mirroring dsh
//! `defineTool`; the value constraints dsh applies in `toTodoList` live here:
//! trimmed non-empty unique content and the single-active discipline.

const std = @import("std");
const compat = @import("compat");
const generated = @import("../generated/tool_schemas.zig");
const render = @import("../generated/tool_render.zig");
const registry = @import("registry.zig");
const session_log = @import("../session_log.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// dsh `allowParallelInProgress`: the base deployment sets it true, but the
/// generated description and error text encode the single-active discipline,
/// so this port validates against the text the model actually sees.
pub const allow_parallel_in_progress = false;

/// ASCII whitespace, what JSON tool arguments carry in practice. dsh trims the
/// full Unicode space set; non-ASCII padding is left in place here.
/// shortcut: ASCII-only trim, extend if a real caller pads with Unicode spaces.
const trim_chars = " \t\n\r\x0b\x0c";

pub const Context = struct {
    /// The calling agent's session log. Null means no owning agent session:
    /// dsh rejects the write instead of silently dropping the list.
    log: ?*session_log.Log = null,

    pub fn handler(self: *Context) registry.Handler {
        return .{ .context = @ptrCast(self), .call = call };
    }

    pub fn register(self: *Context, reg: *registry.Registry, allocator: Allocator) !void {
        try reg.register(allocator, .{
            .name = generated.todo_write.name,
            .description = generated.todo_write.description,
            .input_schema_json = generated.todo_write.input_schema_json,
            .handler = self.handler(),
        });
    }
};

const Counts = struct {
    pending: usize = 0,
    in_progress: usize = 0,
    completed: usize = 0,
};

const Invalid = union(enum) {
    empty_content,
    duplicate: []const u8,
    parallel_in_progress: usize,
};

fn call(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const self: *Context = @ptrCast(@alignCast(context.?));
    // execute.zig rejects malformed arguments against the generated schema, so
    // every item has a string `content`, a known `status`, and no extra keys
    // (dsh `additionalProperties: false`).
    const raw = args.object.get("todos").?.array.items;

    if (validate(raw)) |invalid| return switch (invalid) {
        .empty_content => failure(allocator, "INVALID_TODO", render.todo_write.error_empty_content),
        .duplicate => |content| duplicateFailure(allocator, content),
        .parallel_in_progress => |count| parallelFailure(allocator, count),
    };

    const log = self.log orelse
        return failure(allocator, "NO_AGENT", render.todo_write.error_requires_agent);

    // Append the whole-list snapshot before reporting success: a failed write
    // fails the call instead of claiming a list the session never recorded.
    const snapshot = try encodeSnapshot(allocator, raw);
    _ = log.append("todo/write", .{ .object = snapshot.data }, .{}) catch
        return failure(allocator, "LOG_WRITE_FAILED", "todo_write could not append the session event");

    const text = try std.fmt.allocPrint(allocator, render.todo_write.success, .{
        snapshot.counts.pending,
        snapshot.counts.in_progress,
        snapshot.counts.completed,
    });
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = text };
    return .{ .success = .{
        .content = blocks,
        .meta = try encodeOutput(allocator, snapshot),
    } };
}

/// dsh `toTodoList` constraints, in its order: per-item trimmed non-empty
/// content, then duplicate trimmed content, then at most one `in_progress`
/// when parallel work is off.
fn validate(raw: []const Value) ?Invalid {
    var active: usize = 0;
    for (raw, 0..) |entry, index| {
        const content = trimmedContent(entry);
        if (content.len == 0) return .empty_content;
        for (raw[0..index]) |previous| {
            if (std.mem.eql(u8, trimmedContent(previous), content)) {
                return .{ .duplicate = content };
            }
        }
        if (std.mem.eql(u8, entry.object.get("status").?.string, "in_progress")) active += 1;
    }
    if (active > 1 and !allow_parallel_in_progress) {
        return .{ .parallel_in_progress = active };
    }
    return null;
}

fn trimmedContent(entry: Value) []const u8 {
    return std.mem.trim(u8, entry.object.get("content").?.string, trim_chars);
}

const Snapshot = struct {
    /// `{"todos":[...]}` — the `todo/write` event payload of dsh `types.ts`.
    data: std.json.ObjectMap,
    counts: Counts,
};

fn encodeSnapshot(allocator: Allocator, raw: []const Value) !Snapshot {
    var array = std.json.Array.init(allocator);
    try array.ensureTotalCapacity(raw.len);
    var counts: Counts = .{};
    for (raw) |entry| {
        const status = entry.object.get("status").?.string;
        var item: std.json.ObjectMap = .empty;
        try item.put(allocator, "content", .{ .string = trimmedContent(entry) });
        try item.put(allocator, "status", .{ .string = status });
        array.appendAssumeCapacity(.{ .object = item });
        if (std.mem.eql(u8, status, "pending")) counts.pending += 1;
        if (std.mem.eql(u8, status, "in_progress")) counts.in_progress += 1;
        if (std.mem.eql(u8, status, "completed")) counts.completed += 1;
    }
    var data: std.json.ObjectMap = .empty;
    try data.put(allocator, "todos", .{ .array = array });
    return .{ .data = data, .counts = counts };
}

/// dsh tool output value: `{todos, counts:{pending,inProgress,completed}}`.
/// Extends the snapshot map after the event serialized, so both share one
/// `todos` array.
fn encodeOutput(allocator: Allocator, snapshot: Snapshot) !Value {
    var counts: std.json.ObjectMap = .empty;
    try counts.put(allocator, "pending", .{ .integer = @intCast(snapshot.counts.pending) });
    try counts.put(allocator, "inProgress", .{ .integer = @intCast(snapshot.counts.in_progress) });
    try counts.put(allocator, "completed", .{ .integer = @intCast(snapshot.counts.completed) });
    var output = snapshot.data;
    try output.put(allocator, "counts", .{ .object = counts });
    return .{ .object = output };
}

fn duplicateFailure(allocator: Allocator, content: []const u8) !registry.ToolResult {
    const quoted = try std.json.Stringify.valueAlloc(allocator, content, .{});
    defer allocator.free(quoted);
    const message = try std.fmt.allocPrint(allocator, render.todo_write.error_duplicate_content, .{quoted});
    return failure(allocator, "INVALID_TODO", message);
}

fn parallelFailure(allocator: Allocator, count: usize) !registry.ToolResult {
    const message = try std.fmt.allocPrint(allocator, render.todo_write.error_parallel_in_progress, .{count});
    return failure(allocator, "INVALID_TODO", message);
}

/// dsh wraps a thrown tool error as `Error: <message>` with no `error.info`.
fn failure(allocator: Allocator, code: []const u8, message: []const u8) !registry.ToolResult {
    const text = try std.fmt.allocPrint(allocator, "Error: {s}", .{message});
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = text };
    return .{ .failure = .{
        .error_info = .{ .name = "Error", .code = code, .reason = message },
        .content = blocks,
    } };
}

// Tests

const testing = std.testing;
const execute = @import("execute.zig");

fn callArgs(arguments: []const u8) types.ToolCall {
    return .{ .id = "call-todo-1", .name = "todo_write", .arguments = arguments };
}

fn expectSuccessText(result: registry.ToolResult, expected: []const u8) !void {
    try testing.expect(!result.isError());
    try testing.expectEqual(@as(usize, 1), result.content().len);
    try testing.expectEqualStrings(expected, result.content()[0].text);
}

fn expectFailure(result: registry.ToolResult, code: []const u8, text: []const u8) !void {
    try testing.expect(result.isError());
    switch (result) {
        .failure => |failure_value| {
            try testing.expectEqualStrings("Error", failure_value.error_info.name);
            try testing.expectEqualStrings(code, failure_value.error_info.code);
        },
        .success => return error.ExpectedFailure,
    }
    try testing.expectEqual(@as(usize, 1), result.content().len);
    try testing.expectEqualStrings(text, result.content()[0].text);
}

/// Session log fixture for the handler's append path.
const TestLog = struct {
    tmp: std.testing.TmpDir,
    dir: []const u8,
    path: []const u8,
    log: session_log.Log,
    closed: bool = false,

    fn init(allocator: Allocator) !TestLog {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
        errdefer allocator.free(dir);
        const path = try std.fs.path.join(allocator, &.{ dir, "session.jsonl" });
        errdefer allocator.free(path);
        return .{
            .tmp = tmp,
            .dir = dir,
            .path = path,
            .log = try session_log.Log.create(allocator, path, .{ .id = "session-todo", .created_at = 1 }),
        };
    }

    fn close(self: *TestLog) void {
        if (self.closed) return;
        self.log.close();
        self.closed = true;
    }

    fn deinit(self: *TestLog, allocator: Allocator) void {
        self.close();
        allocator.free(self.path);
        allocator.free(self.dir);
        self.tmp.cleanup();
    }
};

fn readEvents(fixture: *TestLog) !session_log.ReadResult {
    fixture.close();
    return session_log.readLog(testing.allocator, fixture.path);
}

test "todo_write replaces the whole list and appends one todo/write snapshot per call" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try TestLog.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var context = Context{ .log = &fixture.log };
    var reg = registry.Registry.init();
    defer reg.deinit(testing.allocator);
    try context.register(&reg, testing.allocator);

    const first = try execute.execute(&reg, arena, callArgs(
        "{\"todos\":[{\"content\":\"  first  \",\"status\":\"pending\"},{\"content\":\"second\",\"status\":\"in_progress\"}]}",
    ));
    try expectSuccessText(first, "Updated todo list: 1 pending, 1 in progress, 0 completed.");
    const first_meta = first.success.meta.?.object;
    try testing.expectEqual(@as(i64, 1), first_meta.get("counts").?.object.get("pending").?.integer);
    try testing.expectEqualStrings("first", first_meta.get("todos").?.array.items[0].object.get("content").?.string);

    const second = try execute.execute(&reg, arena, callArgs(
        "{\"todos\":[{\"content\":\"only\",\"status\":\"completed\"}]}",
    ));
    try expectSuccessText(second, "Updated todo list: 0 pending, 0 in progress, 1 completed.");

    var read = try readEvents(&fixture);
    defer read.deinit();
    try testing.expectEqual(@as(usize, 2), read.events.len);

    const first_event = read.events[0];
    try testing.expectEqualStrings("todo/write", first_event.event_type);
    try testing.expectEqual(@as(u64, 0), first_event.seq);
    try testing.expectEqual(@as(usize, 1), first_event.data.object.count());
    const first_todos = first_event.data.object.get("todos").?.array.items;
    try testing.expectEqual(@as(usize, 2), first_todos.len);
    try testing.expectEqual(@as(usize, 2), first_todos[0].object.count());
    try testing.expectEqualStrings("first", first_todos[0].object.get("content").?.string);
    try testing.expectEqualStrings("pending", first_todos[0].object.get("status").?.string);
    try testing.expectEqualStrings("second", first_todos[1].object.get("content").?.string);
    try testing.expectEqualStrings("in_progress", first_todos[1].object.get("status").?.string);

    // Last write wins: the second snapshot is the whole replacement list.
    const second_todos = read.events[1].data.object.get("todos").?.array.items;
    try testing.expectEqual(@as(usize, 1), second_todos.len);
    try testing.expectEqualStrings("only", second_todos[0].object.get("content").?.string);
    try testing.expectEqualStrings("completed", second_todos[0].object.get("status").?.string);
}

test "todo_write accepts an empty list and records an empty snapshot" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try TestLog.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var context = Context{ .log = &fixture.log };
    var reg = registry.Registry.init();
    defer reg.deinit(testing.allocator);
    try context.register(&reg, testing.allocator);

    const result = try execute.execute(&reg, arena, callArgs("{\"todos\":[]}"));
    try expectSuccessText(result, "Updated todo list: 0 pending, 0 in progress, 0 completed.");
    try testing.expectEqual(@as(usize, 0), result.success.meta.?.object.get("todos").?.array.items.len);

    var read = try readEvents(&fixture);
    defer read.deinit();
    try testing.expectEqual(@as(usize, 1), read.events.len);
    try testing.expectEqual(@as(usize, 0), read.events[0].data.object.get("todos").?.array.items.len);
}

test "todo_write rejects invalid status and nested item shapes at the schema boundary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try TestLog.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var context = Context{ .log = &fixture.log };
    var reg = registry.Registry.init();
    defer reg.deinit(testing.allocator);
    try context.register(&reg, testing.allocator);

    const bad_status = try execute.execute(&reg, arena, callArgs(
        "{\"todos\":[{\"content\":\"task\",\"status\":\"done\"}]}",
    ));
    try expectSchemaFailure(bad_status);

    // `content` must be a string, not a nested object.
    const nested_content = try execute.execute(&reg, arena, callArgs(
        "{\"todos\":[{\"content\":{\"text\":\"task\"},\"status\":\"pending\"}]}",
    ));
    try expectSchemaFailure(nested_content);

    // Item objects are closed (`additionalProperties: false`): an unknown
    // nested key rejects the whole call instead of being silently dropped.
    const extra_key = try execute.execute(&reg, arena, callArgs(
        "{\"todos\":[{\"content\":\"task\",\"status\":\"pending\",\"subtasks\":[]}]}",
    ));
    try expectSchemaFailure(extra_key);

    var read = try readEvents(&fixture);
    defer read.deinit();
    try testing.expectEqual(@as(usize, 0), read.events.len);
}

fn expectSchemaFailure(result: registry.ToolResult) !void {
    try testing.expect(result.isError());
    switch (result) {
        .failure => |failure_value| {
            try testing.expectEqualStrings("ToolArgsError", failure_value.error_info.name);
            try testing.expectEqualStrings("INVALID_ARGS", failure_value.error_info.code);
        },
        .success => return error.ExpectedFailure,
    }
    try testing.expect(std.mem.startsWith(u8, result.content()[0].text, "Error: invalid arguments: "));
}

test "todo_write rejects empty and duplicate content without appending" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try TestLog.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var context = Context{ .log = &fixture.log };
    var reg = registry.Registry.init();
    defer reg.deinit(testing.allocator);
    try context.register(&reg, testing.allocator);

    const empty = try execute.execute(&reg, arena, callArgs(
        "{\"todos\":[{\"content\":\"  \\t  \",\"status\":\"pending\"}]}",
    ));
    try expectFailure(empty, "INVALID_TODO", "Error: invalid todo: `content` must be a non-empty string");

    // Duplicates compare after trimming, and the message quotes the content.
    const duplicate = try execute.execute(&reg, arena, callArgs(
        "{\"todos\":[{\"content\":\"task\",\"status\":\"pending\"},{\"content\":\" task \",\"status\":\"in_progress\"}]}",
    ));
    try expectFailure(duplicate, "INVALID_TODO", "Error: invalid todos: duplicate content \"task\"");

    var read = try readEvents(&fixture);
    defer read.deinit();
    try testing.expectEqual(@as(usize, 0), read.events.len);
}

test "todo_write rejects more than one in_progress todo" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try TestLog.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var context = Context{ .log = &fixture.log };
    var reg = registry.Registry.init();
    defer reg.deinit(testing.allocator);
    try context.register(&reg, testing.allocator);

    const result = try execute.execute(&reg, arena, callArgs(
        "{\"todos\":[{\"content\":\"one\",\"status\":\"in_progress\"},{\"content\":\"two\",\"status\":\"in_progress\"}]}",
    ));
    try expectFailure(result, "INVALID_TODO", "Error: invalid todos: at most one task may be in_progress (got 2)");

    var read = try readEvents(&fixture);
    defer read.deinit();
    try testing.expectEqual(@as(usize, 0), read.events.len);
}

test "todo_write requires an owning agent session after value validation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var context = Context{};
    var reg = registry.Registry.init();
    defer reg.deinit(testing.allocator);
    try context.register(&reg, testing.allocator);

    const no_agent = try execute.execute(&reg, arena, callArgs(
        "{\"todos\":[{\"content\":\"task\",\"status\":\"pending\"}]}",
    ));
    try expectFailure(no_agent, "NO_AGENT", "Error: todo_write requires an owning agent session");

    // dsh runs `toTodoList` first, so a bad list still reports its own error.
    const empty = try execute.execute(&reg, arena, callArgs(
        "{\"todos\":[{\"content\":\"\",\"status\":\"pending\"}]}",
    ));
    try expectFailure(empty, "INVALID_TODO", "Error: invalid todo: `content` must be a non-empty string");
}

test "todo_write keeps a 64KB list intact without leaking" {
    var fixture = try TestLog.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var context = Context{ .log = &fixture.log };
    var reg = registry.Registry.init();
    defer reg.deinit(testing.allocator);
    try context.register(&reg, testing.allocator);

    const big_len = 64 * 1024 + 1;
    const big = try testing.allocator.alloc(u8, big_len);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const arguments = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"todos\":[{{\"content\":\"{s}\",\"status\":\"completed\"}}]}}",
        .{big},
    );
    defer testing.allocator.free(arguments);
    var parsed = try std.json.parseFromSlice(Value, testing.allocator, arguments, .{});
    defer parsed.deinit();

    // Regression: the result must own every byte it exposes; a leak test with
    // a caller-owned allocator catches intermediate buffers on the big path.
    const result = try reg.invoke(testing.allocator, "todo_write", parsed.value);
    defer freeResult(testing.allocator, result);

    try expectSuccessText(result, "Updated todo list: 0 pending, 0 in progress, 1 completed.");
    const meta_content = result.success.meta.?.object.get("todos").?.array.items[0].object.get("content").?.string;
    try testing.expectEqual(big_len, meta_content.len);

    var read = try readEvents(&fixture);
    defer read.deinit();
    const snapshot_content = read.events[0].data.object.get("todos").?.array.items[0].object.get("content").?.string;
    try testing.expectEqual(big_len, snapshot_content.len);
}

/// Deep-free a success built by `call` with a caller-owned allocator. String
/// values borrow the parsed arguments, so only the containers are freed.
fn freeResult(allocator: Allocator, result: registry.ToolResult) void {
    switch (result) {
        .success => |success| {
            allocator.free(success.content[0].text);
            if (success.meta) |meta| freeValue(allocator, meta);
        },
        .failure => {},
    }
    allocator.free(result.content());
}

fn freeValue(allocator: Allocator, value: Value) void {
    switch (value) {
        .object => |object_value| {
            var object = object_value;
            var entries = object.iterator();
            while (entries.next()) |entry| freeValue(allocator, entry.value_ptr.*);
            object.deinit(allocator);
        },
        .array => |array_value| {
            var array = array_value;
            for (array.items) |item| freeValue(allocator, item);
            array.deinit();
        },
        else => {},
    }
}

test "todo.Context.register binds the generated todo_write schema" {
    var reg = registry.Registry.init();
    defer reg.deinit(testing.allocator);
    var context = Context{};
    try context.register(&reg, testing.allocator);

    const tool = reg.get(generated.todo_write.name) orelse return error.MissingTool;
    try testing.expectEqualStrings(generated.todo_write.name, tool.name);
    try testing.expectEqualStrings(generated.todo_write.description, tool.description);
    try testing.expectEqualStrings(generated.todo_write.input_schema_json, tool.input_schema_json);
    try testing.expect(tool.handler.call == call);
}
