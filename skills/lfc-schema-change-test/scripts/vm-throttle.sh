#!/usr/bin/env bash
# vm-throttle.sh <MB/s | off | show>: limit the disk reads and writes of the source container on its cloud VM, through
# the container's cgroup v2 io.max (no restart), to see how a slow source disk changes a load. `off` removes the limit;
# `show` prints it. Also drops SQL Server's clean buffers with `<MB/s> --cold` (needs SRC_SQL), so reads go to the disk.
#   Needs VM_IP and MSSQL_CONTAINER (as vm-mssql.sh); optional VM_USER (azureuser), SSH_KEY (~/.ssh/lfc_test_rsa).
#   vm-throttle.sh 20 --cold; ... run the test ...; vm-throttle.sh off
set -euo pipefail
: "${VM_IP:?set VM_IP}" "${MSSQL_CONTAINER:?set MSSQL_CONTAINER}" "${1:?MB/s, off or show}"
SSH=(ssh -i "${SSH_KEY:-$HOME/.ssh/lfc_test_rsa}" -o BatchMode=yes -o ConnectTimeout=15 "${VM_USER:-azureuser}@$VM_IP")
"${SSH[@]}" bash -s "$1" "$MSSQL_CONTAINER" <<'REMOTE'
set -euo pipefail
P="podman --remote --url unix:///run/podman/podman.sock"
F=/sys/fs/cgroup$($P inspect --format '{{.State.CgroupPath}}' "$2")/io.max
# the block device the container storage is on (a partition's parent disk)
dev=$(df --output=source "$($P info --format '{{.Store.GraphRoot}}')" | tail -1); parent=$(lsblk -no PKNAME "$dev"); [ -n "$parent" ] && dev=/dev/$parent
mm=$(lsblk -dno MAJ:MIN "$dev" | tr -d ' ')
case $1 in
  show) ;;
  off) echo "$mm rbps=max wbps=max riops=max wiops=max" | sudo tee "$F" >/dev/null;;
  *[!0-9]*) echo "vm-throttle.sh: MB/s must be a number, off or show"; exit 2;;
  *) b=$(( $1 * 1024 * 1024 )); echo "$mm rbps=$b wbps=$b" | sudo tee "$F" >/dev/null;;
esac
echo "device $dev ($mm), io.max: $(cat "$F" || true)"
REMOTE
if [ "${2:-}" = --cold ]; then
  : "${SRC_SQL:?--cold needs SRC_SQL}"
  printf 'CHECKPOINT; DBCC DROPCLEANBUFFERS;\n' | $SRC_SQL master >/dev/null && echo "SQL Server clean buffers dropped"
fi
