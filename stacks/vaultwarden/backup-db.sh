#!/bin/bash
# Daily consistent backup of the Vaultwarden DB, before restic's 05:30 UTC run.
# `vaultwarden backup` uses SQLite's online backup API and writes
# data/db_YYYYMMDD_HHMMSS.sqlite3; the copy is integrity-checked, moved to
# DEST and mirrored to the RAID (different physical disk). The vault items are
# end-to-end encrypted with Konrad's master password, the DB holds no plaintext.
# On any failure: ntfy push to Konrad only (topic file of media-maintenance).
# Cron (admin): 10 5 * * * /opt/vaultwarden/backup-db.sh >> /opt/vaultwarden/backups/backup.log 2>&1

set -euo pipefail
umask 077

CONTAINER=vaultwarden
DATA=/opt/vaultwarden/data
DEST=/opt/vaultwarden/backups
MIRROR=/mnt/storage/vaultwarden-backups
KEEP_DAYS=14
NTFY_TOPIC_FILE=/home/admin/.config/media-maintenance/ntfy_topic

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"; }

alert() {
    curl -fsS -m 20 -H "Title: Vaultwarden: DB backup FAILED" -H "Priority: urgent" -H "Tags: warning" \
        -d "$1" "https://ntfy.sh/$(cat "$NTFY_TOPIC_FILE")" > /dev/null || log "ntfy alert could not be sent"
}

trap 'rc=$?; log "FAILED (exit $rc, line $LINENO)"; alert "Daily Vaultwarden DB backup failed on Serverus (line $LINENO). See $DEST/backup.log."; exit $rc' ERR

mkdir -p "$DEST"
log "start"

out=$(docker exec "$CONTAINER" /vaultwarden backup)
file=$(echo "$out" | grep -oE "db_[0-9]{8}_[0-9]{6}\.sqlite3")
mv "$DATA/$file" "$DEST/$file"
chmod 600 "$DEST/$file"

python3 -I - "$DEST/$file" <<'PY'
import sqlite3, sys
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
ok = c.execute("PRAGMA integrity_check").fetchone()[0]
if ok != "ok":
    sys.exit(f"integrity_check: {ok}")
print("users=%d ciphers=%d" % (c.execute("SELECT COUNT(*) FROM users").fetchone()[0],
                               c.execute("SELECT COUNT(*) FROM ciphers").fetchone()[0]))
PY
gzip -9f "$DEST/$file"
log "saved $DEST/$file.gz ($(du -h "$DEST/$file.gz" | cut -f1))"

if mountpoint -q /mnt/storage; then
    mkdir -p "$MIRROR"
    cp -p "$DEST/$file.gz" "$MIRROR/"
    find "$MIRROR" -name 'db_*.sqlite3.gz' -mtime +"$KEEP_DAYS" -delete
    log "mirrored to $MIRROR"
else
    log "WARN /mnt/storage not mounted, mirror skipped"
    alert "Vaultwarden DB backup saved locally, but /mnt/storage is not mounted, so no mirror copy."
fi

find "$DEST" -name 'db_*.sqlite3.gz' -mtime +"$KEEP_DAYS" -delete
log "done"
