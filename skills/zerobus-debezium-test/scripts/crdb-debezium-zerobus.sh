#!/usr/bin/env bash
# crdb-debezium-zerobus.sh: CockroachDB -> Debezium Server (Zerobus sink) -> append-only bronze change-log tables.
#
# Runs from the laptop and drives a cloud VM over SSH (lfc-source-cloud-vm). It creates, on a fresh epoch:
#   - a schema in CATALOG with one bronze change-log table, cdc_log, for every source table: Debezium's envelope with the
#     key, the event (before, after, op, source) and the position as VARIANT, liquid-clustered by destination (the source table);
#   - a service principal with an OAuth secret, granted SELECT and MODIFY on cdc_log (Zerobus writes as it);
#   - on the VM, a Podman network with CockroachDB and Debezium Server, which streams a sinkless changefeed to Zerobus.
# Then it checks that the initial snapshot lands, runs inserts, updates and deletes, and counts each op in bronze.
# Everything it created is removed on exit (KEEP=1 keeps it). Nothing secret is printed: the OAuth secret lives only in
# 0600 files (a temp dir here, a temp dir on the VM), both deleted at the end.
#
#   DROP_FIELDS=before,transaction,ts_ms,ts_us drops top-level event fields with Kafka's ReplaceField transform.
# Needs: PROFILE (Databricks CLI profile), CATALOG (with its own storage), VM_IP; optional VM_USER (azureuser),
#   SSH_KEY (~/.ssh/lfc_test_rsa), CRDB_IMAGE, DBZ_IMAGE, WAIT (seconds to wait for rows, default 180), OUT=<file.md>.
# Exit 0 when every claim passed, 1 when one failed, 2 when a prerequisite is missing.
set -uo pipefail
export PATH=/opt/homebrew/bin:$PATH
: "${PROFILE:?}" "${CATALOG:?}" "${VM_IP:?}"
CRDB_IMAGE=${CRDB_IMAGE:-docker.io/cockroachdb/cockroach:v25.4.13}
DBZ_IMAGE=${DBZ_IMAGE:-quay.io/debezium/server:3.7.0.Final}
WAIT=${WAIT:-180}
dbx() { databricks "$@" --profile "$PROFILE"; }
SSH=(ssh -i "${SSH_KEY:-$HOME/.ssh/lfc_test_rsa}" -o BatchMode=yes "${VM_USER:-azureuser}@$VM_IP")
vm() { "${SSH[@]}" "$@"; }
RESULTS=(); FAILED=0
claim() { RESULTS+=("| \`$1\` | $2 | $3 |"); [ "$2" = PASS ] || FAILED=1; echo "$2 $1: $3"; }
observe() { RESULTS+=("| \`$1\` | OBSERVED | $2 |"); echo "OBSERVED $1: $2"; }

# --- pre-flight -------------------------------------------------------------------------------------------------------
umask 077; W=$(mktemp -d)
ME=$(dbx current-user me -o json | yq '.userName') || { echo "profile $PROFILE doesn't authenticate"; exit 2; }
PREFIX=${PREFIX:-$(echo "$ME" | cut -d@ -f1 | tr -d '.-' | tr 'A-Z' 'a-z')}
eval "$(dbx metastores current -o json | yq -o shell '{"WS_ID": .workspace_id}')"
eval "$(dbx metastores summary -o json | yq -o shell '{"REGION": .region, "CLOUD": .cloud}')"
HOST=$(databricks auth env --profile "$PROFILE" 2>/dev/null | yq -p json '.env.DATABRICKS_HOST' 2>/dev/null)
case $CLOUD in azure) ZB="https://$WS_ID.zerobus.$REGION.azuredatabricks.net";; aws) ZB="https://$WS_ID.zerobus.$REGION.cloud.databricks.com";;
  *) echo "cloud $CLOUD: set the Zerobus endpoint form for it"; exit 2;; esac
[ -n "$HOST" ] && [ "$HOST" != null ] || { echo "no host for profile $PROFILE"; exit 2; }
WAREHOUSE=${WAREHOUSE:-$(dbx warehouses list -o json | yq '[.[] | select(.enable_serverless_compute)][0].id')}; export WAREHOUSE
vm 'command -v podman >/dev/null' || { echo "no Podman on $VM_IP"; exit 2; }
E=$(date +%s); S=${PREFIX}_crdb_dbz_$E; NET=crdb-dbz-$E; CRDB=$PREFIX-crdb-$E; DBZ=$PREFIX-debezium-$E; RD=/tmp/dbz-$E
T="\`$CATALOG\`.$S"
echo "run $E: schema $CATALOG.$S, VM containers $CRDB and $DBZ"

