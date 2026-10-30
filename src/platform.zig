const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");

const env_c = @cImport({
    @cInclude("stdlib.h");
});

/// Cross-platform wrapper over std_compat.process.getEnvVarOwned that returns
/// null instead of error.EnvironmentVariableNotFound.
/// Caller owns the returned slice and must free it with `allocator.free()`.
/// Note: OOM is treated as "variable not found" because callers universally
/// use the pattern `if (getEnvOrNull(...)) |v| { defer free(v); ... }` and
/// propagating OOM would require changing every call-site to handle errors.
/// In practice, env var allocation (< 4 KB) does not OOM.
pub fn getEnvOrNull(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return std_compat.process.getEnvVarOwned(allocator, name) catch return null;
}

/// Sets or unsets a process environment variable.
/// Passing null removes the variable on POSIX and clears it on Windows.
pub fn setProcessEnv(allocator: std.mem.Allocator, name: []const u8, value: ?[]const u8) !void {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    const rc: c_int = if (value) |env_value| blk: {
        const value_z = try allocator.dupeZ(u8, env_value);
        defer allocator.free(value_z);
        break :blk if (comptime builtin.os.tag == .windows)
            env_c._putenv_s(name_z.ptr, value_z.ptr)
        else
            env_c.setenv(name_z.ptr, value_z.ptr, 1);
    } else if (comptime builtin.os.tag == .windows)
        env_c._putenv_s(name_z.ptr, "")
    else
        env_c.unsetenv(name_z.ptr);

    if (rc != 0) return error.EnvMutationFailed;
}

/// Test-only guard for process-wide environment mutations. Captures all named
/// variables and restores them on deinit, including values inherited from the
/// developer shell or CI runner.
pub const TestEnvGuard = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,

    const Entry = struct {
        name: []const u8,
        value: ?[]u8,
    };

    pub fn capture(allocator: std.mem.Allocator, names: []const []const u8) !TestEnvGuard {
        const entries = try allocator.alloc(Entry, names.len);
        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |entry| {
                if (entry.value) |value| allocator.free(value);
            }
            allocator.free(entries);
        }

        for (names, 0..) |name, i| {
            const value = std_compat.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
                error.EnvironmentVariableNotFound => null,
                else => return err,
            };
            entries[i] = .{ .name = name, .value = value };
            initialized += 1;
        }
        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn clear(self: *const TestEnvGuard) !void {
        for (self.entries) |entry| {
            try setProcessEnv(self.allocator, entry.name, null);
        }
    }

    pub fn captureAndClear(allocator: std.mem.Allocator, names: []const []const u8) !TestEnvGuard {
        var guard = try capture(allocator, names);
        errdefer guard.deinit();
        try guard.clear();
        return guard;
    }

    pub fn deinit(self: *TestEnvGuard) void {
        var restore_failed = false;
        for (self.entries) |entry| {
            setProcessEnv(self.allocator, entry.name, entry.value) catch {
                restore_failed = true;
            };
            if (entry.value) |value| self.allocator.free(value);
        }
        self.allocator.free(self.entries);
        if (restore_failed) @panic("failed to restore test process environment");
    }
};

/// Returns the user's home directory. Tries:
///   Windows: USERPROFILE → HOMEDRIVE+HOMEPATH
///   Unix:    HOME
/// Caller owns the returned slice.
pub fn getHomeDir(allocator: std.mem.Allocator) ![]const u8 {
    if (comptime builtin.os.tag == .windows) {
        if (getEnvOrNull(allocator, "USERPROFILE")) |v| return v;
        const drive = getEnvOrNull(allocator, "HOMEDRIVE") orelse return error.HomeDirNotFound;
        defer allocator.free(drive);
        const path = getEnvOrNull(allocator, "HOMEPATH") orelse return error.HomeDirNotFound;
        defer allocator.free(path);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ drive, path });
    } else {
        return std_compat.process.getEnvVarOwned(allocator, "HOME") catch return error.HomeDirNotFound;
    }
}

/// Pure shell selection; takes the abi so host tests can assert Android behavior.
pub fn shellPath(abi: std.Target.Abi) []const u8 {
    // Android has no /bin/sh; it lives at /system/bin/sh.
    if (abi == .android) return "/system/bin/sh";
    return if (comptime builtin.os.tag == .windows) "cmd.exe" else "/bin/sh";
}

