const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");
const root = @import("root.zig");
const voice = @import("../voice.zig");
const fs_compat = @import("../fs_compat.zig");
const platform = @import("../platform.zig");
const net_security = @import("../net_security.zig");
const config_types = @import("../config_types.zig");
const telegram = @import("telegram.zig");
const interaction_choices = @import("../interactions/choices.zig");
const control_plane = @import("../control_plane.zig");
const agent_routing = @import("../agent_routing.zig");
const bus_mod = @import("../bus.zig");
const websocket = @import("../websocket.zig");
const stream_presenter = @import("slack_stream_presenter.zig");

const Atomic = @import("../portable_atomic.zig").Atomic;

const log = std.log.scoped(.slack);

const SocketFd = std_compat.net.Stream.Handle;
const invalid_socket: SocketFd = switch (builtin.os.tag) {
    .windows => std_compat.net.invalidHandle(SocketFd),
    else => -1,
};

const CALLBACK_VALUE_PREFIX = "ncslack:";
const DEFAULT_INTERACTION_TTL_SECS: u64 = 900;

const PendingInteractionOption = struct {
    id: []const u8,
    label: []const u8,
    submit_text: []const u8,

    fn deinit(self: *const PendingInteractionOption, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.submit_text);
    }
};

const PendingInteraction = struct {
    allocator: std.mem.Allocator,
    created_at: u64,
    expires_at: u64,
    account_id: []const u8,
    target: []const u8,
    owner_identity: ?[]const u8 = null,
    options: []PendingInteractionOption,

    fn deinit(self: *const PendingInteraction) void {
        self.allocator.free(self.account_id);
        self.allocator.free(self.target);
        if (self.owner_identity) |owner| self.allocator.free(owner);
        for (self.options) |opt| opt.deinit(self.allocator);
        self.allocator.free(self.options);
    }
};

pub const CallbackSelection = union(enum) {
    ok: struct {
        submit_text: []u8,
        target: []u8,
    },
    not_found,
    expired,
    owner_mismatch,
    invalid_option,
};

var shared_interactions_mu: std_compat.sync.Mutex = .{};
var shared_interactions: std.StringHashMapUnmanaged(PendingInteraction) = .empty;
var shared_interaction_seq: Atomic(u64) = Atomic(u64).init(1);

fn sharedInteractionsAllocator() std.mem.Allocator {
    return if (builtin.is_test) std.testing.allocator else std.heap.page_allocator;
}

fn validateChoices(choices: []const root.Channel.OutboundChoice) bool {
    if (choices.len < interaction_choices.MIN_OPTIONS or choices.len > interaction_choices.MAX_OPTIONS) {
        return false;
    }

    for (choices) |choice| {
        if (choice.id.len == 0 or choice.id.len > interaction_choices.MAX_ID_LEN) return false;
        if (choice.label.len == 0 or choice.label.len > interaction_choices.MAX_LABEL_LEN) return false;
        if (choice.submit_text.len == 0 or choice.submit_text.len > interaction_choices.MAX_SUBMIT_TEXT_LEN) return false;
    }

    return true;
}

fn buildThreadStatusRequestBody(
    allocator: std.mem.Allocator,
    channel_id: []const u8,
    thread_ts: []const u8,
    status: []const u8,
) ![]u8 {
    var body_list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body_list.deinit(allocator);
    var body_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &body_list);
    errdefer body_writer.deinit();
    const bw = &body_writer.writer;
    try bw.writeAll("{\"channel_id\":");
    try root.appendJsonStringW(bw, channel_id);
    try bw.writeAll(",\"thread_ts\":");
    try root.appendJsonStringW(bw, thread_ts);
    try bw.writeAll(",\"status\":");
    try root.appendJsonStringW(bw, status);
    try bw.writeByte('}');
    body_list = body_writer.toArrayList();
    return try body_list.toOwnedSlice(allocator);
}

/// Build the JSON body for an ephemeral slash-command reply. Split out of
/// respondToSlashCommand so the encoding is unit-testable without a network call.
fn buildSlashResponseBody(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var body_list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body_list.deinit(allocator);
    var body_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &body_list);
    errdefer body_writer.deinit();
    const bw = &body_writer.writer;
    try bw.writeAll("{\"text\":");
    try root.appendJsonStringW(bw, text);
    try bw.writeAll(",\"response_type\":\"ephemeral\"}");
    body_list = body_writer.toArrayList();
    return try body_list.toOwnedSlice(allocator);
}

/// Recently seen inbound event hashes, used to drop Slack redeliveries.
const SEEN_INBOUND_EVENTS = 256;

/// One unit of inbound work for the worker pool. Message events carry the
/// serialized Slack event; slash commands carry the command text and sender.
const InboundEvent = struct {
    kind: Kind,
    /// Serialized event JSON for `.message`; command text for `.slash`.
    payload: []u8,
    channel_id: []u8,
    /// Slash commands only: the invoking user.
    sender_id: ?[]u8 = null,
    /// Hash of the session key (see `inboundConversationHash`). Events sharing
    /// it are processed in FIFO order while other sessions proceed
    /// concurrently.
    conversation_hash: u64,
    /// Assigned under `inbound_mu` by the producer.
    id: u64 = 0,
    /// Set by the worker that picked the event; keeps later events of the same
    /// conversation from overtaking it.
    claimed: bool = false,

    const Kind = enum { message, slash };

    fn deinit(self: *InboundEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        allocator.free(self.channel_id);
        if (self.sender_id) |sender| allocator.free(sender);
    }
};

/// One worker per conversation keeps FIFO, so a handful of workers let other
/// chats proceed while a file download or transcription blocks one.
const INBOUND_WORKER_COUNT = 4;
/// Total queued inbound events. Past this the socket reader drops the event
/// instead of growing without bound. A per-conversation reply is not sent from
/// the reader: a network call there is exactly what the queue exists to avoid.
const MAX_INBOUND_QUEUE = 256;
/// The Socket Mode reader may wait at most this long for space on the inbound
/// bus before it hands the event to the FIFO instead.
const STOP_PUBLISH_TIMEOUT_MS: u32 = 100;

/// Slack re-delivers an envelope (after a failed ack) with `retry_attempt`
/// set. Return it, or 0 when absent, so a first delivery is always processed.
fn socketRetryAttempt(obj: std.json.ObjectMap) u64 {
    const val = obj.get("retry_attempt") orelse return 0;
    return switch (val) {
        .integer => |n| if (n > 0) @intCast(n) else 0,
        else => 0,
    };
}

/// Slack targets are `channel_id` or `channel_id:thread_ts`; a reaction is
/// keyed by channel only, so the thread suffix is dropped.
fn slackChannelIdOf(target: []const u8) ?[]const u8 {
    if (target.len == 0) return null;
    const idx = std.mem.indexOfScalar(u8, target, ':') orelse return target;
    if (idx == 0) return null;
    return target[0..idx];
}

/// The API calls one lifecycle transition needs. Slack adds reactions instead
/// of replacing them, so the state being left behind has to be removed
/// explicitly; a state that reuses the emoji already on the message needs no
/// call at all.
pub const ReactionPlan = struct {
    removals: [2]?[]const u8 = .{ null, null },
    removals_len: u8 = 0,
    add: ?[]const u8 = null,
};

const superseded_none = [_]root.Channel.TaskReaction{};
const superseded_accepted = [_]root.Channel.TaskReaction{.accepted};
const superseded_running = [_]root.Channel.TaskReaction{ .accepted, .running };

fn supersededReactions(reaction: root.Channel.TaskReaction) []const root.Channel.TaskReaction {
    return switch (reaction) {
        .accepted => &superseded_none,
        .running => &superseded_accepted,
        .done, .failed => &superseded_running,
    };
}

fn reactionEmoji(
    emojis: config_types.SlackReactionEmojisConfig,
    reaction: root.Channel.TaskReaction,
) ?[]const u8 {
    const name = switch (reaction) {
        .accepted => emojis.accepted,
        .running => emojis.running,
        .done => emojis.done,
        .failed => emojis.failed,
    };
    return if (name.len == 0) null else name;
}

/// Pure so the transition table is testable without a network.
pub fn planTaskReaction(
    emojis: config_types.SlackReactionEmojisConfig,
    reaction: root.Channel.TaskReaction,
) ReactionPlan {
    var plan = ReactionPlan{};
    const add = reactionEmoji(emojis, reaction);
    for (supersededReactions(reaction)) |previous| {
        const emoji = reactionEmoji(emojis, previous) orelse continue;
        if (add) |next| {
            if (std.mem.eql(u8, next, emoji)) continue;
        }
        var seen = false;
        for (plan.removals[0..plan.removals_len]) |existing| {
            if (existing) |already| {
                if (std.mem.eql(u8, already, emoji)) seen = true;
            }
        }
        if (seen) continue;
        plan.removals[plan.removals_len] = emoji;
        plan.removals_len += 1;
    }
    plan.add = add;
    return plan;
}

fn buildReactionRequestBody(
    allocator: std.mem.Allocator,
    channel_id: []const u8,
    ts: []const u8,
    emoji: []const u8,
) ![]u8 {
    var body_list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body_list.deinit(allocator);
    var body_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &body_list);
    errdefer body_writer.deinit();
    const bw = &body_writer.writer;
    try bw.writeAll("{\"channel\":");
    try root.appendJsonStringW(bw, channel_id);
    try bw.writeAll(",\"timestamp\":");
    try root.appendJsonStringW(bw, ts);
    try bw.writeAll(",\"name\":");
    try root.appendJsonStringW(bw, emoji);
    try bw.writeByte('}');
    body_list = body_writer.toArrayList();
    return try body_list.toOwnedSlice(allocator);
}

