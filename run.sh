#!/usr/bin/env bash
# Skill test runner -- runs headless Claude sessions against a prompt file.
#
# Usage:
#   ./run.sh [skills-repo] [prompts-file]
#
# Arguments:
#   skills-repo   Path to the databricks-agent-skills checkout whose skills are tested
#                 (default: $SKILLS_REPO, else ../databricks-agent-skills next to this repo)
#   prompts-file  Prompts file, relative to this repo or absolute (default: prompts/lakeflow-connect.txt)
#
# Environment variables (set via env.sh, which sources env.local.sh):
#   PIPELINE_WS   Databricks CLI profile passed to Claude as DATABRICKS_CONFIG_PROFILE (default: DEFAULT)
#   CLAUDE_ALLOWED_TOOLS  Comma-separated tool allowlist for deploy tests, passed as one --allowedTools
#                 argument so rules with spaces work, e.g. 'Bash(databricks:*),Bash(rm -f conn.json)'
#   CLAUDE_ARGS   Other extra flags for claude -p; split on spaces, so no values with spaces (default: none)
#   WORK_DIR      Directory each session runs in (default: a fresh /tmp/<prompts-name>-work). Keep it
#                 outside the skills repo so skills load from the plugin cache, not the checkout.
#
# Prompts file: one `tag|prompt` per line. A `tag+|text` line is a follow-up turn: it resumes
# the session started by `tag` and appends to the same output file (use it to answer the
# questions a skill asks before creating resources). `${VAR}` in a prompt is replaced with the
# environment variable VAR (see env.example.sh); an unset variable stops the run.
#
# Examples:
#   source env.sh
#   ./run.sh
#   ./run.sh ~/github/databricks-agent-skills prompts/lakeflow-connect.txt
#   bin/run_batch.sh prompts/lfc-matrix/qbc-*.txt

PIPELINE_WS="${PIPELINE_WS:-DEFAULT}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${1:-${SKILLS_REPO:-$SCRIPT_DIR/../databricks-agent-skills}}"
if [ ! -d "$REPO_DIR/skills" ]; then
  echo "ERROR: no skills/ in $REPO_DIR (pass the skills repo path or set SKILLS_REPO)"
  exit 1
fi
PROMPTS_ARG="${2:-prompts/lakeflow-connect.txt}"
WORK_DIR="${WORK_DIR:-/tmp/$(basename "${2:-lakeflow-connect}" .txt)-work}"
mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

# Resolve prompts file: if relative, look under SCRIPT_DIR
if [ "${PROMPTS_ARG:0:1}" = "/" ]; then
  PROMPTS="$PROMPTS_ARG"
else
  PROMPTS="$SCRIPT_DIR/$PROMPTS_ARG"
fi

if [ ! -f "$PROMPTS" ]; then
  echo "ERROR: Prompts file not found: $PROMPTS"
  exit 1
fi

# Derive results dir from the prompts file name (e.g. lakeflow-connect -> /tmp/lakeflow-connect-results)
SKILL_NAME=$(basename "$PROMPTS" .txt)
RESULTS_DIR="/tmp/${SKILL_NAME}-results"
mkdir -p "$RESULTS_DIR"

echo "=== Skill Test Runner ==="
echo "Repo:        $(cd "$REPO_DIR" && pwd)"
echo "Prompts:     $PROMPTS"
echo "Results:     $RESULTS_DIR"
echo "Pipeline WS: $PIPELINE_WS  (DATABRICKS_CONFIG_PROFILE for Claude)"
echo "Work dir:    $WORK_DIR"
[ -n "$CLAUDE_ALLOWED_TOOLS" ] && echo "Allowed:     $CLAUDE_ALLOWED_TOOLS"
[ -n "$CLAUDE_ARGS" ] && echo "Claude args: $CLAUDE_ARGS"
echo ""

# --- Plugin cache: patch with local skill files ---

# Extract skill name from the prompts directory or let it find all lakeflow-connect-like paths
CACHE_DIRS=$(find ~/.claude/plugins/cache -path "*/databricks/*/skills/databricks-*" -type d 2>/dev/null)

