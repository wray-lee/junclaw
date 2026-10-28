# Changelog

## Unreleased

### Fixed

- dsh engine: the in-process engine's runtime context now carries the same
  channel attachment-marker guidance as the native system prompt, so the model
  emits `[FILE:...]`, `[DOCUMENT:...]`, `[IMAGE:...]`, and the other markers
  instead of pasting file bodies or calling a channel API with its own
  credentials. The dsh system prompt stays verbatim, and the existing
  workspace/`autonomy.allowed_paths` marker-scope filter applies unchanged.
- in-process dsh engine (`agent.harness: "dsh"`): a completed turn now
  autosaves the redacted user text and the delivered reply summary into the
  configured memory backend (`memory.auto_save`), and a pre-compaction flush
  extracts durable facts before dsh drops messages
  (`agent.compaction_memory_flush`), including a manual `/compact`. The native
  memory-tool guidance is injected into the runtime context. The `dsh-sidecar`
  engine does not have this wiring.
- in-process dsh engine: `## Skills`, the session-armed
  `## Active Skill Session`, the named agent's `## Agent Profile` prompt,
  `## Runtime Capabilities`, and the native `## Runtime` (OS | Model) line now
  reach the model instead of being dropped. `AGENTS.md` is read through the
  configured bootstrap provider, so copies stored in a database memory backend
  (sqlite/postgres/redis) apply.

## 1.1.1 - 2026-10-28

Fix release: model menu, text tool calls and self-update.

### Fixed

- `/model` no longer falls back to the built-in Claude list when a gateway's
  `/v1/models` call fails. An expired `models_cache.json` entry is served
  instead (still refreshed on the next call); custom/OpenAI-compatible
  providers fall back to the configured model or an empty list with a
  "try again later" message; a built-in provider pointed at a custom
  `base_url` no longer overwrites the gateway cache with its static table.
  The catalog request is retried once and its timeout raised from 10 s to 20 s.
- dsh engine: models that write tool calls as `<tool_call>…</tool_call>` text
  (seen with Gemini behind OpenAI-compatible gateways) now run the tools
  instead of ending the turn with the raw markup. Both blocking and streaming
  paths reuse the native dispatcher parser; structured calls win when both
  appear, the live draft never shows the markup, a malformed or truncated
  block is not executed, and a block inside `<think>` stays reasoning.
- `nullclaw update` now checks and downloads junclaw releases (`junclaw-*`
  assets from `wray-lee/junclaw`) and, in a container, suggests
  `docker pull ghcr.io/wray-lee/junclaw:latest`. It previously fetched
  upstream nullclaw and replaced junclaw with it. Containers are now also
  detected via `/.dockerenv`, since the junclaw image installs to
  `/usr/local/bin`.

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