/// Pure temp-dir selection; takes the abi so host tests can assert Android behavior.
/// Android has no writable /tmp: TMPDIR, else <base>/tmp where base is
/// $NULLCLAW_HOME or $HOME (resolved by the caller).
pub fn tempDirPath(
    allocator: std.mem.Allocator,
    abi: std.Target.Abi,
    tmpdir: ?[]const u8,
    base: ?[]const u8,
) ![]const u8 {
    if (tmpdir) |value| return allocator.dupe(u8, value);
    if (abi != .android) return allocator.dupe(u8, "/tmp");
    const parent = std_compat.mem.trimRight(u8, base orelse return error.TempDirNotFound, "/");
    return std.fmt.allocPrint(allocator, "{s}/tmp", .{parent});
}

/// Android temp dir: TMPDIR, else <NULLCLAW_HOME|HOME>/tmp. Takes the env
/// values so host tests can assert the fallback chain. The directory is
/// created; caller owns the returned slice.
pub fn androidTempDir(
    allocator: std.mem.Allocator,
    tmpdir: ?[]const u8,
    nullclaw_home: ?[]const u8,
    home: ?[]const u8,
) ![]const u8 {
    const dir = try tempDirPath(allocator, .android, tmpdir, nullclaw_home orelse home);
    errdefer allocator.free(dir);
    if (nullclaw_home orelse home) |base| try std_compat.fs.cwd().makePath(base);
    try std_compat.fs.cwd().makePath(dir);
    return dir;
}

/// Temp dir for spooled payloads (attachment downloads, spilled output).
/// Android has no writable /tmp, so use the Android fallback chain; other
/// platforms keep the historical hardcoded "/tmp".
/// Caller owns the returned slice.
pub fn getSpoolTempDir(allocator: std.mem.Allocator) ![]const u8 {
    if (comptime builtin.abi == .android) return getTempDir(allocator);
    return allocator.dupe(u8, "/tmp");
}

/// Returns the system temp directory. Tries:
///   Windows: TEMP → TMP → "C:\\Temp"
///   Android: TMPDIR → "$NULLCLAW_HOME/tmp" → "$HOME/tmp" (directory is created)
///   Unix:    TMPDIR → "/tmp"
/// Caller owns the returned slice.
pub fn getTempDir(allocator: std.mem.Allocator) ![]const u8 {
    if (comptime builtin.os.tag == .windows) {
        if (getEnvOrNull(allocator, "TEMP")) |v| return v;
        if (getEnvOrNull(allocator, "TMP")) |v| return v;
        return allocator.dupe(u8, "C:\\Temp");
    }
    if (comptime builtin.abi != .android) {
        if (getEnvOrNull(allocator, "TMPDIR")) |v| return v;
        return allocator.dupe(u8, "/tmp");
    }
    // Android: no /tmp; TMPDIR, else $NULLCLAW_HOME/tmp or $HOME/tmp.
    const tmpdir = getEnvOrNull(allocator, "TMPDIR");
    defer if (tmpdir) |v| allocator.free(v);
    const nullclaw_home = if (tmpdir == null) getEnvOrNull(allocator, "NULLCLAW_HOME") else null;
    defer if (nullclaw_home) |v| allocator.free(v);
    const home = if (tmpdir == null and nullclaw_home == null) getEnvOrNull(allocator, "HOME") else null;
    defer if (home) |v| allocator.free(v);
    return androidTempDir(allocator, tmpdir, nullclaw_home, home);
}

/// Returns the platform shell for executing commands.
pub fn getShell() []const u8 {
    return shellPath(builtin.abi);
}

/// Returns the shell flag for passing a command string.
pub fn getShellFlag() []const u8 {
    return if (comptime builtin.os.tag == .windows) "/c" else "-c";
}

// ── Tests ────────────────────────────────────────────────────────

test "getEnvOrNull returns null for missing var" {
    try std.testing.expect(getEnvOrNull(std.testing.allocator, "NULLCLAW_NONEXISTENT_VAR_12345") == null);
}