if [ -z "$CACHE_DIRS" ]; then
  echo "Plugin cache missing. Rebuilding with a quick claude call..."
  (cd "$REPO_DIR" && DATABRICKS_CONFIG_PROFILE="$PIPELINE_WS" claude -p "hello" --output-format text > /dev/null 2>&1) < /dev/null
  CACHE_DIRS=$(find ~/.claude/plugins/cache -path "*/databricks/*/skills/databricks-*" -type d 2>/dev/null)
fi

if [ -n "$CACHE_DIRS" ]; then
  CACHE_ROOT=$(echo "$CACHE_DIRS" | head -1 | sed 's|/skills/databricks-.*|/skills|')
  echo "Plugin cache skills dir: $CACHE_ROOT"

  # Copy all local skill directories into the cache
  if [ -d "$REPO_DIR/skills" ]; then
    for skill_dir in "$REPO_DIR"/skills/databricks-*/; do
      skill_basename=$(basename "$skill_dir")
      if [ -d "$CACHE_ROOT/$skill_basename" ]; then
        cp "$skill_dir/SKILL.md" "$CACHE_ROOT/$skill_basename/" 2>/dev/null
        if [ -d "$skill_dir/references" ]; then
          mkdir -p "$CACHE_ROOT/$skill_basename/references"
          cp "$skill_dir/references/"*.md "$CACHE_ROOT/$skill_basename/references/" 2>/dev/null
        fi
      fi
    done
    echo "Plugin cache updated with local skill files."
  fi
else
  echo "WARNING: Could not find or create plugin cache. Tests may use stale skill content."
fi
echo ""

# --- Run prompts ---

pass=0
fail=0

while IFS='|' read -r tag prompt; do
  [ -z "$tag" ] && continue
  # Fill ${VAR} placeholders from the environment; stop on an unset one
  if ! prompt=$(printf '%s' "$prompt" | perl -pe 's/\$\{(\w+)\}/defined $ENV{$1} ? $ENV{$1} : die "unset variable $1\n"/ge'); then
    echo "[$tag] SKIPPED: prompt uses an unset variable (see env.example.sh)"
    fail=$((fail + 1))
    continue
  fi
  resume_args=()
  if [ "${tag%+}" != "$tag" ]; then
    # Follow-up turn: resume the base tag's session and append to its output
    tag="${tag%+}"
    outfile="$RESULTS_DIR/${tag}.json"
    session_id=$(grep -m1 -o '"session_id":"[^"]*"' "$outfile" 2>/dev/null | cut -d'"' -f4)
    if [ -z "$session_id" ]; then
      echo "[$tag+] SKIPPED: no session to resume in $outfile"
      fail=$((fail + 1))
      continue
    fi
    resume_args=(--resume "$session_id")
    echo "[$tag+] Follow-up: $prompt"
  else
    outfile="$RESULTS_DIR/${tag}.json"
    : > "$outfile"
    : > "$RESULTS_DIR/${tag}.err"
    echo "[$tag] Running: $prompt"
  fi
  errfile="$RESULTS_DIR/${tag}.err"

  (
    cd "$WORK_DIR"
    # shellcheck disable=SC2086  # CLAUDE_ARGS is intentionally word-split
    DATABRICKS_CONFIG_PROFILE="$PIPELINE_WS" claude -p "$prompt" \
      "${resume_args[@]}" \
      ${CLAUDE_ALLOWED_TOOLS:+--allowedTools "$CLAUDE_ALLOWED_TOOLS"} \
      --verbose \
      --output-format stream-json \
      $CLAUDE_ARGS \
      >> "$outfile" 2>>"$errfile"
  ) < /dev/null

  exit_code=$?
  lines=$(wc -l < "$outfile" 2>/dev/null || echo 0)

  if [ $exit_code -ne 0 ]; then
    echo "[$tag] FAILED (exit $exit_code)"
    [ -s "$errfile" ] && echo "[$tag] stderr: $(head -5 "$errfile")"
    fail=$((fail + 1))
  else
    echo "[$tag] done -> $outfile ($lines lines)"
    pass=$((pass + 1))
  fi
  echo ""
done < "$PROMPTS"

echo "=== $pass passed, $fail failed ==="
echo "Summarize: python3 $SCRIPT_DIR/summarize.py $RESULTS_DIR"
