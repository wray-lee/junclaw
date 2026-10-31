//! Android device capability bridge — client for the Kotlin host socket.
//!
//! Contract: DSH ENGINE-CONTRACT §3 (newline-delimited JSON-RPC 2.0), with
//! one connection per request. Host tools are registered as `android_<name>`
//! only when this binary is an Android build and `JUNCLAW_DEVICE_SOCKET` is set.

const std = @import("std");
const builtin = @import("builtin");
const std_compat = @import("compat");
const fs_compat = @import("../fs_compat.zig");
const root = @import("root.zig");

const testing = std.testing;
const log = std.log.scoped(.android_device);
const Allocator = std.mem.Allocator;

// ── Contract constants ──────────────────────────────────────────────

pub const socket_env_var = "JUNCLAW_DEVICE_SOCKET";
pub const name_prefix = "android_";
pub const max_frame_bytes: usize = 64 * 1024 * 1024;
pub const list_timeout_ms: u64 = 10_000;
pub const invoke_timeout_margin_ms: u64 = 10_000;
pub const image_dir_name = "android-device";

pub const Risk = enum { read, write, sensitive, dangerous };

pub const ToolDescriptor = struct {
    name: []const u8,
    group: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
    risk: Risk,
    needs_unlock: bool,
    timeout_ms: u64,
};

/// Descriptors allocated in one arena; `deinit` releases everything.
pub const DescriptorList = struct {
    arena: std.heap.ArenaAllocator,
    items: []ToolDescriptor,

    pub fn deinit(self: *DescriptorList, allocator: Allocator) void {
        self.arena.deinit();
        allocator.free(self.items);
        self.* = undefined;
    }
};

// ── Names ───────────────────────────────────────────────────────────

pub fn isValidToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

pub fn prefixedName(allocator: Allocator, host_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ name_prefix, host_name });
}

/// Strips the junclaw-side prefix; returns null when `prefixed` is not one.
pub fn hostName(prefixed: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, prefixed, name_prefix)) return null;
    const name = prefixed[name_prefix.len..];
    if (name.len == 0) return null;
    return name;
}

// ── NDJSON framing ──────────────────────────────────────────────────

pub fn extractFrame(bytes: []const u8, max_bytes: usize) error{ NeedMore, LineTooLong }![]const u8 {
    if (std.mem.indexOfScalar(u8, bytes, '\n')) |end| {
        if (end > max_bytes) return error.LineTooLong;
        const line = bytes[0..end];
        if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
        return line;
    }
    if (bytes.len > max_bytes) return error.LineTooLong;
    return error.NeedMore;
}

// ── Descriptor parsing ──────────────────────────────────────────────

fn stringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn parseDescriptor(arena: Allocator, entry: std.json.Value) !ToolDescriptor {
    if (entry != .object) return error.InvalidDescriptor;
    const object = entry.object;

    const name = stringField(object, "name") orelse return error.InvalidDescriptor;
    if (!isValidToolName(name)) return error.InvalidDescriptor;
    const group = stringField(object, "group") orelse return error.InvalidDescriptor;
    const description = stringField(object, "description") orelse return error.InvalidDescriptor;

    const schema_value = object.get("inputSchema") orelse return error.InvalidDescriptor;
    if (schema_value != .object) return error.InvalidDescriptor;

    const risk_name = stringField(object, "risk") orelse return error.InvalidDescriptor;
    const risk = std.meta.stringToEnum(Risk, risk_name) orelse return error.InvalidDescriptor;

    const needs_unlock = switch (object.get("needsUnlock") orelse return error.InvalidDescriptor) {
        .bool => |value| value,
        else => return error.InvalidDescriptor,
    };
    const timeout_ms = switch (object.get("timeoutMs") orelse return error.InvalidDescriptor) {
        .integer => |value| if (value < 0) return error.InvalidDescriptor else @as(u64, @intCast(value)),
        else => return error.InvalidDescriptor,
    };

    return .{
        .name = try arena.dupe(u8, name),
        .group = try arena.dupe(u8, group),
        .description = try arena.dupe(u8, description),
        .input_schema_json = try std.json.Stringify.valueAlloc(arena, schema_value, .{}),
        .risk = risk,
        .needs_unlock = needs_unlock,
        .timeout_ms = timeout_ms,
    };
}

