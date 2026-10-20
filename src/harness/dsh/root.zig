//! dsh sidecar Remote API client (P0 spike scaffold).

pub const protocol = @import("protocol.zig");
pub const client = @import("client.zig");
pub const sidecar = @import("sidecar.zig");

test {
    _ = @import("protocol.zig");
    _ = @import("client.zig");
    _ = @import("sidecar.zig");
}

test "harness_dsh scaffold compiles" {}
