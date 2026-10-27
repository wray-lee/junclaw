# Browser Automation

junclaw's browser images provide two independent routes:

| Route | Image | Tool visible to the model |
|-------|-------|---------------------------|
| Firefox/WebDriver backend | `main-browser`, `full-dsh-browser` | the built-in `browser` tool |
| Lightpanda over MCP | `main-lightpanda` | `mcp_lightpanda_<tool>` |

The Firefox backend is built into junclaw: it starts Firefox ESR through
geckodriver and serves eight actions from the `browser` tool. The Lightpanda
route runs as a separate process reached through its MCP server and keeps the
MCP tool set. The routes are independent; pick the image and configuration for
the one you want. If you do not need browser automation, the slim release image
(`latest`) includes neither route.

## Firefox/WebDriver Backend

Set `browser.backend` to `"webdriver"` to serve every `browser` action from a
local Firefox session. junclaw starts and stops geckodriver itself; the
automation path does not use a system browser, Node or Playwright.

### Image Variants

- `main-browser`: the release binary on a Debian 13 runtime, plus Firefox ESR
  and geckodriver.
- `full-dsh-browser`: the same browser layer on top of `full-dsh` (Node 22 and
  the dsh sidecar).
- geckodriver 0.37.1 is downloaded per architecture and checked against a
  pinned SHA-256 at build time. Firefox ESR comes from Debian `firefox-esr`
  (153.5.1esr at build time) and follows Debian security updates, so it is not
  pinned by digest.
- `fonts-dejavu-core` keeps headless screenshots legible.
  `/usr/local/bin/firefox` is a symlink to `firefox-esr` because geckodriver
  looks up `firefox` on `PATH`.
- Both images run as uid/gid 65534 and use the normal `nullclaw` entrypoint.

Image tags:

| Tag | Meaning |
|-----|---------|
| `main-browser` | rolling build from `main` |
| `main-browser-<sha>` | fixed build for a 10-character commit SHA |
| `<tag>-browser` | build for a git tag |
| `full-dsh-browser` | rolling build of the full dsh variant |
| `full-dsh-browser-<sha>` | fixed build for a 10-character commit SHA |
| `<tag>-full-dsh-browser` | tag build of the full dsh variant |

- `latest` still points at the slim release image; the browser variants are
  opt-in.
- Measured uncompressed image sizes: 843 MB for `main-browser` and 2.1 GB for
  `full-dsh-browser` (linux/amd64). These are image sizes, not runtime memory.
- CI builds and verifies `linux/amd64`. The Dockerfile carries an aarch64
  geckodriver hash, but no arm64 image has been built or tested.

Pull `ghcr.io/wray-lee/junclaw:main-browser` or
`ghcr.io/wray-lee/junclaw:full-dsh-browser` and mount `/nullclaw-data`; both use
the normal gateway entrypoint:

```yaml
services:
  junclaw:
    image: ghcr.io/wray-lee/junclaw:main-browser
    shm_size: 256m
    mem_limit: 1536m
    volumes:
      - ./data:/nullclaw-data
```

These limits are sized for one Firefox session per container. `shm_size: 256m`
is what a real page load needed in the image smoke test; `mem_limit: 1536m`
follows the phase-2 measurements: about 350–421 MiB cgroup usage for a warm idle
session, 991–1012 MiB at cold first start including reclaimable page cache, and
a 427–453 MiB OOM-relevant peak, with a practical range of 1280–2048 MiB. Size
from cgroup usage, not from the ~1.05 GiB summed RSS, which counts shared pages
once per process.

geckodriver and Firefox must not outlive the agent. In a container the primary
guarantee is container PID 1 exiting together with the agent, which stops
everything in it. As a per-process backstop, on Linux and macOS a small `sh`
wrapper kills geckodriver's process group when the pipe held by the agent
reaches EOF, so an OOM-killed or crashed agent still takes the browser down; on
Windows geckodriver runs in a Job Object with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.

The browser needs no extra sidecar or environment variable. Use
`full-dsh-browser` when you also want Node 22 and the dsh sidecar; the `browser`
tool is registered through the same tool set under the dsh harness, so its
actions are identical in both variants.

### Configuration

