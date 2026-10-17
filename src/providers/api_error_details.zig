const std = @import("std");

const MAX_PROVIDER_BYTES: usize = 64;
const MAX_DETAIL_BYTES: usize = 2048;

// Regression: this snapshot was process-global, so a concurrent session on
// another thread could overwrite this turn's detail between the provider
// failure and the channel building the reply (a timeout could be shown as a
// rate limit, or vice versa). Provider calls are synchronous on the turn's
// thread and the detail is read there, so keep it per-thread, exactly like the
// retry counters in reliable.zig.
threadlocal var last_provider_buf: [MAX_PROVIDER_BYTES]u8 = undefined;
threadlocal var last_provider_len: usize = 0;
threadlocal var last_detail_buf: [MAX_DETAIL_BYTES]u8 = undefined;
threadlocal var last_detail_len: usize = 0;

fn copyTrimmedBounded(dst: []u8, src: []const u8) usize {
    const trimmed = std.mem.trim(u8, src, " \t\r\n");
    const n = @min(dst.len, trimmed.len);
    if (n == 0) return 0;
    @memcpy(dst[0..n], trimmed[0..n]);
    return n;
}

/// Clear this thread's last provider API error detail.
pub fn clear() void {
    last_provider_len = 0;
    last_detail_len = 0;
}

/// Record the last provider API error detail (best-effort, truncated).
pub fn set(provider_name: []const u8, detail: []const u8) void {
    last_provider_len = copyTrimmedBounded(&last_provider_buf, provider_name);
    last_detail_len = copyTrimmedBounded(&last_detail_buf, detail);
}

/// Copy the last recorded provider API error into `buf` without allocating.
/// Format: "<provider>: <detail>" or just "<detail>" when provider is empty.
/// The copy is bounded by `buf.len`; classification only needs the prefix.
pub fn snapshotInto(buf: []u8) ?[]const u8 {
    if (last_detail_len == 0 or buf.len == 0) return null;

    var idx: usize = 0;
    if (last_provider_len > 0) {
        const provider = last_provider_buf[0..last_provider_len];
        const n = @min(buf.len, provider.len);
        @memcpy(buf[0..n], provider[0..n]);
        idx = n;
        if (idx < buf.len) {
            buf[idx] = ':';
            idx += 1;
        }
        if (idx < buf.len) {
            buf[idx] = ' ';
            idx += 1;
        }
    }
    if (idx < buf.len) {
        const detail = last_detail_buf[0..last_detail_len];
        const n = @min(buf.len - idx, detail.len);
        @memcpy(buf[idx .. idx + n], detail[0..n]);
        idx += n;
    }
    return buf[0..idx];
}

/// Return a heap-owned snapshot of the last recorded provider API error.
/// Format: "<provider>: <detail>" or just "<detail>" when provider is empty.
pub fn snapshot(allocator: std.mem.Allocator) !?[]u8 {
    if (last_detail_len == 0) return null;

    const detail = last_detail_buf[0..last_detail_len];
    if (last_provider_len == 0) {
        return try allocator.dupe(u8, detail);
    }

    const provider = last_provider_buf[0..last_provider_len];
    return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ provider, detail });
}

test "api error detail set snapshot clear" {
    clear();
    try std.testing.expect((try snapshot(std.testing.allocator)) == null);

    set("gemini", "status=503 message=high demand");
    const snap = (try snapshot(std.testing.allocator)).?;
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("gemini: status=503 message=high demand", snap);

    clear();
    try std.testing.expect((try snapshot(std.testing.allocator)) == null);
}

test "api error detail truncates oversized provider and detail" {
    clear();

    var provider_buf: [MAX_PROVIDER_BYTES + 20]u8 = undefined;
    @memset(&provider_buf, 'p');
    var detail_buf: [MAX_DETAIL_BYTES + 50]u8 = undefined;
    @memset(&detail_buf, 'd');

    set(&provider_buf, &detail_buf);
    const snap = (try snapshot(std.testing.allocator)).?;
    defer std.testing.allocator.free(snap);

    try std.testing.expect(snap.len > 0);
    try std.testing.expect(snap.len <= MAX_PROVIDER_BYTES + 2 + MAX_DETAIL_BYTES);
}

test "api error detail snapshotInto matches snapshot without allocating" {
    clear();
    var buf: [128]u8 = undefined;
    try std.testing.expect(snapshotInto(buf[0..0]) == null);

    set("gemini", "status=503 message=high demand");
    const snap = snapshotInto(&buf).?;
    try std.testing.expectEqualStrings("gemini: status=503 message=high demand", snap);

    // A short buffer keeps the provider prefix so classification still works.
    var tiny: [7]u8 = undefined;
    try std.testing.expectEqualStrings("gemini:", snapshotInto(&tiny).?);

    clear();
    try std.testing.expect(snapshotInto(&buf) == null);
}

test "api error detail is isolated per thread" {
    const Writer = struct {
        fn run() void {
            set("other", "status=503 message=overloaded");
        }
    };

    clear();
    defer clear();
    set("main", "status=408 message=request timed out");

    const thread = try std.Thread.spawn(.{}, Writer.run, .{});
    thread.join();

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "main: status=408 message=request timed out",
        snapshotInto(&buf).?,
    );
}
