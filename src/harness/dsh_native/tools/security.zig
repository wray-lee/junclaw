//! junclaw SecurityPolicy gate shared by the dsh-native file and shell tools.
//!
//! dsh resolves `path`/`workdir` against the session workspace; this module
//! re-applies the native tools' boundary before any filesystem access. System
//! prefixes stay blocked, then the resolved path (symlinks included) must sit
//! inside the workspace or one of `allowed_paths`.
//!
//! The autonomy, rate-limit and bash command checks mirror `Agent.executeTool`
//! and `ShellTool.execute`, so the dsh-native engine is never wider than the
//! native one.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const fs_compat = @import("../../../fs_compat.zig");
const file_common = @import("../../../tools/file_common.zig");
const path_security = @import("../../../tools/path_security.zig");
const SecurityPolicy = @import("../../../security/policy.zig").SecurityPolicy;

pub const Scope = struct {
    /// Session workspace (the dsh tool cwd). Relative paths resolve against it.
    cwd: []const u8,
    /// `autonomy.allowed_paths` from the agent config.
    allowed_paths: []const []const u8 = &.{},
    /// dsh's own spill directory. Read-only access, because dsh advertises
    /// spill paths to the model (`spill_retrieval_hint`) and they live under
    /// `dsh_home`, outside the workspace.
    read_root: ?[]const u8 = null,
};

pub fn pathAllowed(allocator: std.mem.Allocator, scope: Scope, input: []const u8) !bool {
    return check(allocator, scope, input, false);
}

pub fn readPathAllowed(allocator: std.mem.Allocator, scope: Scope, input: []const u8) !bool {
    return check(allocator, scope, input, true);
}

fn check(allocator: std.mem.Allocator, scope: Scope, input: []const u8, allow_read_root: bool) !bool {
    if (scope.cwd.len == 0 or std.mem.indexOfScalar(u8, input, 0) != null) return false;
    const absolute = try std.fs.path.resolve(allocator, &.{ scope.cwd, input });
    defer allocator.free(absolute);
    // Fail closed when the workspace itself cannot be resolved.
    const ws_resolved = fs_compat.realpathAllocPath(allocator, scope.cwd) catch return false;
    defer allocator.free(ws_resolved);
    // Existing targets are canonicalized (symlink-safe); a target that does not
    // exist yet is checked through its nearest existing ancestor, which is the
    // native file tools' rule for create/write.
    const resolved = fs_compat.realpathAllocPath(allocator, absolute) catch |err| switch (err) {
        error.FileNotFound => blk: {
            // Regression: a dangling final symlink resolves through its parent,
            // which made the ancestor check pass, but create() then followed the
            // link and wrote outside the workspace. Native swaps inodes via
            // temp+rename; the dsh write path opens in place, so refuse the link.
            if (!allow_read_root) {
                // Only a missing parent is a normal create; any other
                // inspection failure is a reason to refuse, not to proceed.
                const is_link = file_common.isSymlinkPath(absolute) catch |inspect_err| switch (inspect_err) {
                    error.FileNotFound => false,
                    else => return false,
                };
                if (is_link) return false;
            }
            break :blk file_common.resolveNearestExistingAncestor(allocator, absolute) catch return false;
        },
        else => return false,
    };
    defer allocator.free(resolved);
    if (path_security.isResolvedPathAllowed(allocator, resolved, ws_resolved, scope.allowed_paths)) return true;
    if (allow_read_root) {
        if (scope.read_root) |root| {
            if (root.len != 0) {
                const root_resolved = fs_compat.realpathAllocPath(allocator, root) catch return false;
                defer allocator.free(root_resolved);
                return path_security.pathStartsWith(resolved, root_resolved);
            }
        }
    }
    return false;
}

/// `Agent.executeTool`'s autonomy gate.
pub fn autonomyDenial(policy: *const SecurityPolicy) ?[]const u8 {
    if (!policy.canAct()) return "Action blocked: agent is in read-only mode";
    return null;
}

