//! Tool registry: handler interface, result shape and name→{handler, schema}
//! mapping (design §1.2 B23/B25, §3.1 tools boundary).
//!
//! Mirrors the model-facing half of dsh `packages/core/tools/src/index.ts:572-597`:
//! success is `isError:false` with optional content/meta/additionalContexts,
//! failure is `isError:true` with structured `error{name,code,reason}`, and
//! `concludesTurn` (default false) ends the turn after the result batch commits.
//! Schemas are the exact strings in `generated/tool_schemas.zig`; this module
//! never re-serializes them.
//!
//! Approval, pre-execute, execute-waterfall and post-result policy are P2 and
//! deliberately have no hook points here. The `Wrap` below only appends
//! rendering to an already-built result (edit's diff).

const std = @import("std");
const generated = @import("../generated/tool_schemas.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Structured failure identity (B25): `error{name,code,reason}`.
pub const ErrorInfo = struct {
    name: []const u8,
    code: []const u8,
    /// Optional raw detail; model-facing content carries its own text.
    reason: ?[]const u8 = null,
};

/// The outcome of one tool call.
pub const ToolResult = union(enum) {
    success: Success,
    failure: Failure,

    pub const Success = struct {
        content: []const types.ContentBlock = &.{},
        meta: ?Value = null,
        /// User messages spliced into the next-step inbox, not the tool result.
        additional_contexts: []const types.Message = &.{},
        /// Stop the turn after this result batch (dsh `concludesTurn`; the goal
        /// wrap-up uses additional contexts instead).
        concludes_turn: bool = false,
        /// Presentation hint: keep it intact through wrapping; not model-visible.
        replaces_selected_content: bool = false,
    };

    pub const Failure = struct {
        error_info: ErrorInfo,
        content: []const types.ContentBlock = &.{},
        meta: ?Value = null,
        additional_contexts: []const types.Message = &.{},
        replaces_selected_content: bool = false,
    };

    pub fn isError(self: ToolResult) bool {
        return switch (self) {
            .success => false,
            .failure => true,
        };
    }

    pub fn content(self: ToolResult) []const types.ContentBlock {
        return switch (self) {
            .success => |success| success.content,
            .failure => |failure| failure.content,
        };
    }

    /// Append wrapper-rendered blocks, allocating the merged slice in `allocator`
    /// before the union is touched so a failed append leaves the result intact.
    pub fn appendContent(self: *ToolResult, allocator: Allocator, extra: []const types.ContentBlock) !void {
        if (extra.len == 0) return;
        const existing = self.content();
        if (existing.len == 0) {
            switch (self.*) {
                .success => |*success| success.content = extra,
                .failure => |*failure| failure.content = extra,
            }
            return;
        }
        const merged = try allocator.alloc(types.ContentBlock, existing.len + extra.len);
        @memcpy(merged[0..existing.len], existing);
        @memcpy(merged[existing.len..], extra);
        switch (self.*) {
            .success => |*success| success.content = merged,
            .failure => |*failure| failure.content = merged,
        }
    }
};

/// One tool handler. `context` is the handler's own state (cwd, policy); the
/// registry stores the pointer and never owns it.
pub const Handler = struct {
    context: ?*anyopaque = null,
    /// `args` is the parsed tool-call argument object. Every byte the result
    /// points at must be allocated from `allocator` (the caller's step arena).
    call: *const fn (context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!ToolResult,
};

/// Rendering append applied after the handler returns: returns blocks appended
/// to content. It must not alter any other result field, so meta,
/// additionalContexts, concludesTurn and replacesSelectedContent survive.
pub const Wrap = struct {
    context: ?*anyopaque = null,
    render: *const fn (context: ?*anyopaque, allocator: Allocator, args: Value, result: *const ToolResult) anyerror![]const types.ContentBlock,
};

/// Metadata for a host (junclaw) bridged tool. Kept separate from core tools
/// so dsh's generated schemas and aliases stay the only resolvable names.
pub const HostMeta = struct {
    /// Only an explicit `true` joins a parallel pool; everything else is an
    /// exclusive barrier (dsh's fail-closed classifier).
    concurrency_safe: bool = false,
    /// A tool that must reach the user fails closed when the turn has no
    /// interaction channel, mirroring `port.Interaction == null`.
    requires_interaction: bool = false,
};

/// A registered core tool: the generated schema plus its handler.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// Raw inputSchema JSON, verbatim from `generated/tool_schemas.zig`, or the
    /// host tool's own schema for bridged entries.
    input_schema_json: []const u8,
    handler: Handler,
    wrap: ?Wrap = null,
    /// Set for bridged host tools; null for dsh core tools.
    host: ?HostMeta = null,
};

pub const Schema = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
};

