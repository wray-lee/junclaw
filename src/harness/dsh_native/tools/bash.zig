//! Bash tool: foreground command execution, timeout, and tail truncation with
//! spill files (design §1.2 B25b; dsh `packages/shell/tool-bash/src/index.ts:64-115,369-400`,
//! `packages/shell/bash-local/src/index.ts:102`).
//!
//! Model-facing text mirrors dsh `render.ts` byte for byte: stdout, a marked
//! stderr section, then timeout/signal/exit markers. A non-zero exit is a
//! successful result, not an error; only argument validation and infrastructure
//! failures (spawn, unsupported platform) become structured failures.
//!
//! shortcut: foreground only — run_in_background is rejected and there is no
//! job_output/job_kill; upgrade when the P2 job registry lands.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const platform = @import("../../../platform.zig");
const shell_mod = @import("../../../tools/shell.zig");
const registry = @import("registry.zig");
const security_mod = @import("security.zig");
const types = @import("../types.zig");
const generated = @import("../generated/tool_render.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Writer = std.Io.Writer;

/// dsh bash-local defaults (`packages/shell/bash-local/src/index.ts:102`).
pub const default_timeout_ms: u64 = 120_000;
pub const max_timeout_ms: u64 = 600_000;
pub const max_output_bytes: usize = 64_000;
pub const max_spill_bytes: u64 = 64 * 1024 * 1024;

/// Per-deployment handler state. `cwd` is the session working directory;
/// `spill_dir` selects where truncated-output recovery files go (dsh spills
/// under the OS tmpdir; set this when /tmp is not writable).
pub const Context = struct {
    cwd: ?[]const u8 = null,
    spill_dir: ?[]const u8 = null,
    /// `autonomy.allowed_paths`: extra roots a model-supplied workdir may use.
    allowed_paths: []const []const u8 = &.{},

    pub fn handler(self: *Context) registry.Handler {
        return .{ .context = self, .call = call };
    }
};

fn call(context: ?*anyopaque, allocator: Allocator, args: Value) anyerror!registry.ToolResult {
    const self: *const Context = @ptrCast(@alignCast(context orelse return error.MissingContext));
    return invoke(self, allocator, args);
}

const Args = struct {
    command: []const u8,
    description: []const u8,
    workdir: ?[]const u8 = null,
    timeout_ms: u64 = default_timeout_ms,
    run_in_background: bool = false,
    sandbox_permissions: ?[]const u8 = null,
    justification: ?[]const u8 = null,
};

const ParseIssue = struct { code: []const u8, message: []const u8 };
const ParseResult = union(enum) { ok: Args, invalid: ParseIssue };

fn invalid(message: []const u8) ParseResult {
    return .{ .invalid = .{ .code = "INVALID_ARGUMENTS", .message = message } };
}

fn parseArgs(value: Value) ParseResult {
    const obj = switch (value) {
        .object => |obj| obj,
        else => return invalid("tool arguments must be a JSON object"),
    };

    // dsh validates command first, then description and timeout (`validateBashArgs`).
    const command = switch (obj.get("command") orelse return invalid("invalid command: expected a non-empty string")) {
        .string => |text| text,
        else => return invalid("invalid command: expected a non-empty string"),
    };
    if (std.mem.trim(u8, command, " \t\r\n").len == 0) return invalid("invalid command: expected a non-empty string");

    const description = switch (obj.get("description") orelse return invalid("invalid description: expected a non-empty string")) {
        .string => |text| text,
        else => return invalid("invalid description: expected a non-empty string"),
    };
    if (std.mem.trim(u8, description, " \t\r\n").len == 0) return invalid("invalid description: expected a non-empty string");

    var args: Args = .{ .command = command, .description = description };

    if (obj.get("timeoutMs")) |raw| {
        const requested: f64 = switch (raw) {
            .integer => |number| @floatFromInt(number),
            .float => |number| number,
            .number_string => |text| std.fmt.parseFloat(f64, text) catch return invalid("invalid timeoutMs: expected a positive number"),
            else => return invalid("invalid timeoutMs: expected a positive number"),
        };
        if (!std.math.isFinite(requested) or requested <= 0) return invalid("invalid timeoutMs: expected a positive number");
        const capped = @min(requested, @as(f64, @floatFromInt(max_timeout_ms)));
        args.timeout_ms = @intFromFloat(@max(1.0, @floor(capped)));
    }

    if (obj.get("workdir")) |raw| switch (raw) {
        .string => |text| args.workdir = text,
        else => return invalid("invalid workdir: expected a string"),
    };

    if (obj.get("run_in_background")) |raw| switch (raw) {
        .bool => |flag| args.run_in_background = flag,
        else => return invalid("invalid run_in_background: expected a boolean"),
    };

    if (obj.get("sandbox_permissions")) |raw| switch (raw) {
        .string => |text| args.sandbox_permissions = text,
        else => return invalid("invalid sandbox_permissions: expected a string"),
    };
    if (obj.get("justification")) |raw| switch (raw) {
        .string => |text| args.justification = text,
        else => return invalid("invalid justification: expected a string"),
    };
    if (args.sandbox_permissions) |mode| {
        if (!std.mem.eql(u8, mode, "workspace-write") and !std.mem.eql(u8, mode, "danger-full-access")) {
            return invalid("invalid sandbox_permissions: expected workspace-write or danger-full-access");
        }
        const reason = args.justification orelse return invalid("invalid escalation: sandbox_permissions requires a justification");
        if (std.mem.trim(u8, reason, " \t\r\n").len == 0) return invalid("invalid justification: expected a non-empty sentence");
    } else if (args.justification) |reason| {
        // dsh treats an omitted-or-blank justification as absent when no mode was requested.
        if (std.mem.trim(u8, reason, " \t\r\n").len != 0) {
            return invalid("invalid escalation: justification is only valid together with sandbox_permissions");
        }
        args.justification = null;
    }

    return .{ .ok = args };
}

pub fn invoke(context: *const Context, allocator: Allocator, value: Value) anyerror!registry.ToolResult {
    const args = switch (parseArgs(value)) {
        .ok => |args| args,
        .invalid => |issue| return failure(allocator, issue.code, issue.message),
    };

    if (args.run_in_background) {
        return failure(allocator, "UNSUPPORTED", "run_in_background is unavailable: this build runs foreground bash only (job_output/job_kill land with the P2 job registry)");
    }

    return if (comptime builtin.os.tag == .windows)
        failure(allocator, "UNSUPPORTED_PLATFORM", "bash is unavailable on Windows: the P1a executor requires a POSIX shell")
    else
        runPosix(context, allocator, args);
}

const Term = union(enum) {
    exited: u8,
    signal: std.posix.SIG,
};

const Stream = struct {
    text: []const u8 = "",
    truncated: bool = false,
    spill_path: ?[]const u8 = null,
};

const Outcome = struct {
    term: Term,
    timed_out: bool,
    stdout: Stream,
    stderr: Stream,
};

fn failure(allocator: Allocator, code: []const u8, message: []const u8) !registry.ToolResult {
    const text = try std.fmt.allocPrint(allocator, "Error: {s}", .{message});
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = text };
    return .{ .failure = .{
        .error_info = .{ .name = "Error", .code = code, .reason = message },
        .content = content,
    } };
}