/// Slack channel — socket/http event pipeline for inbound, chat.postMessage for outbound.
pub const SlackChannel = struct {
    allocator: std.mem.Allocator,
    account_id: []const u8 = "default",
    mode: config_types.SlackReceiveMode = .socket,
    bot_token: []const u8,
    app_token: ?[]const u8,
    signing_secret: ?[]const u8 = null,
    webhook_path: []const u8 = "/slack/events",
    channel_id: ?[]const u8,
    allow_from: []const []const u8,
    last_ts: []const u8,
    last_ts_owned: bool = false,
    last_ts_by_channel: std.StringHashMapUnmanaged([]u8) = .empty,
    thread_ts: ?[]const u8 = null,
    reply_to_mode: config_types.SlackReplyToMode = .off,
    /// Shared audio transcription pipeline (tools.media.audio), installed by
    /// ChannelManager. Slack has no poller of its own to install it per-loop.
    audio_media: config_types.AudioMediaConfig = .{},
    audio_provider_key: ?[]const u8 = null,
    transcriber: ?voice.Transcriber = null,
    owned_transcriber: ?*voice.WhisperTranscriber = null,
    /// Test seam: replaces the network fetch in `downloadSlackFile` so the
    /// inbound marker/temp-file pipeline is covered without network access.
    file_fetch_override: ?*const fn (std.mem.Allocator, SlackFileInfo) ?[]u8 = null,
    /// Emit progressive replies through the streaming Web API / edited messages.
    streaming_enabled: bool = false,
    /// Set once a chat.startStream call proves this app/workspace can never
    /// stream; every later turn uses the chat.postMessage + chat.update path.
    native_stream_disabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Show task lifecycle on the triggering message via reactions.add/remove.
    status_reactions_enabled: bool = false,
    reaction_emojis: config_types.SlackReactionEmojisConfig = .{},
    /// Set once the API proves this app can never react (`missing_scope` and
    /// friends); later turns skip the calls entirely.
    reactions_disabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Guards `stream_states` and the API calls made from it.
    stream_mu: std_compat.sync.Mutex = .{},
    stream_states: std.StringHashMapUnmanaged(stream_presenter.StreamState) = .empty,
    /// Targets whose current turn was stopped. Queued `.chunk` events for them
    /// are dropped so a stopped turn's leftovers cannot replay once the
    /// outbound dispatcher catches up. Keyed by the exact outbound target and
    /// expiring after the late-chunk grace window. Guarded by `stream_mu`.
    stream_cancels: std.StringHashMapUnmanaged(i64) = .empty,
    policy: root.ChannelPolicy = .{},
    /// Session DM scope and identity links mirrored from the daemon config.
    /// The inbound FIFO hash keys DMs by the routed session, not the raw
    /// sender, so peers that share a session cannot run concurrently.
    dm_scope: config_types.DmScope = .per_channel_peer,
    identity_links: []const config_types.IdentityLink = &.{},
    bus: ?*bus_mod.Bus = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    connected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    socket_fallback_to_polling: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    lifecycle_mu: std_compat.sync.Mutex = .{},
    poll_thread: ?std.Thread = null,
    socket_thread: ?std.Thread = null,
    socket_mu: std_compat.sync.Mutex = .{},
    /// Socket Mode events are handed to this pool so inbound file downloads
    /// and transcription never run on the websocket reader thread (which also
    /// has to keep answering pings and acking queued envelopes).
    inbound_mu: std_compat.sync.Mutex = .{},
    inbound_cond: std_compat.sync.Condition = .{},
    inbound_queue: std.ArrayListUnmanaged(InboundEvent) = .empty,
    inbound_threads: [INBOUND_WORKER_COUNT]?std.Thread = [_]?std.Thread{null} ** INBOUND_WORKER_COUNT,
    inbound_next_id: u64 = 1,
    inbound_stop: bool = false,
    /// Bounded ring of recently seen event hashes (redelivery dedupe).
    inbound_seen: [SEEN_INBOUND_EVENTS]u64 = [_]u64{0} ** SEEN_INBOUND_EVENTS,
    inbound_seen_count: usize = 0,
    inbound_seen_next: usize = 0,
    /// Test seam: counts native chat.stopStream calls (the API is stubbed).
    test_native_stop_calls: if (builtin.is_test) u32 else void = if (builtin.is_test) 0 else {},
    ws_fd: std.atomic.Value(SocketFd) = std.atomic.Value(SocketFd).init(invalid_socket),
    bot_user_id: ?[]u8 = null,
    bot_team_id: ?[]u8 = null,
    bot_api_app_id: ?[]u8 = null,
    slash_command_enabled: bool = false,
    slash_command_name: []const u8 = "nullclaw",

    pub const API_BASE = "https://slack.com/api";
    pub const DEFAULT_WEBHOOK_PATH = "/slack/events";
    pub const RECONNECT_DELAY_NS: u64 = 5 * std.time.ns_per_s;
    pub const POLL_INTERVAL_SECS: u64 = 3;
    pub const POLL_THREAD_STACK_SIZE: usize = 2 * 1024 * 1024;
    pub const SOCKET_THREAD_STACK_SIZE: usize = 2 * 1024 * 1024;
    pub const SOCKET_FAILURE_FALLBACK_THRESHOLD: u32 = 3;
    pub const TOKEN_TRIM_CHARS = " \t\r\n";

    pub fn init(
        allocator: std.mem.Allocator,
        bot_token: []const u8,
        app_token: ?[]const u8,
        channel_id: ?[]const u8,
        allow_from: []const []const u8,
    ) SlackChannel {
        return .{
            .allocator = allocator,
            .bot_token = bot_token,
            .app_token = app_token,
            .channel_id = channel_id,
            .allow_from = allow_from,
            .last_ts = "0",
        };
    }

    fn parseDmPolicy(raw: []const u8) root.DmPolicy {
        if (std.mem.eql(u8, raw, "allow")) return .allow;
        if (std.mem.eql(u8, raw, "deny")) return .deny;
        if (std.mem.eql(u8, raw, "allowlist") or std.mem.eql(u8, raw, "pairing")) return .allowlist;
        return .allowlist;
    }

    fn parseGroupPolicy(raw: []const u8) root.GroupPolicy {
        if (std.mem.eql(u8, raw, "open")) return .open;
        if (std.mem.eql(u8, raw, "allowlist")) return .allowlist;
        return .mention_only;
    }

    pub fn normalizeWebhookPath(raw: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return DEFAULT_WEBHOOK_PATH;
        if (trimmed[0] != '/') return DEFAULT_WEBHOOK_PATH;
        return trimmed;
    }

    pub fn initWithPolicy(
        allocator: std.mem.Allocator,
        bot_token: []const u8,
        app_token: ?[]const u8,
        channel_id: ?[]const u8,
        allow_from: []const []const u8,
        policy: root.ChannelPolicy,
    ) SlackChannel {
        return .{
            .allocator = allocator,
            .bot_token = bot_token,
            .app_token = app_token,
            .channel_id = channel_id,
            .allow_from = allow_from,
            .last_ts = "0",
            .policy = policy,
        };
    }

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.SlackConfig) SlackChannel {
        const policy = root.ChannelPolicy{
            .dm = parseDmPolicy(cfg.dm_policy),
            .group = parseGroupPolicy(cfg.group_policy),
            .allowlist = cfg.allow_from,
        };
        var ch = initWithPolicy(
            allocator,
            cfg.bot_token,
            cfg.app_token,
            cfg.channel_id,
            cfg.allow_from,
            policy,
        );
        ch.account_id = cfg.account_id;
        ch.mode = cfg.mode;
        ch.signing_secret = cfg.signing_secret;
        ch.webhook_path = normalizeWebhookPath(cfg.webhook_path);
        ch.reply_to_mode = cfg.reply_to_mode;
        ch.slash_command_enabled = cfg.slash_command.enabled;
        ch.slash_command_name = if (cfg.slash_command.name.len == 0) "nullclaw" else cfg.slash_command.name;
        ch.streaming_enabled = cfg.streaming;
        ch.status_reactions_enabled = cfg.status_reactions;
        ch.reaction_emojis = cfg.reaction_emojis;
        return ch;
    }

    /// React to the message that triggered a task, mirroring the Telegram
    /// lifecycle. Best-effort: a failure is logged, never propagated.
    pub fn setTaskReaction(
        self: *SlackChannel,
        target: []const u8,
        message_id: ?[]const u8,
        reaction: root.Channel.TaskReaction,
    ) void {
        if (!self.status_reactions_enabled) return;
        if (self.reactions_disabled.load(.acquire)) return;
        const ts = message_id orelse return;
        const channel_id = slackChannelIdOf(target) orelse return;
        if (ts.len == 0) return;

        const plan = planTaskReaction(self.reaction_emojis, reaction);
        for (plan.removals[0..plan.removals_len]) |removal| {
            if (removal) |emoji| self.callReactionApi("reactions.remove", channel_id, ts, emoji);
        }
        if (plan.add) |emoji| self.callReactionApi("reactions.add", channel_id, ts, emoji);
    }

    fn callReactionApi(
        self: *SlackChannel,
        endpoint: []const u8,
        channel_id: []const u8,
        ts: []const u8,
        emoji: []const u8,
    ) void {
        const body = buildReactionRequestBody(self.allocator, channel_id, ts, emoji) catch return;
        defer self.allocator.free(body);

        var result = self.callSlackApi(endpoint, body, channel_id) catch |err| {
            log.debug("Slack {s} failed: {}", .{ endpoint, err });
            return;
        };
        defer result.deinit(self.allocator);

        const code = result.error_code orelse return;
        // The reaction is already in the wanted state.
        if (std.mem.eql(u8, code, "already_reacted") or std.mem.eql(u8, code, "no_reaction")) return;
        if (isAuthFailureCode(code)) {
            if (!self.reactions_disabled.swap(true, .acq_rel)) {
                log.warn(
                    "Slack status reactions unavailable for this app ({s}); disabling them for {s}",
                    .{ code, self.account_id },
                );
            }
        }
    }

    /// Set the thread timestamp for threaded replies.
    pub fn setThreadTs(self: *SlackChannel, ts: ?[]const u8) void {
        self.thread_ts = ts;
    }

    /// Parse a target string, splitting "channel_id:thread_ts" if colon-separated.
    /// Returns the channel ID and optionally sets thread_ts on the instance.
    pub fn parseTarget(self: *SlackChannel, target: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, target, ':')) |idx| {
            const parsed_thread = target[idx + 1 ..];
            self.thread_ts = if (parsed_thread.len > 0) parsed_thread else null;
            return target[0..idx];
        }
        self.thread_ts = null;
        return target;
    }

    pub fn channelName(_: *SlackChannel) []const u8 {
        return "slack";
    }

    pub fn setBus(self: *SlackChannel, b: *bus_mod.Bus) void {
        self.bus = b;
    }

    pub fn isUserAllowed(self: *const SlackChannel, sender: []const u8) bool {
        return root.isAllowedScoped("slack channel", self.allow_from, sender);
    }

    /// Check if an incoming message should be handled based on the channel policy.
    /// `sender_id`: the Slack user ID of the message sender.
    /// `is_dm`: true if the message is a direct message (IM channel).
    /// `message_text`: the raw message text (used to detect bot mention).
    /// `bot_user_id`: the bot's own Slack user ID (for mention detection).
    pub fn shouldHandle(self: *const SlackChannel, sender_id: []const u8, is_dm: bool, message_text: []const u8, bot_user_id: ?[]const u8) bool {
        const is_mention = if (bot_user_id) |bid| containsMention(message_text, bid) else false;
        return root.checkPolicyScoped("slack channel", self.policy, sender_id, is_dm, is_mention);
    }

    pub fn healthCheck(self: *SlackChannel) bool {
        if (!self.running.load(.acquire)) return false;
        return switch (self.mode) {
            .http => true,
            .socket => (self.connected.load(.acquire) and self.socket_thread != null) or self.poll_thread != null,
        };
    }

    fn shutdownActiveSocket(self: *SlackChannel) void {
        self.socket_mu.lock();
        defer self.socket_mu.unlock();
        websocket.shutdownTrackedSocket(&self.ws_fd, invalid_socket, .both);
    }

    fn closeOwnedSocket(self: *SlackChannel, ws: *websocket.WsClient) void {
        self.socket_mu.lock();
        defer self.socket_mu.unlock();
        websocket.shutdownTrackedSocket(&self.ws_fd, invalid_socket, .both);
        ws.deinit();
    }

    fn closeOwnedSocketStream(self: *SlackChannel, stream: std_compat.net.Stream) void {
        self.socket_mu.lock();
        defer self.socket_mu.unlock();
        websocket.shutdownTrackedSocket(&self.ws_fd, invalid_socket, .both);
        stream.close();
    }

    fn publishSocket(self: *SlackChannel, fd: SocketFd) bool {
        self.socket_mu.lock();
        defer self.socket_mu.unlock();
        self.ws_fd.store(fd, .release);
        if (self.running.load(.acquire)) return true;
        websocket.shutdownTrackedSocket(&self.ws_fd, invalid_socket, .both);
        return false;
    }

    fn setLastTs(self: *SlackChannel, ts: []const u8) !void {
        if (self.last_ts_owned) {
            self.allocator.free(self.last_ts);
            self.last_ts_owned = false;
        }
        self.last_ts = try self.allocator.dupe(u8, ts);
        self.last_ts_owned = true;
    }

    fn channelLastTs(self: *const SlackChannel, channel_id: []const u8) []const u8 {
        if (self.last_ts_by_channel.get(channel_id)) |ts| return ts;
        if (self.channel_id) |configured| {
            const cfg_trimmed = std.mem.trim(u8, configured, " \t\r\n");
            if (std.mem.indexOfScalar(u8, configured, ',') == null and std.mem.eql(u8, cfg_trimmed, channel_id)) {
                return self.last_ts;
            }
        }
        return "0";
    }

    fn setChannelLastTs(self: *SlackChannel, channel_id: []const u8, ts: []const u8) !void {
        if (self.channel_id) |configured| {
            const cfg_trimmed = std.mem.trim(u8, configured, " \t\r\n");
            if (std.mem.indexOfScalar(u8, configured, ',') == null and std.mem.eql(u8, cfg_trimmed, channel_id)) {
                return self.setLastTs(ts);
            }
        }

        if (self.last_ts_by_channel.getEntry(channel_id)) |entry| {
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = try self.allocator.dupe(u8, ts);
            return;
        }

        const key_copy = try self.allocator.dupe(u8, channel_id);
        errdefer self.allocator.free(key_copy);
        const ts_copy = try self.allocator.dupe(u8, ts);
        errdefer self.allocator.free(ts_copy);
        try self.last_ts_by_channel.put(self.allocator, key_copy, ts_copy);
    }

    fn clearChannelCursors(self: *SlackChannel) void {
        var it = self.last_ts_by_channel.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.last_ts_by_channel.deinit(self.allocator);
        self.last_ts_by_channel = .empty;
    }

    fn parseTs(ts: []const u8) f64 {
        return std.fmt.parseFloat(f64, ts) catch 0.0;
    }

    const SlackApiErrorInfo = struct {
        code: []const u8,
        needed: ?[]const u8 = null,
        provided: ?[]const u8 = null,
    };

    /// Owned `ts` / `error` fields of a Slack Web API response.
    const SlackApiResult = struct {
        ts: ?[]u8 = null,
        error_code: ?[]u8 = null,
        /// files.getUploadURLExternal ticket fields.
        upload_url: ?[]u8 = null,
        file_id: ?[]u8 = null,

        pub fn deinit(self: *SlackApiResult, allocator: std.mem.Allocator) void {
            if (self.ts) |ts| allocator.free(ts);
            if (self.error_code) |code| allocator.free(code);
            if (self.upload_url) |url| allocator.free(url);
            if (self.file_id) |id| allocator.free(id);
            self.* = .{};
        }

        pub fn takeTs(self: *SlackApiResult) ?[]u8 {
            const ts = self.ts;
            self.ts = null;
            return ts;
        }
    };

    fn slackApiErrorInfo(obj: std.json.ObjectMap) ?SlackApiErrorInfo {
        const err_val = obj.get("error") orelse return null;
        if (err_val != .string or err_val.string.len == 0) return null;

        var info = SlackApiErrorInfo{
            .code = err_val.string,
        };
        if (obj.get("needed")) |needed_val| {
            if (needed_val == .string and needed_val.string.len > 0) info.needed = needed_val.string;
        }
        if (obj.get("provided")) |provided_val| {
            if (provided_val == .string and provided_val.string.len > 0) info.provided = provided_val.string;
        }
        return info;
    }

    fn isAuthFailureCode(code: []const u8) bool {
        return std.mem.eql(u8, code, "invalid_auth") or
            std.mem.eql(u8, code, "not_authed") or
            std.mem.eql(u8, code, "account_inactive") or
            std.mem.eql(u8, code, "token_revoked") or
            std.mem.eql(u8, code, "missing_scope") or
            std.mem.eql(u8, code, "not_allowed_token_type") or
            std.mem.eql(u8, code, "no_permission");
    }

    fn logSlackApiError(endpoint: []const u8, context: ?[]const u8, info: SlackApiErrorInfo) void {
        if (context) |ctx| {
            if (info.needed) |needed| {
                if (info.provided) |provided| {
                    log.warn("Slack {s} API error ({s}): {s} (needed={s}, provided={s})", .{ endpoint, ctx, info.code, needed, provided });
                } else {
                    log.warn("Slack {s} API error ({s}): {s} (needed={s})", .{ endpoint, ctx, info.code, needed });
                }
            } else {
                log.warn("Slack {s} API error ({s}): {s}", .{ endpoint, ctx, info.code });
            }
            return;
        }

        if (info.needed) |needed| {
            if (info.provided) |provided| {
                log.warn("Slack {s} API error: {s} (needed={s}, provided={s})", .{ endpoint, info.code, needed, provided });
            } else {
                log.warn("Slack {s} API error: {s} (needed={s})", .{ endpoint, info.code, needed });
            }
        } else {
            log.warn("Slack {s} API error: {s}", .{ endpoint, info.code });
        }
    }

    fn ensureSlackApiOk(obj: std.json.ObjectMap, endpoint: []const u8, context: ?[]const u8) !void {
        const ok_val = obj.get("ok") orelse return error.SlackApiError;
        if (ok_val == .bool and ok_val.bool) return;

        if (slackApiErrorInfo(obj)) |info| {
            logSlackApiError(endpoint, context, info);
            if (isAuthFailureCode(info.code)) return error.SlackAuthFailed;
        }
        return error.SlackApiError;
    }

    fn hasValidBotToken(self: *const SlackChannel) bool {
        return self.normalizedBotToken().len > 0;
    }

    fn isDirectConversationId(channel_id: []const u8) bool {
        return channel_id.len > 0 and channel_id[0] == 'D';
    }

    /// Strip a leading `/` and surrounding whitespace from a slash command name.
    fn normalizeSlashCommandName(raw: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0 and trimmed[0] == '/') return std.mem.trim(u8, trimmed[1..], " \t\r\n");
        return trimmed;
    }

    /// Compare a configured slash command name with the one Slack delivered,
    /// ignoring a leading `/` and case.
    fn slashCommandNameMatches(configured: []const u8, incoming: []const u8) bool {
        const want = normalizeSlashCommandName(configured);
        const got = normalizeSlashCommandName(incoming);
        if (want.len == 0 or got.len == 0) return false;
        return std.ascii.eqlIgnoreCase(want, got);
    }

    fn normalizedBotToken(self: *const SlackChannel) []const u8 {
        return std.mem.trim(u8, self.bot_token, TOKEN_TRIM_CHARS);
    }

    fn normalizedAppToken(self: *const SlackChannel) ?[]const u8 {
        const app_token = self.app_token orelse return null;
        const trimmed = std.mem.trim(u8, app_token, TOKEN_TRIM_CHARS);
        if (trimmed.len == 0) return null;
        return trimmed;
    }

    fn parseApiAppIdFromAppToken(raw: []const u8) ?[]const u8 {
        const token = std.mem.trim(u8, raw, TOKEN_TRIM_CHARS);
        if (token.len == 0) return null;

        var parts = std.mem.splitScalar(u8, token, '-');
        const prefix = parts.next() orelse return null;
        if (!std.ascii.eqlIgnoreCase(prefix, "xapp")) return null;

        const version = parts.next() orelse return null;
        if (version.len == 0) return null;
        for (version) |ch| {
            if (!std.ascii.isDigit(ch)) return null;
        }

        const api_app_id = parts.next() orelse return null;
        if (api_app_id.len == 0) return null;
        for (api_app_id) |ch| {
            if (!std.ascii.isAlphanumeric(ch)) return null;
        }
        const remainder = parts.next() orelse return null;
        if (remainder.len == 0) return null;
        return api_app_id;
    }

    fn ensureSocketTokenPairMatches(self: *const SlackChannel) !void {
        if (self.mode != .socket) return;
        const app_token = self.normalizedAppToken() orelse return;
        const bot_api_app_id = self.bot_api_app_id orelse return;
        const expected_api_app_id = parseApiAppIdFromAppToken(app_token) orelse return;
        if (std.ascii.eqlIgnoreCase(bot_api_app_id, expected_api_app_id)) return;

        const mismatch_fmt = "Slack token mismatch: bot_token api_app_id={s} but app_token api_app_id={s}";
        if (builtin.is_test) {
            log.warn(mismatch_fmt, .{ bot_api_app_id, expected_api_app_id });
        } else {
            log.err(mismatch_fmt, .{ bot_api_app_id, expected_api_app_id });
        }
        return error.SlackAuthFailed;
    }

    fn shouldDropMismatchedSocketEvent(self: *const SlackChannel, payload_obj: std.json.ObjectMap) bool {
        const incoming_api_app_id = if (payload_obj.get("api_app_id")) |api_app_id_val|
            if (api_app_id_val == .string and api_app_id_val.string.len > 0) api_app_id_val.string else null
        else
            null;
        const incoming_team_id = if (payload_obj.get("team_id")) |team_id_val|
            if (team_id_val == .string and team_id_val.string.len > 0) team_id_val.string else null
        else
            null;

        if (self.bot_api_app_id) |expected_api_app_id| {
            if (incoming_api_app_id) |actual_api_app_id| {
                if (!std.ascii.eqlIgnoreCase(expected_api_app_id, actual_api_app_id)) {
                    log.warn(
                        "Slack socket event dropped: api_app_id={s} expected={s}",
                        .{ actual_api_app_id, expected_api_app_id },
                    );
                    return true;
                }
            }
        }

        if (self.bot_team_id) |expected_team_id| {
            if (incoming_team_id) |actual_team_id| {
                if (!std.mem.eql(u8, expected_team_id, actual_team_id)) {
                    log.warn(
                        "Slack socket event dropped: team_id={s} expected={s}",
                        .{ actual_team_id, expected_team_id },
                    );
                    return true;
                }
            }
        }

        return false;
    }

    fn fetchBotUserId(self: *SlackChannel) !void {
        if (builtin.is_test) return;
        const url = API_BASE ++ "/auth.test";
        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.normalizedBotToken()});
        defer self.allocator.free(auth_header);
        const headers = [_][]const u8{auth_header};
        const resp = root.http_util.curlGet(self.allocator, url, &headers, "15") catch return error.SlackApiError;
        defer self.allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return error.SlackApiError;
        defer parsed.deinit();
        if (parsed.value != .object) return error.SlackApiError;
        try ensureSlackApiOk(parsed.value.object, "auth.test", null);
        const uid_val = parsed.value.object.get("user_id") orelse return error.SlackApiError;
        if (uid_val != .string or uid_val.string.len == 0) return error.SlackApiError;
        const team_id = if (parsed.value.object.get("team_id")) |team_id_val|
            if (team_id_val == .string and team_id_val.string.len > 0) team_id_val.string else null
        else
            null;
        const api_app_id = if (parsed.value.object.get("api_app_id")) |api_app_id_val|
            if (api_app_id_val == .string and api_app_id_val.string.len > 0) api_app_id_val.string else null
        else
            null;

        if (self.bot_user_id) |old| self.allocator.free(old);
        self.bot_user_id = try self.allocator.dupe(u8, uid_val.string);
        if (self.bot_team_id) |old| self.allocator.free(old);
        self.bot_team_id = if (team_id) |value| try self.allocator.dupe(u8, value) else null;
        if (self.bot_api_app_id) |old| self.allocator.free(old);
        self.bot_api_app_id = if (api_app_id) |value| try self.allocator.dupe(u8, value) else null;
    }

    fn processHistoryMessage(
        self: *SlackChannel,
        msg_obj: std.json.ObjectMap,
        channel_id: []const u8,
    ) !void {
        const subtype = if (msg_obj.get("subtype")) |sub_val|
            if (sub_val == .string) sub_val.string else ""
        else
            "";
        // Regression: every subtype was dropped, so Slack `file_share` messages
        // (images, audio clips, PDFs) never reached the agent at all. Other
        // subtypes (edits, joins, deletions) still have no reply semantics.
        const is_file_share = std.mem.eql(u8, subtype, "file_share");
        if (subtype.len > 0 and !is_file_share) return;

        const user_val = msg_obj.get("user") orelse return;
        if (user_val != .string or user_val.string.len == 0) return;
        const sender_id = user_val.string;
        if (self.bot_user_id) |bot_uid| {
            if (std.mem.eql(u8, sender_id, bot_uid)) return;
        }

        const text = if (msg_obj.get("text")) |text_val|
            if (text_val == .string) std.mem.trim(u8, text_val.string, " \t\r\n") else ""
        else
            "";
        // Some integrations attach files without the `file_share` subtype.
        const has_files = messageHasFiles(msg_obj);
        if (text.len == 0 and !has_files) return;
        const message_ts = if (msg_obj.get("ts")) |ts_val| switch (ts_val) {
            .string => |s| if (s.len > 0) s else null,
            else => null,
        } else null;
        const thread_ts = if (msg_obj.get("thread_ts")) |thread_ts_val| switch (thread_ts_val) {
            .string => |s| if (s.len > 0) s else null,
            else => null,
        } else null;

        const is_dm = isDirectConversationId(channel_id);
        // Policy is checked against the raw text: mention_only requires the
        // mention. Publishing strips a leading bot mention so a "<@BOT> /stop"
        // that had to queue behind earlier work is still a command for the
        // daemon (the stop fast path already strips it).
        if (!self.shouldHandle(sender_id, is_dm, text, self.bot_user_id)) return;
        const publish_text = if (self.bot_user_id) |bot_uid|
            stripLeadingMention(text, bot_uid) orelse text
        else
            text;

        const file_content = if (has_files)
            try self.buildFileShareContent(self.allocator, msg_obj, publish_text)
        else
            null;
        defer if (file_content) |owned| self.allocator.free(owned);
        const content = file_content orelse publish_text;
        if (content.len == 0) return;

        try self.publishInboundMessage(sender_id, channel_id, content, message_ts, thread_ts);
    }

    /// True when this event was already processed. Slack redelivers an event
    /// (same `event_id`, or `client_msg_id`/`ts` for older payloads) when the
    /// envelope ack was lost; processing it again would duplicate the turn.
    /// Every available key is checked: the same post can arrive as both
    /// `app_mention` and `message.channels` with different event_ids.
    fn inboundEventAlreadySeen(self: *SlackChannel, payload_obj: std.json.ObjectMap, event_obj: std.json.ObjectMap) bool {
        var seen = false;
        if (jsonStringValue(payload_obj, "event_id")) |event_id| {
            if (self.markInboundSeen(std.hash.Wyhash.hash(0, event_id))) seen = true;
        }
        if (jsonStringValue(event_obj, "client_msg_id")) |client_msg_id| {
            if (self.markInboundSeen(std.hash.Wyhash.hash(0, client_msg_id))) seen = true;
        }
        if (jsonStringValue(event_obj, "ts")) |ts| {
            if (jsonStringValue(event_obj, "channel")) |channel_id| {
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(channel_id);
                hasher.update(":");
                hasher.update(ts);
                if (self.markInboundSeen(hasher.final())) seen = true;
            }
        }
        return seen;
    }

    fn markInboundSeen(self: *SlackChannel, hash: u64) bool {
        // Never store 0 so the zero-filled table reads as empty.
        const tag = hash | 1;
        for (self.inbound_seen[0..self.inbound_seen_count]) |seen| {
            if (seen == tag) return true;
        }
        self.inbound_seen[self.inbound_seen_next] = tag;
        self.inbound_seen_next = (self.inbound_seen_next + 1) % SEEN_INBOUND_EVENTS;
        if (self.inbound_seen_count < SEEN_INBOUND_EVENTS) self.inbound_seen_count += 1;
        return false;
    }

    /// Hand an owned event to the worker pool. Takes ownership of the event,
    /// including on failure.
    fn enqueueInboundEvent(self: *SlackChannel, event: InboundEvent) !void {
        var owned = event;
        self.inbound_mu.lock();
        defer self.inbound_mu.unlock();

        if (self.inbound_stop or !self.ensureInboundWorkersLocked()) {
            owned.deinit(self.allocator);
            return error.SlackInboundWorkerUnavailable;
        }
        if (self.inbound_queue.items.len >= MAX_INBOUND_QUEUE) {
            log.warn("Slack inbound queue full ({d}); dropping event for channel {s}", .{ MAX_INBOUND_QUEUE, owned.channel_id });
            owned.deinit(self.allocator);
            return error.SlackInboundQueueFull;
        }
        owned.id = self.inbound_next_id;
        self.inbound_next_id +%= 1;
        self.inbound_queue.append(self.allocator, owned) catch |err| {
            owned.deinit(self.allocator);
            return err;
        };
        self.inbound_cond.broadcast();
    }

    /// Spawn any missing pool worker. Called with `inbound_mu` held.
    fn ensureInboundWorkersLocked(self: *SlackChannel) bool {
        for (&self.inbound_threads) |*slot| {
            if (slot.* != null) continue;
            slot.* = std.Thread.spawn(
                .{ .stack_size = SOCKET_THREAD_STACK_SIZE },
                inboundWorkerLoop,
                .{self},
            ) catch |err| {
                log.warn("Slack inbound worker spawn failed: {}", .{err});
                return false;
            };
        }
        return true;
    }

    /// True when this conversation already has an event in the inbound FIFO
    /// (queued or claimed). The typed-/stop fast path must not overtake it;
    /// see `maybePublishStopMessage`.
    fn hasQueuedInboundFor(self: *SlackChannel, conversation_hash: u64) bool {
        self.inbound_mu.lock();
        defer self.inbound_mu.unlock();
        for (self.inbound_queue.items) |event| {
            if (event.conversation_hash == conversation_hash) return true;
        }
        return false;
    }

    /// Pick the oldest event whose conversation has no in-flight event. Called
    /// with `inbound_mu` held; the event stays queued (claimed) until its worker
    /// finishes, so other workers can see the conversation is busy.
    fn takeInboundEventLocked(self: *SlackChannel) ?InboundEvent {
        if (self.inbound_stop) return null;
        for (self.inbound_queue.items) |*candidate| {
            if (candidate.claimed) continue;
            var busy = false;
            for (self.inbound_queue.items) |other| {
                if (other.claimed and other.conversation_hash == candidate.conversation_hash) {
                    busy = true;
                    break;
                }
            }
            if (busy) continue;
            candidate.claimed = true;
            return candidate.*;
        }
        return null;
    }

    fn removeInboundEventLocked(self: *SlackChannel, id: u64) void {
        for (self.inbound_queue.items, 0..) |candidate, idx| {
            if (candidate.id == id) {
                _ = self.inbound_queue.orderedRemove(idx);
                return;
            }
        }
    }

    fn inboundWorkerLoop(self: *SlackChannel) void {
        while (true) {
            self.inbound_mu.lock();
            const picked = self.takeInboundEventLocked();
            if (picked == null) {
                if (self.inbound_stop) {
                    self.inbound_mu.unlock();
                    return;
                }
                self.inbound_cond.wait(&self.inbound_mu);
                self.inbound_mu.unlock();
                continue;
            }
            self.inbound_mu.unlock();

            var event = picked.?;
            defer {
                self.inbound_mu.lock();
                self.removeInboundEventLocked(event.id);
                self.inbound_cond.broadcast();
                self.inbound_mu.unlock();
                event.deinit(self.allocator);
            }

            switch (event.kind) {
                .message => {
                    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, event.payload, .{}) catch continue;
                    defer parsed.deinit();
                    if (parsed.value != .object) continue;
                    self.processHistoryMessage(parsed.value.object, event.channel_id) catch |err| {
                        log.warn("Slack inbound event processing failed: {}", .{err});
                    };
                },
                .slash => {
                    const sender = event.sender_id orelse continue;
                    self.publishInboundMessage(sender, event.channel_id, event.payload, null, null) catch |err| {
                        log.warn("Slack slash command publish failed: {}", .{err});
                    };
                },
            }
        }
    }

    /// Test seam: wait until the inbound pool has drained every queued event.
    fn waitForInboundIdle(self: *SlackChannel) void {
        self.inbound_mu.lock();
        defer self.inbound_mu.unlock();
        while (self.inbound_queue.items.len > 0) {
            self.inbound_cond.wait(&self.inbound_mu);
        }
    }

    /// Build inbound content for a `file_share` message. Each downloadable file
    /// becomes the same marker the Telegram inbound pipeline emits (`[IMAGE:]`,
    /// `[FILE:]`, `[Voice]:`); files that cannot be fetched stay as metadata so
    /// the model still knows what was attached. The caption is appended.
    fn buildFileShareContent(
        self: *SlackChannel,
        allocator: std.mem.Allocator,
        msg_obj: std.json.ObjectMap,
        text: []const u8,
    ) !?[]u8 {
        const files_val = msg_obj.get("files") orelse return null;
        if (files_val != .array or files_val.array.items.len == 0) return null;

        self.sweepInboundTempFiles();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        var count: usize = 0;
        for (files_val.array.items) |file_val| {
            if (count >= MAX_INBOUND_FILES) break;
            if (file_val != .object) continue;
            const info = parseSlackFileInfo(file_val.object) orelse continue;
            count += 1;

            const marker = try self.buildFileMarker(allocator, info);
            defer allocator.free(marker);
            if (out.items.len > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, marker);
        }

        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) {
            if (out.items.len > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, trimmed);
        }
        if (out.items.len == 0) {
            out.deinit(allocator);
            return null;
        }
        return try out.toOwnedSlice(allocator);
    }

    fn buildFileMarker(self: *SlackChannel, allocator: std.mem.Allocator, info: SlackFileInfo) ![]u8 {
        const kind = classifySlackFile(info);
        if (self.downloadSlackFile(allocator, info)) |path| {
            defer allocator.free(path);
            switch (kind) {
                .image => return std.fmt.allocPrint(allocator, "[IMAGE:{s}]", .{path}),
                .file => return std.fmt.allocPrint(allocator, "[FILE:{s}]", .{path}),
                .audio => {
                    if (self.transcribeSlackAudio(allocator, path)) |transcript| {
                        defer allocator.free(transcript);
                        return std.fmt.allocPrint(allocator, "[Voice]: {s}", .{transcript});
                    }
                    return buildSlackAttachmentMetadata(allocator, "audio", info);
                },
            }
        }
        return buildSlackAttachmentMetadata(allocator, kindLabel(kind), info);
    }

    /// Download a Slack-hosted file with the bot token. `url_private` only
    /// works with that token, so the host is pinned to Slack's own domains to
    /// keep the credential from following an attacker-controlled URL.
    fn downloadSlackFile(self: *SlackChannel, allocator: std.mem.Allocator, info: SlackFileInfo) ?[]u8 {
        if (self.file_fetch_override) |fetch| {
            const data = fetch(allocator, info) orelse return null;
            defer allocator.free(data);
            if (data.len == 0 or looksLikeHtml(data)) return null;
            return saveSlackTempFile(allocator, info, data);
        }
        if (builtin.is_test) return null;
        if (info.url_private.len == 0) return null;
        if (!isAllowedSlackFileUrl(info.url_private)) {
            log.warn("Slack inbound file skipped: untrusted url_private host", .{});
            return null;
        }
        if (info.size) |size| {
            if (size > MAX_INBOUND_FILE_BYTES) {
                log.warn("Slack inbound file skipped: {d} bytes exceeds the {d}-byte cap", .{ size, MAX_INBOUND_FILE_BYTES });
                return null;
            }
        }

        var auth_buf: [512]u8 = undefined;
        var auth_writer: std.Io.Writer = .fixed(&auth_buf);
        auth_writer.print("Authorization: Bearer {s}", .{self.normalizedBotToken()}) catch return null;
        const auth_header = auth_writer.buffered();

        // Regression: `curlGetMaxBytes` silently falls back to the untimed
        // std.http client for a credentialed GET, so a stalled download could
        // block the Slack socket reader forever and the size cap was not
        // applied. This helper always keeps both bounds and does not follow
        // redirects when caller headers are present.
        const data = root.http_util.httpGetWithProxyTimeout(
            allocator,
            info.url_private,
            &.{auth_header},
            null,
            "60",
            MAX_INBOUND_FILE_BYTES,
        ) catch |err| {
            log.warn("Slack inbound file download failed: {}", .{err});
            return null;
        };
        defer allocator.free(data);
        if (data.len == 0) return null;
        if (looksLikeHtml(data)) {
            // A redirect or auth page is not the file; never hand HTML to the
            // vision/transcription pipeline.
            log.warn("Slack inbound file skipped: download returned HTML", .{});
            return null;
        }

        return saveSlackTempFile(allocator, info, data);
    }

    /// Telegram's poll loop is the only temp-media sweeper, and a Slack-only
    /// deployment has no poll loop, so downloaded files (including audio that
    /// was transcribed) would never expire. Sweep on start and on each file
    /// message instead, reusing the same 24h TTL and file-name prefixes.
    fn sweepInboundTempFiles(self: *SlackChannel) void {
        const tmp_dir = platform.getTempDir(self.allocator) catch return;
        defer self.allocator.free(tmp_dir);
        telegram.sweepTempMediaFilesInDir(tmp_dir, std_compat.time.timestamp(), telegram.TEMP_MEDIA_TTL_SECS);
    }

    fn transcribeSlackAudio(self: *SlackChannel, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const transcriber = self.transcriber orelse return null;
        return transcriber.transcribe(allocator, path) catch |err| {
            log.warn("Slack inbound audio transcription failed: {}", .{err});
            return null;
        };
    }

    /// Install the shared Whisper transcriber once, on start. Slack is not a
    /// polling channel, so this cannot live in a poll loop like Telegram's.
    fn ensureTranscriber(self: *SlackChannel) void {
        if (self.transcriber != null) return;
        if (!self.audio_media.enabled) return;
        const key = self.audio_provider_key orelse return;
        if (key.len == 0) return;

        const transcriber = self.allocator.create(voice.WhisperTranscriber) catch return;
        transcriber.* = .{
            .endpoint = voice.resolveTranscriptionEndpoint(self.audio_media.provider, self.audio_media.base_url),
            .api_key = key,
            .model = self.audio_media.model,
            .language = self.audio_media.language,
        };
        self.owned_transcriber = transcriber;
        self.transcriber = transcriber.transcriber();
    }

    /// Build and publish an inbound Slack message onto the bus. Shared by the
    /// Socket Mode event pipeline and the single slash command so both derive
    /// the same chat_id/session_key and reach the same command handling: a
    /// `/stop` typed in a channel and `/name /stop` interrupt the same turn.
    fn publishInboundMessage(
        self: *SlackChannel,
        sender_id: []const u8,
        channel_id: []const u8,
        text: []const u8,
        message_ts: ?[]const u8,
        thread_ts: ?[]const u8,
    ) !void {
        return self.publishInboundMessageTimeout(sender_id, channel_id, text, message_ts, thread_ts, null);
    }

    /// Same as `publishInboundMessage`, with an optional bounded wait for space
    /// on the inbound bus. The Socket Mode reader uses a short timeout: it must
    /// keep acking envelopes and answering pings, or Slack drops the websocket
    /// and redelivers. `error.Timeout` means nothing was published and the
    /// caller still owns the event.
    fn publishInboundMessageTimeout(
        self: *SlackChannel,
        sender_id: []const u8,
        channel_id: []const u8,
        text: []const u8,
        message_ts: ?[]const u8,
        thread_ts: ?[]const u8,
        timeout_ms: ?u32,
    ) !void {
        const is_dm = isDirectConversationId(channel_id);

        // Determine effective thread_ts for the reply target.
        // A message with thread_ts == ts is a top-level post that merely started a
        // thread; only thread_ts != ts means it is an actual thread reply.
        const is_thread_reply = if (thread_ts) |tts|
            if (message_ts) |mts| !std.mem.eql(u8, tts, mts) else true
        else
            false;
        const effective_thread_ts: ?[]const u8 = switch (self.reply_to_mode) {
            .off => if (is_thread_reply) thread_ts else null,
            .all => thread_ts orelse message_ts,
        };

        // Build chat_id: "channel_id:thread_ts" for threaded replies, plain channel_id otherwise.
        const chat_id = if (effective_thread_ts) |tts|
            try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ channel_id, tts })
        else
            channel_id;
        defer if (effective_thread_ts != null) self.allocator.free(chat_id);

        const session_key = if (is_dm)
            try std.fmt.allocPrint(self.allocator, "slack:{s}:direct:{s}", .{ self.account_id, sender_id })
        else
            try std.fmt.allocPrint(self.allocator, "slack:{s}:channel:{s}", .{ self.account_id, channel_id });
        defer self.allocator.free(session_key);

        var metadata: std.ArrayListUnmanaged(u8) = .empty;
        defer metadata.deinit(self.allocator);
        var metadata_writer: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &metadata);
        const mw = &metadata_writer.writer;
        try mw.writeByte('{');
        try mw.writeAll("\"account_id\":");
        try root.appendJsonStringW(mw, self.account_id);
        try mw.writeAll(",\"is_dm\":");
        try mw.writeAll(if (is_dm) "true" else "false");
        try mw.writeAll(",\"channel_id\":");
        try root.appendJsonStringW(mw, channel_id);
        if (message_ts) |ts| {
            try mw.writeAll(",\"message_id\":");
            try root.appendJsonStringW(mw, ts);
        }
        if (thread_ts) |tts| {
            try mw.writeAll(",\"thread_id\":");
            try root.appendJsonStringW(mw, tts);
        }
        try mw.writeByte('}');
        metadata = metadata_writer.toArrayList();

        const inbound = try bus_mod.makeInboundFull(
            self.allocator,
            "slack",
            sender_id,
            chat_id,
            text,
            session_key,
            &.{},
            metadata.items,
        );
        if (self.bus) |b| {
            const publish_result = if (timeout_ms) |ms|
                b.publishInboundTimeout(inbound, ms)
            else
                b.publishInbound(inbound);
            publish_result catch |err| {
                log.warn("Slack publishInbound failed: {}", .{err});
                inbound.deinit(self.allocator);
                return err;
            };
        } else {
            inbound.deinit(self.allocator);
        }
    }

    /// Conversation FIFO key for an inbound event. It mirrors the daemon's
    /// session key: `resolveInboundSessionKey` appends `:thread:<thread_id>`
    /// for every message whose metadata carries a thread_ts, and
    /// `publishInboundMessage` writes the raw thread_ts there. Events that
    /// share a session must not run concurrently, but threads of one channel
    /// are distinct sessions and must not share a FIFO hash either: a
    /// file_share event downloads up to MAX_INBOUND_FILES files (60s each), and
    /// keying the whole channel together would stall every other thread.
    fn inboundConversationHash(
        self: *const SlackChannel,
        sender_id: []const u8,
        channel_id: []const u8,
        thread_ts: ?[]const u8,
    ) u64 {
        var hasher = std.hash.Wyhash.init(0);
        if (isDirectConversationId(channel_id)) {
            hasher.update("slack:");
            hasher.update(self.account_id);
            hasher.update(":direct:");
            if (self.dm_scope == .main) {
                // dm_scope=main maps every DM of this agent to one session;
                // key them together or two workers can publish into that
                // session concurrently and reorder messages.
                hasher.update("main");
            } else {
                // identity_links merges peer ids into one routed session.
                hasher.update(agent_routing.resolveLinkedPeerId(sender_id, self.identity_links));
            }
        } else {
            hasher.update("slack:");
            hasher.update(self.account_id);
            hasher.update(":channel:");
            hasher.update(channel_id);
        }
        if (thread_ts) |tts| {
            hasher.update(":thread:");
            hasher.update(tts);
        }
        return hasher.final();
    }

    /// A typed `/stop` has to interrupt the turn that is blocking this
    /// conversation's FIFO, so it cannot wait behind that turn like an ordinary
    /// message. Publish it immediately from the socket reader, exactly as the
    /// slash-command `/stop` path does, after the same sender/bot/policy checks
    /// `processHistoryMessage` applies. Returns true when the event was
    /// handled.
    fn maybePublishStopMessage(self: *SlackChannel, msg_obj: std.json.ObjectMap, channel_id: []const u8) bool {
        // Subtyped events (edits, joins, file_share, ...) never carry a
        // command; keep them on the normal path.
        const subtype = if (msg_obj.get("subtype")) |sub_val|
            if (sub_val == .string) sub_val.string else ""
        else
            "";
        if (subtype.len > 0) return false;
        // Messages carrying files need the normal attachment pipeline.
        if (messageHasFiles(msg_obj)) return false;

        const user_val = msg_obj.get("user") orelse return false;
        if (user_val != .string or user_val.string.len == 0) return false;
        const sender_id = user_val.string;
        if (self.bot_user_id) |bot_uid| {
            if (std.mem.eql(u8, sender_id, bot_uid)) return false;
        }

        const raw_text = if (msg_obj.get("text")) |text_val|
            if (text_val == .string) std.mem.trim(u8, text_val.string, " \t\r\n") else ""
        else
            "";
        // In a mention-only group the accepted form is "<@BOT> /stop", which
        // parseSlashCommand does not recognise. Strip the leading mention for
        // the stop check and publish the command itself, so the daemon's
        // isStopLikeCommand sees the same text a typed "/stop" produces.
        const text = if (self.bot_user_id) |bot_uid|
            stripLeadingMention(raw_text, bot_uid) orelse raw_text
        else
            raw_text;
        if (!control_plane.isStopLikeCommand(text)) return false;

        const is_dm = isDirectConversationId(channel_id);
        // Policy is checked against the raw text: mention_only requires the
        // mention stripped above.
        if (!self.shouldHandle(sender_id, is_dm, raw_text, self.bot_user_id)) return false;

        const message_ts = if (msg_obj.get("ts")) |ts_val| switch (ts_val) {
            .string => |v| if (v.len > 0) v else null,
            else => null,
        } else null;
        const thread_ts = if (msg_obj.get("thread_ts")) |tts_val| switch (tts_val) {
            .string => |v| if (v.len > 0) v else null,
            else => null,
        } else null;

        // Do not overtake earlier work for this conversation. The dispatcher
        // only treats a stop as an interrupt while a turn is running, so a stop
        // published ahead of a queued message (for example one behind a claimed
        // file download) would run as an ordinary turn first and reverse the
        // reply order. Returning false lets the caller enqueue the stop on the
        // FIFO, behind those events.
        if (self.hasQueuedInboundFor(self.inboundConversationHash(sender_id, channel_id, thread_ts))) return false;

        self.publishInboundMessageTimeout(sender_id, channel_id, text, message_ts, thread_ts, STOP_PUBLISH_TIMEOUT_MS) catch |err| {
            if (err == error.Timeout) {
                // The inbound bus is full. Fall back to the normal FIFO path on
                // a worker instead of blocking the socket reader until a turn
                // drains the bus (acks and pings would stall, and Slack would
                // redeliver the event).
                return false;
            }
            log.warn("Slack stop message publish failed: {}", .{err});
        };
        return true;
    }

    /// Handle a Slack `slash_commands` Socket Mode envelope for the single
    /// configured command. The envelope is already acked by the caller.
    pub fn handleSlashCommand(self: *SlackChannel, payload_obj: std.json.ObjectMap) void {
        if (!self.slash_command_enabled) {
            log.warn("Slack slash command received but channels.slack.slash_command.enabled is false; ignoring", .{});
            return;
        }

        const command_val = payload_obj.get("command") orelse return;
        if (command_val != .string) return;
        if (!slashCommandNameMatches(self.slash_command_name, command_val.string)) {
            // A registered command that does not match the configured name is a
            // misconfiguration (for example the app registers "/openclaw" while
            // the default name is "nullclaw"). Make it observable instead of
            // silently dropping the invocation.
            log.warn("Slack slash command {s} does not match the configured name {s}; set channels.slack.slash_command.name", .{ command_val.string, self.slash_command_name });
            self.respondToSlashCommand(payload_obj, "This command is not configured on this app.");
            return;
        }

        if (self.shouldDropMismatchedSocketEvent(payload_obj)) return;

        const user_val = payload_obj.get("user_id") orelse return;
        if (user_val != .string or user_val.string.len == 0) return;
        const sender_id = user_val.string;
        if (self.bot_user_id) |bot_uid| {
            if (std.mem.eql(u8, sender_id, bot_uid)) return;
        }

        const channel_val = payload_obj.get("channel_id") orelse return;
        if (channel_val != .string or channel_val.string.len == 0) return;
        const channel_id = channel_val.string;

        const text = if (payload_obj.get("text")) |text_val|
            if (text_val == .string) std.mem.trim(u8, text_val.string, " \t\r\n") else ""
        else
            "";

        const is_dm = isDirectConversationId(channel_id);
        // SECURITY/UX NOTE: a slash command is an explicit, app-directed
        // invocation, so it is treated as a mention for the group policy. The
        // same DM/allowlist gates as a normal message still apply (an
        // unauthorized sender is refused below), but `group_policy =
        // mention_only` does NOT block it, because Slack never puts a bot
        // mention in the slash text. Anyone the allowlists admit can therefore
        // drive the agent with `/name <text>` in a mention-only room; tighten
        // `allow_from` or the group allowlist to restrict this.
        if (!root.checkPolicyScoped("slack channel", self.policy, sender_id, is_dm, true)) {
            log.warn("Slack slash command from unauthorized sender dropped channel={s}", .{channel_id});
            self.respondToSlashCommand(payload_obj, "You are not authorized to use this command.");
            return;
        }

        if (text.len == 0) {
            self.respondToSlashCommand(payload_obj, "Send a message after the command, for example `/stop`.");
            return;
        }

        // Feed the text as if the user typed it in this channel (top level), so
        // the normal command handling runs. A `/stop` therefore reaches the same
        // interrupt path as a typed message.
        //
        // `/stop` must stay immediate (it has to interrupt the turn that is
        // blocking the queue). Every other command joins the same
        // per-conversation FIFO as messages, so `/new` cannot run ahead of an
        // earlier queued message in this channel.
        if (control_plane.isStopLikeCommand(text)) {
            self.publishInboundMessage(sender_id, channel_id, text, null, null) catch |err| {
                log.warn("Slack slash command publish failed: {}", .{err});
            };
            return;
        }

        const text_copy = self.allocator.dupe(u8, text) catch return;
        const channel_copy = self.allocator.dupe(u8, channel_id) catch {
            self.allocator.free(text_copy);
            return;
        };
        const sender_copy = self.allocator.dupe(u8, sender_id) catch {
            self.allocator.free(text_copy);
            self.allocator.free(channel_copy);
            return;
        };
        self.enqueueInboundEvent(.{
            .kind = .slash,
            .payload = text_copy,
            .channel_id = channel_copy,
            .sender_id = sender_copy,
            .conversation_hash = self.inboundConversationHash(sender_id, channel_id, null),
        }) catch |err| {
            if (err == error.SlackInboundQueueFull) return;
            self.publishInboundMessage(sender_id, channel_id, text, null, null) catch |publish_err| {
                log.warn("Slack slash command publish failed: {}", .{publish_err});
            };
        };
    }

    /// Best-effort ephemeral reply to a slash command via its response_url.
    /// Slack only needs a plain JSON POST; failures are logged, never
    /// propagated. The POST is bounded so a slow or unreachable response_url
    /// cannot stall the Socket Mode read loop and delay acks for later
    /// envelopes (which makes Slack retry and re-deliver them).
    fn respondToSlashCommand(self: *SlackChannel, payload_obj: std.json.ObjectMap, text: []const u8) void {
        if (builtin.is_test) return;

        const url_val = payload_obj.get("response_url") orelse return;
        if (url_val != .string or url_val.string.len == 0) return;

        const body = buildSlashResponseBody(self.allocator, text) catch return;
        defer self.allocator.free(body);

        const resp = root.http_util.curlPostWithProxy(self.allocator, url_val.string, body, &.{}, null, "2") catch |err| {
            log.warn("Slack slash response_url post failed: {}", .{err});
            return;
        };
        self.allocator.free(resp);
    }

    fn pollChannelHistory(self: *SlackChannel, channel_id: []const u8) !void {
        var url_buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&url_buf);
        const oldest = self.channelLastTs(channel_id);
        try w.print("{s}/conversations.history?channel={s}&oldest={s}&inclusive=false&limit=100", .{ API_BASE, channel_id, oldest });
        const url = w.buffered();

        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.normalizedBotToken()});
        defer self.allocator.free(auth_header);
        const headers = [_][]const u8{auth_header};
        const resp = root.http_util.curlGet(self.allocator, url, &headers, "30") catch return error.SlackApiError;
        defer self.allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return error.SlackApiError;
        defer parsed.deinit();
        if (parsed.value != .object) return error.SlackApiError;
        try ensureSlackApiOk(parsed.value.object, "conversations.history", channel_id);

        const messages_val = parsed.value.object.get("messages") orelse return;
        if (messages_val != .array) return;

        const current_last_ts = parseTs(oldest);
        var max_seen = current_last_ts;
        var max_ts_raw: ?[]const u8 = null;

        var idx: usize = messages_val.array.items.len;
        while (idx > 0) {
            idx -= 1;
            const msg = messages_val.array.items[idx];
            if (msg != .object) continue;
            const ts_val = msg.object.get("ts") orelse continue;
            if (ts_val != .string) continue;
            const ts_num = parseTs(ts_val.string);
            if (ts_num <= current_last_ts) continue;
            if (ts_num > max_seen) {
                max_seen = ts_num;
                max_ts_raw = ts_val.string;
            }
            try self.processHistoryMessage(msg.object, channel_id);
        }

        if (max_ts_raw) |ts| {
            try self.setChannelLastTs(channel_id, ts);
        }
    }

    fn pollOnce(self: *SlackChannel) !void {
        const channel_ids = self.channel_id orelse return;

        var saw_any = false;
        var it = std.mem.splitScalar(u8, channel_ids, ',');
        while (it.next()) |raw_channel_id| {
            const channel_id = std.mem.trim(u8, raw_channel_id, " \t\r\n");
            if (channel_id.len == 0) continue;
            saw_any = true;
            try self.pollChannelHistory(channel_id);
        }

        if (!saw_any) {
            return error.SlackChannelIdRequired;
        }
    }

    fn pollLoop(self: *SlackChannel) void {
        while (self.running.load(.acquire)) {
            self.pollOnce() catch |err| {
                if (err == error.SlackAuthFailed) {
                    log.err("Slack polling auth failed; stopping Slack channel. Verify bot_token and scopes.", .{});
                    self.running.store(false, .release);
                    self.connected.store(false, .release);
                    return;
                }
                log.warn("Slack poll error: {}", .{err});
            };

            var slept: u64 = 0;
            while (slept < POLL_INTERVAL_SECS and self.running.load(.acquire)) : (slept += 1) {
                std_compat.thread.sleep(std.time.ns_per_s);
            }
        }
    }

    fn hasValidAppToken(self: *const SlackChannel) bool {
        return self.normalizedAppToken() != null;
    }

    fn hasPollingTargets(self: *const SlackChannel) bool {
        const channel_ids = self.channel_id orelse return false;
        var it = std.mem.splitScalar(u8, channel_ids, ',');
        while (it.next()) |raw_channel_id| {
            if (std.mem.trim(u8, raw_channel_id, " \t\r\n").len > 0) return true;
        }
        return false;
    }

    fn shouldUsePollingFallbackForSocketStart(self: *const SlackChannel) bool {
        if (!self.hasPollingTargets()) return false;
        if (self.socket_fallback_to_polling.load(.acquire)) return true;
        return !self.hasValidAppToken();
    }

    fn startPollingThread(self: *SlackChannel) !void {
        if (self.poll_thread != null) return;
        if (!self.hasPollingTargets()) return error.SlackChannelIdRequired;
        self.poll_thread = try std.Thread.spawn(.{ .stack_size = POLL_THREAD_STACK_SIZE }, pollLoop, .{self});
    }

    fn activatePollingFallback(self: *SlackChannel, reason: []const u8) bool {
        if (!self.running.load(.acquire)) return false;
        if (!self.hasPollingTargets()) {
            log.warn("Slack fallback to polling skipped ({s}): no channel_id configured", .{reason});
            return false;
        }

        self.socket_fallback_to_polling.store(true, .release);
        self.connected.store(false, .release);
        self.startPollingThread() catch |err| {
            log.err("Slack fallback to polling failed: {}", .{err});
            return false;
        };

        log.warn("Slack switched to polling fallback: {s}", .{reason});
        return true;
    }

    fn shouldCountSocketFailure(err: anyerror) bool {
        return err != error.ShouldReconnect;
    }

    fn componentAsSlice(component: std.Uri.Component) []const u8 {
        return switch (component) {
            .raw => |v| v,
            .percent_encoded => |v| v,
        };
    }

    fn parseSocketConnectParts(
        socket_url: []const u8,
        host_buf: *[std.Io.net.HostName.max_len]u8,
        path_buf: []u8,
    ) !struct { host: []const u8, port: u16, path: []const u8 } {
        const uri = std.Uri.parse(socket_url) catch return error.SlackApiError;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "wss")) return error.SlackApiError;

        const host = (uri.getHost(host_buf) catch return error.SlackApiError).bytes;
        const port = uri.port orelse 443;
        const raw_path = componentAsSlice(uri.path);
        const query = if (uri.query) |q| componentAsSlice(q) else "";

        var w: std.Io.Writer = .fixed(path_buf);
        if (raw_path.len == 0) {
            try w.writeByte('/');
        } else {
            if (raw_path[0] != '/') try w.writeByte('/');
            try w.writeAll(raw_path);
        }
        if (query.len > 0) {
            try w.writeByte('?');
            try w.writeAll(query);
        }
        return .{
            .host = host,
            .port = port,
            .path = w.buffered(),
        };
    }

    fn openSocketUrl(self: *SlackChannel) ![]u8 {
        const app_token = self.normalizedAppToken() orelse return error.SlackAppTokenRequired;
        const url = API_BASE ++ "/apps.connections.open";
        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{app_token});
        defer self.allocator.free(auth_header);
        const headers = [_][]const u8{auth_header};
        const resp = root.http_util.curlPost(self.allocator, url, "{}", &headers) catch return error.SlackApiError;
        defer self.allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return error.SlackApiError;
        defer parsed.deinit();
        if (parsed.value != .object) return error.SlackApiError;
        try ensureSlackApiOk(parsed.value.object, "apps.connections.open", null);
        const ws_url = parsed.value.object.get("url") orelse return error.SlackApiError;
        if (ws_url != .string or ws_url.string.len == 0) return error.SlackApiError;
        return self.allocator.dupe(u8, ws_url.string);
    }

    fn ackSocketEnvelope(self: *SlackChannel, ws: *websocket.WsClient, envelope_id: []const u8) !void {
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.writeAll("{\"envelope_id\":");
        try root.appendJsonStringW(&w, envelope_id);
        try w.writeAll("}");
        try ws.writeText(w.buffered());
        _ = self;
    }

    fn handleSocketPayload(self: *SlackChannel, ws: *websocket.WsClient, payload: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;

        const msg_type = if (parsed.value.object.get("type")) |tv|
            if (tv == .string) tv.string else ""
        else
            "";

        if (std.mem.eql(u8, msg_type, "disconnect")) return error.ShouldReconnect;

        if (parsed.value.object.get("envelope_id")) |env_val| {
            if (env_val == .string and env_val.string.len > 0) {
                self.ackSocketEnvelope(ws, env_val.string) catch |err| {
                    log.warn("Slack socket ack failed: {}", .{err});
                };
            }
        }

        if (std.mem.eql(u8, msg_type, "slash_commands")) {
            // Slack delivers the single configured slash command over Socket
            // Mode as a `slash_commands` envelope. The envelope is already
            // acked above; decide here whether to act on it.
            //
            // A failed ack makes Slack resend the envelope with
            // retry_attempt > 0. Ignore those: the command already ran and
            // re-processing it would double the side effects.
            if (socketRetryAttempt(parsed.value.object) > 0) return;
            const slash_payload = parsed.value.object.get("payload") orelse return;
            if (slash_payload != .object) return;
            self.handleSlashCommand(slash_payload.object);
            return;
        }

        if (!std.mem.eql(u8, msg_type, "events_api")) return;

        const payload_val = parsed.value.object.get("payload") orelse return;
        if (payload_val != .object) return;
        if (self.shouldDropMismatchedSocketEvent(payload_val.object)) return;
        const event_val = payload_val.object.get("event") orelse return;
        if (event_val != .object) return;

        const event_type_val = event_val.object.get("type") orelse return;
        if (event_type_val != .string) return;
        const event_type = event_type_val.string;
        if (!std.mem.eql(u8, event_type, "message") and !std.mem.eql(u8, event_type, "app_mention")) {
            return;
        }

        const channel_val = event_val.object.get("channel") orelse return;
        if (channel_val != .string or channel_val.string.len == 0) return;

        // Slack redelivers an event when its ack was lost; processing it again
        // duplicates the turn (and its file downloads).
        if (self.inboundEventAlreadySeen(payload_val.object, event_val.object)) return;

        // A typed `/stop` must not wait behind the per-conversation FIFO it is
        // meant to interrupt (the slash-command `/stop` path is immediate).
        if (self.maybePublishStopMessage(event_val.object, channel_val.string)) return;

        // Never run file downloads on the socket reader thread: it must keep
        // reading pongs and acking queued envelopes. A stalled download (up to
        // 60s x MAX_INBOUND_FILES) used to cause Slack redelivery and dropped
        // websockets.
        const event_json = std.json.Stringify.valueAlloc(self.allocator, event_val, .{}) catch
            return self.processHistoryMessage(event_val.object, channel_val.string);
        const channel_id = self.allocator.dupe(u8, channel_val.string) catch {
            self.allocator.free(event_json);
            return self.processHistoryMessage(event_val.object, channel_val.string);
        };
        // Events of the same session run FIFO; different sessions run
        // concurrently. The key mirrors the daemon session key, which appends
        // the thread: threads of one channel are independent sessions.
        self.enqueueInboundEvent(.{
            .kind = .message,
            .payload = event_json,
            .channel_id = channel_id,
            .conversation_hash = self.inboundConversationHash(
                jsonStringValue(event_val.object, "user") orelse "",
                channel_val.string,
                jsonStringValue(event_val.object, "thread_ts"),
            ),
        }) catch |err| {
            // The queue is bounded; a full queue drops the event with a log
            // rather than blocking the socket reader on a slow turn.
            if (err == error.SlackInboundQueueFull) return;
            // enqueueInboundEvent freed the owned copies; process the still-live
            // event rather than dropping it.
            return self.processHistoryMessage(event_val.object, channel_val.string);
        };
    }

    fn runSocketOnce(self: *SlackChannel) !void {
        const ws_url = try self.openSocketUrl();
        defer self.allocator.free(ws_url);

        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        var path_buf: [2048]u8 = undefined;
        const parts = try parseSocketConnectParts(ws_url, &host_buf, &path_buf);
        const ws_stream = try websocket.WsClient.connectTcp(self.allocator, parts.host, parts.port);
        if (!self.publishSocket(ws_stream.handle)) {
            self.closeOwnedSocketStream(ws_stream);
            return error.ConnectionClosed;
        }
        var ws = websocket.WsClient.connectFromStream(self.allocator, ws_stream, parts.host, parts.path, &.{}) catch |err| {
            self.closeOwnedSocketStream(ws_stream);
            return err;
        };
        defer {
            self.connected.store(false, .release);
            self.closeOwnedSocket(&ws);
        }
        self.connected.store(true, .release);

        while (self.running.load(.acquire)) {
            const maybe_text = ws.readTextMessage() catch |err| switch (err) {
                error.ConnectionClosed => break,
                else => return err,
            };
            const text = maybe_text orelse break;
            defer self.allocator.free(text);
            self.handleSocketPayload(&ws, text) catch |err| {
                if (err == error.ShouldReconnect) return err;
                log.warn("Slack socket payload error: {}", .{err});
            };
        }
    }

    fn socketLoop(self: *SlackChannel) void {
        var consecutive_socket_failures: u32 = 0;
        while (self.running.load(.acquire)) {
            if (self.runSocketOnce()) |_| {
                consecutive_socket_failures = 0;
            } else |err| {
                if (err == error.SlackAuthFailed) {
                    log.err("Slack socket auth failed; stopping Slack channel. Verify bot_token/app_token and scopes.", .{});
                    self.running.store(false, .release);
                    self.connected.store(false, .release);
                    return;
                }
                if (shouldCountSocketFailure(err)) {
                    if (err != error.SlackAppTokenRequired) {
                        log.warn("Slack socket cycle failed: {}", .{err});
                    }
                    consecutive_socket_failures +|= 1;
                } else {
                    consecutive_socket_failures = 0;
                }

                const should_fallback = err == error.SlackAppTokenRequired or
                    consecutive_socket_failures >= SOCKET_FAILURE_FALLBACK_THRESHOLD;
                if (should_fallback and self.activatePollingFallback(@errorName(err))) {
                    return;
                }
            }
            if (!self.running.load(.acquire)) break;

            var slept: u64 = 0;
            while (slept < RECONNECT_DELAY_NS and self.running.load(.acquire)) {
                std_compat.thread.sleep(100 * std.time.ns_per_ms);
                slept += 100 * std.time.ns_per_ms;
            }
        }
        self.connected.store(false, .release);
    }

    // ── Channel vtable ──────────────────────────────────────────────

    /// `thread_ts` is passed explicitly rather than read from `self.thread_ts`
    /// so callers on the streaming path do not depend on the mutable field that
    /// `parseTarget` rewrites.
    fn appendPostMessageBody(
        self: *SlackChannel,
        body_list: *std.ArrayListUnmanaged(u8),
        actual_channel: []const u8,
        thread_ts: ?[]const u8,
        text: []const u8,
    ) !void {
        const mrkdwn_text = try markdownToSlackMrkdwn(self.allocator, text);
        defer self.allocator.free(mrkdwn_text);
        try self.appendPostMessageMrkdwnBody(body_list, actual_channel, thread_ts, mrkdwn_text);
    }

    /// Same as `appendPostMessageBody`, for text already converted to mrkdwn.
    fn appendPostMessageMrkdwnBody(
        self: *SlackChannel,
        body_list: *std.ArrayListUnmanaged(u8),
        actual_channel: []const u8,
        thread_ts: ?[]const u8,
        mrkdwn_text: []const u8,
    ) !void {
        try body_list.appendSlice(self.allocator, "{\"channel\":\"");
        try body_list.appendSlice(self.allocator, actual_channel);
        try body_list.appendSlice(self.allocator, "\",\"mrkdwn\":true,\"text\":");
        try root.json_util.appendJsonString(body_list, self.allocator, mrkdwn_text);
        if (thread_ts) |tts| {
            try body_list.appendSlice(self.allocator, ",\"thread_ts\":\"");
            try body_list.appendSlice(self.allocator, tts);
            try body_list.append(self.allocator, '"');
        }
        try body_list.append(self.allocator, '}');
    }

    fn nextInteractionToken(self: *const SlackChannel) ![]u8 {
        var token_buf: [32]u8 = undefined;
        const seq = shared_interaction_seq.fetchAdd(1, .monotonic);
        const token = std.fmt.bufPrint(&token_buf, "{x}", .{seq}) catch unreachable;
        return self.allocator.dupe(u8, token);
    }

    fn registerPendingInteraction(
        self: *SlackChannel,
        token: []const u8,
        target: []const u8,
        owner_identity: ?[]const u8,
        choices: []const root.Channel.OutboundChoice,
    ) !void {
        const interaction_allocator = sharedInteractionsAllocator();
        const now = root.nowEpochSecs();

        var options = try interaction_allocator.alloc(PendingInteractionOption, choices.len);
        var built: usize = 0;
        errdefer {
            for (options[0..built]) |opt| opt.deinit(interaction_allocator);
            interaction_allocator.free(options);
        }

        for (choices, 0..) |choice, i| {
            const owned = try interaction_choices.ChoiceOption.initOwned(
                interaction_allocator,
                choice.id,
                choice.label,
                choice.submit_text,
            );
            options[i] = .{
                .id = owned.id,
                .label = owned.label,
                .submit_text = owned.submit_text,
            };
            built += 1;
        }

        const key = try interaction_allocator.dupe(u8, token);
        errdefer interaction_allocator.free(key);
        const target_dup = try interaction_allocator.dupe(u8, target);
        errdefer interaction_allocator.free(target_dup);
        const account_id_dup = try interaction_allocator.dupe(u8, self.account_id);
        errdefer interaction_allocator.free(account_id_dup);
        const owner_dup = if (owner_identity) |owner|
            try interaction_allocator.dupe(u8, owner)
        else
            null;
        errdefer if (owner_dup) |owner| interaction_allocator.free(owner);

        shared_interactions_mu.lock();
        defer shared_interactions_mu.unlock();

        self.expireInteractionsLocked(now);

        try shared_interactions.put(interaction_allocator, key, .{
            .allocator = interaction_allocator,
            .created_at = now,
            .expires_at = now + DEFAULT_INTERACTION_TTL_SECS,
            .account_id = account_id_dup,
            .target = target_dup,
            .owner_identity = owner_dup,
            .options = options,
        });
    }

    fn expireInteractionsLocked(self: *SlackChannel, now: u64) void {
        _ = self;
        while (true) {
            var expired_key: ?[]const u8 = null;
            var it = shared_interactions.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.expires_at < now) {
                    expired_key = entry.key_ptr.*;
                    break;
                }
            }

            const key = expired_key orelse break;
            if (shared_interactions.fetchRemove(key)) |removed| {
                removed.value.deinit();
                removed.value.allocator.free(@constCast(removed.key));
            }
        }

        if (shared_interactions.count() == 0) {
            shared_interactions.deinit(sharedInteractionsAllocator());
            shared_interactions = .empty;
        }
    }

    pub fn consumeInteractionSelection(
        self: *SlackChannel,
        token: []const u8,
        option_index: usize,
        sender_identity: []const u8,
    ) CallbackSelection {
        shared_interactions_mu.lock();
        defer shared_interactions_mu.unlock();

        const now = root.nowEpochSecs();
        self.expireInteractionsLocked(now);

        const interaction = shared_interactions.getPtr(token) orelse return .not_found;
        if (!std.ascii.eqlIgnoreCase(interaction.account_id, self.account_id)) return .not_found;
        if (interaction.owner_identity) |owner| {
            if (!std.ascii.eqlIgnoreCase(owner, sender_identity)) return .owner_mismatch;
        }
        if (option_index >= interaction.options.len) return .invalid_option;

        const submit_text = self.allocator.dupe(u8, interaction.options[option_index].submit_text) catch return .invalid_option;
        errdefer self.allocator.free(submit_text);
        const target = self.allocator.dupe(u8, interaction.target) catch return .invalid_option;
        errdefer self.allocator.free(target);

        if (shared_interactions.fetchRemove(token)) |removed| {
            removed.value.deinit();
            removed.value.allocator.free(@constCast(removed.key));
        }

        return .{ .ok = .{
            .submit_text = submit_text,
            .target = target,
        } };
    }

    fn deinitPendingInteractions(self: *SlackChannel) void {
        shared_interactions_mu.lock();
        defer shared_interactions_mu.unlock();

        while (true) {
            var matching_key: ?[]const u8 = null;
            var it = shared_interactions.iterator();
            while (it.next()) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.value_ptr.account_id, self.account_id)) {
                    matching_key = entry.key_ptr.*;
                    break;
                }
            }

            const key = matching_key orelse break;
            if (shared_interactions.fetchRemove(key)) |removed| {
                removed.value.deinit();
                removed.value.allocator.free(@constCast(removed.key));
            }
        }

        if (shared_interactions.count() == 0) {
            shared_interactions.deinit(sharedInteractionsAllocator());
            shared_interactions = .empty;
        }
    }

    fn appendInteractivePostMessageBody(
        self: *SlackChannel,
        body_list: *std.ArrayListUnmanaged(u8),
        actual_channel: []const u8,
        text: []const u8,
        token: []const u8,
        choices: []const root.Channel.OutboundChoice,
    ) !void {
        const mrkdwn_text = try markdownToSlackMrkdwn(self.allocator, text);
        defer self.allocator.free(mrkdwn_text);

        try body_list.appendSlice(self.allocator, "{\"channel\":\"");
        try body_list.appendSlice(self.allocator, actual_channel);
        try body_list.appendSlice(self.allocator, "\",\"mrkdwn\":true,\"text\":");
        try root.json_util.appendJsonString(body_list, self.allocator, mrkdwn_text);
        if (self.thread_ts) |tts| {
            try body_list.appendSlice(self.allocator, ",\"thread_ts\":\"");
            try body_list.appendSlice(self.allocator, tts);
            try body_list.append(self.allocator, '"');
        }
        try body_list.appendSlice(self.allocator, ",\"blocks\":[{\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":");
        try root.json_util.appendJsonString(body_list, self.allocator, mrkdwn_text);
        try body_list.appendSlice(self.allocator, "}},{\"type\":\"actions\",\"elements\":[");
        for (choices, 0..) |choice, i| {
            if (i > 0) try body_list.append(self.allocator, ',');
            const callback_value = try std.fmt.allocPrint(self.allocator, "{s}{s}:{d}", .{ CALLBACK_VALUE_PREFIX, token, i });
            defer self.allocator.free(callback_value);

            try body_list.appendSlice(self.allocator, "{\"type\":\"button\",\"text\":{\"type\":\"plain_text\",\"text\":");
            try root.json_util.appendJsonString(body_list, self.allocator, choice.label);
            try body_list.appendSlice(self.allocator, "},\"value\":");
            try root.json_util.appendJsonString(body_list, self.allocator, callback_value);
            try body_list.appendSlice(self.allocator, ",\"action_id\":");
            try root.json_util.appendJsonString(body_list, self.allocator, choice.id);
            try body_list.append(self.allocator, '}');
        }
        try body_list.appendSlice(self.allocator, "]}]}");
    }

    /// Parse `[IMAGE:...]`/`[FILE:...]` markers out of a reply and return the
    /// remaining text plus the attachments to upload. Reuses Telegram's marker
    /// parser so both channels accept exactly the same syntax.
    fn prepareOutbound(
        self: *SlackChannel,
        allocator: std.mem.Allocator,
        message: []const u8,
        media: []const []const u8,
    ) !telegram.OwnedOutboundPayload {
        _ = self;
        return telegram.buildOwnedOutboundPayloadFromLegacy(allocator, message, media, false);
    }

    /// Deliver a final reply that may carry attachment markers. The text is
    /// sent through the normal (streaming or plain) path with the markers
    /// stripped; each attachment is then uploaded into the same channel/thread.
    fn deliverFinal(self: *SlackChannel, target: []const u8, message: []const u8, media: []const []const u8) !void {
        var payload = self.prepareOutbound(self.allocator, message, media) catch {
            if (message.len == 0) {
                self.finishStreamStateFor(target);
                return;
            }
            return self.streamFinal(target, message, media, false);
        };
        defer payload.deinit(self.allocator);

        if (payload.attachments.len == 0) {
            if (message.len == 0) {
                self.finishStreamStateFor(target);
                return;
            }
            return self.streamFinal(target, message, media, false);
        }

        if (payload.text.len > 0) {
            try self.streamFinal(target, payload.text, &.{}, true);
        } else {
            // A reply that is only an attachment streams the raw marker as its
            // preview; remove it so the file is not preceded by `[IMAGE:...]`.
            self.discardStreamPreview(target);
        }

        for (payload.attachments) |attachment| {
            self.uploadAttachment(target, attachment) catch |err| {
                log.warn("Slack attachment upload failed ({s}): {}", .{ attachment.target, err });
            };
        }
    }

    fn discardStreamPreview(self: *SlackChannel, target: []const u8) void {
        self.stream_mu.lock();
        defer self.stream_mu.unlock();

        const now_ms = std_compat.time.milliTimestamp();
        self.clearStreamCancelLocked(target);
        const state = self.stream_states.getPtr(target) orelse return;
        defer state.finishTurn(self.allocator, now_ms);
        if (state.message_ts.len == 0) return;

        const parsed = stream_presenter.resolveStreamTarget(target);
        // A native stream is still active until chat.stopStream finalizes it;
        // deleting first can be refused and leaves the raw marker visible.
        if (state.mode == .native) {
            self.stopNativeStream(parsed, state.message_ts) catch |err| {
                log.warn("Slack chat.stopStream failed ({s})", .{@errorName(err)});
            };
        }

        const body = buildDeleteMessageBody(self.allocator, parsed.channel_id, state.message_ts) catch |err| {
            log.warn("Slack preview delete body failed ({s})", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(body);

        var result = self.callSlackApi("chat.delete", body, parsed.channel_id) catch |err| {
            log.warn("Slack chat.delete preview failed ({s})", .{@errorName(err)});
            return;
        };
        result.deinit(self.allocator);
    }

    /// Upload one outbound attachment through Slack's external upload flow:
    /// files.getUploadURLExternal -> raw POST -> files.completeUploadExternal.
    fn uploadAttachment(self: *SlackChannel, target: []const u8, attachment: root.Channel.OutboundAttachment) !void {
        if (builtin.is_test) return;
        const parsed = stream_presenter.resolveStreamTarget(target);
        const data = self.loadAttachmentBytes(attachment.target) catch |err| {
            log.warn("Slack attachment read failed ({s}): {}", .{ attachment.target, err });
            return err;
        };
        defer self.allocator.free(data);
        if (data.len == 0) return error.SlackApiError;

        const file_name = attachmentFileName(attachment.target);
        try self.uploadExternal(parsed.channel_id, parsed.thread_ts, file_name, attachmentContentType(file_name), data);
    }

    fn loadAttachmentBytes(self: *SlackChannel, path_or_url: []const u8) ![]u8 {
        // Regression: model-supplied http(s) URLs used to be fetched with no
        // outbound-URL policy, so a prompt-injected reply could make the bot
        // download loopback or cloud-metadata endpoints (SSRF). Telegram hands
        // URLs to Telegram instead of fetching them; Slack must read the bytes
        // itself, so only local paths are accepted.
        if (asciiStartsWithIgnoreCase(path_or_url, "http://") or
            asciiStartsWithIgnoreCase(path_or_url, "https://"))
        {
            return error.UnsupportedAttachmentUrl;
        }
        return fs_compat.readFileAlloc(std_compat.fs.cwd(), self.allocator, path_or_url, MAX_OUTBOUND_FILE_BYTES);
    }

    fn uploadExternal(
        self: *SlackChannel,
        channel_id: []const u8,
        thread_ts: ?[]const u8,
        file_name: []const u8,
        content_type: []const u8,
        data: []const u8,
    ) !void {
        const ticket_body = try buildGetUploadUrlBody(self.allocator, file_name, data.len);
        defer self.allocator.free(ticket_body);

        var ticket = try self.callSlackApi("files.getUploadURLExternal", ticket_body, channel_id);
        defer ticket.deinit(self.allocator);
        if (ticket.error_code != null) return error.SlackApiError;
        const upload_url = ticket.upload_url orelse return error.SlackApiError;
        const file_id = ticket.file_id orelse return error.SlackApiError;

        const upload_resp = try root.http_util.curlPostRawWithContentType(
            self.allocator,
            upload_url,
            data,
            content_type,
            &.{},
            "120",
        );
        self.allocator.free(upload_resp);

        const complete_body = try buildCompleteUploadBody(self.allocator, file_id, file_name, channel_id, thread_ts);
        defer self.allocator.free(complete_body);

        var completed = try self.callSlackApi("files.completeUploadExternal", complete_body, channel_id);
        defer completed.deinit(self.allocator);
        if (completed.error_code != null) return error.SlackApiError;
    }

    /// Send a message to a Slack channel via chat.postMessage API.
    /// The target may contain "channel_id:thread_ts" for threaded replies.
    pub fn sendMessage(self: *SlackChannel, target_channel: []const u8, text: []const u8) !void {
        // Tests must never reach the network; payload builders are covered
        // directly (see appendPostMessageBody tests).
        if (builtin.is_test) return;

        const url = API_BASE ++ "/chat.postMessage";

        // Parse target for thread_ts (channel_id:thread_ts)
        const actual_channel = self.parseTarget(target_channel);

        // Build JSON body
        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);
        try self.appendPostMessageBody(&body_list, actual_channel, self.thread_ts, text);

        // Build auth header: "Authorization: Bearer xoxb-..."
        var auth_buf: [512]u8 = undefined;
        var auth_writer: std.Io.Writer = .fixed(&auth_buf);
        try auth_writer.print("Authorization: Bearer {s}", .{self.normalizedBotToken()});
        const auth_header = auth_writer.buffered();

        const resp = root.http_util.curlPost(self.allocator, url, body_list.items, &.{auth_header}) catch |err| {
            log.err("Slack API POST failed: {}", .{err});
            return error.SlackApiError;
        };
        defer self.allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return error.SlackApiError;
        defer parsed.deinit();
        if (parsed.value != .object) return error.SlackApiError;
        try ensureSlackApiOk(parsed.value.object, "chat.postMessage", actual_channel);
    }

    pub fn sendRichPayload(self: *SlackChannel, target_channel: []const u8, payload: root.Channel.OutboundPayload) !void {
        if (payload.attachments.len > 0) {
            if (payload.text.len > 0) try self.sendMessage(target_channel, payload.text);
            for (payload.attachments) |attachment| {
                self.uploadAttachment(target_channel, attachment) catch |err| {
                    log.warn("Slack attachment upload failed ({s}): {}", .{ attachment.target, err });
                };
            }
            return;
        }
        if (payload.choices.len == 0) return self.sendMessage(target_channel, payload.text);
        if (!validateChoices(payload.choices)) return error.InvalidChoices;

        const actual_channel = self.parseTarget(target_channel);
        const token = try self.nextInteractionToken();
        defer self.allocator.free(token);

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);
        try self.appendInteractivePostMessageBody(&body_list, actual_channel, payload.text, token, payload.choices);

        var auth_buf: [512]u8 = undefined;
        var auth_writer: std.Io.Writer = .fixed(&auth_buf);
        try auth_writer.print("Authorization: Bearer {s}", .{self.normalizedBotToken()});
        const auth_header = auth_writer.buffered();

        const resp = root.http_util.curlPost(self.allocator, API_BASE ++ "/chat.postMessage", body_list.items, &.{auth_header}) catch |err| {
            log.err("Slack API POST failed: {}", .{err});
            return error.SlackApiError;
        };
        defer self.allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return error.SlackApiError;
        defer parsed.deinit();
        if (parsed.value != .object) return error.SlackApiError;
        try ensureSlackApiOk(parsed.value.object, "chat.postMessage", actual_channel);

        try self.registerPendingInteraction(token, target_channel, null, payload.choices);
    }

    /// Set Slack Assistant thread status (best-effort, errors ignored).
    pub fn setThreadStatus(self: *SlackChannel, channel_id: []const u8, thread_ts: []const u8, status: []const u8) void {
        if (builtin.is_test) return;
        if (channel_id.len == 0 or thread_ts.len == 0) return;

        const url = API_BASE ++ "/assistant.threads.setStatus";
        const body = buildThreadStatusRequestBody(self.allocator, channel_id, thread_ts, status) catch return;
        defer self.allocator.free(body);

        var auth_buf: [512]u8 = undefined;
        var auth_writer: std.Io.Writer = .fixed(&auth_buf);
        auth_writer.print("Authorization: Bearer {s}", .{self.normalizedBotToken()}) catch return;
        const auth_header = auth_writer.buffered();

        const resp = root.http_util.curlPost(self.allocator, url, body, &.{auth_header}) catch return;
        self.allocator.free(resp);
    }

    fn parseStatusTarget(target: []const u8) ?struct { channel_id: []const u8, thread_ts: []const u8 } {
        const idx = std.mem.indexOfScalar(u8, target, ':') orelse return null;
        if (idx == 0) return null;
        const channel_id = target[0..idx];
        const thread_ts = target[idx + 1 ..];
        if (thread_ts.len == 0) return null;
        return .{
            .channel_id = channel_id,
            .thread_ts = thread_ts,
        };
    }

    pub fn startTyping(self: *SlackChannel, target: []const u8) !void {
        if (!self.running.load(.acquire)) return;
        const status_target = parseStatusTarget(target) orelse return;
        self.setThreadStatus(status_target.channel_id, status_target.thread_ts, "is typing...");
    }

    pub fn stopTyping(self: *SlackChannel, target: []const u8) !void {
        if (!self.running.load(.acquire)) return;
        const status_target = parseStatusTarget(target) orelse return;
        self.setThreadStatus(status_target.channel_id, status_target.thread_ts, "");
    }

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        self.lifecycle_mu.lock();
        defer self.lifecycle_mu.unlock();

        if (self.running.load(.acquire)) return;
        if (!self.hasValidBotToken()) return error.SlackBotTokenRequired;

        self.ensureTranscriber();
        self.sweepInboundTempFiles();
        self.running.store(true, .release);
        errdefer self.running.store(false, .release);
        self.connected.store(false, .release);

        // Regression: stop() left inbound_stop set and the worker handles
        // cleared, and channel_manager restarts the same instance after a
        // health-check failure. Without resetting both here the respawned
        // worker exited immediately, events queued forever and inbound went
        // silently dead. Join any worker that outlived a failed start, then
        // start a fresh pool.
        self.inbound_mu.lock();
        self.inbound_stop = true;
        self.inbound_cond.broadcast();
        self.inbound_mu.unlock();
        for (&self.inbound_threads) |*slot| {
            if (slot.*) |thread| {
                thread.join();
                slot.* = null;
            }
        }
        self.inbound_mu.lock();
        var stale_queue = self.inbound_queue;
        self.inbound_queue = .empty;
        self.inbound_stop = false;
        const workers_ok = self.ensureInboundWorkersLocked();
        self.inbound_mu.unlock();
        for (stale_queue.items) |*event| event.deinit(self.allocator);
        stale_queue.deinit(self.allocator);
        if (!workers_ok) return error.SlackInboundWorkerUnavailable;

        // Best-effort bot identity fetch for mention-only policies.
        var fetched_bot_identity = true;
        self.fetchBotUserId() catch |err| {
            if (err == error.SlackAuthFailed) {
                log.err("Slack auth.test failed due authentication error; refusing to start Slack channel.", .{});
                return err;
            }
            log.warn("Slack auth.test failed: {}", .{err});
            fetched_bot_identity = false;
        };
        if (fetched_bot_identity) {
            try self.ensureSocketTokenPairMatches();
        }

        switch (self.mode) {
            .socket => {
                if (self.shouldUsePollingFallbackForSocketStart()) {
                    const fallback_reason: []const u8 = if (self.socket_fallback_to_polling.load(.acquire))
                        "sticky fallback flag"
                    else
                        "missing/empty app_token";
                    if (!self.activatePollingFallback(fallback_reason)) {
                        return error.SlackAppTokenRequired;
                    }
                    return;
                }
                if (!self.hasValidAppToken()) return error.SlackAppTokenRequired;
                self.socket_thread = try std.Thread.spawn(.{ .stack_size = SOCKET_THREAD_STACK_SIZE }, socketLoop, .{self});
            },
            .http => {
                const secret = self.signing_secret orelse return error.SlackSigningSecretRequired;
                if (std.mem.trim(u8, secret, " \t\r\n").len == 0) return error.SlackSigningSecretRequired;
            },
        }
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        self.lifecycle_mu.lock();
        defer self.lifecycle_mu.unlock();

        self.running.store(false, .release);
        self.connected.store(false, .release);

        // shutdown() unblocks the socket reader while WsClient retains final close
        // ownership in runSocketOnce's defer.
        self.shutdownActiveSocket();

        if (self.socket_thread) |t| {
            t.join();
            self.socket_thread = null;
        }

        if (self.poll_thread) |t| {
            t.join();
            self.poll_thread = null;
        }

        // No producer is left after the socket/poll joins; stop the inbound
        // pool before freeing the fields it reads (bot ids, transcriber).
        self.inbound_mu.lock();
        self.inbound_stop = true;
        self.inbound_cond.broadcast();
        self.inbound_mu.unlock();
        for (&self.inbound_threads) |*slot| {
            if (slot.*) |thread| {
                thread.join();
                slot.* = null;
            }
        }
        self.inbound_mu.lock();
        var queued = self.inbound_queue;
        self.inbound_queue = .empty;
        self.inbound_mu.unlock();
        for (queued.items) |*event| event.deinit(self.allocator);
        queued.deinit(self.allocator);

        self.socket_fallback_to_polling.store(false, .release);
        if (self.bot_user_id) |uid| {
            self.allocator.free(uid);
            self.bot_user_id = null;
        }
        if (self.bot_team_id) |team_id| {
            self.allocator.free(team_id);
            self.bot_team_id = null;
        }
        if (self.bot_api_app_id) |api_app_id| {
            self.allocator.free(api_app_id);
            self.bot_api_app_id = null;
        }
        if (self.owned_transcriber) |transcriber| {
            self.allocator.destroy(transcriber);
            self.owned_transcriber = null;
            self.transcriber = null;
        }
        self.deinitPendingInteractions();
        self.clearChannelCursors();
        self.deinitStreamStates();
        if (self.last_ts_owned) {
            self.allocator.free(self.last_ts);
            self.last_ts = "0";
            self.last_ts_owned = false;
        }
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, media: []const []const u8) anyerror!void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        var payload = self.prepareOutbound(self.allocator, message, media) catch {
            return self.sendMessage(target, message);
        };
        defer payload.deinit(self.allocator);
        if (payload.attachments.len == 0) return self.sendMessage(target, message);

        if (payload.text.len > 0) try self.sendMessage(target, payload.text);
        for (payload.attachments) |attachment| {
            self.uploadAttachment(target, attachment) catch |err| {
                log.warn("Slack attachment upload failed ({s}): {}", .{ attachment.target, err });
            };
        }
    }

    fn vtableSendRich(ptr: *anyopaque, target: []const u8, payload: root.Channel.OutboundPayload) anyerror!void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        try self.sendRichPayload(target, payload);
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        return self.channelName();
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        return self.healthCheck();
    }

    fn vtableStartTyping(ptr: *anyopaque, recipient: []const u8) anyerror!void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        try self.startTyping(recipient);
    }

    fn vtableStopTyping(ptr: *anyopaque, recipient: []const u8) anyerror!void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        try self.stopTyping(recipient);
    }

    // ── Streaming outbound ──────────────────────────────────────────
    //
    // Slack has two ways to show a reply while it is still being generated:
    //
    //   native   chat.startStream → throttled chat.appendStream → chat.stopStream.
    //            Slack only accepts a stream inside a thread, so this path needs
    //            a "channel_id:thread_ts" target (reply_to_mode = all, or an
    //            inbound thread reply / assistant thread).
    //   fallback chat.postMessage, then throttled chat.update edits of that same
    //            message. Used for top-level targets and whenever the native
    //            methods are unavailable to this app.
    //
    // Deltas are coalesced by slack_stream_presenter so a token stream turns into
    // at most one API call per second per turn.

    const StreamState = stream_presenter.StreamState;

    fn vtableSetTaskReaction(ptr: *anyopaque, update: root.Channel.TaskReactionUpdate) anyerror!void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        self.setTaskReaction(update.target, update.message_id, update.reaction);
    }

    fn vtableSupportsStreamingOutbound(ptr: *anyopaque) bool {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        return self.streaming_enabled;
    }

    fn vtableSendEvent(
        ptr: *anyopaque,
        target: []const u8,
        message: []const u8,
        media: []const []const u8,
        stage: root.Channel.OutboundStage,
    ) anyerror!void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));

        if (!self.streaming_enabled) {
            if (stage != .final) return;
            // Regression: an empty final fell through to sendMessage(""), which
            // Slack rejects with `no_text`; the dispatcher then retried it as a
            // transient failure. An empty final with no attachments has nothing
            // to deliver.
            if (message.len == 0 and media.len == 0) return;
            return vtableSend(ptr, target, message, media);
        }

        switch (stage) {
            .chunk => {
                if (message.len == 0) return;
                self.streamChunk(target, message);
            },
            .final => {
                if (message.len == 0 and media.len == 0) {
                    self.finishStreamStateFor(target);
                    return;
                }
                try self.deliverFinal(target, message, media);
            },
        }
    }

    fn deinitStreamStates(self: *SlackChannel) void {
        self.stream_mu.lock();
        defer self.stream_mu.unlock();
        stream_presenter.deinitStreamStates(self.allocator, &self.stream_states);
        var it = self.stream_cancels.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.stream_cancels.deinit(self.allocator);
        self.stream_cancels = .empty;
    }

    fn vtableCancelStreams(ptr: *anyopaque, target: []const u8) void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        self.cancelStreams(target);
    }

    /// Mark `target` cancelled after a /stop, so the stopped turn's already
    /// queued `.chunk` events are dropped instead of replaying. Cleared when the
    /// stopped turn's final reply is delivered, or after the grace window.
    pub fn cancelStreams(self: *SlackChannel, target: []const u8) void {
        if (target.len == 0) return;

        self.stream_mu.lock();
        defer self.stream_mu.unlock();

        const now_ms = std_compat.time.milliTimestamp();
        self.pruneStreamCancelsLocked(now_ms);

        const gop = self.stream_cancels.getOrPut(self.allocator, target) catch |err| {
            log.warn("Slack stream cancel allocation failed: {}", .{err});
            return;
        };
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, target) catch {
                _ = self.stream_cancels.remove(target);
                log.warn("Slack stream cancel allocation failed: {}", .{error.OutOfMemory});
                return;
            };
        }
        gop.value_ptr.* = now_ms + stream_presenter.STREAM_LATE_CHUNK_GRACE_MS;
    }

    fn isStreamCancelledLocked(self: *SlackChannel, target: []const u8, now_ms: i64) bool {
        const expiry = self.stream_cancels.get(target) orelse return false;
        if (now_ms >= expiry) {
            self.clearStreamCancelLocked(target);
            return false;
        }
        return true;
    }

    fn clearStreamCancelLocked(self: *SlackChannel, target: []const u8) void {
        if (self.stream_cancels.fetchRemove(target)) |entry| self.allocator.free(entry.key);
    }

    /// Drop expired cancel markers so a long-running bot does not accumulate one
    /// entry per target it has ever stopped.
    fn pruneStreamCancelsLocked(self: *SlackChannel, now_ms: i64) void {
        var stale: [stream_presenter.STREAM_MAX_TRACKED_TARGETS][]const u8 = undefined;
        var stale_len: usize = 0;
        var it = self.stream_cancels.iterator();
        while (it.next()) |entry| {
            if (now_ms < entry.value_ptr.*) continue;
            if (stale_len == stale.len) break;
            stale[stale_len] = entry.key_ptr.*;
            stale_len += 1;
        }
        for (stale[0..stale_len]) |key| {
            if (self.stream_cancels.fetchRemove(key)) |entry| self.allocator.free(entry.key);
        }
    }

    /// The turn ended without a reply body; close the turn so late deltas are
    /// dropped instead of opening a new stream.
    fn finishStreamStateFor(self: *SlackChannel, target: []const u8) void {
        self.stream_mu.lock();
        defer self.stream_mu.unlock();

        const now_ms = std_compat.time.milliTimestamp();
        if (self.stream_states.getPtr(target)) |state| {
            // Regression: an empty `.final` freed the state without closing a
            // native stream, leaving the message stuck in Slack's streaming
            // state. Finalize it the same way discardStreamPreview does.
            if (state.mode == .native and state.message_ts.len > 0) {
                const parsed = stream_presenter.resolveStreamTarget(target);
                self.stopNativeStream(parsed, state.message_ts) catch |err| {
                    log.warn("Slack chat.stopStream failed ({s})", .{@errorName(err)});
                };
            }
            state.finishTurn(self.allocator, now_ms);
        }
        self.clearStreamCancelLocked(target);
    }

    fn streamChunk(self: *SlackChannel, target: []const u8, chunk: []const u8) void {
        // The mutex also covers the API call: chunks arrive on the outbound
        // dispatcher thread while the final reply may arrive on the durable
        // outbox worker, and both must see the same stream state.
        self.stream_mu.lock();
        defer self.stream_mu.unlock();

        const now_ms = std_compat.time.milliTimestamp();
        // A /stop cancelled this target: the deltas still queued ahead of the
        // stop must not replay to the user once the dispatcher catches up.
        if (self.isStreamCancelledLocked(target, now_ms)) return;
        const state = self.ensureStreamStateLocked(target, now_ms) catch |err| {
            log.warn("Slack streaming state allocation failed: {}", .{err});
            return;
        };
        // The final reply may already have been delivered for this turn (see
        // STREAM_LATE_CHUNK_GRACE_MS); those leftovers must not open a new stream.
        if (state.send_failed or state.isLateChunk(now_ms)) return;

        var flush = stream_presenter.appendStreamChunk(self.allocator, state, chunk, now_ms) catch |err| {
            log.warn("Slack streaming buffer append failed: {}", .{err});
            return;
        } orelse return;
        defer flush.deinit(self.allocator);

        self.publishStreamFlushLocked(target, state, &flush);
    }

    fn ensureStreamStateLocked(self: *SlackChannel, target: []const u8, now_ms: i64) !*StreamState {
        self.pruneFinishedStreamStatesLocked(now_ms);

        const gop = try self.stream_states.getOrPut(self.allocator, target);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, target);
            const has_thread = stream_presenter.resolveStreamTarget(target).thread_ts != null;
            gop.value_ptr.* = .{
                .mode = stream_presenter.chooseTurnTransport(
                    has_thread,
                    self.native_stream_disabled.load(.acquire),
                ),
            };
        }
        return gop.value_ptr;
    }

    /// Drop finished targets once the map grows, so a long-running bot does not
    /// accumulate one entry per Slack thread it has ever answered in.
    fn pruneFinishedStreamStatesLocked(self: *SlackChannel, now_ms: i64) void {
        if (self.stream_states.count() <= stream_presenter.STREAM_MAX_TRACKED_TARGETS) return;

        var stale: [stream_presenter.STREAM_MAX_TRACKED_TARGETS][]const u8 = undefined;
        var stale_len: usize = 0;
        var it = self.stream_states.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.finished_at_ms == 0) continue;
            if (entry.value_ptr.isLateChunk(now_ms)) continue;
            if (stale_len == stale.len) break;
            stale[stale_len] = entry.key_ptr.*;
            stale_len += 1;
        }
        for (stale[0..stale_len]) |key| {
            stream_presenter.clearStreamState(self.allocator, &self.stream_states, key);
        }
    }

    fn publishStreamFlushLocked(
        self: *SlackChannel,
        target: []const u8,
        state: *StreamState,
        flush: *const stream_presenter.StreamFlush,
    ) void {
        const parsed = stream_presenter.resolveStreamTarget(target);

        if (state.mode == .native) {
            if (flush.native_full) {
                // The accumulated snapshot has outgrown Slack's message cap, so
                // the next chat.appendStream would answer `msg_too_long` -- a
                // per-call split cannot prevent a cumulative overflow. Close the
                // stream and finish on the edited-message transport, whose
                // chat.update is capped at STREAM_UPDATE_MAX_BYTES and whose
                // overflow goes out as thread follow-ups.
                if (state.message_ts.len > 0) {
                    self.stopNativeStream(parsed, state.message_ts) catch |err| {
                        log.warn("Slack chat.stopStream failed ({s})", .{@errorName(err)});
                    };
                }
                state.mode = .fallback;
            } else if (state.message_ts.len == 0) {
                self.startNativeStreamLocked(parsed, state, flush.text) catch |err| {
                    log.warn("Slack chat.startStream failed ({s}); using edited messages", .{@errorName(err)});
                    state.mode = .fallback;
                };
            } else if (flush.rewrite) {
                // The snapshot dropped earlier bytes (an orphan reasoning closer
                // removed the leaked draft, or a late `<think>` moved them).
                // chat.appendStream is append-only, so appending the whole
                // snapshot would show the draft twice; close the stream and
                // rewrite the message in place from here on.
                self.stopNativeStream(parsed, state.message_ts) catch |err| {
                    log.warn("Slack chat.stopStream failed ({s})", .{@errorName(err)});
                };
                state.mode = .fallback;
            } else {
                // Keep the native transport: the streamed message still has to be
                // closed with chat.stopStream, and the final reply reconciles it.
                self.appendNativeStreamLocked(parsed, state, flush.delta()) catch |err| {
                    // A failed append — most likely `msg_too_long` once the
                    // message passes Slack's cumulative cap, which a per-call
                    // split cannot foresee — leaves the native stream unusable
                    // for this turn. Close it now rather than only stopping live
                    // updates: otherwise a turn with no final body can leave the
                    // message stuck in the streaming state. Finish on the
                    // edited-message transport, whose chat.update is capped and
                    // splits, so the final reply is still delivered intact.
                    log.warn("Slack chat.appendStream failed ({s}); finishing on edited messages", .{@errorName(err)});
                    if (state.message_ts.len > 0) {
                        self.stopNativeStream(parsed, state.message_ts) catch |stop_err| {
                            log.warn("Slack chat.stopStream failed ({s})", .{@errorName(stop_err)});
                        };
                    }
                    state.mode = .fallback;
                    state.send_failed = true;
                };
            }
            if (state.mode == .native) return;
        }

        if (state.mode != .fallback or state.send_failed) return;

        if (state.message_ts.len == 0) {
            const ts = self.postMessageForStream(parsed, flush.text) catch |err| {
                log.warn("Slack streaming chat.postMessage failed ({s}); reply will be sent complete", .{@errorName(err)});
                state.send_failed = true;
                return;
            };
            defer self.allocator.free(ts);
            state.setMessageTs(self.allocator, ts) catch |err| {
                log.warn("Slack streaming state allocation failed: {}", .{err});
                state.send_failed = true;
            };
            return;
        }

        self.updateStreamMessage(parsed, state.message_ts, flush.text) catch |err| {
            log.warn("Slack streaming chat.update failed ({s}); continuing without live updates", .{@errorName(err)});
            state.send_failed = true;
        };
    }

    fn startNativeStreamLocked(
        self: *SlackChannel,
        parsed: stream_presenter.StreamTarget,
        state: *StreamState,
        text: []const u8,
    ) !void {
        const thread_ts = parsed.thread_ts orelse {
            // Defensive: ensureStreamStateLocked already picks the fallback
            // transport for a top-level target.
            state.mode = .fallback;
            return error.SlackStreamNotThreaded;
        };

        const chunks = try stream_presenter.splitForLimit(
            self.allocator,
            text,
            stream_presenter.STREAM_MARKDOWN_MAX_BYTES,
        );
        defer stream_presenter.freeChunks(self.allocator, chunks);

        const body = try stream_presenter.buildStartStreamBody(
            self.allocator,
            parsed.channel_id,
            thread_ts,
            chunks[0],
        );
        defer self.allocator.free(body);

        var result = try self.callSlackApi("chat.startStream", body, parsed.channel_id);
        defer result.deinit(self.allocator);

        if (result.error_code) |code| {
            try self.recordNativeStreamFailure(code);
            return error.SlackStreamRejected;
        }
        const ts = result.ts orelse return error.SlackStreamRejected;
        try state.setMessageTs(self.allocator, ts);

        for (chunks[1..]) |chunk| {
            try self.appendNativeStreamLocked(parsed, state, chunk);
        }
    }

    fn appendNativeStreamLocked(
        self: *SlackChannel,
        parsed: stream_presenter.StreamTarget,
        state: *StreamState,
        text: []const u8,
    ) !void {
        if (text.len == 0) return;

        const chunks = try stream_presenter.splitForLimit(
            self.allocator,
            text,
            stream_presenter.STREAM_MARKDOWN_MAX_BYTES,
        );
        defer stream_presenter.freeChunks(self.allocator, chunks);

        for (chunks) |chunk| {
            const body = try stream_presenter.buildAppendStreamBody(
                self.allocator,
                parsed.channel_id,
                state.message_ts,
                chunk,
            );
            defer self.allocator.free(body);

            var result = try self.callSlackApi("chat.appendStream", body, parsed.channel_id);
            defer result.deinit(self.allocator);
            if (result.error_code) |code| try self.recordNativeStreamFailure(code);
        }
    }

    /// Map an API error to the retry policy for this turn and for the account.
    fn recordNativeStreamFailure(self: *SlackChannel, code: []const u8) !void {
        if (stream_presenter.classifyStreamFailure(code) == .disable_native) {
            if (!self.native_stream_disabled.swap(true, .acq_rel)) {
                log.warn(
                    "Slack native streaming unavailable for this app ({s}); falling back to edited messages",
                    .{code},
                );
            }
        }
        return error.SlackStreamRejected;
    }

    fn postMessageForStream(
        self: *SlackChannel,
        parsed: stream_presenter.StreamTarget,
        text: []const u8,
    ) ![]u8 {
        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);
        try self.appendPostMessageBody(&body_list, parsed.channel_id, parsed.thread_ts, text);

        var result = try self.callSlackApi("chat.postMessage", body_list.items, parsed.channel_id);
        defer result.deinit(self.allocator);
        return result.takeTs() orelse error.SlackStreamRejected;
    }

    fn updateStreamMessage(
        self: *SlackChannel,
        parsed: stream_presenter.StreamTarget,
        ts: []const u8,
        markdown_text: []const u8,
    ) !void {
        const mrkdwn = try markdownToSlackMrkdwn(self.allocator, markdown_text);
        defer self.allocator.free(mrkdwn);

        // chat.update rejects text above 4,000 chars with `msg_too_long`. Bound
        // the in-place preview to that cap, keeping the newest text so a growing
        // turn keeps moving instead of freezing on its first chunk; the final
        // reply is still delivered complete by deliverFallbackFinal.
        const preview = try stream_presenter.boundUpdatePreview(
            self.allocator,
            mrkdwn,
            stream_presenter.STREAM_UPDATE_MAX_BYTES,
        );
        defer self.allocator.free(preview);

        try self.updateStreamMessageMrkdwn(parsed, ts, preview);
    }

    /// `chat.update` with text already converted to mrkdwn and known to fit the
    /// cap. The final reply uses this directly: re-converting and re-bounding it
    /// would silently drop the head of a chunk that expanded during conversion.
    fn updateStreamMessageMrkdwn(
        self: *SlackChannel,
        parsed: stream_presenter.StreamTarget,
        ts: []const u8,
        mrkdwn_text: []const u8,
    ) !void {
        const body = try stream_presenter.buildUpdateBody(self.allocator, parsed.channel_id, ts, mrkdwn_text);
        defer self.allocator.free(body);

        var result = try self.callSlackApi("chat.update", body, parsed.channel_id);
        defer result.deinit(self.allocator);
        if (result.error_code) |code| {
            if (stream_presenter.classifyStreamFailure(code) == .disable_native) {
                self.native_stream_disabled.store(true, .release);
            }
            return error.SlackStreamRejected;
        }
    }

    /// Deliver the authoritative final reply.
    ///
    /// The streamed text is only a preview: the model may have produced
    /// intermediate text before a tool call, and redaction rehydration can
    /// rewrite the reply after the last delta. When the streamed content is a
    /// prefix of the final text we append the remainder and stop the stream, so
    /// the message already shows the final reply. Otherwise the stream is
    /// stopped and the final reply is posted as its own message, which is what
    /// Telegram does for every turn.
    fn streamFinal(
        self: *SlackChannel,
        target: []const u8,
        message: []const u8,
        media: []const []const u8,
        force_rewrite: bool,
    ) !void {
        self.stream_mu.lock();
        defer self.stream_mu.unlock();

        const now_ms = std_compat.time.milliTimestamp();
        // Every queued delta was dequeued ahead of this final, so the stop marker
        // has done its job and must not leak into the next turn -- including a
        // turn that streamed nothing and returns early below without a state.
        self.clearStreamCancelLocked(target);
        const state = self.stream_states.getPtr(target) orelse
            return vtableSend(@ptrCast(self), target, message, media);
        // Keep the entry: late deltas of this turn are dropped by isLateChunk.
        defer state.finishTurn(self.allocator, now_ms);

        if (state.message_ts.len == 0) {
            // Nothing was ever flushed (short reply inside the throttle window),
            // or the fallback message could not be created.
            return vtableSend(@ptrCast(self), target, message, media);
        }

        const parsed = stream_presenter.resolveStreamTarget(target);

        if (state.mode == .native) {
            const suffix = stream_presenter.pendingFinalSuffix(message, state.sent);
            // The closing append must respect the same cumulative budget as the
            // live flushes: when the answer lands inside one throttle window the
            // whole remainder is appended in a single call, and chat.appendStream
            // would answer `msg_too_long` past Slack's message cap. Finish on the
            // edited-message transport instead so the answer is delivered intact.
            const over_budget = if (suffix) |s|
                stream_presenter.finalAppendOverflowsBudget(state.sent.len, s.len)
            else
                false;
            const stream_completed = if (!force_rewrite and suffix != null and !over_budget) blk: {
                self.appendNativeStreamLocked(parsed, state, suffix.?) catch |err| {
                    log.warn("Slack chat.appendStream final delta failed ({s})", .{@errorName(err)});
                    break :blk false;
                };
                break :blk true;
            } else false;

            self.stopNativeStream(parsed, state.message_ts) catch |err| {
                log.warn("Slack chat.stopStream failed ({s})", .{@errorName(err)});
            };
            if (stream_completed) return;
            // The preview streamed the raw attachment marker, which the final
            // text no longer contains. Rewrite the message in place instead of
            // leaving `[IMAGE:...]` visible and posting a second copy.
            if (force_rewrite) {
                return self.deliverFallbackFinal(parsed, state.message_ts, message, media, target);
            }
            // A streamed reasoning quote is deliberately absent from the final
            // reply, so that turn's snapshot can never be a prefix of it.
            // Rewrite the stopped message in place rather than leaving the
            // thinking behind and posting the reply a second time. The same
            // rewrite carries a final message that would overflow the stream
            // budget.
            if (state.rendered_reasoning or over_budget) {
                return self.deliverFallbackFinal(parsed, state.message_ts, message, media, target);
            }
            // When the stream could not be completed the streamed message keeps
            // an intermediate prefix, so the reply is posted again in full.
            return vtableSend(@ptrCast(self), target, message, media);
        }

        try self.deliverFallbackFinal(parsed, state.message_ts, message, media, target);
    }

    fn deliverFallbackFinal(
        self: *SlackChannel,
        parsed: stream_presenter.StreamTarget,
        ts: []const u8,
        message: []const u8,
        media: []const []const u8,
        target: []const u8,
    ) !void {
        const chunks = try chunkFinalFallbackReply(self.allocator, message);
        defer stream_presenter.freeChunks(self.allocator, chunks);

        self.updateStreamMessageMrkdwn(parsed, ts, chunks[0]) catch |err| {
            log.warn("Slack streaming final chat.update failed ({s})", .{@errorName(err)});
            return vtableSend(@ptrCast(self), target, message, media);
        };

        // Anything past the first chat.update-able slice goes out as follow-up
        // messages in the same thread.
        const followups = @min(chunks.len - 1, stream_presenter.STREAM_MAX_FOLLOWUPS);
        if (chunks.len - 1 > followups) {
            log.warn("Slack streaming reply truncated: {} overflow chunks dropped", .{chunks.len - 1 - followups});
        }
        for (chunks[1 .. 1 + followups]) |chunk| {
            self.postStreamFollowup(parsed, chunk) catch |err| {
                log.warn("Slack streaming follow-up post failed ({s})", .{@errorName(err)});
                break;
            };
        }
    }

    fn postStreamFollowup(
        self: *SlackChannel,
        parsed: stream_presenter.StreamTarget,
        mrkdwn_text: []const u8,
    ) !void {
        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);
        try self.appendPostMessageMrkdwnBody(&body_list, parsed.channel_id, parsed.thread_ts, mrkdwn_text);

        var result = try self.callSlackApi("chat.postMessage", body_list.items, parsed.channel_id);
        result.deinit(self.allocator);
    }

    fn stopNativeStream(
        self: *SlackChannel,
        parsed: stream_presenter.StreamTarget,
        ts: []const u8,
    ) !void {
        const body = try stream_presenter.buildStopStreamBody(self.allocator, parsed.channel_id, ts);
        defer self.allocator.free(body);

        var result = try self.callSlackApi("chat.stopStream", body, parsed.channel_id);
        defer result.deinit(self.allocator);
        if (builtin.is_test) self.test_native_stop_calls += 1;
        if (result.error_code) |code| try self.recordNativeStreamFailure(code);
    }

    /// POST a Slack Web API method and return the parsed `ts` / `error` fields.
    /// Transport and JSON failures surface as errors; API-level failures are
    /// reported through `error_code` so callers can apply a retry policy.
    fn callSlackApi(
        self: *SlackChannel,
        endpoint: []const u8,
        body: []const u8,
        context: ?[]const u8,
    ) !SlackApiResult {
        // Streaming outbound must never touch the network under `zig build test`;
        // the throttling/fallback state machine is covered through this stub.
        if (builtin.is_test) {
            return .{ .ts = try self.allocator.dupe(u8, "1700000000.000000") };
        }

        const url = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ API_BASE, endpoint });
        defer self.allocator.free(url);

        var auth_buf: [512]u8 = undefined;
        var auth_writer: std.Io.Writer = .fixed(&auth_buf);
        try auth_writer.print("Authorization: Bearer {s}", .{self.normalizedBotToken()});
        const auth_header = auth_writer.buffered();

        const resp = root.http_util.curlPost(self.allocator, url, body, &.{auth_header}) catch |err| {
            log.err("Slack {s} POST failed: {}", .{ endpoint, err });
            return error.SlackApiError;
        };
        defer self.allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch
            return error.SlackApiError;
        defer parsed.deinit();
        if (parsed.value != .object) return error.SlackApiError;

        var result = SlackApiResult{};
        errdefer result.deinit(self.allocator);
        if (parsed.value.object.get("ts")) |ts_val| {
            if (ts_val == .string and ts_val.string.len > 0) {
                result.ts = try self.allocator.dupe(u8, ts_val.string);
            }
        }
        if (parsed.value.object.get("upload_url")) |upload_url_val| {
            if (upload_url_val == .string and upload_url_val.string.len > 0) {
                result.upload_url = try self.allocator.dupe(u8, upload_url_val.string);
            }
        }
        if (parsed.value.object.get("file_id")) |file_id_val| {
            if (file_id_val == .string and file_id_val.string.len > 0) {
                result.file_id = try self.allocator.dupe(u8, file_id_val.string);
            }
        }
        if (slackApiErrorInfo(parsed.value.object)) |info| {
            logSlackApiError(endpoint, context, info);
            result.error_code = try self.allocator.dupe(u8, info.code);
        }
        return result;
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .sendEvent = &vtableSendEvent,
        .sendRich = &vtableSendRich,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
        .startTyping = &vtableStartTyping,
        .stopTyping = &vtableStopTyping,
        .setTaskReaction = &vtableSetTaskReaction,
        .supportsStreamingOutbound = &vtableSupportsStreamingOutbound,
        .cancelStreams = &vtableCancelStreams,
    };

    pub fn channel(self: *SlackChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

// ── Slack media helpers ─────────────────────────────────────────

const MAX_INBOUND_FILES: usize = 8;
const MAX_INBOUND_FILE_BYTES: usize = 20 * 1024 * 1024;
const MAX_OUTBOUND_FILE_BYTES: usize = 20 * 1024 * 1024;

const InboundFileKind = enum { image, audio, file };

const SlackFileInfo = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    mimetype: []const u8 = "",
    subtype: []const u8 = "",
    url_private: []const u8 = "",
    size: ?i64 = null,
};

