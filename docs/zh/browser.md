# 浏览器自动化（Lightpanda）

junclaw 额外发布 `main-lightpanda` 镜像变体，在标准镜像中加入
[Lightpanda](https://github.com/lightpanda-io/browser) 无头浏览器。Lightpanda
以独立进程运行，经其自带的 MCP server 接入，因此 junclaw 不新增浏览器后端：
复用 [MCP](./mcp.md) 中已有的客户端，通过 stdio 连接。

本页只覆盖 Lightpanda 变体（阶段 1）。Firefox/WebDriver 浏览器后端属于阶段 2，
不在本镜像范围内。

## 变体包含什么

- 追加式 `lightpanda` Dockerfile target；release target 保持不变。
- Lightpanda 1.0.2 官方 glibc 二进制，按架构下载，并在构建时用固定的 SHA-256
  校验。
- 供 Lightpanda 使用的 Debian 13 运行时，加上正常构建出的静态 musl junclaw
  二进制。
- 通过 `LIGHTPANDA_DISABLE_TELEMETRY=true` 关闭遥测。
- 非 root 用户，uid/gid 65534。

agent 看到的工具名是 `mcp_lightpanda_<tool>`（例如 `mcp_lightpanda_goto`）。
工具在启动时发现一次；修改配置后需重启 junclaw。

## 配置 MCP server

在 `~/.nullclaw/config.json` 中加入：

```json
{
  "mcp_servers": {
    "lightpanda": {
      "transport": "stdio",
      "command": "lightpanda",
      "args": ["mcp", "--block-private-networks"],
      "timeout_ms": 30000,
      "tools": [
        "goto",
        "markdown",
        "links",
        "click",
        "fill",
        "interactiveElements",
        "scroll",
        "waitForSelector",
        "structuredData",
        "search"
      ]
    }
  }
}
```

- `command`/`args`：镜像内 `lightpanda` 在 `PATH` 上；`mcp` 子命令以 stdio
  启动服务器。
- `--block-private-networks`：保持开启，见[安全模型](#安全模型)。
- `timeout_ms`：`30000` 为冷启动和慢页面留出余量。实测 `example.com` 约 0.3
  秒，343 KB 的页面约 1.1 秒，但 JavaScript 较重的页面可能更久。不够就改
  `60000`；默认 `10000` 对页面抓取偏紧。
- `tools`：原始 `tools/list` 名称的白名单，不带 `mcp_lightpanda_` 前缀。省略
  或留空会注册全部工具；服务器没有暴露的名字会告警并忽略。见
  [工具白名单与 token 成本](#工具白名单与-token-成本)。
- 默认不要加 `--cookie-jar`。cookie jar 会在退出时把 cookie 落盘，扩大泄露
  面；只有工作流需要登录态跨重启保留时才开启。

## 工具白名单与 token 成本

Lightpanda 1.0.2 的完整 `tools/list` 约 39 KB，约合 1 万 token。注册全部工具
会让每次模型请求都带上这份载荷。上面的白名单只保留以下十个 schema：

| 工具 | 用途 |
|------|------|
| `goto` | 打开 URL，并把页面留在内存中 |
| `markdown` | 把页面或选中的子树渲染为 Markdown |
| `links` | 列出页面上的链接 |
| `click` | 点击元素 |
| `fill` | 向输入框键入文本 |
| `interactiveElements` | 列出页面上的可交互元素 |
| `scroll` | 滚动页面或元素 |
| `waitForSelector` | 等待元素出现 |
| `structuredData` | 提取 JSON-LD / OpenGraph 数据 |
| `search` | 执行 web 搜索并以 Markdown 返回结果；不会导航当前页面 |

有两个工具是刻意排除的：

- `evaluate` 在页面上下文执行任意 JavaScript。这给了模型脚本执行能力和数据
  外带路径：它可以读取页面数据并发送到任意主机。默认不启用。只对可信站点
  添加，并且把它的输出视为不可信。
- `screenshot` 返回的是 Lightpanda 计算出的文本布局 PNG，不是像素级渲染
  （没有图片、字体或 CSS 颜色）。文本页面用 `markdown` 或 `links`；确实需要
  布局图时再加 `screenshot`。

其他可用工具（如 `html`、`tree`、`extract`、`detectForms`、`waitForScript`、
`waitForState`、`findElement`、`hover`、`press`、`selectOption`、
`setChecked`、`getUrl`、`consoleLogs`，以及 cookie、env、session 类工具）为
控制上下文而省略。工作流需要时把原始名称加进 `tools`。

## 关键词过滤

若只想在需要时暴露浏览器，加入一个 `dynamic` 过滤组：

```json
{
  "agent": {
    "tool_filter_groups": [
      {
        "mode": "dynamic",
        "tools": ["mcp_lightpanda_*"],
        "keywords": [
          "http", "https", "www", "url", "web", "browse", "browser", "click",
          "search", "fetch", "网页", "网站", "页面", "打开", "浏览", "搜索",
          "链接", "抓取"
        ]
      }
    ]
  }
}
```

- `tool_filter_groups` 里的 `tools` 用带前缀的名字（`mcp_lightpanda_*`）；
  `mcp_servers` 里的 `tools` 用原始名字（`goto`）。
- 匹配是字节子串搜索，不是按单词或 token 匹配。ASCII 字母按大小写不敏感
  比较。
- 中文关键词可用：0x7F 以上的 UTF-8 字节原样比较，因此 `网页` 这样的关键词
  会匹配消息中任意位置的同一字节序列，不需要分词。
- 因为是子串匹配，短关键词可能过度命中：`url` 会命中 `curl`，`web` 会命中
  `website`。尽量用有区分度的词。
- `dynamic` 分组只在原生工具 schema 路径上生效；文本 prompt 路径无论关键词
  是否命中都不会包含它们，见
  [MCP](./mcp.md#两条工具暴露路径的行为不同)。如果 provider 不支持原生工具
  schema，改用 `mode: "always"`，并靠 `tools` 白名单控制上下文大小。

## 安全模型

- **内网与 SSRF。** `--block-private-networks` 上游默认 false；推荐配置会开启。
  Lightpanda 在 DNS 解析后拒绝发往私有/内部地址的页面请求。1.0.2 实测包含
  loopback：开启后访问 `http://127.0.0.1:<port>/` 和
  `http://localhost:<port>/` 都会以 `CouldntConnect` 失败；不开启则本地页面
  可以加载。该标记不拦 stdio MCP 传输，`--port` 模式下的 MCP `initialize`
  也仍然正常。
  - 本地调试例外：确实要抓 loopback 页面时，为该会话单独用一份一次性配置，
    去掉 `--block-private-networks`，并且绝不要用它访问不可信页面。该配置里
    保留 `--block-cidrs 169.254.169.254/32`，让云元数据地址仍被拦住。
- **云元数据。** 1.0.2 实测 `169.254.169.254` 在开启
  `--block-private-networks` 时会被拒绝；此时再加
  `--block-cidrs 169.254.169.254/32` 是冗余的，所以默认配置不加。任何去掉
  主开关的调试配置都要保留这条 CIDR。IPv6 元数据网段未单独实测；在暴露
  IPv6 元数据的云上按需补充 CIDR。
- **遥测。** Lightpanda 1.0.2 默认收集使用遥测，可用
  `LIGHTPANDA_DISABLE_TELEMETRY=true` 关闭。镜像已设置该变量。对镜像内二进制
  实测：默认环境会向 Lightpanda 遥测端点发送 DNS 与 TLS 流量；使用镜像环境
  变量后，`fetch`、`serve`、`mcp` 均未产生遥测包。在镜像外直接运行二进制时
  要自己设置。
- **非 root。** 容器以 uid/gid 65534 运行。
- **Cookie。** 默认不配置 cookie jar，cookie 不会落盘。加载（`--cookie`）或
  保存（`--cookie-jar`）cookie 都会扩大泄露面；只在确有需要时开启。
- **不可信的页面内容。** 网页可能包含 prompt injection 文本。保持工具白名单
  精简；抓不可信站点时不要加入 `evaluate`。
- **AGPL-3.0。** Lightpanda 以 AGPL-3.0 授权。镜像分发官方、未修改的 1.0.2
  二进制。合规材料在 `/usr/share/doc/lightpanda/`：`AGPL-3.0.txt` 为完整
  许可证，`NOTICE.txt` 含版本、1.0.2 tag 的源码地址、未修改声明，以及各架构
  的 SHA-256。junclaw 自身仍是 MIT。镜像是两个独立程序的聚合：Lightpanda
  没有链接进 junclaw，也不会改变 junclaw 的许可。若你修改 Lightpanda，AGPL
  的源码提供义务适用于你修改后的二进制；本镜像未做修改。

## 部署

```yaml
services:
  junclaw:
    image: ghcr.io/wray-lee/junclaw:main-lightpanda
    mem_limit: 256m
    volumes:
      - ./data:/nullclaw-data
```

- `mem_limit: 256m` 依据内存实测：20 次顺序页面抓取的进程 RSS 峰值约
  18.6 MiB，容器 cgroup 峰值约 23.6 MiB。256 MiB 为页缓存和并发工具调用
  留出余量；同时抓多个大页面时可调高。
- 配置位于 `/nullclaw-data/config.json`；镜像已设置
  `NULLCLAW_HOME=/nullclaw-data`。
- 镜像标签：
  - `main-lightpanda`：`main` 的滚动构建。
  - `main-lightpanda-<sha>`：对应 10 位提交 SHA 的固定构建。
  - `<tag>-lightpanda`：对应 git tag 的构建。
  - `latest` 仍指向瘦 release 镜像；浏览器变体需显式选用。
- CI 构建并校验 `linux/amd64`。Dockerfile 里有 aarch64 二进制的哈希，但
  arm64 镜像尚未构建或测试。
- 在镜像外运行 junclaw 时，请自行安装 Lightpanda 1.0.2 二进制并把
  `lightpanda` 放到 `PATH`。

## 相关页面

- [MCP](./mcp.md) — 传输方式、工具白名单与过滤分组
- [配置指南](./configuration.md) — 完整配置参考
- [安全机制](./security.md) — 安全模型
- [安装](./installation.md) — 镜像与二进制安装
