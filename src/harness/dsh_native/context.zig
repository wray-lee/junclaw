//! Runtime context snapshots and the AGENTS.md instruction baseline
//! (design §3.1 context.zig, B15/B16; dsh `packages/core/agent-loop/src/runtime-context.ts`,
//! `packages/core/system-prompt/src/index.ts`, `packages/context/agent-instructions/src`).
//!
//! Runtime context: model-visible sentences (working directory, sandbox policy,
//! approval policy, harness checkout, web URL) join with the dsh
//! `renderContextSnapshot` framing. The tracker emits one user/message worth of
//! content per changed snapshot, or the fixed "none" text after a snapshot
//! becomes empty (runtime-context.ts:20,152-163).
//!
//! Instructions: dsh's ordered user-global and project-root-to-cwd discovery,
//! trimmed-content dedup, 65536-byte default budget (omit broader files first,
//! then truncate the most specific file), and replacement-baseline bookkeeping.
//! The session layer owns the actual `user/message` event and its
//! `surfaceOp: replace`; this module returns the content plus the seq of the
//! baseline it replaces.
//!
//! The dsh context templates are reproduced here verbatim with source
//! references because `generated/` (P1a codegen) currently emits system-prompt
//! and tool text only. Do not paraphrase them: tests pin the exact bytes.

const std = @import("std");
const compat = @import("compat");
const config_types = @import("../../config_types.zig");
const fs_compat = @import("../../fs_compat.zig");
const bootstrap_mod = @import("../../bootstrap/root.zig");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Runtime context snapshot
// ---------------------------------------------------------------------------

/// dsh runtime-context positions (`CONTEXT_ORDERS`, system-prompt/src/index.ts:174-183).
pub const ContextOrder = struct {
    /// junclaw contributions injected ahead of dsh's own sentences.
    pub const junclaw_memory: i32 = 70;
    pub const junclaw_guides: i32 = 80;
    /// Native memory-tool guidance (memory_store / memory_recall).
    pub const junclaw_memory_tools: i32 = 81;
    /// Native `## Skills` list and the session-armed `## Active Skill Session`.
    pub const junclaw_skills: i32 = 82;
    pub const junclaw_active_skill: i32 = 83;
    /// Native `## Runtime Capabilities` inventory.
    pub const junclaw_capabilities: i32 = 84;
    /// Channel attachment/choice marker guidance shared with the native prompt.
    pub const junclaw_channel_attachments: i32 = 85;
    /// Native `## Safety` policy, shared verbatim with the native prompt.
    pub const junclaw_safety: i32 = 86;
    /// Native conversation-context, group-chat and schedule guidance.
    pub const junclaw_turn_guidance: i32 = 87;
    /// Native `## Runtime` (OS | Model) section.
    pub const junclaw_runtime: i32 = 88;
    pub const current_datetime: i32 = 90;
    pub const working_directory: i32 = 100;
    pub const sandbox_policy: i32 = 110;
    pub const approval_policy: i32 = 115;
    pub const harness_source: i32 = 200;
    pub const web_surface: i32 = 210;
};

/// dsh's fixed clearing text (runtime-context.ts:20).
pub const cleared_text =
    "Current runtime context: none. Earlier runtime-context snapshots no longer apply.";

/// Prefix dsh puts in front of every non-empty snapshot (system-prompt/src/index.ts:317).
pub const snapshot_prefix =
    "Current runtime context. This snapshot supersedes earlier runtime-context snapshots.\n\n";

/// One named runtime-context contribution.
pub const Section = struct {
    name: []const u8,
    order: i32,
    text: []const u8,
};

pub const SandboxMode = enum {
    read_only,
    workspace_write,
    danger_full_access,
};

pub const ApprovalPolicy = enum { ask, never };

/// Build a caller-supplied section (model, environment, startup, capabilities,
/// or any future dsh context contributor).
pub fn customSection(name: []const u8, order: i32, text: []const u8) Section {
    return .{ .name = name, .order = order, .text = text };
}

/// "Current working directory: \"<path>\"." (working-directory/src/index.ts:173).
pub fn workingDirectorySection(allocator: Allocator, cwd: []const u8) !Section {
    return .{
        .name = "working-directory:current",
        .order = ContextOrder.working_directory,
        .text = try quotedLine(allocator, "Current working directory: ", cwd, "."),
    };
}

/// Native's "## Current Date & Time" block as a runtime-context contribution.
/// The caller recomputes it on every pre-step so the model sees the real
/// request time; text matches `Agent.prompt.appendDateTimeSection` (trailing
/// newlines dropped: the snapshot join supplies the separator).
pub fn dateTimeSection(allocator: Allocator, timezone: []const u8, now_secs: i64) !Section {
    const offset_secs_opt = config_types.AgentConfig.parseTimezoneOffsetSeconds(timezone);
    const offset_secs = offset_secs_opt orelse 0;
    const adjusted_ts = now_secs + offset_secs;
    const safe_ts: u64 = if (adjusted_ts < 0) 0 else @intCast(adjusted_ts);

    const tz_label = if (offset_secs_opt != null) timezone else "UTC";
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = safe_ts };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return .{
        .name = "junclaw:date-time",
        .order = ContextOrder.current_datetime,
        .text = try std.fmt.allocPrint(allocator, "## Current Date & Time\n\n{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} {s}", .{
            year_day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            tz_label,
        }),
    };
}

/// File-policy sentence (sandbox-policy/src/index.ts:45-52).
pub fn sandboxPolicySection(
    allocator: Allocator,
    mode: SandboxMode,
    workspace_root: ?[]const u8,
) !Section {
    const text = switch (mode) {
        .read_only =>
        // Verbatim dsh sentence.
        "Current DSH file policy: read-only. Any available operation enforced by the DSH file sandbox cannot modify files in the standing mode. Do not refuse a required modification from this policy alone: try an available tool normally and follow any denial and escalation guidance it returns.",
        .workspace_write => blk: {
            const root = workspace_root orelse return error.MissingWorkspaceRoot;
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(
                allocator,
                "Current DSH file policy: workspace-write. Any available operation enforced by the DSH file sandbox may modify files under the session workspace: ",
            );
            try appendJsonQuoted(&out, allocator, root);
            try out.appendSlice(
                allocator,
                ". Some platform temporary areas may also be writable.",
            );
            break :blk try out.toOwnedSlice(allocator);
        },
        .danger_full_access =>
        // Verbatim dsh sentence.
        "Current DSH file policy: danger-full-access. The DSH file sandbox does not restrict file modifications by available operations.",
    };
    return .{ .name = "sandbox:policy", .order = ContextOrder.sandbox_policy, .text = text };
}

