//! Host tool bridge: register the session's junclaw `Tool` list in the dsh
//! registry (P3-A, design §1.4 B22 / §3.1 tools boundary).
//!
//! Model-visible names, descriptions and input schemas are the host tool's
//! own strings; execution delegates to the host executor (junclaw's
//! `Agent.executeTool` path in production). dsh keeps precedence: a host tool
//! that collides with a registered dsh name, or that duplicates one of dsh's
//! six file/shell tools under a junclaw spelling, is not exposed.
//!
//! Concurrency is fail-closed: a bridged tool is an exclusive barrier unless
//! it is explicitly read-only, and then only an explicit `true` joins a
//! parallel pool (dsh `isConcurrencySafe` semantics).
//!
//! Overlong results reuse dsh's bash retention rule: keep the tail up to
//! 64,000 bytes, spill the full text under `dsh_home/spill`, and append
//! `generated.tool_render.bash.output_truncated`.

const std = @import("std");
const compat = @import("compat");
const bash = @import("bash.zig");
const registry = @import("registry.zig");
const render = @import("../generated/tool_render.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// One host tool as the model sees it.
pub const HostTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
    /// Only set for tools with no side effects the model could observe.
    concurrency_safe: bool = false,
    /// Fails closed when the turn has no `port.Interaction`.
    requires_interaction: bool = false,
};

/// Result of one host execution; `output` is the model-facing text for both
/// success and failure (junclaw already puts the message there).
pub const HostResult = struct {
    success: bool,
    output: []const u8,
};

pub const HostExecutor = struct {
    context: *anyopaque,
    call: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        name: []const u8,
        args: Value,
    ) anyerror!HostResult,
};

pub const Host = struct {
    tools: []const HostTool = &.{},
    executor: ?HostExecutor = null,
    spill_dir: []const u8 = "",
};

/// junclaw spellings of the six dsh tools; dsh's versions stay the only
/// model-visible ones.
const dsh_equivalents = [_][]const u8{
    "shell",
    "file_read",
    "file_read_hashed",
    "file_write",
    "file_append",
    "file_edit",
    "file_edit_hashed",
};

/// Host tools with no observable side effects, so they may join a parallel
/// pool. Anything not listed is exclusive. Network reads and memory reads are
/// listed; anything that can write local state, the channel or hardware is not.
const read_only_host_tools = [_][]const u8{
    "anonymize_text",
    "calculator",
    "cron_list",
    "cron_runs",
    "hardware_board_info",
    "hardware_memory",
    "image_info",
    "memory_list",
    "memory_recall",
    "web_fetch",
    "web_search",
};

pub fn isReadOnlyHostTool(name: []const u8) bool {
    for (read_only_host_tools) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// dsh scheduling classification for a model-issued name. Bridged tools use
/// their declared flag; dsh's read/grep/glob stay parallel; all else is an
/// exclusive barrier.
pub fn isParallel(reg: *const registry.Registry, name: []const u8) bool {
    if (reg.hostMeta(name)) |meta| return meta.concurrency_safe;
    return std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "grep") or
        std.mem.eql(u8, name, "glob");
}

const Slot = struct {
    name: []const u8,
    executor: HostExecutor,
    spill_dir: []const u8,
};

/// Register the host tools that dsh does not already provide. Returns the
/// registered names (owned by `perm`) in host order.
pub fn register(
    perm: Allocator,
    map_allocator: Allocator,
    reg: *registry.Registry,
    host: Host,
) ![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    const executor = host.executor orelse return names.items;

    for (host.tools) |spec| {
        if (isDshEquivalent(spec.name)) continue;
        // Core names and aliases are reserved for dsh (also covers `dev__`).
        if (reg.get(spec.name) != null) continue;

        const name = try perm.dupe(u8, spec.name);
        const slot = try perm.create(Slot);
        slot.* = .{ .name = name, .executor = executor, .spill_dir = host.spill_dir };
        reg.registerHost(map_allocator, .{
            .name = name,
            .description = try perm.dupe(u8, spec.description),
            .input_schema_json = try perm.dupe(u8, spec.input_schema_json),
            .handler = .{ .context = slot, .call = callHost },
            .host = .{
                .concurrency_safe = spec.concurrency_safe,
                .requires_interaction = spec.requires_interaction,
            },
        }) catch |err| switch (err) {
            // A repeated host name (two MCP servers, a duplicated config
            // entry) keeps the first registration instead of failing the turn.
            error.DuplicateTool => continue,
            else => return err,
        };
        try names.append(perm, name);
    }
    return names.items;
}

