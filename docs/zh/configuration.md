# 配置指南

NullClaw 与 OpenClaw 配置结构兼容，使用 `snake_case` 字段风格。

## 页面导航

- 这页适合谁：已经装好 NullClaw，准备生成、修改或审查 `config.json` 的使用者与运维者。
- 看完去哪里：要把配置真正跑起来看 [使用与运维](./usage.md)；要理解安全边界看 [安全机制](./security.md)；要查看命令入口与覆盖参数看 [命令参考](./commands.md)；要接非 core 渠道看 [外部渠道插件](./external-channels.md)。
- 如果你是从某页来的：从 [安装指南](./installation.md) 来，下一步通常就是生成初始配置；从 [Gateway API](./gateway-api.md) 来，这页可回查 `gateway` 与 channel 相关字段；从 [安全机制](./security.md) 来，这页提供具体配置落点与示例。

## 配置文件位置

- macOS/Linux: `~/.nullclaw/config.json`
- Windows: `%USERPROFILE%\\.nullclaw\\config.json`

建议先执行：

```bash
nullclaw onboard --interactive
```

这会自动生成初始配置文件。

## 最小可运行配置

下面示例可在本地 CLI 模式跑通（需要替换 API Key）：

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

## 核心配置块说明

### `diagnostics`

- 用于控制运行时诊断与可观测性输出。
- 配置 OpenTelemetry 时，请使用嵌套的 `diagnostics.otel` 对象。
- OTEL spans 会在回合完成、agent 结束等自然运行边界触发 flush；更长运行流程仍保留批量 flush 作为兜底。
- `diagnostics.otel.endpoint` 连接远程 collector 时应优先使用 `https://...`；`http://...` 仅适用于 localhost、私有网络 collector，或 `host.docker.internal`、`host.containers.internal`、`otel` 这类容器本地目标。

日志开关（默认均为 `false`）。这些 `info` 级别日志输出到 stderr —— `nullclaw agent` 或 `nullclaw gateway` 前台运行时直接打到终端；写入文件则由服务包装器或你自己的重定向负责：服务模式写入 `~/.nullclaw/logs/daemon.stderr.log`（launchd 服务配置会提供该文件），而 `gateway` 命令本身不会把这些日志路由到守护进程日志文件：

- `log_tool_calls`：记录每次工具调用的名称、状态和耗时。工具参数只有在 `log_llm_io` 同时开启时才会记录。
- `log_message_receipts`：记录收到用户消息的事件 —— 仅元数据（渠道、会话哈希、大小），不含内容。
- `log_message_payloads`：记录入站/出站用户可见消息的内容预览 —— UTF-8 安全、上限 4,096 字节，超出时标记 `[log preview truncated]`。仅用于本地调试 —— 可能包含敏感文本。
- `log_llm_io`：记录聊天调用提供方请求/响应的脱敏、截断预览，包括回复与推理（reasoning）内容的预览。仅用于本地调试 —— 可能包含敏感文本；生产环境请保持关闭。
- `token_usage_ledger_enabled`（默认 `true`）以及 `token_usage_ledger_window_hours` / `token_usage_ledger_max_bytes` / `token_usage_ledger_max_lines`：将每次响应的 token 计数持久化到 config.json 附近的 JSONL 台账。仅记录 token 数量（提供方/模型/prompt/completion/total），绝不记录消息文本。

示例（生产安全配置：涉及内容的开关均关闭）：

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

- 定义各 LLM provider 的连接参数与 API Key。
- 常见 provider：`openrouter`、`openai`、`anthropic`、`groq`、`nearai`、`atlas-cloud`、`evolink`、`edenai`、`cheaperinference` 等。

示例：

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

常见的 provider 级字段：

- `api_key`：该 provider 条目的凭据。
- `base_url`：provider 专用的 API 端点覆盖。所需的路径格式取决于 provider；
  OpenAI 兼容 provider 通常需要以 `/v1` 结尾的 base，而原生 Anthropic provider 不需要。
- `api_mode`：为兼容 provider 选择 `chat_completions` 或 `responses`。
- `user_agent`：可选的 `User-Agent` 请求头覆盖。
- `max_streaming_prompt_bytes`：当估算 prompt 大小超过该阈值时跳过流式请求。
- `chat_template_enable_thinking_param`：针对自定义 OpenAI 兼容的 vLLM/Qwen 端点，把 `reasoning_effort` 映射到 `chat_template_kwargs.enable_thinking`。

#### 原生 Anthropic provider

NullClaw 内置了原生的 Anthropic provider，可直接连接 Anthropic API，无需经过 OpenRouter 或代理。

认证方式：

- **Anthropic Console API Key** 通过 `x-api-key` 请求头发送。请将密钥写入
  `models.providers.anthropic.api_key`，或设置 `ANTHROPIC_API_KEY`。
- **Claude 订阅 setup token**（以 `sk-ant-oat01-` 开头）通过 Bearer 认证发送。
  先运行 `claude setup-token` 生成长期令牌，再将其写入
  `models.providers.anthropic.api_key`，或设置 `ANTHROPIC_OAUTH_TOKEN`。
  NullClaw 不会读取 Claude Code 的凭据存储，也不会刷新该令牌。请参阅
  [Claude Code 认证指南](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token)。

该 provider 支持文本流式输出、URL 和 base64 图片输入，以及非流式请求中的原生工具调用。
设置 `reasoning_effort`（或使用 `/think`）可在支持该功能的模型上启用 Anthropic
扩展思考。NullClaw 对 Claude Opus/Sonnet 4.6 使用自适应思考，对支持该功能的旧模型
使用手动预算；Anthropic 针对具体模型的限制仍然适用。

示例（直接使用 Anthropic API Key）：

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

说明：

- 在 `agents.defaults.model.primary` 中，为 Anthropic 模型 ID 添加
  `anthropic/` provider 前缀，例如 `anthropic/claude-sonnet-4-6`。如果 agent
  条目单独设置了 `"provider": "anthropic"`，则使用不带前缀的模型 ID。
  可通过 `nullclaw --list-models --provider anthropic` 浏览 NullClaw 收录的
  Anthropic 模型 ID；该命令不会检查你的 Anthropic 账户实际启用了哪些模型。
- `base_url` 字段是可选的，默认值为 `https://api.anthropic.com`。
  对于 Anthropic 兼容的代理或网关，请将其设为 `/v1/messages` 之前的 API root
  （不要包含末尾的 `/v1`）；NullClaw 会自行追加该路径。远程端点必须使用 HTTPS；
  只有本地或私有网络主机才允许使用普通 HTTP。

### `agents.defaults.model.primary`

- 设置默认模型路由，通常是 `provider/vendor/model`。
- 示例：`openrouter/anthropic/claude-sonnet-4`

### `agent.default_queue_mode`

- 设置新建会话的入站队列模式。可选值为 `steer`、`off`、`serial`、`latest` 和 `debounce`，默认值为 `steer`。
- `steer`（默认）会把正在执行回合时到达的消息按到达顺序注入当前活动回合，在下一个工具或模型边界交给模型，因此不会静默丢弃。发送者会立即收到可见确认（typing 指示、accepted 反应，或在不支持前两者的通道上收到一条简短提示）。steer 会保留每一条消息，不受队列容量上限限制。如果已确认的 steer 消息在后续回合中处理失败，回复会说明该消息无法处理并请发送者重发，而不会自动重试。
- `off` 会丢弃正在执行回合时到达的消息，并告知发送者消息未送达。`serial` 会等待当前回合结束，`latest` 只保留最新的待注入消息（替换较早的消息），`debounce` 选择现有的运行时 debounce 模式；此字段不配置其时长、容量或丢弃策略。
- `/queue` 可以覆盖当前会话的模式（如 `/queue steer`、`/queue latest`）。`/queue reset`、`/restart` 和 `/debug reset` 会恢复这里配置的默认值。
- 修改后需要重启，确保 session manager 与后续新建会话使用同一个默认值。
- 旧版本写出的配置会包含 `"default_queue_mode": "off"`，从而保留旧的丢弃行为。要使用新的默认值，请删除该字段或将其设为 `steer`。

示例：

```json
{
  "agent": {
    "default_queue_mode": "steer"
  }
}
```

### `agent.reasoning_mode`

- 设置新建会话的推理展示模式。可选值为 `off`、`on` 和 `stream`，默认值为 `off`。
- `off` 不展示推理内容；`on` 会在最终回复上方输出 `Reasoning:` 引用块；`stream` 会在模型生成时实时输出推理内容。
- `/reasoning <off|on|stream>` 可以覆盖当前会话的模式。`/restart` 和 `/debug reset` 会恢复这里配置的默认值，而不是一律重置为 `off`。
- 会话会在 `agent.session_idle_timeout_secs` 空闲后被回收，因此配置默认值可以避免每次回收后都要重新执行 `/reasoning on`。
- 修改后需要重启，新的会话才会使用新的默认值。

