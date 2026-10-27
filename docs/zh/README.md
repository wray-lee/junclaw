> **个人分叉。** `junclaw` 是 [nullclaw/nullclaw](https://github.com/nullclaw/nullclaw)
> 的个人硬分叉，由 [@wray-lee](https://github.com/wray-lee) 维护。它以 **merge**
> 方式跟随上游（绝不 rebase）。上游兼容的修复会排队提交上游；已有上游 PR 跟踪于
> [nullclaw/nullclaw#1066](https://github.com/nullclaw/nullclaw/issues/1066)。
> 仅 fork 的功能（dsh harness、浏览器镜像）留在此仓库；junclaw 的问题请报到
> [wray-lee/junclaw/issues](https://github.com/wray-lee/junclaw/issues)。
> 代码为 MIT 许可，保留原始版权；为保持兼容，二进制名、配置目录（`~/.nullclaw`）、
> `NULLCLAW_*` 环境变量与 Zig 包名均有意保持不变。
>
> 图标为原创同人画作，角色为东方 Project 的纯狐（Junko），(c) Team Shanghai
> Alice，为本项目绘制；非商业同人作品（不授予图标商用许可）。

# Junclaw 中文文档

本目录提供面向使用者、运维者与贡献者的中文文档入口。

社区： [上游 Discord 社区](https://discord.gg/Bfmdua22Ud)

如果你刚接触 NullClaw，先从这里找对阅读路径，再进入具体章节。

## junclaw 新增内容

junclaw 在 1.0.0 中于上游 nullclaw 之上加入了代理引擎层，1.1.0 加入了浏览器镜像，二进制名与配置格式保持不变。版本记录见 [CHANGELOG](../../CHANGELOG.md)。

### 代理引擎

`agent.harness` 选择每轮对话使用的引擎（[配置文档](./configuration.md#agentharness)）：

| 取值 | 引擎 |
|---|---|
| `dsh`（默认） | 进程内的 dsh 代理循环 Zig 移植版：JSONL 会话日志、压缩、`/goal`、`/plan`、审批、流式与推理显示，junclaw 工具已桥接，junclaw 安全策略作用于其文件与 shell 工具。`dsh-native` 是别名。 |
| `native` | 上游原有 `Agent.turn` 引擎，未改动。设 `"harness": "native"` 可切回。 |
| `dsh-sidecar` | 以 Node 子进程运行真正的 dsh。需要 `-Dharness_dsh=true` 构建和 full 镜像。 |

从更早的 fork 构建升级：旧配置里的 `"harness": "dsh"` 指的是 sidecar，现在必须写成 `"dsh-sidecar"`。

### 浏览器镜像

默认镜像保持精简，另有三个变体：

- `main-lightpanda` — 通过 MCP 使用 Lightpanda，最轻。
- `main-browser` — Firefox ESR + geckodriver，W3C WebDriver 后端，提供 `browser` 工具。
- `full-dsh-browser` — `full-dsh` 加 Firefox。

选择、配置与安全模型见 [浏览器自动化](./browser.md)。

## 安装 junclaw

发布二进制：[wray-lee/junclaw Releases](https://github.com/wray-lee/junclaw/releases/latest)（最新 `v1.1.1`，2026-10-28）。安装后的二进制名仍是 `nullclaw`。

| 平台 | 发布资产 |
|---|---|
| Linux x86_64 / aarch64 / riscv64 | `junclaw-linux-x86_64.bin`、`junclaw-linux-aarch64.bin`、`junclaw-linux-riscv64.bin` |
| Linux arm32（glibc / musl） | `junclaw-linux-arm32-gnu.bin`、`junclaw-linux-arm32-musl.bin` |
| macOS aarch64 / x86_64 | `junclaw-macos-aarch64.bin`、`junclaw-macos-x86_64.bin` |
| Windows x86_64 / aarch64 | `junclaw-windows-x86_64.zip` / `.exe`、`junclaw-windows-aarch64.zip` / `.exe`（内含 `nullclaw.exe`） |
| Android aarch64 / armv7 / x86_64 | `junclaw-android-aarch64.bin`、`junclaw-android-armv7.bin`、`junclaw-android-x86_64.bin` |
| 源码 | `junclaw-source-v1.1.1.tar.gz` |

Linux（x86_64）：

```bash
curl -fsSL -o /tmp/nullclaw https://github.com/wray-lee/junclaw/releases/latest/download/junclaw-linux-x86_64.bin
chmod +x /tmp/nullclaw && sudo mv /tmp/nullclaw /usr/local/bin/nullclaw
nullclaw --version   # 1.1.1
```

macOS（Apple Silicon；Intel 用 `junclaw-macos-x86_64.bin`）：

```bash
curl -fsSL -o /tmp/nullclaw https://github.com/wray-lee/junclaw/releases/latest/download/junclaw-macos-aarch64.bin
chmod +x /tmp/nullclaw && sudo mv /tmp/nullclaw /usr/local/bin/nullclaw
nullclaw --version   # 1.1.1
```

Docker 镜像（`ghcr.io/wray-lee/junclaw`，仅 `linux/amd64`）：

| 标签 | 内容 |
|---|---|
| `latest`、`v1.1.1`、`main-<sha>` | 精简镜像：发布二进制 + 进程内 dsh 引擎 |
| `full-dsh`、`full-dsh-v1.1.1`、`full-dsh-main-<sha>` | 加 Node 22 与 dsh sidecar（设 `"harness": "dsh-sidecar"`） |
| `main-lightpanda`、`main-lightpanda-<sha>`、`v1.1.1-lightpanda` | 加 Lightpanda（MCP） |
| `main-browser`、`main-browser-<sha>`、`v1.1.1-browser` | 加 Firefox ESR + geckodriver（`browser` 工具） |
| `full-dsh-browser`、`full-dsh-browser-<sha>`、`v1.1.1-full-dsh-browser` | `full-dsh` 加 Firefox |

`full-dsh` 与 `full-dsh-v<version>` 由 `full-dsh-v*` 标签（每次发版一并推送）或手动运行 `image-full-dsh` workflow 重建。

```bash
docker pull ghcr.io/wray-lee/junclaw:v1.1.1
docker run --rm -it -v nullclaw-data:/nullclaw-data ghcr.io/wray-lee/junclaw:v1.1.1 status
```

### 源码构建

```bash
git clone https://github.com/wray-lee/junclaw.git
cd junclaw
zig build -Doptimize=ReleaseSmall                      # 默认：进程内 dsh 引擎
zig build -Doptimize=ReleaseSmall -Dharness_dsh=true   # 可选：dsh sidecar（需要 Node 22）
zig build test --summary all
```

> 上游生态：[nullhub](https://github.com/nullclaw/nullhub) 是管理上游 NullClaw 的 UI（beta），安装的是上游 nullclaw，不是本 fork。

## 页面怎么用

**这页适合谁**

- 刚进入项目、还不知道先看哪篇文档的用户
- 需要在运维、开发、使用三条路线之间做选择的人
- 想从中文总览快速跳到细节页的贡献者

**看完先去哪里**

- 还没跑起来：先看 [安装指南](./installation.md)
- Debian 源码构建还缺 Zig：先看 [Zig 安装指南](./zig-installation.md)
- 已经装好，准备接 provider / memory / channel：看 [配置指南](./configuration.md)
- 只想找命令：直接去 [命令参考](./commands.md)

**如果你是从这里跳过来的**

- `README.md`：把这页当成中文落地页，然后按你的目标继续往下走
- [命令参考](./commands.md)：回到这里可重新选择“上手 / 运维 / 开发”的阅读路径
- [开发指南](./development.md)：回到这里可切换到用户或运维视角的文档

## 从哪开始

### 0. 我没有任何技术背景

如果这是你第一次接触 NullClaw、从未配置过 AI 模型、没编辑过 JSON 文件，先从这里开始。

[新手入门指南](./beginners-guide.md)

注意：该指南来自上游，其中的安装步骤装的是上游 nullclaw。要使用 junclaw，请按[安装指南](./installation.md)中的发布二进制步骤安装。

### 1. 我只想先跑起来

推荐顺序：

1. [安装指南](./installation.md)
2. [配置指南](./configuration.md)
3. [使用与运维](./usage.md)
4. [命令参考](./commands.md)

### 2. 我要部署和长期运行

重点看：

- [使用与运维](./usage.md)
- [安全机制](./security.md)
- [Gateway API](./gateway-api.md)
- [DingTalk 运维就绪](./ops/dingtalk-ops-readiness.md)
- [Lark 运维就绪](./ops/lark-ops-readiness.md)
- [Signal 部署专题](../../SIGNAL.md)

### 3. 我要接入内置渠道之外的系统

重点看：

- [外部渠道插件](./external-channels.md)
- [配置指南](./configuration.md)
- [使用与运维](./usage.md)
- [架构总览](./architecture.md)

### 4. 我要开发、改代码、提 PR

重点看：

- [架构总览](./architecture.md)
- [开发指南](./development.md)
- [命令参考](./commands.md)
- [贡献指南](../../CONTRIBUTING.md)

## 文档导航

- [新手入门指南](./beginners-guide.md)  ← 第一次接触 NullClaw，从这里开始（该指南来自上游，安装 junclaw 请走[安装指南](./installation.md)）
- [安装指南](./installation.md)
- [Zig 安装指南](./zig-installation.md)
- [Termux 指南](./termux.md)
- [配置指南](./configuration.md)
- [使用与运维](./usage.md)
- [架构总览](./architecture.md)
- [安全机制](./security.md)
- [Gateway API](./gateway-api.md)
- [外部渠道插件](./external-channels.md)
- [MCP 集成](./mcp.md)
- [子 Agent](./subagents.md)
- [语音](./voice.md)
- [硬件与外设](./hardware.md)
- [命令参考](./commands.md)
- [浏览器自动化](./browser.md)
- [开发指南](./development.md)

## 运维专题

- [DingTalk 运维就绪](./ops/dingtalk-ops-readiness.md)
- [Lark 运维就绪](./ops/lark-ops-readiness.md)

## 先看这 3 条

1. NullClaw 当前要求 **Zig 0.16.0**（精确版本）；Debian 安装见 [Zig 安装指南](./zig-installation.md)。
2. 默认配置文件路径为 `~/.nullclaw/config.json`（由 `nullclaw onboard` 生成）。
3. 首次上手建议先跑 `onboard --interactive`，再用 `agent` 和 `gateway` 验证。

## 最短上手路径（3 分钟）

```bash
# Linux x86_64；macOS 用 junclaw-macos-aarch64.bin 或 junclaw-macos-x86_64.bin
curl -fsSL -o /tmp/nullclaw https://github.com/wray-lee/junclaw/releases/latest/download/junclaw-linux-x86_64.bin
chmod +x /tmp/nullclaw && sudo mv /tmp/nullclaw /usr/local/bin/nullclaw
nullclaw onboard --interactive
nullclaw agent -m "你好，junclaw"
```

Homebrew 的 `nullclaw` formula 安装的是上游 nullclaw，不是 junclaw。其他平台与容器、源码流程见 [安装指南](./installation.md)。

## 推荐阅读顺序

### 新用户

1. [安装指南](./installation.md)
2. [配置指南](./configuration.md)
3. [使用与运维](./usage.md)
4. [命令参考](./commands.md)

### 运维 / 集成

1. [使用与运维](./usage.md)
2. [安全机制](./security.md)
3. [Gateway API](./gateway-api.md)
4. [Signal 部署专题](../../SIGNAL.md)

### 贡献者

1. [架构总览](./architecture.md)
2. [开发指南](./development.md)
3. [贡献指南](../../CONTRIBUTING.md)

## 专题文档

- [安全披露流程](../../SECURITY.md)
- [Signal 渠道部署](../../SIGNAL.md)
- [贡献指南](../../CONTRIBUTING.md)

## 下一步

- 新用户：按 [安装指南](./installation.md) → [配置指南](./configuration.md) → [使用与运维](./usage.md) 继续。
- 运维 / 集成：先看 [使用与运维](./usage.md)，再补 [安全机制](./security.md)、[Gateway API](./gateway-api.md) 与对应运维专题。
- 贡献者：先读 [开发指南](./development.md)，需要提交流程时再看 [贡献指南](../../CONTRIBUTING.md)。

## 相关页面

- [Termux 指南](./termux.md)
- [命令参考](./commands.md)
- [架构总览](./architecture.md)
- [安全机制](./security.md)
- [Gateway API](./gateway-api.md)