fn asciiStartsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn jsonStringValue(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val != .string or val.string.len == 0) return null;
    return val.string;
}

fn parseSlackFileInfo(obj: std.json.ObjectMap) ?SlackFileInfo {
    const url_private = jsonStringValue(obj, "url_private") orelse "";
    const id = jsonStringValue(obj, "id") orelse "";
    const name = jsonStringValue(obj, "name") orelse "";
    const mimetype = jsonStringValue(obj, "mimetype") orelse "";
    const subtype = jsonStringValue(obj, "subtype") orelse "";
    // An entry with no metadata at all cannot produce a useful marker.
    if (url_private.len == 0 and id.len == 0 and name.len == 0 and mimetype.len == 0) return null;
    return .{
        .id = id,
        .name = name,
        .mimetype = mimetype,
        .subtype = subtype,
        .url_private = url_private,
        .size = blk: {
            const size_val = obj.get("size") orelse break :blk null;
            break :blk switch (size_val) {
                .integer => |n| if (n >= 0) n else null,
                else => null,
            };
        },
    };
}

fn looksLikeHtml(data: []const u8) bool {
    const head = std.mem.trimStart(u8, data[0..@min(data.len, 512)], " \t\r\n");
    return asciiStartsWithIgnoreCase(head, "<!doctype html") or asciiStartsWithIgnoreCase(head, "<html");
}

