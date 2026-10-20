#!/usr/bin/env bash
# sqlserver-add-column.sh: when does ADD COLUMN on a SQL Server source need a full refresh? Runs the claims end to end on
# standard CDC (serverless gateway + ingestion pipeline) against a fresh database, then deletes everything it made.
#
#   Needs:    PROFILE     Databricks CLI profile
#             CONNECTION  UC SQLSERVER connection to the source
#             CATALOG     catalog with its own storage (not Default Storage) and a working credential
#             SRC_SQL     command that runs T-SQL from stdin on the source as an admin; first arg = database
#   Optional: SRC_ENV     command that prints the source environment (host, Podman, image), one fact per line
#                         (for a VM container: scripts/vm-mssql.sh)
#             CONN_USER   the connection's login on the source
#   Optional: PREFIX (default: the CLI user's firstnamelastname), WAREHOUSE (default: first serverless one),
#             GATEWAY_WAIT seconds after each source change (default 90), KEEP=1 to keep everything, OUT=<file.md>
#
# Prints one row per claim (PASS / FAIL with what was seen) and exits 1 if any claim failed.
set -uo pipefail
export PATH=/opt/homebrew/bin:$PATH
: "${PROFILE:?}" "${CONNECTION:?}" "${CATALOG:?}" "${SRC_SQL:?}" "${CONN_USER:?}"
HERE=$(cd "$(dirname "$0")" && pwd)
WAIT=${GATEWAY_WAIT:-90}
MODE=${MODE:-standard}   # standard: gateway + ingestion pipeline; integrated: one pipeline (connector_type CDC)
case $MODE in standard|integrated) ;; *) echo "MODE must be standard or integrated"; exit 2;; esac
dbx() { databricks "$@" --profile "$PROFILE"; }
RESULTS=(); FAILED=0
claim() { RESULTS+=("| \`$1\` | $2 | $3 |"); [ "$2" = PASS ] || FAILED=1; echo "$2 $1: $3"; }
observe() { RESULTS+=("| \`$1\` | OBSERVED | $2 |"); echo "OBSERVED $1: $2"; }   # no expected answer yet

# --- pre-flight -------------------------------------------------------------------------------------------------------
ME=$(dbx current-user me -o json | yq '.userName')
PREFIX=${PREFIX:-$(echo "$ME" | cut -d@ -f1 | tr -d '.-' | tr 'A-Z' 'a-z')}
ROOT=$(dbx catalogs get "$CATALOG" -o json | yq '.storage_root // ""')
DEF=$(dbx external-locations get __databricks_managed_storage_location -o json 2>/dev/null | yq '.url // ""')
[ -n "$ROOT" ] || { echo "catalog $CATALOG has no storage root"; exit 2; }
[ -n "$DEF" ] && [[ "$ROOT" == "$DEF"* ]] && { echo "catalog $CATALOG is on Default Storage: CDC refuses it"; exit 2; }
[ "$(dbx connections get "$CONNECTION" -o json | yq '.connection_type')" = SQLSERVER ] || { echo "$CONNECTION is not SQLSERVER"; exit 2; }
WAREHOUSE=${WAREHOUSE:-$(dbx warehouses list -o json | yq '[.[] | select(.enable_serverless_compute)][0].id')}

E=$(date +%s); DB=${PREFIX}_addcol_$E; BASE=${PREFIX}_$(echo "$CONNECTION" | tr -- '-' '_' | sed "s/^${PREFIX}_//")
S=${BASE}_$E; STG=${S}_stg; GWN=${BASE}_gw_$E; APN=${BASE}_ap_$E; W=$(mktemp -d)
echo "run $E: source database $DB, catalog $CATALOG, schemas $S and $STG"

# sql "<statement>": run on the warehouse, print rows tab-separated
sql() {
  yq -n -o json '.warehouse_id = strenv(WAREHOUSE) | .wait_timeout = "50s" | .statement = strenv(Q)' > "$W/st.json"
  dbx api post /api/2.0/sql/statements --json @"$W/st.json" > "$W/st.out"
  [ "$(yq '.status.state' "$W/st.out")" = SUCCEEDED ] || { yq '.status.state + ": " + (.status.error.message // "")' "$W/st.out" | cut -c1-300 >&2; return 1; }
  yq -r '.result.data_array[] | @tsv' "$W/st.out"
}
export WAREHOUSE
q() { export Q=$1; sql; }