sql() {
  yq -n -o json '.warehouse_id = strenv(WAREHOUSE) | .wait_timeout = "50s" | .statement = strenv(Q)' > "$W/st.json"
  dbx api post /api/2.0/sql/statements --json @"$W/st.json" > "$W/st.out"
  [ "$(yq '.status.state' "$W/st.out")" = SUCCEEDED ] || { yq '.status.state + ": " + (.status.error.message // "")' "$W/st.out" | cut -c1-300 >&2; return 1; }
  yq -r '(.result.data_array // [])[] | @tsv' "$W/st.out"
}
q() { export Q=$1; sql; }
crdb() { vm "sudo podman exec -i $CRDB cockroach sql --insecure --format=tsv"; }   # SQL from stdin

cleanup() {
  [ "${KEEP:-0}" = 1 ] && { echo "KEEP=1: left $CATALOG.$S, SP ${SP_NAME:-}, VM containers and $RD"; rm -rf "$W"; return; }
  vm "sudo podman rm -f $DBZ $CRDB >/dev/null 2>&1; sudo podman network rm $NET >/dev/null 2>&1; sudo rm -rf $RD" || true
  [ -n "${SP_ID:-}" ] && dbx service-principals delete "$SP_ID" >/dev/null 2>&1
  dbx schemas delete "$CATALOG.$S" --force >/dev/null 2>&1
  left=$(vm "sudo podman ps -a --format '{{.Names}}' | grep -c -E '^($DBZ|$CRDB)\$'" 2>/dev/null)
  echo "cleanup: containers left ${left:-?}; SP ${SP_ID:+deleted}; schema dropped"
  rm -rf "$W"
}
trap cleanup EXIT

# --- source: CockroachDB with a small schema ---------------------------------------------------------------------------
vm "sudo podman network create $NET >/dev/null && sudo podman run -d --name $CRDB --network $NET --network-alias cockroachdb \
  $CRDB_IMAGE start-single-node --insecure --advertise-addr=cockroachdb >/dev/null" || { echo "CockroachDB start failed"; exit 2; }
for _ in $(seq 1 30); do echo 'SELECT 1;' | crdb >/dev/null 2>&1 && break; sleep 2; done
crdb >/dev/null <<'SQL' || { echo "CockroachDB setup failed"; exit 2; }
SET CLUSTER SETTING kv.rangefeed.enabled = true;
CREATE DATABASE shop;
CREATE TABLE shop.customers (id INT PRIMARY KEY, name STRING NOT NULL, tier STRING NOT NULL);
CREATE TABLE shop.orders (id INT PRIMARY KEY, customer_id INT NOT NULL, amount DECIMAL(10,2) NOT NULL, status STRING NOT NULL);
INSERT INTO shop.customers SELECT g, 'customer_' || g::STRING, 'bronze' FROM generate_series(1, 5) g;
INSERT INTO shop.orders SELECT g, 1 + g % 5, g * 10.5, 'placed' FROM generate_series(1, 5) g;
SQL
CRDB_VERSION=$(echo 'SELECT version();' | crdb | tail -1 | cut -c1-80)
# T: the snapshot time. The snapshot is taken out of band as of T (phase 2); Debezium starts its change feed at T and
# takes no snapshot of its own, so the log holds only changes after the snapshot.
T_HLC=$(echo 'SELECT cluster_logical_timestamp();' | crdb | tail -1)

# --- destination: bronze tables, a service principal with a secret, grants -------------------------------------------
dbx schemas create "$S" "$CATALOG" >/dev/null || exit 2
LOG=$T.cdc_log
q "CREATE TABLE $LOG (target_table STRING NOT NULL, destination STRING NOT NULL, partition INT, operation STRING NOT NULL,
  idempotency_key STRING, key VARIANT, value VARIANT, source_position VARIANT, headers VARIANT) CLUSTER BY (destination)
  COMMENT 'Append-only change log: one Debezium envelope per source change, all source tables'" >/dev/null || exit 2
SP_NAME=$PREFIX-zerobus-dbz-$E
eval "$(dbx service-principals create --display-name "$SP_NAME" -o json | yq -o shell '{"SP_ID": .id, "SP_APP": .applicationId}')"
[ -n "${SP_ID:-}" ] || { echo "service principal create failed"; exit 2; }
dbx service-principal-secrets-proxy create "$SP_ID" -o json > "$W/secret.json" || { echo "secret create failed"; exit 2; }
for g in "GRANT USE CATALOG ON CATALOG \`$CATALOG\` TO \`$SP_APP\`" "GRANT USE SCHEMA ON SCHEMA $T TO \`$SP_APP\`" \
         "GRANT SELECT, MODIFY ON TABLE $LOG TO \`$SP_APP\`"; do
  q "$g" >/dev/null || exit 2