示例：

```json
{
  "agent": {
    "reasoning_mode": "stream"
  }
}
```

### `agent.compaction_memory_flush`

- 默认 `true`。压缩丢弃旧消息之前会发起一次有界的一次性 LLM 调用，提取值得长期记住的用户事实和偏好，每行存为一条记忆（键名以 `flush_compact_*` 开头）。
- flush 输入上限为 8,000 字符（UTF-8 安全截断），每次压缩最多存储 10 行。
- provider 报错或输出为空不会阻塞压缩，摘要和历史裁剪照常进行。
- flush 直接调用 provider，不经过 agent turn，因此不会递归触发再次压缩。
- 设为 `false` 可跳过这次额外调用。主动压缩本身仍需 `agent.compact_context` 开启。

示例：

```json
{
  "agent": {
    "compaction_memory_flush": false
  }
}
```

### `workspace_audit.llm_triage`

- 选择 `nullclaw workspace audit --llm-triage external` 使用的 provider/model。
- 该配置本身不会启用 LLM triage；命令行模式仍然必须显式开启。
- 省略时回退到 `agents.defaults.model.primary`。

示例：

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

如果 provider 已在 `models.providers` 中配置，也可以把 model 写成带 provider 前缀的引用，例如 `"model": "openrouter/anthropic/claude-sonnet-4"`。

### `model_routes`

- 顶层可选路由表，用于 `nullclaw agent` 在每一轮对话里自动选择模型。
- 每个条目用 `hint` 映射到具体的 `provider` 和 `model`。
- 当前 daemon 识别的路由提示词包括：`fast`、`balanced`、`deep`、`reasoning`、`vision`。
- 配置了 `balanced` 时，它会作为常规兜底路线。`fast` 更适合简短的状态/列表/检查类请求，以及提取、计数、分类、只返回结果这类边界清晰的短结构化任务。`deep` 和 `reasoning` 更适合调查、规划、权衡分析和长上下文。`vision` 用于图片输入回合。
- `api_key` 是可选的；如果不填，会继续使用 `models.providers.<provider>` 里的常规凭据。
- `cost_class` 是可选元数据，可选值为 `free`、`cheap`、`standard`、`premium`。
- `quota_class` 是可选元数据，可选值为 `unlimited`、`normal`、`constrained`。

示例：

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

说明：

- 只有在当前会话没有被显式 pin 到某个模型时，`model_routes` 才会生效。
- 如果同时配置了 `deep` 和 `reasoning`，深度分析类请求会优先选择 `deep`。
- `/model` 还会显示最近一次自动路由决策，方便查看选中了哪条路线以及原因。
- 如果自动路由命中的提供方遇到配额或限流错误，这条路线会被临时降级，直到冷却时间结束才会再次尝试。
- 路由元数据只会轻微影响评分，不会推翻保守策略。含糊请求仍然优先留在 `balanced`，`fast` 只给高置信度且便宜的任务，强烈的深度分析信号仍然会压过更便宜的路线。

### `agents.list`

- 定义可供 `/delegate` 等工具使用的命名 agent 配置。
- 每个条目既可以显式写 `provider` + `model`，也可以直接在 `model.primary` 中写完整的 `provider/model` 引用。
- 示例：

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

#### `agents.list[].workspace_path`

当某个命名 agent 需要使用独立工作区而不是全局工作区时，使用 `workspace_path`。

示例：

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

行为说明：

