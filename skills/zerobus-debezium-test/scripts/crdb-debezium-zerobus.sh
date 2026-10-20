#!/usr/bin/env bash
# crdb-debezium-zerobus.sh: CockroachDB -> snapshot as of T into a Volume, and Debezium Server (Zerobus sink) from T
# -> one append-only bronze change log -> silver, one AUTO CDC table per source table.
#
# Runs from the laptop and drives a cloud VM over SSH (lfc-source-cloud-vm). It creates, on a fresh epoch:
#   - a schema in CATALOG with one bronze change-log table, cdc_log, for every source table: Debezium's envelope with the
#     key, the event (after, op, ts_ns) and the position as VARIANT, liquid-clustered by destination (the source table);
#   - a service principal with an OAuth secret, granted SELECT and MODIFY on cdc_log (Zerobus writes as it);
#   - on the VM, a Podman network with CockroachDB and Debezium Server, which streams a sinkless changefeed to Zerobus.
#   - phase 2: a Volume with the snapshot (EXPORT INTO PARQUET ... AS OF SYSTEM TIME T), a UC connection to CockroachDB
#     (the schema comes through it with remote_query), and a serverless pipeline with the silver tables.
# Phase 1 checks that no snapshot events reach the log and counts each op in bronze. Phase 2 checks that silver equals
# the source, after the phase 1 changes and again after a second round. Everything it created is removed on exit
# (KEEP=1 keeps it). Nothing secret is printed: the OAuth secret lives only in 0600 files (a temp dir here, a temp dir
# on the VM), both deleted at the end.
#
#   PHASE=1 stops after bronze, PHASE=2 after silver; PHASE=3 (the default) adds gold, a materialized view. DROP_FIELDS (default before,transaction,ts_ms,ts_us,source) drops top-level event fields
#   with Kafka's ReplaceField transform; keep ts_ns, which silver sequences by. ENRICHED_PROPERTIES=source asks
#   CockroachDB for its source block (the 3.7.0.Final connector drops its commit time anyway).
# Needs: PROFILE (Databricks CLI profile), CATALOG (with its own storage), VM_IP; optional VM_USER (azureuser),
#   SSH_KEY (~/.ssh/lfc_test_rsa), CRDB_IMAGE, DBZ_IMAGE, CRDB_PORT (published for the UC connection, default 30026),
#   WAIT (seconds to wait for rows, default 180), OUT=<file.md>.
# Exit 0 when every claim passed, 1 when one failed, 2 when a prerequisite is missing.
set -uo pipefail
export PATH=/opt/homebrew/bin:$PATH
: "${PROFILE:?}" "${CATALOG:?}" "${VM_IP:?}"
CRDB_IMAGE=${CRDB_IMAGE:-docker.io/cockroachdb/cockroach:v25.4.13}
DBZ_IMAGE=${DBZ_IMAGE:-quay.io/debezium/server:3.7.0.Final}
WAIT=${WAIT:-180}; PHASE=${PHASE:-3}; CHECK=${CHECK:-$PWD/scripts/scd2-history-check.py} CRDB_PORT=${CRDB_PORT:-30026}
DROP_FIELDS=${DROP_FIELDS-before,transaction,ts_ms,ts_us,source}   # DROP_FIELDS= (empty) keeps the whole event
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
  [ -n "${PIPELINE_ID:-}" ] && dbx pipelines delete "$PIPELINE_ID" >/dev/null 2>&1
  [ -n "${CONN:-}" ] && dbx connections delete "$CONN" >/dev/null 2>&1
  [ -n "${WSDIR:-}" ] && dbx workspace delete "$WSDIR" --recursive >/dev/null 2>&1
  dbx schemas delete "$CATALOG.$S" --force >/dev/null 2>&1
  left=$(vm "sudo podman ps -a --format '{{.Names}}' | grep -c -E '^($DBZ|$CRDB)\$'" 2>/dev/null)
  echo "cleanup: containers left ${left:-?}; SP ${SP_ID:+deleted}; pipeline ${PIPELINE_ID:+deleted}; connection ${CONN:+deleted}; schema dropped"
  rm -rf "$W"
}
trap cleanup EXIT

