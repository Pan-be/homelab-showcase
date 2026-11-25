#!/bin/bash
# Nightly vault tidy: lint the vault, let a headless Claude session tidy the board and fix mechanical lint,
# then commit and push. DRY_RUN=1 changes nothing and prints the report instead.
set -uo pipefail
export TZ="${TZ:-Europe/Warsaw}"
VAULT="$HOME/AI-Brain"
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$HOME/.local/state/vault-tidy"
mkdir -p "$STATE/runs"
DRY="${DRY_RUN:-0}"
STAMP="$(date +%F_%H%M)"
LOG="$STATE/runs/$STAMP$([ "$DRY" = 1 ] && echo -dry).log"
MAX_FAILS=3

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG" >&2; }
fail() {
  log "FAIL: $*"
  [ "$DRY" = 1 ] || echo $(( $(cat "$STATE/fails" 2>/dev/null || echo 0) + 1 )) > "$STATE/fails"
  exit 1
}

exec 9>"${XDG_RUNTIME_DIR:-/tmp}/vault-tidy.lock"
flock -n 9 || { log "another run holds the lock, skipping"; exit 0; }

fails=$(cat "$STATE/fails" 2>/dev/null || echo 0)
if [ "$DRY" != 1 ] && [ "$fails" -ge "$MAX_FAILS" ]; then
  log "SKIP: $fails failed runs in a row; check $STATE/runs and delete $STATE/fails to re-enable"
  exit 1
fi

cd "$VAULT" || fail "no vault at $VAULT"
[ -z "$(git status --porcelain)" ] || fail "vault working tree not clean, not touching it: $(git status --porcelain | head -5 | tr '\n' ' ')"
# One retry: a transient clash (another fetch in the same second, a network blip) shouldn't cost the night.
if ! PULL_ERR="$(git pull -q --ff-only 2>&1)"; then
  log "git pull failed, retrying in 30 s: $(echo "$PULL_ERR" | tail -2 | tr '\n' ' ')"
  sleep 30
  PULL_ERR="$(git pull -q --ff-only 2>&1)" \
    || fail "git pull --ff-only failed twice: $(echo "$PULL_ERR" | tail -2 | tr '\n' ' '); left for an interactive session"
fi
HEAD_BEFORE="$(git rev-parse HEAD)"

LINT="$(python3 -I "$HERE/lint.py" "$VAULT")" || fail "lint.py failed"
SINCE="$(cat "$STATE/last_ok" 2>/dev/null || date -d '26 hours ago' '+%F %T')"

# Pan-be: weekly (Mondays, or PANBE_CHECK=1) read-only version table, staging vs production.
# A failure here is reported, never fatal for the tidy run.
PANBE="not checked this run (weekly, Mondays)"
if [ "$(date +%u)" = 1 ] || [ "${PANBE_CHECK:-0}" = 1 ]; then
  if PANBE_OUT="$(timeout 300 "$HOME/dev/pan-be/tools/versions.sh" 2>&1)"; then
    PANBE="$PANBE_OUT"
  else
    PANBE="versions.sh FAILED (exit $?): $(echo "$PANBE_OUT" | tail -3)"
  fi
  log "pan-be version check ran"
fi

if [ "$DRY" = 1 ]; then
  MODE="dry run"
  MODE_RULES="**DRY RUN: change no file at all** (you have no edit tools). Skip writing the report into the vault and the daily note; put the full report in your final message instead, with each board move and lint fix phrased as what you would do."
  TOOLS="Read,Glob,Grep,Bash"
  ALLOW=()
else
  MODE="live"
  MODE_RULES=""
  TOOLS="Read,Edit,Write,Glob,Grep,Bash"
  ALLOW=("Edit(~/AI-Brain/**)" "Write(~/AI-Brain/**)")
fi

PROMPT="$(TODAY="$(date +%F)" NOW="$(date +%H:%M)" YESTERDAY="$(date -d yesterday +%F)" SINCE="$SINCE" \
  MODE="$MODE" MODE_RULES="$MODE_RULES" LINT="$LINT" PANBE="$PANBE" python3 -I -c '
import os, sys
s = open(sys.argv[1], encoding="utf-8").read()
for k in ("TODAY", "NOW", "YESTERDAY", "SINCE", "MODE", "MODE_RULES", "LINT", "PANBE"):
    s = s.replace("{{" + k + "}}", os.environ[k])
print(s)' "$HERE/prompt.md")" || fail "prompt render failed"

log "start ($MODE), since $SINCE"
JSONL="${LOG%.log}.jsonl"
timeout 45m "$HOME/.local/bin/claude" -p "$PROMPT" \
  --model sonnet \
  --tools "$TOOLS" \
  --allowedTools "Read(~/AI-Brain/**)" Glob Grep \
                 "Bash(git log:*)" "Bash(git show:*)" "Bash(git diff:*)" "Bash(git blame:*)" "${ALLOW[@]}" \
  --permission-mode dontAsk --permission-prompts none \
  --no-session-persistence --output-format stream-json --verbose </dev/null >"$JSONL" 2>>"$LOG"
RC=$?
# final report + any denied tool calls into the readable log
python3 -I "$HERE/report.py" "$JSONL" >>"$LOG" 2>&1
[ "$RC" = 0 ] || fail "claude exited $RC (see log above)"

if [ "$DRY" = 1 ]; then
  [ -z "$(git status --porcelain)" ] || fail "dry run left changes in the vault: $(git status --porcelain | tr '\n' ' ')"
  log "dry run done, report above"
  exit 0
fi

[ "$(git rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail "HEAD moved during the run; not committing"
CHANGED="$(git status --porcelain)"
if [ -n "$CHANGED" ]; then
  if echo "$CHANGED" | awk '{print $NF}' | grep -qv '\.md"\?$'; then
    fail "non-Markdown files changed, leaving them uncommitted for review: $(echo "$CHANGED" | tr '\n' ' ')"
  fi
  git add -A
  git commit -q -m "Night tidy $(date +%F): board and lint

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" >>"$LOG" 2>&1 || fail "git commit failed"
  git push -q >>"$LOG" 2>&1 || fail "git push failed; commit $(git rev-parse --short HEAD) is local only"
  log "committed and pushed $(git rev-parse --short HEAD): $(echo "$CHANGED" | wc -l) file(s)"
else
  log "nothing to change"
fi

date '+%F %T' > "$STATE/last_ok"
rm -f "$STATE/fails"
ls -1t "$STATE"/runs/*.log 2>/dev/null | tail -n +61 | xargs -r rm -f
ls -1t "$STATE"/runs/*.jsonl 2>/dev/null | tail -n +15 | xargs -r rm -f
log "done"
