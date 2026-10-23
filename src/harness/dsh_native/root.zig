//! dsh native harness — P0 core (session log + store).
//!
//! Not wired into the runtime yet: these modules are only compiled by tests.
//! See `.scratch/dsh-zig-rewrite-design.md` §3.1 / §4.1 in the junclaw repo.

const std = @import("std");

pub const types = @import("types.zig");
pub const json = @import("json.zig");
pub const session_log = @import("session_log.zig");
pub const session_store = @import("session_store.zig");
pub const surface = @import("surface.zig");
pub const replay_provider = @import("replay_provider.zig");
pub const inbox = @import("inbox.zig");
pub const request = @import("request.zig");
pub const stream = @import("stream.zig");
pub const prompt = @import("prompt.zig");
pub const context = @import("context.zig");
pub const token_meter = @import("token_meter.zig");
pub const compaction = @import("compaction.zig");
pub const approval = @import("approval.zig");
pub const questions = @import("questions.zig");
pub const commands = @import("commands.zig");
pub const loop = @import("loop.zig");
pub const tools_registry = @import("tools/registry.zig");
pub const tools_scheduler = @import("tools/scheduler.zig");
pub const tools_execute = @import("tools/execute.zig");
pub const tools_builtins = @import("tools/builtins.zig");
pub const tools_bash = @import("tools/bash.zig");
pub const tools_ask_user = @import("tools/ask_user.zig");
pub const generated = @import("generated/root.zig");
pub const harness = @import("harness.zig");

/// Session format generation written and read by this build.
pub const SESSION_FORMAT_VERSION: u32 = types.SESSION_FORMAT_VERSION;

test {
    std.testing.refAllDecls(@This());
    _ = @import("types.zig");
    _ = @import("json.zig");
    _ = @import("session_log.zig");
    _ = @import("session_store.zig");
    _ = @import("surface.zig");
    _ = @import("replay_provider.zig");
    _ = @import("inbox.zig");
    _ = @import("request.zig");
    _ = @import("stream.zig");
    _ = @import("prompt.zig");
    _ = @import("context.zig");
    _ = @import("token_meter.zig");
    _ = @import("compaction.zig");
    _ = @import("approval.zig");
    _ = @import("questions.zig");
    _ = @import("commands.zig");
    _ = @import("loop.zig");
    _ = @import("tools/registry.zig");
    _ = @import("tools/scheduler.zig");
    _ = @import("tools/execute.zig");
    _ = @import("tools/builtins.zig");
    _ = @import("tools/bash.zig");
    _ = @import("tools/ask_user.zig");
    _ = @import("generated/root.zig");
    _ = @import("fixture_compare.zig");
    _ = @import("plain_turn_test.zig");
    _ = @import("harness.zig");
    _ = @import("harness_test.zig");
    _ = @import("fixture_replay_test.zig");
}
