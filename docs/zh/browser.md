# 浏览器自动化

junclaw 的浏览器镜像提供两条互相独立的路线：

| 路线 | 镜像 | 模型看到的工具 |
|------|------|----------------|
| Firefox/WebDriver 后端 | `main-browser`、`full-dsh-browser` | 内置 `browser` 工具 |
| Lightpanda over MCP | `main-lightpanda` | `mcp_lightpanda_<tool>` |

Firefox 后端内置在 junclaw 里：它通过 geckodriver 启动 Firefox ESR，由
`browser` 工具提供八个动作。Lightpanda 路线以独立进程运行，经其 MCP server
接入，沿用 MCP 工具集。两条路线互不影响，按需要选择镜像和配置。不需要浏览器
自动化时，瘦 release 镜像（`latest`）不包含这两条路线。

## Firefox/WebDriver 后端

把 `browser.backend` 设为 `"webdriver"`，`browser` 的每个动作都由本地
Firefox 会话完成。geckodriver 由 junclaw 自行启动和停止；自动化链路不需要
系统浏览器、Node 或 Playwright。

### 镜像变体

- `main-browser`：release 二进制运行在 Debian 13 运行时上，外加 Firefox ESR
  和 geckodriver。
- `full-dsh-browser`：在 `full-dsh`（Node 22 与 dsh sidecar）之上叠加同一套
  浏览器层。
- geckodriver 0.37.1 按架构下载，并在构建时用固定的 SHA-256 校验。Firefox
  ESR 来自 Debian 的 `firefox-esr`（构建时为 153.5.1esr），随 Debian 安全
  更新浮动，因此没有按摘要固定。
- `fonts-dejavu-core` 让无头截图更清晰。`/usr/local/bin/firefox` 是指向
  `firefox-esr` 的符号链接，因为 geckodriver 会在 `PATH` 上查找 `firefox`。
- 两个镜像都以 uid/gid 65534 运行，入口与普通 `nullclaw` 镜像一致。

镜像标签：

| 标签 | 含义 |
|------|------|
| `main-browser` | `main` 的滚动构建 |
| `main-browser-<sha>` | 对应 10 位提交 SHA 的固定构建 |
| `<tag>-browser` | 对应 git tag 的构建 |
| `full-dsh-browser` | full dsh 变体的滚动构建 |
| `full-dsh-browser-<sha>` | 对应 10 位提交 SHA 的固定构建 |
| `<tag>-full-dsh-browser` | full dsh 变体的 tag 构建 |

- `latest` 仍指向瘦 release 镜像；浏览器变体需显式选用。
- 实测未压缩镜像大小：`main-browser` 为 843 MB，`full-dsh-browser` 为
  2.1 GB（linux/amd64）。这是镜像大小，不是运行时内存。
- CI 构建并校验 `linux/amd64`。Dockerfile 带有 aarch64 的 geckodriver
  哈希，但尚未构建或测试 arm64 镜像。

拉取 `ghcr.io/wray-lee/junclaw:main-browser` 或
`ghcr.io/wray-lee/junclaw:full-dsh-browser`，并挂载 `/nullclaw-data`；两者都
使用正常的 gateway 入口：

```yaml
services:
  junclaw:
    image: ghcr.io/wray-lee/junclaw:main-browser
    shm_size: 256m
    mem_limit: 1536m
    volumes:
      - ./data:/nullclaw-data
```

这两个上限按每个容器一个 Firefox 会话估算：`shm_size: 256m` 来自镜像冒烟测试
中真实页面的需要；`mem_limit: 1536m` 依据阶段 2 实测——热态空闲会话的 cgroup
占用约 350–421 MiB，冷启动首轮峰值 991–1012 MiB（含可回收页缓存），与 OOM
相关的唯一集峰值 427–453 MiB，可用区间 1280–2048 MiB。请按 cgroup 用量而不是
合计约 1.05 GiB 的 RSS 来定 `mem_limit`；后者会把共享页按进程重复计算。

