#!/usr/bin/env bash
# nebula-sync on garlic: copies Pi-hole settings from Serverus (primary, 192.0.2.50)
# to garlic (replica, 192.0.2.51). Changes are made on Serverus only.
# Run on garlic:  sudo bash install-nebula-sync-garlic.sh
# Safe to re-run: existing files are kept (it stops if they differ), passwords are
# asked only when .env doesn't exist yet.
#
# Choices (see the vault, Homelab Ideas, garlic):
# - Selective sync, not FULL_SYNC.
# - RUN_GRAVITY=false: nebula-sync would also run gravity on the PRIMARY (upstream
#   issue #271). Gravity on garlic is run once here, locally, and weekly by Pi-hole.
# - dns.listeningMode and dns.interface are not synced (set per host; listeningMode is
#   locked by an FTLCONF_ env var on garlic, and a rejected PATCH aborts the whole sync).
# - misc.dnsmasq_lines (the home.example.com wildcard) is not synced: Pi-hole's API
#   refuses it (400). It is set by FTLCONF_misc_dnsmasq_lines in garlic's Pi-hole compose.
# - Serverus needs its web login password here, not the app password: an app session
#   without app_sudo gets 403 on the teleporter export.
# - The webserver section (web password) is never synced by nebula-sync.
# - Every 6 h; force a sync with: docker restart nebula-sync
set -euo pipefail

IMAGE="ghcr.io/lovelaze/nebula-sync:v0.11.3"
STACK_DIR="/opt/nebula-sync"
PRIMARY_URL="http://192.0.2.50:8082"
REPLICA_URL="http://192.0.2.51:8082"
EXPECTED_HOST="garlic"

