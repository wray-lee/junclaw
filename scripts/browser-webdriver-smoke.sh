#!/usr/bin/env bash
# Firefox/geckodriver WebDriver hardening smoke (WSL one-click).
#
# Real Firefox against a loopback test double. Probes covered:
#   (f) a normal HTTPS page loads through the session CONNECT proxy
#   (a) a page subresource to a private host reaches the proxy and is denied
#   (c) a click-opened new window to a private host is denied
#   (d) a form submission to a private host is denied
#   (e) a hostname whose answer mixes public and private addresses is denied
#       (rebinding-style, fail-closed mixed answers)
#
# Everything runs in one --network none namespace, so no external site is
# reachable. The helper's policy is a test double for these probes; junclaw's
# real proxy policy is covered by the Zig tests. Proxies, DNS and TLS all stay
# on loopback with placeholder names (site.test, blocked.test, ...).
#
# Usage (WSL with docker):
#   scripts/browser-webdriver-smoke.sh
#
# Env:
#   SMOKE_BROWSER_IMAGE  image with firefox-esr + geckodriver
#                        (default junclaw:browser-smoke; built from this tree
#                        when absent)
#   SMOKE_HELPER_IMAGE   python3 image for the loopback helper
#                        (default python:3-alpine)
#   KEEP=1               keep the containers and temp dir for debugging
#
# Not part of the CI must-run set: it needs real Firefox and docker, and the
# image build needs network. Host tools: docker and openssl. Run it locally.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

IMAGE=${SMOKE_BROWSER_IMAGE:-junclaw:browser-smoke}
HELPER_IMAGE=${SMOKE_HELPER_IMAGE:-python:3-alpine}
NAME=junclaw-browser-smoke-$$
HELPER_NAME=junclaw-browser-smoke-helper-$$
CID=
HELPER_ID=
TMP=$(mktemp -d)
PROXY_PORT=18080
SITE_PORT=18443

