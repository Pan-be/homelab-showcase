#!/bin/bash
# Daily copy of the restic repo files from butter's SSD to Backblaze B2.
# rclone copy --immutable: only adds new files, never deletes, and fails if a
# file already in B2 differs (restic never rewrites a repo file). The bucket has
# Object Lock (compliance, 30 days), so not even this key can delete recent
# files. Deletions after a prune are mirrored by restic-prune.sh. Needs no repo
# password. Run as user restic by restic-cloud-copy.timer (07:30 UTC, after the
# HDD copy). Success/failure goes to healthchecks.io (butter-cloud-copy -> ntfy).
# Repos: one per client host, each under its own prefix in the bucket. A repo
# that doesn't exist yet is skipped; a failure in one repo doesn't stop the
# others, but the run still reports /fail.
set -uo pipefail
REPOS=(serverus garlic)
BUCKET=$(cat /etc/restic-cloud-bucket)
HC=$(cat /etc/restic-cloud-hc-url)
RC=(rclone --config /etc/restic-rclone.conf)
log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"; }
hc() { curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "$2" "$HC$1" || log "healthchecks ping failed"; }

hc /start ""
errors=()
summary=()
for name in "${REPOS[@]}"; do
    SRC=/srv/restic/$name
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
    if OUT=$("${RC[@]}" copy "$SRC" "b2cloud:$BUCKET/$name" --exclude "locks/**" \
          --immutable --fast-list --transfers 4 -q 2>&1); then
        SIZE=$("${RC[@]}" size "b2cloud:$BUCKET/$name" --fast-list 2>/dev/null | tr '\n' ' ')
        log "$name: copy OK, B2: $SIZE"
        summary+=("$name: $SIZE")
    else
        log "$name: FAILED, rclone copy failed: $(echo "$OUT" | tail -3)"
        errors+=("$name: rclone copy failed: $(echo "$OUT" | tail -3)")
    fi
done

if [ ${#errors[@]} -ne 0 ]; then
    log "FAILED: ${errors[*]}"
    hc /fail "${errors[*]} See: journalctl -u restic-cloud-copy"
    exit 1
fi
log "all repos copied"
hc "" "copy OK, B2: ${summary[*]}"
