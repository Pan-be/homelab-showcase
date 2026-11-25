#!/bin/bash
# Manual pruning of one client's restic repo. Runs ON butter, against the local
# repo files, because the clients can only append (rest-server --append-only).
# The repo password is typed in each time and never stored on butter; each
# repo has its own password.
# Review the snapshot list before confirming: a compromised client can't
# delete anything, but it could add fake snapshots to push real ones out of
# the keep policy. Afterwards the HDD copy is mirrored (deletions included)
# and checked too.
# Usage: sudo restic-prune.sh [serverus|garlic]   (default serverus;
#        not around 05:30, 05:45, 07:00 or 07:30 UTC)

set -euo pipefail
NAME=${1:-serverus}
case $NAME in
    serverus|garlic) ;;
    *) echo "unknown repo '$NAME' (serverus or garlic)"; exit 1 ;;
esac
REPO=/srv/restic/$NAME
HDD=/srv/restic-hdd/$NAME
KEEP=(--keep-daily 14 --keep-weekly 8 --keep-monthly 12)
# Group by host+tags, not paths: the Crafty snapshot path changes every week
# (and the Docker volumes path after the NVMe move), and grouping by paths
# would make each of those its own group that never gets pruned.
GROUP=(--group-by host,tags)

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ -d "$REPO" ] || { echo "no repo at $REPO"; exit 1; }
read -rsp "restic repo password for $NAME: " RESTIC_PASSWORD; echo
export RESTIC_PASSWORD

r() { runuser -u restic -- restic -r "$REPO" --no-cache "$@"; }

echo "== snapshots ($NAME)"
r snapshots
read -rp "All snapshots look genuine (host $NAME, expected dates)? [y/N] " a
[ "$a" = y ] || { echo "stopped"; exit 1; }

echo "== dry run"
r forget "${GROUP[@]}" "${KEEP[@]}" --dry-run
read -rp "Forget and prune for real? [y/N] " a
[ "$a" = y ] || { echo "stopped"; exit 1; }

echo "== forget + prune"
r forget "${GROUP[@]}" "${KEEP[@]}" --prune

echo "== check (SSD)"
r check

if mountpoint -q /srv/restic-hdd; then
    echo "== mirror to HDD (with deletions)"
    runuser -u restic -- rsync -a --delete --exclude='/locks/*' "$REPO/" "$HDD/"
    echo "== check (HDD copy)"
    runuser -u restic -- restic -r "$HDD" --no-cache check
else
    echo "WARN /srv/restic-hdd not mounted, HDD copy not mirrored or checked"
fi

echo "== mirror to B2 (deletions become hidden versions; files under Object Lock stay)"
BUCKET=$(cat /etc/restic-cloud-bucket)
runuser -u restic -- rclone --config /etc/restic-rclone.conf sync "$REPO" "b2cloud:$BUCKET/$NAME" \
    --exclude "locks/**" --fast-list || echo "WARN B2 mirror reported errors (files under Object Lock can't be deleted yet; fine)"

echo "== disk"
du -sh "$REPO" "$HDD" 2>/dev/null || true
df -h /srv/restic /srv/restic-hdd | tail -2
