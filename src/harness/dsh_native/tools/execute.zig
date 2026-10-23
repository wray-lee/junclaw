//! Single tool-call execution pipeline: registry lookup, argument parsing and
//! validation, handler dispatch and B25 result construction (design §1.2
//! B21/B24 execution half, B25, §3.1 tools boundary).
//!
//! Mirrors dsh `packages/core/agent-loop/src/tool-calls.ts:104-110` argument
//! parsing and the dispatch half of `packages/core/tools/src/index.ts`:
//! empty arguments become `{}`, unparseable JSON stays raw text (so the root
//! object check reports it), unknown tools fail before validation, and schema
//! violations become `ToolArgsError`/`INVALID_ARGS` results before a handler
//! runs. A thrown handler error cannot prove whether side effects happened, so
//! it maps to the conservative B23 recovery result
//! (`ToolOutcomeUnknownError`/`TOOL_OUTCOME_UNKNOWN`).
//!
//! Approval, pre-execute, the execute waterfall and post-result policy are P2;
//! this module deliberately has no hook points for them.

const std = @import("std");
const registry = @import("registry.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Violations = std.ArrayListUnmanaged([]const u8);

pub const ExecuteError = error{ OutOfMemory, InvalidToolSchema };

/// Pre-dispatch hook (design B24): bind per-call state and run the approval
/// gate before any handler sees the call. Returning a reason denies the call
/// with a structured `isError` result; null allows it.
pub const Gate = struct {
    context: *anyopaque,
    decide: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        call: types.ToolCall,
        args: Value,
    ) anyerror!?[]const u8,
};

/// `CLOSER_TEXT.interrupted.started` from dsh `core/session/src/repair.ts`: a
/// started call whose outcome was never recorded, so retries must be careful.
const outcome_unknown_text =
    "The tool call was recorded and invoked, but no result was durably recorded. Its outcome is unknown. " ++
    "Decide whether to retry from the tool semantics: retry only if the operation is read-only or idempotent; " ++
    "if it may have side effects, first verify external state or ask the user. Do not retry blindly.";

/// Execute one model-issued tool call.
///
/// Model input never panics and never escapes as a Zig error: unknown tools,
/// malformed arguments and schema violations return structured `isError`
/// results. Only allocation failure and a malformed registered schema escape.
/// `allocator` must outlive the result (the scheduler's step arena).
pub fn execute(
    reg: *const registry.Registry,
    allocator: Allocator,
    call: types.ToolCall,
) ExecuteError!registry.ToolResult {
    return executeWithGate(reg, allocator, call, null);
}

/// Same pipeline with an optional pre-dispatch gate. Non-core registered
/// schemas (`ask_user_question`) are resolved through the exact-name map;
/// aliases still only resolve through `Registry.get`.
pub fn executeWithGate(
    reg: *const registry.Registry,
    allocator: Allocator,
    call: types.ToolCall,
    gate: ?Gate,
) ExecuteError!registry.ToolResult {
    const tool = reg.get(call.name) orelse blk: {
        const entry = reg.tools.getPtr(call.name) orelse return unknownTool(allocator, call.name);
        break :blk entry;
    };

    // dsh keeps unparseable arguments as raw text; the schema walk then reports
    // `"arguments" must be an object` instead of a JSON syntax error.
    const args: Value = if (call.arguments.len == 0)
        .{ .object = .empty }
    else
        std.json.parseFromSliceLeaky(Value, allocator, call.arguments, .{}) catch
            Value{ .string = call.arguments };

    const violations = try collectViolations(allocator, tool.input_schema_json, args);
    if (violations.len != 0) return invalidArguments(allocator, violations);

    if (gate) |hook| {
        const denial = hook.decide(hook.context, allocator, call, args) catch |err|
            return recovery(allocator, @errorName(err));
        if (denial) |reason| {
            const text = try std.fmt.allocPrint(allocator, "Error: {s}", .{reason});
            return failure(allocator, "ToolApprovalError", "APPROVAL_DENIED", reason, text);
        }
    }

    var result = tool.handler.call(tool.handler.context, allocator, args) catch |err| {
        if (err == error.UnknownTool) return unknownTool(allocator, call.name);
        return recovery(allocator, @errorName(err));
    };
    if (tool.wrap) |wrap| {
        const extra = wrap.render(wrap.context, allocator, args, &result) catch |err|
            return recovery(allocator, @errorName(err));
        try result.appendContent(allocator, extra);
    }
    return result;
}

