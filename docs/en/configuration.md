# Configuration

NullClaw is compatible with OpenClaw config structure and uses `snake_case` keys.

## Page Guide

**Who this page is for**

- Users creating or editing the main `config.json`
- Operators tuning channels, gateway behavior, and autonomy limits
- Migrators mapping existing OpenClaw-style settings into NullClaw

**Read this next**

- Open [Usage and Operations](./usage.md) after config edits to validate runtime behavior
- Open [Security](./security.md) before widening permissions, public exposure, or tool scope
- Open [Gateway API](./gateway-api.md) if your config changes affect pairing, webhooks, or external integrations
- Open [External Channel Plugins](./external-channels.md) if you are wiring a non-core channel

**If you came from ...**

- [Installation](./installation.md): this page takes over once `nullclaw` is installed and ready for first-run setup
- [README](./README.md): this is the detailed config path after choosing the operator/user docs route
- [Gateway API](./gateway-api.md): come back here when the API workflow depends on concrete `gateway` or channel settings

## Config File Path

- macOS/Linux: `~/.nullclaw/config.json`
- Windows: `%USERPROFILE%\\.nullclaw\\config.json`

Recommended first step:

```bash
nullclaw onboard --interactive
```

This generates your initial config file.

## Minimal Working Config

The example below is enough to run local CLI mode (replace API key):

```json
{
  "models": {
    "providers": {
      "openrouter": {
        "api_key": "YOUR_OPENROUTER_API_KEY"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "openrouter/anthropic/claude-sonnet-4"
      }
    }
  },
  "channels": {
    "cli": true
  },
  "memory": {
    "backend": "sqlite",
    "auto_save": true
  },
  "gateway": {
    "host": "127.0.0.1",
    "port": 3000,
    "require_pairing": true
  },
  "autonomy": {
    "level": "supervised",
    "workspace_only": true,
    "max_actions_per_hour": 20
  },
  "security": {
    "sandbox": {
      "backend": "auto"
    },
    "audit": {
      "enabled": true
    }
  }
}
```

## Core Sections

### `diagnostics`

- Controls runtime diagnostics and observability output.
- For OpenTelemetry, use the nested `diagnostics.otel` object.
- OTEL spans are flushed at natural runtime boundaries such as turn completion and agent shutdown, with batch flushing still used as a fallback for longer-running flows.
- `diagnostics.otel.endpoint` should use `https://...` for remote collectors. Plain `http://...` is accepted only for localhost/private collectors or container-local targets such as `host.docker.internal`, `host.containers.internal`, or single-label service names like `otel`.

Logging flags (all default `false`). The `info`-level lines go to stderr: the terminal when `nullclaw agent` or `nullclaw gateway` runs in the foreground. Getting them into a file is up to the service wrapper or your own redirection — service mode writes `~/.nullclaw/logs/daemon.stderr.log` (the launchd service config supplies it), while the `gateway` command itself does not route them to a daemon log file:

- `log_tool_calls`: log each tool call with name, status, and duration. Tool arguments are included only when `log_llm_io` is also enabled.
- `log_message_receipts`: log when a user message is received — metadata only (channel, session hash, size), never content.
- `log_message_payloads`: log a content preview of inbound/outbound user-visible messages — UTF-8-safe and capped at 4,096 bytes, marked `[log preview truncated]` when longer. Local debugging only — can include sensitive text.
- `log_llm_io`: log redacted, truncated previews of provider request/response content around chat calls, including response and reasoning previews. Local debugging only — can include sensitive text; keep off in production.
- `token_usage_ledger_enabled` (default `true`) plus `token_usage_ledger_window_hours` / `token_usage_ledger_max_bytes` / `token_usage_ledger_max_lines`: persist per-response token counters to a JSONL ledger near `config.json`. Token counts only — provider/model/prompt/completion/total — never message text.

Example (production-safe: content-bearing flags off):

```json
{
  "diagnostics": {
    "backend": "otel",
    "log_tool_calls": true,
    "log_message_receipts": true,
    "log_message_payloads": false,
    "log_llm_io": false,
    "otel": {
      "endpoint": "https://otel.example.com:4318",
      "service_name": "nullclaw",
      "headers": {
        "Authorization": "Bearer example-token"
      }
    }
  }
}
```

### `models.providers`

- Defines LLM provider connection parameters and API keys.
- Common providers: `openrouter`, `openai`, `anthropic`, `groq`, `nearai`, `atlas-cloud`, `evolink`, `edenai`, `cheaperinference`.

Example:

```json
{
  "models": {
    "providers": {
      "openrouter": { "api_key": "sk-or-..." },
      "nearai": { "api_key": "YOUR_NEARAI_API_KEY" },
      "atlas-cloud": { "api_key": "YOUR_ATLASCLOUD_API_KEY" },
      "edenai": { "api_key": "YOUR_EDENAI_API_KEY" },
      "cheaperinference": { "api_key": "YOUR_CHEAPER_INFERENCE_API_KEY" },
      "evolink": { "api_key": "YOUR_EVOLINK_API_KEY" },
      "anthropic": { "api_key": "sk-ant-..." },
      "openai": { "api_key": "sk-..." }
    }
  }
}
```

Common per-provider fields:

- `api_key`: credential for that provider entry.
- `base_url`: provider-specific API endpoint override. The expected path shape
  depends on the provider; OpenAI-compatible providers usually expect a `/v1`
  base, while the native Anthropic provider does not.
- `api_mode`: select `chat_completions` or `responses` for compatible providers.
- `user_agent`: optional `User-Agent` header override.
- `max_streaming_prompt_bytes`: skip streaming above this estimated prompt size.
- `chat_template_enable_thinking_param`: for custom OpenAI-compatible vLLM/Qwen endpoints, map `reasoning_effort` to `chat_template_kwargs.enable_thinking`.

#### Native Anthropic provider

NullClaw has a dedicated Anthropic provider that connects directly to the Anthropic API
— no OpenRouter or proxy is required.

Authentication options:

- **Anthropic Console API keys** are sent in the `x-api-key` header. Put the key
  in `models.providers.anthropic.api_key` or set `ANTHROPIC_API_KEY`.
- **Claude subscription setup tokens** beginning with `sk-ant-oat01-` are sent
  with Bearer authentication. Generate a long-lived token with `claude setup-token`,
  then put it in `models.providers.anthropic.api_key` or set
  `ANTHROPIC_OAUTH_TOKEN`. NullClaw does not read Claude Code's credential store
  or refresh the token. See the [Claude Code authentication guide](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token).

The provider supports text streaming, URL and base64 image inputs, and native
tool calls on non-streaming requests. Setting `reasoning_effort` (or using
`/think`) enables Anthropic extended thinking on models that support it.
NullClaw uses adaptive thinking for Claude Opus/Sonnet 4.6 and a manual budget
for older supported models; model-specific Anthropic restrictions still apply.

Example (direct Anthropic API key):

```json
{
  "models": {
    "providers": {
      "anthropic": { "api_key": "sk-ant-api03-..." }
    }
  },
  "agents": {
    "defaults": {
      "model": { "primary": "anthropic/claude-sonnet-4-6" }
    }
  }
}
```

Notes:

- In `agents.defaults.model.primary`, prefix the Anthropic model ID with
  `anthropic/`, for example `anthropic/claude-sonnet-4-6`. When an agent entry
  has a separate `"provider": "anthropic"` field, use the bare model ID instead.
  Browse NullClaw's cataloged Anthropic model IDs with
  `nullclaw --list-models --provider anthropic`; this command does not inspect
  the models enabled for your Anthropic account.
- The `base_url` field is optional and defaults to `https://api.anthropic.com`.
  For an Anthropic-compatible proxy or gateway, set it to the API root before
  `/v1/messages` (do not include the final `/v1`); NullClaw appends that path.
  Remote endpoints must use HTTPS. Plain HTTP is accepted only for local or
  private-network hosts.

### `agents.defaults.model.primary`

- Sets default model route, typically `provider/vendor/model`.
- Example: `openrouter/anthropic/claude-sonnet-4`

### `agent.default_queue_mode`

- Sets the inbound queue mode for newly created sessions. Accepted values are `steer`, `off`, `serial`, `latest`, and `debounce`; the default is `steer`.
- `steer` (default) injects a message that arrives while a turn is running into that active turn at the next tool or model boundary, in arrival order, so nothing is silently dropped. The sender is acknowledged immediately with a typing indicator, an accepted reaction, or a short notice on channels that support neither. Steer keeps every message and is not limited by a queue cap. If a follow-up turn that runs an already-acknowledged steer message fails, the reply says the message could not be processed and asks the sender to resend it; it is not retried automatically.
- `off` discards messages that arrive while a turn is running; the sender is told the message was not delivered. `serial` waits for the active turn, `latest` keeps only the newest pending injection (replacing an earlier one), and `debounce` selects the existing runtime debounce mode; this field does not configure its duration, cap, or drop policy.
- `/queue` can override the mode for the current session (`/queue steer`, `/queue latest`, and so on). `/queue reset`, `/restart`, and `/debug reset` restore the configured default.
- Changes require a restart so the session manager and newly created sessions use the same default.
- Configs written by older versions contain `"default_queue_mode": "off"`, which keeps the old drop behaviour. Remove the field or set it to `steer` to use the new default.

Example:

```json
{
  "agent": {
    "default_queue_mode": "steer"
  }
}
```

### `agent.reasoning_mode`

- Sets the reasoning display mode for newly created sessions. Accepted values are `off`, `on`, and `stream`; the default is `off`.
- `off` hides reasoning content, `on` prints a `Reasoning:` quote block above the final reply, and `stream` prints reasoning live while the model produces it.
- `/reasoning <off|on|stream>` overrides the mode for the current session. `/restart` and `/debug reset` restore this configured default instead of always resetting to `off`.
- Sessions are evicted after `agent.session_idle_timeout_secs`, so setting this avoids re-running `/reasoning on` after every idle eviction.
- Changes apply to sessions created after a restart.