# update [table,table]: start an ingestion update (full refresh of the listed tables), wait, set STATE and ERRS
update() {
  local body='{}'; [ -n "${1:-}" ] && body=$(echo "$1" | yq -o json -I0 'split(",") | {"full_refresh_selection": .}')
  local u; u=$(dbx pipelines start-update "$AP" --json "$body" -o json | yq '.update_id')
  for _ in $(seq 1 90); do
    STATE=$(dbx pipelines get-update "$AP" "$u" -o json | yq '.update.state')
    case $STATE in COMPLETED|FAILED|CANCELED) break;; esac; sleep 20
  done
  dbx api get "/api/2.0/pipelines/$AP/events?max_results=250" -o json \
    | yq -o json "[.events[] | select(.origin.update_id == \"$u\")]" > "$W/ev_last.json"
  ERRS=$(yq -r '.[] | .error.exceptions[]?.error_class // ""' "$W/ev_last.json" | sort -u | tr '\n' ' ')
  echo "update ${1:+(full refresh $1) }$STATE ${ERRS}"
}

# errs_for <table>: error classes the last update reported for that table's flows
errs_for() { T1=$1 yq -r '.[] | select((.origin.flow_name // "") | test("_" + strenv(T1) + "_")) | .error.exceptions[]?.error_class // ""' "$W/ev_last.json" | sort -u | tr '\n' ' '; }

# settle <table> <column>: after a source change, run updates until one reports an error, or <column> shows up in the
# destination <table> (applied inline). The gateway can take longer than one fixed wait to pick up a change, and an
# update that ran before it did proves nothing.
settle() {
  for _ in 1 2 3 4; do
    sleep "$WAIT"; update
    [ -n "${ERRS// /}" ] && return
    q "SELECT $2 FROM $T.$1 LIMIT 0" >/dev/null 2>&1 && return
  done
}

cleanup() {
  [ "${KEEP:-0}" = 1 ] && { echo "KEEP=1: left $DB, $GWN, $APN, $CATALOG.$S"; return; }
  [ -n "${AP:-}" ] && dbx pipelines delete "$AP"; [ -n "${GW:-}" ] && dbx pipelines delete "$GW"; sleep 15
  dbx schemas delete "$CATALOG.$S" --force 2>/dev/null; dbx schemas delete "$CATALOG.$STG" --force 2>/dev/null
  local left
  for _ in 1 2 3; do   # a pipeline that was just deleted can still hold a session for a while
    printf 'USE %s;\nEXEC sys.sp_cdc_disable_db;\nGO\nUSE master;\nALTER DATABASE %s SET SINGLE_USER WITH ROLLBACK IMMEDIATE;\nDROP DATABASE %s;\n' \
      "$DB" "$DB" "$DB" | $SRC_SQL master > "$W/drop.out" 2>&1
    left=$(printf "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = '%s';\n" "$DB" | $SRC_SQL master)
    [ "${left//[[:space:]]/}" = 0 ] && break; sleep 30
  done
  [ "${left//[[:space:]]/}" = 0 ] || { echo "source database $DB not dropped:"; tail -3 "$W/drop.out"; }
  echo "cleanup: pipelines and schemas deleted; source database left: ${left//[[:space:]]/}"
  rm -rf "$W"
}
trap cleanup EXIT

