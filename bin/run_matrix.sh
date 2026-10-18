#!/usr/bin/env bash
# Run the full Lakeflow Connect matrix (see MATRIX.md) against one workspace. LFC_SKIP_LAKEBASE=1 leaves the Lakebase
# tests out (a workspace with no Lakebase project for them).
#
# Usage:
#   LFC_ENV=<name> source env.sh
#   bin/run_matrix.sh                 # all batches, in order
#   bin/run_matrix.sh qbc fcqbc       # only some batches
#
# Batches run one after another so tests on the same connection never race for the same
# default pipeline name. Order matters: qbc creates the Lakebase project and connection that
# fcqbc-lakebase and dml-lakebase use.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/prompts/lfc-matrix"
if [ $# -gt 0 ]; then batches=("$@"); else batches=(qbc fcqbc icdc scdc dml); fi

for b in "${batches[@]}"; do
  case $b in
    qbc|fcqbc|icdc) files=("$M/$b-lakebase.txt" "$M/$b-pg.txt" "$M/$b-mysql.txt" "$M/$b-sqlserver.txt")
                    [ -n "${LFC_ORACLE_CONNECTION:-}" ] && files+=("$M/$b-oracle.txt");;   # Oracle: when the env names its connections
    scdc) files=("$M/$b-lakebase.txt" "$M/$b-pg.txt" "$M/$b-mysql.txt" "$M/$b-sqlserver.txt");;
    dml) files=("$M/dml-lakebase.txt");;
    *) echo "unknown batch: $b (qbc, fcqbc, icdc, scdc, dml)"; exit 1;;
  esac
  [ -n "${LFC_SKIP_LAKEBASE:-}" ] && files=("${files[@]/*-lakebase.txt/}") && files=($(printf '%s\n' "${files[@]}" | grep .))
  echo "### batch $b  $(date -u +%H:%M:%S)"
  "$ROOT/bin/run_batch.sh" "${files[@]}"
done
echo "### done  $(date -u +%H:%M:%S)  results: ${RESULTS_ROOT:-/tmp}"
