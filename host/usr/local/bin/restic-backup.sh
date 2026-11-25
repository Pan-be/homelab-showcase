#!/bin/bash
# Daily restic backup of Serverus to butter (rest-server --append-only, over
# Tailscale). Run as root by restic-backup.timer. Secrets and path lists live in
# /root/.config/restic/. On failure or an incomplete snapshot: ntfy alert.
# Minecraft comes from the newest backup_crafty.sh snapshot (weekly, taken with
# Crafty stopped, so the world is consistent), not from the live ~/crafty.
# Pruning old snapshots can't be done from here (append-only); run it on butter.

set -uo pipefail
umask 077

CONF=/root/.config/restic
export RESTIC_REPOSITORY_FILE=$CONF/repo
export RESTIC_PASSWORD_FILE=$CONF/repo-pass
export RESTIC_CACHE_DIR=/root/.cache/restic

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"; }

alert() {
    local topic
    if ! topic=$(cat "$CONF/ntfy-topic" 2>/dev/null) || [ -z "$topic" ]; then
        log "no ntfy topic, alert not sent"; return 0
    fi
    curl -fsS -m 20 -H "Title: $1" -H "Priority: high" -H "Tags: warning" \
        -d "$2" "https://ntfy.sh/$topic" >/dev/null || log "ntfy alert could not be sent"
}

EXTRA=()
CRAFTY=$(readlink -f /mnt/storage/crafty-backups/latest 2>/dev/null || true)
if [ -n "$CRAFTY" ] && [ -d "$CRAFTY" ]; then
    EXTRA+=("$CRAFTY")
    log "Minecraft from $CRAFTY"
else
    log "WARN no Crafty snapshot found, Minecraft skipped"
    alert "Serverus backup: Minecraft skipped" "No Crafty snapshot under /mnt/storage/crafty-backups/latest (RAID not mounted?). The rest is being backed up."
fi

log "backup start"
restic backup --files-from "$CONF/paths" --exclude-file "$CONF/excludes" \
    --tag daily "${EXTRA[@]}"
rc=$?

case $rc in
    0) log "backup OK" ;;
    3) log "backup INCOMPLETE (some files unreadable, snapshot saved)"
       alert "Serverus backup incomplete" "restic saved a snapshot but could not read some files. See: journalctl -u restic-backup" ;;
    *) log "backup FAILED (exit $rc)"
       alert "Serverus backup FAILED" "restic exit $rc, no snapshot. See: journalctl -u restic-backup"
       exit "$rc" ;;
esac

# Sundays: verify the repo structure plus a random 5% of the data.
if [ "$(date -u +%u)" = 7 ]; then
    log "weekly check start"
    if restic check --read-data-subset=5%; then
        log "check OK"
    else
        log "check FAILED"
        alert "Serverus backup: repo check FAILED" "restic check on butter reported errors. See: journalctl -u restic-backup"
        exit 1
    fi
fi
exit 0