/// `Agent.executeTool`'s per-call rate limit.
pub fn rateLimitDenial(policy: *const SecurityPolicy) ?[]const u8 {
    const allowed = policy.recordAction() catch return null;
    if (!allowed) return "Rate limit exceeded";
    return null;
}

/// `ShellTool.execute`'s command policy for the dsh bash tool. `approved` is
/// always false: dsh-native has no exec-approval channel yet, so an
/// approval-required command is denied rather than allowed.
pub fn commandDenial(policy: *const SecurityPolicy, command: []const u8) ?[]const u8 {
    _ = policy.validateCommandExecution(command, false) catch |err| return switch (err) {
        error.CommandNotAllowed => "Command not allowed by security policy",
        error.HighRiskBlocked => "High-risk command blocked by security policy",
        error.MediumRiskBlocked => "Medium-risk command blocked by security policy",
        error.ApprovalRequired => "Command requires approval (medium/high risk)",
    };
    return null;
}

// ---------------------------------------------------------------------------
// tests

fn realpathTmp(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
}

fn writeFixtureFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    errdefer allocator.free(path);
    if (std.fs.path.dirname(path)) |parent| try fs_compat.makePath(parent);
    const file = try fs_compat.createPath(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("fixture\n");
    return path;
}

test "security: workspace and allowed_paths bound every resolved path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try realpathTmp(allocator, &tmp);
    defer allocator.free(base);
    const workspace = try std.fs.path.join(allocator, &.{ base, "workspace" });
    defer allocator.free(workspace);
    try fs_compat.makePath(workspace);
    const allowed = try std.fs.path.join(allocator, &.{ base, "allowed" });
    defer allocator.free(allowed);
    try fs_compat.makePath(allowed);

    const inside = try writeFixtureFile(allocator, workspace, "note.txt");
    defer allocator.free(inside);
    const outside = try writeFixtureFile(allocator, base, "outside.txt");
    defer allocator.free(outside);
    const allowed_file = try writeFixtureFile(allocator, allowed, "shared.txt");
    defer allocator.free(allowed_file);

    const scope: Scope = .{ .cwd = workspace };
    try std.testing.expect(try pathAllowed(allocator, scope, "note.txt"));
    try std.testing.expect(try pathAllowed(allocator, scope, inside));
    // A create target that does not exist yet is judged by its ancestor.
    try std.testing.expect(try pathAllowed(allocator, scope, "new dir/deep/file.txt"));
    try std.testing.expect(!try pathAllowed(allocator, scope, "../outside.txt"));
    try std.testing.expect(!try pathAllowed(allocator, scope, outside));
    try std.testing.expect(!try pathAllowed(allocator, scope, "../new dir/file.txt"));
    try std.testing.expect(!try pathAllowed(allocator, scope, ".."));
    try std.testing.expect(!try pathAllowed(allocator, .{ .cwd = "" }, "note.txt"));

    // allowed_paths widen the boundary only to that directory.
    const widened: Scope = .{ .cwd = workspace, .allowed_paths = &.{allowed} };
    try std.testing.expect(try pathAllowed(allocator, widened, allowed_file));
    try std.testing.expect(try pathAllowed(allocator, widened, "../allowed/new.txt"));
    try std.testing.expect(!try pathAllowed(allocator, widened, outside));
    // System prefixes stay blocked even when listed in allowed_paths.
    if (comptime builtin.os.tag != .windows) {
        try std.testing.expect(!try pathAllowed(allocator, .{
            .cwd = workspace,
            .allowed_paths = &.{"/etc"},
        }, "/etc/passwd"));
    }
}