fn collectViolations(
    allocator: Allocator,
    schema_json: []const u8,
    args: Value,
) ExecuteError![]const []const u8 {
    const schema = std.json.parseFromSliceLeaky(Value, allocator, schema_json, .{}) catch
        return error.InvalidToolSchema;
    var violations: Violations = .empty;
    try collect(allocator, &violations, schema, args, "");
    return violations.items;
}

/// Walk one value against one raw JSON Schema node. Only the keywords the
/// generated core schemas (and dsh's parameter root) use are enforced:
/// `type`, `properties`, `required`, `additionalProperties:false` and `items`.
/// shortcut: enum/const/oneOf are not evaluated; extend before registering a
/// schema that relies on them.
fn collect(
    allocator: Allocator,
    out: *Violations,
    schema: Value,
    value: Value,
    path: []const u8,
) ExecuteError!void {
    const node = switch (schema) {
        .object => |object| object,
        else => return error.InvalidToolSchema,
    };
    const type_name = try optionalString(node, "type") orelse return;
    if (!try checkType(allocator, out, type_name, value, path)) return;

    if (std.mem.eql(u8, type_name, "object")) {
        const object = value.object;
        const properties = try optionalObject(node, "properties");

        // dsh checks required keys first, then declared children, then extras.
        if (try optionalArray(node, "required")) |required| {
            for (required.items) |entry| {
                const key = switch (entry) {
                    .string => |key| key,
                    else => return error.InvalidToolSchema,
                };
                if (object.get(key) != null) continue;
                try addViolation(allocator, out, "missing required property \"{s}\"", .{
                    try propertyPath(allocator, path, key),
                });
            }
        }

        if (properties) |declared| {
            var children = declared.iterator();
            while (children.next()) |entry| {
                const child = object.get(entry.key_ptr.*) orelse continue;
                try collect(
                    allocator,
                    out,
                    entry.value_ptr.*,
                    child,
                    try propertyPath(allocator, path, entry.key_ptr.*),
                );
            }
        }

        if (node.get("additionalProperties")) |additional| {
            const forbidden = switch (additional) {
                .bool => |allowed| !allowed,
                else => false, // dsh only enforces the literal `false`
            };
            if (forbidden) {
                var entries = object.iterator();
                while (entries.next()) |entry| {
                    const declared = if (properties) |known|
                        known.get(entry.key_ptr.*) != null
                    else
                        false;
                    if (declared) continue;
                    try addViolation(
                        allocator,
                        out,
                        "\"{s}\" is not a declared property (additionalProperties: false)",
                        .{try propertyPath(allocator, path, entry.key_ptr.*)},
                    );
                }
            }
        }
    } else if (std.mem.eql(u8, type_name, "array")) {
        const array = value.array;
        const item_schema = node.get("items") orelse return;
        for (array.items, 0..) |entry, index| {
            try collect(
                allocator,
                out,
                item_schema,
                entry,
                try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index }),
            );
        }
    }
}

fn checkType(
    allocator: Allocator,
    out: *Violations,
    type_name: []const u8,
    value: Value,
    path: []const u8,
) ExecuteError!bool {
    if (std.mem.eql(u8, type_name, "json")) return true;
    if (std.mem.eql(u8, type_name, "number")) {
        switch (value) {
            .integer => return true,
            .float => |number| if (std.math.isFinite(number)) return true,
            .number_string => return appendViolation(allocator, out, path, "must be a finite JSON number"),
            else => {},
        }
        return appendViolation(allocator, out, path, "must be a number");
    }
    if (std.mem.eql(u8, type_name, "integer")) {
        switch (value) {
            .integer => return true,
            .float => |number| if (std.math.isFinite(number) and @trunc(number) == number) return true,
            else => {},
        }
        return appendViolation(allocator, out, path, "must be an integer");
    }
    if (std.mem.eql(u8, type_name, "string")) return expectTag(allocator, out, path, value, .string, "must be a string");
    if (std.mem.eql(u8, type_name, "boolean")) return expectTag(allocator, out, path, value, .bool, "must be a boolean");
    if (std.mem.eql(u8, type_name, "null")) return expectTag(allocator, out, path, value, .null, "must be null");
    if (std.mem.eql(u8, type_name, "array")) return expectTag(allocator, out, path, value, .array, "must be an array");
    if (std.mem.eql(u8, type_name, "object")) return expectTag(allocator, out, path, value, .object, "must be an object");
    return error.InvalidToolSchema;
}