/// Approval-policy sentence (user-approval/src/index.ts:73-75).
pub fn approvalPolicySection(policy: ApprovalPolicy) Section {
    return .{
        .name = "approval:policy",
        .order = ContextOrder.approval_policy,
        .text = switch (policy) {
            .never =>
            // Verbatim dsh sentence.
            "Approval prompts are disabled in this session: actions that require approval are rejected automatically — do not request sandbox escalation (do not set `sandbox_permissions`).",
            .ask =>
            // Verbatim dsh sentence.
            "Approval policy: ask. Operations that require approval may ask through the configured answerers; without an available answerer, the request fails closed.",
        },
    };
}

/// Harness checkout line (harness-dev-context/src/index.ts:151).
pub fn harnessSourceSection(allocator: Allocator, checkout: []const u8) !Section {
    return .{
        .name = "harness:source",
        .order = ContextOrder.harness_source,
        .text = try quotedLine(
            allocator,
            "Current DeepSeek Harness implementation checkout: ",
            checkout,
            ".",
        ),
    };
}

/// Web GUI URL line (harness-dev-context/src/index.ts:163).
pub fn webSurfaceSection(allocator: Allocator, url: []const u8) !Section {
    return .{
        .name = "app:web-surface",
        .order = ContextOrder.web_surface,
        .text = try quotedLine(
            allocator,
            "Current DeepSeek Harness Web GUI URL: ",
            url,
            ".",
        ),
    };
}

/// dsh `joinContextSections`: join non-empty section texts with a blank line and
/// prepend the snapshot sentence; an empty body renders as "".
pub fn joinContextSections(allocator: Allocator, sections: []const Section) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    for (sections, 0..) |section, index| {
        if (index > 0) try out.appendSlice(allocator, "\n\n");
        try out.appendSlice(allocator, section.text);
    }
    if (out.items.len == 0) return allocator.dupe(u8, "");
    var framed: std.ArrayListUnmanaged(u8) = .empty;
    errdefer framed.deinit(allocator);
    try framed.appendSlice(allocator, snapshot_prefix);
    try framed.appendSlice(allocator, out.items);
    return framed.toOwnedSlice(allocator);
}

/// dsh `renderContextSnapshot`: order contributions by position then name,
/// drop empty ones, and join.
pub fn renderContextSnapshot(allocator: Allocator, sections: []const Section) ![]u8 {
    const ordered = try collectSections(allocator, sections);
    defer allocator.free(ordered);
    return joinContextSections(allocator, ordered);
}

/// One retained-snapshot projection, ready for the session layer to log as a
/// user message. `text` and every name/text in `source` belong to `allocator`.
pub const Snapshot = struct {
    text: []u8,
    source: Source,

    pub const Source = union(enum) {
        /// `source={kind:"runtime-context", form:"snapshot", sections}`.
        snapshot: []Section,
        /// `source={kind:"runtime-context"}` with no sections (runtime-context.ts:159-162).
        cleared,
    };

    pub fn deinit(self: *Snapshot, allocator: Allocator) void {
        allocator.free(self.text);
        switch (self.source) {
            .cleared => {},
            .snapshot => |sections| {
                for (sections) |section| {
                    allocator.free(section.name);
                    allocator.free(section.text);
                }
                allocator.free(sections);
            },
        }
    }
};

/// Retains the last snapshot text so an unchanged environment emits nothing
/// (runtime-context.ts:113-163). Owns the retained copy until `deinit`.
pub const SnapshotTracker = struct {
    retained: ?[]u8 = null,

    pub fn deinit(self: *SnapshotTracker, allocator: Allocator) void {
        if (self.retained) |text| allocator.free(text);
        self.retained = null;
    }

    /// Render the current contributions and return a message only when the
    /// snapshot changed. An empty snapshot renders as the fixed clearing text.
    pub fn project(
        self: *SnapshotTracker,
        allocator: Allocator,
        sections: []const Section,
    ) !?Snapshot {
        const rendered = try renderContextSnapshot(allocator, sections);
        const cleared = rendered.len == 0;
        const text = if (cleared) blk: {
            allocator.free(rendered);
            break :blk try allocator.dupe(u8, cleared_text);
        } else rendered;

        if (self.retained) |previous| {
            if (std.mem.eql(u8, previous, text)) {
                allocator.free(text);
                return null;
            }
        }

        const owned_sections: []Section = if (cleared)
            &.{}
        else
            try copySections(allocator, sections);
        errdefer if (!cleared) {
            for (owned_sections) |section| {
                allocator.free(section.name);
                allocator.free(section.text);
            }
            allocator.free(owned_sections);
        };

        const retained_copy = try allocator.dupe(u8, text);
        if (self.retained) |previous| allocator.free(previous);
        self.retained = retained_copy;

        return .{
            .text = text,
            .source = if (cleared) .cleared else .{ .snapshot = owned_sections },
        };
    }
};

fn collectSections(allocator: Allocator, sections: []const Section) ![]Section {
    var ordered: std.ArrayListUnmanaged(Section) = .empty;
    for (sections) |section| {
        if (section.text.len == 0) continue;
        try ordered.append(allocator, section);
    }
    std.mem.sort(Section, ordered.items, {}, sectionLessThan);
    return ordered.toOwnedSlice(allocator);
}

fn copySections(allocator: Allocator, sections: []const Section) ![]Section {
    const ordered = try collectSections(allocator, sections);
    defer allocator.free(ordered);
    const copies = try allocator.alloc(Section, ordered.len);
    var initialized: usize = 0;
    errdefer {
        for (copies[0..initialized]) |section| {
            allocator.free(section.name);
            allocator.free(section.text);
        }
        allocator.free(copies);
    }
    for (ordered, 0..) |section, index| {
        copies[index] = .{
            .name = try allocator.dupe(u8, section.name),
            .order = section.order,
            .text = try allocator.dupe(u8, section.text),
        };
        initialized += 1;
    }
    return copies;
}

fn sectionLessThan(_: void, left: Section, right: Section) bool {
    if (left.order != right.order) return left.order < right.order;
    return std.mem.order(u8, left.name, right.name) == .lt;
}

