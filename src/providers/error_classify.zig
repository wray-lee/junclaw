const std = @import("std");
const api_error_details = @import("api_error_details.zig");
const text_helpers = @import("text_helpers.zig");

pub const ApiErrorKind = enum {
    rate_limited,
    context_exhausted,
    vision_unsupported,
    other,
};

pub fn kindToError(kind: ApiErrorKind) anyerror {
    return switch (kind) {
        .rate_limited => error.RateLimited,
        .context_exhausted => error.ContextLengthExceeded,
        .vision_unsupported => error.ProviderDoesNotSupportVision,
        .other => error.ApiError,
    };
}

fn lookupMessageField(obj: anytype) ?[]const u8 {
    if (obj.get("message")) |value| {
        if (value == .string) return value.string;
    }
    if (obj.get("msg")) |value| {
        if (value == .string) return value.string;
    }
    return null;
}

fn parseStatusCode(value: std.json.Value) ?u16 {
    return switch (value) {
        .integer => |i| blk: {
            if (i < 0 or i > std.math.maxInt(u16)) break :blk null;
            break :blk @intCast(i);
        },
        .string => |s| std.fmt.parseInt(u16, std.mem.trim(u8, s, " \t\r\n"), 10) catch null,
        else => null,
    };
}

fn extractErrorFields(root_obj: anytype) ?struct {
    status: ?u16,
    code: ?[]const u8,
    type_name: ?[]const u8,
    message: ?[]const u8,
} {
    var status: ?u16 = null;
    var code: ?[]const u8 = null;
    var type_name: ?[]const u8 = null;
    var message: ?[]const u8 = null;
    var has_error_signal = false;

    if (root_obj.get("error")) |err_value| {
        has_error_signal = true;
        if (err_value == .string) {
            message = err_value.string;
        } else if (err_value == .object) {
            const err_obj = err_value.object;

            if (err_obj.get("status")) |v| {
                status = parseStatusCode(v);
            }

            if (err_obj.get("code")) |v| {
                switch (v) {
                    .string => |s| {
                        code = s;
                        if (status == null) status = parseStatusCode(v);
                    },
                    .integer => {
                        if (status == null) status = parseStatusCode(v);
                    },
                    else => {},
                }
            }

            if (err_obj.get("type")) |v| {
                if (v == .string) type_name = v.string;
            }
            if (message == null) message = lookupMessageField(err_obj);
        }
    }

    if (message == null) message = lookupMessageField(root_obj);

    if (status == null) {
        if (root_obj.get("status")) |v| {
            status = parseStatusCode(v);
            if (status != null) has_error_signal = true;
        }
    }

    if (code == null) {
        if (root_obj.get("code")) |v| {
            has_error_signal = true;
            switch (v) {
                .string => |s| code = s,
                .integer => {
                    if (status == null) status = parseStatusCode(v);
                },
                else => {},
            }
        }
    }

    if (type_name == null) {
        if (root_obj.get("type")) |v| {
            if (v == .string) {
                type_name = v.string;
                if (text_helpers.containsAsciiFold(v.string, "error")) has_error_signal = true;
            }
        }
    }

    if (!has_error_signal and message == null and status == null and code == null and type_name == null) {
        return null;
    }

    return .{
        .status = status,
        .code = code,
        .type_name = type_name,
        .message = message,
    };
}

fn appendBounded(out: []u8, idx: *usize, text: []const u8) void {
    if (text.len == 0 or idx.* >= out.len) return;
    const n = @min(out.len - idx.*, text.len);
    @memcpy(out[idx.* .. idx.* + n], text[0..n]);
    idx.* += n;
}

fn appendFieldPrefix(out: []u8, idx: *usize, wrote_any: *bool, name: []const u8) void {
    if (wrote_any.*) appendBounded(out, idx, " ");
    appendBounded(out, idx, name);
    appendBounded(out, idx, "=");
    wrote_any.* = true;
}

