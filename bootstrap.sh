#!/usr/bin/env bash
# Rebuild Serverus's host layer on a fresh Ubuntu 24.04 install.
# Run as the admin user (admin, with sudo) from a clone of this repo:
#   ./bootstrap.sh            apply
#   ./bootstrap.sh --check    show what would change, change nothing
# Before the first run put the restic secrets back (docs/restore.md, step 2).
# After it: tailscale up, restic restore of /opt and the rest, then the stacks (docs/restore.md).
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(id -u)" -eq 0 ]; then
    echo "Run as the admin user, not root (sudo is asked for when needed)." >&2
    exit 1
fi
. /etc/os-release
if [ "${ID:-}" != ubuntu ] || [ "${VERSION_ID:-}" != 24.04 ]; then
    echo "Written for Ubuntu 24.04; this is ${PRETTY_NAME:-unknown}." >&2
    exit 1
fi

check=()
if [ "${1:-}" = --check ]; then check=(--check --diff); shift; fi

if ! command -v ansible-playbook >/dev/null; then
    echo "==> installing ansible-core from apt"
    sudo apt-get update
    sudo apt-get install -y ansible-core
fi

echo "==> host layer${check:+ (check only)}"
cd ansible
# Ask for the sudo password only when sudo actually needs one.
become=(--ask-become-pass)
if sudo -n true 2>/dev/null; then become=(); fi
ansible-playbook site.yml "${become[@]}" "${check[@]}" "$@"