/// Parses the `result` member of a `capability/list` response. Entries that do
/// not match the contract descriptor shape are dropped, not fatal.
pub fn parseListResult(allocator: Allocator, result: std.json.Value) !DescriptorList {
    if (result != .object) return error.Protocol;
    const tools_value = result.object.get("tools") orelse return error.Protocol;
    if (tools_value != .array) return error.Protocol;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var items: std.ArrayList(ToolDescriptor) = .empty;
    errdefer items.deinit(allocator);

    for (tools_value.array.items) |entry| {
        const descriptor = parseDescriptor(arena.allocator(), entry) catch |err| switch (err) {
            error.InvalidDescriptor => continue,
            else => return err,
        };
        try items.append(allocator, descriptor);
    }

    return .{ .arena = arena, .items = try items.toOwnedSlice(allocator) };
}

// ── Request / response transport ────────────────────────────────────

pub fn buildRequestLine(allocator: Allocator, method: []const u8, params: std.json.Value) ![]u8 {
    var envelope: std.json.ObjectMap = .empty;
    defer envelope.deinit(allocator);
    try envelope.put(allocator, "jsonrpc", .{ .string = "2.0" });
    try envelope.put(allocator, "id", .{ .integer = 1 });
    try envelope.put(allocator, "method", .{ .string = method });
    try envelope.put(allocator, "params", params);
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = envelope }, .{});
}

/// Opens one connection, sends one request line, reads one response line.
/// Timeout or cancellation closes the connection, which the host treats as
/// `capability/cancel`. Reads use the poll-based helper because std's
/// SO_RCVTIMEO path maps EAGAIN to a panic.
pub fn request(
    allocator: Allocator,
    socket_path: []const u8,
    line: []const u8,
    timeout_ms: u64,
) !std.json.Parsed(std.json.Value) {
    const io = std_compat.io();
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const inner = try address.connect(io);
    const conn = std_compat.net.Stream{ .handle = inner.socket.handle };
    defer conn.close();

    // Requests are far smaller than a socket buffer; a wedged host is bounded
    // by the read timeout instead.
    try conn.writeAll(line);
    try conn.writeAll("\n");

    const started_ms = std_compat.time.milliTimestamp();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    while (true) {
        if (extractFrame(buffer.items, max_frame_bytes)) |frame| {
            return std.json.parseFromSlice(std.json.Value, allocator, frame, .{});
        } else |err| switch (err) {
            error.NeedMore => {},
            error.LineTooLong => return error.LineTooLong,
        }

        const elapsed: u64 = @intCast(@max(0, std_compat.time.milliTimestamp() - started_ms));
        if (elapsed >= timeout_ms) return error.Timeout;
        const remaining: u32 = @intCast(@min(timeout_ms - elapsed, std.math.maxInt(u32)));
        var chunk: [4096]u8 = undefined;
        const n = std_compat.net.readWithTimeout(conn, &chunk, remaining) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return err,
        };
        if (n == 0) return error.ServerClosed;
        try buffer.appendSlice(allocator, chunk[0..n]);
    }
}

const RpcErrorInfo = struct {
    code: i64,
    message: []const u8,
};

fn rpcErrorInfo(value: std.json.Value) ?RpcErrorInfo {
    if (value != .object) return null;
    const error_value = value.object.get("error") orelse return null;
    if (error_value != .object) return null;
    const code = switch (error_value.object.get("code") orelse return null) {
        .integer => |number| number,
        else => 0,
    };
    return .{ .code = code, .message = stringField(error_value.object, "message") orelse "" };
}

fn responseResult(value: std.json.Value) !std.json.Value {
    if (value != .object) return error.Protocol;
    if (rpcErrorInfo(value)) |info| {
        log.warn("device bridge JSON-RPC error {d}: {s}", .{ info.code, info.message });
        return error.RpcError;
    }
    return value.object.get("result") orelse error.Protocol;
}

pub fn listFromSocket(allocator: Allocator, socket_path: []const u8, timeout_ms: u64) !DescriptorList {
    var params: std.json.ObjectMap = .empty;
    defer params.deinit(allocator);
    const line = try buildRequestLine(allocator, "capability/list", .{ .object = params });
    defer allocator.free(line);

    var response = try request(allocator, socket_path, line, timeout_ms);
    defer response.deinit();
    const result = try responseResult(response.value);
    return parseListResult(allocator, result);
}

// ── ToolResult rendering ────────────────────────────────────────────

fn imageExtension(mime_type: []const u8) []const u8 {
    if (std.mem.eql(u8, mime_type, "image/png")) return "png";
    if (std.mem.eql(u8, mime_type, "image/jpeg") or std.mem.eql(u8, mime_type, "image/jpg")) return "jpg";
    if (std.mem.eql(u8, mime_type, "image/webp")) return "webp";
    if (std.mem.eql(u8, mime_type, "image/gif")) return "gif";
    return "img";
}

