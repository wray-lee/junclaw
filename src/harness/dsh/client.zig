//! dsh Remote API client: HTTP RPC over std.http and the
//! `/api/remote.mux` WebSocket event stream.
//!
//! Ownership: `DshClient` owns its `base_url`/`cookie` copies. Events returned
//! by `nextEvent` own their strings; release them with `freeEvent`.

const std = @import("std");
const std_compat = @import("compat");
const websocket = @import("../../websocket.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;

pub const WS_HOST = "127.0.0.1";
pub const WS_PATH = "/api/remote.mux";
/// Client stream id for the process-wide `$events` waterfall stream.
const events_stream_id = "events";

// ---------------------------------------------------------------------------
// Boot URL helpers
// ---------------------------------------------------------------------------

pub const BootEndpoint = struct {
    /// Scheme + authority, no path/query (`http://127.0.0.1:4123`).
    base_url: []const u8,
    port: u16,
    token: []const u8,
};

/// Split a dsh launch URL into the HTTP base URL, port, and launch token.
/// Every returned slice borrows from `url`.
pub fn parseBootEndpoint(url: []const u8) !BootEndpoint {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidBootUrl;
    const authority_start = scheme_end + 3;
    const authority_end = std.mem.indexOfAnyPos(u8, url, authority_start, "/?#") orelse url.len;
    const authority = url[authority_start..authority_end];
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return error.InvalidBootUrl;
    const port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.InvalidBootUrl;

    const marker = "token=";
    const token_start = (std.mem.indexOf(u8, url, marker) orelse return error.InvalidBootUrl) + marker.len;
    var token_end = token_start;
    while (token_end < url.len and url[token_end] != '&' and url[token_end] != '#') token_end += 1;
    if (token_end == token_start) return error.InvalidBootUrl;

    return .{
        .base_url = url[0..authority_end],
        .port = port,
        .token = url[token_start..token_end],
    };
}

/// Build the owner-cookie exchange URL (`/connect?token=…&interactions=answer`).
pub fn connectUrl(allocator: Allocator, boot_url: []const u8) ![]u8 {
    const endpoint = try parseBootEndpoint(boot_url);
    return std.fmt.allocPrint(
        allocator,
        "{s}/connect?token={s}&interactions=answer",
        .{ endpoint.base_url, endpoint.token },
    );
}

/// Replace the launch token so the URL can be logged.
pub fn redactUrl(allocator: Allocator, url: []const u8) ![]u8 {
    const marker = "token=";
    const start = std.mem.indexOf(u8, url, marker) orelse return allocator.dupe(u8, url);
    var end = start + marker.len;
    while (end < url.len and url[end] != '&' and url[end] != '#') end += 1;
    return std.fmt.allocPrint(allocator, "{s}{s}<redacted>{s}", .{ url[0..start], marker, url[end..] });
}

/// Build the WebSocket/HTTP `Cookie` request header value.
pub fn cookieHeader(allocator: Allocator, cookie: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Cookie: {s}", .{cookie});
}

pub const HttpResponse = struct {
    status: u16,
    /// Raw response head (status line + headers), used to read Set-Cookie.
    headers: []u8,
    body: []u8,
};

const HttpIoCell = struct {
    allocator: Allocator,
    req: *std.http.Client.Request,
    body: ?[]const u8,
    mutex: std_compat.sync.Mutex = .{},
    finished: bool = false,
    abandoned: bool = false,
    result: ?HttpResponse = null,
    err: ?anyerror = null,
};

fn freeHttpResponse(allocator: Allocator, response: HttpResponse) void {
    allocator.free(response.headers);
    allocator.free(response.body);
}

/// Worker half: send the request and read the response. Publishes under the
/// cell lock, or frees the result itself when the caller already gave up.
fn httpIoWorker(cell: *HttpIoCell) void {
    const outcome = performHttpExchange(cell);
    cell.mutex.lock();
    const abandoned = cell.abandoned;
    if (!abandoned) {
        if (outcome) |response| {
            cell.result = response;
        } else |err| {
            cell.err = err;
        }
        cell.finished = true;
    }
    cell.mutex.unlock();

    if (abandoned) {
        if (outcome) |response| freeHttpResponse(cell.allocator, response) else |_| {}
    }
}

fn performHttpExchange(cell: *HttpIoCell) anyerror!HttpResponse {
    const req = cell.req;
    if (cell.body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var request_body = try req.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(payload);
        try request_body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const response_headers = try cell.allocator.dupe(u8, response.head.bytes);
    errdefer cell.allocator.free(response_headers);

    var aw: std.Io.Writer.Allocating = .init(cell.allocator);
    defer aw.deinit();
    var transfer_buffer: [256]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    _ = reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    return .{
        .status = @intFromEnum(response.head.status),
        .headers = response_headers,
        .body = try cell.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]),
    };
}

