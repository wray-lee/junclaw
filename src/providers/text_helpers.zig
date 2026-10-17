const std = @import("std");

/// Case-insensitive byte-level string equality.
pub fn sliceEqlAsciiFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// Case-insensitive substring search.
pub fn containsAsciiFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (sliceEqlAsciiFold(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Returns true if `text` indicates a rate-limit error.
pub fn isRateLimitedText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (containsAsciiFold(text, "ratelimited") or
        containsAsciiFold(text, "rate limited") or
        containsAsciiFold(text, "rate_limit") or
        containsAsciiFold(text, "too many requests") or
        containsAsciiFold(text, "throttle") or
        containsAsciiFold(text, "quota exceeded"))
    {
        return true;
    }
    return containsAsciiFold(text, "429") and
        (containsAsciiFold(text, "rate") or
            containsAsciiFold(text, "limit") or
            containsAsciiFold(text, "too many"));
}

/// Returns true if `text` indicates a context-window exhaustion error.
pub fn isContextExhaustedText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (containsAsciiFold(text, "context length exceeded") or
        containsAsciiFold(text, "contextlengthexceeded") or
        containsAsciiFold(text, "maximum context length") or
        containsAsciiFold(text, "context window") or
        containsAsciiFold(text, "prompt is too long") or
        containsAsciiFold(text, "input is too long"))
    {
        return true;
    }
    const has_context = containsAsciiFold(text, "context");
    const has_token = containsAsciiFold(text, "token");
    if (has_context and (containsAsciiFold(text, "length") or
        containsAsciiFold(text, "maximum") or
        containsAsciiFold(text, "window") or
        containsAsciiFold(text, "exceed")))
    {
        return true;
    }
    if (has_token and (containsAsciiFold(text, "limit") or
        containsAsciiFold(text, "maximum") or
        containsAsciiFold(text, "too many") or
        containsAsciiFold(text, "exceed")))
    {
        return true;
    }
    return containsAsciiFold(text, "413") and containsAsciiFold(text, "too large");
}

/// Returns true if `text` indicates a vision-unsupported error.
pub fn isVisionUnsupportedText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (containsAsciiFold(text, "does not support image") or
        containsAsciiFold(text, "doesn't support image") or
        containsAsciiFold(text, "image input not supported") or
        containsAsciiFold(text, "no endpoints found that support image input") or
        containsAsciiFold(text, "vision not supported") or
        containsAsciiFold(text, "multimodal not supported") or
        containsAsciiFold(text, "not a multimodal model"))
    {
        return true;
    }

    // infini-ai reports unsupported vision inputs as:
    // "message type 'image_url' is not supported for model 'glm-5'"
    if (containsAsciiFold(text, "image_url") and containsAsciiFold(text, "not supported")) {
        return true;
    }

    return false;
}

test "isVisionUnsupportedText matches infini-ai phrasing" {
    const text = "Bad Request: [message type 'image_url' is not supported for model 'glm-5']";
    try std.testing.expect(isVisionUnsupportedText(text));
}

test "isVisionUnsupportedText does not false-positive on unrelated image mention" {
    const text = "Please provide an image description";
    try std.testing.expect(!isVisionUnsupportedText(text));
}

/// True when a three-digit status token in `text` falls inside `[min, max]`.
fn containsStatusCodeIn(text: []const u8, min: u16, max: u16) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (std.ascii.isDigit(text[i])) {
            var end = i;
            while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
            if (end - i == 3) {
                const code = std.fmt.parseInt(u16, text[i..end], 10) catch {
                    i = end;
                    continue;
                };
                if (code >= min and code <= max) return true;
            }
            i = end;
        } else {
            i += 1;
        }
    }
    return false;
}

/// Returns true if `text` indicates an overloaded provider or a transient 5xx.
pub fn isOverloadedText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (containsAsciiFold(text, "overloaded") or
        containsAsciiFold(text, "over capacity") or
        containsAsciiFold(text, "high demand") or
        containsAsciiFold(text, "temporarily unavailable") or
        containsAsciiFold(text, "service unavailable") or
        containsAsciiFold(text, "internal server error") or
        containsAsciiFold(text, "server error"))
    {
        return true;
    }
    // 529 is Anthropic's non-standard overload status.
    return containsStatusCodeIn(text, 500, 599) or containsAsciiFold(text, "529");
}

/// Returns true if `text` indicates a provider authentication/authorization
/// failure, including a missing or invalid API key.
pub fn isAuthErrorText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (containsAsciiFold(text, "unauthorized") or
        containsAsciiFold(text, "unauthenticated") or
        containsAsciiFold(text, "authentication failed") or
        containsAsciiFold(text, "invalid api key") or
        containsAsciiFold(text, "incorrect api key") or
        containsAsciiFold(text, "invalid_api_key") or
        containsAsciiFold(text, "api key not valid") or
        containsAsciiFold(text, "missing api key") or
        containsAsciiFold(text, "no api key") or
        containsAsciiFold(text, "api key is required") or
        containsAsciiFold(text, "permission denied"))
    {
        return true;
    }
    return containsStatusCodeIn(text, 401, 401) or containsStatusCodeIn(text, 403, 403);
}

/// Returns true if `text` indicates a provider timeout.
pub fn isTimeoutText(text: []const u8) bool {
    if (text.len == 0) return false;
    return containsAsciiFold(text, "timed out") or
        containsAsciiFold(text, "timeout") or
        containsAsciiFold(text, "deadline exceeded") or
        containsStatusCodeIn(text, 408, 408);
}

test "isOverloadedText matches 5xx and overload phrasing" {
    try std.testing.expect(isOverloadedText("status=503 message=This model is currently experiencing high demand."));
    try std.testing.expect(isOverloadedText("529 overloaded_error"));
    try std.testing.expect(!isOverloadedText("status=401 message=Unauthorized"));
    try std.testing.expect(!isOverloadedText("status=429 message=Rate limit exceeded"));
    try std.testing.expect(!isOverloadedText(""));
}

test "isAuthErrorText matches auth failures without secrets" {
    try std.testing.expect(isAuthErrorText("status=401 message=Unauthorized"));
    try std.testing.expect(isAuthErrorText("Incorrect API key provided"));
    try std.testing.expect(isAuthErrorText("missing api key for provider"));
    try std.testing.expect(!isAuthErrorText("status=503 message=overloaded"));
    try std.testing.expect(!isAuthErrorText(""));
}

test "isTimeoutText matches timeout phrasing" {
    try std.testing.expect(isTimeoutText("request timed out"));
    try std.testing.expect(isTimeoutText("status=408 message=Request Timeout"));
    try std.testing.expect(!isTimeoutText("status=500 message=server error"));
    try std.testing.expect(!isTimeoutText(""));
}
