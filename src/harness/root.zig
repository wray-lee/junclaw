//! Harness-port module: the turn port, its native adapter, and the golden
//! traces that prove the adapter is behavior-identical to the direct path.

const std = @import("std");

pub const port = @import("port.zig");
pub const native = @import("native.zig");
pub const test_provider = @import("test_provider.zig");

test {
    std.testing.refAllDecls(@This());
}
