#!/usr/bin/env bash
# Firefox/geckodriver WebDriver smoke (WSL one-click).
#
# Starts a throwaway container from the Dockerfile `browser` target with
# --network none and checks the loopback WebDriver path the junclaw backend
# uses: geckodriver boots, creates a headless Firefox session, navigates to a
# local file page, reads title and source, then deletes the session. With no
# network in the container, no external site can be reached.
#
# Usage (WSL with docker):
#   scripts/browser-webdriver-smoke.sh
#
# Env:
#   SMOKE_BROWSER_IMAGE  image with nullclaw + firefox-esr + geckodriver
#                        (default junclaw:browser-smoke; built from this tree
#                        when absent)
#   KEEP=1               keep the container for debugging
#
# Not part of the CI must-run set: it needs the real Firefox binary and docker.
# Run it locally.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

IMAGE=${SMOKE_BROWSER_IMAGE:-junclaw:browser-smoke}
NAME=junclaw-browser-smoke-$$
CID=

cleanup() {
  rc=$?
  if [ -n "$CID" ] && [ "${KEEP:-0}" != 1 ]; then docker rm -f "$CID" >/dev/null 2>&1 || true; fi
  exit "$rc"
}
trap cleanup EXIT

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "building $IMAGE from $REPO_ROOT (Dockerfile target browser)"
  docker build --target browser -t "$IMAGE" "$REPO_ROOT"
fi

# The image entrypoint is nullclaw, so exec runs inside the browser container.
exec_in() { docker exec "$CID" "$@"; }

CID=$(docker run -d --rm --name "$NAME" --network none --shm-size=256m \
  --entrypoint geckodriver "$IMAGE" --host 127.0.0.1 --port 4444)

# Firefox drops a content sandbox when user namespaces are unavailable; that
# warning is expected in a container (the container is the security boundary).

uid=$(exec_in id -u)
[ "$uid" = 65534 ] || { echo "default user is $uid, want 65534" >&2; exit 1; }

ready=0
for _ in $(seq 1 50); do
  if exec_in curl -fsS http://127.0.0.1:4444/status >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.2
done
if [ "$ready" != 1 ]; then
  echo "geckodriver did not start" >&2
  docker logs "$CID" >&2 || true
  exit 1
fi
exec_in curl -fsS http://127.0.0.1:4444/status
echo

# Local page only; the container has no network anyway.
exec_in sh -c 'printf "%s" "<html><head><title>smoke-ok</title></head><body><h1 id=\"m\">SMOKEOK4F2A</h1></body></html>" > /tmp/browser-smoke.html'

session=$(exec_in curl -fsS -X POST http://127.0.0.1:4444/session \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":{"alwaysMatch":{"browserName":"firefox","moz:firefoxOptions":{"args":["-headless"]}}}}')
sid=$(printf '%s' "$session" | sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p')
if [ -z "$sid" ]; then
  echo "session not created: $session" >&2
  docker logs "$CID" >&2 || true
  exit 1
fi
echo "session $sid"

exec_in curl -fsS -X POST "http://127.0.0.1:4444/session/$sid/url" \
  -H 'Content-Type: application/json' -d '{"url":"file:///tmp/browser-smoke.html"}'
echo
title=$(exec_in curl -fsS "http://127.0.0.1:4444/session/$sid/title")
source=$(exec_in curl -fsS "http://127.0.0.1:4444/session/$sid/source")
echo "title: $title"
echo "source: $source"
case "$title" in *smoke-ok*) ;; *) echo "unexpected title" >&2; exit 1 ;; esac
case "$source" in *SMOKEOK4F2A*) ;; *) echo "page marker missing" >&2; exit 1 ;; esac

exec_in curl -fsS -X DELETE "http://127.0.0.1:4444/session/$sid"
echo

gone=0
for _ in $(seq 1 50); do
  if ! exec_in pgrep -x firefox-esr >/dev/null 2>&1; then gone=1; break; fi
  sleep 0.2
done
[ "$gone" = 1 ] || { echo "firefox-esr still running after session delete" >&2; exit 1; }

# geckodriver must survive the session lifecycle for the next call.
exec_in curl -fsS http://127.0.0.1:4444/status
echo
echo "PASS: geckodriver + headless Firefox WebDriver session (offline)"