test "setProcessEnv updates and clears process env var" {
    const allocator = std.testing.allocator;
    const name = "NULLCLAW_PLATFORM_TEST_ENV";
    const previous = getEnvOrNull(allocator, name);
    defer if (previous) |value| allocator.free(value);
    defer setProcessEnv(allocator, name, previous) catch @panic("failed to restore platform test env");

    try setProcessEnv(allocator, name, "value");
    const current = getEnvOrNull(allocator, name) orelse return error.TestUnexpectedResult;
    defer allocator.free(current);
    try std.testing.expectEqualStrings("value", current);

    try setProcessEnv(allocator, name, null);
    const cleared = getEnvOrNull(allocator, name);
    defer if (cleared) |value| allocator.free(value);
    try std.testing.expect(cleared == null);
}

test "TestEnvGuard restores inherited values" {
    const allocator = std.testing.allocator;
    const name = "NULLCLAW_PLATFORM_GUARD_TEST_ENV";
    var outer = try TestEnvGuard.capture(allocator, &.{name});
    defer outer.deinit();

    try setProcessEnv(allocator, name, "original");
    {
        var guard = try TestEnvGuard.captureAndClear(allocator, &.{name});
        defer guard.deinit();
        const cleared = getEnvOrNull(allocator, name);
        defer if (cleared) |value| allocator.free(value);
        try std.testing.expect(cleared == null);
        try setProcessEnv(allocator, name, "mutated");
    }

    const restored = getEnvOrNull(allocator, name) orelse return error.TestUnexpectedResult;
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("original", restored);
}

test "getHomeDir returns a non-empty string" {
    const home = try getHomeDir(std.testing.allocator);
    defer std.testing.allocator.free(home);
    try std.testing.expect(home.len > 0);
}

test "getTempDir returns a non-empty string" {
    const tmp = try getTempDir(std.testing.allocator);
    defer std.testing.allocator.free(tmp);
    try std.testing.expect(tmp.len > 0);
}

test "getShell returns a known value" {
    const shell = getShell();
    try std.testing.expect(shell.len > 0);
}

test "shellPath selects /system/bin/sh on Android" {
    // Regression: Android has no /bin/sh, so spawning the shell failed with ENOENT.
    try std.testing.expectEqualStrings("/system/bin/sh", shellPath(.android));
}

test "shellPath keeps /bin/sh on non-Android Unix" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expectEqualStrings("/bin/sh", shellPath(.gnu));
}

test "tempDirPath prefers TMPDIR on Android" {
    // Regression: /tmp is not writable on Android.
    const dir = try tempDirPath(std.testing.allocator, .android, "/data/local/tmp", null);
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("/data/local/tmp", dir);
}

test "tempDirPath falls back under the home base on Android" {
    // Regression: /tmp is not writable on Android; NULLCLAW_HOME/HOME/tmp is used.
    const dir = try tempDirPath(std.testing.allocator, .android, null, "/data/user/0/com.example.app");
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("/data/user/0/com.example.app/tmp", dir);
}

test "tempDirPath reports a missing Android temp base" {
    try std.testing.expectError(error.TempDirNotFound, tempDirPath(std.testing.allocator, .android, null, null));
}

test "tempDirPath keeps /tmp on non-Android Unix" {
    const dir = try tempDirPath(std.testing.allocator, .gnu, null, "/home/user");
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("/tmp", dir);
}

test "tempDirPath fails closed on empty or root Android base" {
    // Regression: an empty or "/" HOME resolved to /tmp, which Android cannot
    // create, and getTempDir created HOME as a side effect.
    try std.testing.expectError(error.TempDirNotFound, tempDirPath(std.testing.allocator, .android, null, ""));
    try std.testing.expectError(error.TempDirNotFound, tempDirPath(std.testing.allocator, .android, null, "/"));
}

test "androidTempDir does not create the home base" {
    // Regression: getTempDir created HOME instead of failing closed when the
    // base directory was missing.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const missing = try std_compat.fs.path.join(allocator, &.{ root, "missing-home" });
    defer allocator.free(missing);
    try std.testing.expectError(error.FileNotFound, androidTempDir(allocator, null, missing, null));
    try std.testing.expectError(error.FileNotFound, std_compat.fs.accessAbsolute(missing, .{}));
}

test "androidTempDir creates the tmp directory 0700" {
    // Regression: HOME/tmp was created with the default 0755 mode.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const dir = try androidTempDir(allocator, null, root, null);
    defer allocator.free(dir);
    const stat = try std_compat.fs.cwd().statFile(dir);
    try std.testing.expectEqual(@as(std_compat.fs.File.Mode, 0o700), stat.mode & 0o777);
}
