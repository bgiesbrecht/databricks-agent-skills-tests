#!/usr/bin/env bash
# test-validate-model.sh: offline checks of validate-model.py (model format 1) on fixtures/model-*.yaml: both indentations (tables at
# 0 and at 2 spaces), flow and block columns, a value list over two lines; and each refusal with its reason (a missing or float
# version, a missing or doubled row count, a duplicate table or column, a column without a type, a block scalar, a tab, a flow
# collection not closed). Prints "all passed" or the failures; exit 1 on any failure.
#   bash skills/lfc-workload-contract/scripts/test-validate-model.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); FX=$HERE/fixtures; VM=$HERE/validate-model.py
T=$(mktemp -d); fails=0
ok() { printf "  ok    %s\n" "$1"; }
no() { printf "  FAIL  %s\n" "$1"; fails=$((fails + 1)); }
check() { local name=$1; shift; if "$@" > "$T/out" 2>&1; then ok "$name"; else no "$name"; sed 's/^/        /' "$T/out" | tail -5; fi; }

passes() { python3 "$VM" "$FX/$1" > "$T/o" 2>&1 && [ ! -s "$T/o" ]; }
refused() {   # refused <fixture> <words>: exit 1, one line per problem, each word in the output
  local f=$FX/$1 w rc; shift
  python3 "$VM" "$f" > "$T/o" 2>&1; rc=$?
  [ "$rc" = 1 ] || return 1
  for w in "$@"; do grep -qF -- "$w" "$T/o" || return 1; done
}
none_is_usage() { python3 "$VM" > /dev/null 2>&1; [ $? = 2 ]; }

check "tables at indent 0, flow columns, a value list over two lines: passes" passes model-indent0.yaml
check "tables at indent 2, block columns, a comment, version in single quotes: passes" passes model-indent2.yaml
check "no version: refused" refused model-no-version.yaml "missing version"
check "version as a number (1.0): refused" refused model-version-float.yaml 'needs the string "1.0"'
check "no row count: refused" refused model-no-rows.yaml "needs exactly one of"
check "row_count and row_count_per_sf both: refused" refused model-both-rows.yaml "needs exactly one of"
check "row_count as text: refused" refused model-bad-rows.yaml "row_count must be a whole number"
check "no columns: refused" refused model-no-columns.yaml "columns must be a non-empty list"
check "duplicate table: refused" refused model-dup-table.yaml "duplicate table name"
check "duplicate column: refused" refused model-dup-column.yaml "listed twice"
check "column without a type: refused" refused model-no-type.yaml "has no type"
check "block scalar: refused, the line named" refused model-block-scalar.yaml "model-block-scalar.yaml:4:" "block scalars"
check "a tab in the indentation: refused, the line named" refused model-tab.yaml "model-tab.yaml:4:" "a tab"
check "a flow collection not closed: refused" refused model-unclosed.yaml "not closed"
check "no file: usage, exit 2" none_is_usage

rm -rf "${T:?}"
echo; [ $fails -eq 0 ] && echo "all passed" || echo "$fails failed"; exit $((fails > 0))
