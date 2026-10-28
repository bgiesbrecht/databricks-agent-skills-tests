#!/usr/bin/env bash
# ensure-lima-podman.sh <instance> [--create] [--fix-rosetta]
#   Make a Lima VM ready to run test containers with `limactl shell <instance> -- podman --remote ...` (rootful, no sudo):
#   the instance exists (--create makes it with this skill's command), it's running, and ensure-podman-rootless.sh
#   passes inside it (Podman installed, which an existing VM can lack: an existing Ubuntu 25.10 Lima VM,
#   had none; subordinate IDs; linger).
#   Rosetta: an existing VM can lack it (one with "rosetta" in its name had it off, 2026-10-28), and x86_64-only images
#   (SQL Server, Db2, Informix) then fail at start with "Exec format error". --fix-rosetta turns it on for a vz VM:
#   limactl stop, limactl edit --rosetta, limactl start (the VM restarts, so its containers stop).
#   Prints one line per step, PASS / FIXED / FAIL / WARN; exit 1 if anything FAILs.
set -uo pipefail
I=${1:?instance name}; CREATE=no; FIX_ROSETTA=no; fails=0
for a in "${@:2}"; do case $a in --create) CREATE=yes ;; --fix-rosetta) FIX_ROSETTA=yes ;; *) echo "unknown option $a" >&2; exit 2 ;; esac; done
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
rosetta() { limactl shell "$I" -- bash -c 'test -e /proc/sys/fs/binfmt_misc/rosetta'; }
if rosetta; then row PASS "Rosetta for x86_64 images" ""
elif [ $FIX_ROSETTA = yes ]; then
  vt=$(limactl list --format '{{.Name}} {{.VMType}}' 2>/dev/null | awk -v i="$I" '$1 == i {print $2}')
  if [ "$vt" != vz ]; then row FAIL "Rosetta for x86_64 images" "needs a vz VM (this one is $vt): create one with --create"
  elif limactl stop "$I" >/dev/null 2>&1 && limactl edit --tty=false --rosetta "$I" >/dev/null 2>&1 \
       && limactl start --tty=false "$I" >/dev/null 2>&1 && rosetta; then
    row FIXED "Rosetta for x86_64 images" "turned on (limactl edit --rosetta) and registered; the VM restarted"
  else row FAIL "Rosetta for x86_64 images" "limactl stop / edit --rosetta / start didn't register it"; fi
else row WARN "Rosetta for x86_64 images" "not registered: x86_64 images fail with 'Exec format error'; run again with --fix-rosetta (restarts the VM)"; fi
exit $((fails > 0))