- 相对路径会相对于 `config.json` 所在目录解析。
- 绝对路径会原样使用。
- 配置中可以写 `/` 或 `\`，运行时会按当前操作系统规范化路径分隔符。
- `workspace_path` 不会禁用 `system_prompt`。如果两者同时设置，nullclaw 仍会应用命名 agent 的 profile prompt，并从该独立工作区加载 bootstrap 上下文。
- 首次使用时，如果工作区不存在，nullclaw 会自动创建并初始化：
  - `AGENTS.md`
  - `SOUL.md`
  - `IDENTITY.md`
  - `MEMORY.md`

隔离模型：

- 该 agent 的文件操作、markdown memory 文件以及 workspace 相关上下文都会使用这个工作区。
- 设置 `workspace_path` 后，该 agent 还会获得一个持久 memory namespace，格式为 `agent:<agent-id>`。
- 这个 namespace 会用于：
  - `nullclaw agent --agent <id>`
  - `/subagents spawn --agent <id> ...`
  - 通过 `bindings` 路由到该命名 agent 的会话

实际效果：

- 两个命名 agent 即使使用相同的 provider/model，也可以保持各自独立的持久笔记和工作区。
- `workspace_path` 本身不会决定聊天路由；路由仍然由 `bindings`、`/bind` 或显式 `--agent` / `/subagents spawn --agent` 决定。

#### `agents.list[].autonomy`

当某个命名 agent（例如只绑定单个聊天对端的 guest）需要使用比全局更严格的安全策略时，使用 `autonomy`。

- 该对象支持与顶层 `autonomy` 相同的字段：`level`、`workspace_only`、`allowed_commands`、`allowed_paths`、`max_actions_per_hour`、`require_approval_for_medium_risk`、`block_high_risk_commands`、`block_medium_risk_commands`、`allow_raw_url_chars`。
- 一旦设置，它会**替换**该 agent 的全局 `autonomy`。未写出的字段回落到 `AutonomyConfig` 的安全默认值（`supervised`、`workspace_only: true`、空的 `allowed_paths`、保守的命令白名单），**不会**从全局块继承。`level` 取值非法时会在加载配置时直接报错。
- 即使没有设置 `workspace_path`，该 agent 也会拥有独立的 runtime 与独立的安全策略（限速、命令白名单、路径范围）。
- 对于拥有独立 autonomy 的 agent，以下“在全局策略下执行工作”或“会触达工作区之外”的工具会被**移除**（否则它们会以该 agent 策略并未授予的权限执行）：
  - `spawn` —— 后台 subagent 运行在全局 autonomy 下。
  - `schedule` —— cron shell 任务运行在调度器的全局 shell 策略下。
  - `image_info` —— 直接打开任意绝对路径、不做工作区/策略校验，是主机路径的元数据探测器（存在性、大小、格式）。
  - `git`（`git_operations`）—— 会无视 `read_only` 意图直接写仓库（commit、checkout、reset 等）。
  - `screenshot` —— 截取主机屏幕，泄露工作区之外的信息。
  - MCP 工具 —— 每个已配置的 MCP server 会作为子进程启动并代理其工具，且不会经过该 agent 的策略。
  - `delegate` —— 它可以指定任意已配置的 agent，并用运营者的 API key 调用该 agent 的 provider 和模型，访客因此可以消耗其他 agent 的 key，并把内容发给原本没有授权给它的 provider。

  `cron_*` 系列工具本身就不在 agent 工具集中。
- 涉及共享配置、在工作区之外写入、或读取主机状态的 slash 命令会被拦截：
  - `/config`（`get`、`set`、`unset`、`apply`、`reload`、`validate`）会被拒绝。它会在全局策略下读写共享的 `config.json`，从而泄露 provider key 与 channel token，或让 guest 削弱主 agent 的 `autonomy`/`security` 配置块。
  - `/capabilities` 只报告该 agent 自身的 runtime 工具，不再读取共享 `config.json` 来列出已配置的 channel 与工具。
  - `/model` 仍然可以为该 agent 自身的会话切换模型，但不再把 `agents.defaults.model.primary` 持久化到全局配置，且交互式 provider/model 菜单不再读取共享 `config.json` —— 它改用公开模型列表，而不是全局 provider key。
  - `/export` 会被拒绝：它接受任意绝对路径并截断/创建该文件，是一个可被绑定聊天对端触发的“整机文件写入”原语。
  - 当该 Telegram 对端当前被路由到拥有独立 autonomy 的 agent 时，`/bind` 会被拒绝。否则 guest 可以用 `/bind clear` 回退到默认路由，或用 `/bind <其他 agent>` 迁移到无限制的 agent，从而逃离受限 agent。（`/bind status` 仍为只读。）
  - 其余 slash 命令要么只影响自身会话（model、think、verbose、reasoning、usage、cost、queue、tts、focus/unfocus/dock/activation/send、session ttl、context、memory、skills、debug、stop、compact、doctor），要么作用于该 agent 自己的 subagent —— 而后者对它不可用，因为 `spawn` 工具已被移除（`/subagents spawn`、`/steer`、`/tell`、`/agents`、`/kill`、`/poll` 都会提示 subagent manager 已禁用）。`/bash`、`/approve`、`/exec`、`/elevated` 仍走该 agent 自己的 shell 工具与策略，因此下面的限制同样适用于它们。
- 出站附件被限制：一次出站回复只能附带由**绝对路径**命名、且解析后（跟随符号链接）位于该 agent 工作区（及其自身 `allowed_paths`）之内的本地文件。相对路径会被拒绝，因为 channel 上传器（`curl --form file=@<target>`）会按自身进程 cwd 而非工作区解析它，导致上传的文件未必是检查所解析的那个。回复文本中目标落在工作区之外或为相对路径的旧式标记（`[IMAGE:…]`、`[DOCUMENT:…]`、`[FILE:…]`、`[PHOTO:…]`、`[VIDEO:…]`、`[AUDIO:…]`、`[VOICE:…]`）会在发送前被丢弃并记录日志，对所有会上传此类标记的 channel（Telegram、Max、Signal 等）都生效。远程 `http(s)` URL 不指向本地文件，不受影响。这是一条不经过工具调用的纯文本外泄路径，因此 `read_only` 同样适用。
- shell 工具被限制在该 agent 的工作区内。命令会按 shell 视为 IFS 空白的所有字节（空格、tab、换行、垂直制表符、换页符）做词切分，随后任何命名路径的参数（绝对路径、`..` 回溯、`~`）都会被拒绝；命令中出现任何控制字节都会被直接拒绝，因为 shell 会据此切分出参数检查看不到的参数（`cat x\t/etc/passwd` 会执行 `cat x /etc/passwd`）。`$` 参数展开（`$IFS`、`$HOME`、`$1`、`$@` 等）、单引号之外的反斜杠转义，以及未加引号的 glob/花括号元字符也会被拒绝，因为 shell 会在执行时把它们展开或去转义成参数检查看不到的文本（`cat $IFS/etc/passwd` 和 `cat \/etc/passwd` 都会变成 `cat /etc/passwd`）。会直接拒绝执行来自工作区代码的命令 —— 包管理器及其 run/build 子命令（`npm`、`pnpm`、`yarn`、`npx`、`bun`、`deno`、`cargo`），以及会运行脚本的 git 子命令（`git bisect`、`git submodule`、`git filter-branch`、`git filter-repo`，外加 git `-c` 配置注入与 `!` 别名）—— 因为这类代码以 agent 进程的权限运行并绕过该限制。 此外，受限命令只能包含字母、数字、普通空格、分隔符 `;`、`|`、`&&`、`||` 以及标点 `-_./,:=+@%^`：任何引号、重定向（`<`、`>`）、转义、展开或通配字节都会被拒绝，因此 `cat ''/etc/passwd`、`cat '..'/x`、`cat </etc/passwd` 会被直接拒绝，而不会被 shell 重新解释。`find` 的写入/执行谓词（`-exec`、`-execdir`、`-ok`、`-okdir`、`-delete`、`-fprint*`、`-fls`）同样被拒绝。`nullclaw agent --agent <name>` 也使用同一套按 agent 的 autonomy。
- **该 shell 限制是尽力而为的参数检查，而非文件系统 jail。** 它是在常见的无外部沙箱（bubblewrap/firejail/docker/landlock）场景下的纵深防御；若某命令通过该检查未覆盖的机制访问主机文件，仍可能绕过。对不可信的 guest，优先使用 `"level": "read_only"` —— 它会直接禁用**所有**工具调用，并让进程运行在外部沙箱中。
- 没有 `autonomy` 块的 agent 仍然共用全局策略。

示例 —— 一个只绑定单个 Telegram 对端、只读的 guest：

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

对不可信的 guest，优先使用 `"level": "read_only"`：它会禁用所有工具调用，只依赖上面的限制（shell 参数检查与出站附件检查）。当 guest 可以执行动作、但所有中高风险命令仍需审批时，改用 `"level": "supervised"`，并通过 `allowed_commands` / `allowed_paths` 授予一个明确而狭窄的范围。两种 level 都不是文件系统 jail —— 面对不可信输入时应配合外部沙箱。

### `messages.inbound`

- `debounce_ms` 用来延迟处理连续快速到达的纯文本入站消息，把短时间内的多条碎片合并成一次 turn。
- 默认值：`300`。
- 作用范围包括 daemon 路由的入站文本和 Agent CLI REPL。
- 设为 `0` 可关闭。
- slash 命令和带媒体的入站消息会跳过 debounce。
- Telegram 仍保留自己的长消息分段合并逻辑：该值作为基础窗口（默认 300ms），接近单条上限的长文本（≥4000 字节或 ≥4 个片段）至少等待 1500ms 后再合并。

示例：

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

- `policy` 控制 daemon 路由的入站 turn 失败时是否向用户发送错误回复：
  - `always`（默认）：每次失败都发送。
  - `once`（可选）：每个聊天和每种失败类别只发送第一次错误，在 `cooldown_mins` 内抑制重复。
  - `silent`：从不发送，只记录日志。
- `cooldown_mins`：`once` 策略下抑制重复错误的时长（默认值：`240`，即 4 小时），仅对 `once` 生效。
- 去重键由出站聊天范围和分类后的失败类别组成，因此即使 provider 细节不同，同一种错误也会被去重。
- 仅作用于 daemon 路由的入站 turn；轮询式 channel loop 和 HTTP gateway 保持原有行为。

示例：

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

- 配置 LLM 提供者的全局重试和故障转移行为。
- `provider_retries`: 重试失败的 LLM 请求的次数（默认值：2）。
- `provider_backoff_ms`: 重试之间的初始指数退避延迟（默认值：500 毫秒）。
- `fallback_providers`: 当未显式指定 provider 的模型需要在主要提供方之外继续尝试时，可使用的备用提供方名称列表。
- `model_fallbacks`: 模型到有序备用模型列表的映射。每个备用项既可以是裸模型名，也可以是显式的 `provider/model` 引用。

示例：

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

备注：

- 裸模型名的故障转移顺序：先尝试主要提供方，再依次尝试每个列出的 `fallback_provider`。
- 像 `openai/gpt-4o` 这样的显式 `provider/model` 备用项会直接路由到对应 provider，不会再走通用 provider 扇出链路。
- `api_keys`: (可选) 用于在速率限制 (429) 错误时轮换的额外 API 密钥列表。

### `scheduler`

- 配置运行定时任务的 cron 调度器。
- `enabled`：定时任务调度的总开关（默认值：`true`）。
- `max_tasks`：调度器可跟踪的任务数量上限（默认值：`64`）。
- `max_concurrent`：会被解析并由 `nullclaw cron status` 展示，但**当前并未生效** —— cron 调度器同一时刻只运行一个任务（见下方说明）。
- `agent_timeout_secs`：单个 cron **agent** 任务的硬性墙钟时间上限，单位为秒（默认值：`0`，即**不设超时**）。

示例：

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

#### `agent_timeout_secs` 为何重要

定时任务在**单个调度线程上串行执行**。到期的任务会被启动并等待结束，调度器才会去看下一个任务，因此一个永远不退出的任务会把其余所有定时任务（包括心跳）一起拖延同样长的时间。在默认值 `0` 下没有截止时间：调度器会无限期等待该任务的输出到达 EOF。

凡是运行定时 agent 任务的主机，都应设置一个非零值：

- 取值应明显高于最慢的正常任务，同时远小于任务之间的间隔。例如 2 小时的 cron 配上 15 分钟上限，既留足余量，又能限制卡死时长。
- 该上限只作用于 **agent 类型**任务。shell 类型的 cron 任务另有 60 秒的独立上限，不受此值影响。
- 该值与其余 `scheduler` 配置一样，只在 daemon 启动时读取一次。系统不支持 SIGHUP 重载 —— **修改后需要重启 daemon 才会生效**。
- 超时触发时，任务子进程会被杀掉，本次运行记为错误，随后下一次触发即可正常进行。

已知限制：kill 只会作用于该任务的直接子进程，不会作用于其后代进程。如果某个孙进程继承了任务的输出管道，调度器仍可能在超时之后继续等待。

### `identity`（AIEOS v1.1）

如果你希望运行时身份来自 AIEOS 文档，可以使用这一节。配置后，nullclaw 会把解析后的 AIEOS 内容连同 `AGENTS.md`、`IDENTITY.md` 等工作区身份文件一起注入 system prompt：

```json
{
  "identity": {
    "format": "aieos",
    "aieos_path": "./identity/aieos.identity.json"
  }
}
```

也可以直接把同样的文档内联到配置里：

```json
{
  "identity": {
    "format": "aieos",
    "aieos_inline": "{\"identity\":{\"names\":{\"first\":\"nullclaw-assistant\"},\"bio\":\"通用自主助手\"},\"linguistics\":{\"style\":\"concise\"},\"motivations\":{\"core_drive\":\"安全地帮助操作者完成任务\"}}"
  }
}
```

最小 AIEOS v1.1 示例文件（`identity/aieos.identity.json`）：

```json
{
  "identity": {
    "names": {
      "first": "nullclaw-assistant"
    },
    "bio": "通用自主助手"
  },
  "linguistics": {
    "style": "concise"
  },
  "motivations": {
    "core_drive": "安全地帮助操作者完成任务"
  }
}
```

说明：

- AIEOS payload 采用 `identity`、`psychology`、`linguistics`、`motivations`、`capabilities` 等顶层 section。
- 为了可维护性和版本控制可读性，优先使用 `aieos_path`。
- 只有在你确实需要单文件自包含配置时，再使用 `aieos_inline`。
- `identity.format` 应与 payload 来源保持一致，也就是 `aieos`。
- 相对路径的 `aieos_path` 会优先按当前 workspace 解析，找不到时再按当前工作目录解析。

### `channels`

- 渠道配置统一在 `channels.<name>` 下。
- 多账号渠道通常用 `accounts` 包裹。

外部渠道插件示例：

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

外部渠道说明：

完整的协议、生命周期、metadata 约定和插件作者契约，请继续看
[外部渠道插件](./external-channels.md)。

- `runtime_name` 是 nullclaw 内部使用的运行时渠道 id，routing、bindings、session key 和出站分发都会使用它。它不能复用内建 channel 名称，也不能和任何其他已配置 channel 已占用的运行时名字冲突。
- `transport.command` 和可选的 `transport.args` 会把插件作为子进程启动，并通过 stdio 上的逐行 JSON-RPC 通信。
- `transport.timeout_ms` 会限制 host 到插件的 RPC 等待时间；同时 nullclaw 还会在内部对 control-plane 请求做上限裁剪，避免一个坏插件把 supervision 卡住几分钟。
- `transport.env` 只会传给插件进程本身。
- `config` 必须是 JSON object；它会原样透传给插件 `start` 请求里的 `params.config`。
- 插件必须响应 `get_manifest`，处理 `start`、`send`、`stop`；建议实现 `health`，这样 supervision 才能识别“进程活着但 sidecar 已断开”的状态。
- `get_manifest.result` 现在必须显式声明 `protocol_version: 2`；`capabilities.health`、`capabilities.streaming`、`capabilities.send_rich`、`capabilities.typing`、`capabilities.edit`、`capabilities.delete`、`capabilities.reactions`、`capabilities.read_receipts` 都是可选能力标记。
- `health.result` 必须返回显式布尔值（`healthy`）或显式健康信号（`ok`、`connected`、`logged_in`）；空对象会被视为无效响应。对于需要扫码或设备绑定的渠道，后台认证尚未完成时，应在这里报告 `connected: false` 或 `logged_in: false`。
- `start.params` 现在包含嵌套的 `runtime` 对象，里面有 `name`、`account_id` 和 host 提供的 `state_dir`。
- `start.result` 必须返回 `started: true`；`start` 应在完成本地初始化后尽快返回，而不是阻塞等待扫码或人工登录。`send`、`send_rich`、`edit_message`、`delete_message` 以及其他 typing/message-action RPC 在真正接受动作时都必须返回 `result.accepted: true`。仅仅没有 JSON-RPC `error` 已经不够了。
- `send.params` 现在也拆成嵌套的 `runtime` 和 `message` 对象；文本字段统一使用 `message.text`。
- 如果插件同时声明了 `capabilities.edit=true` 和 `capabilities.delete=true`，那么 `send.result` 还可以返回 `message_id`，或者返回 `message { target?, message_id }`；这样 nullclaw 就能在不支持原生 `.chunk` 流式发送的渠道上维护一条可编辑的草稿消息。
- 如果 `capabilities.streaming=true`，nullclaw 可能在模型流式输出时发送 `.chunk` 阶段的 `send` 事件；如果缺省或为 `false`，只会发送最终结果。
- 如果 `capabilities.send_rich=true`，host 还可能调用 `send_rich`，其参数同样包含嵌套的 `runtime` 和 `message { target, text, attachments, choices }`。
- 如果 `capabilities.typing=true`，host 还可能调用 `start_typing` / `stop_typing`，参数包含嵌套的 `runtime` 和 `recipient`。
- 如果声明了 `capabilities.edit=true` / `capabilities.delete=true`，host 还可能调用 `edit_message` / `delete_message`。
- 如果声明了 `capabilities.reactions=true` 或 `capabilities.read_receipts=true`，host 还可能调用 `set_reaction` 和 `mark_read`。
- `inbound_message.params.message` 必须包含 `sender_id`、`chat_id`、`text`；如果带了 `metadata`，它必须是 JSON object；如果带了 `media`，它必须是由非空字符串组成的数组。
- 如果希望 unknown channel 也能正确做 routing/bindings，建议在 `metadata` 里带上 `peer_kind` 和 `peer_id`。
- unknown/external channel 也可以提供 `metadata.is_group`、`metadata.is_dm` 或 `metadata.typing_recipient`，nullclaw 会把这些信息提升到 prompt 的 conversation context 和处理状态路由里。
- PR #265 的 WhatsApp Web bridge 兼容适配器示例放在 `examples/whatsapp-web/nullclaw-plugin-whatsapp-web`。
- 生产级的配套仓库已经移到仓库外：[nullclaw/nullclaw-channel-baileys](https://github.com/nullclaw/nullclaw-channel-baileys) 和 [nullclaw/nullclaw-channel-whatsmeow-bridge](https://github.com/nullclaw/nullclaw-channel-whatsmeow-bridge)。
- `nullclaw channel start external` 会启动第一个已配置的外部账号；`nullclaw channel start <runtime_name>` 可以直接启动某个具体运行时名字，比如 `whatsapp_web`。

Telegram 示例：

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

WeChat 示例：

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

WeChat 说明：

- NullClaw 已经内置 WeChat webhook channel；接收公众号回调时不需要额外的 external plugin。
- Gateway webhook 路径是 `/wechat`。配置多个 WeChat 账号时，可通过 `?account_id=<id>` 选择账号。
- `callback_token` 是签名校验必填项。
- `encoding_aes_key` 是可选项；当 WeChat 回调配置为 `encrypt_type=aes` 时必须提供。
- `app_id` 和 `app_secret` 只有在需要通过 WeChat custom message API 主动发送消息时才需要。
- 空 `allow_from` 会拒绝入站消息；请显式列出可信 OpenID，仅在有意开放账号时使用 `"*"`。
- 如果当前二进制未编译 WeChat channel，请使用 `-Dchannels=wechat`（或 `-Dchannels=all`）重新构建。

#### Weixin — 微信 iLink Bot（扫码登录）

`weixin` channel 通过二维码授权微信 iLink bot。这与上方使用签名 webhook 的
`wechat` 公众号 channel 不同。

首先，扫码登录获取 token：

```bash
nullclaw auth login weixin
```

此命令会在终端渲染二维码。使用微信扫码并在手机上确认授权后，命令会把生成的
`token` 保存到配置文件；如果服务返回了非默认主机，也会保存对应的 `base_url`。

登录后，编辑该命令更新的 Weixin 账号条目，显式设置 `allow_from`。新配置会使用
下方所示的内联条目；已有的 `accounts` 对象会保留原布局。如果登录命令提供了
`--proxy`，该代理会保存到同一账号，并继续用于运行时 API 请求。

```json
{
  "channels": {
    "weixin": {
      "account_id": "default",
      "token": "<扫码登录获取的 bot token>",
      "base_url": "https://ilinkai.weixin.qq.com/",
      "proxy": null,
      "allow_from": ["<你的微信用户 ID>"]
    }
  }
}
```

Weixin channel 字段：

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `account_id` | `"default"` | routing 和 session key 使用的内部账号标识 |
| `token` | `""` | 从 `nullclaw auth login weixin` 获取的 bot token（必填） |
| `base_url` | `https://ilinkai.weixin.qq.com/` | 不含 query/fragment 的绝对 HTTPS iLink API URL（地区重定向后可能变化） |
| `proxy` | `null` | 运行时 API 请求使用的可选 `http://`、`https://` 或 `socks5://` 代理 URL |
| `allow_from` | `[]` | 允许向 bot 发消息的精确微信用户 ID 列表；请显式配置 |

