//! P0 spike: drive a real dsh web sidecar end to end.
//!
//! Runs the design §4 P0 checklist against a keyless OpenAI mock:
//! spawn -> boot URL -> owner cookie -> session/create -> follow -> tool round
//! with an approval waterfall -> completed turn -> slow turn cancelled by the
//! user -> session id persisted -> sidecar killed and restarted -> follow the
//! persisted session -> short turn completed.
//!
//! Every output line is `PHASE …` or `EVENT session=… <type> …`. Text is
//! clipped, launch tokens are redacted, and cookies are never printed.

const std = @import("std");
const std_compat = @import("compat");
const yc = @import("nullclaw");

const client = yc.harness_dsh.client;
const sidecar = yc.harness_dsh.sidecar;
const protocol = yc.harness_dsh.protocol;

const Allocator = std.mem.Allocator;

const Args = struct {
    dsh_bin: []const u8,
    workspace: []const u8,
    dsh_home: []const u8,
    persist_file: []const u8,
};

fn parseArgs(allocator: Allocator) !Args {
    const argv = try std_compat.process.argsAlloc(allocator);
    var dsh_bin: ?[]const u8 = null;
    var workspace: ?[]const u8 = null;
    var dsh_home: ?[]const u8 = null;
    var persist_file: ?[]const u8 = null;

    var index: usize = 1;
    while (index < argv.len) : (index += 2) {
        if (index + 1 >= argv.len) return error.MissingArgumentValue;
        const key = argv[index];
        const value = argv[index + 1];
        if (std.mem.eql(u8, key, "--dsh-bin")) {
            dsh_bin = value;
        } else if (std.mem.eql(u8, key, "--workspace")) {
            workspace = value;
        } else if (std.mem.eql(u8, key, "--dsh-home")) {
            dsh_home = value;
        } else if (std.mem.eql(u8, key, "--persist-file")) {
            persist_file = value;
        } else {
            return error.UnknownArgument;
        }
    }

    return .{
        .dsh_bin = dsh_bin orelse return error.MissingDshBin,
        .workspace = workspace orelse return error.MissingWorkspace,
        .dsh_home = dsh_home orelse return error.MissingDshHome,
        .persist_file = persist_file orelse return error.MissingPersistFile,
    };
}

fn emit(comptime fmt: []const u8, args: anytype) void {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print(fmt, args) catch return;
    std_compat.fs.File.stdout().writeAll(writer.buffered()) catch {};
}

/// One event per line: collapse newlines and clip long text.
fn oneLine(buffer: []u8, text: []const u8) []const u8 {
    const max: usize = 80;
    const take = @min(text.len, max);
    var len: usize = 0;
    for (text[0..take]) |char| {
        if (len >= buffer.len) break;
        buffer[len] = if (char == '\n' or char == '\r') ' ' else char;
        len += 1;
    }
    if (text.len > take and len + 3 <= buffer.len) {
        @memcpy(buffer[len .. len + 3], "...");
        len += 3;
    }
    return buffer[0..len];
}

fn printEvent(session_id: []const u8, event: protocol.ServerEvent) void {
    switch (event) {
        .committed => |message| {
            var text_buf: [128]u8 = undefined;
            emit("EVENT session={s} committed text=\"{s}\"\n", .{ session_id, oneLine(&text_buf, message) });
        },
        .assistant_chunk => |chunk| switch (chunk) {
            .text_delta => |delta| {
                var text_buf: [128]u8 = undefined;
                emit("EVENT session={s} text-delta index={d} text=\"{s}\"\n", .{
                    session_id,
                    delta.index,
                    oneLine(&text_buf, delta.text),
                });
            },
            .tool_call => |call| {
                var args_buf: [128]u8 = undefined;
                emit("EVENT session={s} tool-call id={s} name={s} args={s}\n", .{
                    session_id,
                    call.call_id,
                    call.name,
                    oneLine(&args_buf, call.arguments_json),
                });
            },
            .tool_result => |result| {
                var content_buf: [128]u8 = undefined;
                emit("EVENT session={s} tool-result id={s} isError={} content=\"{s}\"\n", .{
                    session_id,
                    result.call_id,
                    result.is_error,
                    oneLine(&content_buf, result.content_json),
                });
            },
            .reasoning_delta => {},
            .other => {},
        },
        .turn_end => |turn| emit("EVENT session={s} turn/end kind={s} reason={s}\n", .{
            session_id,
            turn.kind,
            turn.reason_kind orelse "-",
        }),
        .approval_request => |request| {
            var reason_buf: [128]u8 = undefined;
            emit("EVENT session={s} approval/request toolName={s} callId={s} eventId={s} displayReason=\"{s}\"\n", .{
                session_id,
                request.tool_name,
                request.call_id,
                request.event_id orelse "-",
                oneLine(&reason_buf, request.display_reason orelse ""),
            });
        },
        .ignored => {},
        .unknown => {},
    }
}

fn frameHas(raw: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, raw, needle) != null;
}