Example:

```json
{
  "agent": {
    "reasoning_mode": "stream"
  }
}
```

### `agent.compaction_memory_flush`

- When `true` (default), one bounded one-shot LLM call runs before compaction discards older messages. It extracts durable user facts and preferences and stores each line as a memory entry (`flush_compact_*`).
- Flush input is capped at 8,000 characters (UTF-8 safe truncation) and at most 10 lines are stored per compaction.
- A provider error or empty output never blocks compaction; the summary and history trimming still happen.
- The flush calls the provider directly instead of running an agent turn, so it cannot recursively trigger another compaction.
- Set to `false` to skip the extra call. `agent.compact_context` must still be enabled for proactive compaction to run.

Example:

```json
{
  "agent": {
    "compaction_memory_flush": false
  }
}
```

### `workspace_audit.llm_triage`

- Selects the provider/model used by `nullclaw workspace audit --llm-triage external`.
- Does not enable LLM triage by itself; the command-line mode remains opt-in.
- Falls back to `agents.defaults.model.primary` when omitted.

Example:

```json
{
  "workspace_audit": {
    "llm_triage": {
      "provider": "ollama",
      "model": "qwen2.5-coder:7b",
      "max_calls": 20
    }
  }
}
```

You can also provide the model as a provider-prefixed ref when the provider is configured in `models.providers`, for example `"model": "openrouter/anthropic/claude-sonnet-4"`.

### `model_routes`

- Optional top-level routing table for automatic per-turn model selection in `nullclaw agent`.
- Each entry maps a route `hint` to a concrete `provider` and `model`.
- Recognized routing hints in the current daemon are `fast`, `balanced`, `deep`, `reasoning`, and `vision`.
- `balanced` is the normal fallback when configured. `fast` is preferred for short status/list/check prompts and other short structured tasks such as extraction, counting, classification, or narrow return-only transforms. `deep` and `reasoning` are preferred for investigation, planning, tradeoff analysis, and longer contexts. `vision` is used for image turns.
- `api_key` is optional. If omitted, NullClaw uses the normal credential from `models.providers.<provider>`.
- `cost_class` is optional metadata with values `free`, `cheap`, `standard`, or `premium`.
- `quota_class` is optional metadata with values `unlimited`, `normal`, or `constrained`.

Example:

```json
{
  "model_routes": [
    { "hint": "fast", "provider": "groq", "model": "llama-3.3-70b", "cost_class": "free", "quota_class": "unlimited" },
    { "hint": "balanced", "provider": "openrouter", "model": "anthropic/claude-sonnet-4", "cost_class": "standard", "quota_class": "normal" },
    { "hint": "deep", "provider": "openrouter", "model": "anthropic/claude-opus-4", "cost_class": "premium", "quota_class": "constrained" },
    { "hint": "vision", "provider": "openrouter", "model": "openai/gpt-4.1", "cost_class": "standard", "quota_class": "normal" }
  ]
}
```

Notes:

- `model_routes` are used only when the session is not pinned to an explicit model.
- If both `deep` and `reasoning` are configured, deep-analysis prompts prefer `deep`.
- `/model` shows the last auto-route decision so operators can see which route was picked and why.
- Auto-routed sessions temporarily degrade a route after quota or rate-limit failures and skip it until the cooldown expires.
- Route metadata only nudges scoring. Ambiguous prompts still stay on `balanced`; `fast` is reserved for high-confidence cheap tasks, and strong deep-analysis signals still win over cheaper routes.

### `agents.list`

- Defines named agent profiles used by the `delegate` tool, `/subagents spawn --agent`, and `bindings`.
- Each entry may set `provider` + `model`, or a full `provider/model` ref in `model.primary`.
- Example:

```json
{
  "agents": {
    "list": [
      {
        "id": "coder",
        "model": { "primary": "ollama/qwen3.5:cloud" },
        "system_prompt": "You're an experienced coder"
      }
    ]
  }
}
```

### Subagent Profiles + Routing (Practical Pattern)

Use this pattern when you want one "orchestrator" agent to delegate specialized tasks:

1. Define reusable specialists under `agents.list`.
2. Keep a general default under `agents.defaults`.
3. Use `bindings` to route specific chats/topics to a specialist.
4. Use `/subagents spawn --agent <agent-id> <task>` when you want explicit one-off delegation from the operator side.

Example:

```json
{
  "agents": {
    "defaults": {
      "model": { "primary": "openrouter/anthropic/claude-sonnet-4" }
    },
    "list": [
      {
        "id": "orchestrator",
        "model": { "primary": "openrouter/anthropic/claude-sonnet-4" },
        "system_prompt": "Coordinate tasks and delegate to specialists."
      },
      {
        "id": "coder",
        "model": { "primary": "openrouter/qwen/qwen3-coder" },
        "system_prompt": "You are focused on implementation and tests."
      },
      {
        "id": "researcher",
        "model": { "primary": "openrouter/openai/gpt-4.1" },
        "system_prompt": "You are focused on investigation and synthesis."
      }
    ]
  }
}
```

Notes:

- `agents.list[].id` is the value used by `/subagents spawn --agent <name>`, the `delegate` tool's `agent` argument, and `bindings[].agent_id`.
- Prefer short stable ids (`coder`, `researcher`) so chat commands stay simple.
- Keep specialist prompts narrow; broad prompts overlap and reduce routing clarity.

#### `agents.list[].workspace_path`

Use `workspace_path` when a named agent should run from its own workspace instead of the global one.

Example:

```json
{
  "agents": {
    "list": [
      {
        "id": "coder",
        "model": { "primary": "ollama/qwen2.5-coder:14b" },
        "system_prompt": "Focus on implementation and tests.",
        "workspace_path": "agents/coder"
      }
    ]
  }
}
```

Behavior:

- Relative paths are resolved relative to the directory that contains `config.json`.
- Absolute paths are used as-is.
- Both `/` and `\` are accepted in config; the runtime normalizes separators for the current OS.
- `workspace_path` does not disable `system_prompt`. If both are set, nullclaw keeps the named profile prompt and also loads bootstrap context from that dedicated workspace.
- On first use, nullclaw scaffolds the workspace if missing and creates:
  - `AGENTS.md`
  - `SOUL.md`
  - `IDENTITY.md`
  - `MEMORY.md`

Isolation model:

- The agent's file operations, markdown memory files, and workspace-scoped context use that workspace.
- When `workspace_path` is set, the agent also gets a durable memory namespace of the form `agent:<agent-id>`.
- That namespace is used by:
  - `nullclaw agent --agent <id>`
  - `/subagents spawn --agent <id> ...`
  - routed sessions that resolve to that named agent through `bindings`

Practical effect:

- Two named agents can share the same provider/model family but keep separate durable notes and separate workspaces.
- `workspace_path` does not route chats by itself. Routing still comes from `bindings`, `/bind`, or explicit `--agent` / `/subagents spawn --agent`.

#### `agents.list[].autonomy`

Use `autonomy` when a named agent (for example a guest bound to a single chat peer) must run with a stricter security policy than the global one.

- The object accepts the same keys as the top-level `autonomy` block: `level`, `workspace_only`, `allowed_commands`, `allowed_paths`, `max_actions_per_hour`, `require_approval_for_medium_risk`, `block_high_risk_commands`, `block_medium_risk_commands`, `allow_raw_url_chars`.
- When present it **replaces** the global `autonomy` for that agent. Keys you omit fall back to the secure `AutonomyConfig` defaults (`supervised`, `workspace_only: true`, empty `allowed_paths`, the conservative command allowlist) — they are **not** inherited from the global block. An unknown `level` is rejected at config load.
- The agent always gets its own runtime and its own security policy (rate limit, command allowlist, path scope), even without `workspace_path`.
- Tools that run work under the global policy instead of the agent's, or that reach outside its workspace, are **withheld** from an agent with its own autonomy, because they would act with permissions the agent's policy does not grant:
  - `spawn` — background subagents run under the global autonomy.
  - `schedule` — cron shell jobs run under the scheduler's global shell policy.
  - `image_info` — opens any absolute path with no workspace/policy check, so it is a host-path metadata oracle (existence, size, format).
  - `git` (`git_operations`) — writes to the repository (commit, checkout, reset, …) regardless of `read_only` intent.
  - `screenshot` — captures the host screen, leaking information outside the workspace.
  - MCP tools — each configured MCP server is spawned as a child process and its tools are proxied without consulting the agent's policy.
  - `delegate` — it can name any configured agent and run that agent's provider and model with the operator's API key, so a guest could spend other agents' keys and send its content to providers it was never given.

  The `cron_*` tools are not part of the agent tool set at all.
- Slash commands that touch the shared configuration, write outside the workspace, or read host state are gated:
  - `/config` (`get`, `set`, `unset`, `apply`, `reload`, `validate`) is refused. It reads or rewrites the shared `config.json` under the global policy, which would leak provider keys and channel tokens or let the guest weaken the main agent's `autonomy`/`security` blocks.
  - `/capabilities` reports only the agent's own runtime tools; it no longer reads the shared `config.json` to list configured channels and tools.
  - `/model` still switches the model for that agent's own session, but no longer persists `agents.defaults.model.primary` to the global config, and the interactive provider/model menu does not read the shared `config.json` — it falls back to the public model list instead of the global provider keys.
  - `/export` is refused: it takes an arbitrary absolute path and truncates/creates it, i.e. a whole-host file-write primitive reachable from a bound chat peer.
  - Telegram `/bind` is refused when the peer is currently routed to an agent with its own autonomy. Otherwise the guest could `/bind clear` back to the default route or `/bind <other-agent>` to move to an unrestricted agent, escaping the restricted one. (`/bind status` stays read-only.)
  - Every other slash command is session-local (model, think, verbose, reasoning, usage, cost, queue, tts, focus/unfocus/dock/activation/send, session ttl, context, memory, skills, debug, stop, compact, doctor), or operates on the agent's own subagents — which are unavailable to it because the `spawn` tool is withheld (`/subagents spawn`, `/steer`, `/tell`, `/agents`, `/kill`, `/poll` all report the subagent manager is disabled). `/bash`, `/approve`, `/exec` and `/elevated` still run through the agent's own shell tool and policy, so the confinement below applies to them.
- Outbound attachments are confined: an outbound reply may only attach local files named by an **absolute** path that resolves (symlinks followed) inside the agent's workspace (plus its own `allowed_paths`). Relative targets are refused, because the channel uploader (`curl --form file=@<target>`) resolves them against its own process cwd rather than the workspace, so the uploaded file need not be the one the check resolved. Legacy reply markers (`[IMAGE:…]`, `[DOCUMENT:…]`, `[FILE:…]`, `[PHOTO:…]`, `[VIDEO:…]`, `[AUDIO:…]`, `[VOICE:…]`) whose target escapes the workspace or is relative are dropped and logged before the reply is sent, on every channel that uploads such markers (Telegram, Max, Signal, …). Remote `http(s)` URLs name no local file and are unaffected. This is a text-only exfiltration path that does not go through tool calls, so it also applies to `read_only`.
- The shell tool is confined to the agent's workspace. The command is word-split on every byte the shell treats as IFS whitespace (space, tab, newline, vertical tab, form feed), and every resulting argument that names a path (absolute, `..` traversal or `~`) is rejected; a control byte anywhere in the command is rejected outright, because the shell splits on it into arguments the check would otherwise not see (`cat x\t/etc/passwd` runs `cat x /etc/passwd`). `$` parameter expansion (`$IFS`, `$HOME`, `$1`, `$@`, …), backslash escapes outside single quotes, and unquoted glob/brace metacharacters are rejected because the shell expands or unescapes them at execution time into text the argument check never sees (`cat $IFS/etc/passwd` and `cat \/etc/passwd` both become `cat /etc/passwd`). Commands that execute code taken from the workspace are refused outright — the package managers and their run/build verbs (`npm`, `pnpm`, `yarn`, `npx`, `bun`, `deno`, `cargo`) and the git subcommands that run a script (`git bisect`, `git submodule`, `git filter-branch`, `git filter-repo`, plus git `-c` config injection and `!`-aliases) — because such code runs with the agent's privileges and ignores the confinement. Beyond that, a confined command may contain only letters, digits, plain spaces, the separators `;`, `|`, `&&`, `||` and the punctuation `-_./,:=+@%^`: every quote, redirection (`<`, `>`), escape, expansion or glob byte is refused, so `cat ''/etc/passwd`, `cat '..'/x` and `cat </etc/passwd` are rejected rather than reinterpreted by the shell. `find` write/exec predicates (`-exec`, `-execdir`, `-ok`, `-okdir`, `-delete`, `-fprint*`, `-fls`) are refused too. The same per-agent autonomy applies to `nullclaw agent --agent <name>`.
- **This shell confinement is a best-effort argument check, not a filesystem jail.** It is defence-in-depth for the common case of no external sandbox (bubblewrap/firejail/docker/landlock), and a command that reaches a host file through a mechanism the check does not model can still slip through. For an untrusted guest, prefer `"level": "read_only"`, which disables **all** tool calls outright, and run the process under an external sandbox.
- Agents without an `autonomy` block keep using the shared global policy.

Example — a guest bound to one Telegram peer, read-only:

```json
{
  "agents": {
    "list": [
      {
        "id": "guest",
        "model": { "primary": "anthropic/claude-haiku-3.5" },
        "system_prompt": "You are a read-only guest. Answer questions, never modify anything.",
        "autonomy": { "level": "read_only" }
      }
    ]
  },
  "bindings": [
    {
      "agent_id": "guest",
      "match": {
        "channel": "telegram",
        "account_id": "main",
        "peer": { "kind": "direct", "id": "123456789" }
      }
    }
  ]
}
```

For an untrusted guest prefer `"level": "read_only"`: it disables all tool calls, and only the confinement above (shell argument check and outbound-attachment check) is relied upon. Use `"level": "supervised"` instead when the guest may act but every medium/high-risk command still needs approval; add `allowed_commands` / `allowed_paths` to grant a narrow, explicit scope. Neither level is a filesystem jail — pair it with an external sandbox for untrusted input.

### `messages.inbound`

- `debounce_ms` delays handling rapid-fire plain-text inbound messages so several short fragments can collapse into one turn.
- Default: `300`.
- Applies to daemon-routed inbound text and the Agent CLI REPL.
- Set `0` to disable it.
- Slash commands and media-bearing inbound messages bypass debounce.
- Telegram keeps its channel-specific split-message merge path: this value is the base window (default 300 ms) for merging split Telegram messages, and near-limit pastes (4000+ bytes or 4+ fragments) wait at least 1500 ms.

Example:

```json
{
  "messages": {
    "inbound": {
      "debounce_ms": 1500
    }
  }
}
```

### `messages.error_reply`

- `policy` controls the user-visible error reply when a daemon-routed inbound turn fails:
  - `always` (default): send every failure.
  - `once` (opt-in): send the first error per chat and failure class, then suppress repeats for `cooldown_mins`.
  - `silent`: never send; failures are only logged.
- `cooldown_mins`: how long a suppressed `once` error stays quiet (default: `240`, i.e. 4 hours). Only applies to `once`.
- The key is the outbound chat scope plus the classified failure kind, so the same kind of error is deduped even when provider details differ.
- Applies to daemon-routed inbound turns. Polling channel loops and the HTTP gateway keep their existing behavior.

Example:

```json
{
  "messages": {
    "error_reply": {
      "policy": "always",
      "cooldown_mins": 240
    }
  }
}
```

### `reliability`

- Configures global retry and failover behavior for LLM providers.
- `provider_retries`: Number of times to retry a failed LLM request (default: 2).
- `provider_backoff_ms`: Initial exponential backoff delay between retries (default: 500).
- `fallback_providers`: List of provider names to try if an unqualified model should fan out beyond the primary provider.
- `model_fallbacks`: Mapping of a model to an ordered list of fallback models. Each fallback may be either another bare model name or an explicit `provider/model` ref.

Example:

```json
{
  "reliability": {
    "provider_retries": 2,
    "provider_backoff_ms": 500,
    "fallback_providers": ["groq", "openai"],
    "model_fallbacks": [
      {
        "model": "anthropic/claude-sonnet-4",
        "fallbacks": ["openai/gpt-4o", "groq/llama-3.3-70b"]
      }
    ]
  }
}
```

Notes:

- Failover order for bare model refs: primary provider first, then each listed `fallback_provider`.
- Provider-qualified fallback refs such as `openai/gpt-4o` route directly to that provider and skip the generic provider fanout.
- `api_keys`: (Optional) List of extra API keys for rotation on rate-limit (429) errors.

### `scheduler`

- Configures the cron scheduler that runs scheduled jobs.
- `enabled`: Master switch for cron scheduling (default: `true`).
- `max_tasks`: Maximum number of jobs the scheduler tracks (default: `64`).
- `max_concurrent`: Parsed and reported by `nullclaw cron status`, but **not currently enforced** — the cron scheduler runs one job at a time (see the note below).
- `agent_timeout_secs`: Hard wall-clock limit, in seconds, on a single cron **agent** job (default: `0` = **no timeout**).

Example:

```json
{
  "scheduler": {
    "enabled": true,
    "max_tasks": 64,
    "max_concurrent": 4,
    "agent_timeout_secs": 900
  }
}
```

#### Why `agent_timeout_secs` matters

Cron jobs are dispatched **serially on a single scheduler thread**. A due job is spawned and awaited before the scheduler looks at the next one, so a job that never exits delays every other scheduled job — including heartbeats — for as long as it hangs. With the default of `0` there is no deadline: the scheduler waits indefinitely for the job's output to reach EOF.

Set a non-zero value on any host that runs scheduled agent jobs:

- Pick a value comfortably above your slowest healthy job, and well below the interval between jobs. A 2-hour cron with a 15-minute cap leaves ample headroom while bounding a stall.
- The timeout covers **agent-type jobs only**. Shell-type cron jobs are already capped separately at 60 seconds and ignore this value.
- The limit is read once at daemon startup, alongside the rest of `scheduler`. There is no SIGHUP reload — **restart the daemon for a change to take effect**.
- On expiry the job's child process is killed and the run is recorded as an error, so the next tick proceeds normally.

Known limitation: the kill is delivered to the job's direct child process only, not to its descendants. A grandchild that inherits the job's output pipe can keep the scheduler waiting past the timeout.

### `identity` (AIEOS v1.1)

Use this section when you want the runtime identity to come from an AIEOS document.
When configured, nullclaw injects the parsed AIEOS content into the system prompt alongside workspace identity files such as `AGENTS.md` and `IDENTITY.md`:

```json
{
  "identity": {
    "format": "aieos",
    "aieos_path": "./identity/aieos.identity.json"
  }
}
```

You can also inline the same document directly in config:

```json
{
  "identity": {
    "format": "aieos",
    "aieos_inline": "{\"identity\":{\"names\":{\"first\":\"nullclaw-assistant\"},\"bio\":\"General-purpose autonomous assistant\"},\"linguistics\":{\"style\":\"concise\"},\"motivations\":{\"core_drive\":\"Help the operator finish tasks safely\"}}"
  }
}
```

Minimal AIEOS v1.1 example file (`identity/aieos.identity.json`):

```json
{
  "identity": {
    "names": {
      "first": "nullclaw-assistant"
    },
    "bio": "General-purpose autonomous assistant"
  },
  "linguistics": {
    "style": "concise"
  },
  "motivations": {
    "core_drive": "Help the operator finish tasks safely"
  }
}
```

Notes:

- AIEOS payloads use top-level sections such as `identity`, `psychology`, `linguistics`, `motivations`, and `capabilities`.
- Prefer `aieos_path` for maintainability and version control readability.
- Use `aieos_inline` only when you need a fully self-contained single config file.
- Keep `identity.format` aligned with the payload source (`aieos`).
- Relative `aieos_path` values are resolved against the active workspace first, then against the current working directory.

### `channels`

- Channel config lives under `channels.<name>`.
- Multi-account channels typically use an `accounts` wrapper.

External channel plugin example:

```json
{
  "channels": {
    "external": {
      "accounts": {
        "wa-web": {
          "runtime_name": "whatsapp_web",
          "transport": {
            "command": "nullclaw-plugin-whatsapp-web",
            "args": ["--stdio"],
            "timeout_ms": 10000,
            "env": {
              "PLUGIN_TOKEN": "secret"
            }
          },
          "config": {
            "bridge_url": "http://127.0.0.1:3301",
            "allow_from": ["*"]
          }
        }
      }
    }
  }
}
```

External channel notes:

For the full protocol, lifecycle, metadata conventions, and plugin author
contract, see [External Channel Plugins](./external-channels.md).

- `runtime_name` is the nullclaw runtime channel id used by routing, bindings, session keys, and outbound dispatch. It must not reuse a built-in channel name or any runtime name already claimed by another configured channel.
- `transport.command` plus optional `transport.args` starts the plugin as a child process over line-delimited JSON-RPC on stdio.
- `transport.timeout_ms` bounds host->plugin RPC waits; nullclaw still caps control-plane waits internally so one broken plugin cannot stall supervision for minutes.
- `transport.env` is forwarded only to the plugin process.
- `config` must be a JSON object; it is forwarded to the plugin `start` request as `params.config`.
- Plugins must answer `get_manifest`, handle `start`/`send`/`stop`; `health` is recommended so supervision can detect disconnected sidecars instead of only live processes.
- `get_manifest.result` must contain `protocol_version: 2`; `capabilities.health`, `capabilities.streaming`, `capabilities.send_rich`, `capabilities.typing`, `capabilities.edit`, `capabilities.delete`, `capabilities.reactions`, and `capabilities.read_receipts` are optional capability bits.
- `health.result` must report an explicit boolean (`healthy`) or explicit health signals (`ok`, `connected`, `logged_in`); an empty object is treated as invalid. For QR/device-link style channels, this is the place to report `connected: false` or `logged_in: false` while background auth is still in progress.
- `start.params` now has a nested `runtime` object with `name`, `account_id`, and host-owned `state_dir`.
- `start.result` must contain `started: true`; `start` should return promptly after local initialization instead of blocking on QR scans or human login. `send`, `send_rich`, `edit_message`, `delete_message`, and typing/message-action RPCs must return `result.accepted: true` when the plugin actually accepts the action. A JSON-RPC success envelope by itself is not enough.
- `send.params` now has nested `runtime` and `message` objects; text payloads use `message.text`.
- If a plugin declares both `capabilities.edit=true` and `capabilities.delete=true`, `send.result` may also include `message_id` or `message { target?, message_id }`; that lets nullclaw keep a tracked draft updated on channels that do not support native `.chunk` streaming.
- If `capabilities.streaming=true`, nullclaw may emit `.chunk` staged `send` events during model streaming. If it is absent or `false`, nullclaw will only emit final responses.
- If `capabilities.send_rich=true`, the host may call `send_rich` with nested `runtime` and `message { target, text, attachments, choices }`.
- If `capabilities.typing=true`, the host may call `start_typing` / `stop_typing` with nested `runtime` plus `recipient`.
- If `capabilities.edit=true` / `capabilities.delete=true`, the host may call `edit_message` / `delete_message`.
- If `capabilities.reactions=true` or `capabilities.read_receipts=true`, the host may call `set_reaction` and `mark_read`.
- `inbound_message.params.message` must include `sender_id`, `chat_id`, and `text`; if `metadata` is present it must be a JSON object, and if `media` is present it must be an array of non-empty strings.
- Include `metadata.peer_kind` plus `metadata.peer_id` when you want routing/bindings to distinguish direct vs group peers for unknown channels.
- Unknown/external channels can also set `metadata.is_group`, `metadata.is_dm`, or `metadata.typing_recipient`; nullclaw promotes that metadata into prompt conversation context and processing-indicator routing.
- A reference bridge adapter for the PR #265 WhatsApp Web sidecar lives in `examples/whatsapp-web/nullclaw-plugin-whatsapp-web`.
- Production companion repositories now live out of tree: [nullclaw/nullclaw-channel-baileys](https://github.com/nullclaw/nullclaw-channel-baileys) and [nullclaw/nullclaw-channel-whatsmeow-bridge](https://github.com/nullclaw/nullclaw-channel-whatsmeow-bridge).
- `nullclaw channel start external` starts the first configured external account; `nullclaw channel start <runtime_name>` targets a specific configured runtime name such as `whatsapp_web`.

Telegram example:

```json
{
  "channels": {
    "telegram": {
      "accounts": {
        "main": {
          "bot_token": "123456:ABCDEF",
          "webhook_secret": "replace-with-random-telegram-webhook-secret",
          "allow_from": ["YOUR_TELEGRAM_USER_ID"]
        }
      }
    }
  }
}
```

WeChat example:

```json
{
  "channels": {
    "wechat": {
      "accounts": {
        "main": {
          "callback_token": "wechat-callback-token",
          "encoding_aes_key": "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
          "app_id": "wx1234567890abcdef",
          "app_secret": "wechat-app-secret",
          "allow_from": ["openid_123"]
        }
      }
    }
  }
}
```

WeChat notes:

- NullClaw already supports WeChat as a built-in webhook channel; you do not need an external plugin to receive Official Account callbacks.
- The gateway webhook path is `/wechat`. Use `?account_id=<id>` when you have multiple configured WeChat accounts.
- `callback_token` is required for signature verification.
- `encoding_aes_key` is optional but required when your WeChat callback is configured for `encrypt_type=aes`.
- `app_id` and `app_secret` are optional unless you want outbound active-message delivery through the WeChat custom message API.
- An empty `allow_from` denies inbound messages; list trusted OpenIDs explicitly, or use `"*"` only for an intentionally open account.
- Build with `-Dchannels=wechat` (or `-Dchannels=all`) if your binary was compiled without the WeChat channel.

#### Weixin — WeChat iLink Bot (QR Code Login)

The `weixin` channel authorizes a WeChat iLink bot by QR code. This is separate
from the `wechat` Official Account channel above, which uses signed webhooks.

First, log in and obtain a token:

```bash
nullclaw auth login weixin
```

This renders a QR code in the terminal. Scan it with WeChat and confirm the
authorization on your phone. The command saves the resulting `token` and, when
the service returns a non-default host, its `base_url` to your config.

After login, edit the Weixin account entry updated by the command to set an
explicit `allow_from` list. On a new config this is the inline entry shown
below; an existing `accounts` object keeps its layout. When supplied, the login
command's `--proxy` value is saved in the same account and reused for runtime
API requests.

```json
{
  "channels": {
    "weixin": {
      "account_id": "default",
      "token": "<bot-token-from-qr-login>",
      "base_url": "https://ilinkai.weixin.qq.com/",
      "proxy": null,
      "allow_from": ["<your-wechat-user-id>"]
    }
  }
}
```

Weixin channel fields:

| Field | Default | Description |
|-------|---------|-------------|
| `account_id` | `"default"` | Internal account identifier used by routing and session keys |
| `token` | `""` | Bot token from `nullclaw auth login weixin` (required) |
| `base_url` | `https://ilinkai.weixin.qq.com/` | Absolute HTTPS iLink API URL without query/fragment (may change after region redirect) |
| `proxy` | `null` | Optional `http://`, `https://`, or `socks5://` proxy URL for runtime API requests |
| `allow_from` | `[]` | Exact WeChat user IDs allowed to message the bot; configure this explicitly |