fn appendMessageValue(out: []u8, idx: *usize, raw: []const u8) void {
    for (raw) |c| {
        if (idx.* >= out.len) break;
        out[idx.*] = switch (c) {
            '\r', '\n', '\t' => ' ',
            else => c,
        };
        idx.* += 1;
    }
}

/// Build a compact summary for known provider API errors.
/// Returns null when the payload does not look like an error envelope.
pub fn summarizeKnownApiError(root_obj: anytype, out: []u8) ?[]const u8 {
    if (out.len == 0) return null;
    const fields = extractErrorFields(root_obj) orelse return null;

    var idx: usize = 0;
    var wrote_any = false;

    if (fields.status) |status| {
        appendFieldPrefix(out, &idx, &wrote_any, "status");
        var status_buf: [16]u8 = undefined;
        const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{status}) catch "0";
        appendBounded(out, &idx, status_str);
    }
    if (fields.code) |code| {
        appendFieldPrefix(out, &idx, &wrote_any, "code");
        appendBounded(out, &idx, std.mem.trim(u8, code, " \t\r\n"));
    }
    if (fields.type_name) |type_name| {
        appendFieldPrefix(out, &idx, &wrote_any, "type");
        appendBounded(out, &idx, std.mem.trim(u8, type_name, " \t\r\n"));
    }
    if (fields.message) |message| {
        appendFieldPrefix(out, &idx, &wrote_any, "message");
        appendMessageValue(out, &idx, std.mem.trim(u8, message, " \t\r\n"));
    }

    if (!wrote_any or idx == 0) return null;
    return out[0..idx];
}

fn classifyFromFields(
    status: ?u16,
    code: ?[]const u8,
    type_name: ?[]const u8,
    message: ?[]const u8,
) ApiErrorKind {
    if (status) |status_code| {
        if (status_code == 429 or status_code == 408) return .rate_limited;
        if (status_code == 413) return .context_exhausted;
    }

    if (message) |msg| {
        if (text_helpers.isRateLimitedText(msg)) return .rate_limited;
        if (text_helpers.isContextExhaustedText(msg)) return .context_exhausted;
        if (text_helpers.isVisionUnsupportedText(msg)) return .vision_unsupported;
    }
    if (type_name) |typ| {
        if (text_helpers.isRateLimitedText(typ)) return .rate_limited;
        if (text_helpers.isContextExhaustedText(typ)) return .context_exhausted;
        if (text_helpers.isVisionUnsupportedText(typ)) return .vision_unsupported;
    }
    if (code) |raw_code| {
        if (text_helpers.isRateLimitedText(raw_code)) return .rate_limited;
        if (text_helpers.isContextExhaustedText(raw_code)) return .context_exhausted;
        if (text_helpers.isVisionUnsupportedText(raw_code)) return .vision_unsupported;
    }

    return .other;
}

/// Classify `{"error": {...}}` payloads used by OpenAI-compatible,
/// Anthropic, and Gemini APIs.
pub fn classifyErrorObject(root_obj: anytype) ?ApiErrorKind {
    const err_value = root_obj.get("error") orelse return null;
    if (err_value == .null) return null;
    if (err_value == .string) {
        return classifyFromFields(null, null, null, err_value.string);
    }
    if (err_value != .object) return .other;
    const err_obj = err_value.object;

    var status: ?u16 = null;
    if (err_obj.get("status")) |v| {
        status = parseStatusCode(v);
    }

    var code: ?[]const u8 = null;
    if (err_obj.get("code")) |v| {
        switch (v) {
            .string => |s| {
                code = s;
                if (status == null) status = parseStatusCode(v);
            },
            .integer => {
                if (status == null) status = parseStatusCode(v);
            },
            else => {},
        }
    }

    var type_name: ?[]const u8 = null;
    if (err_obj.get("type")) |v| {
        if (v == .string) type_name = v.string;
    }

    var message: ?[]const u8 = lookupMessageField(err_obj);
    if (message == null) message = lookupMessageField(root_obj);

    return classifyFromFields(status, code, type_name, message);
}