fn messageHasFiles(msg_obj: std.json.ObjectMap) bool {
    const files_val = msg_obj.get("files") orelse return false;
    return files_val == .array and files_val.array.items.len > 0;
}

fn slackFileExtension(name: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfAny(u8, name, "/\\")) |idx| name[idx + 1 ..] else name;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    if (dot + 1 >= base.len) return "";
    return base[dot + 1 ..];
}

fn isImageExtension(ext: []const u8) bool {
    const known = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff" };
    for (known) |item| {
        if (std.ascii.eqlIgnoreCase(ext, item)) return true;
    }
    return false;
}

fn isAudioExtension(ext: []const u8) bool {
    const known = [_][]const u8{ "mp3", "m4a", "wav", "ogg", "oga", "opus", "flac", "aac" };
    for (known) |item| {
        if (std.ascii.eqlIgnoreCase(ext, item)) return true;
    }
    return false;
}

/// Slack audio clips report subtype `slack_audio` but are served as `video/*`.
fn classifySlackFile(info: SlackFileInfo) InboundFileKind {
    if (asciiStartsWithIgnoreCase(info.mimetype, "image/")) return .image;
    if (std.mem.eql(u8, info.subtype, "slack_audio")) return .audio;
    if (asciiStartsWithIgnoreCase(info.mimetype, "audio/")) return .audio;

    const ext = slackFileExtension(info.name);
    if (isImageExtension(ext)) return .image;
    if (isAudioExtension(ext)) return .audio;
    return .file;
}