fn isDshEquivalent(name: []const u8) bool {
    for (dsh_equivalents) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn callHost(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const slot: *Slot = @ptrCast(@alignCast(context orelse return error.MissingHostTool));
    const outcome = try slot.executor.call(slot.executor.context, allocator, slot.name, args);
    const text = try retain(allocator, slot.spill_dir, slot.name, outcome.output);
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = text };
    if (outcome.success) return .{ .success = .{ .content = blocks } };
    return .{ .failure = .{
        .error_info = .{ .name = "ToolError", .code = "TOOL_FAILED", .reason = text },
        .content = blocks,
    } };
}

/// dsh bash's retention shape: the model sees the tail, the spill keeps all.
fn retain(allocator: Allocator, spill_dir: []const u8, name: []const u8, text: []const u8) ![]const u8 {
    if (text.len <= bash.max_output_bytes) return text;
    var start = text.len - bash.max_output_bytes;
    // Never hand the model a split code point.
    while (start < text.len and (text[start] & 0xC0) == 0x80) start += 1;
    const spill_path = writeSpill(allocator, spill_dir, name, text) catch null;
    return std.fmt.allocPrint(allocator, render.bash.output_truncated, .{
        text[start..],
        spill_path orelse "(unavailable)",
    });
}

fn writeSpill(allocator: Allocator, spill_dir: []const u8, name: []const u8, text: []const u8) ![]const u8 {
    if (spill_dir.len == 0) return error.MissingSpillDir;
    var random: [6]u8 = undefined;
    compat.crypto.random.bytes(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const filename = try std.fmt.allocPrint(allocator, "dsh-tool-{s}-{s}.log", .{ &hex, name });
    const path = try std.fs.path.join(allocator, &.{ spill_dir, filename });
    const file = try compat.fs.createFileAbsolute(path, .{
        .truncate = true,
        .exclusive = true,
        .permissions = compat.fs.permissionsFromMode(0o600),
    });
    defer file.close();
    try file.writeAll(text);
    return path;
}

// Tests

const testing = std.testing;

const Output = struct { name: []const u8, text: []const u8, success: bool = true };

const FakeHost = struct {
    mutex: compat.sync.Mutex = .{},
    calls: std.ArrayListUnmanaged([]const u8) = .empty,
    allocator: Allocator,
    outputs: []const Output = &.{},
    big_len: usize = 0,

    fn deinit(self: *FakeHost) void {
        for (self.calls.items) |entry| self.allocator.free(entry);
        self.calls.deinit(self.allocator);
    }

    fn executor(self: *FakeHost) HostExecutor {
        return .{ .context = @ptrCast(self), .call = call };
    }

    fn call(context: *anyopaque, allocator: Allocator, name: []const u8, args: Value) anyerror!HostResult {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        const rendered = try std.json.Stringify.valueAlloc(allocator, args, .{});
        const line = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ name, rendered });
        self.mutex.lock();
        self.calls.append(self.allocator, line) catch @panic("test allocator failed");
        self.mutex.unlock();

        if (self.big_len > 0) {
            const text = try allocator.alloc(u8, self.big_len);
            @memset(text, 'x');
            return .{ .success = true, .output = text };
        }
        for (self.outputs) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return .{ .success = entry.success, .output = entry.text };
            }
        }
        return .{ .success = false, .output = try std.fmt.allocPrint(allocator, "failed: {s}", .{name}) };
    }
};

fn fakeHandler(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    _ = context;
    _ = args;
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = "dsh" };
    return .{ .success = .{ .content = blocks } };
}

