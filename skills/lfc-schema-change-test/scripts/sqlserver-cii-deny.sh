#!/usr/bin/env bash
# sqlserver-cii-deny.sh: on a CDC table, does a column added after the first load need the login's UPDATE on the
# utility objects' lakeflowCaptureInstanceInfo table? Answers lfc-faq #8 (a cause listed for
# TABLE_METADATA_NOT_READY_INTERNAL_ERROR). One CDC table, 10 rows; after the load a row, then ADD COLUMN and a row.
# Prints the destination rows and columns after each step, the source's capture instances and the info table's row
# (old/new capture instance, committedCursor: what the gateway writes when it moves to the new capture instance).
#
#   CII_DENY=1 (default) denies the login UPDATE on lakeflowCaptureInstanceInfo after setup; CII_DENY=0 is the control.
#   Needs and options: as sqlserver-add-column.sh (PROFILE CONNECTION CATALOG SRC_SQL CONN_USER; SRC_ENV, MODE, KEEP, OUT)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
lfc_init cii
CII_DENY=${CII_DENY:-1}; conf cii_deny "$CII_DENY"
FP_TABLES=p_cii
echo "CREATE TABLE lfcddemo.p_cii (id INT NOT NULL PRIMARY KEY, v VARCHAR(20));" | src_db
fill p_cii 10; src_util; track cdc p_cii
CII=$(printf "SET NOCOUNT ON; SELECT TOP 1 name FROM sys.tables WHERE name LIKE 'lakeflowCaptureInstanceInfo%%';\n" | src | tr -d '[:space:]')
[ "$CII_DENY" = 1 ] && echo "DENY UPDATE ON dbo.$CII TO $CONN_USER;" | src >/dev/null
observe setup "CDC on p_cii; UPDATE on dbo.$CII $( [ "$CII_DENY" = 1 ] && echo denied || echo granted) to the login"
pipelines_create "$(obj p_cii)"
update; [ "$(q "SELECT COUNT(*) FROM $T.p_cii" 2>&1)" = 10 ] || update
cols() { q "SELECT CONCAT_WS(',', COLLECT_LIST(column_name)) FROM \`$CATALOG\`.information_schema.columns WHERE table_schema = '$S' AND table_name = 'p_cii'" 2>&1; }
info() { printf "SET NOCOUNT ON; SELECT CONCAT(oldCaptureInstance, ' -> ', newCaptureInstance, ', committedCursor ', ISNULL(committedCursor, 'NULL'), ', triggerReinit ', triggerReinit) FROM dbo.%s WHERE tableName = 'p_cii';\nSELECT STRING_AGG(capture_instance, ' ') FROM cdc.change_tables WHERE source_object_id = OBJECT_ID('lfcddemo.p_cii');\n" "$CII" | src 2>&1 | paste -sd';' - | sed 's/;/; capture instances: /'; }
step() {   # <rows wanted> <name>: up to 4 updates until the rows arrive or the table has an error
  local r e
  for _ in 1 2 3 4; do
    sleep "$WAIT"; update
    r=$(q "SELECT COUNT(*) FROM $T.p_cii" 2>&1); e=$(errs_for p_cii)
    { [ "$r" = "$1" ] || [ -n "${e// /}" ]; } && break
  done
  observe "$2" "rows $r (source $1); ids $(q "SELECT CONCAT_WS(',', COLLECT_LIST(id)) FROM (SELECT id FROM $T.p_cii WHERE id > 10 ORDER BY id)" 2>&1); columns $(cols); errors: ${e:-none}$( [ -n "${e// /}" ] && echo "; $(msgs_for p_cii | head -1 | cut -c1-200)"); source: $(info)"
  [ "$r" = "$1" ]
}
observe after-load "rows $(q "SELECT COUNT(*) FROM $T.p_cii" 2>&1); columns $(cols); source: $(info)"
echo "INSERT INTO lfcddemo.p_cii (id, v) VALUES (11, 'after');" | src >/dev/null
step 11 row-after-load
echo "ALTER TABLE lfcddemo.p_cii ADD c INT NULL;" | src >/dev/null
echo "INSERT INTO lfcddemo.p_cii (id, v, c) VALUES (12, 'ddl', 1);" | src >/dev/null
if step 12 column-after-load; then claim column-row-arrives PASS "after ADD COLUMN the new row arrived (UPDATE on $CII $( [ "$CII_DENY" = 1 ] && echo denied || echo granted))"
else claim column-row-arrives FAIL "after ADD COLUMN the new row didn't arrive in 4 updates (UPDATE on $CII $( [ "$CII_DENY" = 1 ] && echo denied || echo granted)); source: $(info)"; fi
result_md "sqlserver-cii-deny (CII_DENY=$CII_DENY)"
exit $FAILED