/// Minimal HTTP/1.1 request to the local sidecar over std.http. No curl
/// dependency: the dsh image is a bare Node image.
/// Redirects are never followed: the connect call needs the 302 that carries
/// the owner cookie, and an RPC redirect is an error, not a new transport.
///
/// std.http has no socket timeout of its own, and `Io.Threaded` treats a recv
/// timeout as a programmer bug, so the exchange runs on a worker and the caller
/// enforces `timeout_ms`: on expiry it shuts the socket down and joins, which
/// unwinds the worker with no buffer or connection left behind.
pub fn httpRequest(
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    headers: []const []const u8,
    body: ?[]const u8,
    timeout_ms: u64,
) !HttpResponse {
    var client: std.http.Client = .{ .allocator = allocator, .io = std_compat.io() };
    defer client.deinit();

    var header_buf: [8]std.http.Header = undefined;
    if (headers.len > header_buf.len) return error.TooManyHeaders;
    for (headers, 0..) |header, index| {
        const colon = std.mem.indexOfScalar(u8, header, ':') orelse return error.InvalidHeader;
        header_buf[index] = .{
            .name = std.mem.trim(u8, header[0..colon], " \t"),
            .value = std.mem.trim(u8, header[colon + 1 ..], " \t"),
        };
    }

    const uri = try std.Uri.parse(url);
    var req = try client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = header_buf[0..headers.len],
    });
    defer req.deinit();

    var cell: HttpIoCell = .{ .allocator = allocator, .req = &req, .body = body };
    const thread = try std.Thread.spawn(.{}, httpIoWorker, .{&cell});
    const deadline = std_compat.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        cell.mutex.lock();
        if (cell.finished) {
            const result = cell.result;
            const err = cell.err;
            cell.mutex.unlock();
            thread.join();
            if (err) |e| return e;
            return result.?;
        }
        if (std_compat.time.milliTimestamp() >= deadline) {
            cell.abandoned = true;
            // Shut down under the cell lock: the worker publishes under the
            // same lock, so the fd cannot be closed or reused behind our back.
            if (req.connection) |connection| {
                const stream = std_compat.net.Stream{
                    .handle = connection.stream_reader.stream.socket.handle,
                };
                stream.shutdown(.both) catch {};
            }
            cell.mutex.unlock();
            thread.join();
            return error.RpcTimeout;
        }
        cell.mutex.unlock();
        std_compat.thread.sleep(std.time.ns_per_ms);
    }
}

fn parsePort(base_url: []const u8) !u16 {
    const scheme_end = std.mem.indexOf(u8, base_url, "://") orelse return error.InvalidBaseUrl;
    const authority_start = scheme_end + 3;
    const authority_end = std.mem.indexOfAnyPos(u8, base_url, authority_start, "/?#") orelse base_url.len;
    const authority = base_url[authority_start..authority_end];
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return error.InvalidBaseUrl;
    return std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch error.InvalidBaseUrl;
}

pub fn newRequestId(allocator: Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std_compat.crypto.random.bytes(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &hex);
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

pub const Event = struct {
    session_id: []u8,
    event: protocol.ServerEvent,
};

pub fn freeEvent(allocator: Allocator, event: *Event) void {
    allocator.free(event.session_id);
    freeServerEvent(allocator, event.event);
}

fn freeServerEvent(allocator: Allocator, event: protocol.ServerEvent) void {
    switch (event) {
        .assistant_chunk => |chunk| switch (chunk) {
            .text_delta => |delta| allocator.free(delta.text),
            .tool_call => |call| {
                allocator.free(call.call_id);
                allocator.free(call.name);
                allocator.free(call.arguments_json);
            },
            .tool_result => |result| {
                allocator.free(result.call_id);
                allocator.free(result.content_json);
            },
            .other => |raw| allocator.free(raw),
        },
        .committed => |message| allocator.free(message),
        .turn_end => |turn| {
            allocator.free(turn.kind);
            if (turn.reason_kind) |kind| allocator.free(kind);
            if (turn.error_message) |message| allocator.free(message);
        },
        .approval_request => |request| {
            allocator.free(request.tool_name);
            allocator.free(request.call_id);
            if (request.display_reason) |reason| allocator.free(reason);
            if (request.event_id) |id| allocator.free(id);
        },
        .ignored => |kind| allocator.free(kind),
        .unknown => |raw| allocator.free(raw),
    }
}

pub const CancelResult = struct {
    /// Terminal `turn/end` kind (normally "aborted").
    kind: []const u8,
    /// Nested terminal reason (e.g. "user"), when dsh reports one.
    reason_kind: ?[]const u8,
    /// Assistant text emitted before the turn ended; caller frees. When
    /// `committed` is set this is the latest committed `assistant/message`
    /// (dsh's finalized prefix), otherwise the sum of `text-delta`s.
    partial_text: []u8,
    /// True when `partial_text` came from a committed `assistant/message`.
    committed: bool,
};

pub fn freeCancelResult(allocator: Allocator, result: *CancelResult) void {
    allocator.free(result.kind);
    if (result.reason_kind) |kind| allocator.free(kind);
    allocator.free(result.partial_text);
}

/// One `session/follow` stream's event queue. The mux reader routes frames
/// here by stream id, so one WebSocket serves every session in the process.
pub const Subscription = struct {
    allocator: Allocator,
    session_id: []u8,
    stream_id: []u8,
    queue: std.ArrayListUnmanaged(Event) = .empty,
    tool_calls: protocol.ToolCallAccumulator = .{},
    /// Call ids whose half-streamed state `drain` dropped. A late `tool-call`
    /// completion for one belongs to the dead turn, not to the next turn.
    stale_calls: std.ArrayListUnmanaged([]u8) = .empty,
    mutex: std_compat.sync.Mutex = .{},
    lost: std.atomic.Value(bool) = .init(false),

    /// Parse one frame addressed to this stream and queue its event.
    fn pushFrame(self: *Subscription, frame_json: []const u8) !void {
        const event = protocol.parseServerFrame(self.allocator, frame_json) catch return;
        try self.pushEvent(event);
    }

    /// Consumes `event`: frees it when no event is emitted or on error.
    fn pushEvent(self: *Subscription, event: protocol.ServerEvent) !void {
        // The accumulator and `drain` share this lock: a drain must never
        // interleave with a fold, or half a tool call survives it.
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.dropStaleToolCall(event)) return;

        // Deltas fold into their pending call and produce no event.
        const emitted = (try self.tool_calls.absorb(self.allocator, event)) orelse return;
        errdefer freeServerEvent(self.allocator, emitted);
        const session_id = try self.allocator.dupe(u8, self.session_id);
        errdefer self.allocator.free(session_id);
        try self.queue.append(self.allocator, .{ .session_id = session_id, .event = emitted });
    }

    /// True when `event` is a late tool-call frame for a call whose deltas
    /// `drain` dropped. A full call clears its tombstone; a stray delta keeps
    /// it so the eventual completion is still swallowed.
    fn dropStaleToolCall(self: *Subscription, event: protocol.ServerEvent) bool {
        const call = switch (event) {
            .assistant_chunk => |chunk| switch (chunk) {
                .tool_call => |tool| tool,
                else => return false,
            },
            else => return false,
        };
        for (self.stale_calls.items, 0..) |stale_id, index| {
            if (!std.mem.eql(u8, stale_id, call.call_id)) continue;
            if (!call.is_delta) self.allocator.free(self.stale_calls.swapRemove(index));
            freeServerEvent(self.allocator, event);
            return true;
        }
        return false;
    }

    /// Drop every queued event. A cancel that timed out leaves the old turn
    /// streaming into this subscription; the next turn must start clean.
    pub fn drain(self: *Subscription) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.queue.items) |*event| freeEvent(self.allocator, event);
        self.queue.clearRetainingCapacity();

        // A turn stopped mid tool-call leaves argument fragments pending.
        // Free them and tombstone the ids so the completion cannot surface as
        // the next turn's `.tool_call` progress.
        for (self.tool_calls.pending.items) |call| {
            const call_id = self.allocator.dupe(u8, call.call_id) catch continue;
            self.stale_calls.append(self.allocator, call_id) catch self.allocator.free(call_id);
        }
        self.tool_calls.deinit(self.allocator);
        self.tool_calls = .{};
    }

    /// Test seam: frames arrive here asynchronously from the mux reader.
    pub fn queuedCount(self: *Subscription) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queue.items.len;
    }

    pub fn nextEvent(self: *Subscription, timeout_ms: u64) !Event {
        const deadline = std_compat.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (true) {
            self.mutex.lock();
            if (self.queue.items.len > 0) {
                const event = self.queue.orderedRemove(0);
                self.mutex.unlock();
                return event;
            }
            const lost = self.lost.load(.acquire);
            self.mutex.unlock();

            if (lost) return error.ConnectionLost;
            if (std_compat.time.milliTimestamp() >= deadline) return error.Timeout;
            std_compat.thread.sleep(5 * std.time.ns_per_ms);
        }
    }

    fn deinitContents(self: *Subscription) void {
        while (self.queue.items.len > 0) {
            var event = self.queue.orderedRemove(0);
            freeEvent(self.allocator, &event);
        }
        self.queue.deinit(self.allocator);
        self.tool_calls.deinit(self.allocator);
        for (self.stale_calls.items) |call_id| self.allocator.free(call_id);
        self.stale_calls.deinit(self.allocator);
        self.allocator.free(self.session_id);
        self.allocator.free(self.stream_id);
    }

    fn deinit(self: *Subscription) void {
        self.deinitContents();
        self.allocator.destroy(self);
    }
};

