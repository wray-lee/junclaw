# Changelog

## Unreleased

### Changed

- `agent.harness` now defaults to `"dsh"`, the in-process dsh engine
  (`src/harness/dsh_native/`). Set `"harness": "native"` to keep the original
  engine.
- The DeepSeek-Harness sidecar value moved from `"dsh"` to `"dsh-sidecar"`.
  It still requires a `-Dharness_dsh=true` build. Configs that meant the
  sidecar must change `"dsh"` to `"dsh-sidecar"`.
- `"dsh-native"` is kept as an alias for `"dsh"`; saving a config writes the
  canonical `"dsh"`.

### Fixed

- Telegram no longer posts a reply twice when a rich, HTML or plain send fails
  with an indeterminate transport error (for example a request timeout): such
  a failure counts as one best-effort attempt and is not re-sent in another
  format or retried by the outbox/dispatch layers.
- Telegram inline-button callback edits no longer post the whole reply again
  when the edit outcome is unknown, and a `message is not modified` rejection
  from a rich edit is treated as success.
- Curl pre-send failures (for example an unresolvable proxy, exit 5) are no
  longer treated as "may have been delivered", so a reply that definitely was
  not sent is retried instead of being silently dropped.
- Slack no longer posts a reply twice when a send or streaming update fails
  with an indeterminate transport error (for example a request timeout or a
  broken/partial response): such a failure counts as one best-effort attempt
  and is not re-sent in another format, retried by the outbox/dispatch layers,
  or posted again by a streaming fallback.
