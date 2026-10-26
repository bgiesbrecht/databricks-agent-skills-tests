#!/usr/bin/env bash
# integrated-split-boundary.sh: does integrated CDC on SQL Server load every row of a table whose snapshot splits on a
# DATETIME2(7) column? Tables (10 rows each): intpk (INT key), pk_dt7 (PRIMARY KEY on DATETIME2(7), values with a nonzero
# 7th digit), p7_dist (no key, index on such a column), p7_zero (7th digit 0). For each it prints the rows loaded, the
# extractor's split plan and the rows in its snapshot file, both read from the pipeline's staging volume. Seen
# 2026-10-20: pk_dt7 and p7_dist 9 of 10, the split's upper bound cut to 6 digits; intpk and p7_zero 10 of 10.
# Needs PROFILE, CONNECTION, CATALOG, CONN_USER, SRC_SQL (as sqlserver-add-column.sh). Set QBC_FLAG=true|false to also set
# pipelines.qbcSnapSplitBoundaryToColumnScale in the pipeline configuration; PIPELINE_CONF (a JSON object) adds more settings.
set -uo pipefail
export PATH=/opt/homebrew/bin:$PATH
dbx() { databricks "$@" --profile "$PROFILE"; }
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$(dbx current-user me -o json | yq '.userName' | cut -d@ -f1 | tr -d '.-' | tr 'A-Z' 'a-z')}
E=$(date +%s); DB=${PREFIX}_splitb_$E; W=$(mktemp -d)
WAREHOUSE=$(dbx warehouses list -o json | yq '[.[] | select(.enable_serverless_compute)][0].id'); export WAREHOUSE
q() { export Q=$1; yq -n -o json '.warehouse_id = strenv(WAREHOUSE) | .wait_timeout = "50s" | .statement = strenv(Q)' > "$W/st.json"
  dbx api post /api/2.0/sql/statements --json @"$W/st.json" -o json > "$W/st.out"; yq -r '.result.data_array[] | @tsv' "$W/st.out" 2>/dev/null || yq '.status.error.message' "$W/st.out"; }