/// Wait for the aborted `turn/end`, keeping assistant text seen on the way.
fn waitForTurnEnd(sub: *Subscription, timeout_ms: u64) !CancelResult {
    const allocator = sub.allocator;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text.deinit(allocator);
    // A cancelled turn commits its delivered prefix before `turn/end`; that
    // finalized text wins over the deltas that produced it.
    var committed: ?[]u8 = null;
    errdefer if (committed) |message| allocator.free(message);

    const deadline = std_compat.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        const remaining = deadline - std_compat.time.milliTimestamp();
        if (remaining <= 0) return error.CancelTimeout;
        var event = sub.nextEvent(@intCast(remaining)) catch |err| switch (err) {
            error.Timeout => return error.CancelTimeout,
            else => return err,
        };

        switch (event.event) {
            .turn_end => |turn| if (std.mem.eql(u8, turn.kind, "aborted")) {
                // Move the terminal reason out of the queue event.
                const from_committed = committed != null;
                const partial_text = if (committed) |message| blk: {
                    committed = null;
                    break :blk message;
                } else text.toOwnedSlice(allocator) catch |err| {
                    allocator.free(event.session_id);
                    allocator.free(turn.kind);
                    if (turn.reason_kind) |kind| allocator.free(kind);
                    if (turn.error_message) |message| allocator.free(message);
                    return err;
                };
                if (from_committed) text.deinit(allocator);
                allocator.free(event.session_id);
                if (turn.error_message) |message| allocator.free(message);
                return .{
                    .kind = turn.kind,
                    .reason_kind = turn.reason_kind,
                    .partial_text = partial_text,
                    .committed = from_committed,
                };
            },
            .assistant_chunk => |chunk| switch (chunk) {
                .text_delta => |delta| text.appendSlice(allocator, delta.text) catch |err| {
                    freeEvent(allocator, &event);
                    return err;
                },
                else => {},
            },
            .committed => |message| if (message.len > 0) {
                const copy = allocator.dupe(u8, message) catch |err| {
                    freeEvent(allocator, &event);
                    return err;
                };
                if (committed) |old| allocator.free(old);
                committed = copy;
            },
            else => {},
        }
        freeEvent(allocator, &event);
    }
}