fn coreRegistry(reg: *registry.Registry) !void {
    try reg.registerCore(testing.allocator, .{
        .read = .{ .call = fakeHandler },
        .write = .{ .call = fakeHandler },
        .edit = .{ .call = fakeHandler },
        .bash = .{ .call = fakeHandler },
        .grep = .{ .call = fakeHandler },
        .glob = .{ .call = fakeHandler },
        .get_goal = .{ .call = fakeHandler },
        .create_goal = .{ .call = fakeHandler },
        .update_goal = .{ .call = fakeHandler },
    });
}

fn callNamed(name: []const u8) types.ToolCall {
    return .{ .id = name, .name = name, .arguments = "{}" };
}

fn textOf(block: types.ContentBlock) []const u8 {
    return switch (block) {
        .text => |text| text,
        else => "",
    };
}

test "bridge shadows dsh tools and junclaw equivalents" {
    const allocator = testing.allocator;
    var reg = registry.Registry.init();
    defer reg.deinit(allocator);
    try coreRegistry(&reg);

    var fake = FakeHost{ .allocator = allocator };
    defer fake.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const specs = [_]HostTool{
        .{ .name = "web_search", .description = "search", .input_schema_json = "{\"type\":\"object\"}" },
        .{ .name = "read", .description = "shadowed", .input_schema_json = "{}" },
        .{ .name = "file_read", .description = "equivalent", .input_schema_json = "{}" },
        .{ .name = "shell", .description = "equivalent", .input_schema_json = "{}" },
        .{ .name = "web_search", .description = "duplicate", .input_schema_json = "{}" },
    };
    const names = try register(arena.allocator(), allocator, &reg, .{
        .tools = &specs,
        .executor = fake.executor(),
    });

    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("web_search", names[0]);
    try testing.expect(reg.get("web_search") != null);
    try testing.expect(reg.get("file_read") == null);
    try testing.expect(reg.get("shell") == null);
    // dsh's own name still resolves to the dsh entry.
    try testing.expect(reg.get("read").?.handler.call == fakeHandler);
}

test "bridge executes host success and failure through the registry" {
    const allocator = testing.allocator;
    var reg = registry.Registry.init();
    defer reg.deinit(allocator);
    try coreRegistry(&reg);

    var fake = FakeHost{ .allocator = allocator, .outputs = &.{
        .{ .name = "web_search", .text = "two results" },
        .{ .name = "memory_store", .text = "disk is full", .success = false },
    } };
    defer fake.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const specs = [_]HostTool{
        .{ .name = "web_search", .description = "search", .input_schema_json = "{\"type\":\"object\"}" },
        .{ .name = "memory_store", .description = "store", .input_schema_json = "{\"type\":\"object\"}" },
    };
    _ = try register(arena.allocator(), allocator, &reg, .{
        .tools = &specs,
        .executor = fake.executor(),
    });

    const ok = try @import("execute.zig").execute(&reg, arena.allocator(), callNamed("web_search"));
    try testing.expect(!ok.isError());
    try testing.expectEqualStrings("two results", textOf(ok.content()[0]));

    const bad = try @import("execute.zig").execute(&reg, arena.allocator(), callNamed("memory_store"));
    try testing.expect(bad.isError());
    try testing.expectEqualStrings("TOOL_FAILED", bad.failure.error_info.code);
    try testing.expectEqualStrings("disk is full", textOf(bad.content()[0]));
}

test "bridge classification defaults to exclusive" {
    const allocator = testing.allocator;
    var reg = registry.Registry.init();
    defer reg.deinit(allocator);
    try coreRegistry(&reg);

    var fake = FakeHost{ .allocator = allocator };
    defer fake.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const specs = [_]HostTool{
        .{ .name = "web_search", .description = "search", .input_schema_json = "{}", .concurrency_safe = true },
        .{ .name = "memory_store", .description = "store", .input_schema_json = "{}" },
    };
    _ = try register(arena.allocator(), allocator, &reg, .{
        .tools = &specs,
        .executor = fake.executor(),
    });

    try testing.expect(isParallel(&reg, "web_search"));
    try testing.expect(!isParallel(&reg, "memory_store"));
    try testing.expect(isParallel(&reg, "read"));
    try testing.expect(!isParallel(&reg, "bash"));
    try testing.expect(!isParallel(&reg, "unknown"));
    try testing.expect(isReadOnlyHostTool("web_search"));
    try testing.expect(!isReadOnlyHostTool("memory_store"));
}