fn writeImage(
    allocator: Allocator,
    workspace_dir: []const u8,
    mime_type: []const u8,
    data: []const u8,
    index: usize,
) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(data) catch return error.InvalidBase64;
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    decoder.decode(bytes, data) catch return error.InvalidBase64;
    if (bytes.len == 0) return error.InvalidBase64;

    const dir_path = try std_compat.fs.path.join(allocator, &.{ workspace_dir, image_dir_name });
    defer allocator.free(dir_path);
    fs_compat.makePath(dir_path) catch return error.WriteFailed;

    const filename = try std.fmt.allocPrint(allocator, "android-{x}-{d}.{s}", .{
        std_compat.crypto.random.int(u32),
        index,
        imageExtension(mime_type),
    });
    defer allocator.free(filename);
    const path = try std_compat.fs.path.join(allocator, &.{ dir_path, filename });
    errdefer allocator.free(path);
    std_compat.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes }) catch return error.WriteFailed;
    return path;
}

/// Maps a contract `ToolResult` to junclaw's ToolResult. Text segments are
/// concatenated; each image is saved under `<workspace>/android-device/` and
/// replaced by the `[IMAGE:<abs path>]` marker the channels understand.
pub fn renderToolResult(allocator: Allocator, workspace_dir: []const u8, result: std.json.Value) !root.ToolResult {
    if (result != .object) return error.Protocol;
    const ok = switch (result.object.get("ok") orelse return error.Protocol) {
        .bool => |value| value,
        else => return error.Protocol,
    };

    if (!ok) {
        var code: []const u8 = "failed";
        var message: []const u8 = "";
        if (result.object.get("error")) |error_value| {
            if (error_value == .object) {
                if (stringField(error_value.object, "code")) |value| code = value;
                if (stringField(error_value.object, "message")) |value| message = value;
            }
        }
        const text = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ code, message });
        return .{ .success = false, .output = "", .error_msg = text };
    }

    const content_value = result.object.get("content") orelse return error.Protocol;
    if (content_value != .array) return error.Protocol;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var image_index: usize = 0;
    for (content_value.array.items) |block| {
        if (block != .object) return error.Protocol;
        const kind = stringField(block.object, "type") orelse return error.Protocol;
        if (std.mem.eql(u8, kind, "text")) {
            try output.appendSlice(allocator, stringField(block.object, "text") orelse return error.Protocol);
        } else if (std.mem.eql(u8, kind, "image")) {
            const mime_type = stringField(block.object, "mimeType") orelse return error.Protocol;
            const data = stringField(block.object, "data") orelse return error.Protocol;
            const path = writeImage(allocator, workspace_dir, mime_type, data, image_index) catch {
                output.deinit(allocator);
                return root.ToolResult.fail("android device image: invalid base64 payload");
            };
            defer allocator.free(path);
            image_index += 1;
            try output.appendSlice(allocator, "[IMAGE:");
            try output.appendSlice(allocator, path);
            try output.appendSlice(allocator, "]");
        }
        // Contract content types are text and image; anything else is ignored.
    }

    return .{ .success = true, .output = try output.toOwnedSlice(allocator) };
}

// ── Invoke ──────────────────────────────────────────────────────────