# --- source: CockroachDB with a small schema ---------------------------------------------------------------------------
vm "sudo podman network create $NET >/dev/null && sudo podman run -d --name $CRDB --network $NET --network-alias cockroachdb \
  -p $CRDB_PORT:26257 $CRDB_IMAGE start-single-node --insecure --advertise-addr=cockroachdb >/dev/null" || { echo "CockroachDB start failed"; exit 2; }
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
# T: the snapshot time. The snapshot is taken out of band as of T; Debezium starts its change feed at T and takes no
# snapshot of its own, so the log holds only changes after the snapshot.
T_HLC=$(echo 'SELECT cluster_logical_timestamp();' | crdb | tail -1)
T_NS=${T_HLC%%.*}   # the wall time in nanoseconds: silver's sequence for the snapshot rows
TABLES="customers orders"
if [ "$PHASE" -ge 2 ]; then
  # the snapshot: every table as of T, into Parquet in the node's external directory, then onto the laptop. DECIMAL goes
  # out as STRING: v25.4.13 writes a DECIMAL column as BYTE_ARRAY annotated DECIMAL but filled with the number's text,
  # so readers get "21.00" as the unscaled integer 0x32312E3030 (2155734753.76). Silver casts it back.
  for t in $TABLES; do
    cols=$(echo "SELECT string_agg(CASE WHEN data_type = 'numeric' THEN column_name || '::STRING AS ' || column_name ELSE column_name END,
      ', ' ORDER BY ordinal_position) FROM shop.information_schema.columns
      WHERE table_schema = 'public' AND table_name = '$t' AND is_hidden = 'NO';" | crdb | tail -1)
    echo "EXPORT INTO PARQUET 'nodelocal://self/snap/$t' FROM SELECT $cols FROM shop.$t AS OF SYSTEM TIME '$T_HLC';" | crdb >/dev/null \
      || { echo "EXPORT of $t failed"; exit 2; }
  done
  mkdir -p "$W/snap" && vm "sudo podman exec $CRDB tar -C /cockroach/cockroach-data/extern/snap -cf - ." | tar -xf - -C "$W/snap" \
    || { echo "snapshot copy failed"; exit 2; }
fi

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
$( [ -n "${ENRICHED_PROPERTIES:-}" ] && echo "debezium.source.cockroachdb.changefeed.enriched.properties=$ENRICHED_PROPERTIES" )
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
R=$(q "SELECT key:id::INT, value:after IS NULL OR value:after::STRING = 'null', value:ts_ns::STRING FROM $LOG WHERE destination LIKE '%.customers' AND operation = 'delete'" 2>&1 | tr '\t\n' ' ')
observe delete-event "customers delete (key.id, after is null, ts_ns): $R"
R=$(q "SELECT value:after:tier::STRING, value:before IS NULL FROM $LOG WHERE destination LIKE '%.customers' AND operation = 'update'" 2>&1 | tr '\t\n' ' ')
observe update-event "customers update (after.tier, before is null with include.diff=false): $R"
observe commit-time "events, distinct source.ts_hlc, distinct source.ts_ns, distinct ts_ns: $(q "SELECT COUNT(*), COUNT(DISTINCT value:source:ts_hlc::STRING), COUNT(DISTINCT value:source:ts_ns::STRING), COUNT(DISTINCT value:ts_ns::STRING) FROM $LOG" 2>&1 | tr '\t' ' ')"
observe variant-paths "value top-level keys: $(q "SELECT CONCAT_WS(',', SORT_ARRAY(MAP_KEYS(FROM_JSON(TO_JSON(value), 'MAP<STRING,STRING>')))) FROM $LOG LIMIT 1" 2>&1 | cut -c1-200)"
observe event-bytes "per event, average bytes (op: total value after source key position headers): $(q "SELECT operation, ROUND(AVG(LENGTH(TO_JSON(value)) + LENGTH(TO_JSON(key)) + LENGTH(COALESCE(TO_JSON(source_position),'')) + LENGTH(COALESCE(TO_JSON(headers),'')) + LENGTH(idempotency_key))), ROUND(AVG(LENGTH(TO_JSON(value)))), ROUND(AVG(LENGTH(TO_JSON(value:after)))), ROUND(AVG(LENGTH(TO_JSON(value:source)))), ROUND(AVG(LENGTH(TO_JSON(key)))), ROUND(AVG(LENGTH(COALESCE(TO_JSON(source_position),'')))), ROUND(AVG(LENGTH(COALESCE(TO_JSON(headers),'')))) FROM $LOG GROUP BY operation ORDER BY 1" 2>&1 | tr '\t\n' ' ;')"
observe event-sample "one update event value: $(q "SELECT TO_JSON(value) FROM $LOG WHERE operation = 'update' LIMIT 1" 2>&1 | cut -c1-400)"
observe change-log "rows by operation, customers: $(counts customers); orders: $(counts orders); clustering: $(q "DESCRIBE DETAIL $LOG" 2>/dev/null | head -1 | grep -o 'destination' | head -1)"