fn classifyTopLevelError(root_obj: anytype) ?ApiErrorKind {
    var has_error_signal = false;

    var status: ?u16 = null;
    if (root_obj.get("status")) |v| {
        status = parseStatusCode(v);
        if (status != null) has_error_signal = true;
    }

    var code: ?[]const u8 = null;
    if (root_obj.get("code")) |v| {
        has_error_signal = true;
        switch (v) {
            .string => |s| code = s,
            .integer => {
                if (status == null) status = parseStatusCode(v);
            },
            else => {},
        }
    }

    var type_name: ?[]const u8 = null;
    if (root_obj.get("type")) |v| {
        if (v == .string) {
            type_name = v.string;
            if (text_helpers.containsAsciiFold(v.string, "error")) has_error_signal = true;
        }
    }

    const message = lookupMessageField(root_obj);

    if (!has_error_signal) return null;
    return classifyFromFields(status, code, type_name, message);
}

/// Classify known API error envelopes.
/// Returns null when no error envelope is present.
pub fn classifyKnownApiError(root_obj: anytype) ?ApiErrorKind {
    if (classifyErrorObject(root_obj)) |kind| return kind;
    return classifyTopLevelError(root_obj);
}

test "classifyKnownApiError detects rate-limit payloads" {
    const body = "{\"error\":{\"message\":\"Rate limit exceeded\",\"type\":\"rate_limit_error\",\"code\":429}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(.rate_limited, classifyKnownApiError(parsed.value.object).?);
}

test "classifyKnownApiError detects context payloads" {
    const body = "{\"error\":{\"message\":\"This model's maximum context length is 128000 tokens\",\"type\":\"invalid_request_error\"}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(.context_exhausted, classifyKnownApiError(parsed.value.object).?);
}

test "classifyKnownApiError detects vision unsupported payloads" {
    const body = "{\"error\":{\"message\":\"No endpoints found that support image input\",\"code\":404}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(.vision_unsupported, classifyKnownApiError(parsed.value.object).?);
    try std.testing.expect(kindToError(.vision_unsupported) == error.ProviderDoesNotSupportVision);
}

test "classifyKnownApiError returns null for non-error payload" {
    const body = "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    try std.testing.expect(classifyKnownApiError(parsed.value.object) == null);
}

test "classifyKnownApiError returns null for error:null" {
    const body = "{\"error\":null,\"output\":[{\"role\":\"assistant\",\"content\":[{\"text\":\"ok\"}]}]}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    try std.testing.expect(classifyKnownApiError(parsed.value.object) == null);
}

test "summarizeKnownApiError captures status code and message" {
    const body =
        \\{"error":{"code":503,"message":"This model is currently experiencing high demand.","status":"UNAVAILABLE"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    var buf: [512]u8 = undefined;
    const summary = summarizeKnownApiError(parsed.value.object, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, summary, "status=503") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "message=This model is currently experiencing high demand.") != null);
}

test "summarizeKnownApiError returns null for non-error payload" {
    const body = "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    var buf: [128]u8 = undefined;
    try std.testing.expect(summarizeKnownApiError(parsed.value.object, &buf) == null);
}

