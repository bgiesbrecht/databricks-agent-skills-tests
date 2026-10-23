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
# the info table must exist, and in deny mode the DENY must show in the permissions: else the run would be the control
[[ "$CII" =~ ^lakeflowCaptureInstanceInfo[A-Za-z0-9_]*$ ]] || { claim setup FAIL "no lakeflowCaptureInstanceInfo table found (got '${CII:0:120}')"; result_md sqlserver-cii-deny; exit 1; }
[ "$CII_DENY" = 1 ] && echo "DENY UPDATE ON dbo.$CII TO $CONN_USER;" | src >/dev/null
PERM=$(printf "SET NOCOUNT ON; SELECT ISNULL(MAX(state_desc), 'none') FROM sys.database_permissions WHERE major_id = OBJECT_ID('dbo.%s') AND permission_name = 'UPDATE' AND grantee_principal_id = USER_ID('%s');\n" "$CII" "$CONN_USER" | src 2>&1 | tr -d '[:space:]')
[ "$CII_DENY" = 1 ] && [ "$PERM" != DENY ] && { claim setup FAIL "DENY UPDATE on dbo.$CII to $CONN_USER didn't take (permission state: ${PERM:0:120})"; result_md sqlserver-cii-deny; exit 1; }
observe setup "CDC on p_cii; UPDATE on dbo.$CII $( [ "$CII_DENY" = 1 ] && echo denied || echo granted) to the login (permission state: $PERM)"
pipelines_create "$(obj p_cii)"
update; [ "$(q "SELECT COUNT(*) FROM $T.p_cii" 2>&1)" = 10 ] || update
cols() { q "SELECT CONCAT_WS(',', COLLECT_LIST(column_name)) FROM \`$CATALOG\`.information_schema.columns WHERE table_schema = '$S' AND table_name = 'p_cii'" 2>&1; }
info() { printf "SET NOCOUNT ON; SELECT CONCAT(oldCaptureInstance, ' -> ', newCaptureInstance, ', committedCursor ', ISNULL(committedCursor, 'NULL'), ', triggerReinit ', triggerReinit) FROM dbo.%s WHERE tableName = 'p_cii';\nSELECT STRING_AGG(capture_instance, ' ') FROM cdc.change_tables WHERE source_object_id = OBJECT_ID('lfcddemo.p_cii');\n" "$CII" | src 2>&1 | paste -sd';' - | sed 's/;/; capture instances: /'; }
step() {   # <rows wanted> <name>: up to 4 updates until the rows arrive or the table has an error
  settle_rows "SELECT COUNT(*) FROM $T.p_cii" "$1" p_cii
  observe "$2" "rows $ROWS (source $1); ids $(q "SELECT CONCAT_WS(',', COLLECT_LIST(id)) FROM (SELECT id FROM $T.p_cii WHERE id > 10 ORDER BY id)" 2>&1); columns $(cols); errors: ${TERRS:-none}$( [ -n "${TERRS// /}" ] && echo "; $(msgs_for p_cii | head -1 | cut -c1-200)"); source: $(info)"
  [ "$SETTLED" = 1 ]
}
observe after-load "rows $(q "SELECT COUNT(*) FROM $T.p_cii" 2>&1); columns $(cols); source: $(info)"
echo "INSERT INTO lfcddemo.p_cii (id, v) VALUES (11, 'after');" | src >/dev/null
step 11 row-after-load
echo "ALTER TABLE lfcddemo.p_cii ADD c INT NULL;" | src >/dev/null
echo "INSERT INTO lfcddemo.p_cii (id, v, c) VALUES (12, 'ddl', 1);" | src >/dev/null
# the expected answer depends on the mode: with UPDATE granted the row arrives; denied, the gateway can't move to the
# new capture instance and the row doesn't arrive (lfc-faq #8). A denied run where the row arrives means that changed
if step 12 column-after-load; then arrived=1; else arrived=0; fi
if [ "$CII_DENY" = 0 ]; then
  [ $arrived = 1 ] && claim column-row-arrives PASS "after ADD COLUMN the new row arrived (UPDATE on $CII granted)" \
    || claim column-row-arrives FAIL "after ADD COLUMN the new row didn't arrive in 4 updates (UPDATE on $CII granted); source: $(info)"
else
  [ $arrived = 0 ] && claim column-row-stops-when-denied PASS "after ADD COLUMN the new row didn't arrive in 4 updates (UPDATE on $CII denied), as documented; source: $(info)" \
    || claim column-row-stops-when-denied FAIL "after ADD COLUMN the new row arrived although UPDATE on $CII is denied: the documented behavior changed"
fi
result_md "sqlserver-cii-deny (CII_DENY=$CII_DENY)"
exit $FAILED