Notes:

- No inbound messages are accepted until `allow_from` lists trusted user IDs
  (or the intentional wildcard `"*"`).
- `nullclaw auth status weixin` reports whether a non-empty token is configured;
  it does not probe the remote iLink session.
- Use `nullclaw auth logout weixin` to remove the configured token.
- Use `nullclaw auth login weixin --proxy http://localhost:7890` when a proxy is
  required; the command persists it for both login and runtime API requests.
- Build with `-Dchannels=weixin` (or `-Dchannels=all`) if your binary was compiled without it.
- `nullclaw gateway` starts and supervises the configured `weixin` polling loop.
- The current adapter treats inbound conversations as direct messages and sends
  text replies; group routing and media/file delivery are not implemented.

Telegram forum topics:

- Topic session isolation is automatic; there is no separate `topic_id` field under `channels.telegram`.
- The practical operator flow is:
  1. configure named agent profiles under `agents.list`
  2. open the target Telegram chat or forum topic
  3. run `/bind <agent>`
- If you want a specific forum topic to use a specific agent, configure it in `bindings` with `match.peer.id = "<chat_id>:thread:<topic_id>"`.
- If you also want a fallback agent for the rest of the same Telegram group, add another binding for the plain group id `"<chat_id>"`.
- `/bind status` shows the current effective route and the available agent ids.
- `/bind clear` removes only the exact binding for the current account/chat/topic and lets routing fall back to the broader match.
- `/bind` writes an exact `bindings[]` entry for the current Telegram account and peer.
- `/bind status` distinguishes an exact local override from an inherited broader fallback.
- Topic-specific bindings win over group fallback by route priority; the order in `bindings[]` does not matter.
- Telegram menu visibility for `/bind` is controlled by `channels.telegram.accounts.<id>.binding_commands_enabled`.

Example:

```json
{
  "bindings": [
    {
      "agent_id": "coder",
      "match": {
        "channel": "telegram",
        "account_id": "main",
        "peer": { "kind": "group", "id": "-1001234567890:thread:42" }
      }
    },
    {
      "agent_id": "orchestrator",
      "match": {
        "channel": "telegram",
        "account_id": "main",
        "peer": { "kind": "group", "id": "-1001234567890" }
      }
    }
  ]
}
```

In that setup, topic `42` routes to `coder`, while the rest of the forum falls back to `orchestrator`.