说明：

- 在 `allow_from` 列出可信用户 ID（或明确使用通配符 `"*"`）之前，不会接受任何入站消息。
- `nullclaw auth status weixin` 只报告是否配置了非空 token，不会探测远端 iLink session。
- 使用 `nullclaw auth logout weixin` 删除已配置的 token。
- 需要代理时，使用 `nullclaw auth login weixin --proxy http://localhost:7890`；
  该命令会保存代理，供登录流程和运行时 API 请求共同使用。
- 如果二进制未编译 weixin channel，请使用 `-Dchannels=weixin`（或 `-Dchannels=all`）重新构建。
- `nullclaw gateway` 会启动并监管已配置的 `weixin` 轮询循环。
- 当前 adapter 把入站会话视为私聊并发送文本回复；尚未实现群聊 routing 和媒体/文件投递。

规则说明：

- 对基于 allowlist 的渠道，空 `allow_from` 会拒绝入站消息；如果要做私有机器人，请显式填写 ID/OpenID。
- `allow_from: ["*"]` 会在基于 allowlist 的渠道上允许所有来源，仅在你明确接受风险时使用。
- Telegram webhook 必须配置 `channels.telegram.accounts.<id>.webhook_secret`，并要求 Telegram 的 `X-Telegram-Bot-Api-Secret-Token` header 匹配。
- Teams 入站 webhook 现在会使用 Bot Framework JWT bearer token 并对照 Microsoft OpenID metadata 做认证。`channels.teams.accounts.<id>.webhook_secret` 变为可选项；如果配置，会额外要求 `X-Webhook-Secret` 匹配。