# --- source: fresh database, two tables, utility objects ----------------------------------------------------------
$SRC_SQL master >/dev/null <<EOF || { echo "source setup failed"; exit 2; }
CREATE DATABASE $DB;
GO
USE $DB;
GO
CREATE SCHEMA lfcddemo;
GO
CREATE TABLE lfcddemo.intpk (id INT NOT NULL PRIMARY KEY, v VARCHAR(20), dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME());
CREATE TABLE lfcddemo.dtix (id INT NOT NULL, v VARCHAR(20), dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME());
CREATE INDEX dtix_dt ON lfcddemo.dtix(dt);
CREATE TABLE lfcddemo.cdcpk (id INT NOT NULL PRIMARY KEY, v VARCHAR(20), dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME());
CREATE TABLE lfcddemo.afrpk (id INT NOT NULL PRIMARY KEY, v VARCHAR(20), dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME());
CREATE TABLE lfcddemo.scd2pk (id INT NOT NULL PRIMARY KEY, v VARCHAR(20), dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME());
CREATE TABLE lfcddemo.aopk (id INT NOT NULL PRIMARY KEY, v VARCHAR(20), dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME());
INSERT INTO lfcddemo.intpk (id, v) SELECT TOP 10 ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 'before' FROM sys.objects;
INSERT INTO lfcddemo.dtix (id, v) SELECT TOP 10 ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 'before' FROM sys.objects;
INSERT INTO lfcddemo.cdcpk (id, v) SELECT TOP 10 ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 'before' FROM sys.objects;
INSERT INTO lfcddemo.afrpk (id, v) SELECT TOP 10 ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 'before' FROM sys.objects;
INSERT INTO lfcddemo.scd2pk (id, v) SELECT TOP 10 ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 'before' FROM sys.objects;
INSERT INTO lfcddemo.aopk (id, v) SELECT TOP 10 ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 'before' FROM sys.objects;
CREATE USER $CONN_USER FOR LOGIN $CONN_USER;
EOF
curl -fsSL -o "$W/utility_script.sql" https://learn.microsoft.com/en-us/azure/databricks/_extras/documents/utility_script.sql
$SRC_SQL "$DB" < "$W/utility_script.sql" >/dev/null || { echo "utility objects install failed"; exit 2; }
$SRC_SQL "$DB" >/dev/null <<EOF
EXEC dbo.lakeflowSetupChangeTracking @Tables = 'lfcddemo.intpk', @User = '$CONN_USER';
EXEC dbo.lakeflowSetupChangeTracking @Tables = 'lfcddemo.afrpk', @User = '$CONN_USER';
EXEC dbo.lakeflowSetupChangeTracking @Tables = 'lfcddemo.scd2pk', @User = '$CONN_USER';
EXEC dbo.lakeflowSetupChangeTracking @Tables = 'lfcddemo.aopk', @User = '$CONN_USER';
EXEC dbo.lakeflowSetupChangeDataCapture @Tables = 'lfcddemo.dtix', @User = '$CONN_USER';
EXEC dbo.lakeflowSetupChangeDataCapture @Tables = 'lfcddemo.cdcpk', @User = '$CONN_USER';
EXEC dbo.lakeflowFixPermissions @User = '$CONN_USER', @Tables = 'SCHEMAS:lfcddemo';
EOF
SEEN=$(q "SELECT * FROM remote_query('$CONNECTION', database => '$DB', query => 'SELECT (SELECT COUNT(*) FROM lfcddemo.intpk) AS intpk_rows, (SELECT COUNT(*) FROM lfcddemo.dtix) AS dtix_rows, (SELECT COUNT(*) FROM lfcddemo.cdcpk) AS cdcpk_rows, (SELECT COUNT(*) FROM lfcddemo.afrpk) AS afrpk_rows, dbo.lakeflowUtilityVersion() AS util')")
echo "through the connection: $SEEN"
[ "$(echo "$SEEN" | cut -f1-4)" = "$(printf '10\t10\t10\t10')" ] || { echo "serverless can't read the source through $CONNECTION"; exit 2; }
UTIL=$(echo "$SEEN" | cut -f5)

# --- pipelines ----------------------------------------------------------------------------------------------------
dbx schemas create "$S" "$CATALOG" >/dev/null || exit 2
# obj <table> [extra table_configuration JSON]
obj() { echo "{\"table\":{\"source_catalog\":\"$DB\",\"source_schema\":\"lfcddemo\",\"source_table\":\"$1\",\"destination_catalog\":\"$CATALOG\",\"destination_schema\":\"$S\",\"table_configuration\":{\"scd_type\":\"${SCD:-SCD_TYPE_1}\"${2:+,$2}}}}"; }
AFR='"auto_full_refresh_policy":{"enabled":true,"min_interval_hours":1}'
OBJS="$(obj intpk),$(obj dtix),$(obj cdcpk),$(obj afrpk "$AFR"),$(SCD=SCD_TYPE_2 obj scd2pk),$(SCD=APPEND_ONLY obj aopk)"
if [ "$MODE" = standard ]; then
  dbx schemas create "$STG" "$CATALOG" >/dev/null || exit 2
  GW=$(dbx pipelines create -o json --json "{\"name\":\"$GWN\",\"catalog\":\"$CATALOG\",\"schema\":\"$STG\",\"serverless\":true,\"continuous\":true,
    \"gateway_definition\":{\"connection_name\":\"$CONNECTION\",\"gateway_storage_catalog\":\"$CATALOG\",\"gateway_storage_schema\":\"$STG\",\"gateway_storage_name\":\"$GWN\"}}" | yq '.pipeline_id')
  [ -n "$GW" ] && [ "$GW" != null ] || { echo "gateway create failed"; exit 2; }
  SRCDEF="\"ingestion_gateway_id\":\"$GW\""
