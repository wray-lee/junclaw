//! The dsh-native turn engine: `port.Harness` over the pure kernel
//! (`loop.zig`), one instance per host session key.
//!
//! P1b scope: text and tool turns, steer pulled through the kernel inbox,
//! typed end reasons, `/new` (reset) and resume (restore) over the v4 JSONL
//! session log. Everything durable goes through `session_log.Log`; the
//! model-visible surface is rebuilt from the same messages the log stores.
//!
//! Deliberate P1b limits:
//! - The provider bridge is blocking (`Provider.chatWithTools`); the kernel
//!   sees one text chunk plus `done` per model call. Live deltas reach the host
//!   as one `delta` per assistant message, not per provider token.
//! - junclaw's provider interface cannot carry an assistant `tool_calls`
//!   message, so history uses the native harness convention (`<tool_call>` XML
//!   in assistant text, `[Tool results]` as a user message). The request still
//!   advertises native tool schemas.
//! - Runtime context (working directory / sandbox / approval policy) is
//!   appended to the system prompt rather than being a separate
//!   `runtime-context` user message (dsh emits the latter; P3).
//! - Approvals, questions, compaction, plan and slash commands are P2; goal
//!   commands stay unwired (rounds and wrap-ups are P2b);
//!   `handleLocalCommand` stays null.
//! - `restore` reattaches to the JSONL and rebuilds the surface. Nothing else
//!   is replayed: this adapter never leaves durable pending inbox input, and
//!   late-steer merging belongs to the host (`session.zig`, P1b-3).
//!
//! The harness must outlive `init` at a stable address: tool handlers borrow
//! heap-pinned contexts and the kernel's host context points at `Self`.