fn extractString(raw: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buffer: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buffer, "\"{s}\":\"", .{key}) catch return null;
    const start = (std.mem.indexOf(u8, raw, pattern) orelse return null) + pattern.len;
    const end = std.mem.indexOfScalarPos(u8, raw, start, '"') orelse return null;
    return raw[start..end];
}

/// Consume events until the follow snapshot arrives, remembering the
/// `$events` client id needed to answer waterfall requests.
fn waitForSnapshot(
    client_ptr: *client.DshClient,
    allocator: Allocator,
    session_id: []const u8,
    client_id: *?[]const u8,
    timeout_ms: u64,
) !protocol.Snapshot {
    const deadline = std_compat.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std_compat.time.milliTimestamp() < deadline) {
        var event = client_ptr.nextEvent(250) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        defer client.freeEvent(allocator, &event);
        switch (event.event) {
            .unknown => |raw| {
                if (frameHas(raw, "\"type\":\"ready\"")) {
                    // The event owns `raw` and is freed before the next poll;
                    // keep a copy that outlives it.
                    client_id.* = if (extractString(raw, "clientId")) |cid|
                        try allocator.dupe(u8, cid)
                    else
                        null;
                    emit("EVENT session={s} events-ready clientId={s}\n", .{
                        session_id,
                        client_id.* orelse "-",
                    });
                } else if (frameHas(raw, "\"type\":\"snapshot\"")) {
                    return protocol.parseSnapshot(allocator, raw);
                }
            },
            else => printEvent(session_id, event.event),
        }
    }
    return error.SnapshotTimeout;
}

fn nextTurnEnd(
    client_ptr: *client.DshClient,
    allocator: Allocator,
    session_id: []const u8,
    timeout_ms: u64,
) !client.Event {
    const deadline = std_compat.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std_compat.time.milliTimestamp() < deadline) {
        var event = client_ptr.nextEvent(250) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        printEvent(session_id, event.event);
        if (event.event == .turn_end) return event;
        client.freeEvent(allocator, &event);
    }
    return error.TurnTimeout;
}

/// Tool round: mock streams a bash call, the sandbox denies an
/// out-of-workspace write, the escalation call raises an approval waterfall,
/// and `allowed-once` lets the tool run and the turn complete.
fn runToolTurn(
    client_ptr: *client.DshClient,
    allocator: Allocator,
    session_id: []const u8,
    client_id: *?[]const u8,
) !void {
    try client_ptr.prompt(session_id, "🎁 TOOL round: write outside the workspace");
    emit("PHASE prompt-tool accepted session={s}\n", .{session_id});

    var answered = false;
    const deadline = std_compat.time.milliTimestamp() + 30_000;
    while (std_compat.time.milliTimestamp() < deadline) {
        var event = client_ptr.nextEvent(250) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        defer client.freeEvent(allocator, &event);

        switch (event.event) {
            .unknown => |raw| {
                if (frameHas(raw, "\"type\":\"ready\"")) {
                    // The event owns `raw` and is freed before the next poll;
                    // keep a copy that outlives it.
                    client_id.* = if (extractString(raw, "clientId")) |cid|
                        try allocator.dupe(u8, cid)
                    else
                        null;
                    emit("EVENT session={s} events-ready clientId={s}\n", .{
                        session_id,
                        client_id.* orelse "-",
                    });
                }
            },
            .approval_request => |request| {
                printEvent(session_id, event.event);
                const cid = client_id.* orelse return error.MissingClientId;
                const event_id = request.event_id orelse return error.MissingEventId;
                const args = try protocol.buildApprovalResultArgs(
                    allocator,
                    cid,
                    event_id,
                    "allowed-once",
                );
                defer allocator.free(args);
                var reply = try client_ptr.call("$events/result", args);
                defer client_ptr.freeReply(&reply);
                if (!reply.ok) {
                    emit("EVENT session={s} approval-error {s}\n", .{
                        session_id,
                        reply.error_json orelse "null",
                    });
                    return error.ApprovalRejected;
                }
                if (answered) return error.DuplicateApproval;
                answered = true;
                emit("PHASE approval-answer outcome=allowed-once eventId={s}\n", .{event_id});
            },
            .turn_end => |turn| {
                printEvent(session_id, event.event);
                if (!std.mem.eql(u8, turn.kind, "completed")) return error.ToolTurnNotCompleted;
                if (!answered) return error.ApprovalNeverRequested;
                return;
            },
            else => printEvent(session_id, event.event),
        }
    }
    return error.ToolTurnTimeout;
}