TABLES="intpk pk_dt7 p7_dist p7_zero"
cleanup() {
  [ -n "${AP:-}" ] && dbx pipelines delete "$AP"; sleep 30; [ -n "${S:-}" ] && dbx schemas delete "$CATALOG.$S" --force 2>/dev/null
  for _ in 1 2 3; do
    printf 'USE %s;\nEXEC sys.sp_cdc_disable_db;\nGO\nUSE master;\nALTER DATABASE %s SET SINGLE_USER WITH ROLLBACK IMMEDIATE;\nDROP DATABASE %s;\n' "$DB" "$DB" "$DB" | $SRC_SQL master >/dev/null 2>&1
    [ "$(printf "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = '%s';\n" "$DB" | $SRC_SQL master | tr -d '[:space:]')" = 0 ] && break; sleep 30
  done
  echo "cleanup: source database left: $(printf "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = '%s';\n" "$DB" | $SRC_SQL master | tr -d '[:space:]')"; rm -rf "${W:?}"
}
trap cleanup EXIT
$SRC_SQL master >/dev/null <<SQL
CREATE DATABASE $DB;
GO
USE $DB;
GO
CREATE SCHEMA lfcddemo;
GO
CREATE TABLE lfcddemo.intpk (id INT NOT NULL PRIMARY KEY, v VARCHAR(20), dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME());
CREATE TABLE lfcddemo.pk_dt7 (dt DATETIME2(7) NOT NULL PRIMARY KEY, id INT NOT NULL, v VARCHAR(20));
CREATE TABLE lfcddemo.p7_dist (id INT NOT NULL, v VARCHAR(20), dt DATETIME2(7) NOT NULL);
CREATE INDEX p7_dist_dt ON lfcddemo.p7_dist(dt);
CREATE TABLE lfcddemo.p7_zero (id INT NOT NULL, v VARCHAR(20), dt DATETIME2(7) NOT NULL);
CREATE INDEX p7_zero_dt ON lfcddemo.p7_zero(dt);
GO
INSERT INTO lfcddemo.intpk (id, v) SELECT TOP 10 ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 'before' FROM sys.objects;
INSERT INTO lfcddemo.pk_dt7 (id, v, dt) SELECT n, 'before', DATEADD(SECOND, n, CAST('2026-01-01 00:00:00.1234567' AS DATETIME2(7))) FROM (SELECT TOP 10 ROW_NUMBER() OVER (ORDER BY (SELECT 1)) n FROM sys.objects) x;
INSERT INTO lfcddemo.p7_dist (id, v, dt) SELECT n, 'before', DATEADD(SECOND, n, CAST('2026-01-01 00:00:00.1234567' AS DATETIME2(7))) FROM (SELECT TOP 10 ROW_NUMBER() OVER (ORDER BY (SELECT 1)) n FROM sys.objects) x;
INSERT INTO lfcddemo.p7_zero (id, v, dt) SELECT n, 'before', DATEADD(SECOND, n, CAST('2026-01-01 00:00:00.1234560' AS DATETIME2(7))) FROM (SELECT TOP 10 ROW_NUMBER() OVER (ORDER BY (SELECT 1)) n FROM sys.objects) x;
CREATE USER $CONN_USER FOR LOGIN $CONN_USER;
SQL
curl -fsSL -o "$W/u.sql" https://learn.microsoft.com/en-us/azure/databricks/_extras/documents/utility_script.sql
$SRC_SQL "$DB" < "$W/u.sql" >/dev/null
$SRC_SQL "$DB" >/dev/null <<SQL
EXEC dbo.lakeflowSetupChangeTracking @Tables = 'lfcddemo.intpk', @User = '$CONN_USER';
EXEC dbo.lakeflowSetupChangeTracking @Tables = 'lfcddemo.pk_dt7', @User = '$CONN_USER';
EXEC dbo.lakeflowSetupChangeDataCapture @Tables = 'lfcddemo.p7_dist', @User = '$CONN_USER';
EXEC dbo.lakeflowSetupChangeDataCapture @Tables = 'lfcddemo.p7_zero', @User = '$CONN_USER';
EXEC dbo.lakeflowFixPermissions @User = '$CONN_USER', @Tables = 'SCHEMAS:lfcddemo';
SQL
obj() { echo "{\"table\":{\"source_catalog\":\"$DB\",\"source_schema\":\"lfcddemo\",\"source_table\":\"$1\",\"destination_catalog\":\"$CATALOG\",\"destination_schema\":\"$S\",\"table_configuration\":{\"scd_type\":\"SCD_TYPE_1\"}}}"; }
counts() { q "SELECT $(for t in $TABLES; do printf '(SELECT COUNT(*) FROM %s.%s),' "$T" "$t"; done | sed 's/,$//')" 2>/dev/null; }

