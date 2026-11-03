#!/usr/bin/env bash
# workload.sh --model <model> --sf <scale> --dialect tsql --out <dir>: write a workload for a statschema model (schemas/<model>.yaml,
# the TPC models) shaped at a scale: <dir>/model.yaml (shape.py, checked against model format 1), <dir>/model.sql (ddl.py for the
# dialect), and <dir>/workload.json (workload contract 1, lfc-workload-contract), whose fill_cmd and bundle_cmd are this folder's
# copies.sh and bundle.sh. Prints the workload file's path. Needs uv (shape.py and ddl.py run through it). Exit 2 with one line
# when a step fails; the workload file is checked by the contract's workload-env.sh before the path is printed.
#   bash skills/lfc-source-datagen/scripts/workload.sh --model tpcc --sf 0.01 --dialect tsql --out /abs/work/tpcc
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SK=$HERE/../..
SCH=$SK/lfc-source-statschema; CON=$SK/lfc-workload-contract/scripts
MODEL= SF= DIALECT= OUT=
die() { echo "workload.sh: $*" >&2; exit 2; }
usage() { sed -n 2,5p "$0" >&2; exit 2; }

while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case $1 in
    --model) MODEL=$2 ;;
    --sf) SF=$2 ;;
    --dialect) DIALECT=$2 ;;
    --out) OUT=$2 ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$MODEL" ] && [ -n "$SF" ] && [ -n "$DIALECT" ] && [ -n "$OUT" ] || usage

case $MODEL in *[!a-z0-9_]*|"") die "--model must be a lowercase name: $MODEL" ;; esac
[ -r "$SCH/schemas/$MODEL.yaml" ] || die "no model $MODEL (no schemas/$MODEL.yaml in lfc-source-statschema)"
case $SF in *[!0-9.]*|""|.*|*.|*.*.*) die "--sf must be a number such as 0.01 or 10: $SF" ;; esac
awk -v s="$SF" 'BEGIN { exit !(s + 0 > 0) }' || die "--sf must be above 0: $SF"
# the fill command is copies.sh, which fills SQL Server (ms) only; other dialects get their DDL from ddl.py alone
[ "$DIALECT" = tsql ] || die "--dialect $DIALECT: only tsql has a fill command so far (copies.sh fills SQL Server)"
ENGINE=ms
command -v uv > /dev/null 2>&1 || die "needs uv (shape.py and ddl.py run through it)"

mkdir -p "$OUT" || die "can't make $OUT"
OUT=$(cd "$OUT" && pwd)
case $OUT$HERE in *" "*) die "the paths of the output folder and of this skill can't have a space (the workload file's paths are words)" ;; esac
TMPD=$(mktemp -d); trap 'rm -rf "${TMPD:?}"' EXIT

uv run -q "$SCH/scripts/shape.py" "$SCH/schemas/$MODEL.yaml" --sf "$SF" --expected "$TMPD/expected.json" > "$OUT/model.yaml" 2> "$TMPD/shape.err" \
  || die "shape.py failed: $(tail -2 "$TMPD/shape.err" | tr '\n' ' ')"
python3 "$CON/validate-model.py" "$OUT/model.yaml" > "$TMPD/model.err" \
  || die "model.yaml breaks model format 1: $(head -3 "$TMPD/model.err" | tr '\n' ' ')"
uv run -q "$SCH/scripts/ddl.py" "$OUT/model.yaml" --dialect "$DIALECT" > "$OUT/model.sql" 2> "$TMPD/ddl.err" \
  || die "ddl.py failed: $(tail -2 "$TMPD/ddl.err" | tr '\n' ' ')"
TB=$(grep -o -E '^CREATE TABLE \[[A-Za-z_0-9]+\]' "$OUT/model.sql" | sed -E 's/.*\[(.*)\]/\1/')
[ -n "$TB" ] || die "no CREATE TABLE in $OUT/model.sql"
TABLES=$(printf '%s\n' "$TB" | jq -R -s -c 'split("\n") | map(select(length > 0))')

jq -n -c --arg model "$MODEL" --argjson scale "$SF" --arg dialect "$DIALECT" --argjson tables "$TABLES" \
  --arg ddl "$OUT/model.sql" --arg fill "bash $HERE/copies.sh $ENGINE" --arg bundle "bash $HERE/bundle.sh" \
  '{contract: 1, model: $model, scale: $scale, dialect: $dialect, tables: $tables, ddl: $ddl, fill_cmd: $fill, bundle_cmd: $bundle}' \
  > "$OUT/workload.json" || die "can't write $OUT/workload.json"
bash "$CON/workload-env.sh" "$OUT/workload.json" > /dev/null || die "the workload file fails its contract (the line above)"
echo "workload.sh: $MODEL at SF $SF, $(printf '%s\n' "$TB" | wc -l | tr -d ' ') tables, $DIALECT" >&2
echo "$OUT/workload.json"
