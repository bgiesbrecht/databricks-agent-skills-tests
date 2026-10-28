#!/usr/bin/env bash
# secret-perms.sh [--fix] <path...>: secret files that another local user can read. Each path is a file or a directory
#   (its files, recursively). Prints the mode and path of each file not limited to its owner; --fix sets it to 600 (and
#   the directories to 700). Exit 0 when all are owner-only (or fixed), 1 when some aren't, 2 on usage.
set -uo pipefail
FIX=; [ "${1:-}" = --fix ] && { FIX=1; shift; }
[ $# -gt 0 ] || { sed -n '2,4p' "$0" >&2; exit 2; }
mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }   # macOS, then Linux
bad=0
while IFS= read -r f; do
  m=$(mode "$f"); [ $(( 8#$m & 8#077 )) -eq 0 ] && continue
  if [ -n "$FIX" ]; then
    if [ -d "$f" ]; then chmod 700 "$f"; else chmod 600 "$f"; fi; echo "fixed $m -> $(mode "$f") $f"
  else echo "$m $f"; bad=1; fi
done < <(find "$@" \( -type f -o -type d \) 2>/dev/null)
exit $bad
