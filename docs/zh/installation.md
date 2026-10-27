# 安装指南

本指南覆盖 macOS、Linux、Windows 的主流安装方式。

## 页面导航

- 这页适合谁：刚准备安装 NullClaw，或者要确认本机环境、容器部署、升级与卸载路径的人。
- 看完去哪里：安装完成后先看 [配置指南](./configuration.md)；想直接跑一遍常用命令看 [使用与运维](./usage.md)；想先浏览 CLI 入口看 [命令参考](./commands.md)。
- 如果你是从某页来的：从 [README](./README.md) 来，这页就是落地安装的第一站；从 [命令参考](./commands.md) 来，适合回头补齐本机安装与 PATH；从 [开发指南](./development.md) 来，可把本页当作本地环境准备清单。

## 前置要求

- 如果走源码构建：必须使用 **Zig 0.16.0**。Debian 安装步骤见 [Zig 安装指南](./zig-installation.md)。
- Git（源码安装需要）。

检查 Zig 版本：

```bash
zig version
```

输出必须是 `0.16.0`。

## 方式一：使用二进制文件
### junclaw 发布二进制（推荐）

从 [junclaw Releases](https://github.com/wray-lee/junclaw/releases/latest) 下载对应平台的资产——`junclaw-linux-x86_64.bin`、`junclaw-macos-aarch64.bin`、`junclaw-windows-x86_64.zip` 等（完整列表见[根 README](../../README.md#install-junclaw)）。安装后的二进制名仍是 `nullclaw`。

```bash
# Linux x86_64；macOS 用 junclaw-macos-aarch64.bin 或 junclaw-macos-x86_64.bin
curl -fsSL -o /tmp/nullclaw https://github.com/wray-lee/junclaw/releases/latest/download/junclaw-linux-x86_64.bin
chmod +x /tmp/nullclaw && sudo mv /tmp/nullclaw /usr/local/bin/nullclaw
nullclaw --help
```

Homebrew 的 `nullclaw` formula 安装的是上游 nullclaw，不是本 fork；junclaw 没有 tap。只有想用上游时才执行：

```bash
brew install nullclaw
nullclaw --help
```
如果命令可用，说明安装成功。

### 命令行（CMD）(Windows)

从发布页下载 Windows `junclaw-windows-x86_64.zip`（或 `junclaw-windows-aarch64.zip`）并解压后，即可直接在命令行中运行其中的 `nullclaw.exe`。

比如检查nullclaw版本号的命令如下：

```cmd
x:\path\nullclaw.exe --version
```

## 方式二：容器镜像（Docker / Podman）

junclaw 提供自己的 OCI 镜像：`ghcr.io/wray-lee/junclaw`（仅 `linux/amd64`）。上游也发布 `ghcr.io/nullclaw/nullclaw`，但其中没有 dsh harness 和浏览器变体。

容器内的持久化目录统一放在 `/nullclaw-data`：

- 配置文件：`/nullclaw-data/config.json`
- 工作区：`/nullclaw-data/workspace`

镜像内自带的初始配置已经使用当前配置结构（`agents.defaults.model.primary` 和 `models.providers`），因此在你填入 provider 凭证之前，`latest` 也应能正常启动。

### 已有数据卷

命名数据卷会保留首次填充时的属主。如果该卷是由 `/nullclaw-data` 属主为 root 的旧镜像创建的，即使镜像已经修复，容器仍会报 `AccessDenied`。以 root 身份执行一次修复：

```bash
docker run --rm -u 0 -v nullclaw-data:/nullclaw-data \
  --entrypoint sh ghcr.io/wray-lee/junclaw:v1.1.1 \
  -c 'chown -R 65534:65534 /nullclaw-data'
```

绑定挂载（bind mount）不受该命令影响：它们继承宿主目录的属主，因此被挂载的目录必须对 uid `65534` 可写。

### 单次命令

```bash
docker run --rm -it \
  -v nullclaw-data:/nullclaw-data \
  ghcr.io/wray-lee/junclaw:v1.1.1 status
```

交互式初始化配置：

```bash
docker run --rm -it \
  -v nullclaw-data:/nullclaw-data \
  ghcr.io/wray-lee/junclaw:v1.1.1 onboard --interactive
```

运行交互式 agent：

```bash
docker run --rm -it \
  -v nullclaw-data:/nullclaw-data \
  ghcr.io/wray-lee/junclaw:v1.1.1 agent
```

运行 HTTP gateway：

```bash
docker run --rm -it \
  -p 127.0.0.1:3000:3000 \
  -v nullclaw-data:/nullclaw-data \
  ghcr.io/wray-lee/junclaw:v1.1.1
```

### Docker Compose

仓库根目录的 `docker-compose.yml` 默认从本仓库 Dockerfile 构建 `nullclaw:local`，且 `make up` 会强制重建。要用已发布的 junclaw 镜像，先拉取再直接启动 compose：

```bash
export NULLCLAW_IMAGE=ghcr.io/wray-lee/junclaw:v1.1.1
docker compose --profile gateway pull gateway
docker compose --profile gateway up -d gateway   # 不要用 `make up`，它带 --build
```

交互式初始化：

```bash
docker compose --profile agent run --rm agent onboard --interactive
```

在容器流程里，workspace 提示直接回车即可保留挂载卷里的默认路径：

- 工作区：`/nullclaw-data/workspace`

交互式 agent 会话：

```bash
docker compose --profile agent run --rm agent
```

长期运行 gateway：

```bash
docker compose --profile gateway up -d gateway
```

Profile 含义：

- `agent`：一次性的交互式 CLI 容器
- `gateway`：长期运行的 HTTP gateway，默认发布到宿主机回环地址 `3210`（可用 `NULLCLAW_PORT` 覆盖）

如果你需要局域网或公网访问，请显式修改发布地址，并先阅读 [安全指南](./security.md)。

如果你要固定版本标签，或者以后切换到其他镜像仓库，可以覆盖 `NULLCLAW_IMAGE`：

```bash
NULLCLAW_IMAGE=ghcr.io/wray-lee/junclaw:v1.1.1 docker compose --profile gateway pull gateway
NULLCLAW_IMAGE=ghcr.io/wray-lee/junclaw:v1.1.1 docker compose --profile gateway up -d gateway
```

### full-dsh 镜像（可选）

本分叉还提供一个内置 [dsh](https://github.com/deepseek-ai/deepseek-harness) sidecar harness 的完整镜像，`nullclaw` 二进制与精简镜像相同：

```bash
docker pull ghcr.io/wray-lee/junclaw:full-dsh
```

标签：

- `:full-dsh` —— `full-dsh` target 的最新构建
- `:full-dsh-v<version>` —— 由 `full-dsh-v*` 标签产生，每次发版一并推送（如 `:full-dsh-v1.1.1`）
- `:full-dsh-main-<sha>` —— 手动 CI 运行

发布不产生 `v<version>-full-dsh`；full 浏览器变体是 `:v<version>-full-dsh-browser`。

本地构建：

```bash
docker build --target full-dsh -t junclaw:full-dsh .
```

**平台：** 仅 `linux/amd64`。ARM64 运行时尚未实测，因此该镜像不声明支持 ARM64。

**体积与内存（linux/amd64 实测）：**

- 镜像：未压缩 1.4 GB（1,441,200,646 字节），压缩后 250 MB（约 261 MB）（`docker save | gzip`）
- RSS：空闲约 2-3 MB（gateway 运行、dsh 未启动）；一轮对话时容器峰值约 288 MB，dsh sidecar 的 VmRSS 峰值约 320 MB（早期探针在较短轮次下测得 202-244 MB）

建议每容器至少 512 MB 内存，1 GB 更稳。

**启用 dsh sidecar：** `agent.harness` 默认是 `dsh`（进程内引擎），本镜像同样会运行它。镜像另外打包了 DeepSeek-Harness sidecar 并设置了 `NULLCLAW_DSH_BIN` 与 `DSH_HOME=/nullclaw-data/.dsh`；若要改用打包的 sidecar，需显式开启：

```json
{
  "agent": {
    "harness": "dsh-sidecar"
  }
}
```

`config.json` 里照常配置 `models.providers`；harness 会把 `junclaw` 路由写入 dsh 的 web profile。`HOME`、`NULLCLAW_HOME` 与工作区仍在 `/nullclaw-data` 下（uid 65534）。

**行为差异：**

- dsh 在容器内运行自己的 agent 循环和工具。junclaw 的 `memory`、`cron`、`tools` 不会自动暴露给 dsh；要打通需要 MCP server 或 dsh 插件。
- 审批（在接入后）只支持 `allow-once` 和 `reject`，dsh 没有 allow-always。当前 P1 harness 尚未把审批提示暴露到频道。
- dsh web profile 固定为 `0.2.1-rc.2`；镜像用提交进仓库的 lock 文件安装，带 integrity 校验。

## 方式三：源码构建（通用）

```bash
git clone https://github.com/wray-lee/junclaw.git
cd junclaw
zig build -Doptimize=ReleaseSmall
zig build test --summary all
```

默认构建包含进程内 `dsh` 引擎。要同时构建可选的 dsh sidecar harness（运行需要 Node 22），加 `-Dharness_dsh=true`：

```bash
zig build -Doptimize=ReleaseSmall -Dharness_dsh=true
```

构建产物：

- `zig-out/bin/nullclaw`

## 方式四：Android / Termux

有三种常见路径：

- 直接下载官方发布的 Android / Termux 预构建二进制
- 在手机上的 Termux 里原生构建
- 在另一台机器上交叉编译 Android 二进制

### Termux 原生构建

```bash
pkg update
pkg install git zig
git clone https://github.com/wray-lee/junclaw.git
cd junclaw
zig version
zig build -Doptimize=ReleaseSmall
./zig-out/bin/nullclaw --help
```

说明：

- 必须使用 **Zig 0.16.0**
- 如果 `zig build` 一开始就失败，先确认 Zig 版本
- Termux 原生构建使用当前环境的 native target，通常不需要手动传 `-Dtarget`
- 在 Android / Termux 上，建议先跑前台命令（如 `agent`、`gateway`），确认没问题后再考虑后台托管
- 官方 release 提供 `aarch64`、`armv7`、`x86_64` 的 Android / Termux 预构建二进制
- 更完整的说明和排错见 [Termux 指南](./termux.md)。

### 为 Android 交叉编译

如果你是在另一台机器上给 Android / Termux 设备构建，需要显式传入 Zig target，并提供 Android 的 libc/sysroot 文件；只传 `-Dtarget` 还不够：

```bash
zig build -Dtarget=aarch64-linux-android.24 -Doptimize=ReleaseSmall --libc /path/to/android-libc-aarch64.txt
```

常见 Android targets：

- `aarch64-linux-android.24`
- `arm-linux-androideabi.24`，配合 `-Dcpu=baseline+v7a`
- `x86_64-linux-android.24`

选择与目标手机或模拟器架构匹配的 target。完整的 `--libc` 文件生成示例可参考 [`.github/workflows/release.yml`](../../.github/workflows/release.yml)。官方 release 也附带基于 Android API 24 构建的对应二进制。

## 将二进制加入 PATH

### 使用编译后的二进制文件

#### macOS/Linux（zsh/bash）

```bash
zig build -Doptimize=ReleaseSmall -p "$HOME/.local"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
# bash 用户改为 ~/.bashrc
source ~/.zshrc
```

#### Windows（PowerShell）

```powershell
zig build -Doptimize=ReleaseSmall -p "$HOME\.local"

$bin = "$HOME\.local\bin"
$user_path = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not ($user_path -split ";" | Where-Object { $_ -eq $bin })) {
  [Environment]::SetEnvironmentVariable("Path", "$user_path;$bin", "User")
}
$env:Path = "$env:Path;$bin"
```

### 直接使用下载的二进制文件（Windows, Powershell)
从发布页下载 Windows `.zip` 压缩包并解压后，可在管理员权限的 Powershell 中执行如下命令，将 `nullclaw.exe` 所在目录加入 Windows 的 `PATH` 环境变量：

```Powershell 
$old = [Environment]::GetEnvironmentVariable("Path", "Machine")
$new = "$old;x:\path\to\nullclaw"
[Environment]::SetEnvironmentVariable("Path", $new, "Machine")
```

## 安装验证

```bash
nullclaw --help
nullclaw --version
nullclaw status
```

若 `status` 能正常输出组件状态，说明安装与运行环境基本可用。

## 升级与卸载

> **从 1.1.0 及更早版本升级：** 这些版本的 `nullclaw update` 仍会拉取上游 nullclaw，把 junclaw 替换成上游。请先从 [Releases](https://github.com/wray-lee/junclaw/releases/latest) 下载新的 `junclaw-*` 资产手动替换一次（命令同方式一）；之后的版本 `nullclaw update` 会从 junclaw releases 更新。

### 发布二进制

- 升级：下载新的 `junclaw-<platform>.bin`，`chmod +x` 后覆盖已安装的 `nullclaw`
- 卸载：删除 `nullclaw` 二进制，并从 `PATH` 移除其所在目录

### Homebrew（仅上游 nullclaw）

- 升级：`brew update && brew upgrade nullclaw`（安装的是上游，不是 junclaw）
- 卸载：`brew uninstall nullclaw`

### 源码安装

- 升级：`git pull` 后重新执行 `zig build -Doptimize=ReleaseSmall`
- 卸载：删除安装位置中的 `nullclaw` 二进制，并移除 PATH 配置行

## 下一步

- 要开始初始化配置：继续看 [配置指南](./configuration.md)，先生成可运行的 `config.json`。
- 要快速跑通一遍：继续看 [使用与运维](./usage.md)，按首次启动流程验证安装结果。
- 要核对 CLI 命令：继续看 [命令参考](./commands.md)，确认 `onboard`、`agent`、`gateway` 等入口。

## 相关页面

- [中文文档入口](./README.md)
- [Termux 指南](./termux.md)
- [配置指南](./configuration.md)
- [使用与运维](./usage.md)
- [命令参考](./commands.md)
