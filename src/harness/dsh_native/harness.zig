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
const approval_mod = @import("approval.zig");
const commands_mod = @import("commands.zig");
const compaction_mod = @import("compaction.zig");
const context = @import("context.zig");
const generated = @import("generated/tool_schemas.zig");
const generated_interaction = @import("generated/interaction.zig");
const generated_system_prompt = @import("generated/system_prompt.zig");
const questions_mod = @import("questions.zig");
const token_meter = @import("token_meter.zig");
const tools_ask_user = @import("tools/ask_user.zig");
const inbox = @import("inbox.zig");
const loop_mod = @import("loop.zig");
const prompt = @import("prompt.zig");
const request = @import("request.zig");
const registry = @import("tools/registry.zig");
const bridge = @import("tools/bridge.zig");
const builtins_mod = @import("tools/builtins.zig");
const bash_mod = @import("tools/bash.zig");
const goal_mod = @import("goal.zig");
const goal_command_mod = @import("goal_command.zig");
const goal_rounds = @import("goal_rounds.zig");
const goal_tools = @import("tools/goal.zig");
const plan_mod = @import("plan.zig");
const tools_exit_plan = @import("tools/exit_plan.zig");
const tools_todo = @import("tools/todo.zig");
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
    /// Routed model capacity for dsh proactive compaction. Zero disables the
    /// pre-step pressure probe; provider-confirmed overflow still compacts.
    context_window: u64 = 0,
    compaction_threshold_ratio: ?f64 = null,
    compaction_retain_ratio: ?f64 = null,
    compaction_headroom_tokens: ?u64 = null,
    /// Test seam: when non-empty, substitute workspace-path occurrences in
    /// message text with this fixed string for compaction pricing and prune
    /// windowing, so fixture results do not depend on the checkout location.
    /// Empty keeps the real path.
    workspace_placeholder: []const u8 = "",
    /// `agent.dsh_question_timeout`: ask_user_question wait in seconds.
    question_timeout_s: i32 = 120,
    temperature: f64 = 0.7,
    /// Deterministic clock for tests; null uses the wall clock.
    now_ms: ?*const fn (clock_context: ?*anyopaque) i64 = null,
    clock_context: ?*anyopaque = null,
    /// Host (junclaw) tools to bridge into the registry. Names, descriptions
    /// and schemas are copied into the permanent arena during `init`; the
    /// host keeps the strings alive only through `init`.
    host_tools: []const bridge.HostTool = &.{},
    /// Executor for `host_tools`; null disables bridging even when tools are
    /// listed, which keeps the default (native) configuration unchanged.
    host_executor: ?bridge.HostExecutor = null,
};

