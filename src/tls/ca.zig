//! TLS trust anchors.
//!
//! Android has no `/etc/ssl` tree for `Bundle.rescan` to find, so the Mozilla
//! CA bundle from curl.se is embedded in Android builds and the system/APEX
//! certificate directories are appended as a supplement. All other targets
//! keep the system rescan.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.tls);

pub const TlsCa = union(enum) {
    no_verification,
    bundle: std.crypto.Certificate.Bundle,
};

/// Android system trust stores; both hold one PEM certificate per hashed file.
/// `/apex/com.android.conscrypt/cacerts` is the Android 14+ Conscrypt APEX.
const android_system_ca_dirs = [_][]const u8{
    "/system/etc/security/cacerts",
    "/apex/com.android.conscrypt/cacerts",
};

const begin_marker = "-----BEGIN CERTIFICATE-----";
const end_marker = "-----END CERTIFICATE-----";
const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");

/// Mozilla CA bundle, embedded only in Android binaries.
pub fn embeddedPem() []const u8 {
    if (builtin.abi == .android) return @embedFile("cacert.pem");
    return "";
}

/// Pick the trust anchors for a TLS connection. `abi` and `pem` are parameters
/// so host tests can exercise the Android branch.
///
/// Non-Android keeps the historical WebSocket policy: a failed system scan
/// falls back to no verification. Android never does: an unparseable embedded
/// bundle is an error, because falling back there would silently allow MITM.
pub fn selectSource(
    gpa: Allocator,
    io: Io,
    now: Io.Timestamp,
    abi: std.Target.Abi,
    pem: []const u8,
) !TlsCa {
    if (abi == .android) return .{ .bundle = try androidBundle(gpa, io, now, pem) };
    var bundle = std.crypto.Certificate.Bundle.empty;
    if (bundle.rescan(gpa, io, now)) |_| {
        return .{ .bundle = bundle };
    } else |err| {
        bundle.deinit(gpa);
        log.warn("system CA bundle unavailable, fallback to no verification: {}", .{err});
        return .no_verification;
    }
}

/// Embedded bundle plus best-effort system/APEX supplements. The embedded
/// bundle must contain at least one certificate; supplement failures only warn.
pub fn androidBundle(
    gpa: Allocator,
    io: Io,
    now: Io.Timestamp,
    pem: []const u8,
) !std.crypto.Certificate.Bundle {
    var bundle = std.crypto.Certificate.Bundle.empty;
    errdefer bundle.deinit(gpa);
    if (try addPem(&bundle, gpa, pem, now.toSeconds()) == 0) return error.AndroidCaBundleInvalid;
    for (android_system_ca_dirs) |dir| {
        bundle.addCertsFromDirPathAbsolute(gpa, io, now, dir) catch |err| {
            log.warn("Android system CA supplement {s} unavailable: {}", .{ dir, err });
        };
    }
    return bundle;
}

/// Give a std.http.Client the Android trust anchors instead of letting it
/// rescan the absent system paths on first use. No-op on other targets.
pub fn configureHttpClient(client: *std.http.Client, gpa: Allocator) !void {
    if (builtin.abi != .android) return;
    const now = Io.Timestamp.now(client.io, .real);
    client.ca_bundle = try androidBundle(gpa, client.io, now, embeddedPem());
    client.now = now;
}

/// Parse concatenated PEM certificates into `bundle`, returning how many were
/// added. Mirrors `Certificate.Bundle.addCertsFromFile`, which only accepts a
/// file reader.
pub fn addPem(
    bundle: *std.crypto.Certificate.Bundle,
    gpa: Allocator,
    pem: []const u8,
    now_sec: i64,
) !usize {
    var added: usize = 0;
    var search_from: usize = 0;
    while (std.mem.findPos(u8, pem, search_from, begin_marker)) |begin| {
        const cert_start = begin + begin_marker.len;
        const cert_end = std.mem.findPos(u8, pem, cert_start, end_marker) orelse
            return error.MissingEndCertificateMarker;
        search_from = cert_end + end_marker.len;
        const encoded = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
        const upper_bound = encoded.len / 4 * 3;
        try bundle.bytes.ensureUnusedCapacity(gpa, upper_bound);
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        const dest = bundle.bytes.allocatedSlice()[decoded_start..][0..upper_bound];
        bundle.bytes.items.len += try base64.decode(dest, encoded);
        try bundle.parseCert(gpa, decoded_start, now_sec);
        added += 1;
    }
    return added;
}

const testing = std.testing;
const bundle_pem = @embedFile("cacert.pem");

test "android embedded CA bundle parses more than 100 certificates" {
    var bundle = std.crypto.Certificate.Bundle.empty;
    defer bundle.deinit(testing.allocator);
    const count = try addPem(&bundle, testing.allocator, bundle_pem, 0);
    try testing.expect(count > 100);
}

test "android CA selection never falls back to no_verification" {
    // Regression: Android WebSocket used .no_verification (MITM)
    var ca = try selectSource(
        testing.allocator,
        testing.io,
        Io.Timestamp.now(testing.io, .real),
        .android,
        bundle_pem,
    );
    defer switch (ca) {
        .bundle => |*bundle| bundle.deinit(testing.allocator),
        .no_verification => {},
    };
    try testing.expect(std.meta.activeTag(ca) == .bundle);
}

test "android CA selection fails closed when the embedded bundle is unparseable" {
    // Regression: Android WebSocket used .no_verification (MITM)
    try testing.expectError(error.AndroidCaBundleInvalid, selectSource(
        testing.allocator,
        testing.io,
        Io.Timestamp.now(testing.io, .real),
        .android,
        "not a certificate",
    ));
}