for flag in run; do
  S=${PREFIX}_splitb_$E; T="\`$CATALOG\`.$S"
  dbx schemas create "$S" "$CATALOG" >/dev/null
  CONF='{}'; [ -n "${QBC_FLAG:-}" ] && CONF="{\"pipelines.qbcSnapSplitBoundaryToColumnScale\":\"$QBC_FLAG\"}"
  # PIPELINE_CONF='{"pipelines.<setting>":"true"}': more pipeline settings (an engineer's suggestion to try)
  [ -n "${PIPELINE_CONF:-}" ] && CONF=$(echo "$CONF" | P="$PIPELINE_CONF" yq -o json -I0 '. * (strenv(P) | from_json)')
  AP=$(dbx pipelines create -o json --json "{\"name\":\"${PREFIX}_splitb_$E\",\"catalog\":\"$CATALOG\",\"schema\":\"$S\",\"serverless\":true,\"configuration\":$CONF,
    \"ingestion_definition\":{\"connection_name\":\"$CONNECTION\",\"connector_type\":\"CDC\",\"objects\":[$(for t in $TABLES; do obj $t; done | paste -sd, -)]}}" | yq '.pipeline_id')
  echo "flag $flag: pipeline $AP"
  u=$(dbx pipelines list-updates "$AP" --max-results 1 -o json | yq '.updates[0].update_id')
  [ -z "$u" ] || [ "$u" = null ] && u=$(dbx pipelines start-update "$AP" -o json | yq '.update_id')
  t0=$(date +%s); prev=""; stable=0; stopped=""
  for _ in $(seq 1 90); do
    st=$(dbx pipelines get-update "$AP" "$u" -o json | yq '.update.state'); case $st in COMPLETED|FAILED|CANCELED) break;; esac
    # early stop: every snapshot reported COMPLETED in the event log, and destination counts unchanged for 2 polls
    done_snaps=$(dbx api get "/api/2.0/pipelines/$AP/events?max_results=250" -o json | U=$u yq '[.events[] | select(.origin.update_id == strenv(U) and .event_type == "flow_progress" and ((.origin.flow_name // "") | test("_snapshot_flow$")) and .details.flow_progress.status == "COMPLETED")] | length')
    c=$(counts); if [ "${done_snaps:-0}" -ge 4 ] && [ -n "$c" ] && [ "$c" = "$prev" ]; then stable=$((stable + 1)); else stable=0; fi; prev=$c
    if [ $stable -ge 2 ]; then dbx pipelines stop "$AP" >/dev/null 2>&1; stopped=" (stopped early after $(( $(date +%s) - t0 ))s)"; st=STOPPED; break; fi
    sleep 20
  done
  echo "flag $flag: update $st$stopped; rows $TABLES: $(counts | tr '\t' ' ')"
  for t in pk_dt7 p7_dist; do echo "flag $flag: $t ids loaded: $(q "SELECT CONCAT_WS(',', SORT_ARRAY(COLLECT_LIST(id))) FROM $T.$t")"; done
  echo "flag $flag: runtime flag value: $(dbx api get "/api/2.0/pipelines/$AP/events?max_results=250" -o json | U=$u yq '[.events[] | select(.origin.update_id == strenv(U) and .event_type == "runtime_details")][0].details.runtime_details.runtime_configuration.configuration["pipelines.qbcSnapSplitBoundaryToColumnScale"] // "not in runtime_configuration"')"
  # staging: the extractor's split plan and the snapshot file rows, per table
  VOL=$(dbx volumes list "$CATALOG" "$S" -o json | yq '.[] | select(.name | test("^__databricks_ingestion_gateway_staging_data-")) | .name' | head -1)
  ID=${VOL#__databricks_ingestion_gateway_staging_data-}; V="/Volumes/$CATALOG/$S/$VOL/$ID"
  dbx fs cat "dbfs:$V/metadata/general_table_schemas/all_tables.json" > "$W/tables.json" 2>/dev/null
  for t in $TABLES; do
    uoid=$(DB=$DB TN=$t yq -r '.schemas[] | select(.catalog == strenv(DB)) | .tables[] | select(.name == strenv(TN)) | .uoid' "$W/tables.json")
    ts=$(dbx fs ls "dbfs:$V/snapshot/$uoid" 2>/dev/null | grep -v qbc_checkpoint | head -1)
    offs=$(dbx fs ls "dbfs:$V/snapshot/$uoid/qbc_checkpoint/$ts/offsets" 2>/dev/null | grep -v tmp | sort -n | tail -1)
    plan=$(dbx fs cat "dbfs:$V/snapshot/$uoid/qbc_checkpoint/$ts/offsets/$offs" 2>/dev/null | tail -1)
    rows=$(q "SELECT COUNT(*), '-' FROM read_files('$V/snapshot/$uoid/$ts/', format => 'parquet')" | tr '\t' ' ')
    echo "flag $flag: staging $t: snapshot file rows/ids: $rows; split plan: $plan"
  done
  dbx pipelines delete "$AP"; AP=""; sleep 20; dbx schemas delete "$CATALOG.$S" --force 2>/dev/null
done
