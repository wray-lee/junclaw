# Installation

This guide covers the main installation paths for macOS, Linux, and Windows.

## Page Guide

**Who this page is for**

- First-time users installing NullClaw on a local machine
- Operators choosing between package install, container deployment, and source build
- Contributors validating the baseline runtime before deeper setup

**Read this next**

- Open [Configuration](./configuration.md) after the binary is installed and on your `PATH`
- Open [Usage and Operations](./usage.md) when you are ready to run first commands and service mode
- Open [README](./README.md) if you want the broader English docs map before going deeper

**If you came from ...**

- [README](./README.md): this page is the concrete first-run path after choosing the installation track
- [Commands](./commands.md): come here first if the CLI is missing or `nullclaw --help` does not work yet
- [Development](./development.md): return here if a contributor workflow also needs a clean local binary setup

## Prerequisites

- If building from source, use **Zig 0.16.0**. See [Zig Installation](./zig-installation.md) for Debian setup.
- Git (required for source install).

Check Zig version:

```bash
zig version
```

The output must be `0.16.0`.

## Option 1: Release binary (junclaw, recommended)

Download the asset for your platform from [junclaw Releases](https://github.com/wray-lee/junclaw/releases/latest) — `junclaw-linux-x86_64.bin`, `junclaw-macos-aarch64.bin`, `junclaw-windows-x86_64.zip`, and so on (full list: [root README](../../README.md#install-junclaw)). The installed binary is still named `nullclaw`.

```bash
# Linux x86_64; macOS: junclaw-macos-aarch64.bin or junclaw-macos-x86_64.bin
curl -fsSL -o /tmp/nullclaw https://github.com/wray-lee/junclaw/releases/latest/download/junclaw-linux-x86_64.bin
chmod +x /tmp/nullclaw && sudo mv /tmp/nullclaw /usr/local/bin/nullclaw
nullclaw --help
```

Homebrew's `nullclaw` formula installs upstream nullclaw, not this fork; there is no junclaw tap. Use it only if you want upstream:

```bash
brew install nullclaw
nullclaw --help
```

If the command works, installation is complete.

## Option 2: Container Image (Docker / Podman)

junclaw publishes its own OCI image at `ghcr.io/wray-lee/junclaw` (`linux/amd64` only). Upstream also publishes `ghcr.io/nullclaw/nullclaw`, which does not include the dsh harness or browser variants.

The container stores its persistent state under `/nullclaw-data`:

- config: `/nullclaw-data/config.json`
- workspace: `/nullclaw-data/workspace`

The bundled starter config already uses the current schema (`agents.defaults.model.primary` plus `models.providers`), so `latest` should boot cleanly before you customize provider credentials.

### Existing volumes

A named volume keeps the ownership it was first populated with. If yours was created by an image where `/nullclaw-data` was owned by root, the container still fails with `AccessDenied` after the image is fixed. Repair it once, as root:

```bash
docker run --rm -u 0 -v nullclaw-data:/nullclaw-data \
  --entrypoint sh ghcr.io/wray-lee/junclaw:v1.1.2 \
  -c 'chown -R 65534:65534 /nullclaw-data'
```

Bind mounts are not covered by that command: they carry the host directory's ownership, so the directory you mount must be writable by uid `65534`.

### Quick one-off commands

```bash
docker run --rm -it \
  -v nullclaw-data:/nullclaw-data \
  ghcr.io/wray-lee/junclaw:v1.1.2 status
```

Initialize config interactively:

```bash
docker run --rm -it \
  -v nullclaw-data:/nullclaw-data \
  ghcr.io/wray-lee/junclaw:v1.1.2 onboard --interactive
```

Run the interactive agent:

```bash
docker run --rm -it \
  -v nullclaw-data:/nullclaw-data \
  ghcr.io/wray-lee/junclaw:v1.1.2 agent
```

Run the HTTP gateway:

```bash
docker run --rm -it \
  -p 127.0.0.1:3000:3000 \
  -v nullclaw-data:/nullclaw-data \
  ghcr.io/wray-lee/junclaw:v1.1.2
```

### Docker Compose

The repository's `docker-compose.yml` builds `nullclaw:local` from the Dockerfile by default, and `make up` forces a rebuild. To use the published junclaw image instead, pull it and start compose directly:

```bash
export NULLCLAW_IMAGE=ghcr.io/wray-lee/junclaw:v1.1.2
docker compose --profile gateway pull gateway
docker compose --profile gateway up -d gateway   # do not use `make up`; it adds --build
```

Interactive onboarding:

```bash
docker compose --profile agent run --rm agent onboard --interactive
```

Inside the container flow, pressing Enter at the workspace prompt keeps the volume-backed default:

- workspace: `/nullclaw-data/workspace`

Interactive agent session:

```bash
docker compose --profile agent run --rm agent
```

Long-running gateway:

```bash
docker compose --profile gateway up -d gateway
```

Profile behavior:

- `agent`: one-off interactive CLI container
- `gateway`: long-running HTTP gateway published on host loopback port `3210` (override with `NULLCLAW_PORT`)

If you need LAN or public exposure, change the published host IP deliberately and review [Security](./security.md) first.

To pin a release tag or switch registries later, override `NULLCLAW_IMAGE`:

```bash
NULLCLAW_IMAGE=ghcr.io/wray-lee/junclaw:v1.1.2 docker compose --profile gateway pull gateway
NULLCLAW_IMAGE=ghcr.io/wray-lee/junclaw:v1.1.2 docker compose --profile gateway up -d gateway
```

### Full dsh image (optional)

The fork also publishes a full image that bundles the [dsh](https://github.com/deepseek-ai/deepseek-harness) sidecar harness with the same `nullclaw` binary:

```bash
docker pull ghcr.io/wray-lee/junclaw:full-dsh
```

Tags:

- `:full-dsh` — latest build of the `full-dsh` target
- `:full-dsh-v<version>` — build from a `full-dsh-v*` tag, pushed with each release (e.g. `:full-dsh-v1.1.2`)
- `:full-dsh-main-<sha>` — manual CI run

Releases publish no `v<version>-full-dsh`; the full browser variant is `:v<version>-full-dsh-browser`.

Build it locally from the repository Dockerfile target:

```bash
docker build --target full-dsh -t junclaw:full-dsh .
```

**Platform:** `linux/amd64` only. The ARM64 runtime has not been tested, so this image does not claim ARM64 support.

**Size and memory (measured on linux/amd64):**

- Image: 1.4 GB (1,441,200,646 bytes) uncompressed, 250 MB (about 261 MB) compressed (`docker save | gzip`)
- RSS: about 2-3 MB idle (gateway running, dsh not started); about 288 MB for the container at peak during a turn, with the dsh sidecar peaking at about 320 MB VmRSS (an earlier probe measured 202-244 MB for shorter turns)

Plan for at least 512 MB of memory per container; 1 GB is safer.

**Enabling the dsh sidecar:** `agent.harness` defaults to `dsh`, the in-process engine, which this image also runs. The image additionally bundles the DeepSeek-Harness sidecar and sets `NULLCLAW_DSH_BIN` and `DSH_HOME=/nullclaw-data/.dsh`; to use the bundled sidecar instead, opt in explicitly:

```json
{
  "agent": {
    "harness": "dsh-sidecar"
  }
}
```

Keep your normal `models.providers` configuration in `config.json`; the harness writes a `junclaw` route into dsh's web profile. `HOME`, `NULLCLAW_HOME`, and the workspace stay under `/nullclaw-data` (uid 65534).

**Behavior differences:**

- dsh runs its own agent loop and tools inside the container. junclaw `memory`, `cron`, and `tools` are not automatically exposed to dsh; bridging them needs an MCP server or a dsh plugin.
- Approvals, when surfaced, support only `allow-once` and `reject` (dsh has no allow-always). The current P1 harness does not yet surface approval prompts to channels.
- The dsh web profile is pinned to `0.2.1-rc.2`; the image installs it from a committed lock file with integrity hashes.

## Option 3: Build from Source (cross-platform)

```bash
git clone https://github.com/wray-lee/junclaw.git
cd junclaw
zig build -Doptimize=ReleaseSmall
zig build test --summary all
```

The default build includes the in-process `dsh` engine. To also build the optional dsh sidecar harness (needs Node 22 at run time), add `-Dharness_dsh=true`:

```bash
zig build -Doptimize=ReleaseSmall -Dharness_dsh=true
```

Build output:

- `zig-out/bin/nullclaw`

## Option 4: Android / Termux

There are three different Android / Termux paths:

- download an official pre-built Android / Termux binary from releases
- build directly inside Termux on the Android device
- cross-compile an Android binary from another machine

### Termux native build

```bash
pkg update
pkg install git zig
git clone https://github.com/wray-lee/junclaw.git
cd junclaw
zig version
zig build -Doptimize=ReleaseSmall
./zig-out/bin/nullclaw --help
```

Notes:

- Use **Zig 0.16.0** exactly.
- If `zig build` fails immediately, verify the Zig version first.
- This uses the native target of the current Termux environment, so you usually do **not** need `-Dtarget`.
- On Android / Termux, prefer foreground use first (`agent`, `gateway`) before trying to manage it as a background service.
- Official releases publish pre-built Android / Termux binaries for `aarch64`, `armv7`, and `x86_64`.
- For the fuller Android / Termux path, including troubleshooting, see [Termux Guide](./termux.md).

### Cross-compiling for Android

If you are building on another machine for a Termux / Android device, pass an explicit Zig target and an Android libc/sysroot file. `-Dtarget` alone is not enough:

```bash
zig build -Dtarget=aarch64-linux-android.24 -Doptimize=ReleaseSmall --libc /path/to/android-libc-aarch64.txt
```

Common Android targets:

- `aarch64-linux-android.24`
- `arm-linux-androideabi.24` with `-Dcpu=baseline+v7a`
- `x86_64-linux-android.24`

Use the target that matches the phone or emulator architecture.
See [`.github/workflows/release.yml`](../../.github/workflows/release.yml) for a complete example of generating the `--libc` file from the Android NDK.
Official releases also attach matching Android / Termux binaries built for Android API 24.

## Add binary to PATH

### Compiled binary file

#### macOS/Linux（zsh/bash）

```bash
zig build -Doptimize=ReleaseSmall -p "$HOME/.local"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
# bash users: use ~/.bashrc
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

### Downloaded nullclaw binary file (Windows, Powershell)
Download `junclaw-windows-x86_64.zip` (or `junclaw-windows-aarch64.zip`) from [junclaw Releases](https://github.com/wray-lee/junclaw/releases/latest), extract it, and then run the following commands with administrator privileges in Powershell to add the directory containing `nullclaw.exe` to the Windows `PATH` environment variable:

```Powershell 
$old = [Environment]::GetEnvironmentVariable("Path", "Machine")
$new = "$old;x:\path\to\nullclaw"
[Environment]::SetEnvironmentVariable("Path", $new, "Machine")
```

## Verify Installation

```bash
nullclaw --help
nullclaw --version
nullclaw status
```

If `status` returns component state successfully, runtime basics are ready.

## Upgrade and Uninstall

> **Upgrading from 1.1.0 or earlier:** those builds' `nullclaw update` still fetches upstream nullclaw and would replace junclaw with it. Download the new `junclaw-*` asset from [Releases](https://github.com/wray-lee/junclaw/releases/latest) once and replace the binary (same commands as Option 1); later builds update from junclaw releases with `nullclaw update`.

### Release binary

- upgrade: download the new `junclaw-<platform>.bin`, then `chmod +x` and move it over the installed `nullclaw`
- uninstall: delete the `nullclaw` binary and remove its directory from `PATH`

### Homebrew (upstream nullclaw only)

- upgrade: `brew update && brew upgrade nullclaw` (installs upstream, not junclaw)
- uninstall: `brew uninstall nullclaw`

### Source install

- Upgrade: `git pull`, then rebuild with `zig build -Doptimize=ReleaseSmall`.
- Uninstall: delete the installed `nullclaw` binary and remove the PATH entry.

## Next Steps

- Run `nullclaw onboard --interactive`, then continue with [Configuration](./configuration.md)
- Use [Usage and Operations](./usage.md) for first-run commands, service mode, and troubleshooting
- Keep [Commands](./commands.md) nearby if you want a task-based CLI reference after install

## Related Pages

- [README](./README.md)
- [Termux Guide](./termux.md)
- [Configuration](./configuration.md)
- [Usage and Operations](./usage.md)
- [Commands](./commands.md)
