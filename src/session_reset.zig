//! Automatic session reset policy (`session.reset` / `session.reset_by_type`).
//!
//! Mirrors OpenClaw's reset-policy model: the policy is evaluated lazily when a
//! session is next used, not by a timer. Defaults keep the old behavior: with
//! `mode: none` nothing is ever reset automatically.
//!
//! Divergence from OpenClaw: there is no host-local-timezone resolution, so the
//! daily `at_hour` boundary is computed from `agent.timezone` (a fixed offset
//! such as "UTC+08:00", default "UTC"). IANA/DST names are not supported.

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

/// Most recent `at_hour` boundary in UTC epoch seconds.
pub fn dailyBoundary(now: i64, at_hour: u8) i64 {
    const hour: i64 = @min(at_hour, 23);
    const today = @divFloor(now, 86400) * 86400 + hour * 3600;
    return if (now < today) today - 86400 else today;
}

/// Most recent `at_hour` boundary in the given fixed UTC offset, returned as
/// UTC epoch seconds: `dailyBoundary(now + offset, at_hour) - offset`.
pub fn dailyBoundaryAtOffset(now: i64, at_hour: u8, offset_secs: i64) i64 {
    return dailyBoundary(now + offset_secs, at_hour) - offset_secs;
}

/// Whether a session must be reset before serving the next message.
/// `created_at` is the session start (daily), `last_active` the last
/// interaction (idle). `tz_offset_secs` is the configured `agent.timezone`
/// fixed offset applied to the daily boundary.
pub fn isStale(
    policy: config_types.SessionResetConfig,
    now: i64,
    created_at: i64,
    last_active: i64,
    tz_offset_secs: i64,
) bool {
    return switch (policy.mode) {
        .none => false,
        .daily => created_at < dailyBoundaryAtOffset(now, policy.at_hour, tz_offset_secs),
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
    try std.testing.expect(!isStale(policy, 1_000_000_000, 0, 0, 0));
}

test "isStale: daily boundary before and after at_hour" {
    const day: i64 = 86_400;
    const now: i64 = 20_000 * day + 10 * 3600; // 10:00 UTC
    const policy = config_types.SessionResetConfig{ .mode = .daily, .at_hour = 4 };
    // Started 03:00 UTC today: before the boundary -> stale.
    try std.testing.expect(isStale(policy, now, 20_000 * day + 3 * 3600, now, 0));
    // Started 05:00 UTC today: after the boundary -> fresh.
    try std.testing.expect(!isStale(policy, now, 20_000 * day + 5 * 3600, now, 0));
    // Boundary is today 04:00 UTC.
    try std.testing.expectEqual(20_000 * day + 4 * 3600, dailyBoundary(now, 4));
    // Before at_hour the boundary is yesterday's.
    try std.testing.expectEqual(19_999 * day + 4 * 3600, dailyBoundary(20_000 * day + 2 * 3600, 4));
    try std.testing.expectEqual(19_999 * day + 23 * 3600, dailyBoundary(now, 255));
}

test "isStale: idle expiry uses last_active" {
    const policy = config_types.SessionResetConfig{ .mode = .idle, .idle_minutes = 60 };
    const now: i64 = 1_000_000;
    try std.testing.expect(!isStale(policy, now, 0, now - 59 * 60, 0));
    try std.testing.expect(isStale(policy, now, 0, now - 61 * 60, 0));
    // Idle mode without idle_minutes never expires.
    const no_minutes = config_types.SessionResetConfig{ .mode = .idle };
    try std.testing.expect(!isStale(no_minutes, now, 0, 0, 0));
}

test "isStale: daily boundary honors agent.timezone fixed offset" {
    const day: i64 = 86_400;
    // 2026-05-01T00:00:00Z is day 24661; pick 2026-05-01T12:00:00Z as "now".
    const now: i64 = 24_661 * day + 12 * 3600;
    const policy = config_types.SessionResetConfig{ .mode = .daily, .at_hour = 4 };

    // UTC (default): boundary is today 04:00 UTC -> started at 12:00 today is fresh.
    try std.testing.expectEqual(24_661 * day + 4 * 3600, dailyBoundaryAtOffset(now, 4, 0));
    try std.testing.expect(!isStale(policy, now, 24_661 * day + 5 * 3600, now, 0));
    try std.testing.expect(isStale(policy, now, 24_661 * day + 3 * 3600, now, 0));

    // UTC+08:00 (east of UTC): the day runs ahead, so local 04:00 falls at
    // 20:00 UTC on the previous day. A session created at 21:00 UTC yesterday
    // is fresh in that zone but would be reset by UTC reasoning.
    const plus8: i64 = 8 * 3600;
    try std.testing.expectEqual(24_660 * day + 20 * 3600, dailyBoundaryAtOffset(now, 4, plus8));
    try std.testing.expect(!isStale(policy, now, 24_660 * day + 21 * 3600, now, plus8));
    try std.testing.expect(isStale(policy, now, 24_660 * day + 19 * 3600, now, plus8));

    // UTC-05:00 (west of UTC): the day lags, so local 04:00 is 09:00 UTC today.
    // A session created at 08:00 UTC today is already stale in that zone but
    // fresh under UTC reasoning.
    const minus5: i64 = -5 * 3600;
    try std.testing.expectEqual(24_661 * day + 9 * 3600, dailyBoundaryAtOffset(now, 4, minus5));
    try std.testing.expect(!isStale(policy, now, 24_661 * day + 10 * 3600, now, minus5));
    try std.testing.expect(isStale(policy, now, 24_661 * day + 8 * 3600, now, minus5));
}
