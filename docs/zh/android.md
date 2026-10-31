# Android 设备能力桥

Android 宿主 App 可以把设备工具（文件、屏幕、通知等）提供给 agent。工具本身和审批流程由 Kotlin 宿主负责；junclaw 只负责列出工具、注册成工具，并转发调用。线协议沿用 DSH ENGINE-CONTRACT §3（换行分隔 JSON-RPC 2.0）。

本页讲 junclaw 这一侧。Termux 下的构建和运行见 [Termux 指南](./termux.md)。

## 启用条件

以下两个条件**同时**满足时才会启用：

1. junclaw 是 Android 构建（`builtin.abi == .android`）；
2. 环境变量 `JUNCLAW_DEVICE_SOCKET` 指向 socket 的绝对路径。

宿主必须在拉起 junclaw 子进程之前就开始监听。其它平台、或没有该环境变量时，工具清单与之前完全一致；客户端模块在所有平台都会编译，方便在普通主机上测试。

宿主不可达或 `capability/list` 失败时，junclaw 只记一条 warning，不注册设备工具，不影响其它工具，也不会让启动失败。

## Socket

- 路径：应用私有目录下的 `<filesDir>/run/device.sock`（目录权限 `0700`）。
- 类型：文件系统命名空间里的 `AF_UNIX` / `SOCK_STREAM`（不是 abstract socket，也不是 socketpair）。
- 宿主校验对端 uid 与自身一致。
- 每次请求开一条新连接：客户端连接、发一行请求、读一行响应，然后关闭。

绝对路径通过环境变量传给子进程：

```bash
JUNCLAW_DEVICE_SOCKET=/data/user/0/<package>/files/run/device.sock
```

路径长度必须符合平台 unix socket 限制（Linux/Android 为 108 字节）。

## 分帧

换行分隔的 JSON-RPC 2.0，UTF-8，一行一个对象。单行上限 64 MiB；超长行会被拒绝并关闭连接。

## 方法

### `capability/list`

请求参数：`{}`。结果：`{ "tools": ToolDescriptor[] }`。

```ts
interface ToolDescriptor {
  name: string          // ^[A-Za-z0-9_-]{1,64}$
  group: string         // files | apps | screen | system | notifications | comms | media | clipboard | browser | rules | vscreen
  description: string   // 面向模型的英文描述
  inputSchema: object   // type 为 "object" 的 JSON Schema
  risk: "read" | "write" | "sensitive" | "dangerous"
  needsUnlock: boolean
  timeoutMs: number     // 单次调用预算；宿主默认 300000，needsUnlock 工具默认 900000
}
```

junclaw 会校验每个 descriptor；name、group、description、schema、risk、`timeoutMs` 任一项不符合契约的条目会被静默丢弃。单个坏条目不会影响其它工具注册。

### `capability/invoke`

请求参数：

```json
{
  "sessionId": "<junclaw 会话标识或随机 UUID>",
  "callId": "<随机 UUID>",
  "tool": "<宿主工具名>",
  "args": { },
  "timeoutMs": 300000
}
```

结果：`ToolResult`。

```ts
interface ToolResult {
  ok: boolean
  content: Array<
    | { type: "text", text: string }
    | { type: "image", mimeType: string, data: string } // base64
  >
  error?: { code: string, message: string }
}
```

JSON-RPC 错误沿用标准错误码：未知方法 `-32601`，参数错误 `-32602`。

## 命名

宿主使用 DSH 原名（`file_read`、`screen_tap`、`device_status` 等）。junclaw 注册给模型时统一加 `android_` 前缀（模型看到 `android_file_read`），发送 `capability/invoke` 前再去掉前缀。

## 超时与取消

- `capability/list`：读超时 10 秒。
- `capability/invoke`：读超时为 `timeoutMs + 10 秒`。
- 超时或取消时客户端立即关闭连接；宿主把“响应前断开”视为 `capability/cancel`。

## 结果映射

- `ok: true`：text 段按顺序拼接为工具输出。每个 image 段 base64 解码后写入 `<workspace>/android-device/`，输出里放 `[IMAGE:<绝对路径>]`，与 `screenshot` 工具、各 channel 的约定一致。
- `ok: false`：该工具调用失败，文本为 `<code>: <message>`（宿主两个字段都缺省时为 `failed: `）。
- 宿主响应格式错误或连接被关闭，只让当前这次工具调用失败。

## 更新

Android 构建打包在宿主 App 内，随 APK 一同更新；`junclaw update` 在 Android 上被显式禁用，避免将 bionic 二进制覆盖为通用 glibc Linux 发行包。

## 安全

设备能力的审批由宿主负责，junclaw 不重复审批。但设备工具仍是普通的 junclaw 工具：执行前照常经过 agent 的 `SecurityPolicy`（只读 autonomy、动作限流、按 agent 收窄工具等），桥接不会绕过这些通用限制。

## 测试

`zig build test` 覆盖分帧（含超长行拒绝）、descriptor 校验与过滤、前缀加/去、text/image/error 映射，以及针对假 unix socket 宿主的一次性连接往返（list、invoke、JSON-RPC 错误、宿主不响应时的超时）。AF_UNIX 集成测试在 Windows 上跳过（该测试环境不依赖 unix socket）。

Android 交叉编译走常规路径，例如：

```bash
zig build -Dtarget=x86_64-linux-android.29 --libc /path/to/android-libc-x86_64.txt
```