# --- phase 2: snapshot in a Volume, schema through a UC connection, silver ---------------------------------------------
if [ "$PHASE" -ge 2 ]; then
  VOL=/Volumes/$CATALOG/$S/snapshot
  q "CREATE VOLUME $T.snapshot COMMENT 'Snapshot as of T, one folder per source table'" >/dev/null || exit 2
  dbx fs cp -r "$W/snap" "dbfs:$VOL" --overwrite >/dev/null || { echo "snapshot upload failed"; exit 2; }
  F=$(for t in $TABLES; do printf '%s=%s ' "$t" "$(dbx fs ls "dbfs:$VOL/$t" -o json | yq '[.[] | select(.name | test("parquet$"))] | length')"; done)
  echo "$F" | grep -q '=0' && claim snapshot-in-volume FAIL "parquet files per table: $F" \
    || claim snapshot-in-volume PASS "EXPORT INTO PARQUET ... AS OF SYSTEM TIME T, into $VOL: parquet files per table: $F"

  # the schema: columns, types and primary keys from CockroachDB's information_schema, through a UC connection
  CONN=$PREFIX-crdb-dbz-$E; export CONN VM_IP CRDB_PORT
  yq -n -o json '.name = strenv(CONN) | .connection_type = "POSTGRESQL" |
    .options = {"host": strenv(VM_IP), "port": strenv(CRDB_PORT), "user": "root", "password": "unused-insecure-node"}' > "$W/conn.json"
  dbx connections create --json @"$W/conn.json" >/dev/null || { echo "connection create failed"; exit 2; }
  # table, ordinal, column, Databricks type, 1 when in the primary key
  fetch_schema() { q "SELECT table_name, ordinal_position, column_name,
       CASE data_type WHEN 'bigint' THEN 'BIGINT' WHEN 'integer' THEN 'INT' WHEN 'smallint' THEN 'SMALLINT'
         WHEN 'numeric' THEN CONCAT('DECIMAL(', numeric_precision, ',', numeric_scale, ')') WHEN 'boolean' THEN 'BOOLEAN'
         WHEN 'double precision' THEN 'DOUBLE' WHEN 'real' THEN 'FLOAT' WHEN 'date' THEN 'DATE'
         WHEN 'timestamp without time zone' THEN 'TIMESTAMP_NTZ' WHEN 'timestamp with time zone' THEN 'TIMESTAMP'
         ELSE 'STRING' END, in_pk
     FROM remote_query('$CONN', database => 'shop', query => \"
       SELECT c.table_name, c.ordinal_position, c.column_name, c.data_type, c.numeric_precision, c.numeric_scale,
              CASE WHEN k.column_name IS NULL THEN 0 ELSE 1 END AS in_pk
       FROM information_schema.columns c
       LEFT JOIN information_schema.table_constraints tc
         ON tc.table_schema = c.table_schema AND tc.table_name = c.table_name AND tc.constraint_type = 'PRIMARY KEY'
       LEFT JOIN information_schema.key_column_usage k
         ON k.constraint_schema = tc.constraint_schema AND k.constraint_name = tc.constraint_name AND k.column_name = c.column_name
       WHERE c.table_schema = 'public' AND c.is_hidden = 'NO'\")
     ORDER BY 1, 2" > "$W/schema.tsv" 2>"$W/schema.err"; }
  fetch_schema; cp "$W/schema.tsv" "$W/schema0.tsv"   # schema0: the columns the snapshot has
  if [ -s "$W/schema.tsv" ]; then
    claim schema-from-connection PASS "remote_query on a POSTGRESQL connection: $(awk -F'\t' '{c[$1]=c[$1] (c[$1]?", ":"") $3 " " $4 ($5==1?" key":"")} END {for (t in c) printf "%s (%s); ", t, c[t]}' "$W/schema.tsv")"
  else claim schema-from-connection FAIL "$(cut -c1-300 "$W/schema.err")"; exit 1; fi

  # silver: per table, the snapshot rows sequenced by T and the change-log rows sequenced by ts_ns, into one AUTO CDC table.
  # A column added after T isn't in the snapshot, so its snapshot rows get NULL there.
  gen_silver() { awk -F'\t' -v vol="$VOL" -v lg="$LOG" -v tns="$T_NS" '
    FNR==NR { insnap[$1 "." $3]=1; next }
    { t=$1; col=$3; ty=$4; cols[t]=cols[t] (cols[t]?", ":"") col; if ($5==1) keys[t]=keys[t] (keys[t]?", ":"") col
      snap[t]=snap[t] (snap[t]?", ":"") "CAST(" ((t "." col) in insnap ? col : "NULL") " AS " ty ") AS " col
      chg[t]=chg[t] (chg[t]?", ":"") ($5==1 ? "key:" : "value:after:") col "::" ty " AS " col }
    END { for (t in cols) {
      printf "CREATE TEMPORARY VIEW %s_snapshot AS SELECT %s, CAST(%s AS BIGINT) AS _seq, \047read\047 AS _op\n  FROM STREAM read_files(\047%s/%s\047, format => \047parquet\047);\n\n", t, snap[t], tns, vol, t
      printf "CREATE TEMPORARY VIEW %s_changes AS SELECT %s, value:ts_ns::BIGINT AS _seq, operation AS _op\n  FROM STREAM(%s) WHERE destination = \047crdb.public.%s\047;\n\n", t, chg[t], lg, t
      printf "CREATE OR REFRESH STREAMING TABLE %s CLUSTER BY (%s)\n  COMMENT \047Current rows of the source table: the snapshot as of T, then the change log\047;\n\n", t, keys[t]
      printf "CREATE FLOW %s_from_snapshot AS AUTO CDC INTO %s FROM STREAM(%s_snapshot)\n  KEYS (%s) SEQUENCE BY _seq COLUMNS * EXCEPT (_seq, _op) STORED AS SCD TYPE 1;\n\n", t, t, t, keys[t]
      printf "CREATE FLOW %s_from_changes AS AUTO CDC INTO %s FROM STREAM(%s_changes)\n  KEYS (%s) APPLY AS DELETE WHEN _op = \047delete\047 SEQUENCE BY _seq COLUMNS * EXCEPT (_seq, _op) STORED AS SCD TYPE 1;\n\n", t, t, t, keys[t]
      # SCD type 2 from the same snapshot, and from the change log without replays (cdc_log_dedup, in dedupe.py)
      printf "CREATE TEMPORARY VIEW %s_changes_dedup AS SELECT %s, value:ts_ns::BIGINT AS _seq, operation AS _op\n  FROM STREAM(cdc_log_dedup) WHERE destination = \047crdb.public.%s\047;\n\n", t, chg[t], t
      hist(t "_history", t "_changes_dedup", "Every version of each source row (SCD type 2), replays removed")
      if (t == "customers") hist(t "_history_nodedup", t "_changes", "Every version (SCD type 2) from the change log as it is, replays included: shows what a restart does") } }
    function hist(h, src, comment) {
      printf "CREATE OR REFRESH STREAMING TABLE %s CLUSTER BY (%s)\n  COMMENT \047%s\047;\n\n", h, keys[t], comment
      printf "CREATE FLOW %s_from_snapshot AS AUTO CDC INTO %s FROM STREAM(%s_snapshot)\n  KEYS (%s) SEQUENCE BY _seq COLUMNS * EXCEPT (_seq, _op) STORED AS SCD TYPE 2;\n\n", h, h, t, keys[t]
      printf "CREATE FLOW %s_from_changes AS AUTO CDC INTO %s FROM STREAM(%s)\n  KEYS (%s) APPLY AS DELETE WHEN _op = \047delete\047 SEQUENCE BY _seq COLUMNS * EXCEPT (_seq, _op) STORED AS SCD TYPE 2;\n\n", h, h, src, keys[t] }
  ' "$W/schema0.tsv" "$W/schema.tsv" > "$W/silver.sql"; }
  gen_silver
  # gold: one materialized view for a reader that wants each customer's orders by tier; GOLD_Q is also run on the source
  GOLD_Q="SELECT c.id AS customer_id, c.name, c.tier, COUNT(o.id) AS orders, CAST(COALESCE(SUM(o.amount), 0) AS DECIMAL(12,2)) AS amount
    FROM customers c LEFT JOIN orders o ON o.customer_id = c.id GROUP BY c.id, c.name, c.tier"
  printf 'CREATE OR REFRESH MATERIALIZED VIEW customer_orders CLUSTER BY (tier)\n  COMMENT %s\nAS %s;\n' \
    "'Each customer with the count and total of their orders, for readers that filter by tier'" "$GOLD_Q" > "$W/gold.sql"
  # the change log without replays: a restart re-sends changes with a new ts_ns but the same idempotency_key and row
  # image. The key alone isn't unique (two quick updates of a row share it), so the row image is part of the match.
  cat > "$W/dedupe.py" <<'PY'
from pyspark import pipelines as dp
from pyspark.sql import functions as F


@dp.temporary_view(name="cdc_log_dedup")
def cdc_log_dedup():
    return (spark.readStream.table("cdc_log")
            .withColumn("_event_time", F.timestamp_micros(F.expr("value:ts_ns::BIGINT DIV 1000")))
            .withColumn("_after", F.expr("TO_JSON(value:after)"))
            .withWatermark("_event_time", "10 minutes")
            .dropDuplicatesWithinWatermark(["destination", "idempotency_key", "operation", "_after"])
            .drop("_event_time", "_after"))
PY
  WSDIR=/Users/$ME/crdb_dbz_$E; LIBS="silver.sql dedupe.py"; [ "$PHASE" -ge 3 ] && LIBS="silver.sql dedupe.py gold.sql"
  dbx workspace mkdirs "$WSDIR" || exit 2
  for f in $LIBS; do dbx workspace import "$WSDIR/$f" --file "$W/$f" --format RAW >/dev/null || { echo "$f upload failed"; exit 2; }; done
  export WSDIR CATALOG S PIPE_NAME=$PREFIX-crdb-dbz-silver-$E LIBS
  yq -n -o json '.name = strenv(PIPE_NAME) | .catalog = strenv(CATALOG) | .schema = strenv(S) | .serverless = true |
    .continuous = false | .development = true | .channel = "CURRENT" |
    .libraries = [strenv(LIBS) | split(" ") | .[] | {"file": {"path": strenv(WSDIR) + "/" + .}}]' > "$W/pipe.json"
  PIPELINE_ID=$(dbx pipelines create --json @"$W/pipe.json" -o json | yq '.pipeline_id') || { echo "pipeline create failed"; exit 2; }

  run_silver() { # one pipeline update (extra args go to start-update); prints its final state
    local u st; u=$(dbx pipelines start-update "$PIPELINE_ID" "$@" -o json | yq '.update_id'); echo "$u" > "$W/update_id"
    for _ in $(seq 1 120); do
      st=$(dbx pipelines get-update "$PIPELINE_ID" "$u" -o json | yq '.update.state')
      case $st in COMPLETED|FAILED|CANCELED) break;; esac; sleep 10; done
    [ "$st" = COMPLETED ] || dbx pipelines list-pipeline-events "$PIPELINE_ID" --max-results 50 -o json \
      | yq -r '.[] | select(.level == "ERROR") | .message' | head -3 | cut -c1-300 >&2
    echo "$st"
  }
  same_hist() { # same_hist <table> <round>: the history table's current versions equal the source
    local cols keys a b; cols=$(awk -F'\t' -v t="$1" '$1==t {printf "%s%s", (n++?", ":""), $3}' "$W/schema.tsv")
    keys=$(awk -F'\t' -v t="$1" '$1==t && $5==1 {printf "%s%s", (n++?", ":""), $3}' "$W/schema.tsv")
    a=$(echo "SELECT $cols FROM shop.$1 ORDER BY $keys;" | crdb | tail -n +2)
    b=$(q "SELECT $cols FROM $T.$1_history WHERE __END_AT IS NULL ORDER BY $keys")
    [ "$a" = "$b" ] && claim "history-current-$1-$2" PASS "the current versions in $1_history equal the source: $(echo "$a" | grep -c .) rows" \
      || claim "history-current-$1-$2" FAIL "source vs current history: $(diff <(echo "$a") <(echo "$b") | grep '^[<>]' | tr '\t\n' ', ' | cut -c1-300)"
  }
  history() { # history <table> <history table> <claim|observe>: every version, against CockroachDB's own changefeed from T
    local cols keys r
    cols=$(awk -F'\t' -v t="$1" '$1==t {printf "%s%s", (n++?", ":""), $3}' "$W/schema.tsv")
    keys=$(awk -F'\t' -v t="$1" '$1==t && $5==1 {printf "%s%s", (n++?", ":""), $3}' "$W/schema.tsv")
    echo "SELECT $cols FROM shop.$1 AS OF SYSTEM TIME '$T_HLC';" | crdb > "$W/snap-$1.tsv"
    q "SELECT $cols FROM $T.$2 ORDER BY $keys, __START_AT" > "$W/hist-$2.tsv"
    r=$(python3 -I "$CHECK" "$W/schema.tsv" "$1" "$W/snap-$1.tsv" "$W/feed.tsv" "$W/hist-$2.tsv" 2>&1); local rc=$?
    if [ "$3" = observe ]; then observe "history-$2" "versions expected, in silver, keys that differ: $r"
    elif [ $rc -eq 0 ]; then claim "history-$2" PASS "every version equals the source's changefeed (expected, in silver, keys that differ): $r"
    else claim "history-$2" FAIL "versions expected, in silver, keys that differ: $r"; fi
  }

  same() { # same <table> <round>: silver equals the source, row by row, ordered by the key
    local cols keys a b; cols=$(awk -F'\t' -v t="$1" '$1==t {printf "%s%s", (n++?", ":""), $3}' "$W/schema.tsv")
    keys=$(awk -F'\t' -v t="$1" '$1==t && $5==1 {printf "%s%s", (n++?", ":""), $3}' "$W/schema.tsv")
    a=$(echo "SELECT $cols FROM shop.$1 ORDER BY $keys;" | crdb | tail -n +2)
    b=$(q "SELECT $cols FROM $T.$1 ORDER BY $keys")
    if [ "${3:-}" = observe ]; then observe "silver-$1-$2" "source vs silver: $( [ "$a" = "$b" ] && echo equal || diff <(echo "$a") <(echo "$b") | grep '^[<>]' | tr '\t\n' ', ' | cut -c1-300)"
    elif [ "$a" = "$b" ]; then claim "silver-$1-$2" PASS "silver $1 equals the source: $(echo "$a" | grep -c .) rows"
    else claim "silver-$1-$2" FAIL "source vs silver: $(diff <(echo "$a") <(echo "$b") | grep '^[<>]' | tr '\t\n' ', ' | cut -c1-300)"; fi
  }

  gold() { # gold <round>: the materialized view equals the same query on the source
    [ "$PHASE" -ge 3 ] || return 0
    local a b; a=$(echo "${GOLD_Q//customers/shop.customers} ORDER BY customer_id;" | sed 's/JOIN orders/JOIN shop.orders/' | crdb | tail -n +2)
    b=$(q "SELECT * FROM $T.customer_orders ORDER BY customer_id")
    if [ "$a" = "$b" ]; then claim "gold-$1" PASS "customer_orders equals the query on the source: $(echo "$a" | grep -c .) rows"
    else claim "gold-$1" FAIL "source vs gold: $(diff <(echo "$a") <(echo "$b") | grep '^[<>]' | tr '\t\n' ', ' | cut -c1-300)"; fi
  }
  refresh() { # how the last update refreshed the view: the chosen technique, from the pipeline's event log
    q "SELECT CONCAT(details:planning_information:incrementalization_status::STRING, ' ', CONCAT_WS(',', TRANSFORM(FILTER(
        FROM_JSON(details:planning_information:technique_information::STRING, 'ARRAY<STRUCT<maintenance_type STRING, is_chosen BOOLEAN>>'),
        x -> x.is_chosen), x -> x.maintenance_type)))
      FROM event_log('$PIPELINE_ID') WHERE event_type = 'planning_information' AND origin.update_id = '$(cat "$W/update_id")'" 2>&1 | tr '\n' ' '
  }

  st=$(run_silver); [ "$st" = COMPLETED ] || claim silver-update-1 FAIL "pipeline update: $st"
  for t in $TABLES; do same "$t" 1; done
  gold 1
  [ "$PHASE" -ge 3 ] && observe gold-refresh-1 "update 1: $(refresh)"

  # round 2: two updates of one key, a delete and reinsert of one key, a reinsert of a key deleted in round 1
  N0=$(q "SELECT COUNT(*) FROM $LOG")
  crdb >/dev/null <<'SQL'
