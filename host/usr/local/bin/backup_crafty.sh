#!/bin/bash
# Daily backup of ~/crafty to the RAID, with history (root cron, 08:00 UTC).
# Stops Crafty for a consistent copy and ALWAYS starts it again (EXIT trap),
# even if rsync fails. Snapshots: /mnt/storage/crafty-backups/snapshots/<date>,
# unchanged files hardlinked to the previous one (rsync --link-dest), so each
# day only costs what changed. Keeps the newest $KEEP snapshots.
# Replaces the old mirror version (rsync --delete into one dir, no history,
# Crafty left stopped on failure). Changed 2026-10-03.

SRC=/home/admin/crafty/
ROOT=/mnt/storage/crafty-backups
SNAPS=$ROOT/snapshots
LOG=/var/log/backup_crafty.log
KEEP=7
TODAY=$(date -u +%Y-%m-%d)

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if ! mountpoint -q /mnt/storage; then
    log "Backup disk NOT mounted — aborting (Crafty not touched)"
    exit 1
fi

WAS_RUNNING=$(docker inspect -f '{{.State.Running}}' crafty 2>/dev/null || echo false)

finish() {
    rc=$?
    if [ "$WAS_RUNNING" = "true" ]; then
        docker start crafty >> "$LOG" 2>&1 || log "ERROR: docker start crafty failed"
    fi
    if [ $rc -eq 0 ]; then log "Backup finished OK"; else log "Backup FAILED (exit $rc)"; fi
    echo "------------------------------------" >> "$LOG"
}
trap finish EXIT
set -euo pipefail

log "Backup started (snapshot $TODAY)"
mkdir -p "$SNAPS"

[ "$WAS_RUNNING" = "true" ] && docker stop crafty >> "$LOG" 2>&1

LINK=()
[ -d "$ROOT/latest/" ] && LINK=(--link-dest="$ROOT/latest/")

rm -rf "$SNAPS"/*.partial
rsync -a --delete "${LINK[@]}" "$SRC" "$SNAPS/$TODAY.partial/" >> "$LOG" 2>&1
rm -rf "$SNAPS/$TODAY"
mv "$SNAPS/$TODAY.partial" "$SNAPS/$TODAY"
ln -sfn "snapshots/$TODAY" "$ROOT/latest"
log "Snapshot $SNAPS/$TODAY written"

# Retention: keep the newest $KEEP dated snapshots.
ls -1d "$SNAPS"/20??-??-?? 2>/dev/null | sort | head -n -"$KEEP" | while read -r old; do
    rm -rf "$old" && log "Removed old snapshot $old"
done
