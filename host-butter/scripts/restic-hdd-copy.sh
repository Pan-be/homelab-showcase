#!/bin/bash
# Daily copy of the restic repos from butter's SSD to its HDD (second local copy).
# rsync --ignore-existing: restic never rewrites a repo file (names are content
# hashes), so only new files are copied and nothing on the HDD is overwritten or
# deleted; a file corrupted on the SSD can't spoil the HDD copy. Deletions after
# a prune are mirrored by restic-prune.sh. Needs no repo password.
# Run as user restic by restic-hdd-copy.timer (07:00 UTC, after the 05:30
# Serverus and 05:45 garlic backups).
# Repos: one per client host. A repo that doesn't exist yet is skipped; a failure
# in one repo doesn't stop the others, but the run still ends as FAILED.
set -uo pipefail
REPOS=(serverus garlic)
log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"; }
alert() {
    topic=$(cat /etc/restic-ntfy-topic 2>/dev/null) && [ -n "$topic" ] && \
        curl -fsS -m 20 -H "Title: butter: HDD copy FAILED" -H "Priority: high" -H "Tags: warning" \
            -d "$1 See: journalctl -u restic-hdd-copy" "https://ntfy.sh/$topic" >/dev/null
}
fail() { log "FAILED: $1"; alert "$1"; exit 1; }

mountpoint -q /srv/restic-hdd || fail "HDD not mounted at /srv/restic-hdd."

errors=()
for name in "${REPOS[@]}"; do
    SRC=/srv/restic/$name
    DST=/srv/restic-hdd/$name
    if [ ! -d "$SRC" ]; then
        log "$name: no repo at $SRC yet, skipped"; continue
    fi
    # Wait while the client holds a lock (a backup is running), up to 2 hours.
    for _ in $(seq 24); do
        [ -z "$(ls -A "$SRC/locks")" ] && break
        log "$name: repo locked, waiting 5 min"; sleep 300
    done
    if [ -n "$(ls -A "$SRC/locks")" ]; then
        log "$name: FAILED, still locked after 2 h (stale lock?)"
        errors+=("$name: repo still locked after 2 h (stale lock?)."); continue
    fi
    mkdir -p "$DST"
    if rsync -a --ignore-existing --exclude='/locks/*' --stats "$SRC/" "$DST/" \
        | grep -E "Number of (regular )?files transferred|Total transferred file size"; then
        log "$name: copy OK, HDD: $(du -sh "$DST" | cut -f1)"
    else
        log "$name: FAILED, rsync failed"
        errors+=("$name: rsync failed.")
    fi
done

[ ${#errors[@]} -eq 0 ] || fail "${errors[*]}"
log "all repos copied"