UPDATE shop.customers SET tier = 'platinum' WHERE id = 1;
UPDATE shop.customers SET tier = 'diamond' WHERE id = 1;
DELETE FROM shop.customers WHERE id = 3;
INSERT INTO shop.customers VALUES (3, 'customer_3b', 'silver');
INSERT INTO shop.customers VALUES (2, 'customer_2b', 'bronze');
UPDATE shop.orders SET amount = amount + 1 WHERE id = 2;
SQL
  t0=$SECONDS; until [ "$(q "SELECT COUNT(*) FROM $LOG" 2>/dev/null)" -ge $((N0 + 6)) ] 2>/dev/null || [ $((SECONDS - t0)) -ge "$WAIT" ]; do sleep 5; done
  st=$(run_silver); [ "$st" = COMPLETED ] || claim silver-update-2 FAIL "pipeline update: $st"
  for t in $TABLES; do same "$t" 2; done
  gold 2
  [ "$PHASE" -ge 3 ] && observe gold-refresh-2 "update 2, after round 2: $(refresh)"
  [ "$PHASE" -ge 3 ] && observe clustering "clustering columns: $(for t in $TABLES customer_orders; do printf '%s %s; ' "$t" "$(q "DESCRIBE TABLE EXTENDED $T.$t" 2>/dev/null | grep -o -E 'clusteringColumns=\[\[[^]]*\]\]' | head -1)"; done)"
  if [ "$PHASE" -ge 3 ]; then
    # round 3, retries: changes, then Debezium killed (SIGKILL, no offset flush) and started again, then one more change
    N0=$(q "SELECT COUNT(*) FROM $LOG")
    crdb >/dev/null <<'SQL'
