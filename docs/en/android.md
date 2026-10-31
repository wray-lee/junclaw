# Android Device Capability Bridge

An Android host app can expose its device tools (files, screen, notifications, and so on) to the agent. The Kotlin host owns the tools and their approval flow; junclaw only lists them, registers them as tools, and forwards calls. The wire contract is DSH ENGINE-CONTRACT §3 (newline-delimited JSON-RPC 2.0).

This page covers the junclaw side. For building and running under Termux, see [Termux](./termux.md).

## Activation

The bridge is active only when **both** conditions hold:

1. junclaw is built for Android (`builtin.abi == .android`); and
2. the environment variable `JUNCLAW_DEVICE_SOCKET` is set to the absolute socket path.

The host must already be listening before it spawns the junclaw process. On every other platform, or without the variable, the tool list is exactly the same as before; the client module still compiles so it can be tested on a normal host.

If the host cannot be reached or `capability/list` fails, junclaw logs a warning and registers no device tools. Other tools are unaffected, and startup does not fail.

## Socket

- Path: `<filesDir>/run/device.sock` in the app private directory (directory mode `0700`).
- Type: `AF_UNIX` / `SOCK_STREAM` in the filesystem namespace (not an abstract socket, not a socketpair).
- The host verifies that the peer uid matches its own.
- One connection per request: the client connects, sends one request line, reads one response line, then closes.

The absolute path is passed to the child as:

```bash
JUNCLAW_DEVICE_SOCKET=/data/user/0/<package>/files/run/device.sock
```

The path must fit the platform unix-socket limit (108 bytes on Linux/Android).

## Framing

Newline-delimited JSON-RPC 2.0, UTF-8, one object per line. The maximum line length is 64 MiB; a longer line is rejected and the connection is closed.

## Methods

### `capability/list`

Request params: `{}`. Result: `{ "tools": ToolDescriptor[] }`.

```ts
interface ToolDescriptor {
  name: string          // ^[A-Za-z0-9_-]{1,64}$
  group: string         // files | apps | screen | system | notifications | comms | media | clipboard | browser | rules | vscreen
  description: string   // model-facing, English
  inputSchema: object   // JSON Schema with type "object"
  risk: "read" | "write" | "sensitive" | "dangerous"
  needsUnlock: boolean
  timeoutMs: number     // per-call budget; host defaults 300000, 900000 for needsUnlock
}
```

junclaw validates each descriptor and silently drops entries whose name, group, description, schema, risk, or `timeoutMs` do not match the contract. A malformed entry never prevents the remaining tools from registering.

### `capability/invoke`

Request params:

```json
{
  "sessionId": "<junclaw session id or random UUID>",
  "callId": "<random UUID>",
  "tool": "<host tool name>",
  "args": { },
  "timeoutMs": 300000
}
```

Result: `ToolResult`.

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

JSON-RPC errors use the standard codes: `-32601` for an unknown method and `-32602` for invalid params.

## Naming

The host uses the original DSH tool names (`file_read`, `screen_tap`, `device_status`, ...). junclaw registers each one with the `android_` prefix, so the model sees `android_file_read`, and strips the prefix again before sending `capability/invoke`.

## Timeouts and cancellation

- `capability/list`: 10 s read timeout.
- `capability/invoke`: `timeoutMs + 10 s` read timeout.
- On timeout or cancellation the client closes the connection immediately; the host treats a disconnect before its response as `capability/cancel`.

## Result mapping

- `ok: true`: text segments are concatenated in order into the tool output. Each image segment is base64-decoded and written to `<workspace>/android-device/`, and the output carries `[IMAGE:<absolute path>]` instead of the payload, matching the `screenshot` convention used by channels.
- `ok: false`: the tool call fails with `<code>: <message>` (`failed: ` when the host omits both fields).
- Malformed host responses or a closed connection fail only that tool call.

## Updates

Android builds are packaged into the host application and are updated along with the APK; `junclaw update` is disabled on Android to prevent overwriting the bionic binary with a glibc Linux release asset.

## Security

Device-specific approval is the host's responsibility; junclaw does not duplicate it. However, device tools are ordinary junclaw tools: the agent's `SecurityPolicy` (read-only autonomy, action rate limits, and any per-agent tool withholding) still applies before execution, and nothing in the bridge bypasses it.

## Testing

`zig build test` covers frame extraction (including over-limit lines), descriptor validation and filtering, prefix add/strip, text/image/error mapping, and one-connection round-trips against a fake unix-socket host (list, invoke, JSON-RPC error, and the no-response timeout). AF_UNIX integration tests are skipped on Windows, where the test environment does not rely on unix sockets.

Cross-compiling the Android client follows the normal Android build path, for example:

```bash
zig build -Dtarget=x86_64-linux-android.29 --libc /path/to/android-libc-x86_64.txt
```