fn expectTag(
    allocator: Allocator,
    out: *Violations,
    path: []const u8,
    value: Value,
    comptime tag: std.meta.Tag(Value),
    comptime message: []const u8,
) ExecuteError!bool {
    if (std.meta.activeTag(value) == tag) return true;
    return appendViolation(allocator, out, path, message);
}

fn appendViolation(
    allocator: Allocator,
    out: *Violations,
    path: []const u8,
    message: []const u8,
) ExecuteError!bool {
    try addViolation(allocator, out, "\"{s}\" {s}", .{ diagnosticPath(path), message });
    return false;
}

fn addViolation(
    allocator: Allocator,
    out: *Violations,
    comptime format: []const u8,
    args: anytype,
) ExecuteError!void {
    try out.append(allocator, try std.fmt.allocPrint(allocator, format, args));
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ExecuteError!?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidToolSchema,
    };
}

fn optionalObject(object: std.json.ObjectMap, key: []const u8) ExecuteError!?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .object => |child| child,
        else => error.InvalidToolSchema,
    };
}

fn optionalArray(object: std.json.ObjectMap, key: []const u8) ExecuteError!?std.json.Array {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .array => |child| child,
        else => error.InvalidToolSchema,
    };
}

fn diagnosticPath(path: []const u8) []const u8 {
    return if (path.len == 0) "arguments" else path;
}

fn propertyPath(allocator: Allocator, path: []const u8, key: []const u8) ExecuteError![]const u8 {
    if (path.len == 0) return key;
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, key });
}

fn invalidArguments(allocator: Allocator, violations: []const []const u8) ExecuteError!registry.ToolResult {
    const joined = try std.mem.join(allocator, "; ", violations);
    const reason = try std.fmt.allocPrint(allocator, "invalid arguments: {s}", .{joined});
    const text = try std.fmt.allocPrint(allocator, "Error: {s}", .{reason});
    return failure(allocator, "ToolArgsError", "INVALID_ARGS", reason, text);
}

fn unknownTool(allocator: Allocator, name: []const u8) ExecuteError!registry.ToolResult {
    const reason = try std.fmt.allocPrint(allocator, "unknown tool \"{s}\"", .{name});
    const text = try std.fmt.allocPrint(allocator, "Error: {s}", .{reason});
    return failure(allocator, "ToolNotFoundError", "UNKNOWN_TOOL", reason, text);
}

/// Conservative B23 recovery: the handler was invoked but threw, so side
/// effects cannot be ruled out. The raw Zig error name stays in `reason`.
fn recovery(allocator: Allocator, error_name: []const u8) ExecuteError!registry.ToolResult {
    return failure(allocator, "ToolOutcomeUnknownError", "TOOL_OUTCOME_UNKNOWN", error_name, outcome_unknown_text);
}

fn failure(
    allocator: Allocator,
    name: []const u8,
    code: []const u8,
    reason: []const u8,
    text: []const u8,
) ExecuteError!registry.ToolResult {
    // Arena red line: every allocation finishes before the union is returned.
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = text };
    return .{ .failure = .{
        .error_info = .{ .name = name, .code = code, .reason = reason },
        .content = blocks,
    } };
}

// Tests

const testing = std.testing;

const TestContext = struct {
    calls: usize = 0,
    last_args: ?Value = null,
};

fn noopHandler(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    _ = context;
    _ = allocator;
    _ = args;
    return .{ .success = .{} };
}

fn successHandler(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const ctx: *TestContext = @ptrCast(@alignCast(context.?));
    ctx.calls += 1;
    ctx.last_args = args;
    const text = try allocator.dupe(u8, "ok");
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = text };
    return .{ .success = .{ .content = blocks } };
}

fn structuredFailureHandler(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const ctx: *TestContext = @ptrCast(@alignCast(context.?));
    ctx.calls += 1;
    _ = args;
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = "the tool refused" };
    return .{ .failure = .{
        .error_info = .{ .name = "ToolFailed", .code = "E_TOOL", .reason = "refused" },
        .content = blocks,
    } };
}