fn uuidV4(buffer: *[36]u8) []const u8 {
    var raw: [16]u8 = undefined;
    std_compat.crypto.random.bytes(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    const hex = "0123456789abcdef";
    var index: usize = 0;
    var out: usize = 0;
    while (index < raw.len) : (index += 1) {
        if (index == 4 or index == 6 or index == 8 or index == 10) {
            buffer[out] = '-';
            out += 1;
        }
        buffer[out] = hex[raw[index] >> 4];
        buffer[out + 1] = hex[raw[index] & 0x0f];
        out += 2;
    }
    return buffer[0..36];
}

fn failureResult(allocator: Allocator, err: anyerror) !root.ToolResult {
    const message = try std.fmt.allocPrint(allocator, "android device bridge: {s}", .{@errorName(err)});
    return .{ .success = false, .output = "", .error_msg = message };
}

/// Sends `capability/invoke` for one host tool. `host_name` is the DSH name,
/// without the `android_` prefix junclaw exposes to the model.
pub fn invoke(
    allocator: Allocator,
    socket_path: []const u8,
    workspace_dir: []const u8,
    host_name_value: []const u8,
    timeout_ms: u64,
    args: root.JsonObjectMap,
) !root.ToolResult {
    var uuid_buffer: [36]u8 = undefined;
    const session_id = root.threadMemorySessionId() orelse uuidV4(&uuid_buffer);
    var call_id_buffer: [36]u8 = undefined;
    const call_id = uuidV4(&call_id_buffer);

    var params: std.json.ObjectMap = .empty;
    defer params.deinit(allocator);
    try params.put(allocator, "sessionId", .{ .string = session_id });
    try params.put(allocator, "callId", .{ .string = call_id });
    try params.put(allocator, "tool", .{ .string = host_name_value });
    try params.put(allocator, "args", .{ .object = args });
    try params.put(allocator, "timeoutMs", .{ .integer = @intCast(@min(timeout_ms, std.math.maxInt(i64))) });

    const line = try buildRequestLine(allocator, "capability/invoke", .{ .object = params });
    defer allocator.free(line);

    const budget = timeout_ms +| invoke_timeout_margin_ms;
    var response = request(allocator, socket_path, line, budget) catch |err| return failureResult(allocator, err);
    defer response.deinit();

    if (rpcErrorInfo(response.value)) |info| {
        const text = try std.fmt.allocPrint(allocator, "{d}: {s}", .{ info.code, info.message });
        return .{ .success = false, .output = "", .error_msg = text };
    }
    const result = responseResult(response.value) catch |err| return failureResult(allocator, err);
    return renderToolResult(allocator, workspace_dir, result) catch |err| failureResult(allocator, err);
}

// ── Tool registration ───────────────────────────────────────────────

pub const AndroidDeviceTool = struct {
    socket_path: []const u8,
    /// Borrowed from allTools; outlives the tool.
    workspace_dir: []const u8,
    tool_name: []const u8,
    desc: []const u8,
    params_json: []const u8,
    timeout_ms: u64,

    const vtable = root.Tool.VTable{
        .execute = &executeImpl,
        .name = &nameImpl,
        .description = &descImpl,
        .parameters_json = &paramsImpl,
        .deinit = &deinitImpl,
    };

    pub fn tool(self: *AndroidDeviceTool) root.Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(ptr: *anyopaque, allocator: Allocator, args: root.JsonObjectMap) anyerror!root.ToolResult {
        const self: *AndroidDeviceTool = @ptrCast(@alignCast(ptr));
        const host_name = hostName(self.tool_name) orelse
            return root.ToolResult.fail("android device tool has an invalid name");
        return invoke(allocator, self.socket_path, self.workspace_dir, host_name, self.timeout_ms, args);
    }

    fn nameImpl(ptr: *anyopaque) []const u8 {
        const self: *AndroidDeviceTool = @ptrCast(@alignCast(ptr));
        return self.tool_name;
    }

    fn descImpl(ptr: *anyopaque) []const u8 {
        const self: *AndroidDeviceTool = @ptrCast(@alignCast(ptr));
        return self.desc;
    }

    fn paramsImpl(ptr: *anyopaque) []const u8 {
        const self: *AndroidDeviceTool = @ptrCast(@alignCast(ptr));
        return self.params_json;
    }

    fn deinitImpl(ptr: *anyopaque, allocator: Allocator) void {
        const self: *AndroidDeviceTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn deinit(self: *AndroidDeviceTool, allocator: Allocator) void {
        allocator.free(self.socket_path);
        allocator.free(self.tool_name);
        allocator.free(self.desc);
        allocator.free(self.params_json);
        allocator.destroy(self);
    }
};

pub fn createTool(
    allocator: Allocator,
    socket_path: []const u8,
    workspace_dir: []const u8,
    descriptor: ToolDescriptor,
) !*AndroidDeviceTool {
    const self = try allocator.create(AndroidDeviceTool);
    errdefer allocator.destroy(self);

    const socket_copy = try allocator.dupe(u8, socket_path);
    errdefer allocator.free(socket_copy);
    const name_copy = try prefixedName(allocator, descriptor.name);
    errdefer allocator.free(name_copy);
    const desc_copy = try allocator.dupe(u8, descriptor.description);
    errdefer allocator.free(desc_copy);
    const params_copy = try allocator.dupe(u8, descriptor.input_schema_json);
    errdefer allocator.free(params_copy);

    self.* = .{
        .socket_path = socket_copy,
        .workspace_dir = workspace_dir,
        .tool_name = name_copy,
        .desc = desc_copy,
        .params_json = params_copy,
        .timeout_ms = descriptor.timeout_ms,
    };
    return self;
}

/// Android builds with `JUNCLAW_DEVICE_SOCKET` set list the host's tools and
/// append them; a missing/unresponsive host only logs a warning. Every other
/// platform is a comptime no-op, so its tool list is byte-for-byte unchanged.
pub fn registerTools(allocator: Allocator, list: *std.ArrayList(root.Tool), workspace_dir: []const u8) void {
    if (comptime builtin.abi != .android) return;

    const socket_path = std_compat.process.getEnvVarOwned(allocator, socket_env_var) catch return;
    defer allocator.free(socket_path);
    if (socket_path.len == 0) return;

    var descriptors = listFromSocket(allocator, socket_path, list_timeout_ms) catch |err| {
        log.warn("device capability bridge unavailable, no device tools registered: {s}", .{@errorName(err)});
        return;
    };
    defer descriptors.deinit(allocator);

    for (descriptors.items) |descriptor| {
        const device_tool = createTool(allocator, socket_path, workspace_dir, descriptor) catch |err| {
            log.warn("device tool '{s}' skipped: {s}", .{ descriptor.name, @errorName(err) });
            continue;
        };
        list.append(allocator, device_tool.tool()) catch |err| {
            device_tool.deinit(allocator);
            log.warn("device tool '{s}' not registered: {s}", .{ descriptor.name, @errorName(err) });
            return;
        };
    }
}
// ── Test helpers ────────────────────────────────────────────────────

fn skipWithoutUnixSockets() !void {
    // Windows CI: this repo does not run AF_UNIX socket tests there (the
    // platform support varies by Windows build), so skip rather than flake.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    if (comptime !std.Io.net.has_unix_sockets) return error.SkipZigTest;
}

/// Reads one NDJSON line from a test socket. The 5 s cap is only a hang
/// guard for broken tests, never an assertion.
fn testReadLine(allocator: std.mem.Allocator, conn: std_compat.net.Stream) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    while (std.mem.indexOfScalar(u8, buf.items, '\n') == null) {
        var chunk: [512]u8 = undefined;
        const n = try std_compat.net.readWithTimeout(conn, &chunk, 5_000);
        if (n == 0) return error.ServerClosed;
        try buf.appendSlice(allocator, chunk[0..n]);
        if (buf.items.len > 1 << 20) return error.LineTooLong;
    }
    const end = std.mem.indexOfScalar(u8, buf.items, '\n').?;
    return allocator.dupe(u8, buf.items[0..end]);
}

const TestServer = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    handler: *const fn (server: *TestServer, request: []const u8) anyerror!?[]u8,
    server: std.Io.net.Server = undefined,
    thread: ?std.Thread = null,
    captured_request: ?[]u8 = null,
    err: ?anyerror = null,
    eof_seen: bool = false,

    fn start(self: *TestServer) !void {
        const io = std_compat.io();
        const address = try std.Io.net.UnixAddress.init(self.path);
        self.server = try address.listen(io, .{});
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *TestServer) void {
        self.serve() catch |err| {
            self.err = err;
        };
    }

    fn serve(self: *TestServer) !void {
        const io = std_compat.io();
        defer self.server.deinit(io);
        const inner = try self.server.accept(io);
        const conn = std_compat.net.Stream{ .handle = inner.socket.handle };
        defer conn.close();

        const line = try testReadLine(self.allocator, conn);
        defer self.allocator.free(line);
        self.captured_request = try self.allocator.dupe(u8, line);

        if (try self.handler(self, line)) |response| {
            defer self.allocator.free(response);
            try conn.writeAll(response);
            try conn.writeAll("\n");
        } else {
            // No response: the client must time out and close the connection,
            // which the host interprets as capability/cancel.
            var buf: [64]u8 = undefined;
            while (true) {
                const n = std_compat.net.readWithTimeout(conn, &buf, 5_000) catch |err| switch (err) {
                    error.Timeout => return error.ClientDidNotClose,
                    else => return err,
                };
                if (n == 0) {
                    self.eof_seen = true;
                    return;
                }
            }
        }
    }

    fn join(self: *TestServer) !void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.err) |err| return err;
    }

    fn deinit(self: *TestServer) void {
        if (self.captured_request) |captured| self.allocator.free(captured);
    }
};