/// Slow round: the mock streams for ~10s; cancel after ~0.8s and expect
/// `turn/end kind=aborted reason=user`.
fn runSlowCancelTurn(
    client_ptr: *client.DshClient,
    allocator: Allocator,
    session_id: []const u8,
) !void {
    try client_ptr.prompt(session_id, "🐌 SLOW run for cancel");
    emit("PHASE prompt-slow accepted session={s}\n", .{session_id});

    const slow_until = std_compat.time.milliTimestamp() + 800;
    while (std_compat.time.milliTimestamp() < slow_until) {
        var event = client_ptr.nextEvent(100) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        printEvent(session_id, event.event);
        client.freeEvent(allocator, &event);
    }

    const args = try std.json.Stringify.valueAlloc(allocator, .{
        .request = .{ .sessionId = session_id },
    }, .{});
    defer allocator.free(args);
    var reply = try client_ptr.call("session/cancel", args);
    defer client_ptr.freeReply(&reply);
    if (!reply.ok) return error.CancelRejected;
    emit("PHASE cancel accepted session={s}\n", .{session_id});

    const deadline = std_compat.time.milliTimestamp() + 15_000;
    while (std_compat.time.milliTimestamp() < deadline) {
        var event = client_ptr.nextEvent(250) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        defer client.freeEvent(allocator, &event);
        switch (event.event) {
            .turn_end => |turn| {
                printEvent(session_id, event.event);
                const reason = turn.reason_kind orelse "";
                if (!std.mem.eql(u8, turn.kind, "aborted") or
                    !std.mem.eql(u8, reason, "user"))
                {
                    return error.CancelDidNotAbort;
                }
                return;
            },
            else => printEvent(session_id, event.event),
        }
    }
    return error.CancelTimeout;
}

fn redactedBootUrl(allocator: Allocator, side: *sidecar.Sidecar) ![]u8 {
    return client.redactUrl(allocator, side.boot_url orelse return error.SidecarNotStarted);
}

pub fn main(init: std.process.Init) !void {
    std_compat.initProcess(init);
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const args = try parseArgs(allocator);
    const options = sidecar.Options{
        .bin_js = args.dsh_bin,
        .workspace = args.workspace,
        .dsh_home = args.dsh_home,
    };

    var session_id: []const u8 = undefined;
    {
        var side = try sidecar.Sidecar.start(allocator, options);
        defer side.deinit();

        const boot_url = try redactedBootUrl(allocator, &side);
        emit("PHASE sidecar-spawn url={s}\n", .{boot_url});
        emit("PHASE connect owner-cookie=acquired\n", .{});

        var dsh = try client.DshClient.init(allocator, side.base_url.?, side.cookie.?);
        defer dsh.deinit();

        session_id = try dsh.createSession(args.workspace);
        emit("PHASE session/create session={s} cwd={s}\n", .{ session_id, args.workspace });

        try dsh.connect(session_id);
        emit("PHASE session/follow session={s} assistantStream=true\n", .{session_id});

        var events_client_id: ?[]const u8 = null;
        const snapshot = try waitForSnapshot(&dsh, allocator, session_id, &events_client_id, 10_000);
        emit("PHASE follow-snapshot cursor={?d} records={d} turn={s}\n", .{
            snapshot.cursor,
            snapshot.record_count,
            snapshot.turn_kind orelse "-",
        });

        try runToolTurn(&dsh, allocator, session_id, &events_client_id);
        try runSlowCancelTurn(&dsh, allocator, session_id);

        try sidecar.saveSessionId(args.persist_file, session_id);
        emit("PHASE session/persist file={s} session={s}\n", .{ args.persist_file, session_id });
    }
    emit("PHASE sidecar-killed session={s}\n", .{session_id});

    {
        var side = try sidecar.Sidecar.start(allocator, options);
        defer side.deinit();

        const boot_url = try redactedBootUrl(allocator, &side);
        emit("PHASE sidecar-restart url={s}\n", .{boot_url});
        emit("PHASE connect owner-cookie=acquired\n", .{});

        const persisted = (try sidecar.loadSessionId(allocator, args.persist_file)) orelse
            return error.PersistedSessionMissing;
        if (!std.mem.eql(u8, persisted, session_id)) return error.PersistedSessionMismatch;

        var dsh = try client.DshClient.init(allocator, side.base_url.?, side.cookie.?);
        defer dsh.deinit();

        try dsh.connect(persisted);
        emit("PHASE resume-follow session={s} assistantStream=true\n", .{persisted});

        var events_client_id: ?[]const u8 = null;
        const snapshot = try waitForSnapshot(&dsh, allocator, persisted, &events_client_id, 10_000);
        emit("PHASE resume-snapshot session={s} cursor={?d} records={d} turn={s}\n", .{
            persisted,
            snapshot.cursor,
            snapshot.record_count,
            snapshot.turn_kind orelse "-",
        });

        try dsh.prompt(persisted, "resume hello");
        emit("PHASE resume-prompt accepted session={s}\n", .{persisted});
        var ended = try nextTurnEnd(&dsh, allocator, persisted, 30_000);
        defer client.freeEvent(allocator, &ended);
        switch (ended.event) {
            .turn_end => |turn| {
                if (!std.mem.eql(u8, turn.kind, "completed")) return error.ResumeTurnNotCompleted;
            },
            else => return error.ResumeTurnNotCompleted,
        }
    }

    emit("PHASE done tool-turn=completed slow-turn=aborted resume=completed\n", .{});
}
