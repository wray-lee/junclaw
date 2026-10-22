#!/usr/bin/env bash
# Full dsh image smoke test: boot -> connect -> one tool turn (keyless mock
# provider) -> cancel -> resume, then report image size and RSS.
# Build the image first:
#   docker build --target full-dsh -t junclaw:full-dsh-test .
# Then run this script from the WSL host. Not part of `zig build test`.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
IMAGE="${IMAGE:-junclaw:full-dsh-test}"
CONTAINER="${DSH_CONTAINER:-junclaw-full-dsh-smoke}"
ZIG_IMAGE="${ZIG_IMAGE:-nc-zig:0.16.0}"
DSH_HOME=/nullclaw-data/.dsh-smoke
WORKSPACE=/nullclaw-data/smoke-workspace
SPIKE_HOST="$REPO/zig-out/bin/dsh-spike"
SPIKE_GUEST=/tmp/dsh-smoke/dsh-spike

cleanup() {
  docker rm -f "$CONTAINER" "${CONTAINER}-idle" >/dev/null 2>&1 || true
  rm -f /tmp/dsh-full-smoke-inner.sh /tmp/dsh-full-smoke.log
}
trap cleanup EXIT

docker image inspect "$IMAGE" >/dev/null

echo "== build spike =="
flock /root/zig.lock docker run --rm --memory=6g \
  -v "$REPO:/src" -v nc-zig-cache:/root/.cache/zig -w /src \
  "$ZIG_IMAGE" zig build -Dharness_dsh=true dsh-spike

echo "== start container =="
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --entrypoint sleep "$IMAGE" infinity >/dev/null

echo "== stage fixtures =="
docker exec -u 0 "$CONTAINER" mkdir -p "$DSH_HOME/profiles/web" "$WORKSPACE" /tmp/dsh-smoke
docker cp "$SPIKE_HOST" "$CONTAINER:$SPIKE_GUEST"
docker cp "$REPO/scripts/dsh-full-mock-openai.mjs" "$CONTAINER:/tmp/dsh-smoke/mock-openai.mjs"
docker cp "$REPO/scripts/dsh-full-cordis.patch.yml" "$CONTAINER:$DSH_HOME/profiles/web/cordis.patch.yml"
docker exec -u 0 "$CONTAINER" chown -R 65534:65534 "$DSH_HOME" "$WORKSPACE" /tmp/dsh-smoke
docker exec "$CONTAINER" chmod +x "$SPIKE_GUEST"

cat > /tmp/dsh-full-smoke-inner.sh <<'INNER'
#!/usr/bin/env bash
set -uo pipefail
export MOCK_API_KEY=test-key
export MOCK_LOG=/tmp/dsh-smoke/mock.log
export MOCK_TOOL_CMD="touch /nullclaw-data/outside-workspace.txt"
export DSH_TELEMETRY_MODE=DISABLED
rm -f "$MOCK_LOG" /nullclaw-data/outside-workspace.txt
node /tmp/dsh-smoke/mock-openai.mjs > /tmp/dsh-smoke/mock.out 2>&1 &
MOCK_PID=$!
trap 'kill -9 "$MOCK_PID" 2>/dev/null || true' EXIT
for i in $(seq 1 50); do grep -q listen "$MOCK_LOG" 2>/dev/null && break; sleep 0.1; done
if ! grep -q listen "$MOCK_LOG" 2>/dev/null; then
  echo "mock provider did not start"
  cat /tmp/dsh-smoke/mock.out
  exit 1
fi
/tmp/dsh-smoke/dsh-spike \
  --dsh-bin /opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js \
  --workspace /nullclaw-data/smoke-workspace \
  --dsh-home /nullclaw-data/.dsh-smoke \
  --persist-file /nullclaw-data/.dsh-smoke/session.json | tee /tmp/dsh-smoke/spike.out
rc=${PIPESTATUS[0]}
test -f /nullclaw-data/outside-workspace.txt || { echo "approval round did not execute the tool"; exit 1; }
grep -q "PHASE done tool-turn=completed slow-turn=aborted resume=completed" /tmp/dsh-smoke/spike.out || exit 1
exit "$rc"
INNER

docker cp /tmp/dsh-full-smoke-inner.sh "$CONTAINER:/tmp/dsh-smoke/run.sh"
docker exec -u 0 "$CONTAINER" chown 65534:65534 /tmp/dsh-smoke/run.sh
docker exec "$CONTAINER" chmod +x /tmp/dsh-smoke/run.sh

echo "== image size =="
uncompressed=$(docker image inspect "$IMAGE" --format '{{.Size}}')
echo "image_uncompressed_bytes=$uncompressed"
echo "image_uncompressed_human=$(numfmt --to=iec --suffix=B "$uncompressed")"
compressed=$(docker save "$IMAGE" | gzip -c | wc -c)
echo "image_compressed_gzip_bytes=$compressed"
echo "image_compressed_gzip_human=$(numfmt --to=iec --suffix=B "$compressed")"

echo "== idle RSS (default gateway, dsh not started) =="
docker run -d --name "${CONTAINER}-idle" "$IMAGE" >/dev/null
sleep 3
docker stats --no-stream --format 'idle_container_mem={{.MemUsage}}' "${CONTAINER}-idle" || true
docker rm -f "${CONTAINER}-idle" >/dev/null 2>&1 || true

echo "== run smoke =="
docker exec "$CONTAINER" /tmp/dsh-smoke/run.sh > /tmp/dsh-full-smoke.log 2>&1 &
exec_pid=$!
max_mem_mib=0
max_dsh_kb=0
for i in $(seq 1 30); do
  sleep 1
  kill -0 "$exec_pid" 2>/dev/null || break
  mem=$(docker stats --no-stream --format '{{.MemUsage}}' "$CONTAINER" 2>/dev/null | awk '{print $1}' || true)
  if [ -n "$mem" ]; then
    mib=$(awk -v v="$mem" 'BEGIN { if (v ~ /GiB$/) { sub(/GiB$/, "", v); printf "%.1f", v*1024 } else { sub(/MiB$/, "", v); printf "%.1f", v } }')
    if awk -v a="$mib" -v b="$max_mem_mib" 'BEGIN { exit !(a > b) }'; then
      max_mem_mib="$mib"
    fi
  fi
  dsh_rss=$(docker exec "$CONTAINER" sh -c '
    for p in /proc/[0-9]*; do
      cmd=$(tr "\0" " " < "$p/cmdline" 2>/dev/null) || continue
      case "$cmd" in
        *"@deepseek-ai/dsh/lib/bin.js"*) awk "/^VmRSS:/{print \$2}" "$p/status" ;;
      esac
    done' 2>/dev/null || true)
  for kb in $dsh_rss; do
    if [ "$kb" -gt "$max_dsh_kb" ]; then
      max_dsh_kb="$kb"
    fi
  done
done
echo "runtime_container_mem_peak_mib=$max_mem_mib"
echo "runtime_dsh_vmrss_peak_kb=$max_dsh_kb"
if ! wait "$exec_pid"; then
  cat /tmp/dsh-full-smoke.log
  exit 1
fi
cat /tmp/dsh-full-smoke.log
grep -q "PHASE done tool-turn=completed slow-turn=aborted resume=completed" /tmp/dsh-full-smoke.log
echo "SMOKE OK"