fn runPosix(context: *const Context, allocator: Allocator, args: Args) !registry.ToolResult {
    const io = compat.io();
    const workdir = try resolveWorkdir(allocator, context, args.workdir);
    if (args.workdir != null) {
        const scope: security_mod.Scope = .{
            .cwd = context.cwd orelse "",
            .allowed_paths = context.allowed_paths,
        };
        if (!try security_mod.pathAllowed(allocator, scope, workdir orelse "")) {
            return failure(allocator, "WORKDIR_NOT_ALLOWED", "workdir is outside the session workspace");
        }
    }

    // Clear the environment like the native shell tool (CWE-200): provider
    // keys and channel tokens must not reach the child. Only the functional
    // variables listed in `shell.SAFE_ENV_VARS` are restored.
    var env = compat.process.EnvMap.init(allocator);
    defer env.deinit();
    for (shell_mod.SAFE_ENV_VARS) |key| {
        if (platform.getEnvOrNull(allocator, key)) |value| {
            defer allocator.free(value);
            try env.put(key, value);
        }
    }

    const stdout_temp = try createTempFile(allocator, context, "stdout");
    defer stdout_temp.file.close();
    errdefer compat.fs.deleteFileAbsolute(stdout_temp.path) catch {};
    const stderr_temp = try createTempFile(allocator, context, "stderr");
    defer stderr_temp.file.close();
    errdefer compat.fs.deleteFileAbsolute(stderr_temp.path) catch {};

    const child = std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", args.command },
        .cwd = if (workdir) |dir| .{ .path = dir } else .inherit,
        .environ_map = &env,
        .stdout = .{ .file = stdout_temp.file.toInner() },
        .stderr = .{ .file = stderr_temp.file.toInner() },
    }) catch |err| {
        compat.fs.deleteFileAbsolute(stdout_temp.path) catch {};
        compat.fs.deleteFileAbsolute(stderr_temp.path) catch {};
        const message = try std.fmt.allocPrint(allocator, "failed to start command: {s}", .{@errorName(err)});
        return failure(allocator, "SPAWN_FAILED", message);
    };
    const pid = child.id orelse return failure(allocator, "SPAWN_FAILED", "failed to start command: no process id");

    const wait = try waitWithTimeout(io, pid, args.timeout_ms);
    const raw_status: u32 = @bitCast(wait.status);
    const term: Term = if (std.posix.W.IFEXITED(raw_status))
        .{ .exited = @intCast(std.posix.W.EXITSTATUS(raw_status)) }
    else if (std.posix.W.IFSIGNALED(raw_status))
        .{ .signal = std.posix.W.TERMSIG(raw_status) }
    else
        .{ .exited = 0 };

    const outcome: Outcome = .{
        .term = term,
        .timed_out = wait.timed_out,
        .stdout = try collectStream(allocator, stdout_temp.path),
        .stderr = try collectStream(allocator, stderr_temp.path),
    };

    const text = try render(allocator, args, outcome);
    const meta = try buildMeta(allocator, args, workdir, outcome);
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = text };
    return .{ .success = .{ .content = content, .meta = meta } };
}