test "bridge truncates long output to the dsh cap with a spill file" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spill_dir = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(spill_dir);

    var reg = registry.Registry.init();
    defer reg.deinit(allocator);
    var fake = FakeHost{ .allocator = allocator, .big_len = bash.max_output_bytes + 4096 };
    defer fake.deinit();
    const specs = [_]HostTool{
        .{ .name = "web_fetch", .description = "fetch", .input_schema_json = "{}" },
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try register(arena.allocator(), allocator, &reg, .{
        .tools = &specs,
        .executor = fake.executor(),
        .spill_dir = spill_dir,
    });

    const result = try @import("execute.zig").execute(&reg, arena.allocator(), callNamed("web_fetch"));
    try testing.expect(!result.isError());
    const text = textOf(result.content()[0]);
    try testing.expect(text.len <= bash.max_output_bytes + 120);
    const marker = "[output truncated; full output: ";
    try testing.expect(std.mem.indexOf(u8, text, marker) != null);

    const from = std.mem.indexOf(u8, text, marker).? + marker.len;
    const to = std.mem.indexOfScalarPos(u8, text, from, ']').?;
    const spill = try compat.fs.openFileAbsolute(text[from..to], .{});
    defer spill.close();
    try testing.expectEqual(@as(u64, bash.max_output_bytes + 4096), (try spill.stat()).size);
}

const Event = struct {
    mutex: compat.sync.Mutex = .{},
    condition: compat.sync.Condition = .{},
    signaled: bool = false,

    fn set(self: *Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.signaled = true;
        self.condition.broadcast();
    }

    fn wait(self: *Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.signaled) self.condition.wait(&self.mutex);
    }
};

const scheduler = @import("scheduler.zig");

const SchedCall = struct {
    name: []const u8,
    entered: Event = .{},
    gate: Event = .{},
    hold: bool = false,
};

const SchedCtx = struct {
    registry: *const registry.Registry,
    calls: []SchedCall,
    order: std.ArrayListUnmanaged([]const u8) = .empty,
    order_mutex: compat.sync.Mutex = .{},
    allocator: Allocator,

    fn deinit(self: *SchedCtx) void {
        self.order.deinit(self.allocator);
    }

    fn record(self: *SchedCtx, name: []const u8) void {
        self.order_mutex.lock();
        defer self.order_mutex.unlock();
        self.order.append(self.allocator, name) catch @panic("test allocator failed");
    }

    fn find(self: *SchedCtx, id: []const u8) ?*SchedCall {
        for (self.calls) |*call| {
            if (std.mem.eql(u8, call.name, id)) return call;
        }
        return null;
    }

    fn classify(context: *anyopaque, call: types.ToolCall) bool {
        const self: *SchedCtx = @ptrCast(@alignCast(context));
        return isParallel(self.registry, call.name);
    }

    fn dispatch(context: *anyopaque, allocator: Allocator, call: types.ToolCall, signal: scheduler.Signal) anyerror!registry.ToolResult {
        const self: *SchedCtx = @ptrCast(@alignCast(context));
        const sched_call = self.find(call.id).?;
        self.record(sched_call.name);
        sched_call.entered.set();
        if (sched_call.hold) sched_call.gate.wait();
        if (signal.isAborted() and !sched_call.hold) return error.Aborted;
        // Real execution through the registry, so a missing bridge entry shows
        // up as the unknown-tool failure instead of a hand-written result.
        return self.registry.invoke(allocator, sched_call.name, Value{ .object = .empty });
    }
};

const Scheduled = struct {
    allocator: Allocator,
    calls: []const types.ToolCall,
    classifier: ?scheduler.Classifier,
    dispatcher: scheduler.Dispatcher,
    abort_flag: *std.atomic.Value(bool),
    max_parallel: usize = scheduler.DEFAULT_MAX_PARALLEL_TOOL_CALLS,
    batch: ?scheduler.Batch = null,
    err: ?anyerror = null,

    fn run(self: *Scheduled) void {
        self.batch = scheduler.schedule(
            self.allocator,
            self.calls,
            self.classifier,
            self.dispatcher,
            .{ .flag = self.abort_flag },
            .{ .max_parallel = self.max_parallel },
            .{},
        ) catch |err| {
            self.err = err;
            return;
        };
    }
};

