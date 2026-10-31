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
    // An empty or "/" base would resolve to the unwritable /tmp.
    if (parent.len == 0) return error.TempDirNotFound;
    return std.fmt.allocPrint(allocator, "{s}/tmp", .{parent});
}

/// Android temp dir: TMPDIR, else <NULLCLAW_HOME|HOME>/tmp. Takes the env
/// values so host tests can assert the fallback chain. Creates only the tmp
/// directory (0700): a missing or invalid home base fails closed instead of
/// being created as a side effect. Caller owns the returned slice.
pub fn androidTempDir(
    allocator: std.mem.Allocator,
    tmpdir: ?[]const u8,
    nullclaw_home: ?[]const u8,
    home: ?[]const u8,
) ![]const u8 {
    const dir = try tempDirPath(allocator, .android, tmpdir, nullclaw_home orelse home);
    errdefer allocator.free(dir);
    if (tmpdir == null) {
        std.Io.Dir.createDirAbsolute(std_compat.io(), dir, std_compat.fs.permissionsFromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    return dir;
}

/// Name of the junclaw-owned subdirectory under the system temp dir. All
/// channel attachment spool files live here so sweeps never touch unrelated
/// temp files.
pub const spool_dir_name = "nullclaw-spool";

/// Default lifetime for spool files that were not released with their message
/// (for example after a crash). 24 hours.
pub const spool_ttl_secs: i64 = 24 * 60 * 60;

/// True when an existing spool directory is safe to reuse. In a shared temp
/// dir another local user can pre-create (or symlink) the name, so on POSIX
/// require a real directory owned by us with no group/other access. Windows
/// has no POSIX ownership model and WASI has no temp dir to share.
/// A reusable spool dir must be a directory (not a symlink, which shows up as
/// 0o120000), owned by the effective user, with no group/other access.
fn spoolDirStatIsTrusted(mode: u32, uid: u32, euid: u32) bool {
    return uid == euid and
        (mode & 0o170000) == 0o040000 and
        (mode & 0o077) == 0;
}

fn existingSpoolDirIsOwned(path: []const u8) bool {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return true;
    // Android's spool dir lives in app-private storage, and its seccomp filter
    // may reject statx on older kernels.
    if (comptime builtin.abi == .android) return true;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;

    var mode: u32 = undefined;
    var uid: u32 = undefined;
    var euid: u32 = undefined;
    if (comptime builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        switch (std.os.linux.errno(std.os.linux.statx(
            std.os.linux.AT.FDCWD,
            z.ptr,
            std.os.linux.AT.SYMLINK_NOFOLLOW,
            .{ .TYPE = true, .MODE = true, .UID = true },
            &stx,
        ))) {
            .SUCCESS => {},
            // Kernels older than 4.11 lack statx; nothing to verify against.
            .NOSYS => return true,
            else => return false,
        }
        mode = stx.mode;
        uid = stx.uid;
        euid = std.os.linux.geteuid();
    } else if (comptime builtin.link_libc) {
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, z.ptr, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return false;
        mode = @intCast(st.mode);
        uid = @intCast(st.uid);
        euid = std.c.geteuid();
    } else {
        return true;
    }
    return uid == euid and
        (mode & 0o170000) == 0o040000 and
        (mode & 0o077) == 0;
}

/// Temp dir for spooled payloads (attachment downloads, spilled output).
/// Uses the platform temp dir: a hardcoded "/tmp" does not exist on Windows,
/// where the failed mkdir silently dropped every attachment download. The
/// returned directory is the junclaw-owned subdirectory and is created (0700)
/// if needed, so sweeps never have to touch unrelated temp files.
/// Caller owns the returned slice.
pub fn getSpoolTempDir(allocator: std.mem.Allocator) ![]const u8 {
    const base = try getTempDir(allocator);
    defer allocator.free(base);
    const dir = try std.fs.path.join(allocator, &.{ base, spool_dir_name });
    errdefer allocator.free(dir);
    std.Io.Dir.createDirAbsolute(std_compat.io(), dir, std_compat.fs.permissionsFromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => if (!existingSpoolDirIsOwned(dir)) return error.SpoolDirNotOwned,
        else => return err,
    };
    return dir;
}

/// Remove a single spool file. Refuses paths outside a junclaw spool directory
/// so a bad caller cannot delete arbitrary files.
pub fn deleteSpoolFile(path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (!std.mem.eql(u8, std.fs.path.basename(parent), spool_dir_name)) return;
    std_compat.fs.deleteFileAbsolute(path) catch {};
}

/// Delete files in `dir_path` whose age is at or past `ttl_secs`. `now_secs`
/// is injected so callers (and tests) control the clock. Only directories
/// named like the junclaw spool dir are touched.
pub fn sweepSpoolFilesInDir(dir_path: []const u8, now_secs: i64, ttl_secs: i64) void {
    if (!std.mem.eql(u8, std.fs.path.basename(dir_path), spool_dir_name)) return;

    var dir = std_compat.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;

        const stat = dir.statFile(entry.name) catch continue;
        const mtime_secs: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
        if ((now_secs - mtime_secs) < ttl_secs) continue;

        dir.deleteFile(entry.name) catch continue;
    }
}

/// Sweep the platform spool directory.
pub fn sweepSpoolTempDir(allocator: std.mem.Allocator, now_secs: i64, ttl_secs: i64) void {
    const dir = getSpoolTempDir(allocator) catch return;
    defer allocator.free(dir);
    sweepSpoolFilesInDir(dir, now_secs, ttl_secs);
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

test "spoolDirStatIsTrusted rejects symlinks and foreign or group-writable dirs" {
    // Regression: getSpoolTempDir trusted any pre-existing /tmp/nullclaw-spool,
    // so another local user could own (or symlink) the dir and read attachments.
    const me: u32 = 1000;
    try std.testing.expect(spoolDirStatIsTrusted(0o040700, me, me));
    // Symlink planted under the same name.
    try std.testing.expect(!spoolDirStatIsTrusted(0o120777, me, me));
    // Owned by someone else.
    try std.testing.expect(!spoolDirStatIsTrusted(0o040700, 1001, me));
    // Group/other accessible.
    try std.testing.expect(!spoolDirStatIsTrusted(0o040755, me, me));
    try std.testing.expect(!spoolDirStatIsTrusted(0o040770, me, me));
    // Not a directory.
    try std.testing.expect(!spoolDirStatIsTrusted(0o100700, me, me));
}

test "getSpoolTempDir reuses its own 0700 dir and rejects a planted one" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    if (comptime builtin.abi == .android) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const spool = try std_compat.fs.path.join(allocator, &.{ root, spool_dir_name });
    defer allocator.free(spool);

    // A world-writable dir planted at the spool name must be refused, not reused.
    try std_compat.fs.makeDirAbsolute(spool);
    try std_compat.fs.chmodAbsolute(spool, 0o777);
    try std.testing.expect(!existingSpoolDirIsOwned(spool));

    // The dir junclaw creates itself is 0700 and is reused.
    try std_compat.fs.chmodAbsolute(spool, 0o700);
    try std.testing.expect(existingSpoolDirIsOwned(spool));

    // A symlink at the spool name is never trusted.
    const link = try std_compat.fs.path.join(allocator, &.{ root, "planted-link" });
    defer allocator.free(link);
    std_compat.fs.Dir.wrap(tmp.dir).symLink(root, "planted-link", .{}) catch return error.SkipZigTest;
    try std.testing.expect(!existingSpoolDirIsOwned(link));
}

test "deleteSpoolFile removes a file inside the spool dir" {
    // Regression: Signal/WhatsApp/Mattermost/Discord attachment spool files
    // were never deleted after their message was handled.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = std_compat.fs.Dir.wrap(tmp.dir);
    try dir.makeDir(spool_dir_name);
    try dir.writeFile(.{ .sub_path = spool_dir_name ++ "/signal_test.dat", .data = "x" });
    const path = try dir.realpathAlloc(allocator, spool_dir_name ++ "/signal_test.dat");
    defer allocator.free(path);

    deleteSpoolFile(path);

    try std.testing.expectError(error.FileNotFound, dir.statFile(spool_dir_name ++ "/signal_test.dat"));
}

test "deleteSpoolFile refuses paths outside the spool dir" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = std_compat.fs.Dir.wrap(tmp.dir);
    try dir.writeFile(.{ .sub_path = "outside.txt", .data = "keep" });
    const path = try dir.realpathAlloc(allocator, "outside.txt");
    defer allocator.free(path);

    deleteSpoolFile(path);

    const stat = try dir.statFile("outside.txt");
    try std.testing.expect(stat.size > 0);
}