INSERT INTO shop.customers VALUES (8, 'customer_8', 'gold');
UPDATE shop.customers SET tier = 'silver' WHERE id = 4;
UPDATE shop.customers SET tier = 'gold' WHERE id = 4;
INSERT INTO shop.orders VALUES (7, 8, 12.34, 'placed');
SQL
    t0=$SECONDS; until [ "$(q "SELECT COUNT(*) FROM $LOG" 2>/dev/null)" -ge $((N0 + 4)) ] 2>/dev/null || [ $((SECONDS - t0)) -ge "$WAIT" ]; do sleep 2; done
    vm "sudo podman kill $DBZ >/dev/null && sudo podman start $DBZ >/dev/null" || claim retry-restart FAIL "Debezium restart failed"
    sleep 40
    echo "UPDATE shop.orders SET status = 'shipped' WHERE id = 7;" | crdb >/dev/null
    t0=$SECONDS; until [ "$(q "SELECT COUNT(*) FROM $LOG WHERE operation = 'update' AND destination LIKE '%.orders' AND key:id::INT = 7" 2>/dev/null)" -ge 1 ] 2>/dev/null || [ $((SECONDS - t0)) -ge "$WAIT" ]; do sleep 5; done
    sleep 10
    R=$(q "SELECT COUNT(*) - $N0, COUNT(*) - COUNT(DISTINCT idempotency_key), (SELECT COUNT(*) FROM (SELECT 1 FROM $LOG GROUP BY destination, TO_JSON(key), TO_JSON(value:after), operation HAVING COUNT(*) > 1)) FROM $LOG" 2>&1 | tr '\t' ' ')
    observe retry-bronze "after the kill and restart, rows added since round 3 began (5 changes), rows sharing an idempotency key, change contents seen more than once: $R"
    [ "$(q "SELECT COUNT(*) FROM $LOG WHERE operation = 'update' AND destination LIKE '%.orders' AND key:id::INT = 7")" -ge 1 ] \
      && claim retry-stream-resumes PASS "a change after the restart reached bronze" || claim retry-stream-resumes FAIL "no event for the change after the restart"
    st=$(run_silver); [ "$st" = COMPLETED ] || claim silver-update-3 FAIL "pipeline update: $st"
    for t in $TABLES; do same "$t" 3; done
    gold 3
    # the source's own history: its changefeed from T, with each row's commit time (`updated`)
    vm "timeout 20 sudo podman exec $CRDB cockroach sql --insecure --format=tsv -e \"EXPERIMENTAL CHANGEFEED FOR shop.customers, shop.orders WITH updated, cursor = '$T_HLC'\"" > "$W/feed.tsv" 2>/dev/null
    for t in $TABLES; do history "$t" "${t}_history" claim; same_hist "$t" 3; done
    history customers customers_history_nodedup observe

    # round 4, schema change: a column added on the source, with a default, then a change that sets it
    echo "ALTER TABLE shop.customers ADD COLUMN email STRING NOT NULL DEFAULT 'none';" | crdb >/dev/null
    sleep 15
    echo "UPDATE shop.customers SET email = 'c6@example.com' WHERE id = 6;" | crdb >/dev/null
    t0=$SECONDS; until [ "$(q "SELECT COUNT(*) FROM $LOG WHERE value:after:email::STRING = 'c6@example.com'" 2>/dev/null)" -ge 1 ] 2>/dev/null || [ $((SECONDS - t0)) -ge "$WAIT" ]; do sleep 5; done
    R=$(q "SELECT COUNT(*), COUNT_IF(value:after:email::STRING = 'none') FROM $LOG WHERE destination LIKE '%.customers' AND value:after:email IS NOT NULL" 2>&1 | tr '\t' ' ')
    [ "$(q "SELECT COUNT(*) FROM $LOG WHERE value:after:email::STRING = 'c6@example.com'")" -ge 1 ] \
      && claim schema-new-column-bronze PASS "the added column reaches bronze with no Databricks DDL (customers events with email, with email = none from the backfill): $R" \
      || claim schema-new-column-bronze FAIL "no event with the new column: $R"
    observe schema-backfill-events "customers events by operation since the ALTER: $(q "SELECT operation, COUNT(*) FROM $LOG WHERE destination LIKE '%.customers' AND value:after:email IS NOT NULL GROUP BY 1" 2>&1 | tr '\t\n' '= ')"
    # silver as it is, without the column: the old columns still match
    st=$(run_silver); observe schema-silver-before-regenerate "update with the old flow: $st; silver customers columns: $(q "SELECT CONCAT_WS(',', COLLECT_LIST(column_name)) FROM \`$CATALOG\`.information_schema.columns WHERE table_schema = '$S' AND table_name = 'customers'" 2>&1)"
    # regenerate: the schema again through the connection, the flow from it, then a refresh of that table and a plain update
    fetch_schema; gen_silver
    dbx workspace import "$WSDIR/silver.sql" --file "$W/silver.sql" --format RAW --overwrite >/dev/null
    st=$(run_silver); observe schema-update-after-regenerate "plain update with the regenerated flow: $st"
    [ "$st" = COMPLETED ] && same customers 4a observe
    st=$(run_silver --json '{"full_refresh_selection": ["customers", "customers_history", "customers_history_nodedup"]}'); [ "$st" = COMPLETED ] || claim silver-full-refresh-4 FAIL "full refresh of customers: $st"
    # an update with full_refresh_selection runs only the selected tables: a plain update brings gold along
    st=$(run_silver); [ "$st" = COMPLETED ] || claim silver-update-4 FAIL "plain update after the full refresh: $st"
    for t in $TABLES; do same "$t" 4; same_hist "$t" 4; done
    gold 4

    # round 5: a dropped column and a retyped one (DECIMAL(10,2) -> DECIMAL(12,2)), then a value only the new type holds
    crdb >/dev/null <<'SQL'
SET sql_safe_updates = false;
SET enable_experimental_alter_column_type_general = true;
ALTER TABLE shop.orders DROP COLUMN status;
ALTER TABLE shop.orders ALTER COLUMN amount TYPE DECIMAL(12,2);
SQL
    sleep 15
    echo "UPDATE shop.orders SET amount = 1234567890.12 WHERE id = 1;" | crdb >/dev/null
    t0=$SECONDS; until [ "$(q "SELECT COUNT(*) FROM $LOG WHERE value:after:amount::STRING = '1234567890.12'" 2>/dev/null)" -ge 1 ] 2>/dev/null || [ $((SECONDS - t0)) -ge "$WAIT" ]; do sleep 5; done
    observe schema-change-bronze "all orders events, by operation and whether they have status (a backfill would add updates without it): $(q "SELECT CONCAT(operation, ' status=', value:after:status IS NOT NULL), COUNT(*) FROM $LOG WHERE destination LIKE '%.orders' GROUP BY 1" 2>&1 | tr '\t\n' '= '); the new value: $(q "SELECT COUNT(*) FROM $LOG WHERE value:after:amount::STRING = '1234567890.12'" 2>&1)"
    st=$(run_silver 2>/dev/null); observe schema-change-old-flow "update with the old flow (status still selected, amount still DECIMAL(10,2)): $st; $(q "SELECT REGEXP_EXTRACT(error.exceptions[0].message, '\\[(INVALID_[A-Z_]+|[A-Z_]+CAST[A-Z_]*)\\][^\\n]*', 0) FROM event_log('$PIPELINE_ID') WHERE event_type = 'flow_progress' AND origin.flow_name LIKE '%.orders_from_changes' AND error IS NOT NULL ORDER BY timestamp DESC LIMIT 1" 2>&1 | cut -c1-300)"
    fetch_schema; gen_silver
    dbx workspace import "$WSDIR/silver.sql" --file "$W/silver.sql" --format RAW --overwrite >/dev/null
    st=$(run_silver --json '{"full_refresh_selection": ["orders", "orders_history"]}' 2>"$W/err5b")
    [ "$st" = COMPLETED ] || claim silver-full-refresh-5 FAIL "regenerated flow, full refresh of orders: $st $(cut -c1-300 "$W/err5b" | tr '\n' ' ')"
    st=$(run_silver); [ "$st" = COMPLETED ] || claim silver-update-5 FAIL "plain update after the full refresh: $st"
    for t in $TABLES; do same "$t" 5; same_hist "$t" 5; done
    gold 5
  fi
  observe silver-sql "the generated pipeline source, first table: $(head -c 700 "$W/silver.sql" | tr '\n' ' ')"
fi

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