> **Peer ID format note**: Topic peer IDs in `bindings` must use the canonical `:thread:N` format (e.g. `"-1001234567890:thread:42"`). The legacy `#topic:N` format (e.g. `"-1001234567890#topic:42"`) is auto-converted at load time but is **deprecated** — a warning will appear in the logs. If you see `#topic:` in nullclaw's log output, convert it to `:thread:` when copying into your config. The `/bind` command always saves in the correct format automatically.

Named agent profiles and bindings are separate concerns: `agents.list` defines reusable profiles, while `bindings` decides which profile is used for a given chat/topic.

Minimal end-to-end example:

```json
{
  "agents": {
    "list": [
      {
        "id": "orchestrator",
        "provider": "openrouter",
        "model": "anthropic/claude-sonnet-4"
      },
      {
        "id": "coder",
        "provider": "ollama",
        "model": "qwen2.5-coder:14b",
        "system_prompt": "You are the coding agent for this topic."
      }
    ]
  },
  "channels": {
    "telegram": {
      "accounts": {
        "main": {
          "bot_token": "123456:ABCDEF",
          "webhook_secret": "replace-with-random-telegram-webhook-secret",
          "allow_from": ["YOUR_TELEGRAM_USER_ID"],
          "draft_previews": false,
          "tool_progress": true,
          "rich_messages": false,
          "binding_commands_enabled": true,
          "topic_commands_enabled": true,
          "topic_map_command_enabled": true,
          "commands_menu_mode": "scoped"
        }
      }
    }
  },
  "bindings": [
    {
      "agent_id": "orchestrator",
      "match": {
        "channel": "telegram",
        "account_id": "main",
        "peer": { "kind": "group", "id": "-1001234567890" }
      }
    }
  ]
}
```

Operator flow:

- Send `/bind coder` inside the target forum topic.
- `nullclaw` writes a new exact `bindings[]` entry to `~/.nullclaw/config.json` for that topic and Telegram account.
- The next message in that topic uses the new routed agent profile.
- `nullclaw` must have write access to `~/.nullclaw/config.json` for `/bind` to persist changes.

About `draft_previews`:

- `draft_previews=false` is the default and recommended setting.
- When disabled, Telegram still shows activity/typing while the reply is being generated, but it does not use ephemeral `sendMessageDraft` previews.
- Set `draft_previews=true` only if you explicitly want live partial previews and accept that Telegram may hide and replace those drafts before the final message lands.

About `tool_progress`:

- `tool_progress=true` is the default. While a live draft has no answer text yet (a long turn with many tool-call rounds), the draft shows what the agent is doing instead of a bare elapsed-time heartbeat:

  ```
  ⏳ 121s · 11 tool calls
  🔧 web_search
  🔧 web_fetch example.com
  ❌ web_fetch failed
  ```

- The header shows elapsed seconds and the number of tool calls so far. Below it, up to five recent tool lines are shown; failures (`❌`) are kept visible over successes when the list is trimmed. Every line is capped at ~60 characters.
- Hints are deliberately conservative: `web_fetch`/`http_request` show the host only, `web_search` shows a truncated query (≤40 chars), file tools show the file's basename, and shell/exec and unknown tools show the tool name only — never the raw command. Every hint is HTML-escaped for Telegram's HTML parse mode.
- The first tool call of a turn refreshes the draft immediately, even if no text or reasoning has streamed yet, so the user sees what the agent started doing right away. Later tool events in the same batch honour the existing draft flush throttle (4s) so `sendMessageDraft` is not rate-limited; an event that lands inside the throttle is kept pending and rendered on the next typing heartbeat instead of being dropped.
- Once real answer text streams, the draft shows that text exactly as before; tool lines are never mixed into the answer text, the final reply, or session history. The draft is released before the final reply is delivered, so progress refreshes (including the elapsed-time heartbeat) stop immediately and the tool block is never re-sent after the answer is visible.
- A streamed reasoning quote (`/reasoning stream`) is not answer text: while tools run the draft shows the tool block in place of the quote, and switches to the answer text once it arrives.
- The block renders on both Telegram delivery paths - the polling loop and the gateway/webhook path.
- `tool_progress=false` keeps the previous behaviour but drops the misleading `Current size: 0 bytes` line: the draft shows plain elapsed time and the "still being prepared" note.

About `rich_messages`:

- `rich_messages=false` is the default. When enabled, replies are sent with the Bot API `sendRichMessage` method using GFM Markdown, so the model can use headings, tables, task lists, footnotes, `==mark==`, `||spoiler||` and `$math$`.
- It is off by default because some Desktop/Web/Android and third-party clients render rich messages as an unsupported placeholder.
- Any rich send or edit that fails falls back to the normal HTML/plain-text path, so replies are never lost.
- Tables wider than 20 columns are sent as a code block instead of a rich table.
- Plain-text line breaks in rich replies are emitted as GFM hard breaks so multi-line output such as `/status` stays multi-line; fenced and indented code blocks, multiline inline code spans, and tables retain their existing structure. Code contents (including heredoc delimiters) receive no added trailing spaces. Inline code spans only match within the same Markdown paragraph; an unmatched backtick cannot consume a following code fence. Lines beginning with emphasis, inline code, or ordinary numbers keep their visual line breaks.
- Escaping caveat: the Bot API documents one rich-Markdown escape (`\#hashtag`) and states Rich Markdown can contain arbitrary HTML. `\<` escaping of raw `<` in model output (so it is not parsed as an HTML tag) follows GFM/CommonMark, where any ASCII punctuation may be backslash-escaped. If a client does not honour that escape, a stray raw HTML tag in a reply renders as a literal tag instead of showing the tag text (cosmetic, and only reachable when the model emits raw HTML despite the prompt telling it not to). `==`, `||` and `$math$` are passed through verbatim by design.

About `account_id`:

- `account_id` identifies the configured Telegram account entry, not a topic and not an agent.
- In the standard `channels.telegram.accounts` layout, the object key becomes the account id. For example, `accounts.main` means `account_id = "main"`.
- In `bindings`, `match.account_id` restricts a binding to one specific Telegram account.
- If `match.account_id` is omitted, the binding can match any Telegram account for that channel.
- Different account ids are only useful when the same nullclaw instance runs multiple Telegram bot accounts/tokens.

### Web UI / Browser Relay

Use `channels.web` for browser UI / extension traffic over WebSocket (`/ws` by default).

Example:

```json
{
  "channels": {
    "web": {
      "accounts": {
        "default": {
          "transport": "local",
          "listen": "127.0.0.1",
          "port": 32123,
          "path": "/ws",
          "auth_token": "replace-with-long-random-token",
          "message_auth_mode": "pairing",
          "allowed_origins": ["http://localhost:5173"]
        }
      }
    }
  }
}
```

Practical rules:

- Keep `listen = "127.0.0.1"` for the pairing-first local UX.
- In local transport, unauthenticated WebSocket upgrade is allowed only on loopback. This is what lets a UI connect first and then send `pairing_request`.
- Local loopback pairing no longer depends on a fixed shared code. `pairing_request` may omit `payload.pairing_code`, and legacy loopback clients that still send `123456` remain compatible.
- If you change `listen` to `0.0.0.0` or another non-loopback address, the WebSocket upgrade must already include the channel token:
  - `ws://host:32123/ws?token=<auth_token>`
  - or `Authorization: Bearer <auth_token>`
- For non-loopback bind, do not expect local `pairing_request` to work before the socket is authenticated. The pairing-first flow is loopback-only by design.
- `message_auth_mode = "pairing"` means each `user_message` must carry the UI `access_token` returned by the pairing flow.
- `message_auth_mode = "token"` is local-transport only and requires a stable token from config or env. In this mode, the UI sends `auth_token` on each `user_message` instead of a pairing JWT.
- `auth_token` hardens the WebSocket upgrade and becomes mandatory for non-loopback bind.
- Use `/ws` for the WebSocket endpoint. `/pair` belongs to the HTTP gateway API, not the web channel WebSocket flow.
- For headless/LAN access, the safest operator path is still SSH tunnel or reverse proxy in front of a loopback-bound web channel.

Remote/headless example:

```json
{
  "channels": {
    "web": {
      "accounts": {
        "default": {
          "transport": "local",
          "listen": "0.0.0.0",
          "port": 32123,
          "path": "/ws",
          "auth_token": "replace-with-long-random-token",
          "message_auth_mode": "token",
          "allowed_origins": ["https://chat-ui.example.com"]
        }
      }
    }
  }
}
```

Effect on delivery:

- Incoming Telegram updates are handled by the account that received them.
- Routing uses that same `account_id`, so `match.account_id = "main"` matches only messages received through `channels.telegram.accounts.main`.
- Replies go back out through the same Telegram account/runtime that handled the message.
- If one binding uses `account_id = "main"` and another uses `account_id = "sub"`, they apply to different configured Telegram accounts; this does not split a single Telegram account's traffic by itself.

Rules:

- Empty `allow_from` denies inbound messages on allowlist-based channels. Set explicit IDs/OpenIDs for a private bot.
- `allow_from: ["*"]` allows all sources on allowlist-based channels; use it only when you intentionally want an open bot.
- Telegram webhooks require `channels.telegram.accounts.<id>.webhook_secret` and Telegram's `X-Telegram-Bot-Api-Secret-Token` header to match.
- Teams inbound webhooks are authenticated with Bot Framework JWT bearer tokens against Microsoft's OpenID metadata. `channels.teams.accounts.<id>.webhook_secret` is optional and, when set, acts as an additional `X-Webhook-Secret` check.

Max example:

```json
{
  "channels": {
    "max": {
      "accounts": {
        "main": {
          "bot_token": "MAX_BOT_TOKEN",
          "allow_from": ["YOUR_MAX_USER_ID"],
          "group_allow_from": ["YOUR_MAX_USER_ID"],
          "group_policy": "allowlist",
          "mode": "webhook",
          "webhook_url": "https://bot.example.com/max?account_id=main",
          "webhook_secret": "replace-with-random-secret",
          "require_mention": true,
          "streaming": true,
          "interactive": {
            "enabled": true,
            "ttl_secs": 900,
            "owner_only": true
          }
        }
      }
    }
  }
}
```

