#!/usr/bin/env bash
# debezium-zerobus.sh: a source database -> snapshot as of T into a Volume, and Debezium Server (Zerobus sink) from T
# -> one append-only bronze change log -> silver (SCD type 1 and 2, AUTO CDC) -> gold (a materialized view).
#
# SOURCE=crdb (CockroachDB, the default) or SOURCE=yb (YugabyteDB, through its PostgreSQL logical replication).
# Runs from the laptop and drives a cloud VM over SSH (lfc-source-cloud-vm). It creates, on a fresh epoch:
#   - a schema in CATALOG with one bronze change-log table, cdc_log, for every source table: Debezium's envelope with the
#     key, the event and the position as VARIANT, liquid-clustered by destination (the source table);
#   - a service principal with an OAuth secret, granted SELECT and MODIFY on cdc_log (Zerobus writes as it);
#   - on the VM, a Podman network with the source and Debezium Server, which streams the source's changes from T to Zerobus;
#   - phase 2: a Volume with the snapshot as of T, a UC connection to the source (the schema comes through it with
#     remote_query), and a serverless pipeline with the silver tables; phase 3 adds gold and rounds 3 to 5.
# T is CockroachDB's cluster time (the changefeed's cursor), or YugabyteDB's replication slot snapshot (the slot is
# created first; the dump reads with yb_read_time set to it). Everything it created is removed on exit (KEEP=1 keeps
# it). Nothing secret is printed: the OAuth secret lives only in 0600 files (a temp dir here, a temp dir on the VM).
#
#   PHASE=1 stops after bronze, PHASE=2 after silver; PHASE=3 (the default) adds gold and rounds 3 to 5.
#   DROP_FIELDS drops top-level event fields with Kafka's ReplaceField transform (default before,transaction,ts_ms,ts_us,
#   source for crdb, before,transaction,ts_ms,ts_us for yb); keep ts_ns, which silver sequences by.
#   ENRICHED_PROPERTIES=source (crdb) asks CockroachDB for its source block (the 3.7.0.Final connector drops its commit
#   time anyway).
# Needs: PROFILE (Databricks CLI profile), CATALOG (with its own storage), VM_IP; optional VM_USER (azureuser),
#   SSH_KEY (~/.ssh/lfc_test_rsa), SRC_IMAGE, DBZ_IMAGE, SRC_PORT (published for the UC connection, default 30026),
#   WAIT (seconds to wait for rows, default 180), OUT=<file.md>.
# Exit 0 when every claim passed, 1 when one failed, 2 when a prerequisite is missing.
set -uo pipefail
export PATH=/opt/homebrew/bin:$PATH
: "${PROFILE:?}" "${CATALOG:?}"
[ -n "${LIMA:-}" ] || : "${VM_IP:?set VM_IP (a cloud VM) or LIMA (a local Lima instance with Podman)}"
SOURCE=${SOURCE:-crdb}
case $SOURCE in
  crdb) SRC_IMAGE=${SRC_IMAGE:-docker.io/cockroachdb/cockroach:v25.4.13}; SRC_NAME=CockroachDB; SRC_SCHEMA=public
        DROP_FIELDS=${DROP_FIELDS-before,transaction,ts_ms,ts_us,source};;
  yb)   SRC_IMAGE=${SRC_IMAGE:-docker.io/yugabytedb/yugabyte:2026.1.2.0-b137}; SRC_NAME=YugabyteDB; SRC_SCHEMA=shop
        DROP_FIELDS=${DROP_FIELDS-before,transaction,ts_ms,ts_us};;
  *) echo "SOURCE: crdb or yb"; exit 2;;
esac
# SINK=zerobus: Debezium Server's Zerobus sink (gRPC). SINK=kafka: Kafka Connect, standalone (offsets in a file, no
# broker), with the producer pointed at Zerobus's Kafka-compatible endpoint; for connectors that only run on Kafka Connect
SINK=${SINK:-$([ "$SOURCE" = yb ] && echo kafka || echo zerobus)}
YB_CONNECTOR_URL=${YB_CONNECTOR_URL:-https://github.com/yugabyte/debezium/releases/download/dz.2.5.2.yb.2026.1.2.0.1/yugabytedb-source-connector-dz.2.5.2.yb.2026.1.2.0.1-jar-with-dependencies.jar}
CONNECT_IMAGE=${CONNECT_IMAGE:-docker.io/apache/kafka:3.7.2}
DEST_PREFIX=$SOURCE.$SRC_SCHEMA   # the topic prefix and the schema: the change log's destination is <DEST_PREFIX>.<table>
DBZ_IMAGE=${DBZ_IMAGE:-quay.io/debezium/server:3.7.0.Final}
WAIT=${WAIT:-180}; PHASE=${PHASE:-3}; CHECK=${CHECK:-$PWD/scripts/scd2-history-check.py}; SRC_PORT=${SRC_PORT:-${CRDB_PORT:-30026}}
dbx() { databricks "$@" --profile "$PROFILE"; }
if [ -n "${LIMA:-}" ]; then   # the laptop: Podman in a Lima VM; nothing on the laptop is reachable from Databricks
  vm() { limactl shell "$LIMA" -- bash -c "$*"; }; HOSTDESC="Lima $LIMA"
else
  SSH=(ssh -i "${SSH_KEY:-$HOME/.ssh/lfc_test_rsa}" -o BatchMode=yes "${VM_USER:-azureuser}@$VM_IP")
  vm() { "${SSH[@]}" "$@"; }; HOSTDESC="VM $VM_IP"
fi
# the schema: through a UC connection (remote_query, the source must be reachable from serverless), or as statschema's
# canonical schema.yaml in the Volume, which the pipeline reads (the laptop)
SCHEMA_VIA=${SCHEMA_VIA:-$([ -n "${LIMA:-}" ] && echo volume || echo connection)}
STATSCHEMA=${STATSCHEMA:-$PWD/../lfc-source-statschema/scripts}
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
vm 'command -v podman >/dev/null' || { echo "no Podman on $HOSTDESC"; exit 2; }
E=$(date +%s); S=${PREFIX}_${SOURCE}_dbz_$E; NET=$SOURCE-dbz-$E; SRCC=$PREFIX-$SOURCE-$E; DBZ=$PREFIX-debezium-$E; RD=/tmp/dbz-$SOURCE-$E
T="\`$CATALOG\`.$S"
echo "run $E: schema $CATALOG.$S, VM containers $SRCC and $DBZ"

sql() {
  yq -n -o json '.warehouse_id = strenv(WAREHOUSE) | .wait_timeout = "50s" | .statement = strenv(Q)' > "$W/st.json"
  dbx api post /api/2.0/sql/statements --json @"$W/st.json" > "$W/st.out"
  [ "$(yq '.status.state' "$W/st.out")" = SUCCEEDED ] || { yq '.status.state + ": " + (.status.error.message // "")' "$W/st.out" | cut -c1-300 >&2; return 1; }
  yq -r '(.result.data_array // [])[] | @tsv' "$W/st.out"
}
q() { export Q=$1; sql; }
# src: SQL from stdin on the source, tab-separated with a header row
case $SOURCE in
  crdb) src() { vm "sudo podman exec -i $SRCC cockroach sql --insecure --format=tsv"; };;
  yb)   src() { vm "sudo podman exec -i $SRCC bin/ysqlsh -h yugabytedb -U yugabyte -d shop -q -A -z -P footer=off -v ON_ERROR_STOP=1 | tr '\\000' '\\t'"; };;
esac

