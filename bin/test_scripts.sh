#!/usr/bin/env bash
# bin/test_scripts.sh: regression tests for the skills' scripts.
#   Offline (always): shell syntax, every markdown link, the script rules (bin/lint_scripts.py) and SCRIPTS.md, the six TPC schemas through shape.py and ddl.py for seven
#   dialects, a DDL import round trip, the Python fill planner compiles, and the shared DuckDB runners.
#   With databases (PSQL and/or MYSQL set, e.g. PSQL="podman exec -i dg-pg psql -U postgres",
#   MYSQL="podman exec -i dg-my mysql -uroot"): fill TPC-C (1 warehouse) and the TPC-H spec schema (SF 0.1) on each, and
#   check every table is at its target, TPC-H's spec rules, and the audit (0 bad rows). Schemas test_* are dropped first.
#   The planner files must be readable by the client: with podman exec, copy them in and set DIR_PG / DIR_MY to that path.
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd); SK=$R/skills; SS=$SK/lfc-source-statschema/scripts; DG=$SK/lfc-source-datagen/scripts
T=$(mktemp -d); fails=0
ok() { printf "  ok    %s\n" "$1"; }
no() { printf "  FAIL  %s\n" "$1"; fails=$((fails + 1)); }
check() { local name=$1; shift; if "$@" > "$T/out" 2>&1; then ok "$name"; else no "$name"; sed 's/^/        /' "$T/out" | tail -5; fi; }

echo "== offline"
for f in $(find "$SK" -name '*.sh'); do check "bash -n ${f#$SK/}" bash -n "$f"; done
check "links in every skill" python3 "$R/bin/check_links.py" "$SK"
check "script rules: headers, SKILL.md size, rm guards, first-argument flags, jq for one value" python3 "$R/bin/lint_scripts.py"
check "SCRIPTS.md is current" python3 "$R/bin/scripts_index.py" --check
for w in tpcb tpcc tpch tpcdi tpcds tpce; do
  check "shape.py $w" sh -c "uv run -q '$SS/shape.py' '$SK/lfc-source-statschema/schemas/$w.yaml' --sf 0.1 --expected '$T/$w.exp.json' > '$T/$w.yaml'"
  for d in postgres mysql tsql oracle db2 informix databricks; do
    check "ddl.py $w $d" sh -c "uv run -q '$SS/ddl.py' '$T/$w.yaml' --dialect $d | grep -c 'CREATE TABLE' | grep -qv '^0$'"
  done
  check "validate.py $w" uv run -q "$SS/validate.py" "$T/$w.yaml"
done
check "ddl-to-schema.py round trip (TPC-H spec)" bash -c "bash '$DG/tpc/tpc-schema.sh' tpch 0.1 | uv run -q '$SS/ddl-to-schema.py' --dialect mysql > '$T/spec.yaml' \
  && uv run -q '$SS/ddl.py' '$T/spec.yaml' --dialect mysql | uv run -q '$SS/ddl-to-schema.py' --dialect mysql > '$T/spec2.yaml' \
  && python3 -c \"import sys, yaml; f = lambda p: [{k: ([{c: v for c, v in x.items() if c != 'native_type'} for x in v] if k == 'columns' else v) for k, v in t.items()} for t in yaml.safe_load(open(p))['tables']]; sys.exit(f('$T/spec.yaml') != f('$T/spec2.yaml'))\""
