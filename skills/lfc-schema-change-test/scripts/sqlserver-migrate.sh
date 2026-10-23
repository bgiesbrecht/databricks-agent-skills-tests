#!/usr/bin/env bash
# sqlserver-migrate.sh: can a SQL Server pipeline move between integrated CDC and the gateway model and keep its
# destination tables? Answers a field question. In place: the same ingestion pipeline gets a new source, so its tables stay.
#
#   PART=A  created as integrated CDC -> a new gateway (the case the question asks; no earlier gateway to go back to)
#   PART=B  created on a gateway -> integrated CDC -> back to the same gateway (the path the product's own migration tests run)
#   PART=C  side by side: a new gateway + ingestion pipeline writing to the same destination tables, while the
#           integrated pipeline exists, and then after it's deleted (both A and B are refused by the API, 2026-10-21)
#
# Each step records whether the spec change was accepted, the update's errors, whether the tables kept their rows or
# were loaded again (Delta history), and whether a new source row arrives.
#   Needs and options: as sqlserver-add-column.sh (PROFILE CONNECTION CATALOG SRC_SQL CONN_USER; SRC_ENV, KEEP, OUT)
set -uo pipefail
PART=${PART:-A}
case $PART in A|C) MODE=integrated;; B) MODE=standard;; *) echo "PART must be A, B or C"; exit 2;; esac
. "$(dirname "$0")/lib.sh"
lfc_init mig$(echo $PART | tr A-Z a-z)
FP_TABLES="ctm cdcm"

src_db <<'EOF'
CREATE TABLE lfcddemo.ctm (id INT NOT NULL PRIMARY KEY, v VARCHAR(20));
CREATE TABLE lfcddemo.cdcm (id INT NOT NULL PRIMARY KEY, v VARCHAR(20));
EOF
fill ctm 10; fill cdcm 10; src_util; track ct ctm; track cdc cdcm
pipelines_create "$(obj ctm),$(obj cdcm)"
both() { q "SELECT (SELECT COUNT(*) FROM $T.ctm), (SELECT COUNT(*) FROM $T.cdcm)" 2>&1 | tr '\t' ' '; }
update; [ "$(both)" = "10 10" ] || update
[ "$(both)" = "10 10" ] || { echo "baseline rows wrong: $(both); $ERRS"; exit 1; }

# reloaded <since>: the Delta operations on ctm since <since>; a re-snapshot shows as a full overwrite
ops_since() { q "SELECT CONCAT_WS(',', COLLECT_SET(operation)) FROM (DESCRIBE HISTORY $T.ctm) WHERE timestamp >= '$1'" 2>&1; }
# flip <to>: point the pipeline at the gateway $GW (to=gateway) or at the connection (to=integrated)
flip() {
  dbx pipelines get "$AP" -o json | yq -o json '.spec' > "$W/spec.json"
  if [ "$1" = gateway ]; then
    yq -i -o json 'del(.ingestion_definition.connection_name) | del(.ingestion_definition.connector_type) | .ingestion_definition.ingestion_gateway_id = strenv(GW)' "$W/spec.json"
  else
    yq -i -o json 'del(.ingestion_definition.ingestion_gateway_id) | .ingestion_definition.connection_name = strenv(CONNECTION) | .ingestion_definition.connector_type = "CDC" | .configuration."pipelines.directCdc.migrationSourceGatewayId" = strenv(GW)' "$W/spec.json"
  fi
  FLIP_OUT=$(dbx pipelines update "$AP" --json @"$W/spec.json" 2>&1); FLIP_RC=$?
}
export GW CONNECTION
# step <name> <to> <next id>: flip, one source row, update, record
step() {
  local t0; t0=$(date -u +%FT%TZ)
  flip "$2"
  if [ $FLIP_RC -ne 0 ]; then observe "$1-flip" "refused: $(echo "$FLIP_OUT" | head -2 | tr '\n' ' ' | cut -c1-240)"; return 1; fi
  observe "$1-flip" "accepted"
  printf "INSERT INTO lfcddemo.ctm (id, v) VALUES (%s, 'after_%s'); INSERT INTO lfcddemo.cdcm (id, v) VALUES (%s, 'after_%s');\n" "$3" "$1" "$3" "$1" | src >/dev/null
  [ "$2" = gateway ] && MODE=standard || MODE=integrated; WAIT=$([ "$2" = gateway ] && echo "${GATEWAY_WAIT:-90}" || echo 0)
  settle_rows "SELECT (SELECT COUNT(*) FROM $T.ctm WHERE id = $3), (SELECT COUNT(*) FROM $T.cdcm WHERE id = $3)" "$(printf '1\t1')"
  observe "$1-update" "rows $(both) (source $3 each); new row arrived: $([ "$SETTLED" = 1 ] && echo yes || echo no); errors: ${ERRS:-none}; updates: $CHAIN"
  observe "$1-history" "ctm Delta operations since the flip: $(ops_since "$t0")"
  [ "$(both)" = "$3 $3" ] && claim "$1-keeps-tables" PASS "after the flip both tables hold every source row ($3 each), the same tables" \
    || claim "$1-keeps-tables" FAIL "rows $(both), source $3 each"
}

