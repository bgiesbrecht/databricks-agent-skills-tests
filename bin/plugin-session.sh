#!/usr/bin/env bash
# plugin-session.sh: the lfc-tests plugin's SessionStart hook. Lets the skills run from any folder when this repo is
#   installed as a Claude Code plugin rather than opened as a checkout: sets LFC_TESTS to this copy and puts its bin/
#   on PATH for every Bash command (through $CLAUDE_ENV_FILE), and tells the session (stdout becomes context) that the
#   skills' repo-relative paths (skills/<skill>/..., bin/..., results/...) are under $LFC_TESTS.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  { printf 'export LFC_TESTS=%q\n' "$here"; printf 'export PATH=%q:"$PATH"\n' "$here/bin"; } >> "$CLAUDE_ENV_FILE"
fi
printf 'lfc-tests plugin: paths in its skills that start with skills/, bin/, results/ or docs/ are relative to $LFC_TESTS (%s); run them as "$LFC_TESTS/<path>", from any folder.\n' "$here"
exit 0