test "exclusive host tools are a barrier; annotated read-only calls run parallel" {
    const allocator = testing.allocator;
    var reg = registry.Registry.init();
    defer reg.deinit(allocator);
    try coreRegistry(&reg);

    var fake = FakeHost{ .allocator = allocator, .outputs = &.{
        .{ .name = "search_a", .text = "a" },
        .{ .name = "store_x", .text = "x" },
        .{ .name = "search_b", .text = "b" },
    } };
    defer fake.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const specs = [_]HostTool{
        .{ .name = "search_a", .description = "a", .input_schema_json = "{}", .concurrency_safe = true },
        .{ .name = "store_x", .description = "x", .input_schema_json = "{}" },
        .{ .name = "search_b", .description = "b", .input_schema_json = "{}", .concurrency_safe = true },
    };
    _ = try register(arena.allocator(), allocator, &reg, .{
        .tools = &specs,
        .executor = fake.executor(),
    });

    var calls = [_]SchedCall{
        .{ .name = "search_a", .hold = true },
        .{ .name = "store_x", .hold = true },
        .{ .name = "search_b", .hold = true },
    };
    var ctx = SchedCtx{ .registry = &reg, .calls = &calls, .allocator = allocator };
    defer ctx.deinit();
    // Parallel calls sit next to each other; the exclusive one is the barrier.
    var tool_calls = [_]types.ToolCall{ callNamed("search_a"), callNamed("search_b"), callNamed("store_x") };
    var abort_flag = std.atomic.Value(bool).init(false);
    var scheduled = Scheduled{
        .allocator = allocator,
        .calls = &tool_calls,
        .classifier = .{ .context = @ptrCast(&ctx), .is_concurrency_safe = SchedCtx.classify },
        .dispatcher = .{ .context = @ptrCast(&ctx), .dispatch = SchedCtx.dispatch },
        .abort_flag = &abort_flag,
    };
    var thread: ?std.Thread = try std.Thread.spawn(.{}, Scheduled.run, .{&scheduled});
    defer {
        for (&calls) |*call| call.gate.set();
        if (thread) |value| value.join();
        if (scheduled.batch) |*batch| batch.deinit(allocator);
    }

    // Both parallel calls are in flight before the exclusive barrier starts.
    calls[0].entered.wait();
    calls[2].entered.wait();
    try testing.expectEqual(@as(usize, 2), ctx.order.items.len);
    for (ctx.order.items) |name| try testing.expect(!std.mem.eql(u8, name, "store_x"));
    calls[0].gate.set();
    calls[2].gate.set();
    calls[1].entered.wait();
    calls[1].gate.set();
    thread.?.join();
    thread = null;

    try testing.expect(scheduled.err == null);
    const done = scheduled.batch.?;
    try testing.expectEqualStrings("a", textOf(done.results[0].content()[0]));
    try testing.expectEqualStrings("b", textOf(done.results[1].content()[0]));
    try testing.expectEqualStrings("x", textOf(done.results[2].content()[0]));
    try testing.expectEqual(@as(usize, 3), ctx.order.items.len);
    try testing.expectEqualStrings("store_x", ctx.order.items[2]);
}

