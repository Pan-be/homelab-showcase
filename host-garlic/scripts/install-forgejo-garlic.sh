#!/usr/bin/env bash
# Forgejo v15 LTS on garlic: binary + systemd, SQLite, LAN + Tailscale.
# Run on garlic as: sudo bash install-forgejo-garlic.sh
# Adapted 2026-11-06 on Serverus from butter's install-forgejo.sh (sha256 c0273350...);
# same version, checks and settings, different listen addresses and firewall rules.
# 2026-11-06: [migrations] ALLOWED_DOMAINS for the push mirror to butter.
# Plan in the vault: Homelab Config Repo, Homelab Ideas (garlic).
set -euo pipefail

VERSION=15.0.11
SHA256=17b59b5f8a8f968126b7a6fcc1d45d9531228dbf293f172cf5565d2e72e999a3
GPG_FPR=EB114F5E6C0DC2BCDD183550A4B61A2DC5923710
LAN_IP=192.0.2.51
LAN_NET=192.0.2.0/24
TS_IP=100.64.0.30
BUTTER_TS_IP=100.64.0.20   # push mirror target (Forgejo on butter, tailnet SSH :2222)
HTTP_PORT=3000
SSH_PORT=2222
ADMIN_USER=admin
ADMIN_EMAIL=admin@example.com

BIN=/usr/local/bin/forgejo
WORK=/var/lib/forgejo
CONF_DIR=/etc/forgejo
CONF=$CONF_DIR/app.ini
UNIT=/etc/systemd/system/forgejo.service

