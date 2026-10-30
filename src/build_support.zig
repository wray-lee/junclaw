//! Pure build-selection helpers shared by build.zig and the host test suite.

const std = @import("std");

pub const DshSpikeLinkage = enum { inherit, static, dynamic };

/// dsh-spike linkage: static musl on Linux so the binary runs in the bare dsh
/// Node image; Android's bionic only ships shared libc, so it must be a
/// dynamic PIE. Other targets keep Zig's default.
pub fn dshSpikeLinkage(os: std.Target.Os.Tag, abi: std.Target.Abi) DshSpikeLinkage {
    _ = abi;
    if (os == .linux) return .static;
    return .inherit;
}

test "dsh-spike links dynamically on Android" {
    // Regression: the Android spike was statically linked and could not run;
    // bionic ships no static libc.
    try std.testing.expectEqual(DshSpikeLinkage.dynamic, dshSpikeLinkage(.linux, .android));
    try std.testing.expectEqual(DshSpikeLinkage.static, dshSpikeLinkage(.linux, .gnu));
    try std.testing.expectEqual(DshSpikeLinkage.inherit, dshSpikeLinkage(.windows, .msvc));
}
