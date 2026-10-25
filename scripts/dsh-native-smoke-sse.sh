#!/usr/bin/env bash
# Container-side reader for the A2A SSE stream in dsh-native-smoke-inner.sh.
# Not meant to run on a host.
#
# Reads the HTTP response (headers + `data:` events) from stdin and asserts:
#   - at least --min-deltas artifact-update events (provider text deltas);
#   - those deltas arrived before the task's final event.
# Prints SMOKE_SSE_OK on success. The caller pipes the TCP response into this
# script under `set -o pipefail`, so a dropped connection also fails the smoke.
set -euo pipefail

min_deltas=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --min-deltas)
      [ "$#" -ge 2 ] || { echo "SMOKE_FAIL: --min-deltas needs a value" >&2; exit 2; }
      min_deltas=$2
      shift 2
      ;;
    *)
      echo "SMOKE_FAIL: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

deltas=0
saw_final=0
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in
    'data: '*)
      event=${line#data: }
      case "$event" in
        *'"kind":"artifact-update"'*)
          deltas=$((deltas + 1))
          ;;
        *'"final":true'*)
          saw_final=1
          if [ "$deltas" -lt "$min_deltas" ]; then
            echo "SMOKE_FAIL: final event arrived after only $deltas delta(s), want >= $min_deltas" >&2
            exit 1
          fi
          ;;
      esac
      ;;
  esac
done

[ "$saw_final" -eq 1 ] || { echo "SMOKE_FAIL: SSE stream ended without a final event" >&2; exit 1; }
[ "$deltas" -ge "$min_deltas" ] || { echo "SMOKE_FAIL: saw $deltas delta(s), want >= $min_deltas" >&2; exit 1; }

echo "SMOKE_SSE_OK: deltas=$deltas first_delta_before_final=1"