const std = @import("std");
const compat = @import("compat");
const fs_compat = @import("../../fs_compat.zig");
const agent_mod = @import("../../agent/root.zig");
const dispatcher = @import("../../agent/dispatcher.zig");
const providers = @import("../../providers/root.zig");
const config_types = @import("../../config_types.zig");
const port = @import("../port.zig");
const context = @import("context.zig");
const generated = @import("generated/tool_schemas.zig");
const inbox = @import("inbox.zig");
const loop_mod = @import("loop.zig");
const prompt = @import("prompt.zig");
const request = @import("request.zig");
const registry = @import("tools/registry.zig");
const builtins_mod = @import("tools/builtins.zig");
const bash_mod = @import("tools/bash.zig");
const goal_mod = @import("goal.zig");
const goal_rounds = @import("goal_rounds.zig");
const goal_tools = @import("tools/goal.zig");
const execute = @import("tools/execute.zig");
const scheduler = @import("tools/scheduler.zig");
const session_log = @import("session_log.zig");
const session_store = @import("session_store.zig");
const stream = @import("stream.zig");
const surface_mod = @import("surface.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Writer = std.Io.Writer;

/// Borrowed for the harness lifetime (same contract as the sidecar's
/// `Options`); the owner keeps every slice alive until `deinit`, except
/// `session_key`, which `rebindSessionKey` may re-point.
pub const Options = struct {
    /// Host session identity; the mapping file is keyed by it. Borrowed, and
    /// re-pointed by `rebindSessionKey` when the host canonicalizes the key.
    session_key: []const u8,
    /// dsh home: `sessions/<project>/<id>/session.v4.jsonl` lives under it.
    dsh_home: []const u8,
    /// Mapping directory (`{dir}/{Wyhash(key)}.json`). Null disables resume
    /// and mapping writes.
    session_dir: ?[]const u8 = null,
    workspace_dir: []const u8 = "",
    provider: providers.Provider,
    provider_name: []const u8,
    model: []const u8,
    reasoning_effort: ?[]const u8 = null,
    max_tokens: ?u32 = null,
    persona: []const u8 = "",
    approval_policy: config_types.DshApprovalPolicy = .ask,
    sandbox: config_types.DshSandbox = .workspace_write,
    max_parallel_tools: usize = config_types.DEFAULT_DSH_MAX_PARALLEL_TOOLS,
    on_corrupt: config_types.DshOnCorrupt = .fail,
    temperature: f64 = 0.7,
    /// Deterministic clock for tests; null uses the wall clock.
    now_ms: ?*const fn (clock_context: ?*anyopaque) i64 = null,
    clock_context: ?*anyopaque = null,
};

pub const DshNativeHarness = struct {
    const Self = @This();

    const PendingCall = struct {
        call: types.ToolCall,
        seq: u64,
    };

    allocator: Allocator,
    /// Permanent: tool schemas and the system prompt.
    perm: std.heap.ArenaAllocator,
    /// Session: ids and the surface. Freed on reset/restore.
    arena: std.heap.ArenaAllocator,
    opts: Options,

    log: ?session_log.Log = null,
    loop: ?loop_mod.Loop = null,
    session_id: []const u8 = "",
    next_id: u64 = 1,
    /// Set when `/new` failed; the next turn reports it (`reset` cannot).
    reset_error: ?anyerror = null,
    context_written: bool = false,

    /// The model-visible surface (arena-owned), in request order.
    messages: std.ArrayListUnmanaged(types.Message) = .empty,

    tool_schemas: []const request.ToolSchema = &.{},
    tool_specs: []const providers.ToolSpec = &.{},
    registry: registry.Registry = .{},
    builtins: ?*builtins_mod.Builtins = null,
    bash: ?*bash_mod.Context = null,
    goal_store: ?*goal_mod.Store = null,
    goal_tools: ?*goal_tools.Context = null,
    goal_driver: ?goal_rounds.Driver = null,
    system_prompt: []const u8 = "",
    spill_dir: []const u8 = "",

    in_turn: bool = false,
    interrupt: bool = false,
    /// Tokens billed by every model call this harness ran (all turns).
    total_tokens: u64 = 0,
    turn_model_calls: u64 = 0,
    turn_text: std.ArrayListUnmanaged(u8) = .empty,
    last_assistant_text: ?[]const u8 = null,

    // Per turn.
    sink: ?port.Sink = null,
    live_stream: bool = false,
    drain: ?agent_mod.DrainCallback = null,
    drain_ctx: ?*anyopaque = null,

    /// Tool calls logged but not yet answered, in model order.
    pending_calls: std.ArrayListUnmanaged(PendingCall) = .empty,

    // Per model call.
    call_arena: std.heap.ArenaAllocator,
    pending: std.ArrayListUnmanaged(stream.Event) = .empty,
    pending_index: usize = 0,

    pub fn init(allocator: Allocator, opts: Options) !Self {
        if (opts.dsh_home.len == 0) return error.MissingDshHome;
        var self = Self{
            .allocator = allocator,
            .perm = std.heap.ArenaAllocator.init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .opts = opts,
            .call_arena = std.heap.ArenaAllocator.init(allocator),
            .registry = registry.Registry.init(),
        };
        errdefer self.deinit(allocator);
        try self.buildTools();
        try self.buildPrompt();
        return self;
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        // `allocator` is the host's free allocator, the same one `init` took.
        _ = allocator;
        self.closeSession();
        self.turn_text.deinit(self.allocator);
        self.pending_calls.deinit(self.allocator);
        self.registry.deinit(self.allocator);
        if (self.builtins) |value| self.allocator.destroy(value);
        if (self.bash) |value| self.allocator.destroy(value);
        if (self.goal_tools) |value| self.allocator.destroy(value);
        if (self.goal_store) |value| {
            value.deinit();
            self.allocator.destroy(value);
        }
        self.call_arena.deinit();
        self.arena.deinit();
        self.perm.deinit();
    }

    pub fn harness(self: *Self) port.Harness {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// Mirrors the sidecar handle: the host leaves a pre-turn `/stop` to
    /// `runTurn` (which closes through the kernel's abort path) instead of
    /// answering it as a local command.
    pub fn interruptPending(self: *const Self) bool {
        return self.interrupt;
    }

    /// Follow a host key canonicalization. The harness borrows the key, so the
    /// owner must call this before freeing the old slice.
    pub fn rebindSessionKey(self: *Self, session_key: []const u8) void {
        self.opts.session_key = session_key;
        // Best effort: a restart under the canonical key must find the same
        // JSONL. A failed write keeps the stale mapping; turns still run.
        if (self.session_id.len != 0) self.writeMapping() catch {};
    }

    fn workspace(self: *const Self) []const u8 {
        return if (self.opts.workspace_dir.len == 0) "." else self.opts.workspace_dir;
    }

    fn now(self: *const Self) ?i64 {
        if (self.opts.now_ms) |clock| return clock(self.opts.clock_context);
        return null;
    }

    fn appendEvent(self: *Self, event_type: []const u8, data: Value, surface_op: ?types.SurfaceOp, seqs: ?[]const u64) !u64 {
        const log = if (self.log) |*value| value else return error.NoSession;
        return log.append(event_type, data, .{
            .time_ms = self.now(),
            .surface_op = surface_op,
            .source_event_seqs = seqs,
        });
    }

    fn buildTools(self: *Self) !void {
        const perm = self.perm.allocator();
        const dir = self.workspace();
        self.spill_dir = try std.fs.path.join(perm, &.{ self.opts.dsh_home, "spill" });

        const builtins = try self.allocator.create(builtins_mod.Builtins);
        errdefer self.allocator.destroy(builtins);
        builtins.* = .{ .cwd = dir, .spill_dir = self.spill_dir };
        try builtins.register(&self.registry, self.allocator);

        const bash = try self.allocator.create(bash_mod.Context);
        errdefer self.allocator.destroy(bash);
        bash.* = .{ .cwd = dir, .spill_dir = self.spill_dir };
        try self.registry.register(self.allocator, .{
            .name = generated.bash.name,
            .description = generated.bash.description,
            .input_schema_json = generated.bash.input_schema_json,
            .handler = bash.handler(),
        });

        self.builtins = builtins;
        self.bash = bash;

        const goal_store = try self.allocator.create(goal_mod.Store);
        errdefer self.allocator.destroy(goal_store);
        goal_store.* = goal_mod.Store.init(self.allocator);
        const goal_context = try self.allocator.create(goal_tools.Context);
        errdefer self.allocator.destroy(goal_context);
        goal_context.* = .{ .store = goal_store };
        try goal_context.register(&self.registry, self.allocator);
        self.goal_store = goal_store;
        self.goal_tools = goal_context;
        self.goal_driver = .{ .store = goal_store };

        const names = try perm.alloc([]const u8, registry.core_schemas.len);
        for (registry.core_schemas, 0..) |schema, index| names[index] = schema.name;
        const ordered = try prompt.orderTools(perm, names, null);

        const schemas = try perm.alloc(request.ToolSchema, ordered.len);
        const specs = try perm.alloc(providers.ToolSpec, ordered.len);
        for (ordered, 0..) |name, index| {
            const schema = findSchema(name) orelse return error.MissingToolSchema;
            schemas[index] = .{
                .name = schema.name,
                .description = schema.description,
                .parameters_json = schema.input_schema_json,
            };
            specs[index] = .{
                .name = schema.name,
                .description = schema.description,
                .parameters_json = schema.input_schema_json,
            };
        }
        self.tool_schemas = schemas;
        self.tool_specs = specs;
    }

    fn findSchema(name: []const u8) ?registry.Schema {
        for (registry.core_schemas) |schema| {
            if (std.mem.eql(u8, schema.name, name)) return schema;
        }
        return null;
    }

    /// System prompt plus the runtime-context block (working directory, file
    /// and approval policy), rendered once per harness.
    fn buildPrompt(self: *Self) !void {
        const perm = self.perm.allocator();
        const built = try prompt.buildSystemPrompt(perm, .{
            .persona_prefix = self.opts.persona,
        });

        const sandbox: context.SandboxMode = switch (self.opts.sandbox) {
            .read_only => .read_only,
            .workspace_write => .workspace_write,
            .danger_full_access => .danger_full_access,
        };
        const approval: context.ApprovalPolicy = switch (self.opts.approval_policy) {
            .ask => .ask,
            .never => .never,
        };
        const sections = [_]context.Section{
            try context.workingDirectorySection(perm, self.workspace()),
            try context.sandboxPolicySection(perm, sandbox, self.workspace()),
            context.approvalPolicySection(approval),
        };
        const rendered = try context.renderContextSnapshot(perm, &sections);
        self.system_prompt = if (rendered.len == 0)
            built
        else
            try std.fmt.allocPrint(perm, "{s}\n\n{s}", .{ built, rendered });
    }

    fn closeSession(self: *Self) void {
        self.cancelCall();
        if (self.loop) |*l| {
            l.deinit();
            self.loop = null;
        }
        if (self.goal_store) |store| {
            store.reset();
            store.attachLog(null);
        }
        if (self.goal_driver) |*driver| driver.pending = null;
        if (self.log) |*log| {
            log.close();
            self.log = null;
        }
        for (self.pending_calls.items) |entry| self.freePendingCall(entry);
        self.pending_calls.clearRetainingCapacity();
        self.turn_text.clearRetainingCapacity();
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
        // The list itself lived in the arena that was just released.
        self.messages = .empty;
        self.session_id = "";
        self.last_assistant_text = null;
        self.total_tokens = 0;
        self.context_written = false;
    }

    // ── session lifecycle ────────────────────────────────────────────────────

    /// Create a fresh session id + JSONL, take its write lease and start the
    /// kernel loop.
    fn openNewSession(self: *Self, session_id: ?[]const u8) !void {
        self.closeSession();
        const arena = self.arena.allocator();

        const id = if (session_id) |value|
            try arena.dupe(u8, value)
        else
            try newSessionId(arena);
        self.session_id = id;

        const header = types.Header{
            .id = id,
            .created_at = self.now() orelse compat.time.milliTimestamp(),
            .cwd = self.workspace(),
            .is_seeded = false,
            .delegation_depth = 0,
        };
        self.log = try session_store.createLog(self.allocator, self.opts.dsh_home, self.workspace(), id, header);
        if (self.goal_store) |store| store.attachLog(&self.log.?);
        self.buildLoop();
    }

    /// Reopen the JSONL for `session_id` and rebuild the surface from it.
    fn openExistingSession(self: *Self, session_id: []const u8) !void {
        self.closeSession();
        const arena = self.arena.allocator();
        self.session_id = try arena.dupe(u8, session_id);
        self.log = try session_store.openLog(self.allocator, self.opts.dsh_home, self.workspace(), self.session_id);
        if (self.goal_store) |store| store.attachLog(&self.log.?);

        var read = session_log.readLog(self.allocator, self.log.?.path) catch |err| {
            if (self.opts.on_corrupt != .native) return err;
            try self.startFresh();
            return;
        };
        defer read.deinit();
        // Snapshot the last header in force before the read arena dies: the
        // kernel must log `resume`, not `initial`, for a reopened session.
        var baseline: ?request.Header = null;
        for (read.events) |event| {
            if (!std.mem.eql(u8, event.event_type, "request/header")) continue;
            baseline = try cloneLastHeader(arena, event) orelse baseline;
        }
        for (read.events) |event| {
            if (std.mem.eql(u8, event.event_type, "permission/preset")) self.context_written = true;
        }
        try self.rebuildSurface(read.events, arena);
        if (self.goal_store) |store| store.rebuild(read.events) catch |err| {
            // Same policy as a corrupt log: a projection the log cannot
            // replay starts a fresh session instead of wedging every open.
            if (self.opts.on_corrupt != .native) return err;
            try self.startFresh();
            return;
        };
        self.buildLoop();
        if (baseline) |header| {
            const loop = &self.loop.?;
            loop.last_header = header;
            loop.tracker.logged = true;
        }
    }

    fn cloneLastHeader(allocator: Allocator, event: types.Event) !?request.Header {
        const object = switch (event.data) {
            .object => |value| value,
            else => return null,
        };
        const header_value = object.get("header") orelse return null;
        const header_object = switch (header_value) {
            .object => |value| value,
            else => return null,
        };
        const config_value = header_object.get("config") orelse return null;
        const config_object = switch (config_value) {
            .object => |value| value,
            else => return null,
        };
        const provider = switch (config_object.get("provider") orelse return null) {
            .string => |text| try allocator.dupe(u8, text),
            else => return null,
        };
        const model = switch (config_object.get("model") orelse return null) {
            .string => |text| try allocator.dupe(u8, text),
            else => return null,
        };
        return .{ .config = .{ .provider = provider, .model = model } };
    }

    /// Rebuild the model-visible surface (and the tool-call id map) from a log.
    fn rebuildSurface(self: *Self, events: []const types.Event, arena: Allocator) !void {
        var fold = try surface_mod.fold(self.allocator, events);
        defer fold.deinit();

        const messages = try arena.alloc(types.Message, fold.nodes.len);
        for (fold.nodes, 0..) |node, index| {
            messages[index] = try cloneMessage(arena, node.message);
        }
        try self.messages.appendSlice(arena, messages);
    }

    fn buildLoop(self: *Self) void {
        if (self.loop) |*existing| existing.deinit();
        self.loop = null;
        const arena = std.heap.ArenaAllocator.init(self.allocator);
        self.loop = loop_mod.Loop.init(arena, .{
            .provider = self.opts.provider_name,
            .model = self.opts.model,
            .reasoning_effort = self.opts.reasoning_effort,
            .max_tokens = self.opts.max_tokens,
            .tools = self.tool_schemas,
            .max_parallel_tools = self.opts.max_parallel_tools,
            .now_ms = self.opts.now_ms,
            .clock_context = self.opts.clock_context,
        }, .{
            .context = @ptrCast(self),
            .emit = hostEmit,
            .system_messages = hostSystemMessages,
            .pre_step = hostPreStep,
            .serialize_message = hostSerializeMessage,
            .provider = .{
                .context = @ptrCast(self),
                .begin = providerBegin,
                .next = providerNext,
                .cancel = providerCancel,
            },
            .classifier = .{ .context = @ptrCast(self), .is_concurrency_safe = classifyTool },
            .dispatcher = .{ .context = @ptrCast(self), .dispatch = dispatchTool },
        });
    }

    // ── reset / restore / mapping ────────────────────────────────────────────

    /// `/new`: fresh dsh session id, fresh JSONL, rewritten mapping. `reset`
    /// cannot report, so a failure is recorded for the next turn.
    fn reset(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.resetSession() catch |err| {
            self.reset_error = err;
        };
    }

    fn resetSession(self: *Self) !void {
        self.reset_error = null;
        try self.openNewSession(null);
        try self.writeMapping();
    }

    fn restore(ptr: *anyopaque, input: port.RestoreInput) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // The mapping, not the host's memory of the id, is the resume source:
        // a restarted host and the dsh sidecar then read the same JSONL.
        const stored = try self.loadMappedId();
        const session_id = input.dsh_session_id orelse stored orelse {
            try self.startFresh();
            return;
        };
        self.openExistingSession(session_id) catch |err| switch (err) {
            error.FileNotFound => try self.startFresh(),
            else => return err,
        };
    }

    fn startFresh(self: *Self) !void {
        try self.openNewSession(null);
        try self.writeMapping();
    }

    fn loadMappedId(self: *Self) !?[]const u8 {
        const arena = self.arena.allocator();
        const path = self.mappingPath(arena) catch |err| switch (err) {
            error.NoSessionDir => return null,
            else => return err,
        };
        const loaded = try session_store.loadMapping(self.allocator, path) orelse return null;
        defer self.allocator.free(loaded);
        return try arena.dupe(u8, loaded);
    }

    /// `{session_dir}/{Wyhash(session_key)}.json`, the sidecar's format.
    fn mappingPath(self: *Self, allocator: Allocator) ![]u8 {
        const dir = self.opts.session_dir orelse return error.NoSessionDir;
        const name = try std.fmt.allocPrint(allocator, "{x}.json", .{std.hash.Wyhash.hash(0, self.opts.session_key)});
        defer allocator.free(name);
        return std.fs.path.join(allocator, &.{ dir, name });
    }

    fn writeMapping(self: *Self) !void {
        const path = self.mappingPath(self.allocator) catch |err| switch (err) {
            error.NoSessionDir => return,
            else => return err,
        };
        defer self.allocator.free(path);
        const dir = std.fs.path.dirname(path) orelse ".";
        try fs_compat.makePath(dir);

        // Write beside the target then rename: a crash can never leave a
        // truncated mapping that points resume at a half-written id.
        const temp_name = try std.fmt.allocPrint(self.allocator, ".dsh-mapping-{x}.tmp", .{
            compat.crypto.random.int(u64),
        });
        defer self.allocator.free(temp_name);
        const temp_path = try std.fs.path.join(self.allocator, &.{ dir, temp_name });
        defer self.allocator.free(temp_path);
        {
            const file = try fs_compat.createPath(temp_path, .{ .truncate = true, .exclusive = true });
            errdefer fs_compat.deletePath(temp_path) catch {};
            defer file.close();
            var writer: Writer.Allocating = .init(self.allocator);
            defer writer.deinit();
            try writer.writer.writeAll("{\"sessionId\":");
            try std.json.Stringify.value(self.session_id, .{}, &writer.writer);
            try writer.writer.writeByte('}');
            try file.writeAll(writer.written());
            try file.sync();
        }
        fs_compat.renamePath(temp_path, path) catch |err| {
            fs_compat.deletePath(temp_path) catch {};
            return err;
        };
        fs_compat.syncDirPath(dir) catch {};
    }

    // ── port.Harness vtable ──────────────────────────────────────────────────

    const vtable = port.Harness.VTable{
        .runTurn = runTurn,
        .requestInterrupt = requestInterrupt,
        .clearInterrupt = clearInterrupt,
        .activeToolName = activeToolName,
        .restore = restore,
        .reset = reset,
        .invalidatePrompt = invalidatePrompt,
        .info = info,
        .deinit = deinitVtable,
    };

    fn deinitVtable(ptr: *anyopaque, allocator: Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    fn runTurn(ptr: *anyopaque, input: port.TurnInput) anyerror!port.TurnResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.in_turn) return error.TurnInProgress;
        if (self.reset_error) |err| {
            self.reset_error = null;
            return err;
        }
        if (self.log == null) try self.startFresh();
        const loop = if (self.loop) |*value| value else return error.NoSession;

        const arena = self.arena.allocator();
        self.in_turn = true;
        defer self.in_turn = false;
        // A goal round is one kernel turn; never leak that authority forward.
        defer {
            if (self.goal_tools) |tools| tools.authority = .{};
        }
        self.sink = input.sink;
        self.live_stream = input.live_stream;
        self.drain = input.drain;
        self.drain_ctx = input.drain_ctx;
        defer {
            self.sink = null;
            self.drain = null;
            self.drain_ctx = null;
        }

        self.turn_text.clearRetainingCapacity();
        self.last_assistant_text = null;
        const calls_before = self.turn_model_calls;

        // A pre-turn /stop behaves like native's: the turn still runs and
        // closes through the kernel's abort path.
        if (self.interrupt) loop.abort(.user);

        const message_id = try self.nextMessageId();
        const data = try self.userMessageJson(arena, message_id, input.user_message);
        _ = try loop.inbox.followup(.{ .id = message_id, .data = data });

        if (!self.context_written) {
            try self.writeSessionDefaults(arena);
            self.context_written = true;
        }

        // Automatic goal continuation: after a completed turn, the driver
        // reserves at most one `<goal_round>` followup and the kernel runs it
        // as another turn in this session; terminal goal phases stop it.
        var outcome = try loop.runTurn();
        while (true) {
            const reason = switch (outcome) {
                .ended => |value| value,
                .paused => return error.UnexpectedPause,
            };
            const continues = switch (reason) {
                .completed => true,
                else => false,
            };
            if (!continues) break;
            const driver = if (self.goal_driver) |*value| value else break;
            const continuation = (try driver.next(arena)) orelse break;
            _ = try loop.followup(continuation);
            outcome = try loop.runTurn();
        }
        const reason = switch (outcome) {
            .ended => |value| value,
            .paused => return error.UnexpectedPause,
        };
        self.interrupt = false;

        // `reply` and `error` are owned by the host's allocator (native.zig
        // hands back Agent-allocated memory); the engine's arena copies here.
        const reply = try self.allocator.dupe(u8, self.turn_text.items);
        errdefer self.allocator.free(reply);
        var result = port.TurnResult{
            .reply = reply,
            .persisted_reply = null,
            .total_tokens = self.total_tokens,
            .end_reason = mapEndReason(reason),
            .dsh_session_id = self.session_id,
            .turn_count = self.turn_model_calls - calls_before,
        };
        if (self.last_assistant_text) |text| result.persisted_reply = text;
        switch (reason) {
            .aborted => |cause| result.abort_cause = switch (cause) {
                .user => "user",
                .parent => "parent",
                .hook => "hook",
                .disposed => "disposed",
                .legacy => "legacy",
            },
            .failure => |failure| {
                result.@"error" = try self.allocator.dupe(u8, failure.message);
                result.error_code = failure.code;
            },
            else => {},
        }
        return result;
    }

    fn mapEndReason(reason: types.EndReason) port.EndReason {
        return switch (reason) {
            .completed => .completed,
            .aborted => .aborted,
            .blocked => .blocked,
            .failure => .@"error",
            .max_tokens => .max_tokens,
            .interrupted => .interrupted,
            .forked => .forked,
        };
    }

    fn requestInterrupt(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.interrupt = true;
        if (self.loop) |*loop| loop.abort(.user);
    }

    fn clearInterrupt(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.interrupt = false;
        // A /stop that arrives after the turn ended sets the kernel flag below
        // the adapter; drop it too, or the next turn aborts before the model.
        if (!self.in_turn) if (self.loop) |*loop| loop.clearAbort();
    }

    fn activeToolName(ptr: *anyopaque, allocator: Allocator) anyerror!?[]u8 {
        _ = ptr;
        _ = allocator;
        return null;
    }

    fn invalidatePrompt(ptr: *anyopaque) void {
        // The prompt is rendered per harness; nothing is cached per turn.
        _ = ptr;
    }

    fn info(ptr: *anyopaque) port.Info {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return .{
            .provider_name = self.opts.provider_name,
            .model_name = self.opts.model,
            .workspace_dir = self.workspace(),
            .allowed_paths = &.{},
            .has_own_autonomy = false,
            .queue_mode = .steer,
            .reasoning_mode = .off,
            .redactor = null,
            .harness_kind = .dsh_native,
            .owns_inbox = true,
            .supports_commands = false,
            .dsh_session_id = if (self.session_id.len == 0) null else self.session_id,
        };
    }

    fn nextMessageId(self: *Self) ![]const u8 {
        const id = try std.fmt.allocPrint(self.arena.allocator(), "msg-{d}", .{self.next_id});
        self.next_id += 1;
        return id;
    }

    // ── log writers ─────────────────────────────────────────────────────────

    fn writeSessionDefaults(self: *Self, arena: Allocator) !void {
        const sandbox = self.opts.sandbox.toSlice();
        var preset = std.json.ObjectMap.empty;
        try preset.put(arena, "preset", .{ .string = sandbox });
        _ = try self.appendEvent("permission/preset", .{ .object = preset }, null, null);

        var mode = std.json.ObjectMap.empty;
        try mode.put(arena, "mode", .{ .string = sandbox });
        _ = try self.appendEvent("sandbox/mode", .{ .object = mode }, null, null);

        var policy = std.json.ObjectMap.empty;
        try policy.put(arena, "policy", .{ .string = self.opts.approval_policy.toSlice() });
        _ = try self.appendEvent("approval/policy", .{ .object = policy }, null, null);
    }

    /// One `user/message` payload exactly as dsh stores it.
    fn userMessageJson(self: *Self, allocator: Allocator, id: []const u8, text: []const u8) ![]u8 {
        _ = self;
        var writer: Writer.Allocating = .init(allocator);
        defer writer.deinit();
        const w = &writer.writer;
        try w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(text, .{}, w);
        try w.writeAll("}],\"source\":{\"kind\":\"user\"},\"role\":\"user\",\"id\":");
        try std.json.Stringify.value(id, .{}, w);
        try w.writeByte('}');
        return writer.toOwnedSlice();
    }

    fn cloneMessage(allocator: Allocator, message: types.Message) !types.Message {
        const blocks = try allocator.alloc(types.ContentBlock, message.content.len);
        for (message.content, 0..) |block, index| {
            blocks[index] = switch (block) {
                .text => |text| .{ .text = try allocator.dupe(u8, text) },
                .reasoning => |text| .{ .reasoning = try allocator.dupe(u8, text) },
                .tool_call => |call| .{ .tool_call = .{
                    .id = try allocator.dupe(u8, call.id),
                    .name = try allocator.dupe(u8, call.name),
                    .arguments = try allocator.dupe(u8, call.arguments),
                } },
                .raw => |value| .{ .raw = try cloneValue(allocator, value) },
            };
        }
        return .{
            .id = try allocator.dupe(u8, message.id),
            .role = message.role,
            .content = blocks,
            .source = switch (message.source) {
                .user => .user,
                .system_prompt => .system_prompt,
                .model => |source| .{ .model = .{
                    .provider = try allocator.dupe(u8, source.provider),
                    .model = try allocator.dupe(u8, source.model),
                } },
                .tool => |source| .{ .tool = .{ .call_id = try allocator.dupe(u8, source.call_id) } },
                .other => |value| .{ .other = try cloneValue(allocator, value) },
            },
            .tool_call_id = if (message.tool_call_id) |id| try allocator.dupe(u8, id) else null,
            .is_error = message.is_error,
        };
    }

    fn cloneValue(allocator: Allocator, value: Value) !Value {
        const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(text);
        return std.json.parseFromSliceLeaky(Value, allocator, text, .{ .allocate = .alloc_always });
    }

    // ── kernel host callbacks ───────────────────────────────────────────────

    fn selfOf(context_ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(context_ptr));
    }

    fn hostEmit(context_ptr: *anyopaque, event: loop_mod.Event) anyerror!u64 {
        const self = selfOf(context_ptr);
        switch (event) {
            .turn_start => |payload| {
                return self.appendPositional("turn/start", null, payload.turn, 0);
            },
            .step_start => |position| {
                return self.appendPositional("step/start", position, 0, 0);
            },
            .system_message => |payload| return self.appendSystemMessage(payload.position, payload.message),
            .user_message => |payload| return self.appendUserMessage(payload.position, payload.message),
            .request_start => |payload| return self.appendRequestStart(payload.header),
            .assistant_stream => |payload| {
                self.forwardDelta(payload.event);
                return 0;
            },
            .assistant_message => |payload| return self.appendAssistant(payload.position, payload.settlement, false),
            .assistant_attempt => |payload| return self.appendAssistant(payload.position, payload.settlement, true),
            .tool_call => |payload| return self.appendToolCall(payload.position, payload.call),
            .tool_result => |payload| return self.appendToolResult(payload.position, payload.result),
            .step_end => |position| {
                const seq = try self.appendPositional("step/end", position, 0, 0);
                // Pull a host steer here, not in `pre_step`: the kernel claims
                // next-step input *before* calling `pre_step`, so a steer added
                // there would only reach the step after next.
                try self.pumpSteer(self.arena.allocator());
                return seq;
            },
            .turn_end => |payload| {
                const arena = self.arena.allocator();
                var data = try objectWithPosition(arena, null, payload.turn, 0);
                try data.put(arena, "reason", try endReasonValue(arena, payload.reason));
                return self.appendEvent("turn/end", .{ .object = data }, null, null);
            },
        }
    }

    fn objectWithPosition(
        allocator: Allocator,
        position: ?loop_mod.Position,
        turn: u64,
        step: u64,
    ) !std.json.ObjectMap {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "turn", .{ .integer = @intCast(if (position) |value| value.turn else turn) });
        const step_value = if (position) |value| value.step else step;
        if (step_value != 0) try object.put(allocator, "step", .{ .integer = @intCast(step_value) });
        return object;
    }

    fn appendPositional(self: *Self, event_type: []const u8, position: ?loop_mod.Position, turn: u64, step: u64) !u64 {
        const data = try objectWithPosition(self.arena.allocator(), position, turn, step);
        return self.appendEvent(event_type, .{ .object = data }, null, null);
    }

    fn appendSystemMessage(self: *Self, position: loop_mod.Position, message: loop_mod.SystemMessage) !u64 {
        const arena = self.arena.allocator();
        var data = try objectWithPosition(arena, position, 0, 0);
        const id = try arena.dupe(u8, message.id);
        const text = try arena.dupe(u8, message.text);
        try data.put(arena, "message", try systemMessageValue(arena, id, text));
        const seq = try self.appendEvent("system/message", .{ .object = data }, .append, null);
        try self.addSurfaceSnapshot(arena, .{
            .id = id,
            .role = .system,
            .content = try arena.dupe(types.ContentBlock, &.{.{ .text = text }}),
            .source = .system_prompt,
        });
        return seq;
    }

    fn appendUserMessage(self: *Self, position: loop_mod.Position, message: loop_mod.UserMessage) !u64 {
        _ = position;
        const arena = self.arena.allocator();
        // dsh stores `user/message` with the message at the top level of
        // `data` (no inner `message` key); `surface.fold` reads it that way.
        const data = try parseValue(arena, message.json);
        // Fold before logging: a goal round the projection rejects (stale
        // revision, wrong phase) must not leave a user/message the log can
        // never replay.
        // Regression: logging first turned one rejected goal round into a
        // session that failed every later open/restore with GoalInvalidChange.
        if (self.goal_store) |store| {
            try store.applyEvent(.{
                .event_type = "user/message",
                .seq = 0,
                .time_ms = 0,
                .data = data,
            });
        }
        // Authority follows the admitted message, not the loop position: a
        // goal followup queued before a pause can be admitted in a later
        // human turn and must stay autonomous. Wrap-ups keep the open turn.
        if (self.goal_tools) |tools| {
            const kind = messageSourceKind(data);
            if (std.mem.eql(u8, kind, "goal")) {
                if (self.goal_store) |store| {
                    tools.authority = .{ .direct_human = false, .goal_round = store.find() };
                }
            } else if (!std.mem.eql(u8, kind, "tool-goal")) {
                tools.authority = .{};
            }
        }
        const seq = try self.appendEvent("user/message", data, .append, message.source_event_seqs);
        try self.addSurfaceSnapshot(arena, try surface_mod.messageFromEvent(arena, .{
            .event_type = "user/message",
            .seq = seq,
            .time_ms = 0,
            .data = data,
            .surface_op = .append,
        }));
        return seq;
    }

    fn appendRequestStart(self: *Self, decision: request.HeaderDecision) !u64 {
        if (!decision.append) return 0;
        const arena = self.arena.allocator();
        var data: std.json.ObjectMap = .empty;
        try data.put(arena, "header", try headerValue(arena, decision.header));
        try data.put(arena, "reason", .{ .string = headerReasonName(decision.reason) });
        return self.appendEvent("request/header", .{ .object = data }, null, null);
    }

    fn appendAssistant(
        self: *Self,
        position: loop_mod.Position,
        settlement: stream.Settlement,
        is_attempt: bool,
    ) !u64 {
        const arena = self.arena.allocator();
        var data = try objectWithPosition(arena, position, 0, 0);
        try data.put(arena, "message", try messageValue(arena, settlement.message));
        if (settlement.usage) |usage| try data.put(arena, "usage", try usageValue(arena, usage));
        try data.put(arena, "stream", try streamValue(arena, settlement.stream));
        if (settlement.interrupted) try data.put(arena, "interrupted", .{ .bool = true });

        if (is_attempt) {
            return self.appendEvent("assistant/attempt", .{ .object = data }, null, null);
        }

        const seq = try self.appendEvent("assistant/message", .{ .object = data }, .append, null);

        // The host renders the turn's whole text; the log keeps every segment.
        const text = try textOf(arena, settlement.message.content);
        try self.turn_text.appendSlice(self.allocator, text);
        if (countToolCalls(settlement.message.content) == 0) self.last_assistant_text = text;
        if (self.sink) |sink| {
            if (text.len > 0) sink.send(.{ .assistant_message = .{ .text = text } });
        }
        // The kernel's accumulator arena dies at step end: copy first.
        try self.addSurfaceSnapshot(arena, try cloneMessage(arena, settlement.message));
        if (settlement.usage) |usage| {
            self.total_tokens += usage.input_tokens + usage.output_tokens;
            // The host's ledger wants one record per model call, like the
            // native engine's `usage_record_callback`. The engine never calls
            // that callback, so this is the only source (no double count).
            if (self.sink) |sink| {
                const total = usage.total_tokens orelse (usage.input_tokens +| usage.output_tokens);
                sink.send(.{ .usage = .{
                    .ts = compat.time.timestamp(),
                    .provider = self.opts.provider_name,
                    .model = self.opts.model,
                    .usage = .{
                        .prompt_tokens = clampU32(usage.input_tokens),
                        .completion_tokens = clampU32(usage.output_tokens),
                        .total_tokens = clampU32(total),
                    },
                    .success = true,
                } });
            }
        }
        return seq;
    }

    fn freePendingCall(self: *Self, entry: PendingCall) void {
        self.allocator.free(entry.call.id);
        self.allocator.free(entry.call.name);
        self.allocator.free(entry.call.arguments);
    }

    fn appendToolCall(self: *Self, position: loop_mod.Position, call: types.ToolCall) !u64 {
        const arena = self.arena.allocator();
        var data = try objectWithPosition(arena, position, 0, 0);
        try data.put(arena, "callId", .{ .string = call.id });
        try data.put(arena, "name", .{ .string = call.name });
        try data.put(arena, "arguments", .{ .string = call.arguments });
        const seq = try self.appendEvent("tool/call", .{ .object = data }, null, null);

        // Owned by the long-lived allocator: entries outlive arena resets.
        try self.pending_calls.append(self.allocator, .{
            .call = .{
                .id = try self.allocator.dupe(u8, call.id),
                .name = try self.allocator.dupe(u8, call.name),
                .arguments = try self.allocator.dupe(u8, call.arguments),
            },
            .seq = seq,
        });
        if (self.sink) |sink| sink.send(.{ .tool_call = .{
            .call_id = call.id,
            .name = call.name,
            .arguments_json = call.arguments,
        } });
        return seq;
    }

    fn appendToolResult(self: *Self, position: loop_mod.Position, result: registry.ToolResult) !u64 {
        const arena = self.arena.allocator();
        // The kernel commits results in model order, one per pending call.
        if (self.pending_calls.items.len == 0) return error.UnexpectedToolResult;
        const call = self.pending_calls.items[0];
        _ = self.pending_calls.orderedRemove(0);
        defer self.freePendingCall(call);

        const message = types.Message{
            .id = try self.nextMessageId(),
            .role = .tool,
            .content = result.content(),
            .source = .{ .tool = .{ .call_id = try arena.dupe(u8, call.call.id) } },
            .tool_call_id = try arena.dupe(u8, call.call.id),
            .is_error = result.isError(),
        };
        var data = try objectWithPosition(arena, position, 0, 0);
        try data.put(arena, "message", try messageValue(arena, message));
        switch (result) {
            .success => |success| if (success.meta) |meta| try data.put(arena, "meta", try cloneValue(arena, meta)),
            .failure => |failure| {
                var error_object: std.json.ObjectMap = .empty;
                try error_object.put(arena, "name", .{ .string = failure.error_info.name });
                try error_object.put(arena, "code", .{ .string = failure.error_info.code });
                if (failure.error_info.reason) |reason| {
                    try error_object.put(arena, "reason", .{ .string = reason });
                }
                try data.put(arena, "error", .{ .object = error_object });
                if (failure.meta) |meta| try data.put(arena, "meta", try cloneValue(arena, meta));
            },
        }
        const seqs = [1]u64{call.seq};
        const seq = try self.appendEvent("tool/result", .{ .object = data }, .append, &seqs);
        try self.addSurfaceSnapshot(arena, try cloneMessage(arena, message));
        if (self.sink) |sink| sink.send(.{ .tool_result = .{
            .call_id = call.call.id,
            .name = call.call.name,
            .output = try toolOutputText(arena, result),
            .is_error = result.isError(),
        } });
        return seq;
    }

    /// Record one surface message in request order. The caller passes an
    /// arena-owned message; it is adopted, not copied.
    fn addSurfaceSnapshot(self: *Self, arena: Allocator, message: types.Message) !void {
        try self.messages.append(arena, message);
    }

    fn forwardDelta(self: *Self, event: stream.Event) void {
        // The blocking provider path yields one text chunk per attempt, which
        // `appendAssistant` already reports as an `assistant_message`.
        switch (event) {
            .chunk => |chunk| switch (chunk) {
                .text_delta => |delta| if (self.live_stream) {
                    if (self.sink) |sink| sink.send(.{ .delta = .{
                        .delta = delta.text,
                        .is_final = false,
                        .token_count = @intCast((delta.text.len + 3) / 4),
                    } });
                },
                else => {},
            },
            .done, .record => {},
        }
    }

    // ── kernel host: prompt + steer ─────────────────────────────────────────

    fn hostSystemMessages(
        context_ptr: *anyopaque,
        allocator: Allocator,
        position: loop_mod.Position,
        out: *std.ArrayListUnmanaged(loop_mod.SystemMessage),
    ) anyerror!void {
        const self = selfOf(context_ptr);
        if (position.step != 1) return;
        const id = try std.fmt.allocPrint(allocator, "system-{d}", .{position.turn});
        try out.append(allocator, .{ .id = id, .text = self.system_prompt });
    }

    /// Steer: take what the host collected and put it on the kernel's
    /// next-step queue. The drain returns a slice allocated with `allocator`.
    fn pumpSteer(self: *Self, allocator: Allocator) !void {
        const drain = self.drain orelse return;
        const drain_ctx = self.drain_ctx orelse return;
        const text = try drain(drain_ctx, allocator) orelse return;
        if (text.len == 0) return;

        const loop = if (self.loop) |*value| value else return;
        const id = try self.nextMessageId();
        const data = try self.userMessageJson(allocator, id, text);
        _ = try loop.inbox.steer(.{ .id = id, .data = data });
    }

    /// `agent/pre-step`: this adapter returns no runtime-context extras and
    /// never vetoes; steer is pumped at the preceding `step_end` instead.
    fn hostPreStep(
        context_ptr: *anyopaque,
        allocator: Allocator,
        position: loop_mod.Position,
        claimed: loop_mod.Claimed,
        out: *std.ArrayListUnmanaged(loop_mod.UserMessage),
    ) anyerror!loop_mod.PreStepDecision {
        _ = context_ptr;
        _ = allocator;
        _ = position;
        _ = claimed;
        _ = out;
        return .{};
    }

    fn hostSerializeMessage(
        context_ptr: *anyopaque,
        allocator: Allocator,
        message: types.Message,
    ) anyerror![]u8 {
        _ = context_ptr;
        return std.json.Stringify.valueAlloc(allocator, try messageValue(allocator, message), .{});
    }

    // ── provider bridge (kernel -> junclaw provider) ────────────────────────

    /// One blocking provider call per attempt. The whole assistant message is
    /// pushed as a synthetic stream (text chunk, tool-call chunks, done); the
    /// kernel assembles it exactly like a live one.
    fn providerBegin(context_ptr: *anyopaque, view: loop_mod.RequestView) anyerror!void {
        const self = selfOf(context_ptr);
        self.cancelCall();
        self.pending.clearRetainingCapacity();
        self.pending_index = 0;

        const arena = self.call_arena.allocator();
        const messages = try requestsFromMessages(arena, self.messages.items);
        const chat = providers.ChatRequest{
            .messages = messages,
            .model = self.opts.model,
            .temperature = self.opts.temperature,
            .max_tokens = self.opts.max_tokens,
            .tools = self.tool_specs,
            .reasoning_effort = self.opts.reasoning_effort,
            .session_id = if (self.opts.session_key.len == 0) null else self.opts.session_key,
        };
        _ = view;

        var response = try self.opts.provider.chatWithTools(arena, chat);
        defer freeResponseFields(arena, &response);

        self.turn_model_calls += 1;
        const content: []const u8 = response.content orelse "";
        if (content.len > 0) {
            try self.pending.append(arena, .{ .chunk = .{ .text_delta = .{
                .index = 0,
                .text = try arena.dupe(u8, content),
            } } });
        }
        var done_calls = try arena.alloc(types.ToolCall, response.tool_calls.len);
        for (response.tool_calls, 0..) |call, index| {
            done_calls[index] = .{
                .id = try arena.dupe(u8, call.id),
                .name = try arena.dupe(u8, call.name),
                .arguments = try arena.dupe(u8, call.arguments),
            };
        }
        const usage = stream.ProviderUsage{
            .prompt_tokens = response.usage.prompt_tokens,
            .completion_tokens = response.usage.completion_tokens,
            .total_tokens = response.usage.total_tokens,
        };
        const finish: stream.Finish = if (response.tool_calls.len > 0)
            .tool_calls
        else if (response.truncated)
            .max_tokens
        else
            .stop;
        try self.pending.append(arena, .{ .done = .{
            .finish = finish,
            .usage = usage,
            .tool_calls = done_calls,
        } });
    }

    fn providerNext(context_ptr: *anyopaque) anyerror!?stream.Event {
        const self = selfOf(context_ptr);
        if (self.pending_index >= self.pending.items.len) return null;
        const event = self.pending.items[self.pending_index];
        self.pending_index += 1;
        return event;
    }

    fn providerCancel(context_ptr: *anyopaque) void {
        selfOf(context_ptr).cancelCall();
    }

    fn cancelCall(self: *Self) void {
        self.pending.clearRetainingCapacity();
        self.pending_index = 0;
        _ = self.call_arena.reset(.retain_capacity);
    }

    fn freeResponseFields(allocator: Allocator, response: *providers.ChatResponse) void {
        if (response.content) |content| if (content.len > 0) allocator.free(content);
        for (response.tool_calls) |call| {
            if (call.id.len > 0) allocator.free(call.id);
            if (call.name.len > 0) allocator.free(call.name);
            if (call.arguments.len > 0) allocator.free(call.arguments);
        }
        if (response.tool_calls.len > 0) allocator.free(response.tool_calls);
        if (response.provider.len > 0) allocator.free(response.provider);
        if (response.model.len > 0) allocator.free(response.model);
        if (response.reasoning_content) |reasoning| if (reasoning.len > 0) allocator.free(reasoning);
        response.content = null;
        response.tool_calls = &.{};
        response.provider = "";
        response.model = "";
        response.reasoning_content = null;
    }

    /// Surface items -> provider messages. Assistant tool calls are rendered as
    /// the native harness's `<tool_call>` text and tool results as the
    /// `[Tool results]` user message, because `ChatMessage` cannot carry an
    /// assistant `tool_calls` array.
    fn requestsFromMessages(allocator: Allocator, messages: []const types.Message) ![]providers.ChatMessage {
        var out: std.ArrayListUnmanaged(providers.ChatMessage) = .empty;
        for (messages, 0..) |message, index| {
            switch (message.role) {
                .system => {
                    // Every turn logs its own system message; the provider
                    // gets one, and only when it differs from the last one.
                    const text = try textOf(allocator, message.content);
                    if (index > 0 and messages[index - 1].role == .system) {
                        const previous = out.items[out.items.len - 1];
                        if (previous.role == .system and std.mem.eql(u8, previous.content, text)) continue;
                    }
                    try out.append(allocator, .{ .role = .system, .content = text });
                },
                .developer, .user => try out.append(allocator, .{
                    .role = .user,
                    .content = try textOf(allocator, message.content),
                }),
                .assistant => {
                    const text = try assistantHistoryText(allocator, message.content);
                    if (text.len == 0) continue;
                    try out.append(allocator, .{ .role = .assistant, .content = text });
                },
                .tool => {
                    const name = toolNameFor(messages, message.tool_call_id);
                    const body = try textOf(allocator, message.content);
                    const rendered = try std.fmt.allocPrint(
                        allocator,
                        "[Tool results]\n<tool_result name=\"{s}\" status=\"{s}\">\n{s}\n</tool_result>\n",
                        .{ name, if (message.is_error orelse false) "error" else "ok", body },
                    );
                    try out.append(allocator, .{ .role = .user, .content = rendered });
                },
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn toolNameFor(messages: []const types.Message, call_id: ?[]const u8) []const u8 {
        const wanted = call_id orelse return "tool";
        for (messages) |message| {
            for (message.content) |block| switch (block) {
                .tool_call => |call| if (std.mem.eql(u8, call.id, wanted)) return call.name,
                else => {},
            };
        }
        return "tool";
    }

    fn textOf(allocator: Allocator, content: []const types.ContentBlock) ![]const u8 {
        var buffer: Writer.Allocating = .init(allocator);
        defer buffer.deinit();
        for (content) |block| switch (block) {
            .text => |text| try buffer.writer.writeAll(text),
            else => {},
        };
        return buffer.toOwnedSlice();
    }

    fn countToolCalls(content: []const types.ContentBlock) usize {
        var count: usize = 0;
        for (content) |block| switch (block) {
            .tool_call => count += 1,
            else => {},
        };
        return count;
    }

    /// Assistant surface message -> provider text: visible text plus the
    /// `<tool_call>` blocks the next request has to answer.
    fn assistantHistoryText(allocator: Allocator, content: []const types.ContentBlock) ![]const u8 {
        var buffer: Writer.Allocating = .init(allocator);
        defer buffer.deinit();
        var wrote = false;
        for (content) |block| switch (block) {
            .text => |text| {
                if (text.len == 0) continue;
                if (wrote) try buffer.writer.writeByte('\n');
                try buffer.writer.writeAll(text);
                wrote = true;
            },
            .tool_call => |call| {
                if (wrote) try buffer.writer.writeByte('\n');
                try buffer.writer.writeAll("<tool_call>\n{\"name\": ");
                try std.json.Stringify.value(call.name, .{}, &buffer.writer);
                try buffer.writer.writeAll(", \"arguments\": ");
                if (call.arguments.len == 0) try buffer.writer.writeAll("{}") else try buffer.writer.writeAll(call.arguments);
                try buffer.writer.writeAll("}\n</tool_call>");
                wrote = true;
            },
            else => {},
        };
        return buffer.toOwnedSlice();
    }

    // ── tool bridge (kernel -> execute.zig) ────────────────────────────────

    /// Only the three read-only tools are concurrency-safe; everything else is
    /// exclusive, mirroring dsh's fail-closed classification.
    fn classifyTool(context_ptr: *anyopaque, call: types.ToolCall) bool {
        _ = context_ptr;
        return std.mem.eql(u8, call.name, "read") or
            std.mem.eql(u8, call.name, "grep") or
            std.mem.eql(u8, call.name, "glob");
    }

    fn dispatchTool(
        context_ptr: *anyopaque,
        allocator: Allocator,
        call: types.ToolCall,
        signal: scheduler.Signal,
    ) anyerror!registry.ToolResult {
        const self = selfOf(context_ptr);
        if (signal.isAborted()) return error.Aborted;
        if (self.interrupt) return error.Aborted;
        return execute.execute(&self.registry, allocator, call);
    }

    fn toolOutputText(allocator: Allocator, result: registry.ToolResult) ![]const u8 {
        return textOf(allocator, result.content());
    }

    // ── JSON shapes (mirroring dsh's v4 records) ───────────────────────────

    fn parseValue(allocator: Allocator, json: []const u8) !Value {
        return std.json.parseFromSliceLeaky(Value, allocator, json, .{ .allocate = .alloc_always });
    }

    fn systemMessageValue(allocator: Allocator, id: []const u8, text: []const u8) !Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "role", .{ .string = "system" });
        try object.put(allocator, "content", try contentValue(allocator, &.{.{ .text = text }}));
        var source: std.json.ObjectMap = .empty;
        try source.put(allocator, "kind", .{ .string = "system-prompt" });
        try object.put(allocator, "source", .{ .object = source });
        try object.put(allocator, "id", .{ .string = id });
        return .{ .object = object };
    }

    fn messageValue(allocator: Allocator, message: types.Message) !Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "role", .{ .string = @tagName(message.role) });
        try object.put(allocator, "content", try contentValue(allocator, message.content));
        try object.put(allocator, "source", try sourceValue(allocator, message.source));
        try object.put(allocator, "id", .{ .string = message.id });
        if (message.tool_call_id) |call_id| {
            try object.put(allocator, "toolCallId", .{ .string = call_id });
        }
        if (message.is_error) |is_error| try object.put(allocator, "isError", .{ .bool = is_error });
        return .{ .object = object };
    }

    fn contentValue(allocator: Allocator, blocks: []const types.ContentBlock) !Value {
        const items = try allocator.alloc(Value, blocks.len);
        for (blocks, 0..) |block, index| {
            var object: std.json.ObjectMap = .empty;
            switch (block) {
                .text => |text| {
                    try object.put(allocator, "type", .{ .string = "text" });
                    try object.put(allocator, "text", .{ .string = text });
                },
                .reasoning => |text| {
                    try object.put(allocator, "type", .{ .string = "reasoning" });
                    try object.put(allocator, "text", .{ .string = text });
                },
                .tool_call => |call| {
                    try object.put(allocator, "type", .{ .string = "tool-call" });
                    try object.put(allocator, "id", .{ .string = call.id });
                    try object.put(allocator, "name", .{ .string = call.name });
                    try object.put(allocator, "arguments", .{ .string = call.arguments });
                },
                .raw => |value| {
                    items[index] = value;
                    continue;
                },
            }
            items[index] = .{ .object = object };
        }
        var array = std.json.Array.init(allocator);
        try array.ensureTotalCapacity(items.len);
        for (items) |item| array.appendAssumeCapacity(item);
        return .{ .array = array };
    }

    fn sourceValue(allocator: Allocator, source: types.MessageSource) !Value {
        var object: std.json.ObjectMap = .empty;
        switch (source) {
            .user => try object.put(allocator, "kind", .{ .string = "user" }),
            .system_prompt => try object.put(allocator, "kind", .{ .string = "system-prompt" }),
            .model => |model| {
                try object.put(allocator, "kind", .{ .string = "model" });
                try object.put(allocator, "provider", .{ .string = model.provider });
                try object.put(allocator, "model", .{ .string = model.model });
            },
            .tool => |tool| {
                try object.put(allocator, "kind", .{ .string = "tool" });
                try object.put(allocator, "callId", .{ .string = tool.call_id });
            },
            .other => |value| return value,
        }
        return .{ .object = object };
    }

    /// The kernel counts u64 tokens; the host's provider type is u32.
    fn clampU32(value: u64) u32 {
        return @intCast(@min(value, std.math.maxInt(u32)));
    }

    fn usageValue(allocator: Allocator, usage: types.Usage) !Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "inputTokens", .{ .integer = @intCast(usage.input_tokens) });
        try object.put(allocator, "outputTokens", .{ .integer = @intCast(usage.output_tokens) });
        if (usage.total_tokens) |total| try object.put(allocator, "totalTokens", .{ .integer = @intCast(total) });
        if (usage.cache_read_tokens) |value| try object.put(allocator, "cacheReadTokens", .{ .integer = @intCast(value) });
        if (usage.cache_write_tokens) |value| try object.put(allocator, "cacheWriteTokens", .{ .integer = @intCast(value) });
        if (usage.reasoning_tokens) |value| try object.put(allocator, "reasoningTokens", .{ .integer = @intCast(value) });
        return .{ .object = object };
    }

    fn streamValue(allocator: Allocator, records: []const stream.StreamRecord) !Value {
        const items = try allocator.alloc(Value, records.len);
        for (records, 0..) |record, index| {
            var object: std.json.ObjectMap = .empty;
            switch (record) {
                .text_chunks, .reasoning_chunks => {
                    var type_name: []const u8 = "text-chunks";
                    var run: stream.TextRun = undefined;
                    switch (record) {
                        .text_chunks => |value| run = value,
                        .reasoning_chunks => |value| {
                            run = value;
                            type_name = "reasoning-chunks";
                        },
                        else => unreachable,
                    }
                    try object.put(allocator, "type", .{ .string = type_name });
                    try object.put(allocator, "time0", .{ .integer = run.time0 });
                    try object.put(allocator, "index", .{ .integer = @intCast(run.index) });
                    try object.put(allocator, "dt", try i64Array(allocator, run.dt));
                    try object.put(allocator, "texts", try stringArray(allocator, run.texts));
                },
                .tool_call_chunks => |run| {
                    try object.put(allocator, "type", .{ .string = "tool-call-chunks" });
                    try object.put(allocator, "time0", .{ .integer = run.time0 });
                    try object.put(allocator, "index", .{ .integer = @intCast(run.index) });
                    try object.put(allocator, "dt", try i64Array(allocator, run.dt));
                    try object.put(allocator, "id", .{ .string = run.id });
                    if (run.name) |name| try object.put(allocator, "name", .{ .string = name });
                    try object.put(allocator, "args", try stringArray(allocator, run.args));
                },
                .chunk => |raw| {
                    try object.put(allocator, "type", .{ .string = "chunk" });
                    try object.put(allocator, "time", .{ .integer = raw.time });
                    try object.put(allocator, "chunk", try chunkValue(allocator, raw.chunk));
                },
            }
            items[index] = .{ .object = object };
        }
        var array = std.json.Array.init(allocator);
        try array.ensureTotalCapacity(items.len);
        for (items) |item| array.appendAssumeCapacity(item);
        return .{ .array = array };
    }

    fn chunkValue(allocator: Allocator, chunk: stream.Chunk) !Value {
        var object: std.json.ObjectMap = .empty;
        switch (chunk) {
            .text_delta => |delta| {
                try object.put(allocator, "type", .{ .string = "text-delta" });
                try object.put(allocator, "index", .{ .integer = @intCast(delta.index) });
                try object.put(allocator, "text", .{ .string = delta.text });
            },
            .reasoning_delta => |delta| {
                try object.put(allocator, "type", .{ .string = "reasoning-delta" });
                try object.put(allocator, "index", .{ .integer = @intCast(delta.index) });
                try object.put(allocator, "text", .{ .string = delta.text });
            },
            .tool_call_delta => |delta| {
                try object.put(allocator, "type", .{ .string = "tool-call-delta" });
                try object.put(allocator, "index", .{ .integer = @intCast(delta.index) });
                try object.put(allocator, "id", .{ .string = delta.id });
                if (delta.name) |name| try object.put(allocator, "name", .{ .string = name });
                try object.put(allocator, "argumentsDelta", .{ .string = delta.arguments_delta });
            },
            .block_start => |start| {
                try object.put(allocator, "type", .{ .string = "block-start" });
                try object.put(allocator, "index", .{ .integer = @intCast(start.index) });
                try object.put(allocator, "blockType", .{ .string = start.block_type });
            },
            .block_end => |end| {
                try object.put(allocator, "type", .{ .string = "block-end" });
                try object.put(allocator, "index", .{ .integer = @intCast(end.index) });
                try object.put(allocator, "block", try contentValue(allocator, &.{end.block}));
            },
            .usage => |usage| {
                try object.put(allocator, "type", .{ .string = "usage" });
                try object.put(allocator, "usage", try usageValue(allocator, usage));
            },
            .finish => |finish| {
                try object.put(allocator, "type", .{ .string = "finish" });
                try object.put(allocator, "reason", .{ .string = finishKind(finish) });
            },
        }
        return .{ .object = object };
    }

    fn finishKind(finish: stream.Finish) []const u8 {
        return switch (finish) {
            .stop => "stop",
            .tool_calls => "tool-calls",
            .max_tokens => "max-tokens",
        };
    }

    fn endReasonValue(allocator: Allocator, reason: types.EndReason) !Value {
        var object: std.json.ObjectMap = .empty;
        switch (reason) {
            .completed => try object.put(allocator, "kind", .{ .string = "completed" }),
            .max_tokens => try object.put(allocator, "kind", .{ .string = "max-tokens" }),
            .blocked => try object.put(allocator, "kind", .{ .string = "blocked" }),
            .interrupted => try object.put(allocator, "kind", .{ .string = "interrupted" }),
            .forked => try object.put(allocator, "kind", .{ .string = "forked" }),
            .aborted => |cause| {
                try object.put(allocator, "kind", .{ .string = "aborted" });
                var reason_object: std.json.ObjectMap = .empty;
                switch (cause) {
                    .user => try reason_object.put(allocator, "kind", .{ .string = "user" }),
                    .parent => try reason_object.put(allocator, "kind", .{ .string = "parent" }),
                    .hook => |hook_reason| {
                        try reason_object.put(allocator, "kind", .{ .string = "hook" });
                        try reason_object.put(allocator, "reason", .{ .string = hook_reason });
                    },
                    .disposed => try reason_object.put(allocator, "kind", .{ .string = "disposed" }),
                    .legacy => try reason_object.put(allocator, "kind", .{ .string = "legacy" }),
                }
                try object.put(allocator, "reason", .{ .object = reason_object });
            },
            .failure => |failure| {
                try object.put(allocator, "kind", .{ .string = "error" });
                var error_object: std.json.ObjectMap = .empty;
                try error_object.put(allocator, "message", .{ .string = failure.message });
                try error_object.put(allocator, "code", .{ .string = failure.code });
                try object.put(allocator, "error", .{ .object = error_object });
            },
        }
        return .{ .object = object };
    }

    fn headerValue(allocator: Allocator, header: request.Header) !Value {
        var object: std.json.ObjectMap = .empty;
        var config: std.json.ObjectMap = .empty;
        try config.put(allocator, "provider", .{ .string = header.config.provider });
        try config.put(allocator, "model", .{ .string = header.config.model });
        if (header.config.reasoning_effort) |effort| {
            try config.put(allocator, "reasoningEffort", .{ .string = effort });
        }
        if (header.config.max_tokens) |max_tokens| {
            try config.put(allocator, "maxTokens", .{ .integer = @intCast(max_tokens) });
        }
        try object.put(allocator, "config", .{ .object = config });
        return .{ .object = object };
    }

    fn headerReasonName(reason: request.HeaderReason) []const u8 {
        return switch (reason) {
            .initial => "initial",
            .@"resume" => "resume",
            .change => "change",
            .series => "series",
        };
    }

    fn stringArray(allocator: Allocator, values: []const []const u8) !Value {
        var array = std.json.Array.init(allocator);
        try array.ensureTotalCapacity(values.len);
        for (values) |value| array.appendAssumeCapacity(.{ .string = value });
        return .{ .array = array };
    }

    fn i64Array(allocator: Allocator, values: []const i64) !Value {
        var array = std.json.Array.init(allocator);
        try array.ensureTotalCapacity(values.len);
        for (values) |value| array.appendAssumeCapacity(.{ .integer = value });
        return .{ .array = array };
    }
};

