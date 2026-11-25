#!/usr/bin/env bash
# On Serverus, as admin (no sudo):  bash ~/setup-forgejo-garlic-key.sh
# Deploy key + ssh alias + verified host key so Serverus can push the AI-Brain
# vault to Forgejo on garlic. Same pattern as forgejo-butter for homelab.
# Safe to re-run: each step skips what already exists.
set -euo pipefail

KEY=~/.ssh/forgejo_aibrain
ALIAS=forgejo-garlic
HOST=192.0.2.51
PORT=2222
FPR="SHA256:<host-key-fingerprint>"   # confirmed by Konrad on garlic 2026-11-06

die() { printf '!! STOP: %s\n' "$*" >&2; exit 1; }
install -d -m 700 ~/.ssh

# 1. deploy key
if [[ -f $KEY ]]; then
  echo "1. key $KEY exists, kept"
else
  ssh-keygen -q -t ed25519 -N '' -C "serverus-aibrain-deploy" -f "$KEY"
  echo "1. key $KEY created"
fi

# 2. host key, only if it matches the confirmed fingerprint
if ssh-keygen -F "[$HOST]:$PORT" >/dev/null; then
  echo "2. host key for [$HOST]:$PORT already in known_hosts"
  ssh-keygen -lF "[$HOST]:$PORT" | grep -q "$FPR" || die "known_hosts has a DIFFERENT key for [$HOST]:$PORT"
else
  LINE=$(ssh-keyscan -p "$PORT" -t rsa -T 5 "$HOST" 2>/dev/null | grep -v '^#' | head -1)
  [[ -n $LINE ]] || die "no host key from $HOST:$PORT"
  GOT=$(ssh-keygen -lf - <<<"$LINE" | awk '{print $2}')
  [[ $GOT == "$FPR" ]] || die "host key fingerprint $GOT does not match $FPR"
  printf '%s\n' "$LINE" >> ~/.ssh/known_hosts
  echo "2. host key verified ($FPR) and added"
fi

# 3. ssh alias
if grep -qE "^Host[[:space:]]+$ALIAS\$" ~/.ssh/config 2>/dev/null; then
  echo "3. alias $ALIAS already in ~/.ssh/config"
else
  cat >> ~/.ssh/config <<EOF

Host $ALIAS
    HostName $HOST
    Port $PORT
    User git
    IdentityFile $KEY
    IdentitiesOnly yes
EOF
  chmod 600 ~/.ssh/config
  echo "3. alias $ALIAS added to ~/.ssh/config"
fi

echo
echo "Public key, add it in garlic's Forgejo: admin/AI-Brain > Settings > Deploy keys,"
echo "title 'serverus', tick 'Enable write access':"
echo
cat "$KEY.pub"