cleanup() {
  [ "${KEEP:-0}" = 1 ] && { echo "KEEP=1: left $CATALOG.$S, SP ${SP_NAME:-}, VM containers and $RD"; rm -rf "$W"; return; }
  vm "sudo podman rm -f --ignore $DBZ $SRCC >/dev/null 2>&1; sudo podman network rm $NET >/dev/null 2>&1; sudo rm -rf $RD" || true
  [ -n "${SP_ID:-}" ] && dbx service-principals delete "$SP_ID" >/dev/null 2>&1
  [ -n "${PIPELINE_ID:-}" ] && dbx pipelines delete "$PIPELINE_ID" >/dev/null 2>&1
  [ -n "${CONN:-}" ] && dbx connections delete "$CONN" >/dev/null 2>&1
  [ -n "${WSDIR:-}" ] && dbx workspace delete "$WSDIR" --recursive >/dev/null 2>&1
  dbx schemas delete "$CATALOG.$S" --force >/dev/null 2>&1
  left=$(vm "sudo podman ps -a --format '{{.Names}}' | grep -c -E '^($DBZ|$SRCC)\$'" 2>/dev/null)
  echo "cleanup: containers left ${left:-?}; SP ${SP_ID:+deleted}; pipeline ${PIPELINE_ID:+deleted}; connection ${CONN:+deleted}; schema dropped"
  rm -rf "$W"
}
trap cleanup EXIT

# --- source: a small schema ----------------------------------------------------------------------------------------
TABLES="customers orders"
SETUP_SQL="CREATE TABLE shop.customers (id INT PRIMARY KEY, name TEXT NOT NULL, tier TEXT NOT NULL);
CREATE TABLE shop.orders (id INT PRIMARY KEY, customer_id INT NOT NULL, amount DECIMAL(10,2) NOT NULL, status TEXT NOT NULL);
INSERT INTO shop.customers SELECT g, 'customer_' || g::TEXT, 'bronze' FROM generate_series(1, 5) g;
INSERT INTO shop.orders SELECT g, 1 + g % 5, g * 10.5, 'placed' FROM generate_series(1, 5) g;"
if [ "$SOURCE" = crdb ]; then
  vm "sudo podman network create $NET >/dev/null && sudo podman run -d --name $SRCC --network $NET --network-alias cockroachdb \
    $([ "$SCHEMA_VIA" = connection ] && echo "-p $SRC_PORT:26257") $SRC_IMAGE start-single-node --insecure --advertise-addr=cockroachdb >/dev/null" || { echo "CockroachDB start failed"; exit 2; }
  for _ in $(seq 1 30); do echo 'SELECT 1;' | src >/dev/null 2>&1 && break; sleep 2; done
  printf 'SET CLUSTER SETTING kv.rangefeed.enabled = true;\nCREATE DATABASE shop;\n%s\n' "$SETUP_SQL" | src >/dev/null || { echo "CockroachDB setup failed"; exit 2; }
  SRC_VERSION=$(echo 'SELECT version();' | src | tail -1 | cut -c1-80)
  # T: the cluster time. Debezium's changefeed starts there, with no snapshot of its own.
  T_HLC=$(echo 'SELECT cluster_logical_timestamp();' | src | tail -1)
  T_NS=${T_HLC%%.*}   # the wall time in nanoseconds: silver's sequence for the snapshot rows
  snap_select() { echo "SELECT $2 FROM shop.$1 AS OF SYSTEM TIME '$T_HLC';"; }   # snap_select <table> <columns>: the rows at T
else
  vm "sudo podman network create $NET >/dev/null && sudo podman run -d --name $SRCC --network $NET --network-alias yugabytedb \
    $([ "$SCHEMA_VIA" = connection ] && echo "-p $SRC_PORT:5433") $SRC_IMAGE bin/yugabyted start --background=false --advertise_address=yugabytedb >/dev/null" || { echo "YugabyteDB start failed"; exit 2; }
  for _ in $(seq 1 60); do vm "sudo podman exec $SRCC bin/ysqlsh -h yugabytedb -U yugabyte -c 'SELECT 1'" >/dev/null 2>&1 && break; sleep 3; done
  vm "sudo podman exec $SRCC bin/ysqlsh -h yugabytedb -U yugabyte -c 'CREATE DATABASE shop'" >/dev/null || { echo "YugabyteDB setup failed"; exit 2; }
  # the truth for the history check: an audit trigger writes every change, in commit order, to a table not published
  { echo "CREATE SCHEMA shop;"; echo "$SETUP_SQL"; cat <<'SQL'; } | src >/dev/null || { echo "YugabyteDB setup failed"; exit 2; }
CREATE TABLE shop.audit (seq BIGSERIAL PRIMARY KEY, tbl TEXT NOT NULL, op TEXT NOT NULL, row_data JSONB);
CREATE FUNCTION shop.audit_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
  INSERT INTO shop.audit (tbl, op, row_data) VALUES (TG_TABLE_NAME, TG_OP, CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END);
  RETURN NULL; END $$;
CREATE TRIGGER customers_audit AFTER INSERT OR UPDATE OR DELETE ON shop.customers FOR EACH ROW EXECUTE FUNCTION shop.audit_fn();
CREATE TRIGGER orders_audit AFTER INSERT OR UPDATE OR DELETE ON shop.orders FOR EACH ROW EXECUTE FUNCTION shop.audit_fn();
ALTER TABLE shop.customers REPLICA IDENTITY DEFAULT;
ALTER TABLE shop.orders REPLICA IDENTITY DEFAULT;
CREATE PUBLICATION dbz_pub FOR TABLE shop.customers, shop.orders;
SELECT 1 FROM pg_create_logical_replication_slot('dbz_slot', 'pgoutput');
SQL
  SRC_VERSION=$(echo 'SELECT version();' | src | tail -1 | cut -c1-80)
  # T: the slot's consistent snapshot, a hybrid time (microseconds << 12). Debezium streams from the slot, with no
  # snapshot of its own; the dump reads as of T with yb_read_time.
  T_HT=$(echo "SELECT yb_restart_commit_ht FROM pg_replication_slots WHERE slot_name = 'dbz_slot';" | src | tail -1)
  T_US=$((T_HT >> 12)); T_NS=$((T_US * 1000)); T_HLC="slot dbz_slot, hybrid time $T_HT ($T_US us)"
  snap_select() { printf 'SET yb_read_time TO %s;\nSELECT %s FROM shop.%s;\nRESET yb_read_time;\n' "$T_US" "$2" "$1"; }
fi
if [ "$PHASE" -ge 2 ]; then
  # the snapshot: every table as of T, onto the laptop. CockroachDB: EXPORT INTO PARQUET; DECIMAL goes out as STRING
  # because v25.4.13 writes a DECIMAL column as BYTE_ARRAY annotated DECIMAL but filled with the number's text, so
  # readers get "21.00" as the unscaled integer 0x32312E3030 (2155734753.76). YugabyteDB: COPY ... CSV under
  # yb_read_time. Silver casts every column to its type.
  mkdir -p "$W/snap"
  for t in $TABLES; do
    if [ "$SOURCE" = crdb ]; then
      cols=$(echo "SELECT string_agg(CASE WHEN data_type = 'numeric' THEN column_name || '::STRING AS ' || column_name ELSE column_name END,
        ', ' ORDER BY ordinal_position) FROM shop.information_schema.columns
        WHERE table_schema = 'public' AND table_name = '$t' AND is_hidden = 'NO';" | src | tail -1)
      echo "EXPORT INTO PARQUET 'nodelocal://self/snap/$t' FROM SELECT $cols FROM shop.$t AS OF SYSTEM TIME '$T_HLC';" | src >/dev/null \
        || { echo "EXPORT of $t failed"; exit 2; }
    else
      mkdir -p "$W/snap/$t"
      printf 'SET yb_read_time TO %s;\nCOPY (SELECT * FROM shop.%s) TO STDOUT WITH (FORMAT csv, HEADER);\n' "$T_US" "$t" \
        | vm "sudo podman exec -i $SRCC bin/ysqlsh -h yugabytedb -U yugabyte -d shop -q -v ON_ERROR_STOP=1" > "$W/snap/$t/$t.csv" 2>/dev/null \
        || { echo "COPY of $t failed"; exit 2; }
    fi
  done
  [ "$SOURCE" = crdb ] && { vm "sudo podman exec $SRCC tar -C /cockroach/cockroach-data/extern/snap -cf - ." | tar -xf - -C "$W/snap" \
    || { echo "snapshot copy failed"; exit 2; }; }
  SNAP_FMT=$([ "$SOURCE" = crdb ] && echo parquet || echo csv)
