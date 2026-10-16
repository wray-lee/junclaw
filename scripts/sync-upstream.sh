#!/usr/bin/env bash
# Merge upstream nullclaw into this fork. Never rebases.
set -euo pipefail

upstream_url="${UPSTREAM_URL:-https://github.com/nullclaw/nullclaw.git}"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$upstream_url"
git fetch upstream
git merge --no-edit upstream/main
zig fmt --check src/

cat <<'MSG'

Merged upstream/main. Next steps:
  - Resolve conflicts: keep upstream where it has landed the same fix; when an
    upstream PR duplicates a fork patch, drop the fork patch.
  - zig build test --summary all
MSG