/// `source.kind` of a logged message, or "" when absent.
fn messageSourceKind(data: Value) []const u8 {
    const object = switch (data) {
        .object => |value| value,
        else => return "",
    };
    const source = switch (object.get("source") orelse return "") {
        .object => |value| value,
        else => return "",
    };
    return switch (source.get("kind") orelse return "") {
        .string => |value| value,
        else => return "",
    };
}

/// A v4 session id: 32 lowercase hex characters from a CSPRNG.
fn newSessionId(allocator: Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    compat.crypto.random.bytes(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &hex);
}

test "dsh-native harness: a rejected goal round never reaches the log" {
    // Regression: user/message was logged before `goal.Store` folded it, so a
    // stale goal round left a record every later open/restore failed to replay.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const dsh_home = try std.fs.path.join(allocator, &.{ root, "dsh-home" });
    defer allocator.free(dsh_home);
    try fs_compat.makePath(dsh_home);
    const workspace = try std.fs.path.join(allocator, &.{ root, "workspace" });
    defer allocator.free(workspace);
    try fs_compat.makePath(workspace);

    // The provider is unused: this drives the host emit path directly.
    var engine = try DshNativeHarness.init(allocator, .{
        .session_key = "test-session-key",
        .dsh_home = dsh_home,
        .workspace_dir = workspace,
        .provider = undefined,
        .provider_name = "",
        .model = "",
    });
    defer engine.deinit(allocator);
    engine.log = try session_store.createLog(allocator, dsh_home, workspace, "test-session", .{
        .id = "test-session",
        .created_at = 0,
        .cwd = workspace,
    });
    engine.goal_store.?.attachLog(&engine.log.?);

    const store = engine.goal_store.?;
    _ = try store.create("ship it", 4);

    const stale = loop_mod.UserMessage{
        .json = "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"stale\"}],\"source\":{\"kind\":\"goal\",\"goalId\":\"goal-1\",\"revision\":2,\"round\":1},\"id\":\"stale\"}",
    };
    try std.testing.expectError(error.GoalInvalidChange, engine.appendUserMessage(.{ .turn = 1, .step = 1 }, stale));

    var read = try session_log.readLog(allocator, engine.log.?.path);
    defer read.deinit();
    try std.testing.expectEqual(@as(usize, 1), read.events.len);
    try std.testing.expectEqualStrings("goal/change", read.events[0].event_type);

    const round = loop_mod.UserMessage{
        .json = "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"round one\"}],\"source\":{\"kind\":\"goal\",\"goalId\":\"goal-1\",\"revision\":1,\"round\":1},\"id\":\"round-1\"}",
    };
    _ = try engine.appendUserMessage(.{ .turn = 2, .step = 1 }, round);
    try std.testing.expectEqual(@as(u32, 1), store.rounds_started);
    // Authority is derived from the admitted message, not the loop position.
    try std.testing.expect(!engine.goal_tools.?.authority.direct_human);
    try std.testing.expectEqualStrings("goal-1", engine.goal_tools.?.authority.goal_round.?.id);

    const human = loop_mod.UserMessage{
        .json = "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"source\":{\"kind\":\"user\"},\"id\":\"human-1\"}",
    };
    _ = try engine.appendUserMessage(.{ .turn = 3, .step = 1 }, human);
    try std.testing.expect(engine.goal_tools.?.authority.direct_human);
}