Telegram forum topics：

- Topic 会话隔离是自动的，`channels.telegram` 下无需单独配置 `topic_id` 字段。
- 实际操作流程：
  1. 在 `agents.list` 中配置命名 agent 配置
  2. 打开目标 Telegram 群组或 forum topic
  3. 发送 `/bind <agent>`
- 如果要让某个 forum topic 使用特定 agent，在 `bindings` 中配置 `match.peer.id = "<chat_id>:thread:<topic_id>"`。
- 如果还需要为同一 Telegram 群组的其余部分设置兜底 agent，再添加一条 binding，peer id 为纯群组 id `"<chat_id>"`。
- `/bind status` 显示当前生效的路由和可用 agent id。
- `/bind clear` 仅移除当前 account/chat/topic 的精确 binding，让路由回退到更宽泛的匹配。
- `/bind` 会为当前 Telegram account 和 peer 写入一条精确的 `bindings[]` 条目。
- Topic 级 binding 优先于群组级兜底（按路由优先级，与 `bindings[]` 中的顺序无关）。
- Telegram 菜单中 `/bind` 的可见性由 `channels.telegram.accounts.<id>.binding_commands_enabled` 控制。

示例：

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

上述配置中，topic `42` 路由到 `coder`，群组其余部分兜底到 `orchestrator`。

命名 agent 配置与 bindings 是独立关注点：`agents.list` 定义可复用的配置，`bindings` 决定哪个配置用于哪个 chat/topic。

完整端到端示例：

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

操作流程：

- 在目标 forum topic 中发送 `/bind coder`。
- `nullclaw` 会为该 topic 和 Telegram account 写入一条新的精确 `bindings[]` 条目到 `~/.nullclaw/config.json`。
- 该 topic 中的下一条消息将使用新路由的 agent 配置。
- `nullclaw` 必须对 `~/.nullclaw/config.json` 有写权限，`/bind` 才能持久化变更。

关于 `draft_previews`：

- 默认值也是推荐值是 `false`。
- 关闭后，Telegram 仍会在回复生成期间显示活动状态/typing，但不会使用临时的 `sendMessageDraft` 预览。
- 只有在你明确想要实时部分预览，并且能接受 Telegram 在最终消息到达前隐藏、替换这些 draft 时，才建议设置 `draft_previews=true`。

关于 `tool_progress`：

- 默认值为 `true`。当 live draft 还没有任何回答文本时（长时间、多轮工具调用的 turn），draft 会展示 agent 正在做什么，而不是只显示一个 elapsed 心跳：

  ```
  ⏳ 121s · 11 tool calls
  🔧 web_search
  🔧 web_fetch example.com
  ❌ web_fetch failed
  ```

- 首行显示已经过的秒数和目前的工具调用次数。下面最多展示 5 条最近的工具行；裁剪时失败行（`❌`）优先保留、成功行先被丢弃。每行最多约 60 个字符。
- hint 刻意保守：`web_fetch`/`http_request` 只显示 host，`web_search` 显示截断后的查询（≤40 字符），文件类工具显示文件 basename，shell/exec 及未知工具只显示工具名——绝不显示原始命令。所有 hint 都会按 Telegram 的 HTML parse mode 做 HTML 转义。
- turn 内第一个工具调用会立即刷新 draft（即使还没有任何文本或推理流出），让用户马上看到 agent 开始做什么。同一批次后续的工具事件仍遵守现有的 draft flush 节流（4s），因此不会触发 `sendMessageDraft` 限流；落在节流窗口内的事件会被保留，并在下一次 typing 心跳时补渲染，不会丢失。
- 一旦有真正的回答文本开始流式输出，draft 会像以前一样只显示该文本；工具行绝不会混入回答文本、最终回复或会话历史。最终回复投递前就会释放 draft，因此进度刷新（包括 elapsed 心跳）会立即停止，回答可见后工具区块不会再被重发。
- 流式推理引用（`/reasoning stream`）不算回答文本：工具运行时 draft 会用工具区块替代该引用，等真正的回答文本到达后再照常切换为文本。
- 该区块在 Telegram 的两条投递路径上都会渲染——轮询循环与 gateway/webhook 路径。
- `tool_progress=false` 保留原有行为，但会去掉误导性的 `Current size: 0 bytes` 行：draft 只显示纯 elapsed 时间和“仍在准备中”的提示。

关于 `rich_messages`：

- 默认值为 `false`。开启后回复改用 Bot API 的 `sendRichMessage` 方法以 GFM Markdown 发送，模型可以使用标题、表格、任务列表、脚注、`==mark==`、`||spoiler||` 和 `$math$`。
- 默认关闭是因为部分 Desktop/Web/Android 以及第三方客户端会把富消息渲染为“不支持”的占位符。
- 任何富消息发送或编辑失败都会回退到原有的 HTML/纯文本路径，回复不会丢失。
- 超过 20 列的表格会退化为代码块发送。
- 富消息中的纯文本换行会作为 GFM 硬换行发送，因此 `/status` 等多行输出会保持分行；围栏代码、缩进代码、跨行的行内代码和表格保持原有结构。代码内容（包括 heredoc 结束标记）不会被添加行尾空格。行内代码只在同一 Markdown 段落中匹配，未配对的反引号不会跨入后续代码围栏；以强调、行内代码或普通数字开头的文本行也会保留视觉换行。
- 转义说明：Bot API 只文档化了一个富 Markdown 转义（`\#hashtag`），并说明富 Markdown 可包含任意 HTML。对模型输出中原始 `<` 的 `\<` 转义（避免被解析为 HTML 标签）遵循 GFM/CommonMark，那里任何 ASCII 标点都可以用反斜杠转义。如果客户端不识别该转义，回复里偶发的原始 HTML 标签会按字面标签渲染而不是显示标签文本（仅是外观问题，且只有在模型不顾提示仍输出原始 HTML 时才会发生）。`==`、`||` 和 `$math$` 按设计原样传递。

关于 `account_id`：

- `account_id` 标识的是配置中的 Telegram 账号条目，不是 topic 也不是 agent。
- 在标准 `channels.telegram.accounts` 布局中，对象 key 就是 account id。例如 `accounts.main` 意味着 `account_id = "main"`。
- `bindings` 中的 `match.account_id` 将 binding 限定到某个特定 Telegram 账号。
- 如果省略 `match.account_id`，该 binding 可匹配该 channel 下的任意 Telegram 账号。
- 只有同一个 nullclaw 实例运行多个 Telegram bot 账号/token 时，不同 account id 才有意义。

### Web UI / Browser Relay

`channels.web` 用于浏览器 UI / 扩展通过 WebSocket 接入，默认路径是 `/ws`。

示例：

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

实用规则：

- 想使用“先连上再配对”的本地体验，保持 `listen = "127.0.0.1"`。
- 在 local transport 下，只有 loopback 才允许未鉴权的 WebSocket upgrade；这样 UI 才能先连上，再发送 `pairing_request`。
- local loopback 配对流程不再依赖固定共享码。`pairing_request` 可以省略 `payload.pairing_code`，仍然发送旧值 `123456` 的 loopback 客户端也保持兼容。
- 如果把 `listen` 改成 `0.0.0.0` 或其他非 loopback 地址，那么 WebSocket upgrade 一开始就必须带上 channel token：
  - `ws://host:32123/ws?token=<auth_token>`
  - 或 `Authorization: Bearer <auth_token>`
- 非 loopback bind 下，不要假设 local `pairing_request` 还能在未鉴权连接上工作；这个 pairing-first 流程本来就是只给 loopback 用的。
- `message_auth_mode = "pairing"` 表示每条 `user_message` 都要带上 pairing 流程返回的 UI `access_token`。
- `message_auth_mode = "token"` 只支持 local transport，并且要求使用配置或环境变量中的稳定 token。此模式下，UI 每条 `user_message` 发送 `auth_token`，而不是 pairing JWT。
- `auth_token` 既可以加固 WebSocket upgrade，在非 loopback bind 时也会变成必需项。
- WebSocket 端点用的是 `/ws`。`/pair` 属于 HTTP gateway API，不是 web channel 的 WebSocket 配对入口。
- 对于 headless/LAN 场景，更稳妥的运维路径仍然是 SSH 隧道，或者在 loopback 绑定前面加反向代理。