/// JSON.stringify-compatible string quoting (dsh interpolates paths and URLs
/// into the sentences with `JSON.stringify`).
fn appendJsonQuoted(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    value: []const u8,
) !void {
    try out.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\x08' => try out.appendSlice(allocator, "\\b"),
            '\x0c' => try out.appendSlice(allocator, "\\f"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (byte < 0x20) {
                    const hex = "0123456789abcdef";
                    try out.appendSlice(allocator, &.{
                        '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0x0f],
                    });
                } else {
                    try out.append(allocator, byte);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

fn quotedLine(
    allocator: Allocator,
    prefix: []const u8,
    value: []const u8,
    suffix: []const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(allocator, prefix);
    try appendJsonQuoted(&out, allocator, value);
    try out.appendSlice(allocator, suffix);
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// AGENTS.md instruction baseline
// ---------------------------------------------------------------------------

pub const default_max_bytes: usize = 65_536;
pub const default_max_source_bytes: usize = 1_048_576;

/// dsh render.ts:16-25, verbatim.
pub const instructions_intro =
    "The following workspace instructions may be relevant to your work. " ++
    "Use them as guidance when applicable. More specific instructions take precedence over broader ones. " ++
    "They do not override system, developer, or direct user instructions.";
pub const replacement_intro = "This complete workspace instruction baseline replaces all earlier workspace instruction baselines. " ++
    instructions_intro;
pub const empty_replacement_intro = "This complete workspace instruction baseline replaces all earlier workspace instruction baselines. " ++
    "No workspace instructions are currently active.";
pub const compact_intro =
    "Workspace instructions were omitted or truncated to fit the configured byte budget.";

const system_reminder_open = "<system-reminder>";
const system_reminder_close = "</system-reminder>";
const escaped_system_reminder_close = "<\\/system-reminder>";

const default_root_markers = [_][]const u8{".git"};
const default_file_candidates = [_][]const u8{ "AGENTS.md", "CLAUDE.md" };

pub const Options = struct {
    /// Session working directory; resolved to an absolute path during discovery.
    cwd: []const u8,
    /// `$DSH_HOME`; its `AGENTS.md` loads before project files.
    dsh_home: ?[]const u8 = null,
    /// Shared agents root; its `AGENTS.md` joins the user-global candidate group.
    agents_home: ?[]const u8 = null,
    /// Model-facing labels for the two user-global roots.
    dsh_home_display: []const u8 = "$DSH_HOME",
    agents_home_display: []const u8 = "$AGENTS_HOME",
    /// Explicit project root; otherwise walk up from `cwd` to the first marker.
    project_root: ?[]const u8 = null,
    project_root_markers: []const []const u8 = &default_root_markers,
    /// Ordered same-directory candidates (files.ts:13-15 config defaults).
    instruction_file_candidates: []const []const u8 = &default_file_candidates,
    /// UTF-8 byte cap for the rendered baseline (dsh default 65536).
    max_bytes: usize = default_max_bytes,
    /// Per-file read cap; larger files are ignored (config.ts:13).
    max_source_bytes: usize = default_max_source_bytes,
    /// Native workspace bootstrap provider. When set, the workspace-level
    /// `AGENTS.md` is read through it (memory-backend bootstrap docs) instead
    /// of the file system; ancestor directories keep the file scan.
    bootstrap_provider: ?bootstrap_mod.BootstrapProvider = null,
};

/// One file read during discovery.
const LoadedFile = struct {
    absolute_path: []const u8,
    display_path: []const u8,
    content: []const u8,
    /// Per-directory dedup group: `user-global` for both user-global roots,
    /// otherwise the containing display directory.
    group: []const u8,
};

pub const Truncated = struct {
    display_path: []const u8,
    original_bytes: usize,
    included_bytes: usize,
};

pub const RenderedFile = struct {
    absolute_path: []const u8,
    display_path: []const u8,
    content: []const u8,
};

pub const Omitted = struct {
    absolute_path: []const u8,
    display_path: []const u8,
};

/// A rendered baseline (or replacement baseline) ready to become one
/// `user/message` with `source={kind:"agent-instructions", form:"instructions"}`.
///
/// The struct owns an arena for all of its strings; move it, do not copy it,
/// and call `deinit` once.
pub const Baseline = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8,
    files: []const RenderedFile,
    omitted: []const Omitted,
    truncated: []const Truncated,
    /// SHA-256 over the discovery configuration and every observed file.
    identity: [32]u8,
    /// False for the first baseline; true when this supersedes an earlier one.
    replacement: bool,
    /// Seq of the visible baseline message this replacement supersedes.
    replace_seq: ?u64,

    pub const source_kind = "agent-instructions";
    pub const source_form = "instructions";

    pub fn deinit(self: *Baseline) void {
        self.arena.deinit();
    }
};

/// Rendered baseline step input plus the seq it replaces.
pub fn loadBaseline(allocator: Allocator, options: Options) !?Baseline {
    if (options.max_bytes == 0 or options.max_source_bytes == 0) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const cwd = try compat.fs.path.resolve(a, &.{options.cwd});
    const root = try resolveProjectRoot(a, cwd, options);
    const loaded = try discover(a, options, cwd, root);
    const kept = try dedup(a, loaded);
    if (kept.len == 0) {
        arena.deinit();
        return null;
    }

    const identity = identityFor(options, cwd, root, loaded);
    return @as(?Baseline, try buildBaseline(&arena, options.max_bytes, kept, identity, false, null));
}

/// Tracks baseline identity across turns. A changed file set, changed file
/// bytes, or a newly discovered subdirectory produces a replacement baseline;
/// identical reloads produce nothing.
pub const BaselineTracker = struct {
    identity: ?[32]u8 = null,

    pub fn update(
        self: *BaselineTracker,
        allocator: Allocator,
        options: Options,
        visible_baseline_seq: ?u64,
    ) !?Baseline {
        if (options.max_bytes == 0 or options.max_source_bytes == 0) return null;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const cwd = try compat.fs.path.resolve(a, &.{options.cwd});
        const root = try resolveProjectRoot(a, cwd, options);
        const loaded = try discover(a, options, cwd, root);
        const kept = try dedup(a, loaded);
        const identity = identityFor(options, cwd, root, loaded);

        if (self.identity) |previous| {
            if (std.mem.eql(u8, previous[0..], identity[0..])) {
                arena.deinit();
                return null;
            }
        }

        const replacement = self.identity != null;
        if (kept.len == 0 and !replacement) {
            arena.deinit();
            return null;
        }

        const baseline = try buildBaseline(
            &arena,
            options.max_bytes,
            kept,
            identity,
            replacement,
            if (replacement) visible_baseline_seq else null,
        );
        self.identity = identity;
        return @as(?Baseline, baseline);
    }
};

const RenderPlan = struct {
    text: []u8,
    /// Input files `[start..]` survive as sections.
    start: usize,
    truncated_content: ?[]const u8 = null,
    truncated: ?Truncated = null,
    /// Final compact fallback rendered only a notice/heading, so no file is
    /// semantically represented.
    unrepresented: bool = false,
};

fn buildBaseline(
    arena: *std.heap.ArenaAllocator,
    max_bytes: usize,
    files: []const LoadedFile,
    identity: [32]u8,
    replacement: bool,
    replace_seq: ?u64,
) !Baseline {
    // Every allocation finishes before the arena state is copied into the
    // returned struct (arena red line).
    const allocator = arena.allocator();
    const plan = try planRender(allocator, files, max_bytes, replacement);

    var represented: []RenderedFile = &.{};
    if (!plan.unrepresented) {
        if (plan.truncated) |truncated| {
            if (truncated.included_bytes > 0 or truncated.original_bytes == 0) {
                const file = files[files.len - 1];
                const out = try allocator.alloc(RenderedFile, 1);
                out[0] = .{
                    .absolute_path = file.absolute_path,
                    .display_path = file.display_path,
                    .content = plan.truncated_content.?,
                };
                represented = out;
            }
        } else {
            const out = try allocator.alloc(RenderedFile, files.len - plan.start);
            for (files[plan.start..], 0..) |file, index| {
                out[index] = .{
                    .absolute_path = file.absolute_path,
                    .display_path = file.display_path,
                    .content = file.content,
                };
            }
            represented = out;
        }
    }

    const omitted_end = if (plan.truncated != null) files.len - 1 else plan.start;
    var omitted: []Omitted = &.{};
    if (omitted_end > 0) {
        const out = try allocator.alloc(Omitted, omitted_end);
        for (files[0..omitted_end], 0..) |file, index| {
            out[index] = .{
                .absolute_path = file.absolute_path,
                .display_path = file.display_path,
            };
        }
        omitted = out;
    }

    var truncated_list: []Truncated = &.{};
    if (plan.truncated) |truncated| {
        const out = try allocator.alloc(Truncated, 1);
        out[0] = truncated;
        truncated_list = out;
    }

    return .{
        .arena = arena.*,
        .text = plan.text,
        .files = represented,
        .omitted = omitted,
        .truncated = truncated_list,
        .identity = identity,
        .replacement = replacement,
        .replace_seq = replace_seq,
    };
}

fn planRender(
    allocator: Allocator,
    files: []const LoadedFile,
    max_bytes: usize,
    replacement: bool,
) !RenderPlan {
    const intro = if (replacement)
        (if (files.len == 0) empty_replacement_intro else replacement_intro)
    else
        instructions_intro;

    const full_text = try buildInstructionText(allocator, files, max_bytes, &.{}, null, intro, true);
    if (full_text.len <= max_bytes) {
        return .{ .text = full_text, .start = 0 };
    }
    allocator.free(full_text);

    // Omit broadest files first, then re-render the remaining suffix.
    var start: usize = 1;
    while (start < files.len) : (start += 1) {
        const omitted = try omittedDisplays(allocator, files[0..start]);
        defer allocator.free(omitted);
        const text = try buildInstructionText(
            allocator,
            files[start..],
            max_bytes,
            omitted,
            null,
            intro,
            true,
        );
        if (text.len <= max_bytes) return .{ .text = text, .start = start };
        allocator.free(text);
    }

    // Even the most specific file alone is too large: truncate it. Try the
    // normal intro first, then dsh's shorter compact intro.
    if (files.len == 0) return .{ .text = try allocator.dupe(u8, ""), .start = 0 };

    const most_specific = files[files.len - 1];
    const omitted = try omittedDisplays(allocator, files[0 .. files.len - 1]);
    defer allocator.free(omitted);
    const original_bytes = most_specific.content.len;

    for ([_]bool{ false, true }) |compact| {
        const candidate_intro = if (compact) compact_intro else intro;
        const content = try truncateToFit(
            allocator,
            most_specific,
            max_bytes,
            omitted,
            candidate_intro,
        );
        const truncated = Truncated{
            .display_path = most_specific.display_path,
            .original_bytes = original_bytes,
            .included_bytes = content.len,
        };
        var truncated_list = [_]Truncated{truncated};
        const view = [_]LoadedFile{.{
            .absolute_path = most_specific.absolute_path,
            .display_path = most_specific.display_path,
            .content = content,
            .group = most_specific.group,
        }};
        const text = try buildInstructionText(
            allocator,
            &view,
            max_bytes,
            omitted,
            &truncated_list,
            candidate_intro,
            true,
        );
        if (text.len <= max_bytes) {
            return .{
                .text = text,
                .start = files.len - 1,
                .truncated_content = content,
                .truncated = truncated,
            };
        }
        allocator.free(text);
    }

    // Last resort, verbatim dsh render.ts:392-403: either a notice plus the
    // file heading, or just the notice, without the system-reminder frame.
    const truncated = Truncated{
        .display_path = most_specific.display_path,
        .original_bytes = original_bytes,
        .included_bytes = 0,
    };
    var truncated_list = [_]Truncated{truncated};
    const marker = try markerText(allocator, max_bytes, omitted, &truncated_list);
    defer allocator.free(marker);
    const empty_section = [_]LoadedFile{.{
        .absolute_path = most_specific.absolute_path,
        .display_path = most_specific.display_path,
        .content = "",
        .group = most_specific.group,
    }};
    const heading = try buildUnframedInstructionText(
        allocator,
        &empty_section,
        marker,
        "",
        false,
    );
    if (heading.len <= max_bytes) {
        return .{
            .text = heading,
            .start = files.len - 1,
            .truncated_content = "",
            .truncated = truncated,
            .unrepresented = original_bytes != 0,
        };
    }
    allocator.free(heading);

    if (marker.len <= max_bytes) {
        return .{
            .text = try allocator.dupe(u8, marker),
            .start = files.len - 1,
            .truncated_content = "",
            .truncated = truncated,
            .unrepresented = true,
        };
    }
    return .{
        .text = try allocator.dupe(u8, truncateUtf8(marker, max_bytes)),
        .start = files.len - 1,
        .truncated_content = "",
        .truncated = truncated,
        .unrepresented = true,
    };
}

fn truncateToFit(
    allocator: Allocator,
    file: LoadedFile,
    max_bytes: usize,
    omitted: []const []const u8,
    intro: []const u8,
) ![]const u8 {
    var low: usize = 0;
    var high: usize = file.content.len;
    var best: []const u8 = file.content[0..0];
    while (low <= high) {
        const mid = low + (high - low) / 2;
        const content = truncateUtf8(file.content, mid);
        const truncated = Truncated{
            .display_path = file.display_path,
            .original_bytes = file.content.len,
            .included_bytes = content.len,
        };
        var truncated_list = [_]Truncated{truncated};
        const view = [_]LoadedFile{.{
            .absolute_path = file.absolute_path,
            .display_path = file.display_path,
            .content = content,
            .group = file.group,
        }};
        const text = try buildInstructionText(
            allocator,
            &view,
            max_bytes,
            omitted,
            &truncated_list,
            intro,
            true,
        );
        const fits = text.len <= max_bytes;
        allocator.free(text);
        if (fits) {
            best = content;
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }
    return best;
}

/// dsh render.ts:292-312: the budget marker, omitted list, and truncation
/// record. Empty when nothing was dropped.
fn markerText(
    allocator: Allocator,
    max_bytes: usize,
    omitted: []const []const u8,
    truncated: []const Truncated,
) ![]u8 {
    if (omitted.len == 0 and truncated.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendPrint(&out, allocator, "Workspace instruction budget {d} bytes: ", .{max_bytes});
    if (omitted.len > 0) {
        try out.appendSlice(allocator, "omitted ");
        for (omitted, 0..) |path, index| {
            if (index > 0) try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, path);
        }
    }
    if (truncated.len > 0) {
        if (omitted.len > 0) try out.appendSlice(allocator, "; ");
        try out.appendSlice(allocator, "truncated ");
        for (truncated, 0..) |item, index| {
            if (index > 0) try out.appendSlice(allocator, ", ");
            try appendPrint(&out, allocator, "{s} from {d} to {d} bytes", .{
                item.display_path,
                item.original_bytes,
                item.included_bytes,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn buildInstructionText(
    allocator: Allocator,
    files: []const LoadedFile,
    max_bytes: usize,
    omitted: []const []const u8,
    truncated: ?[]const Truncated,
    intro: []const u8,
    framed: bool,
) ![]u8 {
    const no_truncated = [_]Truncated{};
    const trunc = if (truncated) |items| items else &no_truncated;
    const marker = try markerText(allocator, max_bytes, omitted, trunc);
    defer allocator.free(marker);
    return buildUnframedInstructionText(allocator, files, marker, intro, framed);
}

/// Join non-empty blocks with a blank line, escape the frame close tag, and
/// optionally wrap in the system-reminder frame (render.ts:316-318).
fn buildUnframedInstructionText(
    allocator: Allocator,
    files: []const LoadedFile,
    marker: []const u8,
    intro: []const u8,
    framed: bool,
) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    if (marker.len > 0) try appendBlock(&body, allocator, marker, true);
    if (intro.len > 0) try appendBlock(&body, allocator, intro, true);
    for (files) |file| {
        if (body.items.len > 0) try body.appendSlice(allocator, "\n\n");
        try body.appendSlice(allocator, "Instructions from: ");
        try body.appendSlice(allocator, file.display_path);
        try body.appendSlice(allocator, "\n\n");
        try body.appendSlice(allocator, file.content);
    }
    defer body.deinit(allocator);

    const escaped = try escapeFrameBody(allocator, body.items);
    if (!framed) return escaped;
    defer allocator.free(escaped);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, system_reminder_open);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, escaped);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, system_reminder_close);
    return out.toOwnedSlice(allocator);
}

fn appendBlock(
    body: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    block: []const u8,
    separate: bool,
) !void {
    if (separate and body.items.len > 0) try body.appendSlice(allocator, "\n\n");
    try body.appendSlice(allocator, block);
}

fn appendPrint(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    comptime format: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn escapeFrameBody(allocator: Allocator, body: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, body, system_reminder_close) == null) {
        return allocator.dupe(u8, body);
    }
    const size = std.mem.replacementSize(
        u8,
        body,
        system_reminder_close,
        escaped_system_reminder_close,
    );
    const out = try allocator.alloc(u8, size);
    _ = std.mem.replace(
        u8,
        body,
        system_reminder_close,
        escaped_system_reminder_close,
        out,
    );
    return out;
}

/// dsh truncateUtf8 (render.ts:78-92): never split a UTF-8 code point.
fn truncateUtf8(content: []const u8, max_bytes: usize) []const u8 {
    if (content.len <= max_bytes) return content;
    var end = max_bytes;
    while (end > 0 and (content[end] & 0xc0) == 0x80) end -= 1;
    return content[0..end];
}

fn omittedDisplays(allocator: Allocator, files: []const LoadedFile) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, files.len);
    for (files, 0..) |file, index| out[index] = file.display_path;
    return out;
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

fn resolveProjectRoot(allocator: Allocator, cwd: []const u8, options: Options) ![]u8 {
    if (options.project_root) |explicit| {
        return compat.fs.path.resolve(allocator, &.{explicit});
    }
    var current: []const u8 = cwd;
    while (true) {
        for (options.project_root_markers) |marker| {
            const candidate = try compat.fs.path.join(allocator, &.{ current, marker });
            if (fs_compat.accessPath(candidate, .{})) |_| {
                return allocator.dupe(u8, current);
            } else |_| {}
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    return allocator.dupe(u8, cwd);
}

fn discover(
    allocator: Allocator,
    options: Options,
    cwd: []const u8,
    project_root: []const u8,
) ![]LoadedFile {
    var files: std.ArrayListUnmanaged(LoadedFile) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    if (options.dsh_home) |home| {
        try addUserGlobal(allocator, &files, &seen, home, options.dsh_home_display, options);
    }
    if (options.agents_home) |home| {
        try addUserGlobal(allocator, &files, &seen, home, options.agents_home_display, options);
    }

    const chain = try ancestorChain(allocator, project_root, cwd);
    for (chain) |dir| {
        for (options.instruction_file_candidates) |candidate| {
            const absolute = try compat.fs.path.join(allocator, &.{ dir, candidate });
            if (seen.contains(absolute)) continue;
            const display = try projectDisplayPath(allocator, project_root, absolute);
            const group = std.fs.path.dirname(display) orelse ".";
            // The workspace-level AGENTS.md is the only bootstrap document a
            // memory backend stores; ancestors remain file-only.
            const provider = if (options.bootstrap_provider != null and
                std.mem.eql(u8, dir, cwd) and
                std.mem.eql(u8, candidate, "AGENTS.md"))
                options.bootstrap_provider
            else
                null;
            if (try readCandidate(allocator, absolute, display, group, options.max_source_bytes, provider)) |file| {
                try seen.put(allocator, absolute, {});
                try files.append(allocator, file);
            }
        }
    }
    return files.toOwnedSlice(allocator);
}

fn addUserGlobal(
    allocator: Allocator,
    files: *std.ArrayListUnmanaged(LoadedFile),
    seen: *std.StringHashMapUnmanaged(void),
    home: []const u8,
    display_root: []const u8,
    options: Options,
) !void {
    const absolute = try compat.fs.path.join(allocator, &.{ home, "AGENTS.md" });
    if (seen.contains(absolute)) return;
    const display = try compat.fs.path.join(allocator, &.{ display_root, "AGENTS.md" });
    if (try readCandidate(allocator, absolute, display, "user-global", options.max_source_bytes, null)) |file| {
        try seen.put(allocator, absolute, {});
        try files.append(allocator, file);
    }
}

fn readCandidate(
    allocator: Allocator,
    absolute: []const u8,
    display: []const u8,
    group: []const u8,
    max_source_bytes: usize,
    provider: ?bootstrap_mod.BootstrapProvider,
) !?LoadedFile {
    // `statFile` is one fstatat on POSIX and never opens the path, so a FIFO is
    // rejected before the provider can block reading it. Only the kind is
    // checked here: a DB-backed provider may hold the document while the
    // workspace copy is unusable, and its read is bounded below.
    const disk_stat: ?compat.fs.File.Stat = compat.fs.cwd().statFile(absolute) catch null;
    if (disk_stat) |stat| {
        if (stat.kind != .file) return null;
    }
    if (provider) |bp| {
        // Bootstrap docs live in the memory backend for DB-backed engines
        // (sqlite/postgres/redis); file backends read the same workspace path
        // and fall through to the direct read when the provider has no entry.
        // One extra byte bounds the read and keeps the oversize-skip rule.
        if (bp.load_excerpt(allocator, "AGENTS.md", max_source_bytes +| 1) catch null) |content| {
            if (content.len <= max_source_bytes) return .{
                .absolute_path = absolute,
                .display_path = display,
                .content = content,
                .group = group,
            };
            allocator.free(content);
        }
    }
    const stat = disk_stat orelse return null;
    if (stat.size > max_source_bytes) return null;
    const content = fs_compat.readFileAlloc(
        compat.fs.cwd(),
        allocator,
        absolute,
        max_source_bytes,
    ) catch return null;
    if (content.len > max_source_bytes) return null;
    return .{
        .absolute_path = absolute,
        .display_path = display,
        .content = content,
        .group = group,
    };
}

fn ancestorChain(
    allocator: Allocator,
    project_root: []const u8,
    cwd: []const u8,
) ![]const []const u8 {
    var reversed: std.ArrayListUnmanaged([]const u8) = .empty;
    var current: []const u8 = cwd;
    while (!std.mem.eql(u8, current, project_root)) {
        try reversed.append(allocator, current);
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    try reversed.append(allocator, project_root);
    std.mem.reverse([]const u8, reversed.items);
    return reversed.toOwnedSlice(allocator);
}

fn projectDisplayPath(
    allocator: Allocator,
    project_root: []const u8,
    absolute: []const u8,
) ![]u8 {
    const relative_path = try compat.fs.path.relative(allocator, project_root, absolute);
    const first_end = std.mem.indexOfScalar(u8, relative_path, compat.fs.path.sep) orelse
        relative_path.len;
    const first = relative_path[0..first_end];
    if (std.mem.eql(u8, first, "user-global") or std.mem.eql(u8, first, "agents-global")) {
        return std.fmt.allocPrint(allocator, ".{s}{s}", .{
            compat.fs.path.sep_str,
            relative_path,
        });
    }
    return relative_path;
}

/// Collapse later candidates whose trimmed bytes match an earlier candidate in
/// the same group (files.ts:414-446; digest.ts:24-28). The two user-global
/// roots share one group.
fn dedup(allocator: Allocator, files: []const LoadedFile) ![]LoadedFile {
    var kept: std.ArrayListUnmanaged(LoadedFile) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (files) |file| {
        // shortcut: ASCII whitespace trim; JS trim() also strips Unicode
        // spaces (NBSP, U+FEFF) — upgrade if such content becomes common.
        const trimmed = std.mem.trim(u8, file.content, " \t\r\n\x0b\x0c");
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(trimmed, &digest, .{});
        const key = try allocator.alloc(u8, file.group.len + 1 + digest.len);
        @memcpy(key[0..file.group.len], file.group);
        key[file.group.len] = 0;
        @memcpy(key[file.group.len + 1 ..], &digest);
        if (seen.contains(key)) continue;
        try seen.put(allocator, key, {});
        try kept.append(allocator, file);
    }
    return kept.toOwnedSlice(allocator);
}

/// SHA-256 over the discovery configuration and every observed file. A file
/// change (even one hidden by budgeting) or a newly discovered directory
/// changes the identity and therefore replaces the visible baseline.
fn identityFor(
    options: Options,
    cwd: []const u8,
    project_root: []const u8,
    loaded: []const LoadedFile,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("dsh-native-agent-instructions-v1");
    hashField(&hasher, cwd);
    hashField(&hasher, project_root);
    hashField(&hasher, options.dsh_home orelse "");
    hashField(&hasher, options.agents_home orelse "");
    hashField(&hasher, options.dsh_home_display);
    hashField(&hasher, options.agents_home_display);
    var budget: [8]u8 = undefined;
    std.mem.writeInt(u64, &budget, options.max_bytes, .little);
    hasher.update(&budget);
    std.mem.writeInt(u64, &budget, options.max_source_bytes, .little);
    hasher.update(&budget);
    for (options.project_root_markers) |marker| hashField(&hasher, marker);
    for (options.instruction_file_candidates) |candidate| hashField(&hasher, candidate);
    for (loaded) |file| {
        hashField(&hasher, file.absolute_path);
        hashField(&hasher, file.content);
    }
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .little);
    hasher.update(&length);
    hasher.update(value);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestTree = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    allocator: Allocator,

    fn init(allocator: Allocator) !TestTree {
        const tmp = std.testing.tmpDir(.{});
        const root = try compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
        return .{ .tmp = tmp, .root = root, .allocator = allocator };
    }

    fn deinit(self: *TestTree) void {
        self.tmp.cleanup();
    }

    fn write(self: *TestTree, parts: []const []const u8, content: []const u8) !void {
        const relative_path = try compat.fs.path.join(self.allocator, parts);
        const absolute = try compat.fs.path.join(self.allocator, &.{ self.root, relative_path });
        if (std.fs.path.dirname(absolute)) |dir| try fs_compat.makePath(dir);
        const file = try fs_compat.createPath(absolute, .{});
        defer file.close();
        try file.writeAll(content);
    }

    fn remove(self: *TestTree, parts: []const []const u8) !void {
        const relative_path = try compat.fs.path.join(self.allocator, parts);
        const absolute = try compat.fs.path.join(self.allocator, &.{ self.root, relative_path });
        try compat.fs.cwd().deleteFile(absolute);
    }

    fn path(self: *TestTree, parts: []const []const u8) ![]u8 {
        const relative_path = try compat.fs.path.join(self.allocator, parts);
        return compat.fs.path.join(self.allocator, &.{ self.root, relative_path });
    }
};

test "runtime context snapshot joins ordered sections with dsh framing" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try workingDirectorySection(a, "/work/a b");
    try std.testing.expectEqualStrings(
        "Current working directory: \"/work/a b\".",
        cwd.text,
    );
    const sandbox = try sandboxPolicySection(a, .workspace_write, "/work/a b");
    try std.testing.expectStringEndsWith(sandbox.text, "session workspace: \"/work/a b\". Some platform temporary areas may also be writable.");
    const approval = approvalPolicySection(.ask);

    const utc = try dateTimeSection(a, "UTC", 1_700_000_000);
    try std.testing.expectEqualStrings("## Current Date & Time\n\n2023-11-14 22:13 UTC", utc.text);
    const shifted = try dateTimeSection(a, "UTC+08:00", 1_700_000_000);
    try std.testing.expectEqualStrings("## Current Date & Time\n\n2023-11-15 06:13 UTC+08:00", shifted.text);
    // A malformed timezone falls back to UTC, like the native prompt.
    const invalid = try dateTimeSection(a, "Asia/Shanghai", 1_700_000_000);
    try std.testing.expectEqualStrings("## Current Date & Time\n\n2023-11-14 22:13 UTC", invalid.text);

    // Deliberately out of order: cwd (100), sandbox (110), approval (115).
    var sections = [_]Section{ approval, sandbox, cwd, customSection("empty", 105, "") };
    const text = try renderContextSnapshot(a, &sections);
    try std.testing.expectEqualStrings(
        "Current runtime context. This snapshot supersedes earlier runtime-context snapshots.\n\n" ++
            "Current working directory: \"/work/a b\".\n\n" ++
            "Current DSH file policy: workspace-write. Any available operation enforced by the DSH file sandbox may modify files under the session workspace: \"/work/a b\". Some platform temporary areas may also be writable.\n\n" ++
            "Approval policy: ask. Operations that require approval may ask through the configured answerers; without an available answerer, the request fails closed.",
        text,
    );

    // Sections with equal order sort by name; joinContextSections preserves input order.
    var tied = [_]Section{
        customSection("b", 1, "second"),
        customSection("a", 1, "first"),
    };
    try std.testing.expectEqualStrings(
        "Current runtime context. This snapshot supersedes earlier runtime-context snapshots.\n\nfirst\n\nsecond",
        try renderContextSnapshot(a, &tied),
    );
    try std.testing.expectEqualStrings("", try joinContextSections(a, &.{}));
    try std.testing.expectEqualStrings("", try renderContextSnapshot(a, &.{}));
}

test "runtime context tracker emits once per change and clears with the fixed text" {
    const allocator = std.testing.allocator;
    var tracker = SnapshotTracker{};
    defer tracker.deinit(allocator);

    const initial = [_]Section{approvalPolicySection(.ask)};
    var first = (try tracker.project(allocator, &initial)).?;
    defer first.deinit(allocator);
    try std.testing.expect(first.source == .snapshot);
    try std.testing.expectEqualStrings("approval:policy", first.source.snapshot[0].name);

    try std.testing.expect((try tracker.project(allocator, &initial)) == null);

    const changed = [_]Section{approvalPolicySection(.never)};
    var second = (try tracker.project(allocator, &changed)).?;
    defer second.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, second.text, "Approval prompts are disabled") != null);

    const empty = [_]Section{customSection("empty", 1, "")};
    var cleared = (try tracker.project(allocator, &empty)).?;
    defer cleared.deinit(allocator);
    try std.testing.expect(cleared.source == .cleared);
    try std.testing.expectEqualStrings(cleared_text, cleared.text);
    try std.testing.expect((try tracker.project(allocator, &empty)) == null);

    var restored = (try tracker.project(allocator, &initial)).?;
    defer restored.deinit(allocator);
    try std.testing.expect(restored.source == .snapshot);
}

test "runtime context renders paths over 64 KiB without leaking" {
    const allocator = std.testing.allocator;
    const long_path = try allocator.alloc(u8, 70_000);
    defer allocator.free(long_path);
    @memset(long_path, 'p');

    const section = try workingDirectorySection(allocator, long_path);
    defer allocator.free(section.text);
    try std.testing.expect(section.text.len > 70_000);

    const text = try renderContextSnapshot(allocator, &.{section});
    defer allocator.free(text);
    try std.testing.expect(text.len > 70_000);
}

test "AGENTS.md baseline discovers root-to-cwd chain with spaces and CLAUDE compatibility" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();

    try tree.write(&.{".git"}, "");
    try tree.write(&.{"AGENTS.md"}, "root rules");
    try tree.write(&.{ "sub dir", "AGENTS.md" }, "sub rules");
    try tree.write(&.{ "sub dir", "CLAUDE.md" }, "claude rules");
    try tree.write(&.{ "sub dir", "deep", "AGENTS.md" }, "deep rules");

    var baseline = (try loadBaseline(a, .{
        .cwd = try tree.path(&.{ "sub dir", "deep" }),
    })).?;
    defer baseline.deinit();

    try std.testing.expect(!baseline.replacement);
    try std.testing.expectEqual(@as(?u64, null), baseline.replace_seq);
    try std.testing.expectEqual(@as(usize, 4), baseline.files.len);
    try std.testing.expectEqualStrings("AGENTS.md", baseline.files[0].display_path);
    try std.testing.expectEqualStrings(
        try compat.fs.path.join(a, &.{ "sub dir", "AGENTS.md" }),
        baseline.files[1].display_path,
    );
    try std.testing.expectEqualStrings(
        try compat.fs.path.join(a, &.{ "sub dir", "CLAUDE.md" }),
        baseline.files[2].display_path,
    );
    try std.testing.expectEqualStrings(
        try compat.fs.path.join(a, &.{ "sub dir", "deep", "AGENTS.md" }),
        baseline.files[3].display_path,
    );

    try std.testing.expectStringStartsWith(baseline.text, "<system-reminder>\n");
    try std.testing.expectStringEndsWith(baseline.text, "\n</system-reminder>");
    try std.testing.expect(std.mem.indexOf(u8, baseline.text, instructions_intro) != null);
    try std.testing.expect(std.mem.indexOf(u8, baseline.text, "Instructions from: AGENTS.md\n\nroot rules") != null);
    try std.testing.expect(std.mem.indexOf(u8, baseline.text, "Instructions from: sub dir" ++ compat.fs.path.sep_str ++ "deep" ++ compat.fs.path.sep_str ++ "AGENTS.md\n\ndeep rules") != null);
}

test "AGENTS.md baseline loads DSH_HOME and agents home, and dedups shared content" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();

    try tree.write(&.{".git"}, "");
    try tree.write(&.{"AGENTS.md"}, "shared global\n");
    try tree.write(&.{ "agents home", "AGENTS.md" }, "shared global\n");
    try tree.write(&.{ "project", "AGENTS.md" }, "project");
    try tree.write(&.{ "project", "CLAUDE.md" }, "project");

    var baseline = (try loadBaseline(a, .{
        .cwd = try tree.path(&.{"project"}),
        .dsh_home = tree.root,
        .agents_home = try tree.path(&.{"agents home"}),
        .dsh_home_display = "$DSH_HOME",
        .agents_home_display = "$AGENTS_HOME",
    })).?;
    defer baseline.deinit();

    try std.testing.expectEqual(@as(usize, 2), baseline.files.len);
    const home_display = try compat.fs.path.join(a, &.{ "$DSH_HOME", "AGENTS.md" });
    try std.testing.expectEqualStrings(home_display, baseline.files[0].display_path);
    try std.testing.expectEqualStrings("shared global\n", baseline.files[0].content);
    try std.testing.expectEqualStrings(
        try compat.fs.path.join(a, &.{ "project", "AGENTS.md" }),
        baseline.files[1].display_path,
    );
    try std.testing.expectEqualStrings("project", baseline.files[1].content);
}

