#!/usr/bin/env bash
# dsh-native acceptance smoke, real-provider edition.
#
# Same turn and assertions as dsh-native-smoke-scripted.sh, but the provider is
# an endpoint given through the environment. Nothing is contacted unless
# SMOKE_BASE_URL and SMOKE_API_KEY are set; there is no default endpoint.
# The model is instructed to call the bash tool and then answer exactly
# SMOKE_REPLY_OK, which is what the assertions look for.
#
# Usage:
#   JUNCLAW_BIN=/path/to/nullclaw \
#   SMOKE_BASE_URL=https://llm.example.com/v1 \
#   SMOKE_API_KEY=test-key \
#   SMOKE_MODEL=smoke-model \
#   scripts/dsh-native-smoke-real.sh
#
# Env:
#   JUNCLAW_BIN            required, static Linux binary (default build)
#   SMOKE_BASE_URL         required, OpenAI-compatible base URL
#   SMOKE_API_KEY          required
#   SMOKE_MODEL            model name sent to the provider (default smoke-model)
#   SMOKE_PROVIDER         config provider key (default smoke)
#   SMOKE_API_MODE         optional "chat_completions" or "responses"
#   SMOKE_IMAGE            runtime image (default nc-zig:0.16.0)
#   SMOKE_DOCKER_NETWORK   docker network (default bridge; use host for a
#                          provider listening on the docker host)
#   SMOKE_TOKEN            paired token used for /webhook (default test-token)
#   KEEP=1                 keep the container for debugging
#   SMOKE_KEEP_WORK=1      keep the host log on success
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/dsh-native-smoke-lib.sh"

if [ -z "${JUNCLAW_BIN:-}" ] || [ -z "${SMOKE_BASE_URL:-}" ] || [ -z "${SMOKE_API_KEY:-}" ]; then
  cat >&2 <<'USAGE'
SMOKE_FAIL: JUNCLAW_BIN, SMOKE_BASE_URL and SMOKE_API_KEY are required.
No endpoint is contacted without them. Example:
  JUNCLAW_BIN=/path/to/nullclaw \
  SMOKE_BASE_URL=https://llm.example.com/v1 \
  SMOKE_API_KEY=test-key \
  SMOKE_MODEL=smoke-model \
  scripts/dsh-native-smoke-real.sh
USAGE
  exit 2
fi

SMOKE_IMAGE=${SMOKE_IMAGE:-nc-zig:0.16.0}
SMOKE_PROVIDER=${SMOKE_PROVIDER:-smoke}
SMOKE_MODEL=${SMOKE_MODEL:-smoke-model}
SMOKE_DOCKER_NETWORK=${SMOKE_DOCKER_NETWORK:-bridge}
SMOKE_API_MODE=${SMOKE_API_MODE:-chat_completions}

for value in "$SMOKE_BASE_URL" "$SMOKE_API_KEY" "$SMOKE_PROVIDER" "$SMOKE_MODEL" "$SMOKE_API_MODE"; do
  case "$value" in
    *'"'*|*'\'*|*$'\n'*)
      echo "SMOKE_FAIL: provider env values must not contain quotes, backslashes or newlines" >&2
      exit 2
      ;;
  esac
done
if [ -n "$SMOKE_API_MODE" ] && [ "$SMOKE_API_MODE" != "chat_completions" ] && [ "$SMOKE_API_MODE" != "responses" ]; then
  echo "SMOKE_FAIL: SMOKE_API_MODE must be chat_completions or responses" >&2
  exit 2
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/dsh-native-smoke-cfg.XXXXXX")
trap 'rm -rf "$tmp"; smoke_cleanup' EXIT INT TERM

# No "agent.harness" key on purpose: the default (in-process dsh) is the
# engine under test.
{
  cat <<JSON
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "$SMOKE_PROVIDER/$SMOKE_MODEL"
      }
    }
  },
  "models": {
    "providers": {
      "$SMOKE_PROVIDER": {
        "api_key": "$SMOKE_API_KEY",
        "base_url": "$SMOKE_BASE_URL",
        "api_mode": "$SMOKE_API_MODE"
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
} >"$tmp/config.json"

# `responses` mode has no streaming implementation, so the live-delta
# assertion would always fail; the turn still runs end-to-end.
if [ "${SMOKE_API_MODE:-}" = "responses" ]; then
  echo "smoke: SMOKE_API_MODE=responses has no streaming; skipping the delta assertion" >&2
  export SMOKE_STREAM_CHECK=skip
fi

smoke_run "$tmp/config.json" 0 "$SMOKE_DOCKER_NETWORK"