done

# --- Debezium Server: CockroachDB connector, envelopes into one change-log table ------------------------------------------
export SP_APP ZB HOST CATALOG S
yq -r '"debezium.sink.zerobus.client.secret=" + .secret' "$W/secret.json" > "$W/secret.line"
cat > "$W/application.properties" <<EOF
debezium.source.connector.class=io.debezium.connector.cockroachdb.CockroachDBConnector
debezium.source.name=crdb-zerobus
debezium.source.topic.prefix=crdb
debezium.source.database.hostname=cockroachdb
debezium.source.database.port=26257
debezium.source.database.user=root
debezium.source.database.password=
debezium.source.database.dbname=shop
debezium.source.database.sslmode=disable
debezium.source.database.server.name=crdb
debezium.source.table.include.list=public.customers,public.orders
debezium.source.snapshot.mode=no_data
debezium.source.cockroachdb.changefeed.cursor=$T_HLC
debezium.source.extended.headers.enabled=false
debezium.source.tombstones.on.delete=false
debezium.source.cockroachdb.changefeed.sink.type=sinkless
debezium.source.cockroachdb.changefeed.resolved.interval=5s
debezium.source.cockroachdb.changefeed.include.diff=false
debezium.source.cockroachdb.changefeed.include.updated=true
debezium.source.offset.storage=org.apache.kafka.connect.storage.FileOffsetBackingStore
debezium.source.offset.storage.file.filename=/debezium/data/offsets.dat
debezium.source.offset.flush.interval.ms=1000
debezium.format.key=json
debezium.format.value=json
debezium.format.key.schemas.enable=false
debezium.format.value.schemas.enable=false
$( [ -n "${DROP_FIELDS:-}" ] && printf 'debezium.transforms=slim\ndebezium.transforms.slim.type=org.apache.kafka.connect.transforms.ReplaceField$Value\ndebezium.transforms.slim.exclude=%s\n' "$DROP_FIELDS" )
debezium.sink.type=zerobus
debezium.sink.zerobus.endpoint=$ZB
debezium.sink.zerobus.workspace.url=$HOST
debezium.sink.zerobus.client.id=$SP_APP
debezium.sink.zerobus.payload.mode=envelope
debezium.sink.zerobus.table=$CATALOG.$S.cdc_log
debezium.sink.zerobus.record.format=json
debezium.sink.zerobus.idempotency.mode=source
debezium.sink.zerobus.tombstone.handling.mode=drop
debezium.sink.zerobus.json.flexible.fields.encoding=string
debezium.sink.zerobus.max.record.bytes=10000000
EOF
cat "$W/secret.line" >> "$W/application.properties"; rm -f "$W/secret.line" "$W/secret.json"
vm "umask 077; mkdir -p $RD/data && cat > $RD/application.properties" < "$W/application.properties"; rm -f "$W/application.properties"
# :U gives the mounted files to the container user (Debezium runs as a non-root user), so the secret stays 0600
vm "sudo podman run -d --name $DBZ --network $NET -v $RD/application.properties:/debezium/config/application.properties:ro,U \
  -v $RD/data:/debezium/data:U $DBZ_IMAGE >/dev/null" || { echo "Debezium start failed"; exit 2; }

# --- checks -----------------------------------------------------------------------------------------------------------
# counts <table>: change-log rows for that source table per operation, as "create=.. read=.. update=.. delete=.."
counts() { q "SELECT operation, COUNT(*) FROM $LOG WHERE destination LIKE '%.$1' GROUP BY operation ORDER BY operation" 2>/dev/null | awk -F'\t' '{printf "%s=%s ", $1, $2}'; }
await() { # await <table> <operation> <n>: seconds until the log has n rows for that table and operation, or empty on timeout
  local t0=$SECONDS; while [ $((SECONDS - t0)) -lt "$WAIT" ]; do
    [ "$(q "SELECT COUNT(*) FROM $LOG WHERE destination LIKE '%.$1' AND operation = '$2'" 2>/dev/null)" -ge "$3" ] 2>/dev/null && { echo $((SECONDS - t0)); return; }
    sleep 5; done; }
sleep 30   # let the change feed start
R=$(q "SELECT COUNT(*) FROM $LOG WHERE operation = 'read'" 2>/dev/null)
[ "$R" = 0 ] && claim no-snapshot-events PASS "no read events: the snapshot stays out of the log (feed starts at T=$T_HLC)" \
  || claim no-snapshot-events FAIL "read events in the log: ${R:-query failed}"