fn resolveWorkdir(allocator: Allocator, context: *const Context, requested: ?[]const u8) !?[]const u8 {
    const model_workdir = requested orelse return context.cwd;
    if (std.fs.path.isAbsolute(model_workdir)) return model_workdir;
    const base = context.cwd orelse return model_workdir;
    return try std.fs.path.join(allocator, &.{ base, model_workdir });
}

const TempFile = struct { path: []const u8, file: compat.fs.File };

fn createTempFile(allocator: Allocator, context: *const Context, label: []const u8) !TempFile {
    var random: [6]u8 = undefined;
    compat.crypto.random.bytes(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "dsh-bash-{s}-{s}.log", .{ &hex, label });
    // shortcut: POSIX-only fallback (the executor already refuses Windows);
    // dsh spills under os.tmpdir() (subprocess-local/src/output.ts:32-36).
    // Upgrade to a TMPDIR lookup when a sandboxed deployment needs it.
    const dir = context.spill_dir orelse "/tmp";
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    const file = compat.fs.createFileAbsolute(path, .{
        .truncate = true,
        .exclusive = true,
        .permissions = compat.fs.permissionsFromMode(0o600),
    }) catch |err| {
        allocator.free(path);
        return err;
    };
    return .{ .path = path, .file = file };
}

const WaitOutcome = struct {
    status: if (builtin.link_libc) c_int else u32,
    timed_out: bool,
};

const poll_interval_ms = 5;

