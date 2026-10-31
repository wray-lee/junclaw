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

// ── Contract constants ──────────────────────────────────────────────

pub const socket_env_var = "JUNCLAW_DEVICE_SOCKET";
pub const name_prefix = "android_";
pub const max_frame_bytes: usize = 64 * 1024 * 1024;
pub const list_timeout_ms: u64 = 10_000;
pub const invoke_timeout_margin_ms: u64 = 10_000;
pub const image_dir_name = "android-device";

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
    request: ?[]u8 = null,
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
        self.request = try self.allocator.dupe(u8, line);

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
        if (self.request) |request| self.allocator.free(request);
    }
};

fn serverSocketPath(allocator: std.mem.Allocator, dir: std.fs.Dir) ![]u8 {
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
    return testing.allocator.dupe(u8,
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[
        \\{"name":"file_read","group":"files","description":"Read a file","inputSchema":{"type":"object"},"risk":"read","needsUnlock":false,"timeoutMs":5000},
        \\{"name":"bad name","group":"files","description":"bad","inputSchema":{"type":"object"},"risk":"read","needsUnlock":false,"timeoutMs":1}
        \\]}}
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
    return testing.allocator.dupe(u8,
        \\{"jsonrpc":"2.0","id":1,"result":{"ok":true,"content":[{"type":"text","text":"tapped"}]}}
    );
}

fn rpcErrorHandler(_: *TestServer, _: []const u8) !?[]u8 {
    return testing.allocator.dupe(u8,
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

// ── Registration gating ─────────────────────────────────────────────

test "registerTools is a no-op outside Android builds" {
    if (comptime builtin.abi == .android) return error.SkipZigTest;
    var list: std.ArrayList(root.Tool) = .empty;
    defer list.deinit(testing.allocator);
    registerTools(testing.allocator, &list, "/tmp");
    try testing.expectEqual(@as(usize, 0), list.items.len);
}
