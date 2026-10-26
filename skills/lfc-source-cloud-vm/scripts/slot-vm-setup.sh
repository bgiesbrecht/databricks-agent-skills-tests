#!/usr/bin/env bash
# slot-vm-setup.sh: as root on a new Ubuntu 24.04 VM, make it a slot.sh host with its own JuiceFS volume:
#   podman, fuse3, jq and the JuiceFS client; the data disk as XFS at /var/lib/containers (disk-setup.sh); Redis for the
#   metadata (127.0.0.1 only, unless META_URL names another store); the volume formatted if it's new, mounted at /mnt/jfs at boot (lfc-jfs.service); slot.sh,
#   slot-ssh.sh and the login user `slot` (references/shared-vm-slots.md). Safe to rerun.
# Before it runs: /etc/juicefs/azure.env (mode 600) with AZURE_STORAGE_CONNECTION_STRING for the volume's container
#   (references/juicefs-branches.md, "Access"). Next to it: disk-setup.sh, slot.sh, slot-ssh.sh.
# Settings (environment): VOLUME (the JuiceFS volume name), BUCKET (https://<container>.core.windows.net), HOST (the
#   address slot.sh prints), DISK (default /dev/disk/azure/scsi1/lun0), CACHE_MB (default half the data disk),
#   SLOT_SETTINGS (more lines for /etc/lfc-slot.env, e.g. MAX_PER_OWNER=0), META_URL (a metadata store JuiceFS
#   supports, without the password, e.g. postgres://<role>@<host>:5432/<database>?sslmode=require for a managed
#   Postgres; its password goes in azure.env as META_PASSWORD; default: the local Redis).
#   KIND=personal: slot.sh's state goes on the volume at /mnt/jfs/.state (it comes back with the data when the VM is
#   rebuilt), and its lock stays on the VM's disk (LOCK=/var/lib/lfc/lock). Any other value: as before.
#   RESTORE_DUMP=<gzipped juicefs dump>: when the metadata store is empty, load this dump into it instead of formatting
#   the volume (a VM rebuilt over the data its volume has in object storage). Without it, an empty store is formatted.
#   JFS_VERSION=<x.y.z>: install this JuiceFS release (when the client isn't installed yet). Unset: the latest release.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
: "${VOLUME:?VOLUME=<volume name>}" "${BUCKET:?BUCKET=https://<container>.core.windows.net}" "${HOST:?HOST=<public address>}"
DISK=${DISK:-/dev/disk/azure/scsi1/lun0}
[ -s /etc/juicefs/azure.env ] || { echo "no /etc/juicefs/azure.env: write the storage connection string first"; exit 1; }
PERSONAL=0; [ "${KIND:-}" = personal ] && PERSONAL=1
chmod 600 /etc/juicefs/azure.env
step() { echo "== $*"; }

step "packages (after cloud-init's own)"
cloud-init status --wait >/dev/null 2>&1 || true
export DEBIAN_FRONTEND=noninteractive
command -v podman >/dev/null && command -v jq >/dev/null && dpkg -s fuse3 >/dev/null 2>&1 \
  || { apt-get update -qq && apt-get install -y -qq podman fuse3 jq xfsprogs >/dev/null; }
