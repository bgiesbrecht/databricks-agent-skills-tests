#!/usr/bin/env bash
# matrix.sh: debezium-zerobus.sh over every combination of SOURCES x MODELS x NSRCS (the scale-out grid: databases,
# models, and how many source databases merge into one silver), at most PARALLEL runs at once, and one table of results.
#
#   PROFILE=<cli profile> CATALOG=<catalog> VM_IP=<vm> \
#   SOURCES="pg mssql oracle" MODELS="tpch tpcb tpcc tpcds tpce tpcdi" NSRCS="1 2 4" PARALLEL=2 \
#     bash skills/zerobus-debezium-test/scripts/matrix.sh
#
# Each run gets its own copy of the skills folder (bash reads a script as it runs, so editing the scripts or starting
# another run can't change one in progress), its own log and result file in RESULTS (default
# ~/.lfc-test/results/matrix-<UTC time>), and a free port. A run cleans up after itself (debezium-zerobus.sh's trap).
# PARALLEL: one run per two vCPUs (2 on a 4-vCPU VM), when the VM's memory allows (SKILL.md, Choosing PARALLEL): a
# database container takes 0.5 (PostgreSQL) to 4 GB (SQL Server, Oracle), and each producer (Debezium Server) about
# 0.4 GB, one per source database. With NSRC=4 a run has 4 producers. Other sessions' containers share the VM.
# Every other setting (SF, ROUNDS, BRONZE, LFC_PERF_DIR, KEEP, ...) passes through to every run. ROUNDS defaults per
# source (debezium-zerobus.sh: 3 for SQL Server and Oracle so far, 5 otherwise).
# RESULTS/summary.md: one row per run, source, model, sources, exit (0 every claim passed, 1 one failed, 2 a
# prerequisite missing), claims passed and failed, the first failure, minutes. Exit 0 only when every run exited 0.
set -uo pipefail
: "${PROFILE:?}" "${CATALOG:?}" "${VM_IP:?}"
# bash reads a script as it runs: run from a copy, so editing this file can't change a matrix in progress (an edit
# did: "syntax error near unexpected token" at the end of a 2026-10-24 matrix)
if [ -z "${MATRIX_SELF:-}" ]; then c=$(mktemp "${TMPDIR:-/tmp}/matrix.XXXXXX"); cp "$0" "$c"
  MATRIX_SELF=$(cd "$(dirname "$0")" && pwd) exec bash "$c" "$@"; fi
SOURCES=${SOURCES:-pg}; MODELS=${MODELS:-tpch}; NSRCS=${NSRCS:-1}; PARALLEL=${PARALLEL:-2}
SKILLS=$(cd "$MATRIX_SELF/../.." && pwd); rm -f "$0"
RESULTS=${RESULTS:-$HOME/.lfc-test/results/matrix-$(date -u +%Y%m%dT%H%M%SZ)}; mkdir -p "$RESULTS"
echo "matrix: sources [$SOURCES] x models [$MODELS] x NSRC [$NSRCS], $PARALLEL at a time, into $RESULTS"
# the runs' numbers go only where LFC_PERF_DIR points (debezium-zerobus.sh); unset, nothing records them
[ -n "${LFC_PERF_DIR:-}" ] || echo "matrix: LFC_PERF_DIR isn't set: the runs' timings won't be recorded anywhere but their logs"

run_one() { # run_one <source> <model> <nsrc> <port>
  local s=$1 m=$2 n=$3 port=$4 name="$1-$2-n$3" dir t0=$SECONDS rc
  dir=$(mktemp -d "${TMPDIR:-/tmp}/matrix-$name.XXXXXX")
  COPYFILE_DISABLE=1 tar -C "$SKILLS/.." --exclude __pycache__ -cf - "$(basename "$SKILLS")" | tar -xf - -C "$dir"
  (cd "$dir/skills/zerobus-debezium-test" && SOURCE=$s MODEL=$m NSRC=$n SRC_PORT=$port OUT="$RESULTS/$name.md" \
    RECORD_OUT="$RESULTS/$name.record.json" RECORD_RUN="${RECORD_RUN:-$(date -u +%F)-zerobus-matrix}" \
    bash scripts/debezium-zerobus.sh > "$RESULTS/$name.log" 2>&1); rc=$?
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$s" "$m" "$n" "$rc" "$(grep -c '^PASS' "$RESULTS/$name.log")" \
    "$(grep -c '^FAIL' "$RESULTS/$name.log")" "$(grep -m1 -E '^FAIL|failed' "$RESULTS/$name.log" | cut -c1-120 | tr '\t|' '  ')" \
    "$(( (SECONDS - t0) / 60 ))" >> "$RESULTS/rows.tsv"
  rm -rf "${dir:?}"
  echo "done $name: exit $rc ($(( (SECONDS - t0) / 60 )) min)"
}

port=30040; jobs_running() { jobs -rp | wc -l | tr -d ' '; }
for s in $SOURCES; do for m in $MODELS; do for n in $NSRCS; do
  while [ "$(jobs_running)" -ge "$PARALLEL" ]; do sleep 20; done
  echo "start $s-$m-n$n (port $port or the next free one)"
  run_one "$s" "$m" "$n" "$port" &
  port=$((port + 1)); [ "$port" -gt 30063 ] && port=30040
  sleep 30   # one container start at a time on the VM
done; done; done
wait

{ echo "| Source | Model | Sources | Exit | Passed | Failed | First failure | Minutes |"; echo "|---|---|---|---|---|---|---|---|"
  sort "$RESULTS/rows.tsv" | awk -F'\t' '{printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7, $8}'; } > "$RESULTS/summary.md"
cat "$RESULTS/summary.md"
cat "$RESULTS"/*.record.json > "$RESULTS/records.jsonl" 2>/dev/null \
  && echo "coverage records: $RESULTS/records.jsonl (look, then: uv run skills/lfc-test-results/scripts/record.py < it)"
awk -F'\t' '$4 != 0 {bad = 1} END {exit bad}' "$RESULTS/rows.tsv"
