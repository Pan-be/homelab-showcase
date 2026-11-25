#!/usr/bin/env bash
# Copies Serverus's live config (compose stacks in /opt and ~/crafty) into stacks/, so the
# repo can be refreshed and reviewed with `git diff`. Read-only towards the live paths.
# Never copies .env files, data, backups (*.bak*, *.before*) or Caddyfile~ style leftovers;
# stacks/<name>/.env.example is generated from the variable names only, never the values.
# Usage: scripts/collect.sh   (then: git diff, scripts/scan.sh, commit)
set -euo pipefail
cd "$(dirname "$0")/.."

# <stack> <live dir> <files and dirs to copy, relative to the live dir>
STACKS=(
    "board          /opt/board              docker-compose.yml nginx.conf"
    "books          /opt/books              docker-compose.yml stats/app.py"
    "caddy          /opt/caddy              docker-compose.yml Dockerfile Caddyfile"
    "crafty         $HOME/crafty            docker-compose.yml"
    "homepage       /opt/homepage           docker-compose.yml config/bookmarks.yaml config/docker.yaml config/services.yaml config/settings.yaml config/widgets.yaml config/custom.css config/custom.js"
    "infrastructure /opt/infrastructure     docker-compose.yml"
    "jellyfin       /opt/jellyfin           docker-compose.yml"
    "kalorie        /opt/kalorie            compose.yaml"
    "larapaper      /opt/larapaper          compose.yaml recipes/agenda-kindle/src/settings.yml recipes/agenda-kindle/src/shared.liquid recipes/agenda-kindle/src/full.liquid recipes/agenda-kindle/src/half_horizontal.liquid recipes/agenda-kindle/src/half_vertical.liquid recipes/agenda-kindle/src/quadrant.liquid feeds/calendar-a-ics.py feeds/calendar-b-ics.py"
    "private-app         /opt/private-app-1.0         docker-compose.yml nginx/default.conf backup-db.sh heartbeat-ping.sh"
    "ollama         /opt/ollama             docker-compose.yml"
    "pan-be-staging /opt/pan-be-staging     docker-compose.yml uploads.ini"
    "pihole         /opt/pihole             docker-compose.yml"
    "vaultwarden    /opt/vaultwarden        docker-compose.yml backup-db.sh"
)