/// The process-wide `/api/remote.mux` socket. dsh admits one socket per
/// authenticated peer (`rpc-host.ts` `admitConnection` answers 409 to a second
/// one), so every session follows over this single socket.
const Mux = struct {
    allocator: Allocator,
    ws: websocket.WsClient,
    reader: ?std.Thread = null,
    /// Set when the socket closes; every subscription surfaces ConnectionLost.
    lost: std.atomic.Value(bool) = .init(false),
    /// Serializes client frames on the one socket.
    write_mutex: std_compat.sync.Mutex = .{},
    /// Guards the routing table and `next_stream`.
    mutex: std_compat.sync.Mutex = .{},
    subs: std.ArrayListUnmanaged(*Subscription) = .empty,
    next_stream: u32 = 1,

    fn connect(allocator: Allocator, port: u16, cookie: []const u8, handshake_timeout_ms: u64) !*Mux {
        const mux = try allocator.create(Mux);
        errdefer allocator.destroy(mux);

        const header = try cookieHeader(allocator, cookie);
        defer allocator.free(header);
        // dsh signs the owner cookie for the Host authority, so the handshake
        // Host header must carry the port (unlike the bare connectTcp host).
        const handshake_host = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ WS_HOST, port });
        defer allocator.free(handshake_host);
        const stream = try websocket.WsClient.connectTcp(allocator, WS_HOST, port);
        mux.* = .{
            .allocator = allocator,
            .ws = try connectHandshakeBounded(
                allocator,
                stream,
                handshake_host,
                WS_PATH,
                &.{header},
                handshake_timeout_ms,
            ),
        };
        errdefer mux.ws.deinit();

        const events = try protocol.buildEventsOpen(allocator, events_stream_id);
        defer allocator.free(events);
        try mux.ws.writeText(events);

        mux.reader = try std.Thread.spawn(.{}, readerMain, .{mux});
        return mux;
    }

    /// Open one `session/follow` stream on the shared socket.
    fn subscribe(self: *Mux, session_id: []const u8) !*Subscription {
        if (self.lost.load(.acquire)) return error.ConnectionLost;

        const sub = try self.allocator.create(Subscription);
        var owned = false;
        errdefer if (!owned) self.allocator.destroy(sub);
        const sid = try self.allocator.dupe(u8, session_id);
        errdefer if (!owned) self.allocator.free(sid);

        self.mutex.lock();
        const seq = self.next_stream;
        self.next_stream += 1;
        self.mutex.unlock();
        const stream_id = try std.fmt.allocPrint(self.allocator, "follow-{d}", .{seq});
        errdefer if (!owned) self.allocator.free(stream_id);
        sub.* = .{ .allocator = self.allocator, .session_id = sid, .stream_id = stream_id };

        const frame = try protocol.buildFollowOpen(self.allocator, stream_id, session_id);
        defer self.allocator.free(frame);

        // Register before writing the open: dsh may answer with a snapshot at
        // once, and the reader must have somewhere to put it.
        self.mutex.lock();
        self.subs.append(self.allocator, sub) catch |err| {
            self.mutex.unlock();
            return err;
        };
        owned = true;
        self.mutex.unlock();

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (self.lost.load(.acquire)) {
            self.remove(sub);
            return error.ConnectionLost;
        }
        self.ws.writeText(frame) catch |err| {
            self.remove(sub);
            return err;
        };
        return sub;
    }

    /// Stop the server-side follow stream, then drop its queue.
    fn unsubscribe(self: *Mux, sub: *Subscription) void {
        if (!self.lost.load(.acquire)) {
            const frame: ?[]u8 = std.json.Stringify.valueAlloc(self.allocator, .{
                .type = "cancel",
                .streamId = sub.stream_id,
            }, .{}) catch null;
            if (frame) |text| {
                defer self.allocator.free(text);
                self.write_mutex.lock();
                defer self.write_mutex.unlock();
                self.ws.writeText(text) catch {};
            }
        }
        self.remove(sub);
    }

    fn remove(self: *Mux, sub: *Subscription) void {
        self.mutex.lock();
        for (self.subs.items, 0..) |item, index| {
            if (item == sub) {
                _ = self.subs.swapRemove(index);
                break;
            }
        }
        self.mutex.unlock();
        sub.deinit();
    }

    fn enqueueFrame(self: *Mux, frame_json: []const u8) void {
        const routed = protocol.parseRoutedServerFrame(self.allocator, frame_json) catch return;
        defer if (routed.stream_id) |id| self.allocator.free(id);

        self.mutex.lock();
        defer self.mutex.unlock();
        const stream_id = routed.stream_id orelse {
            freeServerEvent(self.allocator, routed.event);
            return;
        };
        if (std.mem.eql(u8, stream_id, events_stream_id)) {
            // `$events` is process-wide, not tied to one follow stream, so
            // every session queue gets a copy (P1 drops approvals).
            freeServerEvent(self.allocator, routed.event);
            for (self.subs.items) |sub| sub.pushFrame(frame_json) catch {};
            return;
        }
        const sub = self.findSubLocked(stream_id) orelse {
            freeServerEvent(self.allocator, routed.event);
            return;
        };
        sub.pushEvent(routed.event) catch {};
    }

    fn findSubLocked(self: *Mux, stream_id: []const u8) ?*Subscription {
        for (self.subs.items) |sub| {
            if (std.mem.eql(u8, sub.stream_id, stream_id)) return sub;
        }
        return null;
    }

    fn markLost(self: *Mux) void {
        self.lost.store(true, .release);
        self.mutex.lock();
        for (self.subs.items) |sub| sub.lost.store(true, .release);
        self.mutex.unlock();
    }

    fn deinit(self: *Mux) void {
        self.ws.writeClose();
        self.ws.stream.shutdown(.both) catch {};
        if (self.reader) |thread| thread.join();
        self.reader = null;
        self.ws.deinit();
        for (self.subs.items) |sub| sub.deinit();
        self.subs.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

fn readerMain(mux: *Mux) void {
    while (true) {
        const maybe_text = mux.ws.readTextMessage() catch {
            mux.markLost();
            return;
        };
        const text = maybe_text orelse {
            mux.markLost();
            return;
        };
        {
            defer mux.allocator.free(text);
            mux.enqueueFrame(text);
        }
    }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

const HandshakeCell = struct {
    allocator: Allocator,
    stream: std_compat.net.Stream,
    host: []const u8,
    path: []const u8,
    headers: []const []const u8,
    mutex: std_compat.sync.Mutex = .{},
    finished: bool = false,
    abandoned: bool = false,
    ws: ?websocket.WsClient = null,
    err: ?anyerror = null,
};

/// Worker half of the bounded WS upgrade. The worker owns `stream` in every
/// outcome: success hands the WsClient to the caller, failure closes it.
fn handshakeWorker(cell: *HandshakeCell) void {
    const outcome = websocket.WsClient.connectPlainFromStream(
        cell.allocator,
        cell.stream,
        cell.host,
        cell.path,
        cell.headers,
    );
    cell.mutex.lock();
    const abandoned = cell.abandoned;
    if (!abandoned) {
        if (outcome) |ws| {
            cell.ws = ws;
        } else |err| {
            cell.err = err;
        }
        cell.finished = true;
    }
    cell.mutex.unlock();

    if (outcome) |ws| {
        if (abandoned) {
            var owned = ws;
            owned.deinit();
        }
    } else |_| {
        // `connectPlainFromStream` leaves the stream to the caller on failure.
        cell.stream.close();
    }
}

/// Bound the WS upgrade read, which `connectPlainFromStream` leaves unbounded.
/// Takes ownership of `stream`; on timeout the caller shuts the socket down and
/// joins the worker, so no half-open connection outlives the call.
fn connectHandshakeBounded(
    allocator: Allocator,
    stream: std_compat.net.Stream,
    host: []const u8,
    path: []const u8,
    headers: []const []const u8,
    timeout_ms: u64,
) !websocket.WsClient {
    var cell: HandshakeCell = .{
        .allocator = allocator,
        .stream = stream,
        .host = host,
        .path = path,
        .headers = headers,
    };
    const thread = std.Thread.spawn(.{}, handshakeWorker, .{&cell}) catch |err| {
        stream.close();
        return err;
    };
    const deadline = std_compat.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        cell.mutex.lock();
        if (cell.finished) {
            const ws = cell.ws;
            const err = cell.err;
            cell.mutex.unlock();
            thread.join();
            if (err) |e| return e;
            return ws.?;
        }
        if (std_compat.time.milliTimestamp() >= deadline) {
            cell.abandoned = true;
            // Shutdown under the cell lock so the worker cannot close the fd
            // first; it closes the stream only after taking this lock.
            stream.shutdown(.both) catch {};
            cell.mutex.unlock();
            thread.join();
            return error.HandshakeTimeout;
        }
        cell.mutex.unlock();
        std_compat.thread.sleep(std.time.ns_per_ms);
    }
}

/// True when `err` means the sidecar transport died (process gone or the mux
/// socket closed), rather than one RPC or subscription failing on its own.
/// `error.ConnectionLost` is the mux's own signal; the rest come from the HTTP
/// and socket layers.
pub fn isConnectionError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionLost,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionAborted,
        error.ConnectionClose,
        error.BrokenPipe,
        error.NetworkUnreachable,
        error.ReadFailed,
        error.WriteFailed,
        error.UnexpectedEndOfStream,
        error.EndOfStream,
        error.Closed,
        error.HttpConnectionClosing,
        => true,
        else => false,
    };
}

