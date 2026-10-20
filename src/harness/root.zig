//! Harness-port module: golden-trace tests for the streaming turn path.

const std = @import("std");

pub const test_provider = @import("test_provider.zig");

test {
    std.testing.refAllDecls(@This());
}
