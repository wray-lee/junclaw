//! Automatic session reset policy (`session.reset` / `session.reset_by_type`).
//!
//! Mirrors OpenClaw's reset-policy model: the policy is evaluated lazily when a
//! session is next used, not by a timer. Defaults keep the old behavior: with
//! `mode: none` nothing is ever reset automatically.
//!
//! Divergence from OpenClaw: junclaw has no local-time helper, so `at_hour` is
//! evaluated in UTC. OpenClaw resolves it in the host's local timezone.

const std = @import("std");
const config_types = @import("config_types.zig");

pub const ResetType = enum { direct, group, thread };

/// Classify a session key. Thread wins over group: a thread key ends with
/// `:thread:{id}` and may also contain the parent's `:group:`/`:channel:`.
pub fn classify(session_key: []const u8) ResetType {
    if (std.mem.indexOf(u8, session_key, ":thread:") != null) return .thread;
    if (std.mem.indexOf(u8, session_key, ":group:") != null or
        std.mem.indexOf(u8, session_key, ":channel:") != null or
        std.mem.indexOf(u8, session_key, ":room:") != null) return .group;
    return .direct;
}

/// Effective policy for a session key: a `reset_by_type` entry replaces the
/// base `reset` policy for that kind.
pub fn resolvePolicy(
    cfg: config_types.SessionConfig,
    session_key: []const u8,
) config_types.SessionResetConfig {
    return switch (classify(session_key)) {
        .direct => cfg.reset_by_type.direct orelse cfg.reset,
        .group => cfg.reset_by_type.group orelse cfg.reset,
        .thread => cfg.reset_by_type.thread orelse cfg.reset,
    };
}

/// Most recent `at_hour` boundary, in UTC epoch seconds.
pub fn dailyBoundary(now: i64, at_hour: u8) i64 {
    const hour: i64 = @min(at_hour, 23);
    const today = @divFloor(now, 86400) * 86400 + hour * 3600;
    return if (now < today) today - 86400 else today;
}

/// Whether a session must be reset before serving the next message.
/// `created_at` is the session start (daily), `last_active` the last
/// interaction (idle).
pub fn isStale(
    policy: config_types.SessionResetConfig,
    now: i64,
    created_at: i64,
    last_active: i64,
) bool {
    return switch (policy.mode) {
        .none => false,
        .daily => created_at < dailyBoundary(now, policy.at_hour),
        .idle => if (policy.idle_minutes) |minutes|
            minutes > 0 and now > last_active + @as(i64, minutes) * 60
        else
            false,
    };
}

test "classify session keys" {
    try std.testing.expectEqual(ResetType.thread, classify("agent:main:telegram:group:-100:thread:7"));
    try std.testing.expectEqual(ResetType.group, classify("agent:main:telegram:group:-100"));
    try std.testing.expectEqual(ResetType.group, classify("agent:main:slack:channel:C1"));
    try std.testing.expectEqual(ResetType.group, classify("agent:main:slack:room:R1"));
    try std.testing.expectEqual(ResetType.direct, classify("agent:main:telegram:direct:42"));
    try std.testing.expectEqual(ResetType.direct, classify("agent:main"));
}

test "resolvePolicy: default is off" {
    const cfg = config_types.SessionConfig{};
    const policy = resolvePolicy(cfg, "agent:main:telegram:direct:42");
    try std.testing.expectEqual(config_types.SessionResetMode.none, policy.mode);
    try std.testing.expectEqual(@as(?u32, null), policy.idle_minutes);
}

test "resolvePolicy: resetByType overrides base per kind" {
    const base = config_types.SessionResetConfig{ .mode = .daily, .at_hour = 6 };
    const group = config_types.SessionResetConfig{ .mode = .idle, .idle_minutes = 30 };
    const cfg = config_types.SessionConfig{
        .reset = base,
        .reset_by_type = .{ .group = group },
    };
    try std.testing.expectEqual(@as(u8, 6), resolvePolicy(cfg, "agent:main:telegram:direct:1").at_hour);
    const group_policy = resolvePolicy(cfg, "agent:main:telegram:group:-1");
    try std.testing.expectEqual(config_types.SessionResetMode.idle, group_policy.mode);
    try std.testing.expectEqual(@as(?u32, 30), group_policy.idle_minutes);
    try std.testing.expectEqual(config_types.SessionResetMode.daily, resolvePolicy(cfg, "agent:main:telegram:group:-1:thread:2").mode);
}

test "isStale: none never resets, even with old timestamps" {
    const policy = config_types.SessionResetConfig{};
    try std.testing.expect(!isStale(policy, 1_000_000_000, 0, 0));
}

test "isStale: daily boundary before and after at_hour" {
    const day: i64 = 86_400;
    const now: i64 = 20_000 * day + 10 * 3600; // 10:00 UTC
    const policy = config_types.SessionResetConfig{ .mode = .daily, .at_hour = 4 };
    // Started 03:00 UTC today: before the boundary -> stale.
    try std.testing.expect(isStale(policy, now, 20_000 * day + 3 * 3600, now));
    // Started 05:00 UTC today: after the boundary -> fresh.
    try std.testing.expect(!isStale(policy, now, 20_000 * day + 5 * 3600, now));
    // Boundary is today 04:00 UTC.
    try std.testing.expectEqual(20_000 * day + 4 * 3600, dailyBoundary(now, 4));
    // Before at_hour the boundary is yesterday's.
    try std.testing.expectEqual(19_999 * day + 4 * 3600, dailyBoundary(20_000 * day + 2 * 3600, 4));
    try std.testing.expectEqual(19_999 * day + 23 * 3600, dailyBoundary(now, 255));
}

test "isStale: idle expiry uses last_active" {
    const policy = config_types.SessionResetConfig{ .mode = .idle, .idle_minutes = 60 };
    const now: i64 = 1_000_000;
    try std.testing.expect(!isStale(policy, now, 0, now - 59 * 60));
    try std.testing.expect(isStale(policy, now, 0, now - 61 * 60));
    // Idle mode without idle_minutes never expires.
    const no_minutes = config_types.SessionResetConfig{ .mode = .idle };
    try std.testing.expect(!isStale(no_minutes, now, 0, 0));
}