check "python fill planner compiles" python3 -m py_compile "$DG/python/fill.py" "$DG/python/planner.py" "$DG/python/drivers.py" "$DG"/python/engines/*.py
check "results/runs/*.jsonl valid, nothing internal" python3 "$SK/lfc-test-results/scripts/record.py" --check
check "results/*.md: nothing internal" python3 -c "import sys, glob, re; sys.path.insert(0, '$SK/lfc-test-results/scripts'); import record; bad = [(f, w) for f in glob.glob('$R/results/*.md') for w in record.leaks({'text': open(f).read()})]; print(bad); sys.exit(bool(bad))"   # the same check as record.py's, version masking included
check "recall.py runs" sh -c "python3 '$SK/lfc-test-results/scripts/recall.py' > /dev/null"
export WANT="10.0.0.0/24 10.9.0.0/24" HAVE="10.0.0.0/16"
check "q.sh missing.sql" sh -c "'$SK/shell-json-scripting/scripts/q.sh' '$SK/lfc-source-firewall/scripts/missing.sql' | grep -qE \"^MISSING='?10.9.0.0/24'?$\""
check "q.py missing.sql" sh -c "uv run -q '$SK/shell-json-scripting/scripts/q.py' '$SK/lfc-source-firewall/scripts/missing.sql' | grep -qE \"^MISSING='?10.9.0.0/24'?$\""

# the schema-change matrix: the results validate and render to the committed table; the commands run offline
DM=$SK/lfc-schema-change-test/scripts
check "ddl-matrix: every result file validates" uv run -q "$DM/ddl-matrix-validate.py" "$R"/results/ddl-matrix/*.yaml
check "ddl-matrix: the rendered table is the committed one" sh -c "uv run -q '$DM/ddl-matrix.py' render | diff -q - '$SK/lfc-schema-change-test/references/ddl-matrix-results.md'"
check "ddl-matrix: sql prints the change-tracking setup and the case" sh -c "uv run -q '$DM/ddl-matrix.py' sql sqlserver ct --cases int-to-bigint | grep -q 'ENABLE CHANGE_TRACKING'"
check "ddl-matrix: bundle has one table per case" sh -c "uv run -q '$DM/ddl-matrix.py' bundle --connection c --catalog k --schema s --source-catalog d --cases int-to-bigint,drop-column --out '$T/b.yml' && grep -c source_table '$T/b.yml' | grep -qx 2"
check "ddl-matrix: collect on saved events: a restart with its row, a stop, and an unfinished update" sh -c "
  mkdir -p '$T/cm' && python3 - '$T/cm' <<'PY'
import json, sys
d = sys.argv[1]
flow = lambda t: f\"main.s.applier_main_s_x_{t}_cdc_flow\"
ev = [{'event_type': 'update_progress', 'level': 'INFO', 'message': 'Update u1 is RUNNING.', 'timestamp': '2026-10-26T22:05:00.000Z'},
      {'event_type': 'flow_progress', 'level': 'WARN', 'message': 'Flow ' + flow('int_to_bigint') + ' has terminated.', 'timestamp': '2026-10-26T22:06:00.000Z', 'origin': {'flow_name': flow('int_to_bigint')},
       'error': {'exceptions': [{'message': '[FLOW_SCHEMA_CHANGED] Flow terminated since it encountered a schema change.'}]}},
      {'event_type': 'flow_progress', 'level': 'ERROR', 'message': 'Failed to resolve flow', 'timestamp': '2026-10-26T22:07:00.000Z', 'origin': {'flow_name': flow('bigint_to_int')},
       'error': {'exceptions': [{'message': \"[CDC_INCOMPATIBLE_SCHEMA_CHANGES.UNSUPPORTED_DATA_TYPE_CHANGE] incompatible\"}]}},
      {'event_type': 'update_progress', 'level': 'INFO', 'message': 'Update u1 is COMPLETED.', 'timestamp': '2026-10-26T22:20:00.000Z'}]
tables = {'int_to_bigint': {'columns': {'id': 'int', 'n': 'bigint'}, 'row': {'id': '3', 'n': '3000000000'}},
          'bigint_to_int': {'columns': {'id': 'int', 'n': 'bigint'}, 'row': None}}
json.dump(ev, open(d + '/events.json', 'w')); json.dump(tables, open(d + '/tables.json', 'w'))
open(d + '/env.yaml', 'w').write('environment:\n  engine: sqlserver\n  product: Azure SQL Database\n  version: test\n  mechanism: ct\n  setup: none\n  source_setup: test\n  pipeline_mode: integrated\n  compute: serverless\n  workspace: {cloud: AWS, region: us-west-2}\n  date: 2026-10-26\n  method: one-case-at-a-time\n  caveats: [test fixture]\n')
PY
  uv run -q '$DM/ddl-matrix.py' collect --events-json '$T/cm/events.json' --tables-json '$T/cm/tables.json' --env '$T/cm/env.yaml' --cases int-to-bigint,bigint-to-int --out '$T/cm/sqlserver-ct-none-2026-10-26.yaml' > '$T/cm/out.txt' && grep -q '^PASS ' '$T/cm/out.txt' && grep -q '^STOP ' '$T/cm/out.txt'"

db() {                                         # db <pg|my> <client> <planner dir>: fill and check two schemas
  local e=$1 cli=$2 dir=$3 dial; [ "$e" = pg ] && dial=postgres || dial=mysql
  echo "== $dial"
  for w in tpcc_s:tpcc tpch_spec:spec; do local db=test_${w%:*} src=${w#*:} y
    if [ "$src" = spec ]; then y=$T/spec.yaml; else uv run -q "$SS/shape.py" "$SK/lfc-source-statschema/schemas/tpcc.yaml" --sf 1 --expected /dev/null > "$T/c.yaml" 2>/dev/null; y=$T/c.yaml; fi
    uv run -q "$SS/ddl.py" "$y" --dialect $dial > "$T/$db.sql"
    if [ "$e" = pg ]; then { echo "DROP SCHEMA IF EXISTS $db CASCADE; CREATE SCHEMA $db; SET search_path = $db;"; cat "$T/$db.sql"; } | $cli -q -v ON_ERROR_STOP=1 > /dev/null 2>&1
      out=$(PSQL="$cli" DIR=$dir bash "$DG/fill.sh" pg $db 2>&1)
    else { echo "DROP DATABASE IF EXISTS $db; CREATE DATABASE $db; USE $db;"; cat "$T/$db.sql"; } | $cli > /dev/null 2>&1
      out=$(MYSQL="$cli" DIR=$dir bash "$DG/fill.sh" my $db 2>&1); fi
    n=$(echo "$out" | awk -F'|' 'NF == 5' | wc -l); short=$(echo "$out" | awk -F'|' 'NF == 5 && $4 != $5' | wc -l)
    [ "$n" -gt 0 ] && [ "$short" -eq 0 ] && ok "$db: $n tables at target" || { no "$db: $short of $n short"; echo "$out" | tail -3 | sed 's/^/        /'; }
    if [ "$src" = spec ]; then
      if [ "$e" = pg ]; then bad=$({ echo "SET search_path = $db;"; sed -E 's/DATEDIFF\(([^,]+), ([^)]+)\)/(\1 - \2)/g' "$DG/tpc/tpch-verify.sql"; } | $cli -At | grep '^bad' | cut -d'|' -f2- | tr '|' '\n' | awk '$1 != 0' | wc -l)
      else bad=$($cli -N $db < "$DG/tpc/tpch-verify.sql" | grep '^bad' | cut -f2- | tr '\t' '\n' | awk '$1 != 0' | wc -l); fi
      [ "$bad" -eq 0 ] && ok "$db: TPC-H spec rules" || no "$db: $bad spec rules broken"
    fi
    if [ "$e" = pg ]; then a=$(cat "$DG/postgres/cast.sql" "$DG/postgres/plan-audit.sql" | $cli -At -q -v schema=$db -v plain_every=4 | $cli -At | awk -F'|' '{ b += $3 } END { print b + 0 }')
    else a=$({ echo "SET @db='$db', @plain_every=4, @block=1000;"; cat "$DG/mysql/cast.sql" "$DG/mysql/plan-audit.sql"; } | $cli -N -B -r $db | $cli -N $db | awk -F'\t' '{ b += $3 } END { print b + 0 }'); fi
    [ "$a" = 0 ] && ok "$db: audit 0 bad rows" || no "$db: audit $a bad rows"
  done
}
[ -n "${PSQL:-}" ] && db pg "$PSQL" "${DIR_PG:-$DG/postgres}"
[ -n "${MYSQL:-}" ] && db my "$MYSQL" "${DIR_MY:-$DG/mysql}"
rm -rf "${T:?}"
echo; [ $fails -eq 0 ] && echo "all passed" || echo "$fails failed"; exit $((fails > 0))