fi
# dump_schema: the source's DDL -> statschema's canonical schema.yaml ($W/schema.yaml), with the lfc-source-statschema
# skill's ddl-to-schema.py; then $W/schema.tsv (table, ordinal, column, Databricks type, 1 for a key) for the checks.
# sqlglot's postgres dialect doesn't take CockroachDB's "PRIMARY KEY (id ASC)" or its typed literals ('none':::STRING),
# so the key order and the casts go.
dump_schema() {
  [ "$SOURCE" = crdb ] || { echo "SCHEMA_VIA=volume: only SOURCE=crdb dumps DDL so far"; return 1; }
  vm "sudo podman exec $SRCC cockroach sql --insecure -d shop --format=raw -e 'SHOW CREATE ALL TABLES'" | grep -v '^#' \
    | sed -E 's/ (ASC|DESC)([,)])/\2/g; s/:::[A-Za-z0-9_]+(\[\])?//g' | (cd "$STATSCHEMA/.." && uv run -q scripts/ddl-to-schema.py --dialect postgres) > "$W/schema.yaml" 2>"$W/schema.err" || return 1
  yq -r '.tables[] | .name as $t | .columns | to_entries[] | [$t, .key + 1, .value.name,
    (.value.type as $y | {"integer": "INT", "long": "BIGINT", "float": "FLOAT", "double": "DOUBLE", "boolean": "BOOLEAN", "date": "DATE",
      "timestamp": "TIMESTAMP_NTZ", "timestamptz": "TIMESTAMP", "binary": "BINARY"}[$y] //
      (select($y == "decimal") | "DECIMAL(" + (.value.precision // 38 | tostring) + "," + (.value.scale // 0 | tostring) + ")") // "STRING"),
    ((.value.primary_key // false) | tostring | sub("true"; "1") | sub("false"; "0"))] | @tsv' "$W/schema.yaml" > "$W/schema.tsv"
}
[ "$PHASE" -ge 2 ] && [ "$SCHEMA_VIA" = volume ] && { dump_schema || { echo "schema dump failed: $(head -c 300 "$W/schema.err")"; exit 2; }; cp "$W/schema.yaml" "$W/snap-schema-at-T.yaml"; }

# --- destination: bronze tables, a service principal with a secret, grants -------------------------------------------
dbx schemas create "$S" "$CATALOG" >/dev/null || exit 2
LOG=$T.cdc_log
# NORM: the change log in one shape for both sinks: destination, operation (create/update/delete/read), idempotency_key,
# key, value, source_position, headers, _seq (orders each key's changes) and _event_ns (for the deduplication watermark).
# Kafka Connect's records carry only the event (the Kafka API ingests the value alone): the operation comes from op, the
# key from after or before, and the sequence from the slot's LSN, which follows commit order; the snapshot is sequence 0.
if [ "$SINK" = kafka ]; then
  NORM="SELECT destination, CASE value:op::STRING WHEN 'c' THEN 'create' WHEN 'u' THEN 'update' WHEN 'd' THEN 'delete' WHEN 'r' THEN 'read' END AS operation,
    value:source:lsn::STRING AS idempotency_key, CASE value:op::STRING WHEN 'd' THEN value:before ELSE value:after END AS key, value, value:source AS source_position,
    CAST(NULL AS VARIANT) AS headers, value:source:lsn::BIGINT AS _seq, value:ts_ms::BIGINT * 1000000 AS _event_ns"
  SNAP_SEQ=0
  q "CREATE TABLE $LOG (destination STRING NOT NULL, value VARIANT) CLUSTER BY (destination)
    COMMENT 'Append-only change log: one Debezium event per source change, all source tables (Kafka Connect through the Zerobus Kafka API)'" >/dev/null || exit 2
else
  NORM="SELECT *, value:ts_ns::BIGINT AS _seq, value:ts_ns::BIGINT AS _event_ns"; SNAP_SEQ=$T_NS
q "CREATE TABLE $LOG (target_table STRING NOT NULL, destination STRING NOT NULL, partition INT, operation STRING NOT NULL,
  idempotency_key STRING, key VARIANT, value VARIANT, source_position VARIANT, headers VARIANT) CLUSTER BY (destination)
  COMMENT 'Append-only change log: one Debezium envelope per source change, all source tables'" >/dev/null || exit 2
fi
LOGQ="($NORM FROM $LOG)"
if [ -n "${SP_CLIENT_ID:-}" ]; then   # a service principal someone else created: its application ID and a file with its secret
  [ -r "${SP_SECRET_FILE:-}" ] || { echo "SP_CLIENT_ID needs SP_SECRET_FILE, a file with the OAuth secret"; exit 2; }
  SP_APP=$SP_CLIENT_ID; SP_NAME="existing $SP_CLIENT_ID"; SECRET=$(cat "$SP_SECRET_FILE") yq -n -o json '.secret = strenv(SECRET)' > "$W/secret.json"
else
SP_NAME=$PREFIX-zerobus-dbz-$E
eval "$(dbx service-principals create --display-name "$SP_NAME" -o json | yq -o shell '{"SP_ID": .id, "SP_APP": .applicationId}')"
[ -n "${SP_ID:-}" ] || { echo "service principal create failed"; exit 2; }
dbx service-principal-secrets-proxy create "$SP_ID" -o json > "$W/secret.json" || { echo "secret create failed"; exit 2; }
fi
for g in "GRANT USE CATALOG ON CATALOG \`$CATALOG\` TO \`$SP_APP\`" "GRANT USE SCHEMA ON SCHEMA $T TO \`$SP_APP\`" \
         "GRANT SELECT, MODIFY ON TABLE $LOG TO \`$SP_APP\`"; do
  q "$g" >/dev/null || exit 2
done

# --- Debezium Server: the source's connector, envelopes into one change-log table ---------------------------------------
export SP_APP ZB HOST CATALOG S
if [ "$SINK" = zerobus ]; then
yq -r '"debezium.sink.zerobus.client.secret=" + .secret' "$W/secret.json" > "$W/secret.line"
cat > "$W/application.properties" <<EOF
$( if [ "$SOURCE" = crdb ]; then cat <<CRDB
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
debezium.source.cockroachdb.changefeed.cursor=$T_HLC
debezium.source.cockroachdb.changefeed.sink.type=sinkless
debezium.source.cockroachdb.changefeed.resolved.interval=5s
debezium.source.cockroachdb.changefeed.include.diff=false
debezium.source.cockroachdb.changefeed.include.updated=true
CRDB
[ -n "${ENRICHED_PROPERTIES:-}" ] && echo "debezium.source.cockroachdb.changefeed.enriched.properties=$ENRICHED_PROPERTIES"
else cat <<YB
debezium.source.connector.class=${YB_CONNECTOR_CLASS:-io.debezium.connector.postgresql.PostgresConnector}
debezium.source.name=yb-zerobus
debezium.source.topic.prefix=yb
debezium.source.database.hostname=yugabytedb
debezium.source.database.port=5433
debezium.source.database.user=yugabyte
debezium.source.database.password=yugabyte
debezium.source.database.dbname=shop
debezium.source.plugin.name=pgoutput
debezium.source.slot.name=dbz_slot
debezium.source.publication.name=dbz_pub
debezium.source.publication.autocreate.mode=disabled
debezium.source.table.include.list=shop.customers,shop.orders
debezium.source.decimal.handling.mode=string
YB
fi )
debezium.source.snapshot.mode=no_data
debezium.source.extended.headers.enabled=false
debezium.source.tombstones.on.delete=false
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
else
# --- Kafka Connect, standalone, into Zerobus's Kafka-compatible endpoint (no broker) ------------------------------------
# The producer needs SASL OAUTHBEARER with a token minted for the table: the login callback handler in Debezium's Zerobus
# sink jar does that (JAAS options clientId, clientSecret, workspaceUrl, workspaceId, tables). The Kafka API ingests the
# record value only, so the transforms put everything into it: the event as "value" (StringifyField makes it JSON text,
# which is how Zerobus takes a VARIANT), the source topic as "destination", and every topic routed to the one table.
# Jars are cached on the host in ~/.cache/dbz-zerobus.
HERE=$(cd "$(dirname "$CHECK")" && pwd)
vm "umask 077; mkdir -p $RD/data $RD/cfg; C=\$HOME/.cache/dbz-zerobus; mkdir -p \$C/plugins/yb \$C/plugins/stringify \$C/cp \$C/src
  [ -s \$C/plugins/yb/yb.jar ] || curl -s -L -o \$C/plugins/yb/yb.jar '$YB_CONNECTOR_URL'
  [ -s \$C/cp/zerobus-sink.jar ] || sudo podman run --rm --entrypoint sh $DBZ_IMAGE -c 'cat /debezium/lib/debezium-server-databricks-zerobus-*.jar' > \$C/cp/zerobus-sink.jar" \
  || { echo "Kafka Connect jars failed"; exit 2; }
vm "cat > \$HOME/.cache/dbz-zerobus/src/StringifyField.java" < "$HERE/kafka-connect/StringifyField.java"
vm "C=\$HOME/.cache/dbz-zerobus; [ -s \$C/plugins/stringify/lfc-stringify-field.jar ] && [ \$C/plugins/stringify/lfc-stringify-field.jar -nt \$C/src/StringifyField.java ] && exit 0
  sudo podman run --rm -v \$C:/c:Z $CONNECT_IMAGE sh -c 'mkdir -p /c/k && cp /opt/kafka/libs/connect-api-*.jar /opt/kafka/libs/connect-json-*.jar /opt/kafka/libs/kafka-clients-*.jar /c/k/' \
  && sudo podman run --rm -v \$C:/c:Z docker.io/library/eclipse-temurin:17-jdk sh -c 'cd /c && rm -rf build && javac -d build -cp \"/c/k/*\" src/StringifyField.java && jar cf plugins/stringify/lfc-stringify-field.jar -C build .'" >/dev/null \
  || { echo "StringifyField build failed"; exit 2; }
TOPIC=$CATALOG.$S.cdc_log; BOOT=${ZB#https://}:9092
export JAAS_SECRET=$(yq -r '.secret' "$W/secret.json"); rm -f "$W/secret.json"
{ for pre in "" producer. admin.; do cat <<EOF
${pre}bootstrap.servers=$BOOT
${pre}security.protocol=SASL_SSL
${pre}sasl.mechanism=OAUTHBEARER
${pre}sasl.login.callback.handler.class=io.debezium.server.databricks.zerobus.ZerobusOAuthBearerLoginCallbackHandler
${pre}sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="$SP_APP" clientSecret="$JAAS_SECRET" workspaceUrl="$HOST" workspaceId="$WS_ID" tables="$TOPIC";
EOF
done; cat <<EOF
producer.acks=all
producer.compression.type=none
producer.enable.idempotence=false
producer.linger.ms=20
key.converter=org.apache.kafka.connect.json.JsonConverter
value.converter=org.apache.kafka.connect.json.JsonConverter
key.converter.schemas.enable=false
value.converter.schemas.enable=false
offset.storage.file.filename=/data/offsets.dat
offset.flush.interval.ms=1000
plugin.path=/plugins
topic.creation.enable=false
EOF
} > "$W/worker.properties"; unset JAAS_SECRET
cat > "$W/connector.properties" <<EOF
name=yb-zerobus
connector.class=io.debezium.connector.postgresql.YugabyteDBConnector
tasks.max=1
database.hostname=yugabytedb
database.port=5433
database.user=yugabyte
database.password=yugabyte
database.dbname=shop
topic.prefix=yb
plugin.name=pgoutput
slot.name=dbz_slot
publication.name=dbz_pub
publication.autocreate.mode=disabled
snapshot.mode=never
table.include.list=shop.customers,shop.orders
decimal.handling.mode=string
tombstones.on.delete=false
transforms=hoist,dest,json,route
transforms.hoist.type=org.apache.kafka.connect.transforms.HoistField\$Value
transforms.hoist.field=value
transforms.dest.type=org.apache.kafka.connect.transforms.InsertField\$Value
transforms.dest.topic.field=destination
transforms.json.type=lfc.connect.StringifyField
transforms.json.fields=value
transforms.route.type=org.apache.kafka.connect.transforms.RegexRouter
transforms.route.regex=.*
transforms.route.replacement=$TOPIC
EOF
for f in worker connector; do vm "umask 077; cat > $RD/cfg/$f.properties" < "$W/$f.properties"; done; rm -f "$W/worker.properties" "$W/connector.properties"
vm "C=\$HOME/.cache/dbz-zerobus; sudo podman run -d --name $DBZ --network $NET -v $RD/cfg:/cfg:ro,U -v $RD/data:/data:U -v \$C/plugins:/plugins:ro,Z \
  -v \$C/cp:/extra:ro,Z -e CLASSPATH=/extra/zerobus-sink.jar --entrypoint /opt/kafka/bin/connect-standalone.sh $CONNECT_IMAGE \
  /cfg/worker.properties /cfg/connector.properties >/dev/null" || { echo "Kafka Connect start failed"; exit 2; }
fi

# --- checks -----------------------------------------------------------------------------------------------------------
# counts <table>: change-log rows for that source table per operation, as "create=.. read=.. update=.. delete=.."
counts() { q "SELECT operation, COUNT(*) FROM $LOGQ WHERE destination LIKE '%.$1' GROUP BY operation ORDER BY operation" 2>/dev/null | awk -F'\t' '{printf "%s=%s ", $1, $2}'; }
await() { # await <table> <operation> <n>: seconds until the log has n rows for that table and operation, or empty on timeout
  local t0=$SECONDS; while [ $((SECONDS - t0)) -lt "$WAIT" ]; do
    [ "$(q "SELECT COUNT(*) FROM $LOGQ WHERE destination LIKE '%.$1' AND operation = '$2'" 2>/dev/null)" -ge "$3" ] 2>/dev/null && { echo $((SECONDS - t0)); return; }
    sleep 5; done; }
sleep 30   # let the change feed start
R=$(q "SELECT COUNT(*) FROM $LOGQ WHERE operation = 'read'" 2>/dev/null)
[ "$R" = 0 ] && claim no-snapshot-events PASS "no read events: the snapshot stays out of the log (feed starts at T=$T_HLC)" \
  || claim no-snapshot-events FAIL "read events in the log: ${R:-query failed}"

src >/dev/null <<'SQL'
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
R=$(q "SELECT key:id::INT, value:after IS NULL OR value:after::STRING = 'null', value:ts_ns::STRING FROM $LOGQ WHERE destination LIKE '%.customers' AND operation = 'delete'" 2>&1 | tr '\t\n' ' ')
observe delete-event "customers delete (key.id, after is null, ts_ns): $R"
R=$(q "SELECT value:after:tier::STRING, value:before IS NULL FROM $LOGQ WHERE destination LIKE '%.customers' AND operation = 'update'" 2>&1 | tr '\t\n' ' ')
observe update-event "customers update (after.tier, before is null with include.diff=false): $R"
observe commit-time "events, distinct source.ts_hlc, distinct source.ts_ns, distinct ts_ns, distinct source.lsn, distinct source.ts_ms: $(q "SELECT COUNT(*), COUNT(DISTINCT value:source:ts_hlc::STRING), COUNT(DISTINCT value:source:ts_ns::STRING), COUNT(DISTINCT value:ts_ns::STRING), COUNT(DISTINCT value:source:lsn::STRING), COUNT(DISTINCT value:source:ts_ms::STRING) FROM $LOGQ" 2>&1 | tr '\t' ' ')"
observe variant-paths "value top-level keys: $(q "SELECT CONCAT_WS(',', SORT_ARRAY(MAP_KEYS(FROM_JSON(TO_JSON(value), 'MAP<STRING,STRING>')))) FROM $LOGQ LIMIT 1" 2>&1 | cut -c1-200)"
observe event-bytes "per event, average bytes (op: total value after source key position headers): $(q "SELECT operation, ROUND(AVG(LENGTH(TO_JSON(value)) + LENGTH(TO_JSON(key)) + LENGTH(COALESCE(TO_JSON(source_position),'')) + LENGTH(COALESCE(TO_JSON(headers),'')) + LENGTH(idempotency_key))), ROUND(AVG(LENGTH(TO_JSON(value)))), ROUND(AVG(LENGTH(TO_JSON(value:after)))), ROUND(AVG(LENGTH(TO_JSON(value:source)))), ROUND(AVG(LENGTH(TO_JSON(key)))), ROUND(AVG(LENGTH(COALESCE(TO_JSON(source_position),'')))), ROUND(AVG(LENGTH(COALESCE(TO_JSON(headers),'')))) FROM $LOGQ GROUP BY operation ORDER BY 1" 2>&1 | tr '\t\n' ' ;')"
observe event-sample "one update event value: $(q "SELECT TO_JSON(value) FROM $LOGQ WHERE operation = 'update' LIMIT 1" 2>&1 | cut -c1-400)"
observe change-log "rows by operation, customers: $(counts customers); orders: $(counts orders); clustering: $(q "DESCRIBE DETAIL $LOG" 2>/dev/null | head -1 | grep -o 'destination' | head -1)"

# --- phase 2: snapshot in a Volume, schema through a UC connection, silver ---------------------------------------------
if [ "$PHASE" -ge 2 ]; then
  VOL=/Volumes/$CATALOG/$S/snapshot
  q "CREATE VOLUME $T.snapshot COMMENT 'Snapshot as of T, one folder per source table'" >/dev/null || exit 2
  dbx fs cp -r "$W/snap" "dbfs:$VOL" --overwrite >/dev/null || { echo "snapshot upload failed"; exit 2; }
  F=$(for t in $TABLES; do printf '%s=%s ' "$t" "$(dbx fs ls "dbfs:$VOL/$t" -o json | SNAP_FMT=$SNAP_FMT yq '[.[] | select(.name | test(strenv(SNAP_FMT) + "$"))] | length')"; done)
  echo "$F" | grep -q '=0' && claim snapshot-in-volume FAIL "$SNAP_FMT files per table: $F" \
    || claim snapshot-in-volume PASS "the tables as of T ($([ "$SOURCE" = crdb ] && echo 'EXPORT INTO PARQUET ... AS OF SYSTEM TIME' || echo 'COPY ... CSV under yb_read_time')), into $VOL: $SNAP_FMT files per table: $F"

  if [ "$SCHEMA_VIA" = volume ]; then
  # the schema: statschema's schema.yaml in the Volume, as at T and as now; the pipeline reads both when it starts
  dbx fs mkdir "dbfs:$VOL/_schema" && dbx fs cp "$W/snap-schema-at-T.yaml" "dbfs:$VOL/_schema/schema-at-T.yaml" --overwrite >/dev/null \
    && dbx fs cp "$W/schema.yaml" "dbfs:$VOL/_schema/schema.yaml" --overwrite >/dev/null || { echo "schema upload failed"; exit 2; }
  cp "$W/schema.tsv" "$W/schema0.tsv"
  claim schema-in-volume PASS "statschema schema.yaml (ddl-to-schema.py from the source's DDL) in $VOL/_schema: $(awk -F'\t' '{c[$1]=c[$1] (c[$1]?", ":"") $3 " " $4 ($5==1?" key":"")} END {for (t in c) printf "%s (%s); ", t, c[t]}' "$W/schema.tsv")"
  fetch_schema() { dump_schema && dbx fs cp "$W/schema.yaml" "dbfs:$VOL/_schema/schema.yaml" --overwrite >/dev/null; }
  gen_silver() { :; }   # the pipeline builds itself from schema.yaml
  else
  # the schema: columns, types and primary keys from the source's information_schema, through a UC connection
  CONN=$PREFIX-$SOURCE-dbz-$E; export CONN VM_IP SRC_PORT
  [ "$SOURCE" = crdb ] && { export DB_USER=root DB_PASS=unused-insecure-node; } || { export DB_USER=yugabyte DB_PASS=yugabyte; }
  yq -n -o json '.name = strenv(CONN) | .connection_type = "POSTGRESQL" |
    .options = {"host": strenv(VM_IP), "port": strenv(SRC_PORT), "user": strenv(DB_USER), "password": strenv(DB_PASS)}' > "$W/conn.json"
  dbx connections create --json @"$W/conn.json" >/dev/null || { echo "connection create failed"; exit 2; }
  # table, ordinal, column, Databricks type, 1 when in the primary key
  fetch_schema() { q "SELECT table_name, ordinal_position, column_name,
       CASE data_type WHEN 'bigint' THEN 'BIGINT' WHEN 'integer' THEN 'INT' WHEN 'smallint' THEN 'SMALLINT'
         WHEN 'numeric' THEN CONCAT('DECIMAL(', numeric_precision, ',', numeric_scale, ')') WHEN 'boolean' THEN 'BOOLEAN'
         WHEN 'double precision' THEN 'DOUBLE' WHEN 'real' THEN 'FLOAT' WHEN 'date' THEN 'DATE'
         WHEN 'timestamp without time zone' THEN 'TIMESTAMP_NTZ' WHEN 'timestamp with time zone' THEN 'TIMESTAMP'
         ELSE 'STRING' END, in_pk,
       COALESCE(CASE WHEN LEFT(column_default, 1) = CHR(39) OR column_default RLIKE '^-?[0-9.]+(:::?[A-Za-z ]+)?\$'
                     THEN REGEXP_REPLACE(column_default, ':::?[A-Za-z ]+\$', '') END, '')
     FROM remote_query('$CONN', database => 'shop', query => \"
       SELECT c.table_name, c.ordinal_position, c.column_name, c.data_type, c.numeric_precision, c.numeric_scale,
              CASE WHEN k.column_name IS NULL THEN 0 ELSE 1 END AS in_pk, c.column_default
       FROM information_schema.columns c
       LEFT JOIN information_schema.table_constraints tc
         ON tc.table_schema = c.table_schema AND tc.table_name = c.table_name AND tc.constraint_type = 'PRIMARY KEY'
       LEFT JOIN information_schema.key_column_usage k
         ON k.constraint_schema = tc.constraint_schema AND k.constraint_name = tc.constraint_name AND k.column_name = c.column_name
       WHERE c.table_schema = '$SRC_SCHEMA' AND c.table_name IN ('customers', 'orders')$([ "$SOURCE" = crdb ] && echo " AND c.is_hidden = 'NO'")\")
     ORDER BY 1, 2" > "$W/schema.tsv" 2>"$W/schema.err"; }
  fetch_schema; cp "$W/schema.tsv" "$W/schema0.tsv"   # schema0: the columns the snapshot has
  if [ -s "$W/schema.tsv" ]; then
    claim schema-from-connection PASS "remote_query on a POSTGRESQL connection: $(awk -F'\t' '{c[$1]=c[$1] (c[$1]?", ":"") $3 " " $4 ($5==1?" key":"")} END {for (t in c) printf "%s (%s); ", t, c[t]}' "$W/schema.tsv")"
  else claim schema-from-connection FAIL "$(cut -c1-300 "$W/schema.err")"; exit 1; fi
  fi

  # silver: per table, the snapshot rows sequenced by T and the change-log rows sequenced by ts_ns, into one AUTO CDC table.
  # A column added after T isn't in the snapshot, so its snapshot rows get NULL there.
  SNAP_OPTS=$([ "$SNAP_FMT" = csv ] && echo "format => 'csv', header => true" || echo "format => 'parquet'")
  [ "$SCHEMA_VIA" = volume ] || gen_silver() { awk -F'\t' -v vol="$VOL" -v lg="$LOG" -v tns="$SNAP_SEQ" -v dp="$DEST_PREFIX" -v so="$SNAP_OPTS" '
    FNR==NR { insnap[$1 "." $3]=1; next }
    { t=$1; col=$3; ty=$4; cols[t]=cols[t] (cols[t]?", ":"") col; if ($5==1) keys[t]=keys[t] (keys[t]?", ":"") col
      # a column added after T is not in the snapshot, nor in changes made before it was added. A PostgreSQL-protocol
      # source does not resend old rows when a column is added, so those rows hold the column default: use it when the
      # field is missing (SQL NULL from the path), not when it is a JSON null
      dflt=($6 != "" ? $6 : "NULL")
      snap[t]=snap[t] (snap[t]?", ":"") "CAST(" ((t "." col) in insnap ? col : dflt) " AS " ty ") AS " col
      chg[t]=chg[t] (chg[t]?", ":"") ($5==1 ? "key:" col "::" ty : ($6 != "" ? "CASE WHEN value:after IS NOT NULL AND NOT is_variant_null(value:after) AND value:after:" col " IS NULL THEN CAST(" $6 " AS " ty ") ELSE value:after:" col "::" ty " END" : "value:after:" col "::" ty)) " AS " col }
    END { for (t in cols) {
      printf "CREATE TEMPORARY VIEW %s_snapshot AS SELECT %s, CAST(%s AS BIGINT) AS _seq, \047read\047 AS _op\n  FROM STREAM read_files(\047%s/%s\047, %s);\n\n", t, snap[t], tns, vol, t, so
      printf "CREATE TEMPORARY VIEW %s_changes AS SELECT %s, _seq, operation AS _op\n  FROM STREAM(cdc_log_norm) WHERE destination = \047" dp ".%s\047;\n\n", t, chg[t], t
      printf "CREATE OR REFRESH STREAMING TABLE %s CLUSTER BY (%s)\n  COMMENT \047Current rows of the source table: the snapshot as of T, then the change log\047;\n\n", t, keys[t]
      printf "CREATE FLOW %s_from_snapshot AS AUTO CDC INTO %s FROM STREAM(%s_snapshot)\n  KEYS (%s) SEQUENCE BY _seq COLUMNS * EXCEPT (_seq, _op) STORED AS SCD TYPE 1;\n\n", t, t, t, keys[t]
      printf "CREATE FLOW %s_from_changes AS AUTO CDC INTO %s FROM STREAM(%s_changes)\n  KEYS (%s) APPLY AS DELETE WHEN _op = \047delete\047 SEQUENCE BY _seq COLUMNS * EXCEPT (_seq, _op) STORED AS SCD TYPE 1;\n\n", t, t, t, keys[t]
      # SCD type 2 from the same snapshot, and from the change log without replays (cdc_log_dedup, in dedupe.py)
      printf "CREATE TEMPORARY VIEW %s_changes_dedup AS SELECT %s, _seq, operation AS _op\n  FROM STREAM(cdc_log_dedup) WHERE destination = \047" dp ".%s\047;\n\n", t, chg[t], t
      hist(t "_history", t "_changes_dedup", "Every version of each source row (SCD type 2), replays removed")
      if (t == "customers") hist(t "_history_nodedup", t "_changes", "Every version (SCD type 2) from the change log as it is, replays included: shows what a restart does") } }
    function hist(h, src, comment) {
      printf "CREATE OR REFRESH STREAMING TABLE %s CLUSTER BY (%s)\n  COMMENT \047%s\047;\n\n", h, keys[t], comment
      printf "CREATE FLOW %s_from_snapshot AS AUTO CDC INTO %s FROM STREAM(%s_snapshot)\n  KEYS (%s) SEQUENCE BY _seq COLUMNS * EXCEPT (_seq, _op) STORED AS SCD TYPE 2;\n\n", h, h, t, keys[t]
      printf "CREATE FLOW %s_from_changes AS AUTO CDC INTO %s FROM STREAM(%s)\n  KEYS (%s) APPLY AS DELETE WHEN _op = \047delete\047 SEQUENCE BY _seq COLUMNS * EXCEPT (_seq, _op) STORED AS SCD TYPE 2;\n\n", h, h, src, keys[t] }
  ' "$W/schema0.tsv" "$W/schema.tsv" > "$W/silver.body"
    { printf 'CREATE TEMPORARY VIEW cdc_log_norm AS %s\n  FROM STREAM(cdc_log);\n\n' "$NORM"; cat "$W/silver.body"; } > "$W/silver.sql"; }
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
    return (spark.readStream.table("cdc_log_norm")
            .withColumn("_event_time", F.timestamp_micros(F.expr("_event_ns DIV 1000")))
            .withColumn("_after", F.expr("TO_JSON(value:after)"))
            .withWatermark("_event_time", "10 minutes")
            .dropDuplicatesWithinWatermark(["destination", "idempotency_key", "operation", "_after"])
            .drop("_event_time", "_after"))
PY
  WSDIR=/Users/$ME/${SOURCE}_dbz_$E; LIBS="silver.sql dedupe.py"
  [ "$SCHEMA_VIA" = volume ] && { LIBS=silver-from-schema.py; cp "$(dirname "$CHECK")/silver-from-schema.py" "$W/"; }
  [ "$PHASE" -ge 3 ] && LIBS="$LIBS gold.sql"
  dbx workspace mkdirs "$WSDIR" || exit 2
  for f in $LIBS; do dbx workspace import "$WSDIR/$f" --file "$W/$f" --format RAW >/dev/null || { echo "$f upload failed"; exit 2; }; done
  export VOL SINK DEST_PREFIX SNAP_FMT; export T_NS=$SNAP_SEQ; export WSDIR CATALOG S PIPE_NAME=$PREFIX-$SOURCE-dbz-silver-$E LIBS
  yq -n -o json '.name = strenv(PIPE_NAME) | .catalog = strenv(CATALOG) | .schema = strenv(S) | .serverless = true |
    .continuous = false | .development = true | .channel = "CURRENT" |
    .libraries = [strenv(LIBS) | split(" ") | .[] | {"file": {"path": strenv(WSDIR) + "/" + .}}] |
    .configuration = {"cdc.volume": strenv(VOL), "cdc.t_ns": strenv(T_NS), "cdc.dest_prefix": strenv(DEST_PREFIX),
      "cdc.snapshot_format": strenv(SNAP_FMT), "cdc.nodedup_table": "customers", "cdc.bronze": strenv(SINK)}' > "$W/pipe.json"
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
    a=$(echo "SELECT $cols FROM shop.$1 ORDER BY $keys;" | src | tail -n +2)
    b=$(q "SELECT $cols FROM $T.$1_history WHERE __END_AT IS NULL ORDER BY $keys")
    [ "$a" = "$b" ] && claim "history-current-$1-$2" PASS "the current versions in $1_history equal the source: $(echo "$a" | grep -c .) rows" \
      || claim "history-current-$1-$2" FAIL "source vs current history: $(diff <(echo "$a") <(echo "$b") | grep '^[<>]' | tr '\t\n' ', ' | cut -c1-300)"
  }
  history() { # history <table> <history table> <claim|observe>: every version, against CockroachDB's own changefeed from T
    local cols keys r
    cols=$(awk -F'\t' -v t="$1" '$1==t {printf "%s%s", (n++?", ":""), $3}' "$W/schema.tsv")
    keys=$(awk -F'\t' -v t="$1" '$1==t && $5==1 {printf "%s%s", (n++?", ":""), $3}' "$W/schema.tsv")
    snap_select "$1" "$cols" | src > "$W/snap-$1.tsv"
    q "SELECT $cols FROM $T.$2 ORDER BY $keys, __START_AT" > "$W/hist-$2.tsv"
    r=$(python3 -I "$CHECK" "$W/schema.tsv" "$1" "$W/snap-$1.tsv" "$W/feed.tsv" "$W/hist-$2.tsv" 2>&1); local rc=$?
    if [ "$3" = observe ]; then observe "history-$2" "versions expected, in silver, keys that differ: $r"
    elif [ $rc -eq 0 ]; then claim "history-$2" PASS "every version equals the source's changefeed (expected, in silver, keys that differ): $r"
    else claim "history-$2" FAIL "versions expected, in silver, keys that differ: $r"; fi
  }

  same() { # same <table> <round>: silver equals the source, row by row, ordered by the key
    local cols keys a b; cols=$(awk -F'\t' -v t="$1" '$1==t {printf "%s%s", (n++?", ":""), $3}' "$W/schema.tsv")
    keys=$(awk -F'\t' -v t="$1" '$1==t && $5==1 {printf "%s%s", (n++?", ":""), $3}' "$W/schema.tsv")
    a=$(echo "SELECT $cols FROM shop.$1 ORDER BY $keys;" | src | tail -n +2)
    b=$(q "SELECT $cols FROM $T.$1 ORDER BY $keys")
    if [ "${3:-}" = observe ]; then observe "silver-$1-$2" "source vs silver: $( [ "$a" = "$b" ] && echo equal || diff <(echo "$a") <(echo "$b") | grep '^[<>]' | tr '\t\n' ', ' | cut -c1-300)"
    elif [ "$a" = "$b" ]; then claim "silver-$1-$2" PASS "silver $1 equals the source: $(echo "$a" | grep -c .) rows"
    else claim "silver-$1-$2" FAIL "source vs silver: $(diff <(echo "$a") <(echo "$b") | grep '^[<>]' | tr '\t\n' ', ' | cut -c1-300)"; fi
  }

  gold() { # gold <round>: the materialized view equals the same query on the source
    [ "$PHASE" -ge 3 ] || return 0
    local a b; a=$(echo "${GOLD_Q//customers/shop.customers} ORDER BY customer_id;" | sed 's/JOIN orders/JOIN shop.orders/' | src | tail -n +2)
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
  N0=$(q "SELECT COUNT(*) FROM $LOGQ")
  src >/dev/null <<'SQL'
UPDATE shop.customers SET tier = 'platinum' WHERE id = 1;
UPDATE shop.customers SET tier = 'diamond' WHERE id = 1;
DELETE FROM shop.customers WHERE id = 3;
INSERT INTO shop.customers VALUES (3, 'customer_3b', 'silver');
INSERT INTO shop.customers VALUES (2, 'customer_2b', 'bronze');
UPDATE shop.orders SET amount = amount + 1 WHERE id = 2;
SQL
  t0=$SECONDS; until [ "$(q "SELECT COUNT(*) FROM $LOGQ" 2>/dev/null)" -ge $((N0 + 6)) ] 2>/dev/null || [ $((SECONDS - t0)) -ge "$WAIT" ]; do sleep 5; done
  st=$(run_silver); [ "$st" = COMPLETED ] || claim silver-update-2 FAIL "pipeline update: $st"
  for t in $TABLES; do same "$t" 2; done
  gold 2
  [ "$PHASE" -ge 3 ] && observe gold-refresh-2 "update 2, after round 2: $(refresh)"
  [ "$PHASE" -ge 3 ] && observe clustering "clustering columns: $(for t in $TABLES customer_orders; do printf '%s %s; ' "$t" "$(q "DESCRIBE TABLE EXTENDED $T.$t" 2>/dev/null | grep -o -E 'clusteringColumns=\[\[[^]]*\]\]' | head -1)"; done)"
  if [ "$PHASE" -ge 3 ]; then
    # round 3, retries: changes, then Debezium killed (SIGKILL, no offset flush) and started again, then one more change
    N0=$(q "SELECT COUNT(*) FROM $LOGQ")
    src >/dev/null <<'SQL'
INSERT INTO shop.customers VALUES (8, 'customer_8', 'gold');
UPDATE shop.customers SET tier = 'silver' WHERE id = 4;
UPDATE shop.customers SET tier = 'gold' WHERE id = 4;
INSERT INTO shop.orders VALUES (7, 8, 12.34, 'placed');
SQL
    t0=$SECONDS; until [ "$(q "SELECT COUNT(*) FROM $LOGQ" 2>/dev/null)" -ge $((N0 + 4)) ] 2>/dev/null || [ $((SECONDS - t0)) -ge "$WAIT" ]; do sleep 2; done
    vm "sudo podman kill $DBZ >/dev/null && sudo podman start $DBZ >/dev/null" || claim retry-restart FAIL "Debezium restart failed"
    sleep 40
    echo "UPDATE shop.orders SET status = 'shipped' WHERE id = 7;" | src >/dev/null
    t0=$SECONDS; until [ "$(q "SELECT COUNT(*) FROM $LOGQ WHERE operation = 'update' AND destination LIKE '%.orders' AND key:id::INT = 7" 2>/dev/null)" -ge 1 ] 2>/dev/null || [ $((SECONDS - t0)) -ge "$WAIT" ]; do sleep 5; done
    sleep 10
    R=$(q "SELECT COUNT(*) - $N0, COUNT(*) - COUNT(DISTINCT idempotency_key), (SELECT COUNT(*) FROM (SELECT 1 FROM $LOGQ GROUP BY destination, TO_JSON(key), TO_JSON(value:after), operation HAVING COUNT(*) > 1)) FROM $LOGQ" 2>&1 | tr '\t' ' ')
    observe retry-bronze "after the kill and restart, rows added since round 3 began (5 changes), rows sharing an idempotency key, change contents seen more than once: $R"
    [ "$(q "SELECT COUNT(*) FROM $LOGQ WHERE operation = 'update' AND destination LIKE '%.orders' AND key:id::INT = 7")" -ge 1 ] \
      && claim retry-stream-resumes PASS "a change after the restart reached bronze" || claim retry-stream-resumes FAIL "no event for the change after the restart"
    st=$(run_silver); [ "$st" = COMPLETED ] || claim silver-update-3 FAIL "pipeline update: $st"
    for t in $TABLES; do same "$t" 3; done
    gold 3
    # the source's own history: its changefeed from T, with each row's commit time (`updated`)
    if [ "$SOURCE" = crdb ]; then
      vm "timeout 20 sudo podman exec $SRCC cockroach sql --insecure --format=tsv -e \"EXPERIMENTAL CHANGEFEED FOR shop.customers, shop.orders WITH updated, cursor = '$T_HLC'\"" > "$W/feed.tsv" 2>/dev/null
    else   # the audit table, in the changefeed's form: table, key, \x hex of {"after": row, "updated": commit order}
      echo "SELECT tbl, '', '\\x' || encode(convert_to(jsonb_build_object('after', row_data, 'updated', seq::TEXT)::TEXT, 'UTF8'), 'hex') FROM shop.audit ORDER BY seq;" | src > "$W/feed.tsv"
    fi
    for t in $TABLES; do history "$t" "${t}_history" claim; same_hist "$t" 3; done
    history customers customers_history_nodedup observe

    # round 4, schema change: a column added on the source, with a default, then a change that sets it
    echo "ALTER TABLE shop.customers ADD COLUMN email TEXT NOT NULL DEFAULT 'none';" | src >/dev/null
    sleep 15
    echo "UPDATE shop.customers SET email = 'c6@example.com' WHERE id = 6;" | src >/dev/null
    t0=$SECONDS; until [ "$(q "SELECT COUNT(*) FROM $LOGQ WHERE value:after:email::STRING = 'c6@example.com'" 2>/dev/null)" -ge 1 ] 2>/dev/null || [ $((SECONDS - t0)) -ge "$WAIT" ]; do sleep 5; done
    R=$(q "SELECT COUNT(*), COUNT_IF(value:after:email::STRING = 'none') FROM $LOGQ WHERE destination LIKE '%.customers' AND value:after:email IS NOT NULL" 2>&1 | tr '\t' ' ')
    [ "$(q "SELECT COUNT(*) FROM $LOGQ WHERE value:after:email::STRING = 'c6@example.com'")" -ge 1 ] \
      && claim schema-new-column-bronze PASS "the added column reaches bronze with no Databricks DDL (customers events with email, with email = none from the backfill): $R" \
      || claim schema-new-column-bronze FAIL "no event with the new column: $R"
    observe schema-backfill-events "customers events by operation since the ALTER: $(q "SELECT operation, COUNT(*) FROM $LOGQ WHERE destination LIKE '%.customers' AND value:after:email IS NOT NULL GROUP BY 1" 2>&1 | tr '\t\n' '= ')"
    # silver as it is, without the column: the old columns still match
    st=$(run_silver); observe schema-silver-before-regenerate "update with the old flow: $st; silver customers columns: $(q "SELECT CONCAT_WS(',', COLLECT_LIST(column_name)) FROM \`$CATALOG\`.information_schema.columns WHERE table_schema = '$S' AND table_name = 'customers'" 2>&1)"
    # regenerate: the schema again through the connection, the flow from it, then a refresh of that table and a plain update
    fetch_schema || claim schema-refetch FAIL "the schema didn't come through again: $(head -c 300 "$W/schema.err" 2>/dev/null)"; gen_silver
    [ "$SCHEMA_VIA" = volume ] || dbx workspace import "$WSDIR/silver.sql" --file "$W/silver.sql" --format RAW --overwrite >/dev/null
    st=$(run_silver); observe schema-update-after-regenerate "plain update with the regenerated flow: $st"
    [ "$st" = COMPLETED ] && same customers 4a observe
    st=$(run_silver --json '{"full_refresh_selection": ["customers", "customers_history", "customers_history_nodedup"]}'); [ "$st" = COMPLETED ] || claim silver-full-refresh-4 FAIL "full refresh of customers: $st"
    # an update with full_refresh_selection runs only the selected tables: a plain update brings gold along
    st=$(run_silver); [ "$st" = COMPLETED ] || claim silver-update-4 FAIL "plain update after the full refresh: $st"
    for t in $TABLES; do same "$t" 4; same_hist "$t" 4; done
    gold 4

    # round 5: a dropped column and a retyped one (DECIMAL(10,2) -> DECIMAL(12,2)), then a value only the new type holds
    { [ "$SOURCE" = crdb ] && printf 'SET sql_safe_updates = false;\nSET enable_experimental_alter_column_type_general = true;\n'
      cat <<'SQL'; } | src >/dev/null || observe schema-change-ddl "the ALTERs failed on $SRC_NAME"
ALTER TABLE shop.orders DROP COLUMN status;
ALTER TABLE shop.orders ALTER COLUMN amount TYPE DECIMAL(12,2);
SQL
    sleep 15
    echo "UPDATE shop.orders SET amount = 1234567890.12 WHERE id = 1;" | src >/dev/null
    t0=$SECONDS; until [ "$(q "SELECT COUNT(*) FROM $LOGQ WHERE value:after:amount::STRING = '1234567890.12'" 2>/dev/null)" -ge 1 ] 2>/dev/null || [ $((SECONDS - t0)) -ge "$WAIT" ]; do sleep 5; done
    observe schema-change-bronze "all orders events, by operation and whether they have status (a backfill would add updates without it): $(q "SELECT CONCAT(operation, ' status=', value:after:status IS NOT NULL), COUNT(*) FROM $LOGQ WHERE destination LIKE '%.orders' GROUP BY 1" 2>&1 | tr '\t\n' '= '); the new value: $(q "SELECT COUNT(*) FROM $LOGQ WHERE value:after:amount::STRING = '1234567890.12'" 2>&1)"
    st=$(run_silver 2>/dev/null); observe schema-change-old-flow "update with the old flow (status still selected, amount still DECIMAL(10,2)): $st; $(q "SELECT REGEXP_EXTRACT(error.exceptions[0].message, '\\[(INVALID_[A-Z_]+|[A-Z_]+CAST[A-Z_]*)\\][^\\n]*', 0) FROM event_log('$PIPELINE_ID') WHERE event_type = 'flow_progress' AND origin.flow_name LIKE '%.orders_from_changes' AND error IS NOT NULL ORDER BY timestamp DESC LIMIT 1" 2>&1 | cut -c1-300)"
    fetch_schema || claim schema-refetch FAIL "the schema didn't come through again: $(head -c 300 "$W/schema.err" 2>/dev/null)"; gen_silver
    [ "$SCHEMA_VIA" = volume ] || dbx workspace import "$WSDIR/silver.sql" --file "$W/silver.sql" --format RAW --overwrite >/dev/null
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
  echo "# debezium-zerobus run $E ($SRC_NAME)"; echo
  echo "- Date (UTC): $(date -u +%F)"
  echo "- Source: $SRC_NAME $SRC_VERSION, image $SRC_IMAGE ($(vm "sudo podman inspect -f '{{.ImageDigest}}' $SRCC"))"
  echo "- Debezium: $DBZ_IMAGE ($(vm "sudo podman inspect -f '{{.ImageDigest}}' $DBZ")), $([ "$SOURCE" = crdb ] && echo 'CockroachDB connector, sinkless changefeed' || echo 'PostgreSQL connector, pgoutput on a YugabyteDB logical replication slot'), Zerobus sink (envelope into one change-log table, VARIANT fields, idempotency source)"
  echo "- Host: $(vm '. /etc/os-release; echo $PRETTY_NAME'), $(vm 'podman --version')"
  echo "- Destination: Zerobus in $CLOUD $REGION, one append-only change-log Delta table, liquid-clustered by destination (the source table)"
  echo; echo "| Claim | Result | Observation |"; echo "|---|---|---|"
  printf '%s\n' "${RESULTS[@]}"
} | tee "${OUT:-/dev/null}"
exit $FAILED