test "security: only reads may reach the dsh spill directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try realpathTmp(allocator, &tmp);
    defer allocator.free(base);
    const workspace = try std.fs.path.join(allocator, &.{ base, "workspace" });
    defer allocator.free(workspace);
    try fs_compat.makePath(workspace);
    const spill = try std.fs.path.join(allocator, &.{ base, "spill" });
    defer allocator.free(spill);
    try fs_compat.makePath(spill);
    const spilled = try writeFixtureFile(allocator, spill, "bash-1.log");
    defer allocator.free(spilled);

    const scope: Scope = .{ .cwd = workspace, .read_root = spill };
    try std.testing.expect(try readPathAllowed(allocator, scope, spilled));
    try std.testing.expect(!try pathAllowed(allocator, scope, spilled));
    try std.testing.expect(!try readPathAllowed(allocator, .{ .cwd = workspace }, spilled));
}

test "security: a symlink inside the workspace cannot escape it" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try realpathTmp(allocator, &tmp);
    defer allocator.free(base);
    const workspace = try std.fs.path.join(allocator, &.{ base, "workspace" });
    defer allocator.free(workspace);
    try fs_compat.makePath(workspace);
    const outside_dir = try std.fs.path.join(allocator, &.{ base, "outside" });
    defer allocator.free(outside_dir);
    try fs_compat.makePath(outside_dir);
    const secret = try writeFixtureFile(allocator, outside_dir, "secret.txt");
    defer allocator.free(secret);
    const link = try std.fs.path.join(allocator, &.{ workspace, "link" });
    defer allocator.free(link);
    try compat.fs.Dir.wrap(tmp.dir).symLink("../outside", "workspace/link", .{});
    // Regression: a dangling link hid behind its existing parent, so the
    // ancestor rule allowed it while create() followed it to a missing target.
    try compat.fs.Dir.wrap(tmp.dir).symLink("../outside/not-there.txt", "workspace/dangling", .{});

    const scope: Scope = .{ .cwd = workspace };
    try std.testing.expect(!try readPathAllowed(allocator, scope, "link/secret.txt"));
    try std.testing.expect(!try pathAllowed(allocator, scope, "link/new.txt"));
    try std.testing.expect(!try pathAllowed(allocator, scope, "dangling"));
    // Reads keep their existing not-found behavior; only writers must refuse.
    try std.testing.expect(try readPathAllowed(allocator, scope, "dangling"));
}

test "security: autonomy and command policy mirror the native gate" {
    const read_only = SecurityPolicy{ .autonomy = .read_only };
    try std.testing.expectEqualStrings(
        "Action blocked: agent is in read-only mode",
        autonomyDenial(&read_only).?,
    );
    try std.testing.expect(autonomyDenial(&SecurityPolicy{}) == null);

    // The allowlist is checked before the risk tier, so a risk denial needs a
    // policy that explicitly allows the command.
    const policy = SecurityPolicy{ .allowed_commands = &.{ "rm", "curl", "ls" } };
    try std.testing.expectEqualStrings(
        "High-risk command blocked by security policy",
        commandDenial(&policy, "rm -rf /").?,
    );
    try std.testing.expectEqualStrings(
        "Medium-risk command blocked by security policy",
        commandDenial(&policy, "curl https://example.com").?,
    );
    try std.testing.expectEqualStrings(
        "Command not allowed by security policy",
        commandDenial(&policy, "python script.py").?,
    );
    try std.testing.expect(commandDenial(&policy, "ls -la") == null);

    const unblocked = SecurityPolicy{
        .allowed_commands = &.{"rm"},
        .block_high_risk_commands = false,
    };
    try std.testing.expectEqualStrings(
        "Command requires approval (medium/high risk)",
        commandDenial(&unblocked, "rm -rf /").?,
    );

    const yolo = SecurityPolicy{ .autonomy = .yolo };
    try std.testing.expect(commandDenial(&yolo, "rm -rf /") == null);
}

test "security: the action rate limit is enforced when a tracker is attached" {
    const allocator = std.testing.allocator;
    var tracker = @import("../../../security/tracker.zig").RateTracker.init(allocator, 1);
    defer tracker.deinit();
    const policy = SecurityPolicy{ .tracker = &tracker };
    try std.testing.expect(rateLimitDenial(&policy) == null);
    try std.testing.expectEqualStrings("Rate limit exceeded", rateLimitDenial(&policy).?);
}
