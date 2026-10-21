//! The native adapter: `Harness` implemented over the existing `Agent`.
//!
//! Its only job is to be a behavior-identical wrapper. Everything it does was
//! lifted out of `src/session.zig` verbatim (see the per-method notes for the
//! line each one replaced) so the default path keeps byte-for-byte behavior
//! while the host talks to a port instead of to the Agent directly.
//!
//! What it deliberately does NOT do: touch `usage_record_callback`. That
//! callback is installed once at session creation and writes the usage ledger;
//! re-installing or wrapping it per turn would double-count or drop rows.

const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const providers = @import("../providers/root.zig");
const turn_persistence = @import("../agent/turn_persistence.zig");
const prompt = @import("../agent/prompt.zig");
const observability = @import("../observability.zig");
const memory_mod = @import("../memory/root.zig");
const port = @import("port.zig");

const Agent = agent_mod.Agent;
const Harness = port.Harness;

pub const NativeHarness = struct {
    const Self = @This();

    agent: *Agent,
    /// Borrowed for the duration of `runTurn`; the host keeps it alive.
    conversation_context: ?prompt.ConversationContext = null,
    /// Session key for this turn; the host sets it before every turn.
    session_key: []const u8 = "",
    /// The session host records `agent_start`; direct CLI/subagent callers
    /// never did, so they turn this off to stay behavior-identical.
    emit_start_event: bool = true,

    pub fn init(agent: *Agent) Self {
        return .{ .agent = agent };
    }

    pub fn harness(self: *Self) Harness {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    // ── stream forwarder ────────────────────────────────────────────────────
    /// The port's delta is the raw provider chunk, so forward it untouched:
    /// the host derives the rendered text (and any live-draft suppression)
    /// exactly as `streaming.Sink` does.
    fn streamChunkForwarder(ctx_ptr: *anyopaque, chunk: providers.StreamChunk) void {
        const sink: *port.Sink = @ptrCast(@alignCast(ctx_ptr));
        sink.send(.{ .delta = chunk });
    }

    // ── vtable ────────────────────────────────────────────────────────

    fn runTurn(ptr: *anyopaque, input: port.TurnInput) anyerror!port.TurnResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const agent = self.agent;

        // Replaces src/session.zig:2739-2771 verbatim: the stream callback is
        // installed only when the host has a live draft, the progress callback
        // only when the host has a sink, and both are restored on the way out.
        const prev_stream_callback = agent.stream_callback;
        const prev_stream_ctx = agent.stream_ctx;
        defer {
            agent.stream_callback = prev_stream_callback;
            agent.stream_ctx = prev_stream_ctx;
        }

        // The agent's callbacks take a *anyopaque, and `input` is a by-value
        // parameter whose address would not outlive the call, so keep a stable
        // local copy of the sink for the lifetime of the turn.
        var sink_holder: ?port.Sink = input.sink;
        const sink_ptr: ?*port.Sink = if (sink_holder) |*s| s else null;

        // The host installs the stream callback only when it has a live draft
        // (`stream_callback != null`); a null sink means "no observer this
        // turn", which is the `else` branch the host already had.
        if (input.live_stream) {
            if (sink_ptr) |s| {
                agent.stream_callback = streamChunkForwarder;
                agent.stream_ctx = @ptrCast(s);
            } else {
                agent.stream_callback = null;
                agent.stream_ctx = null;
            }
        } else {
            agent.stream_callback = null;
            agent.stream_ctx = null;
        }

        const prev_progress_callback = agent.progress_callback;
        const prev_progress_ctx = agent.progress_ctx;
        defer {
            agent.progress_callback = prev_progress_callback;
            agent.progress_ctx = prev_progress_ctx;
        }
        if (sink_ptr) |s| {
            agent.progress_callback = progressForwarder;
            agent.progress_ctx = @ptrCast(s);
        } else {
            agent.progress_callback = null;
            agent.progress_ctx = null;
        }

        // Kept from src/session.zig:2773-2780: the observer's agent_start event
        // with channel attribution must survive the install block moving here.
        if (self.emit_start_event) {
            const start_event = observability.ObserverEvent{ .agent_start = .{
                .provider = agent.provider.getName(),
                .model = agent.model_name,
                .channel = if (input.conversation_context) |ctx| ctx.channel else null,
                .bot_account = if (input.conversation_context) |ctx| ctx.account_id else null,
            } };
            agent.observer.recordEvent(&start_event);
        }

        // Replaces src/session.zig:2786-2794: the drain is installed per turn
        // with this turn's context, exactly as the host did.
        const prev_drain_callback = agent.drain_injection_cb;
        const prev_drain_ctx = agent.drain_injection_ctx;
        defer {
            agent.drain_injection_cb = prev_drain_callback;
            agent.drain_injection_ctx = prev_drain_ctx;
        }
        if (input.drain) |cb| {
            agent.drain_injection_cb = cb;
            agent.drain_injection_ctx = input.drain_ctx;
        } else {
            agent.drain_injection_cb = null;
            agent.drain_injection_ctx = null;
        }

        const reply = agent.turn(input.user_message) catch |err| {
            return err;
        };
        errdefer agent.allocator.free(reply);

        return .{
            .reply = reply,
            .persisted_reply = turn_persistence.persistedAssistantReply(agent.history.items, reply),
            .total_tokens = agent.total_tokens,
            .end_reason = if (agent.last_turn_interrupted) .interrupted else .completed,
            .compacted = agent.last_turn_compacted,
        };
    }

    fn progressForwarder(ctx_ptr: *anyopaque, hint: agent_mod.ProgressHint) void {
        const sink: *port.Sink = @ptrCast(@alignCast(ctx_ptr));
        sink.send(.{ .progress = hint });
    }

    fn requestInterrupt(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.agent.requestInterrupt();
    }

    fn clearInterrupt(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.agent.clearInterruptRequest();
    }

    fn activeToolName(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.agent.snapshotActiveToolName(allocator);
    }

    fn restore(ptr: *anyopaque, input: port.RestoreInput) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const agent = self.agent;
        // Replaces src/session.zig:182-206 (restorePersistedSessionState):
        // runtime-command rows are replayed as local commands, everything else
        // is appended to history.
        for (input.messages) |entry| {
            if (memory_mod.isRuntimeCommandRole(entry.role)) {
                const maybe_response = agent.handleSlashCommand(entry.content) catch null;
                if (maybe_response) |response| agent.allocator.free(response);
                continue;
            }

            const role: providers.Role = if (std.mem.eql(u8, entry.role, "assistant"))
                .assistant
            else if (std.mem.eql(u8, entry.role, "system"))
                .system
            else
                .user;

            const content = agent.allocator.dupe(u8, entry.content) catch continue;
            agent.history.append(agent.allocator, .{
                .role = role,
                .content = content,
            }) catch {
                agent.allocator.free(content);
                continue;
            };
        }
        agent.total_tokens = input.total_tokens;
        agent.compaction_count = input.compaction_count;
    }

    fn reset(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Replaces src/session.zig:1997.
        agent_mod.commands.clearSessionState(self.agent);
    }

    fn invalidatePrompt(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Replaces src/session.zig:3401.
        self.agent.has_system_prompt = false;
    }

    fn info(ptr: *anyopaque) port.Info {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const agent = self.agent;
        return .{
            .provider_name = agent.provider.getName(),
            .model_name = agent.model_name,
            .workspace_dir = agent.workspace_dir,
            .allowed_paths = agent.allowed_paths,
            .has_own_autonomy = agent.has_own_autonomy,
            .queue_mode = agent.queue_mode,
            .reasoning_mode = agent.reasoning_mode,
            .redactor = agent.redactor,
        };
    }

    fn handleLocalCommand(ptr: *anyopaque, content: []const u8) anyerror!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.agent.handleSlashCommand(content);
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }

    const vtable = Harness.VTable{
        .runTurn = runTurn,
        .requestInterrupt = requestInterrupt,
        .clearInterrupt = clearInterrupt,
        .activeToolName = activeToolName,
        .restore = restore,
        .reset = reset,
        .invalidatePrompt = invalidatePrompt,
        .info = info,
        .handleLocalCommand = handleLocalCommand,
        .deinit = deinit,
    };
};
