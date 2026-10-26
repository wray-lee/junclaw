#!/usr/bin/env bash
# Lightpanda MCP end-to-end smoke (WSL one-click).
#
# Starts a throwaway docker network with a local static-page container and a
# junclaw container built from the Dockerfile `lightpanda` target (nullclaw and
# lightpanda in PATH). A keyless scripted OpenAI-compatible provider, served by
# the page container, drives real webhook turns through the default agent
# engine; the agent calls the Lightpanda MCP server's goto and markdown tools.
# The page and the provider are both local, so the smoke never leaves the box.
#
# Asserts both sides of the private-network guard:
#   A. with the default --block-private-networks, goto http://site:8080/
#      returns "navigation failed: CouldntConnect" and the page marker never
#      reaches the provider;
#   B. adding the documented negative CIDR (--block-cidrs -10.213.7.0/24)
#      exempts the smoke subnet: goto reports "Navigated. HTTP 200 OK." and
#      markdown returns the page text containing SMOKEPAGEMARKER7F3A.
#
# Usage (WSL with docker):
#   scripts/lightpanda-mcp-smoke.sh
#
# Env:
#   SMOKE_LP_IMAGE  image with nullclaw + lightpanda (default
#                   junclaw:lightpanda-smoke; built from this tree when absent)
#   SMOKE_PY_IMAGE  page/provider image (default python:3-alpine)
#   KEEP=1          keep containers, network and work dir for debugging
#
# Not part of the CI must-run set: it needs the real Lightpanda binary image
# and docker networking, neither of which the three-platform CI runners
# provide. Run it locally in WSL.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

LP_IMAGE=${SMOKE_LP_IMAGE:-junclaw:lightpanda-smoke}
PY_IMAGE=${SMOKE_PY_IMAGE:-python:3-alpine}
SUBNET=10.213.7.0/24
SITE_IP=10.213.7.2
TOKEN=test-token
NET=junclaw-lp-smoke-$$
SITE=junclaw-lp-smoke-site-$$
JC_A=junclaw-lp-smoke-a-$$
JC_B=junclaw-lp-smoke-b-$$
WORK=$(mktemp -d "${TMPDIR:-/tmp}/junclaw-lp-smoke.XXXXXX")

die() {
  echo "SMOKE_FAIL: $*" >&2
  exit 1
}

cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then
    echo "smoke: kept $SITE $JC_A $JC_B, network $NET, work $WORK (KEEP=1)" >&2
    return
  fi
  docker rm -f "$JC_A" "$JC_B" "$SITE" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ── static page + scripted provider (container-side) ─────────────────────────
cat >"$WORK/mock.py" <<'PY'
#!/usr/bin/env python3
"""Static page + scripted OpenAI-compatible provider for the Lightpanda smoke.

Serves the page on / and answers /v1/chat/completions with
mcp_lightpanda_goto, then mcp_lightpanda_markdown, then a final reply. Every
request body is appended to MOCK_LOG so the host can assert on the tool results
the engine sent back. No network, no model, no keys.
"""
import http.server
import json
import os

PAGE = (b"<!doctype html><html><body><h1>SMOKEPAGEMARKER7F3A</h1>"
        b"<p>lightpanda smoke page</p></body></html>")
LOG = os.environ.get("MOCK_LOG", "/tmp/mock.log")


def completion(message, finish):
    return {"id": "chatcmpl-smoke", "object": "chat.completion", "created": 0,
            "model": "mock-model",
            "choices": [{"index": 0, "message": message,
                         "finish_reason": finish}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1,
                      "total_tokens": 2}}


GOTO = completion({"role": "assistant", "content": None, "tool_calls": [{
    "id": "call_goto_1", "type": "function",
    "function": {"name": "mcp_lightpanda_goto",
                 "arguments": json.dumps({"url": "http://site:8080/"})}}]},
    "tool_calls")
MARKDOWN = completion({"role": "assistant", "content": None, "tool_calls": [{
    "id": "call_markdown_2", "type": "function",
    "function": {"name": "mcp_lightpanda_markdown",
                 "arguments": "{}"}}]}, "tool_calls")
