//! dsh native harness — P0 core (session log + store).
//!
//! Not wired into the runtime yet: these modules are only compiled by tests.
//! See `.scratch/dsh-zig-rewrite-design.md` §3.1 / §4.1 in the junclaw repo.

const std = @import("std");

pub const types = @import("types.zig");
pub const json = @import("json.zig");
pub const session_log = @import("session_log.zig");
pub const session_store = @import("session_store.zig");

/// Session format generation written and read by this build.
pub const SESSION_FORMAT_VERSION: u32 = types.SESSION_FORMAT_VERSION;

test {
    std.testing.refAllDecls(@This());
    _ = @import("types.zig");
    _ = @import("json.zig");
    _ = @import("session_log.zig");
    _ = @import("session_store.zig");
}
