#!/usr/bin/env bash
# Daily restic backup of garlic (Forgejo + host config) to butter's rest-server.
# Run on garlic as: sudo bash install-restic-garlic.sh
# Written 2026-11-09 on Serverus (card #63), modelled on Serverus's restic-backup.sh.
#
# Forgejo's SQLite DB is copied with sqlite3 .backup (consistent, online) and
# integrity-checked before restic runs; the live DB files are excluded.
# Repos are also push-mirrored to butter's Forgejo; this backup adds users,
# keys, settings and mirror config.
#
# Before running: on butter, rest-server user `garlic` exists (htpasswd), and the
# Tailscale policy grants garlic -> butter tcp:8000.
# Secrets: typed or generated at run time into /root/.config/restic (700/600),
# never stored in this file or in git.
set -euo pipefail

TS_IP=100.64.0.30
BUTTER=100.64.0.20
REST_PORT=8000
REST_USER=garlic
SCHEDULE='*-*-* 05:45:00 UTC'   # after Serverus 05:30, before butter's 07:00 HDD copy

CONF=/root/.config/restic
DUMP_DIR=/var/backups/forgejo
DB=/var/lib/forgejo/data/forgejo.db
SCRIPT=/usr/local/bin/restic-backup.sh
SERVICE=/etc/systemd/system/restic-backup.service
TIMER=/etc/systemd/system/restic-backup.timer

step() { printf '\n== %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Write stdin to $1 with mode $2. Refuse to change a live file that differs.
put() {
    local dst=$1 mode=$2 tmp
    tmp=$(mktemp)
    cat >"$tmp"
    if [ -e "$dst" ]; then
        if cmp -s "$tmp" "$dst"; then echo "unchanged: $dst"; rm -f "$tmp"; return 0; fi
        rm -f "$tmp"; die "$dst exists and differs, refusing to overwrite (diff it by hand)"
    fi
    install -m "$mode" -o root -g root "$tmp" "$dst"; rm -f "$tmp"; echo "written:   $dst"
}

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ "$(hostname)" = garlic ] || die "this is $(hostname), not garlic"
ip -4 addr show tailscale0 | grep -q "inet $TS_IP/" || die "tailscale0 does not have $TS_IP"
systemctl is-active -q forgejo || die "forgejo.service is not active"
[ -f "$DB" ] || die "$DB not found"

step "1/7 packages (restic, sqlite3, curl)"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq restic sqlite3 curl >/dev/null
restic version

step "2/7 rest-server on butter reachable"
code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$BUTTER:$REST_PORT/" || true)
[ "$code" = 401 ] || die "http://$BUTTER:$REST_PORT/ answered '$code', expected 401 (Tailscale grant garlic -> butter tcp:$REST_PORT?)"
echo "butter rest-server answers 401 (OK)"

step "3/7 secrets in $CONF"
install -d -m 700 "$CONF"
if [ -e "$CONF/repo" ]; then
    echo "kept:      $CONF/repo"
else
    read -rsp "rest-server password for user '$REST_USER' (from butter): " pw; echo
    [ -n "$pw" ] || die "empty password"
    case $pw in *[!A-Za-z0-9]*) die "use a hex/alphanumeric password (it goes into a URL)";; esac
    umask 077; printf 'rest:http://%s:%s@%s:%s/%s/\n' "$REST_USER" "$pw" "$BUTTER" "$REST_PORT" "$REST_USER" >"$CONF/repo"
    unset pw; echo "written:   $CONF/repo"
fi
if [ -e "$CONF/repo-pass" ]; then
    echo "kept:      $CONF/repo-pass"
else
    umask 077; openssl rand -base64 33 >"$CONF/repo-pass"
    echo
    echo "NEW restic repo password for garlic (the only key to this backup). Save it NOW"
    echo "in Vaultwarden and in your offline copy, next to Serverus's. Shown once:"
    echo
    echo "    $(cat "$CONF/repo-pass")"
    echo
    read -rp "Saved it? Type YES: " ok; [ "$ok" = YES ] || die "stopped; $CONF/repo-pass is kept, show it with: sudo cat $CONF/repo-pass"
fi
if [ ! -e "$CONF/ntfy-topic" ]; then
    read -rp "ntfy topic for alerts (same as Serverus's /root/.config/restic/ntfy-topic; empty = none): " t
    umask 077; printf '%s\n' "$t" >"$CONF/ntfy-topic"