FINAL = completion({"role": "assistant", "content": "SMOKE_REPLY_OK"}, "stop")
TITLE = completion({"role": "assistant", "content": "Lightpanda MCP smoke"},
                   "stop")


def message_text(body):
    try:
        messages = json.loads(body).get("messages", [])
    except ValueError:
        return body
    return "\n".join(m.get("content") for m in messages
                     if isinstance(m.get("content"), str))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, code, ctype, data):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/":
            self.send(200, "text/html", PAGE)
        elif self.path.startswith("/v1/models"):
            self.send(200, "application/json", json.dumps(
                {"object": "list",
                 "data": [{"id": "mock-model", "object": "model"}]}).encode())
        else:
            self.send(404, "text/plain", b"not found")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace")
        with open(LOG, "a", encoding="utf-8") as log:
            log.write(body + "\n")
        if not self.path.endswith("/chat/completions"):
            self.send(404, "text/plain", b"not found")
            return
        try:
            request = json.loads(body)
        except ValueError:
            request = {}
        if not request.get("tools"):
            # Session-title and other helper calls carry no tool schemas.
            self.send(200, "application/json", json.dumps(TITLE).encode())
            return
        text = message_text(body)
        if '<tool_result name="mcp_lightpanda_goto"' not in text:
            reply = GOTO
        elif '<tool_result name="mcp_lightpanda_markdown"' not in text:
            reply = MARKDOWN
        else:
            reply = FINAL
        self.send(200, "application/json", json.dumps(reply).encode())


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

# ── junclaw container-side driver ────────────────────────────────────────────
cat >"$WORK/inner.sh" <<'SH'
#!/bin/bash
# Container-side half of the Lightpanda MCP smoke. Starts the nullclaw gateway
# with one config and drives one webhook turn. Not meant to run on a host.
set -euo pipefail

CONFIG=$1
DATA=$2
TOKEN=${SMOKE_TOKEN:-test-token}
LOG=$DATA/gateway.log

mkdir -p "$DATA/workspace"
cp "$CONFIG" "$DATA/config.json"
export NULLCLAW_HOME="$DATA"

fail() {
  echo "SMOKE_FAIL: $*" >&2
  echo "--- gateway.log (tail) ---" >&2
  tail -n 60 "$LOG" >&2 2>/dev/null || true
  exit 1
}

nullclaw gateway --port 3001 --host 127.0.0.1 >"$LOG" 2>&1 &
GW_PID=$!
trap 'kill "$GW_PID" 2>/dev/null || true' EXIT

ready=0
for _ in $(seq 1 200); do
  if (exec 3<>/dev/tcp/127.0.0.1/3001) 2>/dev/null; then
    exec 3<>/dev/tcp/127.0.0.1/3001
    printf 'GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' >&3
    health=$(cat <&3) || true
    exec 3>&-
    case "$health" in *' 200 '*) ready=1; break ;; esac
  fi
  sleep 0.1
done
[ "$ready" = "1" ] || fail "gateway did not become ready"

MESSAGE='SMOKE_PING: browse http://site:8080/ with the lightpanda MCP tools.'
BODY=$(printf '{"message":"%s"}' "$MESSAGE")
exec 3<>/dev/tcp/127.0.0.1/3001
printf 'POST /webhook HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
  "$TOKEN" "${#BODY}" "$BODY" >&3
RESPONSE=$(cat <&3)
exec 3>&-
case "$RESPONSE" in
  *SMOKE_REPLY_OK*) ;;
  *) echo "$RESPONSE" >&2; fail "webhook reply is missing SMOKE_REPLY_OK" ;;
esac
echo "SMOKE_TURN_OK"
SH

# ── configs: same agent wiring, only the lightpanda args differ ──────────────
write_config() {
  cat >"$1" <<JSON
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
        "base_url": "http://$SITE_IP:8080/v1"
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
  },
  "mcp_servers": {
    "lightpanda": {
      "command": "lightpanda",
      "args": ["mcp", "--block-private-networks"$2],
      "timeout_ms": 30000,
      "tools": ["goto", "markdown"]
    }
  }
}
JSON
}

