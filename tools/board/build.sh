#!/bin/sh
# Rebuild the board from Active Priorities as it is on origin/main (the vault's working tree is never touched).
set -eu
VAULT="$HOME/AI-Brain"
OUT="${BOARD_OUT:-/opt/board/www}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/board-build.lock"
flock -n 9 || exit 0
# --no-write-fetch-head: never touch FETCH_HEAD, which a concurrent `git pull` (vault tidy, sessions) reads;
# both timers once fired in the same second and the pull failed with "Cannot fast-forward to multiple branches".
git -C "$VAULT" fetch --no-write-fetch-head -q origin main
git -C "$VAULT" show "origin/main:Active Priorities.md" > "$TMP"
python3 -I "$HERE/board.py" "$TMP" "$OUT/index.html" --full --bg="$HERE/bg.jpg"
python3 -I "$HERE/board.py" "$TMP" "$OUT/embed.html" --full --embed
