//! Recorded model provider for dsh-native harness tests (P0 prototype).
//!
//! A fixture supplies the packed assistant stream for each model call
//! (`test/fixtures/dsh_native/plain-turn/replay.json`). The provider returns
//! that stream verbatim, including its terminal `finish` chunk; it never
//! synthesizes chunks. The driver writes the returned records into
//! `assistant/message.data.stream`.
//!
//! The provider also records each request so a test can compare what the
//! harness would have sent with the fixture's expected surface.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// One model call as seen by the provider.
pub const Request = struct {
    provider: []const u8,
    model: []const u8,
    /// Borrowed from the caller's surface fold; keep the fold alive while
    /// inspecting `recordedRequests()`.
    messages: []const types.Message,
};

const ReplayFile = struct {
    calls: []const Call = &.{},

    const Call = struct {
        index: u64 = 0,
        stream: []const Value = &.{},
    };
};

pub const ReplayProvider = struct {
    arena: std.heap.ArenaAllocator,
    calls: []const ReplayFile.Call,
    next_call: usize = 0,
    requests: std.ArrayListUnmanaged(Request) = .empty,

    /// Parse a replay script. Calls must be numbered 1..N with non-empty
    /// streams; the fixture's first model call is call 1.
    pub fn initFromJson(allocator: Allocator, bytes: []const u8) !ReplayProvider {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const parsed = try std.json.parseFromSliceLeaky(ReplayFile, arena.allocator(), bytes, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        if (parsed.calls.len == 0) return error.InvalidReplay;
        for (parsed.calls, 0..) |call, index| {
            if (call.index != index + 1) return error.InvalidReplay;
            if (call.stream.len == 0) return error.InvalidReplay;
        }

        return .{ .arena = arena, .calls = parsed.calls };
    }

    pub fn deinit(self: *ReplayProvider) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Return the recorded packed stream for the next model call.
    pub fn complete(self: *ReplayProvider, request: Request) ![]const Value {
        if (self.next_call >= self.calls.len) return error.ReplayExhausted;
        try self.requests.append(self.arena.allocator(), request);
        const stream = self.calls[self.next_call].stream;
        self.next_call += 1;
        return stream;
    }

    pub fn recordedRequests(self: *const ReplayProvider) []const Request {
        return self.requests.items;
    }
};

test "replay provider returns recorded streams and records requests" {
    var provider = try ReplayProvider.initFromJson(
        std.testing.allocator,
        \\{"calls":[{"index":1,"stream":[{"type":"text-chunks","time0":0,"index":0,"dt":[],"texts":["hi"]}]}]}
        ,
    );
    defer provider.deinit();

    const request = Request{ .provider = "fake", .model = "fake", .messages = &.{} };
    const stream = try provider.complete(request);
    try std.testing.expectEqual(@as(usize, 1), stream.len);
    try std.testing.expectEqualStrings("text-chunks", stream[0].object.get("type").?.string);

    const requests = provider.recordedRequests();
    try std.testing.expectEqual(@as(usize, 1), requests.len);
    try std.testing.expectEqualStrings("fake", requests[0].provider);

    try std.testing.expectError(error.ReplayExhausted, provider.complete(request));
    try std.testing.expectError(error.InvalidReplay, ReplayProvider.initFromJson(
        std.testing.allocator,
        \\{"calls":[{"index":2,"stream":[{"type":"chunk"}]}]}
        ,
    ));
}
