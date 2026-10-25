#!/bin/bash
# Container-side half of the dsh-native acceptance smoke. The host runners
# (dsh-native-smoke-scripted.sh / dsh-native-smoke-real.sh) copy this file and
# a config into a throwaway container and start it. Not meant to run on a host.
#
# Asserts: the webhook turn replies, the dsh JSONL has the full tool loop, the
# junclaw store mirrors the messages, and the config did not select a harness
# (so the default engine did the work).
set -euo pipefail

DATA=${SMOKE_DATA:-/smoke-data}
TOKEN=${SMOKE_TOKEN:-test-token}
MOCK=${SMOKE_MOCK:-0}
GATEWAY_LOG=/tmp/gateway.log
MOCK_LOG=/tmp/mock.log
RESPONSE_FILE=/tmp/webhook-response.txt

MOCK_PID=""
GW_PID=""

dump() {
  echo "--- gateway.log (tail) ---"
  tail -n 40 "$GATEWAY_LOG" 2>/dev/null || true
  echo "--- mock requests ---"
  grep -c '^REQ ' "$MOCK_LOG" 2>/dev/null || true
  echo "--- mock.out (head) ---"
  head -c 1500 /tmp/mock.out 2>/dev/null || true
  echo
  echo "--- webhook response ---"
  head -c 2000 "$RESPONSE_FILE" 2>/dev/null || true
  echo
}

cleanup() {
  status=$?
  if [ -n "$GW_PID" ]; then kill "$GW_PID" 2>/dev/null || true; fi
  if [ -n "$MOCK_PID" ]; then kill "$MOCK_PID" 2>/dev/null || true; fi
  if [ "$status" -ne 0 ]; then dump; fi
}
trap cleanup EXIT

fail() {
  echo "SMOKE_FAIL: $*"
  exit 1
}

mkdir -p "$DATA/workspace"
cp /tmp/smoke-config.json "$DATA/config.json"
export NULLCLAW_HOME="$DATA"

# The default harness (dsh) must be under test: nothing may pin it.
if grep -q '"harness"' "$DATA/config.json"; then
  fail "the smoke config must not set agent.harness"
fi

if [ "$MOCK" = "1" ]; then
  MOCK_PORT=18081 MOCK_LOG="$MOCK_LOG" /tmp/smoke-mock >/tmp/mock.out 2>&1 &
  MOCK_PID=$!
fi

/tmp/nullclaw gateway --port 3001 --host 127.0.0.1 >"$GATEWAY_LOG" 2>&1 &
GW_PID=$!

# Readiness poll only; no assertion depends on elapsed time.
ready=0
for _ in $(seq 1 200); do
  # The subshell keeps bash's connect error off stderr; the real connection
  # is opened once the probe succeeds.
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

MESSAGE="SMOKE_PING: call the bash tool with command 'echo SMOKE_TOOL_OUTPUT' and description 'Emit the smoke marker', then reply with exactly SMOKE_REPLY_OK."
BODY=$(printf '{"message":"%s"}' "$MESSAGE")
BODY_LEN=${#BODY}

exec 3<>/dev/tcp/127.0.0.1/3001
printf 'POST /webhook HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
  "$TOKEN" "$BODY_LEN" "$BODY" >&3
RESPONSE=$(cat <&3)
exec 3>&-
printf '%s' "$RESPONSE" >"$RESPONSE_FILE"

case "$RESPONSE" in
  *SMOKE_REPLY_OK*) ;;
  *) fail "webhook reply is missing SMOKE_REPLY_OK" ;;
esac

if [ "$MOCK" = "1" ]; then
  requests=$(grep -c '^REQ POST .*chat/completions' "$MOCK_LOG" || true)
  [ "$requests" -eq 2 ] || fail "expected 2 provider requests, got $requests"
  # The tool result must be in the follow-up request, not just the prompt.
  awk 'prev ~ /^REQ POST .*chat\/completions/ && /\[Tool results\]/ && /SMOKE_TOOL_OUTPUT/ { ok = 1 } { prev = $0 } END { exit !ok }' "$MOCK_LOG" ||
    fail "the follow-up provider request has no tool result"
fi

JSONL=$(find "$DATA/.dsh/sessions" -name session.v4.jsonl -type f 2>/dev/null | head -n 1) || true
[ -n "$JSONL" ] || fail "dsh session JSONL was not written"
for event in user/message tool/call tool/result assistant/message turn/end; do
  grep -q "\"type\":\"$event\"" "$JSONL" || fail "dsh JSONL is missing $event"
done
grep -q '"type":"tool/call".*"name":"bash"' "$JSONL" || fail "dsh JSONL has no bash tool call"
grep -q '"type":"tool/result".*SMOKE_TOOL_OUTPUT' "$JSONL" || fail "dsh JSONL tool result has no tool output"
grep -q 'SMOKE_REPLY_OK' "$JSONL" || fail "dsh JSONL has no final reply"

SESSIONS=$(/tmp/nullclaw agent sessions list --json) || fail "junclaw store is unreadable"
case "$SESSIONS" in
  *"\"session_key\":\"webhook:$TOKEN\""*) ;;
  *) fail "junclaw store is missing session webhook:$TOKEN" ;;
esac
case "$SESSIONS" in
  *'"turn_count":1'*) ;;
  *) fail "junclaw store turn_count is not 1" ;;
esac
# SQLite keeps the newest rows in the WAL until a checkpoint.
grep -aq 'SMOKE_REPLY_OK' "$DATA"/workspace/memory.db* || fail "junclaw store does not contain the mirrored reply"

echo "SMOKE_OK"
