# MCP（模型上下文协议）

NullClaw 支持 [Model Context Protocol](https://modelcontextprotocol.io/)，通过外部工具和服务扩展 agent 能力。

## 传输方式

- **stdio**：以子进程方式启动 MCP 服务器，适合本地工具和 npm 包。
- **http**：通过 HTTPS（或 localhost HTTP）连接远程 MCP 服务器，支持自定义 headers 和超时。

## 配置

在 `~/.nullclaw/config.json` 的 `mcp_servers` 下添加：

```json
{
  "mcp_servers": {
    "filesystem": {
      "transport": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem"]
    },
    "remote": {
      "transport": "http",
      "url": "https://mcp.example.com/rpc",
      "timeout_ms": 10000,
      "headers": {
        "Authorization": "Bearer token-here"
      }
    }
  }
}
```

### 配置字段

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `transport` | string | `stdio` | `stdio` 或 `http` |
| `command` | string | — | stdio 传输的可执行文件 |
| `args` | array | `[]` | 命令参数 |
| `env` | object | `{}` | 环境变量覆盖：string → string 映射（`{"KEY": "value"}`） |
| `url` | string | — | HTTP 端点 URL（http 传输必需） |
| `timeout_ms` | number | `10000` | 单请求超时（毫秒） |
| `headers` | object | `{}` | 自定义 HTTP headers：string → string 映射 |
| `tools` | array | `[]`（全部） | 可选白名单：`tools/list` 返回的原始工具名（不带 `mcp_<服务器>_` 前缀，如 `goto`）。省略或空数组注册全部工具；不存在的名字告警后忽略 |

### 工具白名单

默认注册 `tools/list` 返回的全部工具。设置 `tools` 后只注册列出的原始工具名
（不含 `mcp_<服务器>_` 前缀），避免工具数量多或 schema 大的服务器（如 Lightpanda
约 25 个工具）占满模型上下文：

```json
{
  "mcp_servers": {
    "browser": {
      "command": "lightpanda",
      "args": ["mcp"],
      "tools": ["goto", "click", "markdown"]
    }
  }
}
```

服务器未暴露的名字会被忽略并记录 warn 日志。完整的浏览器配置见
[浏览器自动化（Lightpanda）](./browser.md)。

## 工作原理

启动时，nullclaw 连接每个 MCP 服务器，执行 `initialize` 握手，通过 `tools/list` 发现工具，以 `mcp_<服务器>_<工具>` 前缀暴露给 agent。

工具发现仅在启动时执行一次，重启 nullclaw 以加载新工具。

## 安全

- HTTP URL 必须为 HTTPS（localhost 和私有 IP 除外）
- Header 值禁止换行符
- 单个服务器连接失败不影响其他工具

## 工具过滤

通过 `agent.tool_filter_groups` 控制每轮包含哪些 MCP 工具：

```json
{
  "agent": {
    "tool_filter_groups": [
      {
        "mode": "always",
        "tools": ["mcp_filesystem_*"]
      },
      {
        "mode": "dynamic",
        "tools": ["mcp_jira_*"],
        "keywords": ["ticket", "jira", "issue"]
      }
    ]
  }
}
```

- `always`：匹配该模式的工具始终包含。
- `dynamic`：当用户消息包含该组关键词之一时包含（不区分大小写的 ASCII 子串匹配）。

若未配置任何 `tool_filter_groups`，本轮包含全部工具。

### 两条工具暴露路径的行为不同

这是最容易让人意外的地方：`always` 与 `dynamic` 的行为**并不一致**，
因为它们作用在不同阶段。

| | 原生工具 schema | 文本 prompt |
|---|---|---|
| 非 MCP（内置）工具 | 始终包含 | 始终包含 |
| `always` 分组匹配项 | 始终包含 | 始终包含 |
| `dynamic` 分组匹配项 | 关键词命中时包含 | **永不包含** |

- 在**原生工具 schema** 路径上，`dynamic` 分组会针对当轮用户消息做关键词匹配
  （`filterToolSpecsForTurn`），命中时该工具会出现在 provider 的工具列表中。
- 在**文本 prompt** 路径上，过滤器（`filterToolsForPromptText`）只接受内置
  工具和 `always` 分组工具。无论关键词是否命中，`dynamic` 工具都不会被写入
  prompt 文本。

两个使用原生工具 schema 的引擎共用同一实现：内置 agent 与进程内 dsh 引擎
（`agent.harness = "dsh"`，即默认值）每轮都用当轮用户消息调用一次
`tool_filter.toolExposed`。因此同一份 `tool_filter_groups` 配置和同一条消息在
两个引擎上暴露的 MCP 工具逐项一致，`dynamic` 在两个引擎上都生效；dsh 引擎
没有文本 prompt 工具列表，这是它唯一的工具暴露路径。

实际影响：如果你的 provider 不支持原生工具 schema，`dynamic` 分组会静默失效。
在依赖 `dynamic` 来压缩庞大的 MCP 工具面之前，请先用支持原生 schema 的
后端验证。

## 相关页面

- [浏览器自动化（Lightpanda）](./browser.md) — main-lightpanda 镜像与 MCP 配置
- [配置指南](./configuration.md)
- [架构总览](./architecture.md)
- [安全机制](./security.md)