/// dsh answers `session/cancel` with `session/not-found` once the turn has
/// ended and its agent detached; that race means there is nothing to cancel.
fn isSessionNotAttached(reply: protocol.RpcReply) bool {
    const error_json = reply.error_json orelse return false;
    return std.mem.indexOf(u8, error_json, "\"code\":\"session/not-found\"") != null;
}

fn isSessionWriterHeld(reply: protocol.RpcReply) bool {
    const error_json = reply.error_json orelse return false;
    return std.mem.indexOf(u8, error_json, "\"code\":\"session/writer-held\"") != null;
}

pub const DshClient = struct {
    allocator: Allocator,
    base_url: []u8,
    cookie: []u8,
    port: u16,
    /// Deadline for one HTTP RPC; the engine copies its option here.
    rpc_timeout_ms: u64 = 30_000,
    /// Deadline for the WebSocket upgrade handshake.
    handshake_timeout_ms: u64 = 10_000,
    /// The process-wide mux, opened once and shared by every session.
    mux: ?*Mux = null,
    /// Single-session binding used by the client API and its tests.
    sub: ?*Subscription = null,
    /// Engine entries hold a ref while they are bound to this client, so a
    /// restart can free the old client as soon as the last turn moves off it.
    refs: std.atomic.Value(u32) = .init(1),

    /// Take a reference; the caller must already hold one.
    pub fn retain(self: *DshClient) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Drop a reference, freeing the client (and its mux/subscriptions) when
    /// it was the last one.
    pub fn release(self: *DshClient) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            const allocator = self.allocator;
            self.deinit();
            allocator.destroy(self);
        }
    }

    pub fn init(allocator: Allocator, base_url: []const u8, cookie: []const u8) !DshClient {
        const base_copy = try allocator.dupe(u8, base_url);
        errdefer allocator.free(base_copy);
        return .{
            .allocator = allocator,
            .base_url = base_copy,
            .cookie = try allocator.dupe(u8, cookie),
            .port = try parsePort(base_url),
        };
    }

    pub fn deinit(self: *DshClient) void {
        if (self.sub) |sub| self.unsubscribe(sub);
        self.sub = null;
        if (self.mux) |mux| mux.deinit();
        self.mux = null;
        self.allocator.free(self.base_url);
        self.allocator.free(self.cookie);
    }

    /// Open the shared mux once. The engine calls this at boot, before any
    /// session exists; one socket serves the whole process.
    pub fn connectMux(self: *DshClient) !void {
        if (self.mux != null) return;
        self.mux = try Mux.connect(
            self.allocator,
            self.port,
            self.cookie,
            self.handshake_timeout_ms,
        );
    }

    /// Single-session convenience: open the mux and follow `session_id`.
    pub fn connect(self: *DshClient, session_id: []const u8) !void {
        if (self.sub != null) return error.AlreadyConnected;
        try self.connectMux();
        self.sub = try self.mux.?.subscribe(session_id);
    }

    /// Follow one more session on the shared socket.
    pub fn subscribe(self: *DshClient, session_id: []const u8) !*Subscription {
        const mux = self.mux orelse return error.NotConnected;
        return mux.subscribe(session_id);
    }

    pub fn unsubscribe(self: *DshClient, sub: *Subscription) void {
        if (self.mux) |mux| mux.unsubscribe(sub);
    }

    /// POST one RPC and parse the `{result:{ok,value}}` envelope.
    /// Redirects are never followed, so a stray 302 surfaces as `UnexpectedStatus`.
    pub fn call(self: *DshClient, method: []const u8, args_json: []const u8) !protocol.RpcReply {
        const rpc_id = try newRequestId(self.allocator);
        defer self.allocator.free(rpc_id);
        const body = try protocol.buildRpcBody(self.allocator, rpc_id, method, args_json);
        defer self.allocator.free(body);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/{s}", .{ self.base_url, method });
        defer self.allocator.free(url);
        const header = try cookieHeader(self.allocator, self.cookie);
        defer self.allocator.free(header);

        const response = try httpRequest(self.allocator, .POST, url, &.{
            header,
            "Content-Type: application/json",
        }, body, self.rpc_timeout_ms);
        defer self.allocator.free(response.headers);
        defer self.allocator.free(response.body);

        if (response.status != 200) return error.UnexpectedStatus;
        return protocol.parseRpcBody(self.allocator, response.body);
    }

    pub fn freeReply(self: *DshClient, reply: *protocol.RpcReply) void {
        self.allocator.free(reply.value_json);
        if (reply.error_json) |err| self.allocator.free(err);
        reply.* = .{ .ok = false, .value_json = &.{}, .error_json = null };
    }

    pub fn createSession(self: *DshClient, cwd: []const u8) ![]u8 {
        const args = try std.json.Stringify.valueAlloc(self.allocator, .{ .request = .{ .cwd = cwd } }, .{});
        defer self.allocator.free(args);

        var reply = try self.call("session/create", args);
        defer self.freeReply(&reply);
        if (!reply.ok) return error.RpcFailed;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, reply.value_json, .{}) catch
            return error.InvalidRpcReply;
        defer parsed.deinit();
        const value = switch (parsed.value) {
            .object => |object| object.get("sessionId") orelse return error.InvalidRpcReply,
            else => return error.InvalidRpcReply,
        };
        const session_id = switch (value) {
            .string => |text| text,
            else => return error.InvalidRpcReply,
        };
        return self.allocator.dupe(u8, session_id);
    }

    /// Select the Session-local model; dsh persists it as the default in the
    /// background. Requires the session to be resumed (WS `session/follow`).
    pub fn selectModel(
        self: *DshClient,
        session_id: []const u8,
        provider: []const u8,
        model: []const u8,
    ) !void {
        const args = try std.json.Stringify.valueAlloc(self.allocator, .{
            .request = .{ .sessionId = session_id, .provider = provider, .model = model },
        }, .{});
        defer self.allocator.free(args);

        var reply = try self.call("session/selectModel", args);
        defer self.freeReply(&reply);
        if (!reply.ok) return error.RpcFailed;
    }

    pub fn prompt(self: *DshClient, session_id: []const u8, text: []const u8) !void {
        return self.sendPrompt(session_id, text, "queue", null);
    }

    /// Resend with a caller-owned id. dsh dedupes prompts by `requestId`
    /// ("retries whose requestId is already queued or logged return the
    /// original acceptance"), so a retry after a crash must reuse the id.
    pub fn promptWithRequestId(
        self: *DshClient,
        session_id: []const u8,
        text: []const u8,
        request_id: []const u8,
    ) !void {
        return self.sendPrompt(session_id, text, "queue", request_id);
    }

    pub fn steer(self: *DshClient, session_id: []const u8, text: []const u8) !void {
        return self.sendPrompt(session_id, text, "steer", null);
    }

    fn sendPrompt(
        self: *DshClient,
        session_id: []const u8,
        text: []const u8,
        mode: []const u8,
        explicit_id: ?[]const u8,
    ) !void {
        const TextPart = struct { type: []const u8, text: []const u8 };
        const request_id = explicit_id orelse try newRequestId(self.allocator);
        defer if (explicit_id == null) self.allocator.free(request_id);

        const args = try std.json.Stringify.valueAlloc(self.allocator, .{
            .request = .{
                .requestId = request_id,
                .sessionId = session_id,
                .mode = mode,
                .content = [1]TextPart{.{ .type = "text", .text = text }},
            },
        }, .{});
        defer self.allocator.free(args);

        var reply = try self.call("session/prompt", args);
        defer self.freeReply(&reply);
        if (!reply.ok) {
            // dsh maps SessionAlreadyOwnedError to session/writer-held. Keep it
            // distinct so the harness can clear the leftover writer and retry
            // instead of reporting an opaque RPC failure.
            if (isSessionWriterHeld(reply)) return error.SessionWriterHeld;
            return error.RpcFailed;
        }
    }

    /// Cancel the active turn and return the terminal `turn/end` plus any
    /// assistant text emitted before it (queued deltas are otherwise dropped).
    pub fn cancel(self: *DshClient, session_id: []const u8, timeout_ms: u64) !CancelResult {
        const sub = self.sub orelse return error.NotConnected;
        return self.cancelOn(sub, session_id, timeout_ms);
    }

    /// Cancel and drain the given stream's queue (the engine owns one
    /// subscription per session).
    pub fn cancelOn(self: *DshClient, sub: *Subscription, session_id: []const u8, timeout_ms: u64) !CancelResult {
        const args = try std.json.Stringify.valueAlloc(self.allocator, .{ .request = .{ .sessionId = session_id } }, .{});
        defer self.allocator.free(args);

        var reply = try self.call("session/cancel", args);
        defer self.freeReply(&reply);
        if (!reply.ok) {
            // The turn finished before this RPC arrived, so dsh detached its
            // agent and answers session/not-found; nothing is left to cancel.
            if (isSessionNotAttached(reply)) return error.TurnAlreadyEnded;
            return error.RpcFailed;
        }

        return waitForTurnEnd(sub, timeout_ms);
    }

    pub fn closeSession(self: *DshClient, session_id: []const u8) !void {
        const args = try std.json.Stringify.valueAlloc(self.allocator, .{ .request = .{ .sessionId = session_id } }, .{});
        defer self.allocator.free(args);

        var reply = try self.call("session/close", args);
        defer self.freeReply(&reply);
        if (!reply.ok) return error.RpcFailed;
    }

    /// Pop the next event, waiting at most `timeout_ms`.
    /// Returns `error.ConnectionLost` when the WebSocket reader stopped.
    pub fn nextEvent(self: *DshClient, timeout_ms: u64) !Event {
        const sub = self.sub orelse return error.NotConnected;
        return sub.nextEvent(timeout_ms);
    }
};

