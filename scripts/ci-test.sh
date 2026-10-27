#!/usr/bin/env bash
# Bounded `zig build test` for CI.
#
# Zig 0.16's build runner only applies a per-test timeout when it is asked to
# (`--test-timeout`); otherwise `waitZigTest` waits on a running test forever
# (only the between-test response timeout defaults to 60 s). One blocking test
# therefore hangs the whole job: PR #16 ran for 5 h on macOS with no output.
# The reusable nullbuilder workflow also gives the caller no way to bound the
# step (a job that `uses:` a reusable workflow cannot set `timeout-minutes`,
# and the called workflow has no timeout input), so the bounds live here:
#
#   1. --test-timeout makes the build runner kill and NAME a hung test.
#   2. A wall-clock watchdog kills the run if anything else wedges.
#
# Env: NULLCLAW_CI_TEST_TIMEOUT - wall-clock seconds, default 2700 (45 min).
set -u

wall_clock="${NULLCLAW_CI_TEST_TIMEOUT:-2700}"
echo "ci-test: per-test timeout 300s, wall-clock watchdog ${wall_clock}s"

zig build test --summary all --test-timeout 300s &
zig_pid=$!

# The watchdog must not keep the pipe to `tee` open, so all its stdio is /dev/null.
# Git Bash on Windows has no pkill; `kill` alone is the fallback there.
kill_tree() {
    if command -v pkill >/dev/null 2>&1; then
        pkill "$1" -P "$zig_pid" 2>/dev/null
    fi
    kill "$1" "$zig_pid" 2>/dev/null
}

(
    sleep "$wall_clock"
    kill_tree -TERM
    sleep 10
    kill_tree -KILL
) </dev/null >/dev/null 2>&1 &
watchdog_pid=$!

wait "$zig_pid"
status=$?
kill "$watchdog_pid" 2>/dev/null
wait "$watchdog_pid" 2>/dev/null
if [ "$status" -eq 143 ] || [ "$status" -eq 137 ]; then
    echo "ci-test: the ${wall_clock}s wall-clock watchdog killed the test run" >&2
elif [ "$status" -ne 0 ]; then
    echo "ci-test: zig build test exited with status ${status}" >&2
fi
exit "$status"
