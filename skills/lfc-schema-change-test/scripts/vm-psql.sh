#!/usr/bin/env bash
# vm-psql.sh [database]: run SQL from stdin as postgres on a PostgreSQL Podman container on a cloud VM
# (lfc-source-cloud-vm). Needs VM_IP and PG_CONTAINER; optional VM_USER (azureuser), SSH_KEY (~/.ssh/lfc_test_rsa).
# No password crosses the network: psql runs inside the container as the local superuser.
#   vm-psql.sh --env prints the host OS, the Podman version and the container's image and digest instead.
set -euo pipefail
: "${VM_IP:?set VM_IP}" "${PG_CONTAINER:?set PG_CONTAINER}"
SSH=(ssh -i "${SSH_KEY:-$HOME/.ssh/lfc_test_rsa}" -o BatchMode=yes -o ConnectTimeout=15 "${VM_USER:-azureuser}@$VM_IP")
PODMAN=${PODMAN:-podman --remote --url unix:///run/podman/podman.sock}
if [ "${1:-}" = --env ]; then
  "${SSH[@]}" ". /etc/os-release; echo \"Host: \$PRETTY_NAME\"; echo \"Podman: \$(podman --version)\"; $PODMAN inspect --format 'Image: {{.ImageName}} ({{.ImageDigest}})' $PG_CONTAINER"
  exit
fi
# ssh exits 255 when it can't connect (a dropped VPN, the laptop's IP changing): retry with the same input, so a step
# isn't silently skipped. Any other exit status is the SQL's own and is returned as is. (`|| rc=$?`: under set -e a
# failing ssh would otherwise exit before the retry.)
IN=$(cat); rc=255
for wait in 5 15 30 60 120; do
  rc=0; printf '%s\n' "$IN" | "${SSH[@]}" "$PODMAN exec -i $PG_CONTAINER psql -U postgres -d ${1:-postgres} -v ON_ERROR_STOP=1 -qtAX -F \$'\t'" || rc=$?
  [ $rc -ne 255 ] && exit $rc
  echo "ssh to $VM_IP failed; retrying in ${wait}s" >&2; sleep $wait
done
exit $rc