step() { printf '\n== %s\n' "$*"; }
ok()   { printf '   OK: %s\n' "$*"; }
die()  { printf '\n!! STOP: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. checks
step "0. Checks"
[[ $EUID -eq 0 ]] || die "run with sudo: sudo bash $0"
[[ $(hostname) == "$EXPECTED_HOST" ]] || die "this is $(hostname), not $EXPECTED_HOST"
docker ps --format '{{.Names}}' | grep -qx pihole || die "pihole container is not running"
for u in "$PRIMARY_URL" "$REPLICA_URL"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u/admin/login" || true)
  [[ $code == 200 ]] || die "$u/admin/login answers $code, expected 200"
done
ok "pihole running; Serverus and garlic Pi-hole UIs reachable"

# ------------------------------------------- 1. app_sudo on the replica
step "1. webserver.api.app_sudo on garlic's Pi-hole (needed for app passwords)"
if [[ $(docker exec pihole pihole-FTL --config webserver.api.app_sudo) == true ]]; then
  ok "already true"
else
  docker exec pihole pihole-FTL --config webserver.api.app_sudo true >/dev/null
  [[ $(docker exec pihole pihole-FTL --config webserver.api.app_sudo) == true ]] \
    || die "could not set webserver.api.app_sudo"
  ok "set to true"
fi

# ---------------------------------------------------- 2. secrets (.env)
step "2. $STACK_DIR/.env (passwords, root 600)"
install -d -m 0755 "$STACK_DIR"
if [[ -f $STACK_DIR/.env ]]; then
  ok ".env already exists, not asking again (delete it to re-enter passwords)"
else
  [[ -t 0 ]] || die "no terminal to type the passwords"
  ask() {
    local prompt=$1 pw
    read -r -s -p "   $prompt: " pw; echo >&2
    [[ -n $pw ]] || die "empty password"
    [[ $pw != *[\|,\']* ]] || die "password contains | , or ' (breaks the PRIMARY/REPLICAS format)"
    printf '%s' "$pw"
  }
  echo "   Serverus (primary): its web LOGIN password, not the app password (an app"
  echo "   session without app_sudo gets 403 on the export). Don't generate a new app"
  echo "   password on Serverus: that replaces Homepage's and breaks its widget."
  P1=$(ask "Serverus Pi-hole password")
  echo "   garlic (replica): an app password generated in garlic's UI"
  echo "   (Settings > Web interface / API > App password), or its web password."
  P2=$(ask "garlic Pi-hole password")
  ( umask 077
    printf "PRIMARY='%s|%s'\nREPLICAS='%s|%s'\n" "$PRIMARY_URL" "$P1" "$REPLICA_URL" "$P2" > "$STACK_DIR/.env" )
  unset P1 P2
  chown root:root "$STACK_DIR/.env"; chmod 600 "$STACK_DIR/.env"
  ok ".env written (600 root:root)"
fi

# ------------------------------------------------------- 3. compose file
step "3. $STACK_DIR/docker-compose.yml"
COMPOSE_NEW=$(cat <<EOF
services:
  nebula-sync:
    container_name: nebula-sync
    image: $IMAGE
    env_file: .env
    environment:
      TZ: Europe/Warsaw
      FULL_SYNC: "false"
      RUN_GRAVITY: "false"
      CRON: "15 */6 * * *"
      SYNC_CONFIG_DNS: "true"
      SYNC_CONFIG_DNS_EXCLUDE: "listeningMode,interface"
      SYNC_CONFIG_MISC: "true"
      SYNC_CONFIG_MISC_EXCLUDE: "dnsmasq_lines"
      SYNC_GRAVITY_GROUP: "true"
      SYNC_GRAVITY_AD_LIST: "true"
      SYNC_GRAVITY_AD_LIST_BY_GROUP: "true"
      SYNC_GRAVITY_DOMAIN_LIST: "true"
      SYNC_GRAVITY_DOMAIN_LIST_BY_GROUP: "true"
    restart: unless-stopped
EOF
)
if [[ -f $STACK_DIR/docker-compose.yml ]]; then
  [[ "$(cat "$STACK_DIR/docker-compose.yml")" == "$COMPOSE_NEW" ]] \
    || die "$STACK_DIR/docker-compose.yml exists and differs; not overwriting it"
  ok "compose file already in place"
else
  printf '%s\n' "$COMPOSE_NEW" > "$STACK_DIR/docker-compose.yml"
  ok "compose file written"
fi

# ------------------------------------------- 4. start, wait for first sync
step "4. Start nebula-sync (it syncs once at start, then every 6 h)"
cd "$STACK_DIR"
docker compose pull --quiet
docker compose up -d --force-recreate
printf '   waiting for the first sync'
RESULT=""
for _ in $(seq 1 60); do
  LOGS=$(docker logs nebula-sync 2>&1 || true)
  if grep -q 'Sync completed' <<<"$LOGS"; then RESULT=ok; break; fi
  if grep -qE 'Sync failed|Error during sync' <<<"$LOGS"; then RESULT=failed; break; fi
  printf '.'; sleep 3
done
echo
docker logs --tail 15 nebula-sync 2>&1 | sed 's/^/   | /'
case "$RESULT" in
  ok)     ok "first sync completed" ;;
  failed) die "first sync failed (log above); garlic still answers DNS, nothing on Serverus changed" ;;
  *)      die "no result after 3 min (log above)" ;;
esac

# --------------------------------------------- 5. gravity on garlic only
step "5. Gravity on garlic (builds the synced blocklists; local only, not on Serverus)"
docker exec pihole pihole -g >/dev/null 2>&1 && ok "gravity rebuilt" \
  || echo "   WARN: gravity failed; run later: docker exec pihole pihole -g" >&2

# ------------------------------------------------------- 6. quick checks
step "6. Local records through garlic's Pi-hole"
for n in pihole.home.arpa kalorie.home.example.com; do
  a=$(docker exec pihole dig +short +time=3 @127.0.0.1 "$n" A | tail -1)
  printf '   %-26s -> %s\n' "$n" "${a:-(no answer)}"
done

step "Done"
echo "   Expected above: both names -> 192.0.2.50. Tell Jarvis; it checks from Serverus too."
