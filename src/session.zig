//! Session Manager — persistent in-process Agent sessions.
//!
//! Replaces subprocess spawning with reusable Agent instances keyed by
//! session_key (e.g. "telegram:chat123"). Each session maintains its own
//! conversation history across turns.
//!
//! Thread safety: SessionManager.mutex guards the sessions map (short hold),
//! Session.mutex serializes turn() per session (may be long). Different
//! sessions are processed in parallel.

const std = @import("std");
const std_compat = @import("compat");
const Allocator = std.mem.Allocator;
const Config = @import("config.zig").Config;
const fs_compat = @import("fs_compat.zig");
const agent_routing = @import("agent_routing.zig");
const model_refs = @import("model_refs.zig");
const agent_mod = @import("agent/root.zig");
const turn_persistence = @import("agent/turn_persistence.zig");
const session_reset = @import("session_reset.zig");
const Agent = agent_mod.Agent;
const NamedAgentConfig = @import("config_types.zig").NamedAgentConfig;
const ConversationContext = @import("agent/prompt.zig").ConversationContext;
const config_types = @import("config_types.zig");
const providers = @import("providers/root.zig");
const Provider = providers.Provider;
const memory_mod = @import("memory/root.zig");
const Memory = memory_mod.Memory;
const governance = @import("governance.zig");
const redaction = @import("redaction.zig");
const util = @import("util.zig");
const onboard = @import("onboard.zig");
const bootstrap_mod = @import("bootstrap/root.zig");
const observability = @import("observability.zig");
const inbound_router = @import("inbound_router.zig");
const control_plane = @import("control_plane.zig");
const Observer = observability.Observer;
const tools_mod = @import("tools/root.zig");
const cron_mod = @import("cron.zig");
const cron_add_mod = @import("tools/cron_add.zig");
const Tool = tools_mod.Tool;
const security = @import("security/policy.zig");
const SecurityPolicy = security.SecurityPolicy;
const streaming = @import("streaming.zig");
const outbound_mod = @import("outbound.zig");
const thread_stacks = @import("thread_stacks.zig");
const cost_mod = @import("cost.zig");
const harness_port = @import("harness/port.zig");
const native_harness = @import("harness/native.zig");
/// The in-process dsh engine (`agent.harness = "dsh"`, legacy alias
/// `"dsh-native"`). No build flag gates it, so the import is unconditional.
const dsh_native_mod = @import("harness/dsh_native/harness.zig");
const dsh_bridge = @import("harness/dsh_native/tools/bridge.zig");
const dsh_native_session_log = @import("harness/dsh_native/session_log.zig");
const dsh_native_types = @import("harness/dsh_native/types.zig");
const build_options = @import("build_options");
const dsh_enabled = build_options.enable_harness_dsh;
const dsh_harness_mod = if (dsh_enabled) @import("harness/dsh/harness.zig") else struct {
    pub const DshHarness = void;
    pub const DshEngine = void;
};

/// Per-session dsh handle. The sidecar and the key→session table live in the
/// process-wide `DshEngine`; this only owns the handle's key copy.
const DshState = if (dsh_enabled) struct {
    harness: dsh_harness_mod.DshHarness,

    fn deinit(self: *@This()) void {
        self.harness.deinit();
    }
} else struct {
    fn deinit(self: *@This()) void {
        _ = self;
    }
};

/// The process-wide dsh engine plus the option strings its `Options` borrow.
/// Created lazily by the manager; the sidecar itself boots on the first turn.
const DshEngineState = if (dsh_enabled) struct {
    allocator: Allocator,
    engine: *dsh_harness_mod.DshEngine,
    dsh_home: []u8,
    session_base: []u8,
    /// Owned strings backing `engine.opts.sidecar.profile` (null when the
    /// config has no usable default model, so the profile is left alone).
    profile_base_url: ?[]u8 = null,
    profile_model: ?[]u8 = null,
    profile_models: ?[][]const u8 = null,

    fn deinit(self: *@This()) void {
        self.engine.deinit();
        self.allocator.destroy(self.engine);
        self.allocator.free(self.dsh_home);
        self.allocator.free(self.session_base);
        if (self.profile_base_url) |value| self.allocator.free(value);
        if (self.profile_model) |value| self.allocator.free(value);
        if (self.profile_models) |value| self.allocator.free(value);
    }
} else struct {
    fn deinit(self: *@This()) void {
        _ = self;
    }
};

/// Dsh builds carry the lazily created engine; a default build compiles the
/// slot to an empty struct, so the native path is unchanged.
const DshEngineSlot = if (dsh_enabled) struct {
    mutex: std_compat.sync.Mutex = .{},
    state: ?DshEngineState = null,
} else struct {};

/// Per-session in-process dsh engine. The options borrow the session's
/// provider/model/workspace and the owned path strings here; the harness must
/// outlive `init` at this stable address.
const DshNativeState = struct {
    harness: dsh_native_mod.DshNativeHarness,
    dsh_home: []u8,
    session_dir: []u8,
    /// Owned because `/model` frees `agent.model_name`; the harness borrows
    /// this slice until `syncCallConfig` swaps in the next owned copy.
    model: []u8,
    /// The engine's cumulative `TurnResult.total_tokens` after the last turn.
    /// The counter restarts at 0 on /new, so `/new` resets this too.
    reported_total_tokens: u64 = 0,
    /// `Event.usage` count. A turn that emitted none falls back to the
    /// `total_tokens` delta, so the ledger never double counts.
    usage_events: u64 = 0,
    /// Owned descriptors for the session's bridged junclaw tools (the string
    /// slices inside are borrowed from the live tools).
    host_tools: []const dsh_bridge.HostTool = &.{},

    fn init(allocator: Allocator, config: *const Config, session: *Session) !DshNativeState {
        const config_dir = std_compat.fs.path.dirname(config.config_path) orelse ".";
        // Defaults mirror the sidecar's layout so both engines find the same
        // `dsh-sessions/{hash}.json` mapping for a key.
        const dsh_home = if (config.agent.dsh_home) |path|
            try allocator.dupe(u8, path)
        else
            try std_compat.fs.path.join(allocator, &.{ config_dir, ".dsh" });
        errdefer allocator.free(dsh_home);
        const session_dir = if (config.agent.dsh_session_dir) |path|
            try allocator.dupe(u8, path)
        else
            try std_compat.fs.path.join(allocator, &.{ config_dir, "dsh-sessions" });
        errdefer allocator.free(session_dir);
        const model = try allocator.dupe(u8, session.agent.model_name);
        errdefer allocator.free(model);
        // The session's live junclaw tool list, bridged for the model. Names,
        // descriptions and schemas are the tools' own strings (copied into the
        // harness arena during init), so they never reach the model rewritten.
        const host_tools = try allocator.alloc(dsh_bridge.HostTool, session.agent.tools.len);
        errdefer allocator.free(host_tools);
        for (session.agent.tools, 0..) |tool, index| {
            const spec = tool.spec();
            host_tools[index] = .{
                .name = spec.name,
                .description = spec.description,
                .input_schema_json = spec.parameters_json,
                .concurrency_safe = dsh_bridge.isReadOnlyHostTool(spec.name),
            };
        }

        var harness = try dsh_native_mod.DshNativeHarness.init(allocator, .{
            .session_key = session.session_key,
            .dsh_home = dsh_home,
            .session_dir = session_dir,
            .workspace_dir = session.agent.workspace_dir,
            .provider = session.agent.provider,
            .provider_name = session.agent.provider.getName(),
            .model = model,
            .reasoning_effort = session.agent.reasoning_effort,
            .reasoning_mode = session.agent.reasoning_mode,
            .max_tokens = session.agent.max_tokens_override,
            .persona = config.agent.dsh_persona orelse "",
            .timezone = config.agent.timezone,
            .bootstrap_provider = session.agent.bootstrap,
            .identity_config = config.identity,
            .approval_policy = config.agent.dsh_approval_policy,
            .sandbox = config.agent.dsh_sandbox,
            // The dsh tools must never be wider than the native ones: same
            // autonomy/rate gate, workspace/allowed_paths boundary and bash
            // command-risk policy.
            .policy = session.agent.policy,
            .allowed_paths = session.agent.allowed_paths,
            .max_parallel_tools = config.agent.dsh_max_parallel_tools,
            .on_corrupt = config.agent.dsh_on_corrupt,
            .context_window = config.agent.dsh_compaction_context_window,
            .compaction_threshold_ratio = config.agent.dsh_compaction_threshold_ratio,
            .compaction_retain_ratio = config.agent.dsh_compaction_retain_ratio,
            .compaction_headroom_tokens = config.agent.dsh_compaction_headroom_tokens,
            .question_timeout_s = config.agent.dsh_question_timeout,
            .temperature = session.agent.temperature,
            .host_tools = host_tools,
            .host_executor = .{ .context = @ptrCast(&session.agent), .call = hostToolCall },
        });
        errdefer harness.deinit(allocator);
        return .{
            .harness = harness,
            .dsh_home = dsh_home,
            .session_dir = session_dir,
            .model = model,
            .host_tools = host_tools,
        };
    }

    fn deinit(self: *DshNativeState, allocator: Allocator) void {
        self.harness.deinit(allocator);
        if (self.host_tools.len != 0) allocator.free(self.host_tools);
        allocator.free(self.dsh_home);
        allocator.free(self.session_dir);
        allocator.free(self.model);
    }

    /// `/model`, `/think` and `/reasoning` mutate the native agent; mirror the
    /// live selection before the next engine turn so the engine's request
    /// header and provider calls carry it (the `/model` shortcut is gone).
    fn syncCallConfig(self: *DshNativeState, allocator: Allocator, agent: *Agent) !void {
        if (!std.mem.eql(u8, self.model, agent.model_name)) {
            const next = try allocator.dupe(u8, agent.model_name);
            // Point the engine at the new copy before releasing the old one.
            self.harness.setCallConfig(next, agent.reasoning_effort, agent.reasoning_mode);
            allocator.free(self.model);
            self.model = next;
            return;
        }
        self.harness.setCallConfig(self.model, agent.reasoning_effort, agent.reasoning_mode);
    }
};

/// Bridge executor: arguments are re-serialized because the junclaw executor
/// takes raw JSON (the same shape the native loop passes).
fn hostToolCall(
    context: *anyopaque,
    allocator: Allocator,
    name: []const u8,
    args: std.json.Value,
) anyerror!dsh_bridge.HostResult {
    const agent: *Agent = @ptrCast(@alignCast(context));
    const args_json = try std.json.Stringify.valueAlloc(allocator, args, .{});
    const outcome = agent.executeHostTool(allocator, name, args_json);
    return .{ .success = outcome.success, .output = outcome.output };
}

/// Test seam: point session-created dsh harnesses at an in-process mock
/// instead of spawning a sidecar. Production never sets it.
var dsh_test_boot_url: ?[]const u8 = null;

/// Log the ignored `harness: "dsh-sidecar"` selection once per process.
var warned_dsh_ignored = std.atomic.Value(bool).init(false);

fn warnDshIgnored() void {
    if (!warned_dsh_ignored.swap(true, .acq_rel)) {
        log.warn("agent.harness=\"dsh-sidecar\" ignored: this build has no dsh harness (-Dharness_dsh=true); using native", .{});
    }
}

/// Build this session's lightweight dsh handle. The shared engine is created
/// on first use, which only allocates and fills fields; the sidecar boots
/// later, on the first dsh turn, outside the session-table lock.
fn startDshHarness(manager: *SessionManager, session_key: []const u8, agent: *Agent) !DshState {
    const engine = try manager.ensureDshEngine();
    var harness = try dsh_harness_mod.DshHarness.init(engine, session_key);
    // The shared engine outlives sessions; the display mode is per key.
    harness.setCallConfig(agent.model_name, agent.reasoning_effort, agent.reasoning_mode);
    return .{ .harness = harness };
}

const log = std.log.scoped(.session);
const MESSAGE_LOG_MAX_BYTES: usize = 4096;
const MAX_POST_TURN_INJECTION_DRAINS: u32 = 8;
/// Appended to a reply when a follow-up turn fails. The message is not
/// re-queued: a later turn would see it after newer messages, and an idle
/// eviction or restart would drop it anyway, so the sender is asked to resend.
const FOLLOW_UP_FAILED_NOTICE: []const u8 = "It could not be processed; please resend it.";
/// Appended once when a /stop ends the turn and pending steered messages are
/// dropped instead of being run as follow-up turns.
const STOP_DISCARDED_NOTICE: []const u8 = "[Pending message(s) discarded by /stop. Please resend.]";
/// Appended once when this turn cleared the session (/new, /reset, /clear) and
/// pending steered messages are dropped instead of leaking into the fresh
/// session as follow-up turns.
const RESET_DISCARDED_NOTICE: []const u8 = "[Pending message(s) discarded by the session reset. Please resend.]";
const TOKEN_USAGE_LEDGER_FILENAME = "llm_token_usage.jsonl";
const NS_PER_SEC: i128 = std.time.ns_per_s;
const RUNTIME_COMMAND_ROLE = memory_mod.RUNTIME_COMMAND_ROLE;
const CLAIM_STATE_FILENAME = "identity_claims.json";
const CLAIM_STATE_VERSION: u32 = 1;

const ClaimDirectContext = struct {
    channel: []const u8,
    account_id: []const u8,
    peer_id: []const u8,
};

const VerifiedBinding = struct {
    canonical_user_id: []u8,
    verified_at: i64,
};

const ClaimAttempt = struct {
    failures: u32 = 0,
    locked_until: i64 = 0,
};

const ClaimToken = struct {
    expires_at: i64,
    canonical_user_id: []const u8,
    nonce: []const u8,
    signature_hex: []const u8,
};

const ClaimStateSnapshot = struct {
    generation: u64,
    content: []u8,
};

fn messageLogPreview(text: []const u8) struct { slice: []const u8, truncated: bool } {
    const preview = util.previewUtf8(text, MESSAGE_LOG_MAX_BYTES);
    return .{ .slice = preview.slice, .truncated = preview.truncated };
}

const SafeMessageLogPreview = struct {
    owned: ?[]u8 = null,
    slice: []const u8,
    truncated: bool,

    fn deinit(self: *SafeMessageLogPreview, allocator: Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
    }
};

fn safeMessageLogPreview(allocator: Allocator, text: []const u8) SafeMessageLogPreview {
    var r = redaction.Redactor.init(allocator, .{});
    defer r.deinit();
    const safe_text = r.redact(allocator, text) catch return .{
        .slice = "[redaction failed]",
        .truncated = false,
    };
    const preview = messageLogPreview(safe_text);
    return .{
        .owned = safe_text,
        .slice = preview.slice,
        .truncated = preview.truncated,
    };
}

test "messageLogPreview keeps UTF-8 intact when truncating" {
    const prefix = "a" ** (MESSAGE_LOG_MAX_BYTES - 1);
    const preview = messageLogPreview(prefix ++ "\xd0\x99tail");
    try std.testing.expectEqualStrings(prefix, preview.slice);
    try std.testing.expect(preview.truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(preview.slice));
}

test "safeMessageLogPreview redacts PII" {
    var preview = safeMessageLogPreview(testing.allocator, "hello user@example.com");
    defer preview.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, preview.slice, "user@example.com") == null);
    try testing.expect(std.mem.indexOf(u8, preview.slice, "[EMAIL_1]") != null);
}

fn estimateRestoredSessionTokens(entries: []const memory_mod.MessageEntry) u64 {
    var total: u64 = 0;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.role, "assistant")) continue;
        total += agent_mod.estimate_text_tokens(entry.content);
    }
    return total;
}

/// Most recent `max_history_messages` stored entries.
///
/// `persistTurn` appends user+assistant every turn and never prunes the stored
/// session, so a long-lived session accumulates rows without bound. Restoring
/// the entire store re-inflated the per-request context on every session
/// (re)creation (restart or cache eviction), silently defeating
/// `max_history_messages` — compaction/trim only bound the in-memory history.
/// Bound the restored window to the same limit `trimHistory` enforces.
fn recentHistoryWindow(
    entries: []const memory_mod.MessageEntry,
    max_history_messages: u32,
) []const memory_mod.MessageEntry {
    const max: usize = if (max_history_messages == 0) 1 else max_history_messages;
    if (entries.len <= max) return entries;
    return entries[entries.len - max ..];
}

/// Replay from the newest compaction summary. Rows before it were already
/// dropped from the live history by compaction, so replaying them would
/// resurrect context the summary replaced.
fn dropRowsBeforeLastCompactionSummary(entries: []const memory_mod.MessageEntry) []const memory_mod.MessageEntry {
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, entries[i].role, "assistant") and
            std.mem.startsWith(u8, entries[i].content, agent_mod.compaction.COMPACTION_SUMMARY_PREFIX))
        {
            return entries[i..];
        }
    }
    return entries;
}

fn restorePersistedSessionState(session: *Session, entries: []const memory_mod.MessageEntry) void {
    for (entries) |entry| {
        if (memory_mod.isRuntimeCommandRole(entry.role)) {
            const maybe_response = session.handleLocalCommand(entry.content) catch null;
            if (maybe_response) |response| session.agent.allocator.free(response);
            continue;
        }

        const role: providers.Role = if (std.mem.eql(u8, entry.role, "assistant"))
            .assistant
        else if (std.mem.eql(u8, entry.role, "system"))
            .system
        else
            .user;

        const content = session.agent.allocator.dupe(u8, entry.content) catch continue;
        session.agent.history.append(session.agent.allocator, .{
            .role = role,
            .content = content,
        }) catch {
            session.agent.allocator.free(content);
            continue;
        };
    }
}

fn sessionAgentId(session_key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, session_key, "agent:")) return null;
    const rest = session_key["agent:".len..];
    const sep = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    if (sep == 0) return null;
    return rest[0..sep];
}

fn findProfileForSessionKey(config: *const Config, session_key: []const u8) ?config_types.NamedAgentConfig {
    const normalized_agent_id = sessionAgentId(session_key) orelse return null;
    // `agent:main:*` is the reserved root session namespace and must always
    // resolve to the top-level config rather than a named subagent.
    if (std.mem.eql(u8, normalized_agent_id, "main")) return null;

    for (config.agents) |agent_profile| {
        var norm_buf: [64]u8 = undefined;
        const normalized_name = agent_routing.normalizeId(&norm_buf, agent_profile.name);
        if (std.mem.eql(u8, normalized_name, normalized_agent_id)) return agent_profile;
    }

    return null;
}

const SessionProviderContext = struct {
    provider: ?Provider = null,
    holder: ?providers.ProviderHolder = null,
    owned_api_key: ?[]u8 = null,

    fn deinit(self: *SessionProviderContext, allocator: Allocator) void {
        if (self.holder) |*holder| {
            holder.deinit();
            self.holder = null;
        }
        if (self.owned_api_key) |key| {
            allocator.free(key);
            self.owned_api_key = null;
        }
    }
};

/// Channel identity of a message that was steered into a running turn.
/// Borrowed by the router at call time; the Session stores owned copies.
pub const ConsumedRef = struct {
    channel: []const u8,
    account_id: ?[]const u8 = null,
    target: []const u8,
    message_id: []const u8,
    /// Internal ownership and reaction ordering for refs deposited by a transport.
    reaction_state: ?*SteerReactionState = null,
};

/// Terminal outcome applied to a steered message's lifecycle reaction.
pub const SteerOutcome = enum { done, failed };

/// Transport hook for a steered message. The context must outlive the active
/// turn, including an accepted request whose completion outlasts that turn.
pub const SteerReactionSink = struct {
    ctx: *anyopaque,
    finalize: *const fn (ctx: *anyopaque, ref: ConsumedRef, outcome: SteerOutcome) void,
    /// Runs outside the manager/injection locks. A racing terminal reaction is
    /// deferred until this callback returns without blocking the consuming turn.
    accepted: ?*const fn (ctx: *anyopaque, ref: ConsumedRef) void = null,
};

const SteerReactionState = struct {
    mutex: std_compat.sync.Mutex = .{},
    references: usize = 1,
    accepted_done: bool,
    pending_outcome: ?SteerOutcome = null,
    sink: SteerReactionSink,
};

/// Reserve a separate owner for accepted before publishing the ref to a turn.
fn reserveSteerAcknowledgement(ref: ?ConsumedRef) ?ConsumedRef {
    const r = ref orelse return null;
    const state = r.reaction_state orelse return null;
    if (state.sink.accepted == null) return null;
    state.mutex.lock();
    defer state.mutex.unlock();
    state.references += 1;
    return r;
}

fn acknowledgeSteerRef(allocator: Allocator, ref: ?ConsumedRef) void {
    const r = ref orelse return;
    defer freeConsumedRef(allocator, r);
    const state = r.reaction_state.?;
    state.sink.accepted.?(state.sink.ctx, r);
    state.mutex.lock();
    state.accepted_done = true;
    const outcome = state.pending_outcome;
    state.mutex.unlock();
    if (outcome) |terminal| state.sink.finalize(state.sink.ctx, r, terminal);
}

fn dupeConsumedRef(allocator: Allocator, ref: ConsumedRef, sink: ?SteerReactionSink) !ConsumedRef {
    const channel = try allocator.dupe(u8, ref.channel);
    errdefer allocator.free(channel);
    const account_id = if (ref.account_id) |aid| try allocator.dupe(u8, aid) else null;
    errdefer if (account_id) |aid| allocator.free(aid);
    const target = try allocator.dupe(u8, ref.target);
    errdefer allocator.free(target);
    const message_id = try allocator.dupe(u8, ref.message_id);
    errdefer allocator.free(message_id);
    const state = if (sink) |origin| blk: {
        const owned = try allocator.create(SteerReactionState);
        owned.* = .{ .accepted_done = origin.accepted == null, .sink = origin };
        break :blk owned;
    } else null;
    return .{
        .channel = channel,
        .account_id = account_id,
        .target = target,
        .message_id = message_id,
        .reaction_state = state,
    };
}

fn freeConsumedRef(allocator: Allocator, ref: ConsumedRef) void {
    if (ref.reaction_state) |state| {
        state.mutex.lock();
        state.references -= 1;
        const last = state.references == 0;
        state.mutex.unlock();
        if (!last) return;
        allocator.destroy(state);
    }
    allocator.free(ref.channel);
    if (ref.account_id) |aid| allocator.free(aid);
    allocator.free(ref.target);
    allocator.free(ref.message_id);
}

fn freeConsumedRefs(allocator: Allocator, refs: *std.ArrayListUnmanaged(ConsumedRef)) void {
    for (refs.items) |ref| freeConsumedRef(allocator, ref);
    refs.deinit(allocator);
    refs.* = .empty;
}

/// Deliver every collected ref to the transport sink, then free them.
fn finalizeSteerRefs(
    sink: ?SteerReactionSink,
    allocator: Allocator,
    refs: *std.ArrayListUnmanaged(ConsumedRef),
    outcome: SteerOutcome,
) void {
    for (refs.items) |ref| {
        if (ref.reaction_state) |state| {
            state.mutex.lock();
            const ready = state.accepted_done;
            if (!ready) state.pending_outcome = outcome;
            state.mutex.unlock();
            if (ready) state.sink.finalize(state.sink.ctx, ref, outcome);
        } else if (sink) |s| {
            s.finalize(s.ctx, ref, outcome);
        }
    }
    freeConsumedRefs(allocator, refs);
}

// ═══════════════════════════════════════════════════════════════════════════
// Session
// ═══════════════════════════════════════════════════════════════════════════

pub const Session = struct {
    agent: Agent,
    /// The turn port for this session. Wraps `agent` for now; the host reaches
    /// `agent` directly through `nativeAgent()` until every call site moves.
    harness: native_harness.NativeHarness = undefined,
    /// Set only when `agent.harness = "dsh-sidecar"`, this build has the
    /// adapter and the sidecar started; `turnHarness()` prefers it over
    /// `harness`.
    dsh: ?DshState = null,
    /// Set only when `agent.harness = "dsh"` (or its `"dsh-native"` alias);
    /// `turnHarness()` prefers it over everything else.
    dsh_native: ?DshNativeState = null,
    provider_holder: ?providers.ProviderHolder = null,
    owned_provider_api_key: ?[]u8 = null,
    owned_memory_session_id: ?[]u8 = null,
    created_at: i64,
    last_active: i64,
    last_consolidated: u64 = 0,
    session_key: []const u8, // owned copy
    turn_count: u64,
    turn_running: std.atomic.Value(bool),
    /// True from the moment a caller claims the session for a turn (under
    /// SessionManager.mutex) until the turn actually starts under
    /// Session.mutex. Closes the reset TOCTOU window: without it, a concurrent
    /// getOrCreate could reset the session between the reset decision and the
    /// turn start. Set and cleared only under SessionManager.mutex.
    turn_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// True while the turn is tearing down: new mid-turn deposits are refused
    /// and fall back to a fresh turn, so nothing is stranded after the last drain.
    turn_closing: std.atomic.Value(bool),
    mutex: std_compat.sync.Mutex,
    /// Protects injection_pending independently of the session turn mutex.
    injection_mu: std_compat.sync.Mutex = .{},
    /// Pending mid-turn messages in arrival order; owned by the SessionManager allocator.
    injection_pending: std.ArrayListUnmanaged(u8) = .empty,
    /// Channel refs for the pending injection text, in the same arrival order
    /// as the appended text. Owned and guarded by `injection_mu`.
    injection_refs: std.ArrayListUnmanaged(ConsumedRef) = .empty,
    /// Refs whose text a `latest` replacement displaced. The running turn
    /// finalizes them `.failed` so their acknowledgement reaction is not left
    /// stuck.
    discarded_refs: std.ArrayListUnmanaged(ConsumedRef) = .empty,

    /// The native `Agent` behind this session's port. Kept so the host's
    /// not-yet-ported call sites (restore, interrupt/status, reset, persistence,
    /// queue/reasoning reads, attachment filtering, prompt invalidation) keep
    /// working without a rewrite. `Session` is NOT a union yet: that is a later
    /// phase, when a second engine exists.
    pub fn nativeAgent(self: *Session) *Agent {
        return &self.agent;
    }

    /// The engine this session's turns run on: dsh-native or dsh when
    /// selected, otherwise the native adapter. The dsh handles own immutable
    /// key copies; the native adapter still refreshes its key because a legacy
    /// key can be canonicalized after session creation.
    fn turnHarness(self: *Session) harness_port.Harness {
        if (self.dsh_native) |*d| {
            return d.harness.harness();
        }
        if (comptime dsh_enabled) {
            if (self.dsh) |*d| {
                return d.harness.harness();
            }
        }
        self.harness.session_key = self.session_key;
        return self.harness.harness();
    }

    /// Answer a host-side slash command on the engine that owns this session's
    /// turns. A dsh session never runs `Agent.turn`, so its command dispatch
    /// would miss `/stop` and `/new` and send them to dsh as prompt text.
    /// Native calls the agent exactly once: probing `NativeHarness` first
    /// would run every native command twice, because that adapter *is* the
    /// agent call.
    fn handleLocalCommand(self: *Session, content: []const u8) !?[]const u8 {
        if (self.dsh_native) |*d| {
            if (try d.harness.harness().handleLocalCommand(content)) |reply| {
                // The engine's reply is borrowed; host replies are owned.
                return try self.agent.allocator.dupe(u8, reply);
            }
            // `/new` must also rotate the engine session (new id, JSONL and
            // mapping). The ack and agent-state reset stay the native ones.
            if (agent_mod.commands.planTurnInput(content).clear_session) {
                d.harness.harness().reset();
                d.reported_total_tokens = 0;
            }
            const reply = try self.agent.handleSlashCommand(content);
            try d.syncCallConfig(self.agent.allocator, &self.agent);
            return reply;
        }
        if (comptime dsh_enabled) {
            if (self.dsh) |*d| {
                if (try d.harness.harness().handleLocalCommand(content)) |reply| {
                    // The engine's reply is borrowed; host replies are owned.
                    return try self.agent.allocator.dupe(u8, reply);
                }
                // Commands the dsh engine does not own (e.g. /status, /think)
                // stay host-side; mirror their config change to this session's
                // sidecar handle before the next turn.
                const reply = try self.agent.handleSlashCommand(content);
                d.harness.setCallConfig(
                    self.agent.model_name,
                    self.agent.reasoning_effort,
                    self.agent.reasoning_mode,
                );
                return reply;
            }
        }
        return self.agent.handleSlashCommand(content);
    }

    /// Interrupt the engine that owns this session's turns. Native resolves to
    /// the same `Agent` call, so the default path is unchanged.
    pub fn requestInterrupt(self: *Session) void {
        if (self.dsh_native) |*d| {
            d.harness.harness().requestInterrupt();
            return;
        }
        if (comptime dsh_enabled) {
            if (self.dsh) |*d| {
                d.harness.harness().requestInterrupt();
                return;
            }
        }
        self.agent.requestInterrupt();
    }

    /// Clear an interrupt that no turn consumed, e.g. a `/stop` that landed
    /// during reply delivery. Native resolves to the same `Agent` call.
    pub fn clearInterrupt(self: *Session) void {
        if (self.dsh_native) |*d| {
            d.harness.harness().clearInterrupt();
            return;
        }
        if (comptime dsh_enabled) {
            if (self.dsh) |*d| {
                d.harness.harness().clearInterrupt();
                return;
            }
        }
        self.agent.clearInterruptRequest();
    }

    pub fn deinit(self: *Session, allocator: Allocator) void {
        if (self.dsh_native) |*d| d.deinit(allocator);
        if (self.dsh) |*d| d.deinit();
        self.agent.deinit();
        if (self.provider_holder) |*holder| holder.deinit();
        if (self.owned_provider_api_key) |key| allocator.free(key);
        if (self.owned_memory_session_id) |sid| allocator.free(sid);
        freeConsumedRefs(allocator, &self.injection_refs);
        freeConsumedRefs(allocator, &self.discarded_refs);
        self.injection_pending.deinit(allocator);
        allocator.free(self.session_key);
    }

    /// Deposit text in the injection buffer (replaces any existing pending injection).
    /// Must be called with the SM allocator, NOT while holding session.mutex.
    pub fn injectMidTurn(self: *Session, allocator: Allocator, text: []const u8) !void {
        const duped = try allocator.dupe(u8, text);
        errdefer allocator.free(duped);
        self.injection_mu.lock();
        defer self.injection_mu.unlock();
        try self.replaceInjectionLocked(allocator, duped, null);
    }

    /// Replace the pending text and its ref. Must be called with `injection_mu`
    /// held. Takes ownership of `duped` and `owned_ref` on success; on error
    /// the caller keeps ownership. Every buffer is reserved before mutating, so
    /// a failed allocation leaves the pending injection intact.
    fn replaceInjectionLocked(
        self: *Session,
        allocator: Allocator,
        duped: []u8,
        owned_ref: ?ConsumedRef,
    ) !void {
        try self.injection_pending.ensureUnusedCapacity(allocator, duped.len);
        try self.discarded_refs.ensureUnusedCapacity(allocator, self.injection_refs.items.len);
        try self.injection_refs.ensureUnusedCapacity(allocator, if (owned_ref != null) 1 else 0);
        // The displaced text is gone, so its refs can never be consumed by a
        // turn: hand them to the turn-end `.failed` finalizer instead of
        // leaving their reaction stuck.
        for (self.injection_refs.items) |old| self.discarded_refs.appendAssumeCapacity(old);
        self.injection_refs.clearRetainingCapacity();
        self.injection_pending.clearRetainingCapacity();
        self.injection_pending.appendSliceAssumeCapacity(duped);
        allocator.free(duped);
        if (owned_ref) |ref| self.injection_refs.appendAssumeCapacity(ref);
    }

    /// True while a running turn can still accept mid-turn deposits.
    fn acceptsInjection(self: *Session) bool {
        return self.turn_running.load(.acquire) and !self.turn_closing.load(.acquire);
    }

    /// Stop accepting mid-turn deposits before the turn tears down. Called while
    /// the session mutex is held; an appender that already holds injection_mu
    /// completes first, and the caller drains its text afterwards.
    pub fn closeInjectionWindow(self: *Session) void {
        self.injection_mu.lock();
        defer self.injection_mu.unlock();
        self.turn_closing.store(true, .release);
    }

    /// Append only if a turn is still accepting input after the injection lock is held.
    pub fn appendMidTurnIfRunning(self: *Session, allocator: Allocator, text: []const u8) !bool {
        var ack: ?ConsumedRef = null;
        return self.appendMidTurnIfRunningWithRef(allocator, text, null, null, &ack);
    }

    /// Append only if a turn is still accepting input after the injection lock
    /// is held, registering the steered message's channel ref atomically with
    /// its text. The caller must acknowledge ack_out after releasing its locks.
    fn appendMidTurnIfRunningWithRef(
        self: *Session,
        allocator: Allocator,
        text: []const u8,
        ref: ?ConsumedRef,
        sink: ?SteerReactionSink,
        ack_out: *?ConsumedRef,
    ) !bool {
        if (!self.acceptsInjection()) return false;
        const owned_ref = if (ref) |r| try dupeConsumedRef(allocator, r, sink) else null;
        errdefer if (owned_ref) |r| freeConsumedRef(allocator, r);
        self.injection_mu.lock();
        defer self.injection_mu.unlock();
        if (!self.acceptsInjection()) {
            if (owned_ref) |r| freeConsumedRef(allocator, r);
            return false;
        }
        const separator: []const u8 = if (self.injection_pending.items.len > 0) "\n\n" else "";
        try self.injection_pending.ensureUnusedCapacity(allocator, separator.len + text.len);
        try self.injection_refs.ensureUnusedCapacity(allocator, if (owned_ref != null) 1 else 0);
        self.injection_pending.appendSliceAssumeCapacity(separator);
        self.injection_pending.appendSliceAssumeCapacity(text);
        ack_out.* = reserveSteerAcknowledgement(owned_ref);
        if (owned_ref) |r| self.injection_refs.appendAssumeCapacity(r);
        return true;
    }

    /// Deposit text only if a turn is still accepting input after the injection lock is held.
    pub fn injectMidTurnIfRunning(self: *Session, allocator: Allocator, text: []const u8) !bool {
        var ack: ?ConsumedRef = null;
        return self.injectMidTurnIfRunningWithRef(allocator, text, null, null, &ack);
    }

    /// Deposit text only if a turn is still accepting input after the injection
    /// lock is held, registering the steered message's channel ref atomically.
    /// The caller must acknowledge ack_out after releasing its locks.
    fn injectMidTurnIfRunningWithRef(
        self: *Session,
        allocator: Allocator,
        text: []const u8,
        ref: ?ConsumedRef,
        sink: ?SteerReactionSink,
        ack_out: *?ConsumedRef,
    ) !bool {
        if (!self.acceptsInjection()) return false;
        const duped = try allocator.dupe(u8, text);
        errdefer allocator.free(duped);
        const owned_ref = if (ref) |r| try dupeConsumedRef(allocator, r, sink) else null;
        errdefer if (owned_ref) |r| freeConsumedRef(allocator, r);
        self.injection_mu.lock();
        defer self.injection_mu.unlock();
        if (!self.acceptsInjection()) {
            allocator.free(duped);
            if (owned_ref) |r| freeConsumedRef(allocator, r);
            return false;
        }
        try self.replaceInjectionLocked(allocator, duped, owned_ref);
        ack_out.* = reserveSteerAcknowledgement(owned_ref);
        return true;
    }

    /// Returns true if there is a pending injection.
    pub fn hasInjection(self: *Session) bool {
        self.injection_mu.lock();
        defer self.injection_mu.unlock();
        return self.injection_pending.items.len > 0;
    }

    /// Drain and duplicate the pending injection into dst_allocator.
    /// On allocation failure the pending message stays buffered for a later retry.
    pub fn drainInjection(self: *Session, sm_allocator: Allocator, dst_allocator: Allocator) !?[]u8 {
        var refs: std.ArrayListUnmanaged(ConsumedRef) = .empty;
        defer freeConsumedRefs(sm_allocator, &refs);
        return self.drainInjectionWithRefs(sm_allocator, dst_allocator, &refs);
    }

    /// Drain the pending text together with the refs of the messages that
    /// produced it. `refs_out` receives owned refs (SM allocator) in arrival
    /// order; on allocation failure nothing is drained and both stay buffered
    /// for a later retry.
    pub fn drainInjectionWithRefs(
        self: *Session,
        sm_allocator: Allocator,
        dst_allocator: Allocator,
        refs_out: *std.ArrayListUnmanaged(ConsumedRef),
    ) !?[]u8 {
        self.injection_mu.lock();
        defer self.injection_mu.unlock();

        if (self.injection_pending.items.len == 0) return null;
        const duped = try dst_allocator.dupe(u8, self.injection_pending.items);
        errdefer dst_allocator.free(duped);
        try refs_out.ensureUnusedCapacity(sm_allocator, self.injection_refs.items.len);
        for (self.injection_refs.items) |ref| refs_out.appendAssumeCapacity(ref);
        self.injection_refs.clearRetainingCapacity();
        self.injection_pending.clearRetainingCapacity();
        return duped;
    }

    /// Drop pending mid-turn messages after a /stop: the turn that would have
    /// consumed them is over, so their refs move to `discarded_refs` for the
    /// turn-end `.failed` finalizer instead of running as follow-up turns.
    /// Returns the number of pending messages discarded (the buffer is
    /// coalesced, so this is 0 or 1).
    pub fn discardPendingInjections(self: *Session, allocator: Allocator) !usize {
        self.injection_mu.lock();
        defer self.injection_mu.unlock();
        if (self.injection_pending.items.len == 0) return 0;
        try self.discarded_refs.ensureUnusedCapacity(allocator, self.injection_refs.items.len);
        for (self.injection_refs.items) |ref| self.discarded_refs.appendAssumeCapacity(ref);
        self.injection_refs.clearRetainingCapacity();
        self.injection_pending.clearRetainingCapacity();
        return 1;
    }

    /// Take the refs displaced by `latest` replacements so the running turn can
    /// finalize them `.failed` outside the injection lock.
    pub fn takeDiscardedRefs(self: *Session) std.ArrayListUnmanaged(ConsumedRef) {
        self.injection_mu.lock();
        defer self.injection_mu.unlock();
        const taken = self.discarded_refs;
        self.discarded_refs = .empty;
        return taken;
    }
};

const AgentRuntime = struct {
    agent_id: []const u8,
    workspace_dir: []const u8,
    config: Config,
    provider: Provider,
    tools: []const Tool,
    mem: ?Memory,
    mem_rt: ?memory_mod.MemoryRuntime,
    session_store: ?memory_mod.SessionStore,
    response_cache: ?*memory_mod.cache.ResponseCache,
    bootstrap_provider: ?bootstrap_mod.BootstrapProvider,
    /// Security policy used for this agent's sessions and tools. Points at the
    /// global SessionManager policy unless the agent declares its own autonomy,
    /// in which case it points at `owned_policy`.
    policy: ?*const SecurityPolicy = null,
    /// Per-agent policy/tracker, owned only when the named agent has its own
    /// autonomy block (see `createAgentSecurityPolicy`).
    owned_policy: ?*SecurityPolicy = null,

    fn deinit(self: *AgentRuntime, allocator: Allocator) void {
        if (self.tools.len > 0) tools_mod.deinitTools(allocator, self.tools);
        if (self.bootstrap_provider) |bp| bp.deinit();
        if (self.mem_rt) |*rt| rt.deinit();
        if (self.owned_policy) |policy| {
            if (policy.tracker) |tracker| {
                tracker.deinit();
                allocator.destroy(tracker);
            }
            allocator.destroy(policy);
        }
        allocator.free(self.workspace_dir);
        allocator.free(self.agent_id);
    }
};

/// Endpoint and wire protocol for the dsh route derived from junclaw's
/// provider config. Returns error.DshProviderUnsupported when dsh cannot
/// speak the provider's protocol (Gemini/Vertex native APIs, Azure api-key
/// auth, Ollama's native API, CLI providers) so the turn fails loudly instead
/// of leaving the profile empty and letting dsh use its built-in model.
const DshRouteEndpoint = struct {
    base_url: []const u8,
    api: []const u8,
};

/// pi-ai appends `/chat/completions` or `/responses` to the route base URL.
/// A compatible provider's configured URL may already name that full endpoint
/// (compatible.zig accepts both), so strip it before handing the URL to dsh.
fn dshOpenAiBaseUrl(raw: []const u8) []const u8 {
    var url = raw;
    if (url.len > 0 and url[url.len - 1] == '/') url = url[0 .. url.len - 1];
    if (std.mem.endsWith(u8, url, "/chat/completions")) return url[0 .. url.len - "/chat/completions".len];
    if (std.mem.endsWith(u8, url, "/responses")) return url[0 .. url.len - "/responses".len];
    return url;
}

/// dsh appends `/v1/messages` (and does not duplicate a trailing `/v1`), so a
/// configured base_url that already names the version or the full endpoint
/// would otherwise turn into `/v1/v1/messages`.
fn dshAnthropicBaseUrl(raw: []const u8) []const u8 {
    var url = raw;
    if (url.len > 0 and url[url.len - 1] == '/') url = url[0 .. url.len - 1];
    if (std.mem.endsWith(u8, url, "/v1/messages")) return url[0 .. url.len - "/v1/messages".len];
    if (std.mem.endsWith(u8, url, "/v1")) return url[0 .. url.len - "/v1".len];
    return url;
}

fn dshOpenAiEndpoint(config: *const Config, provider: []const u8, base_url: []const u8) !DshRouteEndpoint {
    const route_url = dshOpenAiBaseUrl(base_url);
    if (route_url.len == 0) return error.DshProviderUrlInvalid;
    return .{
        .base_url = route_url,
        .api = switch (config.getProviderApiMode(provider)) {
            .responses => "openai-responses",
            else => "openai-completions",
        },
    };
}

fn dshRouteEndpoint(config: *const Config, provider: []const u8) !DshRouteEndpoint {
    const kind = providers.classifyProvider(provider);
    switch (kind) {
        .anthropic_provider => {
            const base_url = if (std.mem.startsWith(u8, provider, "anthropic-custom:") and
                config_types.ProviderEntry.isValidBaseUrl(provider["anthropic-custom:".len..]))
                provider["anthropic-custom:".len..]
            else
                config.getProviderBaseUrl(provider) orelse
                    providers.factory.defaultProviderUrl(provider) orelse return error.DshProviderUrlInvalid;
            const route_url = dshAnthropicBaseUrl(base_url);
            if (route_url.len == 0) return error.DshProviderUrlInvalid;
            return .{ .base_url = route_url, .api = "anthropic-messages" };
        },
        // dsh speaks the OpenAI wire protocol for these clients, so honor the
        // configured base_url and api_mode instead of forcing the vendor
        // default that createProvider uses.
        .openai_provider, .openrouter_provider => {
            const base_url = config.getProviderBaseUrl(provider) orelse
                providers.factory.defaultProviderUrl(provider) orelse return error.DshProviderUrlInvalid;
            return dshOpenAiEndpoint(config, provider, base_url);
        },
        .compatible_provider, .unknown => {
            const base_url = config.getProviderBaseUrl(provider) orelse blk: {
                if (std.mem.startsWith(u8, provider, "custom:") and
                    config_types.ProviderEntry.isValidBaseUrl(provider["custom:".len..]))
                {
                    break :blk provider["custom:".len..];
                }
                if (kind == .compatible_provider) {
                    if (providers.compatibleProviderUrl(provider)) |url| break :blk url;
                }
                // Mirrors createProvider: no URL and an unknown name both
                // fall back to the OpenRouter client.
                return .{ .base_url = "https://openrouter.ai/api/v1", .api = "openai-completions" };
            };
            return dshOpenAiEndpoint(config, provider, base_url);
        },
        else => return error.DshProviderUnsupported,
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// SessionManager
// ═══════════════════════════════════════════════════════════════════════════

pub const SessionManager = struct {
    allocator: Allocator,
    config: *const Config,
    provider: Provider,
    tools: []const Tool,
    mem: ?Memory,
    session_store: ?memory_mod.SessionStore = null,
    response_cache: ?*memory_mod.cache.ResponseCache = null,
    mem_rt: ?*memory_mod.MemoryRuntime = null,
    observer: Observer,
    policy: ?*const SecurityPolicy = null,
    subagent_manager: ?*@import("subagent.zig").SubagentManager = null,
    cost_tracker: ?cost_mod.CostTracker = null,

    /// Result of the startup vision probe against the configured model.
    /// null = not yet confirmed (probe not run, skipped, or inconclusive), true = model accepts images,
    /// false = model rejected images (ProviderDoesNotSupportVision).
    vision_capable: ?bool = null,

    mutex: std_compat.sync.Mutex,
    /// Process-wide dsh engine, created lazily under its own lock. Empty in a
    /// default build (the field is compiled away).
    dsh_engine: DshEngineSlot = .{},
    usage_log_mutex: std_compat.sync.Mutex,
    claim_state_io_mutex: std_compat.sync.Mutex,
    usage_ledger_state_initialized: bool,
    usage_ledger_window_started_at: i64,
    usage_ledger_line_count: u64,
    sessions: std.StringHashMapUnmanaged(*Session),
    agent_runtimes: std.StringHashMapUnmanaged(*AgentRuntime),
    claim_state_path: ?[]u8 = null,
    claim_state_loaded: bool = false,
    claim_state_generation: u64 = 0,
    claim_state_persisted_generation: u64 = 0,
    verified_bindings: std.StringHashMapUnmanaged(VerifiedBinding),
    used_claim_nonces: std.StringHashMapUnmanaged(i64),
    claim_attempts: std.StringHashMapUnmanaged(ClaimAttempt),
    /// Pre-turn /stop requests recorded before the session existed. Sessions
    /// are created lazily by `processMessageStreaming`, so a stop that lands
    /// in that window has no Agent to flag yet; the turn that creates the
    /// session consumes the entry before its first provider call.
    pending_start_interrupts: std.StringHashMapUnmanaged(void),

    pub fn init(
        allocator: Allocator,
        config: *const Config,
        provider: Provider,
        tools: []const Tool,
        mem: ?Memory,
        observer_i: Observer,
        session_store: ?memory_mod.SessionStore,
        response_cache: ?*memory_mod.cache.ResponseCache,
    ) SessionManager {
        tools_mod.bindMemoryTools(tools, mem);

        const claim_state_path = blk: {
            const secret = config.session.claim_secret orelse break :blk null;
            if (std.mem.trim(u8, secret, " \t\r\n").len == 0) break :blk null;
            const config_dir = std_compat.fs.path.dirname(config.config_path) orelse ".";
            break :blk std_compat.fs.path.join(allocator, &.{ config_dir, "state", CLAIM_STATE_FILENAME }) catch null;
        };

        var manager: SessionManager = .{
            .allocator = allocator,
            .config = config,
            .provider = provider,
            .tools = tools,
            .mem = mem,
            .session_store = session_store,
            .response_cache = response_cache,
            .observer = observer_i,
            .subagent_manager = detectSubagentManager(tools),
            .mutex = .{},
            .usage_log_mutex = .{},
            .claim_state_io_mutex = .{},
            .usage_ledger_state_initialized = false,
            .usage_ledger_window_started_at = 0,
            .usage_ledger_line_count = 0,
            .sessions = .{},
            .agent_runtimes = .{},
            .claim_state_path = claim_state_path,
            .claim_state_loaded = false,
            .claim_state_generation = 0,
            .claim_state_persisted_generation = 0,
            .verified_bindings = .{},
            .used_claim_nonces = .{},
            .claim_attempts = .{},
            .pending_start_interrupts = .{},
            .cost_tracker = if (config.cost.enabled) cost_mod.CostTracker.init(allocator, config.workspace_dir, config.cost.enabled, config.cost.daily_limit_usd, config.cost.monthly_limit_usd, config.cost.warn_at_percent) else null,
        };
        manager.loadClaimState();
        return manager;
    }

    pub fn deinit(self: *SessionManager) void {
        if (self.cost_tracker) |*tracker| tracker.deinit();
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit(self.allocator);

        // Every session released its key above; tear down the shared sidecar
        // last.
        if (comptime dsh_enabled) {
            if (self.dsh_engine.state) |*state| state.deinit();
        }

        var rt_it = self.agent_runtimes.iterator();
        while (rt_it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.agent_runtimes.deinit(self.allocator);

        var bindings_it = self.verified_bindings.iterator();
        while (bindings_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.canonical_user_id);
        }
        self.verified_bindings.deinit(self.allocator);

        var nonces_it = self.used_claim_nonces.iterator();
        while (nonces_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.used_claim_nonces.deinit(self.allocator);

        var attempts_it = self.claim_attempts.iterator();
        while (attempts_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.claim_attempts.deinit(self.allocator);

        var pending_it = self.pending_start_interrupts.iterator();
        while (pending_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending_start_interrupts.deinit(self.allocator);

        if (self.claim_state_path) |path| self.allocator.free(path);
    }

    /// Probe whether the configured model accepts image input by sending a minimal
    /// 1×1 white JPEG directly to the provider (no session history, no tools).
    /// Sets self.vision_capable to true/false accordingly. Errors other than
    /// ProviderDoesNotSupportVision leave the result unset so callers can fall
    /// back to explicit configuration. The result is cached once confirmed.
    pub fn probeVision(self: *SessionManager, allocator: std.mem.Allocator) void {
        if (self.vision_capable != null) return;

        var owned_probe_model_ref: ?[]u8 = null;
        defer if (owned_probe_model_ref) |model_ref| allocator.free(model_ref);

        const probe_model_ref = blk: {
            for (self.config.model_routes) |route| {
                if (!std.mem.eql(u8, route.hint, "vision")) continue;
                const route_model_ref = std.fmt.allocPrint(allocator, "{s}/{s}", .{ route.provider, route.model }) catch {
                    log.info("vision probe: failed to build route model reference, skipping", .{});
                    return;
                };
                owned_probe_model_ref = route_model_ref;
                break :blk route_model_ref;
            }
            break :blk self.config.default_model orelse {
                log.info("vision probe: no default model configured, skipping", .{});
                return;
            };
        };

        if (!self.provider.supportsVisionForModel(probe_model_ref)) {
            log.info("vision probe: model '{s}' is already marked as text-only", .{probe_model_ref});
            self.vision_capable = false;
            return;
        }

        // Minimal 1×1 white JPEG (~500 bytes) — sufficient to test vision acceptance
        // without triggering expensive model compute.
        const tiny_jpeg_b64 =
            "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8U" ++
            "HRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgN" ++
            "DRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIy" ++
            "MjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQ" ++
            "AAAAAAAAAAAAAAAAAAAP/EABQBAQAAAAAAAAAAAAAAAAAAAAD/xAAUEQEAAAAAAAAAAAAA" ++
            "AAAAAAAA/9oADAMBAAIRAxEAPwCwABmX/9k=";

        const content_parts = [_]providers.ContentPart{
            .{ .text = "." },
            .{ .image_base64 = .{ .data = tiny_jpeg_b64, .media_type = "image/jpeg" } },
        };
        const probe_msg = providers.ChatMessage{
            .role = .user,
            .content = ".",
            .content_parts = &content_parts,
        };
        const probe_req = providers.ChatRequest{
            .messages = &[_]providers.ChatMessage{probe_msg},
            .model = probe_model_ref,
            .temperature = 0.0,
            .max_tokens = 1,
            .timeout_secs = self.config.gateway.request_timeout_secs,
        };

        log.info("vision probe: querying model '{s}' for image support", .{probe_model_ref});
        var resp = self.provider.chat(allocator, probe_req, probe_model_ref, 0.0) catch |err| {
            if (err == error.ProviderDoesNotSupportVision) {
                log.info("vision probe: model '{s}' does not support vision", .{probe_model_ref});
                self.vision_capable = false;
            } else {
                log.info("vision probe: model '{s}' probe inconclusive ({s}), leaving capability unset", .{ probe_model_ref, @errorName(err) });
            }
            return;
        };
        // Regression: freeing only content and reasoning_content leaked the
        // probe response's provider, model and tool_calls — the ReliableProvider
        // wrapper annotates provider/model and OpenRouter sets model, so every
        // completed startup probe leaked until process exit.
        providers.freeChatResponse(allocator, &resp);
        log.info("vision probe: model '{s}' confirmed vision support", .{probe_model_ref});
        self.vision_capable = true;
    }

    fn detectSubagentManager(tools: []const Tool) ?*@import("subagent.zig").SubagentManager {
        for (tools) |tool| {
            if (!std.mem.eql(u8, tool.name(), "spawn")) continue;
            const spawn_tool: *tools_mod.spawn.SpawnTool = @ptrCast(@alignCast(tool.ptr));
            return spawn_tool.manager;
        }
        return null;
    }

    fn secureEql(a: []const u8, b: []const u8) bool {
        const max_len = @max(a.len, b.len);
        var diff: u8 = @intFromBool(a.len != b.len);
        var i: usize = 0;
        while (i < max_len) : (i += 1) {
            const av: u8 = if (i < a.len) a[i] else 0;
            const bv: u8 = if (i < b.len) b[i] else 0;
            diff |= av ^ bv;
        }
        return diff == 0;
    }

    fn parseClaimToken(token: []const u8) ?ClaimToken {
        var parts = std.mem.splitScalar(u8, token, ':');
        const version = parts.next() orelse return null;
        const expires_raw = parts.next() orelse return null;
        const canonical = parts.next() orelse return null;
        const nonce = parts.next() orelse return null;
        const sig_hex = parts.next() orelse return null;
        if (parts.next() != null) return null;

        if (!std.mem.eql(u8, version, "v1")) return null;
        if (canonical.len == 0 or nonce.len == 0 or sig_hex.len != 64) return null;

        for (canonical) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return null;
        }
        for (nonce) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return null;
        }
        for (sig_hex) |ch| {
            if (!std.ascii.isHex(ch)) return null;
        }

        const expires_at = std.fmt.parseInt(i64, expires_raw, 10) catch return null;
        return .{
            .expires_at = expires_at,
            .canonical_user_id = canonical,
            .nonce = nonce,
            .signature_hex = sig_hex,
        };
    }

    fn decodeHex32(hex: []const u8) ?[32]u8 {
        if (hex.len != 64) return null;
        var out: [32]u8 = undefined;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            const off = i * 2;
            out[i] = std.fmt.parseInt(u8, hex[off .. off + 2], 16) catch return null;
        }
        return out;
    }

    fn claimSecret(self: *const SessionManager) ?[]const u8 {
        const secret = self.config.session.claim_secret orelse return null;
        const trimmed = std.mem.trim(u8, secret, " \t\r\n");
        if (trimmed.len == 0) return null;
        return trimmed;
    }

    fn claimAdminSecret(self: *const SessionManager) ?[]const u8 {
        const secret = self.config.session.claim_admin_secret orelse return null;
        const trimmed = std.mem.trim(u8, secret, " \t\r\n");
        if (trimmed.len == 0) return null;
        return trimmed;
    }

    fn claimGateEnabled(self: *const SessionManager) bool {
        return self.config.session.auto_provision_direct_agents and self.claimSecret() != null;
    }

    fn claimBindingKeyOwned(self: *SessionManager, channel: []const u8, account_id: []const u8, peer_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}\x1f{s}\x1f{s}", .{ channel, account_id, peer_id });
    }

    fn splitClaimBindingKey(key: []const u8) ?struct { channel: []const u8, account_id: []const u8, peer_id: []const u8 } {
        const first_sep = std.mem.indexOfScalar(u8, key, 0x1f) orelse return null;
        if (first_sep == 0 or first_sep + 1 >= key.len) return null;
        const rest = key[first_sep + 1 ..];
        const second_rel = std.mem.indexOfScalar(u8, rest, 0x1f) orelse {
            return .{
                .channel = key[0..first_sep],
                .account_id = "default",
                .peer_id = rest,
            };
        };
        if (second_rel == 0 or second_rel + 1 >= rest.len) return null;
        return .{
            .channel = key[0..first_sep],
            .account_id = rest[0..second_rel],
            .peer_id = rest[second_rel + 1 ..],
        };
    }

    fn parseAgentIdFromSessionKey(session_key: []const u8) []const u8 {
        return sessionAgentId(session_key) orelse "main";
    }

    fn parseChannelFromSessionKey(session_key: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, session_key, "agent:")) {
            var rest = session_key["agent:".len..];
            const agent_sep = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
            rest = rest[agent_sep + 1 ..];
            const seg_sep = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
            const candidate = rest[0..seg_sep];
            if (std.mem.eql(u8, candidate, "main") or
                std.mem.eql(u8, candidate, "direct") or
                std.mem.eql(u8, candidate, "group") or
                std.mem.eql(u8, candidate, "channel") or
                std.mem.eql(u8, candidate, "room"))
            {
                return null;
            }
            return candidate;
        }
        const sep = std.mem.indexOfScalar(u8, session_key, ':') orelse return null;
        if (sep == 0) return null;
        return session_key[0..sep];
    }

    fn parseAccountIdFromSessionKey(session_key: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, session_key, "agent:")) return null;
        var rest = session_key["agent:".len..];
        const agent_sep = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
        rest = rest[agent_sep + 1 ..];

        const first_sep = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
        const first = rest[0..first_sep];
        if (std.mem.eql(u8, first, "main") or
            std.mem.eql(u8, first, "direct") or
            std.mem.eql(u8, first, "group") or
            std.mem.eql(u8, first, "channel") or
            std.mem.eql(u8, first, "room"))
        {
            return null;
        }

        rest = rest[first_sep + 1 ..];
        const second_sep = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
        const second = rest[0..second_sep];
        if (std.mem.eql(u8, second, "direct") or
            std.mem.eql(u8, second, "group") or
            std.mem.eql(u8, second, "channel") or
            std.mem.eql(u8, second, "room"))
        {
            return null;
        }
        return second;
    }

    fn parsePeerIdFromSessionKey(session_key: []const u8) ?[]const u8 {
        const markers = [_][]const u8{
            ":direct:",
            ":group:",
            ":channel:",
            ":room:",
        };
        for (markers) |marker| {
            const marker_idx = std.mem.indexOf(u8, session_key, marker) orelse continue;
            const start = marker_idx + marker.len;
            if (start >= session_key.len) continue;
            var end = session_key.len;
            if (std.mem.indexOfPos(u8, session_key, start, ":thread:")) |thread_idx| {
                end = thread_idx;
            }
            if (end > start) return session_key[start..end];
        }
        return null;
    }

    fn directContextForClaims(session_key: []const u8, conversation_context: ?ConversationContext) ?ClaimDirectContext {
        const is_direct = if (conversation_context) |ctx|
            if (ctx.is_group) |is_group| !is_group else std.mem.indexOf(u8, session_key, ":direct:") != null
        else
            std.mem.indexOf(u8, session_key, ":direct:") != null;
        if (!is_direct) return null;

        const peer_id = (if (conversation_context) |ctx|
            (ctx.peer_id orelse parsePeerIdFromSessionKey(session_key))
        else
            parsePeerIdFromSessionKey(session_key)) orelse return null;
        const channel = if (conversation_context) |ctx|
            (ctx.channel orelse parseChannelFromSessionKey(session_key) orelse "unknown")
        else
            parseChannelFromSessionKey(session_key) orelse "unknown";
        const account_id = if (conversation_context) |ctx|
            (ctx.account_id orelse parseAccountIdFromSessionKey(session_key) orelse "default")
        else
            parseAccountIdFromSessionKey(session_key) orelse "default";
        return .{ .channel = channel, .account_id = account_id, .peer_id = peer_id };
    }

    fn clearExpiredClaimNoncesLocked(self: *SessionManager, now_ts: i64) void {
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.used_claim_nonces.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* <= now_ts) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.used_claim_nonces.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    fn evictClaimAttemptLocked(self: *SessionManager, binding_key: []const u8) bool {
        if (self.claim_attempts.fetchRemove(binding_key)) |entry| {
            self.allocator.free(entry.key);
            return true;
        }
        return false;
    }

    fn claimAttemptStatusLocked(self: *SessionManager, binding_key: []const u8, now_ts: i64) ?ClaimAttempt {
        const attempt = self.claim_attempts.getPtr(binding_key) orelse return null;
        if (attempt.locked_until > now_ts) return attempt.*;
        if (attempt.failures == 0) {
            _ = self.evictClaimAttemptLocked(binding_key);
            return null;
        }
        return attempt.*;
    }

    fn registerClaimFailureLocked(self: *SessionManager, binding_key: []const u8, now_ts: i64) void {
        const max_attempts: u32 = @max(1, self.config.session.claim_max_attempts);
        const lockout_secs: i64 = @intCast(@max(1, self.config.session.claim_lockout_secs));

        if (self.claim_attempts.getPtr(binding_key)) |attempt| {
            if (attempt.locked_until > now_ts) return;
            attempt.failures += 1;
            if (attempt.failures >= max_attempts) {
                attempt.failures = 0;
                attempt.locked_until = now_ts + lockout_secs;
            }
            return;
        }

        const owned_key = self.allocator.dupe(u8, binding_key) catch return;
        var attempt = ClaimAttempt{ .failures = 1, .locked_until = 0 };
        if (attempt.failures >= max_attempts) {
            attempt.failures = 0;
            attempt.locked_until = now_ts + lockout_secs;
        }
        self.claim_attempts.put(self.allocator, owned_key, attempt) catch {
            self.allocator.free(owned_key);
        };
    }

    fn putClaimNonceLocked(self: *SessionManager, nonce: []const u8, expires_at: i64) void {
        if (self.used_claim_nonces.getPtr(nonce)) |existing| {
            existing.* = expires_at;
            return;
        }
        const owned_nonce = self.allocator.dupe(u8, nonce) catch return;
        self.used_claim_nonces.put(self.allocator, owned_nonce, expires_at) catch {
            self.allocator.free(owned_nonce);
        };
    }

    fn setVerifiedBindingLocked(self: *SessionManager, channel: []const u8, account_id: []const u8, peer_id: []const u8, canonical_user_id: []const u8, verified_at: i64) void {
        const key = self.claimBindingKeyOwned(channel, account_id, peer_id) catch return;
        if (self.verified_bindings.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value.canonical_user_id);
        }

        const canonical_owned = self.allocator.dupe(u8, canonical_user_id) catch {
            self.allocator.free(key);
            return;
        };
        self.verified_bindings.put(self.allocator, key, .{
            .canonical_user_id = canonical_owned,
            .verified_at = verified_at,
        }) catch {
            self.allocator.free(canonical_owned);
            self.allocator.free(key);
        };
    }

    fn removeVerifiedBindingLocked(self: *SessionManager, channel: []const u8, account_id: []const u8, peer_id: []const u8) bool {
        const key = self.claimBindingKeyOwned(channel, account_id, peer_id) catch return false;
        defer self.allocator.free(key);
        if (self.verified_bindings.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value.canonical_user_id);
            return true;
        }
        return false;
    }

    fn hmacClaimPayload(self: *SessionManager, expires_at: i64, canonical_user_id: []const u8, nonce: []const u8) ?[32]u8 {
        const secret = self.claimSecret() orelse return null;
        const payload = std.fmt.allocPrint(self.allocator, "v1:{d}:{s}:{s}", .{ expires_at, canonical_user_id, nonce }) catch return null;
        defer self.allocator.free(payload);

        var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(mac[0..], payload, secret);
        return mac;
    }

    fn verifyClaimTokenLocked(self: *SessionManager, token_raw: []const u8, now_ts: i64) ?ClaimToken {
        const token = parseClaimToken(token_raw) orelse return null;
        if (token.expires_at <= now_ts) return null;

        self.clearExpiredClaimNoncesLocked(now_ts);
        if (self.used_claim_nonces.get(token.nonce)) |_| {
            return null;
        }

        const provided_sig = decodeHex32(token.signature_hex) orelse return null;
        const expected_sig = self.hmacClaimPayload(token.expires_at, token.canonical_user_id, token.nonce) orelse return null;
        if (!std.crypto.timing_safe.eql([32]u8, expected_sig, provided_sig)) return null;
        return token;
    }

    fn loadClaimState(self: *SessionManager) void {
        if (self.claim_state_loaded) return;
        self.claim_state_loaded = true;
        const path = self.claim_state_path orelse return;

        const file = std_compat.fs.openFileAbsolute(path, .{}) catch return;
        defer file.close();
        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return;
        defer self.allocator.free(content);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, content, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const root = parsed.value.object;

        const now_ts = std_compat.time.timestamp();

        if (root.get("bindings")) |bindings_val| {
            if (bindings_val == .array) {
                for (bindings_val.array.items) |item| {
                    if (item != .object) continue;
                    const channel_v = item.object.get("channel") orelse continue;
                    const peer_v = item.object.get("peer_id") orelse continue;
                    const canonical_v = item.object.get("canonical_user_id") orelse continue;
                    if (channel_v != .string or peer_v != .string or canonical_v != .string) continue;
                    const verified_at: i64 = blk: {
                        const ts_v = item.object.get("verified_at") orelse break :blk now_ts;
                        if (ts_v == .integer) break :blk ts_v.integer;
                        break :blk now_ts;
                    };
                    const account_id = if (item.object.get("account_id")) |account_v|
                        if (account_v == .string and account_v.string.len > 0) account_v.string else "default"
                    else
                        "default";
                    self.setVerifiedBindingLocked(channel_v.string, account_id, peer_v.string, canonical_v.string, verified_at);
                }
            }
        }

        if (root.get("used_nonces")) |nonces_val| {
            if (nonces_val == .array) {
                for (nonces_val.array.items) |item| {
                    if (item != .object) continue;
                    const nonce_v = item.object.get("nonce") orelse continue;
                    const expires_v = item.object.get("expires_at") orelse continue;
                    if (nonce_v != .string or expires_v != .integer) continue;
                    if (expires_v.integer <= now_ts) continue;
                    self.putClaimNonceLocked(nonce_v.string, expires_v.integer);
                }
            }
        }

        if (root.get("attempts")) |attempts_val| {
            if (attempts_val == .array) {
                for (attempts_val.array.items) |item| {
                    if (item != .object) continue;
                    const channel_v = item.object.get("channel") orelse continue;
                    const peer_v = item.object.get("peer_id") orelse continue;
                    if (channel_v != .string or peer_v != .string) continue;
                    const account_id = if (item.object.get("account_id")) |account_v|
                        if (account_v == .string and account_v.string.len > 0) account_v.string else "default"
                    else
                        "default";
                    const key = self.claimBindingKeyOwned(channel_v.string, account_id, peer_v.string) catch continue;
                    const failures: u32 = blk: {
                        const fv = item.object.get("failures") orelse break :blk 0;
                        if (fv == .integer and fv.integer > 0) break :blk @intCast(fv.integer);
                        break :blk 0;
                    };
                    const locked_until: i64 = blk: {
                        const lv = item.object.get("locked_until") orelse break :blk 0;
                        if (lv == .integer and lv.integer > now_ts) break :blk lv.integer;
                        break :blk 0;
                    };
                    if (failures == 0 and locked_until == 0) {
                        self.allocator.free(key);
                        continue;
                    }
                    self.claim_attempts.put(self.allocator, key, .{
                        .failures = failures,
                        .locked_until = locked_until,
                    }) catch self.allocator.free(key);
                }
            }
        }
    }

    fn markClaimStateDirtyLocked(self: *SessionManager) void {
        self.claim_state_generation += 1;
    }

    fn captureClaimStateSnapshotLocked(self: *SessionManager) ?ClaimStateSnapshot {
        if (self.claim_state_path == null) return null;
        if (self.claim_state_generation <= self.claim_state_persisted_generation) return null;

        const now_ts = std_compat.time.timestamp();
        self.clearExpiredClaimNoncesLocked(now_ts);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        var buf_writer: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &buf);
        const w = &buf_writer.writer;

        w.print("{{\"version\":{d},\"bindings\":[", .{CLAIM_STATE_VERSION}) catch return null;

        var wrote_binding = false;
        var binding_it = self.verified_bindings.iterator();
        while (binding_it.next()) |entry| {
            const split = splitClaimBindingKey(entry.key_ptr.*) orelse continue;
            if (wrote_binding) w.writeAll(",") catch return null;
            w.print(
                "{{\"channel\":{f},\"account_id\":{f},\"peer_id\":{f},\"canonical_user_id\":{f},\"verified_at\":{d}}}",
                .{
                    std.json.fmt(split.channel, .{}),
                    std.json.fmt(split.account_id, .{}),
                    std.json.fmt(split.peer_id, .{}),
                    std.json.fmt(entry.value_ptr.canonical_user_id, .{}),
                    entry.value_ptr.verified_at,
                },
            ) catch return null;
            wrote_binding = true;
        }

        w.writeAll("],\"used_nonces\":[") catch return null;
        var wrote_nonce = false;
        var nonce_it = self.used_claim_nonces.iterator();
        while (nonce_it.next()) |entry| {
            if (entry.value_ptr.* <= now_ts) continue;
            if (wrote_nonce) w.writeAll(",") catch return null;
            w.print(
                "{{\"nonce\":{f},\"expires_at\":{d}}}",
                .{
                    std.json.fmt(entry.key_ptr.*, .{}),
                    entry.value_ptr.*,
                },
            ) catch return null;
            wrote_nonce = true;
        }

        w.writeAll("],\"attempts\":[") catch return null;
        var wrote_attempt = false;
        var attempt_it = self.claim_attempts.iterator();
        while (attempt_it.next()) |entry| {
            const attempt = entry.value_ptr.*;
            if (attempt.failures == 0 and attempt.locked_until <= now_ts) continue;
            const split = splitClaimBindingKey(entry.key_ptr.*) orelse continue;
            if (wrote_attempt) w.writeAll(",") catch return null;
            w.print(
                "{{\"channel\":{f},\"account_id\":{f},\"peer_id\":{f},\"failures\":{d},\"locked_until\":{d}}}",
                .{
                    std.json.fmt(split.channel, .{}),
                    std.json.fmt(split.account_id, .{}),
                    std.json.fmt(split.peer_id, .{}),
                    attempt.failures,
                    attempt.locked_until,
                },
            ) catch return null;
            wrote_attempt = true;
        }

        w.writeAll("]}") catch return null;
        buf = buf_writer.toArrayList();
        const content = buf.toOwnedSlice(self.allocator) catch return null;
        return .{
            .generation = self.claim_state_generation,
            .content = content,
        };
    }

    fn persistClaimStateSnapshot(self: *SessionManager, snapshot: ?ClaimStateSnapshot) void {
        const claim_snapshot = snapshot orelse return;
        defer self.allocator.free(claim_snapshot.content);

        const path = self.claim_state_path orelse return;

        self.claim_state_io_mutex.lock();
        defer self.claim_state_io_mutex.unlock();

        self.mutex.lock();
        const is_stale = claim_snapshot.generation <= self.claim_state_persisted_generation;
        self.mutex.unlock();
        if (is_stale) return;

        if (std_compat.fs.path.dirname(path)) |parent| {
            std_compat.fs.makeDirAbsolute(parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    fs_compat.makePath(parent) catch return;
                },
            };
        }

        const tmp_path = std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path}) catch return;
        defer self.allocator.free(tmp_path);

        var tmp_file = std_compat.fs.createFileAbsolute(tmp_path, .{}) catch return;
        tmp_file.writeAll(claim_snapshot.content) catch {
            tmp_file.close();
            std_compat.fs.deleteFileAbsolute(tmp_path) catch {};
            return;
        };
        tmp_file.close();

        std_compat.fs.renameAbsolute(tmp_path, path) catch {
            std_compat.fs.deleteFileAbsolute(tmp_path) catch {};
            const file = std_compat.fs.createFileAbsolute(path, .{ .truncate = true }) catch return;
            defer file.close();
            file.writeAll(claim_snapshot.content) catch return;
        };

        self.mutex.lock();
        if (claim_snapshot.generation > self.claim_state_persisted_generation) {
            self.claim_state_persisted_generation = claim_snapshot.generation;
        }
        self.mutex.unlock();
    }

    fn claimTokenArg(message: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, message, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "/claim")) return null;
        if (trimmed.len == "/claim".len) return null;
        if (trimmed["/claim".len] != ' ' and trimmed["/claim".len] != '\t') return null;
        const arg = std.mem.trim(u8, trimmed["/claim".len + 1 ..], " \t\r\n");
        if (arg.len == 0) return null;
        return arg;
    }

    fn revokeSecretArg(message: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, message, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "/revoke")) return null;
        if (trimmed.len == "/revoke".len) return null;
        if (trimmed["/revoke".len] != ' ' and trimmed["/revoke".len] != '\t') return null;
        const arg = std.mem.trim(u8, trimmed["/revoke".len + 1 ..], " \t\r\n");
        if (arg.len == 0) return null;
        return arg;
    }

    fn maybeHandleClaimGate(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        conversation_context: ?ConversationContext,
    ) ?[]const u8 {
        if (!self.claimGateEnabled()) return null;
        if (!std.mem.startsWith(u8, parseAgentIdFromSessionKey(session_key), "peer-")) return null;

        const direct_ctx = directContextForClaims(session_key, conversation_context) orelse return null;
        const now_ts = std_compat.time.timestamp();

        if (revokeSecretArg(content)) |provided_revoke_secret| {
            const admin_secret = self.claimAdminSecret() orelse {
                return self.allocator.dupe(
                    u8,
                    "Revocation is disabled. Configure session.claim_admin_secret to enable /revoke.",
                ) catch null;
            };
            if (!secureEql(provided_revoke_secret, admin_secret)) {
                return self.allocator.dupe(u8, "Invalid revoke secret.") catch null;
            }

            var removed = false;
            var snapshot: ?ClaimStateSnapshot = null;
            self.mutex.lock();
            removed = self.removeVerifiedBindingLocked(direct_ctx.channel, direct_ctx.account_id, direct_ctx.peer_id);
            const attempt_key = self.claimBindingKeyOwned(direct_ctx.channel, direct_ctx.account_id, direct_ctx.peer_id) catch null;
            var cleared_attempts = false;
            if (attempt_key) |k| {
                cleared_attempts = self.evictClaimAttemptLocked(k);
                self.allocator.free(k);
            }
            if (removed or cleared_attempts) {
                self.markClaimStateDirtyLocked();
                snapshot = self.captureClaimStateSnapshotLocked();
            }
            self.mutex.unlock();
            self.persistClaimStateSnapshot(snapshot);

            if (removed) {
                return self.allocator.dupe(u8, "Identity link revoked. This peer is back in gatekeeper mode.") catch null;
            }
            return self.allocator.dupe(u8, "No active identity link was found for this peer.") catch null;
        }

        const claim_token = claimTokenArg(content);
        const binding_key = self.claimBindingKeyOwned(direct_ctx.channel, direct_ctx.account_id, direct_ctx.peer_id) catch return null;
        defer self.allocator.free(binding_key);

        self.mutex.lock();
        if (self.verified_bindings.get(binding_key)) |_| {
            self.mutex.unlock();
            if (claim_token != null) {
                return self.allocator.dupe(u8, "This peer is already verified.") catch null;
            }
            return null;
        }

        if (self.claimAttemptStatusLocked(binding_key, now_ts)) |attempt| {
            if (attempt.locked_until > now_ts) {
                self.mutex.unlock();
                const remaining = @as(u64, @intCast(attempt.locked_until - now_ts));
                return std.fmt.allocPrint(
                    self.allocator,
                    "Too many failed claim attempts. Try again in {d} seconds.",
                    .{remaining},
                ) catch null;
            }
        }

        if (claim_token) |raw_token| {
            const verified = self.verifyClaimTokenLocked(raw_token, now_ts);
            if (verified) |token| {
                self.setVerifiedBindingLocked(
                    direct_ctx.channel,
                    direct_ctx.account_id,
                    direct_ctx.peer_id,
                    token.canonical_user_id,
                    now_ts,
                );
                self.putClaimNonceLocked(token.nonce, token.expires_at);
                _ = self.evictClaimAttemptLocked(binding_key);
                self.markClaimStateDirtyLocked();
                const snapshot = self.captureClaimStateSnapshotLocked();
                self.mutex.unlock();
                self.persistClaimStateSnapshot(snapshot);
                return std.fmt.allocPrint(
                    self.allocator,
                    "Identity verified as '{s}'. Dedicated agent runtime unlocked.",
                    .{token.canonical_user_id},
                ) catch null;
            }

            self.registerClaimFailureLocked(binding_key, now_ts);
            self.markClaimStateDirtyLocked();
            const snapshot = self.captureClaimStateSnapshotLocked();
            self.mutex.unlock();
            self.persistClaimStateSnapshot(snapshot);
            return self.allocator.dupe(
                u8,
                "Invalid or expired claim token. Use `/claim v1:<exp>:<canonical>:<nonce>:<hmac_sha256_hex>`.",
            ) catch null;
        }

        self.mutex.unlock();
        return self.allocator.dupe(
            u8,
            "Identity verification required before agent provisioning. Send `/claim <token>` to continue.",
        ) catch null;
    }

    fn setTurnToolContext(
        tools: []const Tool,
        session_key: []const u8,
        conversation_context: ?ConversationContext,
    ) void {
        const channel = if (conversation_context) |ctx| (ctx.channel orelse parseChannelFromSessionKey(session_key)) else parseChannelFromSessionKey(session_key);
        const chat_id = if (conversation_context) |ctx|
            ctx.delivery_chat_id orelse parsePeerIdFromSessionKey(session_key)
        else
            parsePeerIdFromSessionKey(session_key);
        const account_id = if (conversation_context) |ctx| ctx.account_id else null;
        const peer_kind = if (conversation_context) |ctx|
            if (ctx.is_group) |is_group|
                if (is_group) agent_routing.ChatType.group else agent_routing.ChatType.direct
            else
                null
        else
            null;
        const peer_id = if (conversation_context) |ctx| blk: {
            if (ctx.is_group) |is_group| {
                if (is_group) {
                    if (ctx.group_id) |group_id| break :blk group_id;
                }
            }
            if (ctx.peer_id) |value| break :blk value;
            break :blk chat_id;
        } else chat_id;

        for (tools) |tool| {
            if (std.mem.eql(u8, tool.name(), "schedule")) {
                const schedule_tool: *tools_mod.schedule.ScheduleTool = @ptrCast(@alignCast(tool.ptr));
                schedule_tool.setContext(channel, account_id, chat_id, peer_kind, peer_id, null);
            }
        }
    }

    fn shouldUseDedicatedRuntime(self: *SessionManager, agent_id: []const u8, named_agent: ?NamedAgentConfig) bool {
        if (named_agent) |cfg| {
            if (cfg.workspace_path != null) return true;
            // An agent with its own autonomy needs a dedicated runtime so its
            // stricter policy never falls back to the shared global one.
            if (cfg.autonomy != null) return true;
        }
        return self.config.session.auto_provision_direct_agents and std.mem.startsWith(u8, agent_id, "peer-");
    }

    /// Build a SecurityPolicy + RateTracker from an autonomy block. Mirrors the
    /// field mapping ChannelRuntime.init (channel_loop.zig) uses for the global
    /// policy, but scoped to this agent's workspace. The returned policy owns
    /// its tracker; free both with `destroyAgentSecurityPolicy`.
    fn createAgentSecurityPolicy(
        allocator: Allocator,
        autonomy: config_types.AutonomyConfig,
        workspace_dir: []const u8,
    ) !*SecurityPolicy {
        const tracker = try allocator.create(security.RateTracker);
        errdefer allocator.destroy(tracker);
        tracker.* = security.RateTracker.init(allocator, autonomy.max_actions_per_hour);
        errdefer tracker.deinit();

        const policy = try allocator.create(SecurityPolicy);
        errdefer allocator.destroy(policy);
        policy.* = .{
            .autonomy = autonomy.level,
            .workspace_dir = workspace_dir,
            .workspace_only = autonomy.workspace_only,
            .allowed_commands = security.resolveAllowedCommands(autonomy.level, autonomy.allowed_commands),
            .max_actions_per_hour = autonomy.max_actions_per_hour,
            .require_approval_for_medium_risk = autonomy.require_approval_for_medium_risk,
            .block_high_risk_commands = autonomy.block_high_risk_commands,
            .block_medium_risk_commands = autonomy.block_medium_risk_commands,
            .allow_raw_url_chars = autonomy.allow_raw_url_chars,
            // Confine file-path arguments of the file-reading shell commands to
            // this agent's workspace. Without an active external sandbox (the
            // common case in a container) the shell tool would otherwise let a
            // supervised guest `cat ../../../config.json` or `cat /etc/passwd`.
            .confine_paths = true,
            .tracker = tracker,
        };
        return policy;
    }

    fn destroyAgentSecurityPolicy(allocator: Allocator, policy: *SecurityPolicy) void {
        if (policy.tracker) |tracker| {
            tracker.deinit();
            allocator.destroy(tracker);
        }
        allocator.destroy(policy);
    }

    fn sanitizePathComponent(allocator: Allocator, value: []const u8) ![]u8 {
        var trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) trimmed = "default";
        var out = try allocator.alloc(u8, trimmed.len);
        for (trimmed, 0..) |ch, idx| {
            out[idx] = if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') ch else '_';
        }
        return out;
    }

    fn resolveAgentWorkspaceDir(self: *SessionManager, agent_id: []const u8, named_agent: ?NamedAgentConfig) ![]const u8 {
        if (named_agent) |cfg| {
            if (cfg.workspace_path) |workspace_path| {
                return self.config.resolveAgentWorkspacePath(self.allocator, workspace_path);
            }
        }

        const config_dir = std_compat.fs.path.dirname(self.config.config_path) orelse ".";
        const normalized = try sanitizePathComponent(self.allocator, agent_id);
        defer self.allocator.free(normalized);
        return std_compat.fs.path.join(self.allocator, &.{ config_dir, "agents", normalized, "workspace" });
    }

    fn makeAgentConfig(base: *const Config, workspace_dir: []const u8, named_agent: ?NamedAgentConfig) Config {
        var cfg = base.*;
        cfg.workspace_dir = workspace_dir;
        if (named_agent) |agent_cfg| {
            cfg.default_provider = agent_cfg.provider;
            cfg.default_model = agent_cfg.model;
            if (agent_cfg.temperature) |t| cfg.default_temperature = t;
            // Agent.fromConfigWithProfile derives security-relevant fields
            // (exec_security/exec_ask, allowed_paths, multimodal_unrestricted,
            // the skip_dir_check/allow_remote_fetch pair) straight from
            // cfg.autonomy. Override the copied global block with the agent's own
            // autonomy so a restricted guest does not inherit the global yolo
            // permissions (e.g. reading any local image via [IMAGE:...]).
            if (agent_cfg.autonomy) |autonomy| cfg.autonomy = autonomy;
        }
        cfg.syncFlatFields();
        return cfg;
    }

    fn createAgentRuntime(
        self: *SessionManager,
        agent_id: []const u8,
        named_agent: ?NamedAgentConfig,
    ) !*AgentRuntime {
        const runtime = try self.allocator.create(AgentRuntime);
        errdefer self.allocator.destroy(runtime);

        const owned_agent_id = try self.allocator.dupe(u8, agent_id);
        errdefer self.allocator.free(owned_agent_id);

        const workspace_dir = try self.resolveAgentWorkspaceDir(agent_id, named_agent);
        errdefer self.allocator.free(workspace_dir);

        const agent_autonomy: ?config_types.AutonomyConfig = if (named_agent) |cfg| cfg.autonomy else null;

        // Agents with their own autonomy get a dedicated policy (and rate
        // tracker) built from that autonomy. Everyone else keeps sharing the
        // global SessionManager policy so existing configs behave exactly as
        // before.
        var owned_policy: ?*SecurityPolicy = null;
        errdefer if (owned_policy) |policy| destroyAgentSecurityPolicy(self.allocator, policy);
        if (agent_autonomy) |autonomy| {
            owned_policy = try createAgentSecurityPolicy(self.allocator, autonomy, workspace_dir);
        }
        const runtime_policy: ?*const SecurityPolicy = if (owned_policy) |policy| policy else self.policy;
        const runtime_allowed_paths: []const []const u8 = if (agent_autonomy) |autonomy|
            autonomy.allowed_paths
        else
            self.config.autonomy.allowed_paths;

        var mem_rt = memory_mod.initRuntime(self.allocator, &self.config.memory, workspace_dir);
        errdefer if (mem_rt) |*rt| rt.deinit();

        const mem_opt: ?Memory = if (mem_rt) |rt| rt.memory else null;
        const session_store: ?memory_mod.SessionStore = if (mem_rt) |rt| rt.session_store else null;
        const response_cache: ?*memory_mod.cache.ResponseCache = if (mem_rt) |*rt| rt.response_cache else null;

        const bootstrap_provider = bootstrap_mod.createProvider(
            self.allocator,
            self.config.memory.backend,
            mem_opt,
            workspace_dir,
        ) catch null;
        errdefer if (bootstrap_provider) |bp| bp.deinit();

        var project_ctx = onboard.ProjectContext{};
        onboard.scaffoldWorkspace(self.allocator, workspace_dir, &project_ctx, bootstrap_provider) catch {};

        const runtime_tools = tools_mod.allTools(self.allocator, workspace_dir, .{
            .http_enabled = self.config.http_request.enabled,
            .http_allowed_domains = self.config.http_request.allowed_domains,
            .http_max_response_size = self.config.http_request.max_response_size,
            .http_timeout_secs = self.config.http_request.timeout_secs,
            .web_search_base_url = self.config.http_request.search_base_url,
            .web_search_provider = self.config.http_request.search_provider,
            .web_search_fallback_providers = self.config.http_request.search_fallback_providers,
            .browser_enabled = self.config.browser.enabled,
            .screenshot_enabled = true,
            // MCP tools spawn configured servers as child processes and never
            // consult the agent policy; allTools skips them when
            // withhold_escape_hatches is set (an agent with its own autonomy).
            .mcp_server_configs = self.config.mcp_servers,
            .agents = self.config.agents,
            .configured_providers = self.config.providers,
            .fallback_api_key = self.config.defaultProviderKey(),
            .tools_config = self.config.tools,
            .allowed_paths = runtime_allowed_paths,
            .policy = runtime_policy,
            .withhold_escape_hatches = agent_autonomy != null,
            .subagent_manager = self.subagent_manager,
            .bootstrap_provider = bootstrap_provider,
            .backend_name = self.config.memory.backend,
            .sandbox_backend = self.config.security.sandbox.backend,
            .sandbox_enabled = self.config.sandboxEnabled(),
        }) catch &.{};
        errdefer if (runtime_tools.len > 0) tools_mod.deinitTools(self.allocator, runtime_tools);

        runtime.* = .{
            .agent_id = owned_agent_id,
            .workspace_dir = workspace_dir,
            .config = makeAgentConfig(self.config, workspace_dir, named_agent),
            .provider = self.provider,
            .tools = runtime_tools,
            .mem = mem_opt,
            .mem_rt = mem_rt,
            .session_store = session_store,
            .response_cache = response_cache,
            .bootstrap_provider = bootstrap_provider,
            .policy = runtime_policy,
            .owned_policy = owned_policy,
        };

        tools_mod.bindMemoryTools(runtime.tools, runtime.mem);
        if (runtime.mem_rt) |*rt| {
            tools_mod.bindMemoryRuntime(runtime.tools, rt);
        }

        return runtime;
    }

    fn getOrCreateAgentRuntimeLocked(self: *SessionManager, agent_id: []const u8, named_agent: ?NamedAgentConfig) !*AgentRuntime {
        if (self.agent_runtimes.get(agent_id)) |runtime| return runtime;

        const runtime = try self.createAgentRuntime(agent_id, named_agent);
        errdefer {
            runtime.deinit(self.allocator);
            self.allocator.destroy(runtime);
        }
        try self.agent_runtimes.put(self.allocator, runtime.agent_id, runtime);
        return runtime;
    }

    fn pruneUnusedAgentRuntimesLocked(self: *SessionManager) void {
        if (self.agent_runtimes.count() == 0) return;

        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var runtime_it = self.agent_runtimes.iterator();
        while (runtime_it.next()) |entry| {
            const runtime_agent_id = entry.key_ptr.*;
            var in_use = false;

            var session_it = self.sessions.iterator();
            while (session_it.next()) |session_entry| {
                const session_agent_id = parseAgentIdFromSessionKey(session_entry.key_ptr.*);
                if (std.mem.eql(u8, session_agent_id, runtime_agent_id)) {
                    in_use = true;
                    break;
                }
            }

            if (!in_use) {
                to_remove.append(self.allocator, runtime_agent_id) catch continue;
            }
        }

        for (to_remove.items) |agent_id| {
            if (self.agent_runtimes.fetchRemove(agent_id)) |entry| {
                entry.value.deinit(self.allocator);
                self.allocator.destroy(entry.value);
            }
        }
    }

    /// Lazily create the process-wide dsh engine. Allocation only: no spawn,
    /// no network, so it is safe under the session-table lock.
    fn ensureDshEngine(self: *SessionManager) !*dsh_harness_mod.DshEngine {
        if (comptime dsh_enabled) {
            self.dsh_engine.mutex.lock();
            defer self.dsh_engine.mutex.unlock();
            if (self.dsh_engine.state) |*state| return state.engine;

            const config_dir = std_compat.fs.path.dirname(self.config.config_path) orelse ".";
            const dsh_home = try std_compat.fs.path.join(self.allocator, &.{ config_dir, ".dsh" });
            errdefer self.allocator.free(dsh_home);
            const sessions_dir = try std_compat.fs.path.join(self.allocator, &.{ config_dir, "dsh-sessions" });
            defer self.allocator.free(sessions_dir);
            // Only the directory matters; each key derives its own file.
            const session_base = try std.fmt.allocPrint(self.allocator, "{s}/session.json", .{sessions_dir});
            errdefer self.allocator.free(session_base);

            var opts = dsh_harness_mod.DshEngine.Options{
                .sidecar = .{
                    // Empty: resolved from NULLCLAW_DSH_BIN at boot.
                    .bin_js = "",
                    .workspace = self.config.workspace_dir,
                    .dsh_home = dsh_home,
                },
                .boot_url = dsh_test_boot_url,
                .session_file = session_base,
            };

            var profile_base_url: ?[]u8 = null;
            errdefer if (profile_base_url) |value| self.allocator.free(value);
            var profile_model: ?[]u8 = null;
            errdefer if (profile_model) |value| self.allocator.free(value);
            var profile_models: ?[][]const u8 = null;
            errdefer if (profile_models) |value| self.allocator.free(value);

            // Current junclaw provider config -> the dsh route. The route id
            // and credential env name are constants; only these values move.
            if (self.config.default_model) |model_ref| {
                const provider = self.config.default_provider;
                const model = if (model_refs.matchExplicitProviderPrefix(model_ref, provider)) |ref|
                    ref.model
                else
                    model_ref;
                if (model.len > 0) {
                    const endpoint = try dshRouteEndpoint(self.config, provider);
                    profile_base_url = try self.allocator.dupe(u8, endpoint.base_url);
                    profile_model = try self.allocator.dupe(u8, model);
                    const models = try self.allocator.alloc([]const u8, 1);
                    models[0] = profile_model.?;
                    profile_models = models;
                    opts.sidecar.profile = .{
                        .base_url = profile_base_url.?,
                        .api = endpoint.api,
                        .models = profile_models.?,
                        .default_model = profile_model.?,
                        .api_key = self.config.defaultProviderKey(),
                    };
                }
            }

            const engine = try self.allocator.create(dsh_harness_mod.DshEngine);
            errdefer self.allocator.destroy(engine);
            engine.* = dsh_harness_mod.DshEngine.init(self.allocator, opts);
            self.dsh_engine.state = .{
                .allocator = self.allocator,
                .engine = engine,
                .dsh_home = dsh_home,
                .session_base = session_base,
                .profile_base_url = profile_base_url,
                .profile_model = profile_model,
                .profile_models = profile_models,
            };
            return engine;
        } else unreachable;
    }

    /// Find or create a session for the given key. Thread-safe.
    pub fn getOrCreate(self: *SessionManager, session_key: []const u8) !*Session {
        return self.getOrCreateForTurn(session_key, false);
    }

    /// Find or create a session for the given key, optionally marking it as
    /// claimed for an about-to-start turn (`for_turn`).
    ///
    /// `for_turn` is what makes the automatic reset race-free: the claim and
    /// the reset decision happen under the same `SessionManager.mutex` hold,
    /// so a concurrent getOrCreate for the same key cannot reset the session
    /// after a caller has already decided to run a turn in it. The claim is
    /// released by `beginTurn` (which sets `turn_running`) or by
    /// `abandonTurn` on every failure exit of the caller. Caller holds no lock.
    pub fn getOrCreateForTurn(self: *SessionManager, session_key: []const u8, for_turn: bool) !*Session {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_key)) |session| {
            const now = std_compat.time.timestamp();
            // Lazy automatic reset, evaluated before last_active is refreshed
            // so an idle policy can still see the previous interaction.
            // Lock order: SessionManager.mutex -> (agent/memory/store); no
            // reset path acquires session.mutex or re-enters the manager.
            // maybeResetLocked bails out when a turn is running or claimed
            // (turn_pending is set below under this same mutex hold), so a
            // session already claimed for a turn is never reset out from under
            // its caller.
            if (!session.turn_running.load(.acquire)) {
                self.maybeResetLocked(session, now);
            }
            if (for_turn) session.turn_pending.store(true, .release);
            session.last_active = now;
            return session;
        }

        // Create new session
        const owned_key = try self.allocator.dupe(u8, session_key);
        var key_owned_by_session = false;
        errdefer if (!key_owned_by_session) self.allocator.free(owned_key);

        const session = try self.allocator.create(Session);
        session.provider_holder = null;
        session.owned_provider_api_key = null;
        var session_initialized = false;
        errdefer {
            if (session_initialized) session.deinit(self.allocator);
            self.allocator.destroy(session);
        }
        errdefer if (!session_initialized) {
            if (session.provider_holder) |*holder| holder.deinit();
            if (session.owned_provider_api_key) |key| self.allocator.free(key);
        };

        const agent_profile = findProfileForSessionKey(self.config, session_key);
        const parsed_agent_id = parseAgentIdFromSessionKey(session_key);
        const dedicated_runtime = if (self.shouldUseDedicatedRuntime(parsed_agent_id, agent_profile))
            try self.getOrCreateAgentRuntimeLocked(parsed_agent_id, agent_profile)
        else
            null;

        const selected_config: *const Config = if (dedicated_runtime) |rt| &rt.config else self.config;
        const selected_tools: []const Tool = if (dedicated_runtime) |rt| rt.tools else self.tools;
        const selected_mem: ?Memory = if (dedicated_runtime) |rt| rt.mem else self.mem;
        const selected_session_store: ?memory_mod.SessionStore = if (dedicated_runtime) |rt| rt.session_store else self.session_store;
        const selected_response_cache: ?*memory_mod.cache.ResponseCache = if (dedicated_runtime) |rt| rt.response_cache else self.response_cache;
        const selected_mem_rt: ?*memory_mod.MemoryRuntime = if (dedicated_runtime) |rt|
            (if (rt.mem_rt) |*v| v else null)
        else
            self.mem_rt;

        var provider_ctx = try self.resolveProviderForSession(agent_profile);
        errdefer provider_ctx.deinit(self.allocator);

        session.* = undefined;
        session.provider_holder = provider_ctx.holder;
        session.owned_provider_api_key = provider_ctx.owned_api_key;
        provider_ctx.holder = null;
        provider_ctx.owned_api_key = null;

        const session_provider = if (session.provider_holder) |*holder|
            holder.provider()
        else
            provider_ctx.provider.?;

        var agent = try Agent.fromConfigWithProfile(
            self.allocator,
            selected_config,
            session_provider,
            selected_tools,
            selected_mem,
            self.observer,
            agent_profile,
        );
        agent.policy = if (dedicated_runtime) |rt| rt.policy else self.policy;
        agent.session_store = selected_session_store;
        agent.response_cache = selected_response_cache;
        agent.mem_rt = selected_mem_rt;
        agent.memory_session_id = owned_key;
        var owned_memory_session_id: ?[]u8 = null;
        errdefer if (owned_memory_session_id) |sid| self.allocator.free(sid);
        if (agent_profile) |profile| {
            if (profile.workspace_path != null) {
                if (sessionAgentId(session_key)) |agent_id| {
                    owned_memory_session_id = try std.fmt.allocPrint(self.allocator, "agent:{s}", .{agent_id});
                    agent.memory_session_id = owned_memory_session_id.?;
                }
            }
        }
        if (self.config.diagnostics.token_usage_ledger_enabled or self.config.cost.enabled) {
            agent.usage_record_callback = usageRecordForwarder;
            agent.usage_record_ctx = @ptrCast(self);
        }

        const now = std_compat.time.timestamp();
        const session_provider_holder = session.provider_holder;
        const session_owned_provider_api_key = session.owned_provider_api_key;
        session.* = .{
            .agent = agent,
            // The adapter borrows the agent it wraps, so it must be seeded
            // after `session.*` takes the agent.
            .harness = .{ .agent = undefined },
            .provider_holder = session_provider_holder,
            .owned_provider_api_key = session_owned_provider_api_key,
            .owned_memory_session_id = owned_memory_session_id,
            .created_at = now,
            .last_active = now,
            .last_consolidated = 0,
            .session_key = owned_key,
            .turn_count = 0,
            .turn_running = std.atomic.Value(bool).init(false),
            .turn_pending = std.atomic.Value(bool).init(false),
            .turn_closing = std.atomic.Value(bool).init(false),
            .mutex = .{},
        };
        session.harness = native_harness.NativeHarness.init(&session.agent);
        key_owned_by_session = true;
        session_initialized = true;

        if (selected_config.agent.harness == .dsh) {
            session.dsh_native = try DshNativeState.init(self.allocator, selected_config, session);
        }
        if (comptime dsh_enabled) {
            if (selected_config.agent.harness == .dsh_sidecar) {
                // Attach the handle now; the sidecar boots on the first turn.
                session.dsh = try startDshHarness(self, owned_key, &session.agent);
            }
        } else if (selected_config.agent.harness == .dsh_sidecar) {
            warnDshIgnored();
        }

        if (selected_session_store) |store| {
            self.resetStaleRestoredSessionLocked(session, store, now);
        }

        // Restore persisted conversation history from session store.
        // Bound the restored window so a long-lived session cannot re-inflate the
        // per-request context beyond max_history_messages on restore.
        var dsh_native_restored = false;
        if (selected_session_store) |store| {
            const maybe_entries = store.loadMessages(self.allocator, session_key) catch null;
            if (maybe_entries) |entries| {
                defer memory_mod.freeMessages(self.allocator, entries);
                const restored = dropRowsBeforeLastCompactionSummary(
                    recentHistoryWindow(entries, session.agent.max_history_messages),
                );
                if (selected_config.agent.harness == .dsh) {
                    // First open imports this window as the seeded JSONL prefix;
                    // later opens resume the JSONL and ignore the store copy, so
                    // the import neither repeats nor loses rows.
                    try session.dsh_native.?.harness.harness().restore(.{
                        .messages = restored,
                        .session_key = owned_key,
                        .workspace_dir = session.agent.workspace_dir,
                        .dsh_home = session.dsh_native.?.dsh_home,
                    });
                    dsh_native_restored = true;
                } else if (restored.len > 0) {
                    // The native engine has no JSONL of its own; replaying store
                    // rows rebuilds its history.
                    restorePersistedSessionState(session, restored);
                }
                if (try store.loadUsage(session_key)) |total_tokens| {
                    session.agent.total_tokens = total_tokens;
                } else if (restored.len > 0) {
                    session.agent.total_tokens = estimateRestoredSessionTokens(restored);
                }
            }
            if (try store.loadCompactionCount(session_key)) |count| {
                session.agent.compaction_count = count;
            }
        }
        if (selected_config.agent.harness == .dsh and !dsh_native_restored) {
            // No readable store: still resume the engine's own JSONL. The
            // mapping is the resume source, exactly like the sidecar.
            try session.dsh_native.?.harness.harness().restore(.{
                .messages = &.{},
                .session_key = owned_key,
                .workspace_dir = session.agent.workspace_dir,
                .dsh_home = session.dsh_native.?.dsh_home,
            });
        }

        try self.sessions.put(self.allocator, owned_key, session);
        return session;
    }

    /// Reset a stale session through the shared /new path. Caller holds
    /// self.mutex and has verified that no turn is running.
    fn maybeResetLocked(self: *SessionManager, session: *Session, now: i64) void {
        // A turn that is running or merely claimed must never be reset: the
        // claim is set under this same mutex (see getOrCreateForTurn), so this
        // check is race-free.
        if (session.turn_pending.load(.acquire) or session.turn_running.load(.acquire)) return;

        const policy = session_reset.resolvePolicy(self.config.session, session.session_key);
        const tz_offset_secs = config_types.AgentConfig.parseTimezoneOffsetSeconds(self.config.agent.timezone) orelse 0;
        if (!session_reset.isStale(policy, now, session.created_at, session.last_active, tz_offset_secs)) return;

        clearSessionForReset(session);
        session.created_at = now;
        session.last_active = now;
        log.info("session auto-reset key={s} mode={s}", .{ session.session_key, @tagName(policy.mode) });
    }

    /// Wipe the state a reset must clear. Shared by maybeResetLocked and the
    /// restore-time check so both paths clear exactly the same things.
    fn clearSessionForReset(session: *Session) void {
        if (session.dsh_native) |*d| {
            // New dsh session id + JSONL, atomically rewritten mapping.
            d.harness.harness().reset();
            d.reported_total_tokens = 0;
        }
        agent_mod.commands.clearSessionState(&session.agent);
        const store = session.agent.session_store orelse return;
        store.clearMessages(session.session_key) catch {};
        store.clearAutoSaved(session.session_key) catch {};
        // Explicit save under session_key also clears dedicated-runtime keys,
        // whose memory_session_id is `agent:{id}`.
        store.saveCompactionCount(session.session_key, 0) catch {};
    }

    /// Reset a session recreated from the store when its persisted transcript
    /// is stale. Caller holds self.mutex and calls this before restoring
    /// history. Lock order matches maybeResetLocked: manager mutex ->
    /// agent/memory/store; no session.mutex and no re-entry.
    fn resetStaleRestoredSessionLocked(
        self: *SessionManager,
        session: *Session,
        store: memory_mod.SessionStore,
        now: i64,
    ) void {
        const policy = session_reset.resolvePolicy(self.config.session, session.session_key);
        // Default path: no store query at all.
        if (policy.mode == .none) return;

        // OpenClaw src/config/sessions/reset-policy.ts:90-105 maps daily to the
        // first interaction (sessionStartedAt) and idle to the latest
        // (lastInteractionAt); the persisted transcript supplies both.
        const range = (store.loadMessageTimeRange(session.session_key) catch null) orelse return;
        // Clamp future timestamps from clock skew (OpenClaw resolveTimestamp).
        const first = @min(range.first, now);
        const last = @min(range.last, now);
        const tz = config_types.AgentConfig.parseTimezoneOffsetSeconds(self.config.agent.timezone) orelse 0;
        if (!session_reset.isStale(policy, now, first, last, tz)) return;

        clearSessionForReset(session);
        log.info("session auto-reset on restore key={s} mode={s}", .{ session.session_key, @tagName(policy.mode) });
    }

    fn resolveProviderForSession(
        self: *SessionManager,
        agent_profile: ?config_types.NamedAgentConfig,
    ) !SessionProviderContext {
        const profile = agent_profile orelse return .{ .provider = self.provider };

        var owned_api_key: ?[]u8 = null;
        errdefer if (owned_api_key) |key| self.allocator.free(key);

        const provider_api_key = profile.api_key orelse blk: {
            owned_api_key = providers.resolveApiKeyFromConfig(
                self.allocator,
                profile.provider,
                self.config.providers,
            ) catch null;
            break :blk owned_api_key;
        };

        const holder = providers.holderFromConfig(
            self.allocator,
            self.config,
            profile.provider,
            provider_api_key,
        );
        return .{
            .holder = holder,
            .owned_api_key = owned_api_key,
        };
    }

    /// The host side of the port: maps the engine's `Event` union back onto the
    /// two sinks the channels already own. `Event.usage` only reaches the
    /// ledger for dsh-native: the native engine reports usage through
    /// `usage_record_callback` and never emits this event, so there is no
    /// double count either way.
    const PortEventSink = struct {
        stream: ?streaming.Sink,
        progress: ?agent_mod.ProgressSink,
        manager: *SessionManager,
        session: *Session,

        fn emit(ctx: *anyopaque, event: harness_port.Event) void {
            const self: *PortEventSink = @ptrCast(@alignCast(ctx));
            switch (event) {
                .delta => |chunk| {
                    if (self.stream) |sink| streaming.forwardProviderChunk(sink, chunk);
                },
                .progress => |hint| {
                    if (self.progress) |sink| sink.emit(hint);
                },
                .usage => |record| {
                    if (self.session.dsh_native != null) {
                        self.manager.recordHarnessUsage(self.session, record);
                    }
                },
                // dsh-native observational events; the host renders nothing
                // for them yet (P2 wires approval/question/compaction UI).
                else => {},
            }
        }
    };

    /// Pre-port live-draft rule: when the rendered draft would expose text that
    /// must stay redacted, drop non-final deltas and let the final reply print
    /// path display the rehydrated text. The host computes the decision once per
    /// turn, so follow-up turns share the primary turn's decision.
    const SuppressingSink = struct {
        inner: harness_port.Sink,
        suppress_live: bool,

        fn emit(ctx: *anyopaque, event: harness_port.Event) void {
            const self: *SuppressingSink = @ptrCast(@alignCast(ctx));
            if (self.suppress_live) {
                switch (event) {
                    .delta => |chunk| if (!chunk.is_final) return,
                    else => {},
                }
            }
            self.inner.send(event);
        }

        fn sink(self: *SuppressingSink) harness_port.Sink {
            return .{ .ctx = @ptrCast(self), .emit = emit };
        }
    };

    fn shouldRehydrateDisplay(session_key: []const u8, conversation_context: ?ConversationContext) bool {
        const channel = if (conversation_context) |ctx| ctx.channel else null;
        const is_group = if (conversation_context) |ctx| ctx.is_group else null;
        return governance.shouldRehydrateDisplay(session_key, channel, is_group);
    }

    fn shouldSuppressLiveForRedaction(
        redactor_: ?*redaction.Redactor,
        content: []const u8,
        display_rehydrate_allowed: bool,
    ) bool {
        if (!display_rehydrate_allowed) return false;
        const r = redactor_ orelse return false;
        return r.wouldRehydrate() or (r.config.record_originals and r.wouldRedact(content));
    }

    fn usageRecordForwarder(ctx_ptr: *anyopaque, record: Agent.UsageRecord) void {
        const self: *SessionManager = @ptrCast(@alignCast(ctx_ptr));
        self.appendUsageRecord(record);
    }

    /// Native parity for `memory.auto_recall`: run the same retrieval pipeline
    /// with the same parameters and return the `[Memory context]` block the
    /// dsh runtime-context message should carry for this turn. The native
    /// engine recalls against the redacted user message and redacts the block
    /// before it reaches history; this does both. Null when recall is off or
    /// has nothing to inject.
    fn recallMemoryContext(self: *SessionManager, session: *Session, content: []const u8) !?[]const u8 {
        const mem = session.agent.mem orelse return null;
        if (!session.agent.auto_recall) return null;
        const params = agent_mod.memory_loader.RecallParams{
            .recall_limit = session.agent.recall_limit,
            .max_context_bytes = session.agent.max_context_bytes,
        };
        const safe = if (session.agent.redactor) |r|
            r.redact(self.allocator, content) catch null
        else
            null;
        defer if (safe) |text| self.allocator.free(text);
        const query = safe orelse content;
        const block = if (session.agent.mem_rt) |rt|
            agent_mod.memory_loader.loadContextWithRuntime(
                self.allocator,
                rt,
                query,
                session.agent.memory_session_id,
                params,
            ) catch return null
        else
            agent_mod.memory_loader.loadContext(
                self.allocator,
                mem,
                query,
                session.agent.memory_session_id,
                params,
            ) catch return null;
        if (block.len == 0) {
            self.allocator.free(block);
            return null;
        }
        const redactor = session.agent.redactor orelse return block;
        const redacted = redactor.redact(self.allocator, block) catch {
            self.allocator.free(block);
            return null;
        };
        self.allocator.free(block);
        return redacted;
    }

    /// dsh-native usage: the in-process engine never calls
    /// `usage_record_callback`, so its `Event.usage` goes through the same
    /// ledger path here. Native and sidecar sessions never take this branch.
    fn recordHarnessUsage(self: *SessionManager, session: *Session, record: Agent.UsageRecord) void {
        const d = if (session.dsh_native) |*value| value else return;
        var usage = record.usage;
        if (usage.total_tokens == 0 and (usage.prompt_tokens > 0 or usage.completion_tokens > 0)) {
            usage.total_tokens = usage.prompt_tokens +| usage.completion_tokens;
        }
        d.usage_events += 1;
        session.agent.total_tokens +|= usage.total_tokens;
        session.agent.last_turn_usage = usage;
        session.agent.total_cost_usd += cost_mod.TokenUsage.fromProviders(record.model, usage).cost();
        if (usage.total_tokens > 0) {
            const metric = observability.ObserverMetric{ .tokens_used = usage.total_tokens };
            self.observer.recordMetric(&metric);
        }
        self.appendUsageRecord(.{
            .ts = record.ts,
            .provider = record.provider,
            .model = record.model,
            .usage = usage,
            .success = record.success,
        });
    }

    /// Fallback when the engine emitted no `Event.usage` this turn (a provider
    /// that omits usage, or a sink-less path): account the cumulative
    /// `TurnResult.total_tokens` delta once. When events were seen the ledger
    /// already has them, so only the baseline moves.
    fn reconcileHarnessUsage(self: *SessionManager, session: *Session, total: u64, events_before: u64) void {
        const d = if (session.dsh_native) |*value| value else return;
        if (d.usage_events == events_before and total > d.reported_total_tokens) {
            const delta: u32 = @intCast(@min(total - d.reported_total_tokens, std.math.maxInt(u32)));
            self.recordHarnessUsage(session, .{
                .ts = std_compat.time.timestamp(),
                .provider = session.agent.provider.getName(),
                .model = session.agent.model_name,
                .usage = .{ .total_tokens = delta },
                .success = true,
            });
        }
        d.reported_total_tokens = total;
    }

    fn usageLedgerPath(self: *SessionManager) ?[]u8 {
        if (!self.config.diagnostics.token_usage_ledger_enabled) return null;
        const config_dir = std_compat.fs.path.dirname(self.config.config_path) orelse return null;
        return std_compat.fs.path.join(self.allocator, &.{ config_dir, TOKEN_USAGE_LEDGER_FILENAME }) catch null;
    }

    fn usageWindowSeconds(self: *SessionManager) i64 {
        const hours = self.config.diagnostics.token_usage_ledger_window_hours;
        if (hours == 0) return 0;
        return @as(i64, @intCast(hours)) * 60 * 60;
    }

    fn countLedgerLines(file: *std_compat.fs.File) !u64 {
        try file.seekTo(0);
        var lines: u64 = 0;
        var saw_data = false;
        var last_byte: u8 = '\n';
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try file.read(&buf);
            if (n == 0) break;
            saw_data = true;
            last_byte = buf[n - 1];
            lines += @intCast(std.mem.count(u8, buf[0..n], "\n"));
        }
        if (saw_data and last_byte != '\n') lines += 1;
        return lines;
    }

    fn initializeUsageLedgerState(
        self: *SessionManager,
        file: *std_compat.fs.File,
        stat: std_compat.fs.File.Stat,
        now_ts: i64,
    ) void {
        if (self.usage_ledger_state_initialized) return;
        self.usage_ledger_state_initialized = true;
        if (stat.size > 0) {
            const mtime_secs: i64 = @intCast(@divFloor(stat.mtime, NS_PER_SEC));
            self.usage_ledger_window_started_at = if (mtime_secs > 0) mtime_secs else now_ts;
            if (self.config.diagnostics.token_usage_ledger_max_lines > 0) {
                self.usage_ledger_line_count = countLedgerLines(file) catch 0;
            } else {
                self.usage_ledger_line_count = 0;
            }
        } else {
            self.usage_ledger_window_started_at = now_ts;
            self.usage_ledger_line_count = 0;
        }
    }

    fn shouldResetUsageLedger(
        self: *SessionManager,
        stat: std_compat.fs.File.Stat,
        now_ts: i64,
        pending_bytes: usize,
        pending_lines: u64,
    ) bool {
        const window_secs = self.usageWindowSeconds();
        if (window_secs > 0) {
            const started_at = self.usage_ledger_window_started_at;
            if (started_at > 0 and now_ts - started_at >= window_secs) return true;
        }

        const max_bytes = self.config.diagnostics.token_usage_ledger_max_bytes;
        if (max_bytes > 0) {
            const projected = @as(u64, @intCast(stat.size)) + @as(u64, @intCast(pending_bytes));
            if (projected > max_bytes) return true;
        }

        const max_lines = self.config.diagnostics.token_usage_ledger_max_lines;
        if (max_lines > 0 and self.usage_ledger_line_count + pending_lines > max_lines) return true;

        return false;
    }

    fn appendUsageRecord(self: *SessionManager, record: Agent.UsageRecord) void {
        self.usage_log_mutex.lock();
        defer self.usage_log_mutex.unlock();

        if (self.cost_tracker) |*tracker| {
            const usage = cost_mod.TokenUsage.fromProviders(record.model, record.usage);
            tracker.recordUsage(usage) catch |err| {
                log.err("Failed to record usage in CostTracker: {s}", .{@errorName(err)});
            };
        }

        const ledger_path = self.usageLedgerPath() orelse return;
        defer self.allocator.free(ledger_path);

        var file = fs_compat.openPathForAppend(ledger_path) catch return;
        var file_needs_close = true;
        defer if (file_needs_close) file.close();

        const now_ts = std_compat.time.timestamp();
        const stat = fs_compat.stat(file) catch return;
        self.initializeUsageLedgerState(&file, stat, now_ts);

        const record_line = std.fmt.allocPrint(
            self.allocator,
            "{{\"ts\":{d},\"provider\":{f},\"model\":{f},\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d},\"success\":{}}}\n",
            .{
                record.ts,
                std.json.fmt(record.provider, .{}),
                std.json.fmt(record.model, .{}),
                record.usage.prompt_tokens,
                record.usage.completion_tokens,
                record.usage.total_tokens,
                record.success,
            },
        ) catch return;
        defer self.allocator.free(record_line);

        const pending_bytes: usize = record_line.len;
        if (self.shouldResetUsageLedger(stat, now_ts, pending_bytes, 1)) {
            file.close();
            file_needs_close = false;
            file = std_compat.fs.createFileAbsolute(ledger_path, .{ .truncate = true, .read = true }) catch return;
            file_needs_close = true;
            self.usage_ledger_state_initialized = true;
            self.usage_ledger_window_started_at = now_ts;
            self.usage_ledger_line_count = 0;
        }

        // Zig 0.15 buffered File.writer ignores manual seek position for append-style writes.
        // Use direct file.writeAll after seek to guarantee true append semantics.
        file.seekFromEnd(0) catch return;
        file.writeAll(record_line) catch return;

        if (self.usage_ledger_window_started_at == 0) {
            self.usage_ledger_window_started_at = now_ts;
        }
        if (self.config.diagnostics.token_usage_ledger_max_lines > 0) {
            self.usage_ledger_line_count += 1;
        }
    }

    /// Process a message within a session context.
    /// Finds or creates the session, locks it, runs agent.turn(), returns owned response.
    pub fn processMessage(self: *SessionManager, session_key: []const u8, content: []const u8, conversation_context: ?ConversationContext) ![]const u8 {
        return self.processMessageStreaming(session_key, content, conversation_context, null, null);
    }

    fn lockSessionForTurn(session: *Session) void {
        session.mutex.lock();
    }

    /// Promote a session claimed by `getOrCreateForTurn` to a running turn.
    /// The caller owns `session` for the whole turn, so it clears the pending
    /// claim itself once `turn_running` is visible; no manager lock is needed.
    ///
    /// Order matters: `turn_running` must be visible before `turn_pending` is
    /// dropped, otherwise a concurrent getOrCreate could observe both as false
    /// and reset a session whose turn is about to start.
    fn beginTurn(session: *Session) void {
        session.turn_closing.store(false, .release);
        session.turn_running.store(true, .release);
        session.turn_pending.store(false, .release);
    }

    /// Release a claim left behind by a `getOrCreateForTurn` whose caller is
    /// unwinding, so a later getOrCreate can still reset a stale session.
    /// `turn_pending` is owned by `SessionManager.mutex`, so it is cleared
    /// under that mutex, and only by this path: a live turn clears it itself
    /// (see beginTurn) before it ever releases the session.
    fn abandonTurn(self: *SessionManager, session: *Session) void {
        if (!session.turn_pending.load(.acquire)) return;
        self.mutex.lock();
        session.turn_pending.store(false, .release);
        self.mutex.unlock();
    }

    /// Result of routing and processing an inbound message. `reply` is owned by
    /// the session manager allocator and is null when no turn ran.
    pub const InboundResult = struct {
        action: InboundRouteAction = .process,
        reply: ?[]const u8 = null,
    };

    /// Route and process an inbound message. The action tells the transport
    /// whether the running turn consumed the message (steered/skip) or it was
    /// dropped, so it can acknowledge or notify the sender instead of staying
    /// silent.
    pub fn processInboundMessage(self: *SessionManager, session_key: []const u8, content: []const u8, conversation_context: ?ConversationContext) !InboundResult {
        const action = self.routeInbound(session_key, content);
        if (action.skipsTurn()) return .{ .action = action };
        return .{ .reply = try self.processMessage(session_key, content, conversation_context) };
    }

    /// Streaming variant of processInboundMessage.
    pub fn processInboundMessageStreaming(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        conversation_context: ?ConversationContext,
        stream_sink: ?streaming.Sink,
        progress_sink: ?agent_mod.ProgressSink,
    ) !InboundResult {
        const action = self.routeInbound(session_key, content);
        if (action.skipsTurn()) return .{ .action = action };
        return .{ .reply = try self.processMessageStreaming(session_key, content, conversation_context, stream_sink, progress_sink) };
    }

    /// Handle a slash command against the live session without invoking the LLM turn loop.
    /// Used for transport-driven local UIs such as Telegram callback menus.
    pub fn handleLocalSlashCommand(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        conversation_context: ?ConversationContext,
    ) !?[]const u8 {
        // The claim is registered before the session lock, so Zig's LIFO
        // unwinding releases it only once the lock is gone: the whole local
        // command is protected from a concurrent reset, and the session never
        // reports itself busy (`turn_running` stays false), so a concurrent
        // message still starts its own turn instead of steering into a buffer
        // this path never drains.
        const session = try self.getOrCreateForTurn(session_key, true);
        defer self.abandonTurn(session);

        lockSessionForTurn(session);
        defer session.mutex.unlock();

        session.agent.conversation_context = conversation_context;
        defer session.agent.conversation_context = null;
        setTurnToolContext(session.agent.tools, session_key, conversation_context);

        const maybe_response = try session.handleLocalCommand(content);
        if (maybe_response == null) return null;

        session.turn_count += 1;
        session.last_active = std_compat.time.timestamp();

        if (session.agent.session_store) |store| {
            const turn_input = agent_mod.commands.planTurnInput(content);
            if (turn_input.clear_session) {
                store.clearMessages(session_key) catch {};
                store.clearAutoSaved(session_key) catch {};
            }
            if (agent_mod.commands.persistedRuntimeCommand(content)) |runtime_command| {
                store.saveMessage(session_key, RUNTIME_COMMAND_ROLE, runtime_command) catch {};
            }
        }

        // Same session-boundary attachment filter as processMessageStreaming:
        // a slash command's reply leaves the session here too (this backs the
        // Telegram callback menus), so a command that emitted a local-file
        // marker must be filtered for a restricted agent as well.
        return try self.filterOutboundAttachmentMarkers(session, maybe_response.?);
    }

    /// Drop legacy outbound attachment markers whose local target does not
    /// resolve inside `session`'s agent workspace (+ its allowed_paths). An
    /// agent with its own autonomy must not be able to exfiltrate host files
    /// through `[DOCUMENT:/abs/path]`-style markers in its reply text: the
    /// outbound channels (telegram, max, signal, …) upload any absolute path
    /// the reply names with no policy check, independent of tool calls (so this
    /// also covers read_only). Returns an owned copy of `response` and frees the
    /// input when a filter runs; an agent without its own autonomy is returned
    /// unchanged.
    fn filterOutboundAttachmentMarkers(
        self: *SessionManager,
        session: *Session,
        response: []const u8,
    ) ![]const u8 {
        // The port has no attachment-scope surface yet, so reach the native
        // agent for this one field set.
        const agent = session.nativeAgent();
        if (!agent.has_own_autonomy) return response;
        const scope = outbound_mod.AttachmentScope{
            .workspace_dir = agent.workspace_dir,
            .allowed_paths = agent.allowed_paths,
        };
        const filtered = try outbound_mod.stripEscapingAttachmentMarkers(self.allocator, response, scope);
        self.allocator.free(response);
        return filtered;
    }

    const SteerDrainContext = struct {
        session: *Session,
        allocator: Allocator,
        refs: *std.ArrayListUnmanaged(ConsumedRef),

        fn callback(ctx: *anyopaque, agent_allocator: Allocator) !?[]u8 {
            const dc: *@This() = @ptrCast(@alignCast(ctx));
            return dc.session.drainInjectionWithRefs(dc.allocator, agent_allocator, dc.refs);
        }
    };

    /// User-facing text for a dsh turn that failed with a Zig error. Null
    /// means "not a dsh failure the user can act on", so the error propagates
    /// unchanged (OOM, protocol bugs, native-path errors).
    fn dshTurnErrorMessage(allocator: Allocator, err: anyerror) ?[]const u8 {
        const text = switch (err) {
            error.SidecarBootFailed => "dsh 引擎启动失败，请检查 dsh 安装与配置后重试。",
            error.ConnectionLost => "与 dsh 引擎的连接已断开，请稍后重试。",
            error.TurnTimeout => "dsh 引擎响应超时，请稍后重试。",
            error.WsHandshakeFailed => "无法与 dsh 引擎建立连接（WebSocket 握手失败），请稍后重试。",
            error.DshProviderUnsupported => "该 provider 不支持 dsh harness，请用 agent.harness=native 或换 provider。",
            error.DshProviderUrlInvalid => "dsh 路由的 provider base_url 无效，请检查 models.providers 配置。",
            else => return null,
        };
        return allocator.dupe(u8, text) catch null;
    }

    /// dsh reports an upstream provider failure (500/429) as `turn_result.error`
    /// text while returning an empty or partial reply. Keep any partial reply
    /// and append the mapped failure so the user sees why the turn ended.
    fn dshFailedTurnReply(allocator: Allocator, upstream: []const u8, partial: []const u8) ![]const u8 {
        if (partial.len == 0)
            return std.fmt.allocPrint(allocator, "上游模型服务返回错误：{s}", .{upstream});
        return std.fmt.allocPrint(allocator, "{s}\n\n上游模型服务返回错误：{s}", .{ partial, upstream });
    }

    /// Track every message consumed by one Agent.turn, including messages
    /// drained while a post-turn follow-up is itself running.
    ///
    /// `drain_enabled` reproduces the old guard "only install the per-turn
    /// drain when the streaming entry point already installed one": a
    /// standalone drain helper never installs it, so a real turn does.
    fn runTurnWithSteerSink(
        self: *SessionManager,
        session: *Session,
        refs: *std.ArrayListUnmanaged(ConsumedRef),
        steer_sink: ?SteerReactionSink,
        turn_input: harness_port.TurnInput,
        drain_enabled: bool,
    ) ![]const u8 {
        var ctx = SteerDrainContext{ .session = session, .allocator = self.allocator, .refs = refs };
        var drain: ?agent_mod.DrainCallback = null;
        var drain_ctx: ?*anyopaque = null;
        if (drain_enabled) {
            drain = SteerDrainContext.callback;
            drain_ctx = @ptrCast(&ctx);
        }
        // A /stop that landed during this turn is spent once the turn returns,
        // even when the turn failed before Agent.turn could consume the flag
        // (e.g. error.RateLimited). Clear it so a follow-up turn for a steered
        // message cannot inherit it and answer "Interrupted by /stop" without
        // ever calling the provider.
        defer session.clearInterrupt();
        const usage_events_before = if (session.dsh_native) |*d| d.usage_events else 0;
        var harness_ran = false;
        const turn_result = blk: {
            // `Agent.turn` is native-only: an engine that owns turns receives
            // the prompt itself, so a local command would reach it as text.
            // Answer known commands on the engine instead. A pre-turn /stop
            // still wins like native's: leave it for runTurn, which aborts
            // before the prompt.
            if (session.dsh_native) |*d| {
                if (!d.harness.interruptPending() and
                    agent_mod.commands.isKnownSlashCommand(turn_input.user_message))
                {
                    break :blk harness_port.TurnResult{
                        .reply = try session.handleLocalCommand(turn_input.user_message) orelse
                            return error.SlashCommandDispatchMismatch,
                    };
                }
            }
            if (comptime dsh_enabled) {
                if (session.dsh) |*d| {
                    if (!d.harness.interruptPending() and
                        agent_mod.commands.isKnownSlashCommand(turn_input.user_message))
                    {
                        break :blk harness_port.TurnResult{
                            .reply = try session.handleLocalCommand(turn_input.user_message) orelse
                                return error.SlashCommandDispatchMismatch,
                        };
                    }
                }
            }
            // The adapter is the session's turn engine; hand it the real key so
            // its display-trust decisions match the host's (the key can be
            // renamed when a legacy session is canonicalized, so set it per turn).
            var input = turn_input;
            input.drain = drain;
            input.drain_ctx = drain_ctx;
            const result = session.turnHarness().runTurn(input) catch |err| {
                finalizeSteerRefs(steer_sink, self.allocator, refs, .failed);
                // A dsh engine failure is a reply the user can act on; native
                // errors keep propagating to the existing classification path.
                if (comptime dsh_enabled) {
                    if (session.dsh != null) {
                        if (dshTurnErrorMessage(self.allocator, err)) |message| {
                            session.agent.last_turn_interrupted = false;
                            return message;
                        }
                    }
                }
                return err;
            };
            harness_ran = true;
            break :blk result;
        };
        // Regression: the port's failure text was only freed, so a dsh turn
        // that ended with an upstream 500/429 surfaced as an empty reply. The
        // in-process engine reports failures the same way.
        if (session.dsh != null or session.dsh_native != null) {
            if (turn_result.@"error") |message| {
                defer self.allocator.free(message);
                defer self.allocator.free(turn_result.reply);
                session.agent.last_turn_interrupted = false;
                finalizeSteerRefs(steer_sink, self.allocator, refs, .failed);
                return try dshFailedTurnReply(self.allocator, message, turn_result.reply);
            }
        }
        // Only `reply` is returned; the port hands failure text to the host.
        defer if (turn_result.@"error") |message| self.allocator.free(message);
        // Engines report interruption through the port; the host's /stop tail
        // (pending-injection discard and notices) reads the agent flag. The
        // in-process kernel reports /stop as `.aborted` with a user cause.
        session.agent.last_turn_interrupted = turn_result.end_reason == .interrupted or
            (session.dsh_native != null and turn_result.end_reason == .aborted);
        if (harness_ran and session.dsh_native != null) {
            self.reconcileHarnessUsage(session, turn_result.total_tokens, usage_events_before);
        }
        finalizeSteerRefs(steer_sink, self.allocator, refs, .done);
        return turn_result.reply;
    }

    /// Drain one pending post-turn injection and run it as a follow-up turn.
    /// Returns true when a pending injection was consumed. A failed follow-up
    /// is reported in the reply and never re-queued: the sender is asked to
    /// resend it.
    fn drainLateInjection(
        self: *SessionManager,
        session: *Session,
        session_key: []const u8,
        response: *[]const u8,
        completed_turns: *u64,
        steer_sink: ?SteerReactionSink,
        live_stream: bool,
        sink: ?harness_port.Sink,
    ) !bool {
        var refs: std.ArrayListUnmanaged(ConsumedRef) = .empty;
        defer freeConsumedRefs(self.allocator, &refs);
        const late_content = (try session.drainInjectionWithRefs(self.allocator, self.allocator, &refs)) orelse return false;
        defer self.allocator.free(late_content);

        // An engine that owns its inbox already folded every steer it accepted
        // into the turn. A message still pending here arrived after the final
        // step, so it runs as a new turn (dsh followup semantics), with its own
        // persisted transcript row, instead of being merged into the primary
        // turn. This host returns one reply per inbound message, so the
        // transport string joins both replies with "\n\n" (see the combine
        // below) for every engine, and the preview must carry the same join.
        // Regression: the combined reply joins the two turns with "\n\n" but
        // nothing streamed that separator, so the preview (primary followed by
        // the follow-up's own stream) was not a prefix of the reply. Emit it
        // before the follow-up turn starts streaming. The adapter restores the
        // agent callback after every turn, so writing to agent.stream_callback
        // here would be dropped; go through the host's suppressing sink so the
        // live-draft rule applies to the separator exactly as before the port.
        if (live_stream) {
            if (sink) |s| s.send(.{ .delta = providers.StreamChunk.textDelta("\n\n") });
        }
        const follow_up_response = self.runTurnWithSteerSink(session, &refs, steer_sink, .{
            .user_message = late_content,
            .conversation_context = session.agent.conversation_context,
            .memory_session_id = session.agent.memory_session_id,
            .live_stream = live_stream,
            .sink = sink,
        }, true) catch |err| {
            // Regression: a failed tail-window follow-up dropped the acked
            // injection, so the user's steered message vanished. Keep the
            // completed primary reply and tell the sender to resend it.
            log.warn("post-turn follow-up turn failed: {}", .{err});
            self.persistTurnResult(session, session_key, late_content, null);
            var err_buf: [256]u8 = undefined;
            const notice = providers.userErrorMessage(&err_buf, err, true);
            const combined = std.fmt.allocPrint(
                self.allocator,
                "{s}\n\n[Follow-up turn failed: {s} {s}]",
                .{ response.*, notice, FOLLOW_UP_FAILED_NOTICE },
            ) catch return true;
            self.allocator.free(response.*);
            response.* = combined;
            return true;
        };
        self.persistTurnResult(session, session_key, late_content, follow_up_response);
        // Combine both answers instead of replacing the primary reply with the
        // follow-up's.
        const combined = std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ response.*, follow_up_response }) catch {
            log.warn("post-turn follow-up reply could not be combined; keeping the primary reply", .{});
            self.allocator.free(follow_up_response);
            completed_turns.* += 1;
            return true;
        };
        self.allocator.free(response.*);
        self.allocator.free(follow_up_response);
        response.* = combined;
        completed_turns.* += 1;
        if (session.agent.last_turn_interrupted) {
            // The follow-up was stopped: drop newer steered messages instead
            // of running them as yet another turn.
            session.closeInjectionWindow();
            if ((session.discardPendingInjections(self.allocator) catch 0) > 0) {
                const with_notice = std.fmt.allocPrint(
                    self.allocator,
                    "{s}\n\n{s}",
                    .{ response.*, STOP_DISCARDED_NOTICE },
                ) catch null;
                if (with_notice) |text| {
                    self.allocator.free(response.*);
                    response.* = text;
                }
            }
        }
        return true;
    }

    /// Run acknowledged mid-turn injections after the primary turn failed.
    /// Returns the combined successful follow-up replies with any failure
    /// notices (owned by the session manager allocator), or null when none was
    /// pending or none succeeded (the caller then returns the original primary
    /// error). Every drained message is consumed exactly once: a failed
    /// follow-up contributes a resend notice and the loop keeps draining newer
    /// messages, so a message acknowledged while the failing follow-up ran is
    /// never left pending. Drain errors never replace the original turn error.
    fn drainInjectionsAfterFailedTurn(
        self: *SessionManager,
        session: *Session,
        session_key: []const u8,
        completed_turns: *u64,
        session_hash: u64,
        steer_sink: ?SteerReactionSink,
        live_stream: bool,
        sink: ?harness_port.Sink,
    ) !?[]const u8 {
        var reply: ?[]const u8 = null;
        // Notices for failed follow-ups. Held separately so they are only
        // delivered when a successful reply exists to carry them.
        var failures: ?[]const u8 = null;
        var drain_count: u32 = 0;
        while (drain_count < MAX_POST_TURN_INJECTION_DRAINS) : (drain_count += 1) {
            var refs: std.ArrayListUnmanaged(ConsumedRef) = .empty;
            defer freeConsumedRefs(self.allocator, &refs);
            const late_content = session.drainInjectionWithRefs(self.allocator, self.allocator, &refs) catch |err| {
                // Preserve the primary turn error: the caller returns it when
                // no follow-up reply exists.
                log.warn("post-turn injection drain failed session=0x{x} err={}", .{ session_hash, err });
                break;
            } orelse break;
            defer self.allocator.free(late_content);

            const follow_up_response = self.runTurnWithSteerSink(session, &refs, steer_sink, .{
                .user_message = late_content,
                .conversation_context = session.agent.conversation_context,
                .memory_session_id = session.agent.memory_session_id,
                .live_stream = live_stream,
                .sink = sink,
            }, false) catch |err| {
                log.warn("post-turn injection after failed turn also failed session=0x{x} err={}", .{ session_hash, err });
                self.persistTurnResult(session, session_key, late_content, null);
                var err_buf: [256]u8 = undefined;
                const notice = providers.userErrorMessage(&err_buf, err, true);
                const failure = std.fmt.allocPrint(
                    self.allocator,
                    "[Follow-up turn failed: {s} {s}]",
                    .{ notice, FOLLOW_UP_FAILED_NOTICE },
                ) catch break;
                if (failures) |previous| {
                    const combined = std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ previous, failure }) catch {
                        self.allocator.free(failure);
                        break;
                    };
                    self.allocator.free(previous);
                    self.allocator.free(failure);
                    failures = combined;
                } else {
                    failures = failure;
                }
                // Keep draining: newer messages were acknowledged too, and a
                // slash-command turn never drains them later.
                continue;
            };
            self.persistTurnResult(session, session_key, late_content, follow_up_response);
            // Keep every successful reply instead of delivering only the last.
            const combined = if (reply) |previous|
                std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ previous, follow_up_response }) catch {
                    self.allocator.free(follow_up_response);
                    break;
                }
            else
                follow_up_response;
            if (reply) |previous| {
                self.allocator.free(previous);
                // `combined` is a fresh copy; the follow-up reply itself is
                // no longer referenced.
                self.allocator.free(follow_up_response);
            }
            reply = combined;
            completed_turns.* += 1;
            if (session.agent.last_turn_interrupted) {
                // A stop during a follow-up ends the drain: drop newer steered
                // messages instead of running them as further turns.
                session.closeInjectionWindow();
                const discarded = session.discardPendingInjections(self.allocator) catch 0;
                if (discarded > 0) {
                    if (reply) |previous| {
                        const with_notice = std.fmt.allocPrint(
                            self.allocator,
                            "{s}\n\n{s}",
                            .{ previous, STOP_DISCARDED_NOTICE },
                        ) catch null;
                        if (with_notice) |text| {
                            self.allocator.free(previous);
                            reply = text;
                        }
                    }
                }
                break;
            }
        }
        if (drain_count == MAX_POST_TURN_INJECTION_DRAINS and session.hasInjection()) {
            log.warn("post-turn injection drain limit reached session=0x{x}", .{session_hash});
        }
        if (reply) |successes| {
            if (failures) |notices| {
                const combined = std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ successes, notices }) catch {
                    self.allocator.free(notices);
                    return successes;
                };
                self.allocator.free(successes);
                self.allocator.free(notices);
                return combined;
            }
            return successes;
        }
        // Nothing succeeded: free the notices and let the caller return the
        // original primary error; there is no reply to carry them.
        if (failures) |notices| self.allocator.free(notices);
        return null;
    }

    /// Persist one completed (or failed) turn. A failed turn stores its user
    /// message without an assistant reply, so a later follow-up can never be
    /// persisted under the wrong prompt. Follow-up turns call this in order,
    /// keeping the session store aligned with what the user actually saw.
    fn persistTurnResult(
        self: *SessionManager,
        session: *Session,
        session_key: []const u8,
        content: []const u8,
        response: ?[]const u8,
    ) void {
        const store = session.agent.session_store orelse return;
        const persisted_content = if (session.agent.redactor) |r|
            r.redact(self.allocator, content) catch null
        else
            null;
        defer if (persisted_content) |text| self.allocator.free(text);

        var persisted_response: ?[]const u8 = null;
        if (response) |resp| {
            persisted_response = if (session.agent.redactor) |r|
                r.redact(self.allocator, resp) catch null
            else
                null;
        }
        defer if (persisted_response) |text| self.allocator.free(text);

        turn_persistence.persistTurn(store, .{
            .history = session.agent.history.items,
            .total_tokens = session.agent.total_tokens,
        }, session_key, persisted_content orelse content, if (response) |resp| persisted_response orelse resp else null);
    }

    /// Process a message within a session context and optionally forward text deltas and progress hints.
    /// Deltas are only emitted when provider streaming is active.
    pub fn processMessageStreaming(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        conversation_context: ?ConversationContext,
        stream_sink: ?streaming.Sink,
        progress_sink: ?agent_mod.ProgressSink,
    ) ![]const u8 {
        return self.processMessageStreamingWithSteerSink(
            session_key,
            content,
            conversation_context,
            stream_sink,
            progress_sink,
            null,
        );
    }

    /// Streaming turn with an optional sink that finalizes the lifecycle
    /// reactions of messages steered into this turn (or into a post-turn
    /// follow-up), using the outcome of the turn that consumed them.
    pub fn processMessageStreamingWithSteerSink(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        conversation_context: ?ConversationContext,
        stream_sink: ?streaming.Sink,
        progress_sink: ?agent_mod.ProgressSink,
        steer_sink: ?SteerReactionSink,
    ) ![]const u8 {
        const channel = if (conversation_context) |ctx| (ctx.channel orelse "unknown") else "unknown";
        const session_hash = std.hash.Wyhash.hash(0, session_key);

        if (self.config.diagnostics.log_message_receipts) {
            log.info("message receipt channel={s} session=0x{x} bytes={d}", .{ channel, session_hash, content.len });
        }
        if (self.config.diagnostics.log_message_payloads) {
            var preview = safeMessageLogPreview(self.allocator, content);
            defer preview.deinit(self.allocator);
            log.info(
                "message inbound channel={s} session=0x{x} bytes={d} content={f}{s}",
                .{
                    channel,
                    session_hash,
                    content.len,
                    std.json.fmt(preview.slice, .{}),
                    if (preview.truncated) " [log preview truncated]" else "",
                },
            );
        }

        if (self.maybeHandleClaimGate(session_key, content, conversation_context)) |gate_reply| {
            if (self.config.diagnostics.log_message_payloads) {
                var preview = safeMessageLogPreview(self.allocator, gate_reply);
                defer preview.deinit(self.allocator);
                log.info(
                    "message outbound channel={s} session=0x{x} bytes={d} content={f}{s}",
                    .{
                        channel,
                        session_hash,
                        gate_reply.len,
                        std.json.fmt(preview.slice, .{}),
                        if (preview.truncated) " [truncated]" else "",
                    },
                );
            }
            return gate_reply;
        }

        const session = self.getOrCreateForTurn(session_key, true) catch |err| {
            // dsh routing failures surface while creating the session; return
            // the actionable text instead of a bare Zig error name.
            if (dshTurnErrorMessage(self.allocator, err)) |message| return message;
            return err;
        };
        errdefer self.abandonTurn(session);

        // A /stop that landed before this session existed recorded a pre-turn
        // interrupt in the manager; consume it before the turn lock so the
        // turn sees it at its first provider call instead of running to
        // completion.
        {
            self.mutex.lock();
            const pending_start = self.takePendingStartInterruptLocked(session_key);
            self.mutex.unlock();
            if (pending_start) session.requestInterrupt();
        }

        lockSessionForTurn(session);
        defer session.mutex.unlock();
        // Promotes the claim from getOrCreateForTurn into a running turn.
        beginTurn(session);
        defer {
            // Clear the busy flag first: a router that observes it must not
            // deposit into a turn that is already gone.
            session.turn_running.store(false, .release);
            session.turn_closing.store(false, .release);
            session.clearInterrupt();
        }

        // Keep the handoff under the turn mutex, after closing injections, so
        // cleanup cannot take refs belonging to the next turn.
        defer {
            session.closeInjectionWindow();
            var discarded = session.takeDiscardedRefs();
            finalizeSteerRefs(steer_sink, self.allocator, &discarded, .failed);
        }

        // Set conversation context for this turn.
        session.agent.conversation_context = conversation_context;
        defer session.agent.conversation_context = null;
        setTurnToolContext(session.agent.tools, session_key, conversation_context);

        // The stream/progress install block and the agent_start observer event
        // moved verbatim into the native adapter (src/harness/native.zig
        // runTurn); the host now only describes what it wants observed.
        const display_rehydrate_allowed = shouldRehydrateDisplay(session_key, conversation_context);
        // The adapter forwards raw chunks; live-draft suppression is the host's
        // policy, decided once from the primary content (as before the port).
        const suppress_live = shouldSuppressLiveForRedaction(session.agent.redactor, content, display_rehydrate_allowed);

        var port_sink_ctx = PortEventSink{
            .stream = stream_sink,
            .progress = progress_sink,
            .manager = self,
            .session = session,
        };
        var suppressing_sink = SuppressingSink{
            .inner = .{ .ctx = @ptrCast(&port_sink_ctx), .emit = PortEventSink.emit },
            .suppress_live = suppress_live,
        };
        // dsh-native reports usage only through the sink, so it is installed
        // even when the channel has no live stream to feed.
        const port_sink: ?harness_port.Sink =
            if (stream_sink != null or progress_sink != null or session.dsh_native != null)
                suppressing_sink.sink()
            else
                null;

        var completed_turns: u64 = 0;
        var primary_failed = false;
        var primary_refs: std.ArrayListUnmanaged(ConsumedRef) = .empty;
        defer freeConsumedRefs(self.allocator, &primary_refs);
        // dsh-native never runs Agent.turn, so the host performs the native
        // memory recall and hands the block to the engine's runtime context.
        const memory_context = if (session.dsh_native != null)
            try self.recallMemoryContext(session, content)
        else
            null;
        defer if (memory_context) |text| self.allocator.free(text);
        // The drain callback is installed (and restored) inside the adapter
        // around Agent.turn; the host only has to say "yes, drain this turn".
        const turn_input = harness_port.TurnInput{
            .user_message = content,
            .conversation_context = conversation_context,
            .memory_session_id = session.agent.memory_session_id,
            .memory_context = memory_context,
            .live_stream = stream_sink != null,
            .sink = port_sink,
        };
        var response = self.runTurnWithSteerSink(session, &primary_refs, steer_sink, turn_input, true) catch |turn_err| blk: {
            log.warn("session turn failed session=0x{x}: {}", .{ session_hash, turn_err });
            // Regression: both post-turn drain loops were skipped on error, so
            // a message the router had already acknowledged as steered stayed
            // in injection_pending and never ran. Run the pending injections as
            // follow-up turns; when one succeeds, fall through to the normal
            // tail so scope checks, rehydration and counters still apply to its
            // reply. Only surface the original error when no follow-up
            // succeeded (including when none was pending).
            session.closeInjectionWindow();
            primary_failed = true;
            // Persist the failed prompt before any follow-up runs: otherwise a
            // follow-up reply would be stored as the answer to this message.
            self.persistTurnResult(session, session_key, content, null);
            break :blk (try self.drainInjectionsAfterFailedTurn(session, session_key, &completed_turns, session_hash, steer_sink, stream_sink != null, port_sink)) orelse return turn_err;
        };
        if (!primary_failed) {
            completed_turns += 1;
            self.persistTurnResult(session, session_key, content, response);
        }

        // A reset turn opens a fresh session: a message steered into it belongs
        // to the conversation that just ended, so it must not run as a follow-up
        // turn inside the new session. OpenClaw does the same by refusing steer
        // and follow-up admission for a reset-triggered turn.
        // src/auto-reply/reply/agent-runner-run.ts:244-245
        const reset_turn = !session.agent.last_turn_interrupted and
            agent_mod.commands.planTurnInput(content).clear_session;

        if (session.agent.last_turn_interrupted or reset_turn) {
            // One /stop ends the turn: messages steered into it must not run as
            // fresh follow-up turns with their own model and tool calls.
            session.closeInjectionWindow();
            if ((session.discardPendingInjections(self.allocator) catch 0) > 0) {
                const notice = if (reset_turn) RESET_DISCARDED_NOTICE else STOP_DISCARDED_NOTICE;
                const combined = std.fmt.allocPrint(
                    self.allocator,
                    "{s}\n\n{s}",
                    .{ response, notice },
                ) catch null;
                if (combined) |text| {
                    self.allocator.free(response);
                    response = text;
                }
            }
        } else {
            // Drain messages that arrived while the primary turn was running. A
            // failed follow-up contributes a resend notice but does not stop the
            // loop: messages that arrived after it were already acknowledged and
            // must not be left pending (a slash-command turn never drains them).
            var late_drain_count: u32 = 0;
            while (late_drain_count < MAX_POST_TURN_INJECTION_DRAINS) : (late_drain_count += 1) {
                if (!try self.drainLateInjection(session, session_key, &response, &completed_turns, steer_sink, stream_sink != null, port_sink)) break;
            }

            // Regression: a message that arrived after the last drain but before the
            // deferred turn_running reset was appended and acknowledged, yet nothing
            // drained it until some later inbound message (or never). Close the
            // injection window before persistence: a message arriving from now on
            // falls back to a fresh turn, and anything appended earlier is drained
            // below with turn_running still set so /stop can interrupt these
            // follow-up turns.
            session.closeInjectionWindow();
            late_drain_count = 0;
            while (late_drain_count < MAX_POST_TURN_INJECTION_DRAINS) : (late_drain_count += 1) {
                if (!try self.drainLateInjection(session, session_key, &response, &completed_turns, steer_sink, stream_sink != null, port_sink)) break;
            }
            if (late_drain_count == MAX_POST_TURN_INJECTION_DRAINS and session.hasInjection()) {
                log.warn("post-turn injection drain limit reached session=0x{x}", .{session_hash});
            }
        }

        session.turn_count += completed_turns;
        session.last_active = std_compat.time.timestamp();

        // Track consolidation timestamp
        if (session.agent.last_turn_compacted) {
            session.last_consolidated = @intCast(@max(0, std_compat.time.timestamp()));
        }

        if (self.config.diagnostics.log_message_payloads) {
            var preview = safeMessageLogPreview(self.allocator, response);
            defer preview.deinit(self.allocator);
            log.info(
                "message outbound channel={s} session=0x{x} bytes={d} content={f}{s}",
                .{
                    channel,
                    session_hash,
                    response.len,
                    std.json.fmt(preview.slice, .{}),
                    if (preview.truncated) " [log preview truncated]" else "",
                },
            );
        }

        // An agent with its own autonomy must not be able to exfiltrate files
        // outside its workspace through legacy attachment markers in its reply
        // text (see filterOutboundAttachmentMarkers).
        response = try self.filterOutboundAttachmentMarkers(session, response);

        if (display_rehydrate_allowed) {
            if (session.agent.redactor) |r| {
                if (r.wouldRehydrate()) {
                    const display_response = try r.unredact(self.allocator, response);
                    self.allocator.free(response);
                    return display_response;
                }
            }
        }

        return response;
    }

    pub const InterruptRequestResult = struct {
        requested: bool = false,
        active_tool: ?[]u8 = null,

        pub fn deinit(self: *InterruptRequestResult, allocator: Allocator) void {
            if (self.active_tool) |name| allocator.free(name);
            self.active_tool = null;
        }
    };

    /// Return the routing input for a session without acquiring the long turn mutex.
    /// If the session does not exist yet, returns defaults (process, off, false).
    pub fn routeInput(self: *SessionManager, session_key: []const u8) inbound_router.RouteInput {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session = self.sessions.get(session_key) orelse return .{
            .turn_running = false,
            .queue_mode = self.config.agent.default_queue_mode,
            .has_pending_injection = false,
        };
        return .{
            // A closing turn no longer accepts input, so the message waits on
            // the session lock and runs as a fresh turn instead of being
            // steered into a buffer nobody will drain.
            .turn_running = session.acceptsInjection(),
            .queue_mode = session.agent.queue_mode,
            .has_pending_injection = session.hasInjection(),
        };
    }

    /// Deposit a mid-turn injection for a running session.
    /// Safe to call while the session turn is in progress — does not acquire session.mutex.
    /// Replaces any existing pending injection.  No-op when session does not exist.
    pub fn injectMidTurn(self: *SessionManager, session_key: []const u8, text: []const u8) !void {
        const session = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.sessions.get(session_key) orelse return;
        };
        try session.injectMidTurn(self.allocator, text);
    }

    /// Deposit a mid-turn injection only if the session is still running.
    fn injectMidTurnIfRunning(self: *SessionManager, session_key: []const u8, text: []const u8, ref: ?ConsumedRef, sink: ?SteerReactionSink) !bool {
        var ack: ?ConsumedRef = null;
        const deposited = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const session = self.sessions.get(session_key) orelse return false;
            break :blk try session.injectMidTurnIfRunningWithRef(self.allocator, text, ref, sink, &ack);
        };
        // No session pointer is used after unlocking: the retained ref keeps the
        // reaction alive even if the consuming turn finishes and is evicted.
        acknowledgeSteerRef(self.allocator, ack);
        return deposited;
    }

    /// Append a mid-turn injection only if the session is still running.
    fn appendMidTurnIfRunning(self: *SessionManager, session_key: []const u8, text: []const u8, ref: ?ConsumedRef, sink: ?SteerReactionSink) !bool {
        var ack: ?ConsumedRef = null;
        const deposited = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const session = self.sessions.get(session_key) orelse return false;
            break :blk try session.appendMidTurnIfRunningWithRef(self.allocator, text, ref, sink, &ack);
        };
        // No session pointer is used after unlocking: the retained ref keeps the
        // reaction alive even if the consuming turn finishes and is evicted.
        acknowledgeSteerRef(self.allocator, ack);
        return deposited;
    }

    fn isSessionTurnRunning(self: *SessionManager, session_key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session = self.sessions.get(session_key) orelse return false;
        return session.turn_running.load(.acquire);
    }

    /// True when the session's agent streams reasoning to the caller
    /// (`/reasoning stream`), which is what lets a channel draft show the
    /// thinking live.
    ///
    /// An unknown key reports the configured default instead of false. A session
    /// only exists once its first turn has run, and Slack appends the thread ts
    /// to the key, so a channel turn routinely looks up a session that does not
    /// exist yet. Returning false there silently stripped the live reasoning
    /// from every Slack message.
    pub fn streamsReasoning(self: *SessionManager, session_key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session = self.sessions.get(session_key) orelse {
            return self.config.agent.reasoning_mode == .stream;
        };
        return session.agent.reasoning_mode == .stream;
    }

    pub const InboundRouteAction = enum {
        process,
        /// Injected into the running turn; the caller should acknowledge it.
        steered,
        /// Consumed by the running turn without new text (/stop).
        skip,
        /// Discarded because queue_mode is off; the caller should tell the user.
        dropped,

        /// True when the caller must not start a new turn for this message.
        pub fn skipsTurn(self: InboundRouteAction) bool {
            return self != .process;
        }
    };

    /// User-visible notice a transport should show for a consumed message.
    /// Steer is acknowledged, an explicit drop is explained, /stop is silent.
    pub fn consumedNotice(action: InboundRouteAction) ?[]const u8 {
        return switch (action) {
            .steered => inbound_router.queued_notice,
            .dropped => inbound_router.dropped_notice,
            .process, .skip => null,
        };
    }

    /// Apply inbound routing side effects for a message.
    /// Returns .steered when the message was injected into the running turn,
    /// .skip when the turn consumed it without new text (/stop), and .dropped
    /// when the message was discarded and the caller should notify the sender.
    pub fn routeInbound(self: *SessionManager, session_key: []const u8, content: []const u8) InboundRouteAction {
        return self.routeInboundWithRef(session_key, content, null, null);
    }

    /// Route an inbound message. When the router steers it into the running
    /// turn, `ref` (the message's channel identity) is stored atomically with
    /// the injected text so the turn can finalize the message's lifecycle
    /// reaction when it finishes.
    pub fn routeInboundWithRef(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        ref: ?ConsumedRef,
        sink: ?SteerReactionSink,
    ) InboundRouteAction {
        const session_hash = std.hash.Wyhash.hash(0, session_key);

        // A stop command must reach a busy session even when the queue policy
        // would drop it: it is the only way to interrupt a running turn. The
        // incident dropped "/stop" with "session busy queue_mode=off" and the
        // user could not stop a runaway generation. Signal the interrupt here,
        // centrally, so every channel path (daemon/Slack, all channel_loop
        // variants, callback queries, the sync Telegram path) benefits.
        if (control_plane.isStopLikeCommand(content)) {
            var interrupt = self.requestTurnInterrupt(session_key);
            defer interrupt.deinit(self.allocator);
            if (interrupt.requested) {
                log.info("stop command interrupting running turn session=0x{x}", .{session_hash});
                return .skip;
            }
        }

        // A known slash command is executed by the turn loop
        // (agent.handleSlashCommand), not by the model. Injecting it as user text
        // would leave the command unexecuted and the model would answer the
        // literal text. Return .process so the caller waits on the session lock
        // and runs it as a serial follow-up after the active turn.
        //
        // Only known commands count: slash-prefixed text such as
        // "/tmp/report.csv please read" is ordinary user text and must steer
        // like any other message instead of stalling behind the turn lock.
        if (agent_mod.commands.isKnownSlashCommand(content)) return .process;

        return switch (inbound_router.route(self.routeInput(session_key))) {
            .inject, .replace_injection => blk: {
                const injected = self.injectMidTurnIfRunning(session_key, content, ref, sink) catch |err| {
                    log.warn("mid-turn inject failed session=0x{x} err={}", .{ session_hash, err });
                    break :blk .process;
                };
                break :blk if (injected) .steered else .process;
            },
            .append_injection => blk: {
                const injected = self.appendMidTurnIfRunning(session_key, content, ref, sink) catch |err| {
                    log.warn("mid-turn append failed session=0x{x} err={}", .{ session_hash, err });
                    break :blk .process;
                };
                break :blk if (injected) .steered else .process;
            },
            .drop => blk: {
                if (!self.isSessionTurnRunning(session_key)) break :blk .process;
                log.info("dropping message: session busy queue_mode=off session=0x{x}", .{session_hash});
                break :blk .dropped;
            },
            .process, .queue => .process,
        };
    }

    pub const SessionSnapshot = struct {
        session_key: []u8,
        last_active: i64,
        turn_count: u64,
        turn_running: bool,

        pub fn deinit(self: *SessionSnapshot, allocator: Allocator) void {
            allocator.free(self.session_key);
        }
    };

    /// Request interruption of a currently running turn for a session.
    /// Returns whether it was signaled and the active tool snapshot (if any).
    pub fn requestTurnInterrupt(self: *SessionManager, session_key: []const u8) InterruptRequestResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(session_key) orelse return .{};
        if (!session.turn_running.load(.acquire)) return .{};
        session.requestInterrupt();
        return .{
            .requested = true,
            .active_tool = session.agent.snapshotActiveToolName(self.allocator) catch null,
        };
    }

    /// Set the interrupt flag even though the turn has not published
    /// `turn_running` yet. Used by `/stop` when a worker task passed its epoch
    /// check and is about to start: `Agent.turn` checks the flag before the
    /// first provider call, so the message is never sent. When the session
    /// does not exist yet (a stop right after the first message in a new
    /// chat), the request is recorded and consumed by the turn that creates
    /// it. Returns false only when the request cannot be recorded.
    pub fn requestTurnInterruptAtStart(self: *SessionManager, session_key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sessions.get(session_key)) |session| {
            session.requestInterrupt();
            return true;
        }
        if (!self.pending_start_interrupts.contains(session_key)) {
            const owned_key = self.allocator.dupe(u8, session_key) catch return false;
            self.pending_start_interrupts.put(self.allocator, owned_key, {}) catch {
                self.allocator.free(owned_key);
                return false;
            };
        }
        return true;
    }

    fn takePendingStartInterruptLocked(self: *SessionManager, session_key: []const u8) bool {
        if (self.pending_start_interrupts.fetchRemove(session_key)) |entry| {
            self.allocator.free(entry.key);
            return true;
        }
        return false;
    }

    /// Drop a pre-turn interrupt that no turn consumed. The channel worker
    /// calls this when its task ends without reaching the turn, so the next
    /// message is not interrupted by a stop meant for a turn that never ran.
    pub fn clearPendingStartInterrupt(self: *SessionManager, session_key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.takePendingStartInterruptLocked(session_key);
    }

    /// Clear an interrupt flag that no turn consumed. Called when a worker's
    /// turn has ended: a /stop that landed after the turn cleared its flag but
    /// before the reply was delivered must not interrupt the next message in
    /// the chat.
    pub fn clearTurnInterruptIfIdle(self: *SessionManager, session_key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session = self.sessions.get(session_key) orelse return;
        if (session.turn_running.load(.acquire)) return;
        session.clearInterrupt();
    }

    /// Request interruption of a running turn for `session_key` together with
    /// any active `:thread:` child sessions that name it as their parent.
    ///
    /// A top-level stop command carries no thread context (Slack slash commands
    /// are always top-level), so the busy turn may live in a thread session
    /// under the routed channel/DM session. This interrupts the routed session
    /// and every active thread child so `/stop` reaches a turn running inside a
    /// thread. Returns true when at least one turn was signaled.
    pub fn requestTurnInterruptWithThreads(self: *SessionManager, session_key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var requested = false;
        if (self.sessions.get(session_key)) |session| {
            if (session.turn_running.load(.acquire)) {
                session.requestInterrupt();
                requested = true;
            }
        }

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const parent = agent_routing.resolveThreadParentSessionKey(entry.key_ptr.*) orelse continue;
            if (!std.mem.eql(u8, parent, session_key)) continue;
            const session = entry.value_ptr.*;
            if (!session.turn_running.load(.acquire)) continue;
            session.requestInterrupt();
            requested = true;
        }
        return requested;
    }

    /// Copy the outbound delivery target of the turn running for `session_key`
    /// and any active `:thread:` child into `out` (caller frees each string).
    ///
    /// A `/stop` uses this to drop the stopped turn's already-queued stream
    /// chunks. The target has to come from the running session, not from the
    /// stop command: a Slack slash command carries no thread context, so its
    /// own chat id names the whole channel and would silence concurrent
    /// threads.
    pub fn collectActiveTurnTargets(
        self: *SessionManager,
        allocator: Allocator,
        session_key: []const u8,
        out: *std.ArrayListUnmanaged([]u8),
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        appendActiveTurnTargetHelper(allocator, self.sessions.get(session_key), out);
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const parent = agent_routing.resolveThreadParentSessionKey(entry.key_ptr.*) orelse continue;
            if (!std.mem.eql(u8, parent, session_key)) continue;
            appendActiveTurnTargetHelper(allocator, entry.value_ptr.*, out);
        }
    }

    fn appendActiveTurnTargetHelper(allocator: Allocator, session: ?*Session, out: *std.ArrayListUnmanaged([]u8)) void {
        const s = session orelse return;
        if (!s.turn_running.load(.acquire)) return;
        const ctx = s.agent.conversation_context orelse return;
        const target = ctx.delivery_chat_id orelse return;
        if (target.len == 0) return;
        const owned = allocator.dupe(u8, target) catch return;
        out.append(allocator, owned) catch allocator.free(owned);
    }

    pub fn freeSessionSnapshots(allocator: Allocator, snapshots: []SessionSnapshot) void {
        for (snapshots) |*snapshot| snapshot.deinit(allocator);
        allocator.free(snapshots);
    }

    /// Snapshot active sessions for read-only status/reporting surfaces.
    /// The returned slice owns duplicated session keys and must be freed with
    /// `freeSessionSnapshots`.
    pub fn snapshotSessions(self: *SessionManager, allocator: Allocator) ![]SessionSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = self.sessions.count();
        const snapshots = try allocator.alloc(SessionSnapshot, count);
        errdefer allocator.free(snapshots);

        var idx: usize = 0;
        errdefer {
            for (snapshots[0..idx]) |*snapshot| snapshot.deinit(allocator);
        }

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            session.mutex.lock();
            const last_active = session.last_active;
            const turn_count = session.turn_count;
            session.mutex.unlock();

            snapshots[idx] = .{
                .session_key = try allocator.dupe(u8, session.session_key),
                .last_active = last_active,
                .turn_count = turn_count,
                .turn_running = session.turn_running.load(.acquire),
            };
            idx += 1;
        }

        return snapshots;
    }

    /// Best-effort migration from a legacy session key to a new canonical key.
    /// Used for wire-format changes where we want future turns to land on the
    /// canonical key without dropping persisted transcript or session-scoped memory.
    pub fn migrateLegacySessionKey(self: *SessionManager, canonical_session_key: []const u8, legacy_session_key: ?[]const u8) void {
        const legacy = legacy_session_key orelse return;
        if (std.mem.eql(u8, canonical_session_key, legacy)) return;

        self.migrateLiveSessionKey(canonical_session_key, legacy);
        self.migrateStoredSessionTranscript(canonical_session_key, legacy);
        self.migrateScopedMemoryEntries(canonical_session_key, legacy);
    }

    fn migrateLiveSessionKey(self: *SessionManager, canonical_session_key: []const u8, legacy_session_key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.contains(canonical_session_key)) return;
        const legacy_session = self.sessions.get(legacy_session_key) orelse return;
        if (legacy_session.turn_running.load(.acquire)) return;

        const new_key = self.allocator.dupe(u8, canonical_session_key) catch return;
        if (self.sessions.fetchRemove(legacy_session_key)) |entry| {
            const session = entry.value;
            const old_key = session.session_key;

            session.session_key = new_key;
            if (session.owned_memory_session_id == null) {
                session.agent.memory_session_id = session.session_key;
            }

            self.sessions.put(self.allocator, session.session_key, session) catch {
                session.session_key = old_key;
                if (session.owned_memory_session_id == null) {
                    session.agent.memory_session_id = session.session_key;
                }
                self.sessions.put(self.allocator, old_key, session) catch {
                    log.err("failed to restore live session after canonical key migration rollback", .{});
                };
                self.allocator.free(new_key);
                return;
            };

            // Regression: the dsh-native harness borrowed this slice, so
            // freeing `old_key` below left it dangling and the next mapping
            // write hashed freed memory (or a restart under the canonical key
            // found no mapping at all).
            if (session.dsh_native) |*d| d.harness.rebindSessionKey(new_key);
            self.allocator.free(old_key);
        } else {
            self.allocator.free(new_key);
        }
    }

    fn migrateStoredSessionTranscript(self: *SessionManager, canonical_session_key: []const u8, legacy_session_key: []const u8) void {
        const store = self.session_store orelse return;

        const legacy_messages = store.loadMessages(self.allocator, legacy_session_key) catch return;
        defer memory_mod.freeMessages(self.allocator, legacy_messages);
        const legacy_usage = store.loadUsage(legacy_session_key) catch null;

        if (legacy_messages.len == 0 and legacy_usage == null) return;

        const canonical_messages = store.loadMessages(self.allocator, canonical_session_key) catch return;
        defer memory_mod.freeMessages(self.allocator, canonical_messages);
        const canonical_usage = store.loadUsage(canonical_session_key) catch null;

        if (canonical_messages.len > 0 or canonical_usage != null) return;

        for (legacy_messages) |entry| {
            store.saveMessage(canonical_session_key, entry.role, entry.content) catch return;
        }
        if (legacy_usage) |usage| {
            store.saveUsage(canonical_session_key, usage) catch return;
        }
        store.clearMessages(legacy_session_key) catch return;
    }

    fn migrateScopedMemoryEntries(self: *SessionManager, canonical_session_key: []const u8, legacy_session_key: []const u8) void {
        const mem = self.mem orelse return;
        if (std.mem.eql(u8, mem.name(), "markdown")) return;

        const legacy_entries = mem.list(self.allocator, null, legacy_session_key) catch return;
        defer memory_mod.freeEntries(self.allocator, legacy_entries);
        if (legacy_entries.len == 0) return;

        for (legacy_entries) |entry| {
            mem.store(entry.key, entry.content, entry.category, canonical_session_key) catch return;
            _ = mem.forgetScoped(self.allocator, entry.key, legacy_session_key) catch return;
        }
    }

    /// Number of active sessions.
    pub fn sessionCount(self: *SessionManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.count();
    }

    pub const ReloadSkillsResult = struct {
        sessions_seen: usize = 0,
        sessions_reloaded: usize = 0,
        failures: usize = 0,
    };

    /// Reload skill-backed system prompts for all active sessions.
    /// Each session is reloaded under its own lock to avoid in-flight turn races.
    pub fn reloadSkillsAll(self: *SessionManager) ReloadSkillsResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = ReloadSkillsResult{};

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            result.sessions_seen += 1;
            session.mutex.lock();
            session.agent.has_system_prompt = false;
            session.mutex.unlock();
            result.sessions_reloaded += 1;
        }

        return result;
    }

    /// Evict sessions idle longer than max_idle_secs. Returns number evicted.
    pub fn evictIdle(self: *SessionManager, max_idle_secs: u64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std_compat.time.timestamp();
        var evicted: usize = 0;

        // Collect keys to remove (can't modify map while iterating).
        // Active turns keep stale last_active until the turn finishes, so skip
        // any session that is currently executing.
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            const idle_secs: u64 = @intCast(@max(0, now - session.last_active));
            if (idle_secs > max_idle_secs and !session.turn_running.load(.acquire)) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.sessions.fetchRemove(key)) |kv| {
                const session = kv.value;
                session.deinit(self.allocator);
                self.allocator.destroy(session);
                evicted += 1;
            }
        }

        if (evicted > 0) {
            self.pruneUnusedAgentRuntimesLocked();
        }

        return evicted;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

const testing = std.testing;

// ---------------------------------------------------------------------------
// MockProvider — returns a fixed response, no network calls
// ---------------------------------------------------------------------------

const MockProvider = struct {
    response: []const u8,
    /// Per-call responses; the last entry repeats. When null, `response` is
    /// returned for every call.
    responses: ?[]const []const u8 = null,
    chat_error: ?anyerror = null,
    /// Fail this many initial calls, then succeed (exercises provider retries).
    fail_first: usize = 0,
    /// Fail exactly these 1-based call numbers (e.g. both attempts of one turn).
    fail_calls: []const usize = &.{},
    /// Fail these 1-based calls with RateLimited, which the agent surfaces
    /// without retrying.
    fail_rate_limited_calls: []const usize = &.{},
    /// Test hook invoked from chat() so a test can simulate a mid-turn message
    /// arriving while the provider request is in flight.
    on_chat: ?*const fn (*anyopaque) void = null,
    on_chat_ctx: ?*anyopaque = null,
    chat_calls: usize = 0,
    supports_vision: bool = true,
    vision_model: ?[]const u8 = null,
    /// When true, the returned response carries allocated provider/model fields,
    /// mirroring what ReliableProvider and OpenRouter produce. Used to guard the
    /// probeVision response-freeing regression.
    annotate: bool = false,
    last_chat_model_len: usize = 0,
    last_chat_model_buf: [128]u8 = undefined,
    last_request_timeout_secs: u64 = 0,

    const vtable = Provider.VTable{
        .chatWithSystem = mockChatWithSystem,
        .chat = mockChat,
        .supportsNativeTools = mockSupportsNativeTools,
        .supports_vision = mockSupportsVision,
        .supports_vision_for_model = mockSupportsVisionForModel,
        .getName = mockGetName,
        .deinit = mockDeinit,
    };

    fn provider(self: *MockProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn mockChatWithSystem(
        ptr: *anyopaque,
        _: Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        return self.response;
    }

    fn mockChat(
        ptr: *anyopaque,
        allocator: Allocator,
        request: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        self.chat_calls += 1;
        self.last_chat_model_len = @min(request.model.len, self.last_chat_model_buf.len);
        @memcpy(self.last_chat_model_buf[0..self.last_chat_model_len], request.model[0..self.last_chat_model_len]);
        self.last_request_timeout_secs = request.timeout_secs;
        if (self.on_chat) |hook| {
            if (self.on_chat_ctx) |ctx| hook(ctx);
        }
        if (self.chat_error) |err| return err;
        if (self.chat_calls <= self.fail_first) return error.ProviderError;
        if (std.mem.indexOfScalar(usize, self.fail_rate_limited_calls, self.chat_calls) != null) return error.RateLimited;
        if (std.mem.indexOfScalar(usize, self.fail_calls, self.chat_calls) != null) return error.ProviderError;
        const body = if (self.responses) |responses|
            responses[@min(self.chat_calls - 1, responses.len - 1)]
        else
            self.response;
        var resp = providers.ChatResponse{ .content = try allocator.dupe(u8, body) };
        if (self.annotate) {
            resp.provider = try allocator.dupe(u8, "mock");
            resp.model = try allocator.dupe(u8, request.model);
        }
        return resp;
    }

    fn mockSupportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn mockSupportsVision(ptr: *anyopaque) bool {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        return self.supports_vision;
    }

    fn mockSupportsVisionForModel(ptr: *anyopaque, model: []const u8) bool {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        if (self.vision_model) |vision_model| {
            return std.mem.eql(u8, model, vision_model);
        }
        return self.supports_vision;
    }

    fn lastChatModel(self: *const MockProvider) []const u8 {
        return self.last_chat_model_buf[0..self.last_chat_model_len];
    }

    fn mockGetName(_: *anyopaque) []const u8 {
        return "mock";
    }

    fn mockDeinit(_: *anyopaque) void {}
};

const CaptureMessagesProvider = struct {
    response: []const u8 = "ok",
    chat_calls: usize = 0,
    user_count: usize = 0,
    user_lens: [4]usize = [_]usize{0} ** 4,
    user_bufs: [4][128]u8 = undefined,

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystem,
        .chat = chat,
        .supportsNativeTools = supportsNativeTools,
        .getName = getName,
        .deinit = deinitFn,
    };

    fn provider(self: *CaptureMessagesProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn chatWithSystem(
        ptr: *anyopaque,
        allocator: Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *CaptureMessagesProvider = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, self.response);
    }

    fn chat(
        ptr: *anyopaque,
        allocator: Allocator,
        request: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *CaptureMessagesProvider = @ptrCast(@alignCast(ptr));
        self.chat_calls += 1;
        self.user_count = 0;
        for (request.messages) |message| {
            if (message.role != .user or self.user_count >= self.user_bufs.len) continue;
            const idx = self.user_count;
            const len = @min(message.content.len, self.user_bufs[idx].len);
            @memcpy(self.user_bufs[idx][0..len], message.content[0..len]);
            self.user_lens[idx] = len;
            self.user_count += 1;
        }
        return .{ .content = try allocator.dupe(u8, self.response) };
    }

    fn userMessage(self: *const CaptureMessagesProvider, idx: usize) []const u8 {
        return self.user_bufs[idx][0..self.user_lens[idx]];
    }

    fn supportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "capture_messages";
    }

    fn deinitFn(_: *anyopaque) void {}
};

const LateInjectionProvider = struct {
    session_mgr: *SessionManager,
    session_key: []const u8,
    chat_calls: usize = 0,
    route_action: ?SessionManager.InboundRouteAction = null,
    user_count: usize = 0,
    user_lens: [4]usize = [_]usize{0} ** 4,
    user_bufs: [4][128]u8 = undefined,

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystem,
        .chat = chat,
        .supportsNativeTools = supportsNativeTools,
        .getName = getName,
        .deinit = deinitFn,
    };

    fn provider(self: *LateInjectionProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn chatWithSystem(
        ptr: *anyopaque,
        allocator: Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *LateInjectionProvider = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, if (self.chat_calls == 0) "first response" else "final response");
    }

    fn chat(
        ptr: *anyopaque,
        allocator: Allocator,
        request: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *LateInjectionProvider = @ptrCast(@alignCast(ptr));
        self.chat_calls += 1;
        self.user_count = 0;
        for (request.messages) |message| {
            if (message.role != .user or self.user_count >= self.user_bufs.len) continue;
            const idx = self.user_count;
            const len = @min(message.content.len, self.user_bufs[idx].len);
            @memcpy(self.user_bufs[idx][0..len], message.content[0..len]);
            self.user_lens[idx] = len;
            self.user_count += 1;
        }
        if (self.chat_calls == 1) {
            self.route_action = self.session_mgr.routeInbound(self.session_key, "late message");
            return .{ .content = try allocator.dupe(u8, "first response") };
        }
        return .{ .content = try allocator.dupe(u8, "final response") };
    }

    fn userMessage(self: *const LateInjectionProvider, idx: usize) []const u8 {
        return self.user_bufs[idx][0..self.user_lens[idx]];
    }

    fn supportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "late_injection";
    }

    fn deinitFn(_: *anyopaque) void {}
};

const CapturePromptProvider = struct {
    response: []const u8 = "ok",
    captured_system: ?[]u8 = null,
    /// Allocator used to dup `captured_system` so the test can read it after
    /// `agent.turn()` returns and the per-turn arena (where request.messages
    /// live) has been freed. Set by the test before calling `provider()`.
    capture_alloc: ?Allocator = null,

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystem,
        .chat = chat,
        .supportsNativeTools = supportsNativeTools,
        .getName = getName,
        .deinit = deinitFn,
    };

    fn provider(self: *CapturePromptProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn chatWithSystem(
        _: *anyopaque,
        allocator: Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        return allocator.dupe(u8, "");
    }

    fn chat(
        ptr: *anyopaque,
        allocator: Allocator,
        request: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *CapturePromptProvider = @ptrCast(@alignCast(ptr));
        if (request.messages.len > 0 and request.messages[0].role == .system) {
            if (self.capture_alloc) |alloc| {
                if (self.captured_system) |old| alloc.free(old);
                self.captured_system = try alloc.dupe(u8, request.messages[0].content);
            }
        }
        return .{ .content = try allocator.dupe(u8, self.response) };
    }

    fn supportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "capture_prompt";
    }

    fn deinitFn(_: *anyopaque) void {}
};

const MockStreamingProvider = struct {
    response: []const u8,
    /// Test hook invoked from stream_chat() so a test can simulate a mid-turn
    /// message arriving while the provider stream is in flight.
    on_stream: ?*const fn (*anyopaque) void = null,
    on_stream_ctx: ?*anyopaque = null,

    const vtable = Provider.VTable{
        .chatWithSystem = mockChatWithSystem,
        .chat = mockChat,
        .supportsNativeTools = mockSupportsNativeTools,
        .getName = mockGetName,
        .deinit = mockDeinit,
        .supports_streaming = mockSupportsStreaming,
        .stream_chat = mockStreamChat,
    };

    fn provider(self: *MockStreamingProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn mockChatWithSystem(
        ptr: *anyopaque,
        _: Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *MockStreamingProvider = @ptrCast(@alignCast(ptr));
        return self.response;
    }

    fn mockChat(
        ptr: *anyopaque,
        allocator: Allocator,
        _: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *MockStreamingProvider = @ptrCast(@alignCast(ptr));
        return .{ .content = try allocator.dupe(u8, self.response) };
    }

    fn mockSupportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn mockGetName(_: *anyopaque) []const u8 {
        return "mock_stream";
    }

    fn mockDeinit(_: *anyopaque) void {}

    fn mockSupportsStreaming(_: *anyopaque) bool {
        return true;
    }

    fn mockStreamChat(
        ptr: *anyopaque,
        allocator: Allocator,
        _: providers.ChatRequest,
        model: []const u8,
        _: f64,
        callback: providers.StreamCallback,
        callback_ctx: *anyopaque,
    ) anyerror!providers.StreamChatResult {
        const self: *MockStreamingProvider = @ptrCast(@alignCast(ptr));
        if (self.on_stream) |hook| {
            if (self.on_stream_ctx) |ctx| hook(ctx);
        }
        const mid = self.response.len / 2;
        if (mid > 0) callback(callback_ctx, providers.StreamChunk.textDelta(self.response[0..mid]));
        callback(callback_ctx, providers.StreamChunk.textDelta(self.response[mid..]));
        callback(callback_ctx, providers.StreamChunk.finalChunk());
        return .{
            .content = try allocator.dupe(u8, self.response),
            .model = try allocator.dupe(u8, model),
        };
    }
};

const DeltaCollector = struct {
    allocator: Allocator,
    data: std.ArrayListUnmanaged(u8) = .empty,

    fn onEvent(ctx_ptr: *anyopaque, event: streaming.Event) void {
        if (event.stage != .chunk or event.text.len == 0) return;
        const self: *DeltaCollector = @ptrCast(@alignCast(ctx_ptr));
        self.data.appendSlice(self.allocator, event.text) catch {};
    }

    fn deinit(self: *DeltaCollector) void {
        self.data.deinit(self.allocator);
    }
};

const PortDeltaCollector = struct {
    allocator: Allocator,
    data: std.ArrayListUnmanaged(u8) = .empty,

    fn emit(ctx_ptr: *anyopaque, event: harness_port.Event) void {
        switch (event) {
            .delta => |chunk| if (!chunk.is_final and chunk.delta.len > 0) {
                const self: *PortDeltaCollector = @ptrCast(@alignCast(ctx_ptr));
                self.data.appendSlice(self.allocator, chunk.delta) catch {};
            },
            else => {},
        }
    }

    fn sink(self: *PortDeltaCollector) harness_port.Sink {
        return .{ .ctx = @ptrCast(self), .emit = emit };
    }

    fn deinit(self: *PortDeltaCollector) void {
        self.data.deinit(self.allocator);
    }
};

/// Records the live deltas a production turn's stream sink receives and counts
/// provider calls, so a test can tell the primary turn from its follow-up.
const StreamTurnProbe = struct {
    allocator: Allocator,
    provider_calls: usize = 0,
    data: std.ArrayListUnmanaged(u8) = .empty,

    fn onStream(ctx_ptr: *anyopaque) void {
        const self: *StreamTurnProbe = @ptrCast(@alignCast(ctx_ptr));
        self.provider_calls += 1;
    }

    fn onEvent(ctx_ptr: *anyopaque, event: streaming.Event) void {
        if (event.stage != .chunk or event.text.len == 0) return;
        const self: *StreamTurnProbe = @ptrCast(@alignCast(ctx_ptr));
        self.data.appendSlice(self.allocator, event.text) catch {};
    }

    fn deinit(self: *StreamTurnProbe) void {
        self.data.deinit(self.allocator);
    }
};

/// Deposits one steer from `turn_complete`: that fires after the agent's own
/// last drain and before the turn returns, i.e. the tail window that
/// drainLateInjection exists for.
const TailInjectObserver = struct {
    session: ?*Session = null,
    injected: bool = false,

    const vtable = observability.Observer.VTable{
        .record_event = recordEvent,
        .record_metric = noopMetric,
        .flush = noopFlush,
        .name = name,
        .get_trace_id = noTrace,
        .set_trace_id = noSetTrace,
    };

    fn observer(self: *@This()) observability.Observer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn recordEvent(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (event.*) {
            .turn_complete => {
                if (self.injected) return;
                self.injected = true;
                if (self.session) |session| {
                    _ = session.appendMidTurnIfRunning(testing.allocator, "steered while busy") catch {};
                }
            },
            else => {},
        }
    }

    fn noopMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn noopFlush(_: *anyopaque) void {}
    fn name(_: *anyopaque) []const u8 {
        return "tail_inject";
    }
    fn noTrace(_: *anyopaque) ?[32]u8 {
        return null;
    }
    fn noSetTrace(_: *anyopaque, _: [32]u8) void {}
};

const ProgressCollector = struct {
    count: usize = 0,
    starts: usize = 0,
    ends: usize = 0,
    retries: usize = 0,
    retry_clears: usize = 0,
    last_text_buf: [64]u8 = undefined,
    last_text_len: usize = 0,

    fn onEvent(ctx_ptr: *anyopaque, hint: agent_mod.ProgressHint) void {
        const self: *ProgressCollector = @ptrCast(@alignCast(ctx_ptr));
        self.count += 1;
        switch (hint.kind) {
            .retry => {
                if (hint.retry == null) {
                    self.retry_clears += 1;
                    return;
                }
                self.retries += 1;
            },
            .tool => switch (hint.phase) {
                .start => self.starts += 1,
                .end => self.ends += 1,
            },
        }
        self.last_text_len = @min(hint.text.len, self.last_text_buf.len);
        @memcpy(self.last_text_buf[0..self.last_text_len], hint.text[0..self.last_text_len]);
    }

    fn lastText(self: *const ProgressCollector) []const u8 {
        return self.last_text_buf[0..self.last_text_len];
    }
};

const ProbeTool = struct {
    pub const tool_name = "probe";
    pub const tool_description = "Test probe tool";
    pub const tool_params = "{}";
    const vtable = tools_mod.ToolVTable(@This());

    fn tool(self: *@This()) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *@This(), allocator: Allocator, _: tools_mod.JsonObjectMap) !tools_mod.ToolResult {
        return .{ .success = true, .output = try allocator.dupe(u8, "probe ok") };
    }
};

const StopDuringToolProbe = struct {
    session: ?*Session = null,
    executions: usize = 0,

    pub const tool_name = "stop_probe";
    pub const tool_description = "Test tool that reproduces a /stop killing a tool call";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
    const vtable = tools_mod.ToolVTable(@This());

    fn tool(self: *@This()) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *@This(), _: Allocator, _: tools_mod.JsonObjectMap) !tools_mod.ToolResult {
        self.executions += 1;
        // Deposit while turn_running is still true, exactly as the router does
        // for a message that arrives during the tool call, then reproduce the
        // state a real /stop leaves behind when it kills the tool.
        _ = try self.session.?.appendMidTurnIfRunning(testing.allocator, "steered while busy");
        self.session.?.requestInterrupt();
        return .{ .success = false, .output = "", .error_msg = "Interrupted by /stop" };
    }
};

const SummaryFailureProvider = struct {
    call_count: usize = 0,

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystem,
        .chat = chat,
        .supportsNativeTools = supportsNativeTools,
        .getName = getName,
        .deinit = deinitFn,
    };

    fn provider(self: *SummaryFailureProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn chatWithSystem(
        _: *anyopaque,
        allocator: Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        return allocator.dupe(u8, "");
    }

    fn chat(
        ptr: *anyopaque,
        allocator: Allocator,
        _: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *SummaryFailureProvider = @ptrCast(@alignCast(ptr));
        self.call_count += 1;

        if (self.call_count == 1) {
            const tool_calls = try allocator.alloc(providers.ToolCall, 1);
            tool_calls[0] = .{
                .id = try allocator.dupe(u8, "call-probe"),
                .name = try allocator.dupe(u8, "probe"),
                .arguments = try allocator.dupe(u8, "{}"),
            };
            return .{
                .content = try allocator.dupe(u8, "running"),
                .tool_calls = tool_calls,
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        return error.ProviderError;
    }

    fn supportsNativeTools(_: *anyopaque) bool {
        return true;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "summary_failure";
    }

    fn deinitFn(_: *anyopaque) void {}
};

/// Create a test SessionManager with mock provider.
fn testSessionManager(allocator: Allocator, mock: *MockProvider, cfg: *const Config) SessionManager {
    return testSessionManagerWithMemory(allocator, mock, cfg, null, null);
}

fn testSessionManagerWithMemory(allocator: Allocator, mock: *MockProvider, cfg: *const Config, mem: ?Memory, session_store: ?memory_mod.SessionStore) SessionManager {
    var noop = observability.NoopObserver{};
    return SessionManager.init(
        allocator,
        cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        session_store,
        null,
    );
}

fn testConfig() Config {
    return .{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .default_model = "test/mock-model",
        .allocator = testing.allocator,
        // Session tests exercise both engines explicitly; pin native so a
        // future default switch cannot silently reroute them.
        .agent = .{ .harness = .native },
    };
}

test "probeVision caches unsupported result" {
    var mock = MockProvider{
        .response = "ok",
        .chat_error = error.ProviderDoesNotSupportVision,
        .supports_vision = true,
    };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);

    sm.probeVision(testing.allocator);
    try testing.expectEqual(@as(?bool, false), sm.vision_capable);
    try testing.expectEqual(@as(usize, 1), mock.chat_calls);

    sm.probeVision(testing.allocator);
    try testing.expectEqual(@as(usize, 1), mock.chat_calls);
}

test "probeVision leaves capability unset on transient provider failure" {
    // Regression: inconclusive startup probes must fall back to cfg.a2a.multi_modal.
    var mock = MockProvider{
        .response = "ok",
        .chat_error = error.ProviderError,
        .supports_vision = true,
    };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);

    sm.probeVision(testing.allocator);
    try testing.expect(sm.vision_capable == null);
    try testing.expectEqual(@as(usize, 1), mock.chat_calls);
}

test "probeVision skips network probe when provider already reports no vision support" {
    var mock = MockProvider{
        .response = "ok",
        .supports_vision = false,
    };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);

    sm.probeVision(testing.allocator);
    try testing.expectEqual(@as(?bool, false), sm.vision_capable);
    try testing.expectEqual(@as(usize, 0), mock.chat_calls);
}

test "probeVision uses vision route model ref and gateway timeout" {
    var mock = MockProvider{
        .response = "ok",
        .vision_model = "openrouter/openai/gpt-4.1",
    };
    var cfg = testConfig();
    cfg.default_model = "text-only";
    cfg.gateway.request_timeout_secs = 77;
    cfg.model_routes = &.{
        .{
            .hint = "vision",
            .provider = "openrouter",
            .model = "openai/gpt-4.1",
        },
    };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);

    sm.probeVision(testing.allocator);
    try testing.expectEqual(@as(?bool, true), sm.vision_capable);
    try testing.expectEqual(@as(usize, 1), mock.chat_calls);
    try testing.expectEqualStrings("openrouter/openai/gpt-4.1", mock.lastChatModel());
    try testing.expectEqual(@as(u64, 77), mock.last_request_timeout_secs);
}

test "probeVision frees provider and model on the probe response" {
    // Regression: probeVision freed only content and reasoning_content, so a
    // probe response annotated with provider/model (ReliableProvider sets both,
    // OpenRouter sets model) leaked. testing.allocator fails this test if the
    // response is not fully released.
    var mock = MockProvider{
        .response = "ok",
        .annotate = true,
        .vision_model = "vision-model",
    };
    var cfg = testConfig();
    cfg.default_model = "vision-model";
    var sm = testSessionManager(testing.allocator, &mock, &cfg);

    sm.probeVision(testing.allocator);
    try testing.expectEqual(@as(?bool, true), sm.vision_capable);
    try testing.expectEqual(@as(usize, 1), mock.chat_calls);
}

fn testBuildClaimToken(
    allocator: Allocator,
    secret: []const u8,
    expires_at: i64,
    canonical_user_id: []const u8,
    nonce: []const u8,
) ![]u8 {
    const payload = try std.fmt.allocPrint(allocator, "v1:{d}:{s}:{s}", .{ expires_at, canonical_user_id, nonce });
    defer allocator.free(payload);

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, payload, secret);

    var sig_hex: [64]u8 = undefined;
    for (mac, 0..) |byte, i| {
        sig_hex[i * 2] = "0123456789abcdef"[byte >> 4];
        sig_hex[i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }

    return std.fmt.allocPrint(
        allocator,
        "v1:{d}:{s}:{s}:{s}",
        .{ expires_at, canonical_user_id, nonce, sig_hex[0..] },
    );
}

fn testClaimCommand(allocator: Allocator, token: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/claim {s}", .{token});
}

fn toNativePathFragment(allocator: Allocator, unix_path_fragment: []const u8) ![]u8 {
    const native = try allocator.dupe(u8, unix_path_fragment);
    if (std_compat.fs.path.sep == '\\') {
        for (native) |*ch| {
            if (ch.* == '/') ch.* = '\\';
        }
    }
    return native;
}

fn expectPathContains(path: []const u8, unix_path_fragment: []const u8) !void {
    const native_fragment = try toNativePathFragment(testing.allocator, unix_path_fragment);
    defer testing.allocator.free(native_fragment);
    const has_unix = std.mem.indexOf(u8, path, unix_path_fragment) != null;
    const has_native = std.mem.indexOf(u8, path, native_fragment) != null;
    try testing.expect(has_unix or has_native);
}

fn expectPathEndsWith(path: []const u8, unix_path_suffix: []const u8) !void {
    const native_suffix = try toNativePathFragment(testing.allocator, unix_path_suffix);
    defer testing.allocator.free(native_suffix);
    const ends_unix = std.mem.endsWith(u8, path, unix_path_suffix);
    const ends_native = std.mem.endsWith(u8, path, native_suffix);
    try testing.expect(ends_unix or ends_native);
}

// ---------------------------------------------------------------------------
// 1. Struct tests
// ---------------------------------------------------------------------------

test "SessionManager init/deinit — no leaks" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    sm.deinit();
}

test "usage ledger appends records when retention limits are disabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 0;
    cfg.diagnostics.token_usage_ledger_max_lines = 0;
    cfg.diagnostics.token_usage_ledger_max_bytes = 0;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 101,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 1, .completion_tokens = 1, .total_tokens = 2 },
        .success = true,
    });
    sm.appendUsageRecord(.{
        .ts = 102,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 2, .completion_tokens = 2, .total_tokens = 4 },
        .success = true,
    });

    const file = try std_compat.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, content, "\n"));
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":101") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":102") != null);
}

test "cost tracker records usage when diagnostics ledger is disabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.cost.enabled = true;
    cfg.diagnostics.token_usage_ledger_enabled = false;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 201,
        .provider = "p1",
        .model = "gpt-4o",
        .usage = .{ .prompt_tokens = 10, .completion_tokens = 5, .total_tokens = 15 },
        .success = true,
    });

    const tracker = if (sm.cost_tracker) |*value| value else return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 1), tracker.requestCount());

    const file = try std_compat.fs.openFileAbsolute(tracker.storage_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "\"model\":\"gpt-4o\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"input_tokens\":10") != null);
}

test "usage ledger resets when max line limit is reached" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 0;
    cfg.diagnostics.token_usage_ledger_max_lines = 2;
    cfg.diagnostics.token_usage_ledger_max_bytes = 0;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 1,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 1, .completion_tokens = 2, .total_tokens = 3 },
        .success = true,
    });
    sm.appendUsageRecord(.{
        .ts = 2,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 2, .completion_tokens = 3, .total_tokens = 5 },
        .success = true,
    });
    sm.appendUsageRecord(.{
        .ts = 3,
        .provider = "p2",
        .model = "m2",
        .usage = .{ .prompt_tokens = 3, .completion_tokens = 4, .total_tokens = 7 },
        .success = true,
    });

    const file = try std_compat.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "\n"));
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":3") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"total_tokens\":7") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"success\":true") != null);
}

test "usage ledger resets when window expires" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 1;
    cfg.diagnostics.token_usage_ledger_max_lines = 0;
    cfg.diagnostics.token_usage_ledger_max_bytes = 0;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 10,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 1, .completion_tokens = 1, .total_tokens = 2 },
        .success = true,
    });

    sm.usage_ledger_state_initialized = true;
    sm.usage_ledger_window_started_at = std_compat.time.timestamp() - 2 * 60 * 60;

    sm.appendUsageRecord(.{
        .ts = 11,
        .provider = "p2",
        .model = "m2",
        .usage = .{ .prompt_tokens = 2, .completion_tokens = 2, .total_tokens = 4 },
        .success = true,
    });

    const file = try std_compat.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "\n"));
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":11") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"total_tokens\":4") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"success\":true") != null);
}

test "usage ledger resets when byte limit would be exceeded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 0;
    cfg.diagnostics.token_usage_ledger_max_lines = 0;
    cfg.diagnostics.token_usage_ledger_max_bytes = 140;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 21,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 1, .completion_tokens = 2, .total_tokens = 3 },
        .success = true,
    });
    sm.appendUsageRecord(.{
        .ts = 22,
        .provider = "p2",
        .model = "m2",
        .usage = .{ .prompt_tokens = 2, .completion_tokens = 3, .total_tokens = 5 },
        .success = true,
    });

    const file = try std_compat.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "\n"));
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":22") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"total_tokens\":5") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"success\":true") != null);
}

test "usage ledger records failed response flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 0;
    cfg.diagnostics.token_usage_ledger_max_lines = 0;
    cfg.diagnostics.token_usage_ledger_max_bytes = 0;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 31,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 0, .completion_tokens = 0, .total_tokens = 0 },
        .success = false,
    });

    const file = try std_compat.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":31") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"success\":false") != null);
}

test "getOrCreate creates new session for unknown key" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("telegram:chat1");
    try testing.expect(session.turn_count == 0);
    try testing.expectEqualStrings("telegram:chat1", session.session_key);
}

test "getOrCreate returns same session for same key" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s1 = try sm.getOrCreate("key1");
    const s2 = try sm.getOrCreate("key1");
    try testing.expect(s1 == s2); // pointer equality
}

test "getOrCreate creates separate sessions for different keys" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s1 = try sm.getOrCreate("telegram:a");
    const s2 = try sm.getOrCreate("discord:b");
    try testing.expect(s1 != s2);
}

test "getOrCreate applies named agent profile from routed session key" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.default_provider = "openrouter";
    cfg.agents = &.{
        .{
            .name = "Coder Agent",
            .provider = "ollama",
            .model = "qwen2.5-coder:14b",
            .system_prompt = "You are a coding specialist.",
            .temperature = 0.25,
        },
    };

    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("agent:coder-agent:telegram:group:-100123");
    try testing.expect(session.provider_holder != null);
    try testing.expectEqualStrings("Coder Agent", session.agent.profile_name.?);
    try testing.expectEqualStrings("qwen2.5-coder:14b", session.agent.model_name);
    try testing.expectEqualStrings("ollama", session.agent.default_provider);
    try testing.expectApproxEqAbs(@as(f64, 0.25), session.agent.temperature, 0.000001);
    try testing.expectEqual(@as(usize, 0), session.agent.model_routes.len);
}

test "getOrCreate stores named agent provider interface from session-owned holder" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.default_provider = "openrouter";
    cfg.providers = &.{
        .{
            .name = "custom:dmr",
            .base_url = "http://127.0.0.1:8080/v1",
        },
    };
    cfg.agents = &.{
        .{
            .name = "Coder Agent",
            .provider = "custom:dmr",
            .model = "smollm2",
            .api_key = "placeholder",
        },
    };

    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    // Regression: issue #811 requires holder-backed custom providers to bind
    // Agent.provider to the session-owned holder rather than transient storage.
    const session = try sm.getOrCreate("agent:coder-agent:telegram:group:-100123");
    try testing.expect(session.provider_holder != null);

    var holder = &session.provider_holder.?;
    const holder_provider = holder.provider();
    try testing.expect(session.agent.provider.ptr == holder_provider.ptr);
    try testing.expect(session.agent.provider.vtable == holder_provider.vtable);
    switch (session.provider_holder.?) {
        .compatible => |*compatible_provider| {
            try testing.expectEqual(@intFromPtr(compatible_provider), @intFromPtr(session.agent.provider.ptr));
        },
        else => unreachable,
    }
}

test "getOrCreate uses named agent workspace namespace when workspace_path is set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std_compat.fs.path.join(testing.allocator, &.{ base, "config.json" });
    defer testing.allocator.free(config_path);
    const expected_workspace = try std_compat.fs.path.join(testing.allocator, &.{ base, "agents", "coder-agent" });
    defer testing.allocator.free(expected_workspace);

    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.agents = &.{
        .{
            .name = "Coder Agent",
            .provider = "ollama",
            .model = "qwen2.5-coder:14b",
            .workspace_path = "agents/coder-agent",
        },
    };

    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("agent:coder-agent:telegram:group:-100123");
    try testing.expect(session.owned_memory_session_id != null);
    try testing.expectEqualStrings("agent:coder-agent", session.agent.memory_session_id.?);
    try testing.expectEqualStrings(expected_workspace, session.agent.workspace_dir);
}

test "getOrCreate preserves named agent system prompt when workspace_path is set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std_compat.fs.path.join(testing.allocator, &.{ base, "config.json" });
    defer testing.allocator.free(config_path);

    const expected_prompt = "Focus on implementation and tests.";

    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.agents = &.{
        .{
            .name = "Coder Agent",
            .provider = "ollama",
            .model = "qwen2.5-coder:14b",
            .system_prompt = expected_prompt,
            .workspace_path = "agents/coder-agent",
        },
    };

    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("agent:coder-agent:telegram:group:-100123");
    try testing.expectEqualStrings(expected_prompt, session.agent.profile_system_prompt.?);
    try expectPathEndsWith(session.agent.workspace_dir, "/agents/coder-agent");

    var capture = CapturePromptProvider{ .capture_alloc = testing.allocator };
    defer if (capture.captured_system) |c| testing.allocator.free(c);
    session.agent.provider = capture.provider();

    const response = try session.agent.turn("hello");
    defer testing.allocator.free(response);

    try testing.expectEqualStrings("ok", response);
    try testing.expect(capture.captured_system != null);
    try testing.expect(std.mem.indexOf(u8, capture.captured_system.?, expected_prompt) != null);
    try testing.expect(std.mem.indexOf(u8, capture.captured_system.?, "Profile: Coder Agent") != null);
}

test "getOrCreate auto-provisioned peer uses dedicated runtime workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.session.auto_provision_direct_agents = true;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const auto_session = try sm.getOrCreate("agent:peer-deadbeefcafebabe:whatsapp_web:direct:5511987654321");
    try expectPathContains(auto_session.agent.workspace_dir, "/agents/peer-deadbeefcafebabe/workspace");
    try testing.expectEqual(@as(usize, 1), sm.agent_runtimes.count());

    const default_session = try sm.getOrCreate("agent:main:whatsapp_web:direct:5511987654321");
    try testing.expectEqualStrings(base, default_session.agent.workspace_dir);
    try testing.expectEqual(@as(usize, 1), sm.agent_runtimes.count());
}

test "getOrCreate named agent workspace override creates dedicated runtime" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    const agents = [_]NamedAgentConfig{
        .{
            .name = "Helper Bot",
            .provider = "openrouter",
            .model = "test/mock-model",
            .workspace_path = "agents/helper-workspace",
        },
    };

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.agents = &agents;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("agent:helper-bot:telegram:direct:42");
    try expectPathEndsWith(session.agent.workspace_dir, "agents/helper-workspace");
    try testing.expectEqual(@as(usize, 1), sm.agent_runtimes.count());
}

test "named agent autonomy gets a dedicated stricter runtime policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    const agents = [_]NamedAgentConfig{
        .{
            .name = "guest",
            .provider = "openrouter",
            .model = "test/mock-model",
            .autonomy = .{ .level = .supervised },
        },
        .{
            .name = "plain",
            .provider = "openrouter",
            .model = "test/mock-model",
        },
        .{
            .name = "worker",
            .provider = "openrouter",
            .model = "test/mock-model",
            .workspace_path = "agents/worker-workspace",
        },
    };

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.agents = &agents;
    // Global autonomy is maximally permissive; the guest must not inherit it.
    cfg.autonomy.level = .yolo;
    cfg.autonomy.workspace_only = false;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    var global_tracker = security.RateTracker.init(testing.allocator, 20);
    defer global_tracker.deinit();
    var global_policy = SecurityPolicy{
        .autonomy = .yolo,
        .workspace_dir = base,
        .workspace_only = false,
        .tracker = &global_tracker,
    };
    sm.policy = &global_policy;

    // Guest has its own autonomy but no workspace_path -> still a dedicated runtime.
    const guest = try sm.getOrCreate("agent:guest:telegram:direct:42");
    try testing.expectEqual(@as(usize, 1), sm.agent_runtimes.count());
    const guest_policy = guest.agent.policy orelse return error.TestUnexpectedResult;
    try testing.expect(guest_policy != &global_policy);
    try testing.expectEqual(config_types.AutonomyLevel.supervised, guest_policy.autonomy);
    try testing.expect(guest_policy.workspace_only);
    // Supervised policy blocks command substitution; the global yolo policy allows it.
    try testing.expect(!guest_policy.isCommandAllowed("echo $(whoami)"));
    try testing.expect(global_policy.isCommandAllowed("echo $(whoami)"));
    // Per-agent policies confine file-path arguments to the workspace so the
    // guest cannot cat the global config.json; the global policy does not.
    try testing.expect(guest_policy.confine_paths);
    try testing.expect(!guest_policy.isCommandAllowed("cat ../../../config.json"));
    try testing.expect(global_policy.isCommandAllowed("cat ../../../config.json"));

    const guest_runtime = sm.agent_runtimes.get("guest") orelse return error.TestUnexpectedResult;
    // The runtime config carries the agent's own autonomy, so Agent derives its
    // exec/path/multimodal fields from it rather than the global yolo block.
    try testing.expect(guest.agent.has_own_autonomy);
    try testing.expect(!guest.agent.multimodal_unrestricted);
    try testing.expectEqual(config_types.AutonomyLevel.supervised, guest_runtime.config.autonomy.level);
    var saw_read = false;
    for (guest_runtime.tools) |t| {
        // Escape hatches run work under the global policy, so they are withheld.
        try testing.expect(!std.mem.eql(u8, t.name(), "spawn"));
        try testing.expect(!std.mem.eql(u8, t.name(), "schedule"));
        // image_info opens any absolute path with no policy — withheld as a
        // host-path metadata oracle.
        try testing.expect(!std.mem.eql(u8, t.name(), "image_info"));
        if (!std.mem.eql(u8, t.name(), "file_read")) continue;
        const read_tool: *tools_mod.file_read.FileReadTool = @ptrCast(@alignCast(t.ptr));
        // No extra allowed paths, so absolute paths outside the workspace fail.
        try testing.expectEqual(@as(usize, 0), read_tool.allowed_paths.len);
        try expectPathContains(read_tool.workspace_dir, "/agents/guest/workspace");
        saw_read = true;
    }
    try testing.expect(saw_read);

    const parsed = try tools_mod.parseTestArgs("{\"path\": \"/tmp/nullclaw-outside-probe\"}");
    defer parsed.deinit();
    for (guest_runtime.tools) |t| {
        if (!std.mem.eql(u8, t.name(), "file_read")) continue;
        const result = try t.execute(testing.allocator, parsed.value.object);
        defer if (result.output.len > 0) testing.allocator.free(result.output);
        try testing.expect(!result.success);
        // ToolResult.fail carries a static message — do not free it.
        try testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Absolute paths not allowed") != null);
    }

    // An agent without autonomy keeps the shared global policy.
    const plain = try sm.getOrCreate("agent:plain:telegram:direct:42");
    try testing.expect(plain.agent.policy == &global_policy);
    try testing.expect(!plain.agent.has_own_autonomy);
    // The global policy is yolo, so a non-restricted agent keeps the permissive
    // multimodal behaviour (no regression).
    try testing.expect(plain.agent.multimodal_unrestricted);
    try testing.expectEqual(@as(usize, 1), sm.agent_runtimes.count());

    // A dedicated runtime without an autonomy block keeps the escape hatches.
    const worker = try sm.getOrCreate("agent:worker:telegram:direct:42");
    try testing.expect(worker.agent.policy == &global_policy);
    const worker_runtime = sm.agent_runtimes.get("worker") orelse return error.TestUnexpectedResult;
    var saw_spawn = false;
    var saw_schedule = false;
    var saw_image_info = false;
    for (worker_runtime.tools) |t| {
        if (std.mem.eql(u8, t.name(), "spawn")) saw_spawn = true;
        if (std.mem.eql(u8, t.name(), "schedule")) saw_schedule = true;
        if (std.mem.eql(u8, t.name(), "image_info")) saw_image_info = true;
    }
    try testing.expect(saw_spawn);
    try testing.expect(saw_schedule);
    try testing.expect(saw_image_info);
}

test "reply attachment markers escaping the workspace are dropped for an agent with its own autonomy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_dir = std_compat.fs.Dir.wrap(tmp.dir);
    const base = try tmp_dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    try tmp_dir.writeFile(.{ .sub_path = "ok.txt", .data = "hi" });

    const inside = try std.fmt.allocPrint(testing.allocator, "{s}/ok.txt", .{base});
    defer testing.allocator.free(inside);
    const reply = try std.fmt.allocPrint(
        testing.allocator,
        "here [DOCUMENT:/etc/passwd] and [FILE:{s}]",
        .{inside},
    );
    defer testing.allocator.free(reply);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;

    var mock = MockProvider{ .response = reply };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    // Simulate a named agent that carries its own autonomy (has_own_autonomy is
    // set from the named-agent profile in Agent.fromConfigWithProfile).
    const session = try sm.getOrCreate("user:1");
    session.agent.has_own_autonomy = true;

    const resp = try sm.processMessage("user:1", "hello", null);
    defer testing.allocator.free(resp);
    // The absolute path outside the workspace is dropped...
    try testing.expect(std.mem.indexOf(u8, resp, "/etc/passwd") == null);
    // ...while the in-workspace attachment survives.
    try testing.expect(std.mem.indexOf(u8, resp, "ok.txt") != null);
}

test "reply attachment markers are kept for an agent without its own autonomy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_dir = std_compat.fs.Dir.wrap(tmp.dir);
    const base = try tmp_dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;

    var mock = MockProvider{ .response = "here [DOCUMENT:/etc/passwd] bye" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp = try sm.processMessage("user:1", "hello", null);
    defer testing.allocator.free(resp);
    // No regression: an agent without its own autonomy keeps the current
    // behaviour (the channel decides whether to upload).
    try testing.expect(std.mem.indexOf(u8, resp, "/etc/passwd") != null);
}

test "handleLocalSlashCommand drops escaping attachment markers for an agent with its own autonomy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_dir = std_compat.fs.Dir.wrap(tmp.dir);
    const base = try tmp_dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "agent:guest:telegram:direct:42";
    const session = try sm.getOrCreate(session_key);
    session.agent.has_own_autonomy = true;

    // A command that returns text containing an escaping marker is filtered:
    // /whoami returns status text. We test filterOutboundAttachmentMarkers
    // via a synthetic response to ensure handleLocalSlashCommand threads it.
    const synthetic = "Status [DOCUMENT:/etc/passwd] done";
    const filtered = try sm.filterOutboundAttachmentMarkers(session, try testing.allocator.dupe(u8, synthetic));
    defer testing.allocator.free(filtered);
    try testing.expect(std.mem.indexOf(u8, filtered, "/etc/passwd") == null);
    try testing.expect(std.mem.indexOf(u8, filtered, "Status") != null);
}

test "handleLocalSlashCommand activates interactive skill session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_dir = std_compat.fs.Dir.wrap(tmp.dir);

    const base = try tmp_dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    try tmp_dir.makePath("skills/news-digest");
    {
        const f = try tmp_dir.createFile("skills/news-digest/skill.json", .{});
        defer f.close();
        try f.writeAll(
            \\{
            \\  "name": "news-digest",
            \\  "description": "Build a digest",
            \\  "version": "1.0.0",
            \\  "author": "test"
            \\}
        );
    }
    {
        const f = try tmp_dir.createFile("skills/news-digest/SKILL.md", .{});
        defer f.close();
        try f.writeAll("Collect news and format digest.");
    }

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "agent:main:telegram:group:-100123:thread:7";
    const response = (try sm.handleLocalSlashCommand(session_key, "/iskill news-digest", .{
        .channel = "telegram",
        .account_id = "main",
        .peer_id = "-100123:thread:7",
        .group_id = "-100123",
        .is_group = true,
    })).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "Active skill set to `news-digest`") != null);

    const session = try sm.getOrCreate(session_key);
    try testing.expect(session.agent.active_skill_name != null);
    try testing.expectEqualStrings("news-digest", session.agent.active_skill_name.?);
    try testing.expect(session.agent.active_skill_interactive);
}

test "claim gate blocks unverified peer when dm_scope is main" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.session.dm_scope = .main;
    cfg.session.auto_provision_direct_agents = true;
    cfg.session.claim_secret = "claim-secret";

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp = try sm.processMessage("agent:peer-0011223344556677:main", "hello", .{
        .channel = "whatsapp_web",
        .account_id = "default",
        .peer_id = "5511",
        .is_group = false,
    });
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "Identity verification required") != null);
    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
}

test "claim gate attempts are scoped by account_id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.session.dm_scope = .per_account_channel_peer;
    cfg.session.auto_provision_direct_agents = true;
    cfg.session.claim_secret = "claim-secret";
    cfg.session.claim_max_attempts = 1;
    cfg.session.claim_lockout_secs = 120;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const bad_claim = "/claim v1:9999999999:void:nonce-bad:0000000000000000000000000000000000000000000000000000000000000000";
    const account_a = try sm.processMessage("agent:peer-aaaaaaaaaaaaaaaa:whatsapp_web:acct-a:direct:55118888", bad_claim, .{
        .channel = "whatsapp_web",
        .account_id = "acct-a",
        .peer_id = "55118888",
        .is_group = false,
    });
    defer testing.allocator.free(account_a);
    try testing.expect(std.mem.indexOf(u8, account_a, "Invalid or expired claim token") != null);

    const locked_a = try sm.processMessage("agent:peer-aaaaaaaaaaaaaaaa:whatsapp_web:acct-a:direct:55118888", "hello", .{
        .channel = "whatsapp_web",
        .account_id = "acct-a",
        .peer_id = "55118888",
        .is_group = false,
    });
    defer testing.allocator.free(locked_a);
    try testing.expect(std.mem.indexOf(u8, locked_a, "Too many failed claim attempts") != null);

    const account_b = try sm.processMessage("agent:peer-bbbbbbbbbbbbbbbb:whatsapp_web:acct-b:direct:55118888", "hello", .{
        .channel = "whatsapp_web",
        .account_id = "acct-b",
        .peer_id = "55118888",
        .is_group = false,
    });
    defer testing.allocator.free(account_b);
    try testing.expect(std.mem.indexOf(u8, account_b, "Identity verification required") != null);
}

test "claim gate blocks unverified peer before session provisioning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.session.auto_provision_direct_agents = true;
    cfg.session.claim_secret = "claim-secret";

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "agent:peer-0011223344556677:whatsapp_web:direct:5511";
    const resp = try sm.processMessage(session_key, "hello", null);
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "Identity verification required") != null);
    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
    try testing.expectEqual(@as(usize, 0), sm.agent_runtimes.count());
}

test "claim gate unlocks peer runtime after valid signed token" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.session.auto_provision_direct_agents = true;
    cfg.session.claim_secret = "claim-secret";

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "agent:peer-deadbeefcafebabe:whatsapp_web:direct:5511987654321";
    const token = try testBuildClaimToken(
        testing.allocator,
        cfg.session.claim_secret.?,
        std_compat.time.timestamp() + 600,
        "void",
        "nonce-001",
    );
    defer testing.allocator.free(token);
    const claim_cmd = try testClaimCommand(testing.allocator, token);
    defer testing.allocator.free(claim_cmd);

    const claim_resp = try sm.processMessage(session_key, claim_cmd, null);
    defer testing.allocator.free(claim_resp);
    try testing.expect(std.mem.indexOf(u8, claim_resp, "Identity verified as 'void'") != null);

    const resp = try sm.processMessage(session_key, "hello after claim", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("ok", resp);
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
    try testing.expectEqual(@as(usize, 1), sm.agent_runtimes.count());
}

test "claim gate persists verified identity across manager restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.session.auto_provision_direct_agents = true;
    cfg.session.claim_secret = "claim-secret";

    var mock = MockProvider{ .response = "ok" };
    const session_key = "agent:peer-a1b2c3d4e5f60718:whatsapp_web:direct:55115555";

    {
        var sm = testSessionManager(testing.allocator, &mock, &cfg);
        defer sm.deinit();

        const token = try testBuildClaimToken(
            testing.allocator,
            cfg.session.claim_secret.?,
            std_compat.time.timestamp() + 600,
            "void",
            "nonce-persist",
        );
        defer testing.allocator.free(token);
        const claim_cmd = try testClaimCommand(testing.allocator, token);
        defer testing.allocator.free(claim_cmd);

        const claim_resp = try sm.processMessage(session_key, claim_cmd, null);
        defer testing.allocator.free(claim_resp);
        try testing.expect(std.mem.indexOf(u8, claim_resp, "Identity verified as 'void'") != null);
    }

    {
        var sm = testSessionManager(testing.allocator, &mock, &cfg);
        defer sm.deinit();

        const resp = try sm.processMessage(session_key, "hello after restart", null);
        defer testing.allocator.free(resp);
        try testing.expectEqualStrings("ok", resp);
    }
}

test "claim gate rejects replayed nonce across peers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.session.auto_provision_direct_agents = true;
    cfg.session.claim_secret = "claim-secret";

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const token = try testBuildClaimToken(
        testing.allocator,
        cfg.session.claim_secret.?,
        std_compat.time.timestamp() + 600,
        "void",
        "nonce-replay",
    );
    defer testing.allocator.free(token);
    const claim_cmd = try testClaimCommand(testing.allocator, token);
    defer testing.allocator.free(claim_cmd);

    const first_key = "agent:peer-aaaaaaaaaaaaaaaa:whatsapp_web:direct:551100000001";
    const second_key = "agent:peer-bbbbbbbbbbbbbbbb:whatsapp_web:direct:551100000002";

    const first_resp = try sm.processMessage(first_key, claim_cmd, null);
    defer testing.allocator.free(first_resp);
    try testing.expect(std.mem.indexOf(u8, first_resp, "Identity verified as 'void'") != null);

    const replay_resp = try sm.processMessage(second_key, claim_cmd, null);
    defer testing.allocator.free(replay_resp);
    try testing.expect(std.mem.indexOf(u8, replay_resp, "Invalid or expired claim token") != null);
    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
}

test "claim gate locks out after max failed attempts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.session.auto_provision_direct_agents = true;
    cfg.session.claim_secret = "claim-secret";
    cfg.session.claim_max_attempts = 2;
    cfg.session.claim_lockout_secs = 120;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "agent:peer-feedfacefeedface:whatsapp_web:direct:55118888";
    const bad_claim = "/claim v1:9999999999:void:nonce-bad:0000000000000000000000000000000000000000000000000000000000000000";

    const first = try sm.processMessage(session_key, bad_claim, null);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "Invalid or expired claim token") != null);

    const second = try sm.processMessage(session_key, bad_claim, null);
    defer testing.allocator.free(second);
    try testing.expect(std.mem.indexOf(u8, second, "Invalid or expired claim token") != null);

    const third = try sm.processMessage(session_key, "hello", null);
    defer testing.allocator.free(third);
    try testing.expect(std.mem.indexOf(u8, third, "Too many failed claim attempts") != null);
    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
}

test "claim gate supports revoke and returns peer to quarantine mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.session.auto_provision_direct_agents = true;
    cfg.session.claim_secret = "claim-secret";
    cfg.session.claim_admin_secret = "admin-secret";

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "agent:peer-1234567890abcdef:whatsapp_web:direct:55119999";
    const token = try testBuildClaimToken(
        testing.allocator,
        cfg.session.claim_secret.?,
        std_compat.time.timestamp() + 600,
        "void",
        "nonce-revoke",
    );
    defer testing.allocator.free(token);
    const claim_cmd = try testClaimCommand(testing.allocator, token);
    defer testing.allocator.free(claim_cmd);

    const claim_resp = try sm.processMessage(session_key, claim_cmd, null);
    defer testing.allocator.free(claim_resp);
    try testing.expect(std.mem.indexOf(u8, claim_resp, "Identity verified as 'void'") != null);

    const unlocked = try sm.processMessage(session_key, "hello", null);
    defer testing.allocator.free(unlocked);
    try testing.expectEqualStrings("ok", unlocked);
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());

    const bad_revoke = try sm.processMessage(session_key, "/revoke nope", null);
    defer testing.allocator.free(bad_revoke);
    try testing.expectEqualStrings("Invalid revoke secret.", bad_revoke);

    const revoked = try sm.processMessage(session_key, "/revoke admin-secret", null);
    defer testing.allocator.free(revoked);
    try testing.expect(std.mem.indexOf(u8, revoked, "Identity link revoked") != null);

    const gated_again = try sm.processMessage(session_key, "hello again", null);
    defer testing.allocator.free(gated_again);
    try testing.expect(std.mem.indexOf(u8, gated_again, "Identity verification required") != null);
}

test "getOrCreate falls back to default config for unknown routed agent id" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.default_provider = "openrouter";
    cfg.agents = &.{
        .{
            .name = "coder",
            .provider = "ollama",
            .model = "qwen2.5-coder:14b",
        },
    };

    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("agent:missing:telegram:group:-100123");
    try testing.expect(session.provider_holder == null);
    try testing.expect(session.agent.profile_name == null);
    try testing.expectEqualStrings("test/mock-model", session.agent.model_name);
    try testing.expectEqualStrings("openrouter", session.agent.default_provider);
}

test "getOrCreate keeps routed main session on root config when named agent normalizes to main" {
    // Regression: routed fallback sessions must keep using the root config even
    // when a named agent normalizes to `main`.
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.default_provider = "openrouter";
    cfg.agents = &.{
        .{
            .name = "Main",
            .provider = "ollama",
            .model = "qwen2.5-coder:14b",
        },
    };

    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("agent:main:telegram:group:-100123");
    try testing.expect(session.provider_holder == null);
    try testing.expect(session.agent.profile_name == null);
    try testing.expectEqualStrings("test/mock-model", session.agent.model_name);
    try testing.expectEqualStrings("openrouter", session.agent.default_provider);
}

test "sessionCount reflects active sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
    _ = try sm.getOrCreate("a");
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
    _ = try sm.getOrCreate("b");
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());
    _ = try sm.getOrCreate("a"); // existing
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());
}

test "snapshotSessions captures live session metadata" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("telegram:main:-100123#topic:77");
    session.mutex.lock();
    session.last_active = 1234;
    session.turn_count = 9;
    session.mutex.unlock();
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    const snapshots = try sm.snapshotSessions(testing.allocator);
    defer SessionManager.freeSessionSnapshots(testing.allocator, snapshots);

    try testing.expectEqual(@as(usize, 1), snapshots.len);
    try testing.expectEqualStrings("telegram:main:-100123#topic:77", snapshots[0].session_key);
    try testing.expectEqual(@as(i64, 1234), snapshots[0].last_active);
    try testing.expectEqual(@as(u64, 9), snapshots[0].turn_count);
    try testing.expect(snapshots[0].turn_running);
}

test "migrateLegacySessionKey renames in-memory session to canonical key" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const legacy = try sm.getOrCreate("agent:main:telegram:group:-100123#topic:77");
    legacy.turn_count = 3;

    sm.migrateLegacySessionKey("agent:main:telegram:group:-100123:thread:77", "agent:main:telegram:group:-100123#topic:77");

    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
    try testing.expect(sm.sessions.get("agent:main:telegram:group:-100123#topic:77") == null);

    const canonical = sm.sessions.get("agent:main:telegram:group:-100123:thread:77") orelse return error.TestExpectedEqual;
    try testing.expect(canonical == legacy);
    try testing.expectEqualStrings("agent:main:telegram:group:-100123:thread:77", canonical.session_key);
    try testing.expect(canonical.agent.memory_session_id != null);
    try testing.expectEqualStrings("agent:main:telegram:group:-100123:thread:77", canonical.agent.memory_session_id.?);
    try testing.expectEqual(@as(u64, 3), canonical.turn_count);
}

test "migrateLegacySessionKey copies persisted transcript and usage to canonical key" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, null, sqlite_mem.sessionStore());
    defer sm.deinit();

    const store = sqlite_mem.sessionStore();
    try store.saveMessage("agent:main:telegram:group:-100123#topic:77", "user", "hello");
    try store.saveMessage("agent:main:telegram:group:-100123#topic:77", "assistant", "world");
    try store.saveUsage("agent:main:telegram:group:-100123#topic:77", 42);

    sm.migrateLegacySessionKey("agent:main:telegram:group:-100123:thread:77", "agent:main:telegram:group:-100123#topic:77");

    const canonical_msgs = try store.loadMessages(testing.allocator, "agent:main:telegram:group:-100123:thread:77");
    defer memory_mod.freeMessages(testing.allocator, canonical_msgs);
    try testing.expectEqual(@as(usize, 2), canonical_msgs.len);
    try testing.expectEqualStrings("hello", canonical_msgs[0].content);
    try testing.expectEqualStrings("world", canonical_msgs[1].content);
    try testing.expectEqual(@as(?u64, 42), try store.loadUsage("agent:main:telegram:group:-100123:thread:77"));

    const legacy_msgs = try store.loadMessages(testing.allocator, "agent:main:telegram:group:-100123#topic:77");
    defer memory_mod.freeMessages(testing.allocator, legacy_msgs);
    try testing.expectEqual(@as(usize, 0), legacy_msgs.len);
    try testing.expectEqual(@as(?u64, null), try store.loadUsage("agent:main:telegram:group:-100123#topic:77"));
}

test "migrateLegacySessionKey reattaches session-scoped memory to canonical key" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    try mem.store("autosave_user_1", "legacy memory", .conversation, "agent:main:telegram:group:-100123#topic:77");

    sm.migrateLegacySessionKey("agent:main:telegram:group:-100123:thread:77", "agent:main:telegram:group:-100123#topic:77");

    const migrated = try mem.get(testing.allocator, "autosave_user_1");
    defer if (migrated) |entry| entry.deinit(testing.allocator);
    try testing.expect(migrated != null);
    try testing.expect(migrated.?.session_id != null);
    try testing.expectEqualStrings("agent:main:telegram:group:-100123:thread:77", migrated.?.session_id.?);

    const legacy_entries = try mem.list(testing.allocator, null, "agent:main:telegram:group:-100123#topic:77");
    defer memory_mod.freeEntries(testing.allocator, legacy_entries);
    try testing.expectEqual(@as(usize, 0), legacy_entries.len);
}

test "session has correct initial state" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:init");
    try testing.expectEqual(@as(u64, 0), s.turn_count);
    try testing.expect(!s.turn_running.load(.acquire));
    try testing.expect(!s.agent.has_system_prompt);
    try testing.expectEqual(@as(usize, 0), s.agent.historyLen());
}

test "InboundRouteAction.skipsTurn covers every non-process action" {
    // Regression: shells gate on skipsTurn(), so a new non-process action must
    // never start a turn for a message the router already consumed or dropped.
    try testing.expect(!SessionManager.InboundRouteAction.process.skipsTurn());
    try testing.expect(SessionManager.InboundRouteAction.steered.skipsTurn());
    try testing.expect(SessionManager.InboundRouteAction.skip.skipsTurn());
    try testing.expect(SessionManager.InboundRouteAction.dropped.skipsTurn());
}

test "routeInbound handles active session routing side effects" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "route:active";
    const session = try sm.getOrCreate(session_key);
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    session.agent.queue_mode = .latest;
    try testing.expectEqual(
        SessionManager.InboundRouteAction.steered,
        sm.routeInbound(session_key, "latest message"),
    );
    try testing.expect(sm.routeInput(session_key).has_pending_injection);
    const drained = (try session.drainInjection(sm.allocator, testing.allocator)).?;
    defer testing.allocator.free(drained);
    try testing.expectEqualStrings("latest message", drained);

    session.agent.queue_mode = .off;
    // Regression: a dropped message must be reported so the shell can tell the
    // sender instead of discarding it silently.
    try testing.expectEqual(
        SessionManager.InboundRouteAction.dropped,
        sm.routeInbound(session_key, "drop message"),
    );
    try testing.expect(!sm.routeInput(session_key).has_pending_injection);

    session.agent.queue_mode = .serial;
    try testing.expectEqual(
        SessionManager.InboundRouteAction.process,
        sm.routeInbound(session_key, "queued message"),
    );
}

test "routeInbound appends steer messages in arrival order" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "route:steer";
    const session = try sm.getOrCreate(session_key);
    session.agent.queue_mode = .steer;
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    // Regression: consecutive mid-turn messages used to replace each other,
    // silently losing every message but the newest.
    try testing.expectEqual(
        SessionManager.InboundRouteAction.steered,
        sm.routeInbound(session_key, "use the other file"),
    );
    try testing.expectEqual(
        SessionManager.InboundRouteAction.steered,
        sm.routeInbound(session_key, "and keep the header"),
    );

    const drained = (try session.drainInjection(sm.allocator, testing.allocator)).?;
    defer testing.allocator.free(drained);
    try testing.expectEqualStrings("use the other file\n\nand keep the header", drained);
}

test "routeInbound never injects slash commands into a running turn" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "route:slash";
    const session = try sm.getOrCreate(session_key);
    session.agent.queue_mode = .steer;
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    // Regression: a slash command sent mid-turn used to be appended as plain
    // user text, so agent.handleSlashCommand never ran and the model answered
    // the literal command. It must instead wait for the session lock and run as
    // a serial follow-up.
    try testing.expectEqual(
        SessionManager.InboundRouteAction.process,
        sm.routeInbound(session_key, "/model gpt-5.2"),
    );
    try testing.expect(!sm.routeInput(session_key).has_pending_injection);
}

test "routeInbound steers slash-prefixed text that is not a known command" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "route:slash-path";
    const session = try sm.getOrCreate(session_key);
    session.agent.queue_mode = .steer;
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    // Regression: parseSlashCommand accepted any slash-prefixed token, so
    // "/tmp/report.csv please read" was treated as a command, held back from
    // the running turn, and waited on the session lock.
    try testing.expectEqual(
        SessionManager.InboundRouteAction.steered,
        sm.routeInbound(session_key, "/tmp/report.csv please read"),
    );
    const drained = (try session.drainInjection(sm.allocator, testing.allocator)).?;
    defer testing.allocator.free(drained);
    try testing.expectEqualStrings("/tmp/report.csv please read", drained);
}

test "appendMidTurnIfRunning refuses stopped sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("append:stopped");

    // Regression: if routeInbound observed a running turn but the turn stopped
    // before deposit, the message must fall back to normal processing.
    try testing.expect(!try session.appendMidTurnIfRunning(testing.allocator, "stale"));
    try testing.expect(!session.hasInjection());

    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);
    try testing.expect(try session.appendMidTurnIfRunning(testing.allocator, "active"));
    const drained = (try session.drainInjection(testing.allocator, testing.allocator)) orelse return error.TestExpectedEqual;
    defer testing.allocator.free(drained);
    try testing.expectEqualStrings("active", drained);
}

test "processInboundMessage reports steered and dropped to the caller" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("inbound:result");
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    session.agent.queue_mode = .steer;
    const steered = try sm.processInboundMessage("inbound:result", "steer me", null);
    try testing.expectEqual(SessionManager.InboundRouteAction.steered, steered.action);
    try testing.expect(steered.reply == null);

    session.agent.queue_mode = .off;
    const dropped = try sm.processInboundMessage("inbound:result", "drop me", null);
    try testing.expectEqual(SessionManager.InboundRouteAction.dropped, dropped.action);
    try testing.expect(dropped.reply == null);

    // Regression: transports collapsed every non-process action to "no reply",
    // so a steered message was never acknowledged and a dropped one never told
    // the sender. The action now carries the user-visible notice.
    try testing.expectEqualStrings(inbound_router.queued_notice, SessionManager.consumedNotice(steered.action).?);
    try testing.expectEqualStrings(inbound_router.dropped_notice, SessionManager.consumedNotice(dropped.action).?);
    try testing.expect(SessionManager.consumedNotice(.process) == null);
    try testing.expect(SessionManager.consumedNotice(.skip) == null);
}

test "closing the injection window routes later messages to a fresh turn" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("inject:closing");
    session.agent.queue_mode = .steer;
    session.turn_running.store(true, .release);
    defer {
        session.turn_running.store(false, .release);
        session.turn_closing.store(false, .release);
    }

    try testing.expect(try session.appendMidTurnIfRunning(testing.allocator, "before close"));
    session.closeInjectionWindow();

    // Regression: a deposit after the last drain was acknowledged but left
    // pending until an unrelated turn. It must fall back to a new turn, and
    // text deposited before the window closed must still be drained.
    try testing.expect(!try session.appendMidTurnIfRunning(testing.allocator, "after close"));
    try testing.expectEqual(SessionManager.InboundRouteAction.process, sm.routeInbound("inject:closing", "after close"));
    try testing.expect(session.hasInjection());

    const drained = (try session.drainInjection(testing.allocator, testing.allocator)).?;
    defer testing.allocator.free(drained);
    try testing.expectEqualStrings("before close", drained);
}

test "new sessions default to steer so mid-turn messages are not dropped" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("route:default");
    try testing.expectEqual(agent_mod.Agent.QueueMode.steer, session.agent.queue_mode);
}

test "routeInbound interrupts a busy session for /stop instead of dropping" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "route:stop";
    const session = try sm.getOrCreate(session_key);
    session.agent.queue_mode = .off;
    session.clearInterrupt();
    defer session.turn_running.store(false, .release);

    session.turn_running.store(true, .release);

    // /stop must reach the busy session and set the interrupt flag rather than
    // being dropped by the queue_mode=off busy gate.
    try testing.expectEqual(
        SessionManager.InboundRouteAction.skip,
        sm.routeInbound(session_key, "/stop"),
    );
    try testing.expect(session.agent.interrupt_requested.load(.acquire));

    // A non-stop message in the same state is still dropped without interrupt.
    session.clearInterrupt();
    try testing.expectEqual(
        SessionManager.InboundRouteAction.dropped,
        sm.routeInbound(session_key, "just a message"),
    );
    try testing.expect(!session.agent.interrupt_requested.load(.acquire));

    // /stop when no turn is running is routed normally (agent replies).
    session.turn_running.store(false, .release);
    try testing.expectEqual(
        SessionManager.InboundRouteAction.process,
        sm.routeInbound(session_key, "/stop"),
    );
}

test "requestTurnInterrupt signals only active sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("interrupt:1");
    var none = sm.requestTurnInterrupt("interrupt:1");
    defer none.deinit(testing.allocator);
    try testing.expect(!none.requested);

    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);
    var yes = sm.requestTurnInterrupt("interrupt:1");
    defer yes.deinit(testing.allocator);
    try testing.expect(yes.requested);
    try testing.expect(session.agent.interrupt_requested.load(.acquire));
}

test "requestTurnInterrupt returns active tool snapshot when available" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("interrupt:tool");
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    session.agent.tool_state_mu.lock();
    if (session.agent.active_tool_name) |old| testing.allocator.free(old);
    session.agent.active_tool_name = try testing.allocator.dupe(u8, "shell");
    session.agent.tool_state_mu.unlock();

    var res = sm.requestTurnInterrupt("interrupt:tool");
    defer res.deinit(testing.allocator);
    try testing.expect(res.requested);
    try testing.expect(res.active_tool != null);
    try testing.expectEqualStrings("shell", res.active_tool.?);
}

test "lockSessionForTurn waits without interrupting active serial turn" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("interrupt:contention");
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);
    session.clearInterrupt();

    session.mutex.lock();
    var session_unlocked = false;
    defer if (!session_unlocked) session.mutex.unlock();

    const Worker = struct {
        const Ctx = struct {
            session: *Session,
            started: *std.atomic.Value(bool),
        };

        fn run(ctx: Ctx) void {
            ctx.started.store(true, .release);
            SessionManager.lockSessionForTurn(ctx.session);
            ctx.session.mutex.unlock();
        }
    };

    var worker_started = std.atomic.Value(bool).init(false);
    const ctx = Worker.Ctx{ .session = session, .started = &worker_started };
    var thread = try std.Thread.spawn(.{}, Worker.run, .{ctx});
    var thread_joined = false;
    defer if (!thread_joined) thread.join();

    var attempts: usize = 0;
    while (attempts < 100 and !worker_started.load(.acquire)) : (attempts += 1) {
        std_compat.thread.sleep(2 * std.time.ns_per_ms);
    }
    try testing.expect(worker_started.load(.acquire));

    attempts = 0;
    while (attempts < 20) : (attempts += 1) {
        std_compat.thread.sleep(2 * std.time.ns_per_ms);
    }
    // Regression (#832): serial queued turns must wait behind active turns without hard-stopping them.
    try testing.expect(!session.agent.interrupt_requested.load(.acquire));

    session.mutex.unlock();
    session_unlocked = true;
    thread.join();
    thread_joined = true;
}

// ---------------------------------------------------------------------------
// 2. processMessage tests
// ---------------------------------------------------------------------------

test "processMessage returns mock response" {
    var mock = MockProvider{ .response = "Hello from mock" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp = try sm.processMessage("user:1", "hi", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("Hello from mock", resp);
}

test "routeInput reports pending mid-turn injection" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "inject:route";
    const session = try sm.getOrCreate(session_key);
    session.agent.queue_mode = .latest;
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    try testing.expectEqual(inbound_router.RoutingDecision.inject, inbound_router.route(sm.routeInput(session_key)));

    // Regression: shells rely on has_pending_injection to replace latest-mode
    // input instead of accumulating stale pending messages.
    try sm.injectMidTurn(session_key, "first pending");
    try testing.expectEqual(inbound_router.RoutingDecision.replace_injection, inbound_router.route(sm.routeInput(session_key)));
}

test "processMessageStreaming drains pending mid-turn injection into turn history" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "inject:drain";
    _ = try sm.getOrCreate(session_key);
    try sm.injectMidTurn(session_key, "mid-turn note");

    const resp = try sm.processMessageStreaming(session_key, "hello", null, null, null);
    defer testing.allocator.free(resp);

    const session = try sm.getOrCreate(session_key);
    try testing.expect(!sm.routeInput(session_key).has_pending_injection);
    var saw_initial = false;
    var saw_injected = false;
    for (session.agent.history.items) |entry| {
        if (entry.role != .user) continue;
        if (std.mem.eql(u8, entry.content, "hello")) saw_initial = true;
        if (std.mem.eql(u8, entry.content, "mid-turn note")) saw_injected = true;
    }
    // Regression: pending injections must be owned by the agent history after
    // drain so Session.deinit has no stale buffer and the next turn cannot see it.
    try testing.expect(saw_initial);
    try testing.expect(saw_injected);
}

test "processMessageStreaming forwards provider deltas" {
    var mock = MockStreamingProvider{ .response = "streaming reply" };
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        null,
        noop.observer(),
        null,
        null,
    );
    defer sm.deinit();

    var collector = DeltaCollector{ .allocator = testing.allocator };
    defer collector.deinit();

    const resp = try sm.processMessageStreaming(
        "stream:1",
        "hi",
        null,
        .{
            .callback = DeltaCollector.onEvent,
            .ctx = @ptrCast(&collector),
        },
        null,
    );
    defer testing.allocator.free(resp);

    try testing.expectEqualStrings("streaming reply", resp);
    try testing.expectEqualStrings("streaming reply", collector.data.items);
}

test "processMessageStreaming suppresses redacted chunks and returns display response" {
    var mock = MockStreamingProvider{ .response = "sent to [EMAIL_1]" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    var collector = DeltaCollector{ .allocator = testing.allocator };
    defer collector.deinit();

    const session_key = "stream:redaction";
    const resp = try sm.processMessageStreaming(
        session_key,
        "please email alice@example.com",
        null,
        .{
            .callback = DeltaCollector.onEvent,
            .ctx = @ptrCast(&collector),
        },
        null,
    );
    defer testing.allocator.free(resp);

    try testing.expectEqualStrings("sent to alice@example.com", resp);
    try testing.expectEqualStrings("", collector.data.items);

    const detailed = try sqlite_mem.sessionStore().loadMessagesDetailed(testing.allocator, session_key, 10, 0);
    defer memory_mod.freeDetailedMessages(testing.allocator, detailed);
    try testing.expectEqual(@as(usize, 2), detailed.len);
    for (detailed) |message| {
        try testing.expect(std.mem.indexOf(u8, message.content, "alice@example.com") == null);
    }
    try testing.expect(std.mem.indexOf(u8, detailed[0].content, "[EMAIL_1]") != null);
    try testing.expect(std.mem.indexOf(u8, detailed[1].content, "[EMAIL_1]") != null);
}

test "processMessageStreaming does not rehydrate placeholders for group sessions" {
    var mock = MockStreamingProvider{ .response = "sent to [EMAIL_1]" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    var collector = DeltaCollector{ .allocator = testing.allocator };
    defer collector.deinit();

    const session_key = "telegram:main:group:-1001";
    const resp = try sm.processMessageStreaming(
        session_key,
        "please email alice@example.com",
        .{
            .channel = "telegram",
            .is_group = true,
        },
        .{
            .callback = DeltaCollector.onEvent,
            .ctx = @ptrCast(&collector),
        },
        null,
    );
    defer testing.allocator.free(resp);

    try testing.expectEqualStrings("sent to [EMAIL_1]", resp);
    try testing.expectEqualStrings("sent to [EMAIL_1]", collector.data.items);

    const detailed = try sqlite_mem.sessionStore().loadMessagesDetailed(testing.allocator, session_key, 10, 0);
    defer memory_mod.freeDetailedMessages(testing.allocator, detailed);
    try testing.expectEqual(@as(usize, 2), detailed.len);
    for (detailed) |message| {
        try testing.expect(std.mem.indexOf(u8, message.content, "alice@example.com") == null);
    }
}

test "agent.harness defaults to the in-process dsh engine" {
    // Regression: the P3 default switch must select the in-process engine
    // when `agent.harness` is omitted.
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();
    // Drop the fixture's explicit choice so the compiled-in default applies.
    fixture.cfg.agent = .{};

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{.{ .text = "default engine" }});
    defer provider.deinit();
    var sm = fixture.manager(&provider);
    defer sm.deinit();

    const reply = try sm.processMessage("cli:main:default-harness", "hi", null);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("default engine", reply);

    const session = try sm.getOrCreate("cli:main:default-harness");
    try testing.expect(session.dsh == null);
    try testing.expect(session.dsh_native != null);
    try testing.expectEqual(
        @as(*anyopaque, @ptrCast(&session.dsh_native.?.harness)),
        session.turnHarness().ptr,
    );
}

test "agent.harness=dsh-sidecar is ignored in a default build" {
    if (comptime dsh_enabled) return error.SkipZigTest;
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.agent.harness = .dsh_sidecar;
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("cli:main:local");
    try testing.expect(session.dsh == null);
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&session.harness)), session.turnHarness().ptr);
}

test "dsh route maps providers to dsh endpoints and protocols" {
    const cfg = testConfig();

    const anthropic = try dshRouteEndpoint(&cfg, "anthropic");
    try testing.expectEqualStrings("https://api.anthropic.com", anthropic.base_url);
    try testing.expectEqualStrings("anthropic-messages", anthropic.api);

    const openai = try dshRouteEndpoint(&cfg, "openai");
    try testing.expectEqualStrings("https://api.openai.com/v1", openai.base_url);
    try testing.expectEqualStrings("openai-completions", openai.api);

    const openrouter = try dshRouteEndpoint(&cfg, "openrouter");
    try testing.expectEqualStrings("https://openrouter.ai/api/v1", openrouter.base_url);
    try testing.expectEqualStrings("openai-completions", openrouter.api);

    const custom = try dshRouteEndpoint(&cfg, "custom:https://api.example.com/v1");
    try testing.expectEqualStrings("https://api.example.com/v1", custom.base_url);
    try testing.expectEqualStrings("openai-completions", custom.api);

    const anthropic_custom = try dshRouteEndpoint(&cfg, "anthropic-custom:https://api.example.com");
    try testing.expectEqualStrings("https://api.example.com", anthropic_custom.base_url);
    try testing.expectEqualStrings("anthropic-messages", anthropic_custom.api);

    // A compatible URL may already name the full request endpoint; dsh appends
    // the path itself.
    const full_endpoint = try dshRouteEndpoint(&cfg, "custom:https://api.example.com/v1/chat/completions");
    try testing.expectEqualStrings("https://api.example.com/v1", full_endpoint.base_url);
    try testing.expectEqualStrings("openai-completions", full_endpoint.api);

    // No dsh protocol for these clients.
    try testing.expectError(error.DshProviderUnsupported, dshRouteEndpoint(&cfg, "gemini"));
    try testing.expectError(error.DshProviderUnsupported, dshRouteEndpoint(&cfg, "vertex"));
    try testing.expectError(error.DshProviderUnsupported, dshRouteEndpoint(&cfg, "azure"));
    try testing.expectError(error.DshProviderUnsupported, dshRouteEndpoint(&cfg, "ollama"));
    try testing.expectError(error.DshProviderUnsupported, dshRouteEndpoint(&cfg, "claude-cli"));

    var provider_list = [_]config_types.ProviderEntry{.{
        .name = "proxy",
        .api_key = "test-key",
        .base_url = "https://api.example.com/v1/chat/completions",
        .api_mode = .responses,
    }};
    var proxy_cfg = testConfig();
    proxy_cfg.providers = &provider_list;
    const proxy = try dshRouteEndpoint(&proxy_cfg, "proxy");
    try testing.expectEqualStrings("https://api.example.com/v1", proxy.base_url);
    try testing.expectEqualStrings("openai-responses", proxy.api);
}

test "dsh route prefers configured openai and openrouter base urls" {
    // Regression: the openai/openrouter dsh route forced defaultProviderUrl
    // and ignored models.providers[...].base_url, so requests bypassed the
    // configured proxy or gateway.
    var providers_cfg = [_]config_types.ProviderEntry{
        .{
            .name = "openai",
            .api_key = "test-key",
            .base_url = "https://gateway.example.com/v1/chat/completions",
        },
        .{
            .name = "openrouter",
            .api_key = "test-key",
            .base_url = "https://router.example.com/api/v1",
        },
    };
    var cfg = testConfig();
    cfg.providers = &providers_cfg;

    const openai = try dshRouteEndpoint(&cfg, "openai");
    try testing.expectEqualStrings("https://gateway.example.com/v1", openai.base_url);
    try testing.expectEqualStrings("openai-completions", openai.api);

    const openrouter = try dshRouteEndpoint(&cfg, "openrouter");
    try testing.expectEqualStrings("https://router.example.com/api/v1", openrouter.base_url);
    try testing.expectEqualStrings("openai-completions", openrouter.api);
}

test "dsh route maps openai api_mode responses to the responses protocol" {
    // Regression: api_mode=responses was ignored for the openai provider, so
    // dsh sent chat-completions requests to a responses-only endpoint.
    var providers_cfg = [_]config_types.ProviderEntry{.{
        .name = "openai",
        .api_key = "test-key",
        .api_mode = .responses,
    }};
    var cfg = testConfig();
    cfg.providers = &providers_cfg;

    const openai = try dshRouteEndpoint(&cfg, "openai");
    try testing.expectEqualStrings("https://api.openai.com/v1", openai.base_url);
    try testing.expectEqualStrings("openai-responses", openai.api);
}

test "agent.harness=dsh-sidecar fails loudly for a provider dsh cannot route" {
    if (comptime !dsh_enabled) return error.SkipZigTest;
    // Regression: an unsupported provider left the profile empty, letting dsh
    // silently fall back to its built-in default model.
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.default_provider = "gemini";
    cfg.default_model = "gemini/gemini-pro";
    cfg.agent.harness = .dsh_sidecar;
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    try testing.expectError(error.DshProviderUnsupported, sm.getOrCreate("cli:main:local"));
}

test "dsh route strips anthropic version and messages suffixes" {
    // Regression: an anthropic base_url ending in /v1 or /v1/messages made dsh
    // request /v1/v1/messages (404).
    {
        var providers_cfg = [_]config_types.ProviderEntry{.{
            .name = "anthropic",
            .api_key = "test-key",
            .base_url = "https://api.example.com/v1",
        }};
        var cfg = testConfig();
        cfg.providers = &providers_cfg;
        const endpoint = try dshRouteEndpoint(&cfg, "anthropic");
        try testing.expectEqualStrings("https://api.example.com", endpoint.base_url);
        try testing.expectEqualStrings("anthropic-messages", endpoint.api);
    }
    {
        var providers_cfg = [_]config_types.ProviderEntry{.{
            .name = "anthropic",
            .api_key = "test-key",
            .base_url = "https://api.example.com/v1/messages",
        }};
        var cfg = testConfig();
        cfg.providers = &providers_cfg;
        const endpoint = try dshRouteEndpoint(&cfg, "anthropic");
        try testing.expectEqualStrings("https://api.example.com", endpoint.base_url);
    }
    {
        var providers_cfg = [_]config_types.ProviderEntry{.{
            .name = "anthropic",
            .api_key = "test-key",
            .base_url = "https://v1.example.com",
        }};
        var cfg = testConfig();
        cfg.providers = &providers_cfg;
        // A host named v1 is not a version path.
        const endpoint = try dshRouteEndpoint(&cfg, "anthropic");
        try testing.expectEqualStrings("https://v1.example.com", endpoint.base_url);
    }
    {
        var cfg = testConfig();
        const endpoint = try dshRouteEndpoint(&cfg, "anthropic-custom:https://api.example.com/v1/messages");
        try testing.expectEqualStrings("https://api.example.com", endpoint.base_url);
    }
}

test "agent.harness=dsh-sidecar selects the sidecar engine in a dsh build" {
    if (comptime !dsh_enabled) return error.SkipZigTest;
    const mock_mod = @import("harness/dsh/mock.zig");
    var dsh_mock = try mock_mod.MockDsh.init(testing.allocator);
    defer dsh_mock.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std_compat.fs.path.join(testing.allocator, &.{ base, "config.json" });
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.agent.harness = .dsh_sidecar;

    const boot_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/?token={s}", .{
        dsh_mock.port(),
        mock_mod.test_token,
    });
    defer testing.allocator.free(boot_url);
    dsh_test_boot_url = boot_url;
    defer dsh_test_boot_url = null;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("cli:main:local");
    try testing.expect(session.dsh != null);
    const h = session.turnHarness();
    if (session.dsh) |*d| {
        try testing.expectEqual(@as(*anyopaque, @ptrCast(&d.harness)), h.ptr);
    }
}

/// Runs one host turn on a worker thread and counts the live deltas it gets.
/// Counting (not collecting) keeps the main thread's read race-free.
const HostDshTurn = struct {
    mgr: *SessionManager,
    session_key: []const u8,
    content: []const u8,
    chunks: std.atomic.Value(usize) = .init(0),
    reply: ?[]const u8 = null,
    failure: ?anyerror = null,

    fn onEvent(ctx: *anyopaque, event: streaming.Event) void {
        if (event.stage != .chunk or event.text.len == 0) return;
        const self: *HostDshTurn = @ptrCast(@alignCast(ctx));
        _ = self.chunks.fetchAdd(1, .acq_rel);
    }

    fn main(self: *@This()) void {
        self.reply = self.mgr.processMessageStreaming(self.session_key, self.content, null, .{
            .callback = onEvent,
            .ctx = @ptrCast(self),
        }, null) catch |err| {
            self.failure = err;
            return;
        };
    }
};

fn waitForDshDelta(turn: *HostDshTurn) void {
    const deadline = std_compat.time.milliTimestamp() + 5_000;
    while (turn.chunks.load(.acquire) == 0 and std_compat.time.milliTimestamp() < deadline) {
        std_compat.thread.sleep(std.time.ns_per_ms);
    }
}

fn dshSessionTestConfig(tmp: *std.testing.TmpDir) !struct { base: []u8, config_path: []u8, cfg: Config } {
    const base = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    errdefer testing.allocator.free(base);
    const config_path = try std_compat.fs.path.join(testing.allocator, &.{ base, "config.json" });
    errdefer testing.allocator.free(config_path);
    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.agent.harness = .dsh_sidecar;
    return .{ .base = base, .config_path = config_path, .cfg = cfg };
}

test "host /stop cancels an in-flight dsh turn and keeps the partial reply" {
    // Regression: host /stop never reached the dsh harness, so dsh turns could
    // not be cancelled.
    if (comptime !dsh_enabled) return error.SkipZigTest;
    const mock_mod = @import("harness/dsh/mock.zig");
    var dsh_mock = try mock_mod.MockDsh.init(testing.allocator);
    defer dsh_mock.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var setup = try dshSessionTestConfig(&tmp);
    defer testing.allocator.free(setup.base);
    defer testing.allocator.free(setup.config_path);

    const boot_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/?token={s}", .{
        dsh_mock.port(),
        mock_mod.test_token,
    });
    defer testing.allocator.free(boot_url);
    dsh_test_boot_url = boot_url;
    defer dsh_test_boot_url = null;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &setup.cfg);
    defer sm.deinit();

    // No terminal frame: the turn stays in flight until /stop lands.
    const frames = [_][]const u8{
        try mock_mod.textDeltaFrame(testing.allocator, 0, "part one "),
        try mock_mod.textDeltaFrame(testing.allocator, 1, "part two"),
    };
    defer for (frames) |frame| testing.allocator.free(frame);
    try dsh_mock.setTurnFrames(&frames);

    const session_key = "cli:main:dsh-stop";
    var turn = HostDshTurn{ .mgr = &sm, .session_key = session_key, .content = "hello" };
    const thread = try std.Thread.spawn(
        .{ .stack_size = thread_stacks.SESSION_TURN_STACK_SIZE },
        HostDshTurn.main,
        .{&turn},
    );
    waitForDshDelta(&turn);
    try testing.expect(turn.chunks.load(.acquire) > 0);

    try testing.expectEqual(SessionManager.InboundRouteAction.skip, sm.routeInbound(session_key, "/stop"));
    thread.join();

    try testing.expect(turn.failure == null);
    const reply = turn.reply.?;
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("part one part two", reply);
    try testing.expectEqual(@as(u32, 1), dsh_mock.cancelCount());
    try testing.expect((try sm.getOrCreate(session_key)).agent.last_turn_interrupted);
}

test "host /new starts a fresh dsh session and rewrites the mapping" {
    if (comptime !dsh_enabled) return error.SkipZigTest;
    const mock_mod = @import("harness/dsh/mock.zig");
    const sidecar_mod = @import("harness/dsh/sidecar.zig");
    var dsh_mock = try mock_mod.MockDsh.init(testing.allocator);
    defer dsh_mock.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var setup = try dshSessionTestConfig(&tmp);
    defer testing.allocator.free(setup.base);
    defer testing.allocator.free(setup.config_path);

    const boot_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/?token={s}", .{
        dsh_mock.port(),
        mock_mod.test_token,
    });
    defer testing.allocator.free(boot_url);
    dsh_test_boot_url = boot_url;
    defer dsh_test_boot_url = null;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &setup.cfg);
    defer sm.deinit();

    const session_key = "cli:main:dsh-new";
    try dsh_mock.setTurnFrames(&.{ "first", mock_mod.turn_completed_frame });
    const first = try sm.processMessageStreaming(session_key, "one", null, null, null);
    defer testing.allocator.free(first);
    try testing.expectEqual(@as(u32, 1), dsh_mock.createCount());

    const ack = try sm.processMessageStreaming(session_key, "/new", null, null, null);
    defer testing.allocator.free(ack);
    try testing.expectEqualStrings("Session cleared.", ack);
    // A new dsh session was created, and the command never reached dsh as a prompt.
    try testing.expectEqual(@as(u32, 2), dsh_mock.createCount());
    try testing.expectEqual(@as(u32, 1), dsh_mock.promptCount());

    const session_file = try std.fmt.allocPrint(testing.allocator, "{s}/dsh-sessions/{x}.json", .{
        setup.base,
        std.hash.Wyhash.hash(0, session_key),
    });
    defer testing.allocator.free(session_file);
    const persisted = (try sidecar_mod.loadSessionId(testing.allocator, session_file)).?;
    defer testing.allocator.free(persisted);
    try testing.expectEqualStrings("mock-sess-2", persisted);
}

test "dsh boot does not block session creation under the manager lock" {
    // Regression: the sidecar spawned synchronously inside getOrCreate's
    // SessionManager.mutex hold, so a slow boot stalled every session.
    if (comptime !dsh_enabled) return error.SkipZigTest;
    const mock_mod = @import("harness/dsh/mock.zig");
    var dsh_mock = try mock_mod.MockDsh.init(testing.allocator);
    defer dsh_mock.deinit();

    var gate = mock_mod.ConnectGate{};
    dsh_mock.setConnectGate(&gate);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var setup = try dshSessionTestConfig(&tmp);
    defer testing.allocator.free(setup.base);
    defer testing.allocator.free(setup.config_path);

    const boot_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/?token={s}", .{
        dsh_mock.port(),
        mock_mod.test_token,
    });
    defer testing.allocator.free(boot_url);
    dsh_test_boot_url = boot_url;
    defer dsh_test_boot_url = null;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &setup.cfg);
    defer sm.deinit();

    const slow_delta = try mock_mod.textDeltaFrame(testing.allocator, 0, "slow boot");
    defer testing.allocator.free(slow_delta);
    try dsh_mock.setTurnFrames(&.{ slow_delta, mock_mod.turn_completed_frame });

    const dsh_key = "cli:main:dsh-slow-boot";
    var turn = HostDshTurn{ .mgr = &sm, .session_key = dsh_key, .content = "hello" };
    const thread = try std.Thread.spawn(
        .{ .stack_size = thread_stacks.SESSION_TURN_STACK_SIZE },
        HostDshTurn.main,
        .{&turn},
    );

    // The turn is parked inside the sidecar boot. Creating another session
    // must still complete: boot is not under the session-table lock.
    gate.waitEntered();
    setup.cfg.agent.harness = .native;
    const native_session = try sm.getOrCreate("cli:main:native-during-boot");
    try testing.expect(native_session.dsh == null);
    try testing.expectEqual(
        @as(*anyopaque, @ptrCast(&native_session.harness)),
        native_session.turnHarness().ptr,
    );
    setup.cfg.agent.harness = .dsh_sidecar;

    gate.open();
    thread.join();
    try testing.expect(turn.failure == null);
    const reply = turn.reply.?;
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("slow boot", reply);
}

test "dsh turn failures map to user-facing text" {
    const cases = [_]struct { err: anyerror, needle: []const u8 }{
        .{ .err = error.SidecarBootFailed, .needle = "dsh 引擎启动失败" },
        .{ .err = error.ConnectionLost, .needle = "连接已断开" },
        .{ .err = error.TurnTimeout, .needle = "响应超时" },
        .{ .err = error.WsHandshakeFailed, .needle = "WebSocket 握手失败" },
        .{ .err = error.DshProviderUnsupported, .needle = "该 provider 不支持 dsh harness，请用 agent.harness=native 或换 provider" },
        .{ .err = error.DshProviderUrlInvalid, .needle = "base_url 无效" },
    };
    for (cases) |case| {
        const message = SessionManager.dshTurnErrorMessage(testing.allocator, case.err).?;
        defer testing.allocator.free(message);
        try testing.expect(std.mem.indexOf(u8, message, case.needle) != null);
    }
    try testing.expect(SessionManager.dshTurnErrorMessage(testing.allocator, error.OutOfMemory) == null);
}

test "dsh failed turn reply copies a 64KB upstream message without leaking" {
    const upstream = try testing.allocator.alloc(u8, 64 * 1024 + 7);
    defer testing.allocator.free(upstream);
    @memset(upstream, 'e');

    const reply = try SessionManager.dshFailedTurnReply(testing.allocator, upstream, "");
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.endsWith(u8, reply, upstream));

    const combined = try SessionManager.dshFailedTurnReply(testing.allocator, upstream, "partial answer");
    defer testing.allocator.free(combined);
    try testing.expect(std.mem.startsWith(u8, combined, "partial answer\n\n"));
}

test "dsh upstream turn error reaches the user instead of an empty reply" {
    // Regression: the port's `error` text was freed without being shown, so an
    // upstream 500/429 ended the turn with an empty reply.
    if (comptime !dsh_enabled) return error.SkipZigTest;
    const mock_mod = @import("harness/dsh/mock.zig");
    var dsh_mock = try mock_mod.MockDsh.init(testing.allocator);
    defer dsh_mock.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var setup = try dshSessionTestConfig(&tmp);
    defer testing.allocator.free(setup.base);
    defer testing.allocator.free(setup.config_path);

    const boot_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/?token={s}", .{
        dsh_mock.port(),
        mock_mod.test_token,
    });
    defer testing.allocator.free(boot_url);
    dsh_test_boot_url = boot_url;
    defer dsh_test_boot_url = null;

    const error_frame = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"type\":\"item\",\"streamId\":\"follow\",\"value\":{{\"type\":\"event\"," ++
            "\"event\":{{\"type\":\"turn/end\",\"data\":{{\"reason\":{{\"kind\":\"error\"," ++
            "\"error\":{{\"message\":{f}}}}}}}}}}}}}",
        .{std.json.fmt("upstream provider returned 429", .{})},
    );
    defer testing.allocator.free(error_frame);
    try dsh_mock.setTurnFrames(&.{error_frame});

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &setup.cfg);
    defer sm.deinit();

    const reply = try sm.processMessageStreaming("cli:main:dsh-upstream-error", "hello", null, null, null);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("上游模型服务返回错误：upstream provider returned 429", reply);
}

// ── dsh in-process integration (agent.harness = "dsh", alias "dsh-native") ──

const DshNativeScriptedReply = struct {
    text: []const u8 = "",
    tool_calls: []const providers.ToolCall = &.{},
    prompt_tokens: u32 = 10,
    completion_tokens: u32 = 5,
};

/// Scripted provider for the in-process engine. `Provider.chatWithTools`
/// falls back to `chat` for this vtable, which is the adapter's model call.
const DshNativeScriptedProvider = struct {
    replies: []const DshNativeScriptedReply,
    allocator: Allocator,
    chat_calls: usize = 0,
    /// User-role text of the latest request, for history assertions.
    users: std.ArrayListUnmanaged(u8) = .empty,
    /// Latest request call config, for `/model` and reasoning assertions.
    last_model: ?[]u8 = null,
    last_reasoning_effort: ?[]u8 = null,
    last_include_reasoning: ?bool = null,
    /// Runs inside the blocking call, where a real /stop lands.
    on_chat: ?*const fn (ctx: *anyopaque) void = null,
    on_chat_ctx: ?*anyopaque = null,

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystem,
        .chat = chat,
        .supportsNativeTools = supportsNativeTools,
        .getName = getName,
        .deinit = deinitFn,
    };

    fn init(allocator: Allocator, replies: []const DshNativeScriptedReply) DshNativeScriptedProvider {
        return .{ .replies = replies, .allocator = allocator };
    }

    fn deinit(self: *DshNativeScriptedProvider) void {
        self.users.deinit(self.allocator);
        if (self.last_model) |value| self.allocator.free(value);
        if (self.last_reasoning_effort) |value| self.allocator.free(value);
    }

    fn provider(self: *DshNativeScriptedProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn chatWithSystem(
        _: *anyopaque,
        allocator: Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        return allocator.dupe(u8, "");
    }

    fn chat(
        ptr: *anyopaque,
        allocator: Allocator,
        request: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *DshNativeScriptedProvider = @ptrCast(@alignCast(ptr));
        self.chat_calls += 1;
        self.users.clearRetainingCapacity();
        for (request.messages) |message| {
            if (message.role != .user) continue;
            if (self.users.items.len > 0) try self.users.appendSlice(self.allocator, "\n---\n");
            try self.users.appendSlice(self.allocator, message.content);
        }
        if (self.last_model) |value| self.allocator.free(value);
        self.last_model = try self.allocator.dupe(u8, request.model);
        if (self.last_reasoning_effort) |value| self.allocator.free(value);
        self.last_reasoning_effort = if (request.reasoning_effort) |effort|
            try self.allocator.dupe(u8, effort)
        else
            null;
        self.last_include_reasoning = request.include_reasoning;
        if (self.on_chat) |hook| {
            if (self.on_chat_ctx) |ctx| hook(ctx);
        }
        const script = self.replies[@min(self.chat_calls - 1, self.replies.len - 1)];
        const calls = try allocator.alloc(providers.ToolCall, script.tool_calls.len);
        for (script.tool_calls, 0..) |call, index| {
            calls[index] = .{
                .id = try allocator.dupe(u8, call.id),
                .name = try allocator.dupe(u8, call.name),
                .arguments = try allocator.dupe(u8, call.arguments),
            };
        }
        return .{
            .content = try allocator.dupe(u8, script.text),
            .tool_calls = calls,
            .usage = .{
                .prompt_tokens = script.prompt_tokens,
                .completion_tokens = script.completion_tokens,
                .total_tokens = script.prompt_tokens + script.completion_tokens,
            },
        };
    }

    fn supportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "mock";
    }

    fn deinitFn(_: *anyopaque) void {}
};

/// Temp workspace + config that selects the in-process engine. The mapping and
/// session logs land under the temp root, so tests never touch user state.
const DshNativeFixture = struct {
    tmp: std.testing.TmpDir,
    base: []u8,
    config_path: []u8,
    cfg: Config,

    fn init() !DshNativeFixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const base = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
        errdefer testing.allocator.free(base);
        const config_path = try std.fs.path.join(testing.allocator, &.{ base, "config.json" });
        errdefer testing.allocator.free(config_path);
        var cfg = testConfig();
        cfg.workspace_dir = base;
        cfg.config_path = config_path;
        cfg.agent.harness = .dsh;
        return .{ .tmp = tmp, .base = base, .config_path = config_path, .cfg = cfg };
    }

    fn deinit(self: *DshNativeFixture) void {
        testing.allocator.free(self.config_path);
        testing.allocator.free(self.base);
        self.tmp.cleanup();
    }

    fn manager(self: *DshNativeFixture, provider: *DshNativeScriptedProvider) SessionManager {
        return self.managerWithStore(provider, null);
    }

    fn managerWithStore(
        self: *DshNativeFixture,
        provider: *DshNativeScriptedProvider,
        session_store: ?memory_mod.SessionStore,
    ) SessionManager {
        var noop = observability.NoopObserver{};
        return SessionManager.init(
            testing.allocator,
            &self.cfg,
            provider.provider(),
            &.{},
            null,
            noop.observer(),
            session_store,
            null,
        );
    }

    fn managerWithMemory(
        self: *DshNativeFixture,
        provider: *DshNativeScriptedProvider,
        mem: ?Memory,
    ) SessionManager {
        var noop = observability.NoopObserver{};
        return SessionManager.init(
            testing.allocator,
            &self.cfg,
            provider.provider(),
            &.{},
            mem,
            noop.observer(),
            null,
            null,
        );
    }

    fn mappingPath(self: *DshNativeFixture, allocator: Allocator, session_key: []const u8) ![]u8 {
        const name = try std.fmt.allocPrint(allocator, "{x}.json", .{std.hash.Wyhash.hash(0, session_key)});
        defer allocator.free(name);
        return std.fs.path.join(allocator, &.{ self.base, "dsh-sessions", name });
    }
};

fn readDshNativeLog(path: []const u8) ![]u8 {
    return fs_compat.readFileAlloc(std_compat.fs.cwd(), testing.allocator, path, 1 << 20);
}

test "dsh-native: compaction and question config reach the engine options" {
    // Regression: DshNativeState.init built Options without agent.dsh_compaction_*
    // and agent.dsh_question_timeout, so the production path always ran on the
    // engine defaults.
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();
    fixture.cfg.agent.dsh_compaction_context_window = 32768;
    fixture.cfg.agent.dsh_compaction_threshold_ratio = 0.75;
    fixture.cfg.agent.dsh_compaction_retain_ratio = 0.25;
    fixture.cfg.agent.dsh_compaction_headroom_tokens = 1024;
    fixture.cfg.agent.dsh_question_timeout = 300;

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{});
    defer provider.deinit();
    var sm = fixture.manager(&provider);
    defer sm.deinit();

    const session = try sm.getOrCreate("cli:main:dsh-native-config");
    const opts = session.dsh_native.?.harness.opts;
    try testing.expectEqual(@as(u64, 32768), opts.context_window);
    try testing.expectEqual(@as(?f64, 0.75), opts.compaction_threshold_ratio);
    try testing.expectEqual(@as(?f64, 0.25), opts.compaction_retain_ratio);
    try testing.expectEqual(@as(?u64, 1024), opts.compaction_headroom_tokens);
    try testing.expectEqual(@as(i32, 300), opts.question_timeout_s);
}

test "dsh-native: /model, /think and /reasoning reach the engine request" {
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();
    fixture.cfg.default_model = "example/sub";
    fixture.cfg.reasoning_effort = "high";
    fixture.cfg.agent.reasoning_mode = .off;

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{
        .{ .text = "one" },
        .{ .text = "two" },
        .{ .text = "three" },
    });
    defer provider.deinit();
    var sm = fixture.manager(&provider);
    defer sm.deinit();

    const key = "cli:main:dsh-native-call-config";
    const first = try sm.processMessage(key, "hello", null);
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("example/sub", provider.last_model.?);
    try testing.expectEqualStrings("high", provider.last_reasoning_effort.?);
    try testing.expectEqual(false, provider.last_include_reasoning.?);

    const mode_reply = try sm.processMessage(key, "/reasoning stream", null);
    defer testing.allocator.free(mode_reply);
    try testing.expect(std.mem.indexOf(u8, mode_reply, "stream") != null);

    const think_reply = try sm.processMessage(key, "/think low", null);
    defer testing.allocator.free(think_reply);
    try testing.expect(std.mem.indexOf(u8, think_reply, "low") != null);

    const model_reply = try sm.processMessage(key, "/model openai/gpt-5", null);
    defer testing.allocator.free(model_reply);
    try testing.expect(std.mem.indexOf(u8, model_reply, "openai/gpt-5") != null);

    const second = try sm.processMessage(key, "again", null);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("openai/gpt-5", provider.last_model.?);
    try testing.expectEqualStrings("low", provider.last_reasoning_effort.?);
    try testing.expectEqual(true, provider.last_include_reasoning.?);

    const session = try sm.getOrCreate(key);
    const info = session.dsh_native.?.harness.harness().info();
    try testing.expectEqualStrings("openai/gpt-5", info.model_name);
    try testing.expectEqual(config_types.ReasoningMode.stream, info.reasoning_mode);
}

test "dsh-native: auto recall rides the engine's runtime context" {
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();
    fixture.cfg.memory.auto_recall = true;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();
    try mem.store("test-key", "remembered value", .core, null);

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{.{ .text = "ok" }});
    defer provider.deinit();
    var sm = fixture.managerWithMemory(&provider, mem);
    defer sm.deinit();

    const reply = try sm.processMessage("cli:main:dsh-native-recall", "remembered", null);
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.indexOf(u8, provider.users.items, "[Memory context]") != null);
    try testing.expect(std.mem.indexOf(u8, provider.users.items, "- test-key: remembered value") != null);
}

test "dsh-native: plain turn runs in process, reports usage and selects the engine" {
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();
    fixture.cfg.diagnostics.token_usage_ledger_enabled = true;

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{
        .{ .text = "hello from dsh-native" },
    });
    defer provider.deinit();
    var sm = fixture.manager(&provider);
    defer sm.deinit();

    const key = "cli:main:dsh-native-text";
    const resp = try sm.processMessage(key, "hi", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("hello from dsh-native", resp);
    try testing.expectEqual(@as(usize, 1), provider.chat_calls);
    try testing.expect(std.mem.indexOf(u8, provider.users.items, "hi") != null);

    const session = try sm.getOrCreate(key);
    try testing.expect(session.dsh_native != null);
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&session.dsh_native.?.harness)), session.turnHarness().ptr);
    try testing.expectEqual(@as(u64, 1), session.turn_count);
    try testing.expectEqual(@as(u32, 15), session.agent.last_turn_usage.total_tokens);

    // The ledger is the native one: one row per model call.
    const ledger_path = try std.fs.path.join(testing.allocator, &.{ fixture.base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);
    const ledger = try fs_compat.readFileAlloc(std_compat.fs.cwd(), testing.allocator, ledger_path, 64 * 1024);
    defer testing.allocator.free(ledger);
    try testing.expect(std.mem.indexOf(u8, ledger, "\"total_tokens\":15") != null);
    try testing.expect(std.mem.indexOf(u8, ledger, "\"provider\":\"mock\"") != null);
}

test "dsh-native: a 64KB reply is returned without leaking" {
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();

    const big = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{
        .{ .text = big },
    });
    defer provider.deinit();
    var sm = fixture.manager(&provider);
    defer sm.deinit();

    const resp = try sm.processMessage("cli:main:dsh-native-big", "hi", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings(big, resp);
}

test "dsh-native: tool turn executes the call and answers from its result" {
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();

    const note_path = try std.fs.path.join(testing.allocator, &.{ fixture.base, "note.txt" });
    defer testing.allocator.free(note_path);
    {
        const file = try fs_compat.createPath(note_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("tool says hi");
    }

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{
        .{
            .tool_calls = &.{.{
                .id = "call-1",
                .name = "read",
                .arguments = "{\"file_path\":\"note.txt\"}",
            }},
        },
        .{ .text = "tool done" },
    });
    defer provider.deinit();
    var sm = fixture.manager(&provider);
    defer sm.deinit();

    const key = "cli:main:dsh-native-tool";
    const resp = try sm.processMessage(key, "read the note", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("tool done", resp);
    try testing.expectEqual(@as(usize, 2), provider.chat_calls);
    // The second request carries the tool result back to the model.
    try testing.expect(std.mem.indexOf(u8, provider.users.items, "tool says hi") != null);

    const session = try sm.getOrCreate(key);
    try testing.expectEqual(@as(u64, 1), session.turn_count);
    try testing.expectEqual(@as(u32, 15), session.agent.last_turn_usage.total_tokens);
    try testing.expectEqual(@as(u64, 30), session.agent.total_tokens);
}

test "dsh-native: host /stop aborts the in-process turn" {
    const Probe = struct {
        manager: *SessionManager = undefined,
        key: []const u8,
        fn onChat(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.manager.requestTurnInterrupt(self.key);
        }
    };

    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{
        .{ .text = "never delivered" },
        .{ .text = "next turn ok" },
    });
    defer provider.deinit();
    var sm = fixture.manager(&provider);
    defer sm.deinit();

    const key = "cli:main:dsh-native-stop";
    var probe = Probe{ .manager = &sm, .key = key };
    provider.on_chat = Probe.onChat;
    provider.on_chat_ctx = @ptrCast(&probe);

    const resp = try sm.processMessage(key, "long task", null);
    defer testing.allocator.free(resp);
    // Regression: a blocking provider that completed after /stop was settled
    // as a normal reply with the late body. The adapter now drops it and
    // reports Interrupted; the host's /stop tail keys off the agent flag.
    try testing.expectEqualStrings("", resp);
    try testing.expectEqual(@as(usize, 1), provider.chat_calls);
    const session = try sm.getOrCreate(key);
    try testing.expect(session.agent.last_turn_interrupted);

    // The consumed interrupt does not poison the next turn.
    provider.on_chat = null;
    provider.on_chat_ctx = null;
    const next = try sm.processMessage(key, "again", null);
    defer testing.allocator.free(next);
    try testing.expectEqualStrings("next turn ok", next);
}

test "dsh-native: /new rotates the engine session and rewrites the mapping" {
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{
        .{ .text = "one" },
    });
    defer provider.deinit();
    var sm = fixture.manager(&provider);
    defer sm.deinit();

    const key = "cli:main:dsh-native-new";
    const first = try sm.processMessage(key, "hello", null);
    defer testing.allocator.free(first);

    const session = try sm.getOrCreate(key);
    const first_id = try testing.allocator.dupe(u8, session.dsh_native.?.harness.session_id);
    defer testing.allocator.free(first_id);
    const first_log = try testing.allocator.dupe(u8, session.dsh_native.?.harness.log.?.path);
    defer testing.allocator.free(first_log);

    const ack = try sm.processMessage(key, "/new", null);
    defer testing.allocator.free(ack);
    try testing.expect(std.mem.indexOf(u8, ack, "Session cleared") != null);
    // A local command never reaches the model.
    try testing.expectEqual(@as(usize, 1), provider.chat_calls);

    const new_id = session.dsh_native.?.harness.session_id;
    try testing.expect(!std.mem.eql(u8, first_id, new_id));
    const new_log = session.dsh_native.?.harness.log.?.path;
    try testing.expect(!std.mem.eql(u8, first_log, new_log));

    // The mapping is rewritten atomically to the new id (sidecar format).
    const mapping_path = try fixture.mappingPath(testing.allocator, key);
    defer testing.allocator.free(mapping_path);
    const mapping = try fs_compat.readFileAlloc(std_compat.fs.cwd(), testing.allocator, mapping_path, 4096);
    defer testing.allocator.free(mapping);
    const expected = try std.fmt.allocPrint(testing.allocator, "{{\"sessionId\":\"{s}\"}}", .{new_id});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, mapping);
}

test "dsh-native: canonical key migration keeps the engine mapping on the new key" {
    // Regression: the engine borrowed `session.session_key`; migration freed
    // that slice, so `/new` hashed freed memory and wrote the mapping under
    // the legacy key.
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{.{ .text = "ok" }});
    defer provider.deinit();
    var sm = fixture.manager(&provider);
    defer sm.deinit();

    const legacy = "agent:main:telegram:group:-100123#topic:77";
    const canonical = "agent:main:telegram:group:-100123:thread:77";
    const session = try sm.getOrCreate(legacy);
    try testing.expect(session.dsh_native != null);

    // Session creation wrote the legacy mapping; drop it so a stale file
    // cannot mask a write to the wrong (freed-key) path.
    const legacy_mapping = try fixture.mappingPath(testing.allocator, legacy);
    defer testing.allocator.free(legacy_mapping);
    std_compat.fs.deleteFileAbsolute(legacy_mapping) catch {};
    const first_id = try testing.allocator.dupe(u8, session.dsh_native.?.harness.session_id);
    defer testing.allocator.free(first_id);

    sm.migrateLegacySessionKey(canonical, legacy);
    try testing.expectEqualStrings(canonical, session.session_key);

    // A restart under the canonical key must find the same JSONL.
    const canonical_mapping = try fixture.mappingPath(testing.allocator, canonical);
    defer testing.allocator.free(canonical_mapping);
    const migrated = try fs_compat.readFileAlloc(std_compat.fs.cwd(), testing.allocator, canonical_mapping, 4096);
    defer testing.allocator.free(migrated);
    const expected_migrated = try std.fmt.allocPrint(testing.allocator, "{{\"sessionId\":\"{s}\"}}", .{first_id});
    defer testing.allocator.free(expected_migrated);
    try testing.expectEqualStrings(expected_migrated, migrated);

    // `/new` after the migration also writes under the canonical key.
    session.dsh_native.?.harness.harness().reset();
    try testing.expect(session.dsh_native.?.harness.reset_error == null);
    const raw = try fs_compat.readFileAlloc(std_compat.fs.cwd(), testing.allocator, canonical_mapping, 4096);
    defer testing.allocator.free(raw);
    const expected = try std.fmt.allocPrint(testing.allocator, "{{\"sessionId\":\"{s}\"}}", .{
        session.dsh_native.?.harness.session_id,
    });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, raw);
}

test "dsh-native: a message the engine never claimed runs as a new turn" {
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{
        .{ .text = "first answer" },
        .{ .text = "late answer" },
    });
    defer provider.deinit();
    var sm = fixture.manager(&provider);
    defer sm.deinit();

    const key = "cli:main:dsh-native-late";
    const first = try sm.processMessage(key, "initial", null);
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("first answer", first);

    const session = try sm.getOrCreate(key);
    try session.injectMidTurn(testing.allocator, "late message");

    var response: []const u8 = try testing.allocator.dupe(u8, "first answer");
    defer testing.allocator.free(response);
    var completed: u64 = 0;
    try testing.expect(try sm.drainLateInjection(session, key, &response, &completed, null, false, null));
    try testing.expectEqual(@as(u64, 1), completed);
    try testing.expectEqual(@as(usize, 2), provider.chat_calls);
    try testing.expect(std.mem.indexOf(u8, response, "late answer") != null);
    try testing.expect(std.mem.indexOf(u8, provider.users.items, "late message") != null);
    try testing.expect(!session.hasInjection());

    // Two engine turns, not one: the late message is its own dsh turn.
    const log_path = session.dsh_native.?.harness.log.?.path;
    const log_bytes = try readDshNativeLog(log_path);
    defer testing.allocator.free(log_bytes);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, log_bytes, "\"turn/start\""));
}

test "dsh-native: the follow-up separator streams for the combined reply" {
    const Probe = struct {
        separator_seen: bool = false,
        fn emit(ctx: *anyopaque, event: harness_port.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .delta => |chunk| {
                    if (std.mem.eql(u8, chunk.delta, "\n\n")) self.separator_seen = true;
                },
                else => {},
            }
        }
        fn sink(self: *@This()) harness_port.Sink {
            return .{ .ctx = @ptrCast(self), .emit = emit };
        }
    };

    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{
        .{ .text = "first answer" },
        .{ .text = "late answer" },
    });
    defer provider.deinit();
    var sm = fixture.manager(&provider);
    defer sm.deinit();

    const key = "cli:main:dsh-native-separator";
    const first = try sm.processMessage(key, "initial", null);
    defer testing.allocator.free(first);

    const session = try sm.getOrCreate(key);
    try session.injectMidTurn(testing.allocator, "late message");
    var response: []const u8 = try testing.allocator.dupe(u8, "first answer");
    defer testing.allocator.free(response);
    var completed: u64 = 0;
    var probe = Probe{};
    try testing.expect(try sm.drainLateInjection(session, key, &response, &completed, null, true, probe.sink()));
    // Regression: the combined reply joins the turns with "\n\n"; the preview
    // must stream the same separator, or it is not a prefix of the reply.
    try testing.expect(probe.separator_seen);
    try testing.expectEqualStrings("first answer\n\nlate answer", response);
}

test "dsh-native: usage accumulates across turns and writes one ledger row each" {
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();
    fixture.cfg.diagnostics.token_usage_ledger_enabled = true;

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{
        .{ .text = "one" },
        .{ .text = "two" },
    });
    defer provider.deinit();
    var sm = fixture.manager(&provider);
    defer sm.deinit();

    const key = "cli:main:dsh-native-usage";
    const one = try sm.processMessage(key, "first", null);
    defer testing.allocator.free(one);
    const two = try sm.processMessage(key, "second", null);
    defer testing.allocator.free(two);

    const session = try sm.getOrCreate(key);
    try testing.expectEqual(@as(u64, 30), session.agent.total_tokens);
    try testing.expectEqual(@as(u32, 15), session.agent.last_turn_usage.total_tokens);

    const ledger_path = try std.fs.path.join(testing.allocator, &.{ fixture.base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);
    const ledger = try fs_compat.readFileAlloc(std_compat.fs.cwd(), testing.allocator, ledger_path, 64 * 1024);
    defer testing.allocator.free(ledger);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, ledger, "\"total_tokens\":15"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, ledger, "\"ts\":"));
}

test "dsh-native: restart resumes the same JSONL for the session key" {
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{
        .{ .text = "first answer" },
        .{ .text = "second answer" },
    });
    defer provider.deinit();

    const key = "cli:main:dsh-native-resume";
    var first_id: []u8 = undefined;
    var first_log: []u8 = undefined;
    {
        var sm = fixture.manager(&provider);
        defer sm.deinit();
        const resp = try sm.processMessage(key, "hello", null);
        defer testing.allocator.free(resp);
        try testing.expectEqualStrings("first answer", resp);
        const session = try sm.getOrCreate(key);
        first_id = try testing.allocator.dupe(u8, session.dsh_native.?.harness.session_id);
        first_log = try testing.allocator.dupe(u8, session.dsh_native.?.harness.log.?.path);
    }
    defer testing.allocator.free(first_id);
    defer testing.allocator.free(first_log);

    {
        var sm = fixture.manager(&provider);
        defer sm.deinit();
        const session = try sm.getOrCreate(key);
        try testing.expect(session.dsh_native != null);
        try testing.expectEqualStrings(first_id, session.dsh_native.?.harness.session_id);
        try testing.expectEqualStrings(first_log, session.dsh_native.?.harness.log.?.path);

        const resp = try sm.processMessage(key, "again", null);
        defer testing.allocator.free(resp);
        try testing.expectEqualStrings("second answer", resp);
        // The rebuilt surface carries the previous turn into the request.
        try testing.expect(std.mem.indexOf(u8, provider.users.items, "hello") != null);
    }

    const log_bytes = try fs_compat.readFileAlloc(std_compat.fs.cwd(), testing.allocator, first_log, 1 << 20);
    defer testing.allocator.free(log_bytes);
    try testing.expect(std.mem.indexOf(u8, log_bytes, "first answer") != null);
    try testing.expect(std.mem.indexOf(u8, log_bytes, "second answer") != null);
}

test "dsh-native: a restarted session persists the fresh reply, not the previous one" {
    // Regression: restore replayed the store rows into agent.history, so the
    // first turn after a restart persisted the previous assistant reply as
    // this turn's answer (turn 1 "first answer", turn 2 "second answer", the
    // store recorded "first answer").
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();
    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{
        .{ .text = "first answer" },
        .{ .text = "second answer" },
    });
    defer provider.deinit();

    const key = "cli:main:dsh-native-restart-store";
    {
        var sm = fixture.managerWithStore(&provider, store);
        defer sm.deinit();
        const resp = try sm.processMessage(key, "hello", null);
        defer testing.allocator.free(resp);
        try testing.expectEqualStrings("first answer", resp);
        const session = try sm.getOrCreate(key);
        try testing.expectEqual(@as(usize, 0), session.agent.history.items.len);
    }
    var restored_history_len: usize = 0;
    {
        var sm = fixture.managerWithStore(&provider, store);
        defer sm.deinit();
        const session = try sm.getOrCreate(key);
        restored_history_len = session.agent.history.items.len;

        const resp = try sm.processMessage(key, "again", null);
        defer testing.allocator.free(resp);
        try testing.expectEqualStrings("second answer", resp);
    }

    const messages = try store.loadMessages(testing.allocator, key);
    defer memory_mod.freeMessages(testing.allocator, messages);
    try testing.expect(messages.len >= 2);
    const last = messages[messages.len - 1];
    try testing.expectEqualStrings("assistant", last.role);
    try testing.expectEqualStrings("second answer", last.content);

    // Stored rows stay out of the agent: the engine owns the resumed context.
    try testing.expectEqual(@as(usize, 0), restored_history_len);
}

test "dsh-native: session creation keeps agent.history empty under stored rows" {
    // Regression: getOrCreate appended every stored row to agent.history for
    // dsh-native, duplicating the context the engine already resumes.
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();
    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    const key = "cli:main:dsh-native-history-gate";
    try store.saveMessage(key, "user", "stale question");
    try store.saveMessage(key, "assistant", "stale answer");

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{
        .{ .text = "unused" },
    });
    defer provider.deinit();
    var sm = fixture.managerWithStore(&provider, store);
    defer sm.deinit();

    const session = try sm.getOrCreate(key);
    try testing.expectEqual(@as(usize, 0), session.agent.history.items.len);
    // Usage restoration is outside the gate and still runs.
    try testing.expect(session.agent.total_tokens > 0);
}

test "default native session still restores persisted history" {
    // Guard: the dsh-native gate must leave the native (default) path as is.
    var mock = MockProvider{ .response = "reply" };
    const cfg = testConfig();
    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    const key = "cli:main:native-restore";
    try store.saveMessage(key, "user", "earlier question");
    try store.saveMessage(key, "assistant", "earlier answer");

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        store,
        null,
    );
    defer sm.deinit();

    const session = try sm.getOrCreate(key);
    try testing.expectEqual(@as(usize, 2), session.agent.history.items.len);
    try testing.expectEqualStrings("earlier question", session.agent.history.items[0].content);
    try testing.expectEqualStrings("earlier answer", session.agent.history.items[1].content);
}

test "harness display trust uses the real session key for shared channels" {
    // Regression: the adapter read its own session_key, which no production
    // path assigned, so a shared-channel key with is_group=false looked
    // single-user and the live draft was suppressed.
    var mock = MockStreamingProvider{ .response = "sent to [EMAIL_1]" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    var collector = DeltaCollector{ .allocator = testing.allocator };
    defer collector.deinit();

    const session_key = "telegram:main:group:-1001";
    const resp = try sm.processMessageStreaming(
        session_key,
        "please email alice@example.com",
        .{
            .channel = "telegram",
            .is_group = false,
        },
        .{
            .callback = DeltaCollector.onEvent,
            .ctx = @ptrCast(&collector),
        },
        null,
    );
    defer testing.allocator.free(resp);

    // The manager must hand the real key to the adapter it drives.
    const live_session = try sm.getOrCreate(session_key);
    try testing.expectEqualStrings(session_key, live_session.harness.session_key);
    try testing.expectEqual(
        governance.DisplayTrustScope.shared_channel,
        governance.displayTrustScope(live_session.harness.session_key, "telegram", false),
    );
    try testing.expectEqual(
        governance.displayTrustScope(session_key, "telegram", false),
        governance.displayTrustScope(live_session.harness.session_key, "telegram", false),
    );

    // Shared channel: no rehydration, so the live draft is not suppressed.
    try testing.expectEqualStrings("sent to [EMAIL_1]", resp);
    try testing.expectEqualStrings("sent to [EMAIL_1]", collector.data.items);
}

test "live-draft suppression is fixed by the primary turn and covers follow-ups" {
    var mock = MockStreamingProvider{ .response = "plain answer" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    const session = try sm.getOrCreate("follow-up:suppression");
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    const redactor = session.agent.redactor.?;
    try testing.expect(!redactor.wouldRehydrate());

    // Pre-port rule: the decision comes from the primary content, once.
    const primary = "hello";
    const follow_up = "my email is alice@example.com";
    try testing.expect(!redactor.wouldRedact(primary));
    try testing.expect(redactor.wouldRedact(follow_up));
    const suppress_live = SessionManager.shouldSuppressLiveForRedaction(redactor, primary, true);
    try testing.expect(!suppress_live);

    var collector = PortDeltaCollector{ .allocator = testing.allocator };
    defer collector.deinit();
    var suppressing = SessionManager.SuppressingSink{
        .inner = collector.sink(),
        .suppress_live = suppress_live,
    };

    const first = try session.harness.harness().runTurn(.{
        .user_message = primary,
        .live_stream = true,
        .sink = suppressing.sink(),
    });
    defer testing.allocator.free(first.reply);
    const primary_bytes = collector.data.items.len;
    try testing.expect(primary_bytes > 0);

    // A follow-up whose own content would be redacted must not flip the
    // decision: it shares the wrapper built for the primary turn.
    const second = try session.harness.harness().runTurn(.{
        .user_message = follow_up,
        .live_stream = true,
        .sink = suppressing.sink(),
    });
    defer testing.allocator.free(second.reply);
    try testing.expect(collector.data.items.len > primary_bytes);
}

test "processMessageStreaming forwards tool progress hints" {
    var provider = SummaryFailureProvider{};
    var probe_tool = ProbeTool{};
    const tools = [_]Tool{probe_tool.tool()};
    const cfg = testConfig();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        provider.provider(),
        &tools,
        null,
        noop.observer(),
        null,
        null,
    );
    defer sm.deinit();

    const session_key = "progress:tool";
    const session = try sm.getOrCreate(session_key);
    session.agent.max_tool_iterations = 1;

    var collector = ProgressCollector{};
    const resp = try sm.processMessageStreaming(
        session_key,
        "run probe",
        null,
        null,
        .{
            .callback = ProgressCollector.onEvent,
            .ctx = @ptrCast(&collector),
        },
    );
    defer testing.allocator.free(resp);

    // Regression: A2A streaming depends on this sink to observe tool-call
    // starts. The sink now also receives the matching tool-call end hint, so a
    // single call yields two hints (start then end).
    try testing.expectEqual(@as(usize, 2), collector.count);
    try testing.expectEqual(@as(usize, 1), collector.starts);
    try testing.expectEqual(@as(usize, 1), collector.ends);
    try testing.expectEqualStrings("probe", collector.lastText());
}

test "processMessageStreaming forwards provider retry hints" {
    var mock = MockProvider{ .response = "ok", .fail_first = 1 };
    var reliable = providers.reliable.ReliableProvider.initWithProvider(mock.provider(), 1, 50);
    const cfg = testConfig();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        reliable.provider(),
        &.{},
        null,
        noop.observer(),
        null,
        null,
    );
    defer sm.deinit();

    var collector = ProgressCollector{};
    const resp = try sm.processMessageStreaming(
        "progress:retry",
        "hello",
        null,
        null,
        .{
            .callback = ProgressCollector.onEvent,
            .ctx = @ptrCast(&collector),
        },
    );
    defer testing.allocator.free(resp);

    try testing.expectEqualStrings("ok", resp);
    // Regression: provider retries used to be silent for the whole backoff.
    try testing.expectEqual(@as(usize, 1), collector.retries);
    try testing.expectEqual(@as(usize, 1), collector.retry_clears);
    try testing.expectEqualStrings("Retrying (1/1)\u{2026}", collector.lastText());
    // The indicator is live-draft only and never becomes reply text.
    try testing.expect(std.mem.indexOf(u8, resp, "Retrying") == null);
}

test "processMessageStreaming runs acked injections when the primary turn fails" {
    const InjectOnChat = struct {
        session: *Session,
        fired: bool = false,

        fn hook(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.fired) return;
            self.fired = true;
            // Arrives after the turn's last drain, while the provider request
            // is in flight, so it is still pending when the turn fails.
            _ = self.session.appendMidTurnIfRunning(testing.allocator, "steered while busy") catch return;
        }
    };

    var mock = MockProvider{ .response = "follow-up answer", .fail_first = 2 };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "failed:primary:drain";
    const session = try sm.getOrCreate(session_key);
    var inject = InjectOnChat{ .session = session };
    mock.on_chat = InjectOnChat.hook;
    mock.on_chat_ctx = @ptrCast(&inject);

    // Regression: on agent.turn error both post-turn drain loops were skipped,
    // so a message already acknowledged as steered stayed in injection_pending
    // and never ran.
    const resp = try sm.processMessageStreaming(session_key, "hello", null, null, null);
    defer testing.allocator.free(resp);
    try testing.expect(inject.fired);
    try testing.expectEqualStrings("follow-up answer", resp);
    try testing.expect(!session.hasInjection());
}

test "requestTurnInterruptAtStart stops a turn before it reaches the provider" {
    var mock = MockProvider{ .response = "should not be sent" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "stop:starting-turn";
    const session = try sm.getOrCreate(session_key);

    // Regression: a /stop that landed after the worker's epoch check but
    // before the turn set turn_running was ignored, and the message ran to
    // completion despite the stop reply.
    try testing.expect(sm.requestTurnInterruptAtStart(session_key));
    const reply = try session.agent.turn("hello");
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.indexOf(u8, reply, "Interrupted by /stop") != null);
    try testing.expectEqual(@as(usize, 0), mock.chat_calls);
}

test "a pre-turn stop also cancels a local slash command" {
    var mock = MockProvider{ .response = "unused" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "stop:slash-command";
    const session = try sm.getOrCreate(session_key);

    // Regression: processMessageStreaming consumed the pre-turn stop into
    // agent.interrupt_requested, but Agent.turn dispatched a local slash
    // command before its first interrupt check, so /model still switched the
    // model while the sender was told the stop was signaled.
    try testing.expect(sm.requestTurnInterruptAtStart(session_key));
    const reply = try sm.processMessageStreaming(session_key, "/model openai/gpt-5", null, null, null);
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.indexOf(u8, reply, "Interrupted by /stop") != null);
    try testing.expectEqualStrings("test/mock-model", session.agent.model_name);
}

test "requestTurnInterruptAtStart reaches a session that does not exist yet" {
    var mock = MockProvider{ .response = "should not be sent" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "stop:new-session";
    // Regression: a /stop sent right after the first message in a brand-new
    // chat found no session yet, so the fast path fell through and the turn
    // ran to completion despite the "no in-flight turn" reply.
    try testing.expect(sm.requestTurnInterruptAtStart(session_key));
    const reply = try sm.processMessageStreaming(session_key, "hello", null, null, null);
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.indexOf(u8, reply, "Interrupted by /stop") != null);
    try testing.expectEqual(@as(usize, 0), mock.chat_calls);
}

test "a cleared pre-turn stop does not interrupt the next turn" {
    var mock = MockProvider{ .response = "answered" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "stop:cleared";
    try testing.expect(sm.requestTurnInterruptAtStart(session_key));
    // Regression: a stop recorded while no turn could consume it stayed
    // pending and cancelled the next message in the chat.
    sm.clearPendingStartInterrupt(session_key);
    const reply = try sm.processMessageStreaming(session_key, "hello", null, null, null);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("answered", reply);
    try testing.expectEqual(@as(usize, 1), mock.chat_calls);
}

test "one /stop during a tool call ends the turn without running steered follow-ups" {
    // Regression: one /stop during a tool call does not end the turn.
    var mock = MockProvider{
        .response = "unused",
        .responses = &.{
            "<tool_call>{\"name\":\"stop_probe\",\"arguments\":{}}</tool_call>",
            "follow-up answer",
        },
    };
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    var probe = StopDuringToolProbe{};
    var tools = [_]Tool{probe.tool()};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &tools,
        null,
        noop.observer(),
        null,
        null,
    );
    defer sm.deinit();

    const session_key = "stop:tool-once";
    const session = try sm.getOrCreate(session_key);
    probe.session = session;

    const reply = try sm.processMessageStreamingWithSteerSink(session_key, "run the tool", null, null, null, null);
    defer testing.allocator.free(reply);

    try testing.expect(std.mem.indexOf(u8, reply, "Interrupted by /stop") != null);
    // The steered message must not become a full follow-up turn after the
    // interrupted primary; one /stop ends the whole turn.
    try testing.expectEqual(@as(usize, 1), mock.chat_calls);
    try testing.expectEqual(@as(usize, 1), probe.executions);
    try testing.expect(!session.hasInjection());
    try testing.expect(std.mem.indexOf(u8, reply, "Pending message(s) discarded by /stop") != null);
}

test "a normal message after an interrupted tool turn is not stopped" {
    // Regression: one /stop during a tool call does not end the turn.
    var mock = MockProvider{
        .response = "unused",
        .responses = &.{
            "<tool_call>{\"name\":\"stop_probe\",\"arguments\":{}}</tool_call>",
            "next answer",
        },
    };
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    var probe = StopDuringToolProbe{};
    var tools = [_]Tool{probe.tool()};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &tools,
        null,
        noop.observer(),
        null,
        null,
    );
    defer sm.deinit();

    const session_key = "stop:tool-once";
    const session = try sm.getOrCreate(session_key);
    probe.session = session;

    const interrupted = try sm.processMessageStreamingWithSteerSink(session_key, "run the tool", null, null, null, null);
    defer testing.allocator.free(interrupted);
    try testing.expect(std.mem.indexOf(u8, interrupted, "Interrupted by /stop") != null);

    // The next message is a normal turn: the stop must not leak into it.
    const reply = try sm.processMessageStreamingWithSteerSink(session_key, "next", null, null, null, null);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("next answer", reply);
    try testing.expectEqual(@as(usize, 2), mock.chat_calls);
}

test "clearTurnInterruptIfIdle drops a stale stop flag but keeps a running one" {
    var mock = MockProvider{ .response = "answered" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "stop:idle-cleanup";
    const session = try sm.getOrCreate(session_key);
    try testing.expect(sm.requestTurnInterruptAtStart(session_key));
    try testing.expect(session.agent.interrupt_requested.load(.acquire));
    // Regression: a /stop that landed after the turn ended armed the flag
    // with no turn left to consume it, cancelling the next message.
    sm.clearTurnInterruptIfIdle(session_key);
    try testing.expect(!session.agent.interrupt_requested.load(.acquire));

    // A running turn keeps the interrupt it was signaled with.
    session.turn_running.store(true, .release);
    try testing.expect(sm.requestTurnInterruptAtStart(session_key));
    sm.clearTurnInterruptIfIdle(session_key);
    try testing.expect(session.agent.interrupt_requested.load(.acquire));
    session.turn_running.store(false, .release);
    session.clearInterrupt();
}

test "drainLateInjection keeps the primary reply and asks the sender to resend" {
    var mock = MockProvider{ .response = "unused", .chat_error = error.ProviderError };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("failed:follow-up:reply");
    session.turn_running.store(true, .release);
    try testing.expect(try session.appendMidTurnIfRunning(testing.allocator, "steered while busy"));
    session.turn_running.store(false, .release);

    var response: []const u8 = try testing.allocator.dupe(u8, "primary answer");
    var completed_turns: u64 = 1;

    // Regression: a failed tail-window follow-up freed the completed primary
    // reply and propagated the error, so the user lost the main answer.
    try testing.expect(try sm.drainLateInjection(session, "failed:follow-up:reply", &response, &completed_turns, null, false, null));
    defer testing.allocator.free(response);
    try testing.expect(std.mem.startsWith(u8, response, "primary answer"));
    try testing.expect(std.mem.indexOf(u8, response, "Follow-up turn failed") != null);
    // Regression: the reply promised a retry that an idle eviction or restart
    // could never deliver; it now asks the sender to resend instead.
    try testing.expect(std.mem.indexOf(u8, response, "please resend it") != null);
    try testing.expectEqual(@as(u64, 1), completed_turns);
    // The failed follow-up is consumed exactly once and never re-queued.
    try testing.expect(!session.hasInjection());
}

test "failed-turn injection drain combines successes and reports the failure" {
    const alloc = testing.allocator;
    var mock = MockProvider{
        .response = "unused",
        .responses = &.{ "reply one", "reply two", "reply three" },
        // Calls 3 and 4 are the two attempts of the third follow-up turn.
        .fail_calls = &.{ 3, 4 },
    };
    const cfg = testConfig();
    var sm = testSessionManager(alloc, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("failed:inject:mixed");
    session.turn_running.store(true, .release);
    try testing.expect(try session.appendMidTurnIfRunning(alloc, "first"));
    session.turn_running.store(false, .release);
    // The failed-turn path has already closed the injection window; the drain
    // must still run what was accepted before that.
    session.closeInjectionWindow();

    const InjectNext = struct {
        session: *Session,
        fired: usize = 0,

        fn hook(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fired += 1;
            const next: []const u8 = switch (self.fired) {
                1 => "second",
                2 => "third",
                else => return,
            };
            // Simulates a message acknowledged while the previous follow-up's
            // provider call was in flight.
            self.session.injectMidTurn(testing.allocator, next) catch {};
        }
    };
    var inject = InjectNext{ .session = session };
    mock.on_chat = InjectNext.hook;
    mock.on_chat_ctx = @ptrCast(&inject);

    var completed_turns: u64 = 0;
    const reply = (try sm.drainInjectionsAfterFailedTurn(session, "failed:inject:mixed", &completed_turns, 0xabc, null, false, null)) orelse
        return error.TestExpectedEqual;
    defer alloc.free(reply);

    // Regression: mixed results delivered only the last success.
    try testing.expect(std.mem.startsWith(u8, reply, "reply one\n\nreply two"));
    // The failed third follow-up is reported with a resend request, not dropped
    // and not promised a retry that cannot happen.
    try testing.expect(std.mem.indexOf(u8, reply, "Follow-up turn failed") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "please resend it") != null);
    try testing.expectEqual(@as(u64, 2), completed_turns);
    try testing.expect(!session.hasInjection());
}

test "failed-turn injection drain returns the primary error when every follow-up fails" {
    const alloc = testing.allocator;
    var mock = MockProvider{ .response = "unused", .fail_rate_limited_calls = &.{1} };
    const cfg = testConfig();
    var sm = testSessionManager(alloc, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("failed:inject:all-failed");
    session.turn_running.store(true, .release);
    try testing.expect(try session.appendMidTurnIfRunning(alloc, "steered while busy"));
    session.turn_running.store(false, .release);
    session.closeInjectionWindow();

    var completed_turns: u64 = 0;
    // Regression: a notice-only reply replaced the original primary error when
    // every follow-up failed, so the sender never learned why the primary turn
    // failed.
    try testing.expect((try sm.drainInjectionsAfterFailedTurn(session, "failed:inject:all-failed", &completed_turns, 0xdef, null, false, null)) == null);
    try testing.expectEqual(@as(u64, 0), completed_turns);
    // The failed follow-up is consumed exactly once and never re-queued.
    try testing.expect(!session.hasInjection());
    // Its user message stays in history: nothing is popped or dropped.
    var steered_entries: usize = 0;
    for (session.agent.history.items) |msg| {
        if (msg.role == .user and std.mem.eql(u8, msg.content, "steered while busy")) steered_entries += 1;
    }
    try testing.expectEqual(@as(usize, 1), steered_entries);
}

test "late-drain follow-up failure still drains messages that arrived during it" {
    const alloc = testing.allocator;
    // Primary turn succeeds; the first follow-up fails without a retry while
    // the user's next message arrives.
    var mock = MockProvider{
        .response = "unused",
        .responses = &.{ "primary answer", "unused", "second answer" },
        .fail_rate_limited_calls = &.{2},
    };
    const cfg = testConfig();
    var sm = testSessionManager(alloc, &mock, &cfg);
    defer sm.deinit();

    const session_key = "failed:late-drain:concurrent";
    const session = try sm.getOrCreate(session_key);

    // "first" lands after the primary turn's final injection drain but before
    // it returns, so it is still pending when the late-drain loop starts.
    const CompleteInjector = struct {
        session: *Session,
        fired: bool = false,

        const vtable = observability.Observer.VTable{
            .record_event = recordEvent,
            .record_metric = recordMetric,
            .flush = flush,
            .name = name,
            .get_trace_id = getTraceId,
            .set_trace_id = setTraceId,
        };

        fn observer(self: *@This()) observability.Observer {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        fn recordEvent(ctx: *anyopaque, event: *const observability.ObserverEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (event.* != .turn_complete or self.fired) return;
            self.fired = true;
            _ = self.session.appendMidTurnIfRunning(testing.allocator, "first") catch return;
        }

        fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
        fn flush(_: *anyopaque) void {}
        fn name(_: *anyopaque) []const u8 {
            return "turn-complete-injector";
        }
        fn getTraceId(_: *anyopaque) ?[32]u8 {
            return null;
        }
        fn setTraceId(_: *anyopaque, _: [32]u8) void {}
    };
    var injector = CompleteInjector{ .session = session };
    session.agent.observer = injector.observer();

    const InjectSecond = struct {
        session: *Session,
        mock: *MockProvider,
        fired: bool = false,

        fn hook(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.fired or self.mock.chat_calls != 2) return;
            self.fired = true;
            // "second" arrives while the failing follow-up's provider call is
            // in flight. It was already acknowledged to the sender.
            _ = self.session.appendMidTurnIfRunning(testing.allocator, "second") catch return;
        }
    };
    var inject = InjectSecond{ .session = session, .mock = &mock };
    mock.on_chat = InjectSecond.hook;
    mock.on_chat_ctx = @ptrCast(&inject);

    const resp = try sm.processMessageStreaming(session_key, "hello", null, null, null);
    defer alloc.free(resp);

    // Regression: the failed follow-up stopped the drain loop, leaving the
    // acknowledged "second" message pending until some later LLM turn (a slash
    // command turn never drains it).
    try testing.expect(injector.fired);
    try testing.expect(inject.fired);
    try testing.expectEqual(@as(usize, 3), mock.chat_calls);
    try testing.expect(std.mem.indexOf(u8, resp, "primary answer") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Follow-up turn failed") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "please resend it") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "second answer") != null);
    try testing.expect(!session.hasInjection());
}

test "failed-turn follow-up reply is filtered and persisted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_dir = std_compat.fs.Dir.wrap(tmp.dir);
    const base = try tmp_dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var mock = MockProvider{ .response = "answer [DOCUMENT:/etc/passwd]", .fail_first = 2 };
    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const session_key = "failed:primary:filter";
    const session = try sm.getOrCreate(session_key);
    // Simulate a named agent that carries its own autonomy.
    session.agent.has_own_autonomy = true;

    const InjectOnChat = struct {
        session: *Session,
        fired: bool = false,

        fn hook(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.fired) return;
            self.fired = true;
            _ = self.session.appendMidTurnIfRunning(testing.allocator, "steered while busy") catch return;
        }
    };
    var inject = InjectOnChat{ .session = session };
    mock.on_chat = InjectOnChat.hook;
    mock.on_chat_ctx = @ptrCast(&inject);

    const resp = try sm.processMessageStreaming(session_key, "hello", null, null, null);
    defer testing.allocator.free(resp);
    try testing.expect(inject.fired);
    // Regression: the failed-turn follow-up reply returned before the outbound
    // attachment filter, so an escaping marker reached the channel.
    try testing.expect(std.mem.indexOf(u8, resp, "/etc/passwd") == null);
    try testing.expect(std.mem.indexOf(u8, resp, "answer") != null);

    // Regression: the early return also skipped persistence and counters.
    try testing.expectEqual(@as(u64, 1), session.turn_count);
    const store = sqlite_mem.sessionStore();
    const messages = try store.loadMessages(testing.allocator, session_key);
    defer memory_mod.freeMessages(testing.allocator, messages);
    var saw_assistant = false;
    for (messages) |entry| {
        if (std.mem.eql(u8, entry.role, "assistant")) saw_assistant = true;
    }
    try testing.expect(saw_assistant);
}

test "failed primary turn persists each follow-up under its own prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_dir = std_compat.fs.Dir.wrap(tmp.dir);
    const base = try tmp_dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var mock = MockProvider{ .response = "Paris", .fail_first = 2 };
    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const session_key = "failed:primary:persist-followup";
    const session = try sm.getOrCreate(session_key);

    const InjectOnChat = struct {
        session: *Session,
        fired: bool = false,

        fn hook(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.fired) return;
            self.fired = true;
            _ = self.session.appendMidTurnIfRunning(testing.allocator, "what is the capital of France?") catch return;
        }
    };
    var inject = InjectOnChat{ .session = session };
    mock.on_chat = InjectOnChat.hook;
    mock.on_chat_ctx = @ptrCast(&inject);

    const resp = try sm.processMessageStreaming(session_key, "hello", null, null, null);
    defer testing.allocator.free(resp);
    try testing.expect(inject.fired);

    // Regression: the follow-up reply was persisted as the answer to "hello"
    // and the steered question was missing from the store, so a restart showed
    // "hello" -> "Paris".
    const store = sqlite_mem.sessionStore();
    const messages = try store.loadMessages(testing.allocator, session_key);
    defer memory_mod.freeMessages(testing.allocator, messages);
    try testing.expectEqual(@as(usize, 3), messages.len);
    try testing.expectEqualStrings("user", messages[0].role);
    try testing.expectEqualStrings("hello", messages[0].content);
    try testing.expectEqualStrings("user", messages[1].role);
    try testing.expectEqualStrings("what is the capital of France?", messages[1].content);
    try testing.expectEqualStrings("assistant", messages[2].role);
    try testing.expectEqualStrings("Paris", messages[2].content);
}

test "tool progress hints never enter the reply or history" {
    var provider = SummaryFailureProvider{};
    var probe_tool = ProbeTool{};
    const tools = [_]Tool{probe_tool.tool()};
    const cfg = testConfig();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        provider.provider(),
        &tools,
        null,
        noop.observer(),
        null,
        null,
    );
    defer sm.deinit();

    const session_key = "progress:no-leak";
    const session = try sm.getOrCreate(session_key);
    session.agent.max_tool_iterations = 1;

    var collector = ProgressCollector{};
    const resp = try sm.processMessageStreaming(
        session_key,
        "run probe",
        null,
        null,
        .{
            .callback = ProgressCollector.onEvent,
            .ctx = @ptrCast(&collector),
        },
    );
    defer testing.allocator.free(resp);

    // The sink observed the tool call...
    try testing.expect(collector.count > 0);
    // ...but the progress block markers never leak into the delivered reply...
    try testing.expect(std.mem.indexOf(u8, resp, "\u{1F527}") == null);
    try testing.expect(std.mem.indexOf(u8, resp, "\u{23F3}") == null);
    // ...nor into the recorded history.
    const history = try session.agent.getHistory(testing.allocator);
    defer testing.allocator.free(history);
    for (history) |message| {
        try testing.expect(std.mem.indexOf(u8, message.content, "\u{1F527}") == null);
        try testing.expect(std.mem.indexOf(u8, message.content, "\u{23F3}") == null);
    }
}

test "routeInput observes pending mid-turn injection" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "route:injection";
    const session = try sm.getOrCreate(session_key);
    session.agent.queue_mode = .latest;
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    try sm.injectMidTurn(session_key, "first");
    try sm.injectMidTurn(session_key, "second");

    const input = sm.routeInput(session_key);
    try testing.expect(input.turn_running);
    try testing.expectEqual(agent_mod.Agent.QueueMode.latest, input.queue_mode);
    try testing.expect(input.has_pending_injection);
    try testing.expectEqual(inbound_router.RoutingDecision.replace_injection, inbound_router.route(input));

    const drained = (try session.drainInjection(testing.allocator, testing.allocator)) orelse return error.TestExpectedEqual;
    defer testing.allocator.free(drained);
    try testing.expectEqualStrings("second", drained);
    try testing.expect(!session.hasInjection());
}

test "drainInjection preserves pending message when target allocation fails" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("inject:oom");
    try session.injectMidTurn(testing.allocator, "keep me");

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    failing.fail_index = failing.alloc_index;

    // Regression: a transient allocation failure in the agent allocator must not
    // drop the pending injection before a later tool-loop boundary can retry it.
    try testing.expectError(error.OutOfMemory, session.drainInjection(testing.allocator, failing.allocator()));
    try testing.expect(session.hasInjection());

    const drained = (try session.drainInjection(testing.allocator, testing.allocator)) orelse return error.TestExpectedEqual;
    defer testing.allocator.free(drained);
    try testing.expectEqualStrings("keep me", drained);
    try testing.expect(!session.hasInjection());
}

test "injectMidTurnIfRunning refuses stopped sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("inject:stopped");

    // Regression: if routeInbound observed a running turn but the turn stopped
    // before deposit, the message must fall back to normal processing.
    try testing.expect(!try session.injectMidTurnIfRunning(testing.allocator, "stale"));
    try testing.expect(!session.hasInjection());

    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);
    try testing.expect(try session.injectMidTurnIfRunning(testing.allocator, "active"));
    const drained = (try session.drainInjection(testing.allocator, testing.allocator)) orelse return error.TestExpectedEqual;
    defer testing.allocator.free(drained);
    try testing.expectEqualStrings("active", drained);
}

test "processMessageStreaming drains pending mid-turn injection into provider messages" {
    var provider = CaptureMessagesProvider{};
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        provider.provider(),
        &.{},
        null,
        noop.observer(),
        null,
        null,
    );
    defer sm.deinit();

    const session_key = "inject:provider";
    _ = try sm.getOrCreate(session_key);
    try sm.injectMidTurn(session_key, "mid turn");

    const resp = try sm.processMessage(session_key, "initial", null);
    defer testing.allocator.free(resp);

    // Regression: pending injections must be folded into the active provider
    // request as user history, not left stranded in the session buffer.
    try testing.expectEqual(@as(usize, 1), provider.chat_calls);
    try testing.expectEqual(@as(usize, 2), provider.user_count);
    try testing.expectEqualStrings("initial", provider.userMessage(0));
    try testing.expectEqualStrings("mid turn", provider.userMessage(1));
    const session = try sm.getOrCreate(session_key);
    try testing.expect(!session.hasInjection());
}

test "processMessageStreaming drains late injection before completing turn" {
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    const session_key = "inject:late";
    var provider = LateInjectionProvider{
        .session_mgr = undefined,
        .session_key = session_key,
    };
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        provider.provider(),
        &.{},
        null,
        noop.observer(),
        null,
        null,
    );
    defer sm.deinit();
    provider.session_mgr = &sm;

    const session = try sm.getOrCreate(session_key);
    session.agent.queue_mode = .latest;

    const resp = try sm.processMessage(session_key, "initial", null);
    defer testing.allocator.free(resp);

    // Regression: injection arriving after the first provider request but before
    // turn teardown must not stay pending for a future unrelated message.
    try testing.expectEqualStrings("final response", resp);
    try testing.expectEqual(SessionManager.InboundRouteAction.steered, provider.route_action.?);
    try testing.expectEqual(@as(usize, 2), provider.chat_calls);
    try testing.expectEqual(@as(usize, 2), provider.user_count);
    try testing.expectEqualStrings("initial", provider.userMessage(0));
    try testing.expectEqualStrings("late message", provider.userMessage(1));
    try testing.expect(!session.hasInjection());
    try testing.expectEqual(@as(u64, 1), session.turn_count);
}

test "processMessageStreaming delivers steered mid-turn messages to the provider" {
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    const session_key = "inject:steer-provider";
    var provider = LateInjectionProvider{
        .session_mgr = undefined,
        .session_key = session_key,
    };
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        provider.provider(),
        &.{},
        null,
        noop.observer(),
        null,
        null,
    );
    defer sm.deinit();
    provider.session_mgr = &sm;

    const session = try sm.getOrCreate(session_key);
    session.agent.queue_mode = .steer;

    const resp = try sm.processMessage(session_key, "initial", null);
    defer testing.allocator.free(resp);

    // Regression: with steer as the default, a message that arrives mid-turn
    // must reach the provider as user history instead of being dropped.
    try testing.expectEqual(SessionManager.InboundRouteAction.steered, provider.route_action.?);
    try testing.expectEqual(@as(usize, 2), provider.chat_calls);
    try testing.expectEqual(@as(usize, 2), provider.user_count);
    try testing.expectEqualStrings("initial", provider.userMessage(0));
    try testing.expectEqualStrings("late message", provider.userMessage(1));
    try testing.expect(!session.hasInjection());
}

test "processMessage refreshes system prompt when conversation context is cleared" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const sender_uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";
    const with_context: ?ConversationContext = .{
        .channel = "signal",
        .sender_number = "+15551234567",
        .sender_uuid = sender_uuid,
        .group_id = null,
        .is_group = false,
    };

    const resp1 = try sm.processMessage("ctx:user", "first", with_context);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("ctx:user");
    try testing.expect(session.agent.history.items.len > 0);
    const sys1 = session.agent.history.items[0].content;
    try testing.expect(std.mem.indexOf(u8, sys1, "## Conversation Context") != null);
    try testing.expect(std.mem.indexOf(u8, sys1, sender_uuid) != null);

    const resp2 = try sm.processMessage("ctx:user", "second", null);
    defer testing.allocator.free(resp2);

    try testing.expect(session.agent.history.items.len > 0);
    const sys2 = session.agent.history.items[0].content;
    try testing.expect(std.mem.indexOf(u8, sys2, "## Conversation Context") == null);
    try testing.expect(std.mem.indexOf(u8, sys2, sender_uuid) == null);
}

test "setTurnToolContext prefers delivery chat target over direct peer session id" {
    var schedule_tool = tools_mod.schedule.ScheduleTool{};
    const tools = [_]Tool{schedule_tool.tool()};

    const conversation_context: ?ConversationContext = .{
        .channel = "discord",
        .account_id = "discord-main",
        .delivery_chat_id = "dm-channel-42",
        .peer_id = "user-42",
        .is_group = false,
    };

    // Regression: Discord DM sessions are keyed by author ID, but scheduled
    // delivery must target the DM channel ID for outbound sends.
    SessionManager.setTurnToolContext(&tools, "agent:main:discord:direct:user-42", conversation_context);
    defer schedule_tool.setContext(null, null, null, null, null, null);

    const parsed = try tools_mod.parseTestArgs("{\"action\":\"once\",\"delay\":\"1m\",\"prompt\":\"ping\"}");
    defer parsed.deinit();

    const result = try schedule_tool.execute(testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) testing.allocator.free(result.output);
    try testing.expect(result.success);

    var scheduler = cron_add_mod.loadScheduler(testing.allocator) catch return error.TestUnexpectedResult;
    defer scheduler.deinit();
    defer {
        for (scheduler.listJobs()) |job| {
            _ = scheduler.removeJob(job.id);
        }
        cron_mod.saveJobs(&scheduler) catch {};
    }

    const jobs = scheduler.listJobs();
    try testing.expect(jobs.len > 0);
    const job = jobs[jobs.len - 1];
    try testing.expect(job.delivery.to != null);
    try testing.expectEqualStrings("dm-channel-42", job.delivery.to.?);
    try testing.expect(job.delivery.peer_id != null);
    try testing.expectEqualStrings("user-42", job.delivery.peer_id.?);
}

test "processMessage updates last_active" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("user:2");
    const before = session.last_active;

    // Small sleep so timestamp changes
    std_compat.thread.sleep(10 * std.time.ns_per_ms);

    const resp = try sm.processMessage("user:2", "hello", null);
    defer testing.allocator.free(resp);

    try testing.expect(session.last_active >= before);
}

test "processMessage increments turn_count" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp1 = try sm.processMessage("user:3", "msg1", null);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("user:3");
    try testing.expectEqual(@as(u64, 1), session.turn_count);

    const resp2 = try sm.processMessage("user:3", "msg2", null);
    defer testing.allocator.free(resp2);
    try testing.expectEqual(@as(u64, 2), session.turn_count);
}

test "processMessage preserves session across calls" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp1 = try sm.processMessage("persist:1", "first", null);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("persist:1");
    // After first processMessage: system prompt + user msg + assistant response
    try testing.expect(session.agent.historyLen() > 0);

    const history_before = session.agent.historyLen();

    const resp2 = try sm.processMessage("persist:1", "second", null);
    defer testing.allocator.free(resp2);

    // History should have grown (user msg + assistant response added)
    try testing.expect(session.agent.historyLen() > history_before);
}

test "restored session reconstructs token count from persisted assistant replies" {
    var mock = MockProvider{ .response = "assistant reply" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    const session_key = "telegram:main:chat-1";
    const reply = try sm.processMessage(session_key, "hello", .{
        .channel = "telegram",
        .is_group = false,
        .group_id = null,
    });
    defer testing.allocator.free(reply);

    const expected_tokens = agent_mod.estimate_text_tokens("assistant reply");
    const first_session = try sm.getOrCreate(session_key);
    try testing.expectEqual(@as(u64, expected_tokens), first_session.agent.total_tokens);

    first_session.last_active = 0;
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));

    const restored_session = try sm.getOrCreate(session_key);
    try testing.expectEqual(@as(u64, expected_tokens), restored_session.agent.total_tokens);

    const status = try restored_session.agent.handleSlashCommand("/status");
    defer {
        if (status) |resp| testing.allocator.free(resp);
    }
    try testing.expect(status != null);

    var expected_line_buf: [64]u8 = undefined;
    const expected_line = try std.fmt.bufPrint(&expected_line_buf, "Tokens used: {d}", .{expected_tokens});
    try testing.expect(std.mem.indexOf(u8, status.?, expected_line) != null);
}

test "processMessage session persistence redacts PII" {
    var mock = MockProvider{ .response = "assistant saw user@example.com" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    const session_key = "telegram:main:privacy";
    const reply = try sm.processMessage(session_key, "hello user@example.com", null);
    defer testing.allocator.free(reply);

    const store = sqlite_mem.sessionStore();
    const detailed = try store.loadMessagesDetailed(testing.allocator, session_key, 10, 0);
    defer memory_mod.freeDetailedMessages(testing.allocator, detailed);

    try testing.expectEqual(@as(usize, 2), detailed.len);
    for (detailed) |message| {
        try testing.expect(std.mem.indexOf(u8, message.content, "user@example.com") == null);
    }
    try testing.expect(std.mem.indexOf(u8, detailed[0].content, "[EMAIL_1]") != null);
    try testing.expect(std.mem.indexOf(u8, detailed[1].content, "[EMAIL_1]") != null);
}

test "restored session token reconstruction ignores usage footer decorations" {
    var mock = MockProvider{ .response = "assistant reply" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    const session_key = "telegram:main:chat-usage";
    const session = try sm.getOrCreate(session_key);
    session.agent.usage_mode = .tokens;

    const reply = try sm.processMessage(session_key, "hello", .{
        .channel = "telegram",
        .is_group = false,
        .group_id = null,
    });
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.indexOf(u8, reply, "[usage] total_tokens=") != null);

    const entries = try sqlite_mem.loadMessages(testing.allocator, session_key);
    defer memory_mod.freeMessages(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("assistant", entries[1].role);
    try testing.expectEqualStrings("assistant reply", entries[1].content);

    const expected_tokens = agent_mod.estimate_text_tokens("assistant reply");
    session.last_active = 0;
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));

    const restored_session = try sm.getOrCreate(session_key);
    try testing.expectEqual(@as(u64, expected_tokens), restored_session.agent.total_tokens);
}

test "restored session history is bounded to max_history_messages" {
    // Regression: persistTurn appends user+assistant every turn without pruning
    // the stored session, so restoring a long-lived session reloaded the entire
    // history and the next request was built from all of it. The restored window
    // must be bounded to max_history_messages (restart / cache-eviction path).
    var mock = MockProvider{ .response = "reply" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    const session_key = "telegram:main:chat-restore-bound";
    const session = try sm.getOrCreate(session_key);
    const max: usize = @intCast(session.agent.max_history_messages);
    try testing.expect(max > 0);

    // Seed the persisted session with more turns than the restore window allows.
    const store = sqlite_mem.sessionStore();
    const seed_turns = max + 25;
    var i: usize = 0;
    while (i < seed_turns) : (i += 1) {
        try store.saveMessage(session_key, "user", "hello");
        try store.saveMessage(session_key, "assistant", "reply");
    }

    // Force a restore by evicting the live session, then re-acquiring it.
    session.last_active = 0;
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));

    const restored = try sm.getOrCreate(session_key);
    try testing.expect(restored.agent.history.items.len > 0);
    try testing.expect(restored.agent.history.items.len <= max);
}

test "/new drops every piece of session-scoped state" {
    // Regression: after /new, /reset or /clear the session still carried heavy
    // context residue. The next turn's request was rebuilt from sqlite history,
    // the persisted compaction summary, pending injections, and session-scoped
    // memory (autosave rows plus the facts the pre-compaction memory flush wrote
    // from the old conversation), which autorecall then re-injected.
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    const session_key = "telegram:main:chat-new-reset";
    const store = sqlite_mem.sessionStore();
    const mem = sqlite_mem.memory();

    var mock = MockProvider{ .response = "reply" };

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        store,
        null,
    );
    defer sm.deinit();

    // Phase 1: build old-session state. The raw `*Session` is dropped before
    // evicting so the manager mutex is free (getOrCreate holds it).
    {
        const session = try sm.getOrCreate(session_key);
        const reply = try session.agent.turn("old conversation user turn");
        testing.allocator.free(reply);
        // A pre-compaction memory flush row and a compaction summary, both
        // scoped to this session, as a real compaction leaves behind.
        const scoped_id = session.agent.memory_session_id.?;
        try mem.store("flush_compact_1_0", "old-session durable fact", .conversation, scoped_id);
        try mem.store("autosave_user_1", "old-session autosave row", .conversation, scoped_id);
        try store.saveMessage(session_key, "assistant", agent_mod.compaction.COMPACTION_SUMMARY_PREFIX ++ "\nold summary");
        session.last_active = 0;
    }

    // Phase 2: a restart replays everything the reset path missed.
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));

    const session = try sm.getOrCreate(session_key);
    try testing.expect(session.agent.history.items.len > 0);
    try testing.expect(session.agent.total_tokens > 0);
    // A pending injection that outlived the /new turn is what leaks into the
    // fresh session: the manager drains it as a post-turn follow-up. Seed it on
    // the live restored session, then reset through the manager path.
    session.injectMidTurn(testing.allocator, "mid-turn steered message") catch {};
    try testing.expect(session.hasInjection());
    const calls_before_reset = mock.chat_calls;

    const ack = try sm.processMessageStreaming(session_key, "/new", null, null, null);
    defer testing.allocator.free(ack);
    try testing.expect(std.mem.startsWith(u8, ack, "Session cleared."));
    // The steered message is reported dropped, never answered: the drain loop
    // that would have run it as a follow-up turn must not have called the
    // provider for it.
    try testing.expect(std.mem.indexOf(u8, ack, "discarded by the session reset") != null);
    try testing.expect(std.mem.indexOf(u8, ack, "mid-turn steered message") == null);
    try testing.expectEqual(calls_before_reset, mock.chat_calls);

    try testing.expectEqual(@as(usize, 0), session.agent.history.items.len);
    try testing.expectEqual(@as(u64, 0), session.agent.total_tokens);
    try testing.expectEqual(@as(u64, 0), session.agent.compaction_count);
    try testing.expect(!session.hasInjection());

    // Nothing persisted under the session key survives either.
    const persisted = try store.loadMessages(testing.allocator, session_key);
    defer memory_mod.freeMessages(testing.allocator, persisted);
    try testing.expectEqual(@as(usize, 0), persisted.len);
    try testing.expectEqual(@as(?u64, 0), try store.loadCompactionCount(session_key));

    // Session-scoped memory is gone.
    const scoped = try mem.list(testing.allocator, null, session_key);
    defer memory_mod.freeEntries(testing.allocator, scoped);
    for (scoped) |entry| {
        try testing.expect(std.mem.indexOf(u8, entry.content, "old-session") == null);
    }
    try testing.expectEqual(@as(usize, 0), scoped.len);

    // A restart after /new must not bring the old conversation back: evict the
    // now-idle session so the next getOrCreate replays only what is persisted.
    // The live `session` pointer is no longer used past this point.
    session.last_active = 0;
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));
    const revived = try sm.getOrCreate(session_key);
    try testing.expectEqual(@as(usize, 0), revived.agent.history.items.len);
    try testing.expectEqual(@as(u64, 0), revived.agent.total_tokens);
}

test "/new keeps global long-term memory but drops session-scoped memory" {
    // Regression: long-term memory is global by design (OpenClaw keeps it across
    // /new), but rows scoped to the resetting session are old conversation and
    // autorecall re-injected them into the fresh session.
    var mock = MockProvider{ .response = "reply" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("global_fact", "user prefers Zig", .core, null);

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    const session_key = "telegram:main:chat-scoped-memory";
    const session = try sm.getOrCreate(session_key);
    const scoped_session_id = session.agent.memory_session_id.?;
    // Store under the session id the agent actually uses, not the channel key.
    try mem.store("flush_compact_1_0", "old-session durable fact", .conversation, scoped_session_id);
    try mem.store("autosave_user_1", "old-session autosave row", .conversation, scoped_session_id);

    const ack = try sm.handleLocalSlashCommand(session_key, "/reset", null) orelse
        return error.TestExpectedEqual;
    defer testing.allocator.free(ack);

    // A global fact survives: memory is not session-scoped by design.
    const global = (try mem.get(testing.allocator, "global_fact")) orelse
        return error.TestExpectedEqual;
    defer global.deinit(testing.allocator);

    for ([_][]const u8{ "flush_compact_1_0", "autosave_user_1" }) |key| {
        const scoped = try mem.getScoped(testing.allocator, key, scoped_session_id);
        if (scoped) |entry| {
            entry.deinit(testing.allocator);
            try testing.expect(false);
        }
    }
}

test "session restore keeps compaction summary and drops pre-compaction history" {
    // Regression: session restore dropped the compaction summary and replayed
    // every pre-compaction row, resurrecting context compaction had dropped.
    var mock = MockProvider{ .response = "summary text" };
    var cfg = testConfig();
    cfg.agent.max_history_messages = 4;
    cfg.agent.compaction_keep_recent = 4;
    cfg.agent.compaction_memory_flush = false;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    const session_key = "telegram:main:chat-compaction-restore";
    const store = sqlite_mem.sessionStore();
    // Rows persisted before compaction ran.
    try store.saveMessage(session_key, "user", "pre-compaction-old");
    try store.saveMessage(session_key, "assistant", "pre-compaction-old-reply");

    {
        var noop = observability.NoopObserver{};
        var sm = SessionManager.init(
            testing.allocator,
            &cfg,
            mock.provider(),
            &.{},
            sqlite_mem.memory(),
            noop.observer(),
            store,
            null,
        );
        defer sm.deinit();

        const session = try sm.getOrCreate(session_key);
        for (0..12) |i| {
            try session.agent.history.append(testing.allocator, .{
                .role = if (i % 2 == 0) .user else .assistant,
                .content = try std.fmt.allocPrint(testing.allocator, "message {d}", .{i}),
            });
        }
        try testing.expect(try session.agent.autoCompactHistory());
    }

    try testing.expectEqual(@as(?u64, 1), try store.loadCompactionCount(session_key));

    const persisted = try store.loadMessages(testing.allocator, session_key);
    defer memory_mod.freeMessages(testing.allocator, persisted);
    var has_persisted_summary = false;
    for (persisted) |entry| {
        if (std.mem.startsWith(u8, entry.content, agent_mod.compaction.COMPACTION_SUMMARY_PREFIX)) {
            has_persisted_summary = true;
        }
    }
    try testing.expect(has_persisted_summary);

    var mock2 = MockProvider{ .response = "reply" };
    var noop2 = observability.NoopObserver{};
    var sm2 = SessionManager.init(
        testing.allocator,
        &cfg,
        mock2.provider(),
        &.{},
        sqlite_mem.memory(),
        noop2.observer(),
        store,
        null,
    );
    defer sm2.deinit();

    const restored = try sm2.getOrCreate(session_key);
    var found_summary = false;
    var found_pre_compaction = false;
    for (restored.agent.history.items) |msg| {
        if (std.mem.startsWith(u8, msg.content, agent_mod.compaction.COMPACTION_SUMMARY_PREFIX)) {
            found_summary = true;
        }
        if (std.mem.indexOf(u8, msg.content, "pre-compaction-old") != null) {
            found_pre_compaction = true;
        }
    }
    try testing.expect(found_summary);
    try testing.expect(!found_pre_compaction);
    try testing.expectEqual(@as(u64, 1), restored.agent.compaction_count);
}

test "persisted session keeps the delivered reply when a degraded turn ends with an assistant history entry" {
    var provider = SummaryFailureProvider{};
    var probe_tool = ProbeTool{};
    const tools = [_]Tool{probe_tool.tool()};
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        provider.provider(),
        &tools,
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    const session_key = "telegram:main:chat-fallback";
    const session = try sm.getOrCreate(session_key);
    session.agent.max_tool_iterations = 1;

    const response = try sm.processMessage(session_key, "hello", .{
        .channel = "telegram",
        .is_group = false,
        .group_id = null,
    });
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "Could not produce a summary") != null);
    try testing.expect(session.agent.history.items.len > 0);
    // D2: degraded turns now record the delivered reply in history, so the
    // last entry is the assistant reply the caller received.
    try testing.expect(session.agent.history.items[session.agent.history.items.len - 1].role == .assistant);
    try testing.expectEqualStrings(response, session.agent.history.items[session.agent.history.items.len - 1].content);

    const entries = try sqlite_mem.loadMessages(testing.allocator, session_key);
    defer memory_mod.freeMessages(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("assistant", entries[1].role);
    try testing.expectEqualStrings(response, entries[1].content);
    try testing.expect(!std.mem.eql(u8, entries[1].content, "running"));

    const live_total_tokens = session.agent.total_tokens;
    try testing.expect(live_total_tokens > 0);
    session.last_active = 0;
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));

    const restored_session = try sm.getOrCreate(session_key);
    try testing.expectEqual(live_total_tokens, restored_session.agent.total_tokens);
}

test "restored session token reconstruction stays aligned across response cache hits" {
    var mock = MockProvider{ .response = "assistant reply" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var response_cache = try memory_mod.ResponseCache.init(":memory:", 60, 1000);
    defer response_cache.deinit();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        &response_cache,
    );
    defer sm.deinit();

    const session_key = "telegram:main:chat-cache";
    const first = try sm.processMessage(session_key, "hello", .{
        .channel = "telegram",
        .is_group = false,
        .group_id = null,
    });
    defer testing.allocator.free(first);

    const second = try sm.processMessage(session_key, "hello", .{
        .channel = "telegram",
        .is_group = false,
        .group_id = null,
    });
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);

    const expected_tokens = agent_mod.estimate_text_tokens("assistant reply");
    const live_session = try sm.getOrCreate(session_key);
    try testing.expectEqual(@as(u64, expected_tokens), live_session.agent.total_tokens);
    try testing.expectEqual(@as(u32, 0), live_session.agent.last_turn_usage.total_tokens);

    live_session.last_active = 0;
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));

    const restored_session = try sm.getOrCreate(session_key);
    try testing.expectEqual(@as(u64, expected_tokens), restored_session.agent.total_tokens);
}

fn expectResetTurnPersistsFreshSession(command: []const u8) !void {
    // Regression: bare /new and /reset ran a full LLM turn instead of a local ack.
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    const session_key = "telegram:main:chat-reset-usage";
    const store = sqlite_mem.sessionStore();

    const first = try sm.processMessage(session_key, "before reset", .{
        .channel = "telegram",
        .is_group = false,
        .group_id = null,
    });
    defer testing.allocator.free(first);

    const token_cost = @as(u64, agent_mod.estimate_text_tokens("ok"));
    const session = try sm.getOrCreate(session_key);
    try testing.expectEqual(token_cost, session.agent.total_tokens);
    const calls_before_reset = mock.chat_calls;

    const reset_reply = try sm.processMessage(session_key, command, .{
        .channel = "telegram",
        .is_group = false,
        .group_id = null,
    });
    defer testing.allocator.free(reset_reply);
    try testing.expectEqualStrings("Session cleared.", reset_reply);
    try testing.expectEqual(calls_before_reset, mock.chat_calls);
    try testing.expectEqual(@as(u64, 0), session.agent.total_tokens);
    try testing.expectEqual(@as(usize, 0), session.agent.historyLen());

    const entries = try store.loadMessages(testing.allocator, session_key);
    defer memory_mod.freeMessages(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
    try testing.expectEqual(@as(?u64, null), try store.loadUsage(session_key));

    session.last_active = 0;
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));

    const restored = try sm.getOrCreate(session_key);
    try testing.expectEqual(@as(u64, 0), restored.agent.total_tokens);
    try testing.expectEqual(@as(usize, 0), restored.agent.historyLen());
}

test "processMessage bare /new is a local ack and clears stored session" {
    try expectResetTurnPersistsFreshSession("/new");
}

test "processMessage bare /reset with mention is a local ack and clears stored session" {
    try expectResetTurnPersistsFreshSession("/reset@nullclaw_bot:");
}

test "processMessage slash-prefixed prompt that is not a local command persists across reload" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    const session_key = "telegram:main:slash-path";
    const slash_prompt = "/etc/hosts";
    const response = try sm.processMessage(session_key, slash_prompt, .{
        .channel = "telegram",
        .is_group = false,
        .group_id = null,
    });
    defer testing.allocator.free(response);

    const expected_tokens = @as(u64, agent_mod.estimate_text_tokens("ok"));
    const store = sqlite_mem.sessionStore();
    const entries = try store.loadMessages(testing.allocator, session_key);
    defer memory_mod.freeMessages(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("user", entries[0].role);
    try testing.expectEqualStrings(slash_prompt, entries[0].content);
    try testing.expectEqualStrings("assistant", entries[1].role);
    try testing.expectEqualStrings("ok", entries[1].content);
    try testing.expectEqual(@as(?u64, expected_tokens), try store.loadUsage(session_key));

    const live_session = try sm.getOrCreate(session_key);
    try testing.expectEqual(expected_tokens, live_session.agent.total_tokens);
    live_session.last_active = 0;
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));

    const restored = try sm.getOrCreate(session_key);
    try testing.expectEqual(expected_tokens, restored.agent.total_tokens);
    try testing.expectEqual(@as(usize, 2), restored.agent.historyLen());
    try testing.expectEqualStrings(slash_prompt, restored.agent.history.items[0].content);
    try testing.expectEqualStrings("ok", restored.agent.history.items[1].content);
}

test "processMessage runtime slash commands persist across reload" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    const session_key = "telegram:main:runtime-state";
    const commands = [_][]const u8{
        "/think high",
        "/verbose full",
        "/reasoning stream",
        "/usage full",
        "/exec host=node security=full ask=always node=worker-a",
        "/queue debounce debounce:2s cap:3 drop:oldest",
        "/tts always provider test-provider limit 120 summary on audio on",
        "/session ttl 5m",
        "/focus incident-123",
        "/dock-telegram",
        "/activation always",
        "/send on",
        "/debug reset",
        "/usage cost",
        "/exec host=sandbox security=allowlist ask=on-miss",
        "/queue serial cap:4 drop:newest",
        "/tts tagged provider replay-provider limit 77 summary off audio off",
        "/session ttl 30s",
        "/unfocus",
        "/dock-slack",
        "/activation mention",
        "/send inherit",
        "/elevated full",
    };

    for (commands) |command| {
        const reply = try sm.processMessage(session_key, command, .{
            .channel = "telegram",
            .is_group = false,
            .group_id = null,
        });
        defer testing.allocator.free(reply);
    }

    const live_session = try sm.getOrCreate(session_key);
    try testing.expect(live_session.agent.reasoning_effort == null);
    try testing.expect(live_session.agent.verbose_level == .off);
    try testing.expect(live_session.agent.reasoning_mode == .off);
    try testing.expect(live_session.agent.usage_mode == .cost);
    try testing.expect(live_session.agent.exec_host == .sandbox);
    try testing.expect(live_session.agent.exec_security == .full);
    try testing.expect(live_session.agent.exec_ask == .off);
    try testing.expect(live_session.agent.exec_node_id == null);
    try testing.expect(live_session.agent.queue_mode == .serial);
    try testing.expectEqual(@as(u32, 4), live_session.agent.queue_cap);
    try testing.expect(live_session.agent.queue_drop == .newest);
    try testing.expect(live_session.agent.tts_mode == .tagged);
    try testing.expectEqualStrings("replay-provider", live_session.agent.tts_provider.?);
    try testing.expectEqual(@as(u32, 77), live_session.agent.tts_limit_chars);
    try testing.expect(!live_session.agent.tts_summary);
    try testing.expect(!live_session.agent.tts_audio);
    try testing.expectEqual(@as(?u64, 30), live_session.agent.session_ttl_secs);
    try testing.expect(live_session.agent.focus_target == null);
    try testing.expectEqualStrings("slack", live_session.agent.dock_target.?);
    try testing.expect(live_session.agent.activation_mode == .mention);
    try testing.expect(live_session.agent.send_mode == .inherit);
    try testing.expectEqual(@as(usize, 0), live_session.agent.historyLen());

    const store = sqlite_mem.sessionStore();
    const entries = try store.loadMessages(testing.allocator, session_key);
    defer memory_mod.freeMessages(testing.allocator, entries);
    try testing.expectEqual(@as(usize, commands.len), entries.len);
    for (entries, commands) |entry, command| {
        try testing.expectEqualStrings(RUNTIME_COMMAND_ROLE, entry.role);
        try testing.expectEqualStrings(command, entry.content);
    }

    live_session.last_active = 0;
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));

    const restored = try sm.getOrCreate(session_key);
    try testing.expect(restored.agent.reasoning_effort == null);
    try testing.expect(restored.agent.verbose_level == .off);
    try testing.expect(restored.agent.reasoning_mode == .off);
    try testing.expect(restored.agent.usage_mode == .cost);
    try testing.expect(restored.agent.exec_host == .sandbox);
    try testing.expect(restored.agent.exec_security == .full);
    try testing.expect(restored.agent.exec_ask == .off);
    try testing.expect(restored.agent.exec_node_id == null);
    try testing.expect(restored.agent.queue_mode == .serial);
    try testing.expectEqual(@as(u32, 4), restored.agent.queue_cap);
    try testing.expect(restored.agent.queue_drop == .newest);
    try testing.expect(restored.agent.tts_mode == .tagged);
    try testing.expectEqualStrings("replay-provider", restored.agent.tts_provider.?);
    try testing.expectEqual(@as(u32, 77), restored.agent.tts_limit_chars);
    try testing.expect(!restored.agent.tts_summary);
    try testing.expect(!restored.agent.tts_audio);
    try testing.expectEqual(@as(?u64, 30), restored.agent.session_ttl_secs);
    try testing.expect(restored.agent.focus_target == null);
    try testing.expectEqualStrings("slack", restored.agent.dock_target.?);
    try testing.expect(restored.agent.activation_mode == .mention);
    try testing.expect(restored.agent.send_mode == .inherit);
    try testing.expectEqual(@as(usize, 0), restored.agent.historyLen());
}

test "processMessage different keys — independent sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp_a = try sm.processMessage("user:a", "hello a", null);
    defer testing.allocator.free(resp_a);

    const resp_b = try sm.processMessage("user:b", "hello b", null);
    defer testing.allocator.free(resp_b);

    const sa = try sm.getOrCreate("user:a");
    const sb = try sm.getOrCreate("user:b");
    try testing.expect(sa != sb);
    try testing.expectEqual(@as(u64, 1), sa.turn_count);
    try testing.expectEqual(@as(u64, 1), sb.turn_count);
}

test "processMessage /new clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    // Seed autosave entries for two different sessions.
    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/new", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /new with model clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/new gpt-4o-mini", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /reset clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/reset", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /restart clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/restart", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage with sqlite memory first turn does not panic" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;
    cfg.memory.backend = "sqlite";

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const resp = try sm.processMessage("signal:session:1", "hello", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("ok", resp);

    const entries = try sqlite_mem.loadMessages(testing.allocator, "signal:session:1");
    defer {
        for (entries) |entry| {
            testing.allocator.free(entry.role);
            testing.allocator.free(entry.content);
        }
        testing.allocator.free(entries);
    }
    // One user + one assistant message should be persisted.
    try testing.expect(entries.len >= 2);
}

// ---------------------------------------------------------------------------
// 3. evictIdle tests
// ---------------------------------------------------------------------------

test "evictIdle removes old sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("old:1");
    // Force last_active to the past
    session.last_active = std_compat.time.timestamp() - 1000;

    const evicted = sm.evictIdle(500);
    try testing.expectEqual(@as(usize, 1), evicted);
    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
}

test "evictIdle prunes unused dedicated agent runtimes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.session.auto_provision_direct_agents = true;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("agent:peer-0011223344556677:whatsapp_web:direct:5511");
    try testing.expectEqual(@as(usize, 1), sm.agent_runtimes.count());

    session.last_active = std_compat.time.timestamp() - 1000;
    const evicted = sm.evictIdle(1);
    try testing.expectEqual(@as(usize, 1), evicted);
    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
    try testing.expectEqual(@as(usize, 0), sm.agent_runtimes.count());
}

test "evictIdle preserves recent sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("recent:1");
    // This session was just created, last_active is now

    const evicted = sm.evictIdle(3600); // 1 hour threshold
    try testing.expectEqual(@as(usize, 0), evicted);
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "evictIdle returns correct count" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    // Create 3 sessions, make 2 old
    const s1 = try sm.getOrCreate("s1");
    const s2 = try sm.getOrCreate("s2");
    _ = try sm.getOrCreate("s3");

    s1.last_active = std_compat.time.timestamp() - 2000;
    s2.last_active = std_compat.time.timestamp() - 2000;
    // s3 stays recent

    const evicted = sm.evictIdle(1000);
    try testing.expectEqual(@as(usize, 2), evicted);
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "evictIdle with no sessions returns 0" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    try testing.expectEqual(@as(usize, 0), sm.evictIdle(60));
}

test "evictIdle preserves sessions with active turns" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("busy:1");
    session.last_active = std_compat.time.timestamp() - 1000;
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    const evicted = sm.evictIdle(5);
    try testing.expectEqual(@as(usize, 0), evicted);
    try testing.expect(sm.sessions.contains("busy:1"));
}

// ---------------------------------------------------------------------------
// 4. Thread safety tests
// ---------------------------------------------------------------------------

test "concurrent getOrCreate same key — single Session created" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 8;
    var sessions: [num_threads]*Session = undefined;
    var handles: [num_threads]std.Thread = undefined;

    for (0..num_threads) |t| {
        handles[t] = try std.Thread.spawn(.{ .stack_size = thread_stacks.COORDINATION_STACK_SIZE }, struct {
            fn run(mgr: *SessionManager, out: **Session) void {
                out.* = mgr.getOrCreate("shared:key") catch unreachable;
            }
        }.run, .{ &sm, &sessions[t] });
    }

    for (handles) |h| h.join();

    // All threads should have gotten the same session pointer
    for (1..num_threads) |i| {
        try testing.expect(sessions[0] == sessions[i]);
    }
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "concurrent getOrCreate different keys — separate Sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 8;
    var sessions: [num_threads]*Session = undefined;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][16]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "key:{d}", .{t}) catch "?";
        handles[t] = try std.Thread.spawn(.{ .stack_size = thread_stacks.COORDINATION_STACK_SIZE }, struct {
            fn run(mgr: *SessionManager, key: []const u8, out: **Session) void {
                out.* = mgr.getOrCreate(key) catch unreachable;
            }
        }.run, .{ &sm, keys[t], &sessions[t] });
    }

    for (handles) |h| h.join();

    // All sessions should be distinct
    for (0..num_threads) |i| {
        for (i + 1..num_threads) |j| {
            try testing.expect(sessions[i] != sessions[j]);
        }
    }
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());
}

test "concurrent processMessage different keys — no crash" {
    var mock = MockProvider{ .response = "concurrent ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 4;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][16]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "conc:{d}", .{t}) catch "?";
        // Match the runtime worker stack budget used for threaded session
        // turns so this test exercises concurrency rather than a tiny stack.
        handles[t] = try std.Thread.spawn(.{ .stack_size = thread_stacks.SESSION_TURN_STACK_SIZE }, struct {
            fn run(mgr: *SessionManager, key: []const u8, alloc: Allocator) void {
                for (0..3) |_| {
                    const resp = mgr.processMessage(key, "hello", null) catch return;
                    alloc.free(resp);
                }
            }
        }.run, .{ &sm, keys[t], testing.allocator });
    }

    for (handles) |h| h.join();
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());
}

test "concurrent processMessage with sqlite memory does not panic" {
    var mock = MockProvider{ .response = "concurrent sqlite ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;
    cfg.memory.backend = "sqlite";

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const num_threads = 4;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][24]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;
    var failed = std.atomic.Value(bool).init(false);

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "sqlite-conc:{d}", .{t}) catch "?";
        // This path still executes a full session turn, so keep it aligned
        // with the runtime stack budget for threaded message processing.
        handles[t] = try std.Thread.spawn(.{ .stack_size = thread_stacks.SESSION_TURN_STACK_SIZE }, struct {
            fn run(mgr: *SessionManager, key: []const u8, alloc: Allocator, failed_flag: *std.atomic.Value(bool)) void {
                for (0..5) |_| {
                    const resp = mgr.processMessage(key, "hello sqlite", null) catch {
                        failed_flag.store(true, .release);
                        return;
                    };
                    alloc.free(resp);
                }
            }
        }.run, .{ &sm, keys[t], testing.allocator, &failed });
    }

    for (handles) |h| h.join();
    try testing.expect(!failed.load(.acquire));
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());

    const count = try mem.count();
    try testing.expect(count > 0);
}

// ---------------------------------------------------------------------------
// 5. Session consolidation tests
// ---------------------------------------------------------------------------

test "session last_consolidated defaults to zero" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:consolidation");
    try testing.expectEqual(@as(u64, 0), s.last_consolidated);
}

test "session initial state includes last_consolidated" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:fields");
    try testing.expectEqual(@as(u64, 0), s.last_consolidated);
    try testing.expectEqual(@as(u64, 0), s.turn_count);
    try testing.expect(s.created_at > 0);
    try testing.expect(s.last_active > 0);
}

// ---------------------------------------------------------------------------
// 6. reloadSkillsAll tests
// ---------------------------------------------------------------------------

test "reloadSkillsAll with no sessions returns zero counts" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const result = sm.reloadSkillsAll();
    try testing.expectEqual(@as(usize, 0), result.sessions_seen);
    try testing.expectEqual(@as(usize, 0), result.sessions_reloaded);
    try testing.expectEqual(@as(usize, 0), result.failures);
}

test "reloadSkillsAll invalidates system prompt on all sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s1 = try sm.getOrCreate("reload:a");
    const s2 = try sm.getOrCreate("reload:b");
    s1.agent.has_system_prompt = true;
    s2.agent.has_system_prompt = true;

    const result = sm.reloadSkillsAll();
    try testing.expectEqual(@as(usize, 2), result.sessions_seen);
    try testing.expectEqual(@as(usize, 2), result.sessions_reloaded);
    try testing.expect(!s1.agent.has_system_prompt);
    try testing.expect(!s2.agent.has_system_prompt);
}

test "reloadSkillsAll does not affect session count" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("reload:c");
    _ = try sm.getOrCreate("reload:d");
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());

    _ = sm.reloadSkillsAll();
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());
}

// ═══════════════════════════════════════════════════════════════════════════
// Steered message reaction finalization
// ═══════════════════════════════════════════════════════════════════════════

const SteerSinkProbe = struct {
    calls: [8]Call = undefined,
    count: usize = 0,

    const Call = struct {
        message_id: [32]u8 = undefined,
        len: usize = 0,
        outcome: SteerOutcome = .done,
    };

    fn sink(self: *SteerSinkProbe) SteerReactionSink {
        return .{ .ctx = @ptrCast(self), .finalize = finalize };
    }

    fn finalize(ctx: *anyopaque, ref: ConsumedRef, outcome: SteerOutcome) void {
        const self: *SteerSinkProbe = @ptrCast(@alignCast(ctx));
        if (self.count == self.calls.len) return;
        var call = &self.calls[self.count];
        call.len = @min(ref.message_id.len, call.message_id.len);
        @memcpy(call.message_id[0..call.len], ref.message_id[0..call.len]);
        call.outcome = outcome;
        self.count += 1;
    }

    fn outcomeFor(self: *const SteerSinkProbe, message_id: []const u8) ?SteerOutcome {
        for (self.calls[0..self.count]) |call| {
            if (std.mem.eql(u8, call.message_id[0..call.len], message_id)) return call.outcome;
        }
        return null;
    }
};

test "steered refs are finalized done when the consuming turn succeeds" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "steer:refs:done";
    const session = try sm.getOrCreate(session_key);
    session.agent.queue_mode = .steer;
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    // Regression: the steer path dropped the message ref, so the accepted
    // reaction (the same emoji as running in production) was never finalized.
    const ref = ConsumedRef{ .channel = "telegram", .account_id = "main", .target = "123", .message_id = "42" };
    try testing.expectEqual(
        SessionManager.InboundRouteAction.steered,
        sm.routeInboundWithRef(session_key, "steer me", ref, null),
    );

    var probe = SteerSinkProbe{};
    const reply = try sm.processMessageStreamingWithSteerSink(session_key, "hello", null, null, null, probe.sink());
    defer testing.allocator.free(reply);

    try testing.expectEqualStrings("ok", reply);
    try testing.expectEqual(SteerOutcome.done, probe.outcomeFor("42").?);
    try testing.expect(!session.hasInjection());
}

test "two steered refs are finalized in arrival order" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "steer:refs:order";
    const session = try sm.getOrCreate(session_key);
    session.agent.queue_mode = .steer;
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    try testing.expectEqual(SessionManager.InboundRouteAction.steered, sm.routeInboundWithRef(
        session_key,
        "first",
        .{ .channel = "slack", .target = "C1", .message_id = "1" },
        null,
    ));
    try testing.expectEqual(SessionManager.InboundRouteAction.steered, sm.routeInboundWithRef(
        session_key,
        "second",
        .{ .channel = "slack", .target = "C1", .message_id = "2" },
        null,
    ));

    var probe = SteerSinkProbe{};
    const reply = try sm.processMessageStreamingWithSteerSink(session_key, "hello", null, null, null, probe.sink());
    defer testing.allocator.free(reply);

    try testing.expectEqual(@as(usize, 2), probe.count);
    try testing.expectEqualStrings("1", probe.calls[0].message_id[0..probe.calls[0].len]);
    try testing.expectEqualStrings("2", probe.calls[1].message_id[0..probe.calls[1].len]);
    try testing.expectEqual(SteerOutcome.done, probe.calls[0].outcome);
    try testing.expectEqual(SteerOutcome.done, probe.calls[1].outcome);
}

test "a latest replacement finalizes the displaced ref as failed" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "steer:refs:latest";
    const session = try sm.getOrCreate(session_key);
    session.agent.queue_mode = .latest;
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    try testing.expectEqual(SessionManager.InboundRouteAction.steered, sm.routeInboundWithRef(
        session_key,
        "old",
        .{ .channel = "telegram", .target = "123", .message_id = "old-id" },
        null,
    ));
    try testing.expectEqual(SessionManager.InboundRouteAction.steered, sm.routeInboundWithRef(
        session_key,
        "new",
        .{ .channel = "telegram", .target = "123", .message_id = "new-id" },
        null,
    ));

    var probe = SteerSinkProbe{};
    const reply = try sm.processMessageStreamingWithSteerSink(session_key, "hello", null, null, null, probe.sink());
    defer testing.allocator.free(reply);

    // The displaced message's text was discarded, so its reaction is failed;
    // the replacement is the one the turn consumed.
    try testing.expectEqual(SteerOutcome.failed, probe.outcomeFor("old-id").?);
    try testing.expectEqual(SteerOutcome.done, probe.outcomeFor("new-id").?);
}

test "a failed primary turn finalizes steered refs as failed" {
    var mock = MockProvider{ .response = "unused", .chat_error = error.ProviderError };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "steer:refs:primary-failed";
    const session = try sm.getOrCreate(session_key);
    session.agent.queue_mode = .steer;
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    try testing.expectEqual(SessionManager.InboundRouteAction.steered, sm.routeInboundWithRef(
        session_key,
        "steer me",
        .{ .channel = "slack", .target = "C1", .message_id = "1700.1" },
        null,
    ));

    var probe = SteerSinkProbe{};
    try testing.expectError(
        error.ProviderError,
        sm.processMessageStreamingWithSteerSink(session_key, "hello", null, null, null, probe.sink()),
    );
    try testing.expectEqual(SteerOutcome.failed, probe.outcomeFor("1700.1").?);
}

test "a failed post-turn follow-up finalizes its steered ref as failed" {
    var mock = MockProvider{ .response = "unused", .chat_error = error.ProviderError };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "steer:refs:follow-up-failed";
    const session = try sm.getOrCreate(session_key);
    session.turn_running.store(true, .release);
    try testing.expectEqual(SessionManager.InboundRouteAction.steered, sm.routeInboundWithRef(
        session_key,
        "steered while busy",
        .{ .channel = "slack", .target = "C1", .message_id = "1700.2" },
        null,
    ));
    session.turn_running.store(false, .release);

    var response: []const u8 = try testing.allocator.dupe(u8, "primary answer");
    var completed_turns: u64 = 1;
    var probe = SteerSinkProbe{};
    try testing.expect(try sm.drainLateInjection(session, session_key, &response, &completed_turns, probe.sink(), false, null));
    defer testing.allocator.free(response);
    try testing.expectEqual(SteerOutcome.failed, probe.outcomeFor("1700.2").?);
}

test "p0f reaction regression acknowledgement releases locks and precedes completion" {
    // Regression: accepted performed network I/O under both routing locks;
    // completion must still wait for accepted after those locks are released.
    for ([_]config_types.QueueMode{ .steer, .latest }) |mode| {
        var mock = MockProvider{ .response = "ok" };
        const cfg = testConfig();
        var sm = testSessionManager(testing.allocator, &mock, &cfg);
        defer sm.deinit();
        const key = "steer:ack-locks";
        const session = try sm.getOrCreate(key);
        session.agent.queue_mode = mode;
        session.turn_running.store(true, .release);
        defer session.turn_running.store(false, .release);
        const Probe = struct {
            manager: *SessionManager,
            session: *Session,
            locks_free: bool = false,
            accepting: bool = false,
            finished: bool = false,
            ordered: bool = true,
            fn accept(ctx: *anyopaque, _: ConsumedRef) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                const manager_free = self.manager.mutex.tryLock();
                if (manager_free) self.manager.mutex.unlock();
                const injection_free = self.session.injection_mu.tryLock();
                if (injection_free) self.session.injection_mu.unlock();
                self.locks_free = manager_free and injection_free;
                // The failing implementation returns without blocking the test.
                if (!self.locks_free) return;
                self.accepting = true;
                defer self.accepting = false;
                var refs: std.ArrayListUnmanaged(ConsumedRef) = .empty;
                const text = self.session.drainInjectionWithRefs(testing.allocator, testing.allocator, &refs) catch unreachable;
                defer if (text) |t| testing.allocator.free(t);
                finalizeSteerRefs(.{ .ctx = self, .finalize = finish }, testing.allocator, &refs, .done);
                self.ordered = self.ordered and !self.finished;
                // /stop and routing in another session can re-enter safely.
                var interrupt = self.manager.requestTurnInterrupt("another-session");
                interrupt.deinit(testing.allocator);
            }
            fn finish(ctx: *anyopaque, _: ConsumedRef, _: SteerOutcome) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.ordered = self.ordered and !self.accepting;
                self.finished = true;
            }
        };
        var probe = Probe{ .manager = &sm, .session = session };
        try testing.expectEqual(SessionManager.InboundRouteAction.steered, sm.routeInboundWithRef(
            key,
            "insert",
            .{ .channel = "slack", .target = "D_TEST", .message_id = "1.1" },
            .{ .ctx = &probe, .finalize = Probe.finish, .accepted = Probe.accept },
        ));
        try testing.expect(probe.locks_free);
        try testing.expect(probe.finished);
        try testing.expect(probe.ordered);
    }
}

test "p0f reaction regression each ref retains its originating transport finalizer" {
    // Regression: a shared session used the consuming turn's transport/account
    // for all refs, clearing the wrong bot or dropping Slack timestamps entirely.
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();
    const key = "steer:shared-origin";
    const session = try sm.getOrCreate(key);
    session.agent.queue_mode = .steer;
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);
    var bot_b = SteerSinkProbe{};
    var slack = SteerSinkProbe{};
    var bot_a = SteerSinkProbe{};
    try testing.expectEqual(SessionManager.InboundRouteAction.steered, sm.routeInboundWithRef(
        key,
        "from another bot",
        .{ .channel = "telegram", .account_id = "bot-b", .target = "123", .message_id = "42" },
        bot_b.sink(),
    ));
    try testing.expectEqual(SessionManager.InboundRouteAction.steered, sm.routeInboundWithRef(
        key,
        "from Slack",
        .{ .channel = "slack", .account_id = "main", .target = "D_TEST", .message_id = "1.1" },
        slack.sink(),
    ));
    const reply = try sm.processMessageStreamingWithSteerSink(key, "hello", null, null, null, bot_a.sink());
    defer testing.allocator.free(reply);
    try testing.expectEqual(@as(usize, 0), bot_a.count);
    try testing.expectEqual(SteerOutcome.done, bot_b.outcomeFor("42").?);
    try testing.expectEqual(SteerOutcome.done, slack.outcomeFor("1.1").?);
}

test "steer reactions preserve origin on failed and replaced messages" {
    // Regression: turn-owned sinks finalized another transport's failed or
    // replaced ref, leaving its original account's acknowledgement behind.
    for ([_]bool{ false, true }) |replace| {
        var mock = MockProvider{ .response = "unused", .chat_error = error.ProviderError };
        const cfg = testConfig();
        var sm = testSessionManager(testing.allocator, &mock, &cfg);
        defer sm.deinit();
        const key = "steer:origin-failure";
        const session = try sm.getOrCreate(key);
        session.agent.queue_mode = if (replace) .latest else .steer;
        session.turn_running.store(true, .release);
        defer session.turn_running.store(false, .release);
        var origin = SteerSinkProbe{};
        var consumer = SteerSinkProbe{};
        try testing.expectEqual(SessionManager.InboundRouteAction.steered, sm.routeInboundWithRef(
            key,
            "first",
            .{ .channel = "slack", .account_id = "secondary", .target = "D_TEST", .message_id = "1.1" },
            origin.sink(),
        ));
        if (replace) {
            try testing.expectEqual(SessionManager.InboundRouteAction.steered, sm.routeInboundWithRef(
                key,
                "replacement",
                .{ .channel = "telegram", .account_id = "secondary", .target = "123", .message_id = "42" },
                origin.sink(),
            ));
        }
        try testing.expectError(error.ProviderError, sm.processMessageStreamingWithSteerSink(
            key,
            "hello",
            null,
            null,
            null,
            consumer.sink(),
        ));
        try testing.expectEqual(@as(usize, 0), consumer.count);
        try testing.expectEqual(SteerOutcome.failed, origin.outcomeFor("1.1").?);
        if (replace) try testing.expectEqual(SteerOutcome.failed, origin.outcomeFor("42").?);
    }
}

test "post-turn follow-up streams the separator its reply joins with" {
    // Regression: the combined reply is primary + "\n\n" + follow-up, but the
    // follow-up turn's own stream went out with no separator, so the preview
    // (primary followed by follow-up) was not a prefix of the reply.
    //
    // Rewritten to drive processMessageStreaming: the ported adapter installs
    // and restores the agent callback per turn, so a test that pokes
    // agent.stream_callback by hand passes even while the production path
    // drops the separator.
    var mock = MockStreamingProvider{ .response = "follow-up answer" };
    const cfg = testConfig();
    var observer = TailInjectObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        null,
        observer.observer(),
        null,
        null,
    );
    defer sm.deinit();
    const key = "followup:streamed-separator";
    const session = try sm.getOrCreate(key);
    observer.session = session;

    var probe = StreamTurnProbe{ .allocator = testing.allocator };
    defer probe.deinit();
    mock.on_stream = StreamTurnProbe.onStream;
    mock.on_stream_ctx = @ptrCast(&probe);

    const resp = try sm.processMessageStreaming(key, "hello", null, .{
        .callback = StreamTurnProbe.onEvent,
        .ctx = @ptrCast(&probe),
    }, null);
    defer testing.allocator.free(resp);

    // The steer landed after the agent's last drain, so it ran as a follow-up
    // turn: primary deltas, the separator, then the follow-up's own deltas.
    try testing.expectEqual(@as(usize, 2), probe.provider_calls);
    try testing.expectEqualStrings("follow-up answer\n\nfollow-up answer", resp);
    try testing.expectEqualStrings("follow-up answer\n\nfollow-up answer", probe.data.items);
}

test "suppressed live draft drops the follow-up separator too" {
    // The separator must go through the same suppression wrapper as the turns
    // it joins: with live-draft suppression on, no delta (separator included)
    // may reach the channel.
    var mock = MockStreamingProvider{ .response = "follow-up answer" };
    const cfg = testConfig();
    var observer = TailInjectObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        null,
        observer.observer(),
        null,
        null,
    );
    defer sm.deinit();
    const key = "followup:suppressed-separator";
    const session = try sm.getOrCreate(key);
    observer.session = session;

    var probe = StreamTurnProbe{ .allocator = testing.allocator };
    defer probe.deinit();
    mock.on_stream = StreamTurnProbe.onStream;
    mock.on_stream_ctx = @ptrCast(&probe);

    // PII in the primary content turns the once-per-turn live-draft rule on.
    const resp = try sm.processMessageStreaming(key, "my email is alice@example.com", null, .{
        .callback = StreamTurnProbe.onEvent,
        .ctx = @ptrCast(&probe),
    }, null);
    defer testing.allocator.free(resp);

    try testing.expectEqual(@as(usize, 2), probe.provider_calls);
    try testing.expectEqualStrings("follow-up answer\n\nfollow-up answer", resp);
    try testing.expectEqual(@as(usize, 0), probe.data.items.len);
}

test "steer failed follow up uses its originating reaction sink" {
    // Regression: a failed follow-up must clear the inserted message on its
    // original transport, even when the consuming turn came from another one.
    var mock = MockProvider{ .response = "unused", .chat_error = error.ProviderError };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();
    const key = "steer:origin-follow-up";
    const session = try sm.getOrCreate(key);
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);
    var origin = SteerSinkProbe{};
    var consumer = SteerSinkProbe{};
    try testing.expectEqual(SessionManager.InboundRouteAction.steered, sm.routeInboundWithRef(
        key,
        "follow-up",
        .{ .channel = "slack", .account_id = "secondary", .target = "D_TEST", .message_id = "1.1" },
        origin.sink(),
    ));
    var response: []const u8 = try testing.allocator.dupe(u8, "primary answer");
    defer testing.allocator.free(response);
    var completed_turns: u64 = 1;
    try testing.expect(try sm.drainLateInjection(session, key, &response, &completed_turns, consumer.sink(), false, null));
    try testing.expectEqual(@as(usize, 0), consumer.count);
    try testing.expectEqual(SteerOutcome.failed, origin.outcomeFor("1.1").?);
}

test "steered message reaction is finalized after its consuming turn is interrupted" {
    // Regression: /stop could finish a consuming turn while its inserted
    // message's acknowledgement remained on the original channel forever.
    var mock = MockProvider{ .response = "unused" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();
    const key = "steer:origin-interrupt";
    const session = try sm.getOrCreate(key);
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);
    var origin = SteerSinkProbe{};
    var consumer = SteerSinkProbe{};
    try testing.expectEqual(SessionManager.InboundRouteAction.steered, sm.routeInboundWithRef(
        key,
        "insert",
        .{ .channel = "slack", .account_id = "secondary", .target = "D_TEST", .message_id = "1.1" },
        origin.sink(),
    ));
    const Interrupt = struct {
        session: *Session,
        fn hook(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.session.requestInterrupt();
        }
    };
    var interrupt = Interrupt{ .session = session };
    mock.on_chat = Interrupt.hook;
    mock.on_chat_ctx = &interrupt;
    const reply = try sm.processMessageStreamingWithSteerSink(key, "hello", null, null, null, consumer.sink());
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.indexOf(u8, reply, "Interrupted by /stop") != null);
    try testing.expectEqual(@as(usize, 1), origin.count);
    try testing.expectEqual(@as(usize, 0), consumer.count);
    // Interrupted turns return a user-visible terminal response, like the
    // original message's .done handling; empty done clears the reaction.
    try testing.expectEqual(SteerOutcome.done, origin.outcomeFor("1.1").?);
}

test "steered follow-up does not inherit a stop from the failed primary turn" {
    // Regression: a /stop that landed on a primary turn failing with
    // error.RateLimited left agent.interrupt_requested set until the whole
    // streaming call returned. The steered follow-up (drained by
    // drainInjectionsAfterFailedTurn) then answered "Interrupted by /stop"
    // without ever calling the provider.
    var mock = MockProvider{
        .response = "unused",
        .responses = &.{ "unused", "follow-up answer" },
        .fail_rate_limited_calls = &.{1},
    };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const key = "steer:interrupt-leak";
    const session = try sm.getOrCreate(key);
    session.agent.queue_mode = .steer;

    const SteerAndStop = struct {
        session: *Session,
        fired: bool = false,
        fn hook(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.fired) return;
            self.fired = true;
            _ = self.session.appendMidTurnIfRunning(testing.allocator, "steered while busy") catch false;
            self.session.requestInterrupt();
        }
    };
    var hook_ctx = SteerAndStop{ .session = session };
    mock.on_chat = SteerAndStop.hook;
    mock.on_chat_ctx = &hook_ctx;

    const reply = try sm.processMessageStreamingWithSteerSink(key, "primary", null, null, null, null);
    defer testing.allocator.free(reply);

    try testing.expectEqualStrings("follow-up answer", reply);
    try testing.expect(std.mem.indexOf(u8, reply, "Interrupted by /stop") == null);
    // The failed primary turn and the steered follow-up both reached the
    // provider; the stop must not have skipped the follow-up.
    try testing.expectEqual(@as(usize, 2), mock.chat_calls);
}

test "auto reset clears stale session state on next getOrCreate" {
    var mock = MockProvider{ .response = "reply" };
    var cfg = testConfig();
    cfg.session.reset = .{ .mode = .idle, .idle_minutes = 1 };

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();

    const session_key = "agent:main:telegram:direct:auto-reset";
    const store = sqlite_mem.sessionStore();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        store,
        null,
    );
    defer sm.deinit();

    {
        const session = try sm.getOrCreate(session_key);
        const reply = try session.agent.turn("old conversation user turn");
        testing.allocator.free(reply);
        const scoped_id = session.agent.memory_session_id.?;
        try mem.store("autosave_user_1", "old-session autosave row", .conversation, scoped_id);
        try store.saveMessage(session_key, "assistant", "old persisted reply");
        try store.saveCompactionCount(session_key, 3);
        try testing.expect(session.agent.history.items.len > 0);
        session.created_at = std_compat.time.timestamp() - 600;
        session.last_active = std_compat.time.timestamp() - 600;
    }

    const before = std_compat.time.timestamp();
    const session = try sm.getOrCreate(session_key);
    try testing.expectEqual(@as(usize, 0), session.agent.history.items.len);
    try testing.expectEqual(@as(u64, 0), session.agent.total_tokens);
    try testing.expectEqual(@as(u64, 0), session.agent.compaction_count);
    try testing.expect(session.created_at >= before);
    try testing.expect(session.last_active >= before);

    const persisted = try store.loadMessages(testing.allocator, session_key);
    defer memory_mod.freeMessages(testing.allocator, persisted);
    try testing.expectEqual(@as(usize, 0), persisted.len);
    try testing.expectEqual(@as(?u64, 0), try store.loadCompactionCount(session_key));

    const scoped = try mem.list(testing.allocator, null, session_key);
    defer memory_mod.freeEntries(testing.allocator, scoped);
    try testing.expectEqual(@as(usize, 0), scoped.len);

    // The next turn runs with empty history (system prompt + user + assistant).
    const reply = try session.agent.turn("fresh turn");
    testing.allocator.free(reply);
    try testing.expectEqual(@as(usize, 3), session.agent.history.items.len);
    try testing.expectEqualStrings("fresh turn", session.agent.history.items[1].content);
}

test "auto reset daily boundary uses created_at" {
    var mock = MockProvider{ .response = "reply" };
    var cfg = testConfig();
    cfg.session.reset = .{ .mode = .daily, .at_hour = 0 };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "agent:main:telegram:group:daily-reset";
    const session = try sm.getOrCreate(session_key);
    const reply = try session.agent.turn("old conversation user turn");
    testing.allocator.free(reply);
    try testing.expect(session.agent.history.items.len > 0);
    // Started before today's boundary; the last interaction is current.
    session.created_at = std_compat.time.timestamp() - 2 * 86400;
    session.last_active = std_compat.time.timestamp();

    const again = try sm.getOrCreate(session_key);
    try testing.expectEqual(@as(usize, 0), again.agent.history.items.len);
}

test "auto reset stays off by default even for old sessions" {
    var mock = MockProvider{ .response = "reply" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "agent:main:telegram:direct:no-reset";
    const session = try sm.getOrCreate(session_key);
    const reply = try session.agent.turn("keep me");
    testing.allocator.free(reply);
    const history_len = session.agent.history.items.len;
    session.created_at = 0;
    session.last_active = 0;

    const again = try sm.getOrCreate(session_key);
    try testing.expectEqual(history_len, again.agent.history.items.len);
}

test "auto reset is skipped while a turn is running" {
    var mock = MockProvider{ .response = "reply" };
    var cfg = testConfig();
    cfg.session.reset = .{ .mode = .idle, .idle_minutes = 1 };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "agent:main:telegram:direct:busy-reset";
    const session = try sm.getOrCreate(session_key);
    const reply = try session.agent.turn("keep me");
    testing.allocator.free(reply);
    const history_len = session.agent.history.items.len;
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);
    session.created_at = std_compat.time.timestamp() - 600;
    session.last_active = std_compat.time.timestamp() - 600;

    const again = try sm.getOrCreate(session_key);
    try testing.expectEqual(history_len, again.agent.history.items.len);
}

test "auto reset does not fire for a session claimed for a turn (TOCTOU)" {
    var mock = MockProvider{ .response = "reply" };
    var cfg = testConfig();
    cfg.session.reset = .{ .mode = .idle, .idle_minutes = 1 };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "agent:main:telegram:direct:claimed-reset";
    // The session exists and holds live history from a previous turn.
    const session = try sm.getOrCreate(session_key);
    const reply = try session.agent.turn("live conversation");
    testing.allocator.free(reply);
    try testing.expect(session.agent.history.items.len > 0);

    // Every getOrCreate refreshes last_active, so staleness is re-applied
    // before each step that needs a live reset decision.
    const makeStale = struct {
        fn apply(s: *Session) void {
            const stale = std_compat.time.timestamp() - 600;
            s.created_at = stale;
            s.last_active = stale;
        }
    }.apply;

    // The first claimant owns the reset decision: it resets the stale session
    // and takes the claim in the same SessionManager.mutex hold (single-threaded
    // stand-in for the getOrCreateForTurn -> lockSessionForTurn window).
    makeStale(session);
    const claimed = try sm.getOrCreateForTurn(session_key, true);
    try testing.expectEqual(@as(usize, 0), claimed.agent.history.items.len);
    const reset_at = claimed.created_at;
    try testing.expect(claimed.turn_pending.load(.acquire));
    // The claim is visible on the live session.
    try testing.expect(session.turn_pending.load(.acquire));

    // While the claim is live, nobody else may reset: a fresh-stale session
    // keeps its timestamps (a reset would push created_at to "now").
    makeStale(claimed);
    const stale_at = claimed.created_at;
    const second = try sm.getOrCreate(session_key);
    try testing.expectEqual(stale_at, second.created_at);
    try testing.expect(second.turn_pending.load(.acquire));

    const third = try sm.getOrCreateForTurn(session_key, true);
    try testing.expectEqual(stale_at, third.created_at);
    try testing.expect(third.turn_pending.load(.acquire));
    try testing.expect(reset_at > stale_at);

    // Once the claim is released, the staleness is acted on normally.
    claimed.turn_pending.store(false, .release);
    makeStale(session);
    const after = try sm.getOrCreate(session_key);
    try testing.expect(!after.turn_pending.load(.acquire));
    try testing.expectEqual(@as(usize, 0), after.agent.history.items.len);
    try testing.expect(after.created_at > stale_at);
}

// Regression: a session evicted from memory must be reset on restore from
// the persisted transcript, not from the fresh in-memory timestamps.
test "auto reset fires for an evicted idle session on restore" {
    var mock = MockProvider{ .response = "reply" };
    var cfg = testConfig();
    cfg.session.reset = .{ .mode = .idle, .idle_minutes = 1 };

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();
    const mem = sqlite_mem.memory();

    const session_key = "agent:main:telegram:direct:restore-idle-stale";
    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        store,
        null,
    );
    defer sm.deinit();

    const now = std_compat.time.timestamp();
    {
        const session = try sm.getOrCreate(session_key);
        try sqlite_mem.saveMessageAt(session_key, "user", "old question", now - 600);
        try sqlite_mem.saveMessageAt(session_key, "assistant", "old answer", now - 600);
        try store.saveUsage(session_key, 123);
        try store.saveCompactionCount(session_key, 3);
        try mem.store("autosave_user_1", "old scoped row", .conversation, session.agent.memory_session_id.?);
        session.last_active = now - 600;
    }
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));

    const before = std_compat.time.timestamp();
    const session = try sm.getOrCreate(session_key);
    try testing.expectEqual(@as(usize, 0), session.agent.history.items.len);
    try testing.expectEqual(@as(u64, 0), session.agent.total_tokens);
    try testing.expectEqual(@as(u64, 0), session.agent.compaction_count);
    try testing.expect(session.created_at >= before);
    try testing.expect(session.last_active >= before);

    const persisted = try store.loadMessages(testing.allocator, session_key);
    defer memory_mod.freeMessages(testing.allocator, persisted);
    try testing.expectEqual(@as(usize, 0), persisted.len);
    try testing.expectEqual(@as(?u64, null), try store.loadUsage(session_key));
    try testing.expectEqual(@as(?u64, 0), try store.loadCompactionCount(session_key));

    const scoped = try mem.list(testing.allocator, null, session_key);
    defer memory_mod.freeEntries(testing.allocator, scoped);
    try testing.expectEqual(@as(usize, 0), scoped.len);
}

// Regression: fresh persisted activity must keep an evicted session's history.
test "evicted session with fresh persisted activity restores history" {
    var mock = MockProvider{ .response = "reply" };
    var cfg = testConfig();
    cfg.session.reset = .{ .mode = .idle, .idle_minutes = 1 };

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    const session_key = "agent:main:telegram:direct:restore-idle-fresh";
    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        null,
        noop.observer(),
        store,
        null,
    );
    defer sm.deinit();

    const now = std_compat.time.timestamp();
    {
        const session = try sm.getOrCreate(session_key);
        try sqlite_mem.saveMessageAt(session_key, "user", "recent question", now - 5);
        try sqlite_mem.saveMessageAt(session_key, "assistant", "recent answer", now - 5);
        session.last_active = now - 600;
    }
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));

    const session = try sm.getOrCreate(session_key);
    try testing.expectEqual(@as(usize, 2), session.agent.history.items.len);
    try testing.expectEqualStrings("recent question", session.agent.history.items[0].content);
    try testing.expectEqualStrings("recent answer", session.agent.history.items[1].content);

    const persisted = try store.loadMessages(testing.allocator, session_key);
    defer memory_mod.freeMessages(testing.allocator, persisted);
    try testing.expectEqual(@as(usize, 2), persisted.len);
}

// Regression: daily reset must use the first persisted message after eviction.
test "auto reset daily fires across a boundary after eviction" {
    var mock = MockProvider{ .response = "reply" };
    var cfg = testConfig();
    cfg.session.reset = .{ .mode = .daily, .at_hour = 0 };

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    const session_key = "agent:main:telegram:group:restore-daily-stale";
    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        null,
        noop.observer(),
        store,
        null,
    );
    defer sm.deinit();

    const now = std_compat.time.timestamp();
    {
        const session = try sm.getOrCreate(session_key);
        try sqlite_mem.saveMessageAt(session_key, "user", "old question", now - 2 * 86400);
        try sqlite_mem.saveMessageAt(session_key, "assistant", "current answer", now);
        session.last_active = now - 600;
    }
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));

    const session = try sm.getOrCreate(session_key);
    try testing.expectEqual(@as(usize, 0), session.agent.history.items.len);

    const persisted = try store.loadMessages(testing.allocator, session_key);
    defer memory_mod.freeMessages(testing.allocator, persisted);
    try testing.expectEqual(@as(usize, 0), persisted.len);
}

// Regression: with the default policy (none) the restore check is skipped and
// persisted history still loads.
test "default reset mode restores persisted history after eviction" {
    var mock = MockProvider{ .response = "reply" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    const session_key = "agent:main:telegram:direct:restore-default";
    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        null,
        noop.observer(),
        store,
        null,
    );
    defer sm.deinit();

    const now = std_compat.time.timestamp();
    {
        const session = try sm.getOrCreate(session_key);
        try sqlite_mem.saveMessageAt(session_key, "user", "kept question", now - 2 * 86400);
        try sqlite_mem.saveMessageAt(session_key, "assistant", "kept answer", now - 2 * 86400);
        session.last_active = now - 600;
    }
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));

    const session = try sm.getOrCreate(session_key);
    try testing.expectEqual(@as(usize, 2), session.agent.history.items.len);
}

test "abandonTurn releases a claim so a stale session can still reset" {
    var mock = MockProvider{ .response = "reply" };
    var cfg = testConfig();
    cfg.session.reset = .{ .mode = .idle, .idle_minutes = 1 };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session_key = "agent:main:telegram:direct:failed-claim";
    const session = try sm.getOrCreate(session_key);
    const reply = try session.agent.turn("live conversation");
    testing.allocator.free(reply);

    // Mirrors the errdefer in processMessageStreamingWithSteerSink: a claim is
    // taken and the caller unwinds without ever reaching beginTurn.
    _ = failClaimedTurn(&sm, session_key) catch {};

    // The stale session becomes resettable again once the claim is released.
    const stale = std_compat.time.timestamp() - 600;
    session.created_at = stale;
    session.last_active = stale;
    const after = try sm.getOrCreate(session_key);
    try testing.expect(!after.turn_pending.load(.acquire));
    try testing.expectEqual(@as(usize, 0), after.agent.history.items.len);
    try testing.expect(after.created_at > stale);
}

/// Takes a turn claim and unwinds before the turn starts, exactly as the
/// `errdefer self.abandonTurn(session)` in the streaming path does.
fn failClaimedTurn(sm: *SessionManager, session_key: []const u8) !void {
    const session = try sm.getOrCreateForTurn(session_key, true);
    errdefer sm.abandonTurn(session);
    // Simulated failure exit of the caller.
    return error.ProviderError;
}

fn dshNativeLogEventText(event: dsh_native_types.Event) ![]const u8 {
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

test "dsh-native: store history seeds the JSONL once, windowed, and leaves the store intact" {
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();
    fixture.cfg.agent.max_history_messages = 3;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    const key = "telegram:main:dsh-native-seed";
    const rows = [_]struct { role: []const u8, content: []const u8 }{
        .{ .role = "user", .content = "q1" },
        .{ .role = "assistant", .content = "a1" },
        .{ .role = "user", .content = "q2" },
        .{ .role = "assistant", .content = "a2" },
        .{ .role = "user", .content = "q3" },
        .{ .role = "assistant", .content = "a3" },
    };
    for (rows) |row| try store.saveMessage(key, row.role, row.content);

    var provider = DshNativeScriptedProvider.init(testing.allocator, &.{.{ .text = "next reply" }});
    defer provider.deinit();
    var sm = fixture.managerWithStore(&provider, store);
    defer sm.deinit();

    const session = try sm.getOrCreate(key);
    const log_path = try testing.allocator.dupe(u8, session.dsh_native.?.harness.log.?.path);
    defer testing.allocator.free(log_path);

    var read = try dsh_native_session_log.readLog(testing.allocator, log_path);
    defer read.deinit();
    try testing.expect(read.header.is_seeded);
    // max_history_messages=3 keeps only the newest rows, in native order.
    try testing.expectEqual(@as(usize, 7), read.events.len);
    try testing.expectEqualStrings("assistant/message", read.events[3].event_type);
    try testing.expectEqualStrings("a2", try dshNativeLogEventText(read.events[3]));
    try testing.expectEqualStrings("user/message", read.events[4].event_type);
    try testing.expectEqualStrings("q3", try dshNativeLogEventText(read.events[4]));
    try testing.expectEqualStrings("assistant/message", read.events[5].event_type);
    try testing.expectEqualStrings("a3", try dshNativeLogEventText(read.events[5]));
    try testing.expectEqualStrings("session/end-seed", read.events[6].event_type);

    // Import is read-only for the host store.
    const stored = try store.loadMessages(testing.allocator, key);
    defer memory_mod.freeMessages(testing.allocator, stored);
    try testing.expectEqual(@as(usize, 6), stored.len);
    for (rows, stored) |row, entry| {
        try testing.expectEqualStrings(row.role, entry.role);
        try testing.expectEqualStrings(row.content, entry.content);
    }

    // A cache eviction recreates the session: the JSONL is resumed, not reseeded.
    session.last_active = 0;
    try testing.expectEqual(@as(usize, 1), sm.evictIdle(1));
    _ = try sm.getOrCreate(key);
    var reread = try dsh_native_session_log.readLog(testing.allocator, log_path);
    defer reread.deinit();
    try testing.expectEqual(@as(usize, 7), reread.events.len);

    // Mirroring after the restore still writes to the same store path.
    const reply = try sm.processMessage(key, "next question", null);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("next reply", reply);
    const after = try store.loadMessages(testing.allocator, key);
    defer memory_mod.freeMessages(testing.allocator, after);
    try testing.expectEqual(@as(usize, 8), after.len);
    try testing.expectEqualStrings("next question", after[6].content);
    try testing.expectEqualStrings("next reply", after[7].content);
}

test "agent.harness switch between dsh and native keeps the store and restarts cleanly" {
    // Regression: the P3 default switch must stay reversible. Restarting one
    // session key under a different `agent.harness` may not crash, drop rows
    // from the junclaw store, or wedge the in-process engine's JSONL resume.
    var fixture = try DshNativeFixture.init();
    defer fixture.deinit();
    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    const key = "telegram:main:harness-switch";
    var dsh_provider = DshNativeScriptedProvider.init(testing.allocator, &.{
        .{ .text = "dsh answer one" },
        .{ .text = "dsh answer two" },
    });
    defer dsh_provider.deinit();

    {
        var sm = fixture.managerWithStore(&dsh_provider, store);
        defer sm.deinit();
        const reply = try sm.processMessage(key, "dsh question one", null);
        defer testing.allocator.free(reply);
        try testing.expectEqualStrings("dsh answer one", reply);
    }
    {
        const rows = try store.loadMessages(testing.allocator, key);
        defer memory_mod.freeMessages(testing.allocator, rows);
        try testing.expectEqual(@as(usize, 2), rows.len);
        try testing.expectEqualStrings("dsh question one", rows[0].content);
        try testing.expectEqualStrings("dsh answer one", rows[1].content);
    }

    // Restart the same key on the native engine with the same store.
    fixture.cfg.agent.harness = .native;
    var native_provider = MockProvider{ .response = "native answer" };
    {
        var sm = testSessionManagerWithMemory(testing.allocator, &native_provider, &fixture.cfg, null, store);
        defer sm.deinit();
        const session = try sm.getOrCreate(key);
        try testing.expect(session.dsh_native == null);
        try testing.expectEqual(@as(*anyopaque, @ptrCast(&session.harness)), session.turnHarness().ptr);
        var restored_reply = false;
        for (session.agent.history.items) |message| {
            if (std.mem.eql(u8, message.content, "dsh answer one")) restored_reply = true;
        }
        try testing.expect(restored_reply);

        const reply = try sm.processMessage(key, "native question", null);
        defer testing.allocator.free(reply);
        try testing.expectEqualStrings("native answer", reply);
    }
    {
        const rows = try store.loadMessages(testing.allocator, key);
        defer memory_mod.freeMessages(testing.allocator, rows);
        try testing.expectEqual(@as(usize, 4), rows.len);
        try testing.expectEqualStrings("native question", rows[2].content);
        try testing.expectEqualStrings("native answer", rows[3].content);
    }

    // Switch back: the JSONL resumes and no store row is lost.
    fixture.cfg.agent.harness = .dsh;
    {
        var sm = fixture.managerWithStore(&dsh_provider, store);
        defer sm.deinit();
        const reply = try sm.processMessage(key, "dsh question two", null);
        defer testing.allocator.free(reply);
        try testing.expectEqualStrings("dsh answer two", reply);
    }
    const rows = try store.loadMessages(testing.allocator, key);
    defer memory_mod.freeMessages(testing.allocator, rows);
    try testing.expectEqual(@as(usize, 6), rows.len);
    const expected = [_]struct { role: []const u8, content: []const u8 }{
        .{ .role = "user", .content = "dsh question one" },
        .{ .role = "assistant", .content = "dsh answer one" },
        .{ .role = "user", .content = "native question" },
        .{ .role = "assistant", .content = "native answer" },
        .{ .role = "user", .content = "dsh question two" },
        .{ .role = "assistant", .content = "dsh answer two" },
    };
    for (expected, rows) |want, got| {
        try testing.expectEqualStrings(want.role, got.role);
        try testing.expectEqualStrings(want.content, got.content);
    }
}

test "dsh-sidecar: per-session reasoning_mode follows config and /reasoning" {
    // Regression: Info.reasoning_mode was hardcoded `.off` for every sidecar
    // session, so the host never knew a session had selected on/stream.
    if (comptime !dsh_enabled) return error.SkipZigTest;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const config_path = try std_compat.fs.path.join(allocator, &.{ base, "config.json" });
    defer allocator.free(config_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.agent.harness = .dsh_sidecar;
    cfg.agent.reasoning_mode = .on;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(allocator, &mock, &cfg);
    defer sm.deinit();

    const first = try sm.getOrCreate("cli:main:reasoning-mode-a");
    try testing.expectEqual(
        config_types.ReasoningMode.on,
        first.turnHarness().info().reasoning_mode,
    );

    const reply = (try first.handleLocalCommand("/reasoning stream")).?;
    defer allocator.free(reply);
    try testing.expectEqual(
        config_types.ReasoningMode.stream,
        first.turnHarness().info().reasoning_mode,
    );

    // A second key on the same shared DshEngine keeps the configured default;
    // the first key changing its mode must not retarget it.
    const second = try sm.getOrCreate("cli:main:reasoning-mode-b");
    try testing.expectEqual(
        config_types.ReasoningMode.on,
        second.turnHarness().info().reasoning_mode,
    );
    try testing.expectEqual(
        config_types.ReasoningMode.stream,
        first.turnHarness().info().reasoning_mode,
    );
}