远程 / 无头设备示例：

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

Max 示例：

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

Max 说明：

- `channels.max.accounts` 是账号条目对象；每个对象 key 就是用于区分多个 Max bot 的 `account_id`。
- 生产环境推荐 `mode = "webhook"`。Max 文档将 long polling 定位为开发/测试用途，webhook 是推荐的生产路径。
- `webhook_url` 必须使用 HTTPS。
- 多账号 webhook 场景下，每个账号应使用独立的 `webhook_secret` 或在 webhook URL 中使用独立的 `account_id` query，例如 `/max?account_id=main`。
- `allow_from` 和 `group_allow_from` 接受 Max `user_id` 或用户名。`user_id` 是更稳定的选择。
- `require_mention = true` 仅影响群聊。私聊和 `bot_started` deep link 不受影响。
- Max inline button 在 nullclaw 中是一次性的：有效点击后原始键盘会被清除，避免过期按钮。

### Slack

Slack 示例：

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

参数说明：

- `mode`（默认 `socket`）——`socket` 使用 Socket Mode（需要 `app_token`）；`http` 在 `webhook_path` 接收 Events API webhook，需要 `signing_secret`
- `bot_token`（必填）——Bot User OAuth token（`xoxb-...`）
- `app_token`（可选）——App-level token（`xapp-...`），`mode = socket` 时必填
- `signing_secret`（可选）——`mode = http` 时必填
- `webhook_path`（默认 `/slack/events`）——`mode = http` 的 webhook 路径
- `channel_id`（可选）——Socket Mode 不可用时，history 轮询回退所轮询的频道
- `allow_from`（默认 `[]`）——用户 ID 白名单。留空或省略会拒绝所有入站消息；仅在确实需要开放 bot 时使用 `["*"]`
- `dm_policy`（默认 `pairing`）——`allow`、`deny`、`allowlist`/`pairing`
- `group_policy`（默认 `mention_only`）——`open`、`allowlist`、`mention_only`
- `reply_to_mode`（默认 `off`）——`off` 仅在触发消息本身已是 thread 回复时才用 thread；`all` 始终在 thread 中回复
- `implicit_thread_mention`（默认 `true`）——在 bot 已发言过的频道 thread 中，后续回复在 `group_policy = mention_only` 下视为已 mention，无需再次 @ bot 即可继续对话。顶层消息与 DM 不受影响
- `status_reactions`（默认 `true`）——在触发消息上用 reaction 显示任务状态：`accepted`、`running`，最后是 `done` 或 `failed`。需要 `reactions:write` 权限
- `reaction_emojis`（默认 `eyes`、`hourglass_flowing_sand`、`white_check_mark`、`x`）——按状态覆盖 `accepted`、`running`、`done`、`failed`。Slack 用短名而非 emoji 本身；空字符串表示该状态不加 reaction（并移除已有的）
- `slash_command`（默认关闭）——单命令 Slack 集成：注册一个斜杠命令，并把其后的文本当作普通消息处理。见下文
- `streaming`（默认 `false`）——在回复仍在生成时就展示，见下文
- `long_reply_file_threshold_chunks`（默认 `9`）——最终回复所需分片超过该值时，只发送可读的首片，并把完整回复作为 `reply.md` 上传到同一线程/DM。`0` 表示禁用上传。见下文

#### Slack 媒体

回复可以用与 Telegram 相同的附件标记：`[IMAGE:/abs/path.png]`、`[FILE:/abs/path.pdf]`（也支持 `DOCUMENT`、`VIDEO`、`AUDIO`、`VOICE`）。nullclaw 依次调用 `files.getUploadURLExternal`、上传文件、`files.completeUploadExternal`，把文件发到同一频道/线程，并从文本中移除标记。仅接受本地路径；单个文件上限 20 MB。与 Telegram 不同，Slack 需要 nullclaw 自己读取文件，因此标记中的 `http(s)` URL 会被拒绝，不会在服务端抓取。

入站 `file_share` 消息在 Socket Mode 下不再被丢弃（history 轮询回退同样生效）。nullclaw 用 bot token 下载 `url_private`（上限 20 MB）：

- 图片保存到临时文件，并以 `[IMAGE:/tmp/...]` 交给 vision 通路
- 音频（包括 Slack 语音剪辑：其 subtype 为 `slack_audio`、MIME 却是 `video/*`）走共享的 `tools.media.audio` 转写管线，以 `[Voice]: <转写文本>` 进入对话；未配置转写 provider 时降级为 `[ATTACHMENT:audio ...]` 标记
- 其他文件保存后以 `[FILE:/tmp/...]` 传入
- 消息文字（caption）照常处理

Socket Mode 的下载在独立的入站 worker 上执行，websocket 读取线程可继续确认 envelope 并响应 ping；重复投递的事件（相同 `event_id`）只处理一次。

所需 bot scopes：入站下载需要 `files:read`，出站上传需要 `files:write`（外加 `chat:write`）。下载只允许 Slack 自己的 HTTPS 域名且不跟随重定向，bot token 不会发往其他主机。

webhook 模式（`mode = http`）不处理附件：Slack 要求 3 秒内应答，下载无法满足该时限，因此该模式下 `file_share` 事件只会被确认并跳过（caption 也不会处理）。需要入站媒体时请使用 `mode = socket`。

#### Slack 斜杠命令

只有应用注册了斜杠命令，Slack 才会投递它，且 Slack 界面每次注册只支持一个命令。设置 `slash_command.enabled = true`，并在 Slack 应用里注册同名命令：

```json
"slash_command": { "enabled": true, "name": "nullclaw" }
```

`name` 是不带前导 `/` 的命令名（默认 `nullclaw`），匹配不区分大小写。Socket Mode 下应用配置里的请求 URL 会被忽略，因为 Slack 通过 WebSocket 投递 payload。

输入 `/nullclaw <消息>` 后，命令之后的文本会像用户在该频道里直接输入一样被处理。所有普通命令都可用，包括 `/nullclaw /stop`——它会像手动输入 `/stop` 一样中断该频道（或该用户 DM）正在运行的回合；由于斜杠命令始终是顶层的，它也会中断该频道下某个 thread 里正在运行的回合。斜杠命令是对应用的显式调用，因此被视为一次 mention：`allow_from` 以及 DM/群组 allowlist 检查依然生效，但 `group_policy = mention_only` 不会拦截它。若不希望所有被允许的成员都能在 mention_only 房间里驱动 agent，请收紧 `allow_from`（或群组 allowlist）。空命令会返回一条简短用法提示；未授权发送者会收到一条短暂的 ephemeral 拒绝；与配置的 `name` 不匹配的命令名会被记录日志并以 ephemeral 提示回应，而不是被静默丢弃。

在应用 manifest 的 `features` 下添加（Socket Mode）：

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

并在 `oauth_config.scopes.bot` 中加入 `commands` scope。

#### Slack 状态 reaction

`status_reactions = true` 时，nullclaw 用 `reactions.add` 在触发消息上加 reaction，随任务推进在 `accepted`、`running`、`done`/`failed` 之间切换，并在该状态的短名为空时用 `reactions.remove` 移除。Slack 的 reaction 是累加而非替换，因此会显式移除上一个状态。

插入正在运行轮次的消息也会收到该轮次的终态 reaction，包括轮次被中断或后续轮次失败的情况。即使不同账号或通道共用一个 session，每条插入消息也会通过其原始通道和账号收尾。`done` 或 `failed` 为空时会移除该消息的确认 reaction。

把 `accepted` 和 `running` 设为同一个短名，可以让每轮只产生一次 reaction 请求：

```json
"status_reactions": true,
"reaction_emojis": {
  "accepted": "hourglass_flowing_sand",
  "running": "hourglass_flowing_sand",
  "done": "",
  "failed": "warning"
}
```

若应用没有 `reactions:write`，Slack 返回 `missing_scope`，nullclaw 只记录一次并停止对该账号尝试。

#### Slack 流式回复

开启 `streaming = true` 后，nullclaw 会边生成边推送，而不是等完整回复再发送。按回复目标选择两条通路：

- **原生流式**——目标是 thread 时（`reply_to_mode = all`、入站消息本身是 thread 回复，或 assistant thread），nullclaw 依次调用 `chat.startStream`、限流的 `chat.appendStream`，最后 `chat.stopStream`。Slack 只允许在 thread 内流式输出，因此顶层目标不会走这条通路。
- **编辑消息**——顶层目标，或 Slack 拒绝原生方法时，nullclaw 用 `chat.postMessage` 发一条消息，再用限流的 `chat.update` 更新它。

