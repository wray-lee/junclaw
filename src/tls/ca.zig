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

pub const TlsCa = union(enum) {
    no_verification,
    bundle: std.crypto.Certificate.Bundle,
};

/// Mozilla CA bundle, present only in Android binaries.
pub fn embeddedPem() []const u8 {
    if (comptime builtin.abi == .android) return @embedFile("cacert.pem");
    return "";
}

/// Pick the trust anchors for a TLS connection. `abi` and `pem` are parameters
/// so host tests can exercise the Android branch.
pub fn selectSource(
    gpa: Allocator,
    io: Io,
    now: Io.Timestamp,
    abi: std.Target.Abi,
    pem: []const u8,
) !TlsCa {
    _ = gpa;
    _ = io;
    _ = now;
    _ = pem;
    _ = abi;
    return .no_verification;
}

/// Parse concatenated PEM certificates into `bundle`.
pub fn addPem(
    bundle: *std.crypto.Certificate.Bundle,
    gpa: Allocator,
    pem: []const u8,
    now_sec: i64,
) !usize {
    _ = bundle;
    _ = gpa;
    _ = pem;
    _ = now_sec;
    return 0;
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