fn waitWithTimeout(io: std.Io, pid: std.posix.pid_t, timeout_ms: u64) !WaitOutcome {
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    const timeout_ns: i96 = @as(i96, @intCast(timeout_ms)) * std.time.ns_per_ms;
    const nohang: if (builtin.link_libc) c_int else u32 = std.posix.W.NOHANG;
    var status: if (builtin.link_libc) c_int else u32 = 0;

    while (true) {
        const rc = std.posix.system.waitpid(pid, &status, nohang);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) {
                    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
                    if (elapsed.raw.nanoseconds >= timeout_ns) {
                        killAndReap(pid, &status);
                        return .{ .status = status, .timed_out = true };
                    }
                    try std.Io.sleep(io, .fromMilliseconds(poll_interval_ms), .awake);
                    continue;
                }
                return .{ .status = status, .timed_out = false };
            },
            .INTR => continue,
            else => {
                killAndReap(pid, &status);
                return error.WaitFailed;
            },
        }
    }
}

fn killAndReap(pid: std.posix.pid_t, status: *if (builtin.link_libc) c_int else u32) void {
    // shortcut: kill only the direct child; process-group SIGTERM->SIGKILL with a
    // grace period arrives with the P2 job registry.
    std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    while (true) {
        const rc = std.posix.system.waitpid(pid, status, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return,
        }
    }
}

fn collectStream(allocator: Allocator, path: []const u8) !Stream {
    const file = try compat.fs.openFileAbsolute(path, .{});
    defer file.close();
    const size = (try file.stat()).size;
    if (size <= @as(u64, max_output_bytes)) {
        const text = try allocator.alloc(u8, @intCast(size));
        const read = try file.readAll(text);
        compat.fs.deleteFileAbsolute(path) catch {};
        return .{ .text = text[0..read] };
    }

    const tail_len: usize = max_output_bytes;
    try file.seekTo(size - tail_len);
    const tail = try allocator.alloc(u8, tail_len);
    const read = try file.readAll(tail);
    if (size > max_spill_bytes) {
        // The spill holds the whole stream; past the cap it is discarded and the
        // in-memory tail remains the result (dsh degrades the same way).
        compat.fs.deleteFileAbsolute(path) catch {};
        return .{ .text = tail[0..read], .truncated = true };
    }
    return .{ .text = tail[0..read], .truncated = true, .spill_path = path };
}

fn render(allocator: Allocator, args: Args, outcome: Outcome) ![]const u8 {
    const stdout_text = try streamText(allocator, outcome.stdout);
    const stderr_text = try streamText(allocator, outcome.stderr);

    var body = Writer.Allocating.init(allocator);
    errdefer body.deinit();
    try body.writer.writeAll(stdout_text);
    if (stderr_text.len > 0) {
        const current = body.writer.buffer[0..body.writer.end];
        if (current.len > 0 and current[current.len - 1] != '\n') try body.writer.writeByte('\n');
        try body.writer.print(generated.bash.stderr_section, .{stderr_text});
    }
    if (body.writer.end == 0) try body.writer.writeAll(generated.bash.no_output);

    var has_markers = false;
    if (outcome.timed_out) {
        try markerPrefix(&body, &has_markers);
        try body.writer.print(generated.bash.timed_out, .{args.timeout_ms});
    }
    switch (outcome.term) {
        .signal => |sig| {
            try markerPrefix(&body, &has_markers);
            const name = try std.fmt.allocPrint(allocator, "SIG{s}", .{@tagName(sig)});
            try body.writer.print(generated.bash.killed_by_signal, .{name});
        },
        .exited => |code| if (code != 0) {
            try markerPrefix(&body, &has_markers);
            try body.writer.print(generated.bash.exit_code, .{code});
        },
    }

    return body.toOwnedSlice();
}

fn streamText(allocator: Allocator, stream: Stream) ![]const u8 {
    if (!stream.truncated) return stream.text;
    return std.fmt.allocPrint(allocator, generated.bash.output_truncated, .{
        stream.text,
        stream.spill_path orelse "(unavailable)",
    });
}