增量会被合并（每轮最多每秒一次 API 调用），以落在 Slack 各方法的速率限制内。工具调用标记在发送前始终会被剥离。如果原生流式调用返回永久性错误（`channel_type_not_supported`、`missing_scope`、`invalid_thread_ts` 等），nullclaw 会对该账号停止尝试原生方法，之后改用编辑消息。若追加调用返回 `msg_too_long`，实时更新会切换到编辑消息并继续推送受限预览。预览按 Slack 转义后的文本长度保留最新内容；最终分片均按转义预算适配 Slack 限制，发送首条消息与最多八条后续消息（超出上限部分会被记录告警并在最后一个分片标注截断提示）。
当最终回复超过 `long_reply_file_threshold_chunks`（默认 9）片时，nullclaw 只发送可读的首片，并把完整 Markdown 回复作为 `reply.md` 上传到同一线程/DM，不再发送后续消息。上传失败则回退为上述分片投递。上传沿用现有的 `files:write` 权限，无需新增 scope。

关于 Slack 的 `tool_progress`：默认开启。当一轮对话运行时，nullclaw 会把 assistant 状态设为 `is working…`，并通过 `loading_messages` 传入最新的工具操作（例如 `🔧 web_fetch example.com`），让长时间、多次工具调用的回合能看到 agent 正在做什么。状态每约 6 秒刷新一次，以免被 Slack 的两分钟状态超时清除；更新会合并，每个 thread 每秒最多一次 API 调用。提示是保守的：文件路径只保留文件名，URL 只保留主机名，搜索查询会截断，shell/未知工具只显示工具名——原始参数永远不会被渲染。状态与 typing 指示器使用同一个目标：thread 回复使用该 thread，顶层消息或 DM 使用消息自身的 thread 根，因此这些会话也能看到操作行。该状态会显示在 Slack 的 Assistant/Agent View 体验中，在其他客户端为尽力而为。`assistant.threads.setStatus` 目前接受 `assistant:write` 或 `chat:write`（Slack 计划之后仅要求 `chat:write`）；nullclaw 沿用现有的 `chat:write` 权限，无需新增 OAuth scope，并且在 `streaming` 关闭时也能工作。状态 reaction（默认沙漏）仍用于标记每条消息的进度，nullclaw 不会额外发送进度消息。将 `tool_progress` 设为 `false` 可只保留简单的 `is typing...` 状态。

关于 `session_status`（Slack 智能助手会话状态）：默认关闭（`session_status = false`）。开启后，nullclaw 通过 `agents.sessions.setStatus` 驱动 Slack 的 Agents 会话状态（Turn 执行期间为 `processing`，完成或失败后置为 `active`；`suspended` 保留给未来的人工审批挂起机制）。与 `tool_progress` 一致，状态跟随该轮的线程目标：顶层消息或 DM 使用消息自身的 ts 作为 thread 根（即 typing 指示器使用的同一个 `channel:message_ts` 目标），因此这些会话同样会获得会话状态，而不是被跳过。

原生 **Stop**（停止）按钮支持：当 `session_status = true` 且 Slack 应用订阅了 `agent_session_stopped` 事件时，用户点击 Slack 界面原生 Stop 按钮会通过 Socket Mode 触发该事件，nullclaw 会立即以高优先级中断当前 turn。原生 Stop 是对 bot 的显式调用，因此与 Block Kit 按钮、斜杠命令一样无需正文 mention：`group_policy = mention_only` 不会拦截它，但 `allow_from`、DM 策略与拉黑检查依然生效（且仅接受非 bot 发送者）。未授权或异常事件直接丢弃。残留状态的兜底恢复是尽力而为：它被投递到 inbound worker 队列执行，Socket Mode reader 线程绝不发送状态 POST，队列满时直接丢弃。

权限与 Manifest 变更说明：
- 沿用现有的 `chat:write` bot scope，无需申请任何新的 OAuth scope。
- 依赖 Slack 的 Agents & AI Apps / Agent View 特性 —— `features.agent_view`（从旧版 `features.assistant_view` 迁移不可逆转）或 `features.assistant_view`：
  ```json
  {
    "features": {
      "agent_view": {
        "agent_description": "Describe what your agent does."
      }
    }
  }
  ```
  `features.agent_view` 取代 `features.assistant_view`，其嵌套的 `assistant_description` 相应改为 `agent_description`。按 Slack 文档说明，应用从 `assistant_view` 切换到 `agent_view` 后无法回退，请先在单独的应用或工作区上验证。
- Manifest 配置调整（Socket Mode）：在 `settings.event_subscriptions.bot_events` 中添加 `agent_session_stopped`：
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

#### 草稿中的实时推理

使用 `/reasoning stream` 时，模型的思考过程会在生成过程中实时显示在 Slack 与 Telegram 的草稿里。思考内容以 `>` 引用形式渲染（Slack 为 blockquote；Telegram 草稿不设置 parse mode，因此是带 `>` 前缀的纯文本），模型开始写正文后答案出现在其下方。过长的思考会按平台上限截断并保留尾部，同时沿用原有的每轮限流。

无论哪种模式，最终送达的回复都不包含思考内容：

- `stream`——思考只在草稿中实时展示。
- `on`——不实时展示，改由最终回复追加 `Reasoning:` 区块。
- `off`——丢弃思考内容。

由于草稿中包含最终回复不包含的文本，当某一轮流式输出了推理内容时，Slack 会用 `chat.update` 就地改写已结束的消息，而不是再发一条回复。对于没有地方展示推理内容的渠道，实时预览仍保持剥离。

Slack 应用侧必需配置：

1. 在应用设置的 *Features* 中启用 **Agents & AI Apps**（界面可能只显示 **Agents**）。这是 `chat.startStream` 的功能开关，且需要付费 Slack 套餐。
2. Bot token scopes：`chat:write`（所有出站回复必需），以及 `assistant:write`（把应用声明为 agent 时会自动添加）。如果依赖 history 轮询，再加 `im:history` 与 `channels:history`；媒体收发需要 `files:read` 与 `files:write`。
3. Events：`app_mention`、`message.im`、`message.channels`（assistant thread 另需 `assistant_thread_started` / `assistant_thread_context_changed`）。
4. 修改 scope 后需重新安装应用，然后重启 nullclaw。

即使没有该功能或 scope，`streaming = true` 也不会造成故障：第一次 `chat.startStream` 会被拒绝，回复自动回退到编辑消息通路，且每个账号只记录一次警告。

验证：

```bash
nullclaw channel start slack
nullclaw channel status
```

`nullclaw channel start slack` 只启动第一个配置的 Slack 账号。多账号验证请运行 `nullclaw gateway`，并给每个 bot 各发一条测试消息。

常见问题：

- 回复仍是完整后才出现：确认 `streaming` 为 `true`、应用已启用 Agents & AI Apps，并在日志中查找 `Slack native streaming unavailable for this app`
- 日志出现 `missing_scope`：添加 `chat:write` 与 `assistant:write` 后重新安装应用
- 频道里没有流式输出：Slack 只支持在 thread 内流式输出，请把 `reply_to_mode` 设为 `all`
- 完全没有回复：检查 `allow_from`；在群里还需确认 bot 被 @ 提及

### `session`

自动重置会话记录，在下一条入站消息到达时惰性判断（没有定时器）。默认不启用。

- `session.reset.mode`：`none`（默认）、`daily` 或 `idle`。
- `session.reset.at_hour`（默认 `4`）：每日重置边界的小时，自动夹到 `0`-`23`。**按 UTC 计算**；OpenClaw 使用宿主机本地时区。
- `session.reset.idle_minutes`：`idle` 模式下的空闲分钟数，必须为正数；`null` 表示永不过期。
- `session.reset_by_type`：可选的 `direct`、`group`、`thread` 覆盖。存在的条目会整体替换该类型的 `reset` 策略；thread key 优先于 group key。
- 配置键使用 snake_case，同时接受 OpenClaw 的 camelCase 别名（`atHour`、`idleMinutes`、`resetByType`）。未写 `mode` 的 reset 块按 `daily` 处理（与 OpenClaw 一致）。
- 重置复用 `/new` 路径：清理实时历史、待执行的 exec 命令、当前 skill、token 与 compaction 计数、会话级 memory 行以及持久化会话记录。重置是静默的（仅写日志），在下一轮刷新活跃时间之前执行，且不会在轮次进行中触发。
- `created_at`（会话开始时间）用于 `daily`；`last_active` 用于 `idle`。每日状态不持久化，因此空闲回收后的重启会重新开始一个每日窗口。
- 兼容旧配置：显式写了 `session.idle_minutes` 且没有 `session.reset` 时，会映射为 `{ "mode": "idle", "idle_minutes": <值> }`。旧结构默认的 60 分钟**不会**开启自动重置。

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

