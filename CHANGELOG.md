# Changelog

## Unreleased

## 1.1.0 - 2026-10-27

Browser release: two ways to give the agent a real browser, shipped as separate
image variants so the default image stays small.

### Added

- `main-lightpanda` image: the standard image plus the pinned Lightpanda 1.0.2
  browser, reached through its own MCP server (AGPL-3.0 notice shipped in
  `/usr/share/doc/lightpanda`, telemetry off). Per-server MCP `tools`
  allowlist (`mcp_servers.<name>.tools`) keeps the token cost of the browser
  tool list small.
- `agent.tool_filter_groups` now also applies in the dsh engine, with the
  same matching as the native engine.
- Firefox WebDriver browser backend (`browser.backend = "webdriver"`):
  open, read, snapshot (numbered interactive elements), click, type, scroll,
  screenshot and close. geckodriver is started lazily, one browser per
  process, reaped when idle, with a one-shot profile. HTTPS only, private and
  metadata addresses blocked, final URL rechecked after navigation and after
  each action. See `docs/en/browser.md` for the security model and known
  limits.
- `main-browser` and `full-dsh-browser` image variants (Firefox ESR and
  geckodriver 0.37.1). Tags: `main-browser`, `full-dsh-browser`,
  `<release-tag>-browser`, `<release-tag>-full-dsh-browser` and a `-<sha>`
  suffixed rolling tag; `latest` is unchanged.

### Fixed

- `config save` no longer drops the `mcp_servers.<name>.tools` allowlist.

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