fn kindLabel(kind: InboundFileKind) []const u8 {
    return switch (kind) {
        .image => "image",
        .audio => "audio",
        .file => "document",
    };
}

/// Same fallback shape the Telegram inbound pipeline uses when a file cannot
/// be fetched or transcribed.
fn buildSlackAttachmentMetadata(allocator: std.mem.Allocator, kind: []const u8, info: SlackFileInfo) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    errdefer writer.deinit();
    const w = &writer.writer;

    try w.print("[ATTACHMENT:{s}", .{kind});
    if (info.name.len > 0) try w.print(" file_name={s}", .{info.name});
    if (info.mimetype.len > 0) try w.print(" mime_type={s}", .{info.mimetype});
    if (info.size) |size| try w.print(" file_size={d}", .{size});
    try w.writeByte(']');

    out = writer.toArrayList();
    return try out.toOwnedSlice(allocator);
}

/// `url_private` is fetched with the bot token, so only Slack's own HTTPS
/// hosts may receive it.
fn isAllowedSlackFileUrl(raw: []const u8) bool {
    if (raw.len == 0) return false;
    const uri = std.Uri.parse(raw) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return false;
    const host = net_security.extractHost(raw) orelse return false;

    const allowed = [_][]const u8{ "slack.com", "slack-edge.com", "slack-files.com", "slack-gov.com" };
    for (allowed) |suffix| {
        if (std.ascii.eqlIgnoreCase(host, suffix)) return true;
        if (host.len > suffix.len and
            host[host.len - suffix.len - 1] == '.' and
            std.ascii.eqlIgnoreCase(host[host.len - suffix.len ..], suffix))
        {
            return true;
        }
    }
    return false;
}

fn sanitizeSlackFileComponent(buf: []u8, raw: []const u8, max_len: usize) []const u8 {
    var n: usize = 0;
    for (raw) |ch| {
        if (n >= buf.len or n >= max_len) break;
        buf[n] = if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_') ch else '_';
        n += 1;
    }
    if (n == 0) {
        if (buf.len == 0) return "";
        buf[0] = '_';
        return buf[0..1];
    }
    return buf[0..n];
}

fn trimTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) : (end -= 1) {}
    return path[0..end];
}

/// Save an inbound attachment under a name the existing Telegram temp-media
/// sweeper recognises (`nullclaw_photo_` / `nullclaw_doc_`), so Slack files are
/// cleaned up by the same 24h TTL.
fn saveSlackTempFile(allocator: std.mem.Allocator, info: SlackFileInfo, data: []const u8) ?[]u8 {
    const tmp_dir = platform.getTempDir(allocator) catch return null;
    defer allocator.free(tmp_dir);

    var name_buf: [160]u8 = undefined;
    const safe_id = sanitizeSlackFileComponent(&name_buf, if (info.id.len > 0) info.id else "file", 80);
    const ext = slackFileExtension(info.name);
    const prefix = switch (classifySlackFile(info)) {
        .image => "nullclaw_photo_slack_",
        .audio, .file => "nullclaw_doc_slack_",
    };

    var path_buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&path_buf);
    const base = trimTrailingSlashes(tmp_dir);
    if (ext.len > 0) {
        w.print("{s}/{s}{s}.{s}", .{ base, prefix, safe_id, ext }) catch return null;
    } else {
        w.print("{s}/{s}{s}", .{ base, prefix, safe_id }) catch return null;
    }
    const path = w.buffered();

    const file = std_compat.fs.createFileAbsolute(path, .{}) catch |err| {
        log.warn("Slack inbound file save failed: {}", .{err});
        return null;
    };
    defer file.close();
    file.writeAll(data) catch return null;
    return allocator.dupe(u8, path) catch null;
}

fn attachmentFileName(target: []const u8) []const u8 {
    var path = target;
    if (std.mem.indexOf(u8, path, "://") != null) {
        const uri = std.Uri.parse(path) catch return "upload.bin";
        path = switch (uri.path) {
            .raw => |p| p,
            .percent_encoded => |p| p,
        };
    }
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |idx| path = path[idx + 1 ..];
    if (std.mem.indexOfAny(u8, path, "?#")) |idx| path = path[0..idx];
    if (path.len == 0) return "upload.bin";
    return path;
}

fn attachmentContentType(file_name: []const u8) []const u8 {
    const ext = slackFileExtension(file_name);
    const pairs = [_]struct { ext: []const u8, mime: []const u8 }{
        .{ .ext = "png", .mime = "image/png" },
        .{ .ext = "jpg", .mime = "image/jpeg" },
        .{ .ext = "jpeg", .mime = "image/jpeg" },
        .{ .ext = "gif", .mime = "image/gif" },
        .{ .ext = "webp", .mime = "image/webp" },
        .{ .ext = "pdf", .mime = "application/pdf" },
        .{ .ext = "txt", .mime = "text/plain" },
        .{ .ext = "csv", .mime = "text/csv" },
        .{ .ext = "json", .mime = "application/json" },
        .{ .ext = "zip", .mime = "application/zip" },
        .{ .ext = "mp4", .mime = "video/mp4" },
        .{ .ext = "mp3", .mime = "audio/mpeg" },
        .{ .ext = "m4a", .mime = "audio/mp4" },
        .{ .ext = "ogg", .mime = "audio/ogg" },
        .{ .ext = "wav", .mime = "audio/wav" },
    };
    for (pairs) |pair| {
        if (std.ascii.eqlIgnoreCase(ext, pair.ext)) return pair.mime;
    }
    return "application/octet-stream";
}

fn buildGetUploadUrlBody(allocator: std.mem.Allocator, file_name: []const u8, length: usize) ![]u8 {
    var body_list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body_list.deinit(allocator);
    var body_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &body_list);
    errdefer body_writer.deinit();
    const bw = &body_writer.writer;

    try bw.writeAll("{\"filename\":");
    try root.appendJsonStringW(bw, file_name);
    try bw.print(",\"length\":{d}}}", .{length});
    body_list = body_writer.toArrayList();
    return try body_list.toOwnedSlice(allocator);
}

fn buildCompleteUploadBody(
    allocator: std.mem.Allocator,
    file_id: []const u8,
    title: []const u8,
    channel_id: []const u8,
    thread_ts: ?[]const u8,
) ![]u8 {
    var body_list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body_list.deinit(allocator);
    var body_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &body_list);
    errdefer body_writer.deinit();
    const bw = &body_writer.writer;

    try bw.writeAll("{\"files\":[{\"id\":");
    try root.appendJsonStringW(bw, file_id);
    try bw.writeAll(",\"title\":");
    try root.appendJsonStringW(bw, title);
    try bw.writeAll("}],\"channel_id\":");
    try root.appendJsonStringW(bw, channel_id);
    if (thread_ts) |ts| {
        try bw.writeAll(",\"thread_ts\":");
        try root.appendJsonStringW(bw, ts);
    }
    try bw.writeByte('}');
    body_list = body_writer.toArrayList();
    return try body_list.toOwnedSlice(allocator);
}

fn buildDeleteMessageBody(allocator: std.mem.Allocator, channel_id: []const u8, ts: []const u8) ![]u8 {
    var body_list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body_list.deinit(allocator);
    var body_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &body_list);
    errdefer body_writer.deinit();
    const bw = &body_writer.writer;

    try bw.writeAll("{\"channel\":");
    try root.appendJsonStringW(bw, channel_id);
    try bw.writeAll(",\"ts\":");
    try root.appendJsonStringW(bw, ts);
    try bw.writeByte('}');
    body_list = body_writer.toArrayList();
    return try body_list.toOwnedSlice(allocator);
}

/// Strip a leading Slack mention of `user_id` from `text` and return the
/// trimmed remainder, or null when `text` does not start with that mention.
/// Slack's app_mention text in a channel has the form "<@UBOT> /stop".
fn stripLeadingMention(text: []const u8, user_id: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "<@")) return null;
    const rest = trimmed[2..];
    const end = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
    if (!std.mem.eql(u8, rest[0..end], user_id)) return null;
    return std.mem.trimStart(u8, rest[end + 1 ..], " \t\r\n");
}

/// Check if a message text contains a Slack mention of the given user ID.
/// Slack mentions use the format `<@U12345>`.
pub fn containsMention(text: []const u8, user_id: []const u8) bool {
    // Search for "<@USER_ID>" pattern
    var i: usize = 0;
    while (i + 3 + user_id.len <= text.len) {
        if (text[i] == '<' and text[i + 1] == '@') {
            const start = i + 2;
            if (start + user_id.len <= text.len and
                std.mem.eql(u8, text[start .. start + user_id.len], user_id) and
                start + user_id.len < text.len and text[start + user_id.len] == '>')
            {
                return true;
            }
        }
        i += 1;
    }
    return false;
}

/// Split the authoritative final reply for the edited-message transport.
///
/// Convert to mrkdwn before splitting: conversion can expand text ("- " ->
/// "• "), so splitting markdown first and converting each piece could push it
/// past chat.update's cap, where the live-preview tail bound would drop the
/// head of the final reply.
fn chunkFinalFallbackReply(allocator: std.mem.Allocator, message: []const u8) ![][]const u8 {
    const mrkdwn = try markdownToSlackMrkdwn(allocator, message);
    defer allocator.free(mrkdwn);
    return stream_presenter.splitForLimit(allocator, mrkdwn, stream_presenter.STREAM_UPDATE_MAX_BYTES);
}

/// Convert standard Markdown to Slack mrkdwn format.
///
/// Conversions:
///   **bold**         -> *bold*
///   ~~strike~~       -> ~strike~
///   ```code```       -> ```code``` (preserved)
///   `inline code`    -> `inline code` (preserved)
///   [text](url)      -> <url|text>
///   # Header         -> *Header*
///   - bullet         -> bullet (with bullet char)
pub fn markdownToSlackMrkdwn(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var line_start = true;

    while (i < input.len) {
        // ── Fenced code blocks (```) — preserve as-is ──
        if (i + 3 <= input.len and std.mem.eql(u8, input[i..][0..3], "```")) {
            try result.appendSlice(allocator, input[i..][0..3]);
            i += 3;
            // Copy everything until closing ```
            while (i < input.len) {
                if (i + 3 <= input.len and std.mem.eql(u8, input[i..][0..3], "```")) {
                    try result.appendSlice(allocator, input[i..][0..3]);
                    i += 3;
                    break;
                }
                try result.append(allocator, input[i]);
                i += 1;
            }
            line_start = false;
            continue;
        }

        // ── Headers at start of line: "# " -> bold ──
        if (line_start and i < input.len and input[i] == '#') {
            var hashes: usize = 0;
            var hi = i;
            while (hi < input.len and input[hi] == '#') {
                hashes += 1;
                hi += 1;
            }
            if (hashes > 0 and hi < input.len and input[hi] == ' ') {
                hi += 1; // skip space after #
                // Find end of line
                var end = hi;
                while (end < input.len and input[end] != '\n') {
                    end += 1;
                }
                try result.append(allocator, '*');
                try result.appendSlice(allocator, input[hi..end]);
                try result.append(allocator, '*');
                i = end;
                line_start = false;
                continue;
            }
        }

        // ── Bullet points at start of line: "- " -> "* " ──
        if (line_start and i + 1 < input.len and input[i] == '-' and input[i + 1] == ' ') {
            try result.appendSlice(allocator, "\xe2\x80\xa2 "); // bullet char U+2022
            i += 2;
            line_start = false;
            continue;
        }

        // ── Bold: **text** -> *text* ──
        if (i + 2 <= input.len and std.mem.eql(u8, input[i..][0..2], "**")) {
            // Find closing **
            const start = i + 2;
            if (std.mem.indexOf(u8, input[start..], "**")) |close_offset| {
                try result.append(allocator, '*');
                try result.appendSlice(allocator, input[start .. start + close_offset]);
                try result.append(allocator, '*');
                i = start + close_offset + 2;
                line_start = false;
                continue;
            }
        }

        // ── Strikethrough: ~~text~~ -> ~text~ ──
        if (i + 2 <= input.len and std.mem.eql(u8, input[i..][0..2], "~~")) {
            const start = i + 2;
            if (std.mem.indexOf(u8, input[start..], "~~")) |close_offset| {
                try result.append(allocator, '~');
                try result.appendSlice(allocator, input[start .. start + close_offset]);
                try result.append(allocator, '~');
                i = start + close_offset + 2;
                line_start = false;
                continue;
            }
        }

        // ── Inline code: `code` -> `code` (preserved) ──
        if (i < input.len and input[i] == '`') {
            try result.append(allocator, '`');
            i += 1;
            while (i < input.len and input[i] != '`') {
                try result.append(allocator, input[i]);
                i += 1;
            }
            if (i < input.len) {
                try result.append(allocator, '`');
                i += 1;
            }
            line_start = false;
            continue;
        }

        // ── Links: [text](url) -> <url|text> ──
        if (i < input.len and input[i] == '[') {
            const text_start = i + 1;
            if (std.mem.indexOfScalar(u8, input[text_start..], ']')) |close_bracket_offset| {
                const text_end = text_start + close_bracket_offset;
                const after_bracket = text_end + 1;
                if (after_bracket < input.len and input[after_bracket] == '(') {
                    const url_start = after_bracket + 1;
                    if (std.mem.indexOfScalar(u8, input[url_start..], ')')) |close_paren_offset| {
                        const url_end = url_start + close_paren_offset;
                        try result.append(allocator, '<');
                        try result.appendSlice(allocator, input[url_start..url_end]);
                        try result.append(allocator, '|');
                        try result.appendSlice(allocator, input[text_start..text_end]);
                        try result.append(allocator, '>');
                        i = url_end + 1;
                        line_start = false;
                        continue;
                    }
                }
            }
        }

        // ── Track newlines for line_start ──
        if (input[i] == '\n') {
            try result.append(allocator, '\n');
            i += 1;
            line_start = true;
            continue;
        }

        // ── Default: copy character ──
        try result.append(allocator, input[i]);
        i += 1;
        line_start = false;
    }

    return result.toOwnedSlice(allocator);
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "slack channel init defaults" {
    const allowed = [_][]const u8{"U123"};
    var ch = SlackChannel.init(std.testing.allocator, "xoxb-test", null, "C123", &allowed);
    try std.testing.expectEqualStrings("xoxb-test", ch.bot_token);
    try std.testing.expectEqualStrings("C123", ch.channel_id.?);
    try std.testing.expectEqualStrings("0", ch.last_ts);
    try std.testing.expect(ch.thread_ts == null);
    try std.testing.expect(ch.app_token == null);
    _ = ch.channelName();
}

test "slack native stream finishes on the fallback transport past the message budget" {
    // Slack caps the whole streamed message, so a long turn must leave the
    // native transport before chat.appendStream answers `msg_too_long`; the
    // edited-message transport (chat.update + thread follow-ups) then carries
    // the final answer intact.
    const allocator = std.testing.allocator;
    const allowed = [_][]const u8{"U123"};
    var ch = SlackChannel.init(allocator, "xoxb-test", null, "C123", &allowed);
    defer stream_presenter.deinitStreamStates(allocator, &ch.stream_states);

    const target = "C123:1700000000.000100";
    const big = "x" ** (stream_presenter.STREAM_TOTAL_MAX_BYTES + 1);
    ch.streamChunk(target, big);

    const state = ch.stream_states.getPtr(target) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(stream_presenter.StreamMode.fallback, state.mode);
    try std.testing.expect(state.message_ts.len > 0);
}

test "slack native stream leaves for the fallback transport when a later flush crosses the budget" {
    // Start the native stream with a sub-budget chunk, then cross the cumulative
    // budget on a later flush: the stream must be closed and the turn finished
    // on the edited-message transport, with the message ts kept for the rewrite.
    const allocator = std.testing.allocator;
    const allowed = [_][]const u8{"U123"};
    var ch = SlackChannel.init(allocator, "xoxb-test", null, "C123", &allowed);
    defer stream_presenter.deinitStreamStates(allocator, &ch.stream_states);

    const target = "C123:1700000000.000100";
    const part = "x" ** 7_000;
    ch.streamChunk(target, part);
    const first = ch.stream_states.getPtr(target) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(stream_presenter.StreamMode.native, first.mode);
    try std.testing.expect(first.message_ts.len > 0);

    // Force the next flush past the coalescing window without waiting a second.
    first.last_flush_time = 0;
    ch.streamChunk(target, part);

    const second = ch.stream_states.getPtr(target) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(stream_presenter.StreamMode.fallback, second.mode);
    try std.testing.expect(second.message_ts.len > 0);
}

test "slack initFromConfig maps pairing dm_policy to allowlist" {
    const cfg = config_types.SlackConfig{
        .account_id = "main",
        .mode = .socket,
        .bot_token = "xoxb-test",
        .app_token = "xapp-test",
        .dm_policy = "pairing",
        .group_policy = "mention_only",
        .allow_from = &.{"U123"},
    };
    const ch = SlackChannel.initFromConfig(std.testing.allocator, cfg);
    try std.testing.expectEqual(root.DmPolicy.allowlist, ch.policy.dm);
    try std.testing.expectEqual(config_types.SlackReceiveMode.socket, ch.mode);
    try std.testing.expectEqualStrings(SlackChannel.DEFAULT_WEBHOOK_PATH, ch.webhook_path);
}

test "slack initFromConfig unknown dm_policy fails closed to allowlist" {
    const cfg = config_types.SlackConfig{
        .account_id = "main",
        .mode = .socket,
        .bot_token = "xoxb-test",
        .app_token = "xapp-test",
        .dm_policy = "something-unknown",
        .group_policy = "mention_only",
        .allow_from = &.{"U123"},
    };
    const ch = SlackChannel.initFromConfig(std.testing.allocator, cfg);
    try std.testing.expectEqual(root.DmPolicy.allowlist, ch.policy.dm);
}

test "slack initFromConfig stores http mode signing secret and webhook path" {
    const cfg = config_types.SlackConfig{
        .account_id = "sl-http",
        .mode = .http,
        .bot_token = "xoxb-test",
        .signing_secret = "sign-secret",
        .webhook_path = "/slack/custom-events",
    };
    const ch = SlackChannel.initFromConfig(std.testing.allocator, cfg);
    try std.testing.expectEqual(config_types.SlackReceiveMode.http, ch.mode);
    try std.testing.expectEqualStrings("sign-secret", ch.signing_secret.?);
    try std.testing.expectEqualStrings("/slack/custom-events", ch.webhook_path);
}

test "slack channel name" {
    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    try std.testing.expectEqualStrings("slack", ch.channelName());
}

test "slack channel health check" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    try std.testing.expect(!ch.healthCheck());

    const Noop = struct {
        fn run() void {}
    };
    const t = try std.Thread.spawn(.{}, Noop.run, .{});
    defer t.join();

    ch.running.store(true, .release);
    ch.poll_thread = t;
    defer ch.poll_thread = null;
    try std.testing.expect(ch.healthCheck());
}

