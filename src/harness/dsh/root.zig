//! dsh sidecar Remote API client (P0 spike scaffold).

pub const protocol = @import("protocol.zig");
pub const client = @import("client.zig");
pub const sidecar = @import("sidecar.zig");
pub const profile = @import("profile.zig");
pub const harness = @import("harness.zig");

test {
    _ = @import("protocol.zig");
    _ = @import("client.zig");
    _ = @import("sidecar.zig");
    _ = @import("profile.zig");
    _ = @import("mock.zig");
    _ = @import("mock_test.zig");
    _ = @import("harness.zig");
    _ = @import("harness_test.zig");
}

test "harness_dsh scaffold compiles" {}