fn throwingHandler(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    _ = context;
    _ = allocator;
    _ = args;
    return error.Boom;
}

const big_len = 64 * 1024 + 1;

fn bigHandler(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    _ = context;
    _ = args;
    const text = try allocator.alloc(u8, big_len);
    @memset(text, 'x');
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = text };
    return .{ .success = .{ .content = blocks } };
}

fn handlers(handler: registry.Handler) registry.CoreHandlers {
    return .{
        .read = handler,
        .write = handler,
        .edit = handler,
        .bash = handler,
        .grep = handler,
        .glob = handler,
    };
}

fn setupRegistry(core: registry.CoreHandlers) !registry.Registry {
    var reg = registry.Registry.init();
    errdefer reg.deinit(testing.allocator);
    try reg.registerCore(testing.allocator, core);
    return reg;
}

fn expectCall(id: []const u8, name: []const u8, arguments: []const u8) types.ToolCall {
    return .{ .id = id, .name = name, .arguments = arguments };
}

test "execute resolves exact and dev names and returns handler success" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = TestContext{};
    var core = handlers(.{ .call = noopHandler });
    core.read = .{ .call = successHandler, .context = &ctx };
    var reg = try setupRegistry(core);
    defer reg.deinit(testing.allocator);

    const exact = try execute(&reg, arena, expectCall("call-1", "read", "{\"file_path\":\"notes.txt\"}"));
    try testing.expect(!exact.isError());
    try testing.expectEqual(false, exact.success.concludes_turn);
    try testing.expectEqual(@as(usize, 1), exact.content().len);
    try testing.expectEqualStrings("ok", exact.content()[0].text);
    try testing.expectEqual(@as(usize, 1), ctx.calls);
    try testing.expectEqualStrings("notes.txt", ctx.last_args.?.object.get("file_path").?.string);

    const dev = try execute(&reg, arena, expectCall("call-2", "dev__read", "{\"file_path\":\"other.txt\"}"));
    try testing.expect(!dev.isError());
    try testing.expectEqual(@as(usize, 2), ctx.calls);
}

test "execute turns unknown tools into structured UNKNOWN_TOOL results" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reg = try setupRegistry(handlers(.{ .call = noopHandler }));
    defer reg.deinit(testing.allocator);

    for ([_][]const u8{ "read_file", "Read", "nope" }) |name| {
        const result = try execute(&reg, arena, expectCall("call-1", name, "{}"));
        try testing.expect(result.isError());
        try testing.expectEqualStrings("ToolNotFoundError", result.failure.error_info.name);
        try testing.expectEqualStrings("UNKNOWN_TOOL", result.failure.error_info.code);
        const expected_reason = try std.fmt.allocPrint(arena, "unknown tool \"{s}\"", .{name});
        try testing.expectEqualStrings(expected_reason, result.failure.error_info.reason.?);
        const expected_text = try std.fmt.allocPrint(arena, "Error: {s}", .{expected_reason});
        try testing.expectEqualStrings(expected_text, result.content()[0].text);
    }
}

test "execute validates required fields and types before calling the handler" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = TestContext{};
    var core = handlers(.{ .call = noopHandler });
    core.write = .{ .call = successHandler, .context = &ctx };
    var reg = try setupRegistry(core);
    defer reg.deinit(testing.allocator);

    const missing = try execute(&reg, arena, expectCall("call-1", "write", "{}"));
    try testing.expect(missing.isError());
    try testing.expectEqualStrings("ToolArgsError", missing.failure.error_info.name);
    try testing.expectEqualStrings("INVALID_ARGS", missing.failure.error_info.code);
    try testing.expectEqualStrings(
        "invalid arguments: missing required property \"file_path\"; missing required property \"content\"",
        missing.failure.error_info.reason.?,
    );
    try testing.expectEqual(@as(usize, 0), ctx.calls);

    const wrong_type = try execute(&reg, arena, expectCall("call-2", "write", "{\"file_path\":42,\"content\":\"x\"}"));
    try testing.expectEqualStrings(
        "invalid arguments: \"file_path\" must be a string",
        wrong_type.failure.error_info.reason.?,
    );
    try testing.expectEqual(@as(usize, 0), ctx.calls);

    const null_required = try execute(&reg, arena, expectCall("call-3", "write", "{\"file_path\":null,\"content\":\"x\"}"));
    try testing.expectEqualStrings(
        "invalid arguments: \"file_path\" must be a string",
        null_required.failure.error_info.reason.?,
    );
    try testing.expectEqual(@as(usize, 0), ctx.calls);

    const valid = try execute(&reg, arena, expectCall("call-4", "write", "{\"file_path\":\"a.txt\",\"content\":\"x\"}"));
    try testing.expect(!valid.isError());
    try testing.expectEqual(@as(usize, 1), ctx.calls);
}