// ---------------------------------------------------------------------------
// Tests (pure logic; no network, Node, or wall-clock assertions)
// ---------------------------------------------------------------------------

test "buildRpcBody produces the dsh client-request envelope" {
    const body = try protocol.buildRpcBody(std.testing.allocator, "r-1", "session/prompt", "{\"request\":{}}");
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"type\":\"client-request\",\"rpcId\":\"r-1\",\"method\":\"session/prompt\",\"payload\":{\"args\":{\"request\":{}}}}",
        body,
    );
}

test "owner cookies join into one Cookie header" {
    const cookie = try protocol.ownerCookieFromSetCookie(std.testing.allocator, &.{
        "dsh_owner=test-value; Path=/; HttpOnly; SameSite=Lax",
        "dsh_operator=test-operator; Path=/",
    });
    defer std.testing.allocator.free(cookie);
    try std.testing.expectEqualStrings("dsh_owner=test-value; dsh_operator=test-operator", cookie);

    const header = try cookieHeader(std.testing.allocator, cookie);
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings("Cookie: dsh_owner=test-value; dsh_operator=test-operator", header);
}

test "boot URL yields base URL, port, connect URL and a redacted form" {
    const url = "http://127.0.0.1:54321/?token=test-token&interactions=answer";
    const endpoint = try parseBootEndpoint(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:54321", endpoint.base_url);
    try std.testing.expectEqual(@as(u16, 54321), endpoint.port);
    try std.testing.expectEqualStrings("test-token", endpoint.token);

    const connect = try connectUrl(std.testing.allocator, url);
    defer std.testing.allocator.free(connect);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:54321/connect?token=test-token&interactions=answer",
        connect,
    );

    const redacted = try redactUrl(std.testing.allocator, url);
    defer std.testing.allocator.free(redacted);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:54321/?token=<redacted>&interactions=answer",
        redacted,
    );
}