# Variable names a stack expects: ${VAR} references in the copied files, plus the keys of
# any readable env file next to the compose file (names only: everything after "=" is cut).
env_names() {
    local live=$1 dest=$2
    grep -rhoE --include='*compose.y*ml' '\$\{[A-Za-z_][A-Za-z0-9_]*' "$dest" 2>/dev/null | sed 's/^\${//' || true
    grep -rhoE '\{\{HOMEPAGE_VAR_[A-Z0-9_]+\}\}' "$dest" 2>/dev/null | tr -d '{}' || true
    grep -rhoE --include=Caddyfile '\{env\.[A-Za-z_][A-Za-z0-9_]*\}' "$dest" 2>/dev/null | sed 's/^{env\.//; s/}$//' || true
    for f in "$live"/.env "$live"/*.env; do
        if [ -r "$f" ]; then grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$f" | cut -d= -f1 || true; fi
    done
}

for line in "${STACKS[@]}"; do
    read -r name live files <<<"$line"
    dest="stacks/$name"
    rm -rf "$dest"
    mkdir -p "$dest"
    for f in $files; do
        mkdir -p "$dest/$(dirname "$f")"
        cp "$live/$f" "$dest/$f"
    done
    names=$(env_names "$live" "$dest" | sort -u)
    if [ -n "$names" ]; then
        { echo "# Variables this stack expects. Real values live in $live/.env (600), never in git."
          sed 's/$/=/' <<<"$names"; } >"$dest/.env.example"
    fi
    if [ -e "$live/.env" ] && [ ! -r "$live/.env" ]; then
        echo "note: $live/.env is not readable (root 600); .env.example lists only the \${VAR} references" >&2
    fi
done
echo "collected ${#STACKS[@]} stacks into stacks/"

# --- Pi-hole: local DNS and lists ---------------------------------------------------------
# Only chosen keys from pihole.toml (never the whole file: it holds the web password hash),
# plus the block/allow lists from gravity.db. Restore: README.md "Pi-hole".
python3 -I - /opt/pihole/etc-pihole/pihole.toml stacks/pihole/ftl-settings.json <<'PY'
import json, sys, tomllib
KEYS = ["dns.upstreams", "dns.hosts", "dns.cnameRecords", "dns.revServers", "dns.domain.name",
        "misc.dnsmasq_lines", "dhcp.active"]
with open(sys.argv[1], "rb") as f:
    conf = tomllib.load(f)
out = {}
for key in KEYS:
    node = conf
    for part in key.split("."):
        node = node.get(part, {}) if isinstance(node, dict) else {}
    out[key] = node if node != {} else None
with open(sys.argv[2], "w") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
PY
docker exec pihole pihole-FTL sqlite3 -json /etc/pihole/gravity.db \
    "SELECT address, type, enabled, comment FROM adlist ORDER BY id" >stacks/pihole/adlists.json
docker exec pihole pihole-FTL sqlite3 -json /etc/pihole/gravity.db \
    "SELECT type, domain, enabled, comment FROM domainlist ORDER BY id" >stacks/pihole/domainlist.json
echo "exported Pi-hole settings and lists into stacks/pihole/"

# --- Host layer -----------------------------------------------------------------------------
# Files outside Docker, mirrored under host/<absolute path>. Root-only files are copied with
# `sudo -n` when a sudo session is open (run `sudo -v` first); otherwise the previous copy is
# kept and listed as skipped, so a run without sudo never deletes them from the repo.
HOST_FILES=(
    /etc/fstab
    /etc/systemd/resolved.conf
    /etc/mdadm/mdadm.conf
    /etc/docker/daemon.json
    /etc/systemd/system/docker.service.d/nvme.conf
    /etc/systemd/system/restic-backup.service
    /etc/systemd/system/restic-backup.timer
    /usr/local/bin/restic-backup.sh
    /usr/local/bin/backup_crafty.sh
    /etc/ufw/user.rules
    /etc/ufw/user6.rules
    /etc/ssh/sshd_config.d/00-serverus.conf
    /etc/netplan/50-cloud-init.yaml
    /etc/apt/sources.list.d/docker.list
    /etc/apt/sources.list.d/tailscale.list
    /root/.config/restic/paths
    /root/.config/restic/excludes
    "$HOME/.config/systemd/user/jarvis-web.service"
    "$HOME/.config/systemd/user/kalorie-ai.service"
    "$HOME/.config/systemd/user/localsend.service"
    "$HOME/.config/systemd/user/board.service"
    "$HOME/.config/systemd/user/board.timer"
    "$HOME/.config/systemd/user/soloist.service"
    "$HOME/.config/systemd/user/soloist-update.service"
    "$HOME/.config/systemd/user/soloist-update.timer"
    "$HOME/.config/systemd/user/vault-tidy.service"
    "$HOME/.config/systemd/user/vault-tidy.timer"
    "$HOME/.config/systemd/user/morning-summary.service"
    "$HOME/.config/systemd/user/morning-summary.timer"
    "$HOME/.config/systemd/user/jarvis-web.service.d/proxied-hosts.conf"
    "$HOME/.config/systemd/user/jarvis-web.service.d/claude-token.conf"
    "$HOME/.config/systemd/user/kalorie-ai.service.d/claude-token.conf"
)
skipped=()
copy_host() {  # <src> <dest>; content comes from stdin-less cat, with sudo -n as fallback
    local src=$1 dest=$2
    mkdir -p "$(dirname "$dest")"
    if [ -r "$src" ]; then cp "$src" "$dest"
    elif sudo -n cat "$src" >"$dest.tmp" 2>/dev/null; then mv "$dest.tmp" "$dest"
    else rm -f "$dest.tmp"; skipped+=("$src"); fi
}
for f in "${HOST_FILES[@]}"; do copy_host "$f" "host$f"; done

mkdir -p host/crontab
crontab -l >host/crontab/admin
if sudo -n crontab -l -u root >host/crontab/root.tmp 2>/dev/null; then mv host/crontab/root.tmp host/crontab/root
else rm -f host/crontab/root.tmp; skipped+=("root crontab"); fi

echo "collected host layer into host/"
if ((${#skipped[@]})); then
    echo "skipped (root only, no sudo session; previous copy kept if any):" >&2
    printf '  %s\n' "${skipped[@]}" >&2
fi