test "AGENTS.md budget omits broader files first" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();

    try tree.write(&.{".git"}, "");
    const broad = try a.alloc(u8, 600);
    @memset(broad, 'b');
    try tree.write(&.{"AGENTS.md"}, broad);
    const specific = try a.alloc(u8, 120);
    @memset(specific, 's');
    try tree.write(&.{ "nested", "AGENTS.md" }, specific);

    var baseline = (try loadBaseline(a, .{
        .cwd = try tree.path(&.{"nested"}),
        .max_bytes = 1024,
    })).?;
    defer baseline.deinit();

    try std.testing.expectEqual(@as(usize, 1), baseline.omitted.len);
    try std.testing.expectEqualStrings("AGENTS.md", baseline.omitted[0].display_path);
    try std.testing.expectEqual(@as(usize, 0), baseline.truncated.len);
    try std.testing.expectEqual(@as(usize, 1), baseline.files.len);
    try std.testing.expect(std.mem.indexOf(u8, baseline.text, "omitted AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, baseline.text, "nested" ++ compat.fs.path.sep_str ++ "AGENTS.md") != null);
    try std.testing.expect(baseline.text.len <= 1024);
}

test "AGENTS.md budget truncates the most specific file on a UTF-8 boundary" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();

    try tree.write(&.{".git"}, "");
    var content: std.ArrayListUnmanaged(u8) = .empty;
    // Three-byte code points make a mid-character cut visible.
    for (0..30_000) |_| try content.appendSlice(a, "éa");
    try tree.write(&.{"AGENTS.md"}, content.items);

    var baseline = (try loadBaseline(a, .{ .cwd = tree.root })).?;
    defer baseline.deinit();

    try std.testing.expectEqual(@as(usize, 1), baseline.truncated.len);
    const record = baseline.truncated[0];
    try std.testing.expectEqual(content.items.len, record.original_bytes);
    try std.testing.expect(record.included_bytes > 0);
    try std.testing.expect(record.included_bytes < record.original_bytes);
    try std.testing.expect(baseline.text.len <= default_max_bytes);
    try std.testing.expect(std.mem.indexOf(u8, baseline.text, "truncated AGENTS.md from") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(baseline.files[0].content));
    try std.testing.expectStringEndsWith(baseline.text, "\n</system-reminder>");
}