/// One newline between the body and the first marker, then between markers
/// (`markers.join('\n')` in dsh).
fn markerPrefix(body: *Writer.Allocating, has_markers: *bool) !void {
    if (has_markers.*) {
        try body.writer.writeByte('\n');
        return;
    }
    const current = body.writer.buffer[0..body.writer.end];
    if (current.len > 0 and current[current.len - 1] != '\n') try body.writer.writeByte('\n');
    has_markers.* = true;
}

fn buildMeta(allocator: Allocator, args: Args, workdir: ?[]const u8, outcome: Outcome) !Value {
    var top: std.json.ObjectMap = .empty;
    if (workdir) |dir| try top.put(allocator, "cwd", .{ .string = dir });
    try top.put(allocator, "exitCode", switch (outcome.term) {
        .exited => |code| .{ .integer = @intCast(code) },
        .signal => .null,
    });
    try top.put(allocator, "signal", switch (outcome.term) {
        .exited => .null,
        .signal => |sig| .{ .string = try std.fmt.allocPrint(allocator, "SIG{s}", .{@tagName(sig)}) },
    });
    try top.put(allocator, "timedOut", .{ .bool = outcome.timed_out });
    try top.put(allocator, "aborted", .{ .bool = false });
    try top.put(allocator, "timeoutMs", .{ .integer = @intCast(args.timeout_ms) });
    try top.put(allocator, "stdout", try streamMeta(allocator, outcome.stdout));
    try top.put(allocator, "stderr", try streamMeta(allocator, outcome.stderr));
    if (args.sandbox_permissions) |mode| {
        // P1a validates and records the request; approval and execution escalation are P2.
        var request: std.json.ObjectMap = .empty;
        try request.put(allocator, "mode", .{ .string = mode });
        try request.put(allocator, "justification", .{ .string = args.justification orelse "" });
        try top.put(allocator, "sandboxRequest", .{ .object = request });
    }
    return .{ .object = top };
}

fn streamMeta(allocator: Allocator, stream: Stream) !Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "text", .{ .string = stream.text });
    try obj.put(allocator, "truncated", .{ .bool = stream.truncated });
    if (stream.spill_path) |path| try obj.put(allocator, "spillPath", .{ .string = path });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// Tests. POSIX only: the Windows path returns UNSUPPORTED_PLATFORM, so every
// test that actually runs a command skips there (validation tests still run).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parse(allocator: Allocator, text: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, allocator, text, .{});
}

fn expectFailureContent(result: registry.ToolResult, needle: []const u8) !void {
    switch (result) {
        .failure => |failure_result| {
            const text = switch (failure_result.content[0]) {
                .text => |value| value,
                else => return error.ExpectedText,
            };
            try testing.expect(std.mem.indexOf(u8, text, needle) != null);
            try testing.expect(std.mem.indexOf(u8, failure_result.error_info.reason.?, needle) != null);
        },
        .success => return error.ExpectedFailure,
    }
}

fn expectText(result: registry.ToolResult) ![]const u8 {
    return switch (result) {
        .success => |success| switch (success.content[0]) {
            .text => |value| value,
            else => error.ExpectedText,
        },
        .failure => error.ExpectedSuccess,
    };
}

test "bash requires non-empty command and description" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var context: Context = .{};

    {
        var parsed = try parse(allocator, "{}");
        defer parsed.deinit();
        try expectFailureContent(try invoke(&context, allocator, parsed.value), "invalid command: expected a non-empty string");
    }
    {
        var parsed = try parse(allocator, "{\"command\":\"echo ok\"}");
        defer parsed.deinit();
        try expectFailureContent(try invoke(&context, allocator, parsed.value), "invalid description: expected a non-empty string");
    }
    {
        var parsed = try parse(allocator, "{\"description\":\"Run a command\",\"command\":\"   \"}");
        defer parsed.deinit();
        try expectFailureContent(try invoke(&context, allocator, parsed.value), "invalid command: expected a non-empty string");
    }
    {
        var parsed = try parse(allocator, "{\"description\":\"  \",\"command\":\"echo ok\"}");
        defer parsed.deinit();
        try expectFailureContent(try invoke(&context, allocator, parsed.value), "invalid description: expected a non-empty string");
    }
}