test "execute maps malformed arguments and non-object roots to INVALID_ARGS" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reg = try setupRegistry(handlers(.{ .call = noopHandler }));
    defer reg.deinit(testing.allocator);

    // Empty raw arguments mean `{}`, matching dsh; read then reports its one
    // missing required key.
    const empty = try execute(&reg, arena, expectCall("call-1", "read", ""));
    try testing.expectEqualStrings(
        "invalid arguments: missing required property \"file_path\"",
        empty.failure.error_info.reason.?,
    );

    for ([_][]const u8{ "not json", "[]", "null", "42" }) |raw| {
        const result = try execute(&reg, arena, expectCall("call-2", "read", raw));
        try testing.expect(result.isError());
        try testing.expectEqualStrings("ToolArgsError", result.failure.error_info.name);
        try testing.expectEqualStrings("INVALID_ARGS", result.failure.error_info.code);
        try testing.expectEqualStrings("invalid arguments: \"arguments\" must be an object", result.failure.error_info.reason.?);
        try testing.expectEqualStrings("Error: invalid arguments: \"arguments\" must be an object", result.content()[0].text);
    }
}

test "execute follows dsh unknown-field policy: open roots allow extras" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = TestContext{};
    var core = handlers(.{ .call = noopHandler });
    core.read = .{ .call = successHandler, .context = &ctx };
    var reg = try setupRegistry(core);
    defer reg.deinit(testing.allocator);

    const open = try execute(&reg, arena, expectCall("call-1", "read", "{\"file_path\":\"a.txt\",\"extra\":1}"));
    try testing.expect(!open.isError());
    try testing.expectEqual(@as(usize, 1), ctx.calls);

    // Only a schema that declares `additionalProperties:false` rejects extras.
    reg.tools.getPtr("read").?.input_schema_json =
        "{\"type\":\"object\",\"properties\":{\"file_path\":{\"type\":\"string\"}},\"required\":[\"file_path\"],\"additionalProperties\":false}";
    const closed = try execute(&reg, arena, expectCall("call-2", "read", "{\"file_path\":\"a.txt\",\"extra\":1}"));
    try testing.expect(closed.isError());
    try testing.expectEqualStrings(
        "invalid arguments: \"extra\" is not a declared property (additionalProperties: false)",
        closed.failure.error_info.reason.?,
    );
    try testing.expectEqual(@as(usize, 1), ctx.calls);
}

test "execute maps a thrown handler error to the conservative recovery result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var core = handlers(.{ .call = noopHandler });
    core.edit = .{ .call = throwingHandler };
    var reg = try setupRegistry(core);
    defer reg.deinit(testing.allocator);

    const result = try execute(
        &reg,
        arena,
        expectCall("call-1", "edit", "{\"file_path\":\"a.txt\",\"old_string\":\"b\",\"new_string\":\"c\"}"),
    );
    try testing.expect(result.isError());
    try testing.expectEqualStrings("ToolOutcomeUnknownError", result.failure.error_info.name);
    try testing.expectEqualStrings("TOOL_OUTCOME_UNKNOWN", result.failure.error_info.code);
    try testing.expectEqualStrings("Boom", result.failure.error_info.reason.?);
    try testing.expectEqual(@as(usize, 1), result.content().len);
    try testing.expectEqualStrings(outcome_unknown_text, result.content()[0].text);
}

test "execute passes structured handler failures through unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = TestContext{};
    var core = handlers(.{ .call = noopHandler });
    core.write = .{ .call = structuredFailureHandler, .context = &ctx };
    var reg = try setupRegistry(core);
    defer reg.deinit(testing.allocator);

    const result = try execute(&reg, arena, expectCall("call-1", "write", "{\"file_path\":\"a.txt\",\"content\":\"x\"}"));
    try testing.expect(result.isError());
    try testing.expectEqual(@as(usize, 1), ctx.calls);
    try testing.expectEqualStrings("ToolFailed", result.failure.error_info.name);
    try testing.expectEqualStrings("E_TOOL", result.failure.error_info.code);
    try testing.expectEqualStrings("refused", result.failure.error_info.reason.?);
    try testing.expectEqualStrings("the tool refused", result.content()[0].text);
}