if [ "$PART" = C ]; then
  gateway_create
  AP1=$AP
  AP2=$(dbx pipelines create -o json --json "{\"name\":\"${APN}_2\",\"catalog\":\"$CATALOG\",\"schema\":\"$S\",\"serverless\":true,
    \"ingestion_definition\":{\"ingestion_gateway_id\":\"$GW\",\"objects\":[$(obj ctm),$(obj cdcm)]}}" 2>&1)
  AP2_ID=$(echo "$AP2" | yq '.pipeline_id' 2>/dev/null)
  if [ -z "$AP2_ID" ] || [ "$AP2_ID" = null ]; then observe side-by-side-create "refused: $(echo "$AP2" | head -2 | tr '\n' ' ' | cut -c1-240)"
  else
    observe side-by-side-create "accepted ($AP2_ID)"
    AP=$AP2_ID; MODE=standard; WAIT=${GATEWAY_WAIT:-90}; sleep "$WAIT"; update
    observe side-by-side-update "state $STATE; errors: ${ERRS:-none}$( [ -n "${ERRS// /}" ] && echo "; $(yq -r '.[] | .error.exceptions[]? | select(.error_class) | .message' "$W/ev_last.json" | head -1 | cut -c1-240)")"
  fi
  # delete the integrated pipeline: do its tables go with it?
  dbx pipelines delete "$AP1" >/dev/null; sleep 30
  observe delete-old-pipeline "after deleting the integrated pipeline, destination ctm: $(q "SELECT COUNT(*) FROM $T.ctm" 2>&1 | cut -c1-160)"
  if [ -n "$AP2_ID" ] && [ "$AP2_ID" != null ]; then
    AP=$AP2_ID; MODE=standard; T0=$(date -u +%FT%TZ); update
    echo "INSERT INTO lfcddemo.ctm (id, v) VALUES (11, 'after'); INSERT INTO lfcddemo.cdcm (id, v) VALUES (11, 'after');" | src >/dev/null
    settle_rows "SELECT (SELECT COUNT(*) FROM $T.ctm), (SELECT COUNT(*) FROM $T.cdcm)" "$(printf '11\t11')"
    observe new-pipeline-after-delete "new pipeline: rows $(both); new row arrived: $([ "$SETTLED" = 1 ] && echo yes || echo no); errors: ${ERRS:-none}; $CHAIN"
  else AP=""; fi
elif [ "$PART" = A ]; then
  gateway_create
  sleep "${GATEWAY_WAIT:-90}"   # let the new gateway snapshot and start reading changes
  step integrated-to-new-gateway gateway 11
else
  dbx pipelines stop "$GW" >/dev/null 2>&1   # the forward migration stops the gateway; it isn't deleted
  step gateway-to-integrated integrated 11 && {
    dbx pipelines start-update "$GW" >/dev/null 2>&1
    step back-to-gateway gateway 12
  }
fi

result_md "sqlserver-migrate part $PART"
exit $FAILED