test "slack socket published after stop is shut down without stealing close ownership" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi or
        @TypeOf(std.posix.system.socketpair) == void)
    {
        return error.SkipZigTest;
    } else {
        const sockets = try websocket.createTestSocketPair();
        defer std.Io.Threaded.closeFd(sockets[0]);
        defer std.Io.Threaded.closeFd(sockets[1]);

        var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &.{});
        ch.running.store(false, .release);

        // Regression: close() before joining could leave a blocked reader alive and
        // let the later WsClient.deinit double-close a reused descriptor.
        try std.testing.expect(!ch.publishSocket(sockets[0]));
        try std.testing.expectEqual(invalid_socket, ch.ws_fd.load(.acquire));

        var byte: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 0), try std.posix.read(sockets[1], &byte));
    }
}

test "slack socket thread stack size is 2MB" {
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), SlackChannel.SOCKET_THREAD_STACK_SIZE);
}

test "slack fallback to polling when app token is missing and polling targets exist" {
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, "C123", &.{});
    try std.testing.expect(ch.shouldUsePollingFallbackForSocketStart());
}

test "slack fallback to polling when app token is empty and polling targets exist" {
    var ch = SlackChannel.init(std.testing.allocator, "tok", "   ", "C123", &.{});
    try std.testing.expect(ch.shouldUsePollingFallbackForSocketStart());
}

test "slack does not fallback to polling without channel targets" {
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &.{});
    try std.testing.expect(!ch.shouldUsePollingFallbackForSocketStart());
}

test "slack sticky fallback flag keeps polling mode when targets exist" {
    var ch = SlackChannel.init(std.testing.allocator, "tok", "xapp-valid", "C123", &.{});
    ch.socket_fallback_to_polling.store(true, .release);
    try std.testing.expect(ch.shouldUsePollingFallbackForSocketStart());
}

test "slack socket reconnect does not count toward fallback failures" {
    try std.testing.expect(!SlackChannel.shouldCountSocketFailure(error.ShouldReconnect));
    try std.testing.expect(SlackChannel.shouldCountSocketFailure(error.SlackApiError));
    try std.testing.expect(SlackChannel.shouldCountSocketFailure(error.SlackAppTokenRequired));
}

test "slack auth failure code classification" {
    try std.testing.expect(SlackChannel.isAuthFailureCode("invalid_auth"));
    try std.testing.expect(SlackChannel.isAuthFailureCode("not_authed"));
    try std.testing.expect(SlackChannel.isAuthFailureCode("missing_scope"));
    try std.testing.expect(SlackChannel.isAuthFailureCode("not_allowed_token_type"));
    try std.testing.expect(!SlackChannel.isAuthFailureCode("rate_limited"));
}

test "ensureSlackApiOk maps auth failures to SlackAuthFailed" {
    const payload =
        \\{"ok":false,"error":"missing_scope","needed":"chat:write","provided":"commands"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.SlackAuthFailed,
        SlackChannel.ensureSlackApiOk(parsed.value.object, "chat.postMessage", "C123"),
    );
}

test "ensureSlackApiOk maps non-auth failures to SlackApiError" {
    const payload =
        \\{"ok":false,"error":"channel_not_found"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.SlackApiError,
        SlackChannel.ensureSlackApiOk(parsed.value.object, "chat.postMessage", "C123"),
    );
}

test "hasValidBotToken rejects blank token" {
    var ch = SlackChannel.init(std.testing.allocator, "   ", null, null, &.{});
    try std.testing.expect(!ch.hasValidBotToken());
}

test "normalized token helpers trim whitespace" {
    var ch = SlackChannel.init(std.testing.allocator, "  xoxb-test \n", "\t xapp-1-A123-xyz  ", null, &.{});
    try std.testing.expectEqualStrings("xoxb-test", ch.normalizedBotToken());
    try std.testing.expectEqualStrings("xapp-1-A123-xyz", ch.normalizedAppToken().?);
}

test "parseApiAppIdFromAppToken extracts id" {
    const parsed = SlackChannel.parseApiAppIdFromAppToken(" xapp-1-a1b2c3-token ");
    try std.testing.expect(parsed != null);
    try std.testing.expectEqualStrings("a1b2c3", parsed.?);
}

test "parseApiAppIdFromAppToken rejects malformed tokens" {
    try std.testing.expect(SlackChannel.parseApiAppIdFromAppToken("") == null);
    try std.testing.expect(SlackChannel.parseApiAppIdFromAppToken("xoxb-123") == null);
    try std.testing.expect(SlackChannel.parseApiAppIdFromAppToken("xapp-no-version-A123-foo") == null);
    try std.testing.expect(SlackChannel.parseApiAppIdFromAppToken("xapp-1--foo") == null);
    try std.testing.expect(SlackChannel.parseApiAppIdFromAppToken("xapp-1-A123") == null);
}

test "ensureSocketTokenPairMatches rejects mismatched api_app_id" {
    var ch = SlackChannel.init(std.testing.allocator, "xoxb-test", "xapp-1-B222-foo", null, &.{});
    ch.mode = .socket;
    ch.bot_api_app_id = try std.testing.allocator.dupe(u8, "A111");
    defer {
        if (ch.bot_api_app_id) |api_app_id| std.testing.allocator.free(api_app_id);
        ch.bot_api_app_id = null;
    }

    try std.testing.expectError(error.SlackAuthFailed, ch.ensureSocketTokenPairMatches());
}

test "ensureSocketTokenPairMatches accepts matching api_app_id ignoring case" {
    var ch = SlackChannel.init(std.testing.allocator, "xoxb-test", "xapp-1-a111-foo", null, &.{});
    ch.mode = .socket;
    ch.bot_api_app_id = try std.testing.allocator.dupe(u8, "A111");
    defer {
        if (ch.bot_api_app_id) |api_app_id| std.testing.allocator.free(api_app_id);
        ch.bot_api_app_id = null;
    }

    try ch.ensureSocketTokenPairMatches();
}

test "shouldDropMismatchedSocketEvent drops api_app_id mismatch" {
    var ch = SlackChannel.init(std.testing.allocator, "xoxb-test", "xapp-1-A111-foo", null, &.{});
    ch.bot_api_app_id = try std.testing.allocator.dupe(u8, "A111");
    defer {
        if (ch.bot_api_app_id) |api_app_id| std.testing.allocator.free(api_app_id);
        ch.bot_api_app_id = null;
    }

    const payload =
        \\{"api_app_id":"A222","team_id":"T1"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(ch.shouldDropMismatchedSocketEvent(parsed.value.object));
}

test "shouldDropMismatchedSocketEvent drops team_id mismatch" {
    var ch = SlackChannel.init(std.testing.allocator, "xoxb-test", "xapp-1-A111-foo", null, &.{});
    ch.bot_team_id = try std.testing.allocator.dupe(u8, "T111");
    defer {
        if (ch.bot_team_id) |team_id| std.testing.allocator.free(team_id);
        ch.bot_team_id = null;
    }

    const payload =
        \\{"api_app_id":"A111","team_id":"T222"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(ch.shouldDropMismatchedSocketEvent(parsed.value.object));
}

test "shouldDropMismatchedSocketEvent keeps matching scope" {
    var ch = SlackChannel.init(std.testing.allocator, "xoxb-test", "xapp-1-A111-foo", null, &.{});
    ch.bot_api_app_id = try std.testing.allocator.dupe(u8, "A111");
    ch.bot_team_id = try std.testing.allocator.dupe(u8, "T111");
    defer {
        if (ch.bot_api_app_id) |api_app_id| std.testing.allocator.free(api_app_id);
        ch.bot_api_app_id = null;
        if (ch.bot_team_id) |team_id| std.testing.allocator.free(team_id);
        ch.bot_team_id = null;
    }

    const payload =
        \\{"api_app_id":"A111","team_id":"T111"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(!ch.shouldDropMismatchedSocketEvent(parsed.value.object));
}

test "slack channel user allowed wildcard" {
    const allowed = [_][]const u8{"*"};
    const ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    try std.testing.expect(ch.isUserAllowed("anyone"));
}

test "slack channel user denied" {
    const allowed = [_][]const u8{"alice"};
    const ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    try std.testing.expect(!ch.isUserAllowed("bob"));
}

test "thread_ts field defaults to null" {
    const allowed = [_][]const u8{};
    const ch = SlackChannel.init(std.testing.allocator, "tok", null, "C1", &allowed);
    try std.testing.expect(ch.thread_ts == null);
}

test "setThreadTs sets and clears thread_ts" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, "C1", &allowed);

    ch.setThreadTs("1234567890.123456");
    try std.testing.expectEqualStrings("1234567890.123456", ch.thread_ts.?);

    ch.setThreadTs(null);
    try std.testing.expect(ch.thread_ts == null);
}

test "setThreadTs overwrites previous value" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, "C1", &allowed);

    ch.setThreadTs("111.111");
    try std.testing.expectEqualStrings("111.111", ch.thread_ts.?);

    ch.setThreadTs("222.222");
    try std.testing.expectEqualStrings("222.222", ch.thread_ts.?);
}

test "setChannelLastTs keeps independent cursors for multi-channel polling" {
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, "C1,C2", &.{});
    defer ch.clearChannelCursors();

    try ch.setChannelLastTs("C1", "111.111");
    try ch.setChannelLastTs("C2", "222.222");

    try std.testing.expectEqualStrings("111.111", ch.channelLastTs("C1"));
    try std.testing.expectEqualStrings("222.222", ch.channelLastTs("C2"));
    try std.testing.expectEqualStrings("0", ch.channelLastTs("C3"));
}

test "parseTarget without colon returns full target" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);

    const result = ch.parseTarget("C12345");
    try std.testing.expectEqualStrings("C12345", result);
    try std.testing.expect(ch.thread_ts == null);
}

test "parseTarget with colon splits channel and thread_ts" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);

    const result = ch.parseTarget("C12345:1699999999.000100");
    try std.testing.expectEqualStrings("C12345", result);
    try std.testing.expectEqualStrings("1699999999.000100", ch.thread_ts.?);
}

test "parseTarget colon at end clears thread_ts" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);

    const result = ch.parseTarget("C999:");
    try std.testing.expectEqualStrings("C999", result);
    try std.testing.expect(ch.thread_ts == null);
}

test "parseTarget clears stale thread_ts for non-thread target" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);

    _ = ch.parseTarget("C12345:1699999999.000100");
    try std.testing.expectEqualStrings("1699999999.000100", ch.thread_ts.?);

    const result = ch.parseTarget("C12345");
    try std.testing.expectEqualStrings("C12345", result);
    try std.testing.expect(ch.thread_ts == null);
}

test "slack setThreadStatus is no-op in tests" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    ch.setThreadStatus("C12345", "1700000000.100", "is typing...");
}

test "slack buildThreadStatusRequestBody includes non-empty body" {
    const alloc = std.testing.allocator;
    // Regression: Writer.Allocating must be finalized before Slack status POST reads the body.
    const body = try buildThreadStatusRequestBody(alloc, "C12345", "1700000000.100", "is typing...");
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{\"channel_id\":\"C12345\",\"thread_ts\":\"1700000000.100\",\"status\":\"is typing...\"}", body);
}

test "slack startTyping and stopTyping are safe in tests" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    ch.running.store(true, .release);
    try ch.startTyping("C12345:1700000000.100");
    try ch.stopTyping("C12345:1700000000.100");
}

test "slack processHistoryMessage publishes inbound message to bus" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C12345", &allowed);
    ch.account_id = "sl-main";
    ch.setBus(&eb);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"user":"U123","text":"hello from slack","ts":"1700000000.100","thread_ts":"1700000000.000"}
    ,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    try ch.processHistoryMessage(parsed.value.object, "C12345");

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("slack", msg.channel);
    try std.testing.expectEqualStrings("U123", msg.sender_id);
    // thread_ts (1700000000.000) != ts (1700000000.100) → thread reply; chat_id includes thread_ts
    try std.testing.expectEqualStrings("C12345:1700000000.000", msg.chat_id);
    try std.testing.expectEqualStrings("slack:sl-main:channel:C12345", msg.session_key);
    try std.testing.expectEqualStrings("hello from slack", msg.content);
    try std.testing.expect(msg.metadata_json != null);
    const meta = try std.json.parseFromSlice(std.json.Value, alloc, msg.metadata_json.?, .{});
    defer meta.deinit();
    try std.testing.expect(meta.value == .object);
    try std.testing.expectEqualStrings("1700000000.100", meta.value.object.get("message_id").?.string);
    try std.testing.expectEqualStrings("1700000000.000", meta.value.object.get("thread_id").?.string);
}

test "processHistoryMessage strips a leading bot mention before publishing" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.bot_user_id = try alloc.dupe(u8, "UBOT");
    defer alloc.free(ch.bot_user_id.?);
    ch.setBus(&eb);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"user":"U1","text":"<@UBOT> /stop","ts":"1700000000.100","channel":"C1"}
    ,
        .{},
    );
    defer parsed.deinit();

    try ch.processHistoryMessage(parsed.value.object, "C1");

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    // Regression: a "<@BOT> /stop" that had to queue behind earlier work was
    // published with the mention, so the daemon treated it as ordinary text
    // instead of a stop command.
    try std.testing.expectEqualStrings("/stop", msg.content);
}

test "processHistoryMessage off mode top-level post uses channel_id as chat_id" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C99", &allowed);
    ch.account_id = "sl-main";
    ch.setBus(&eb);
    // reply_to_mode defaults to .off

    // thread_ts == ts: top-level post that started a thread, not a reply
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"user":"U1","text":"hi","ts":"1700000001.000","thread_ts":"1700000001.000"}
    , .{});
    defer parsed.deinit();

    try ch.processHistoryMessage(parsed.value.object, "C99");

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("C99", msg.chat_id);
}

test "processHistoryMessage off mode no thread_ts uses channel_id as chat_id" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C99", &allowed);
    ch.account_id = "sl-main";
    ch.setBus(&eb);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"user":"U1","text":"hi","ts":"1700000001.000"}
    , .{});
    defer parsed.deinit();

    try ch.processHistoryMessage(parsed.value.object, "C99");

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("C99", msg.chat_id);
}

test "processHistoryMessage all mode no thread_ts uses message_ts as thread" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C99", &allowed);
    ch.account_id = "sl-main";
    ch.reply_to_mode = .all;
    ch.setBus(&eb);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"user":"U1","text":"hi","ts":"1700000001.000"}
    , .{});
    defer parsed.deinit();

    try ch.processHistoryMessage(parsed.value.object, "C99");

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("C99:1700000001.000", msg.chat_id);
}

test "processHistoryMessage all mode with thread_ts uses thread_ts" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C99", &allowed);
    ch.account_id = "sl-main";
    ch.reply_to_mode = .all;
    ch.setBus(&eb);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"user":"U1","text":"hi","ts":"1700000002.000","thread_ts":"1700000001.000"}
    , .{});
    defer parsed.deinit();

    try ch.processHistoryMessage(parsed.value.object, "C99");

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("C99:1700000001.000", msg.chat_id);
}

test "mrkdwn bold conversion" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "This is **bold** text");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("This is *bold* text", result);
}

test "mrkdwn strikethrough conversion" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "This is ~~deleted~~ text");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("This is ~deleted~ text", result);
}

test "mrkdwn inline code preserved" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "Use `fmt.Println` here");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Use `fmt.Println` here", result);
}

test "mrkdwn code block preserved" {
    const input = "Before\n```\ncode here\n```\nAfter";
    const result = try markdownToSlackMrkdwn(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "mrkdwn link conversion" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "Visit [Google](https://google.com) now");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Visit <https://google.com|Google> now", result);
}

test "mrkdwn header conversion" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "# My Header");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("*My Header*", result);
}

test "mrkdwn h2 header conversion" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "## Sub Header");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("*Sub Header*", result);
}

test "mrkdwn bullet conversion" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "- item one\n- item two");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\xe2\x80\xa2 item one\n\xe2\x80\xa2 item two", result);
}

test "mrkdwn combined bold and strikethrough" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "**bold** and ~~strike~~");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("*bold* and ~strike~", result);
}

test "mrkdwn combined link and bold" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "**Click** [here](https://example.com)");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("*Click* <https://example.com|here>", result);
}

test "mrkdwn empty input" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "mrkdwn plain text unchanged" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "Hello world, no markdown here.");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello world, no markdown here.", result);
}

test "mrkdwn multiple headers" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "# Title\n## Subtitle");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("*Title*\n*Subtitle*", result);
}

test "mrkdwn link with special chars in text" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "[my site!](https://example.com/path?q=1)");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<https://example.com/path?q=1|my site!>", result);
}

test "mrkdwn bullets with bold items" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "- **first**\n- second");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\xe2\x80\xa2 *first*\n\xe2\x80\xa2 second", result);
}

test "slack channel vtable compiles" {
    const vt = SlackChannel.vtable;
    try std.testing.expect(@TypeOf(vt) == root.Channel.VTable);
}

// ════════════════════════════════════════════════════════════════════════════
// Streaming outbound
//
// `callSlackApi` is stubbed under `builtin.is_test`, so these tests drive the
// whole start/append/stop and postMessage/update state machine without network.
// ════════════════════════════════════════════════════════════════════════════

fn initStreamingChannel(streaming: bool) SlackChannel {
    return SlackChannel.initFromConfig(std.testing.allocator, .{
        .account_id = "sl-main",
        .bot_token = "xoxb-test",
        .streaming = streaming,
    });
}

test "slack streaming is disabled by default" {
    var ch = SlackChannel.initFromConfig(std.testing.allocator, .{ .bot_token = "xoxb-test" });
    defer ch.channel().stop();

    try std.testing.expect(!ch.streaming_enabled);
    try std.testing.expect(!ch.channel().supportsStreamingOutbound());
}

test "slack initFromConfig enables streaming from config" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();

    try std.testing.expect(ch.streaming_enabled);
    try std.testing.expect(ch.channel().supportsStreamingOutbound());
}

test "slack streaming chunk opens a native stream for a thread target" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();

    try ch.channel().sendEvent("C1:1700.1", "x" ** 200, &.{}, .chunk);

    const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(stream_presenter.StreamMode.native, state.mode);
    try std.testing.expect(!state.send_failed);
    try std.testing.expectEqualStrings("1700000000.000000", state.message_ts);
}

test "slack streaming keeps the native path across chunks of one turn" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();

    try ch.channel().sendEvent("C1:1700.1", "x" ** 200, &.{}, .chunk);
    // A second delta inside the flush window is coalesced rather than sent, but
    // the turn must keep using the native transport.
    try ch.channel().sendEvent("C1:1700.1", "y" ** 200, &.{}, .chunk);

    const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(stream_presenter.StreamMode.native, state.mode);
    try std.testing.expectEqualStrings("x" ** 200, state.sent);
}

test "slack streaming uses edited messages when the target has no thread" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();

    try ch.channel().sendEvent("C1", "x" ** 200, &.{}, .chunk);

    const state = ch.stream_states.getPtr("C1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(stream_presenter.StreamMode.fallback, state.mode);
    try std.testing.expectEqualStrings("1700000000.000000", state.message_ts);
}

test "slack streaming uses edited messages when native streaming is disabled" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();
    ch.native_stream_disabled.store(true, .release);

    try ch.channel().sendEvent("C1:1700.1", "x" ** 200, &.{}, .chunk);

    const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(stream_presenter.StreamMode.fallback, state.mode);
}

test "slack streaming final appends the remainder and closes the stream" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();
    const iface = ch.channel();

    try iface.sendEvent("C1:1700.1", "x" ** 200, &.{}, .chunk);
    // The final reply extends the streamed prefix, so no second message is posted.
    try iface.sendEvent("C1:1700.1", ("x" ** 200) ++ " done", &.{}, .final);

    const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(state.finished_at_ms != 0);
    try std.testing.expectEqual(@as(usize, 0), state.buffer.items.len);
}

test "slack streaming final posts the reply when it diverges from the stream" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();
    const iface = ch.channel();

    try iface.sendEvent("C1:1700.1", "x" ** 200, &.{}, .chunk);
    // The model emitted text before a tool call, so the final reply is not an
    // extension of the streamed prefix and is delivered as its own message.
    try iface.sendEvent("C1:1700.1", "unrelated answer", &.{}, .final);

    const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(state.finished_at_ms != 0);
}

test "slack streaming final rewrites the message after streamed reasoning" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();
    const iface = ch.channel();

    // reasoning_mode == .stream: the streamed preview carries the quoted
    // thinking, which the final reply deliberately omits, so the snapshot can
    // never be a prefix of it. The stopped message is rewritten in place with
    // chat.update instead of posting the reply as a second message.
    try iface.sendEvent("C1:1700.1", "<think>weighing the options</think>", &.{}, .chunk);
    try iface.sendEvent("C1:1700.1", "final answer", &.{}, .final);

    const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(state.finished_at_ms != 0);
    try std.testing.expect(!state.rendered_reasoning);
}

test "slack streaming drops deltas that arrive after the final reply" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();
    const iface = ch.channel();

    try iface.sendEvent("C1:1700.1", "x" ** 200, &.{}, .chunk);
    try iface.sendEvent("C1:1700.1", ("x" ** 200) ++ " done", &.{}, .final);

    // Regression: the durable outbox worker can deliver the final reply before
    // the outbound dispatcher has drained the last deltas of the same turn.
    // Those leftovers must not open a second stream.
    try iface.sendEvent("C1:1700.1", "late tail deltas" ** 20, &.{}, .chunk);

    const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), state.buffer.items.len);
}

test "slack streaming drops queued chunks for a cancelled target" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();
    const iface = ch.channel();

    // The turn opened a stream, then the user hit /stop.
    try iface.sendEvent("C1:1700.1", "x" ** 200, &.{}, .chunk);
    {
        // Advance the flush clock past the 1s floor so the next delta would reach
        // the wire (and grow state.sent) if the cancel did not drop it.
        const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
        state.last_flush_time -= stream_presenter.STREAM_FLUSH_MIN_INTERVAL_MS + 1;
    }
    iface.cancelStreams("C1:1700.1");

    // Regression: deltas already queued ahead of the /stop must not replay once
    // the outbound dispatcher catches up.
    try iface.sendEvent("C1:1700.1", "y" ** 200, &.{}, .chunk);

    const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("x" ** 200, state.sent);
}

test "slack streaming flushes a later delta past the interval when not cancelled" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();
    const iface = ch.channel();

    // Positive control for the cancelled-target test above: the same clock
    // advance with no /stop must let the delta through, proving the cancel is
    // what dropped it.
    try iface.sendEvent("C1:1700.1", "x" ** 200, &.{}, .chunk);
    {
        const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
        state.last_flush_time -= stream_presenter.STREAM_FLUSH_MIN_INTERVAL_MS + 1;
    }

    try iface.sendEvent("C1:1700.1", "y" ** 200, &.{}, .chunk);

    const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(("x" ** 200) ++ ("y" ** 200), state.sent);
}

test "slack streaming final without streaming enabled is delivered complete" {
    var ch = initStreamingChannel(false);
    defer ch.channel().stop();
    const iface = ch.channel();

    try iface.sendEvent("C1:1700.1", "x" ** 200, &.{}, .chunk);
    try iface.sendEvent("C1:1700.1", "complete reply", &.{}, .final);

    try std.testing.expectEqual(@as(usize, 0), ch.stream_states.count());
}

test "slack streaming final updates the fallback message in place" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();
    const iface = ch.channel();

    try iface.sendEvent("C1", "x" ** 200, &.{}, .chunk);
    try iface.sendEvent("C1", ("x" ** 200) ++ " tail", &.{}, .final);

    const state = ch.stream_states.getPtr("C1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(state.finished_at_ms != 0);
}

test "slack streaming final splits overflowing fallback replies" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();
    const iface = ch.channel();

    const long = "z" ** (stream_presenter.STREAM_UPDATE_MAX_BYTES * 3);
    try iface.sendEvent("C1", "x" ** 200, &.{}, .chunk);
    try iface.sendEvent("C1", long, &.{}, .final);

    const state = ch.stream_states.getPtr("C1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(state.finished_at_ms != 0);
}

test "slack final fallback chunks converted mrkdwn without losing content" {
    // Regression: the final reply was split as markdown and then converted, so
    // a chunk that expanded past chat.update's cap ("- " -> "• ") was
    // tail-truncated by the preview bound and lost its head.
    var message: std.ArrayListUnmanaged(u8) = .empty;
    defer message.deinit(std.testing.allocator);
    for (0..600) |i| try message.print(std.testing.allocator, "- item {d}\n", .{i});

    const chunks = try chunkFinalFallbackReply(std.testing.allocator, message.items);
    defer stream_presenter.freeChunks(std.testing.allocator, chunks);

    try std.testing.expect(chunks.len > 1);
    for (chunks) |chunk| {
        try std.testing.expect(chunk.len <= stream_presenter.STREAM_UPDATE_MAX_BYTES);
        try std.testing.expect(std.mem.indexOf(u8, chunk, stream_presenter.PREVIEW_TRUNCATED_MARKER) == null);
    }

    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (chunks) |chunk| try joined.appendSlice(std.testing.allocator, chunk);

    // Every bullet survived, including the head of the reply.
    try std.testing.expectEqual(@as(usize, 600), std.mem.count(u8, joined.items, "• "));
    try std.testing.expect(std.mem.startsWith(u8, joined.items, "• item 0"));
    try std.testing.expect(std.mem.endsWith(u8, joined.items, "• item 599\n"));
}

test "slack streaming ignores chunks when streaming is disabled" {
    var ch = initStreamingChannel(false);
    defer ch.channel().stop();

    try ch.channel().sendEvent("C1:1700.1", "x" ** 200, &.{}, .chunk);

    try std.testing.expectEqual(@as(usize, 0), ch.stream_states.count());
}

test "slack streaming chunk for an empty message is ignored" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();

    try ch.channel().sendEvent("C1:1700.1", "", &.{}, .chunk);

    try std.testing.expectEqual(@as(usize, 0), ch.stream_states.count());
}

test "slack streaming short reply never opens a stream" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();

    try ch.channel().sendEvent("C1:1700.1", "ok", &.{}, .chunk);

    // Nothing was flushed inside the coalescing window, so no message exists.
    const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), state.message_ts.len);
    try std.testing.expectEqual(@as(usize, 0), state.sent.len);
}