cleanup() {
  rc=$?
  trap - EXIT
  if [ "${KEEP:-0}" != 1 ]; then
    [ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1 || true
    [ -n "$HELPER_ID" ] && docker rm -f "$HELPER_ID" >/dev/null 2>&1 || true
    rm -rf "$TMP"
  else
    echo "kept containers $NAME $HELPER_NAME; temp dir $TMP" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "building $IMAGE from $REPO_ROOT (Dockerfile target browser)"
  docker build --target browser -t "$IMAGE" "$REPO_ROOT"
fi
if ! docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
  docker pull "$HELPER_IMAGE"
fi

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 1 \
  -subj "/CN=site.test" -addext "subjectAltName=DNS:site.test,IP:127.0.0.1" \
  >/dev/null 2>&1

HELPER_ID=$(docker run -d --rm --name "$HELPER_NAME" --network none \
  -v "$SCRIPT_DIR:/scripts:ro" -v "$TMP:/tmp/smoke" \
  --entrypoint python3 "$HELPER_IMAGE" \
  /scripts/browser-webdriver-smoke-helper.py \
  --proxy-port "$PROXY_PORT" --https-port "$SITE_PORT" \
  --cert /tmp/smoke/cert.pem --key /tmp/smoke/key.pem \
  --log /tmp/smoke/proxy.log --ready /tmp/smoke/ready)

ready=0
for _ in $(seq 1 100); do
  if [ -f "$TMP/ready" ]; then ready=1; break; fi
  sleep 0.1
done
if [ "$ready" != 1 ]; then
  echo "smoke helper did not start" >&2
  docker logs "$HELPER_ID" >&2 || true
  exit 1
fi

# The browser shares the helper's isolated namespace, so 127.0.0.1 is the
# helper's proxy and test site, and nothing else is reachable.
CID=$(docker run -d --rm --name "$NAME" \
  --network "container:$HELPER_NAME" --shm-size=256m \
  --entrypoint geckodriver "$IMAGE" --host 127.0.0.1 --port 4444)

# Firefox drops a content sandbox when user namespaces are unavailable; that
# warning is expected in a container (the container is the security boundary).
exec_in() { docker exec "$CID" "$@"; }

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
  docker logs "$HELPER_ID" >&2 || true
  exit 1
fi

# The same prefs junclaw writes into its one-shot profile. The two load-bearing
# proxy entries are failover_direct=false (never fall back to a direct
# connection) and allow_hijacking_localhost=true (localhost must reach the
# proxy and be refused, not bypass it).
SESSION_JSON=$(cat <<JSON
{"capabilities":{"alwaysMatch":{"browserName":"firefox","acceptInsecureCerts":true,"moz:firefoxOptions":{"args":["-headless"],"prefs":{
"network.proxy.type":1,
"network.proxy.http":"127.0.0.1",
"network.proxy.http_port":$PROXY_PORT,
"network.proxy.ssl":"127.0.0.1",
"network.proxy.ssl_port":$PROXY_PORT,
"network.proxy.ftp":"",
"network.proxy.socks":"",
"network.proxy.socks_remote_dns":true,
"network.proxy.no_proxies_on":"",
"network.proxy.allow_hijacking_localhost":true,
"network.proxy.failover_direct":false,
"network.proxy.autoconfig_url":"",
"network.trr.mode":5,
"network.dns.disablePrefetch":true,
"network.dns.disablePrefetchFromHTTPS":true,
"network.http.speculative-parallel-limit":0,
"network.predictor.enabled":false,
"network.predictor.enable-prefetch":false,
"network.http.http3.enable":false,
"network.http.altsvc.enabled":false,
"media.peerconnection.enabled":false,
"media.peerconnection.ice.proxy_only":true,
"dom.disable_open_during_load":false,
"network.captive-portal-service.enabled":false,
"network.connectivity-service.enabled":false
}}}}}
JSON
)

session=$(exec_in curl -fsS -X POST http://127.0.0.1:4444/session \
  -H 'Content-Type: application/json' -d "$SESSION_JSON")
sid=$(printf '%s' "$session" | sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p')
if [ -z "$sid" ]; then
  echo "session not created: $session" >&2
  docker logs "$CID" >&2 || true
  docker logs "$HELPER_ID" >&2 || true
  exit 1
fi
echo "session $sid"

nav() {
  exec_in curl -sS --max-time 30 -X POST \
    "http://127.0.0.1:4444/session/$sid/url" \
    -H 'Content-Type: application/json' -d "{\"url\":\"$1\"}" >/dev/null || true
}

click() {
  local selector=$1 element
  element=$(exec_in curl -fsS -X POST \
    "http://127.0.0.1:4444/session/$sid/element" \
    -H 'Content-Type: application/json' \
    -d "{\"using\":\"css selector\",\"value\":\"$selector\"}" |
    sed -n 's/.*"element-6066-11e4-a52e-4f735466cecf":"\([^"]*\)".*/\1/p')
  if [ -z "$element" ]; then
    echo "element $selector not found" >&2
    exit 1
  fi
  exec_in curl -sS --max-time 30 -X POST \
    "http://127.0.0.1:4444/session/$sid/element/$element/click" \
    -H 'Content-Type: application/json' -d '{}' >/dev/null || true
}

wait_log() {
  local pattern=$1 what=$2
  for _ in $(seq 1 150); do
    if grep -Fq -- "$pattern" "$TMP/proxy.log"; then return 0; fi
    sleep 0.1
  done
  echo "missing proxy log entry for $what: $pattern" >&2
  sed -n '1,200p' "$TMP/proxy.log" >&2 || true
  exit 1
}

# (f) Normal HTTPS page through the proxy.
nav "https://site.test:$SITE_PORT/ok"
title=$(exec_in curl -fsS "http://127.0.0.1:4444/session/$sid/title")
source=$(exec_in curl -fsS "http://127.0.0.1:4444/session/$sid/source")
echo "title: $title"
case "$title" in *smoke-ok*) ;; *) echo "unexpected title: $title" >&2; exit 1 ;; esac
case "$source" in *SMOKEOK4F2A*) ;; *) echo "page marker missing" >&2; exit 1 ;; esac
wait_log "CONNECT site.test:$SITE_PORT allow allowlisted" "normal HTTPS page"

# (a) Subresource to a private host must reach the proxy and be denied.
nav "https://site.test:$SITE_PORT/subresource"
wait_log "CONNECT blocked.test:443 deny private-address" "private subresource"

# (c) New window opened by a click must reach the proxy and be denied.
nav "https://site.test:$SITE_PORT/popup"
click "#popup"
wait_log "CONNECT popup.test:443 deny private-address" "popup target"

# (d) Form submission must reach the proxy and be denied.
nav "https://site.test:$SITE_PORT/form"
click "#submit"
wait_log "CONNECT form.test:443 deny private-address" "form target"

# (e) Mixed public/private answer fails closed before any connection.
nav "https://rebind.test:$SITE_PORT/"
wait_log "CONNECT rebind.test:$SITE_PORT deny mixed-public-private" "rebinding-style target"

exec_in curl -fsS -X DELETE "http://127.0.0.1:4444/session/$sid" >/dev/null
echo "browser hardening smoke passed"