test "abort commits a started bridged call and synthesizes the rest" {
    const allocator = testing.allocator;
    var reg = registry.Registry.init();
    defer reg.deinit(allocator);
    try coreRegistry(&reg);

    var fake = FakeHost{ .allocator = allocator, .outputs = &.{
        .{ .name = "search_a", .text = "a" },
        .{ .name = "search_b", .text = "b" },
    } };
    defer fake.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const specs = [_]HostTool{
        .{ .name = "search_a", .description = "a", .input_schema_json = "{}", .concurrency_safe = true },
        .{ .name = "search_b", .description = "b", .input_schema_json = "{}", .concurrency_safe = true },
    };
    _ = try register(arena.allocator(), allocator, &reg, .{
        .tools = &specs,
        .executor = fake.executor(),
    });

    var calls = [_]SchedCall{
        .{ .name = "search_a", .hold = true },
        .{ .name = "search_b" },
    };
    var ctx = SchedCtx{ .registry = &reg, .calls = &calls, .allocator = allocator };
    defer ctx.deinit();
    var tool_calls = [_]types.ToolCall{ callNamed("search_a"), callNamed("search_b") };
    var abort_flag = std.atomic.Value(bool).init(false);
    var scheduled = Scheduled{
        .allocator = allocator,
        .calls = &tool_calls,
        .classifier = .{ .context = @ptrCast(&ctx), .is_concurrency_safe = SchedCtx.classify },
        .dispatcher = .{ .context = @ptrCast(&ctx), .dispatch = SchedCtx.dispatch },
        .abort_flag = &abort_flag,
        .max_parallel = 1,
    };
    var thread: ?std.Thread = try std.Thread.spawn(.{}, Scheduled.run, .{&scheduled});
    defer {
        for (&calls) |*call| call.gate.set();
        if (thread) |value| value.join();
        if (scheduled.batch) |*batch| batch.deinit(allocator);
    }

    calls[0].entered.wait();
    abort_flag.store(true, .release);
    calls[0].gate.set();
    thread.?.join();
    thread = null;

    const done = scheduled.batch.?;
    try testing.expect(done.aborted);
    try testing.expectEqualStrings("a", textOf(done.results[0].content()[0]));
    try testing.expect(done.started[0]);
    try testing.expect(done.results[1].isError());
    try testing.expectEqualStrings(scheduler.TOOL_ABORTED_BEFORE_DISPATCH, done.results[1].failure.error_info.code);
    try testing.expect(!done.started[1]);
}

test "bridged and dsh tools share one batch in model order" {
    const allocator = testing.allocator;
    var reg = registry.Registry.init();
    defer reg.deinit(allocator);
    try coreRegistry(&reg);

    var fake = FakeHost{ .allocator = allocator, .outputs = &.{
        .{ .name = "web_search", .text = "web" },
    } };
    defer fake.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const specs = [_]HostTool{
        .{ .name = "web_search", .description = "search", .input_schema_json = "{}", .concurrency_safe = true },
    };
    _ = try register(arena.allocator(), allocator, &reg, .{
        .tools = &specs,
        .executor = fake.executor(),
    });

    const Call = struct {
        fn dispatch(context: *anyopaque, call_allocator: Allocator, call: types.ToolCall, signal: scheduler.Signal) anyerror!registry.ToolResult {
            _ = signal;
            const reg_ptr: *const registry.Registry = @ptrCast(@alignCast(context));
            return @import("execute.zig").execute(reg_ptr, call_allocator, call);
        }
        fn classify(context: *anyopaque, call: types.ToolCall) bool {
            const reg_ptr: *const registry.Registry = @ptrCast(@alignCast(context));
            return isParallel(reg_ptr, call.name);
        }
    };
    const tool_calls = [_]types.ToolCall{
        callNamed("web_search"),
        .{ .id = "read", .name = "read", .arguments = "{\"file_path\":\"x\"}" },
        callNamed("web_search"),
    };
    var abort_flag = std.atomic.Value(bool).init(false);
    var batch = try scheduler.schedule(
        allocator,
        &tool_calls,
        .{ .context = @ptrCast(&reg), .is_concurrency_safe = Call.classify },
        .{ .context = @ptrCast(&reg), .dispatch = Call.dispatch },
        .{ .flag = &abort_flag },
        .{},
        .{},
    );
    defer batch.deinit(allocator);

    try testing.expectEqualStrings("web", textOf(batch.results[0].content()[0]));
    try testing.expectEqualStrings("dsh", textOf(batch.results[1].content()[0]));
    try testing.expectEqualStrings("web", textOf(batch.results[2].content()[0]));
    try testing.expectEqual(@as(usize, 2), fake.calls.items.len);
}