test "DshClient keeps the boot base URL and port" {
    var dsh = try DshClient.init(std.testing.allocator, "http://127.0.0.1:4123", "dsh_owner=test");
    defer dsh.deinit();
    try std.testing.expectEqual(@as(u16, 4123), dsh.port);
    try std.testing.expectEqualStrings("http://127.0.0.1:4123", dsh.base_url);
    try std.testing.expectEqualStrings("dsh_owner=test", dsh.cookie);
}

test "event queue routes parsed frames and tags the session" {
    var shared = Subscription{
        .allocator = std.testing.allocator,
        .session_id = try std.testing.allocator.dupe(u8, "session-test"),
        .stream_id = try std.testing.allocator.dupe(u8, "follow"),
    };
    defer shared.deinitContents();

    try shared.pushFrame(
        "{\"type\":\"item\",\"streamId\":\"follow\",\"value\":{\"type\":\"event\",\"event\":{\"type\":\"turn/end\",\"data\":{\"reason\":{\"kind\":\"aborted\",\"reason\":{\"kind\":\"user\"}}}}}}",
    );
    try shared.pushFrame(
        "{\"type\":\"item\",\"streamId\":\"follow\",\"value\":{\"type\":\"assistant-stream\",\"data\":{\"type\":\"text-delta\",\"index\":0,\"text\":\"slow-12 \"}}}",
    );

    var ended = try shared.nextEvent(0);
    try std.testing.expectEqualStrings("session-test", ended.session_id);
    switch (ended.event) {
        .turn_end => |turn| {
            try std.testing.expectEqualStrings("aborted", turn.kind);
            try std.testing.expectEqualStrings("user", turn.reason_kind.?);
        },
        else => return error.TestUnexpectedEvent,
    }
    freeEvent(std.testing.allocator, &ended);

    var chunk = try shared.nextEvent(0);
    try std.testing.expectEqualStrings("session-test", chunk.session_id);
    switch (chunk.event) {
        .assistant_chunk => |value| switch (value) {
            .text_delta => |delta| try std.testing.expectEqualStrings("slow-12 ", delta.text),
            else => return error.TestUnexpectedEvent,
        },
        else => return error.TestUnexpectedEvent,
    }
    freeEvent(std.testing.allocator, &chunk);

    try std.testing.expectError(error.Timeout, shared.nextEvent(0));
}

