#!/usr/bin/env bash
# slot-sql.sh [database]: run SQL from stdin as the engine's admin in your own database on a source VM (slot.sh,
# lfc-source-cloud-vm references/shared-vm-slots.md), through your slot key: no VM admin login needed, and only your
# own databases are reachable. The SRC_SQL of the harness for a database from slot.sh up.
#   Needs SLOT_HOST (the VM's address: host in slot.sh up's JSON) and SLOT_NAME (the database's name); optional SLOT_KEY
#   (~/.ssh/lfc_slot_ed25519). SQLCMD_FLAGS with -y (lfc-source-datagen fill.sh's "-b -y 0") asks for long values whole.
#   slot-sql.sh --env prints the host OS, the Podman version, the image and digest, and the VM instead (SRC_ENV).
set -euo pipefail
: "${SLOT_HOST:?set SLOT_HOST}" "${SLOT_NAME:?set SLOT_NAME}"
SSH=(ssh -i "${SLOT_KEY:-$HOME/.ssh/lfc_slot_ed25519}" -o BatchMode=yes -o ConnectTimeout=15 "slot@$SLOT_HOST")
if [ "${1:-}" = --env ]; then
  exec "${SSH[@]}" info "$SLOT_NAME"
fi
WIDE=""; case ${SQLCMD_FLAGS:-} in *-y*) WIDE=--wide ;; esac
# ssh exits 255 when it can't connect (a dropped VPN, the laptop's IP changing): retry with the same input, so a step
# isn't silently skipped. Any other exit status is the SQL's own and is returned as is.
IN=$(cat); rc=255
for wait in 5 15 30 60 120; do
  rc=0; printf '%s\n' "$IN" | "${SSH[@]}" sql "$SLOT_NAME" ${1:+"$1"} ${WIDE:+"$WIDE"} || rc=$?
  [ $rc -ne 255 ] && exit $rc
  echo "ssh to $SLOT_HOST failed; retrying in ${wait}s" >&2; sleep "$wait"
done
exit $rc