test "a 64KB+ handler result is owned by the arena and does not leak" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var core = handlers(.{ .call = noopHandler });
    core.bash = .{ .call = bigHandler };
    var reg = try setupRegistry(core);
    defer reg.deinit(testing.allocator);

    const result = try execute(
        &reg,
        arena,
        expectCall("call-1", "bash", "{\"description\":\"List files\",\"command\":\"ls\"}"),
    );
    try testing.expect(!result.isError());
    try testing.expectEqual(@as(usize, 1), result.content().len);
    try testing.expectEqual(@as(usize, big_len), result.content()[0].text.len);
    try testing.expectEqual(@as(u8, 'x'), result.content()[0].text[0]);
    try testing.expectEqual(@as(u8, 'x'), result.content()[0].text[big_len - 1]);
}

const GateState = struct {
    calls: usize = 0,
    deny: ?[]const u8 = null,
    fail: bool = false,
    tool_name: []const u8 = "",
    call_id: []const u8 = "",
    saw_args: bool = false,
};

fn gateDecision(context: *anyopaque, allocator: Allocator, call: types.ToolCall, args: Value) anyerror!?[]const u8 {
    _ = allocator;
    const state: *GateState = @ptrCast(@alignCast(context));
    state.calls += 1;
    state.tool_name = call.name;
    state.call_id = call.id;
    state.saw_args = args == .object and args.object.get("file_path") != null;
    if (state.fail) return error.GateBroken;
    return state.deny;
}

test "approval gate denies before the handler and preserves the reason" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tool_ctx = TestContext{};
    var reg = try setupRegistry(handlers(.{ .context = @ptrCast(&tool_ctx), .call = successHandler }));
    defer reg.deinit(testing.allocator);

    var gate = GateState{ .deny = "the user rejected tool \"read\"" };
    const result = try executeWithGate(&reg, arena, expectCall("call-9", "read", "{\"file_path\":\"a.txt\"}"), .{
        .context = @ptrCast(&gate),
        .decide = gateDecision,
    });
    const denied = switch (result) {
        .failure => |value| value,
        .success => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("ToolApprovalError", denied.error_info.name);
    try testing.expectEqualStrings("APPROVAL_DENIED", denied.error_info.code);
    try testing.expectEqualStrings("the user rejected tool \"read\"", denied.error_info.reason.?);
    try testing.expectEqualStrings("Error: the user rejected tool \"read\"", denied.content[0].text);
    // Fail closed: the handler never ran, and the gate saw the call identity.
    try testing.expectEqual(@as(usize, 0), tool_ctx.calls);
    try testing.expectEqual(@as(usize, 1), gate.calls);
    try testing.expectEqualStrings("read", gate.tool_name);
    try testing.expectEqualStrings("call-9", gate.call_id);
    try testing.expect(gate.saw_args);
}

test "approval gate allows, and a gate failure fails closed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tool_ctx = TestContext{};
    var reg = try setupRegistry(handlers(.{ .context = @ptrCast(&tool_ctx), .call = successHandler }));
    defer reg.deinit(testing.allocator);

    var gate = GateState{};
    const call = expectCall("call-1", "read", "{\"file_path\":\"a.txt\"}");
    const allowed = try executeWithGate(&reg, arena, call, .{
        .context = @ptrCast(&gate),
        .decide = gateDecision,
    });
    try testing.expect(!allowed.isError());
    try testing.expectEqual(@as(usize, 1), tool_ctx.calls);
    try testing.expectEqual(@as(usize, 1), gate.calls);

    gate.fail = true;
    const failed = try executeWithGate(&reg, arena, call, .{
        .context = @ptrCast(&gate),
        .decide = gateDecision,
    });
    const gate_failure = switch (failed) {
        .failure => |value| value,
        .success => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("TOOL_OUTCOME_UNKNOWN", gate_failure.error_info.code);
    try testing.expectEqualStrings("GateBroken", gate_failure.error_info.reason.?);
    try testing.expectEqual(@as(usize, 1), tool_ctx.calls);
}
