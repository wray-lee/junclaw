# Changelog

## Unreleased

## 1.0.0 - 2026-10-26

First tagged release of the junclaw fork. Highlights since the last upstream merge:

### Added

- In-process dsh agent engine (`agent.harness = "dsh"`, default) with a JSONL session log, compaction, `/goal`, `/plan`, `/compact`, approvals and questions, resume with crash repair, junclaw tool bridge, security-policy enforcement, native-history import, live streaming and reasoning display (`reasoning_mode`), and a fast `/stop` that aborts the in-flight provider request.
- Reasoning display for the dsh sidecar (`dsh-sidecar`).
- Agent-engine port layer (`src/harness/`) so the original engine stays selectable (`"harness": "native"`).


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
  with an indeterminate transport error (for example a request timeout, a
  wait failure after curl starts, or a gateway 502/504): such a failure counts
  as one best-effort attempt and is not re-sent in another format or retried by
  the outbox/dispatch layers.
- Telegram inline-button callback edits no longer post the whole reply again
  when the edit outcome is unknown, and a `message is not modified` rejection
  from a rich edit is treated as success.
- Curl pre-send failures (for example an unresolvable proxy, exit 5) are no
  longer treated as "may have been delivered", so a reply that definitely was
  not sent is retried instead of being silently dropped.
- Slack no longer posts a reply twice when a send or streaming update fails
  with an indeterminate transport error (for example a request timeout, a
  wait failure after curl starts, a gateway 502/504, or a broken/partial
  response): such a failure counts as one best-effort attempt and is not
  re-sent in another format, retried by the outbox/dispatch layers, or posted
  again by a streaming fallback.
