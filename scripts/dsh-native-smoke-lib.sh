#!/usr/bin/env bash
# Shared runner for the dsh-native acceptance smokes. Source this file; do not
# run it. The caller writes a config.json and calls:
#
#   smoke_run <config.json> <mock:0|1> <docker-network>
#
# Required env: JUNCLAW_BIN (static Linux binary), SMOKE_IMAGE.
# Optional env: SMOKE_TOKEN (default test-token), SMOKE_MOCK_BIN (mock=1),
#               KEEP=1 (keep container and logs), SMOKE_KEEP_WORK=1.

SMOKE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SMOKE_CONTAINER="junclaw-dsh-native-smoke-$$"

smoke_cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then
    echo "smoke: kept container $SMOKE_CONTAINER (KEEP=1)" >&2
    return
  fi
  docker rm -f "$SMOKE_CONTAINER" >/dev/null 2>&1 || true
}
trap smoke_cleanup EXIT INT TERM

smoke_die() {
  echo "SMOKE_FAIL: $*" >&2
  exit 1
}

# smoke_run <config.json> <mock:0|1> <docker-network>
smoke_run() {
  local config=$1 mock=$2 network=$3
  local image=${SMOKE_IMAGE:-nc-zig:0.16.0}
  local token=${SMOKE_TOKEN:-test-token}
  local work log rc

  case "$token" in
    *[!A-Za-z0-9._-]*) smoke_die "SMOKE_TOKEN must contain only letters, digits, dot, underscore or dash" ;;
  esac
  [ -f "${JUNCLAW_BIN:-}" ] || smoke_die "JUNCLAW_BIN is not a file: ${JUNCLAW_BIN:-<unset>}"
  [ -f "$config" ] || smoke_die "config not found: $config"
  if [ "$mock" = "1" ]; then
    [ -f "${SMOKE_MOCK_BIN:-}" ] || smoke_die "SMOKE_MOCK_BIN is not a file: ${SMOKE_MOCK_BIN:-<unset>}"
  fi
  docker image inspect "$image" >/dev/null 2>&1 || smoke_die "docker image not found: $image"

  work=$(mktemp -d "${TMPDIR:-/tmp}/dsh-native-smoke.XXXXXX")
  log="$work/smoke.log"

  docker rm -f "$SMOKE_CONTAINER" >/dev/null 2>&1 || true
  # BusyBox sleep (the nc-zig image) has no "infinity"; a day is plenty.
  docker run -d --name "$SMOKE_CONTAINER" --network "$network" --entrypoint sleep "$image" 86400 >/dev/null
  docker cp "$JUNCLAW_BIN" "$SMOKE_CONTAINER:/tmp/nullclaw"
  docker cp "$config" "$SMOKE_CONTAINER:/tmp/smoke-config.json"
  docker cp "$SMOKE_DIR/dsh-native-smoke-inner.sh" "$SMOKE_CONTAINER:/tmp/smoke-inner.sh"
  docker exec "$SMOKE_CONTAINER" chmod +x /tmp/nullclaw /tmp/smoke-inner.sh
  if [ "$mock" = "1" ]; then
    docker cp "$SMOKE_MOCK_BIN" "$SMOKE_CONTAINER:/tmp/smoke-mock"
    docker exec "$SMOKE_CONTAINER" chmod +x /tmp/smoke-mock
  fi

  set +e
  docker exec \
    -e SMOKE_MOCK="$mock" \
    -e SMOKE_TOKEN="$token" \
    -e SMOKE_DATA=/smoke-data \
    "$SMOKE_CONTAINER" /bin/bash /tmp/smoke-inner.sh 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e

  if [ "$rc" -ne 0 ] || ! grep -q '^SMOKE_OK$' "$log"; then
    echo "smoke: failed (exit $rc); container logs:" >&2
    docker exec "$SMOKE_CONTAINER" /bin/sh -c \
      'echo ---gateway.log---; tail -n 60 /tmp/gateway.log 2>/dev/null; echo ---mock.log---; grep -c "^REQ " /tmp/mock.log 2>/dev/null; echo ---mock.out---; head -c 2000 /tmp/mock.out 2>/dev/null' >&2 || true
    echo "smoke: host log kept at $log" >&2
    exit 1
  fi

  if [ "${SMOKE_KEEP_WORK:-0}" != "1" ]; then
    rm -rf "$work"
  else
    echo "smoke: log kept at $log" >&2
  fi
  echo "SMOKE_OK"
}
