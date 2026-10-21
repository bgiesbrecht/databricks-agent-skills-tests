#!/usr/bin/env bash
# ensure-lima-podman.sh <instance> [--create]
#   Make a Lima VM ready to run test containers with `limactl shell <instance> -- podman --remote ...` (rootful, no sudo):
#   the instance exists (--create makes it with this skill's command), it's running, and ensure-podman-rootless.sh
#   passes inside it (Podman installed, which an existing VM can lack: forgedb-lima-rosetta2-podman, an Ubuntu 25.10 VM,
#   had none; subordinate IDs; linger).
#   Prints one line per step, PASS / FIXED / FAIL / WARN; exit 1 if anything FAILs.
set -uo pipefail
I=${1:?instance name}; CREATE=no; [ "${2:-}" = --create ] && CREATE=yes; fails=0
row() { printf "%-5s %-40s %s\n" "$1" "$2" "$3"; [ "$1" = FAIL ] && fails=$((fails + 1)); return 0; }
command -v limactl >/dev/null || { row FAIL "limactl installed" "brew install lima"; exit 1; }
st=$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v i="$I" '$1 == i {print $2}')
if [ -z "$st" ]; then
  if [ $CREATE = yes ]; then
    limactl start --tty=false --name "$I" --arch aarch64 --vm-type vz --rosetta --cpus 4 --memory 10 --disk 60 template:podman-rootful >/dev/null 2>&1 \
      && row FIXED "instance $I" "created (template:podman-rootful, Rosetta)" || { row FAIL "instance $I" "limactl start failed"; exit 1; }
  else row FAIL "instance $I" "not found: run again with --create, or pick one from limactl list"; exit 1; fi
elif [ "$st" != Running ]; then
  limactl start --tty=false "$I" >/dev/null 2>&1 && row FIXED "instance $I running" "was $st" || { row FAIL "instance $I running" "limactl start failed (was $st)"; exit 1; }
else row PASS "instance $I running" ""; fi
# Podman inside the VM, then rootful Podman without sudo through the root socket (ensure-podman-socket.sh): one store,
# for databases that need rootful and for tests that could run either way. MODE=rootless prepares rootless instead.
if [ "${MODE:-rootful}" = rootless ]; then bash "$(dirname "$0")/ensure-podman-rootless.sh" --on "limactl shell $I --" || fails=$((fails + 1))
else
  limactl shell "$I" -- bash -c 'command -v podman >/dev/null' || bash "$(dirname "$0")/ensure-podman-rootless.sh" --on "limactl shell $I --" >/dev/null
  bash "$(dirname "$0")/ensure-podman-socket.sh" --on "limactl shell $I --" || fails=$((fails + 1))
fi
limactl shell "$I" -- bash -c 'ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -q -i rosetta' && row PASS "Rosetta for x86_64 images" "" \
  || row WARN "Rosetta for x86_64 images" "not registered: only arm64 images run"
exit $((fails > 0))
