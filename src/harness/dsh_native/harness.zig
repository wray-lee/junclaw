//! The dsh-native turn engine: `port.Harness` over the pure kernel
//! (`loop.zig`), one instance per host session key.
//!
//! P1b scope: text and tool turns, steer pulled through the kernel inbox,
//! typed end reasons, `/new` (reset) and resume (restore) over the v4 JSONL
//! session log. Everything durable goes through `session_log.Log`; the
//! model-visible surface is rebuilt from the same messages the log stores.
//!
//! Deliberate P1b limits:
//! - The provider bridge streams only when the host has a live draft and the
//!   provider can stream native tool calls: every chunk then reaches the host
//!   immediately and the kernel as a text/reasoning delta. Otherwise it blocks
//!   on `chatWithTools` and the kernel sees one text chunk plus `done`.
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
const tool_filter = @import("../../tool_filter.zig");
const dispatcher = @import("../../agent/dispatcher.zig");
const native_prompt = @import("../../agent/prompt.zig");
const bootstrap_mod = @import("../../bootstrap/root.zig");
const providers = @import("../../providers/root.zig");
const provider_helpers = @import("../../providers/helpers.zig");
const redaction = @import("../../redaction.zig");
const http_util = @import("../../http_util.zig");
const config_types = @import("../../config_types.zig");
const memory_mod = @import("../../memory/root.zig");
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
const security_mod = @import("tools/security.zig");
const SecurityPolicy = @import("../../security/policy.zig").SecurityPolicy;
const goal_mod = @import("goal.zig");
const goal_command_mod = @import("goal_command.zig");
const goal_rounds = @import("goal_rounds.zig");
const goal_tools = @import("tools/goal.zig");
const plan_mod = @import("plan.zig");
const tools_exit_plan = @import("tools/exit_plan.zig");
const tools_todo = @import("tools/todo.zig");
const execute = @import("tools/execute.zig");
const scheduler = @import("tools/scheduler.zig");
const repair = @import("repair.zig");
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
    /// `agent.timezone`, rendered into the runtime-context date/time section.
    timezone: []const u8 = "UTC",
    /// `agent.reasoning_mode`: provider reasoning hint and `port.Info` parity.
    reasoning_mode: config_types.ReasoningMode = .off,
    /// Native workspace bootstrap provider; null falls back to direct reads.
    bootstrap_provider: ?bootstrap_mod.BootstrapProvider = null,
    /// Native identity config (AIEOS); disabled by default like native.
    identity_config: ?config_types.IdentityConfig = null,
    /// junclaw PII redactor (`agent.enable_pii_redaction`, default on). Null
    /// disables redaction. Provider-bound messages, every message the JSONL
    /// log stores, and tool output are redacted, the same boundaries native
    /// redacts; the host rehydrates placeholders for allowed displays.
    redactor: ?*redaction.Redactor = null,
    /// Test seam: the captured dsh fixtures ran without the runtime-context
    /// and agent-instructions plugins, so replaying them must not inject the
    /// pre-step context messages that a production session carries.
    inject_model_context: bool = true,
    approval_policy: config_types.DshApprovalPolicy = .ask,
    sandbox: config_types.DshSandbox = .workspace_write,
    /// junclaw SecurityPolicy: autonomy (read-only), the per-call rate limit,
    /// and bash command risk. Null keeps the engine's own behavior.
    policy: ?*const SecurityPolicy = null,
    /// `autonomy.allowed_paths`: extra roots for the file and bash tools.
    allowed_paths: []const []const u8 = &.{},
    max_parallel_tools: usize = config_types.DEFAULT_DSH_MAX_PARALLEL_TOOLS,
    /// `agent.tool_filter_groups`; empty exposes every tool. Applied per turn
    /// with the same `tool_filter.toolExposed` the native agent uses.
    tool_filter_groups: []const config_types.ToolFilterGroup = &.{},
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

    /// Retained runtime-context snapshot. dsh logs a snapshot only when the
    /// rendered text changes (runtime-context.ts tracker).
    runtime_tracker: context.SnapshotTracker = .{},
    /// dsh agent-instructions discovery state for this session.
    instructions_tracker: context.BaselineTracker = .{},
    /// Seq of the visible agent-instructions baseline message, or null.
    instructions_seq: ?u64 = null,

    /// The model-visible surface (arena-owned), in request order.
    messages: std.ArrayListUnmanaged(types.Message) = .empty,

    /// The model-visible catalog. It includes `exit_plan_mode` in every mode:
    /// dsh keeps that tool registered while plan mode is inactive, so switching
    /// modes changes only the prompt section (live recording p2b-plan-off).
    tool_schemas: []const request.ToolSchema = &.{},
    tool_specs: []const providers.ToolSpec = &.{},
    /// The unfiltered catalog; `tool_schemas`/`tool_specs` are a per-turn
    /// subset of these when `tool_filter_groups` is non-empty.
    all_schemas: []const request.ToolSchema = &.{},
    all_specs: []const providers.ToolSpec = &.{},
    /// Backs the per-turn filtered catalog so those slices stay valid until
    /// the next turn without growing the permanent arena.
    turn_tools: std.heap.ArenaAllocator,
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
    /// Native `## Channel Attachments` block, rendered once. It rides the
    /// runtime-context snapshot so dsh's generated system prompt stays
    /// verbatim and its cache prefix never changes with this guidance.
    channel_attachments: ?[]u8 = null,
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
    /// Last assistant message's reasoning for `reasoning_mode = .on`; copied
    /// out of the kernel settlement, which dies with the step.
    turn_reasoning: std.ArrayListUnmanaged(u8) = .empty,
    last_assistant_text: ?[]const u8 = null,

    // Per turn.
    sink: ?port.Sink = null,
    live_stream: bool = false,
    /// Raised by `requestInterrupt`; provider transports see it through the
    /// thread interrupt flag, exactly like the native agent.
    stream_cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// A provider error raised after deltas were relayed. `providerNext`
    /// reports it after the partial stream so the kernel settles the partial
    /// assistant message (P3) instead of "request failed to start".
    stream_error: ?anyerror = null,
    /// The provider error behind the current kernel failure, kept so the
    /// user-facing copy can be classified like the native engine's.
    last_provider_error: ?anyerror = null,
    /// True while `beginStreaming` relays the provider's chunks to the sink;
    /// `forwardDelta` must not replay the same kernel events.
    streamed_live: bool = false,
    drain: ?agent_mod.DrainCallback = null,
    drain_ctx: ?*anyopaque = null,
    /// Host-computed native memory recall block for this turn; borrowed.
    turn_memory_context: []const u8 = "",
    /// Native workspace guide block for this turn (owned when non-empty).
    turn_guides: ?[]u8 = null,

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
            .turn_tools = std.heap.ArenaAllocator.init(allocator),
            .registry = registry.Registry.init(),
        };
        errdefer self.deinit(allocator);
        self.approval = approval_mod.Service.init(.{ .policy = opts.approval_policy });
        try self.buildTools();
        try self.buildPrompt();
        self.channel_attachments = try renderChannelAttachments(allocator);
        return self;
    }

    fn renderChannelAttachments(allocator: Allocator) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);
        var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
        try native_prompt.appendChannelAttachmentsSection(&writer.writer);
        buf = writer.toArrayList();
        return buf.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        // `allocator` is the host's free allocator, the same one `init` took.
        _ = allocator;
        self.closeSession();
        self.turn_text.deinit(self.allocator);
        self.turn_reasoning.deinit(self.allocator);
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
        if (self.channel_attachments) |text| self.allocator.free(text);
        self.allocator.destroy(self.plan_session);
        self.call_arena.deinit();
        self.turn_tools.deinit();
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
        // The JSONL is disk state native keeps redacted (turn persistence and
        // every append site); walk the payload so auxiliary copies (stream
        // chunks, tool-call arguments, summaries) carry no raw PII either.
        if (self.opts.redactor != null) {
            var redactable = data;
            try self.redactEventData(self.arena.allocator(), &redactable);
        }
        return log.append(event_type, data, .{
            .time_ms = self.now(),
            .surface_op = surface_op,
            .source_event_seqs = seqs,
        });
    }

    fn redactEventData(self: *Self, allocator: Allocator, value: *Value) !void {
        switch (value.*) {
            .object => |*object| {
                var entries = object.iterator();
                while (entries.next()) |entry| {
                    if (redactedField(entry.key_ptr.*)) {
                        switch (entry.value_ptr.*) {
                            .string => |text| entry.value_ptr.* = .{ .string = try self.redactText(allocator, text) },
                            .array => |*items| for (items.items) |*item| {
                                if (item.* == .string) item.* = .{ .string = try self.redactText(allocator, item.string) };
                            },
                            else => {},
                        }
                        continue;
                    }
                    try self.redactEventData(allocator, entry.value_ptr);
                }
            },
            .array => |*items| for (items.items) |*item| try self.redactEventData(allocator, item),
            else => {},
        }
    }

    /// dsh event fields that carry human/model text (content blocks, tool
    /// arguments, stream runs); structural fields (ids, names, paths) stay.
    fn redactedField(key: []const u8) bool {
        const fields = [_][]const u8{ "text", "arguments", "argumentsDelta", "texts", "args" };
        for (fields) |field| if (std.mem.eql(u8, key, field)) return true;
        return false;
    }

    fn buildTools(self: *Self) !void {
        const perm = self.perm.allocator();
        const dir = self.workspace();
        self.spill_dir = try std.fs.path.join(perm, &.{ self.opts.dsh_home, "spill" });
        // Regression: the spill directory was only joined, never created, so
        // the bash tool's temp files failed and every bash call returned an
        // error before spawning.
        try fs_compat.makePath(self.spill_dir);

        const builtins = try self.allocator.create(builtins_mod.Builtins);
        errdefer self.allocator.destroy(builtins);
        builtins.* = .{
            .cwd = dir,
            .spill_dir = self.spill_dir,
            .allowed_paths = self.opts.allowed_paths,
            .sandbox = self.sandboxMode(),
        };
        try builtins.register(&self.registry, self.allocator);

        const bash = try self.allocator.create(bash_mod.Context);
        errdefer self.allocator.destroy(bash);
        bash.* = .{
            .cwd = dir,
            .spill_dir = self.spill_dir,
            .allowed_paths = self.opts.allowed_paths,
        };
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
        try names.append(perm, generated.exit_plan_mode.name);
        try names.appendSlice(perm, host_names);
        const ordered = try prompt.orderTools(perm, names.items, null);
        const catalog = try self.assembleCatalog(perm, ordered);
        self.all_schemas = catalog.schemas;
        self.all_specs = catalog.specs;
        self.tool_schemas = catalog.schemas;
        self.tool_specs = catalog.specs;
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

    /// Narrow the model-visible catalog for one turn with
    /// `agent.tool_filter_groups`, matching the native agent's
    /// `filterToolSpecsForTurn`: `always` groups expose their glob matches,
    /// `dynamic` groups only when the turn's user message carries a keyword.
    /// Both engines share `tool_filter.toolExposed`; only the visible schema
    /// changes, the registry keeps every tool (as native keeps `self.tools`).
    fn selectTurnTools(self: *Self, user_message: []const u8) !void {
        _ = self.turn_tools.reset(.retain_capacity);
        if (self.opts.tool_filter_groups.len == 0) {
            self.tool_schemas = self.all_schemas;
            self.tool_specs = self.all_specs;
        } else {
            const arena = self.turn_tools.allocator();

            var schemas: std.ArrayListUnmanaged(request.ToolSchema) = .empty;
            for (self.all_schemas) |schema| {
                if (tool_filter.toolExposed(self.opts.tool_filter_groups, schema.name, user_message)) {
                    try schemas.append(arena, schema);
                }
            }
            self.tool_schemas = try schemas.toOwnedSlice(arena);

            var specs: std.ArrayListUnmanaged(providers.ToolSpec) = .empty;
            for (self.all_specs) |spec| {
                if (tool_filter.toolExposed(self.opts.tool_filter_groups, spec.name, user_message)) {
                    try specs.append(arena, spec);
                }
            }
            self.tool_specs = try specs.toOwnedSlice(arena);
        }
        if (self.loop) |*loop| loop.config.tools = self.tool_schemas;
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

    /// The verbatim dsh system prompt (persona slot, tool guidance, plan
    /// policy). Runtime context is a per-step `user/message`, never mixed in:
    /// dsh re-renders it on every pre-step (design B15/B16).
    fn buildPrompt(self: *Self) !void {
        // free_all, not retain_capacity: a retained buffer kept stale prompt
        // bytes readable and hid dangling slices from PoisonAllocator.
        _ = self.prompt_arena.reset(.free_all);
        self.prompt_generation += 1;
        const perm = self.prompt_arena.allocator();
        const plan_active = self.planActive();
        self.system_prompt = try prompt.buildSystemPrompt(perm, .{
            .persona_prefix = self.opts.persona,
            .plan_policy = if (plan_active) generated_system_prompt.plan_policy_text else "",
        });
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
        self.syncToolSandbox();
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
        self.runtime_tracker.deinit(self.allocator);
        self.instructions_tracker = .{};
        self.instructions_seq = null;
        self.freeTurnGuides();
        self.turn_memory_context = "";
        // A fresh session starts from the full catalog; the per-turn filter is
        // recomputed at the next turn.
        _ = self.turn_tools.reset(.free_all);
        self.tool_schemas = self.all_schemas;
        self.tool_specs = self.all_specs;
    }

    fn freeTurnGuides(self: *Self) void {
        if (self.turn_guides) |text| self.allocator.free(text);
        self.turn_guides = null;
    }

    // ── session lifecycle ────────────────────────────────────────────────────

    /// Create a fresh session id + JSONL, take its write lease and start the
    /// kernel loop. A non-empty `seed` imports the host's persisted history as
    /// the log's inherited prefix (`isSeeded=true`), once.
    fn openNewSession(self: *Self, session_id: ?[]const u8, seed: []const memory_mod.MessageEntry) !void {
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

        const seeded = seedableCount(seed) != 0;
        const header = types.Header{
            .id = id,
            .created_at = self.now() orelse compat.time.milliTimestamp(),
            .cwd = self.workspace(),
            .is_seeded = seeded,
            .delegation_depth = 0,
        };
        self.log = try session_store.createLog(self.allocator, self.opts.dsh_home, self.workspace(), id, header);
        if (self.goal_store) |store| store.attachLog(&self.log.?);
        if (self.todo) |ctx| ctx.log = &self.log.?;
        // dsh pins the missing permission facts before the session is
        // published (`pinInitialPermission`), so a `/permission` issued before
        // the first turn stays the last permission event in the log.
        try self.writeSessionDefaults(arena);
        self.context_written = true;
        if (seeded) {
            // Fold the seed through the same surface path a resumed log uses,
            // so the first turn already sees the imported history.
            try self.rebuildSurface(try self.appendSeed(seed), arena);
        }
        self.buildLoop();
        // A new session starts from the composition defaults again.
        if (!seeded) try self.buildPrompt();
    }

    /// Append one text event per usable store row, then dsh's inherited-cut
    /// marker. Unusable rows (runtime commands, empty or non-UTF-8 text) are
    /// skipped so a damaged transcript cannot abort the open. Returns the
    /// events for the in-memory surface fold.
    fn appendSeed(self: *Self, entries: []const memory_mod.MessageEntry) ![]types.Event {
        return self.appendSeedFrom(entries, 0);
    }

    /// `already` usable rows were written by an earlier, interrupted run:
    /// skip them so a resumed import never duplicates history.
    fn appendSeedFrom(self: *Self, entries: []const memory_mod.MessageEntry, already: usize) ![]types.Event {
        const arena = self.arena.allocator();
        var events: std.ArrayListUnmanaged(types.Event) = .empty;
        errdefer events.deinit(arena);
        var skipped: usize = 0;
        var usable: usize = 0;
        for (entries) |entry| {
            const role = seedRole(entry.role) orelse {
                skipped += 1;
                continue;
            };
            if (entry.content.len == 0 or !std.unicode.utf8ValidateSlice(entry.content)) {
                skipped += 1;
                continue;
            }
            usable += 1;
            if (usable <= already) continue;
            const text = try arena.dupe(u8, entry.content);
            var blocks = [_]types.ContentBlock{.{ .text = text }};
            const message = types.Message{
                .id = try self.nextMessageId(),
                .role = role,
                .content = &blocks,
                .source = switch (role) {
                    .assistant => .{ .model = .{ .provider = self.opts.provider_name, .model = self.opts.model } },
                    .system => .system_prompt,
                    else => .user,
                },
            };
            const value = try messageValue(arena, message);
            const event_type = switch (role) {
                .assistant => "assistant/message",
                .system => "system/message",
                else => "user/message",
            };
            // dsh stores `user/message` at the top level, the others under `message`.
            const data: Value = if (role == .user) value else blk: {
                var object: std.json.ObjectMap = .empty;
                try object.put(arena, "message", value);
                break :blk .{ .object = object };
            };
            const seq = try self.appendEvent(event_type, data, .append, null);
            try events.append(arena, .{
                .event_type = event_type,
                .seq = seq,
                .time_ms = self.now() orelse compat.time.milliTimestamp(),
                .data = data,
                .surface_op = .append,
            });
        }
        if (skipped != 0) std.log.warn("dsh-native: skipped {d} unusable store rows while seeding", .{skipped});
        // `inherited:true` is the marker dsh's v4 format requires for a seeded
        // header: everything before it is the imported prefix.
        var marker: std.json.ObjectMap = .empty;
        try marker.put(arena, "inherited", .{ .bool = true });
        _ = try self.appendEvent("session/end-seed", .{ .object = marker }, null, null);
        return events.toOwnedSlice(arena);
    }

    /// Reopen the JSONL for `session_id` and rebuild the surface from it.
    fn openExistingSession(self: *Self, session_id: []const u8, seed: []const memory_mod.MessageEntry) !void {
        // Copy before closeSession: restore passes the id loadMappedId
        // allocated in the session arena, which closeSession frees.
        const id_copy = try self.allocator.dupe(u8, session_id);
        defer self.allocator.free(id_copy);
        self.closeSession();
        const arena = self.arena.allocator();
        self.session_id = try arena.dupe(u8, id_copy);
        self.log = session_store.openLog(self.allocator, self.opts.dsh_home, self.workspace(), self.session_id) catch |err| {
            if (self.opts.on_corrupt != .native or !isLogCorruption(err)) return err;
            try self.startFresh();
            return;
        };
        if (self.goal_store) |store| store.attachLog(&self.log.?);
        if (self.todo) |ctx| ctx.log = &self.log.?;

        var read = session_log.readLog(self.allocator, self.log.?.path) catch |err| {
            if (self.opts.on_corrupt != .native or !isLogCorruption(err)) return err;
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
        // Regression: a crash between the is_seeded header and the end-seed
        // marker left a valid log that replayed half the host transcript and
        // never finished the import. Continue from the rows already written,
        // before the marker, so the inherited prefix becomes complete.
        var events: []const types.Event = read.events;
        if (read.header.is_seeded and !hasEndSeedMarker(read.events) and seedableCount(seed) != 0) {
            const resumed = try self.appendSeedFrom(seed, seededMessageCount(read.events));
            events = try concatEvents(arena, read.events, resumed);
        }
        // Regression: a crash between `compaction/start` and `compaction/end`
        // left the durable lock active, so every later compaction failed with
        // CompactionLocked while the context kept growing. The exclusive session
        // lock acquired above proves the old writer is gone, so close the dead
        // transaction here. dsh keeps it busy instead; junclaw-only recovery.
        if (try compaction_mod.deadWriterEnd(arena, events)) |end_event| {
            const log = if (self.log) |*value| value else return error.NoSession;
            const seq = try log.append(end_event.event_type, end_event.data, .{ .time_ms = end_event.time_ms });
            if (seq != end_event.seq) return error.RepairSequenceMismatch;
            events = try concatEvents(arena, events, &.{end_event});
        }
        // dsh crash repair: a writer killed inside a turn left no `turn/end`
        // (and possibly an assistant tool call with no result). Append the
        // closers it never wrote before folding, so a resumed request never
        // replays a dangling call and the next turn continues past it.
        const closers = try repair.openTurnClosers(arena, events);
        if (closers.len > 0) {
            const log = if (self.log) |*value| value else return error.NoSession;
            for (closers) |closer| {
                const seq = try log.append(closer.event_type, closer.data, .{
                    .time_ms = closer.time_ms,
                    .surface_op = closer.surface_op,
                    .source_event_seqs = closer.source_event_seqs,
                });
                if (seq != closer.seq) return error.RepairSequenceMismatch;
            }
            events = try concatEvents(arena, events, closers);
        }
        try self.rebuildSurface(events, arena);
        if (self.goal_store) |store| store.rebuild(events) catch |err| {
            // Same policy as a corrupt log: a projection the log cannot
            // replay starts a fresh session instead of wedging every open.
            if (self.opts.on_corrupt != .native) return err;
            try self.startFresh();
            return;
        };
        self.buildLoop();
        // dsh restores `turnBoundary.lastTurn` from the log; a resumed kernel
        // continues numbering instead of reusing turn 1 (and its
        // `system-1` id) in the same session.
        self.loop.?.turn = lastTurn(events);
        if (baseline) |header| {
            const loop = &self.loop.?;
            loop.last_header = header;
            loop.tracker.logged = true;
        }
    }

    /// Errors that mean the JSONL cannot be interpreted. Only these may fall
    /// back to a fresh session under `on_corrupt = "native"`; lock, I/O and
    /// allocation failures always propagate.
    fn isLogCorruption(err: anyerror) bool {
        return switch (err) {
            error.CorruptLog,
            error.SequenceGap,
            error.UnsupportedSessionFormatVersion,
            error.UnsupportedEventType,
            error.InvalidSurfaceOp,
            error.InvalidEvent,
            => true,
            else => false,
        };
    }

    fn lastTurn(events: []const types.Event) u64 {
        var last: u64 = 0;
        for (events) |event| {
            if (!std.mem.eql(u8, event.event_type, "turn/start")) continue;
            const object = switch (event.data) {
                .object => |value| value,
                else => continue,
            };
            const value = object.get("turn") orelse continue;
            const turn: u64 = switch (value) {
                .integer => |number| if (number > 0) @intCast(number) else continue,
                else => continue,
            };
            if (turn > last) last = turn;
        }
        return last;
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
        // Regression: the folded preset aliased the read arena, so `/permission`
        // after a resume read freed memory and crashed.
        if (self.permission_state.preset) |preset| {
            self.permission_state.preset = try arena.dupe(u8, preset);
        }
        self.applyApprovalPolicy(self.permission_state.approval);
        self.syncToolSandbox();
        try self.buildPrompt();
        self.compaction_lock = compaction_mod.scanLock(events);
        self.surface_seqs.clearRetainingCapacity();
        for (fold.nodes) |node| try self.surface_seqs.append(arena, node.seq);

        const messages = try arena.alloc(types.Message, fold.nodes.len);
        for (fold.nodes, 0..) |node, index| {
            messages[index] = try cloneMessage(arena, node.message);
        }
        try self.messages.appendSlice(arena, messages);
        try self.restoreContextTrackerState(fold.nodes);
    }

    /// Resume the dsh context projectors from the folded surface: the last
    /// runtime-context snapshot stays retained (no duplicate on the next
    /// pre-step) and the agent-instructions baseline keeps its identity so an
    /// unchanged file set emits nothing.
    fn restoreContextTrackerState(self: *Self, nodes: []const surface_mod.Node) !void {
        self.runtime_tracker.deinit(self.allocator);
        self.instructions_tracker = .{};
        self.instructions_seq = null;
        for (nodes) |node| {
            const source = switch (node.message.source) {
                .other => |value| value,
                else => continue,
            };
            const kind = sourceKindValue(source);
            if (std.mem.eql(u8, kind, "runtime-context")) {
                const text = try textOf(self.allocator, node.message.content);
                defer self.allocator.free(text);
                self.runtime_tracker.deinit(self.allocator);
                self.runtime_tracker.retained = try self.allocator.dupe(u8, text);
            } else if (std.mem.eql(u8, kind, "agent-instructions")) {
                self.instructions_seq = node.seq;
                const object = switch (source) {
                    .object => |value| value,
                    else => continue,
                };
                if (object.get("baselineIdentity")) |value| switch (value) {
                    .string => |text| if (identityFromHex(text)) |identity| {
                        self.instructions_tracker.identity = identity;
                    },
                    else => {},
                };
            }
        }
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
        try self.startFresh();
    }

    fn restore(ptr: *anyopaque, input: port.RestoreInput) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // The mapping, not the host's memory of the id, is the resume source:
        // a restarted host and the dsh sidecar then read the same JSONL.
        const stored = try self.loadMappedId();
        const session_id = input.dsh_session_id orelse stored orelse {
            try self.startFreshSeeded(input.messages);
            return;
        };
        self.openExistingSession(session_id, input.messages) catch |err| switch (err) {
            error.FileNotFound => try self.startFreshSeeded(input.messages),
            else => return err,
        };
    }

    fn startFresh(self: *Self) !void {
        try self.openNewSession(null, &.{});
        try self.writeMapping();
    }

    /// First open of a mapped session whose JSONL does not exist yet: import
    /// the host transcript as the seeded prefix. Reopening an existing JSONL
    /// never reaches this path, so the import happens once.
    fn startFreshSeeded(self: *Self, seed: []const memory_mod.MessageEntry) !void {
        try self.openNewSession(null, seed);
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
        // `agent.tool_filter_groups` applies to every model call in this turn,
        // exactly like the native agent's per-turn schema filter.
        try self.selectTurnTools(input.user_message);
        // A goal round is one kernel turn; never leak that authority forward.
        defer {
            if (self.goal_tools) |tools| tools.authority = .{};
        }
        self.sink = input.sink;
        self.live_stream = input.live_stream;
        self.last_provider_error = null;
        // Native turns install this per turn so retry notices reach the live
        // draft; the kernel calls the provider directly and would not see them.
        const prev_retry_observer = providers.reliable.retryObserver();
        providers.reliable.setRetryObserver(.{
            .callback = forwardRetryProgress,
            .ctx = @ptrCast(self),
        });
        defer providers.reliable.setRetryObserver(prev_retry_observer);
        self.drain = input.drain;
        self.drain_ctx = input.drain_ctx;
        self.interaction = input.interaction;
        defer {
            self.sink = null;
            self.drain = null;
            self.drain_ctx = null;
            self.interaction = null;
        }

        // Native re-reads the workspace guides once per turn; the runtime
        // context renders them on every pre-step, so they must live that long.
        self.freeTurnGuides();
        self.turn_memory_context = input.memory_context orelse "";
        if (self.opts.inject_model_context) {
            self.turn_guides = try native_prompt.buildWorkspaceGuides(self.allocator, .{
                .workspace_dir = self.workspace(),
                .bootstrap_provider = self.opts.bootstrap_provider,
                .identity_config = self.opts.identity_config,
            });
        }
        defer {
            self.freeTurnGuides();
            self.turn_memory_context = "";
        }

        self.turn_text.clearRetainingCapacity();
        self.turn_reasoning.clearRetainingCapacity();
        self.last_assistant_text = null;
        // A previous turn's stop must not abort this one's first provider
        // call; the kernel flag below still ends a pre-turn stop.
        self.stream_cancel.store(false, .monotonic);
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
        const reply = try self.composeReply();
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
                result.@"error" = try self.failureText(failure);
                result.error_code = failure.code;
            },
            else => {},
        }
        return result;
    }

    /// The kernel reports a provider failure with a fixed internal message and
    /// the Zig error name. Native users get `error_classify` copy; classify the
    /// original provider error so dsh-native users do too instead of seeing
    /// the internal label or an unsanitized upstream detail.
    fn failureText(self: *Self, failure: types.Failure) ![]const u8 {
        if (self.last_provider_error) |err| {
            if (isProviderFailureMessage(failure.message) and
                std.mem.eql(u8, failure.code, @errorName(err)))
            {
                var buf: [512]u8 = undefined;
                const text = providers.userErrorMessage(&buf, err, true);
                return self.allocator.dupe(u8, text);
            }
        }
        return self.allocator.dupe(u8, failure.message);
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
        self.stream_cancel.store(true, .release);
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
            .reasoning_mode = self.opts.reasoning_mode,
            .redactor = self.opts.redactor,
            .harness_kind = .dsh,
            .owns_inbox = true,
            .supports_commands = false,
            .dsh_session_id = if (self.session_id.len == 0) null else self.session_id,
        };
    }

    /// Host seam for `/model`, `/think` and `/reasoning`: the session's agent
    /// owns the live selection, the engine mirrors it into the next request
    /// header (provider routing included, so `provider/model` refs work).
    pub fn setCallConfig(
        self: *Self,
        model: []const u8,
        reasoning_effort: ?[]const u8,
        reasoning_mode: config_types.ReasoningMode,
    ) void {
        self.opts.model = model;
        self.opts.reasoning_effort = reasoning_effort;
        self.opts.reasoning_mode = reasoning_mode;
        if (self.loop) |*l| {
            l.config.model = model;
            l.config.reasoning_effort = reasoning_effort;
        }
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

    /// Mirrors native's retry progress hook: one borrowed hint per retry, and
    /// an attempt of 0 clears the host's retry indicator.
    fn forwardRetryProgress(context_ptr: *anyopaque, notice: providers.reliable.RetryNotice) void {
        const self = selfOf(context_ptr);
        const sink = self.sink orelse return;
        if (notice.attempt == 0) {
            sink.send(.{ .progress = .{ .kind = .retry, .retry = null } });
            return;
        }
        var buf: [40]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "Retrying ({d}/{d})\u{2026}", .{
            notice.attempt,
            notice.max,
        }) catch "Retrying\u{2026}";
        sink.send(.{ .progress = .{
            .kind = .retry,
            .text = text,
            .retry = .{ .attempt = notice.attempt, .max = notice.max },
        } });
    }

    fn hostEmit(context_ptr: *anyopaque, event: loop_mod.Event) anyerror!u64 {
        const self = selfOf(context_ptr);
        switch (event) {
            .turn_start => |payload| {
                const seq = try self.appendPositional("turn/start", null, payload.turn, 0);
                if (self.sink) |sink| sink.send(.{ .turn_start = .{ .turn = payload.turn } });
                return seq;
            },
            .step_start => |position| {
                // `.on` quotes only the last response's reasoning; a step that
                // aborts or fails before its assistant message must not
                // inherit the previous step's block.
                self.turn_reasoning.clearRetainingCapacity();
                const seq = try self.appendPositional("step/start", position, 0, 0);
                if (self.sink) |sink| sink.send(.{ .step_start = .{
                    .turn = position.turn,
                    .step = position.step,
                } });
                return seq;
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
            .assistant_closer => |payload| return self.appendAssistantCloser(payload.position, payload.message),
            .tool_call => |payload| return self.appendToolCall(payload.position, payload.call),
            .tool_result => |payload| return self.appendToolResult(payload.position, payload.result),
            .step_end => |position| {
                const seq = try self.appendPositional("step/end", position, 0, 0);
                if (self.sink) |sink| sink.send(.{ .step_end = .{
                    .turn = position.turn,
                    .step = position.step,
                } });
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
                const seq = try self.appendEvent("turn/end", .{ .object = data }, null, null);
                if (self.sink) |sink| sink.send(.{ .turn_end = .{ .turn = payload.turn } });
                return seq;
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
        var data = try parseValue(arena, message.json);
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
        // PII never reaches the JSONL or the model surface.
        data = try self.redactUserMessageData(arena, data);
        const surface_op = message.surface_op orelse .append;
        const seq = try self.appendEvent("user/message", data, surface_op, message.source_event_seqs);
        const projected = try surface_mod.messageFromEvent(arena, .{
            .event_type = "user/message",
            .seq = seq,
            .time_ms = 0,
            .data = data,
            .surface_op = surface_op,
        });
        switch (surface_op) {
            .append => try self.addSurfaceSnapshot(arena, seq, projected),
            .replace => |range| try self.replaceSurfaceSnapshot(arena, range.start_seq, range.end_seq, seq, projected),
        }
        if (std.mem.eql(u8, messageSourceKind(data), "agent-instructions")) {
            self.instructions_seq = seq;
        }
        return seq;
    }

    /// Mirror a surface replacement in the in-memory request surface: the new
    /// node takes the position of the range it shadows (surface.ts:63-105).
    fn replaceSurfaceSnapshot(
        self: *Self,
        arena: Allocator,
        start_seq: u64,
        end_seq: u64,
        seq: u64,
        message: types.Message,
    ) !void {
        var start: ?usize = null;
        var end: ?usize = null;
        for (self.surface_seqs.items, 0..) |node_seq, index| {
            if (start == null and node_seq == start_seq) start = index;
            if (node_seq == end_seq) {
                end = index;
                break;
            }
        }
        const first = start orelse return error.UnknownSurfaceRange;
        const last = end orelse return error.UnknownSurfaceRange;
        if (first > last) return error.UnknownSurfaceRange;
        try self.surface_seqs.replaceRange(arena, first, last - first + 1, &.{seq});
        try self.messages.replaceRange(arena, first, last - first + 1, &.{message});
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
        // PII never reaches the JSONL, the surface or the host sink.
        var message = settlement.message;
        message.content = try self.redactContent(arena, message.content);
        var data = try objectWithPosition(arena, position, 0, 0);
        try data.put(arena, "message", try messageValue(arena, message));
        if (settlement.usage) |usage| try data.put(arena, "usage", try usageValue(arena, usage));
        try data.put(arena, "stream", try streamValue(arena, settlement.stream));
        if (settlement.interrupted) try data.put(arena, "interrupted", .{ .bool = true });

        if (is_attempt) {
            return self.appendEvent("assistant/attempt", .{ .object = data }, null, null);
        }

        const seq = try self.appendEvent("assistant/message", .{ .object = data }, .append, null);

        // The host renders the turn's whole text; the log keeps every segment.
        const text = try textOf(arena, message.content);
        try self.turn_text.appendSlice(self.allocator, text);
        // `.on` renders the last response's reasoning as a post-turn block,
        // like native's `composeFinalReply`; copy it out of the step arena.
        if (self.opts.reasoning_mode == .on) {
            self.turn_reasoning.clearRetainingCapacity();
            for (message.content) |block| switch (block) {
                .reasoning => |trace| try self.turn_reasoning.appendSlice(self.allocator, trace),
                else => {},
            };
        }
        if (countToolCalls(message.content) == 0) self.last_assistant_text = text;
        if (self.sink) |sink| {
            if (text.len > 0) sink.send(.{ .assistant_message = .{ .text = text } });
        }
        // The kernel's accumulator arena dies at step end: copy first.
        try self.addSurfaceSnapshot(arena, seq, try cloneMessage(arena, message));
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
        if (self.sink) |sink| {
            sink.send(.{ .tool_call = .{
                .call_id = call.id,
                .name = call.name,
                .arguments_json = call.arguments,
            } });
            // Same hint native emits before running a tool. `text` is the tool
            // name; the raw arguments stay in `arguments_json`, which the host
            // only reads for a short safe summary.
            sink.send(.{ .progress = .{
                .text = call.name,
                .arguments_json = call.arguments,
                .phase = .start,
            } });
        }
        return seq;
    }

    fn appendToolResult(self: *Self, position: loop_mod.Position, result: registry.ToolResult) !u64 {
        const arena = self.arena.allocator();
        // The kernel commits results in model order, one per pending call.
        if (self.pending_calls.items.len == 0) return error.UnexpectedToolResult;
        const call = self.pending_calls.items[0];
        _ = self.pending_calls.orderedRemove(0);
        defer self.freePendingCall(call);

        const safe_result = try self.sanitizeToolResult(arena, result);
        const message = types.Message{
            .id = try self.nextMessageId(),
            .role = .tool,
            .content = safe_result.content(),
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
        if (self.sink) |sink| {
            sink.send(.{ .tool_result = .{
                .call_id = call.call.id,
                .name = call.call.name,
                .output = try toolOutputText(arena, safe_result),
                .is_error = result.isError(),
            } });
            sink.send(.{ .progress = .{
                .text = call.call.name,
                .phase = .end,
                .success = !result.isError(),
            } });
        }
        return seq;
    }

    /// Record one surface message in request order. The caller passes an
    /// arena-owned message; it is adopted, not copied.
    fn addSurfaceSnapshot(self: *Self, arena: Allocator, seq: u64, message: types.Message) !void {
        try self.messages.append(arena, message);
        try self.surface_seqs.append(arena, seq);
    }

    /// Persist a kernel-authored failure closer as an ordinary assistant
    /// message. It deliberately skips `turn_text` and the sink: the host owns
    /// the user-visible error and must not receive the marker as a reply.
    fn appendAssistantCloser(self: *Self, position: loop_mod.Position, message: types.Message) !u64 {
        const arena = self.arena.allocator();
        var safe_message = message;
        safe_message.content = try self.redactContent(arena, safe_message.content);
        var data = try objectWithPosition(arena, position, 0, 0);
        try data.put(arena, "message", try messageValue(arena, safe_message));
        try data.put(arena, "stream", try streamValue(arena, &.{}));
        const seq = try self.appendEvent("assistant/message", .{ .object = data }, .append, null);
        try self.addSurfaceSnapshot(arena, seq, try cloneMessage(arena, safe_message));
        return seq;
    }

    fn forwardDelta(self: *Self, event: stream.Event) void {
        // The streaming bridge pushed every chunk from the provider callback,
        // where the host saw it while the call was still running; replaying
        // the kernel events here would duplicate the draft text.
        if (self.streamed_live) return;
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
        _ = claimed;
        const self = selfOf(context_ptr);
        // dsh checks `signal.aborted` before committing a queued selection; the
        // kernel's own check runs after this callback, so an abort that lands
        // just before the step opens must not switch plan mode.
        if (self.loop) |*loop| {
            if (loop.isAborted()) return .{};
        }
        const boundary = self.plan_session.preStep();
        // A committed plan-mode change bumps dsh's surface projection
        // generation, so the next request opens a new series even when the
        // catalog and header are unchanged (live plan-exit-approved: the
        // post-approval request logs reason "series").
        const plan_changed = boundary.emit != null;
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
        if (boundary.narration) |text| {
            const id = try self.nextMessageId();
            const json = try planNarrationJson(allocator, id, text);
            try out.append(allocator, .{ .json = json });
        }
        try self.appendModelContext(allocator, out);
        // A new turn opens a new request series: dsh appends request/header
        // with reason "series" even when the header is unchanged (live
        // recording p2b-plan-off). Without this, an unchanged catalog would
        // hide the per-turn requests from the log.
        return .{ .starts_request_series = plan_changed or (position.step == 1 and position.turn > 1) };
    }

    /// Pre-step context dsh appends after the claimed user messages: the
    /// agent-instructions baseline (B16) and the runtime-context snapshot
    /// (B15). Both stay out of the system prompt.
    fn appendModelContext(self: *Self, allocator: Allocator, out: *std.ArrayListUnmanaged(loop_mod.UserMessage)) !void {
        if (!self.opts.inject_model_context) return;
        try self.appendInstructionsBaseline(allocator, out);
        try self.appendRuntimeContext(allocator, out);
    }

    fn appendInstructionsBaseline(self: *Self, allocator: Allocator, out: *std.ArrayListUnmanaged(loop_mod.UserMessage)) !void {
        const baseline = try self.instructions_tracker.update(allocator, self.instructionsOptions(), self.instructions_seq) orelse return;
        try out.append(allocator, .{
            .json = try instructionsMessageJson(allocator, try self.nextMessageId(), baseline.text, baseline.identity, baseline.replacement),
            .surface_op = if (baseline.replace_seq) |old_seq|
                .{ .replace = .{ .start_seq = old_seq, .end_seq = old_seq } }
            else
                null,
            .source_event_seqs = if (baseline.replace_seq) |old_seq|
                try allocator.dupe(u64, &.{old_seq})
            else
                null,
        });
    }

    fn instructionsOptions(self: *const Self) context.Options {
        return .{
            .cwd = self.workspace(),
            .dsh_home = self.opts.dsh_home,
        };
    }

    fn appendRuntimeContext(self: *Self, allocator: Allocator, out: *std.ArrayListUnmanaged(loop_mod.UserMessage)) !void {
        const sections = try self.runtimeSections(allocator);
        var snapshot = (try self.runtime_tracker.project(self.allocator, sections)) orelse return;
        defer snapshot.deinit(self.allocator);
        try out.append(allocator, .{
            .json = try runtimeContextMessageJson(allocator, try self.nextMessageId(), snapshot),
        });
    }

    fn runtimeSections(self: *const Self, allocator: Allocator) ![]context.Section {
        var sections: std.ArrayListUnmanaged(context.Section) = .empty;
        errdefer sections.deinit(allocator);
        const memory_text = std.mem.trimEnd(u8, self.turn_memory_context, "\n");
        if (memory_text.len > 0) {
            try sections.append(allocator, context.customSection(
                "junclaw:memory",
                context.ContextOrder.junclaw_memory,
                memory_text,
            ));
        }
        if (self.turn_guides) |guides| {
            const guide_text = std.mem.trimEnd(u8, guides, "\n");
            if (guide_text.len > 0) {
                try sections.append(allocator, context.customSection(
                    "junclaw:workspace-guides",
                    context.ContextOrder.junclaw_guides,
                    guide_text,
                ));
            }
        }
        if (self.channel_attachments) |text| {
            const attachments_text = std.mem.trimEnd(u8, text, "\n");
            if (attachments_text.len > 0) {
                try sections.append(allocator, context.customSection(
                    "junclaw:channel-attachments",
                    context.ContextOrder.junclaw_channel_attachments,
                    attachments_text,
                ));
            }
        }
        // Native's `## Safety` policy, verbatim. It rides the runtime context
        // like the other junclaw-only guidance so dsh's generated system
        // prompt keeps its exact bytes and cache prefix.
        const safety_text = std.mem.trimEnd(u8, native_prompt.safety_section, "\n");
        try sections.append(allocator, context.customSection(
            "junclaw:safety",
            context.ContextOrder.junclaw_safety,
            safety_text,
        ));
        try sections.append(allocator, try context.dateTimeSection(allocator, self.opts.timezone, self.nowSeconds()));
        try sections.append(allocator, try context.workingDirectorySection(allocator, self.workspace()));
        try sections.append(allocator, try context.sandboxPolicySection(allocator, self.sandboxMode(), self.workspace()));
        try sections.append(allocator, context.approvalPolicySection(self.approvalPolicy()));
        return sections.toOwnedSlice(allocator);
    }

    fn nowSeconds(self: *const Self) i64 {
        if (self.opts.now_ms) |clock| return @divFloor(clock(self.opts.clock_context), 1000);
        return compat.time.timestamp();
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

    /// One provider call per attempt: live streaming when the host has a draft
    /// and the provider supports it, otherwise one blocking call whose whole
    /// assistant message is pushed as a synthetic stream. The kernel assembles
    /// either as deltas, tool calls and `done`.
    fn providerBegin(context_ptr: *anyopaque, view: loop_mod.RequestView) anyerror!void {
        const self = selfOf(context_ptr);
        self.cancelCall();
        self.pending.clearRetainingCapacity();
        self.pending_index = 0;
        self.stream_error = null;
        self.streamed_live = false;

        const arena = self.call_arena.allocator();
        const messages = try self.requestsFromMessages(arena, self.messages.items);
        const chat = providers.ChatRequest{
            .messages = messages,
            .model = self.opts.model,
            .temperature = self.opts.temperature,
            .max_tokens = self.opts.max_tokens,
            .tools = self.tool_specs,
            .reasoning_effort = self.opts.reasoning_effort,
            .include_reasoning = self.opts.reasoning_mode != .off,
            .session_id = if (self.opts.session_key.len == 0) null else self.opts.session_key,
        };

        // Both paths run on this thread until the request ends, so either one
        // must expose the stop flag to the transport: a /stop from the host
        // thread cancels an in-flight curl request instead of letting it run
        // to completion. Restore the caller's flag for nested harness calls.
        const outer_interrupt = http_util.currentThreadInterruptFlag();
        http_util.setThreadInterruptFlag(&self.stream_cancel);
        defer http_util.setThreadInterruptFlag(outer_interrupt);

        if (self.streamingEnabled()) return self.beginStreaming(arena, chat, view.position);

        var response = self.opts.provider.chatWithTools(arena, chat) catch |err| {
            self.last_provider_error = err;
            return err;
        };
        defer freeResponseFields(arena, &response);
        // A provider that ignores the flag can still finish after the stop;
        // never hand that late body to the kernel as the turn's answer.
        if (self.stream_cancel.load(.acquire)) {
            self.last_provider_error = error.Interrupted;
            return error.Interrupted;
        }

        self.turn_model_calls += 1;
        // Reasoning and text need distinct stream indexes: the accumulator
        // keys one content block per index, so sharing index 0 would fold the
        // answer into the reasoning block (and drop it from the reply).
        var next_block_index: u32 = 0;
        if (self.opts.reasoning_mode != .off) {
            if (response.reasoning_content) |reasoning| {
                if (reasoning.len > 0) {
                    try self.pending.append(arena, .{ .chunk = .{ .reasoning_delta = .{
                        .index = next_block_index,
                        .text = try arena.dupe(u8, reasoning),
                    } } });
                    next_block_index += 1;
                }
            }
        }
        const content: []const u8 = response.content orelse "";
        // A provider without native tool calls can write the call into its
        // answer instead. Recover it with the dispatcher's parser; structured
        // calls always win when the provider sent both.
        var text = content;
        var text_calls: []const providers.ToolCall = &.{};
        if (containsTextToolCall(content)) {
            const parsed = try dispatcher.parseToolCalls(arena, content);
            text = parsed.text;
            if (response.tool_calls.len == 0 and parsed.calls.len > 0) {
                if (response.truncated) {
                    std.log.warn("dsh-native: discarding {d} text tool call(s) from a truncated response", .{parsed.calls.len});
                } else {
                    text_calls = try providerCallsFromText(arena, view.position, parsed.calls, 0);
                }
            }
        }
        if (text.len > 0) {
            try self.pending.append(arena, .{ .chunk = .{ .text_delta = .{
                .index = next_block_index,
                .text = try arena.dupe(u8, text),
            } } });
        }
        try self.pushDone(
            arena,
            if (response.tool_calls.len > 0) response.tool_calls else text_calls,
            response.usage,
            response.truncated,
        );
    }

    /// Live streaming needs a host draft and a provider that returns native
    /// tool calls from the stream; otherwise the blocking path stays the only
    /// one that preserves tool calls.
    fn streamingEnabled(self: *const Self) bool {
        return self.live_stream and
            self.opts.provider.supportsStreaming() and
            (self.tool_specs.len == 0 or
                self.opts.provider.supportsStreamingNativeToolsForModel(self.opts.model));
    }

    /// Streaming bridge state: one provider chunk becomes a host delta and a
    /// kernel text/reasoning delta as it arrives.
    const StreamRelay = struct {
        harness: *Self,
        arena: Allocator,
        mode: config_types.ReasoningMode,
        /// Bytes held because they may start a reasoning tag the next chunk
        /// completes.
        held: std.ArrayListUnmanaged(u8) = .empty,
        in_reasoning: bool = false,
        /// Calls recovered from an explicit `<tool_call>` block in the text.
        text_calls: std.ArrayListUnmanaged(providers.ToolCall) = .empty,
        /// Held begins with a `<tool_call>` opener whose close tag is pending.
        in_tool_block: bool = false,
        /// Names the response for the recovered calls' generated ids.
        position: loop_mod.Position,
        /// At least one delta reached the kernel/host, so a later provider
        /// error settles a partial assistant message (P3).
        saw_delta: bool = false,
        /// A reasoning delta was already relayed, so a non-streaming fallback
        /// result must not append the same reasoning again.
        saw_reasoning: bool = false,
        output_bytes: usize = 0,
        err: ?anyerror = null,

        /// Reasoning and text need distinct indexes: the accumulator keys one
        /// block per index, so a shared index folds the answer into reasoning.
        const text_index: u32 = 0;
        const reasoning_index: u32 = 1;

        fn onChunk(ctx: *anyopaque, chunk: providers.StreamChunk) void {
            const state: *StreamRelay = @ptrCast(@alignCast(ctx));
            if (state.err != null) return;
            state.relay(chunk) catch |err| {
                state.err = err;
            };
        }

        fn relay(self: *StreamRelay, chunk: providers.StreamChunk) !void {
            if (chunk.is_final) {
                self.toHost(chunk);
                return;
            }
            if (chunk.delta.len == 0) return;
            // The splitter owns host delivery too: a `<tool_call>` block must
            // never reach the draft, not even before its close tag arrives.
            try self.split(chunk.delta);
        }

        fn toHost(self: *StreamRelay, chunk: providers.StreamChunk) void {
            if (self.harness.sink) |sink| sink.send(.{ .delta = chunk });
        }

        fn hostText(self: *StreamRelay, text: []const u8) void {
            if (text.len == 0) return;
            self.toHost(.{
                .delta = text,
                .is_final = false,
                .token_count = @intCast((text.len + 3) / 4),
            });
        }

        const tool_open = "<tool_call>";
        const tool_close = "</tool_call>";

        /// True when `rest` is the start of a `<tool_call>` opener, complete or
        /// still split across chunks.
        fn isToolCallPrefix(rest: []const u8) bool {
            if (std.mem.startsWith(u8, rest, tool_open)) return true;
            return rest.len < tool_open.len and std.mem.startsWith(u8, tool_open, rest);
        }

        fn holdFrom(self: *StreamRelay, at: usize) void {
            const tail = self.held.items[at..];
            std.mem.copyForwards(u8, self.held.items[0..tail.len], tail);
            self.held.shrinkRetainingCapacity(tail.len);
        }

        /// Split raw provider text into reasoning, visible and tool-call runs.
        /// The SSE parsers emit `<think>`/`</think>` as their own chunks, but a
        /// tag inside content can straddle chunks, so a trailing partial tag
        /// waits for the next call. A `<tool_call>` block waits for its close
        /// tag and then goes to the dispatcher: neither the draft nor the
        /// assistant text may see the markup.
        fn split(self: *StreamRelay, text: []const u8) !void {
            try self.held.appendSlice(self.arena, text);
            while (true) {
                if (self.in_tool_block) {
                    if (!try self.scanToolBlock()) return;
                    continue;
                }
                var i: usize = 0;
                var start: usize = 0;
                var holding = false;
                while (i < self.held.items.len) {
                    if (self.held.items[i] != '<') {
                        i += 1;
                        continue;
                    }
                    const rest = self.held.items[i..];
                    switch (provider_helpers.scanThinkTag(rest)) {
                        .none => {
                            // A tool-call opener inside a reasoning block is
                            // prose the model is thinking about, not an action.
                            if (!self.in_reasoning and isToolCallPrefix(rest)) {
                                try self.emit(self.held.items[start..i]);
                                self.holdFrom(i);
                                self.in_tool_block = true;
                                holding = true;
                                break;
                            }
                            i += 1;
                        },
                        .partial => {
                            try self.emit(self.held.items[start..i]);
                            self.holdFrom(i);
                            return;
                        },
                        .complete => |tag| {
                            try self.emit(self.held.items[start..i]);
                            if (self.mode != .off) self.hostText(rest[0..tag.len]);
                            self.in_reasoning = !tag.close;
                            i += tag.len;
                            start = i;
                        },
                    }
                }
                if (holding) continue;
                try self.emit(self.held.items[start..]);
                self.held.clearRetainingCapacity();
                return;
            }
        }

        /// Consume the held `<tool_call>` block. False means the close tag (or
        /// the rest of the opener) has not arrived yet.
        fn scanToolBlock(self: *StreamRelay) !bool {
            const bytes = self.held.items;
            if (bytes.len < tool_open.len) {
                if (std.mem.startsWith(u8, tool_open, bytes)) return false;
                // It only looked like an opener: ordinary text.
                self.in_tool_block = false;
                try self.emit(bytes);
                self.held.clearRetainingCapacity();
                return false;
            }
            if (!std.mem.startsWith(u8, bytes, tool_open)) {
                self.in_tool_block = false;
                try self.emit(bytes);
                self.held.clearRetainingCapacity();
                return false;
            }
            const close_rel = std.mem.indexOf(u8, bytes[tool_open.len..], tool_close) orelse return false;
            const end = tool_open.len + close_rel + tool_close.len;

            const parsed = try dispatcher.parseToolCalls(self.arena, bytes[0..end]);
            if (parsed.calls.len > 0) {
                try self.appendTextCalls(parsed.calls);
            } else {
                // Not an executable call: the dispatcher returns the prose with
                // the marker tokens removed, or nothing for a malformed payload.
                try self.emitReleased(parsed.text);
            }

            const rest_len = bytes.len - end;
            std.mem.copyForwards(u8, bytes[0..rest_len], bytes[end..]);
            self.held.shrinkRetainingCapacity(rest_len);
            self.in_tool_block = false;
            return true;
        }

        fn appendTextCalls(self: *StreamRelay, parsed: []const dispatcher.ParsedToolCall) !void {
            try self.text_calls.appendSlice(
                self.arena,
                try providerCallsFromText(self.arena, self.position, parsed, self.text_calls.items.len),
            );
        }

        /// Release prose from a block the dispatcher did not turn into a call.
        /// Forged `<tool_result>` markup is stripped like the blocking path.
        fn emitReleased(self: *StreamRelay, text: []const u8) !void {
            try self.emit(try dispatcher.stripToolResultMarkup(self.arena, text));
        }

        /// Flush what is left at end of stream. A trailing partial tag is text;
        /// an unclosed `<tool_call>` gets the same dispatch decision as the
        /// whole response would.
        fn flush(self: *StreamRelay) !void {
            if (self.in_tool_block) {
                const parsed = try dispatcher.parseToolCalls(self.arena, self.held.items);
                if (parsed.calls.len > 0) {
                    try self.appendTextCalls(parsed.calls);
                } else {
                    std.log.warn("dsh-native: released an unclosed <tool_call> block as text", .{});
                    try self.emitReleased(parsed.text);
                }
                self.held.clearRetainingCapacity();
                self.in_tool_block = false;
                return;
            }
            try self.emit(self.held.items);
            self.held.clearRetainingCapacity();
        }

        /// A non-streaming fallback (large-request skip, curl fallback) hands
        /// the answer to `content` as one delta and leaves reasoning only in
        /// the result. The draft already got the content, so append reasoning
        /// to the kernel stream only: JSONL and the `.on` reply keep it, and
        /// the host never sees an answer followed by its thinking.
        fn emitFallbackReasoning(self: *StreamRelay, reasoning: []const u8) !void {
            if (self.saw_reasoning or self.mode == .off or reasoning.len == 0) return;
            try self.harness.pending.append(self.arena, .{ .chunk = .{ .reasoning_delta = .{
                .index = reasoning_index,
                .text = try self.arena.dupe(u8, reasoning),
            } } });
        }

        fn emit(self: *StreamRelay, text: []const u8) !void {
            if (text.len == 0) return;
            if (self.in_reasoning and self.mode == .off) return;
            self.saw_delta = true;
            self.output_bytes += text.len;
            const copied = try self.arena.dupe(u8, text);
            if (self.in_reasoning) {
                self.saw_reasoning = true;
                try self.harness.pending.append(self.arena, .{ .chunk = .{ .reasoning_delta = .{
                    .index = reasoning_index,
                    .text = copied,
                } } });
            } else {
                try self.harness.pending.append(self.arena, .{ .chunk = .{ .text_delta = .{
                    .index = text_index,
                    .text = copied,
                } } });
            }
            // The draft sees the provider bytes minus tool-call markup (held by
            // `split`) and, in `off` mode, reasoning.
            if (!self.in_reasoning or self.mode != .off) self.hostText(copied);
        }
    };

    /// Relay `Provider.streamChat` into the kernel and the host as it arrives.
    /// The provider invokes the callback synchronously on this thread, so the
    /// call arena and `pending` need no locking; every chunk is copied or
    /// forwarded before the callback returns, because its slice is borrowed.
    fn beginStreaming(
        self: *Self,
        arena: Allocator,
        chat: providers.ChatRequest,
        position: loop_mod.Position,
    ) anyerror!void {
        self.turn_model_calls += 1;
        self.streamed_live = true;
        var relay = StreamRelay{
            .harness = self,
            .arena = arena,
            .mode = self.opts.reasoning_mode,
            .position = position,
        };
        // `providerBegin` installed the stop flag for this whole call.

        var failed: ?anyerror = null;
        var result = self.opts.provider.streamChat(
            arena,
            chat,
            self.opts.model,
            self.opts.temperature,
            StreamRelay.onChunk,
            @ptrCast(&relay),
        ) catch |err| blk: {
            failed = err;
            break :blk providers.StreamChatResult{};
        };
        if (relay.err) |err| {
            self.last_provider_error = err;
            return err;
        }

        if (failed) |err| {
            // A failure can cut inside a `<think>` tag. The held bytes are
            // then only a tag prefix, not text: flushing them would show
            // markup in the draft and turn a zero-output failure into a
            // partial one.
            // Chunks already reached the sink and the kernel, so the kernel
            // settles the partial assistant message when its `next` raises
            // this error. A call that produced nothing keeps the blocking
            // path's "request failed to start" outcome.
            if (!relay.saw_delta) {
                self.last_provider_error = err;
                return err;
            }
            self.last_provider_error = err;
            self.stream_error = err;
            return;
        }
        try relay.flush();
        if (result.reasoning_content) |reasoning| try relay.emitFallbackReasoning(reasoning);
        // Only transports that leave usage at zero reach this fallback
        // estimate; sse/gemini/openai_codex already estimate their raw
        // accumulated bytes (tags and reasoning included). The two layers can
        // therefore differ by markup bytes when a provider omits usage; this
        // is a token-count nicety, not a compaction/statistics input.
        // Mirrors the non-streaming fallback: the fixed density is 4 chars per
        // token.
        if (result.usage.completion_tokens == 0 and relay.output_bytes > 0) {
            const estimate = (relay.output_bytes + 3) / 4;
            result.usage.completion_tokens = @intCast(@min(estimate, std.math.maxInt(u32)));
        }
        // Text-embedded calls are the fallback only: the provider's structured
        // calls decide when it sent any. A truncated response must not run a
        // call salvaged from its partial text.
        var calls: []const providers.ToolCall = result.tool_calls;
        if (calls.len == 0 and relay.text_calls.items.len > 0) {
            if (result.truncated) {
                std.log.warn("dsh-native: discarding {d} text tool call(s) from a truncated response", .{relay.text_calls.items.len});
            } else {
                calls = relay.text_calls.items;
            }
        }
        try self.pushDone(arena, calls, result.usage, result.truncated);
    }

    fn pushDone(
        self: *Self,
        arena: Allocator,
        calls: []const providers.ToolCall,
        usage_in: providers.TokenUsage,
        truncated: bool,
    ) !void {
        var done_calls = try arena.alloc(types.ToolCall, calls.len);
        for (calls, 0..) |call, index| {
            done_calls[index] = .{
                .id = try arena.dupe(u8, call.id),
                .name = try arena.dupe(u8, call.name),
                .arguments = try arena.dupe(u8, call.arguments),
            };
        }
        const usage = stream.ProviderUsage{
            .prompt_tokens = usage_in.prompt_tokens,
            .completion_tokens = usage_in.completion_tokens,
            .total_tokens = usage_in.total_tokens,
        };
        self.last_usage = stream.normalizeUsage(usage);
        const finish: stream.Finish = if (calls.len > 0)
            .tool_calls
        else if (truncated)
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
        if (self.pending_index >= self.pending.items.len) {
            if (self.stream_error) |err| {
                self.stream_error = null;
                return err;
            }
            return null;
        }
        const event = self.pending.items[self.pending_index];
        self.pending_index += 1;
        return event;
    }

    fn providerCancel(context_ptr: *anyopaque) void {
        selfOf(context_ptr).cancelCall();
    }

    fn cancelCall(self: *Self) void {
        self.streamed_live = false;
        self.stream_error = null;
        // The buffer lives in `call_arena`; drop it before the arena resets
        // (clearRetainingCapacity would keep a dangling capacity).
        self.pending = .empty;
        self.pending_index = 0;
        _ = self.call_arena.reset(.free_all);
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

    /// Redact one text at a model/disk boundary; a null redactor passes through.
    fn redactText(self: *Self, allocator: Allocator, text: []const u8) ![]const u8 {
        const r = self.opts.redactor orelse return text;
        return r.redact(allocator, text);
    }

    /// Redacted copy of the text blocks; image and reasoning payloads pass
    /// through untouched.
    fn redactContent(self: *Self, allocator: Allocator, content: []const types.ContentBlock) ![]const types.ContentBlock {
        if (self.opts.redactor == null) return content;
        const out = try allocator.alloc(types.ContentBlock, content.len);
        for (content, 0..) |block, index| {
            out[index] = block;
            switch (block) {
                .text => |text| out[index] = .{ .text = try self.redactText(allocator, text) },
                else => {},
            }
        }
        return out;
    }

    /// Native scrubs secret patterns out of every tool result before it enters
    /// history and then applies the PII redactor; mirror both so the
    /// model-facing text, the JSONL and the sink all see the same bytes.
    fn sanitizeToolResult(self: *Self, allocator: Allocator, result: registry.ToolResult) !registry.ToolResult {
        return switch (result) {
            .success => |success| .{ .success = .{
                .content = try self.sanitizeToolContent(allocator, success.content),
                .meta = success.meta,
                .additional_contexts = success.additional_contexts,
                .concludes_turn = success.concludes_turn,
                .replaces_selected_content = success.replaces_selected_content,
            } },
            .failure => |failure| .{ .failure = .{
                .error_info = failure.error_info,
                .content = try self.sanitizeToolContent(allocator, failure.content),
                .meta = failure.meta,
                .additional_contexts = failure.additional_contexts,
                .replaces_selected_content = failure.replaces_selected_content,
            } },
        };
    }

    fn sanitizeToolContent(self: *Self, allocator: Allocator, content: []const types.ContentBlock) ![]const types.ContentBlock {
        const out = try allocator.alloc(types.ContentBlock, content.len);
        for (content, 0..) |block, index| {
            out[index] = block;
            switch (block) {
                .text => |text| {
                    const scrubbed = try providers.scrubSecretPatterns(allocator, text);
                    out[index] = .{ .text = try self.redactText(allocator, scrubbed) };
                },
                else => {},
            }
        }
        return out;
    }

    /// Redact the text blocks of a dsh user/message payload before it is
    /// logged and folded into the surface. Structural fields stay untouched.
    fn redactUserMessageData(self: *Self, allocator: Allocator, data: Value) !Value {
        if (self.opts.redactor == null or data != .object) return data;
        const content = data.object.getPtr("content") orelse return data;
        if (content.* != .array) return data;
        for (content.array.items) |*item| {
            if (item.* != .object) continue;
            const text = item.object.getPtr("text") orelse continue;
            if (text.* != .string) continue;
            text.* = .{ .string = try self.redactText(allocator, text.string) };
        }
        return data;
    }

    /// Surface items -> provider messages. Assistant tool calls are rendered as
    /// the native harness's `<tool_call>` text and tool results as the
    /// `[Tool results]` user message, because `ChatMessage` cannot carry an
    /// assistant `tool_calls` array. Every text is redacted: this is the
    /// provider boundary native redacts in `redactMessagesForProvider`.
    fn requestsFromMessages(self: *Self, allocator: Allocator, messages: []const types.Message) ![]providers.ChatMessage {
        var out: std.ArrayListUnmanaged(providers.ChatMessage) = .empty;
        for (messages, 0..) |message, index| {
            switch (message.role) {
                .system => {
                    // Every turn logs its own system message; the provider
                    // gets one, and only when it differs from the last one.
                    const text = try self.redactText(allocator, try textOf(allocator, message.content));
                    if (index > 0 and messages[index - 1].role == .system) {
                        const previous = out.items[out.items.len - 1];
                        if (previous.role == .system and std.mem.eql(u8, previous.content, text)) continue;
                    }
                    try out.append(allocator, .{ .role = .system, .content = text });
                },
                .developer, .user => try out.append(allocator, .{
                    .role = .user,
                    .content = try self.redactText(allocator, try textOf(allocator, message.content)),
                }),
                .assistant => {
                    const text = try self.redactText(allocator, try assistantHistoryText(allocator, message.content));
                    if (text.len == 0) continue;
                    try out.append(allocator, .{ .role = .assistant, .content = text });
                },
                .tool => {
                    const name = toolNameFor(messages, message.tool_call_id);
                    const body = try self.redactText(allocator, try textOf(allocator, message.content));
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

    /// The turn's reply with native's `.on` reasoning quote. Stream mode
    /// already showed the thinking live; `persisted_reply` stays clean either
    /// way because the host derives it from `last_assistant_text`.
    fn composeReply(self: *Self) ![]const u8 {
        if (self.opts.reasoning_mode != .on or self.turn_reasoning.items.len == 0) {
            return self.allocator.dupe(u8, self.turn_text.items);
        }
        const clean = try providers.stripToolCallMarkup(self.allocator, self.turn_reasoning.items);
        defer self.allocator.free(clean);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "Reasoning:\n");
        var lines = std.mem.splitScalar(u8, clean, '\n');
        while (lines.next()) |line| {
            try out.appendSlice(self.allocator, "> ");
            try out.appendSlice(self.allocator, line);
            try out.appendSlice(self.allocator, "\n");
        }
        try out.appendSlice(self.allocator, "\n\n");
        try out.appendSlice(self.allocator, self.turn_text.items);
        return out.toOwnedSlice(self.allocator);
    }

    /// The two `failure.message` values loop.zig uses when the provider call
    /// itself failed (as opposed to a tool or scheduling failure).
    fn isProviderFailureMessage(message: []const u8) bool {
        return std.mem.eql(u8, message, "provider request failed to start") or
            std.mem.eql(u8, message, "assistant stream failed");
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

    /// Push the folded sandbox mode into the file tools, so `/permission` and
    /// resume change enforcement rather than only the prompt sentence.
    fn syncToolSandbox(self: *Self) void {
        if (self.builtins) |builtins| builtins.sandbox = self.sandboxMode();
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
        // junclaw policy parity with `Agent.executeTool` + `ShellTool.execute`:
        // every dsh tool call is inside the autonomy/rate boundary, and bash
        // commands additionally pass the native command-risk policy.
        if (self.opts.policy) |policy| {
            if (security_mod.autonomyDenial(policy)) |reason| return reason;
            if (security_mod.rateLimitDenial(policy)) |reason| return reason;
            // Regression: the gate compared the raw call name with "bash", so
            // `dev__bash` dispatched to the bash handler with no command check.
            // Match the resolved identity instead of the model's spelling.
            const tool_name = registry.resolveName(call.name) orelse call.name;
            if (std.mem.eql(u8, tool_name, generated.bash.name)) {
                switch (args) {
                    .object => |object| {
                        if (object.get("command")) |command| switch (command) {
                            .string => |text| {
                                if (security_mod.commandDenial(policy, text)) |reason| return reason;
                            },
                            else => {},
                        };
                    },
                    else => {},
                }
            }
        }
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
            // Bridged junclaw tools keep junclaw's autonomy/risk policy and
            // never enter the dsh approval gate: dsh reviews only the bash
            // escalation carrying `sandbox_permissions`.
            return null;
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
        if (result.plan_decision) |decision| try self.applyPlanDecision(decision, result.events, result.steer);
        return try arena.dupe(u8, result.text);
    }

    /// The mode the next request assembly uses: a queued selection wins over
    /// the logged mode (dsh reads `pending?.active ?? active`).
    fn planActive(self: *const Self) bool {
        return if (self.plan_session.pending) |pending| pending.active else self.plan_session.state.active;
    }

    /// `/plan` settlement: fold the command lifecycle and mode, then inject the
    /// narration the command decided on and, for `/plan <message>`, steer the
    /// message as a user turn (dsh `agent.steer`). The prompt is republished;
    /// the tool catalog never changes with the mode.
    fn applyPlanDecision(
        self: *Self,
        decision: plan_mod.Decision,
        events: []const types.Event,
        message: ?[]const u8,
    ) !void {
        self.plan_session.applyDecision(decision);
        for (events) |event| try self.plan_session.foldEvent(event);
        if (self.planActive() != self.prompt_plan_active) try self.buildPrompt();
        const loop = if (self.loop) |*value| value else return;
        if (decision.narration) |narration| {
            const id = try self.nextMessageId();
            const json = try planNarrationJson(self.arena.allocator(), id, narration);
            _ = try loop.inject(.{ .id = id, .data = json });
        }
        if (message) |text| {
            const id = try self.nextMessageId();
            const json = try self.userMessageJson(self.arena.allocator(), id, text);
            _ = try loop.steer(.{ .id = id, .data = json });
        }
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

    /// One `user/message` carrying the runtime-context snapshot, with dsh's
    /// `source={kind:"runtime-context", form:"snapshot", sections}` metadata.
    fn runtimeContextMessageJson(allocator: Allocator, id: []const u8, snapshot: context.Snapshot) ![]u8 {
        var writer: Writer.Allocating = .init(allocator);
        defer writer.deinit();
        const w = &writer.writer;
        try w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(snapshot.text, .{}, w);
        try w.writeAll("}],\"source\":{\"kind\":\"runtime-context\"");
        switch (snapshot.source) {
            .cleared => {},
            .snapshot => |sections| {
                try w.writeAll(",\"form\":\"snapshot\",\"sections\":[");
                for (sections, 0..) |section, index| {
                    if (index > 0) try w.writeByte(',');
                    try w.writeAll("{\"name\":");
                    try std.json.Stringify.value(section.name, .{}, w);
                    try w.writeAll(",\"text\":");
                    try std.json.Stringify.value(section.text, .{}, w);
                    try w.writeByte('}');
                }
                try w.writeByte(']');
            },
        }
        try w.writeAll("},\"role\":\"user\",\"id\":");
        try std.json.Stringify.value(id, .{}, w);
        try w.writeByte('}');
        return writer.toOwnedSlice();
    }

    /// One `user/message` carrying the agent-instructions baseline, with dsh's
    /// `source={kind:"agent-instructions", form:"instructions"}` metadata.
    fn instructionsMessageJson(
        allocator: Allocator,
        id: []const u8,
        text: []const u8,
        identity: [32]u8,
        replacement: bool,
    ) ![]u8 {
        var writer: Writer.Allocating = .init(allocator);
        defer writer.deinit();
        const w = &writer.writer;
        try w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(text, .{}, w);
        try w.writeAll("}],\"source\":{\"kind\":\"agent-instructions\",\"form\":\"instructions\"");
        if (!replacement) try w.writeAll(",\"baseline\":true");
        try w.writeAll(",\"baselineIdentity\":\"");
        const identity_hex = identityHex(identity);
        try w.writeAll(&identity_hex);
        try w.writeAll("\"},\"role\":\"user\",\"id\":");
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
        self.syncToolSandbox();
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
        const messages = try self.requestsFromMessages(allocator, input.messages);
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

/// True when the response carries an explicit `<tool_call>` marker. Only these
/// markers trigger the text fallback; ordinary prose about tool calls does not.
fn containsTextToolCall(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "<tool_call>") != null;
}

/// Convert the dispatcher's parsed text calls into provider calls. The id is
/// stable for a given response (turn/step) and its position in the batch, so a
/// replay or resume maps the same call to the same id. `first_index` keeps ids
/// unique when a streamed response is parsed one block at a time.
fn providerCallsFromText(
    allocator: Allocator,
    position: loop_mod.Position,
    parsed: []const dispatcher.ParsedToolCall,
    first_index: usize,
) ![]const providers.ToolCall {
    const calls = try allocator.alloc(providers.ToolCall, parsed.len);
    for (parsed, 0..) |call, index| {
        calls[index] = .{
            .id = try std.fmt.allocPrint(
                allocator,
                "text-call-{d}-{d}-{d}",
                .{ position.turn, position.step, first_index + index + 1 },
            ),
            .name = call.name,
            .arguments = call.arguments_json,
        };
    }
    return calls;
}

/// Lowercase hex of an instruction-baseline identity, as dsh stores it in
/// `source.baselineIdentity`.
fn identityHex(identity: [32]u8) [64]u8 {
    const digits = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (identity, 0..) |byte, index| {
        out[index * 2] = digits[byte >> 4];
        out[index * 2 + 1] = digits[byte & 0x0f];
    }
    return out;
}

fn identityFromHex(text: []const u8) ?[32]u8 {
    if (text.len != 64) return null;
    var out: [32]u8 = undefined;
    for (0..32) |index| {
        const hi = std.fmt.charToDigit(text[index * 2], 16) catch return null;
        const lo = std.fmt.charToDigit(text[index * 2 + 1], 16) catch return null;
        out[index] = (hi << 4) | lo;
    }
    return out;
}

/// `kind` of a raw dsh message `source` object, or "" when absent.
fn sourceKindValue(source: Value) []const u8 {
    const object = switch (source) {
        .object => |value| value,
        else => return "",
    };
    return switch (object.get("kind") orelse return "") {
        .string => |value| value,
        else => "",
    };
}

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

/// Store role -> dsh role, mirroring the native restore mapping: assistant and
/// system keep their role, everything else becomes user text. Runtime commands
/// are host directives, not conversation, and are not imported.
fn seedRole(role: []const u8) ?types.MessageRole {
    if (memory_mod.isRuntimeCommandRole(role)) return null;
    if (std.mem.eql(u8, role, "assistant")) return .assistant;
    if (std.mem.eql(u8, role, "system")) return .system;
    return .user;
}

fn seedableCount(entries: []const memory_mod.MessageEntry) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (seedRole(entry.role) == null) continue;
        if (entry.content.len == 0) continue;
        if (!std.unicode.utf8ValidateSlice(entry.content)) continue;
        count += 1;
    }
    return count;
}

/// The marker that closes the inherited prefix; a seeded log without it was
/// interrupted before the import finished.
fn hasEndSeedMarker(events: []const types.Event) bool {
    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, "session/end-seed")) return true;
    }
    return false;
}

/// One message event per imported store row; before the marker the log holds
/// nothing else, so this is the resume cursor.
fn seededMessageCount(events: []const types.Event) usize {
    var count: usize = 0;
    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, "user/message") or
            std.mem.eql(u8, event.event_type, "assistant/message") or
            std.mem.eql(u8, event.event_type, "system/message"))
        {
            count += 1;
        }
    }
    return count;
}

fn concatEvents(allocator: std.mem.Allocator, first: []const types.Event, second: []const types.Event) ![]types.Event {
    const all = try allocator.alloc(types.Event, first.len + second.len);
    @memcpy(all[0..first.len], first);
    @memcpy(all[first.len..], second);
    return all;
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

/// Temp dsh home + mapping dir + workspace for seed/restore tests.
const SeedTestEnv = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    dsh_home: []u8,
    workspace: []u8,
    session_dir: []u8,

    fn init() !SeedTestEnv {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
        errdefer allocator.free(root);
        const dsh_home = try std.fs.path.join(allocator, &.{ root, "dsh-home" });
        errdefer allocator.free(dsh_home);
        try fs_compat.makePath(dsh_home);
        const workspace = try std.fs.path.join(allocator, &.{ root, "workspace" });
        errdefer allocator.free(workspace);
        try fs_compat.makePath(workspace);
        const session_dir = try std.fs.path.join(allocator, &.{ root, "dsh-sessions" });
        errdefer allocator.free(session_dir);
        try fs_compat.makePath(session_dir);
        return .{
            .tmp = tmp,
            .root = root,
            .dsh_home = dsh_home,
            .workspace = workspace,
            .session_dir = session_dir,
        };
    }

    fn deinit(self: *SeedTestEnv) void {
        const allocator = std.testing.allocator;
        allocator.free(self.root);
        allocator.free(self.dsh_home);
        allocator.free(self.workspace);
        allocator.free(self.session_dir);
        self.tmp.cleanup();
    }

    fn engine(self: *SeedTestEnv, session_key: []const u8) !DshNativeHarness {
        return DshNativeHarness.init(std.testing.allocator, .{
            .session_key = session_key,
            .dsh_home = self.dsh_home,
            .session_dir = self.session_dir,
            .workspace_dir = self.workspace,
            .provider = undefined,
            .provider_name = "test-provider",
            .model = "test-model",
        });
    }
};

fn seedEventText(event: types.Event) ![]const u8 {
    const object = switch (event.data) {
        .object => |value| value,
        else => return error.InvalidMessage,
    };
    const message_value = if (std.mem.eql(u8, event.event_type, "user/message"))
        event.data
    else
        object.get("message") orelse return error.InvalidMessage;
    const message = switch (message_value) {
        .object => |value| value,
        else => return error.InvalidMessage,
    };
    const content = switch (message.get("content") orelse return error.InvalidMessage) {
        .array => |value| value,
        else => return error.InvalidMessage,
    };
    if (content.items.len == 0) return error.InvalidMessage;
    const block = switch (content.items[0]) {
        .object => |value| value,
        else => return error.InvalidMessage,
    };
    return switch (block.get("text") orelse return error.InvalidMessage) {
        .string => |value| value,
        else => return error.InvalidMessage,
    };
}

test "dsh-native harness: first open imports store history as a seeded prefix" {
    const allocator = std.testing.allocator;
    var env = try SeedTestEnv.init();
    defer env.deinit();
    var engine = try env.engine("seed-order");
    defer engine.deinit(allocator);

    const entries = [_]memory_mod.MessageEntry{
        .{ .role = "user", .content = "first question" },
        .{ .role = "assistant", .content = "first answer" },
        .{ .role = "user", .content = "second question" },
        .{ .role = "assistant", .content = "second answer" },
    };
    try engine.harness().restore(.{ .messages = &entries });

    var read = try session_log.readLog(allocator, engine.log.?.path);
    defer read.deinit();
    try std.testing.expect(read.header.is_seeded);
    try std.testing.expectEqual(@as(usize, 8), read.events.len);
    const expected_types = [_][]const u8{
        "permission/preset",
        "sandbox/mode",
        "approval/policy",
        "user/message",
        "assistant/message",
        "user/message",
        "assistant/message",
        "session/end-seed",
    };
    for (read.events, expected_types) |event, expected| {
        try std.testing.expectEqualStrings(expected, event.event_type);
    }
    try std.testing.expectEqualStrings("first question", try seedEventText(read.events[3]));
    try std.testing.expectEqualStrings("first answer", try seedEventText(read.events[4]));
    try std.testing.expectEqualStrings("second question", try seedEventText(read.events[5]));
    try std.testing.expectEqualStrings("second answer", try seedEventText(read.events[6]));
    const marker = switch (read.events[7].data) {
        .object => |value| value,
        else => return error.InvalidMessage,
    };
    try std.testing.expect(marker.get("inherited").?.bool);

    // The live surface is folded from the seed too: the first turn must see
    // the imported history, not only a JSONL a later restore would read.
    try std.testing.expectEqual(@as(usize, 4), engine.messages.items.len);
    try std.testing.expectEqualStrings("first question", engine.messages.items[0].content[0].text);
    try std.testing.expectEqualStrings("second answer", engine.messages.items[3].content[0].text);
}

test "dsh-native harness: reopening a seeded session never imports twice" {
    const allocator = std.testing.allocator;
    var env = try SeedTestEnv.init();
    defer env.deinit();

    const entries = [_]memory_mod.MessageEntry{
        .{ .role = "user", .content = "keep me" },
        .{ .role = "assistant", .content = "kept" },
    };

    var first = try env.engine("seed-idempotent");
    try first.harness().restore(.{ .messages = &entries });
    const first_id = try allocator.dupe(u8, first.session_id);
    defer allocator.free(first_id);
    const log_path = try allocator.dupe(u8, first.log.?.path);
    defer allocator.free(log_path);
    first.deinit(allocator);

    var second = try env.engine("seed-idempotent");
    defer second.deinit(allocator);
    try second.harness().restore(.{ .messages = &entries });
    try std.testing.expectEqualStrings(first_id, second.session_id);

    var read = try session_log.readLog(allocator, log_path);
    defer read.deinit();
    try std.testing.expectEqual(@as(usize, 6), read.events.len);
    try std.testing.expectEqualStrings("keep me", try seedEventText(read.events[3]));
    try std.testing.expectEqualStrings("kept", try seedEventText(read.events[4]));

    // A second restore in the same process resumes the same log.
    try second.harness().restore(.{ .messages = &entries });
    var reread = try session_log.readLog(allocator, log_path);
    defer reread.deinit();
    try std.testing.expectEqual(@as(usize, 6), reread.events.len);
}

test "dsh-native harness: unusable store rows are skipped and empty history is not seeded" {
    const allocator = std.testing.allocator;
    var env = try SeedTestEnv.init();
    defer env.deinit();

    var engine = try env.engine("seed-bad-rows");
    defer engine.deinit(allocator);
    const entries = [_]memory_mod.MessageEntry{
        .{ .role = memory_mod.RUNTIME_COMMAND_ROLE, .content = "/model test-model" },
        .{ .role = "user", .content = "" },
        .{ .role = "user", .content = "\xff\xfe" },
        .{ .role = "user", .content = "kept" },
    };
    try engine.harness().restore(.{ .messages = &entries });

    var read = try session_log.readLog(allocator, engine.log.?.path);
    defer read.deinit();
    try std.testing.expect(read.header.is_seeded);
    try std.testing.expectEqual(@as(usize, 5), read.events.len);
    try std.testing.expectEqualStrings("user/message", read.events[3].event_type);
    try std.testing.expectEqualStrings("kept", try seedEventText(read.events[3]));
    try std.testing.expectEqualStrings("session/end-seed", read.events[4].event_type);

    // Empty history opens an ordinary, unseeded session.
    var empty = try env.engine("seed-empty");
    defer empty.deinit(allocator);
    try empty.harness().restore(.{ .messages = &.{} });
    var empty_read = try session_log.readLog(allocator, empty.log.?.path);
    defer empty_read.deinit();
    try std.testing.expect(!empty_read.header.is_seeded);
    // Only the three pinned permission facts; no imported messages.
    try std.testing.expectEqual(@as(usize, 3), empty_read.events.len);
    try std.testing.expect(empty.messages.items.len == 0);
}

test "dsh-native harness: a torn tail on the seeded log resumes intact" {
    const allocator = std.testing.allocator;
    var env = try SeedTestEnv.init();
    defer env.deinit();

    const entries = [_]memory_mod.MessageEntry{
        .{ .role = "user", .content = "before the crash" },
        .{ .role = "assistant", .content = "answer before the crash" },
    };

    var first = try env.engine("seed-torn");
    try first.harness().restore(.{ .messages = &entries });
    const log_path = try allocator.dupe(u8, first.log.?.path);
    defer allocator.free(log_path);
    first.deinit(allocator);

    // A crash between write and newline leaves an uncommitted final record.
    const file = try fs_compat.openPath(log_path, .{ .mode = .read_write });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll("{\"type\":\"user/message\",\"seq\":");

    var resumed = try env.engine("seed-torn");
    defer resumed.deinit(allocator);
    try resumed.harness().restore(.{ .messages = &entries });

    var read = try session_log.readLog(allocator, log_path);
    defer read.deinit();
    try std.testing.expect(read.torn_truncate_to == null);
    try std.testing.expectEqual(@as(usize, 6), read.events.len);
    try std.testing.expectEqualStrings("before the crash", try seedEventText(read.events[3]));
    try std.testing.expectEqualStrings("answer before the crash", try seedEventText(read.events[4]));
    try std.testing.expectEqual(@as(usize, 2), resumed.messages.items.len);
}

test "dsh-native harness: a seeded log without end-seed resumes the import" {
    // Regression: a crash between the is_seeded header and the end-seed marker
    // left a valid log that replayed only the imported prefix and never
    // appended the remaining history.
    const allocator = std.testing.allocator;
    var env = try SeedTestEnv.init();
    defer env.deinit();

    const id = "half-seed";
    var seed_arena = std.heap.ArenaAllocator.init(allocator);
    defer seed_arena.deinit();
    var interrupted = try session_store.createLog(allocator, env.dsh_home, env.workspace, id, .{
        .id = id,
        .created_at = 0,
        .cwd = env.workspace,
        .is_seeded = true,
        .delegation_depth = 0,
    });
    const first = types.Message{
        .id = "msg-1",
        .role = .user,
        .content = &.{.{ .text = "first question" }},
        .source = .user,
    };
    _ = try interrupted.append("user/message", try DshNativeHarness.messageValue(seed_arena.allocator(), first), .{ .surface_op = .append });
    interrupted.close();

    const entries = [_]memory_mod.MessageEntry{
        .{ .role = "user", .content = "first question" },
        .{ .role = "assistant", .content = "first answer" },
        .{ .role = "user", .content = "second question" },
    };
    var engine = try env.engine("seed-interrupted");
    defer engine.deinit(allocator);
    try engine.harness().restore(.{ .dsh_session_id = id, .messages = &entries });

    var read = try session_log.readLog(allocator, engine.log.?.path);
    defer read.deinit();
    try std.testing.expect(read.header.is_seeded);
    const expected_types = [_][]const u8{
        "user/message",
        "assistant/message",
        "user/message",
        "session/end-seed",
    };
    try std.testing.expectEqual(expected_types.len, read.events.len);
    for (read.events, expected_types) |event, expected| {
        try std.testing.expectEqualStrings(expected, event.event_type);
    }
    // The already-imported row is not duplicated.
    try std.testing.expectEqualStrings("first question", try seedEventText(read.events[0]));
    try std.testing.expectEqualStrings("first answer", try seedEventText(read.events[1]));
    try std.testing.expectEqualStrings("second question", try seedEventText(read.events[2]));
    try std.testing.expectEqual(@as(usize, 3), engine.messages.items.len);
    try std.testing.expectEqualStrings("second question", switch (engine.messages.items[2].content[0]) {
        .text => |text| text,
        else => return error.InvalidSeedMessage,
    });
}
