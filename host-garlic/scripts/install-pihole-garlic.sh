#!/usr/bin/env bash
# Second Pi-hole on garlic (ThinkPad T61, 192.0.2.51), same image as Serverus.
# Run on garlic:  sudo bash install-pihole-garlic.sh
# Safe to re-run: every step checks its own state and skips what is already done.
# Stops on the first unexpected state instead of guessing.
set -euo pipefail

IMAGE="pihole/pihole:2026.10.0"
STACK_DIR="/opt/pihole"
EXPECTED_HOST="garlic"
EXPECTED_IP="192.0.2.51"
IFACE="enp0s25"

step() { printf '\n== %s\n' "$*"; }
ok()   { printf '   OK: %s\n' "$*"; }
die()  { printf '\n!! STOP: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. sanity
step "0. Checks"
[[ $EUID -eq 0 ]] || die "run with sudo: sudo bash $0"
[[ $(hostname) == "$EXPECTED_HOST" ]] || die "this is $(hostname), not $EXPECTED_HOST"
ip -4 -br addr show "$IFACE" | grep -q "$EXPECTED_IP/" \
  || die "$IFACE does not have $EXPECTED_IP (static IP step not in place)"
command -v docker >/dev/null || die "docker not installed"
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
systemctl is-active --quiet docker || die "docker service not running"
ok "host $EXPECTED_HOST, $IFACE=$EXPECTED_IP, docker $(docker version --format '{{.Server.Version}}')"

# ------------------------------------------------- 1. free port 53 (resolved)
step "1. systemd-resolved stub listener off"
DROPIN=/etc/systemd/resolved.conf.d/no-stub.conf
RESTART_RESOLVED=0
if [[ -f $DROPIN ]] && grep -qx 'DNSStubListener=no' "$DROPIN"; then
  ok "$DROPIN already present"
else
  mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNSStubListener=no\n' > "$DROPIN"
  RESTART_RESOLVED=1
  ok "wrote $DROPIN"
fi

RESOLV_TARGET=$(readlink -f /etc/resolv.conf)
case "$RESOLV_TARGET" in
  /run/systemd/resolve/resolv.conf)
    ok "/etc/resolv.conf already points to the uplink servers" ;;
  /run/systemd/resolve/stub-resolv.conf)
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    RESTART_RESOLVED=1
    ok "/etc/resolv.conf relinked (was stub-resolv.conf -> 127.0.0.53)" ;;
  *)
    die "/etc/resolv.conf points to $RESOLV_TARGET (unexpected); not touching it" ;;
esac

if (( RESTART_RESOLVED )); then
  systemctl restart systemd-resolved
  sleep 2
fi

if ss -lntupH | grep -E '127\.0\.0\.5[34]:53 ' | grep -q systemd-resolve; then
  die "systemd-resolved still listens on port 53"
fi
getent hosts github.com >/dev/null || die "garlic itself cannot resolve names now (check /etc/resolv.conf)"
ok "port 53 free of resolved; host DNS: $(grep -m3 '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd' ')"

# ------------------------------------------------------------ 2. the stack
step "2. $STACK_DIR/docker-compose.yml"
COMPOSE_NEW=$(cat <<EOF
services:
  pihole:
    container_name: pihole
    image: $IMAGE
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "8082:80/tcp"
    environment:
      TZ: Europe/Warsaw
      FTLCONF_dns_listeningMode: ALL
      # Same wildcard as Serverus. The API refuses misc.dnsmasq_lines, so
      # nebula-sync can't copy it: change it here when it changes on Serverus.
      FTLCONF_misc_dnsmasq_lines: "address=/home.example.com/192.0.2.50"
    volumes:
      - ./etc-pihole:/etc/pihole
    cap_add:
      - NET_ADMIN
      - SYS_TIME
      - SYS_NICE
    restart: unless-stopped
EOF
)
install -d -m 0755 "$STACK_DIR"
if [[ -f $STACK_DIR/docker-compose.yml ]]; then
  if [[ "$(cat "$STACK_DIR/docker-compose.yml")" == "$COMPOSE_NEW" ]]; then
    ok "compose file already in place"
  else
    die "$STACK_DIR/docker-compose.yml exists and differs; not overwriting it"
  fi
else
  printf '%s\n' "$COMPOSE_NEW" > "$STACK_DIR/docker-compose.yml"
  ok "compose file written"
fi

# Something else on port 53 that isn't our container?
if ss -lntupH | grep -E ':53 ' | grep -vq docker-proxy; then
  if ! docker ps --format '{{.Names}}' | grep -qx pihole; then
    ss -lntup | grep -E ':53 ' >&2
    die "another process holds port 53"
  fi
fi

# ------------------------------------------------------------- 3. start it
step "3. Pull and start ($IMAGE; the pull takes a while on the T61)"
cd "$STACK_DIR"
docker compose pull --quiet
docker compose up -d

printf '   waiting for the container to report healthy'
for _ in $(seq 1 60); do
  STATUS=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' pihole 2>/dev/null || echo missing)
  [[ $STATUS == healthy || $STATUS == none ]] && break
  printf '.'; sleep 3
done
echo
case "$STATUS" in
  healthy) ok "pihole healthy" ;;
  none)    ok "pihole running (image has no healthcheck)" ;;
  *)       docker compose logs --tail 30 >&2; die "pihole status: $STATUS" ;;
esac

# ------------------------------------------------------------- 4. test DNS
step "4. DNS test through the new Pi-hole"
if docker exec pihole dig +short +time=3 @127.0.0.1 github.com | grep -qE '^[0-9.]+$'; then
  ok "github.com resolves through Pi-hole"
else
  echo "   WARN: test query inside the container failed; check: docker compose logs" >&2
fi

# ------------------------------------------------------ 5. web UI password
step "5. Web UI password"
if [[ -t 0 ]]; then
  read -r -p "   Set the web password now? Type it yourself, it isn't stored here. [y/N] " ans
  if [[ ${ans,,} == y* ]]; then
    docker exec -it pihole pihole setpassword
  else
    echo "   Skipped. Later: docker exec -it pihole pihole setpassword"
  fi
else
  echo "   No terminal. Later: docker exec -it pihole pihole setpassword"
fi

step "Done"
echo "   Pi-hole: DNS on $EXPECTED_IP:53, UI http://$EXPECTED_IP:8082/admin/"
echo "   Not done here (next steps): sync from Serverus (nebula-sync), router DNS 2."