- `backend`: 建议从 `sqlite` 开始。可选引擎：`sqlite`、`markdown`、`clickhouse`、`postgres`、`redis`、`lancedb`、`lucid`、`memory`（LRU）、`api`、`none`。
- `auto_save`: 开启后会自动持久化会话记忆。
- `auto_recall`（默认：`true`）：设为 `false` 时跳过对入站消息的自动记忆注入。`auto_save` 的存储和 `memory_recall` 工具的按需召回不受影响。
- `recall_limit`（默认：`5`）：每条消息最多注入的记忆条数。
- `max_context_bytes`（默认：`4000`）：注入记忆块的总字节预算，包含头部、键、分隔符与结尾换行。单条记忆会被截断到预算的一半；按 UTF-8 字节计数。若某条记忆会超出预算，则整条丢弃，而不是先写入再裁剪。
- `recall_limit` 与 `max_context_bytes` 必须为非负值；负值会作为配置错误报告，而不是直接崩溃。超出 JSON 解析器可表示范围的值会被忽略。
- 归档的会话分片（hygiene 保存的旧轮次副本）不参与自动注入。由于 hygiene 在保留归档后会删除原始条目，`memory_recall` 工具提供 `include_archived`（默认 `false`），以便显式检索历史轮次。
- 可扩展 hybrid 检索与 embedding 配置（见根目录 `config.example.json`）。

**注意**：`markdown_only` 内存配置文件会自动启用混合检索和时间衰减（半衰期 30 天），以实现最佳的相关性评分。这确保了对纯 markdown 文件的时间感知能力。

### `gateway`

- 默认推荐：
  - `host = "127.0.0.1"`
  - `require_pairing = true`
- 不建议直接公网监听；如需外网访问，优先使用 tunnel。
- 如果绑定到非 loopback 地址，像 `/webhook`、`/a2a`、`/media/transcribe` 这类通用网关端点即使关闭了交互式 pairing，也仍然要求完整权限的 gateway bearer token，因此应保持 `require_pairing = true`，或者预先配置 `paired_tokens`。`/cron/*` 也接受下文所述的独立 cron-scoped 凭据。
- 如果绑定到非 loopback 地址，`/pair` 只接受 loopback 客户端；要么先在本机完成初始 pairing，要么在公开端口前预先配置 `paired_tokens`。
- 需要 cron 鉴权时，gateway 会在启动时创建一个仅限 `/cron/*` 使用的 bearer token。gateway 只保留其哈希，并把加密后的凭据以 `0600` 权限写入配置目录下的 `paired_token`，因此启用了 `require_pairing` 或公开绑定时，schedule/cron 工具也能完成认证，包括配置了预设 pairing token 的情况。该凭据会在每次 gateway 重启时轮换，不属于交互式 `/pair` token。与其他 bearer 凭据一样，它不绑定客户端 IP；必须防止配置目录泄露。`require_pairing = false` 的匿名 loopback gateway 不会创建此凭据。

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `host` | `"127.0.0.1"` | 监听地址 |
| `port` | `3000` | 监听端口 |
| `require_pairing` | `true` | 所有 API 请求均需 bearer token |
| `allow_public_bind` | `false` | 允许绑定非回环地址 |
| `pair_rate_limit_per_minute` | `10` | 每 IP 每分钟最大 `/pair` 请求数 |
| `webhook_rate_limit_per_minute` | `60` | 每 IP 每分钟最大 webhook-like 鉴权请求数。实时 `/media/transcribe` 音频分片场景可适当调高。 |
| `idempotency_ttl_secs` | `300` | 幂等请求结果缓存时长（秒） |
| `max_body_size_bytes` | `65536` | HTTP 请求体最大字节数（64 KB）。接受图片、音频或文件负载时需调高（如 `67108864` 表示 64 MiB）。 |
| `request_timeout_secs` | `30` | 入站 HTTP 请求的 socket 读取超时（秒）。在慢速或高延迟连接下接受大体积负载时需调高。 |

### `tunnel`

隧道服务，用于将本地网关暴露到公网。当没有公网 IP 但需要接收 webhook 回调时使用。

**支持的隧道：**

| 隧道 | 说明 |
|--------|------|
| `none` | 不使用隧道（默认） |
| `cloudflare` | Cloudflare Tunnel |
| `ngrok` | ngrok 隧道 |
| `tailscale` | Tailscale Funnel |
| `custom` | 自定义命令启动隧道 |

**ngrok 示例：**

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

**Cloudflare 示例：**

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

**Tailscale 示例：**

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

**注意：**

- 隧道会在网关启动前自动启动。
- 启动后公网 URL 会打印到控制台，同时写入 `daemon_state.json`。
- `tailscale.auth_key` 是可选项；当你希望启动 `serve`/`funnel` 之前自动执行 `tailscale up` 时再配置它。
- `cloudflare.token`、`ngrok.auth_token`、`tailscale.auth_key` 这类隧道凭据在 `secrets.encrypt = true` 时会以加密形式落盘。

### `autonomy`

- `level`: 推荐先用 `supervised`。
- `workspace_only`: 建议保持 `true`，限制文件访问范围。
- `max_actions_per_hour`: 建议保守设置，避免高频自动动作。
- `block_high_risk_commands`（默认：`true`）：屏蔽破坏性命令，如 `rm`、`sudo`、`mkfs`、`dd`、`shutdown`、`ssh`。
- `block_medium_risk_commands`（默认：`true`）：屏蔽中风险命令，包括网络/传输类命令（如 `curl`、`wget`、`nc`、`scp`、`ftp`、`telnet`）以及会改变状态的命令（如 `git commit`、`npm install`、`touch`、`mkdir`）。设为 `false` 可允许这些命令，同时仍屏蔽高风险命令。
- `require_approval_for_medium_risk`（默认：`true`）：当 `block_medium_risk_commands` 为 `false` 时，在 `supervised` 模式下执行中风险命令前需要明确批准。
- `allowed_commands`：允许的命令基础名称列表。仅在 full 自主模式下可使用 `["*"]` 通配符。高风险与中风险的运行时拦截无论此列表如何设置都会生效。

### `security`

- `sandbox.backend = "auto"`：自动选择可用隔离后端（如 landlock/firejail/bubblewrap/docker）。
- `audit.enabled = true`：建议开启审计日志。

### 进阶：Web Search + Full Shell（高风险）

仅在你明确理解风险时使用。示例：

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

注意：

- `search_base_url`（用于 web_search 工具）：必须是 `https://host[/search]` 或本地/内网的 `http://host[:port][/search]` URL。HTTP 仅允许用于 localhost/私有主机（如 `http://localhost:8888`、`http://192.168.1.10:8888`）。此 URL 供 `web_search` 工具查询 SearXNG 实例使用。
- `allowed_commands: ["*"]` 与 `allowed_paths: ["*"]` 会显著扩大执行范围。
- `http_request.allowed_domains`：绕过 SSRF 保护的域名列表，用于 `http_request` 和 `web_fetch` 工具。
  - `[]` (空数组)：所有域名经过 SSRF 检查（默认，最安全）。
  - `["example.com"]`：只有指定域名跳过 SSRF 保护。
  - `["*.example.com"]`：匹配所有子域名（如 `api.example.com`、`www.example.com`）。
  - `["192.168.1.10"]`：IP 地址也可以加入白名单（仅支持精确匹配，不支持 CIDR 范围）。
  - `["*"]`：**危险** - 所有域名跳过 SSRF 保护和 DNS 钉扎。仅用于可信网络环境，当你控制 DNS 且需要访问任意 IP 地址时使用。这实际上禁用了 SSRF 保护。
  - **示例**：如果你的 SearXNG 运行在 `192.168.1.10`，添加 `"192.168.1.10"` 即可通过 `http_request` 工具访问它。
  - **安全权衡**：白名单域名跳过 DNS 钉扎，允许访问私有 IP。这是用 DNS 重绑定防护换取操作灵活性。
  - **HTTPS-only 策略**：`http_request` 和 `web_fetch` 工具要求使用 `https://` URL。明文 HTTP 因安全原因被拒绝。注意：这不影响 `web_search` 工具的 `search_base_url`，后者允许本地主机使用 HTTP。
  - **检查顺序**：白名单在 DNS 解析之前检查，防止 DNS 渗漏攻击。

## 配置变更后的验证

每次改完配置建议执行：

```bash
nullclaw doctor
nullclaw status
nullclaw channel status
```

如果你修改了 gateway 或 channel，额外执行：

```bash
nullclaw gateway
```

确认服务能正常启动且日志无错误。

## 下一步

- 要验证配置是否可用：继续看 [使用与运维](./usage.md)，按回归检查清单逐项执行。
- 要加固默认边界：继续看 [安全机制](./security.md)，确认 pairing、sandbox 与 allowlist 设置。
- 要对接 webhook 或长期运行网关：继续看 [Gateway API](./gateway-api.md) 和 [命令参考](./commands.md)。

## 相关页面

- [安装指南](./installation.md)
- [使用与运维](./usage.md)
- [安全机制](./security.md)
- [Gateway API](./gateway-api.md)
