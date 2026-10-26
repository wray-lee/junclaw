#!/usr/bin/env bash
# Opt-in MCP stdio integration smoke. NOT part of the CI test set.
#
# Runs the test `mcp stdio bridge: allowlist, per-turn filter, calls, timeout,
# abort, retention` with `JUNCLAW_MCP_STDIO_SERVER` pointing at
# scripts/mcp-stdio-fake-server.py, so the branch really spawns a stdio MCP
# server through junclaw's `mcp.zig` client and bridges it into the in-process
# dsh engine. Without that variable the test skips itself, which is what CI
# sees. No network and no browser are involved.
#
# Covered: tools/list -> `mcp_fake_<tool>` names, the per-server `tools`
# allowlist at initMcpTools, per-turn `agent.tool_filter_groups` (including a
# CJK keyword), call success, JSON-RPC failure, request timeout, /stop abort
# (ABORTED_BEFORE_DISPATCH for the queued call) and the 64 KB tail + spill
# retention rule.
#
# Usage (WSL host with Docker; the image needs python3 and zig, nc-zig has both):
#   scripts/mcp-stdio-smoke.sh [/path/to/clone]
# Defaults to this script's repository root. Set SMOKE_IMAGE to override
# `nc-zig:0.16.0`. The run executes the full `zig build test --summary all`
# because the build has no test filter; expect a few minutes.
set -euo pipefail

clone=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
image=${SMOKE_IMAGE:-nc-zig:0.16.0}

if [ ! -f "$clone/build.zig" ]; then
  echo "mcp-stdio-smoke: no build.zig under $clone" >&2
  exit 2
fi

docker run --rm \
  -e JUNCLAW_MCP_STDIO_SERVER=/src/scripts/mcp-stdio-fake-server.py \
  -v "$clone:/src" \
  -v nc-zig-cache:/root/.cache/zig \
  -w /src \
  "$image" \
  zig build test --summary all