test "bash validates optional argument types and escalation pairing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var context: Context = .{};

    const cases = [_]struct { json: []const u8, needle: []const u8 }{
        .{ .json = "{\"description\":\"d\",\"command\":\"echo ok\",\"timeoutMs\":0}", .needle = "invalid timeoutMs: expected a positive number" },
        .{ .json = "{\"description\":\"d\",\"command\":\"echo ok\",\"timeoutMs\":\"fast\"}", .needle = "invalid timeoutMs: expected a positive number" },
        .{ .json = "{\"description\":\"d\",\"command\":\"echo ok\",\"workdir\":7}", .needle = "invalid workdir: expected a string" },
        .{ .json = "{\"description\":\"d\",\"command\":\"echo ok\",\"run_in_background\":\"yes\"}", .needle = "invalid run_in_background: expected a boolean" },
        .{ .json = "{\"description\":\"d\",\"command\":\"echo ok\",\"sandbox_permissions\":\"workspace-write\"}", .needle = "sandbox_permissions requires a justification" },
        .{ .json = "{\"description\":\"d\",\"command\":\"echo ok\",\"justification\":\"because\"}", .needle = "justification is only valid together with sandbox_permissions" },
        .{ .json = "{\"description\":\"d\",\"command\":\"echo ok\",\"sandbox_permissions\":\"root\",\"justification\":\"because\"}", .needle = "invalid sandbox_permissions: expected workspace-write or danger-full-access" },
        .{ .json = "{\"description\":\"d\",\"command\":\"echo ok\",\"sandbox_permissions\":\"workspace-write\",\"justification\":\"   \"}", .needle = "invalid justification: expected a non-empty sentence" },
    };
    for (cases) |case| {
        var parsed = try parse(allocator, case.json);
        defer parsed.deinit();
        try expectFailureContent(try invoke(&context, allocator, parsed.value), case.needle);
    }

    // A blank justification without sandbox_permissions is treated as absent, as in dsh.
    var parsed = try parse(allocator, "{\"description\":\"d\",\"command\":\"true\",\"justification\":\"   \"}");
    defer parsed.deinit();
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // command execution is POSIX-only
    _ = try expectText(try invoke(&context, allocator, parsed.value));
}

test "bash rejects run_in_background in the P1a foreground build" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var context: Context = .{};

    var parsed = try parse(allocator, "{\"description\":\"d\",\"command\":\"true\",\"run_in_background\":true}");
    defer parsed.deinit();
    const result = try invoke(&context, allocator, parsed.value);
    try expectFailureContent(result, "run_in_background is unavailable");
    switch (result) {
        .failure => |failure_result| try testing.expectEqualStrings("UNSUPPORTED", failure_result.error_info.code),
        .success => return error.ExpectedFailure,
    }
}

test "bash renders stdout, stderr and non-zero exit like dsh" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // POSIX sh -c execution

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var context: Context = .{};

    {
        var parsed = try parse(allocator, "{\"description\":\"Write both streams\",\"command\":\"printf out; printf err >&2; exit 3\"}");
        defer parsed.deinit();
        const result = try invoke(&context, allocator, parsed.value);
        try testing.expectEqualStrings("out\n[stderr]\nerr\n[exit code: 3]", try expectText(result));
        const meta = result.success.meta.?;
        try testing.expectEqual(@as(i64, 3), meta.object.get("exitCode").?.integer);
        try testing.expect(meta.object.get("signal").? == .null);
        try testing.expectEqual(false, meta.object.get("timedOut").?.bool);
    }
    {
        var parsed = try parse(allocator, "{\"description\":\"Exit silently\",\"command\":\"exit 0\"}");
        defer parsed.deinit();
        try testing.expectEqualStrings("(no output)", try expectText(try invoke(&context, allocator, parsed.value)));
    }
}

