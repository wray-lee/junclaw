#!/usr/bin/env bash
# P0 end-to-end check: build the Zig dsh spike, then drive a real dsh web
# sidecar against the keyless OpenAI mock inside the dshside-proto container.
# Not part of `zig build test`; run it from the WSL host.
set -euo pipefail

REPO="${REPO:-/root/nc-dsh-p0}"
CONTAINER="${DSH_CONTAINER:-dshside-proto}"
DSH_BIN=/pkg/node_modules/@deepseek-ai/dsh/lib/bin.js
DSH_HOME=/root/dshhome-p0
WORKSPACE=/root/dsh-p0-wsp
PERSIST=/root/dshhome-p0/session.json
SPIKE_HOST="$REPO/zig-out/bin/dsh-spike"
SPIKE_GUEST=/root/dsh-spike

cleanup() {
  docker exec "$CONTAINER" bash -c '
    for p in /proc/[0-9]*; do
      cmd=$(tr "\0" " " < "$p/cmdline" 2>/dev/null)
      case "$cmd" in
        *mock-openai.mjs*|*"bin.js --profile web"*) kill -9 "${p#/proc/}" 2>/dev/null ;;
      esac
    done
  ' >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== build =="
flock /root/zig.lock docker run --rm --memory=6g \
  -v "$REPO:/src" -v nc-zig-cache:/root/.cache/zig -w /src \
  nc-zig:0.16.0 zig build -Dharness_dsh=true dsh-spike

echo "== stage =="
docker cp "$SPIKE_HOST" "$CONTAINER:$SPIKE_GUEST"
docker exec "$CONTAINER" chmod +x "$SPIKE_GUEST"

echo "== run =="
docker exec -i \
  -e MOCK_TOOL_CMD="touch /root/outside-workspace.txt" \
  -e MOCK_API_KEY=test-key \
  -e DSH_TELEMETRY_MODE=DISABLED \
  -e DSH_HOME="$DSH_HOME" \
  -e WORKSPACE="$WORKSPACE" \
  -e PERSIST="$PERSIST" \
  -e DSH_BIN="$DSH_BIN" \
  -e SPIKE="$SPIKE_GUEST" \
  "$CONTAINER" bash -s <<'EOS'
set -u
for p in /proc/[0-9]*; do
  cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$cmd" in
    *mock-openai.mjs*|*"bin.js --profile web"*) kill -9 "${p#/proc/}" 2>/dev/null ;;
  esac
done
sleep 0.3
rm -rf "$DSH_HOME" "$WORKSPACE" /root/outside-workspace.txt
mkdir -p "$DSH_HOME/profiles/web" "$WORKSPACE"
cp /pkg/web-cordis.patch.yml "$DSH_HOME/profiles/web/cordis.patch.yml"
rm -f /pkg/mock.log /pkg/mock.out
node /pkg/mock-openai.mjs >/pkg/mock.out 2>&1 &
for i in $(seq 1 50); do grep -q listen /pkg/mock.log 2>/dev/null && break; sleep 0.1; done
"$SPIKE" --dsh-bin "$DSH_BIN" --workspace "$WORKSPACE" --dsh-home "$DSH_HOME" --persist-file "$PERSIST"
EOS
