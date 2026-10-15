#!/usr/bin/env bash
# Run several prompt files in parallel, each in its own scratch WORK_DIR.
#
# Usage:
#   source env.sh
#   bin/run_batch.sh prompts/lfc-matrix/qbc-*.txt
#
# Run tests that create pipelines on the same connection in separate batches, so two
# sessions don't pick the same default pipeline name at once.
#
# Results: /tmp/<name>-results/<tag>.json (summarize with ./summarize.py), logs: /tmp/<name>.log

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -gt 0 ] || { echo "usage: $0 <prompts-file>..."; exit 1; }

for f in "$@"; do
  f="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
  name=$(basename "$f" .txt)
  W=/tmp/$name-work
  rm -rf "$W" "/tmp/$name-results"
  # Tools a deploy test needs. conn.json holds a generated password (Lakebase demo), so allow
  # deleting it by every path a session might use.
  ALLOWED="Read,Write,Edit,Glob,Grep,WebFetch,Bash(databricks:*),Bash(ls:*),Bash(mkdir:*),Bash(jq:*)"
  for p in conn.json "$W/conn.json" "/private$W/conn.json" scratch/conn.json "$W/scratch/conn.json" "/private$W/scratch/conn.json"; do
    ALLOWED="$ALLOWED,Bash(rm $p),Bash(rm -f $p)"
  done
  ( WORK_DIR=$W CLAUDE_ALLOWED_TOOLS="$ALLOWED" "$ROOT/run.sh" "$SKILLS_REPO" "$f" > "/tmp/$name.log" 2>&1 ) &
done
wait
for f in "$@"; do
  name=$(basename "$f" .txt)
  echo "== $name: $(grep -E 'passed|FAILED' "/tmp/$name.log" | tail -1)"
done