/// Core tools in dsh order, referencing the generated constants.
pub const core_schemas = [_]Schema{
    .{ .name = generated.read.name, .description = generated.read.description, .input_schema_json = generated.read.input_schema_json },
    .{ .name = generated.write.name, .description = generated.write.description, .input_schema_json = generated.write.input_schema_json },
    .{ .name = generated.edit.name, .description = generated.edit.description, .input_schema_json = generated.edit.input_schema_json },
    .{ .name = generated.bash.name, .description = generated.bash.description, .input_schema_json = generated.bash.input_schema_json },
    .{ .name = generated.grep.name, .description = generated.grep.description, .input_schema_json = generated.grep.input_schema_json },
    .{ .name = generated.glob.name, .description = generated.glob.description, .input_schema_json = generated.glob.input_schema_json },
    .{ .name = generated.get_goal.name, .description = generated.get_goal.description, .input_schema_json = generated.get_goal.input_schema_json },
    .{ .name = generated.create_goal.name, .description = generated.create_goal.description, .input_schema_json = generated.create_goal.input_schema_json },
    .{ .name = generated.update_goal.name, .description = generated.update_goal.description, .input_schema_json = generated.update_goal.input_schema_json },
};

/// Registrable tools the current build does not advertise yet: the model tool
/// list stays `core_schemas`. `todo_write` moves there when the harness wires
/// its handler.
const pending_schemas = [_]Schema{
    .{ .name = generated.todo_write.name, .description = generated.todo_write.description, .input_schema_json = generated.todo_write.input_schema_json },
};

const known_schemas = core_schemas ++ pending_schemas;

/// dsh tool names are exact schema keys: byte-equal, case-sensitive, no aliases.
/// Returns the canonical slice from `known_schemas`.
pub fn toolNameFromExactKeys(name: []const u8) ?[]const u8 {
    for (known_schemas) |schema| {
        if (std.mem.eql(u8, name, schema.name)) return schema.name;
    }
    return null;
}

/// The dev bundle exposes the same core tools under `dev__<name>`. Only that
/// fixed prefix is stripped; the remainder must itself be an exact key.
pub fn toolNameFromDevSubNamespace(name: []const u8) ?[]const u8 {
    const prefix = "dev__";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    return toolNameFromExactKeys(name[prefix.len..]);
}

/// Registry lookup order: exact key, then the dev sub-namespace. Every other
/// spelling (case variants, `read_file`, MCP names) is an alias and is rejected.
pub fn resolveName(name: []const u8) ?[]const u8 {
    return toolNameFromExactKeys(name) orelse toolNameFromDevSubNamespace(name);
}

pub const CoreHandlers = struct {
    read: Handler,
    write: Handler,
    edit: Handler,
    bash: Handler,
    grep: Handler,
    glob: Handler,
    get_goal: Handler,
    create_goal: Handler,
    update_goal: Handler,
    /// Null until the harness supplies the todo context; the tool is
    /// registrable but stays out of the model-visible core list.
    todo_write: ?Handler = null,
};

