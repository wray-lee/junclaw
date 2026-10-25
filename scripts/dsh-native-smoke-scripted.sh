#!/usr/bin/env bash
# dsh-native acceptance smoke, scripted-provider edition.
#
# Runs one full webhook turn through the in-process dsh engine in a throwaway
# container: user message -> bash tool call -> tool result -> final reply. A
# keyless local OpenAI-compatible mock answers the provider calls, so this
# needs no network and no real model.
#
# What it asserts:
#   - the gateway replies with SMOKE_REPLY_OK;
#   - the mock saw exactly two chat requests and the second carried the tool
#     result (the tool really ran);
#   - a dsh v4 JSONL was written under .dsh/sessions/ with user/message,
#     tool/call (bash), tool/result, assistant/message and turn/end;
#   - the junclaw store mirrored the user message and the reply
#     (webhook:test-token, turn_count 1);
#   - the config sets no agent.harness, so the default engine is under test.
#
# Usage:
#   JUNCLAW_BIN=/path/to/nullclaw scripts/dsh-native-smoke-scripted.sh
#
# JUNCLAW_BIN must be a static Linux x86_64 build of this tree, e.g.
#   zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall
# The default build is enough; -Dharness_dsh=true only adds the sidecar.
#
# Env:
#   JUNCLAW_BIN       required, static Linux binary
#   SMOKE_IMAGE       runtime image (default nc-zig:0.16.0; needs bash + zig)
#   SMOKE_MOCK_BIN    prebuilt helper; built in SMOKE_IMAGE when unset
#   SMOKE_TOKEN       paired token used for /webhook (default test-token)
#   KEEP=1            keep the container for debugging
#   SMOKE_KEEP_WORK=1 keep the host log on success
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/dsh-native-smoke-lib.sh"

if [ -z "${JUNCLAW_BIN:-}" ]; then
  cat >&2 <<'USAGE'
SMOKE_FAIL: JUNCLAW_BIN is required.
  JUNCLAW_BIN=/path/to/nullclaw scripts/dsh-native-smoke-scripted.sh
Build it with:
  zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall
USAGE
  exit 2
fi

SMOKE_IMAGE=${SMOKE_IMAGE:-nc-zig:0.16.0}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/dsh-native-smoke-cfg.XXXXXX")
trap 'rm -rf "$tmp"; smoke_cleanup' EXIT INT TERM

# No "agent.harness" key on purpose: the default (in-process dsh) is the
# engine under test.
cat >"$tmp/config.json" <<'JSON'
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "mock/mock-model"
      }
    }
  },
  "models": {
    "providers": {
      "mock": {
        "api_key": "test-key",
        "base_url": "http://127.0.0.1:18081/v1"
      }
    }
  },
  "memory": {
    "backend": "sqlite"
  },
  "gateway": {
    "port": 3001,
    "host": "127.0.0.1",
    "require_pairing": true,
    "paired_tokens": ["test-token"],
    "webhook_sync_for_workers": true,
    "request_timeout_secs": 600
  },
  "channels": {
    "cli": false
  },
  "a2a": {
    "enabled": true
  }
}
JSON

if [ -z "${SMOKE_MOCK_BIN:-}" ]; then
  echo "smoke: building scripted provider helper with $SMOKE_IMAGE" >&2
  docker run --rm -v "$SCRIPT_DIR:/src:ro" -v "$tmp:/out" -w /src "$SMOKE_IMAGE" \
    zig build-exe dsh-native-smoke-mock.zig -target x86_64-linux-musl -O ReleaseSmall \
    -femit-bin=/out/dsh-native-smoke-mock
  SMOKE_MOCK_BIN="$tmp/dsh-native-smoke-mock"
fi

smoke_run "$tmp/config.json" 1 none