test "sweepSpoolFilesInDir deletes files at or past ttl using injected now" {
    // Regression: no TTL sweep existed for the channel spool dir, so files
    // left behind by a crash or a failed handoff stayed forever.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = std_compat.fs.Dir.wrap(tmp.dir);
    try dir.makeDir(spool_dir_name);
    try dir.writeFile(.{ .sub_path = spool_dir_name ++ "/whatsapp_old.dat", .data = "x" });
    const spool = try dir.realpathAlloc(allocator, spool_dir_name);
    defer allocator.free(spool);
    const stat = try dir.statFile(spool_dir_name ++ "/whatsapp_old.dat");
    const mtime_secs: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));

    sweepSpoolFilesInDir(spool, mtime_secs + spool_ttl_secs, spool_ttl_secs);

    try std.testing.expectError(error.FileNotFound, dir.statFile(spool_dir_name ++ "/whatsapp_old.dat"));
}

test "sweepSpoolFilesInDir keeps files younger than ttl" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = std_compat.fs.Dir.wrap(tmp.dir);
    try dir.makeDir(spool_dir_name);
    try dir.writeFile(.{ .sub_path = spool_dir_name ++ "/discord_fresh.dat", .data = "x" });
    const spool = try dir.realpathAlloc(allocator, spool_dir_name);
    defer allocator.free(spool);
    const stat = try dir.statFile(spool_dir_name ++ "/discord_fresh.dat");
    const mtime_secs: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));

    sweepSpoolFilesInDir(spool, mtime_secs + spool_ttl_secs - 1, spool_ttl_secs);

    const kept = try dir.statFile(spool_dir_name ++ "/discord_fresh.dat");
    try std.testing.expect(kept.size > 0);
}

test "sweepSpoolFilesInDir ignores directories that are not the spool dir" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = std_compat.fs.Dir.wrap(tmp.dir);
    try dir.makeDir("not-spool");
    try dir.writeFile(.{ .sub_path = "not-spool/mattermost_old.bin", .data = "x" });
    const other = try dir.realpathAlloc(allocator, "not-spool");
    defer allocator.free(other);

    sweepSpoolFilesInDir(other, std.math.maxInt(i64), -1);

    const kept = try dir.statFile("not-spool/mattermost_old.bin");
    try std.testing.expect(kept.size > 0);
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
    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        try std.testing.expectEqual(@as(std_compat.fs.File.Mode, 0o700), stat.mode & 0o777);
    } else {
        // Windows/WASI report no Unix mode bits; only existence is assertable.
        try std.testing.expect(stat.kind == .directory);
    }
}
