#!/usr/bin/env bash
# Throwaway Ubuntu 24.04 VM on Serverus for restore tests (docs/restore.md).
# QEMU/KVM with user-mode networking: no bridge, no host firewall rules; the VM reaches the
# outside (and butter over Tailscale) as an ordinary process of the host, and is reached only
# by SSH on 127.0.0.1:2222. It has its own SSH key, kept next to the disk, not in ~/.ssh.
#
# Usage: scripts/test-vm.sh create|start|ssh [cmd...]|stop|status|destroy
# Needs: qemu-system-x86, cloud-image-utils, the user in the kvm group, and $VM_DIR writable.
set -euo pipefail

VM_DIR=${VM_DIR:-/srv/nvme/vm/restore-test}
IMAGE_URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
SUMS_URL=https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
CPUS=${CPUS:-2}
MEM_MB=${MEM_MB:-4096}
DISK=${DISK:-40G}
SSH_PORT=${SSH_PORT:-2222}
VM_USER=admin

base=$VM_DIR/noble-base.img
disk=$VM_DIR/disk.qcow2
seed=$VM_DIR/seed.iso
key=$VM_DIR/id_ed25519
pidfile=$VM_DIR/vm.pid

running() { [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }

ssh_vm() {
    ssh -i "$key" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=5 "$VM_USER@127.0.0.1" "$@"
}

create() {
    [ -e "$disk" ] && { echo "$disk exists; run destroy first" >&2; exit 1; }
    mkdir -p "$VM_DIR"
    if [ ! -f "$base" ]; then
        echo "==> downloading the Ubuntu 24.04 cloud image"
        curl -fL --progress-bar -o "$base.part" "$IMAGE_URL"
        want=$(curl -fsSL "$SUMS_URL" | awk '$2 ~ /noble-server-cloudimg-amd64.img$/ {print $1}')
        have=$(sha256sum "$base.part" | cut -d' ' -f1)
        [ -n "$want" ] && [ "$want" = "$have" ] || { echo "checksum mismatch" >&2; rm -f "$base.part"; exit 1; }
        mv "$base.part" "$base"
    fi
    echo "==> disk ($DISK, copy-on-write over the base image)"
    qemu-img create -q -f qcow2 -b "$base" -F qcow2 "$disk" "$DISK"
    [ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -C restore-test -f "$key"
    cat >"$VM_DIR/user-data" <<EOF
#cloud-config
hostname: restore-test
manage_etc_hosts: true
users:
  - name: $VM_USER
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "$key.pub")
ssh_pwauth: false
package_update: false
EOF
    printf 'instance-id: restore-test-%s\nlocal-hostname: restore-test\n' "$(date +%s)" >"$VM_DIR/meta-data"
    cloud-localds "$seed" "$VM_DIR/user-data" "$VM_DIR/meta-data"
    echo "created in $VM_DIR; next: $0 start"
}

start() {
    running && { echo "already running (pid $(cat "$pidfile"))"; return; }
    # Membership in kvm may be newer than this login session; sg picks it up from /etc/group.
    local run=()
    id -nG | tr ' ' '\n' | grep -qx kvm || run=(sg kvm -c)
    local cmd="qemu-system-x86_64 -enable-kvm -cpu host -smp $CPUS -m $MEM_MB \
        -name restore-test \
        -drive file=$disk,if=virtio,format=qcow2 \
        -drive file=$seed,if=virtio,format=raw,readonly=on \
        -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 \
        -display none -serial file:$VM_DIR/serial.log \
        -daemonize -pidfile $pidfile"
    if ((${#run[@]})); then "${run[@]}" "$cmd"; else eval "$cmd"; fi
    echo -n "==> waiting for SSH"
    for _ in $(seq 60); do
        if ssh_vm true 2>/dev/null; then echo " up"; return; fi
        echo -n .; sleep 5
    done
    echo " no SSH after 5 min; see $VM_DIR/serial.log" >&2; exit 1
}

stop() {
    running || { echo "not running"; return; }
    ssh_vm sudo poweroff 2>/dev/null || true
    for _ in $(seq 30); do running || { echo "stopped"; return; }; sleep 2; done
    kill "$(cat "$pidfile")" && echo "killed"
}

case ${1:-} in
    create) create ;;
    start) start ;;
    ssh) shift; ssh_vm "$@" ;;
    stop) stop ;;
    status) if running; then echo "running (pid $(cat "$pidfile"))"; else echo "stopped"; fi ;;
    destroy)
        running && stop
        rm -f "$disk" "$seed" "$pidfile" "$VM_DIR/serial.log" "$VM_DIR/user-data" "$VM_DIR/meta-data"
        echo "disk removed (base image and VM key kept in $VM_DIR)" ;;
    *) sed -n 2,8p "$0"; exit 1 ;;
esac
