//! Bounded dedupe for user-visible error replies on the daemon dispatch path.
//!
//! The store mirrors `SlackChannel.markInboundSeen`: a flat fixed-size ring
//! with no map and no allocation. Each slot holds a key and its expiry, so the
//! oldest entry is overwritten when the ring fills. Keys combine the outbound
//! chat scope with the classified failure kind, so "the same error" means the
//! same failure class in the same chat, not the same rendered bytes.

const std = @import("std");
const std_compat = @import("compat");
const config_types = @import("config_types.zig");
const error_classify = @import("providers/error_classify.zig");

pub const Decision = enum { send, suppress };

pub const Store = struct {
    pub const CAPACITY: usize = 32;

    const Entry = struct {
        key: u64 = 0,
        expires_at_ms: i64 = 0,
    };

    entries: [CAPACITY]Entry = [_]Entry{.{}} ** CAPACITY,
    next: usize = 0,
    mutex: std_compat.sync.Mutex = .{},

    /// Decide whether an error reply may be sent, recording it when allowed.
    /// `now_ms` is caller-supplied so tests never depend on the wall clock.
    pub fn decide(
        self: *Store,
        policy: config_types.ErrorReplyPolicy,
        key: u64,
        now_ms: i64,
        cooldown_ms: i64,
    ) Decision {
        switch (policy) {
            .always => return .send,
            .silent => return .suppress,
            .once => {},
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const tag = key | 1; // never store 0 so an empty slot stays distinguishable
        for (self.entries) |entry| {
            if (entry.key == tag and now_ms < entry.expires_at_ms) return .suppress;
        }
        self.entries[self.next] = .{ .key = tag, .expires_at_ms = now_ms +| cooldown_ms };
        self.next = (self.next + 1) % CAPACITY;
        return .send;
    }
};

/// Dedupe key: outbound channel + account + chat, then the failure class.
pub fn makeKey(
    channel: []const u8,
    account_id: ?[]const u8,
    chat_id: []const u8,
    kind: error_classify.UserErrorKind,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(channel);
    hasher.update("\x00");
    hasher.update(account_id orelse "");
    hasher.update("\x00");
    hasher.update(chat_id);
    hasher.update("\x00");
    hasher.update(@tagName(kind));
    return hasher.final() | 1;
}

test "error reply policy sends the first error and suppresses repeats within cooldown" {
    // Regression: every failed turn re-sent the same error text with no cooldown or dedupe.
    var store = Store{};
    const key = makeKey("telegram", null, "chat-1", .timeout);
    const cooldown_ms: i64 = 240 * 60_000;

    try std.testing.expectEqual(Decision.send, store.decide(.once, key, 1_000, cooldown_ms));
    try std.testing.expectEqual(Decision.suppress, store.decide(.once, key, 1_001, cooldown_ms));
    try std.testing.expectEqual(Decision.suppress, store.decide(.once, key, 1_000 + cooldown_ms - 1, cooldown_ms));
    // At exactly now+cooldown the window has elapsed.
    try std.testing.expectEqual(Decision.send, store.decide(.once, key, 1_000 + cooldown_ms, cooldown_ms));
}

test "error reply policy passes different failure classes and scopes" {
    // Regression: every failed turn re-sent the same error text with no cooldown or dedupe.
    var store = Store{};
    const timeout = makeKey("telegram", null, "chat-1", .timeout);
    const auth = makeKey("telegram", null, "chat-1", .auth);
    const other_chat = makeKey("telegram", null, "chat-2", .timeout);
    const other_account = makeKey("telegram", "backup", "chat-1", .timeout);
    const cooldown_ms: i64 = 60_000;

    try std.testing.expectEqual(Decision.send, store.decide(.once, timeout, 5_000, cooldown_ms));
    try std.testing.expectEqual(Decision.send, store.decide(.once, auth, 5_000, cooldown_ms));
    try std.testing.expectEqual(Decision.send, store.decide(.once, other_chat, 5_000, cooldown_ms));
    try std.testing.expectEqual(Decision.send, store.decide(.once, other_account, 5_000, cooldown_ms));
    try std.testing.expectEqual(Decision.suppress, store.decide(.once, timeout, 5_001, cooldown_ms));
}

test "error reply policy always and silent ignore the store" {
    var store = Store{};
    const key = makeKey("slack", "main", "C123", .generic);

    try std.testing.expectEqual(Decision.send, store.decide(.always, key, 0, 1_000));
    try std.testing.expectEqual(Decision.send, store.decide(.always, key, 1, 1_000));
    try std.testing.expectEqual(Decision.suppress, store.decide(.silent, key, 2, 1_000));
    try std.testing.expectEqual(Decision.suppress, store.decide(.silent, key, 3, 1_000));
}

test "error reply store overwrites the oldest entry when full" {
    var store = Store{};
    var i: usize = 0;
    // One extra write wraps the ring and overwrites the first key.
    while (i <= Store.CAPACITY) : (i += 1) {
        const key: u64 = @intCast(i * 2 + 1);
        try std.testing.expectEqual(Decision.send, store.decide(.once, key, 0, 1_000));
    }
    // The first key was evicted by the ring, so it is allowed again.
    try std.testing.expectEqual(Decision.send, store.decide(.once, 1, 0, 1_000));
}