if ! command -v juicefs >/dev/null; then
  if [ -n "${JFS_VERSION:-}" ]; then V="v${JFS_VERSION#v}"; else V=$(curl -fsSL https://api.github.com/repos/juicedata/juicefs/releases/latest | jq -r .tag_name); fi
  T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
  (cd "$T" && curl -fsSLO "https://github.com/juicedata/juicefs/releases/download/$V/juicefs-${V#v}-linux-amd64.tar.gz" \
    && curl -fsSLO "https://github.com/juicedata/juicefs/releases/download/$V/checksums.txt" \
    && grep " juicefs-${V#v}-linux-amd64.tar.gz" checksums.txt | sha256sum -c - >/dev/null \
    && tar xzf "juicefs-${V#v}-linux-amd64.tar.gz" juicefs && install juicefs /usr/local/bin/)
fi
juicefs version | head -1

step "data disk at /var/lib/containers"
DISK=$DISK MNT=/var/lib/containers bash "$here/disk-setup.sh"
J=/var/lib/containers/jfs; install -d $J/cache $J/redis /mnt/jfs
CACHE_MB=${CACHE_MB:-$(( $(df -m --output=size /var/lib/containers | tail -1) / 2 ))}

if [ -z "${META_URL:-}" ]; then
step "metadata (Redis)"
podman container exists jfs-redis || podman run -d --name jfs-redis --restart=always -p 127.0.0.1:6379:6379 \
  -v $J/redis:/data docker.io/library/redis:7 redis-server --appendonly yes --appendfsync everysec >/dev/null
systemctl enable --now podman-restart.service >/dev/null 2>&1
for _ in $(seq 1 30); do podman exec jfs-redis redis-cli ping 2>/dev/null | grep -q PONG && break; sleep 2; done
META=redis://127.0.0.1:6379/1
WAIT="ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do podman exec jfs-redis redis-cli ping 2>/dev/null | grep -q PONG && exit 0; sleep 2; done; exit 1'"
else
  step "metadata ($(sed -E 's|://.*@|://...@|' <<<"$META_URL"))"
  META=$META_URL WAIT=""
fi
if ! ( set -a; . /etc/juicefs/azure.env; set +a; juicefs status "$META" >/dev/null 2>&1 ); then
  if [ -n "${RESTORE_DUMP:-}" ]; then   # an empty store with the volume's dump: load it, never format over its data
    [ -s "$RESTORE_DUMP" ] || { echo "no dump at $RESTORE_DUMP"; exit 1; }
    T=$(mktemp); zcat "$RESTORE_DUMP" > "$T"; juicefs load "$META" "$T" >/dev/null; rm -f "$T"
    echo "loaded the metadata of $VOLUME from $RESTORE_DUMP"
  else
    ( set -a; . /etc/juicefs/azure.env; set +a; juicefs format --storage wasb --bucket "$BUCKET" --trash-days 0 "$META" "$VOLUME" >/dev/null )
    echo "formatted $VOLUME"
  fi
fi

step "mount at boot (lfc-jfs.service)"
cat > /etc/systemd/system/lfc-jfs.service <<EOF
[Unit]
Description=JuiceFS volume $VOLUME at /mnt/jfs
Wants=network-online.target podman-restart.service
After=network-online.target podman-restart.service

[Service]
Type=simple
EnvironmentFile=/etc/juicefs/azure.env
$WAIT
ExecStart=/usr/local/bin/juicefs mount --writeback --cache-dir $J/cache --cache-size $CACHE_MB -o allow_other --log /var/log/juicefs.log "$META" /mnt/jfs
ExecStop=/usr/local/bin/juicefs umount /mnt/jfs
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable lfc-jfs >/dev/null 2>&1; systemctl restart lfc-jfs
for _ in $(seq 1 30); do findmnt -t fuse.juicefs /mnt/jfs >/dev/null && break; sleep 2; done
findmnt -t fuse.juicefs /mnt/jfs >/dev/null || { echo "FAIL: /mnt/jfs isn't mounted: journalctl -u lfc-jfs"; exit 1; }
install -d /mnt/jfs/masters /mnt/jfs/dbs
[ $PERSONAL = 0 ] || install -d -m 700 /mnt/jfs/.state

step "slot.sh and the slot user"
install -m 755 "$here/slot.sh" /usr/local/sbin/lfc-slot
install -m 755 "$here/slot-ssh.sh" /usr/local/sbin/lfc-slot-ssh
{ printf 'HOST=%s\n' "$HOST"; [ -z "${SLOT_SETTINGS:-}" ] || printf '%s\n' "$SLOT_SETTINGS"
  [ $PERSONAL = 0 ] || printf 'STATE=/mnt/jfs/.state\nLOCK=/var/lib/lfc/lock\n'; } > /etc/lfc-slot.env
id slot >/dev/null 2>&1 || useradd -m -s /bin/bash slot
echo 'slot ALL=(root) NOPASSWD: /usr/local/sbin/lfc-slot' > /etc/sudoers.d/lfc-slot; chmod 440 /etc/sudoers.d/lfc-slot
visudo -cq
install -d -o slot -g slot -m 700 ~slot/.ssh
touch ~slot/.ssh/authorized_keys; chown slot:slot ~slot/.ssh/authorized_keys; chmod 600 ~slot/.ssh/authorized_keys
echo "OK: $VOLUME mounted at /mnt/jfs (cache $CACHE_MB MiB), lfc-slot installed, HOST=$HOST"