crdb >/dev/null <<'SQL'
INSERT INTO shop.customers VALUES (6, 'customer_6', 'silver'), (7, 'customer_7', 'gold');
UPDATE shop.customers SET tier = 'gold' WHERE id = 1;
DELETE FROM shop.customers WHERE id = 2;
INSERT INTO shop.orders VALUES (6, 6, 99.99, 'placed');
UPDATE shop.orders SET status = 'shipped' WHERE id IN (1, 3);
DELETE FROM shop.orders WHERE id = 5;
SQL
c=$(await customers create 2); u=$(await customers update 1); d=$(await customers delete 1)
[ -n "$c" ] && [ -n "$u" ] && [ -n "$d" ] && claim customers-changes PASS "2 inserts, 1 update, 1 delete arrive as create/update/delete events (latest within ${d}s)" \
  || claim customers-changes FAIL "customers: $(counts customers)"
c=$(await orders create 1); u=$(await orders update 2); d=$(await orders delete 1)
[ -n "$c" ] && [ -n "$u" ] && [ -n "$d" ] && claim orders-changes PASS "1 insert, 2 updates, 1 delete arrive as create/update/delete events (latest within ${d}s)" \
  || claim orders-changes FAIL "orders: $(counts orders)"
R=$(q "SELECT key:id::INT, value:after IS NULL OR value:after::STRING = 'null', value:source:ts_ns::STRING FROM $LOG WHERE destination LIKE '%.customers' AND operation = 'delete'" 2>&1 | tr '\t\n' ' ')
observe delete-event "customers delete (key.id, after is null, source.ts_ns): $R"
R=$(q "SELECT value:after:tier::STRING, value:before IS NULL FROM $LOG WHERE destination LIKE '%.customers' AND operation = 'update'" 2>&1 | tr '\t\n' ' ')
observe update-event "customers update (after.tier, before is null with include.diff=false): $R"
observe variant-paths "value top-level keys: $(q "SELECT CONCAT_WS(',', SORT_ARRAY(MAP_KEYS(FROM_JSON(TO_JSON(value), 'MAP<STRING,STRING>')))) FROM $LOG LIMIT 1" 2>&1 | cut -c1-200)"
observe event-bytes "per event, average bytes (op: total value after source key position headers): $(q "SELECT operation, ROUND(AVG(LENGTH(TO_JSON(value)) + LENGTH(TO_JSON(key)) + LENGTH(COALESCE(TO_JSON(source_position),'')) + LENGTH(COALESCE(TO_JSON(headers),'')) + LENGTH(idempotency_key))), ROUND(AVG(LENGTH(TO_JSON(value)))), ROUND(AVG(LENGTH(TO_JSON(value:after)))), ROUND(AVG(LENGTH(TO_JSON(value:source)))), ROUND(AVG(LENGTH(TO_JSON(key)))), ROUND(AVG(LENGTH(COALESCE(TO_JSON(source_position),'')))), ROUND(AVG(LENGTH(COALESCE(TO_JSON(headers),'')))) FROM $LOG GROUP BY operation ORDER BY 1" 2>&1 | tr '\t\n' ' ;')"
observe event-sample "one update event value: $(q "SELECT TO_JSON(value) FROM $LOG WHERE operation = 'update' LIMIT 1" 2>&1 | cut -c1-400)"
observe change-log "rows by operation, customers: $(counts customers); orders: $(counts orders); clustering: $(q "DESCRIBE DETAIL $LOG" 2>/dev/null | head -1 | grep -o 'destination' | head -1)"

# --- result -----------------------------------------------------------------------------------------------------------
{
  echo "# crdb-debezium-zerobus run $E"; echo
  echo "- Date (UTC): $(date -u +%F)"
  echo "- Source: CockroachDB $CRDB_VERSION, image $CRDB_IMAGE ($(vm "sudo podman inspect -f '{{.ImageDigest}}' $CRDB"))"
  echo "- Debezium: $DBZ_IMAGE ($(vm "sudo podman inspect -f '{{.ImageDigest}}' $DBZ")), CockroachDB connector, sinkless changefeed, Zerobus sink (envelope into one change-log table, VARIANT fields, idempotency source)"
  echo "- Host: $(vm '. /etc/os-release; echo $PRETTY_NAME'), $(vm 'podman --version')"
  echo "- Destination: Zerobus in $CLOUD $REGION, one append-only change-log Delta table, liquid-clustered by destination (the source table)"
  echo; echo "| Claim | Result | Observation |"; echo "|---|---|---|"
  printf '%s\n' "${RESULTS[@]}"
} | tee "${OUT:-/dev/null}"
exit $FAILED
