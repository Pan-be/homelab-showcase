# Rebuilding Serverus

Order for a full rebuild on new or wiped hardware. The data disks (RAID1 `md0` for
`/mnt/storage`, the NVMe for `/srv/nvme`) keep their data and UUIDs if they survived; if the
NVMe is gone, `/opt` comes back from restic in step 5.

Tested end to end on a clean VM on 2026-11-02: see "Test log" at the end.

## 1. Install Ubuntu 24.04

Server install on the SATA disk, user `admin` with sudo, OpenSSH. Static address
`192.0.2.50` can be set here or left to the playbook (netplan).

## 2. Put the secrets back (not in git)

From the password manager / offline copy, as root:

```
sudo install -d -m 700 /root/.config/restic
sudo vim /root/.config/restic/repo        # rest:http://<user>:<pass>@100.64.0.20:8000/serverus/
sudo vim /root/.config/restic/repo-pass   # repo password (Konrad's offline copy)
sudo vim /root/.config/restic/ntfy-topic  # optional, alerts
sudo chmod 600 /root/.config/restic/*
```

Vaultwarden runs on this machine, so these must not depend on it: keep the offline copy.

## 3. Host layer

```
git clone <this repo> ~/dev/homelab && cd ~/dev/homelab
./bootstrap.sh --check   # optional dry run
./bootstrap.sh
```

Installs ansible-core from apt, then `ansible/site.yml`: packages, timezone, netplan, sshd,
RAID + fstab mounts, Docker (repo, daemon.json, data root on the NVMe, `caddy_net`),
Tailscale, restic timer and scripts, user units with lingering, crontabs.

## 4. Tailscale

```
sudo tailscale up --advertise-routes=192.0.2.50/32 --accept-dns=true
```

Then in the admin console: approve the route, check the machine name and the split DNS
for `home.arpa`. butter (the backup target) is only reachable over the tailnet.

## 5. Data from restic

```
R="sudo env RESTIC_REPOSITORY_FILE=/root/.config/restic/repo RESTIC_PASSWORD_FILE=/root/.config/restic/repo-pass restic"
$R snapshots
$R restore latest --target /root/restore --include /opt --include /home/admin \
  --include /srv/nvme/docker/volumes --include /gluetun
for p in opt home/admin srv/nvme/docker/volumes gluetun; do
  sudo rsync -aHAX --numeric-ids /root/restore/$p/ /$p/
done
sudo rm -rf /root/restore
```

Restore into a staging directory, then copy **each path separately**. Never
`rsync /root/restore/ /`: that also copies the staging directory's own mode onto `/`
(it came out `700` in the 2026-11-02 test and locked every non-root process out,
networking and sshd included). restic 0.16 (Ubuntu 24.04) refuses `--include` together
with `--exclude`, so anything to keep out (e.g. `~/.ssh` on a test VM) goes as
`--exclude` on the rsync line instead.

Size on 2026-11-02: 7.6 GiB, 3 min 48 s from butter over Tailscale.

If butter is gone too, use the B2 copy (see the vault note "Serverus Backups").

## 6. Stacks

Pi-hole first (the LAN uses it for DNS), then Caddy, then the rest:

```
cd /opt/pihole && docker compose up -d
cd /opt/caddy && docker compose up -d
```

Then each stack in `/opt` (and `~/crafty`). Real `.env` files come back with the restic
restore of `/opt`. Pi-hole's settings are in its restored data dir; if not,
`stacks/pihole/ftl-settings.json` and the lists can be applied by hand (README "Pi-hole").

## 7. Check

`docker ps` all healthy, Uptime Kuma green, `systemctl list-timers restic-backup.timer`,
`systemctl --user status jarvis-web kalorie-ai localsend`, `systemctl --user list-timers board.timer vault-tidy.timer morning-summary.timer`,
`ls -l ~/.config/claude/oauth-token.env` (600; restored with /home, else run `claude setup-token` and write
`CLAUDE_CODE_OAUTH_TOKEN=...` into it)
(the board at `https://board.home.example.com` shows a fresh "updated" time), a manual
`sudo systemctl start restic-backup.service` and its log.

## Test log

### 2026-11-02, VM on Serverus (`scripts/test-vm.sh`), snapshot `bc1ee145`

Passed, with these findings (all fixed in the repo the same day):

- `bootstrap.sh -e restore_test=true` on a fresh Ubuntu 24.04 cloud image: OK after three
  playbook fixes: mount handlers now run before the docker role (otherwise a fresh host would
  start Docker with its data root on the root disk); `restore_test` leaves the physical-disk
  fstab lines out (their mount units blocked Docker's `RequiresMountsFor`); `systemd-resolved`
  stub listener off was missing from the host layer (Pi-hole needs port 53). Second run:
  `changed=0`.
- restic: 7.6 GiB in 3 min 48 s from butter. The only error was Docker's own
  `backingFsBlockDev` already existing (harmless).
- Restore procedure fixed (see step 5): copying the whole staging dir onto `/` set `/` to
  `700`. Recovering also showed that powering a VM off hard right after a big copy leaves
  empty files: run `sync` before any hard stop. The backup itself was intact (checked with
  `restic ls`), and `rsync --checksum` per path repaired the copy.
- Stacks started: pihole, caddy (restored Let's Encrypt cert, no new issuance), homepage,
  kalorie, books, vaultwarden (`/alive` OK, healthy), pan-be-staging (WordPress 200, so the
  MariaDB volume came back). Not started on purpose: private-app (live trading), crafty and
  jellyfin, infrastructure (Kuma would send ntfy alerts), ollama.
- Pi-hole came back with the settings of the snapshot (05:30), i.e. without the
  `*.home.example.com` wildcard added later that day: newer settings come from
  `stacks/pihole/ftl-settings.json`.
- Not tested: Crafty from its snapshot, the private app, Jellyfin, Tailscale join, a
  restore from B2.