pub const Registry = struct {
    tools: std.StringHashMapUnmanaged(Tool) = .empty,
    /// Host-bridged tools keyed by their exact junclaw name. They never enter
    /// `tools`, so `resolveName` still rejects every non-dsh spelling.
    host_tools: std.StringHashMapUnmanaged(Tool) = .empty,

    pub fn init() Registry {
        return .{};
    }

    pub fn deinit(self: *Registry, allocator: Allocator) void {
        self.host_tools.deinit(allocator);
        self.tools.deinit(allocator);
    }

    /// Register a core tool under its exact generated name. Aliases, including
    /// the `dev__` spelling, never enter the map; `get` resolves them instead.
    pub fn register(self: *Registry, allocator: Allocator, tool: Tool) !void {
        const canonical = toolNameFromExactKeys(tool.name) orelse return error.AliasRejected;
        if (self.tools.contains(canonical)) return error.DuplicateTool;
        // Keep the canonical (generated) slice so the entry never borrows a
        // caller-owned name buffer.
        var registered = tool;
        registered.name = canonical;
        try self.tools.put(allocator, canonical, registered);
    }

    /// Register the core tools. Only handlers vary per deployment; names,
    /// descriptions and schemas are the generated dsh strings.
    pub fn registerCore(self: *Registry, allocator: Allocator, handlers: CoreHandlers) !void {
        try self.register(allocator, .{ .name = generated.read.name, .description = generated.read.description, .input_schema_json = generated.read.input_schema_json, .handler = handlers.read });
        try self.register(allocator, .{ .name = generated.write.name, .description = generated.write.description, .input_schema_json = generated.write.input_schema_json, .handler = handlers.write });
        try self.register(allocator, .{ .name = generated.edit.name, .description = generated.edit.description, .input_schema_json = generated.edit.input_schema_json, .handler = handlers.edit });
        try self.register(allocator, .{ .name = generated.bash.name, .description = generated.bash.description, .input_schema_json = generated.bash.input_schema_json, .handler = handlers.bash });
        try self.register(allocator, .{ .name = generated.grep.name, .description = generated.grep.description, .input_schema_json = generated.grep.input_schema_json, .handler = handlers.grep });
        try self.register(allocator, .{ .name = generated.glob.name, .description = generated.glob.description, .input_schema_json = generated.glob.input_schema_json, .handler = handlers.glob });
        try self.register(allocator, .{ .name = generated.get_goal.name, .description = generated.get_goal.description, .input_schema_json = generated.get_goal.input_schema_json, .handler = handlers.get_goal });
        try self.register(allocator, .{ .name = generated.create_goal.name, .description = generated.create_goal.description, .input_schema_json = generated.create_goal.input_schema_json, .handler = handlers.create_goal });
        try self.register(allocator, .{ .name = generated.update_goal.name, .description = generated.update_goal.description, .input_schema_json = generated.update_goal.input_schema_json, .handler = handlers.update_goal });
        if (handlers.todo_write) |handler| {
            try self.register(allocator, .{ .name = generated.todo_write.name, .description = generated.todo_write.description, .input_schema_json = generated.todo_write.input_schema_json, .handler = handler });
        }
    }

    /// Register a host-bridged tool under its exact junclaw name. Core names
    /// and their aliases stay reserved: a host tool may not shadow a dsh tool.
    pub fn registerHost(self: *Registry, allocator: Allocator, tool: Tool) !void {
        if (tool.name.len == 0) return error.InvalidToolName;
        if (tool.host == null) return error.NotAHostTool;
        if (self.get(tool.name) != null) return error.DuplicateTool;
        try self.host_tools.put(allocator, tool.name, tool);
    }

    pub fn get(self: *const Registry, name: []const u8) ?*const Tool {
        // Host names are exact: no case folding, no `dev__` alias.
        if (self.host_tools.getPtr(name)) |tool| return tool;
        const canonical = resolveName(name) orelse return null;
        return self.tools.getPtr(canonical);
    }

    /// Host metadata for `name`, or null when `name` is not a bridged tool.
    pub fn hostMeta(self: *const Registry, name: []const u8) ?HostMeta {
        const tool = self.host_tools.getPtr(name) orelse return null;
        return tool.host;
    }

    /// Run one call and apply its rendering wrap. Unknown names, aliases
    /// included, fail with `error.UnknownTool` before a handler runs.
    pub fn invoke(self: *const Registry, allocator: Allocator, name: []const u8, args: Value) !ToolResult {
        const tool = self.get(name) orelse return error.UnknownTool;
        var result = try tool.handler.call(tool.handler.context, allocator, args);
        if (tool.wrap) |wrap| {
            const extra = try wrap.render(wrap.context, allocator, args, &result);
            try result.appendContent(allocator, extra);
        }
        return result;
    }
};