浏览器不需要额外的 sidecar 或环境变量。需要 Node 22 和 dsh sidecar 时改用
`full-dsh-browser`；`browser` 工具在 dsh 引擎下由同一套工具注册，因此两个
变体的动作完全一致。

### 配置

在配置文件中启用内置工具并选择后端（镜像内为
`/nullclaw-data/config.json`，宿主机安装为 `~/.nullclaw/config.json`）：

```json
{
  "browser": {
    "enabled": true,
    "backend": "webdriver",
    "native_headless": true,
    "allowed_domains": ["example.com"],
    "webdriver_idle_timeout_ms": 120000
  }
}
```

- `enabled`：注册 `browser` 工具。默认关闭。
- `backend`：默认 `"agent_browser"`，用宿主浏览器打开页面并通过 curl 读取。
  Firefox 后端请设为 `"webdriver"`；这些镜像内没有可启动的宿主浏览器。
- `native_headless`：默认 `true`。设为 `false` 会启动带界面的 Firefox，需要
  显示器；不要在容器里使用。
- `allowed_domains`：控制 URL 策略。留空时允许任何可全局路由的 HTTPS 主机；
  非空时只允许精确主机和 `*.` 子域模式。取舍见[安全模型](#安全模型)。
- `webdriver_idle_timeout_ms`：空闲多久后停止 Firefox 和 geckodriver。默认
  `120000`（2 分钟）；`0` 关闭空闲停止。
- `webdriver_geckodriver_path`：覆盖 geckodriver 二进制路径。不设置时使用
  `PATH` 上的 `geckodriver`；镜像已把它装在 `/usr/local/bin`。
- `native_webdriver_url` 与 `native_chrome_path` 不被 WebDriver 后端使用。
  该后端始终在随机回环端口上自行启动 geckodriver，不连接外部 WebDriver
  端点。

修改配置后重启 junclaw。

### 动作

| 动作 | 参数 | 结果 |
|------|------|------|
| `open` | `url` | 导航并返回简短确认。 |
| `read` | `url` | 导航后返回标题、最终 URL 和页面文本（`innerText`）。输出上限 8 KB，超出时追加 `[Content truncated to 8 KB]`。 |
| `snapshot` | 无 | 返回标题、最终 URL、页面文本和带编号的可见可交互元素列表。输出上限 8 KB；文本最多 4 KB，元素最多 100 个。 |
| `click` | `index` 或 `selector` | 点击上次 snapshot 的编号元素，或 CSS selector。 |
| `type` | `index` 或 `selector`、`text` | 向元素发送文本。W3C send-keys 追加到当前值，不清空输入框。 |
| `scroll` | `direction`、`amount` | 滚动窗口。`direction` 为 `up`、`down`、`left` 或 `right`（默认 `down`）；`amount` 为 1–100000 像素（默认 500）。 |
| `screenshot` | 无 | 在 workspace 写 PNG，并返回带绝对路径的 `[IMAGE:...]` 标记，例如 `[IMAGE:/nullclaw-data/workspace/browser-screenshot-1a2b3c4d.png]`。回复中原样保留该标记；base64 数据不会进入模型。 |
| `close` | 无 | 停止 Firefox 和 geckodriver，删除临时 profile。下一个动作会重新启动浏览器。 |

`snapshot` 给每个可见可交互元素写入 `data-junclaw-ref="N"`，并打印
`[N] <tag> label detail`。编号在下一次 `snapshot` 前保持稳定；页面替换 DOM
或发生导航后编号失效，需要重新 `snapshot`。优先用 `index`；`selector` 是 CSS 回退。
`index` 可以是整数或数字字符串。`snapshot` 输出被截断时会追加与 `read`
相同的 `[Content truncated to 8 KB]` 标记。

读取页面内容时优先 `snapshot`（或 `read`）；截图只用于视觉检查。

`screenshot` 需要 workspace。文件名为 `browser-screenshot-<hex>.png`，会留在
workspace 中；junclaw 不会自动删除旧截图。支持附件的通道会把标记转成图片；
没有媒体能力的界面则保留为文本。

`agent_browser` 后端保持原行为：`open` 和 `read` 可用，`close` 会提示没有
可关闭的浏览器，`snapshot` 会提示需要 WebDriver 后端，`click`、`type`、
`scroll` 会提示 CDP 不可用，`screenshot` 会提示改用 `screenshot` 工具。

### 安全模型

WebDriver 后端采用与 `web_fetch` 相同的 URL 策略和信任模型。它不是网络沙箱。

- **只允许 HTTPS。** `http://`、`ws://`、`file://`、`data:` 和
  `javascript:` 在 Firefox 导航前就会被拒绝。allowlist 条目不会改变协议
  规则。
- **私网与元数据地址。** `allowed_domains` 为空时，每个主机都会解析，且必须
  映射到可全局路由的地址。回环、RFC 1918、链路本地、容器运行时别名，以及
  `169.254.169.254` 之类的云元数据地址都会被拒绝。这里复用 `web_fetch`
  背后的检查。
- **allowlist 的取舍。** `allowed_domains` 非空时，这份列表就是全部策略：
  只允许匹配的主机，匹配在 DNS 之前完成，且匹配的主机会跳过私网地址检查，
  因此可以指向内部服务。这与 `web_fetch.allowed_domains` 的
  “操作者显式信任”例外相同。私网必须不可达时请保持列表为空；不要为了打开
  不可信页面而加入私网或回环主机。
- **重定向与最终 URL。** Firefox 自己跟随重定向。每次导航后，以及在
  `snapshot`、`click`、`type`、`scroll`、`screenshot` 之前，junclaw 都会读取
  Firefox 实际落到的 URL 并重新校验。最终 URL 不通过时，页面会关闭，会话
  标记为 stale；下一个动作会重建会话。最终 URL 读取失败按失败处理。
- **不是网络沙箱。** Firefox 会自己为页面子资源解析 DNS。上述检查覆盖导航
  和最终 URL，不覆盖每个子资源；junclaw 的解析与 Firefox 的解析之间的 DNS
  rebinding 也不在覆盖范围内。局域网必须不可达时，请把容器放到隔离网络并在
  那里限制出站流量。
- **代理与浏览器策略手段尚未接入。** Firefox 可以用 `policies.json` 策略文件或
  `network.proxy.*` 首选项强制走代理、收敛出网。当前后端只生成自己的
  `user.js`（关闭遥测与更新等），不接受操作者提供的策略文件或代理首选项，
  因此现在没有受支持的方式在浏览器内固定出网。在该能力实现前，真正可执行的
  边界是部署侧网络隔离（容器网络与出站规则），不是 Firefox 配置。
- **页面脚本会运行。** Firefox 会执行页面 JavaScript。模型拿不到 JavaScript
  动作；`read`、`snapshot` 和 `scroll` 使用固定的内部脚本。页面输出按不可信
  输入处理。
- **一次性 profile。** 每次启动浏览器都会新建临时 profile，不包含宿主机的
  cookie 或存储。`close`、空闲停止和运行时停止时都会删除该 profile。
- **遥测与更新流量。** 生成的 `user.js` 会关闭 Firefox 遥测、健康报告、
  crash/breakpad 上报、Normandy 研究、搜索更新、附加组件发现、Pocket/FxA、
  captive portal 探测和远程下载信誉查询。浏览工具不应自行发起这些外联。
- **下载。** 下载文件写入临时 profile 内的 `downloads` 目录，不会进入
  workspace，并随 profile 一起删除。

不要为了打开页面而削弱这些检查。尤其不要为不可信页面把私网或回环主机加入
`allowed_domains`，也不要为了消除 Firefox 沙箱告警而关闭容器的 seccomp
配置（见[已知限制与验证状态](#已知限制与验证状态)）。

### 进程生命周期与并发

- **懒启动。** 第一次非 `close` 动作会先校验参数，然后启动 geckodriver 和
  Firefox。参数错误不会启动任何进程。
- geckodriver 监听 `127.0.0.1` 的随机端口。junclaw 最多轮询 `/status`
  10 秒；二进制缺失、启动失败或超时都会返回带原因的工具错误。geckodriver
  的输出不会转发。
- **每个运行时最多一个浏览器。** 一个运行时内的所有浏览器动作都走同一个
  manager 和同一个 WebDriver 会话；任一时刻该运行时最多只有一个 Firefox
  实例。互斥锁把命令串行化，因此并发的模型或通道请求会排队，而不会启动
  第二个 Firefox。这是针对 2.4 GB 目标机器的有意设计。
- gateway 可以创建多个会话运行时，每个启用浏览器的运行时都有自己的 manager。
  小机器上请把浏览器工作限制在一个运行时内；否则内存占用会成倍增加。
- **空闲停止。** 超过 `webdriver_idle_timeout_ms` 没有动作时，reaper 会停止
  Firefox 和 geckodriver。检查每 250 ms 一次。`0` 关闭空闲停止；`close`
  立即停止。
- **清理。** 停止路径会删除 WebDriver 会话，向 geckodriver 进程组发送 TERM，
  再以 KILL 兜底，然后删除临时 profile。重复调用是安全的。`close` 返回
  `Browser closed` 或 `Browser is not running`。
- **自愈。** Firefox 死亡（例如被 OOM 杀掉）或驱动丢失会话后，下一个动作会
  清理残留并重新启动一对 geckodriver/Firefox。驱动和传输失败会作为工具错误
  返回，不会让 agent 崩溃。

### 已知限制与验证状态

- **验证缺口。** 本阶段用脚本化的假 WebDriver 服务跑了自动化测试，并做了离线
  镜像冒烟测试：启动 Firefox、打开本地页面、删除会话。还没有让真实模型在真实
  网站上端到端驱动该工具。
- **aarch64。** 构建文件带有 arm64 的 geckodriver 哈希，但尚未构建或测试
  arm64 镜像。CI 只发布 `linux/amd64`。
- **CI 镜像。** 镜像工作流会在推送前构建并校验两个变体。该工作流的一次运行
  不属于本阶段本地验证的一部分。
- **空闲默认值。** 阶段 2 实测后默认值保持 `120000` ms：闲置会话约占
  350–421 MiB，冷启动重建只需 1.0–1.8 s，但超时会丢页面与 snapshot 编号，
  120 s 可覆盖正常模型延迟。内存紧张的部署可显式设为 `60000`；`0` 关闭。
- **snapshot 编号是临时的。** 替换元素的 DOM 重渲染会让编号失效；`click` 和
  `type` 随后会报驱动的元素错误。请重新 `snapshot`。
- **`read` 返回文本。** 它使用 `innerText`，不是 HTML 源码。需要可交互元素
  和链接时用 `snapshot`。
- **`type` 追加。** 它不会先清空输入框；请通过页面交互清空，或直接输入完整
  替换文本。
- **截图会累积。** PNG 留在 workspace 中，不会自动清理。
- **不支持外部 WebDriver。** 该后端忽略 `native_webdriver_url`，始终在本地
  启动 geckodriver。在镜像外运行时，请安装 geckodriver 0.37.1 和 Firefox
  ESR，并确保 `firefox` 在 `PATH` 上，或用 `webdriver_geckodriver_path`
  指向二进制。
- **容器告警。** 在 Docker 默认 seccomp 配置下，Firefox 会记录
  `Sandbox: CanCreateUserNamespace() clone() failure: EPERM` 并回退到隔离较弱
  的沙箱；会话仍可用，容器仍是边界。不要只为消除告警而关闭 seccomp。最小
  页面在默认 64 MB `/dev/shm` 下可用；镜像冒烟测试的真实页面需要 256 MB，
  示例已按此设置。大页面导致 Firefox 崩溃时可调高 `--shm-size`。
- **内存。** 用与镜像相同的 Firefox/geckodriver 组件在镜像外实测：热态空闲
  会话的 cgroup 占用约 350–421 MiB，冷启动首轮峰值 991–1012 MiB（其中页
  缓存可回收），与 OOM 相关的唯一集峰值 427–453 MiB。常被引用的约 1.05 GiB
  是各进程 RSS 合计，会把共享页重复计算，不要用它来定 `mem_limit`。compose
  示例使用 `1536m`；1280 MiB 是实用下限，2048 MiB 只适合内存足够的宿主机。
  这些是本地文本页上的宿主机测量，不是镜像内 cgroup 数字，真实重站点会更高。
  每个运行时一个浏览器是设计前提。

## Lightpanda MCP 变体（阶段 1）

junclaw 以额外的 `main-lightpanda` 镜像变体发布这条路线。
[Lightpanda](https://github.com/lightpanda-io/browser) 以独立进程运行，经其
自带的 MCP server 接入，因此这条路线不使用内置 `browser` 工具：复用
[MCP](./mcp.md) 中已有的客户端，通过 stdio 连接。

### 变体包含什么

- 追加式 `lightpanda` Dockerfile target；release target 保持不变。
- Lightpanda 1.0.2 官方 glibc 二进制，按架构下载，并在构建时用固定的 SHA-256
  校验。
- 供 Lightpanda 使用的 Debian 13 运行时，加上正常构建出的静态 musl junclaw
  二进制。
- 通过 `LIGHTPANDA_DISABLE_TELEMETRY=true` 关闭遥测。
- 非 root 用户，uid/gid 65534。

agent 看到的工具名是 `mcp_lightpanda_<tool>`（例如 `mcp_lightpanda_goto`）。
工具在启动时发现一次；修改配置后需重启 junclaw。

### 配置 Lightpanda MCP server

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
- `--block-private-networks`：保持开启，见
  [Lightpanda 安全模型](#lightpanda-安全模型)。
- `timeout_ms`：`30000` 为冷启动和慢页面留出余量。实测 `example.com` 约 0.3
  秒，343 KB 的页面约 1.1 秒，但 JavaScript 较重的页面可能更久。不够就改
  `60000`；默认 `10000` 对页面抓取偏紧。
- `tools`：原始 `tools/list` 名称的白名单，不带 `mcp_lightpanda_` 前缀。省略
  或留空会注册全部工具；服务器没有暴露的名字会告警并忽略。见
  [Lightpanda 工具白名单与 token 成本](#lightpanda-工具白名单与-token-成本)。
- 默认不要加 `--cookie-jar`。cookie jar 会在退出时把 cookie 落盘，扩大泄露
  面；只有工作流需要登录态跨重启保留时才开启。

### Lightpanda 工具白名单与 token 成本

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

### Lightpanda 关键词过滤

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

### Lightpanda 安全模型

- **内网与 SSRF。** `--block-private-networks` 上游默认 false；推荐配置会开启。
  Lightpanda 在 DNS 解析后拒绝发往私有/内部地址的页面请求。1.0.2 实测包含
  loopback：开启后访问 `http://127.0.0.1:<port>/` 和
  `http://localhost:<port>/` 都会以 `CouldntConnect` 失败；不开启则本地页面
  可以加载。该标记不拦 stdio MCP 传输，`--port` 模式下的 MCP `initialize`
  也仍然正常。
  - 本地调试例外：确实要抓 loopback 页面时，保留 `--block-private-networks`，
    只用负 CIDR 放行确切地址，例如 `--block-cidrs -127.0.0.1/32`（IPv6 再加
    `-::1/128`）。去掉主开关会放行其余所有内网（RFC 1918、link-local、
    CGNAT、Docker 与宿主机管理接口）；负 CIDR 只要比 `/32` 宽，就会重新打开
    对应整段网络。使用一次性配置，并且绝不要用它访问不可信页面。
- **云元数据。** 1.0.2 实测 `169.254.169.254` 在开启
  `--block-private-networks` 时会被拒绝，所以默认配置省略冗余的
  `--block-cidrs 169.254.169.254/32`；上面的 loopback 例外保留主开关，
  元数据地址同样被拦住。IPv6 元数据网段未单独实测；在暴露 IPv6 元数据的
  云上按需补充 CIDR。
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

### Lightpanda 部署

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