// infini-ai: uses top-level "code" (integer) and "msg" (string) instead of
// the standard "error": { "message": ... } envelope.
// Actual payload: {"code":10007,"msg":"Bad Request: [message type 'image_url' is not supported for model 'glm-5']"}
test "classifyKnownApiError detects infini-ai vision-unsupported via top-level msg field" {
    const body =
        \\{"code":10007,"msg":"Bad Request: [message type 'image_url' is not supported for model 'glm-5']"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    const kind = classifyKnownApiError(parsed.value.object);
    try std.testing.expectEqual(ApiErrorKind.vision_unsupported, kind.?);
    try std.testing.expect(kindToError(.vision_unsupported) == error.ProviderDoesNotSupportVision);
}

// Regression: OpenAI-compatible providers may return error.msg instead of error.message.
test "classifyKnownApiError detects vision-unsupported via nested error msg field" {
    const body =
        \\{"error":{"code":10007,"msg":"Bad Request: [message type 'image_url' is not supported for model 'glm-5']"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    const kind = classifyKnownApiError(parsed.value.object);
    try std.testing.expectEqual(ApiErrorKind.vision_unsupported, kind.?);
}

test "isVisionUnsupportedText matches infini-ai phrasing" {
    const text = "Bad Request: [message type 'image_url' is not supported for model 'glm-5']";
    try std.testing.expect(text_helpers.isVisionUnsupportedText(text));
}

test "isVisionUnsupportedText does not false-positive on unrelated image mention" {
    // "image" alone without "not supported" should not trigger
    const text = "Please provide an image description";
    try std.testing.expect(!text_helpers.isVisionUnsupportedText(text));
}

// Regression: generic image validation failures must not disable vision support.
test "classifyKnownApiError does not treat unsupported image format as vision unsupported" {
    const body =
        \\{"code":10008,"msg":"Bad Request: image format is not supported"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    const kind = classifyKnownApiError(parsed.value.object);
    try std.testing.expectEqual(ApiErrorKind.other, kind.?);
}

test "summarizeKnownApiError captures infini-ai msg field" {
    const body =
        \\{"code":10007,"msg":"Bad Request: [message type 'image_url' is not supported for model 'glm-5']"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    var buf: [512]u8 = undefined;
    const summary = summarizeKnownApiError(parsed.value.object, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, summary, "message=") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "image_url") != null);
}

test "summarizeKnownApiError captures nested error msg field" {
    const body =
        \\{"error":{"code":10007,"msg":"Bad Request: [message type 'image_url' is not supported for model 'glm-5']"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    var buf: [512]u8 = undefined;
    const summary = summarizeKnownApiError(parsed.value.object, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, summary, "message=") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "image_url") != null);
}

// ─── User-facing error classification ────────────────────────────────────────

/// Failure class shown to a chat user. Kept separate from `ApiErrorKind`:
/// transport errors carry no provider payload, and the user copy also covers
/// auth and overload cases the JSON classifier does not need.
pub const UserErrorKind = enum {
    rate_limited,
    overloaded,
    auth,
    timeout,
    network,
    context_exhausted,
    vision_unsupported,
    empty_response,
    all_providers_failed,
    out_of_memory,
    generic,
};

/// Classify a terminal agent error for a short, actionable user message.
/// `detail` is the sanitized last provider error (`snapshotInto` format), used
/// only for matching; it is never echoed back to the user.
pub fn classifyUserError(err: anyerror, detail: ?[]const u8) UserErrorKind {
    switch (err) {
        error.RateLimited => return .rate_limited,
        error.ContextLengthExceeded => return .context_exhausted,
        error.ProviderDoesNotSupportVision => return .vision_unsupported,
        error.NoResponseContent => return .empty_response,
        error.OutOfMemory => return .out_of_memory,
        error.CurlTimeout => return .timeout,
        error.CurlPreSendError, error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError, error.CurlDnsError, error.CurlConnectError, error.CurlTlsError => return .network,
        // Providers return these directly when no local credential is
        // configured (streaming path) or wrap them in AllProvidersFailed with
        // a "<provider>: CredentialsNotSet" detail (blocking path).
        error.CredentialsNotSet, error.TokenExpired => return .auth,
        else => {},
    }

    // Only provider failures carry a detail that describes this failure. A
    // successful fallback can leave an earlier provider's detail behind, so
    // matching it for unrelated errors would misclassify them.
    const has_provider_detail = err == error.ApiError or
        err == error.ProviderError or
        err == error.AllProvidersFailed;
    if (has_provider_detail) {
        if (detail) |text| {
            // Rate limits win over context checks: quota messages often contain
            // "token" + "exceed" and would otherwise look like context overflow.
            if (text_helpers.isRateLimitedText(text)) return .rate_limited;
            if (text_helpers.isContextExhaustedText(text)) return .context_exhausted;
            if (text_helpers.isAuthErrorText(text)) return .auth;
            // Timeouts win over the overload heuristic: a detail such as
            // "request timed out after 500 ms" must not read as an HTTP 5xx.
            if (text_helpers.isTimeoutText(text)) return .timeout;
            if (text_helpers.isOverloadedText(text)) return .overloaded;
        }
    }

    if (err == error.AllProvidersFailed) return .all_providers_failed;
    return .generic;
}

fn rateLimitedCopy(buf: []u8, retries_used: u32) []const u8 {
    if (retries_used == 0) {
        return "Rate limited by the provider. Wait a minute and try again.";
    }
    const retry_word = if (retries_used == 1) "retry" else "retries";
    return std.fmt.bufPrint(
        buf,
        "Rate limited by the provider after {d} {s}. Wait a minute and try again.",
        .{ retries_used, retry_word },
    ) catch "Rate limited by the provider. Wait a minute and try again.";
}

/// Render the user-facing copy for a failure class into `buf`.
/// `retries_used` makes an exhausted rate limit say how many retries ran.
/// `with_fresh_hint` keeps `/new` guidance on generic failures for chat
/// channels that own a session; compact channels keep the shorter fallback.
pub fn formatUserError(
    buf: []u8,
    kind: UserErrorKind,
    retries_used: u32,
    with_fresh_hint: bool,
) []const u8 {
    return switch (kind) {
        .rate_limited => rateLimitedCopy(buf, retries_used),
        .overloaded => "The provider is overloaded or temporarily unavailable. Please try again shortly.",
        .auth => "Provider authentication failed. Check the API key in config, then try again.",
        .timeout => "Provider timed out waiting for a response. Please retry or /new for a fresh session.",
        .network => "Network error contacting provider. Check base_url, DNS, proxy, and TLS certificates, then try again.",
        .context_exhausted => "This conversation exceeded the model's context window. Use /new to start a fresh session or send a shorter message.",
        .vision_unsupported => "The current provider does not support image input. Switch to a vision-capable provider or remove [IMAGE:] attachments.",
        .empty_response => "Model returned an empty response. Please retry or /new for a fresh session.",
        .all_providers_failed => "All configured providers failed for this request. Check model/provider compatibility and credentials.",
        .out_of_memory => "Out of memory.",
        .generic => if (with_fresh_hint)
            "An error occurred. Try again or /new for a fresh session."
        else
            "An error occurred. Try again.",
    };
}

/// Classify and render in one call, reading the last sanitized provider detail
/// without allocating. The returned slice points into `buf`.
pub fn userErrorMessage(
    buf: []u8,
    err: anyerror,
    retries_used: u32,
    with_fresh_hint: bool,
) []const u8 {
    var detail_buf: [256]u8 = undefined;
    const detail = api_error_details.snapshotInto(&detail_buf);
    return formatUserError(buf, classifyUserError(err, detail), retries_used, with_fresh_hint);
}

test "classifyUserError uses provider detail for rate limits" {
    try std.testing.expectEqual(
        UserErrorKind.rate_limited,
        classifyUserError(error.AllProvidersFailed, "compatible: status=429 message=Rate limit exceeded"),
    );
    try std.testing.expectEqual(UserErrorKind.rate_limited, classifyUserError(error.RateLimited, null));
}

test "classifyUserError detects auth, overload, timeout and context" {
    try std.testing.expectEqual(
        UserErrorKind.auth,
        classifyUserError(error.AllProvidersFailed, "compatible: status=401 message=Incorrect API key provided"),
    );
    try std.testing.expectEqual(
        UserErrorKind.overloaded,
        classifyUserError(error.AllProvidersFailed, "compatible: status=503 message=This model is currently experiencing high demand."),
    );
    try std.testing.expectEqual(
        UserErrorKind.timeout,
        classifyUserError(error.AllProvidersFailed, "compatible: request timed out"),
    );
    // Regression: a bare number in the detail used to be read as an HTTP 5xx.
    try std.testing.expectEqual(
        UserErrorKind.timeout,
        classifyUserError(error.AllProvidersFailed, "compatible: request timed out after 500 ms"),
    );
    try std.testing.expectEqual(
        UserErrorKind.all_providers_failed,
        classifyUserError(error.AllProvidersFailed, "compatible: max_tokens must be <= 500"),
    );
    try std.testing.expectEqual(
        UserErrorKind.context_exhausted,
        classifyUserError(error.AllProvidersFailed, "compatible: maximum context length is 128000 tokens"),
    );
    try std.testing.expectEqual(UserErrorKind.context_exhausted, classifyUserError(error.ContextLengthExceeded, null));
}

test "classifyUserError maps missing credentials and expired tokens to auth" {
    try std.testing.expectEqual(UserErrorKind.auth, classifyUserError(error.CredentialsNotSet, null));
    try std.testing.expectEqual(UserErrorKind.auth, classifyUserError(error.TokenExpired, null));
    // Blocking providers wrap the raw error and only leave the detail behind.
    try std.testing.expectEqual(
        UserErrorKind.auth,
        classifyUserError(error.AllProvidersFailed, "openai: CredentialsNotSet"),
    );
    try std.testing.expectEqual(
        UserErrorKind.auth,
        classifyUserError(error.AllProvidersFailed, "openai_codex: TokenExpired"),
    );
}

test "classifyUserError keeps transport and fallback classes" {
    try std.testing.expectEqual(UserErrorKind.timeout, classifyUserError(error.CurlTimeout, null));
    try std.testing.expectEqual(UserErrorKind.network, classifyUserError(error.CurlConnectError, null));
    try std.testing.expectEqual(UserErrorKind.all_providers_failed, classifyUserError(error.AllProvidersFailed, null));
    try std.testing.expectEqual(UserErrorKind.generic, classifyUserError(error.Unexpected, null));
    // Regression: a leftover detail from an earlier failed provider must not
    // classify an unrelated agent error.
    try std.testing.expectEqual(
        UserErrorKind.generic,
        classifyUserError(error.Unexpected, "compatible: status=429 message=Rate limit exceeded"),
    );
}

test "formatUserError reports exhausted rate-limit retries" {
    var buf: [256]u8 = undefined;
    const text = formatUserError(&buf, .rate_limited, 3, false);
    try std.testing.expectEqualStrings(
        "Rate limited by the provider after 3 retries. Wait a minute and try again.",
        text,
    );

    // Regression: a single configured retry used to read "after 1 retries".
    const one = formatUserError(&buf, .rate_limited, 1, false);
    try std.testing.expectEqualStrings(
        "Rate limited by the provider after 1 retry. Wait a minute and try again.",
        one,
    );

    const no_retries = formatUserError(&buf, .rate_limited, 0, false);
    try std.testing.expectEqualStrings("Rate limited by the provider. Wait a minute and try again.", no_retries);
}

test "formatUserError keeps generic copy compact unless a session hint is wanted" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "An error occurred. Try again.",
        formatUserError(&buf, .generic, 0, false),
    );
    try std.testing.expectEqualStrings(
        "An error occurred. Try again or /new for a fresh session.",
        formatUserError(&buf, .generic, 0, true),
    );
}

test "userErrorMessage never echoes provider detail or secrets" {
    api_error_details.clear();
    defer api_error_details.clear();
    api_error_details.set("compatible", "status=401 message=Incorrect API key provided: sk-secret-test-key");

    var buf: [256]u8 = undefined;
    const text = userErrorMessage(&buf, error.AllProvidersFailed, 0, true);
    try std.testing.expectEqualStrings(
        "Provider authentication failed. Check the API key in config, then try again.",
        text,
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "sk-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "status=401") == null);
}
