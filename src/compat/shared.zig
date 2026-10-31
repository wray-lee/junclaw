const std = @import("std");
const builtin = @import("builtin");

pub const Io = std.Io;
pub const Allocator = std.mem.Allocator;

var fallback_threaded: Io.Threaded = .init_single_threaded;
var process_io: ?Io = null;
var process_args: ?std.process.Args = null;
var process_environ: ?std.process.Environ = null;

pub fn initProcess(init: std.process.Init) void {
    process_io = init.io;
    process_args = init.minimal.args;
    process_environ = init.minimal.environ;
    if (comptime builtin.abi == .android) installAndroidSignalHandlers();
}

/// Regression: once Android DNS resolved, the first std.http connect killed
/// the process with SIGIO (exit 157). Bionic LP64 puts `sa_flags` before the
/// handler while Zig's `std.c.Sigaction` uses the kernel-ish order, so
/// `std.Io.Threaded` installs its SIGIO/SIGPIPE handlers into the wrong
/// offsets. Reinstall them with bionic's layout before any Io operation can
/// cancel.
const AndroidSigaction = if (@sizeOf(usize) == 8) extern struct {
    flags: c_int,
    handler: extern union {
        handler: ?*const fn (c_int) callconv(.c) void,
        sigaction: ?*const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) void,
    },
    mask: [1]c_ulong,
    restorer: ?*const fn () callconv(.c) void = null,
} else extern struct {
    handler: extern union {
        handler: ?*const fn (c_int) callconv(.c) void,
        sigaction: ?*const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) void,
    },
    mask: c_ulong,
    flags: c_int,
    restorer: ?*const fn () callconv(.c) void = null,
};

extern "c" fn sigaction(sig: c_int, act: ?*const AndroidSigaction, old: ?*AndroidSigaction) c_int;

comptime {
    if (builtin.abi == .android and @sizeOf(usize) == 8) {
        std.debug.assert(@offsetOf(AndroidSigaction, "flags") == 0);
        std.debug.assert(@offsetOf(AndroidSigaction, "handler") == 8);
        std.debug.assert(@offsetOf(AndroidSigaction, "mask") == 16);
        std.debug.assert(@offsetOf(AndroidSigaction, "restorer") == 24);
        std.debug.assert(@sizeOf(AndroidSigaction) == 32);
    }
}

fn ignoreSignal(_: c_int) callconv(.c) void {}

fn installAndroidSignalHandlers() void {
    var act: AndroidSigaction = std.mem.zeroes(AndroidSigaction);
    act.handler = .{ .handler = ignoreSignal };
    _ = sigaction(@intFromEnum(std.posix.SIG.IO), &act, null);
    _ = sigaction(@intFromEnum(std.posix.SIG.PIPE), &act, null);
}

pub fn initProcessMinimal(init: std.process.Init.Minimal) void {
    process_args = init.args;
    process_environ = init.environ;
}

pub fn io() Io {
    if (builtin.is_test) return std.testing.io;
    if (process_io) |current| return current;
    return fallback_threaded.io();
}

pub fn environ() std.process.Environ {
    if (process_environ) |env| return env;
    return switch (builtin.os.tag) {
        .windows, .freestanding, .other => .{ .block = .global },
        .wasi, .emscripten => if (builtin.link_libc) blk: {
            const c_environ = std.c.environ;
            var env_count: usize = 0;
            while (c_environ[env_count] != null) : (env_count += 1) {}
            break :blk .{ .block = .{ .slice = c_environ[0..env_count :null] } };
        } else .{ .block = .global },
        else => blk: {
            const c_environ = std.c.environ;
            var env_count: usize = 0;
            while (c_environ[env_count] != null) : (env_count += 1) {}
            break :blk .{ .block = .{ .slice = c_environ[0..env_count :null] } };
        },
    };
}

pub fn argsAlloc(allocator: Allocator) ![]const [:0]const u8 {
    const args = process_args orelse return error.MissingProcessContext;
    var iter = try args.iterateAllocator(allocator);
    defer iter.deinit();

    var list: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
    }

    while (iter.next()) |arg| {
        try list.append(allocator, try allocator.dupeZ(u8, arg));
    }

    return try list.toOwnedSlice(allocator);
}

pub fn argsFree(allocator: Allocator, args: []const [:0]const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}