test "slack stop releases streaming buffers" {
    var ch = initStreamingChannel(true);
    const iface = ch.channel();

    try iface.sendEvent("C1:1700.1", "x" ** 200, &.{}, .chunk);
    try iface.sendEvent("C1", "y" ** 200, &.{}, .chunk);

    iface.stop();
    try std.testing.expectEqual(@as(usize, 0), ch.stream_states.count());
}

test "sendMessage payload converts markdown to mrkdwn" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);

    var body_list: std.ArrayListUnmanaged(u8) = .empty;
    defer body_list.deinit(std.testing.allocator);

    try ch.appendPostMessageBody(&body_list, "C123", null, "**hello** world");

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body_list.items, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    const text_value = parsed.value.object.get("text") orelse return error.TestExpectedEqual;
    try std.testing.expect(text_value == .string);
    try std.testing.expectEqualStrings("*hello* world", text_value.string);

    const mrkdwn_value = parsed.value.object.get("mrkdwn") orelse return error.TestExpectedEqual;
    try std.testing.expect(mrkdwn_value == .bool and mrkdwn_value.bool);
}

test "slack pending interactions survive across channel instances" {
    var sender = SlackChannel.init(std.testing.allocator, "tok", null, null, &.{});
    sender.account_id = "main";
    defer sender.deinitPendingInteractions();

    const choices = [_]root.Channel.OutboundChoice{
        .{ .id = "yes", .label = "Yes", .submit_text = "Confirm action" },
    };
    try sender.registerPendingInteraction("tok1", "C123:1700.1", null, &choices);

    var receiver = SlackChannel.init(std.testing.allocator, "tok", null, null, &.{});
    receiver.account_id = "main";

    const result = receiver.consumeInteractionSelection("tok1", 0, "U123");
    switch (result) {
        .ok => |selection| {
            defer std.testing.allocator.free(selection.submit_text);
            defer std.testing.allocator.free(selection.target);
            try std.testing.expectEqualStrings("Confirm action", selection.submit_text);
            try std.testing.expectEqualStrings("C123:1700.1", selection.target);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expect(receiver.consumeInteractionSelection("tok1", 0, "U123") == .not_found);
}

test "slack channel interface returns slack name" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    const iface = ch.channel();
    try std.testing.expectEqualStrings("slack", iface.name());
}

test "slack reaction plan clears the state it supersedes" {
    const emojis = config_types.SlackReactionEmojisConfig{};

    const accepted = planTaskReaction(emojis, .accepted);
    try std.testing.expectEqual(@as(u8, 0), accepted.removals_len);
    try std.testing.expectEqualStrings("eyes", accepted.add.?);

    const running = planTaskReaction(emojis, .running);
    try std.testing.expectEqual(@as(u8, 1), running.removals_len);
    try std.testing.expectEqualStrings("eyes", running.removals[0].?);
    try std.testing.expectEqualStrings("hourglass_flowing_sand", running.add.?);

    const done = planTaskReaction(emojis, .done);
    try std.testing.expectEqual(@as(u8, 2), done.removals_len);
    try std.testing.expectEqualStrings("eyes", done.removals[0].?);
    try std.testing.expectEqualStrings("hourglass_flowing_sand", done.removals[1].?);
    try std.testing.expectEqualStrings("white_check_mark", done.add.?);

    const failed = planTaskReaction(emojis, .failed);
    try std.testing.expectEqual(@as(u8, 2), failed.removals_len);
    try std.testing.expectEqualStrings("x", failed.add.?);
}

test "slack reaction plan reuses an emoji two states share" {
    const emojis = config_types.SlackReactionEmojisConfig{
        .accepted = "hourglass_flowing_sand",
        .running = "hourglass_flowing_sand",
        .done = "",
        .failed = "warning",
    };

    // Same emoji as the state being left, so the reaction stays put.
    const running = planTaskReaction(emojis, .running);
    try std.testing.expectEqual(@as(u8, 0), running.removals_len);
    try std.testing.expectEqualStrings("hourglass_flowing_sand", running.add.?);

    // Empty string clears the state instead of setting one.
    const done = planTaskReaction(emojis, .done);
    try std.testing.expectEqual(@as(u8, 1), done.removals_len);
    try std.testing.expectEqualStrings("hourglass_flowing_sand", done.removals[0].?);
    try std.testing.expect(done.add == null);

    const failed = planTaskReaction(emojis, .failed);
    try std.testing.expectEqual(@as(u8, 1), failed.removals_len);
    try std.testing.expectEqualStrings("warning", failed.add.?);
}

test "slack reaction plan with every emoji empty is a no-op" {
    const emojis = config_types.SlackReactionEmojisConfig{
        .accepted = "",
        .running = "",
        .done = "",
        .failed = "",
    };
    const done = planTaskReaction(emojis, .done);
    try std.testing.expectEqual(@as(u8, 0), done.removals_len);
    try std.testing.expect(done.add == null);
}

test "slackChannelIdOf drops the thread suffix" {
    try std.testing.expectEqualStrings("C123", slackChannelIdOf("C123:1700000000.000000").?);
    try std.testing.expectEqualStrings("C123", slackChannelIdOf("C123").?);
    try std.testing.expect(slackChannelIdOf("") == null);
    try std.testing.expect(slackChannelIdOf(":1700000000.000000") == null);
}

test "slack setTaskReaction is inert until status_reactions is on" {
    var ch = SlackChannel.initFromConfig(std.testing.allocator, .{ .bot_token = "tok" });
    ch.setTaskReaction("C123:1700000000.000000", "1700000000.000001", .accepted);

    ch.status_reactions_enabled = true;
    ch.setTaskReaction("C123:1700000000.000000", "1700000000.000001", .accepted);
    ch.setTaskReaction("C123:1700000000.000000", null, .running);
    ch.setTaskReaction("", "1700000000.000001", .failed);

    ch.reactions_disabled.store(true, .release);
    ch.setTaskReaction("C123:1700000000.000000", "1700000000.000001", .done);
}

test "slack vtable exposes the task reaction hook" {
    var ch = SlackChannel.initFromConfig(std.testing.allocator, .{
        .bot_token = "tok",
        .status_reactions = true,
    });
    const channel = ch.channel();
    try channel.setTaskReaction(.{
        .target = "C123:1700000000.000000",
        .message_id = "1700000000.000001",
        .reaction = .running,
    });
}

test "slack channel api base constant" {
    try std.testing.expectEqualStrings("https://slack.com/api", SlackChannel.API_BASE);
}

// ════════════════════════════════════════════════════════════════════════════
test "typed /stop in a mention-only group is fast-pathed" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .mention_only };
    ch.bot_user_id = try alloc.dupe(u8, "UBOT");
    ch.setBus(&eb);
    defer ch.channel().stop();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"app_mention\",\"user\":\"U1\",\"channel\":\"C1\",\"text\":\"<@UBOT> /stop\",\"ts\":\"1700000000.000\"}",
        .{},
    );
    defer parsed.deinit();

    // Regression: only the bare "/stop" form was recognised, so the default
    // mention-only policy accepted "<@UBOT> /stop" on the normal path and
    // enqueued it behind the very turn it was meant to interrupt.
    try std.testing.expect(ch.maybePublishStopMessage(parsed.value.object, "C1"));

    // Bounded wait: if the fast path regresses the test fails instead of
    // blocking the suite forever.
    var msg = (try eb.consumeInboundTimeout(1000)) orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("/stop", msg.content);
    try std.testing.expect(control_plane.isStopLikeCommand(msg.content));
}

// containsMention tests
// ════════════════════════════════════════════════════════════════════════════

test "containsMention detects mention" {
    try std.testing.expect(containsMention("Hello <@U12345> how are you?", "U12345"));
}

test "containsMention no mention" {
    try std.testing.expect(!containsMention("Hello world", "U12345"));
}

test "containsMention at start" {
    try std.testing.expect(containsMention("<@UBOT> do something", "UBOT"));
}

test "containsMention at end" {
    try std.testing.expect(containsMention("ping <@UBOT>", "UBOT"));
}

test "containsMention wrong user" {
    try std.testing.expect(!containsMention("Hey <@UOTHER>", "UBOT"));
}

test "containsMention empty text" {
    try std.testing.expect(!containsMention("", "UBOT"));
}

test "containsMention partial match not detected" {
    try std.testing.expect(!containsMention("<@UBOT", "UBOT"));
    try std.testing.expect(!containsMention("@UBOT>", "UBOT"));
}

// ════════════════════════════════════════════════════════════════════════════
// Per-channel policy integration tests (shouldHandle)
// ════════════════════════════════════════════════════════════════════════════

test "shouldHandle default policy allows DM" {
    const allowed = [_][]const u8{};
    const ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    // Default policy: dm=allow, group=open
    try std.testing.expect(ch.shouldHandle("U123", true, "hello", null));
}

test "shouldHandle default policy allows group without mention" {
    const allowed = [_][]const u8{};
    const ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    try std.testing.expect(ch.shouldHandle("U123", false, "hello", "UBOT"));
}

test "shouldHandle mention_only group requires mention" {
    const allowed = [_][]const u8{};
    const ch = SlackChannel.initWithPolicy(
        std.testing.allocator,
        "tok",
        null,
        null,
        &allowed,
        .{ .group = .mention_only },
    );
    try std.testing.expect(!ch.shouldHandle("U123", false, "hello", "UBOT"));
    try std.testing.expect(ch.shouldHandle("U123", false, "hey <@UBOT> help", "UBOT"));
}

test "shouldHandle deny dm blocks all DMs" {
    const allowed = [_][]const u8{};
    const ch = SlackChannel.initWithPolicy(
        std.testing.allocator,
        "tok",
        null,
        null,
        &allowed,
        .{ .dm = .deny },
    );
    try std.testing.expect(!ch.shouldHandle("U123", true, "hello", null));
    try std.testing.expect(!ch.shouldHandle("U456", true, "hi", "UBOT"));
}

test "shouldHandle dm allowlist permits listed users" {
    const allowed = [_][]const u8{};
    const list = [_][]const u8{ "alice", "bob" };
    const ch = SlackChannel.initWithPolicy(
        std.testing.allocator,
        "tok",
        null,
        null,
        &allowed,
        .{ .dm = .allowlist, .allowlist = &list },
    );
    try std.testing.expect(ch.shouldHandle("alice", true, "hi", null));
    try std.testing.expect(ch.shouldHandle("bob", true, "hi", null));
    try std.testing.expect(!ch.shouldHandle("eve", true, "hi", null));
}

test "shouldHandle group allowlist permits listed users" {
    const allowed = [_][]const u8{};
    const list = [_][]const u8{"trusted"};
    const ch = SlackChannel.initWithPolicy(
        std.testing.allocator,
        "tok",
        null,
        null,
        &allowed,
        .{ .group = .allowlist, .allowlist = &list },
    );
    try std.testing.expect(ch.shouldHandle("trusted", false, "msg", "UBOT"));
    try std.testing.expect(!ch.shouldHandle("stranger", false, "msg", "UBOT"));
}

test "shouldHandle mention_only without bot_user_id treats as no mention" {
    const allowed = [_][]const u8{};
    const ch = SlackChannel.initWithPolicy(
        std.testing.allocator,
        "tok",
        null,
        null,
        &allowed,
        .{ .group = .mention_only },
    );
    // No bot_user_id means mention cannot be detected
    try std.testing.expect(!ch.shouldHandle("U123", false, "hey <@UBOT> help", null));
}

test "initWithPolicy sets policy correctly" {
    const allowed = [_][]const u8{};
    const list = [_][]const u8{"admin"};
    const ch = SlackChannel.initWithPolicy(
        std.testing.allocator,
        "tok",
        "xapp-test",
        "C999",
        &allowed,
        .{ .dm = .deny, .group = .allowlist, .allowlist = &list },
    );
    try std.testing.expect(ch.policy.dm == .deny);
    try std.testing.expect(ch.policy.group == .allowlist);
    try std.testing.expectEqual(@as(usize, 1), ch.policy.allowlist.len);
    try std.testing.expectEqualStrings("admin", ch.policy.allowlist[0]);
    try std.testing.expectEqualStrings("tok", ch.bot_token);
    try std.testing.expectEqualStrings("xapp-test", ch.app_token.?);
    try std.testing.expectEqualStrings("C999", ch.channel_id.?);
}

test "normalizeWebhookPath falls back for invalid values" {
    try std.testing.expectEqualStrings(SlackChannel.DEFAULT_WEBHOOK_PATH, SlackChannel.normalizeWebhookPath(""));
    try std.testing.expectEqualStrings(SlackChannel.DEFAULT_WEBHOOK_PATH, SlackChannel.normalizeWebhookPath("slack/events"));
    try std.testing.expectEqualStrings("/slack/events", SlackChannel.normalizeWebhookPath("/slack/events"));
}

test "parseSocketConnectParts extracts host port and path" {
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    var path_buf: [512]u8 = undefined;
    const parts = try SlackChannel.parseSocketConnectParts(
        "wss://wss-primary.slack.com/link/?ticket=abc123",
        &host_buf,
        &path_buf,
    );
    try std.testing.expectEqualStrings("wss-primary.slack.com", parts.host);
    try std.testing.expectEqual(@as(u16, 443), parts.port);
    try std.testing.expectEqualStrings("/link/?ticket=abc123", parts.path);
}

test "SlackChannel create + healthCheck + stop leaks zero bytes" {
    // SlackChannel holds no heap allocations at init-time.  No deinit needed.
    var ch_struct = SlackChannel.initFromConfig(std.testing.allocator, .{
        .bot_token = "test-bot-token",
    });

    const ch = ch_struct.channel();
    _ = ch.healthCheck();
    ch.stop();
}

test "markdownToSlackMrkdwn converts repeated formatted markdown consistently" {
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(std.testing.allocator);

    const repetitions = 5000;
    for (0..repetitions) |_| {
        try input.appendSlice(std.testing.allocator, "**bold** ~~strike~~ `code` [link](http://x) ");
    }

    const mrkdwn = try markdownToSlackMrkdwn(std.testing.allocator, input.items);
    defer std.testing.allocator.free(mrkdwn);

    const expected_unit = "*bold* ~strike~ `code` <http://x|link> ";
    try std.testing.expectEqual(expected_unit.len * repetitions, mrkdwn.len);
    try std.testing.expect(std.mem.startsWith(u8, mrkdwn, expected_unit));
    try std.testing.expect(std.mem.endsWith(u8, mrkdwn, expected_unit));
    try std.testing.expect(std.mem.indexOf(u8, mrkdwn, "**bold**") == null);
    try std.testing.expect(std.mem.indexOf(u8, mrkdwn, "~~strike~~") == null);
    try std.testing.expect(std.mem.indexOf(u8, mrkdwn, "[link](http://x)") == null);
}

test "SlackChannel start + stop concurrency stress test" {
    // We use HTTP mode here to avoid the thread spawning and auth.test
    // making real network calls. Under is_test, start/stop shouldn't
    // cause actual side-effects, but the flags running/connected
    // are mutated and the lifecycle_mu protects them.
    var ch_struct = SlackChannel.initFromConfig(std.testing.allocator, .{
        .account_id = "test",
        .mode = .http,
        .bot_token = "xoxb-test",
        .signing_secret = "secret",
    });

    const ThreadFn = struct {
        fn run(channel: root.Channel) void {
            for (0..100) |_| {
                _ = channel.start() catch {};
                channel.stop();
            }
        }
    };

    var threads: [10]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, ThreadFn.run, .{ch_struct.channel()});
    }

    for (threads) |t| {
        t.join();
    }

    // Ensure cleanup
    ch_struct.channel().stop();
    try std.testing.expect(!ch_struct.running.load(.acquire));
    try std.testing.expect(!ch_struct.connected.load(.acquire));
    try std.testing.expect(ch_struct.socket_thread == null);
    try std.testing.expect(ch_struct.poll_thread == null);
}

// -- Single-command slash support -------------------------------------------

fn slashCommandTestPayload(alloc: std.mem.Allocator, command: []const u8, text: []const u8) !std.json.Parsed(std.json.Value) {
    const json = try std.fmt.allocPrint(
        alloc,
        "{{\"command\":\"{s}\",\"text\":\"{s}\",\"user_id\":\"U1\",\"channel_id\":\"C1\",\"channel_name\":\"general\",\"team_id\":\"T1\",\"response_url\":\"https://example.invalid/hook\"}}",
        .{ command, text },
    );
    defer alloc.free(json);
    return std.json.parseFromSlice(std.json.Value, alloc, json, .{});
}

test "slack typed /stop is published without joining the conversation FIFO" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi or
        @TypeOf(std.posix.system.socketpair) == void)
    {
        return error.SkipZigTest;
    } else {
        const alloc = std.testing.allocator;
        var eb = bus_mod.Bus.init();
        defer eb.close();

        const sockets = try websocket.createTestSocketPair();
        defer std.Io.Threaded.closeFd(sockets[0]);
        defer std.Io.Threaded.closeFd(sockets[1]);

        const allowed = [_][]const u8{"*"};
        var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
        ch.account_id = "sl-main";
        ch.policy = .{ .dm = .allow, .group = .open };
        ch.setBus(&eb);
        defer ch.channel().stop();

        var ws = websocket.WsClient{
            .allocator = alloc,
            .stream = .{ .handle = sockets[0] },
            .tls = null,
            .write_mu = .{},
        };

        const envelope =
            \\{"type":"events_api","envelope_id":"e1","payload":{"event":{"type":"message","user":"U1","text":"/stop","ts":"1700000001.000","channel":"C1"}}}
        ;
        try ch.handleSocketPayload(&ws, envelope);

        // Regression: a typed stop waited behind the per-conversation FIFO, so
        // the very turn it was meant to interrupt had to finish first.
        var msg = (eb.consumeInboundTimeout(0) catch return error.TestExpectedEqual) orelse
            return error.TestExpectedEqual;
        defer msg.deinit(alloc);
        try std.testing.expectEqualStrings("/stop", msg.content);
        try std.testing.expectEqualStrings("slack:sl-main:channel:C1", msg.session_key);
        // It never entered the FIFO.
        try std.testing.expectEqual(@as(usize, 0), ch.inbound_queue.items.len);
    }
}

test "slack typed stop does not block the socket reader on a full bus" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer {
        // consumeInbound() blocks when empty; drain with a zero timeout.
        while (true) {
            const queued = eb.consumeInboundTimeout(0) catch break;
            var owned = queued orelse break;
            owned.deinit(alloc);
        }
        eb.close();
    }

    // Fill the inbound bus so a blocking publish would never return.
    for (0..bus_mod.QUEUE_CAPACITY) |_| {
        const queued = try bus_mod.makeInbound(alloc, "slack", "U1", "C1", "queued", "slack:sl-main:channel:C1");
        try eb.publishInbound(queued);
    }

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.setBus(&eb);

    // Regression: the fast path used a blocking publish, so a typed /stop on a
    // full bus stalled the reader (no acks/pings) instead of falling back.
    try std.testing.expectError(
        error.Timeout,
        ch.publishInboundMessageTimeout("U1", "C1", "/stop", null, null, 0),
    );

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"user":"U1","text":"/stop","ts":"1700000001.000","channel":"C1"}
    ,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(!ch.maybePublishStopMessage(parsed.value.object, "C1"));
}

test "slack non-stop messages stay on the inbound FIFO" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.setBus(&eb);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"user":"U1","text":"hello","ts":"1700000001.000","channel":"C1"}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expect(!ch.maybePublishStopMessage(parsed.value.object, "C1"));
    try std.testing.expectError(error.Timeout, eb.consumeInboundTimeout(0));
}

test "slack FIFO key follows the daemon session, including the thread" {
    const alloc = std.testing.allocator;
    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";

    const top_level = ch.inboundConversationHash("U1", "C1", null);
    const thread_a = ch.inboundConversationHash("U1", "C1", "1700000000.000");
    const thread_a_reply = ch.inboundConversationHash("U1", "C1", "1700000000.000");
    const thread_b = ch.inboundConversationHash("U1", "C1", "1700000001.000");

    // Same thread: same session, so the same FIFO key.
    try std.testing.expectEqual(thread_a, thread_a_reply);
    // Different threads of one channel are different daemon sessions
    // (`:thread:<thread_id>` is appended), so they must not share a key.
    try std.testing.expect(thread_a != thread_b);
    try std.testing.expect(top_level != thread_a);
    // Different channels and DMs are different sessions.
    try std.testing.expect(top_level != ch.inboundConversationHash("U1", "C2", null));
    try std.testing.expect(top_level != ch.inboundConversationHash("U2", "D1", null));
}

test "slack FIFO hash follows the routed DM session" {
    const alloc = std.testing.allocator;
    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";

    const peer_a = ch.inboundConversationHash("U1", "D1", null);
    const peer_b = ch.inboundConversationHash("U2", "D2", null);
    try std.testing.expect(peer_a != peer_b);

    // Regression: dm_scope=main maps every DM to one daemon session, but the
    // hash keyed the raw sender, so two workers processed them concurrently
    // and the session mutex did not preserve their publish order.
    ch.dm_scope = .main;
    try std.testing.expectEqual(
        ch.inboundConversationHash("U1", "D1", null),
        ch.inboundConversationHash("U2", "D2", null),
    );

    // identity_links merge peer ids into one routed session as well.
    ch.dm_scope = .per_channel_peer;
    const links = [_]config_types.IdentityLink{
        .{ .canonical = "U1", .peers = &.{"U2"} },
    };
    ch.identity_links = &links;
    try std.testing.expectEqual(
        ch.inboundConversationHash("U1", "D1", null),
        ch.inboundConversationHash("U2", "D2", null),
    );
}

test "slack FIFO isolates threads of one channel" {
    const alloc = std.testing.allocator;
    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";

    const hash_a = ch.inboundConversationHash("U1", "C1", "1700000000.000");
    const hash_b = ch.inboundConversationHash("U1", "C1", "1700000001.000");

    // Regression: the session key without the thread made every thread of a
    // channel share one FIFO hash, so a claimed file_share in thread A (up to
    // MAX_INBOUND_FILES downloads) blocked thread B for minutes.
    ch.inbound_queue.append(alloc, .{
        .id = 1,
        .kind = .message,
        .payload = try alloc.dupe(u8, "{}"),
        .channel_id = try alloc.dupe(u8, "C1"),
        .conversation_hash = hash_a,
    }) catch unreachable;
    ch.inbound_queue.append(alloc, .{
        .id = 2,
        .kind = .message,
        .payload = try alloc.dupe(u8, "{}"),
        .channel_id = try alloc.dupe(u8, "C1"),
        .conversation_hash = hash_b,
    }) catch unreachable;
    defer {
        for (ch.inbound_queue.items) |*event| event.deinit(alloc);
        ch.inbound_queue.deinit(alloc);
    }

    const first = ch.takeInboundEventLocked() orelse return error.TestExpectedEqual;
    var first_owned = first;
    defer first_owned.deinit(alloc);
    defer ch.removeInboundEventLocked(first.id);

    // A second worker may claim the other thread concurrently.
    const second = ch.takeInboundEventLocked() orelse return error.TestExpectedEqual;
    var second_owned = second;
    defer second_owned.deinit(alloc);
    defer ch.removeInboundEventLocked(second.id);
    try std.testing.expect(first.id != second.id);

    // Same thread still serializes: a third event for thread A waits.
    ch.inbound_queue.append(alloc, .{
        .id = 3,
        .kind = .message,
        .payload = try alloc.dupe(u8, "{}"),
        .channel_id = try alloc.dupe(u8, "C1"),
        .conversation_hash = hash_a,
    }) catch unreachable;
    try std.testing.expect(ch.takeInboundEventLocked() == null);
}

test "typed /stop does not overtake queued inbound work for the session" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.setBus(&eb);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"message\",\"user\":\"U1\",\"channel\":\"C1\",\"text\":\"/stop\",\"ts\":\"1700000001.000\"}",
        .{},
    );
    defer parsed.deinit();

    // An earlier message for the same conversation is still in the FIFO (for
    // example a text message behind a claimed file_share download).
    ch.inbound_mu.lock();
    try ch.inbound_queue.append(alloc, .{
        .id = 1,
        .kind = .message,
        .payload = try alloc.dupe(u8, "{}"),
        .channel_id = try alloc.dupe(u8, "C1"),
        .conversation_hash = ch.inboundConversationHash("U1", "C1", null),
    });
    ch.inbound_mu.unlock();
    defer {
        ch.inbound_mu.lock();
        for (ch.inbound_queue.items) |*event| event.deinit(alloc);
        ch.inbound_queue.deinit(alloc);
        ch.inbound_mu.unlock();
    }

    // Regression: the fast path published /stop immediately, ahead of the
    // queued event. With no turn running yet the dispatcher ran /stop as an
    // ordinary turn before the earlier message was even published, so the user
    // got a spurious /stop reply first and the reply order was reversed.
    try std.testing.expect(!ch.maybePublishStopMessage(parsed.value.object, "C1"));
    try std.testing.expectError(error.Timeout, eb.consumeInboundTimeout(0));
}

test "slack slash command name match ignores leading slash and case" {
    try std.testing.expect(SlackChannel.slashCommandNameMatches("nullclaw", "/NULLCLAW"));
    try std.testing.expect(SlackChannel.slashCommandNameMatches("/nullclaw", "nullclaw"));
    try std.testing.expect(!SlackChannel.slashCommandNameMatches("nullclaw", "/other"));
    try std.testing.expect(!SlackChannel.slashCommandNameMatches("", "/nullclaw"));
}

test "slack slash command publishes the text as a top-level channel message" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.slash_command_enabled = true;
    ch.slash_command_name = "nullclaw";
    ch.setBus(&eb);
    // Non-stop commands now run on the inbound pool; stop joins its workers.
    defer ch.channel().stop();

    const parsed = try slashCommandTestPayload(alloc, "/nullclaw", "hello there");
    defer parsed.deinit();
    ch.handleSlashCommand(parsed.value.object);

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("slack", msg.channel);
    try std.testing.expectEqualStrings("U1", msg.sender_id);
    try std.testing.expectEqualStrings("C1", msg.chat_id);
    try std.testing.expectEqualStrings("slack:sl-main:channel:C1", msg.session_key);
    try std.testing.expectEqualStrings("hello there", msg.content);
}

test "slack slash command /stop is published verbatim as a stop command" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.slash_command_enabled = true;
    ch.slash_command_name = "nullclaw";
    ch.setBus(&eb);

    const parsed = try slashCommandTestPayload(alloc, "/nullclaw", "/stop");
    defer parsed.deinit();
    ch.handleSlashCommand(parsed.value.object);

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    // The text is fed through verbatim, so the core sees the same stop command
    // a typed "/stop" produces. The interrupt itself is covered end to end by
    // the daemon fast-path tests, which consume this exact message.
    try std.testing.expectEqualStrings("/stop", msg.content);
    try std.testing.expect(@import("../control_plane.zig").isStopLikeCommand(msg.content));
    try std.testing.expectEqualStrings("slack:sl-main:channel:C1", msg.session_key);
}

test "slack slash command ignores an unknown command name" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.slash_command_enabled = true;
    ch.slash_command_name = "nullclaw";
    ch.setBus(&eb);

    const parsed = try slashCommandTestPayload(alloc, "/other", "hi");
    defer parsed.deinit();
    ch.handleSlashCommand(parsed.value.object);

    // consumeInbound() blocks when empty; use a zero timeout to assert nothing was published.
    try std.testing.expectError(error.Timeout, eb.consumeInboundTimeout(0));
}

test "slack slash command refuses an unauthorized sender" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    // Group allowlist that does not contain U1 -> refused even though the slash
    // invocation counts as a mention.
    ch.policy = .{ .dm = .allow, .group = .allowlist, .allowlist = &.{} };
    ch.slash_command_enabled = true;
    ch.slash_command_name = "nullclaw";
    ch.setBus(&eb);

    const parsed = try slashCommandTestPayload(alloc, "/nullclaw", "hi");
    defer parsed.deinit();
    ch.handleSlashCommand(parsed.value.object);

    // consumeInbound() blocks when empty; use a zero timeout to assert nothing was published.
    try std.testing.expectError(error.Timeout, eb.consumeInboundTimeout(0));
}

test "slack slash command empty text does not publish" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.slash_command_enabled = true;
    ch.slash_command_name = "nullclaw";
    ch.setBus(&eb);

    const parsed = try slashCommandTestPayload(alloc, "/nullclaw", "");
    defer parsed.deinit();
    ch.handleSlashCommand(parsed.value.object);

    // consumeInbound() blocks when empty; use a zero timeout to assert nothing was published.
    try std.testing.expectError(error.Timeout, eb.consumeInboundTimeout(0));
}