step() { printf '\n== %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ "$(uname -m)" = x86_64 ] || die "expected x86_64, got $(uname -m)"
[ "$(hostname)" = garlic ] || die "this is $(hostname), not garlic"
ip -4 addr show enp0s25 | grep -q "inet $LAN_IP/" || die "enp0s25 does not have $LAN_IP"
ip -4 addr show tailscale0 | grep -q "inet $TS_IP/" || die "tailscale0 does not have $TS_IP"
ss -tlnH | grep -qE ":($HTTP_PORT|$SSH_PORT)\b" && die "port $HTTP_PORT or $SSH_PORT already in use"
[ -e "$CONF" ] && die "$CONF already exists, refusing to overwrite (already installed?)"
[ -e "$UNIT" ] && die "$UNIT already exists, refusing to overwrite"

step "1/8 packages (git, gpg)"
need=()
command -v git >/dev/null || need+=(git)
command -v gpg >/dev/null || need+=(gpg)
if [ ${#need[@]} -gt 0 ]; then apt-get update -qq && apt-get install -y "${need[@]}"; fi
git --version

step "2/8 download + verify Forgejo $VERSION"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
URL=https://codeberg.org/forgejo/forgejo/releases/download/v$VERSION/forgejo-$VERSION-linux-amd64
curl -fsSL -o "$TMP/forgejo" "$URL"
curl -fsSL -o "$TMP/forgejo.asc" "$URL.asc"
echo "$SHA256  $TMP/forgejo" | sha256sum -c - || die "SHA256 mismatch"
export GNUPGHOME="$TMP/gnupg"; mkdir -m 700 "$GNUPGHOME"
gpg -q --keyserver keys.openpgp.org --recv-keys "$GPG_FPR"
gpg --status-fd 1 --verify "$TMP/forgejo.asc" "$TMP/forgejo" 2>/dev/null \
  | awk -v f="$GPG_FPR" '$2=="VALIDSIG" && $NF==f {ok=1} END {exit !ok}' \
  || die "GPG signature not valid for $GPG_FPR"
echo "signature OK ($GPG_FPR), sha256 OK"
install -m 755 -o root -g root "$TMP/forgejo" "$BIN"
"$BIN" --version

step "3/8 system user git + directories"
if ! id git >/dev/null 2>&1; then
  adduser --system --group --shell /usr/sbin/nologin --gecos 'Forgejo' \
          --disabled-password --home "$WORK" git
fi
install -d -m 750 -o git -g git "$WORK" "$WORK/custom" "$WORK/data" "$WORK/log"
install -d -m 750 -o root -g git "$CONF_DIR"

step "4/8 $CONF"
SECRET_KEY=$("$BIN" generate secret SECRET_KEY)
INTERNAL_TOKEN=$("$BIN" generate secret INTERNAL_TOKEN)
JWT_SECRET=$("$BIN" generate secret JWT_SECRET)
umask 027
cat > "$CONF" <<EOF
APP_NAME = Forgejo (garlic)
RUN_USER = git
RUN_MODE = prod
WORK_PATH = $WORK

[server]
PROTOCOL = http
HTTP_ADDR = 0.0.0.0
HTTP_PORT = $HTTP_PORT
DOMAIN = $LAN_IP
ROOT_URL = http://$LAN_IP:$HTTP_PORT/
START_SSH_SERVER = true
SSH_DOMAIN = $LAN_IP
SSH_LISTEN_HOST = 0.0.0.0
SSH_PORT = $SSH_PORT
SSH_LISTEN_PORT = $SSH_PORT
LFS_START_SERVER = false
OFFLINE_MODE = true

[database]
DB_TYPE = sqlite3
PATH = $WORK/data/forgejo.db

[repository]
ROOT = $WORK/data/forgejo-repositories
DEFAULT_PRIVATE = private

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = true

[security]
INSTALL_LOCK = true
SECRET_KEY = $SECRET_KEY
INTERNAL_TOKEN = $INTERNAL_TOKEN

[oauth2]
JWT_SECRET = $JWT_SECRET

[mirror]
ENABLED = true
DEFAULT_INTERVAL = 8h
MIN_INTERVAL = 10m

; Push mirror URLs go through the migration allow-list. With ALLOWED_DOMAINS empty
; only public hosts pass, and Tailscale's 100.64.0.0/10 counts as private, so butter
; is listed explicitly (added 2026-11-06). Deliberately not ALLOW_LOCALNETWORKS.
[migrations]
ALLOWED_DOMAINS = $BUTTER_TS_IP

[actions]
ENABLED = false

[log]
MODE = console
LEVEL = Info
ROOT_PATH = $WORK/log
EOF
unset SECRET_KEY INTERNAL_TOKEN JWT_SECRET
chown root:git "$CONF"; chmod 640 "$CONF"
umask 022

step "5/8 systemd unit"
cat > "$UNIT" <<EOF
[Unit]
Description=Forgejo (self-hosted Git, LAN + Tailscale)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=$WORK
ExecStart=$BIN web --config $CONF --work-path $WORK
Restart=always
RestartSec=5s
Environment=USER=git HOME=$WORK FORGEJO_WORK_DIR=$WORK
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now forgejo.service

step "6/8 wait for Forgejo"
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HTTP_PORT/api/healthz" || true)
  [ "$code" = 200 ] && break; sleep 2
done
[ "${code:-}" = 200 ] || { journalctl -u forgejo -n 40 --no-pager; die "healthz not 200 (got ${code:-none})"; }
echo "healthz 200"
ss -tln | grep -E ":($HTTP_PORT|$SSH_PORT)\b"

step "7/8 ufw (LAN + Tailscale)"
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  for p in "$HTTP_PORT" "$SSH_PORT"; do
    ufw allow in on tailscale0 to any port "$p" proto tcp comment "forgejo $p tailnet"
    ufw allow from "$LAN_NET" to any port "$p" proto tcp comment "forgejo $p LAN"
  done
  ufw status numbered
else
  echo "ufw not active - no rules added (Forgejo listens on all addresses: LAN, Wi-Fi, Tailscale;"
  echo "the tailnet is limited by the Tailscale policy, login is required for everything)"
fi

step "8/8 admin user '$ADMIN_USER'"
echo ">>> The generated password is printed below ONCE. Save it to Vaultwarden now; you must change it at first login."
sudo -u git "$BIN" admin user create --config "$CONF" --work-path "$WORK" \
  --admin --username "$ADMIN_USER" --email "$ADMIN_EMAIL" \
  --random-password --must-change-password

printf '\nDONE. Open http://%s:%s/ (LAN) or http://%s:%s/ (tailnet) and log in as %s.\n' "$LAN_IP" "$HTTP_PORT" "$TS_IP" "$HTTP_PORT" "$ADMIN_USER"
