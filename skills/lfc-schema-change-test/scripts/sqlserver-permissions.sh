#!/usr/bin/env bash
# sqlserver-permissions.sh: what does the pipeline report when the gateway can't read a table's data or its change
# metadata? Answers lfc-faq #8 (TABLE_METADATA_NOT_READY_INTERNAL_ERROR: which source problems lead to it) and shows
# #14's per-table stop: one table fails, the others keep loading.
#
#   p_ok        change tracking, the login can read it          (control)
#   p_noselect  change tracking, SELECT denied to the login
#   p_notrack   neither change tracking nor CDC
#   p_cdcdeny   CDC, SELECT on its change table denied to the login
#   p_ciideny   CDC, UPDATE on the utility objects' lakeflowCaptureInstanceInfo table denied to the login
#   p_locked    change tracking, a schema lock held on the table while the pipeline starts (released after 15 minutes)
#
#   Needs and options: as sqlserver-add-column.sh (PROFILE CONNECTION CATALOG SRC_SQL CONN_USER; SRC_ENV, MODE, KEEP, OUT)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
lfc_init perm
TABLES="p_ok p_noselect p_notrack p_cdcdeny p_ciideny p_locked"; FP_TABLES=$TABLES
{ for t in $TABLES; do echo "CREATE TABLE lfcddemo.$t (id INT NOT NULL PRIMARY KEY, v VARCHAR(20));"; done; } | src_db
for t in $TABLES; do fill $t 10; done
src_util
track ct p_ok p_noselect p_locked; track cdc p_cdcdeny p_ciideny
echo "GRANT SELECT ON lfcddemo.p_notrack TO $CONN_USER;" | src >/dev/null
# after lakeflowFixPermissions (inside track) has granted everything: take two of the grants away again
src >/dev/null <<EOF
DENY SELECT ON lfcddemo.p_noselect TO $CONN_USER;
DECLARE @ct sysname = (SELECT OBJECT_SCHEMA_NAME(object_id) + '.' + name FROM sys.tables
  WHERE object_id = (SELECT object_id FROM cdc.change_tables WHERE source_object_id = OBJECT_ID('lfcddemo.p_cdcdeny')));
EXEC ('DENY SELECT ON ' + @ct + ' TO $CONN_USER');
DECLARE @cii sysname = (SELECT TOP 1 name FROM sys.tables WHERE name LIKE 'lakeflowCaptureInstanceInfo%');
IF @cii IS NOT NULL EXEC ('DENY UPDATE ON dbo.' + @cii + ' TO $CONN_USER');
EOF
# a schema-modification lock on p_locked, held by a session on the VM for 15 minutes (BEGIN TRAN + ALTER, then rollback)
printf "BEGIN TRAN; ALTER TABLE lfcddemo.p_locked ADD lockcol INT NULL; WAITFOR DELAY '00:15:00'; ROLLBACK;\n" | src >/dev/null 2>&1 &
LOCKER=$!
pipelines_create "$(for t in $TABLES; do printf '%s,' "$(obj $t)"; done | sed 's/,$//')"
update; [ "$(q "SELECT COUNT(*) FROM $T.p_ok" 2>&1)" = 10 ] || update
for t in $TABLES; do
  e=$(errs_for $t)
  observe "$t" "rows $(q "SELECT COUNT(*) FROM $T.$t" 2>&1); errors: ${e:-none}$( [ -n "${e// /}" ] && echo "; $(msgs_for $t | head -1 | cut -c1-220)")"
done
observe update-chain "state $STATE; all errors: ${ERRS:-none}; $CHAIN"
# the control keeps loading while the others fail
echo "INSERT INTO lfcddemo.p_ok (id, v) VALUES (11, 'after');" | src >/dev/null
settle_rows "SELECT COUNT(*) FROM $T.p_ok" 11
[ "$SETTLED" = 1 ] && claim others-keep-loading PASS "p_ok picked up a new row while the other tables failed (errors: ${ERRS:-none})" \
  || claim others-keep-loading FAIL "p_ok rows $(q "SELECT COUNT(*) FROM $T.p_ok" 2>&1); errors: ${ERRS:-none}"
# fix the source, then a full refresh of the failed tables recovers them
wait $LOCKER 2>/dev/null   # the lock is released when its 15 minutes are up
src >/dev/null <<EOF
REVOKE SELECT ON lfcddemo.p_noselect TO $CONN_USER;
DECLARE @ct sysname = (SELECT OBJECT_SCHEMA_NAME(object_id) + '.' + name FROM sys.tables
  WHERE object_id = (SELECT object_id FROM cdc.change_tables WHERE source_object_id = OBJECT_ID('lfcddemo.p_cdcdeny')));
EXEC ('REVOKE SELECT ON ' + @ct + ' TO $CONN_USER');
DECLARE @cii sysname = (SELECT TOP 1 name FROM sys.tables WHERE name LIKE 'lakeflowCaptureInstanceInfo%');
IF @cii IS NOT NULL EXEC ('REVOKE UPDATE ON dbo.' + @cii + ' TO $CONN_USER');
EOF
track ct p_notrack
sleep "$WAIT"
FR=""; for t in p_noselect p_notrack p_cdcdeny p_ciideny p_locked; do [ "$(q "SELECT COUNT(*) FROM $T.$t" 2>&1)" = 10 ] || FR+="${FR:+,}$t"; done
if [ -n "$FR" ]; then
  update "$FR"
  bad=""; for t in ${FR//,/ }; do [ "$(expect 10 "SELECT COUNT(*) FROM $T.$t")" = 10 ] || bad+=" $t($(errs_for $t | tr -d ' '))"; done
  [ -z "$bad" ] && claim fix-then-refresh-recovers PASS "after fixing the source, a full refresh of $FR loads each table's 10 rows" \
    || claim fix-then-refresh-recovers FAIL "after fixing and refreshing $FR, still off:$bad"
fi
result_md sqlserver-permissions
exit $FAILED