fn serverSocketPath(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    const root_path = try std_compat.fs.Dir.wrap(dir).realpathAlloc(allocator, ".");
    defer allocator.free(root_path);
    return std_compat.fs.path.join(allocator, &.{ root_path, "device.sock" });
}

fn listHandler(_: *TestServer, line: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqualStrings("2.0", object.get("jsonrpc").?.string);
    try testing.expectEqualStrings("capability/list", object.get("method").?.string);
    try testing.expectEqual(@as(usize, 0), object.get("params").?.object.count());
    return try testing.allocator.dupe(u8,
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"file_read","group":"files","description":"Read a file","inputSchema":{"type":"object"},"risk":"read","needsUnlock":false,"timeoutMs":5000},{"name":"bad name","group":"files","description":"bad","inputSchema":{"type":"object"},"risk":"read","needsUnlock":false,"timeoutMs":1}]}}
    );
}

fn invokeHandler(_: *TestServer, line: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqualStrings("capability/invoke", object.get("method").?.string);
    const params = object.get("params").?.object;
    try testing.expectEqualStrings("screen_tap", params.get("tool").?.string);
    try testing.expect(params.get("sessionId").?.string.len > 0);
    try testing.expect(params.get("callId").?.string.len > 0);
    try testing.expectEqual(@as(i64, 500), params.get("timeoutMs").?.integer);
    try testing.expectEqualStrings("/sdcard/a.txt", params.get("args").?.object.get("path").?.string);
    return try testing.allocator.dupe(u8,
        \\{"jsonrpc":"2.0","id":1,"result":{"ok":true,"content":[{"type":"text","text":"tapped"}]}}
    );
}