pub const DshNativeHarness = struct {
    const Self = @This();

    const PendingCall = struct {
        call: types.ToolCall,
        seq: u64,
    };

    allocator: Allocator,
    /// Permanent: tool schemas.
    perm: std.heap.ArenaAllocator,
    /// The system prompt, rebuilt when the folded permission state or the
    /// session changes; reset first so repeated renders stay bounded.
    prompt_arena: std.heap.ArenaAllocator,
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
    /// The same catalog plus `exit_plan_mode`; only plan mode advertises it.
    plan_tool_schemas: []const request.ToolSchema = &.{},
    plan_tool_specs: []const providers.ToolSpec = &.{},
    registry: registry.Registry = .{},
    builtins: ?*builtins_mod.Builtins = null,
    bash: ?*bash_mod.Context = null,
    goal_store: ?*goal_mod.Store = null,
    goal_tools: ?*goal_tools.Context = null,
    goal_driver: ?goal_rounds.Driver = null,
    ask_user: ?*tools_ask_user.Context = null,
    todo: ?*tools_todo.Context = null,
    exit_plan: ?*tools_exit_plan.Context = null,
    /// Logged plan mode plus the process-local selection queue. Heap-pinned:
    /// the exit tool borrows this pointer and the harness struct itself moves
    /// out of `init`.
    plan_session: *plan_mod.Session,
    approval: approval_mod.Service = .{ .options = .{} },
    /// Current turn's blocking host channel (null fails closed).
    interaction: ?port.Interaction = null,
    permission_state: commands_mod.PermissionState = .{},
    compaction_lock: compaction_mod.LockState = .{},
    /// Provider usage from the latest successful request; compaction's anchor.
    last_usage: ?types.Usage = null,
    /// Log seq of each surface node, parallel to `messages`.
    surface_seqs: std.ArrayListUnmanaged(u64) = .empty,
    system_prompt: []const u8 = "",
    spill_dir: []const u8 = "",

    in_turn: bool = false,
    /// Bumped by every prompt rebuild; a mid-turn bump re-logs the system
    /// message so the next request carries the plan policy change.
    prompt_generation: u64 = 0,
    emitted_prompt_generation: u64 = 0,
    /// Plan mode the rendered system prompt reflects.
    prompt_plan_active: bool = false,
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
        const plan_session = try allocator.create(plan_mod.Session);
        plan_session.* = .{};
        var self = Self{
            .plan_session = plan_session,
            .allocator = allocator,
            .perm = std.heap.ArenaAllocator.init(allocator),
            .prompt_arena = std.heap.ArenaAllocator.init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .opts = opts,
            .call_arena = std.heap.ArenaAllocator.init(allocator),
            .registry = registry.Registry.init(),
        };
        errdefer self.deinit(allocator);
        self.approval = approval_mod.Service.init(.{ .policy = opts.approval_policy });
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
        if (self.ask_user) |value| self.allocator.destroy(value);
        if (self.todo) |value| self.allocator.destroy(value);
        if (self.exit_plan) |value| self.allocator.destroy(value);
        self.allocator.destroy(self.plan_session);
        self.call_arena.deinit();
        self.arena.deinit();
        self.prompt_arena.deinit();
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

    fn workspaceSubstitution(self: *const Self) token_meter.WorkspaceSubstitution {
        return .{
            .workspace = self.workspace(),
            .placeholder = self.opts.workspace_placeholder,
        };
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

        const ask_user = try self.allocator.create(tools_ask_user.Context);
        errdefer self.allocator.destroy(ask_user);
        ask_user.* = .{ .options = self.questionOptions() };
        try tools_ask_user.register(ask_user, &self.registry, self.allocator);

        const todo = try self.allocator.create(tools_todo.Context);
        errdefer self.allocator.destroy(todo);
        todo.* = .{ .log = if (self.log) |*log| log else null };
        try todo.register(&self.registry, self.allocator);

        const exit_plan = try self.allocator.create(tools_exit_plan.Context);
        errdefer self.allocator.destroy(exit_plan);
        exit_plan.* = .{ .plan = self.plan_session };
        try tools_exit_plan.register(exit_plan, &self.registry, self.allocator);

        self.builtins = builtins;
        self.bash = bash;
        self.ask_user = ask_user;
        self.todo = todo;
        self.exit_plan = exit_plan;

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

        // Register after every dsh tool so the dedupe check sees them all.
        const host_names = try bridge.register(perm, self.allocator, &self.registry, .{
            .tools = self.opts.host_tools,
            .executor = self.opts.host_executor,
            .spill_dir = self.spill_dir,
        });

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (registry.core_schemas) |schema| try names.append(perm, schema.name);
        try names.append(perm, generated_interaction.ask_user_question.name);
        try names.append(perm, generated.todo_write.name);
        try names.appendSlice(perm, host_names);
        const ordered = try prompt.orderTools(perm, names.items, null);
        const base = try self.assembleCatalog(perm, ordered);
        self.tool_schemas = base.schemas;
        self.tool_specs = base.specs;

        const plan_names = try perm.alloc([]const u8, names.items.len + 1);
        @memcpy(plan_names[0..names.items.len], names.items);
        plan_names[names.items.len] = generated.exit_plan_mode.name;
        const plan_ordered = try prompt.orderTools(perm, plan_names, null);
        const plan_catalog = try self.assembleCatalog(perm, plan_ordered);
        self.plan_tool_schemas = plan_catalog.schemas;
        self.plan_tool_specs = plan_catalog.specs;
    }

    const Catalog = struct {
        schemas: []const request.ToolSchema,
        specs: []const providers.ToolSpec,
    };

    fn assembleCatalog(self: *Self, perm: Allocator, ordered: []const []const u8) !Catalog {
        const schemas = try perm.alloc(request.ToolSchema, ordered.len);
        const specs = try perm.alloc(providers.ToolSpec, ordered.len);
        for (ordered, 0..) |name, index| {
            const schema = self.findSchema(name) orelse return error.MissingToolSchema;
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
        return .{ .schemas = schemas, .specs = specs };
    }

    fn findSchema(self: *Self, name: []const u8) ?registry.Schema {
        for (registry.core_schemas) |schema| {
            if (std.mem.eql(u8, schema.name, name)) return schema;
        }
        if (self.registry.get(name)) |tool| {
            if (tool.host != null) return .{
                .name = tool.name,
                .description = tool.description,
                .input_schema_json = tool.input_schema_json,
            };
        }
        const extras = [_]registry.Schema{
            .{
                .name = generated_interaction.ask_user_question.name,
                .description = generated_interaction.ask_user_question.description,
                .input_schema_json = generated_interaction.ask_user_question.input_schema_json,
            },
            .{
                .name = generated.todo_write.name,
                .description = generated.todo_write.description,
                .input_schema_json = generated.todo_write.input_schema_json,
            },
            .{
                .name = generated.exit_plan_mode.name,
                .description = generated.exit_plan_mode.description,
                .input_schema_json = generated.exit_plan_mode.input_schema_json,
            },
        };
        for (extras) |schema| {
            if (std.mem.eql(u8, schema.name, name)) return schema;
        }
        return null;
    }

    /// System prompt plus the runtime-context block (working directory, file
    /// and approval policy) for the current folded permission state. Rebuilt
    /// after `/permission` and on restore so the model sees the live policy.
    fn buildPrompt(self: *Self) !void {
        _ = self.prompt_arena.reset(.retain_capacity);
        self.prompt_generation += 1;
        self.system_prompt = "";
        const perm = self.prompt_arena.allocator();
        const plan_active = self.planActive();
        const built = try prompt.buildSystemPrompt(perm, .{
            .persona_prefix = self.opts.persona,
            .plan_policy = if (plan_active) generated_system_prompt.plan_policy_text else "",
        });

        const sandbox: context.SandboxMode = self.permission_state.sandbox orelse
            switch (self.opts.sandbox) {
                .read_only => .read_only,
                .workspace_write => .workspace_write,
                .danger_full_access => .danger_full_access,
            };
        const approval: context.ApprovalPolicy = self.permission_state.approval orelse
            switch (self.opts.approval_policy) {
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
        self.prompt_plan_active = plan_active;
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
        // The lists themselves lived in the arena that was just released.
        self.messages = .empty;
        self.surface_seqs = .empty;
        self.permission_state = .{};
        self.plan_session.* = .{};
        if (self.todo) |ctx| ctx.log = null;
        self.applyApprovalPolicy(null);
        self.compaction_lock = .{};
        self.last_usage = null;
        // A fresh or reopened session starts its counters at 1; `restore`
        // then seeds them past the ids already in the log.
        self.next_id = 1;
        self.approval.next_id = 1;
        self.session_id = "";
        self.last_assistant_text = null;
        self.total_tokens = 0;
        self.context_written = false;
    }

    // ── session lifecycle ────────────────────────────────────────────────────

    /// Create a fresh session id + JSONL, take its write lease and start the
    /// kernel loop.
    fn openNewSession(self: *Self, session_id: ?[]const u8) !void {
        // Copy before closeSession: the caller may pass an id that lives in
        // this harness session arena, which closeSession frees.
        const id_copy = if (session_id) |value| try self.allocator.dupe(u8, value) else null;
        defer if (id_copy) |copy| self.allocator.free(copy);
        self.closeSession();
        const arena = self.arena.allocator();

        const id = if (id_copy) |value|
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
        if (self.todo) |ctx| ctx.log = &self.log.?;
        self.buildLoop();
        // A new session starts from the composition defaults again.
        try self.buildPrompt();
    }

    /// Reopen the JSONL for `session_id` and rebuild the surface from it.
    fn openExistingSession(self: *Self, session_id: []const u8) !void {
        // Copy before closeSession: restore passes the id loadMappedId
        // allocated in the session arena, which closeSession frees.
        const id_copy = try self.allocator.dupe(u8, session_id);
        defer self.allocator.free(id_copy);
        self.closeSession();
        const arena = self.arena.allocator();
        self.session_id = try arena.dupe(u8, id_copy);
        self.log = try session_store.openLog(self.allocator, self.opts.dsh_home, self.workspace(), self.session_id);
        if (self.goal_store) |store| store.attachLog(&self.log.?);
        if (self.todo) |ctx| ctx.log = &self.log.?;

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
        self.seedIds(read.events);
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

        self.plan_session.* = try plan_mod.Session.replay(events);
        // `UnitState.running.command_id` aliases the read arena; this fold
        // must outlive it.
        if (self.plan_session.state.running) |*running| {
            running.command_id = try arena.dupe(u8, running.command_id);
        }
        self.permission_state = commands_mod.PermissionState.fold(events);
        self.applyApprovalPolicy(self.permission_state.approval);
        try self.buildPrompt();
        self.compaction_lock = compaction_mod.scanLock(events);
        self.surface_seqs.clearRetainingCapacity();
        for (fold.nodes) |node| try self.surface_seqs.append(arena, node.seq);

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
            .compaction = .{
                .context = @ptrCast(self),
                .pressure = compactionPressure,
                .overflow = compactionOverflow,
                .max_overflow_retries = 1,
            },
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

    /// Move the in-process counters past every id the restored log already
    /// used, so a resumed session never mints a duplicate command, message,
    /// compaction or approval id.
    fn seedIds(self: *Self, events: []const types.Event) void {
        for (events) |event| self.seedIdsFromValue(event.data);
    }

    fn seedIdsFromValue(self: *Self, value: std.json.Value) void {
        switch (value) {
            .object => |object| {
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    const key = entry.key_ptr.*;
                    if (std.mem.eql(u8, key, "id") or
                        std.mem.eql(u8, key, "commandId") or
                        std.mem.eql(u8, key, "compactionId") or
                        std.mem.eql(u8, key, "sourceCommandId"))
                    {
                        if (entry.value_ptr.* == .string) self.seedId(entry.value_ptr.string);
                    }
                    self.seedIdsFromValue(entry.value_ptr.*);
                }
            },
            .array => |array| for (array.items) |item| self.seedIdsFromValue(item),
            else => {},
        }
    }

    fn seedId(self: *Self, id: []const u8) void {
        const counters = [_]struct { prefix: []const u8, next: *u64 }{
            .{ .prefix = "msg-", .next = &self.next_id },
            .{ .prefix = "command-", .next = &self.next_id },
            .{ .prefix = "compaction-checkpoint-", .next = &self.next_id },
            .{ .prefix = "compaction-", .next = &self.next_id },
            .{ .prefix = "approval-", .next = &self.approval.next_id },
        };
        for (counters) |counter| {
            if (!std.mem.startsWith(u8, id, counter.prefix)) continue;
            const number = std.fmt.parseInt(u64, id[counter.prefix.len..], 10) catch continue;
            if (number == std.math.maxInt(u64)) return;
            if (number >= counter.next.*) counter.next.* = number + 1;
            return;
        }
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
        .handleLocalCommand = handleLocalCommand,
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
        self.interaction = input.interaction;
        defer {
            self.sink = null;
            self.drain = null;
            self.drain_ctx = null;
            self.interaction = null;
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
        try self.addSurfaceSnapshot(arena, seq, .{
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
        try self.addSurfaceSnapshot(arena, seq, try surface_mod.messageFromEvent(arena, .{
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
        const seq = try self.appendEvent("request/header", .{ .object = data }, null, null);
        // The plan fold narrates a switch only when the last header described
        // the other mode; dsh records the logged mode at each header.
        try self.plan_session.foldEvent(.{
            .event_type = "request/header",
            .seq = seq,
            .time_ms = 0,
            .data = .{ .null = {} },
        });
        return seq;
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
        try self.addSurfaceSnapshot(arena, seq, try cloneMessage(arena, settlement.message));
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
        try self.addSurfaceSnapshot(arena, seq, try cloneMessage(arena, message));
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
    fn addSurfaceSnapshot(self: *Self, arena: Allocator, seq: u64, message: types.Message) !void {
        try self.messages.append(arena, message);
        try self.surface_seqs.append(arena, seq);
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
        if (position.step != 1 and self.prompt_generation == self.emitted_prompt_generation) return;
        self.emitted_prompt_generation = self.prompt_generation;
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

    /// `agent/pre-step`: commit a queued plan selection before the request
    /// header is snapshotted, then hand the narration to this step. Never
    /// vetoes; steer is pumped at the preceding `step_end` instead.
    fn hostPreStep(
        context_ptr: *anyopaque,
        allocator: Allocator,
        position: loop_mod.Position,
        claimed: loop_mod.Claimed,
        out: *std.ArrayListUnmanaged(loop_mod.UserMessage),
    ) anyerror!loop_mod.PreStepDecision {
        _ = position;
        _ = claimed;
        const self = selfOf(context_ptr);
        // dsh checks `signal.aborted` before committing a queued selection; the
        // kernel's own check runs after this callback, so an abort that lands
        // just before the step opens must not switch plan mode.
        if (self.loop) |*loop| {
            if (loop.isAborted()) return .{};
        }
        const boundary = self.plan_session.preStep();
        if (boundary.emit) |active| {
            var data: std.json.ObjectMap = .empty;
            try data.put(allocator, "active", .{ .bool = active });
            _ = try self.appendEvent("plan/mode", .{ .object = data }, null, null);
            try self.plan_session.foldEvent(.{
                .event_type = "plan/mode",
                .seq = 0,
                .time_ms = 0,
                .data = .{ .object = data },
            });
            self.plan_session.pendingCommitted();
        }
        if (self.planActive() != self.prompt_plan_active) try self.buildPrompt();
        if (self.loop) |*loop| loop.config.tools = self.planCatalogSchemas();
        if (boundary.narration) |text| {
            const id = try self.nextMessageId();
            const json = try planNarrationJson(allocator, id, text);
            try out.append(allocator, .{ .json = json });
        }
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
            .tools = self.planCatalogSpecs(),
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
        self.last_usage = stream.normalizeUsage(usage);
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
        // The buffer lives in `call_arena`; drop it before the arena resets
        // (clearRetainingCapacity would keep a dangling capacity).
        self.pending = .empty;
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

    /// Only the three read-only dsh tools, plus bridged tools that declare
    /// themselves read-only, are concurrency-safe; everything else is
    /// exclusive, mirroring dsh's fail-closed classification.
    fn classifyTool(context_ptr: *anyopaque, call: types.ToolCall) bool {
        return bridge.isParallel(&selfOf(context_ptr).registry, call.name);
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
        return execute.executeWithGate(&self.registry, allocator, call, self.gate());
    }

    // ── approval / questions / commands / compaction wiring ────────────────

    fn questionOptions(self: *const Self) questions_mod.Options {
        return .{
            .timeout_s = self.opts.question_timeout_s,
            .now_ms = self.opts.now_ms,
            .clock_context = self.opts.clock_context,
        };
    }

    fn sandboxMode(self: *const Self) context.SandboxMode {
        return self.permission_state.sandbox orelse switch (self.opts.sandbox) {
            .read_only => .read_only,
            .workspace_write => .workspace_write,
            .danger_full_access => .danger_full_access,
        };
    }

    fn approvalPolicy(self: *const Self) context.ApprovalPolicy {
        return switch (self.approval.options.policy) {
            .ask => .ask,
            .never => .never,
        };
    }

    /// Point the approval service at the folded policy (else the composition
    /// default); `gateDecide` reads the service, not the log.
    fn applyApprovalPolicy(self: *Self, folded: ?commands_mod.ApprovalPolicy) void {
        self.approval.options.policy = if (folded) |value|
            switch (value) {
                .ask => .ask,
                .never => .never,
            }
        else switch (self.opts.approval_policy) {
            .ask => .ask,
            .never => .never,
        };
    }

    fn gate(self: *Self) execute.Gate {
        return .{ .context = @ptrCast(self), .decide = gateDecide };
    }

    /// dsh `tools/pre-execute` ask (B24): only a sandbox-escalation call is
    /// gated, so ordinary P1 tool calls keep their fixture behaviour. The same
    /// hook binds the current call identity into `ask_user_question`.
    fn gateDecide(
        context_ptr: *anyopaque,
        allocator: Allocator,
        call: types.ToolCall,
        args: Value,
    ) anyerror!?[]const u8 {
        const self = selfOf(context_ptr);
        if (self.ask_user) |ask| {
            ask.call_id = call.id;
            ask.interaction = self.interaction;
            ask.options = self.questionOptions();
        }
        if (self.exit_plan) |exit| exit.interaction = self.interaction;
        // Bridged tools that need the user fail closed without a channel; the
        // turn's `interaction` is null when the host has no way to ask.
        if (self.registry.hostMeta(call.name)) |meta| {
            if (meta.requires_interaction and self.interaction == null) {
                return "tool requires an interactive channel that is unavailable on this turn";
            }
        }
        const object = switch (args) {
            .object => |value| value,
            else => return null,
        };
        const escalation = object.get("sandbox_permissions") orelse return null;
        switch (escalation) {
            .string => |mode| if (mode.len == 0) return null,
            else => return null,
        }
        const reason = switch (object.get("justification") orelse Value{ .null = {} }) {
            .string => |text| text,
            else => "",
        };
        var decision = try self.approval.request(allocator, self.interaction, .{
            .tool_name = call.name,
            .call_id = call.id,
            .reason = if (reason.len == 0) null else reason,
        });
        defer decision.deinit();
        try approval_mod.assertPaired(&decision.events);
        for (decision.events) |event| {
            const json = try approval_mod.dataJsonAlloc(event, allocator);
            const data = try parseValue(allocator, json);
            _ = try self.appendEvent(switch (event) {
                .asked => "approval/asked",
                .decided => "approval/decided",
            }, data, null, null);
        }
        const denial = decision.denial_reason orelse return null;
        return try allocator.dupe(u8, denial);
    }

    /// Claim a builtin command (`commands.zig`) and append its events; null
    /// lets the host run its own slash commands.
    fn handleLocalCommand(ptr: *anyopaque, content: []const u8) anyerror!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const log = if (self.log) |*value| value else return null;
        const arena = self.arena.allocator();
        const command_id = try std.fmt.allocPrint(arena, "command-{d}", .{self.next_id});
        self.next_id += 1;
        var result = try commands_mod.handleLocalCommand(arena, content, .{
            .command_id = command_id,
            .next_seq = log.next_seq,
            .session_id = self.session_id,
            .permissions = self.permission_state,
            .permission_defaults = .{
                .sandbox = self.sandboxMode(),
                .approval = self.approvalPolicy(),
            },
            .compaction = .{ .context = @ptrCast(self), .call = compactSeam },
            .goal = .{ .context = @ptrCast(self), .call = goalSeam },
            .plan = self.plan_session.view(self.in_turn),
        }) orelse return null;
        defer result.deinit();

        const seqs = try arena.alloc(u64, result.events.len);
        for (result.events, 0..) |event, index| {
            seqs[index] = try self.appendEvent(event.event_type, event.data, event.surface_op, event.source_event_seqs);
        }
        try self.applyPermissionEvents(result.events);
        try self.applyManualCompaction(result.events, seqs);
        if (result.plan_decision) |decision| try self.applyPlanDecision(decision, result.events);
        return try arena.dupe(u8, result.text);
    }

    /// The mode the next request assembly uses: a queued selection wins over
    /// the logged mode (dsh reads `pending?.active ?? active`).
    fn planActive(self: *const Self) bool {
        return if (self.plan_session.pending) |pending| pending.active else self.plan_session.state.active;
    }

    fn planCatalogSchemas(self: *const Self) []const request.ToolSchema {
        return if (self.planActive()) self.plan_tool_schemas else self.tool_schemas;
    }

    fn planCatalogSpecs(self: *const Self) []const providers.ToolSpec {
        return if (self.planActive()) self.plan_tool_specs else self.tool_specs;
    }

    /// `/plan` settlement: fold the command lifecycle and mode, inject the
    /// narration the command decided on, and republish the prompt and catalog.
    fn applyPlanDecision(self: *Self, decision: plan_mod.Decision, events: []const types.Event) !void {
        self.plan_session.applyDecision(decision);
        for (events) |event| try self.plan_session.foldEvent(event);
        if (self.planActive() != self.prompt_plan_active) try self.buildPrompt();
        if (self.loop) |*loop| loop.config.tools = self.planCatalogSchemas();
        const narration = decision.narration orelse return;
        const id = try self.nextMessageId();
        const json = try planNarrationJson(self.arena.allocator(), id, narration);
        if (self.loop) |*loop| _ = try loop.inject(.{ .id = id, .data = json });
    }

    /// dsh plan-mode narration user message (`source.kind="plan-mode"`).
    fn planNarrationJson(allocator: Allocator, id: []const u8, text: []const u8) ![]u8 {
        var writer: Writer.Allocating = .init(allocator);
        defer writer.deinit();
        const w = &writer.writer;
        try w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(text, .{}, w);
        try w.writeAll("}],\"source\":{\"kind\":\"plan-mode\",\"form\":\"notice\",\"summary\":");
        try std.json.Stringify.value(text, .{}, w);
        try w.writeAll("},\"role\":\"user\",\"id\":");
        try std.json.Stringify.value(id, .{}, w);
        try w.writeByte('}');
        return writer.toOwnedSlice();
    }

    /// Run the human `/goal` command on the live goal projection; the
    /// command module owns the lifecycle and appends the returned
    /// `goal/change` events between `command/run` and `command/done`.
    fn goalSeam(
        context_ptr: ?*anyopaque,
        allocator: Allocator,
        raw_input: []const u8,
    ) anyerror!commands_mod.GoalOutcome {
        const self = selfOf(context_ptr.?);
        const store = self.goal_store orelse
            return .{ .kind = .@"error", .text = "The /goal command is unavailable." };
        var command = goal_command_mod.Goal{ .store = store };
        const outcome = try command.executeCaptured(allocator, raw_input);
        return .{
            .kind = switch (outcome.result.kind) {
                .success => .success,
                .failure => .@"error",
            },
            .text = outcome.result.text,
            .events = outcome.events,
        };
    }

    /// Fold one command's permission events into the live knobs and re-render
    /// the prompt when the model-visible context changed.
    fn applyPermissionEvents(self: *Self, events: []const types.Event) !void {
        const delta = commands_mod.PermissionState.fold(events);
        if (delta.preset) |preset| self.permission_state.preset = preset;
        if (delta.sandbox) |sandbox| self.permission_state.sandbox = sandbox;
        if (delta.approval) |approval| self.permission_state.approval = approval;
        if (delta.sandbox == null and delta.approval == null) return;
        self.applyApprovalPolicy(self.permission_state.approval);
        try self.buildPrompt();
    }

    /// Apply the four events a `/compact` seam returned after the command
    /// module's lifecycle has been appended (`command/run` prepends the
    /// transaction, so locate it by type rather than a fixed offset).
    fn applyManualCompaction(self: *Self, events: []const types.Event, seqs: []const u64) !void {
        if (seqs.len != events.len) return error.InvalidCompactionEvents;
        var start: usize = 0;
        while (start + 3 < events.len) : (start += 1) {
            if (std.mem.eql(u8, events[start].event_type, "compaction/start")) break;
        }
        if (start + 3 >= events.len) return;
        if (!std.mem.eql(u8, events[start + 1].event_type, "compaction/summary") or
            !std.mem.eql(u8, events[start + 2].event_type, "user/message") or
            !std.mem.eql(u8, events[start + 3].event_type, "compaction/end")) return;

        const arena = self.arena.allocator();
        const summary_data = switch (events[start + 1].data) {
            .object => |value| value,
            else => return error.InvalidCompactionEvents,
        };
        const range = switch (summary_data.get("shadowedRange") orelse return error.InvalidCompactionEvents) {
            .object => |value| value,
            else => return error.InvalidCompactionEvents,
        };
        const start_seq = switch (range.get("start") orelse return error.InvalidCompactionEvents) {
            .integer => |value| @as(u64, @intCast(value)),
            else => return error.InvalidCompactionEvents,
        };
        const shadowed = switch (summary_data.get("shadowedSeqs") orelse return error.InvalidCompactionEvents) {
            .array => |value| value,
            else => return error.InvalidCompactionEvents,
        };
        const first_idx = indexOfSeq(self.surface_seqs.items, start_seq) orelse
            return error.SurfaceSeqMismatch;
        if (shadowed.items.len > self.messages.items.len - first_idx)
            return error.InvalidCompactionEvents;

        const message = try surface_mod.messageFromEvent(arena, events[start + 2]);
        const new_len = self.messages.items.len - shadowed.items.len;
        std.mem.copyForwards(
            types.Message,
            self.messages.items[first_idx..new_len],
            self.messages.items[first_idx + shadowed.items.len ..],
        );
        self.messages.shrinkRetainingCapacity(new_len);
        try self.messages.insert(arena, first_idx, message);

        std.mem.copyForwards(
            u64,
            self.surface_seqs.items[first_idx..new_len],
            self.surface_seqs.items[first_idx + shadowed.items.len ..],
        );
        self.surface_seqs.shrinkRetainingCapacity(new_len);
        try self.surface_seqs.insert(arena, first_idx, seqs[start + 2]);
        self.last_usage = null;
        self.compaction_lock = .{};
    }

    fn compactionPolicy(self: *const Self) compaction_mod.Options {
        var options = compaction_mod.Options{};
        if (self.opts.compaction_threshold_ratio) |value| options.threshold_ratio = value;
        if (self.opts.compaction_retain_ratio) |value| options.retain_ratio = value;
        if (self.opts.compaction_headroom_tokens) |value| options.headroom_tokens = value;
        options.workspace_substitution = self.workspaceSubstitution();
        return options;
    }

    fn surfaceNodes(self: *const Self, allocator: Allocator) ![]compaction_mod.Node {
        if (self.messages.items.len != self.surface_seqs.items.len) return error.SurfaceSeqMismatch;
        const nodes = try allocator.alloc(compaction_mod.Node, self.messages.items.len);
        for (self.messages.items, self.surface_seqs.items, 0..) |message, seq, index| {
            nodes[index] = .{ .seq = seq, .message = message };
        }
        return nodes;
    }

    fn reservedCompletionTokens(self: *const Self) u64 {
        return self.opts.max_tokens orelse 0;
    }

    /// Fixed kernel hook (`agent/pre-step`): measure, then compact at or above
    /// dsh's threshold. Misconfigured pressure specs leave the turn running;
    /// config validation rejects them at load.
    fn compactionPressure(context_ptr: *anyopaque, allocator: Allocator, position: loop_mod.Position) anyerror!bool {
        const self = selfOf(context_ptr);
        if (self.opts.context_window == 0) return false;
        var tmp = std.heap.ArenaAllocator.init(allocator);
        defer tmp.deinit();
        const nodes = self.surfaceNodes(tmp.allocator()) catch |err| switch (err) {
            error.SurfaceSeqMismatch => return false,
            else => return err,
        };
        const probe = compaction_mod.check(
            tmp.allocator(),
            nodes,
            self.compactionPolicy(),
            self.opts.context_window,
            self.reservedCompletionTokens(),
            self.last_usage,
        ) catch |err| switch (err) {
            error.InvalidContextWindow,
            error.NoMessageBudget,
            error.NoPressureBudget,
            error.InvalidThresholdRatio,
            error.InvalidRetainRatio,
            error.RetainNotBelowThreshold,
            => return false,
            else => return err,
        };
        if (!probe.pressured) return false;
        return self.compactAuto(allocator, .pressure, position.turn);
    }

    /// Fixed kernel hook (`agent/request-error`): one forced compaction so the
    /// kernel can retry the overflowed request.
    fn compactionOverflow(context_ptr: *anyopaque, allocator: Allocator, position: loop_mod.Position) anyerror!bool {
        const self = selfOf(context_ptr);
        return self.compactAuto(allocator, .context_overflow, position.turn);
    }

    const CompactRun = union(enum) {
        result: compaction_mod.Result,
        /// Summarization began (dsh's `compaction/start` would be durable) and
        /// failed; `events` is the start/end{error} pair to record.
        failed: struct {
            events: []const compaction_mod.Event,
            err: anyerror,
        },
    };

    fn compactAuto(self: *Self, allocator: Allocator, trigger: compaction_mod.Trigger, turn: u64) anyerror!bool {
        var run = self.compactRun(allocator, trigger, turn) catch |err| switch (err) {
            error.CompactionLocked => return false,
            else => return err,
        };
        switch (run) {
            .failed => |failure| {
                try self.appendCompactionFailure(self.arena.allocator(), failure.events, null);
                return failure.err;
            },
            .result => |*result| {
                defer result.deinit();
                if (result.events.len == 0 and result.pruned.len == 0) return false;
                try self.commitCompaction(result.*, null);
                return true;
            },
        }
    }

    fn compactRun(
        self: *Self,
        allocator: Allocator,
        trigger: compaction_mod.Trigger,
        turn: ?u64,
    ) !CompactRun {
        var tmp = std.heap.ArenaAllocator.init(allocator);
        defer tmp.deinit();
        const nodes = try self.surfaceNodes(tmp.allocator());
        const compaction_id = try std.fmt.allocPrint(allocator, "compaction-{d}", .{self.next_id});
        self.next_id += 1;
        const replacement_id = try std.fmt.allocPrint(allocator, "compaction-checkpoint-{d}", .{self.next_id});
        self.next_id += 1;
        var started = false;
        const result = compaction_mod.run(allocator, nodes, .{
            .context_window = self.opts.context_window,
            .policy = self.compactionPolicy(),
            .reserved_completion_tokens = self.reservedCompletionTokens(),
            .provider_usage = self.last_usage,
            .trigger = trigger,
            .recovery = self.compaction_lock,
            .compaction_id = compaction_id,
            .replacement_message_id = replacement_id,
            .turn = turn,
            .tools = self.tool_schemas,
            .started = &started,
        }, .{ .context = @ptrCast(self), .call = summarizeCompaction }) catch |err| {
            // Before the summarizer ran dsh has written no `compaction/start`.
            if (!started or err == error.OutOfMemory) return err;
            const events = try compaction_mod.failureEvents(allocator, compaction_id, turn, @errorName(err));
            return .{ .failed = .{ .events = events, .err = err } };
        };
        return .{ .result = result };
    }

    /// dsh's cache-reusing auxiliary call (`summarizer.ts:120-170`): replay the
    /// selected prefix plus the instruction, with the routed model's tools.
    fn summarizeCompaction(
        context_ptr: ?*anyopaque,
        allocator: Allocator,
        input: compaction_mod.SummaryInput,
    ) anyerror!compaction_mod.SummaryOutput {
        const self = selfOf(context_ptr.?);
        const messages = try requestsFromMessages(allocator, input.messages);
        const chat = providers.ChatRequest{
            .messages = messages,
            .model = self.opts.model,
            .temperature = self.opts.temperature,
            .max_tokens = self.opts.max_tokens,
            .tools = self.tool_specs,
            .reasoning_effort = self.opts.reasoning_effort,
            .session_id = if (self.opts.session_key.len == 0) null else self.opts.session_key,
        };
        const response = try self.opts.provider.chatWithTools(allocator, chat);
        const blocks = try allocator.alloc(types.ContentBlock, 1);
        blocks[0] = .{ .text = try allocator.dupe(u8, response.content orelse "") };
        const usage: ?types.Usage = if (response.usage.prompt_tokens == 0 and
            response.usage.completion_tokens == 0 and response.usage.total_tokens == 0)
            null
        else
            stream.normalizeUsage(.{
                .prompt_tokens = response.usage.prompt_tokens,
                .completion_tokens = response.usage.completion_tokens,
                .total_tokens = response.usage.total_tokens,
            });
        return .{
            .blocks = blocks,
            .provider = self.opts.provider_name,
            .model = self.opts.model,
            .max_tokens = self.opts.max_tokens,
            .usage = usage,
        };
    }

    /// Log the prune pass and the four adjacent compaction events, then rewrite
    /// the in-memory surface (and drop the usage anchor).
    fn commitCompaction(self: *Self, result: compaction_mod.Result, command_id: ?[]const u8) !void {
        const arena = self.arena.allocator();
        // dsh appends the pruner's replacements before selecting the summary
        // range, so a node shadowed by both keeps the replacement's seq in the
        // summary and checkpoint records.
        var remap: std.AutoHashMapUnmanaged(u64, u64) = .empty;
        defer remap.deinit(arena);

        for (result.pruned) |pruned| {
            const index = indexOfSeq(self.surface_seqs.items, pruned.seq) orelse continue;
            const tokens = token_meter.estimateMessageWithWorkspace(
                arena,
                self.messages.items[index],
                self.workspaceSubstitution(),
            ) catch 0;
            var prune_data: std.json.ObjectMap = .empty;
            var range: std.json.ObjectMap = .empty;
            try range.put(arena, "start", .{ .integer = @intCast(pruned.seq) });
            try range.put(arena, "end", .{ .integer = @intCast(pruned.seq) });
            try prune_data.put(arena, "shadowedRange", .{ .object = range });
            try prune_data.put(arena, "shadowedSeqs", try seqArrayValue(arena, &.{pruned.seq}));
            try prune_data.put(arena, "shadowedTokenCount", .{ .integer = @intCast(tokens) });
            _ = try self.appendEvent("compaction/prune", .{ .object = prune_data }, null, null);

            var data: std.json.ObjectMap = .empty;
            const replacement = try cloneMessage(arena, pruned.message);
            try data.put(arena, "message", try messageValue(arena, replacement));
            const seq = try self.appendEvent("tool/result", .{ .object = data }, .{
                .replace = .{ .start_seq = pruned.seq, .end_seq = pruned.seq },
            }, try arena.dupe(u64, &.{pruned.seq}));
            try remap.put(arena, pruned.seq, seq);
            self.messages.items[index] = replacement;
            self.surface_seqs.items[index] = seq;
        }

        if (result.events.len == 4) {
            try compaction_mod.assertAdjacent(result.events);
            const summary = switch (result.events[1]) {
                .summary => |value| value,
                else => return error.CompactionEventsNotAdjacent,
            };
            const mapped_seqs = try arena.alloc(u64, summary.shadowed_seqs.len);
            for (summary.shadowed_seqs, 0..) |seq, index| {
                mapped_seqs[index] = remap.get(seq) orelse seq;
            }
            const shadowed = CompactionShadowed{
                .start_seq = remap.get(summary.shadowed_start_seq) orelse summary.shadowed_start_seq,
                .end_seq = remap.get(summary.shadowed_end_seq) orelse summary.shadowed_end_seq,
                .seqs = mapped_seqs,
            };
            const first_idx = indexOfSeq(self.surface_seqs.items, shadowed.start_seq) orelse
                return error.SurfaceSeqMismatch;

            const events = try self.buildCompactionEvents(arena, result, command_id, shadowed, null);
            const start_seq = try self.appendEvent(events[0].event_type, events[0].data, events[0].surface_op, events[0].source_event_seqs);
            const summary_seq = try self.appendEvent(events[1].event_type, events[1].data, events[1].surface_op, events[1].source_event_seqs);
            // dsh records `[startEvent.seq, summaryEvent.seq, ...shadowedSeqs]`.
            const source_seqs = try arena.alloc(u64, 2 + shadowed.seqs.len);
            source_seqs[0] = start_seq;
            source_seqs[1] = summary_seq;
            @memcpy(source_seqs[2..], shadowed.seqs);
            events[2].source_event_seqs = source_seqs;
            const replacement_seq = try self.appendEvent(events[2].event_type, events[2].data, events[2].surface_op, events[2].source_event_seqs);
            _ = try self.appendEvent(events[3].event_type, events[3].data, events[3].surface_op, events[3].source_event_seqs);

            const replacement = switch (result.events[2]) {
                .replacement => |value| value,
                else => return error.CompactionEventsNotAdjacent,
            };
            var message = try cloneMessage(arena, replacement.message);
            message = try compactionReplacementMessage(arena, message, command_id);
            const idx = first_idx;
            const new_len = self.messages.items.len - shadowed.seqs.len;
            std.mem.copyForwards(
                types.Message,
                self.messages.items[idx..new_len],
                self.messages.items[idx + shadowed.seqs.len ..],
            );
            self.messages.shrinkRetainingCapacity(new_len);
            try self.messages.insert(arena, idx, message);

            std.mem.copyForwards(
                u64,
                self.surface_seqs.items[idx..new_len],
                self.surface_seqs.items[idx + shadowed.seqs.len ..],
            );
            self.surface_seqs.shrinkRetainingCapacity(new_len);
            try self.surface_seqs.insert(arena, idx, replacement_seq);
        }
        self.last_usage = null;
        self.compaction_lock = .{};
    }

    /// Surface seqs used by the summary and checkpoint records. They differ
    /// from `result.events` when the pruner replaced a shadowed node first.
    const CompactionShadowed = struct {
        start_seq: u64,
        end_seq: u64,
        seqs: []const u64,
    };

    fn buildCompactionEvents(
        self: *Self,
        allocator: Allocator,
        result: compaction_mod.Result,
        command_id: ?[]const u8,
        shadowed: CompactionShadowed,
        source_prefix: ?[]const u64,
    ) ![]types.Event {
        _ = self;
        const start = switch (result.events[0]) {
            .start => |value| value,
            else => return error.CompactionEventsNotAdjacent,
        };
        const summary = switch (result.events[1]) {
            .summary => |value| value,
            else => return error.CompactionEventsNotAdjacent,
        };
        const replacement = switch (result.events[2]) {
            .replacement => |value| value,
            else => return error.CompactionEventsNotAdjacent,
        };
        const end = switch (result.events[3]) {
            .end => |value| value,
            else => return error.CompactionEventsNotAdjacent,
        };

        const events = try allocator.alloc(types.Event, 4);
        events[0] = .{
            .event_type = "compaction/start",
            .seq = 0,
            .time_ms = 0,
            .data = try compactionEdgeData(allocator, start.compaction_id, start.turn, command_id, null),
        };
        events[1] = .{
            .event_type = "compaction/summary",
            .seq = 0,
            .time_ms = 0,
            .data = try compactionSummaryData(allocator, summary, command_id, shadowed),
        };
        const message = try compactionReplacementMessage(allocator, replacement.message, command_id);
        var source_seqs: []const u64 = shadowed.seqs;
        if (source_prefix) |prefix| {
            const combined = try allocator.alloc(u64, prefix.len + shadowed.seqs.len);
            @memcpy(combined[0..prefix.len], prefix);
            @memcpy(combined[prefix.len..], shadowed.seqs);
            source_seqs = combined;
        }
        events[2] = .{
            .event_type = "user/message",
            .seq = 0,
            .time_ms = 0,
            .data = try messageValue(allocator, message),
            .surface_op = .{ .replace = .{
                .start_seq = shadowed.start_seq,
                .end_seq = shadowed.end_seq,
            } },
            .source_event_seqs = source_seqs,
        };
        events[3] = .{
            .event_type = "compaction/end",
            .seq = 0,
            .time_ms = 0,
            .data = try compactionEdgeData(allocator, end.compaction_id, end.turn, command_id, end.failure),
        };
        return events;
    }

    /// The two log rows of a failed transaction, in log order.
    fn buildCompactionFailureEvents(
        self: *Self,
        allocator: Allocator,
        events: []const compaction_mod.Event,
        command_id: ?[]const u8,
    ) ![]types.Event {
        _ = self;
        if (events.len != 2) return error.CompactionEventsNotAdjacent;
        const start = switch (events[0]) {
            .start => |value| value,
            else => return error.CompactionEventsNotAdjacent,
        };
        const end = switch (events[1]) {
            .end => |value| value,
            else => return error.CompactionEventsNotAdjacent,
        };
        const out = try allocator.alloc(types.Event, 2);
        out[0] = .{
            .event_type = "compaction/start",
            .seq = 0,
            .time_ms = 0,
            .data = try compactionEdgeData(allocator, start.compaction_id, start.turn, command_id, null),
        };
        out[1] = .{
            .event_type = "compaction/end",
            .seq = 0,
            .time_ms = 0,
            .data = try compactionEdgeData(allocator, end.compaction_id, end.turn, command_id, end.failure),
        };
        return out;
    }

    fn appendCompactionFailure(
        self: *Self,
        allocator: Allocator,
        events: []const compaction_mod.Event,
        command_id: ?[]const u8,
    ) !void {
        const rows = try self.buildCompactionFailureEvents(allocator, events, command_id);
        for (rows) |row| _ = try self.appendEvent(row.event_type, row.data, null, null);
    }

    fn compactionEdgeData(
        allocator: Allocator,
        compaction_id: []const u8,
        turn: ?u64,
        command_id: ?[]const u8,
        failure: ?[]const u8,
    ) !Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "compactionId", .{ .string = compaction_id });
        if (command_id) |value| try object.put(allocator, "sourceCommandId", .{ .string = value });
        if (failure) |value| try object.put(allocator, "error", .{ .string = value });
        try object.put(allocator, "turn", if (turn) |value|
            Value{ .integer = @intCast(value) }
        else
            Value{ .null = {} });
        return .{ .object = object };
    }

    fn compactionSummaryData(
        allocator: Allocator,
        summary: compaction_mod.SummaryEvent,
        command_id: ?[]const u8,
        shadowed: CompactionShadowed,
    ) !Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "compactionId", .{ .string = summary.compaction_id });
        if (command_id) |value| try object.put(allocator, "sourceCommandId", .{ .string = value });
        try object.put(allocator, "summary", try contentValue(allocator, summary.summary));
        try object.put(allocator, "rawOutput", try contentValue(allocator, summary.raw_output));
        try object.put(allocator, "llmStreamCall", .{ .bool = true });
        var range: std.json.ObjectMap = .empty;
        try range.put(allocator, "start", .{ .integer = @intCast(shadowed.start_seq) });
        try range.put(allocator, "end", .{ .integer = @intCast(shadowed.end_seq) });
        try object.put(allocator, "shadowedRange", .{ .object = range });
        try object.put(allocator, "shadowedSeqs", try seqArrayValue(allocator, shadowed.seqs));
        try object.put(allocator, "shadowedTokenCount", .{ .integer = @intCast(summary.shadowed_token_count) });
        try object.put(allocator, "provider", .{ .string = summary.provider });
        try object.put(allocator, "model", .{ .string = summary.model });
        if (summary.max_tokens) |value| try object.put(allocator, "maxTokens", .{ .integer = @intCast(value) });
        if (summary.usage) |usage| try object.put(allocator, "usage", try usageValue(allocator, usage));
        return .{ .object = object };
    }

    fn compactionReplacementMessage(
        allocator: Allocator,
        message: types.Message,
        command_id: ?[]const u8,
    ) !types.Message {
        var out = message;
        if (command_id) |id| switch (out.source) {
            .other => |*value| switch (value.*) {
                .object => |*object| try object.put(allocator, "sourceCommandId", .{ .string = id }),
                else => {},
            },
            else => {},
        };
        return out;
    }

    fn seqArrayValue(allocator: Allocator, seqs: []const u64) !Value {
        var array = std.json.Array.init(allocator);
        try array.ensureTotalCapacity(seqs.len);
        for (seqs) |seq| array.appendAssumeCapacity(.{ .integer = @intCast(seq) });
        return .{ .array = array };
    }

    fn compactSeam(
        context_ptr: ?*anyopaque,
        allocator: Allocator,
        command: commands_mod.CompactRequest,
    ) anyerror!commands_mod.CompactOutcome {
        const self = selfOf(context_ptr.?);
        var run = self.compactRun(allocator, .manual, null) catch |err| switch (err) {
            error.CompactionLocked => return .{ .failed = .{ .failure = .busy } },
            error.OutOfMemory => return err,
            else => return .{ .failed = .{ .failure = .summary } },
        };
        switch (run) {
            .failed => |failure| return .{ .failed = .{
                .failure = .summary,
                .events = try self.buildCompactionFailureEvents(allocator, failure.events, command.command_id),
            } },
            .result => |*result| {
                defer result.deinit();
                if (result.events.len == 0) return .no_history;
                try compaction_mod.assertAdjacent(result.events);
                const summary = switch (result.events[1]) {
                    .summary => |value| value,
                    else => return error.CompactionEventsNotAdjacent,
                };
                // Domain events follow `command/run`; dsh's checkpoint records the
                // start and summary seqs before the shadowed range.
                const prefix: ?[]const u64 = if (command.next_seq) |first| blk: {
                    const head = try allocator.alloc(u64, 2);
                    head[0] = first + 1;
                    head[1] = first + 2;
                    break :blk head;
                } else null;
                const events = try self.buildCompactionEvents(allocator, result.*, command.command_id, .{
                    .start_seq = summary.shadowed_start_seq,
                    .end_seq = summary.shadowed_end_seq,
                    .seqs = summary.shadowed_seqs,
                }, prefix);
                for (events) |*event| event.data = try cloneValue(allocator, event.data);
                return .{ .compacted = .{
                    .events = events,
                    .shadowed_item_count = summary.shadowed_seqs.len,
                    .shadowed_token_count = summary.shadowed_token_count,
                    .summary_event_index = 1,
                } };
            },
        }
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
        if (header.tools) |tools| {
            var array = std.json.Array.init(allocator);
            try array.ensureTotalCapacity(tools.len);
            for (tools) |tool| {
                var tool_object: std.json.ObjectMap = .empty;
                try tool_object.put(allocator, "name", .{ .string = tool.name });
                try tool_object.put(allocator, "description", .{ .string = tool.description });
                try tool_object.put(allocator, "parameters", try parseValue(allocator, tool.parameters_json));
                array.appendAssumeCapacity(.{ .object = tool_object });
            }
            try object.put(allocator, "tools", .{ .array = array });
        }
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

fn indexOfSeq(seqs: []const u64, seq: u64) ?usize {
    for (seqs, 0..) |value, index| {
        if (value == seq) return index;
    }
    return null;
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

test "dsh-native harness: an aborted pre-step keeps the queued plan selection" {
    // Regression: hostPreStep committed a pending /plan selection before the
    // kernel's abort check, so a /stop that landed just before the step opened
    // silently switched plan mode.
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

    var engine = try DshNativeHarness.init(allocator, .{
        .session_key = "test-session-key",
        .dsh_home = dsh_home,
        .workspace_dir = workspace,
        .provider = undefined,
        .provider_name = "",
        .model = "",
    });
    defer engine.deinit(allocator);
    try engine.startFresh();

    engine.plan_session.state.active = true;
    engine.plan_session.pending = .{ .active = false, .narrate = false };
    if (engine.loop) |*loop| loop.abort(.user);

    var out: std.ArrayListUnmanaged(loop_mod.UserMessage) = .empty;
    defer out.deinit(allocator);
    _ = try DshNativeHarness.hostPreStep(&engine, allocator, .{ .turn = 1, .step = 1 }, .{
        .next_step = &.{},
        .next_turn = &.{},
    }, &out);

    try std.testing.expect(engine.plan_session.state.active);
    try std.testing.expect(engine.plan_session.pending != null);
    try std.testing.expectEqual(false, engine.plan_session.pending.?.active);
}