test "streamed tool call frames enqueue one tool_call event" {
    // Regression: tool-call after tool-call-delta produced two identical tool_call events.
    const allocator = std.testing.allocator;
    var shared = Subscription{
        .allocator = allocator,
        .session_id = try allocator.dupe(u8, "session-test"),
        .stream_id = try allocator.dupe(u8, "follow"),
    };
    defer shared.deinitContents();

    try shared.pushFrame(
        "{\"type\":\"assistant-stream\",\"data\":{\"type\":\"tool-call-delta\",\"callId\":\"call-1\"," ++
            "\"name\":\"read\",\"argumentsDelta\":\"{\\\"path\\\":\\\"example.com\\\"}\"}}",
    );
    try shared.pushFrame(
        "{\"type\":\"assistant-stream\",\"data\":{\"type\":\"tool-call\",\"callId\":\"call-1\"," ++
            "\"name\":\"read\",\"arguments\":{\"path\":\"example.com\"}}}",
    );

    var event = try shared.nextEvent(0);
    defer freeEvent(allocator, &event);
    switch (event.event) {
        .assistant_chunk => |chunk| switch (chunk) {
            .tool_call => |call| {
                try std.testing.expectEqualStrings("call-1", call.call_id);
                try std.testing.expectEqualStrings("{\"path\":\"example.com\"}", call.arguments_json);
            },
            else => return error.TestUnexpectedChunk,
        },
        else => return error.TestUnexpectedEvent,
    }
    try std.testing.expectError(error.Timeout, shared.nextEvent(0));
}

test "cancel result surfaces the aborted turn/end and partial text" {
    // Regression: cancel() returned without exposing turn/end aborted.
    const allocator = std.testing.allocator;
    var shared = Subscription{
        .allocator = allocator,
        .session_id = try allocator.dupe(u8, "session-test"),
        .stream_id = try allocator.dupe(u8, "follow"),
    };
    defer shared.deinitContents();

    try shared.pushFrame(
        "{\"type\":\"assistant-stream\",\"data\":{\"type\":\"text-delta\",\"index\":0,\"text\":\"partial answer\"}}",
    );
    try shared.pushFrame(
        "{\"type\":\"event\",\"event\":{\"type\":\"turn/end\",\"data\":{\"reason\":{\"kind\":\"aborted\",\"reason\":{\"kind\":\"user\"}}}}}",
    );

    var result = try waitForTurnEnd(&shared, 1000);
    defer freeCancelResult(allocator, &result);
    try std.testing.expectEqualStrings("aborted", result.kind);
    try std.testing.expectEqualStrings("user", result.reason_kind.?);
    try std.testing.expectEqualStrings("partial answer", result.partial_text);
}

test "drain drops a half-streamed tool call and its late completion" {
    // Regression: drain() cleared only the event queue. A turn cancelled mid
    // tool-call kept its pending arguments forever, and the late full
    // `tool-call` surfaced as the next turn's `.tool_call` progress.
    const allocator = std.testing.allocator;
    var shared = Subscription{
        .allocator = allocator,
        .session_id = try allocator.dupe(u8, "session-test"),
        .stream_id = try allocator.dupe(u8, "follow"),
    };
    defer shared.deinitContents();

    try shared.pushFrame(
        "{\"type\":\"assistant-stream\",\"data\":{\"type\":\"tool-call-delta\",\"callId\":\"call-1\"," ++
            "\"name\":\"read\",\"argumentsDelta\":\"{\\\"path\\\":\"}}",
    );
    try shared.pushFrame(
        "{\"type\":\"assistant-stream\",\"data\":{\"type\":\"tool-call-delta\",\"callId\":\"call-1\"," ++
            "\"name\":\"read\",\"argumentsDelta\":\"\\\"example.com\\\"}\"}}",
    );
    try std.testing.expectEqual(@as(usize, 0), shared.queuedCount());

    shared.drain();
    try std.testing.expectEqual(@as(usize, 0), shared.tool_calls.pending.items.len);

    // The dead turn's completion arrives late: swallowed, not emitted.
    try shared.pushFrame(
        "{\"type\":\"assistant-stream\",\"data\":{\"type\":\"tool-call\",\"callId\":\"call-1\"," ++
            "\"name\":\"read\",\"arguments\":{\"path\":\"example.com\"}}}",
    );
    try std.testing.expectEqual(@as(usize, 0), shared.queuedCount());

    // A fresh call still surfaces normally.
    try shared.pushFrame(
        "{\"type\":\"assistant-stream\",\"data\":{\"type\":\"tool-call\",\"callId\":\"call-2\"," ++
            "\"name\":\"read\",\"arguments\":{\"path\":\"example.com\"}}}",
    );
    try std.testing.expectEqual(@as(usize, 1), shared.queuedCount());
    var event = try shared.nextEvent(0);
    defer freeEvent(allocator, &event);
    switch (event.event) {
        .assistant_chunk => |chunk| switch (chunk) {
            .tool_call => |call| try std.testing.expectEqualStrings("call-2", call.call_id),
            else => return error.TestUnexpectedChunk,
        },
        else => return error.TestUnexpectedEvent,
    }
}

test "writer-held RPC error is distinct from a generic RPC failure" {
    const held = protocol.RpcReply{
        .ok = false,
        .value_json = "null",
        .error_json = "{\"code\":\"session/writer-held\",\"message\":\"session is owned by another writer\"}",
    };
    try std.testing.expect(isSessionWriterHeld(held));
    try std.testing.expect(!isSessionNotAttached(held));
    try std.testing.expect(!isSessionWriterHeld(.{ .ok = true, .value_json = "null", .error_json = null }));
}
