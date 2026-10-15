#!/usr/bin/env bash
# Sync skill files and test files via a Databricks workspace file bridge.
#
# Uploads/downloads individual files (not patches) to avoid notebook format
# corruption. The workspace notebook round-trip prepends a header line to
# every file; this script strips it automatically on pull.
#
# Usage:
#   source env.sh
#   ./sync.sh push [file ...]    # upload skills-repo files to the workspace
#   ./sync.sh pull [file ...]    # download skills-repo files from the workspace
#   ./sync.sh push-tests         # upload this repo's test files
#   ./sync.sh pull-tests         # download this repo's test files
#
# With no file arguments, push/pull use the default skill file list (see below).
# File arguments are paths relative to the skills repo.
#
# Environment variables (set via env.sh / env.local.sh):
#   SKILLS_REPO        Path to the databricks-agent-skills checkout (default: ../databricks-agent-skills)
#   OMNIGENT_WS        Databricks CLI profile for the workspace used as the file bridge
#   DATABRICKS_WS_USER Workspace user (default: the profile's current user)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_REPO="$(cd "${SKILLS_REPO:-$SCRIPT_DIR/../databricks-agent-skills}" && pwd)"
OMNIGENT_WS="${OMNIGENT_WS:?set OMNIGENT_WS (see env.example.sh)}"
WS_USER="${DATABRICKS_WS_USER:-$(databricks current-user me --profile "$OMNIGENT_WS" -o json | jq -r .userName)}"
WS_BASE="/Users/$WS_USER/skill-files"

# Default skill files: the source files that matter (no generated plugin bundles)
DEFAULT_FILES=("CLAUDE.md" "manifest.json")
while IFS= read -r f; do DEFAULT_FILES+=("$f"); done < <(cd "$SKILLS_REPO" && ls skills/databricks-lakeflow-connect/SKILL.md skills/databricks-lakeflow-connect/references/*.md)

# Test files, relative to this repo; stored under $WS_BASE/tests in the workspace
TEST_FILES=()
while IFS= read -r f; do TEST_FILES+=("$f"); done < <(cd "$SCRIPT_DIR" && ls README.md env.sh env.example.sh run.sh summarize.py sync.sh bin/*.sh prompts/*.txt prompts/*/*.txt 2>/dev/null)

strip_notebook_header() {
  local f="$1"
  tail -n +2 "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

# do_push <local-base> <workspace-base> <file>...
do_push() {
  local base="$1" ws="$2"; shift 2
  echo "Pushing $# file(s) to $OMNIGENT_WS:$ws ..."
  for f in "$@"; do dirname "$ws/$f"; done | sort -u | while read -r d; do
    databricks workspace mkdirs "$d" --profile "$OMNIGENT_WS" 2>/dev/null
  done
  for f in "$@"; do
    if [ -f "$base/$f" ]; then
      databricks workspace import "$ws/$f" --file "$base/$f" \
        --format SOURCE --language PYTHON --profile "$OMNIGENT_WS" --overwrite 2>/dev/null \
        && echo "  $f" || echo "  FAIL: $f"
    else
      echo "  SKIP (not found): $f"
    fi
  done
  echo "Done."
}

# do_pull <local-base> <workspace-base> <file>...
do_pull() {
  local base="$1" ws="$2"; shift 2
  echo "Pulling $# file(s) from $OMNIGENT_WS:$ws ..."
  for f in "$@"; do
    mkdir -p "$(dirname "$base/$f")"
    if databricks workspace export "$ws/$f" --profile "$OMNIGENT_WS" > "$base/$f.tmp" 2>/dev/null; then
      strip_notebook_header "$base/$f.tmp"
      mv "$base/$f.tmp" "$base/$f"
      echo "  $f"
    else
      rm -f "$base/$f.tmp"
      echo "  SKIP (not in workspace): $f"
    fi
  done
  echo "Done."
}

case "${1:-push}" in
  push)
    shift
    if [ $# -gt 0 ]; then do_push "$SKILLS_REPO" "$WS_BASE" "$@"; else do_push "$SKILLS_REPO" "$WS_BASE" "${DEFAULT_FILES[@]}"; fi
    ;;
  pull)
    shift
    if [ $# -gt 0 ]; then do_pull "$SKILLS_REPO" "$WS_BASE" "$@"; else do_pull "$SKILLS_REPO" "$WS_BASE" "${DEFAULT_FILES[@]}"; fi
    echo ""
    echo "Next steps (in $SKILLS_REPO):"
    echo "  python3 scripts/skills.py generate"
    echo "  python3 scripts/skills.py validate"
    ;;
  push-tests)
    do_push "$SCRIPT_DIR" "$WS_BASE/tests" "${TEST_FILES[@]}"
    ;;
  pull-tests)
    do_pull "$SCRIPT_DIR" "$WS_BASE/tests" "${TEST_FILES[@]}"
    chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/bin/*.sh 2>/dev/null
    ;;
  *)
    echo "Usage: $0 {push|pull|push-tests|pull-tests} [file ...]"
    echo ""
    echo "  push [file ...]       Upload skills-repo files to the workspace (default: LFC skill + CLAUDE.md + manifest.json)"
    echo "  pull [file ...]       Download skills-repo files from the workspace"
    echo "  push-tests            Upload this repo's test files"
    echo "  pull-tests            Download this repo's test files"
    exit 1
    ;;
esac