test "bash resolves a relative workdir against the session cwd" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // POSIX sh -c execution

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    try compat.fs.Dir.wrap(tmp.dir).makeDir("sub");

    var context: Context = .{ .cwd = tmp_dir };
    var parsed = try parse(allocator, "{\"description\":\"Print working directory\",\"command\":\"pwd\",\"workdir\":\"sub\"}");
    defer parsed.deinit();
    const sub_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "sub" });
    const expected = try std.fmt.allocPrint(allocator, "{s}\n", .{sub_dir});
    try testing.expectEqualStrings(expected, try expectText(try invoke(&context, allocator, parsed.value)));
}

test "bash truncates long output to its tail and writes a spill file" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // POSIX sh -c execution

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var context: Context = .{};

    var parsed = try parse(allocator, "{\"description\":\"Emit seventy thousand zero bytes\",\"command\":\"head -c 70000 /dev/zero\"}");
    defer parsed.deinit();
    const result = try invoke(&context, allocator, parsed.value);
    const text = try expectText(result);

    const meta = result.success.meta.?;
    const stdout_meta = meta.object.get("stdout").?.object;
    try testing.expectEqual(true, stdout_meta.get("truncated").?.bool);
    const spill_path = stdout_meta.get("spillPath").?.string;
    const tail = stdout_meta.get("text").?.string;
    try testing.expectEqual(max_output_bytes, tail.len);
    for (tail) |byte| try testing.expectEqual(@as(u8, 0), byte);

    const spill = try compat.fs.openFileAbsolute(spill_path, .{});
    defer spill.close();
    try testing.expectEqual(@as(u64, 70_000), (try spill.stat()).size);
    var first: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try spill.read(&first));
    try testing.expectEqual(@as(u8, 0), first[0]);

    const notice = try std.fmt.allocPrint(allocator, "\n[output truncated; full output: {s}]", .{spill_path});
    try testing.expect(std.mem.endsWith(u8, text, notice));
    try testing.expectEqual(max_output_bytes + notice.len, text.len);

    compat.fs.deleteFileAbsolute(spill_path) catch {};
}

test "bash timeout kills the command and reports dsh markers" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // POSIX sh -c execution

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var context: Context = .{};

    var parsed = try parse(allocator, "{\"description\":\"Sleep past the deadline\",\"command\":\"sleep 5\",\"timeoutMs\":50}");
    defer parsed.deinit();
    const result = try invoke(&context, allocator, parsed.value);
    const text = try expectText(result);
    try testing.expect(std.mem.indexOf(u8, text, "[timed out after 50ms]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[killed by signal: SIGKILL]") != null);

    const meta = result.success.meta.?;
    try testing.expectEqual(true, meta.object.get("timedOut").?.bool);
    try testing.expectEqualStrings("SIGKILL", meta.object.get("signal").?.string);
    try testing.expect(meta.object.get("exitCode").? == .null);
}

test "bash applies the 120s default and the 600s cap" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // POSIX sh -c execution

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var context: Context = .{};

    {
        var parsed = try parse(allocator, "{\"description\":\"Do nothing\",\"command\":\"true\"}");
        defer parsed.deinit();
        const result = try invoke(&context, allocator, parsed.value);
        try testing.expectEqual(@as(i64, 120_000), result.success.meta.?.object.get("timeoutMs").?.integer);
    }
    {
        var parsed = try parse(allocator, "{\"description\":\"Do nothing\",\"command\":\"true\",\"timeoutMs\":9000000}");
        defer parsed.deinit();
        const result = try invoke(&context, allocator, parsed.value);
        try testing.expectEqual(@as(i64, 600_000), result.success.meta.?.object.get("timeoutMs").?.integer);
    }
}