fi
chmod 600 "$CONF"/*

step "4/7 path lists"
put "$CONF/paths" 600 <<EOF
/etc
/opt
/usr/local/bin
/var/lib/forgejo
$DUMP_DIR
/home/k
EOF
put "$CONF/excludes" 600 <<'EOF'
# live SQLite files: the consistent copy is in /var/backups/forgejo
/var/lib/forgejo/data/forgejo.db
/var/lib/forgejo/data/forgejo.db-wal
/var/lib/forgejo/data/forgejo.db-shm
/var/lib/forgejo/data/forgejo.db-journal
/var/lib/forgejo/log
/var/lib/forgejo/data/tmp
# Pi-hole query log (big, rebuilt), nebula-sync syncs the config from Serverus anyway
pihole-FTL.db*
/home/k/.cache
EOF

step "5/7 backup script $SCRIPT"
put "$SCRIPT" 755 <<'EOF'
#!/bin/bash
# Daily restic backup of garlic to butter (rest-server --append-only, over
# Tailscale). Run as root by restic-backup.timer. Installed by
# homelab host-garlic/scripts/install-restic-garlic.sh. Secrets and path lists
# live in /root/.config/restic/. On failure or an incomplete snapshot: ntfy alert.
# Pruning can't be done from here (append-only); run it on butter.

set -uo pipefail
umask 077

CONF=/root/.config/restic
DB=/var/lib/forgejo/data/forgejo.db
DUMP_DIR=/var/backups/forgejo
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

# 1. Consistent online copy of Forgejo's DB, checked before it replaces the last good one.
mkdir -p "$DUMP_DIR"; chmod 700 "$DUMP_DIR"
tmp="$DUMP_DIR/forgejo.db.new"
rm -f "$tmp"
if sqlite3 "$DB" ".backup '$tmp'" && [ "$(sqlite3 "$tmp" 'PRAGMA integrity_check;')" = ok ]; then
    mv -f "$tmp" "$DUMP_DIR/forgejo.db"
    log "forgejo DB copy OK ($(stat -c %s "$DUMP_DIR/forgejo.db") bytes)"
else
    rm -f "$tmp"
    log "forgejo DB copy FAILED, backing up the previous copy"
    alert "garlic backup: Forgejo DB copy FAILED" "sqlite3 .backup or integrity_check failed; restic runs with the previous copy. See: journalctl -u restic-backup"
fi

# 2. restic
log "backup start"
restic backup --files-from "$CONF/paths" --exclude-file "$CONF/excludes" --tag daily
rc=$?
case $rc in
    0) log "backup OK" ;;
    3) log "backup INCOMPLETE (some files unreadable, snapshot saved)"
       alert "garlic backup incomplete" "restic saved a snapshot but could not read some files. See: journalctl -u restic-backup" ;;
    *) log "backup FAILED (exit $rc)"
       alert "garlic backup FAILED" "restic exit $rc, no snapshot. See: journalctl -u restic-backup"
       exit "$rc" ;;
esac

# 3. Sundays: verify the repo structure plus a random 5% of the data.
if [ "$(date -u +%u)" = 7 ]; then
    log "weekly check start"
    if restic check --read-data-subset=5%; then
        log "check OK"
    else
        log "check FAILED"
        alert "garlic backup: repo check FAILED" "restic check on butter reported errors. See: journalctl -u restic-backup"
        exit 1
    fi
fi
exit 0
EOF

step "6/7 systemd service + timer"
put "$SERVICE" 644 <<'EOF'
[Unit]
Description=restic backup of garlic to butter
Wants=network-online.target
After=network-online.target tailscaled.service forgejo.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/restic-backup.sh
Nice=10
IOSchedulingClass=idle
PrivateTmp=yes
EOF
put "$TIMER" 644 <<EOF
[Unit]
Description=Daily restic backup of garlic to butter

[Timer]
OnCalendar=$SCHEDULE
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload

step "7/7 repo init + first backup"
export RESTIC_REPOSITORY_FILE=$CONF/repo RESTIC_PASSWORD_FILE=$CONF/repo-pass RESTIC_CACHE_DIR=/root/.cache/restic
if restic cat config >/dev/null 2>&1; then
    echo "repo already initialised"
else
    restic init
fi
systemctl enable --now restic-backup.timer
echo "running the first backup (journalctl -u restic-backup -f in another shell to watch)"
systemctl start restic-backup.service || true
journalctl -u restic-backup -n 30 --no-pager
restic snapshots
systemctl list-timers restic-backup.timer --no-pager
echo
echo "Done. Next: the restore test (see the vault, card #63)."