test "AGENTS.md source larger than maxSourceBytes is ignored" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();

    try tree.write(&.{".git"}, "");
    try tree.write(&.{"AGENTS.md"}, "0123456789");
    try tree.write(&.{ "nested", "AGENTS.md" }, "ok");

    var baseline = (try loadBaseline(a, .{
        .cwd = try tree.path(&.{"nested"}),
        .max_source_bytes = 5,
    })).?;
    defer baseline.deinit();
    // The 10-byte root file is skipped; the 2-byte nested file survives.
    try std.testing.expectEqual(@as(usize, 1), baseline.files.len);
    try std.testing.expectEqualStrings("ok", baseline.files[0].content);
    try std.testing.expectEqual(@as(usize, 0), baseline.omitted.len);
}

test "AGENTS.md baseline escapes closing system-reminder tags in content" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();

    try tree.write(&.{".git"}, "");
    try tree.write(&.{"AGENTS.md"}, "before </system-reminder> after");

    var baseline = (try loadBaseline(a, .{ .cwd = tree.root })).?;
    defer baseline.deinit();

    try std.testing.expect(std.mem.indexOf(u8, baseline.text, "<\\/system-reminder>") != null);
    const occurrences = std.mem.count(u8, baseline.text, system_reminder_close);
    try std.testing.expectEqual(@as(usize, 1), occurrences);
}