test "slack slash_commands envelope is acked before it is dispatched" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi or
        @TypeOf(std.posix.system.socketpair) == void)
    {
        return error.SkipZigTest;
    } else {
        const alloc = std.testing.allocator;
        var eb = bus_mod.Bus.init();
        defer eb.close();

        const sockets = try websocket.createTestSocketPair();
        defer std.Io.Threaded.closeFd(sockets[0]);
        defer std.Io.Threaded.closeFd(sockets[1]);

        const allowed = [_][]const u8{"*"};
        var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
        ch.account_id = "sl-main";
        ch.policy = .{ .dm = .allow, .group = .open };
        ch.slash_command_enabled = true;
        ch.slash_command_name = "nullclaw";
        ch.setBus(&eb);

        var ws = websocket.WsClient{
            .allocator = alloc,
            .stream = .{ .handle = sockets[0] },
            .tls = null,
            .write_mu = .{},
        };

        const envelope =
            \\{"type":"slash_commands","envelope_id":"e1","payload":{"command":"/nullclaw","text":"/stop","user_id":"U1","channel_id":"C1","team_id":"T1","response_url":"https://example.invalid/hook"}}
        ;
        try ch.handleSocketPayload(&ws, envelope);

        // The ack frame reaches the socket, and the message is dispatched.
        // poll first so a missing ack fails the test instead of blocking.
        var pollfds = [_]std.posix.pollfd{.{ .fd = sockets[1], .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = try std.posix.poll(&pollfds, 1000);
        try std.testing.expect(ready > 0);
        var buf: [64]u8 = undefined;
        const n = try std.posix.read(sockets[1], &buf);
        try std.testing.expect(n > 0);
        try std.testing.expectEqual(@as(u8, 0x81), buf[0]);

        var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
        defer msg.deinit(alloc);
        try std.testing.expectEqualStrings("/stop", msg.content);
    }
}

test "slack slash response body is a valid ephemeral JSON reply" {
    const alloc = std.testing.allocator;
    const body = try buildSlashResponseBody(alloc, "say \"hi\"\nnow");
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{\"text\":\"say \\\"hi\\\"\\nnow\",\"response_type\":\"ephemeral\"}", body);
}

test "slack slash envelope with retry_attempt is acked but not dispatched again" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi or
        @TypeOf(std.posix.system.socketpair) == void)
    {
        return error.SkipZigTest;
    } else {
        const alloc = std.testing.allocator;
        var eb = bus_mod.Bus.init();
        defer eb.close();

        const sockets = try websocket.createTestSocketPair();
        defer std.Io.Threaded.closeFd(sockets[0]);
        defer std.Io.Threaded.closeFd(sockets[1]);

        const allowed = [_][]const u8{"*"};
        var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
        ch.account_id = "sl-main";
        ch.policy = .{ .dm = .allow, .group = .open };
        ch.slash_command_enabled = true;
        ch.slash_command_name = "nullclaw";
        ch.setBus(&eb);

        var ws = websocket.WsClient{
            .allocator = alloc,
            .stream = .{ .handle = sockets[0] },
            .tls = null,
            .write_mu = .{},
        };

        const envelope =
            \\{"type":"slash_commands","envelope_id":"e1","retry_attempt":1,"payload":{"command":"/nullclaw","text":"/stop","user_id":"U1","channel_id":"C1","team_id":"T1","response_url":"https://example.invalid/hook"}}
        ;
        try ch.handleSocketPayload(&ws, envelope);

        // A retried delivery is acked but must not run the command twice.
        try std.testing.expectError(error.Timeout, eb.consumeInboundTimeout(0));
    }
}

var test_fetch_thread_id: ?std.Thread.Id = null;

fn recordFetchThreadAndFail(_: std.mem.Allocator, _: SlackFileInfo) ?[]u8 {
    test_fetch_thread_id = std.Thread.getCurrentId();
    return null;
}

test "slack socket message file downloads run off the reader thread" {
    test_fetch_thread_id = null;
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.file_fetch_override = recordFetchThreadAndFail;
    ch.setBus(&eb);
    defer ch.channel().stop();

    var ws = websocket.WsClient{
        .allocator = alloc,
        .stream = .{ .handle = invalid_socket },
        .tls = null,
        .write_mu = .{},
    };

    const envelope =
        \\{"type":"events_api","payload":{"event_id":"Ev1","event":{"type":"message","subtype":"file_share","channel":"C1","user":"U1","text":"see file","ts":"1700000000.100","files":[{"id":"F1","name":"a.png","mimetype":"image/png","url_private":"https://files.slack.com/a.png","size":10}]}}}
    ;
    try ch.handleSocketPayload(&ws, envelope);

    // Regression: file downloads ran synchronously on the Socket Mode reader
    // thread, so acks/pongs queued behind a slow download and Slack
    // redelivered envelopes or dropped the websocket.
    const reader_thread = std.Thread.getCurrentId();
    ch.waitForInboundIdle();
    try std.testing.expect(test_fetch_thread_id != null);
    try std.testing.expect(test_fetch_thread_id.? != reader_thread);

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "see file") != null);
}

/// Test seam: block one inbound file download until the test releases it.
const TestInboundGate = struct {
    var mutex: std_compat.sync.Mutex = .{};
    var cond: std_compat.sync.Condition = .{};
    var entered: bool = false;
    var release: bool = false;

    fn reset() void {
        mutex.lock();
        entered = false;
        release = false;
        mutex.unlock();
    }

    fn fetch(_: std.mem.Allocator, _: SlackFileInfo) ?[]u8 {
        mutex.lock();
        defer mutex.unlock();
        entered = true;
        cond.broadcast();
        while (!release) cond.wait(&mutex);
        return null;
    }

    /// Bounded wait so a broken worker fails the test instead of hanging it.
    fn waitEntered() bool {
        var waited_ms: u64 = 0;
        while (waited_ms < 10_000) : (waited_ms += 10) {
            mutex.lock();
            const ready = entered;
            mutex.unlock();
            if (ready) return true;
            std_compat.thread.sleep(10 * std.time.ns_per_ms);
        }
        return false;
    }

    fn open() void {
        mutex.lock();
        release = true;
        cond.broadcast();
        mutex.unlock();
    }
};

test "slack restart after stop respawns the inbound pool" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    var ch = SlackChannel.initFromConfig(alloc, .{
        .account_id = "sl-main",
        .mode = .http,
        .bot_token = "xoxb-test",
        .signing_secret = "secret",
    });
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.setBus(&eb);

    const channel = ch.channel();
    try channel.start();
    channel.stop();
    // Regression: vtableStop set inbound_stop and cleared the worker handle,
    // but vtableStart never reset them. channel_manager restarts the same
    // instance after a health-check failure, so the worker exited immediately
    // and every later event queued forever (silent inbound outage).
    try channel.start();
    defer channel.stop();

    var ws = websocket.WsClient{
        .allocator = alloc,
        .stream = .{ .handle = invalid_socket },
        .tls = null,
        .write_mu = .{},
    };
    const envelope =
        \\{"type":"events_api","payload":{"event_id":"EvRestart","event":{"type":"message","channel":"C1","user":"U1","text":"after restart","ts":"1700000000.300"}}}
    ;
    try ch.handleSocketPayload(&ws, envelope);
    ch.waitForInboundIdle();

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("after restart", msg.content);
}

test "slack slow download in one conversation does not block another" {
    TestInboundGate.reset();
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.file_fetch_override = TestInboundGate.fetch;
    ch.setBus(&eb);
    defer {
        TestInboundGate.open();
        ch.channel().stop();
    }

    var ws = websocket.WsClient{
        .allocator = alloc,
        .stream = .{ .handle = invalid_socket },
        .tls = null,
        .write_mu = .{},
    };

    const slow =
        \\{"type":"events_api","payload":{"event_id":"EvSlow","event":{"type":"message","subtype":"file_share","channel":"C1","user":"U1","text":"slow file","ts":"1700000000.400","files":[{"id":"F1","name":"a.png","mimetype":"image/png","url_private":"https://files.slack.com/a.png","size":10}]}}}
    ;
    try ch.handleSocketPayload(&ws, slow);
    try std.testing.expect(TestInboundGate.waitEntered());

    const fast =
        \\{"type":"events_api","payload":{"event_id":"EvFast","event":{"type":"message","channel":"C2","user":"U2","text":"other chat","ts":"1700000000.500"}}}
    ;
    try ch.handleSocketPayload(&ws, fast);

    // Regression: one serial worker meant a slow download in C1 delayed every
    // other conversation until it finished.
    var msg = (try eb.consumeInboundTimeout(5000)) orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("other chat", msg.content);
    // The slow conversation is still blocked.
    try std.testing.expectError(error.Timeout, eb.consumeInboundTimeout(0));

    TestInboundGate.open();
    ch.waitForInboundIdle();
    var slow_msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer slow_msg.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, slow_msg.content, "slow file") != null);
}

test "slack slash commands queue behind earlier messages per conversation" {
    TestInboundGate.reset();
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.slash_command_enabled = true;
    ch.slash_command_name = "nullclaw";
    ch.file_fetch_override = TestInboundGate.fetch;
    ch.setBus(&eb);
    defer {
        TestInboundGate.open();
        ch.channel().stop();
    }

    var ws = websocket.WsClient{
        .allocator = alloc,
        .stream = .{ .handle = invalid_socket },
        .tls = null,
        .write_mu = .{},
    };
    const slow =
        \\{"type":"events_api","payload":{"event_id":"EvSlashSlow","event":{"type":"message","subtype":"file_share","channel":"C1","user":"U1","text":"slow file","ts":"1700000000.600","files":[{"id":"F1","name":"a.png","mimetype":"image/png","url_private":"https://files.slack.com/a.png","size":10}]}}}
    ;
    try ch.handleSocketPayload(&ws, slow);
    try std.testing.expect(TestInboundGate.waitEntered());

    var payload = try slashCommandTestPayload(alloc, "/nullclaw", "/new");
    defer payload.deinit();
    ch.handleSlashCommand(payload.value.object);

    // Regression: slash commands ran inline while messages were queued, so
    // /new could run ahead of an earlier message in the same channel.
    try std.testing.expectError(error.Timeout, eb.consumeInboundTimeout(0));

    TestInboundGate.open();
    ch.waitForInboundIdle();

    var slow_msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer slow_msg.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, slow_msg.content, "slow file") != null);
    var slash_msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer slash_msg.deinit(alloc);
    try std.testing.expectEqualStrings("/new", slash_msg.content);
}

test "slack /stop bypasses the conversation queue" {
    TestInboundGate.reset();
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.slash_command_enabled = true;
    ch.slash_command_name = "nullclaw";
    ch.file_fetch_override = TestInboundGate.fetch;
    ch.setBus(&eb);
    defer {
        TestInboundGate.open();
        ch.channel().stop();
    }

    var ws = websocket.WsClient{
        .allocator = alloc,
        .stream = .{ .handle = invalid_socket },
        .tls = null,
        .write_mu = .{},
    };
    const slow =
        \\{"type":"events_api","payload":{"event_id":"EvStopSlow","event":{"type":"message","subtype":"file_share","channel":"C1","user":"U1","text":"slow file","ts":"1700000000.700","files":[{"id":"F1","name":"a.png","mimetype":"image/png","url_private":"https://files.slack.com/a.png","size":10}]}}}
    ;
    try ch.handleSocketPayload(&ws, slow);
    try std.testing.expect(TestInboundGate.waitEntered());

    var payload = try slashCommandTestPayload(alloc, "/nullclaw", "/stop");
    defer payload.deinit();
    ch.handleSlashCommand(payload.value.object);

    // /stop must stay immediate: it has to interrupt the turn that is holding
    // up the queue, so it cannot wait behind that turn.
    var stop_msg = (try eb.consumeInboundTimeout(5000)) orelse return error.TestExpectedEqual;
    defer stop_msg.deinit(alloc);
    try std.testing.expectEqualStrings("/stop", stop_msg.content);

    TestInboundGate.open();
    ch.waitForInboundIdle();
    var slow_msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer slow_msg.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, slow_msg.content, "slow file") != null);
}

test "slack app_mention and message delivery of one post is processed once" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.setBus(&eb);
    defer ch.channel().stop();

    var ws = websocket.WsClient{
        .allocator = alloc,
        .stream = .{ .handle = invalid_socket },
        .tls = null,
        .write_mu = .{},
    };
    // Same post, two event types and different event_ids, but one
    // client_msg_id/ts.
    const mention =
        \\{"type":"events_api","payload":{"event_id":"EvMention","event":{"type":"app_mention","client_msg_id":"CM1","channel":"C1","user":"U1","text":"hello there","ts":"1700000000.800"}}}
    ;
    const message =
        \\{"type":"events_api","payload":{"event_id":"EvMessage","event":{"type":"message","client_msg_id":"CM1","channel":"C1","user":"U1","text":"hello there","ts":"1700000000.800"}}}
    ;
    try ch.handleSocketPayload(&ws, mention);
    try ch.handleSocketPayload(&ws, message);
    ch.waitForInboundIdle();

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("hello there", msg.content);
    // Regression: dedupe returned after the first key, so the same post
    // delivered as both app_mention and message produced two turns.
    try std.testing.expectError(error.Timeout, eb.consumeInboundTimeout(0));
}

test "slack redelivered socket event is processed once" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.setBus(&eb);
    defer ch.channel().stop();

    var ws = websocket.WsClient{
        .allocator = alloc,
        .stream = .{ .handle = invalid_socket },
        .tls = null,
        .write_mu = .{},
    };

    const envelope =
        \\{"type":"events_api","payload":{"event_id":"Ev2","event":{"type":"message","channel":"C1","user":"U1","text":"hello once","ts":"1700000000.200"}}}
    ;
    try ch.handleSocketPayload(&ws, envelope);
    try ch.handleSocketPayload(&ws, envelope);
    ch.waitForInboundIdle();

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("hello once", msg.content);
    // Regression: a redelivered event (same event_id) duplicated the turn.
    try std.testing.expectError(error.Timeout, eb.consumeInboundTimeout(0));
}

// ════════════════════════════════════════════════════════════════════════════
// Slack media tests
// ════════════════════════════════════════════════════════════════════════════

test "slack file_share subtype is processed instead of dropped" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "C12345", &allowed);
    ch.account_id = "sl-main";
    ch.setBus(&eb);

    // Regression: a non-empty subtype returned early, so `file_share` messages
    // (including their caption) were silently discarded.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"subtype":"file_share","user":"U123","text":"see attached","ts":"1700000000.100","files":[{"id":"F1","name":"chart.png","mimetype":"image/png","size":42,"url_private":"https://files.slack.com/files-pri/T1-F1/chart.png"}]}
    ,
        .{},
    );
    defer parsed.deinit();

    try ch.processHistoryMessage(parsed.value.object, "C12345");

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "see attached") != null);
    // Downloads are disabled under `zig build test`; the metadata fallback must
    // still tell the model what was attached.
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "[ATTACHMENT:image") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "file_name=chart.png") != null);
}

test "slack file_share without caption is still published" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(alloc, "tok", null, "D12345", &allowed);
    ch.account_id = "sl-main";
    ch.policy = .{ .dm = .allow, .group = .open };
    ch.setBus(&eb);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"subtype":"file_share","user":"U123","ts":"1700000000.100","files":[{"id":"F2","name":"notes.pdf","mimetype":"application/pdf","size":99,"url_private":"https://files.slack.com/files-pri/T1-F2/notes.pdf"}]}
    ,
        .{},
    );
    defer parsed.deinit();

    try ch.processHistoryMessage(parsed.value.object, "D12345");

    var msg = eb.consumeInbound() orelse return error.TestExpectedEqual;
    defer msg.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "[ATTACHMENT:document") != null);
}

test "slack file classification covers images, audio clips, and documents" {
    try std.testing.expectEqual(InboundFileKind.image, classifySlackFile(.{ .mimetype = "image/png" }));
    try std.testing.expectEqual(InboundFileKind.image, classifySlackFile(.{ .name = "shot.JPG" }));
    // Slack audio clips report subtype slack_audio but a video/* MIME.
    try std.testing.expectEqual(InboundFileKind.audio, classifySlackFile(.{
        .mimetype = "video/mp4",
        .subtype = "slack_audio",
    }));
    try std.testing.expectEqual(InboundFileKind.audio, classifySlackFile(.{ .mimetype = "audio/ogg" }));
    try std.testing.expectEqual(InboundFileKind.file, classifySlackFile(.{
        .mimetype = "application/pdf",
        .name = "report.pdf",
    }));
}

test "slack inbound file URLs are pinned to Slack HTTPS hosts" {
    try std.testing.expect(isAllowedSlackFileUrl("https://files.slack.com/files-pri/T1-F1/x.png"));
    try std.testing.expect(isAllowedSlackFileUrl("https://files-origin.slack-edge.com/x"));
    try std.testing.expect(!isAllowedSlackFileUrl("https://evil.example.com/x.png"));
    try std.testing.expect(!isAllowedSlackFileUrl("http://files.slack.com/x.png"));
    try std.testing.expect(!isAllowedSlackFileUrl("https://slack.com.evil.example/x"));
}

test "slack outbound markers are stripped and lifted into attachments" {
    const alloc = std.testing.allocator;
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &.{});

    var payload = try ch.prepareOutbound(alloc, "Look\n[IMAGE:/tmp/chart.png]\nthanks", &.{});
    defer payload.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), payload.attachments.len);
    try std.testing.expectEqual(root.Channel.OutboundAttachmentKind.image, payload.attachments[0].kind);
    try std.testing.expectEqualStrings("/tmp/chart.png", payload.attachments[0].target);
    try std.testing.expect(std.mem.indexOf(u8, payload.text, "[IMAGE:") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload.text, "Look") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload.text, "thanks") != null);
}

test "slack outbound FILE marker maps to a document attachment" {
    const alloc = std.testing.allocator;
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &.{});

    var payload = try ch.prepareOutbound(alloc, "[FILE:/tmp/report.pdf]", &.{});
    defer payload.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), payload.attachments.len);
    try std.testing.expectEqual(root.Channel.OutboundAttachmentKind.document, payload.attachments[0].kind);
    try std.testing.expectEqualStrings("", payload.text);
}

test "slack upload request bodies carry channel and thread" {
    const alloc = std.testing.allocator;

    const ticket = try buildGetUploadUrlBody(alloc, "chart.png", 1234);
    defer alloc.free(ticket);
    try std.testing.expectEqualStrings("{\"filename\":\"chart.png\",\"length\":1234}", ticket);

    const complete = try buildCompleteUploadBody(alloc, "F123", "chart.png", "C1", "1700.1");
    defer alloc.free(complete);
    try std.testing.expectEqualStrings(
        "{\"files\":[{\"id\":\"F123\",\"title\":\"chart.png\"}],\"channel_id\":\"C1\",\"thread_ts\":\"1700.1\"}",
        complete,
    );

    const delete_body = try buildDeleteMessageBody(alloc, "C1", "1700.1");
    defer alloc.free(delete_body);
    try std.testing.expectEqualStrings("{\"channel\":\"C1\",\"ts\":\"1700.1\"}", delete_body);
}

const FakeSlackTranscriber = struct {
    text: []const u8,

    fn vtableTranscribe(ptr: *anyopaque, alloc: std.mem.Allocator, _: []const u8) voice.TranscribeError!?[]const u8 {
        const self: *FakeSlackTranscriber = @ptrCast(@alignCast(ptr));
        return try alloc.dupe(u8, self.text);
    }

    const vtable = voice.Transcriber.VTable{ .transcribe = &vtableTranscribe };

    fn transcriber(self: *FakeSlackTranscriber) voice.Transcriber {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

test "slack inbound audio uses the shared transcription pipeline" {
    const alloc = std.testing.allocator;
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &.{});
    var fake = FakeSlackTranscriber{ .text = "spoken words" };
    ch.transcriber = fake.transcriber();

    const transcript = ch.transcribeSlackAudio(alloc, "/tmp/note.ogg") orelse return error.TestExpectedEqual;
    defer alloc.free(transcript);
    try std.testing.expectEqualStrings("spoken words", transcript);
}

test "slack ensureTranscriber installs a Whisper transcriber from audio config" {
    const alloc = std.testing.allocator;
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &.{});
    ch.audio_media = .{ .provider = "groq", .model = "whisper-large-v3" };
    ch.audio_provider_key = "test-key";

    ch.ensureTranscriber();
    try std.testing.expect(ch.transcriber != null);

    if (ch.owned_transcriber) |owned| alloc.destroy(owned);
    ch.owned_transcriber = null;
    ch.transcriber = null;
}

test "slack ensureTranscriber respects tools.media.audio.enabled" {
    const alloc = std.testing.allocator;
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &.{});
    ch.audio_media = .{ .enabled = false, .provider = "groq" };
    ch.audio_provider_key = "test-key";

    ch.ensureTranscriber();
    try std.testing.expect(ch.transcriber == null);
}

test "slack inbound downloads reject HTML auth pages" {
    try std.testing.expect(looksLikeHtml("<!DOCTYPE html><html></html>"));
    try std.testing.expect(looksLikeHtml("\n  <html><body>login</body></html>"));
    try std.testing.expect(!looksLikeHtml("\x89PNG\r\n\x1a\n"));
    try std.testing.expect(!looksLikeHtml(""));
}

// ── Slack inbound media pipeline (injected fetch) ───────────────

fn fetchSlackTestImageBytes(allocator: std.mem.Allocator, _: SlackFileInfo) ?[]u8 {
    return allocator.dupe(u8, "\x89PNG\r\n\x1a\nfake-image") catch null;
}

fn fetchSlackTestPdfBytes(allocator: std.mem.Allocator, _: SlackFileInfo) ?[]u8 {
    return allocator.dupe(u8, "%PDF-1.4 fake") catch null;
}

fn fetchSlackTestAudioBytes(allocator: std.mem.Allocator, _: SlackFileInfo) ?[]u8 {
    return allocator.dupe(u8, "OggS fake-audio") catch null;
}

fn fetchSlackTestHtmlBytes(allocator: std.mem.Allocator, _: SlackFileInfo) ?[]u8 {
    return allocator.dupe(u8, "<!DOCTYPE html><html>login</html>") catch null;
}

fn slackTestBasename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |idx| return path[idx + 1 ..];
    return path;
}

fn slackMarkerPath(content: []const u8, marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, content, marker) orelse return null;
    const rest = content[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
    return rest[0..end];
}

test "slack inbound image download becomes an IMAGE vision marker" {
    const alloc = std.testing.allocator;
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &.{});
    ch.file_fetch_override = &fetchSlackTestImageBytes;

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"files":[{"id":"F1","name":"chart.png","mimetype":"image/png","size":42,"url_private":"https://files.slack.com/files-pri/T1-F1/chart.png"}]}
    ,
        .{},
    );
    defer parsed.deinit();

    const content = (try ch.buildFileShareContent(alloc, parsed.value.object, "see attached")) orelse
        return error.TestExpectedEqual;
    defer alloc.free(content);

    const path = slackMarkerPath(content, "[IMAGE:") orelse return error.TestExpectedEqual;
    defer std_compat.fs.deleteFileAbsolute(path) catch {};
    try std.testing.expect(std.mem.startsWith(u8, slackTestBasename(path), "nullclaw_photo_slack_"));
    try std.testing.expect(std.mem.indexOf(u8, content, "see attached") != null);
}

test "slack inbound document download becomes a FILE marker" {
    const alloc = std.testing.allocator;
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &.{});
    ch.file_fetch_override = &fetchSlackTestPdfBytes;

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"files":[{"id":"F2","name":"notes.pdf","mimetype":"application/pdf","size":99,"url_private":"https://files.slack.com/files-pri/T1-F2/notes.pdf"}]}
    ,
        .{},
    );
    defer parsed.deinit();

    const content = (try ch.buildFileShareContent(alloc, parsed.value.object, "")) orelse
        return error.TestExpectedEqual;
    defer alloc.free(content);

    const path = slackMarkerPath(content, "[FILE:") orelse return error.TestExpectedEqual;
    defer std_compat.fs.deleteFileAbsolute(path) catch {};
    try std.testing.expect(std.mem.startsWith(u8, slackTestBasename(path), "nullclaw_doc_slack_"));
}

test "slack inbound audio download reaches the transcription pipeline" {
    const alloc = std.testing.allocator;
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &.{});
    var fake = FakeSlackTranscriber{ .text = "spoken words" };
    ch.transcriber = fake.transcriber();
    ch.file_fetch_override = &fetchSlackTestAudioBytes;

    const tmp_dir = try platform.getTempDir(alloc);
    defer alloc.free(tmp_dir);
    const saved_path = try std.fs.path.join(alloc, &.{ tmp_dir, "nullclaw_doc_slack_F3.m4a" });
    defer alloc.free(saved_path);
    defer std_compat.fs.deleteFileAbsolute(saved_path) catch {};

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"files":[{"id":"F3","name":"clip.m4a","mimetype":"audio/mp4","size":99,"url_private":"https://files.slack.com/files-pri/T1-F3/clip.m4a"}]}
    ,
        .{},
    );
    defer parsed.deinit();

    const content = (try ch.buildFileShareContent(alloc, parsed.value.object, "")) orelse
        return error.TestExpectedEqual;
    defer alloc.free(content);

    try std.testing.expectEqualStrings("[Voice]: spoken words", content);
}

test "slack inbound HTML download falls back to attachment metadata" {
    const alloc = std.testing.allocator;
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &.{});
    ch.file_fetch_override = &fetchSlackTestHtmlBytes;

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"files":[{"id":"F4","name":"chart.png","mimetype":"image/png","size":42,"url_private":"https://files.slack.com/files-pri/T1-F4/chart.png"}]}
    ,
        .{},
    );
    defer parsed.deinit();

    const content = (try ch.buildFileShareContent(alloc, parsed.value.object, "")) orelse
        return error.TestExpectedEqual;
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "[ATTACHMENT:image") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "[IMAGE:") == null);
}

test "slack temp files use names the shared Telegram sweeper removes" {
    const alloc = std.testing.allocator;
    const info = SlackFileInfo{ .id = "F9", .name = "chart.png", .mimetype = "image/png" };
    const path = saveSlackTempFile(alloc, info, "png-bytes") orelse return error.TestExpectedEqual;
    defer alloc.free(path);
    defer std_compat.fs.deleteFileAbsolute(path) catch {};
    try std.testing.expect(std.mem.startsWith(u8, slackTestBasename(path), "nullclaw_photo_slack_"));

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try @import("compat").fs.Dir.wrap(tmp_dir.dir).writeFile(.{
        .sub_path = "nullclaw_photo_slack_F9.png",
        .data = "x",
    });
    const abs_tmp = try @import("compat").fs.Dir.wrap(tmp_dir.dir).realpathAlloc(alloc, ".");
    defer alloc.free(abs_tmp);

    // TTL < 0 forces matched files to be treated as stale for test determinism.
    telegram.sweepTempMediaFilesInDir(abs_tmp, std_compat.time.timestamp(), -1);
    try std.testing.expectError(
        error.FileNotFound,
        @import("compat").fs.Dir.wrap(tmp_dir.dir).statFile("nullclaw_photo_slack_F9.png"),
    );
}

test "slack outbound attachment URLs are rejected to avoid SSRF" {
    const alloc = std.testing.allocator;
    var ch = SlackChannel.init(alloc, "tok", null, "C1", &.{});

    try std.testing.expectError(
        error.UnsupportedAttachmentUrl,
        ch.loadAttachmentBytes("http://127.0.0.1/secret"),
    );
    try std.testing.expectError(
        error.UnsupportedAttachmentUrl,
        ch.loadAttachmentBytes("https://169.254.169.254/latest/meta-data"),
    );
}

test "slack outbound attachment reads local paths" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try @import("compat").fs.Dir.wrap(tmp_dir.dir).writeFile(.{ .sub_path = "chart.png", .data = "png-bytes" });
    const abs_path = try @import("compat").fs.Dir.wrap(tmp_dir.dir).realpathAlloc(alloc, "chart.png");
    defer alloc.free(abs_path);

    var ch = SlackChannel.init(alloc, "tok", null, "C1", &.{});
    const data = try ch.loadAttachmentBytes(abs_path);
    defer alloc.free(data);
    try std.testing.expectEqualStrings("png-bytes", data);
}

test "slack empty final without attachments closes the turn" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();

    try ch.channel().sendEvent("C1:1700.1", "x" ** 200, &.{}, .chunk);
    try ch.channel().sendEvent("C1:1700.1", "", &.{}, .final);

    const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(state.finished_at_ms != 0);
    try std.testing.expectEqual(@as(usize, 0), state.message_ts.len);
    // Regression: the state was freed without chat.stopStream, so Slack kept
    // the message in its streaming state.
    try std.testing.expectEqual(@as(u32, 1), ch.test_native_stop_calls);
}

test "slack marker-only final stops and discards the stream preview" {
    var ch = initStreamingChannel(true);
    defer ch.channel().stop();

    try ch.channel().sendEvent("C1:1700.1", "x" ** 200, &.{}, .chunk);
    try ch.channel().sendEvent("C1:1700.1", "[IMAGE:/tmp/chart.png]", &.{}, .final);

    const state = ch.stream_states.getPtr("C1:1700.1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(state.finished_at_ms != 0);
    try std.testing.expectEqual(@as(usize, 0), state.message_ts.len);
}