else
  WAIT=0   # integrated CDC reads the source inside each update
  SRCDEF="\"connection_name\":\"$CONNECTION\",\"connector_type\":\"CDC\""
fi
AP=$(dbx pipelines create -o json --json "{\"name\":\"$APN\",\"catalog\":\"$CATALOG\",\"schema\":\"$S\",\"serverless\":true,
  \"ingestion_definition\":{$SRCDEF,\"objects\":[$OBJS]}}" | yq '.pipeline_id')
[ -n "$AP" ] && [ "$AP" != null ] || { echo "ingestion pipeline create failed"; exit 2; }
T="\`$CATALOG\`.$S"

update; [ "$STATE" = COMPLETED ] || { echo "baseline failed: $ERRS"; exit 1; }
COUNTS="SELECT (SELECT COUNT(*) FROM $T.intpk), (SELECT COUNT(*) FROM $T.dtix), (SELECT COUNT(*) FROM $T.cdcpk), (SELECT COUNT(*) FROM $T.afrpk)"
R=$(q "$COUNTS" 2>&1); [ "$R" = "$(printf '10\t10\t10\t10')" ] || { update; R=$(q "$COUNTS" 2>&1); }   # the first update may not load every table
if [ "$MODE" = integrated ] && [ "$R" = "$(printf '10\t0\t10\t10')" ]; then
  observe keyless-cdc-integrated-snapshot "dtix (no primary key, CDC) has 0 rows after the first load; the keyed tables have 10. No error. Its later claims are skipped"
  SKIP_DTIX=1
else
  [ "$R" = "$(printf '10\t10\t10\t10')" ] || { echo "baseline row counts wrong (intpk dtix cdcpk afrpk): $R"; exit 1; }
fi
observe scd-modes-baseline "rows scd2pk (SCD_TYPE_2), aopk (APPEND_ONLY): $(q "SELECT (SELECT COUNT(*) FROM $T.scd2pk), (SELECT COUNT(*) FROM $T.aopk)" 2>&1 | tr '\t' ' ')"

# --- C1: nullable, no default ---------------------------------------------------------------------------------------
$SRC_SQL "$DB" >/dev/null <<'EOF'
ALTER TABLE lfcddemo.intpk ADD c1 INT NULL;
ALTER TABLE lfcddemo.dtix ADD c1 INT NULL;
ALTER TABLE lfcddemo.cdcpk ADD c1 INT NULL;
ALTER TABLE lfcddemo.scd2pk ADD c1 INT NULL;
ALTER TABLE lfcddemo.aopk ADD c1 INT NULL;
GO
INSERT INTO lfcddemo.intpk (id, v, c1) VALUES (11, 'after_c1', 111), (12, 'after_c1', 112);
INSERT INTO lfcddemo.dtix (id, v, c1) VALUES (11, 'after_c1', 111), (12, 'after_c1', 112);
INSERT INTO lfcddemo.cdcpk (id, v, c1) VALUES (11, 'after_c1', 111), (12, 'after_c1', 112);
INSERT INTO lfcddemo.scd2pk (id, v, c1) VALUES (11, 'after_c1', 111), (12, 'after_c1', 112);
INSERT INTO lfcddemo.aopk (id, v, c1) VALUES (11, 'after_c1', 111), (12, 'after_c1', 112);
EOF
[ "${SKIP_DTIX:-0}" = 1 ] && settle intpk c1 || settle dtix c1
R=$(q "SELECT SUM(CASE WHEN c1 IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN c1 > 110 THEN 1 ELSE 0 END) FROM $T.intpk")
[ "$R" = "$(printf '10\t2')" ] && claim nullable-no-default-keyed-inline PASS "intpk: 10 rows c1 NULL, 2 rows with values, while dtix failed in the same update" \
  || claim nullable-no-default-keyed-inline FAIL "intpk c1 NULL/values: ${R:-query failed}"