fn rpcErrorHandler(_: *TestServer, _: []const u8) !?[]u8 {
    return try testing.allocator.dupe(u8,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"bad args"}}
    );
}

fn silentHandler(_: *TestServer, _: []const u8) !?[]u8 {
    return null;
}

// ── NDJSON framing ──────────────────────────────────────────────────

test "extractFrame returns exactly one NDJSON line" {
    try testing.expectEqualStrings("{\"a\":1}", try extractFrame("{\"a\":1}\nrest", 1024));
    try testing.expectEqualStrings("abc", try extractFrame("abc\r\n", 1024));
}

test "extractFrame waits for a newline" {
    try testing.expectError(error.NeedMore, extractFrame("{\"a\":", 1024));
    try testing.expectError(error.NeedMore, extractFrame("", 1024));
}

test "extractFrame rejects lines above the frame limit" {
    try testing.expectError(error.LineTooLong, extractFrame("0123456789", 8));
    try testing.expectError(error.LineTooLong, extractFrame("0123456789\n", 8));
    try testing.expectEqualStrings("01234567", try extractFrame("01234567\n", 8));
}

// ── Descriptor parsing ──────────────────────────────────────────────

test "isValidToolName enforces the contract name pattern" {
    try testing.expect(isValidToolName("file_read"));
    try testing.expect(isValidToolName("screen_tap"));
    try testing.expect(isValidToolName("A1_b-c"));
    try testing.expect(isValidToolName("a" ** 64));
    try testing.expect(!isValidToolName(""));
    try testing.expect(!isValidToolName("bad name"));
    try testing.expect(!isValidToolName("bad/name"));
    try testing.expect(!isValidToolName("tool.name"));
    try testing.expect(!isValidToolName("Ümlaut"));
    try testing.expect(!isValidToolName("a" ** 65));
}

test "parseListResult keeps valid descriptors and filters invalid ones" {
    const allocator = testing.allocator;
    const json =
        \\{"tools":[
        \\{"name":"file_read","group":"files","description":"Read a file","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}},"risk":"read","needsUnlock":false,"timeoutMs":5000},
        \\{"name":"screen_tap","group":"screen","description":"Tap the screen","inputSchema":{"type":"object"},"risk":"dangerous","needsUnlock":true,"timeoutMs":9000},
        \\{"name":"bad name","group":"files","description":"bad","inputSchema":{},"risk":"read","needsUnlock":false,"timeoutMs":1},
        \\{"name":"bad_risk","group":"files","description":"bad","inputSchema":{},"risk":"extreme","needsUnlock":false,"timeoutMs":1},
        \\{"name":"bad_schema","group":"files","description":"bad","inputSchema":[],"risk":"read","needsUnlock":false,"timeoutMs":1},
        \\{"name":"missing_description","group":"files","inputSchema":{},"risk":"read","needsUnlock":false,"timeoutMs":1}
        \\]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    var list = try parseListResult(allocator, parsed.value);
    defer list.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), list.items.len);
    const file_read = list.items[0];
    try testing.expectEqualStrings("file_read", file_read.name);
    try testing.expectEqualStrings("files", file_read.group);
    try testing.expectEqualStrings("Read a file", file_read.description);
    try testing.expectEqual(Risk.read, file_read.risk);
    try testing.expect(!file_read.needs_unlock);
    try testing.expectEqual(@as(u64, 5000), file_read.timeout_ms);
    var schema = try std.json.parseFromSlice(std.json.Value, allocator, file_read.input_schema_json, .{});
    defer schema.deinit();
    try testing.expect(schema.value == .object);
    try testing.expectEqualStrings("object", schema.value.object.get("type").?.string);
    try testing.expect(schema.value.object.get("properties").?.object.get("path") != null);

    const screen_tap = list.items[1];
    try testing.expectEqualStrings("screen_tap", screen_tap.name);
    try testing.expectEqual(Risk.dangerous, screen_tap.risk);
    try testing.expect(screen_tap.needs_unlock);
    try testing.expectEqual(@as(u64, 9000), screen_tap.timeout_ms);
}