Max notes:

- `channels.max.accounts` is an object of account entries; each object key is the `account_id` that distinguishes multiple Max bots.
- Prefer `mode = "webhook"` for production. Max documents long polling as suitable for development/testing, while webhooks are the recommended production path.
- `webhook_url` must be HTTPS.
- For multi-account webhook setups, give each account either a unique `webhook_secret` or a unique `account_id` query in the webhook URL, for example `/max?account_id=main`.
- `allow_from` and `group_allow_from` accept either Max `user_id` values or usernames. `user_id` is the stable choice for bindings and routing.
- `require_mention = true` only affects group chats. Direct messages and `bot_started` deep links still work normally.
- Max inline buttons are one-shot in nullclaw: after a valid click, the original keyboard is cleared to avoid stale buttons.

### Discord

Discord example:

```json
{
  "channels": {
    "discord": {
      "accounts": {
        "default": {
          "token": "YOUR_DISCORD_BOT_TOKEN",
          "intents": 37377,
          "allow_from": ["YOUR_DISCORD_USER_ID"]
        }
      }
    }
  }
}
```

Set `allow_from` explicitly. An omitted or empty `allow_from` list denies inbound messages; use `["*"]` only when you intentionally want an open bot.

Enable MESSAGE CONTENT INTENT in the Discord Developer Portal if you want the bot to process ordinary guild messages. Without it, Discord omits message content for most guild traffic; direct messages and messages that mention the bot still include content.

Gateway intents (`intents`) is a bitmask. Default 37377 = GUILDS (1) + GUILD_MESSAGES (512) + MESSAGE_CONTENT (32768) + DIRECT_MESSAGES (4096). Calculate custom intents from https://discord.com/developers/docs/topics/gateway#gateway-intents.

Discord setup flow:
1. Create application at https://discord.com/developers/applications
2. Bot section → Add Bot → Reset Token (copy immediately)
3. Privileged Gateway Intents → Enable MESSAGE CONTENT INTENT → Save
4. OAuth2 → URL Generator → Scopes: `bot`
5. Bot Permissions: Send Messages, Read Message History, Read Messages/View Channels
6. Copy URL, open in browser, select server, authorize

The current Discord integration does not require extra OAuth scopes or elevated permissions such as `Administrator`.

Multi-bot setup uses `accounts` wrapper. Each `account_id` creates an independent Discord bot connection with separate session state and routing:

```json
{
  "channels": {
    "discord": {
      "accounts": {
        "production": {
          "token": "PRODUCTION_BOT_TOKEN",
          "intents": 37377,
          "allow_from": ["ADMIN_USER_ID"]
        },
        "testing": {
          "token": "TESTING_BOT_TOKEN",
          "intents": 37377,
          "allow_from": ["DEV_USER_ID"]
        }
      }
    }
  }
}
```

Channel-specific bindings use `peer.kind = "channel"` with Discord channel IDs (enable Developer Mode → right-click channel → Copy ID):

```json
{
  "bindings": [
    {
      "agent_id": "coder",
      "match": {
        "channel": "discord",
        "account_id": "default",
        "peer": {"kind": "channel", "id": "CHANNEL_ID_HERE"}
      }
    }
  ]
}
```

Direct message bindings use `peer.kind = "direct"` with user IDs:

```json
{
  "bindings": [
    {
      "agent_id": "personal",
      "match": {
        "channel": "discord",
        "account_id": "default",
        "peer": {"kind": "direct", "id": "USER_ID_HERE"}
      }
    }
  ]
}
```

Parameters:
- `token` (required) - Bot token from Discord Developer Portal
- `intents` (default: 37377) - Gateway intents bitmask
- `allow_bots` (default: false) - Allow messages from other bots. Messages posted by the bot itself are always ignored, even when this is enabled
- `allow_from` (default: []) - User ID allowlist. An omitted or empty list denies inbound messages. `["*"]` explicitly allows all users
- `require_mention` (default: false) - Require bot mention in guilds to respond
- `guild_id` (optional) - Reserved for Discord server scoping; current runtime does not enforce it

NullClaw splits messages >2000 characters (Discord API limit).

Verification:
```bash
nullclaw channel start discord
nullclaw channel status
```

`nullclaw channel start discord` starts only the first configured Discord account. For multi-account validation, run `nullclaw gateway` and send a test message to each configured bot.

Common issues:
- Bot only responds in DMs or explicit mentions: enable MESSAGE CONTENT INTENT, then re-invite the bot if needed
- "Privileged Intents" error: enable MESSAGE CONTENT INTENT in Discord Developer Portal; verified apps may also need Discord approval
- Bot offline: Check `nullclaw service status`, verify token hasn't been reset
- No response in guilds: Check `require_mention` setting, verify Read Messages permission

### Slack

Slack example:

```json
{
  "channels": {
    "slack": {
      "accounts": {
        "default": {
          "bot_token": "xoxb-YOUR_BOT_TOKEN",
          "app_token": "xapp-YOUR_APP_TOKEN",
          "channel_id": "C0123456789",
          "allow_from": ["U0123456789"],
          "reply_to_mode": "all",
          "streaming": true
        }
      }
    }
  }
}
```

Parameters:
- `mode` (default: `socket`) - `socket` uses Socket Mode (needs `app_token`); `http` receives Events API webhooks at `webhook_path` and needs `signing_secret`
- `bot_token` (required) - Bot User OAuth token (`xoxb-...`)
- `app_token` (optional) - App-level token (`xapp-...`), required for `mode = socket`
- `signing_secret` (optional) - Required for `mode = http`
- `webhook_path` (default: `/slack/events`) - Webhook path for `mode = http`
- `channel_id` (optional) - Channel polled by the history fallback when Socket Mode is unavailable
- `allow_from` (default: []) - User ID allowlist. An omitted or empty list denies inbound messages; use `["*"]` only when you intentionally want an open bot
- `dm_policy` (default: `pairing`) - `allow`, `deny`, `allowlist`/`pairing`
- `group_policy` (default: `mention_only`) - `open`, `allowlist`, `mention_only`
- `reply_to_mode` (default: `off`) - `off` threads only when the triggering message is already a thread reply; `all` always replies in a thread
- `implicit_thread_mention` (default: `true`) - A reply in a channel thread the bot has already posted into counts as a mention under `group_policy = mention_only`, so the conversation can continue without re-mentioning the bot. Top-level messages and DMs are unaffected
- `streaming` (default: `false`) - Show the reply while it is still being generated. See below
- `long_reply_file_threshold_chunks` (default: `9`) - When a final reply needs more chunks than this, send only the readable first chunk and upload the complete reply as `reply.md` to the same thread/DM. `0` disables the upload. See below
- `status_reactions` (default: `true`) - Show the task lifecycle as a reaction on the message that triggered it: `accepted`, `running`, then `done` or `failed`. Needs the `reactions:write` scope. See below
- `reaction_emojis` (default: `eyes`, `hourglass_flowing_sand`, `white_check_mark`, `x`) - Per-state overrides for `accepted`, `running`, `done`, `failed`. Slack takes short names, not the emoji themselves; an empty string clears the reaction for that state
- `slash_command` (default: disabled) - Single-command Slack integration: register one slash command and handle its text like a normal message. See below

#### Slack media

Replies can attach files with the same markers the Telegram channel uses:
`[IMAGE:/abs/path.png]`, `[FILE:/abs/path.pdf]` (also `DOCUMENT`, `VIDEO`,
`AUDIO`, `VOICE`). Slack uploads each marker through
`files.getUploadURLExternal` -> raw upload -> `files.completeUploadExternal`,
posts the file into the same channel and thread, and removes the marker from the
text. Only local paths are accepted; each file is capped at 20 MB. Unlike
Telegram, Slack requires nullclaw to read the file itself, so `http(s)` URLs in
markers are rejected instead of being fetched server-side.

Inbound `file_share` messages are no longer dropped in Socket Mode (including
the history-polling fallback). With the bot token, nullclaw downloads
`url_private` files up to 20 MB:

- images are saved to a temp file and passed to the vision path as
  `[IMAGE:/tmp/...]`
- audio clips (including Slack clips, which report `subtype: "slack_audio"` with
  a `video/*` MIME) go through the shared `tools.media.audio` transcription
  pipeline and arrive as `[Voice]: <transcript>`; without a configured
  transcription provider they degrade to an `[ATTACHMENT:audio ...]` marker
- every other file is saved and passed as `[FILE:/tmp/...]`
- the message caption is processed as usual

Socket Mode downloads run on an inbound worker so the websocket reader keeps
acknowledging envelopes and answering pings, and a redelivered event (same
`event_id`) is processed only once.

Required bot scopes: add `files:read` for inbound downloads and `files:write`
for outbound uploads (plus `chat:write`). Downloads are pinned to Slack's own
HTTPS hosts and do not follow redirects, so the bot token is never sent
elsewhere.

The webhook path (`mode = http`) does not process attachments: Slack expects an
acknowledgement within three seconds, which a download cannot meet, so
`file_share` events are acknowledged and skipped there, caption included. Use
`mode = socket` when inbound media matters.

#### Slack slash command

Slack only delivers a slash command when the app registers it, and Slack's UI
supports one command per registration. Set `slash_command.enabled = true` and
register the same name in your Slack app:

```json
"slash_command": { "enabled": true, "name": "nullclaw" }
```

`name` is the command without the leading `/` (default `nullclaw`); the match is
case-insensitive. In Socket Mode the command's request URL in the app config is
ignored, because Slack sends the payload over the WebSocket.