test "bash records a sandbox escalation request without escalating" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // POSIX sh -c execution

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var context: Context = .{};

    var parsed = try parse(allocator, "{\"description\":\"Check escalation recording\",\"command\":\"true\",\"sandbox_permissions\":\"workspace-write\",\"justification\":\"Build artifacts must be written.\"}");
    defer parsed.deinit();
    const result = try invoke(&context, allocator, parsed.value);
    try testing.expectEqualStrings("(no output)", try expectText(result));
    const request = result.success.meta.?.object.get("sandboxRequest").?.object;
    try testing.expectEqualStrings("workspace-write", request.get("mode").?.string);
    try testing.expectEqualStrings("Build artifacts must be written.", request.get("justification").?.string);
}

test "bash reports a spawn failure as a structured error" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // POSIX sh -c execution

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    const missing = try std.fs.path.join(allocator, &.{ tmp_dir, "missing" });

    var context: Context = .{ .cwd = tmp_dir };
    const json = try std.fmt.allocPrint(allocator, "{{\"description\":\"Run in a missing directory\",\"command\":\"true\",\"workdir\":\"{s}\"}}", .{missing});
    var parsed = try parse(allocator, json);
    defer parsed.deinit();
    const result = try invoke(&context, allocator, parsed.value);
    try expectFailureContent(result, "failed to start command");
    switch (result) {
        .failure => |failure_result| try testing.expectEqualStrings("SPAWN_FAILED", failure_result.error_info.code),
        .success => return error.ExpectedFailure,
    }
}

test "bash refuses a workdir outside the workspace unless allowed_paths names it" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // POSIX sh -c execution

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    try compat.fs.Dir.wrap(tmp.dir).makeDir("workspace");
    try compat.fs.Dir.wrap(tmp.dir).makeDir("elsewhere");
    const workspace = try std.fs.path.join(allocator, &.{ tmp_dir, "workspace" });
    const elsewhere = try std.fs.path.join(allocator, &.{ tmp_dir, "elsewhere" });

    // Regression: before the policy bridge, bash ran in any model-supplied
    // directory, including one outside the session workspace.
    var denied_context: Context = .{ .cwd = workspace };
    const denied_json = try std.fmt.allocPrint(allocator, "{{\"description\":\"Run elsewhere\",\"command\":\"pwd\",\"workdir\":\"{s}\"}}", .{elsewhere});
    var denied_args = try parse(allocator, denied_json);
    defer denied_args.deinit();
    const denied = try invoke(&denied_context, allocator, denied_args.value);
    try expectFailureContent(denied, "outside the session workspace");
    switch (denied) {
        .failure => |failure_result| try testing.expectEqualStrings("WORKDIR_NOT_ALLOWED", failure_result.error_info.code),
        .success => return error.ExpectedFailure,
    }

    var allowed_context: Context = .{ .cwd = workspace, .allowed_paths = &.{elsewhere} };
    const allowed_json = try std.fmt.allocPrint(allocator, "{{\"description\":\"Run elsewhere\",\"command\":\"pwd\",\"workdir\":\"{s}\"}}", .{elsewhere});
    var allowed_args = try parse(allocator, allowed_json);
    defer allowed_args.deinit();
    const expected = try std.fmt.allocPrint(allocator, "{s}\n", .{elsewhere});
    try testing.expectEqualStrings(expected, try expectText(try invoke(&allowed_context, allocator, allowed_args.value)));
}

test "bash scrubs the environment before spawning" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // POSIX sh -c execution

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const name = "DSH_NATIVE_TEST_SECRET";
    try platform.setProcessEnv(allocator, name, "leaked-secret");
    defer platform.setProcessEnv(allocator, name, null) catch {};

    var context: Context = .{};
    var parsed = try parse(allocator, "{\"description\":\"Read the secret\",\"command\":\"echo \\\"${DSH_NATIVE_TEST_SECRET:-unset}\\\"\"}");
    defer parsed.deinit();
    // Regression: the dsh bash inherited the host environment, so a model
    // command could print provider keys and channel tokens.
    try testing.expectEqualStrings("unset\n", try expectText(try invoke(&context, allocator, parsed.value)));
}
