#!/usr/bin/env bash
# secret-find.sh <file> <field|-> [dir...]: where a secret's value appears, without printing it. Lists every file under
#   the dirs that contains the value (default: ~/.claude, $TMPDIR, the current directory) and, for each git checkout
#   in or up to 3 levels under a dir, the commits on any branch that add or remove it (git log -S). <file> and <field> as in secret-run.sh.
#   Exit 0 when the value is found nowhere but <file>, 1 when it is found elsewhere (a leak to clean up), 2 on usage.
#   After a leak: rotate the secret first (the value is out), then update every copy that holds it.
#   git log -S takes the value as an argument, so it shows in the process list while the search runs.
set -uo pipefail
[ $# -ge 2 ] || { sed -n '2,7p' "$0" >&2; exit 2; }
F=$1 K=$2; shift 2
[ -r "$F" ] || { echo "secret-find: can't read $F" >&2; exit 2; }
if [ "$K" = - ]; then V=$(cat "$F"); else V=$(yq -r "$K // \"\"" "$F"); fi
[ ${#V} -ge 6 ] || { echo "secret-find: value at $K is empty or under 6 characters: too short to search for" >&2; exit 2; }
[ $# -gt 0 ] || set -- "$HOME/.claude" "${TMPDIR:-/tmp}" "$PWD"
real() { cd "$(dirname "$1")" 2>/dev/null && echo "$(pwd -P)/$(basename "$1")"; }
SELF=$(real "$F"); hits=0
for d in "$@"; do
  [ -e "$d" ] || continue
  while IFS= read -r f; do
    [ "$(real "$f")" = "$SELF" ] && continue
    echo "file: $f"; hits=$((hits + 1))
  done < <(grep -rlF --exclude-dir=node_modules --exclude-dir=.venv -f <(printf '%s\n' "$V") "$d" 2>/dev/null)   # pattern from a pipe, not argv
  # git history: the dir's own checkout and every checkout up to 3 levels below it (worktrees have a .git file)
  while IFS= read -r g; do
    while IFS= read -r c; do echo "commit: $g $c"; hits=$((hits + 1)); done \
      < <(git -C "$g" log --all -S"$V" --format='%h %ad %s' --date=short 2>/dev/null)
  done < <({ git -C "$d" rev-parse --show-toplevel 2>/dev/null
             find "$d" -maxdepth 4 -name .git -prune 2>/dev/null | sed 's|/\.git$||'; } | sort -u)
done
unset V
[ $hits = 0 ] && { echo "secret-find: found only in $F"; exit 0; }
echo "secret-find: $hits place(s) besides $F"; exit 1