write_config "$WORK/config-block.json" ''
write_config "$WORK/config-allow.json" ', "--block-cidrs", "-10.213.7.0/24"'

# ── images ───────────────────────────────────────────────────────────────────
if ! docker image inspect "$LP_IMAGE" >/dev/null 2>&1; then
  echo "smoke: building $LP_IMAGE (Dockerfile target lightpanda)" >&2
  docker buildx build --progress=plain --target lightpanda --load \
    -t "$LP_IMAGE" --build-arg VERSION=1.0.0 "$REPO_ROOT" >&2 ||
    die "image build failed: $LP_IMAGE"
fi
docker image inspect "$PY_IMAGE" >/dev/null 2>&1 ||
  docker pull "$PY_IMAGE" >&2 ||
  die "image not found: $PY_IMAGE"

# ── local static page + provider ─────────────────────────────────────────────
docker network create --subnet "$SUBNET" "$NET" >/dev/null ||
  die "docker network create failed (subnet $SUBNET in use?)"
docker run -d --name "$SITE" --network "$NET" --network-alias site \
  --ip "$SITE_IP" -v "$WORK:/site:ro" -w /site "$PY_IMAGE" \
  python3 mock.py >/dev/null

ready=0
for _ in $(seq 1 100); do
  if docker exec "$SITE" python3 -c \
    "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/', timeout=1)" \
    >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" = "1" ] || die "page/provider container did not become ready"

# ── one gateway turn in a fresh container ────────────────────────────────────
# run_turn <container> <config> <data dir> <host log>
run_turn() {
  local name=$1 config=$2 data=$3 log=$4
  docker run -d --name "$name" --network "$NET" --user 0 \
    --entrypoint sleep "$LP_IMAGE" 86400 >/dev/null
  docker cp "$WORK/inner.sh" "$name:/tmp/inner.sh"
  docker cp "$config" "$name:/tmp/config.json"
  docker exec "$SITE" rm -f /tmp/mock.log
  docker exec "$name" timeout 180 bash /tmp/inner.sh /tmp/config.json "$data" ||
    die "$name: webhook turn failed"
  docker cp "$SITE:/tmp/mock.log" "$log" ||
    die "$name: provider request log missing"
  docker rm -f "$name" >/dev/null
}

echo "smoke: assertion A (private networks blocked)"
run_turn "$JC_A" "$WORK/config-block.json" /smoke-data-a "$WORK/mock-block.log"
grep -q 'mcp_lightpanda_goto' "$WORK/mock-block.log" ||
  die "A: the provider never saw a goto tool call"
grep -q 'navigation failed: CouldntConnect' "$WORK/mock-block.log" ||
  die "A: goto did not report the blocked private network"
if grep -q 'SMOKEPAGEMARKER7F3A' "$WORK/mock-block.log"; then
  die "A: page text leaked through the private-network block"
fi
echo "SMOKE_PASS A: block: goto http://site:8080/ -> navigation failed: CouldntConnect; page text absent"

echo "smoke: assertion B (CIDR exception allows the smoke subnet)"
run_turn "$JC_B" "$WORK/config-allow.json" /smoke-data-b "$WORK/mock-allow.log"
grep -q 'Navigated. HTTP 200 OK.' "$WORK/mock-allow.log" ||
  die "B: goto did not succeed through the CIDR exception"
grep -q 'mcp_lightpanda_markdown' "$WORK/mock-allow.log" ||
  die "B: the provider never saw a markdown tool call"
grep -q 'SMOKEPAGEMARKER7F3A' "$WORK/mock-allow.log" ||
  die "B: markdown output has no page marker"
echo "SMOKE_PASS B: allow: goto -> Navigated. HTTP 200 OK.; markdown text contains page marker"
grep -o '# SMOKEPAGEMARKER7F3A.\{0,32\}' "$WORK/mock-allow.log" | head -n 1 |
  sed 's/^/SMOKE_PAGE_TEXT: /'

echo "SMOKE_OK"
