#!/usr/bin/env bash
# ag-down.sh [--keep-data]: remove the ag-up.sh containers <AG_NAME>-p/-s and their network; without --keep-data also
# the state directory AG_DIR (data, certificates, passwords). Environment: AG_NAME, AG_DIR, PODMAN as in ag-up.sh.
set -euo pipefail
N=${AG_NAME:-lfc-ag}; D=${AG_DIR:-$HOME/$N}; PM=${PODMAN:-podman}
case $N in (""|*[!A-Za-z0-9_-]*) echo "bad AG_NAME" >&2; exit 2;; esac
for r in p s; do $PM rm -f "$N-$r" >/dev/null 2>&1 && echo "removed $N-$r" || true; done
$PM network rm "$N-net" >/dev/null 2>&1 || true
if [ "${1:-}" != --keep-data ]; then
  case $D in (/|"$HOME"|/root|/home|/var|/tmp|"") echo "refusing to remove $D" >&2; exit 2;; esac
  $PM unshare rm -rf "${D:?}" 2>/dev/null || rm -rf "${D:?}"; echo "removed $D"
fi
