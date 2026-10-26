# Browser Automation (Lightpanda)

junclaw publishes an additional image variant, `main-lightpanda`, that adds the
[Lightpanda](https://github.com/lightpanda-io/browser) headless browser to the
standard image. Lightpanda runs as a separate process and is reached through its
own MCP server, so junclaw does not gain a new browser backend: the existing MCP
client described in [MCP](./mcp.md) connects to it over stdio.

This page covers the Lightpanda variant (phase 1). A Firefox/WebDriver browser
backend is phase 2 and is not part of this image.

## What the Variant Contains

- An additive `lightpanda` Dockerfile target; the release target is unchanged.
- Lightpanda 1.0.2, official glibc binary, downloaded per architecture and
  verified against a pinned SHA-256 at build time.
- A Debian 13 runtime for Lightpanda plus the static musl junclaw binary from
  the normal build.
- Telemetry disabled through `LIGHTPANDA_DISABLE_TELEMETRY=true`.
- A non-root user, uid/gid 65534.

The agent sees the browser as `mcp_lightpanda_<tool>` (for example
`mcp_lightpanda_goto`). Tools are discovered once at startup; restart junclaw
after changing the configuration.

## Configure the MCP Server

Add this to `~/.nullclaw/config.json`:

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

- `command`/`args`: `lightpanda` is on `PATH` inside the image; the `mcp`
  subcommand starts the server over stdio.
- `--block-private-networks`: keep it on. See [Security model](#security-model).
- `timeout_ms`: `30000` gives room for cold starts and slow pages. Measured
  loads were about 0.3 s for `example.com` and about 1.1 s for a 343 KB page,
  but JavaScript-heavy pages can take longer. Raise it to `60000` if needed;
  the default `10000` is tight for page loads.
- `tools`: an allowlist of raw `tools/list` names, without the
  `mcp_lightpanda_` prefix. Omit it or leave it empty to register every tool;
  names the server does not expose are ignored with a warning. See
  [Tool allowlist and token cost](#tool-allowlist-and-token-cost).
- Do not add `--cookie-jar` by default. A jar persists cookies to disk on exit,
  which widens the leak surface; enable it only when a workflow needs login
  state to survive restarts.

## Tool Allowlist and Token Cost

The full `tools/list` of Lightpanda 1.0.2 is about 39 KB, roughly 10k tokens.
Registering every tool adds that payload to every model request. The allowlist
above keeps only these ten schemas:

| Tool | Purpose |
|------|---------|
| `goto` | Open a URL and keep the page in memory |
| `markdown` | Render the page or a selected subtree as Markdown |
| `links` | List the links on the page |
| `click` | Click an element |
| `fill` | Type text into an input |
| `interactiveElements` | List interactive elements on the page |
| `scroll` | Scroll the page or an element |
| `waitForSelector` | Wait for an element to appear |
| `structuredData` | Extract JSON-LD / OpenGraph data |
| `search` | Run a web search and return results as Markdown; it does not navigate |

Two tools are left out on purpose:

- `evaluate` runs arbitrary JavaScript in the page context. That gives the
  model script execution and a data-exfiltration path: it can read page data
  and send it to a host of its choosing. It is not in the default set. Add it
  only for trusted sites, and treat its output as untrusted.
- `screenshot` returns a PNG of Lightpanda's computed text layout, not a
  pixel-accurate rendering (no images, fonts or CSS colours). Use `markdown`
  or `links` for text pages; add `screenshot` only if a layout image is
  actually needed.

Other available tools, such as `html`, `tree`, `extract`, `detectForms`,
`waitForScript`, `waitForState`, `findElement`, `hover`, `press`,
`selectOption`, `setChecked`, `getUrl`, `consoleLogs`, and the cookie, env and
session tools, are omitted to keep the context small. Add their raw names to
`tools` when a workflow needs them.

## Keyword Filtering

To expose the browser only on turns that need it, add a `dynamic` filter group:

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

- `tools` in `tool_filter_groups` uses prefixed names (`mcp_lightpanda_*`),
  while `tools` in `mcp_servers` uses raw names (`goto`).
- Matching is a byte substring search, not a word or token search. ASCII
  letters are compared case-insensitively.
- Chinese keywords work: UTF-8 bytes above 0x7F are compared unchanged, so a
  keyword such as `网页` matches the same byte sequence anywhere in the
  message. No word segmentation is needed.
- Because matching is by substring, short keywords can over-match: `url`
  matches `curl`, and `web` matches `website`. Prefer distinctive words.
- `dynamic` groups apply only on the native tool-schema path. On the
  text-prompt path they are never included, regardless of keywords; see
  [MCP](./mcp.md#the-two-tool-exposure-paths-differ). If your provider does not
  support native tool schemas, use `mode: "always"` and rely on the `tools`
  allowlist to keep the context small.

## Security Model

- **Private networks and SSRF.** `--block-private-networks` defaults to false
  upstream; the recommended config turns it on. Lightpanda resolves DNS and
  refuses page requests to private/internal addresses. On 1.0.2 this includes
  loopback: with the flag, requests to `http://127.0.0.1:<port>/` and
  `http://localhost:<port>/` fail with `CouldntConnect`; without it, local
  pages load. The flag does not block the stdio MCP transport, and an MCP
  `initialize` over `--port` still works with it on.
  - Local debugging exception: if you must browse a loopback page, use a
    separate, disposable config without `--block-private-networks` for that
    session only, and never point it at untrusted pages. In that config, keep
    `--block-cidrs 169.254.169.254/32` so the cloud metadata address stays
    blocked.
- **Cloud metadata.** On 1.0.2, `169.254.169.254` is refused while
  `--block-private-networks` is on. Adding
  `--block-cidrs 169.254.169.254/32` is redundant in that case, so the default
  config omits it. Keep that CIDR in any debug config that drops the main
  flag. IPv6 metadata ranges were not separately probed; add the CIDRs you
  need on clouds that expose IPv6 metadata.
- **Telemetry.** Lightpanda 1.0.2 collects usage telemetry by default and can
  be opted out with `LIGHTPANDA_DISABLE_TELEMETRY=true`. The image sets that
  variable. Verified on the shipped binary: the default environment sent DNS
  and TLS traffic to the Lightpanda telemetry endpoint, while `fetch`, `serve`
  and `mcp` runs with the image environment produced zero telemetry packets.
  Set the variable yourself if you run the binary outside the image.
- **Non-root.** The container runs as uid/gid 65534.
- **Cookies.** No cookie jar is configured, so cookies are not persisted to
  disk. Loading (`--cookie`) or saving (`--cookie-jar`) cookies widens the
  leak surface; enable either only when required.
- **Untrusted page content.** Web pages can contain prompt-injection text. Keep
  the tool allowlist narrow and leave `evaluate` out when browsing untrusted
  sites.
- **AGPL-3.0.** Lightpanda is licensed AGPL-3.0. The image redistributes the
  official, unmodified 1.0.2 binary. The compliance artifacts are in
  `/usr/share/doc/lightpanda/`: `AGPL-3.0.txt` with the full license, and
  `NOTICE.txt` with the version, the source URL for the 1.0.2 tag, an
  unmodified-binary declaration, and the per-architecture SHA-256 values.
  junclaw itself remains MIT. The image is an aggregate of two separate
  programs: Lightpanda is not linked into junclaw and does not relicense it.
  If you modify Lightpanda, AGPL source-offer obligations apply to your
  modified binary; this image does not modify it.

## Deployment

```yaml
services:
  junclaw:
    image: ghcr.io/wray-lee/junclaw:main-lightpanda
    mem_limit: 256m
    volumes:
      - ./data:/nullclaw-data
```

- `mem_limit: 256m` follows the memory measurements: 20 sequential page
  fetches peaked at about 18.6 MiB process RSS and 23.6 MiB at the container
  cgroup. 256 MiB leaves headroom for page cache and concurrent tool calls;
  raise it if you browse several large pages at once.
- Configuration lives in `/nullclaw-data/config.json`; the image sets
  `NULLCLAW_HOME=/nullclaw-data`.
- Image tags:
  - `main-lightpanda`: rolling build from `main`.
  - `main-lightpanda-<sha>`: fixed build for a 10-character commit SHA.
  - `<tag>-lightpanda`: build for a git tag.
  - `latest` still points at the slim release image; the browser variant is
    opt-in.
- CI builds and verifies `linux/amd64`. The Dockerfile carries an aarch64
  binary hash, but the arm64 image has not been built or tested.
- If you run junclaw outside the image, install the Lightpanda 1.0.2 binary and
  put `lightpanda` on `PATH`.

## Related

- [MCP](./mcp.md) — Transports, tool allowlist and filter groups
- [Configuration](./configuration.md) — Full config reference
- [Security](./security.md) — Security model
- [Installation](./installation.md) — Image and binary installation