test "baseline tracker emits a replacement baseline with the replaced seq" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();

    try tree.write(&.{".git"}, "");
    try tree.write(&.{"AGENTS.md"}, "first version");
    try tree.write(&.{ "nested", "AGENTS.md" }, "nested rules");

    var tracker = BaselineTracker{};
    const cwd = try tree.path(&.{"nested"});
    var first = (try tracker.update(a, .{ .cwd = cwd }, null)).?;
    defer first.deinit();
    try std.testing.expect(!first.replacement);
    try std.testing.expect(std.mem.indexOf(u8, first.text, instructions_intro) != null);

    // Same files, same bytes: no message.
    try std.testing.expect((try tracker.update(a, .{ .cwd = cwd }, 9)) == null);

    // Changed file bytes: full replacement baseline replacing seq 9.
    try tree.write(&.{"AGENTS.md"}, "second version");
    var second = (try tracker.update(a, .{ .cwd = cwd }, 9)).?;
    defer second.deinit();
    try std.testing.expect(second.replacement);
    try std.testing.expectEqual(@as(?u64, 9), second.replace_seq);
    try std.testing.expect(std.mem.indexOf(u8, second.text, replacement_intro) != null);
    try std.testing.expect(std.mem.indexOf(u8, second.text, "second version") != null);

    // A deeper cwd discovers a new file and replaces again.
    try tree.write(&.{ "nested", "deeper", "AGENTS.md" }, "deeper rules");
    var third = (try tracker.update(a, .{
        .cwd = try tree.path(&.{ "nested", "deeper" }),
    }, 12)).?;
    defer third.deinit();
    try std.testing.expect(third.replacement);
    try std.testing.expectEqual(@as(?u64, 12), third.replace_seq);
    try std.testing.expect(std.mem.indexOf(u8, third.text, "deeper rules") != null);

    // All files gone: the empty replacement baseline still explains the reset.
    try tree.remove(&.{"AGENTS.md"});
    try tree.remove(&.{ "nested", "AGENTS.md" });
    try tree.remove(&.{ "nested", "deeper", "AGENTS.md" });
    var empty = (try tracker.update(a, .{
        .cwd = try tree.path(&.{ "nested", "deeper" }),
    }, 15)).?;
    defer empty.deinit();
    try std.testing.expect(empty.replacement);
    try std.testing.expectEqual(@as(?u64, 15), empty.replace_seq);
    try std.testing.expectEqualStrings(
        empty_replacement_intro,
        empty.text[sysrem_prefix_len .. empty.text.len - sysrem_suffix_len],
    );
    try std.testing.expectEqual(@as(usize, 0), empty.files.len);
}

const sysrem_prefix_len = "<system-reminder>\n".len;
const sysrem_suffix_len = "\n</system-reminder>".len;

test "AGENTS.md baseline over 64 KiB frees cleanly" {
    const allocator = std.testing.allocator;
    var input_arena = std.heap.ArenaAllocator.init(allocator);
    defer input_arena.deinit();
    const content = try input_arena.allocator().alloc(u8, 70_000);
    @memset(content, 'x');

    var tree = try TestTree.init(input_arena.allocator());
    defer tree.deinit();
    try tree.write(&.{".git"}, "");
    try tree.write(&.{"AGENTS.md"}, content);

    var baseline = (try loadBaseline(allocator, .{ .cwd = tree.root })).?;
    defer baseline.deinit();
    try std.testing.expect(baseline.text.len <= default_max_bytes);
    try std.testing.expectEqual(@as(usize, 1), baseline.truncated.len);
}