if [ "${SKIP_DTIX:-0}" = 1 ]; then observe keyless-any-add-full-refresh "skipped: dtix didn't load; errors for dtix: $(errs_for dtix)"
elif [[ "$ERRS" == *PRIMARY_KEY_CHANGE* ]]; then claim keyless-any-add-full-refresh PASS "dtix: PRIMARY_KEY_CHANGE on a nullable no-default add"
else claim keyless-any-add-full-refresh FAIL "dtix errors: ${ERRS:-none}"; fi
R=$(q "SELECT SUM(CASE WHEN c1 IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN c1 > 110 THEN 1 ELSE 0 END) FROM $T.cdcpk")
[ "$R" = "$(printf '10\t2')" ] && claim keyed-cdc-table PASS "cdcpk (CDC, primary key): 10 rows c1 NULL, 2 rows with values" \
  || claim keyed-cdc-table FAIL "cdcpk c1 NULL/values: ${R:-query failed}"
for t in scd2pk aopk; do
  observe "$t-nullable-add" "errors: $(errs_for $t)$( [ -z "$(errs_for $t)" ] && echo none); rows, c1 NULL, c1 set: $(q "SELECT COUNT(*), SUM(CASE WHEN c1 IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN c1 > 110 THEN 1 ELSE 0 END) FROM $T.$t" 2>&1 | tr '\t' ' ' | cut -c1-120)"
done
FR=dtix; for t in scd2pk aopk; do [ -n "$(errs_for $t)" ] && FR+=",$t"; done
update "$FR"

# --- C2: NOT NULL DEFAULT, then C4: full refresh -------------------------------------------------------------------
$SRC_SQL "$DB" >/dev/null <<'EOF'
ALTER TABLE lfcddemo.intpk ADD c2 VARCHAR(10) NOT NULL DEFAULT 'x';
ALTER TABLE lfcddemo.dtix ADD c2 VARCHAR(10) NOT NULL DEFAULT 'x';
ALTER TABLE lfcddemo.cdcpk ADD c2 VARCHAR(10) NOT NULL DEFAULT 'x';
ALTER TABLE lfcddemo.afrpk ADD c2 VARCHAR(10) NOT NULL DEFAULT 'x';
ALTER TABLE lfcddemo.scd2pk ADD c2 VARCHAR(10) NOT NULL DEFAULT 'x';
ALTER TABLE lfcddemo.aopk ADD c2 VARCHAR(10) NOT NULL DEFAULT 'x';
GO
INSERT INTO lfcddemo.intpk (id, v, c1, c2) VALUES (13, 'after_c2', 113, 'y');
INSERT INTO lfcddemo.dtix (id, v, c1, c2) VALUES (13, 'after_c2', 113, 'y');
INSERT INTO lfcddemo.cdcpk (id, v, c1, c2) VALUES (13, 'after_c2', 113, 'y');
INSERT INTO lfcddemo.afrpk (id, v, c2) VALUES (11, 'after_c2', 'y');
INSERT INTO lfcddemo.scd2pk (id, v, c1, c2) VALUES (13, 'after_c2', 113, 'y');
INSERT INTO lfcddemo.aopk (id, v, c1, c2) VALUES (13, 'after_c2', 113, 'y');
EOF
settle intpk c2
[[ "$ERRS" == *ADD_COLUMN_WITH_BACKFILL* ]] && claim not-null-default-full-refresh PASS "intpk: ADD_COLUMN_WITH_BACKFILL" \
  || claim not-null-default-full-refresh FAIL "errors: ${ERRS:-none}"
for t in scd2pk aopk; do observe "$t-not-null-default-add" "errors: $(errs_for $t)$( [ -z "$(errs_for $t)" ] && echo none)"; done
FR=intpk,dtix,cdcpk; for t in scd2pk aopk; do [ -n "$(errs_for $t)" ] && FR+=",$t"; done
update "$FR"   # afrpk is never selected: its policy has to refresh it
for t in scd2pk aopk; do
  observe "$t-after-refresh" "rows, c2 = 'x', c2 = 'y': $(q "SELECT COUNT(*), SUM(CASE WHEN c2 = 'x' THEN 1 ELSE 0 END), SUM(CASE WHEN c2 = 'y' THEN 1 ELSE 0 END) FROM $T.$t" 2>&1 | tr '\t' ' ' | cut -c1-120)"
done
R=$(q "SELECT (SELECT SUM(CASE WHEN c2 = 'x' THEN 1 ELSE 0 END) FROM $T.intpk), (SELECT SUM(CASE WHEN c2 = 'x' THEN 1 ELSE 0 END) FROM $T.dtix), (SELECT SUM(CASE WHEN c2 = 'x' THEN 1 ELSE 0 END) FROM $T.cdcpk)")
[ "$STATE" = COMPLETED ] && [ "$R" = "$(printf '12\t12\t12')" ] && claim full-refresh-recovers PASS "after a full refresh, 12 old rows carry the default in each table" \
  || claim full-refresh-recovers FAIL "full refresh $STATE, old rows with the default: ${R:-query failed}"
