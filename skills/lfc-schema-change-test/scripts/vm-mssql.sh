#!/usr/bin/env bash
# vm-mssql.sh [database]: run T-SQL from stdin as sa on a SQL Server Podman container on a cloud VM (lfc-source-cloud-vm).
#   Needs VM_IP and MSSQL_CONTAINER; optional VM_USER (azureuser), SSH_KEY (~/.ssh/lfc_test_rsa).
#   SQLCMD_FLAGS replaces the output flags (default "-b -W -h -1"); lfc-source-datagen fill.sh needs "-y 0", which
#   prints long values whole.
#   The sa password stays on the VM: sqlcmd reads it from the container's own MSSQL_SA_PASSWORD.
set -euo pipefail
: "${VM_IP:?set VM_IP}" "${MSSQL_CONTAINER:?set MSSQL_CONTAINER}"
#   vm-mssql.sh --env prints the host OS, the Podman version and the container's image and digest instead.
SSH=(ssh -i "${SSH_KEY:-$HOME/.ssh/lfc_test_rsa}" -o BatchMode=yes -o ConnectTimeout=15 "${VM_USER:-azureuser}@$VM_IP")
# rootful, through the root Podman socket, so no sudo (lfc-source-podman ensure-podman-socket.sh); PODMAN="sudo podman" on
# a host without the socket set up
PODMAN=${PODMAN:-podman --remote --url unix:///run/podman/podman.sock}
if [ "${1:-}" = --env ]; then
  "${SSH[@]}" ". /etc/os-release; echo \"Host: \$PRETTY_NAME\"; echo \"Podman: \$(podman --version)\"; $PODMAN inspect --format 'Image: {{.ImageName}} ({{.ImageDigest}})' $MSSQL_CONTAINER"
  # Azure VM: size, region, zone, and the disk the container storage is on (from the instance metadata service)
  "${SSH[@]}" bash -s <<'REMOTE'
curl -sf -H Metadata:true "http://169.254.169.254/metadata/instance/compute?api-version=2021-12-13" > /tmp/imds.json || exit 0
dev=$(readlink -f "$(df --output=source "$(podman --remote --url unix:///run/podman/podman.sock info --format '{{.Store.GraphRoot}}')" | tail -1)")
lun=""; for l in /dev/disk/azure/scsi1/lun*; do [ "$(readlink -f "$l")" = "$dev" ] && lun=${l##*lun}; done
python3 - "$lun" <<"EOF"
import json, sys
c = json.load(open("/tmp/imds.json")); lun = sys.argv[1]
print(f"VM: Azure {c['vmSize']}, region {c['location']}, zone {c.get('zone') or 'none'}")
for d in c["storageProfile"]["dataDisks"]:
    if d["lun"] == lun:
        mbps = int(d["bytesPerSecondThrottle"]) / 1e6
        print(f"Database disk: {d['managedDisk']['storageAccountType']}, {d['diskSizeGB']} GiB, {d['opsPerSecondThrottle']} IOPS, {mbps:.1f} MB/s, host caching {d['caching']}")
EOF
REMOTE

  exit
fi
# Each call uses its own file in the container, so parallel runs don't overwrite each other's SQL.
# ssh exits 255 when it can't connect (a dropped VPN, the laptop's IP changing): retry with the same input, so a step
# isn't silently skipped. Any other exit status is the SQL's own and is returned as is. (`|| rc=$?`: under set -e a
# failing ssh would otherwise exit before the retry.)
IN=$(cat); rc=255
for wait in 5 15 30 60 120; do
  rc=0; printf '%s\n' "$IN" | "${SSH[@]}" "$PODMAN exec -i $MSSQL_CONTAINER sh -c 'f=\$(mktemp); cat > \$f; /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P \"\$MSSQL_SA_PASSWORD\" ${SQLCMD_FLAGS:--b -W -h -1} -d ${1:-master} -i \$f; rc=\$?; rm -f \$f; exit \$rc'" || rc=$?
  [ $rc -ne 255 ] && exit $rc
  echo "ssh to $VM_IP failed; retrying in ${wait}s" >&2; sleep $wait
done
exit $rc