Enable the built-in tool and select the backend in the config file
(`/nullclaw-data/config.json` in the images, `~/.nullclaw/config.json` on a
host install):

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

- `enabled` registers the `browser` tool. It is off by default.
- `backend` defaults to `"agent_browser"`, which opens pages in a host browser
  and reads them over curl. Set `"webdriver"` for the Firefox backend; inside
  these images there is no host browser to launch.
- `native_headless` defaults to `true`. `false` launches a visible Firefox and
  needs a display; do not use it in a container.
- `allowed_domains` controls the URL policy. An empty list allows any globally
  routable HTTPS host; a non-empty list allows only exact hosts and `*.`
  subdomain patterns. See [Security model](#security-model) for the trade-offs.
- `webdriver_idle_timeout_ms` is the idle time before Firefox and geckodriver
  are stopped. The default is `120000` (2 minutes); `0` disables idle shutdown.
- `webdriver_geckodriver_path` overrides the geckodriver binary. Leave it unset
  to use `geckodriver` from `PATH`; the images install it in
  `/usr/local/bin`.
- `native_webdriver_url` and `native_chrome_path` are not used by the WebDriver
  backend. It always starts its own geckodriver on a random loopback port and
  does not connect to an external WebDriver endpoint.

Restart junclaw after changing the configuration.

### Actions

| Action | Parameters | Result |
|--------|------------|--------|
| `open` | `url` | Navigates and returns a short confirmation. |
| `read` | `url` | Navigates, then returns the title, final URL and page text (`innerText`). Output is capped at 8 KB with `[Content truncated to 8 KB]`. |
| `snapshot` | none | Returns the title, final URL, page text and a numbered list of visible interactive elements. Output is capped at 8 KB; text gets at most 4 KB and the list at most 100 elements. |
| `click` | `index` or `selector` | Clicks the numbered element from the last snapshot, or a CSS selector. |
| `type` | `index` or `selector`, `text` | Sends text to the element. W3C send-keys appends to the current value; it does not clear the field. |
| `scroll` | `direction`, `amount` | Scrolls the window. `direction` is `up`, `down`, `left` or `right` (default `down`); `amount` is 1–100000 pixels (default 500). |
| `screenshot` | none | Writes a PNG to the workspace and returns an `[IMAGE:...]` marker with the absolute path, for example `[IMAGE:/nullclaw-data/workspace/browser-screenshot-1a2b3c4d.png]`. Keep the marker verbatim in the reply; the base64 payload never reaches the model. |
| `close` | none | Stops Firefox and geckodriver and deletes the temporary profile. The next action starts a new browser. |

`snapshot` writes `data-junclaw-ref="N"` to each visible interactive element
and prints `[N] <tag> label detail`. Numbers are stable until the next
`snapshot`; a page that replaces its DOM or navigates invalidates them, so call
`snapshot` again after a re-render. Prefer `index`; `selector` is a CSS
fallback. `index` may be an integer or a numeric string. When `snapshot` output is cut, it
appends the same `[Content truncated to 8 KB]` marker as `read`.

Prefer `snapshot` (or `read`) over `screenshot` for page content; the
screenshot is for visual checks.

`screenshot` requires a workspace. The file is named
`browser-screenshot-<hex>.png` and stays in the workspace; junclaw does not
delete old screenshots. Channels that support attachments turn the marker into
an image; on surfaces without media support the marker remains text.

The `agent_browser` backend keeps its old behavior: `open` and `read` work,
`close` reports that there is nothing to close, `snapshot` reports that the
WebDriver backend is required, `click`, `type` and `scroll` report that CDP is
unavailable, and `screenshot` points at the `screenshot` tool.

### Security Model

The WebDriver backend uses the same URL policy and trust model as `web_fetch`,
and it enforces that policy on every browser HTTP(S) request at a filtering
proxy. It is not a kernel-level network sandbox.

- **All browser HTTP(S) traffic goes through a filtering proxy.** Each browser
  session starts an in-process CONNECT proxy bound to a kernel-assigned
  `127.0.0.1` port, and the one-shot profile points `network.proxy.*` at it
  with `failover_direct=false` and `allow_hijacking_localhost=true`. Redirects,
  page subresources, new windows and form submissions therefore leave through
  the proxy. The proxy starts before Firefox; if it cannot start, the session
  fails, and there is no direct-connection fallback or configuration escape
  hatch.
- **HTTPS only.** `http://`, `ws://`, `file://`, `data:` and `javascript:` are
  rejected before Firefox navigates, and the proxy answers any request that is
  not `CONNECT` with `403`. An allowlist entry does not change the scheme rule.
- **Private networks and metadata.** The proxy resolves each CONNECT host once,
  applies the same address rules as `web_fetch` to every result (loopback,
  RFC 1918, link-local, container-runtime aliases, cloud metadata such as
  `169.254.169.254`, IPv6 forms and ambiguous IPv4 literals judged by the
  address they denote) and connects to that pinned address. A mixed
  public/private answer fails closed. Pinning the checked address closes the
  DNS rebinding / TOCTOU window between the check and the connection.
- **Allowlist trade-off.** A non-empty `allowed_domains` turns the list into
  the whole policy: only matching hosts are allowed, the list is checked before
  DNS, and matching hosts skip the private-address check so they may point at
  an internal service. This is the same operator-trusted exception as
  `web_fetch.allowed_domains`. A bare `*` entry allows every host, including
  private addresses. Keep the list empty when private networks must stay
  unreachable; never add private or loopback hosts to make an untrusted page
  load.
- **Redirects and final URL.** Firefox follows redirects itself, through the
  proxy. After every navigation, and again before `snapshot`, `click`, `type`,
  `scroll` and `screenshot`, junclaw reads the URL Firefox actually landed on
  and validates it as defence in depth. If the final URL fails, the page is
  closed and the session is marked stale; the next action rebuilds it. A final
  URL that cannot be read fails closed.
- **Extra windows are closed.** After each successful action junclaw lists the
  session's window handles, closes every window except the current one and
  reports the closed handles. This is best effort: driver errors are logged
  and do not fail the action, so a popup normally does not keep running out of
  view.
- **Network paths around the proxy are disabled.** The generated `user.js`
  turns off DoH/TRR, DNS prefetch, speculative, preconnect and predictor
  connections, HTTP/3, Alt-Svc and WebRTC, and disables Safe Browsing, OCSP,
  Remote Settings, telemetry and update endpoints.
- **Not a kernel-level sandbox.** The proxy is ordinary user-space code, not a
  netns or firewall rule. Firefox components that use raw sockets or bypass
  the necko HTTP stack, or a future component with its own HTTP stack, can
  leave without it, and the local Marionette/Remote Agent connection between
  geckodriver and Firefox is not proxied. In HTTP proxy mode Firefox hands
  page hostnames to the proxy instead of resolving them, and the prefs above
  disable prefetch and TRR; if a future Firefox ignores those pref names it
  could still make its own DNS lookups, which leaks queries but does not
  bypass the address policy. QUIC, WebRTC and other UDP paths are closed by
  prefs only. The proxy sees `CONNECT host:port`, not TLS content, so an
  allowed host can still carry `wss` (WebSocket) traffic. The loopback
  listener has no authentication, so other local processes can use it, though
  only to validated addresses. Keep deployment-side network isolation as the
  outer boundary when the LAN must stay unreachable. Browser cleanup is
  layered the same way: container PID 1 exit is the primary guarantee, and the
  POSIX watchdog or the Windows Job Object is the per-process backstop.
- **Page scripts run.** Firefox executes the page's JavaScript. The model never
  gets a JavaScript action; `read`, `snapshot` and `scroll` use fixed internal
  snippets. Treat page output as untrusted input.
- **One-shot profile.** Each browser start creates a fresh temporary profile
  with no cookies or storage from the host. On POSIX the profile and its
  `downloads` directory are created with mode `0700`. The profile is deleted
  on `close`, on idle shutdown and when the runtime stops; if the agent is
  killed with SIGKILL, the process backstop still stops the browser but the
  profile directory can remain until temporary-file cleanup.
- **Telemetry and update traffic.** A generated `user.js` disables Firefox
  telemetry, health reporting, crash/breakpad submission, Normandy studies,
  search updates, add-on discovery, Pocket/FxA, captive-portal probes and
  remote download-safety lookups. These are outbound calls a browsing tool
  must not make on its own.
- **Downloads.** Downloads go to a `downloads` directory inside the temporary
  profile, never to the workspace, and are deleted with the profile.

Do not weaken these checks to get a page working. There is no supported switch
that turns the proxy off; in particular, do not add private or loopback hosts
to `allowed_domains` for untrusted pages, and do not disable the container's
seccomp profile just to silence a Firefox sandbox warning (see
[Limitations and validation status](#limitations-and-validation-status)).

### Process Lifecycle and Concurrency

- **Lazy start.** The first action other than `close` validates its arguments,
  then starts geckodriver and Firefox. Malformed calls never spawn a process.
- geckodriver listens on `127.0.0.1` on a kernel-assigned random port. junclaw
  accepts that endpoint only when the `Listening on 127.0.0.1:<port>` banner
  arrived through our own child's stderr, the child is still alive and the new
  session reports the profile we created. A foreign listener or another
  profile is retried on a fresh port, at most three attempts, then the start
  fails closed. A missing binary, a failed spawn or a 10-second timeout per
  attempt returns a tool error with the reason. geckodriver output is not
  forwarded.
- **One browser per process.** Every browser action in the junclaw process,
  across all gateway sessions and channel runs, goes through one shared manager
  and one WebDriver session. At any moment the process has at most one Firefox
  instance. A mutex serializes commands, so concurrent model or channel
  requests queue instead of starting a second Firefox. This is deliberate for
  the 2.4 GB target machine.
- **Shared teardown.** `close`, session end or idle shutdown stops the shared
  browser for every session. The next action in any session rebuilds it. There
  is no per-session browser to leak or double.
- **Idle shutdown.** After `webdriver_idle_timeout_ms` without an action, the
  reaper stops Firefox and geckodriver. The check runs every 250 ms. `0`
  disables idle shutdown; `close` stops immediately.
- **Cleanup.** The stop path deletes the WebDriver session, stops the session
  proxy (shutting down tunnels and joining its threads), sends TERM to the
  geckodriver process group, falls back to KILL, then removes the temporary
  profile. On Windows closing the Job Object kills the driver tree. It is safe
  to call repeatedly. `close` returns `Browser closed` or `Browser is not
  running`.
- **Self-healing.** If Firefox dies (for example after an OOM kill) or the
  driver loses the session, the next action tears down the remains and starts
  a new geckodriver/Firefox pair. Driver and transport failures are returned
  as tool errors, not panics.

### Limitations and Validation Status

- **Validation gap.** Automated tests use a scripted fake WebDriver server and
  a scripted proxy; an offline image smoke starts Firefox, opens a local page
  and deletes the session. `scripts/browser-webdriver-smoke.sh` is a manual,
  real-Firefox check of proxy routing (normal page load plus denied
  subresource, popup, form submit and rebinding-style answers) and is not part
  of CI. A real model driving the tool end to end against real sites has not
  been run, and DNS prefetch was not captured with a DNS or packet probe: its
  prefs are covered only by generated-`user.js` tests.
- **aarch64.** The build file carries the arm64 geckodriver hash, but no arm64
  image has been built or tested. CI publishes `linux/amd64` only.
- **CI images.** The image workflow builds and verifies both variants before
  pushing. A run of that workflow is not part of this phase's local
  verification.
- **Idle default.** `120000` ms is the default after the phase-2 measurements:
  an idle session stays around 350–421 MiB, a cold restart takes 1.0–1.8 s, but
  a timeout loses the page and snapshot numbering, so 120 s covers normal model
  latency. Memory-constrained deployments can set `60000`; `0` disables it.
- **Snapshot refs are ephemeral.** A DOM re-render that replaces elements
  invalidates the numbers; `click` and `type` then fail with the driver's
  element error. Call `snapshot` again.
- **`read` returns text.** It uses `innerText`, not HTML source. Use `snapshot`
  for interactive elements and links.
- **`type` appends.** It does not clear the field first; clear it through page
  interaction or type the full replacement.
- **Screenshots accumulate.** PNGs stay in the workspace and are not cleaned
  up automatically.
- **External WebDriver is not supported.** `native_webdriver_url` is ignored
  by this backend; geckodriver is always spawned locally. Outside the images,
  install geckodriver 0.37.1 and Firefox ESR so `firefox` is on `PATH`, or
  point `webdriver_geckodriver_path` at the binary.
- **Container warnings.** Under Docker's default seccomp profile Firefox logs
  `Sandbox: CanCreateUserNamespace() clone() failure: EPERM` and falls back to
  a less isolated sandbox; sessions still work and the container remains the
  boundary. Do not disable seccomp just to remove the warning. A minimal page
  worked with the default 64 MB `/dev/shm`; a real page load in the image smoke
  test needed 256 MB, which the example sets. Raise `--shm-size` if large pages
  crash Firefox.
- **Memory.** Measured outside the image with the same Firefox/geckodriver
  components: a warm idle session uses about 350–421 MiB in cgroup terms, a
  cold first start peaks at 991–1012 MiB including reclaimable page cache, and
  the OOM-relevant set peaks at 427–453 MiB. The ~1.05 GiB figure often quoted
  is summed RSS, which counts shared pages once per process; do not size
  `mem_limit` from it. The compose example uses `1536m`; 1280 MiB is a practical
  floor and 2048 MiB only fits hosts with the RAM. These are host measurements
  on local text pages, not in-image cgroup numbers, so treat them as a lower
  bound for real sites. One browser per process is the design point.

## Lightpanda MCP Variant (Phase 1)

junclaw publishes this route as the additional `main-lightpanda` image
variant. [Lightpanda](https://github.com/lightpanda-io/browser) runs as a
separate process and is reached through its own MCP server, so this route does
not use the built-in `browser` tool: the existing MCP client described in
[MCP](./mcp.md) connects to it over stdio.

### What the Lightpanda Variant Contains

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

### Configure the Lightpanda MCP Server

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
- `--block-private-networks`: keep it on. See
  [Lightpanda security model](#lightpanda-security-model).
- `timeout_ms`: `30000` gives room for cold starts and slow pages. Measured
  loads were about 0.3 s for `example.com` and about 1.1 s for a 343 KB page,
  but JavaScript-heavy pages can take longer. Raise it to `60000` if needed;
  the default `10000` is tight for page loads.
- `tools`: an allowlist of raw `tools/list` names, without the
  `mcp_lightpanda_` prefix. Omit it or leave it empty to register every tool;
  names the server does not expose are ignored with a warning. See
  [Lightpanda tool allowlist and token cost](#lightpanda-tool-allowlist-and-token-cost).
- Do not add `--cookie-jar` by default. A jar persists cookies to disk on exit,
  which widens the leak surface; enable it only when a workflow needs login
  state to survive restarts.

### Lightpanda Tool Allowlist and Token Cost

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

### Lightpanda Keyword Filtering

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

### Lightpanda Security Model

- **Private networks and SSRF.** `--block-private-networks` defaults to false
  upstream; the recommended config turns it on. Lightpanda resolves DNS and
  refuses page requests to private/internal addresses. On 1.0.2 this includes
  loopback: with the flag, requests to `http://127.0.0.1:<port>/` and
  `http://localhost:<port>/` fail with `CouldntConnect`; without it, local
  pages load. The flag does not block the stdio MCP transport, and an MCP
  `initialize` over `--port` still works with it on.
  - Local debugging exception: if you must browse a loopback page, keep
    `--block-private-networks` on and allow only the exact address with a
    negative CIDR, for example `--block-cidrs -127.0.0.1/32` (add `-::1/128`
    for IPv6). Dropping the main flag opens every other private network
    (RFC 1918, link-local, CGNAT, Docker and host management interfaces), and
    a negative CIDR wider than `/32` reopens the whole range it covers. Use a
    separate, disposable config and never point it at untrusted pages.
- **Cloud metadata.** On 1.0.2, `169.254.169.254` is refused while
  `--block-private-networks` is on, so the default config omits the redundant
  `--block-cidrs 169.254.169.254/32`. The loopback exception above keeps the
  main flag, so the metadata address stays blocked there too. IPv6 metadata
  ranges were not separately probed; add the CIDRs you need on clouds that
  expose IPv6 metadata.
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

### Lightpanda Deployment

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