// Tests

const testing = std.testing;

fn fakeHandler(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!ToolResult {
    _ = context;
    _ = allocator;
    _ = args;
    return .{ .success = .{} };
}

fn defaultHandlers(handler: Handler) CoreHandlers {
    return .{
        .read = handler,
        .write = handler,
        .edit = handler,
        .bash = handler,
        .grep = handler,
        .glob = handler,
        .get_goal = handler,
        .create_goal = handler,
        .update_goal = handler,
    };
}

test "registerCore keeps the nine generated schemas verbatim" {
    var registry = Registry.init();
    defer registry.deinit(testing.allocator);

    try registry.registerCore(testing.allocator, defaultHandlers(.{ .call = fakeHandler }));

    try testing.expectEqual(@as(usize, 9), registry.tools.count());
    const expected_names = [_][]const u8{
        "read", "write", "edit", "bash", "grep", "glob", "get_goal", "create_goal", "update_goal",
    };
    for (expected_names, core_schemas) |expected, schema| {
        try testing.expectEqualStrings(expected, schema.name);
        const tool = registry.get(expected).?;
        try testing.expectEqualStrings(schema.name, tool.name);
        try testing.expectEqualStrings(schema.description, tool.description);
        try testing.expectEqualStrings(schema.input_schema_json, tool.input_schema_json);
        // The schema slice is the generated constant itself, not a copy.
        try testing.expectEqual(@intFromPtr(schema.input_schema_json.ptr), @intFromPtr(tool.input_schema_json.ptr));
        try testing.expect(tool.handler.call == fakeHandler);
    }
}

test "registerCore registers todo_write only when a handler is supplied" {
    var registry = Registry.init();
    defer registry.deinit(testing.allocator);

    var core = defaultHandlers(.{ .call = fakeHandler });
    core.todo_write = .{ .call = fakeHandler };
    try registry.registerCore(testing.allocator, core);

    try testing.expectEqual(@as(usize, 10), registry.tools.count());
    const tool = registry.get(generated.todo_write.name).?;
    try testing.expectEqualStrings(generated.todo_write.description, tool.description);
    try testing.expectEqualStrings(generated.todo_write.input_schema_json, tool.input_schema_json);

    // Advertisement follows core_schemas; todo_write stays out until the
    // harness wiring lands, so no request lists a handlerless tool.
    for (core_schemas) |schema| {
        try testing.expect(!std.mem.eql(u8, schema.name, generated.todo_write.name));
    }
}

test {
    _ = @import("todo.zig");
}

test "tool names are exact keys; only the dev__ sub-namespace resolves" {
    try testing.expectEqualStrings("read", toolNameFromExactKeys("read").?);
    try testing.expectEqualStrings("glob", toolNameFromExactKeys("glob").?);
    try testing.expect(toolNameFromExactKeys("Read") == null);
    try testing.expect(toolNameFromExactKeys("read_file") == null);
    try testing.expect(toolNameFromExactKeys(" read") == null);
    try testing.expect(toolNameFromExactKeys("") == null);
    try testing.expect(toolNameFromExactKeys("mcp__srv__read") == null);

    try testing.expectEqualStrings("read", toolNameFromDevSubNamespace("dev__read").?);
    try testing.expect(toolNameFromDevSubNamespace("dev__Read") == null);
    try testing.expect(toolNameFromDevSubNamespace("dev_read") == null);
    try testing.expect(toolNameFromDevSubNamespace("dev__") == null);
    try testing.expect(toolNameFromDevSubNamespace("mcp__srv__read") == null);

    try testing.expectEqualStrings("edit", resolveName("edit").?);
    try testing.expectEqualStrings("edit", resolveName("dev__edit").?);
    try testing.expect(resolveName("shell") == null);
    try testing.expect(resolveName("write ") == null);
}

test "aliases cannot be registered or invoked; duplicates are rejected" {
    var registry = Registry.init();
    defer registry.deinit(testing.allocator);

    try testing.expectError(error.AliasRejected, registry.register(testing.allocator, .{
        .name = "Read",
        .description = "alias",
        .input_schema_json = "{}",
        .handler = .{ .call = fakeHandler },
    }));
    try testing.expectError(error.AliasRejected, registry.register(testing.allocator, .{
        .name = "dev__read",
        .description = "sub-namespace spelling is a lookup form, not a registration",
        .input_schema_json = "{}",
        .handler = .{ .call = fakeHandler },
    }));

    const tool: Tool = .{
        .name = "read",
        .description = "read",
        .input_schema_json = "{}",
        .handler = .{ .call = fakeHandler },
    };
    try registry.register(testing.allocator, tool);
    try testing.expectError(error.DuplicateTool, registry.register(testing.allocator, tool));

    const null_args = Value{ .null = {} };
    try testing.expectError(error.UnknownTool, registry.invoke(testing.allocator, "Read", null_args));
    try testing.expectError(error.UnknownTool, registry.invoke(testing.allocator, "read_file", null_args));
    try testing.expectError(error.UnknownTool, registry.invoke(testing.allocator, "shell", null_args));

    const exact = try registry.invoke(testing.allocator, "read", null_args);
    try testing.expect(!exact.isError());
    const dev = try registry.invoke(testing.allocator, "dev__read", null_args);
    try testing.expect(!dev.isError());
}

test "registration stores the canonical name, not a caller buffer" {
    var registry = Registry.init();
    defer registry.deinit(testing.allocator);

    var name_buffer = [_]u8{ 'r', 'e', 'a', 'd' };
    try registry.register(testing.allocator, .{
        .name = &name_buffer,
        .description = "read",
        .input_schema_json = "{}",
        .handler = .{ .call = fakeHandler },
    });
    @memset(&name_buffer, 'x');

    try testing.expectEqualStrings("read", registry.get("read").?.name);
}

const wrap_contexts = [_]types.Message{
    .{ .id = "ctx-1", .role = .user, .content = &.{}, .source = .user },
};

const WrapCtx = struct {
    calls: usize = 0,
};

fn fakeEdit(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!ToolResult {
    _ = context;
    _ = allocator;
    _ = args;
    return .{ .success = .{
        .content = &[_]types.ContentBlock{.{ .text = "updated example.txt" }},
        .meta = .{ .string = "edit-meta" },
        .additional_contexts = &wrap_contexts,
        .concludes_turn = true,
        .replaces_selected_content = true,
    } };
}

fn appendDiff(context: ?*anyopaque, allocator: Allocator, args: Value, result: *const ToolResult) anyerror![]const types.ContentBlock {
    _ = allocator;
    _ = result;
    const wrap_ctx: *WrapCtx = @ptrCast(@alignCast(context.?));
    wrap_ctx.calls += 1;
    const path = args.object.get("file_path").?.string;
    if (!std.mem.eql(u8, path, "example.txt")) return error.BadArgs;
    return &[_]types.ContentBlock{.{ .text = "--- diff ---" }};
}

test "wrap appends rendering and preserves every result field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registry = Registry.init();
    defer registry.deinit(testing.allocator);

    var wrap_ctx = WrapCtx{};
    try registry.register(testing.allocator, .{
        .name = "edit",
        .description = generated.edit.description,
        .input_schema_json = generated.edit.input_schema_json,
        .handler = .{ .call = fakeEdit },
        .wrap = .{ .context = &wrap_ctx, .render = appendDiff },
    });

    const args = try std.json.parseFromSliceLeaky(Value, arena, "{\"file_path\":\"example.txt\"}", .{});
    const result = try registry.invoke(arena, "edit", args);
    try testing.expect(!result.isError());

    const success = result.success;
    try testing.expectEqual(@as(usize, 2), success.content.len);
    try testing.expectEqualStrings("updated example.txt", success.content[0].text);
    try testing.expectEqualStrings("--- diff ---", success.content[1].text);
    try testing.expectEqualStrings("edit-meta", success.meta.?.string);
    try testing.expectEqual(@as(usize, 1), success.additional_contexts.len);
    try testing.expectEqual(@intFromPtr(&wrap_contexts[0]), @intFromPtr(&success.additional_contexts[0]));
    try testing.expect(success.concludes_turn);
    try testing.expect(success.replaces_selected_content);
    try testing.expectEqual(@as(usize, 1), wrap_ctx.calls);
}

fn fakeWriteFailure(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!ToolResult {
    _ = context;
    _ = allocator;
    _ = args;
    return .{ .failure = .{
        .error_info = .{ .name = "ToolWriteError", .code = "WRITE_FAILED", .reason = "read-only" },
        .content = &[_]types.ContentBlock{.{ .text = "failed" }},
        .replaces_selected_content = true,
    } };
}

fn appendNote(context: ?*anyopaque, allocator: Allocator, args: Value, result: *const ToolResult) anyerror![]const types.ContentBlock {
    _ = context;
    _ = allocator;
    _ = args;
    _ = result;
    return &[_]types.ContentBlock{.{ .text = "note" }};
}

test "wrap keeps a failure structured and appends its rendering" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registry = Registry.init();
    defer registry.deinit(testing.allocator);

    try registry.register(testing.allocator, .{
        .name = "write",
        .description = generated.write.description,
        .input_schema_json = generated.write.input_schema_json,
        .handler = .{ .call = fakeWriteFailure },
        .wrap = .{ .render = appendNote },
    });

    const result = try registry.invoke(arena, "write", Value{ .null = {} });
    try testing.expect(result.isError());

    const failure = result.failure;
    try testing.expectEqualStrings("ToolWriteError", failure.error_info.name);
    try testing.expectEqualStrings("WRITE_FAILED", failure.error_info.code);
    try testing.expectEqualStrings("read-only", failure.error_info.reason.?);
    try testing.expectEqual(@as(usize, 2), failure.content.len);
    try testing.expectEqualStrings("failed", failure.content[0].text);
    try testing.expectEqualStrings("note", failure.content[1].text);
    try testing.expect(failure.replaces_selected_content);
}

test "concludesTurn and replacesSelectedContent default to false" {
    const result = ToolResult{ .success = .{} };
    try testing.expect(!result.isError());
    try testing.expect(!result.success.concludes_turn);
    try testing.expect(!result.success.replaces_selected_content);
    try testing.expectEqual(@as(usize, 0), result.content().len);
}

fn bigAppend(context: ?*anyopaque, allocator: Allocator, args: Value, result: *const ToolResult) anyerror![]const types.ContentBlock {
    _ = context;
    _ = args;
    _ = result;
    const text = try allocator.alloc(u8, 64 * 1024);
    @memset(text, 'd');
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = text };
    return blocks;
}

test "a 64KB wrapped result is owned by the arena and does not leak" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registry = Registry.init();
    defer registry.deinit(testing.allocator);

    try registry.registerCore(testing.allocator, defaultHandlers(.{ .call = fakeHandler }));
    registry.tools.getPtr("read").?.wrap = .{ .render = bigAppend };

    const result = try registry.invoke(arena, "dev__read", Value{ .null = {} });
    try testing.expect(!result.isError());
    try testing.expectEqual(@as(usize, 1), result.content().len);
    try testing.expectEqual(@as(usize, 64 * 1024), result.content()[0].text.len);
    try testing.expectEqual(@as(u8, 'd'), result.content()[0].text[0]);
    try testing.expectEqual(@as(u8, 'd'), result.content()[0].text[64 * 1024 - 1]);
}