test "parseListResult accepts every contract risk level" {
    const allocator = testing.allocator;
    const json =
        \\{"tools":[
        \\{"name":"t_read","group":"g","description":"d","inputSchema":{"type":"object"},"risk":"read","needsUnlock":false,"timeoutMs":1},
        \\{"name":"t_write","group":"g","description":"d","inputSchema":{"type":"object"},"risk":"write","needsUnlock":false,"timeoutMs":1},
        \\{"name":"t_sensitive","group":"g","description":"d","inputSchema":{"type":"object"},"risk":"sensitive","needsUnlock":false,"timeoutMs":1},
        \\{"name":"t_dangerous","group":"g","description":"d","inputSchema":{"type":"object"},"risk":"dangerous","needsUnlock":false,"timeoutMs":1}
        \\]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    var list = try parseListResult(allocator, parsed.value);
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 4), list.items.len);
    try testing.expectEqual(Risk.read, list.items[0].risk);
    try testing.expectEqual(Risk.write, list.items[1].risk);
    try testing.expectEqual(Risk.sensitive, list.items[2].risk);
    try testing.expectEqual(Risk.dangerous, list.items[3].risk);
}

// ── Naming ──────────────────────────────────────────────────────────

test "prefixedName and hostName round-trip contract names" {
    const allocator = testing.allocator;
    const prefixed = try prefixedName(allocator, "screen_tap");
    defer allocator.free(prefixed);
    try testing.expectEqualStrings("android_screen_tap", prefixed);
    try testing.expectEqualStrings("screen_tap", hostName(prefixed).?);
    try testing.expect(hostName("file_read") == null);
    try testing.expect(hostName("android_") == null);
    try testing.expect(hostName("androidx_x") == null);
}

// ── Result mapping ──────────────────────────────────────────────────

test "renderToolResult concatenates text segments" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"ok":true,"content":[{"type":"text","text":"hello "},{"type":"text","text":"world"}]}
    , .{});
    defer parsed.deinit();
    const result = try renderToolResult(allocator, "/tmp", parsed.value);
    defer if (result.output.len > 0) allocator.free(result.output);
    try testing.expect(result.success);
    try testing.expectEqualStrings("hello world", result.output);
}

test "renderToolResult writes image segments into android-device" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    const raw = "fake-png-bytes";
    var encoded: [64]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&encoded, raw);
    const json = try std.fmt.allocPrint(allocator,
        \\{{"ok":true,"content":[{{"type":"text","text":"before "}},{{"type":"image","mimeType":"image/png","data":"{s}"}},{{"type":"text","text":"after"}}]}}
    , .{b64});
    defer allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const result = try renderToolResult(allocator, workspace, parsed.value);
    defer allocator.free(result.output);
    try testing.expect(result.success);

    const marker = std.mem.indexOf(u8, result.output, "[IMAGE:").?;
    const close = std.mem.indexOfScalarPos(u8, result.output, marker, ']').?;
    try testing.expectEqualStrings("before ", result.output[0..marker]);
    try testing.expectEqualStrings("after", result.output[close + 1 ..]);
    const path = result.output[marker + "[IMAGE:".len .. close];
    try testing.expect(std.fs.path.isAbsolute(path));
    try testing.expect(std.mem.endsWith(u8, std.fs.path.dirname(path).?, image_dir_name));
    try testing.expect(std.mem.endsWith(u8, path, ".png"));

    var file = try std_compat.fs.openFileAbsolute(path, .{});
    defer file.close();
    const stored = try file.readToEndAlloc(allocator, 64);
    defer allocator.free(stored);
    try testing.expectEqualStrings(raw, stored);
}

test "renderToolResult maps ok=false to a code-prefixed failure" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"ok":false,"content":[],"error":{"code":"permission_missing","message":"denied"}}
    , .{});
    defer parsed.deinit();
    const result = try renderToolResult(allocator, "/tmp", parsed.value);
    defer if (result.error_msg) |err| allocator.free(err);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("", result.output);
    try testing.expectEqualStrings("permission_missing: denied", result.error_msg.?);
}

test "renderToolResult rejects an invalid image payload" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"ok":true,"content":[{"type":"image","mimeType":"image/png","data":"%%%not-base64%%%"}]}
    , .{});
    defer parsed.deinit();
    const result = try renderToolResult(allocator, "/tmp", parsed.value);
    try testing.expect(!result.success);
}