Type `/nullclaw <message>` and the text after the command is handled exactly as
if the user had typed it in that channel. Every normal command works, including
`/nullclaw /stop`, which interrupts the running turn for that channel (or the
user's DM) the same way a typed `/stop` does; because a slash command is always
top-level it also interrupts a turn running inside a thread under that channel.
The command is an explicit invocation of the app, so it is treated as a mention:
the `allow_from` and DM/group allowlist gates still apply, but `group_policy =
mention_only` does not block it. Restrict `allow_from` (or the group allowlist)
if you do not want every admitted member to be able to drive the agent from a
mention-only room. An empty command shows a short usage reply; an unauthorized
sender gets a short ephemeral refusal, and a command name that does not match the
configured `name` is logged and answered with an ephemeral notice instead of
being silently dropped.

Add to the app manifest under `features` (Socket Mode):

```json
"features": {
  "slash_commands": [
    {
      "command": "/nullclaw",
      "description": "Send a message to nullclaw",
      "should_escape": false
    }
  ]
}
```

and add the `commands` scope to `oauth_config.scopes.bot`.

#### Slack status reactions

With `status_reactions = true`, nullclaw reacts to the triggering message with
`reactions.add` and switches the reaction as the turn progresses, then removes it
on the final state when that state's emoji is empty. Slack adds reactions instead
of replacing them, so the previous state is removed explicitly.

Messages steered into an active turn also receive that turn's final reaction,
including when the turn is interrupted or a follow-up fails. Each inserted
message is finalized on its original channel and account, even when accounts or
channels share a session. An empty `done` or `failed` removes its acknowledgement.

Give `accepted` and `running` the same name to keep the traffic to one reaction
per turn:

```json
"status_reactions": true,
"reaction_emojis": {
  "accepted": "hourglass_flowing_sand",
  "running": "hourglass_flowing_sand",
  "done": "",
  "failed": "warning"
}
```

An app without `reactions:write` answers `missing_scope`; nullclaw logs it once
and stops trying for that account.

#### Slack streaming replies

With `streaming = true`, nullclaw publishes the model output progressively instead of
waiting for the complete reply. Two transports are used, chosen per reply target:

- **Native streaming** - for a threaded target (`reply_to_mode = all`, an inbound thread
  reply, or an assistant thread) nullclaw calls `chat.startStream`, then throttled
  `chat.appendStream` calls, then `chat.stopStream`. Slack only accepts a stream inside a
  thread, so a top-level target never uses this path.
- **Edited message** - for top-level targets, and whenever Slack rejects the native
  methods, nullclaw posts one message with `chat.postMessage` and updates it with
  throttled `chat.update` calls.

Deltas are coalesced (at most one API call per second per turn) to stay inside Slack's
per-method rate limits. Tool-call markup is always stripped before anything is sent. If a
native streaming call fails with a permanent error (`channel_type_not_supported`,
`missing_scope`, `invalid_thread_ts`, ...), nullclaw stops trying the native methods for
that account and uses edited messages from then on. If an append returns
`msg_too_long`, live updates continue through the edited-message transport with a
bounded preview. The preview retains the newest text within Slack's escaped-text
budget; each final chunk is entity-budgeted to fit Slack's limits, delivering the
initial message and up to eight follow-ups (overflow beyond the follow-up cap is
logged and marked with a truncation notice on the final chunk). When the final
reply needs more than `long_reply_file_threshold_chunks` chunks (default 9),
nullclaw sends only the readable first chunk and uploads the full Markdown reply
as `reply.md` to the same thread/DM instead of posting follow-ups. If the upload
fails it falls back to the chunked delivery above. The upload reuses the
existing `files:write` scope; no new scope is required.

About `tool_progress` on Slack: on by default. While a turn runs, nullclaw sets the
assistant status to `is working…` and passes the newest tool operation as a
`loading_messages` entry (for example `🔧 web_fetch example.com`), so a long tool-heavy turn
shows what the agent is doing. The status is refreshed every ~6 seconds to stay ahead of
Slack's two-minute status timeout, and updates coalesce to at most one API call per second
per thread. Hints are conservative: file paths are reduced to basenames, URLs to hosts,
search queries are truncated, and shell/unknown tools show only the tool name - raw
arguments are never rendered. The status goes to the same target as the typing indicator:
the thread for a thread reply, and the message's own thread root for a top-level message
or DM, so those conversations get the operation line too. It renders in Slack's
Assistant/Agent View experience and is best-effort elsewhere. `assistant.threads.setStatus`
accepts `assistant:write` or `chat:write` today (Slack plans to require `chat:write` only);
nullclaw uses the existing `chat:write` scope, so no new OAuth scope is required, and it
works with `streaming` off. The status reaction (default hourglass) still marks each
message's progress, and nullclaw does not post an extra progress message.
Set `tool_progress=false` to keep only the plain `is typing...` status.

About `session_status` on Slack: off by default (`session_status = false`). When enabled, nullclaw drives Slack's Agents session status via `agents.sessions.setStatus` (`processing` while a turn runs, `active` when it completes; `suspended` is reserved for approval-wait hooks). Like `tool_progress`, the status follows the turn's thread target: a top-level message or DM uses its own message ts as the thread root - the same `channel:message_ts` target the typing indicator uses - so those conversations get a session status instead of being skipped.

Native **Stop** button: when `session_status = true` and the Slack app subscribes to the `agent_session_stopped` bot event, clicking Slack's native Stop button in the Agents view delivers `/stop`, interrupting the active turn immediately. A native Stop is an explicit bot-directed action, so - like the Block Kit button and slash-command paths - it does not need a text mention: `group_policy = mention_only` does not block it, while the allowlist, DM policy and block checks still apply (a non-bot sender only). Denied or malformed events are dropped. The stale-status recovery is best-effort: it is queued to the inbound workers so no status POST runs on the Socket Mode reader, and it is dropped when the queue is full.

Scopes and manifest delta:
- Uses the existing `chat:write` bot scope; no new OAuth scope is required.
- Requires Slack's Agents & AI Apps / Agent View feature - `features.agent_view` (the migration from the legacy `features.assistant_view` is irreversible) or `features.assistant_view`:
  ```json
  {
    "features": {
      "agent_view": {
        "agent_description": "Describe what your agent does."
      }
    }
  }
  ```
  `features.agent_view` replaces `features.assistant_view`, and its nested `assistant_description` becomes `agent_description`. Slack documents that once an app is switched from `assistant_view` to `agent_view` the change cannot be reverted, so try it on a separate app or workspace first.
- Manifest change (Socket Mode): add `agent_session_stopped` to `settings.event_subscriptions.bot_events`:
  ```json
  {
    "settings": {
      "event_subscriptions": {
        "bot_events": [
          "agent_session_stopped"
        ]
      }
    }
  }
  ```

#### Live reasoning in drafts

`/reasoning stream` makes the model's thinking visible while it is produced, in the live
draft on Slack and Telegram. The thinking is rendered as a `>` quote (Slack blockquote,
`>`-prefixed lines on Telegram drafts, which are sent without a parse mode) and the answer
appears below it once the model starts writing. Long thinking is truncated to the platform
limit keeping the tail, and the existing per-turn throttling applies to it like any other
delta.

The delivered reply never contains the thinking, whatever the mode:

- `stream` - the thinking is shown live in the draft only.
- `on` - the thinking is not shown live; a `Reasoning:` block is appended to the final reply.
- `off` - the thinking is discarded.

Because a streamed draft contains text the final reply omits, Slack rewrites the stopped
message in place (`chat.update`) when a turn streamed reasoning, instead of posting the
reply a second time. On channels that have nowhere to show reasoning, the live preview stays
stripped.

Required Slack app settings:

1. Enable **Agents & AI Apps** (shown as **Agents**) under *Features* in the app settings.
   This is the feature gate for `chat.startStream` and requires a paid Slack plan.
2. Bot token scopes: `chat:write` (required for all outbound replies) plus `assistant:write`
   (added automatically when the app is declared as an agent). Add `im:history` and
   `channels:history` if you rely on history polling, and `files:read`/`files:write`
   for inbound/outbound media.
3. Events: `app_mention`, `message.im`, `message.channels` (and
   `assistant_thread_started` / `assistant_thread_context_changed` for assistant threads).
4. Reinstall the app after changing scopes, then restart nullclaw.

Without the feature or the scope, `streaming = true` is harmless: the first
`chat.startStream` call is rejected, the reply falls back to the edited-message path, and
the warning is logged once per account.

Verification:
```bash
nullclaw channel start slack
nullclaw channel status
```

`nullclaw channel start slack` starts only the first configured Slack account. For
multi-account validation, run `nullclaw gateway` and send a test message to each configured bot.

Common issues:
- Replies arrive only when complete: check that `streaming` is `true`, that the app has the
  Agents & AI Apps feature enabled, and look for `Slack native streaming unavailable for this app`
  in the logs
- `missing_scope` in the logs: reinstall the app after adding `chat:write` and `assistant:write`
- No streaming in channels: Slack only streams inside threads, so set `reply_to_mode` to `all`
- No response at all: check `allow_from`, and in groups that the bot is mentioned

### `session`

Automatic transcript reset, evaluated lazily on the next inbound message (there is no timer). Defaults keep resets disabled.

- `session.reset.mode`: `none` (default), `daily`, or `idle`.
- `session.reset.at_hour` (default: `4`): hour of the daily boundary, clamped to `0`-`23`. The boundary is computed in `agent.timezone`, which supports `UTC` or a fixed offset such as `UTC+08:00` / `UTC-05:00` (default `UTC`); IANA names and DST are not supported. OpenClaw reads the host's local timezone instead.
- `session.reset.idle_minutes`: inactivity minutes for `idle` mode. Must be positive; `null` means idle never expires.
- `session.reset_by_type`: optional overrides for `direct`, `group`, and `thread` session keys. A present entry replaces the base `reset` policy for that kind; thread keys win over group keys.
- Keys are snake_case. OpenClaw camelCase aliases (`atHour`, `idleMinutes`, `resetByType`) are also accepted. A reset block without `mode` means `daily` (OpenClaw behavior).
- The reset reuses the `/new` path: live history, the pending exec command, the active skill, token and compaction counters, session-scoped memory rows, and the persisted transcript are cleared. It is silent (log only), runs before the next turn refreshes activity, and never runs while a turn is active.
- `created_at` (session start) drives `daily`; `last_active` drives `idle`. Daily state is not persisted, so a restart after idle eviction starts a fresh daily window.
- Legacy: an explicit `session.idle_minutes` with no `session.reset` block is migrated to `{ "mode": "idle", "idle_minutes": <value> }`. The old implicit default of 60 minutes does **not** enable resets.

```json
{
  "session": {
    "reset": { "mode": "daily", "at_hour": 4 },
    "reset_by_type": {
      "group": { "mode": "idle", "idle_minutes": 120 }
    }
  }
}
```

### `memory`

- `backend`: start with `sqlite`. Available engines: `sqlite`, `markdown`, `clickhouse`, `postgres`, `redis`, `lancedb`, `lucid`, `memory` (LRU), `api`, `none`.
- `auto_save`: persists conversation memory automatically.
- `auto_recall` (default: `true`): when `false`, skips automatic memory injection into inbound messages. Storage via `auto_save` and on-demand recall via the `memory_recall` tool keep working.
- `recall_limit` (default: `5`): maximum memory entries injected per message.
- `max_context_bytes` (default: `4000`): total byte budget for the injected memory block, counting the header, keys, separators, and trailing newline. A single entry is truncated to half the budget; counts UTF-8 bytes. An entry that would push the block past the budget is dropped rather than written and trimmed afterwards.
- `recall_limit` and `max_context_bytes` must be non-negative; a negative value is a configuration error rather than a crash. A value too large for the JSON parser to represent is ignored.
- Archived conversation shards (hygiene copies of old turns) are excluded from automatic injection. Because hygiene deletes the original entry after preserving the archive, the `memory_recall` tool exposes `include_archived` (default `false`) so historical turns can still be retrieved explicitly.
- For hybrid retrieval and embedding settings, see root `config.example.json`.

**Note**: The `markdown_only` memory profile automatically enables hybrid retrieval with temporal decay (half-life 30 days) for optimal relevance scoring. This ensures temporal awareness even with plain markdown files.

### `gateway`

Recommended defaults:

- `host = "127.0.0.1"`
- `require_pairing = true`

Avoid direct public exposure. Use tunnel when external access is required.
On non-loopback binds, generic gateway endpoints such as `/webhook`, `/a2a`, and `/media/transcribe` still require a full gateway bearer token even if interactive pairing is disabled, so keep `require_pairing = true` or preconfigure `paired_tokens`. `/cron/*` also accepts the separate cron-scoped credential described below.
On non-loopback binds, `/pair` only accepts loopback clients; do the initial pairing locally or preconfigure `paired_tokens` before exposing the gateway.

When cron authentication is required, the gateway creates a bearer token scoped only to `/cron/*` at startup. It retains only the token hash and writes the encrypted credential to `paired_token` in the config directory with mode `0600`, allowing the schedule/cron tool to authenticate when `require_pairing = true` or the gateway is publicly bound, including configurations with preconfigured pairing tokens. The credential is rotated on every gateway restart and is not an interactive `/pair` token. Like any bearer credential, it is not bound to a client IP; protect the config directory from disclosure. An anonymous loopback gateway with `require_pairing = false` does not create this credential.

| Field | Default | Description |
|-------|---------|-------------|
| `host` | `"127.0.0.1"` | Listen address |
| `port` | `3000` | Listen port |
| `require_pairing` | `true` | Require bearer token on all API requests |
| `allow_public_bind` | `false` | Allow binding to non-loopback addresses |
| `pair_rate_limit_per_minute` | `10` | Max `/pair` requests per minute per IP |
| `webhook_rate_limit_per_minute` | `60` | Max webhook-like authenticated requests per minute. Raise this for live `/media/transcribe` audio chunks. |
| `idempotency_ttl_secs` | `300` | Duration to cache idempotent request results |
| `max_body_size_bytes` | `65536` | Maximum HTTP request body size in bytes (64 KB). Raise this when accepting image, audio, or file payloads (e.g. `67108864` for 64 MiB). |
| `request_timeout_secs` | `30` | Socket read timeout for incoming HTTP requests in seconds. Raise this when accepting large payloads over slow connections. |

### `tunnel`

Tunnel providers for exposing the gateway to the public internet. Required for webhook-based channels when running without a public IP.

**Providers:**

| Provider | Description |
|----------|-------------|
| `none` | No tunnel (default) |
| `cloudflare` | Cloudflare Tunnel |
| `ngrok` | ngrok tunnel |
| `tailscale` | Tailscale Funnel |
| `custom` | Custom tunnel command |

**Example: ngrok**

```json
{
  "tunnel": {
    "provider": "ngrok",
    "ngrok": {
      "auth_token": "YOUR_NGROK_AUTH_TOKEN",
      "domain": "your-domain.ngrok-free.app"
    }
  }
}
```

**Example: Cloudflare**

```json
{
  "tunnel": {
    "provider": "cloudflare",
    "cloudflare": {
      "token": "YOUR_CLOUDFLARE_TUNNEL_TOKEN"
    }
  }
}
```

**Example: Tailscale**

```json
{
  "tunnel": {
    "provider": "tailscale",
    "tailscale": {
      "funnel": true,
      "hostname": "nullclaw.ts.net",
      "auth_key": "tskey-auth-..."
    }
  }
}
```

**Notes:**

- Tunnel starts before gateway.
- Public URL is printed on startup and written to `daemon_state.json`.
- `tailscale.auth_key` is optional. Use it when the machine should auto-run `tailscale up` before starting `serve`/`funnel`.
- Tunnel secrets such as `cloudflare.token`, `ngrok.auth_token`, and `tailscale.auth_key` are encrypted at rest when `secrets.encrypt = true`.

### `autonomy`

- `level`: start with `supervised`.
- `level = "yolo"`: bypasses command policy checks; use only for trusted local debugging.
- `workspace_only`: keep `true` to limit file access scope.
- `max_actions_per_hour`: keep conservative limits first.
- `block_high_risk_commands` (default: `true`): blocks destructive commands such as `rm`, `sudo`, `mkfs`, `dd`, `shutdown`, `ssh`.
- `block_medium_risk_commands` (default: `true`): blocks medium-risk commands, including network/transfer commands such as `curl`, `wget`, `nc`, `scp`, `ftp`, `telnet` and state-changing commands such as `git commit`, `npm install`, `touch`, or `mkdir`. Set to `false` to allow these while still blocking high-risk commands.
- `require_approval_for_medium_risk` (default: `true`): when `block_medium_risk_commands` is `false`, require explicit approval before running medium-risk commands in `supervised` mode.
- `allowed_commands`: explicit list of allowed command basenames. Use `["*"]` for wildcard (full autonomy only). High-risk and medium-risk runtime gates still apply regardless of this list.

### `security`

- `sandbox.backend = "auto"`: auto-selects an available sandbox backend.
- `audit.enabled = true`: recommended for traceability.

### Advanced: Web Search + Full Shell (high risk)

Use only in controlled environments:

```json
{
  "http_request": {
    "enabled": true,
    "allowed_domains": ["192.168.1.10", "*.internal.example.com"],
    "search_base_url": "https://searx.example.com",
    "search_provider": "auto",
    "search_fallback_providers": ["jina", "duckduckgo"]
  },
  "autonomy": {
    "level": "full",
    "allowed_commands": ["*"],
    "allowed_paths": ["*"],
    "require_approval_for_medium_risk": false,
    "block_medium_risk_commands": false,
    "block_high_risk_commands": false
  }
}
```

Notes:

- `search_base_url` (for web_search tool): Must be `https://host[/search]` or a local/private `http://host[:port][/search]` URL. HTTP is allowed only for localhost/private hosts (e.g., `http://localhost:8888`, `http://192.168.1.10:8888`). This URL is used by the `web_search` tool to query SearXNG instances.
- `allowed_commands: ["*"]` and `allowed_paths: ["*"]` significantly widen execution scope.
- `http_request.allowed_domains`: Domains that bypass SSRF protection for the `http_request` and `web_fetch` tools.
  - `[]` (empty): All domains go through SSRF check (default, safest).
  - `["example.com"]`: Only specified domains skip SSRF protection.
  - `["*.example.com"]`: Matches all subdomains (e.g., `api.example.com`, `www.example.com`).
  - `["192.168.1.10"]`: IP addresses can also be allowlisted (exact match only, CIDR ranges not supported).
  - `["*"]`: **DANGEROUS** - All domains skip SSRF protection and DNS pinning. Use only in trusted network environments where you control DNS and need to allow access to any IP address. This effectively disables SSRF protection.
  - **Example**: If your SearXNG runs on `192.168.1.10`, add `"192.168.1.10"` to access it via `http_request` tool.
  - **Security trade-off**: Allowlisted domains skip DNS pinning, allowing access to private IPs. This trades DNS rebinding protection for operational flexibility.
  - **HTTPS-only policy**: The `http_request` and `web_fetch` tools require `https://` URLs. Plain HTTP is rejected for security. Note: This does not affect `web_search` tool's `search_base_url` which allows HTTP for local hosts.
  - **Check order**: Allowlist is checked BEFORE DNS resolution to prevent DNS exfiltration attacks.

## Validate After Config Changes

After each config change:

```bash
nullclaw doctor
nullclaw status
nullclaw channel status
```

If gateway/channel changed, also run:

```bash
nullclaw gateway
```

## Next Steps

- Run `nullclaw doctor` and `nullclaw status` after each edit to confirm the config still loads cleanly
- Use [Usage and Operations](./usage.md) for operational checks, service mode, and troubleshooting flow
- Review [Security](./security.md) before enabling broader autonomy, public bind, or wildcard allowlists

## Related Pages

- [Installation](./installation.md)
- [Usage and Operations](./usage.md)
- [Security](./security.md)
- [Gateway API](./gateway-api.md)