for _ in 1 2 3; do   # the policy's refresh may land in a later update
  R=$(q "SELECT SUM(CASE WHEN c2 = 'x' THEN 1 ELSE 0 END), COUNT(*) FROM $T.afrpk" 2>/dev/null)
  [ "$R" = "$(printf '10\t11')" ] && break; update
done
[ "$R" = "$(printf '10\t11')" ] && claim auto-full-refresh-policy PASS "afrpk refreshed with no full refresh requested: 10 old rows carry the default, 11 rows" \
  || claim auto-full-refresh-policy FAIL "afrpk default/rows: ${R:-query failed}; last errors: ${ERRS:-none}"

# --- C3: nullable WITH default -------------------------------------------------------------------------------------
$SRC_SQL "$DB" >/dev/null <<'EOF'
ALTER TABLE lfcddemo.intpk ADD c3 INT NULL DEFAULT 5;
GO
INSERT INTO lfcddemo.intpk (id, v, c1) VALUES (14, 'after_c3', 114);
EOF
settle intpk c3
[[ "$ERRS" == *ADD_COLUMN_WITH_BACKFILL* ]] && claim nullable-default-full-refresh PASS "intpk: ADD_COLUMN_WITH_BACKFILL although old source rows stay NULL" \
  || claim nullable-default-full-refresh FAIL "errors: ${ERRS:-none}"
update intpk
R=$(q "SELECT SUM(CASE WHEN c3 IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN c3 = 5 THEN 1 ELSE 0 END) FROM $T.intpk")
[ "$R" = "$(printf '13\t1')" ] || claim full-refresh-recovers FAIL "after C3 refresh, c3 NULL/5: ${R:-query failed}"

# --- C4: identity column, C5: computed column ------------------------------------------------------------------------
id=15
for c in "c4 INT IDENTITY(1,1)" "c5 AS (id * 2)"; do
  printf "ALTER TABLE lfcddemo.intpk ADD %s;\nGO\nINSERT INTO lfcddemo.intpk (id, v, c1) VALUES (%s, 'after_%s', 1%s);\n" "$c" "$id" "${c%% *}" "$id" \
    | $SRC_SQL "$DB" >/dev/null; id=$((id + 1))
  settle intpk "${c%% *}"
  [[ "$ERRS" == *ADD_COLUMN_WITH_BACKFILL* ]] && claim identity-computed-full-refresh PASS "intpk: ADD ${c}: ADD_COLUMN_WITH_BACKFILL" \
    || claim identity-computed-full-refresh FAIL "ADD ${c}: errors ${ERRS:-none}"
  update intpk
done

# --- the runtime each pipeline ran on; settings that changed since the last run on this workspace go to the log -------
RT="$HERE/../../../bin/lfc-runtime.sh"
"$RT" "$PROFILE" "$AP" >&2 || true
RUNTIME="- Ingestion pipeline: $("$RT" --summary "$PROFILE" "$AP" 2>/dev/null | sed 's/^Lakeflow runtime: //')"
[ -n "${GW:-}" ] && RUNTIME+=$'\n'"- Gateway: $("$RT" --summary "$PROFILE" "$GW" 2>/dev/null | sed 's/^Lakeflow runtime: //')"

# --- result ---------------------------------------------------------------------------------------------------------
{
  echo "# sqlserver-add-column run $E"
  echo
  echo "- Date (UTC): $(date -u +%F)"
  [ "$MODE" = standard ] && echo "- Mode: standard CDC, serverless gateway and ingestion pipeline" || echo "- Mode: integrated CDC, one serverless pipeline"
  echo "$RUNTIME"
  [ -n "${SRC_ENV:-}" ] && $SRC_ENV | sed 's/^/- /'
  echo "- Source: $(printf "SET NOCOUNT ON; SELECT CONCAT('SQL Server ', CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)), ' ', CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(64)), ' ', CAST(SERVERPROPERTY('ProductUpdateReference') AS nvarchar(64)), ', ', CAST(SERVERPROPERTY('Edition') AS nvarchar(128)));\n" | $SRC_SQL master | head -1); utility objects $UTIL"
  echo
  echo "| Claim | Result | Observation |"
  echo "|---|---|---|"
  printf '%s\n' "${RESULTS[@]}"
} | tee "${OUT:-/dev/null}"
exit $FAILED