// ── Request encoding ────────────────────────────────────────────────

test "buildRequestLine emits one newline-free JSON-RPC request" {
    const allocator = testing.allocator;
    var params: std.json.ObjectMap = .empty;
    defer params.deinit(allocator);
    const line = try buildRequestLine(allocator, "capability/list", .{ .object = params });
    defer allocator.free(line);
    try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);
    try testing.expectEqualStrings("capability/list", parsed.value.object.get("method").?.string);
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("params").?.object.count());
}

// ── Socket round-trips (fake host) ──────────────────────────────────

test "capability/list over a fake unix socket" {
    try skipWithoutUnixSockets();
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try serverSocketPath(allocator, tmp.dir);
    defer allocator.free(path);

    var server = TestServer{ .allocator = allocator, .path = path, .handler = listHandler };
    defer server.deinit();
    try server.start();

    var list = try listFromSocket(allocator, path, 500);
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("file_read", list.items[0].name);

    try server.join();
}

test "invoke sends host names and renders the ToolResult" {
    try skipWithoutUnixSockets();
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try serverSocketPath(allocator, tmp.dir);
    defer allocator.free(path);

    var server = TestServer{ .allocator = allocator, .path = path, .handler = invokeHandler };
    defer server.deinit();
    try server.start();

    var args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"path\":\"/sdcard/a.txt\"}", .{});
    defer args.deinit();
    const result = try invoke(allocator, path, ".", "screen_tap", 500, args.value.object);
    defer allocator.free(result.output);
    try testing.expect(result.success);
    try testing.expectEqualStrings("tapped", result.output);

    try server.join();
}

test "invoke maps JSON-RPC errors to code-prefixed failures" {
    try skipWithoutUnixSockets();
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try serverSocketPath(allocator, tmp.dir);
    defer allocator.free(path);

    var server = TestServer{ .allocator = allocator, .path = path, .handler = rpcErrorHandler };
    defer server.deinit();
    try server.start();

    var args: std.json.ObjectMap = .empty;
    defer args.deinit(allocator);
    const result = try invoke(allocator, path, ".", "screen_tap", 500, args);
    defer if (result.error_msg) |err| allocator.free(err);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("-32602: bad args", result.error_msg.?);

    try server.join();
}

test "request times out and closes when the host never responds" {
    try skipWithoutUnixSockets();
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try serverSocketPath(allocator, tmp.dir);
    defer allocator.free(path);

    var server = TestServer{ .allocator = allocator, .path = path, .handler = silentHandler };
    defer server.deinit();
    try server.start();

    var params: std.json.ObjectMap = .empty;
    defer params.deinit(allocator);
    const line = try buildRequestLine(allocator, "capability/list", .{ .object = params });
    defer allocator.free(line);
    try testing.expectError(error.Timeout, request(allocator, path, line, 50));

    try server.join();
    try testing.expect(server.eof_seen);
}

test "createTool exposes android_ names and invokes with the host name" {
    try skipWithoutUnixSockets();
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try serverSocketPath(allocator, tmp.dir);
    defer allocator.free(path);

    var server = TestServer{ .allocator = allocator, .path = path, .handler = invokeHandler };
    defer server.deinit();
    try server.start();

    const descriptor = ToolDescriptor{
        .name = "screen_tap",
        .group = "screen",
        .description = "Tap the screen",
        .input_schema_json = "{\"type\":\"object\"}",
        .risk = .dangerous,
        .needs_unlock = false,
        .timeout_ms = 500,
    };
    const device = try createTool(allocator, path, ".", descriptor);
    const tool = device.tool();
    defer tool.deinit(allocator);

    try testing.expectEqualStrings("android_screen_tap", tool.name());
    try testing.expectEqualStrings("Tap the screen", tool.description());
    try testing.expectEqualStrings("{\"type\":\"object\"}", tool.parametersJson());

    var args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"path\":\"/sdcard/a.txt\"}", .{});
    defer args.deinit();
    const result = try tool.execute(allocator, args.value.object);
    defer allocator.free(result.output);
    try testing.expect(result.success);
    try testing.expectEqualStrings("tapped", result.output);

    try server.join();
}

// ── Registration gating ─────────────────────────────────────────────

test "registerTools is a no-op outside Android builds" {
    if (comptime builtin.abi == .android) return error.SkipZigTest;
    var list: std.ArrayList(root.Tool) = .empty;
    defer list.deinit(testing.allocator);
    registerTools(testing.allocator, &list, "/tmp");
    try testing.expectEqual(@as(usize, 0), list.items.len);
}
