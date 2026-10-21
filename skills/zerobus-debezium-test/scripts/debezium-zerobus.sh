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
# MODEL: the source's schema, a canonical schema.yaml (lfc-source-statschema's format): models/<MODEL>.yaml here, or
#   lfc-source-statschema's schemas/<MODEL>.yaml (tpcb, tpcc, tpch, tpcds, tpce, tpcdi); default shop. statschema's
#   shape.py sizes it (SF, default 0.001, for the TPC models' row_count_per_sf), ddl.py writes its DDL, and
#   lfc-source-datagen's fill.py fills it before T; model-sql.py writes the rounds' changes and the checks' queries
#   from it, so nothing below names a table or a column. Gold: models/<MODEL>-gold.sql when there is one.
# Needs: PROFILE (Databricks CLI profile), CATALOG (with its own storage), VM_IP; optional VM_USER (azureuser),
#   SSH_KEY (~/.ssh/lfc_test_rsa), SRC_IMAGE, DBZ_IMAGE, SRC_PORT (published for the UC connection, default 30026),
#   WAIT (seconds to wait for rows, default 180), OUT=<file.md>.
# Exit 0 when every claim passed, 1 when one failed, 2 when a prerequisite is missing.
set -uo pipefail
export PATH=/opt/homebrew/bin:$PATH
: "${PROFILE:?}" "${CATALOG:?}"
[ -n "${LIMA:-}" ] || : "${VM_IP:?set VM_IP (a cloud VM) or LIMA (a local Lima instance with Podman)}"
SOURCE=${SOURCE:-crdb}
# MODEL: which schema the source has, in every name, so a run's tables show which model they hold
MODEL=${MODEL:-shop}; case $MODEL in *[!a-z0-9]*|"") echo "MODEL: lowercase letters and digits"; exit 2;; esac
# NSRC: how many source databases with the model, side by side on the one host (the many-hosts case: identical tables
# merged into one silver table, keyed by source); database i is <MODEL><i>, its change log destination prefix
# <SOURCE><i>.<schema>. Rounds 1 to 3 run on every source; round 4's column goes to source 1 only, round 5's changes to
# source NSRC only, so a schema drifts on one host while the others don't.
NSRC=${NSRC:-1}; case $NSRC in *[!0-9]*|""|0) echo "NSRC: 1 or more"; exit 2;; esac
# BRONZE: shared (every producer and table into one change log, cdc_log; silver reads it filtered by table), fanout
# (producers into cdc_log, then fanout.py, a job, copies it per table, cdc_log_<table>, or per shard with
# BRONZE_SHARDS=K, cdc_log_s<k>; silver reads its own), or per-table (the producers write cdc_log_<table> themselves:
# the Kafka route only; a new table then needs its bronze table and the producer's routing first, so it isn't how
# tables are added without stopping). ON_DRIFT: record (silver keeps flowing and records drift; the default) or fail.
BRONZE=${BRONZE:-shared}; BRONZE_SHARDS=${BRONZE_SHARDS:-0}; ON_DRIFT=${ON_DRIFT:-record}
case $BRONZE in shared|fanout|per-table) ;; *) echo "BRONZE: shared, fanout or per-table"; exit 2;; esac
SRC_DB=${MODEL}1
case $SOURCE in
  crdb) SRC_IMAGE=${SRC_IMAGE:-docker.io/cockroachdb/cockroach:v25.4.13}; SRC_NAME=CockroachDB; SRC_SCHEMA=public
        DROP_FIELDS=${DROP_FIELDS-before,transaction,ts_ms,ts_us,source};;
  yb)   SRC_IMAGE=${SRC_IMAGE:-docker.io/yugabytedb/yugabyte:2026.1.2.0-b137}; SRC_NAME=YugabyteDB; SRC_SCHEMA=$SRC_DB
        DROP_FIELDS=${DROP_FIELDS-before,transaction,ts_ms,ts_us};;
  *) echo "SOURCE: crdb or yb"; exit 2;;
esac
# SINK=zerobus: Debezium Server's Zerobus sink (gRPC). SINK=kafka: Kafka Connect, standalone (offsets in a file, no
# broker), with the producer pointed at Zerobus's Kafka-compatible endpoint; for connectors that only run on Kafka Connect
SINK=${SINK:-$([ "$SOURCE" = yb ] && echo kafka || echo zerobus)}
[ "$BRONZE" = per-table ] && [ "$SINK" != kafka ] && { echo "BRONZE=per-table: only the Kafka route routes each table to its own bronze table so far; use BRONZE=fanout"; exit 2; }
YB_CONNECTOR_URL=${YB_CONNECTOR_URL:-https://github.com/yugabyte/debezium/releases/download/dz.2.5.2.yb.2026.1.2.0.1/yugabytedb-source-connector-dz.2.5.2.yb.2026.1.2.0.1-jar-with-dependencies.jar}
CONNECT_IMAGE=${CONNECT_IMAGE:-docker.io/apache/kafka:3.7.2}
DEST_PREFIX=${SOURCE}1.$SRC_SCHEMA   # the topic prefix and the schema: the change log's destination is <DEST_PREFIX>.<table>
DBZ_IMAGE=${DBZ_IMAGE:-quay.io/debezium/server:3.7.0.Final}
WAIT=${WAIT:-180}; PHASE=${PHASE:-3}; CHECK=${CHECK:-$PWD/scripts/scd2-history-check.py}; SRC_PORT=${SRC_PORT:-${CRDB_PORT:-30026}}
# PODMAN: rootful, through the root Podman socket, so no sudo (lfc-source-podman ensure-podman-socket.sh sets it up).
# One store for the databases and the test, so no image is kept twice. PODMAN=podman runs rootless instead.
PODMAN=${PODMAN:-podman --remote --url unix:///run/podman/podman.sock}
# rmc <dir>: the command that removes a host directory whose files containers wrote (as root, or a container user)
rmc() { case $1 in /*/?*) ;; *) echo "rmc: '$1' isn't an absolute path below a folder" >&2; echo false; return;; esac   # never / or empty
  echo "$PODMAN run --rm -v $(dirname "$1"):/p docker.io/library/alpine:3 rm -rf /p/$(basename "$1")"; }
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
STATSCHEMA=${STATSCHEMA:-$PWD/../lfc-source-statschema/scripts}; DATAGEN=${DATAGEN:-$PWD/../lfc-source-datagen/scripts}
HERE=$(cd "$(dirname "$CHECK")" && pwd)
MODEL_YAML=$HERE/../models/$MODEL.yaml; [ -f "$MODEL_YAML" ] || MODEL_YAML=$STATSCHEMA/../schemas/$MODEL.yaml
[ -f "$MODEL_YAML" ] || { echo "MODEL $MODEL: no models/$MODEL.yaml, nor lfc-source-statschema schemas/$MODEL.yaml"; exit 2; }
GOLD_FILE=$HERE/../models/$MODEL-gold.sql; [ -f "$GOLD_FILE" ] || GOLD_FILE=
SF=${SF:-0.001}
# msql ...: model-sql.py on the model (the rounds' changes); msel <table> ...: its select on the source's current schema
SQLD=$([ "$SOURCE" = crdb ] && echo crdb || echo pg)
msql() { python3 -I "$HERE/model-sql.py" "$MODEL_YAML" "$@" --prefix "$SRC_DB" --dialect "$SQLD"; }
msel() { python3 -I "$HERE/model-sql.py" "$W/schema-$I.yaml" select "$@" --dialect "$SQLD"; }   # on source I's schema
# the first table with a primary key: the one the SCD type 2 history without deduplication is built for
NODEDUP=$(yq -r '[.tables[] | select([.columns[] | select(.primary_key == true)] | length > 0)][0].name' "$MODEL_YAML")
RESULTS=(); FAILED=0
claim() { RESULTS+=("| \`$1\` | $2 | $3 |"); [ "$2" = PASS ] || FAILED=1; echo "$2 $1: $3"; }
observe() { RESULTS+=("| \`$1\` | OBSERVED | $2 |"); echo "OBSERVED $1: $2"; }
# link <what> <url>: every Databricks object the run creates gets a clickable link, printed when it's created and kept for
# the result file (the objects are removed at the end, unless KEEP=1)
LINKS=(); link() { LINKS+=("- $1: <$2>"); echo "LINK $1: $2"; }
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
E=$(date +%s); S=${PREFIX}_${SOURCE}_${MODEL}_dbz_$E; NET=$SOURCE-dbz-$E; SRCC=$PREFIX-$SOURCE-$E; DBZ=$PREFIX-debezium-$E; RD=/tmp/dbz-$SOURCE-$E
T="\`$CATALOG\`.$S"
# per source i: SDB (database), DESTP (destination prefix), TNS (T in ns, silver's sequence for its snapshot), THLC and
# TUS (T for the snapshot reads), DBZC (its Debezium Server; Kafka Connect runs every source's connector in one worker)
declare -a SDB DESTP TNS THLC TUS DBZC
for i in $(seq 1 "$NSRC"); do SDB[$i]=$MODEL$i; DBZC[$i]=$([ "$i" = 1 ] && echo "$DBZ" || echo "$PREFIX-debezium$i-$E")
  DESTP[$i]=$SOURCE$i.$([ "$SOURCE" = crdb ] && echo public || echo "${SDB[$i]}"); done
DBZS=$([ "$SINK" = kafka ] && echo "$DBZ" || echo "${DBZC[*]}")   # every producer container
use() { # use <i>: the source the next commands are for
  I=$1; SRC_DB=${SDB[$1]}; DEST_PREFIX=${DESTP[$1]}; [ "$SOURCE" = yb ] && SRC_SCHEMA=$SRC_DB
  T_NS=${TNS[$1]:-}; T_HLC=${THLC[$1]:-}; T_US=${TUS[$1]:-}; :; }
use 1
echo "run $E: schema $CATALOG.$S, VM containers $SRCC and $DBZS; $NSRC source database(s), bronze $BRONZE, drift $ON_DRIFT"

sql() {
  yq -n -o json '.warehouse_id = strenv(WAREHOUSE) | .wait_timeout = "50s" | .statement = strenv(Q)' > "$W/st.json"
  dbx api post /api/2.0/sql/statements --json @"$W/st.json" > "$W/st.out"
  [ "$(yq '.status.state' "$W/st.out")" = SUCCEEDED ] || { yq '.status.state + ": " + (.status.error.message // "")' "$W/st.out" | cut -c1-300 >&2; return 1; }
  yq -r '(.result.data_array // [])[] | @tsv' "$W/st.out"
}
q() { export Q=$1; sql; }
# src: SQL from stdin on the source, tab-separated with a header row
case $SOURCE in
  crdb) src() { vm "$PODMAN exec -i $SRCC cockroach sql --insecure --format=tsv"; };;
  yb)   src() { vm "$PODMAN exec -i $SRCC bin/ysqlsh -h yugabytedb -U yugabyte -d $SRC_DB -q -A -z -P footer=off -v ON_ERROR_STOP=1 | tr '\\000' '\\t'"; };;
esac
# srcq: the same, with unqualified names resolving in the model's database (CockroachDB) or schema (YugabyteDB)
case $SOURCE in
  crdb) srcq() { vm "$PODMAN exec -i $SRCC cockroach sql --insecure -d $SRC_DB --format=tsv"; };;
  yb)   srcq() { { echo "SET search_path TO $SRC_DB;"; cat; } | src; };;
esac

cleanup() {
  [ "${KEEP:-0}" = 1 ] && { echo "KEEP=1: left $CATALOG.$S, SP ${SP_NAME:-}, VM containers and $RD, to inspect:"; printf '%s\n' "${LINKS[@]}"; rm -rf "${W:?}"; return; }
  vm "$PODMAN rm -f --ignore $DBZS $SRCC >/dev/null 2>&1; $PODMAN network rm $NET >/dev/null 2>&1; $(rmc $RD)" || true
  [ -n "${SP_ID:-}" ] && dbx service-principals delete "$SP_ID" >/dev/null 2>&1
  [ -n "${PIPELINE_ID:-}" ] && dbx pipelines delete "$PIPELINE_ID" >/dev/null 2>&1
  [ -n "${JOB_ID:-}" ] && dbx jobs delete "$JOB_ID" >/dev/null 2>&1
  [ -n "${CONN:-}" ] && dbx connections delete "$CONN" >/dev/null 2>&1
  [ -n "${WSDIR:-}" ] && dbx workspace delete "$WSDIR" --recursive >/dev/null 2>&1
  dbx schemas delete "$CATALOG.$S" --force >/dev/null 2>&1
  left=$(vm "$PODMAN ps -a --format '{{.Names}}' | grep -c -E '^($(echo $DBZS | tr ' ' '|')|$SRCC)\$'" 2>/dev/null)
  echo "cleanup: containers left ${left:-?}; SP ${SP_ID:+deleted}; pipeline ${PIPELINE_ID:+deleted}; connection ${CONN:+deleted}; schema dropped"
  rm -rf "${W:?}"
}
trap cleanup EXIT

# the published port, for the UC connection: SRC_PORT, or the next free one up to 30063 (the shared firewall group opens
# 30000-30063), so a run kept with KEEP=1 doesn't block the next
if [ "$SCHEMA_VIA" = connection ]; then
  p=$SRC_PORT; while [ "$p" -le 30063 ] && vm "ss -ltnH 'sport = :$p' | grep -q ." 2>/dev/null; do p=$((p + 1)); done
  [ "$p" -le 30063 ] || { echo "no free port from $SRC_PORT to 30063 on $HOSTDESC"; exit 2; }
  [ "$p" != "$SRC_PORT" ] && echo "port $SRC_PORT is in use (a kept run?): using $p"; SRC_PORT=$p
fi

# --- source: the model, sized, created and filled before T --------------------------------------------------------------
# statschema's shape.py gives each table its rows (SF) and each column its datagen tags, ddl.py the DDL;
# lfc-source-datagen's fill.py fills it from a container on the run's network (nothing is published for it)
(cd "$STATSCHEMA/.." && uv run -q scripts/shape.py "$MODEL_YAML" --sf "$SF" --expected "$W/expected.json" > "$W/shaped.yaml" 2>"$W/shape.err" \
  && uv run -q scripts/ddl.py "$W/shaped.yaml" --dialect "$([ "$SOURCE" = crdb ] && echo cockroachdb || echo postgres)" > "$W/ddl.sql" 2>>"$W/shape.err") \
  || { echo "model $MODEL: shape.py or ddl.py failed: $(head -c 300 "$W/shape.err")"; exit 2; }
fill() { # fill <host> <port> <user> <password> <schema>: lfc-source-datagen's fill.py, every table to its target
  tar -C "$DATAGEN/python" --exclude __pycache__ -cf - . | vm "umask 077; mkdir -p $RD/datagen && tar -xf - -C $RD/datagen && echo $4 > $RD/datagen.pw" || return 1
  vm "C=\$HOME/.cache/dbz-zerobus; mkdir -p \$C/pip; $PODMAN run --rm --network $NET -v $RD/datagen:/dg:ro,Z -v $RD/datagen.pw:/pw:ro,Z \
    -v \$C/pip:/root/.cache/pip:Z docker.io/library/python:3.12-slim sh -c 'pip install -q --disable-pip-version-check psycopg2-binary \
    && python /dg/fill.py pg $5 --host $1 --port $2 --user $3 --database $SRC_DB --password-file /pw'" > "$W/fill.out" 2>&1
}
filled() { # the rows per table, as "table=rows ..."
  for t in $(yq -r '.tables[].name' "$MODEL_YAML"); do printf '%s=%s ' "$t" "$(echo "SELECT COUNT(*) FROM \"$t\";" | srcq | tail -1)"; done; }
if [ "$SOURCE" = crdb ]; then
  vm "$PODMAN network create $NET >/dev/null && $PODMAN run -d --name $SRCC --network $NET --network-alias cockroachdb \
    $([ "$SCHEMA_VIA" = connection ] && echo "-p $SRC_PORT:26257") $SRC_IMAGE start-single-node --insecure --advertise-addr=cockroachdb >/dev/null" || { echo "CockroachDB start failed"; exit 2; }
  for _ in $(seq 1 30); do echo 'SELECT 1;' | src >/dev/null 2>&1 && break; sleep 2; done
  echo 'SET CLUSTER SETTING kv.rangefeed.enabled = true;' | src >/dev/null || { echo "CockroachDB setup failed"; exit 2; }
  for i in $(seq 1 "$NSRC"); do use "$i"
    echo "CREATE DATABASE $SRC_DB;" | src >/dev/null && srcq < "$W/ddl.sql" >/dev/null || { echo "CockroachDB setup of $SRC_DB failed"; exit 2; }
    # the insecure node takes any password
    fill cockroachdb 26257 root unused public || { echo "fill of $SRC_DB failed: $(tail -3 "$W/fill.out" | tr '\n' ' ' | cut -c1-300)"; exit 2; }
  done
  SRC_VERSION=$(echo 'SELECT version();' | src | tail -1 | cut -c1-80)
  # T: the cluster time, after every database is filled; one for all of them. Each Debezium's changefeed starts
  # there, with no snapshot of its own.
  t=$(echo 'SELECT cluster_logical_timestamp();' | src | tail -1)
  for i in $(seq 1 "$NSRC"); do THLC[$i]=$t; TNS[$i]=${t%%.*}; done   # the wall time in nanoseconds: silver's sequence
  # snap_select <table>: its rows at T in the current source, rendered as model-sql.py renders them (header row first)
  snap_select() { local s; s=$(msel "$1" --side source --prefix "$SRC_DB"); echo "${s/ ORDER BY / AS OF SYSTEM TIME '$T_HLC' ORDER BY }"; }
else
  vm "$PODMAN network create $NET >/dev/null && $PODMAN run -d --name $SRCC --network $NET --network-alias yugabytedb \
    $([ "$SCHEMA_VIA" = connection ] && echo "-p $SRC_PORT:5433") $SRC_IMAGE bin/yugabyted start --background=false --advertise_address=yugabytedb >/dev/null" || { echo "YugabyteDB start failed"; exit 2; }
  for _ in $(seq 1 60); do vm "$PODMAN exec $SRCC bin/ysqlsh -h yugabytedb -U yugabyte -c 'SELECT 1'" >/dev/null 2>&1 && break; sleep 3; done
  for i in $(seq 1 "$NSRC"); do use "$i"
    vm "$PODMAN exec $SRCC bin/ysqlsh -h yugabytedb -U yugabyte -c 'CREATE DATABASE $SRC_DB'" >/dev/null && echo "CREATE SCHEMA $SRC_DB;" | src >/dev/null \
      && srcq < "$W/ddl.sql" >/dev/null || { echo "YugabyteDB setup of $SRC_DB failed"; exit 2; }
    fill yugabytedb 5433 yugabyte yugabyte "$SRC_DB" || { echo "fill of $SRC_DB failed: $(tail -3 "$W/fill.out" | tr '\n' ' ' | cut -c1-300)"; exit 2; }
    # after the fill, so only the changes from T are in it: the truth for the history check, an audit trigger writing
    # every change, in commit order, to a table not published. REPLICA IDENTITY DEFAULT (the key) on tables with a key,
    # set before the slot exists; a table without one keeps ddl.py's FULL. @S@ is the schema, @I@ the source: a
    # replication slot's name is the cluster's, so each database has its own.
    sed "s/@S@/$SRC_DB/g; s/@I@/$i/g" <<'SQL' | src >/dev/null || { echo "YugabyteDB setup of $SRC_DB failed"; exit 2; }
CREATE TABLE @S@.audit (seq BIGSERIAL PRIMARY KEY, tbl TEXT NOT NULL, op TEXT NOT NULL, row_data JSONB);
CREATE FUNCTION @S@.audit_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
  INSERT INTO @S@.audit (tbl, op, row_data) VALUES (TG_TABLE_NAME, TG_OP, CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END);
  RETURN NULL; END $$;
DO $$ DECLARE t text; BEGIN
  FOR t IN SELECT table_name FROM information_schema.tables WHERE table_schema = '@S@' AND table_type = 'BASE TABLE' AND table_name <> 'audit' LOOP
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON @S@.%I FOR EACH ROW EXECUTE FUNCTION @S@.audit_fn()', t || '_audit', t); END LOOP; END $$;
DO $$ DECLARE t text; BEGIN
  FOR t IN SELECT tc.table_name FROM information_schema.table_constraints tc WHERE tc.table_schema = '@S@' AND tc.constraint_type = 'PRIMARY KEY' AND tc.table_name <> 'audit' LOOP
    EXECUTE format('ALTER TABLE @S@.%I REPLICA IDENTITY DEFAULT', t); END LOOP;
  -- YugabyteDB 2026.1 refuses CREATE PUBLICATION ... FOR TABLES IN SCHEMA ("not supported yet"): list the tables
  EXECUTE (SELECT 'CREATE PUBLICATION dbz_pub FOR TABLE ' || string_agg(format('@S@.%I', table_name), ', ')
           FROM information_schema.tables WHERE table_schema = '@S@' AND table_type = 'BASE TABLE' AND table_name <> 'audit'); END $$;
SELECT 1 FROM pg_create_logical_replication_slot('dbz_slot_@I@', 'pgoutput');
SQL
    # T: the slot's consistent snapshot, a hybrid time (microseconds << 12). Debezium streams from the slot, with no
    # snapshot of its own; the dump reads as of T with yb_read_time.
    ht=$(echo "SELECT yb_restart_commit_ht FROM pg_replication_slots WHERE slot_name = 'dbz_slot_$i';" | src | tail -1)
    TUS[$i]=$((ht >> 12)); TNS[$i]=$((TUS[i] * 1000)); THLC[$i]="slot dbz_slot_$i, hybrid time $ht (${TUS[$i]} us)"
  done
  SRC_VERSION=$(echo 'SELECT version();' | src | tail -1 | cut -c1-80)
  snap_select() { printf 'SET yb_read_time TO %s;\n%s\nRESET yb_read_time;\n' "$T_US" "$(msel "$1" --side source --prefix "$SRC_DB")"; }
fi
FILLED=; for i in $(seq 1 "$NSRC"); do use "$i"; f=$(filled); FILLED="$FILLED${FILLED:+; }$SRC_DB: $f"
  echo " $f" | grep -q -E ' [^ =]+=(0)? ' && { claim model-fill FAIL "a table is empty in $SRC_DB: $f"; exit 1; }
  # the key maxima, so the workload's new keys come after every generated one
  msql state | src > "$W/state-$i.tsv" || { echo "key maxima in $SRC_DB failed"; exit 2; }; done
use 1
claim model-fill PASS "$MODEL at SF $SF (shape.py, ddl.py, fill.py), $NSRC database(s): $FILLED"
# the tables: every base table in the source schema (but the audit table, the history check's truth), so nothing below
# names one; the model decides what they are (the same in every source). CockroachDB's client connects to defaultdb, so
# it reads <db>.information_schema; YugabyteDB's connects to the model's database
TABLES=$(echo "SELECT table_name FROM $([ "$SOURCE" = crdb ] && echo "$SRC_DB.")information_schema.tables WHERE table_schema = '$SRC_SCHEMA' AND table_type = 'BASE TABLE' AND table_name <> 'audit' ORDER BY 1;" \
  | src | tail -n +2 | tr '\n' ' ' | sed 's/ $//')
[ -n "$TABLES" ] || { echo "no tables in $SRC_SCHEMA"; exit 2; }
include() { for t in $TABLES; do printf '%s.%s,' "$SRC_SCHEMA" "$t"; done | sed 's/,$//'; }   # schema.table, for the current source's connector
keyed() { awk -F'\t' -v t="$1" '$1 == t && $5 == 1 {f = 1} END {exit !f}' "$W/schema.tsv"; }   # keyed <table>: has a primary key
if [ "$PHASE" -ge 2 ]; then
  # the snapshot: every table of every source as of its T, onto the laptop, as <table>/<destination prefix>/ (the
  # layout silver reads: the folder names the source). CockroachDB: EXPORT INTO PARQUET; DECIMAL goes out as STRING
  # because v25.4.13 writes a DECIMAL column as BYTE_ARRAY annotated DECIMAL but filled with the number's text, so
  # readers get "21.00" as the unscaled integer 0x32312E3030 (2155734753.76). YugabyteDB: COPY ... CSV under
  # yb_read_time. Silver casts every column to its type.
  mkdir -p "$W/snap" "$W/raw"
  for i in $(seq 1 "$NSRC"); do use "$i"
    for t in $TABLES; do
      mkdir -p "$W/snap/$t/$DEST_PREFIX"
      if [ "$SOURCE" = crdb ]; then
        cols=$(echo "SELECT string_agg(CASE WHEN data_type = 'numeric' THEN quote_ident(column_name) || '::STRING AS ' || quote_ident(column_name)
          ELSE quote_ident(column_name) END, ', ' ORDER BY ordinal_position) FROM $SRC_DB.information_schema.columns
          WHERE table_schema = 'public' AND table_name = '$t' AND is_hidden = 'NO';" | src | tail -1)
        echo "EXPORT INTO PARQUET 'nodelocal://self/snap/$i/$t' FROM SELECT $cols FROM $SRC_DB.\"$t\" AS OF SYSTEM TIME '$T_HLC';" | src >/dev/null \
          || { echo "EXPORT of $SRC_DB.$t failed"; exit 2; }
      else
        printf 'SET yb_read_time TO %s;\nCOPY (SELECT * FROM %s."%s") TO STDOUT WITH (FORMAT csv, HEADER);\n' "$T_US" "$SRC_DB" "$t" \
          | vm "$PODMAN exec -i $SRCC bin/ysqlsh -h yugabytedb -U yugabyte -d $SRC_DB -q -v ON_ERROR_STOP=1" > "$W/snap/$t/$DEST_PREFIX/$t.csv" 2>/dev/null \
          || { echo "COPY of $SRC_DB.$t failed"; exit 2; }
      fi
    done
  done; use 1
  if [ "$SOURCE" = crdb ]; then
    vm "$PODMAN exec $SRCC tar -C /cockroach/cockroach-data/extern/snap -cf - ." | tar -xf - -C "$W/raw" || { echo "snapshot copy failed"; exit 2; }
    for i in $(seq 1 "$NSRC"); do for t in $TABLES; do mv "$W/raw/$i/$t"/* "$W/snap/$t/${DESTP[$i]}/" 2>/dev/null; done; done
  fi
  SNAP_FMT=$([ "$SOURCE" = crdb ] && echo parquet || echo csv)
fi
# tsv_of <schema.yaml>: table, ordinal, column, Databricks type, 1 for a key: for the checks
tsv_of() {
  yq -r '.tables[] | .name as $t | .columns | to_entries[] | [$t, .key + 1, .value.name,
    (.value.type as $y | {"integer": "INT", "long": "BIGINT", "float": "FLOAT", "double": "DOUBLE", "boolean": "BOOLEAN", "date": "DATE",
      "timestamp": "TIMESTAMP_NTZ", "timestamptz": "TIMESTAMP", "binary": "BINARY", "char": "CHAR"}[$y] //
      (select($y == "decimal") | "DECIMAL(" + (.value.precision // 38 | tostring) + "," + (.value.scale // 0 | tostring) + ")") // "STRING"),
    ((.value.primary_key // false) | tostring | sub("true"; "1") | sub("false"; "0"))] | @tsv' "$1"
}
# dump_schema: the current source's DDL -> statschema's canonical schema.yaml ($W/schema-<I>.yaml), with the
# lfc-source-statschema skill's ddl-to-schema.py, and its tsv. sqlglot's postgres dialect doesn't take CockroachDB's
# "PRIMARY KEY (id ASC)" or its typed literals ('none':::STRING), so the key order and the casts go; nor is
# CockroachDB's hidden rowid, the key of a table without one, a column of the model (the snapshot leaves it out too).
dump_schema() {
  [ "$SOURCE" = crdb ] || { echo "SCHEMA_VIA=volume: only SOURCE=crdb dumps DDL so far" > "$W/schema.err"; return 1; }
  vm "$PODMAN exec $SRCC cockroach sql --insecure -d $SRC_DB --format=raw -e 'SHOW CREATE ALL TABLES'" | grep -v '^#' \
    | perl -0pe 's/,\s*\n\s*CONSTRAINT \S+ PRIMARY KEY \(rowid[^)]*\)//g; s/,\s*\n\s*rowid INT8 NOT VISIBLE[^\n]*//g' \
    | sed -E 's/ (ASC|DESC)([,)])/\2/g; s/:::[A-Za-z0-9_]+(\[\])?//g' | (cd "$STATSCHEMA/.." && uv run -q scripts/ddl-to-schema.py --dialect postgres) > "$W/schema-$I.yaml" 2>"$W/schema.err" || return 1
  tsv_of "$W/schema-$I.yaml" > "$W/schema-$I.tsv"
}
# schemas [evolve]: every source's canonical schema ($W/schema-<i>.yaml and .tsv, with fetch_one: the DDL, or the UC
# connection), then their union (schema-union.py: the one silver is built from, $W/schema.yaml and .tsv). evolve: the
# tables whose union changed go to $W/changed/<table>.yaml (silver's _schema/tables/), and their names to $W/changed.txt
schemas() {
  local i ok=0 cur=""; for i in $(seq 1 "$NSRC"); do use "$i"; fetch_one || ok=1; done; use 1
  [ $ok = 0 ] || return 1
  rm -rf "${W:?}/changed"; : > "$W/changed.txt"
  [ "${1:-}" = evolve ] && { cp "$W/schema.yaml" "$W/schema-before.yaml"; cur="--current $W/schema-before.yaml --changed-dir $W/changed"; }
  python3 -I "$HERE/schema-union.py" $(for i in $(seq 1 "$NSRC"); do echo "$W/schema-$i.yaml"; done) $cur > "$W/schema.yaml" 2>"$W/changed.txt" \
    || { cat "$W/changed.txt" > "$W/schema.err"; return 1; }
  tsv_of "$W/schema.yaml" > "$W/schema.tsv"
}
if [ "$PHASE" -ge 2 ] && [ "$SCHEMA_VIA" = volume ]; then
  fetch_one() { dump_schema; }
  schemas || { echo "schema dump failed: $(head -c 300 "$W/schema.err")"; exit 2; }
fi

# --- destination: bronze tables, a service principal with a secret, grants -------------------------------------------
dbx schemas create "$S" "$CATALOG" >/dev/null || exit 2
link "schema $CATALOG.$S" "$HOST/explore/data/$CATALOG/$S"
# the tables the producers write: cdc_log (BRONZE=shared or fanout), or one per source table (per-table)
LOGS=$([ "$BRONZE" = per-table ] && for t in $TABLES; do printf 'cdc_log_%s ' "$t"; done || echo cdc_log); LOGS=${LOGS% }
LOG=$T.cdc_log
# NORM: the change log in one shape for both sinks: destination, operation (create/update/delete/read), idempotency_key,
# key, value, source_position, headers, _seq (orders each key's changes) and _event_ns (for the deduplication watermark).
# Kafka Connect's records carry only the event (the Kafka API ingests the value alone): the operation comes from op, the
# key from after or before, and the sequence from the slot's LSN, which follows commit order; the snapshot is sequence 0.
if [ "$SINK" = kafka ]; then
  NORM="SELECT destination, CASE value:op::STRING WHEN 'c' THEN 'create' WHEN 'u' THEN 'update' WHEN 'd' THEN 'delete' WHEN 'r' THEN 'read' END AS operation,
    value:source:lsn::STRING AS idempotency_key, CASE value:op::STRING WHEN 'd' THEN value:before ELSE value:after END AS key, value, value:source AS source_position,
    CAST(NULL AS VARIANT) AS headers, value:source:lsn::BIGINT AS _seq, value:ts_ms::BIGINT * 1000000 AS _event_ns"
  for i in $(seq 1 "$NSRC"); do SNAPSEQ[$i]=0; done
  mklog() { q "CREATE TABLE $T.$1 (destination STRING NOT NULL, value VARIANT) CLUSTER BY (destination)
    COMMENT 'Append-only change log: one Debezium event per source change (Kafka Connect through the Zerobus Kafka API)'" >/dev/null; }
else
  NORM="SELECT *, value:ts_ns::BIGINT AS _seq, value:ts_ns::BIGINT AS _event_ns"
  for i in $(seq 1 "$NSRC"); do SNAPSEQ[$i]=${TNS[$i]}; done
  mklog() { q "CREATE TABLE $T.$1 (target_table STRING NOT NULL, destination STRING NOT NULL, partition INT, operation STRING NOT NULL,
    idempotency_key STRING, key VARIANT, value VARIANT, source_position VARIANT, headers VARIANT) CLUSTER BY (destination)
    COMMENT 'Append-only change log: one Debezium envelope per source change'" >/dev/null; }
fi
for l in $LOGS; do mklog "$l" || exit 2; link "change log (bronze) $CATALOG.$S.$l" "$HOST/explore/data/$CATALOG/$S/$l"; done
# LOGQ: every event, normalized, for the checks (over every producer table when there are several)
LOGQ="($(for l in $LOGS; do printf '%s FROM %s.%s UNION ALL ' "$NORM" "$T" "$l"; done | sed 's/ UNION ALL $//'))"
if [ -n "${SP_CLIENT_ID:-}" ]; then   # a service principal someone else created: its application ID and a file with its secret
  [ -r "${SP_SECRET_FILE:-}" ] || { echo "SP_CLIENT_ID needs SP_SECRET_FILE, a file with the OAuth secret"; exit 2; }
  SP_APP=$SP_CLIENT_ID; SP_NAME="existing $SP_CLIENT_ID"; SECRET=$(cat "$SP_SECRET_FILE") yq -n -o json '.secret = strenv(SECRET)' > "$W/secret.json"
else
SP_NAME=$PREFIX-zerobus-dbz-$E
eval "$(dbx service-principals create --display-name "$SP_NAME" -o json | yq -o shell '{"SP_ID": .id, "SP_APP": .applicationId}')"
[ -n "${SP_ID:-}" ] || { echo "service principal create failed"; exit 2; }
link "service principal $SP_NAME" "$HOST/settings/workspace/identity-and-access/service-principals/$SP_ID"
dbx service-principal-secrets-proxy create "$SP_ID" -o json > "$W/secret.json" || { echo "secret create failed"; exit 2; }
fi
# directly on each table: the producer's token is scoped to its tables, which inherited grants may not satisfy (4024)
for g in "GRANT USE CATALOG ON CATALOG \`$CATALOG\` TO \`$SP_APP\`" "GRANT USE SCHEMA ON SCHEMA $T TO \`$SP_APP\`" \
         $(for l in $LOGS; do printf 'GRANT@SELECT,@MODIFY@ON@TABLE@%s.%s@TO@`%s` ' "$T" "$l" "$SP_APP"; done); do
  q "${g//@/ }" >/dev/null || exit 2
done

# --- producers: one per source database (Debezium Server), or every source's connector in one Kafka Connect worker -----
export SP_APP ZB HOST CATALOG S
if [ "$SINK" = zerobus ]; then
yq -r '"debezium.sink.zerobus.client.secret=" + .secret' "$W/secret.json" > "$W/secret.line"; rm -f "$W/secret.json"
for i in $(seq 1 "$NSRC"); do use "$i"
cat > "$W/application.properties" <<EOF
$( if [ "$SOURCE" = crdb ]; then cat <<CRDB
debezium.source.connector.class=io.debezium.connector.cockroachdb.CockroachDBConnector
debezium.source.name=crdb$i-zerobus
debezium.source.topic.prefix=crdb$i
debezium.source.database.hostname=cockroachdb
debezium.source.database.port=26257
debezium.source.database.user=root
debezium.source.database.password=
debezium.source.database.dbname=$SRC_DB
debezium.source.database.sslmode=disable
debezium.source.database.server.name=crdb$i
debezium.source.table.include.list=$(include)
debezium.source.cockroachdb.changefeed.cursor=$T_HLC
debezium.source.cockroachdb.changefeed.sink.type=sinkless
debezium.source.cockroachdb.changefeed.resolved.interval=5s
debezium.source.cockroachdb.changefeed.include.diff=false
debezium.source.cockroachdb.changefeed.include.updated=true
CRDB
[ -n "${ENRICHED_PROPERTIES:-}" ] && echo "debezium.source.cockroachdb.changefeed.enriched.properties=$ENRICHED_PROPERTIES"
else cat <<YB
debezium.source.connector.class=${YB_CONNECTOR_CLASS:-io.debezium.connector.postgresql.PostgresConnector}
debezium.source.name=yb$i-zerobus
debezium.source.topic.prefix=yb$i
debezium.source.database.hostname=yugabytedb
debezium.source.database.port=5433
debezium.source.database.user=yugabyte
debezium.source.database.password=yugabyte
debezium.source.database.dbname=$SRC_DB
debezium.source.plugin.name=pgoutput
debezium.source.slot.name=dbz_slot_$i
debezium.source.publication.name=dbz_pub
debezium.source.publication.autocreate.mode=disabled
debezium.source.table.include.list=$(include)
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
cat "$W/secret.line" >> "$W/application.properties"
vm "umask 077; mkdir -p $RD/src$i/data && cat > $RD/src$i/application.properties" < "$W/application.properties"; rm -f "$W/application.properties"
# :U gives the mounted files to the container user (Debezium runs as a non-root user), so the secret stays 0600
vm "$PODMAN run -d --name ${DBZC[$i]} --network $NET -v $RD/src$i/application.properties:/debezium/config/application.properties:ro,U \
  -v $RD/src$i/data:/debezium/data:U $DBZ_IMAGE >/dev/null" || { echo "Debezium start for $SRC_DB failed"; exit 2; }
done; use 1; rm -f "$W/secret.line"
else
# --- Kafka Connect, standalone, into Zerobus's Kafka-compatible endpoint (no broker) ------------------------------------
# The producer needs SASL OAUTHBEARER with a token minted for the tables: the login callback handler in Debezium's
# Zerobus sink jar does that (JAAS options clientId, clientSecret, workspaceUrl, workspaceId, tables). The Kafka API
# ingests the record value only, so the transforms put everything into it: the event as "value" (StringifyField makes it
# JSON text, which is how Zerobus takes a VARIANT), the source topic as "destination", and every topic routed to the one
# table (BRONZE=per-table: to cdc_log_<table>). One worker runs every source's connector (standalone takes several
# connector files). Jars are cached on the host in ~/.cache/dbz-zerobus.
vm "umask 077; mkdir -p $RD/data $RD/cfg; C=\$HOME/.cache/dbz-zerobus; mkdir -p \$C/plugins/yb \$C/plugins/stringify \$C/cp \$C/src
  [ -s \$C/plugins/yb/yb.jar ] || curl -s -L -o \$C/plugins/yb/yb.jar '$YB_CONNECTOR_URL'
  [ -s \$C/cp/zerobus-sink.jar ] || $PODMAN run --rm --entrypoint sh $DBZ_IMAGE -c 'cat /debezium/lib/debezium-server-databricks-zerobus-*.jar' > \$C/cp/zerobus-sink.jar" \
  || { echo "Kafka Connect jars failed"; exit 2; }
# the source only when it changed, so the jar is rebuilt only then
vm "S=\$HOME/.cache/dbz-zerobus/src/StringifyField.java; cat > \$S.new; cmp -s \$S.new \$S && rm \$S.new || mv \$S.new \$S" < "$HERE/kafka-connect/StringifyField.java"
vm "C=\$HOME/.cache/dbz-zerobus; [ -s \$C/plugins/stringify/lfc-stringify-field.jar ] && [ \$C/plugins/stringify/lfc-stringify-field.jar -nt \$C/src/StringifyField.java ] && exit 0
  $PODMAN run --rm -u 0 -v \$C:/c:Z $CONNECT_IMAGE sh -c 'mkdir -p /c/k && cp /opt/kafka/libs/connect-api-*.jar /opt/kafka/libs/connect-json-*.jar /opt/kafka/libs/kafka-clients-*.jar /c/k/' \
  && $PODMAN run --rm -u 0 -v \$C:/c:Z docker.io/library/eclipse-temurin:17-jdk sh -c 'cd /c && rm -rf build && javac -d build -cp \"/c/k/*\" src/StringifyField.java && jar cf plugins/stringify/lfc-stringify-field.jar -C build .'" >/dev/null \
  || { echo "StringifyField build failed"; exit 2; }
TOPICS=$(for l in $LOGS; do printf '%s.%s.%s,' "$CATALOG" "$S" "$l"; done | sed 's/,$//'); BOOT=${ZB#https://}:9092
export JAAS_SECRET=$(yq -r '.secret' "$W/secret.json"); rm -f "$W/secret.json"
{ for pre in "" producer. admin.; do cat <<EOF
${pre}bootstrap.servers=$BOOT
${pre}security.protocol=SASL_SSL
${pre}sasl.mechanism=OAUTHBEARER
${pre}sasl.login.callback.handler.class=io.debezium.server.databricks.zerobus.ZerobusOAuthBearerLoginCallbackHandler
${pre}sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="$SP_APP" clientSecret="$JAAS_SECRET" workspaceUrl="$HOST" workspaceId="$WS_ID" tables="$TOPICS";
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
# the route: every topic (<prefix>.<schema>.<table>) to cdc_log, or to cdc_log_<table>
[ "$BRONZE" = per-table ] && ROUTE='[^.]+\\.[^.]+\\.(.*)'"|$CATALOG.$S.cdc_log_\$1" || ROUTE=".*|$CATALOG.$S.cdc_log"
for i in $(seq 1 "$NSRC"); do use "$i"
cat > "$W/connector$i.properties" <<EOF
name=yb$i-zerobus
connector.class=io.debezium.connector.postgresql.YugabyteDBConnector
tasks.max=1
database.hostname=yugabytedb
database.port=5433
database.user=yugabyte
database.password=yugabyte
database.dbname=$SRC_DB
topic.prefix=yb$i
plugin.name=pgoutput
slot.name=dbz_slot_$i
publication.name=dbz_pub
publication.autocreate.mode=disabled
snapshot.mode=never
table.include.list=$(include)
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
transforms.route.regex=${ROUTE%%|*}
transforms.route.replacement=${ROUTE#*|}
EOF
done; use 1
for f in worker $(seq -f 'connector%g' 1 "$NSRC"); do vm "umask 077; cat > $RD/cfg/$f.properties" < "$W/$f.properties"; rm -f "$W/$f.properties"; done
vm "C=\$HOME/.cache/dbz-zerobus; $PODMAN run -d --name $DBZ --network $NET -v $RD/cfg:/cfg:ro,U -v $RD/data:/data:U -v \$C/plugins:/plugins:ro,Z \
  -v \$C/cp:/extra:ro,Z -e CLASSPATH=/extra/zerobus-sink.jar --entrypoint /opt/kafka/bin/connect-standalone.sh $CONNECT_IMAGE \
  /cfg/worker.properties $(for i in $(seq 1 "$NSRC"); do printf '/cfg/connector%s.properties ' "$i"; done)>/dev/null" || { echo "Kafka Connect start failed"; exit 2; }
fi

# --- checks -----------------------------------------------------------------------------------------------------------
# have: the change log's rows per destination (source and table) and operation
have() { q "SELECT destination, operation, COUNT(*) FROM $LOGQ GROUP BY 1, 2 ORDER BY 1, 2" 2>/dev/null; }
short() { # short <round><part>: the destinations and operations with fewer events than every source's manifest expects
  have > "$W/have.tsv"
  for i in $(seq 1 "$NSRC"); do DP=${DESTP[$i]} yq -p json -oy -r '.expect | to_entries[] | .key as $t | .value | to_entries[]
    | select(.value > 0) | [strenv(DP) + "." + $t, .key, .value] | @tsv' "$W/m$1-$i.json"; done \
    | awk -F'\t' 'NR == FNR {h[$1 FS $2] = $3; next} (h[$1 FS $2] + 0) < $3 {printf "%s %s %d of %d; ", $1, $2, h[$1 FS $2], $3}' "$W/have.tsv" -; }
expect() { # expect <round><part>: "ok <seconds>" once every expected event is in the log, or the shortfalls after WAIT
  local t0=$SECONDS r; while :; do r=$(short "$1"); [ -z "$r" ] && { echo "ok $((SECONDS - t0))"; return; }
    [ $((SECONDS - t0)) -ge "$WAIT" ] && { echo "$r"; return; }; sleep 5; done; }
probe() { # probe <condition>: wait until the log has a row matching it; "ok" or nothing
  local t0=$SECONDS; until [ "$(q "SELECT COUNT(*) FROM $LOGQ WHERE $1" 2>/dev/null)" -ge 1 ] 2>/dev/null; do
    [ $((SECONDS - t0)) -ge "$WAIT" ] && return; sleep 5; done; echo ok; }
expected() { echo "$(yq -p json -o json -I0 '.expect' "$W/m$1-1.json" | tr -d '"' | cut -c1-400) in each of $NSRC source(s)"; }
round() { # round <n> [after]: model-sql.py's changes for round n on every source; manifests in $W/m<n><part>-<i>.json
  local part=${2:-before} i
  for i in $(seq 1 "$NSRC"); do use "$i"
    msql round "$1" --part "$part" --state "$W/state-$i.tsv" --manifest "$W/m$1$part-$i.json" > "$W/r$1$part-$i.sql" \
      && src >/dev/null < "$W/r$1$part-$i.sql" || claim "workload-$1${2:+-$2}" FAIL "the round's changes failed on $SRC_NAME, $SRC_DB"
  done; use 1; }
probes() { # probes <round><part>: every source's probe for that part (its own destinations), "ok" when all arrived
  local i p r=ok; for i in $(seq 1 "$NSRC"); do p=$(yq -p json -oy -r '.probe' "$W/m$1-$i.json")
    [ "$(probe "($p) AND destination LIKE '${DESTP[$i]}.%'")" = ok ] || r=; done; echo $r; }
sleep 30   # let the change feed start
R=$(q "SELECT COUNT(*) FROM $LOGQ WHERE operation = 'read'" 2>/dev/null)
[ "$R" = 0 ] && claim no-snapshot-events PASS "no read events: the snapshot stays out of the log (feed starts at T=$T_HLC)" \
  || claim no-snapshot-events FAIL "read events in the log: ${R:-query failed}"

# round 1, from model-sql.py: per table with a key, 3 inserts of new keys, 1 update, 1 delete (of an inserted row); a
# table without a key gets 2 inserts
round 1; r=$(expect 1before)
case $r in ok*) claim changes-1 PASS "every table's changes arrive as create/update/delete events (within ${r#ok }s): $(expected 1before)";;
  *) claim changes-1 FAIL "fewer events than expected: $r";; esac
R=$(q "SELECT TO_JSON(key), value:after IS NULL OR value:after::STRING = 'null', value:ts_ns::STRING FROM $LOGQ WHERE destination LIKE '%.$NODEDUP' AND operation = 'delete' LIMIT 3" 2>&1 | tr '\t\n' ' ')
observe delete-event "$NODEDUP delete (key, after is null, ts_ns): $R"
R=$(q "SELECT TO_JSON(value:after), value:before IS NULL FROM $LOGQ WHERE destination LIKE '%.$NODEDUP' AND operation = 'update' LIMIT 1" 2>&1 | tr '\t\n' ' ' | cut -c1-300)
observe update-event "$NODEDUP update (after, before is null with include.diff=false): $R"
observe commit-time "events, distinct source.ts_hlc, distinct source.ts_ns, distinct ts_ns, distinct source.lsn, distinct source.ts_ms: $(q "SELECT COUNT(*), COUNT(DISTINCT value:source:ts_hlc::STRING), COUNT(DISTINCT value:source:ts_ns::STRING), COUNT(DISTINCT value:ts_ns::STRING), COUNT(DISTINCT value:source:lsn::STRING), COUNT(DISTINCT value:source:ts_ms::STRING) FROM $LOGQ" 2>&1 | tr '\t' ' ')"
observe variant-paths "value top-level keys: $(q "SELECT CONCAT_WS(',', SORT_ARRAY(MAP_KEYS(FROM_JSON(TO_JSON(value), 'MAP<STRING,STRING>')))) FROM $LOGQ LIMIT 1" 2>&1 | cut -c1-200)"
observe event-bytes "per event, average bytes (op: total value after source key position headers): $(q "SELECT operation, ROUND(AVG(LENGTH(TO_JSON(value)) + LENGTH(TO_JSON(key)) + LENGTH(COALESCE(TO_JSON(source_position),'')) + LENGTH(COALESCE(TO_JSON(headers),'')) + LENGTH(idempotency_key))), ROUND(AVG(LENGTH(TO_JSON(value)))), ROUND(AVG(LENGTH(TO_JSON(value:after)))), ROUND(AVG(LENGTH(TO_JSON(value:source)))), ROUND(AVG(LENGTH(TO_JSON(key)))), ROUND(AVG(LENGTH(COALESCE(TO_JSON(source_position),'')))), ROUND(AVG(LENGTH(COALESCE(TO_JSON(headers),'')))) FROM $LOGQ GROUP BY operation ORDER BY 1" 2>&1 | tr '\t\n' ' ;')"
observe event-sample "one update event value: $(q "SELECT TO_JSON(value) FROM $LOGQ WHERE operation = 'update' LIMIT 1" 2>&1 | cut -c1-400)"
observe change-log "rows by table and operation: $(have | tr '\t\n' '= ' | cut -c1-400); clustering: $(q "DESCRIBE DETAIL $LOG" 2>/dev/null | head -1 | grep -o 'destination' | head -1)"

# --- phase 2: snapshot in a Volume, schema through a UC connection, silver ---------------------------------------------
if [ "$PHASE" -ge 2 ]; then
  VOL=/Volumes/$CATALOG/$S/snapshot
  q "CREATE VOLUME $T.snapshot COMMENT 'Snapshot as of T, one folder per source table, then one per source'" >/dev/null || exit 2
  link "volume $CATALOG.$S.snapshot" "$HOST/explore/data/volumes/$CATALOG/$S/snapshot"
  dbx fs cp -r "$W/snap" "dbfs:$VOL" --overwrite >/dev/null || { echo "snapshot upload failed"; exit 2; }
  F=$(for t in $TABLES; do for i in $(seq 1 "$NSRC"); do printf '%s/%s=%s ' "$t" "${DESTP[$i]}" "$(dbx fs ls "dbfs:$VOL/$t/${DESTP[$i]}" -o json | SNAP_FMT=$SNAP_FMT yq '[.[] | select(.name | test(strenv(SNAP_FMT) + "$"))] | length')"; done; done)
  echo "$F" | grep -q '=0' && claim snapshot-in-volume FAIL "$SNAP_FMT files per table and source: $F" \
    || claim snapshot-in-volume PASS "the tables as of T ($([ "$SOURCE" = crdb ] && echo 'EXPORT INTO PARQUET ... AS OF SYSTEM TIME' || echo 'COPY ... CSV under yb_read_time')), into $VOL/<table>/<source>/: $SNAP_FMT files: $F"
  # the sources silver merges: each one's destination prefix, T (its snapshot's sequence) and snapshot format
  { echo "# the sources feeding this silver (debezium-zerobus.sh run $E): destination = <prefix>.<table>"
    echo "source_key: $([ "$NSRC" -gt 1 ] && echo true || echo false)"; echo "sources:"
    for i in $(seq 1 "$NSRC"); do printf '  - {prefix: "%s", t_ns: %s, format: %s, database: "%s"}\n' "${DESTP[$i]}" "${SNAPSEQ[$i]}" "$SNAP_FMT" "${SDB[$i]}"; done
  } > "$W/_sources.yaml"
  dbx fs cp "$W/_sources.yaml" "dbfs:$VOL/_sources.yaml" --overwrite >/dev/null || { echo "sources upload failed"; exit 2; }

  if [ "$SCHEMA_VIA" = volume ]; then
  claim schema-in-volume PASS "statschema schema.yaml (ddl-to-schema.py from each source's DDL, then schema-union.py) for $VOL/_schema: $(awk -F'\t' '{c[$1]=c[$1] (c[$1]?", ":"") $3 " " $4 ($5==1?" key":"")} END {for (t in c) printf "%s (%s); ", t, c[t]}' "$W/schema.tsv")"
  else
  # the schema: columns, types and primary keys from each source's information_schema, through a UC connection
  CONN=$PREFIX-$SOURCE-dbz-$E; export CONN VM_IP SRC_PORT
  [ "$SOURCE" = crdb ] && { export DB_USER=root DB_PASS=unused-insecure-node; } || { export DB_USER=yugabyte DB_PASS=yugabyte; }
  yq -n -o json '.name = strenv(CONN) | .connection_type = "POSTGRESQL" |
    .options = {"host": strenv(VM_IP), "port": strenv(SRC_PORT), "user": strenv(DB_USER), "password": strenv(DB_PASS)}' > "$W/conn.json"
  dbx connections create --json @"$W/conn.json" >/dev/null || { echo "connection create failed"; exit 2; }
  link "connection $CONN" "$HOST/explore/connections/$CONN"
  # the current source's: table, ordinal, column, Databricks type, 1 when in the primary key, default; then canonical
  fetch_one() { q "SELECT table_name, ordinal_position, column_name,
       CASE data_type WHEN 'bigint' THEN 'BIGINT' WHEN 'integer' THEN 'INT' WHEN 'smallint' THEN 'SMALLINT'
         WHEN 'numeric' THEN CONCAT('DECIMAL(', numeric_precision, ',', numeric_scale, ')') WHEN 'boolean' THEN 'BOOLEAN'
         WHEN 'double precision' THEN 'DOUBLE' WHEN 'real' THEN 'FLOAT' WHEN 'date' THEN 'DATE'
         WHEN 'timestamp without time zone' THEN 'TIMESTAMP_NTZ' WHEN 'timestamp with time zone' THEN 'TIMESTAMP'
         WHEN 'character' THEN 'CHAR' ELSE 'STRING' END, in_pk,
       COALESCE(CASE WHEN LEFT(column_default, 1) = CHR(39) OR column_default RLIKE '^-?[0-9.]+(:::?[A-Za-z ]+)?\$'
                     THEN REGEXP_REPLACE(column_default, ':::?[A-Za-z ]+\$', '') END, '')
     FROM remote_query('$CONN', database => '$SRC_DB', query => \"
       SELECT c.table_name, c.ordinal_position, c.column_name, c.data_type, c.numeric_precision, c.numeric_scale,
              CASE WHEN k.column_name IS NULL THEN 0 ELSE 1 END AS in_pk, c.column_default
       FROM information_schema.columns c
       LEFT JOIN information_schema.table_constraints tc
         ON tc.table_schema = c.table_schema AND tc.table_name = c.table_name AND tc.constraint_type = 'PRIMARY KEY'
       LEFT JOIN information_schema.key_column_usage k
         ON k.constraint_schema = tc.constraint_schema AND k.constraint_name = tc.constraint_name AND k.column_name = c.column_name
       WHERE c.table_schema = '$SRC_SCHEMA' AND c.table_name IN ($(for t in $TABLES; do printf "'%s'," "$t"; done | sed 's/,$//'))$([ "$SOURCE" = crdb ] && echo " AND c.is_hidden = 'NO'")\")
     ORDER BY 1, 2" > "$W/schema-$I.tsv" 2>"$W/schema.err" && [ -s "$W/schema-$I.tsv" ] \
     && python3 -I "$HERE/schema-tsv-to-canonical.py" "$W/schema-$I.tsv" "$SRC_NAME $SRC_VERSION, $SRC_DB's information_schema through the UC connection $CONN" > "$W/schema-$I.yaml"; }
  if schemas; then
    claim schema-from-connection PASS "remote_query on a POSTGRESQL connection, each source, then schema-union.py: $(awk -F'\t' '{c[$1]=c[$1] (c[$1]?", ":"") $3 " " $4 ($5==1?" key":"")} END {for (t in c) printf "%s (%s); ", t, c[t]}' "$W/schema.tsv")"
  else claim schema-from-connection FAIL "$(cut -c1-300 "$W/schema.err")"; exit 1; fi
  fi

  # silver: one generator for every source, model and bronze layout, silver-from-schema.py, which reads the canonical
  # schema from the volume (_schema/, written by trace below) and the sources (_sources.yaml) when the pipeline starts
  # gold: the model's materialized view, models/<MODEL>-gold.sql: its header lines (-- name:, -- cluster_by:, -- comment:)
  # and a query on the model's tables, unqualified; the same query runs on the source for the check. With several
  # sources the view is models/<MODEL>-gold-multi.sql (the same, by _source too), checked against the single-source
  # query on each source, its rows prefixed with that source. No file, no gold.
  GOLD=; GOLD_MV=$GOLD_FILE; [ "$NSRC" -gt 1 ] && { GOLD_MV=${GOLD_FILE%.sql}-multi.sql; [ -f "$GOLD_MV" ] || GOLD_MV=; }
  [ "$PHASE" -ge 3 ] && [ -n "$GOLD_MV" ] && GOLD=$(sed -n 's/^-- name: *//p' "$GOLD_MV")
  if [ -n "$GOLD" ]; then
    GOLD_Q=$(grep -v '^--' "$GOLD_FILE" | sed 's/;[[:space:]]*$//'); GC=$(sed -n 's/^-- cluster_by: *//p' "$GOLD_MV")
    printf 'CREATE OR REFRESH MATERIALIZED VIEW %s%s\n  COMMENT %s\nAS %s;\n' "$GOLD" "${GC:+ CLUSTER BY ($GC)}" \
      "'$(sed -n 's/^-- comment: *//p' "$GOLD_MV" | sed "s/'/''/g")'" "$(grep -v '^--' "$GOLD_MV" | sed 's/;[[:space:]]*$//')" > "$W/gold.sql"
  fi
  WSDIR=/Users/$ME/${SOURCE}_dbz_$E; LIBS=silver-from-schema.py; cp "$HERE/silver-from-schema.py" "$HERE/fanout.py" "$W/"
  [ -n "$GOLD" ] && LIBS="$LIBS gold.sql"
  FILES="$LIBS fanout.py"   # fanout.py: for BRONZE=fanout, and for a table moved out of the shared log
  dbx workspace mkdirs "$WSDIR" || exit 2
  link "pipeline source folder $WSDIR" "$HOST/#workspace$WSDIR"
  for f in $FILES; do dbx workspace import "$WSDIR/$f" --file "$W/$f" --format RAW >/dev/null || { echo "$f upload failed"; exit 2; }; done
  # trace <step>: for full traceability, the volume holds, next to the snapshot, the canonical schema the views were built
  # from (statschema's schema.yaml, lfc-source-statschema; checked with its validate.py), each source's, and the
  # pipeline files: _schema/schema-at-T.yaml, _schema/schema.yaml (the current union), _schema/tables/<table>.yaml (a
  # table evolved on its own, which silver reads over schema.yaml), _schema/sources/<prefix>/schema.yaml,
  # _schema/history/<step>-schema.yaml, and _pipeline/<step>/<files>. Called at T and after each evolution.
  trace() {
    local step=$1 ok=yes i f
    (cd "$STATSCHEMA/.." && uv run -q scripts/validate.py "$W/schema.yaml" $(for i in $(seq 1 "$NSRC"); do echo "$W/schema-$i.yaml"; done) \
      $(ls "$W"/changed/*.yaml 2>/dev/null)) > "$W/validate.out" 2>&1 || ok=no
    # fs cp into a volume doesn't create missing parent folders
    for f in _schema/history _schema/tables "_pipeline/$step"; do dbx fs mkdir "dbfs:$VOL/$f" >/dev/null 2>&1; done
    [ "$step" = 1-at-T ] && { dbx fs cp "$W/schema.yaml" "dbfs:$VOL/_schema/schema-at-T.yaml" --overwrite >/dev/null || ok=no; }
    dbx fs cp "$W/schema.yaml" "dbfs:$VOL/_schema/schema.yaml" --overwrite >/dev/null || ok=no
    dbx fs cp "$W/schema.yaml" "dbfs:$VOL/_schema/history/$step-schema.yaml" --overwrite >/dev/null || ok=no
    for f in "$W"/changed/*.yaml; do [ -f "$f" ] && { dbx fs cp "$f" "dbfs:$VOL/_schema/tables/$(basename "$f")" --overwrite >/dev/null || ok=no; }; done
    for i in $(seq 1 "$NSRC"); do dbx fs mkdir "dbfs:$VOL/_schema/sources/${DESTP[$i]}" >/dev/null 2>&1
      dbx fs cp "$W/schema-$i.yaml" "dbfs:$VOL/_schema/sources/${DESTP[$i]}/schema.yaml" --overwrite >/dev/null || ok=no; done
    for f in $FILES; do dbx fs cp "$W/$f" "dbfs:$VOL/_pipeline/$step/$f" --overwrite >/dev/null || ok=no; done
    [ $ok = yes ] && claim "trace-$step" PASS "in $VOL: the canonical schema ($(grep -m1 '/schema.yaml: ' "$W/validate.out" | sed 's/^.*schema.yaml: //'), statschema's validate.py), each source's, $(ls "$W"/changed/*.yaml 2>/dev/null | wc -l | tr -d ' ') evolved table(s), and the pipeline files ($FILES) at step $step" \
      || claim "trace-$step" FAIL "schema or pipeline files not written to the volume: $(tail -2 "$W/validate.out" | tr '\n' ' ' | cut -c1-200)"
  }
  trace 1-at-T
  link "canonical schema and pipeline files (folders _schema, _pipeline)" "$HOST/explore/data/volumes/$CATALOG/$S/snapshot"
  # the bronze table each silver table reads: the shared log, the producers' per-table logs, or fanout.py's
  case $BRONZE in shared) BT=cdc_log;; per-table) BT='cdc_log_{table}';;
    fanout) BT=$([ "$BRONZE_SHARDS" -gt 0 ] && echo 'cdc_log_s{shard}' || echo 'cdc_log_{table}');; esac
  export VOL SINK NODEDUP BT ON_DRIFT; export SHARDS=$([ "$BRONZE_SHARDS" -gt 0 ] && echo "$BRONZE_SHARDS" || echo 1)
  export WSDIR CATALOG S PIPE_NAME=$PREFIX-$SOURCE-$MODEL-dbz-silver-$E LIBS
  yq -n -o json '.name = strenv(PIPE_NAME) | .catalog = strenv(CATALOG) | .schema = strenv(S) | .serverless = true |
    .continuous = false | .development = true | .channel = "CURRENT" |
    .libraries = [strenv(LIBS) | split(" ") | .[] | {"file": {"path": strenv(WSDIR) + "/" + .}}] |
    .configuration = {"cdc.volume": strenv(VOL), "cdc.bronze": strenv(SINK), "cdc.bronze_table": strenv(BT),
      "cdc.bronze_shards": strenv(SHARDS), "cdc.nodedup_table": strenv(NODEDUP), "cdc.on_drift": strenv(ON_DRIFT)}' > "$W/pipe.json"
  PIPELINE_ID=$(dbx pipelines create --json @"$W/pipe.json" -o json | yq '.pipeline_id') || { echo "pipeline create failed"; exit 2; }
  link "pipeline $PIPE_NAME (silver${GOLD:+, gold}; bronze $BT)" "$HOST/pipelines/$PIPELINE_ID"
  for t in $TABLES; do link "silver $t" "$HOST/explore/data/$CATALOG/$S/$t"; done
  [ -n "$GOLD" ] && link "gold $GOLD" "$HOST/explore/data/$CATALOG/$S/$GOLD"
  [ "$ON_DRIFT" = record ] && link "schema drift schema_drift" "$HOST/explore/data/$CATALOG/$S/schema_drift"
  make_fanout() { # make_fanout <target> <checkpoint> [tables]: fanout.py as a serverless job (one read of cdc_log, written
    # per table, per shard, or for the tables given only), run before each silver update; sets JOB_ID
    export JOB_NAME=$PREFIX-$SOURCE-$MODEL-dbz-fanout-$E FPY=$WSDIR/fanout.py FSRC="$T.cdc_log" FTGT=$1 FCP=$2 FTB=${3:-}
    yq -n -o json '.name = strenv(JOB_NAME) | .environments = [{"environment_key": "default", "spec": {"client": "2"}}] |
      .tasks = [{"task_key": "fanout", "environment_key": "default", "spark_python_task": {"python_file": strenv(FPY),
        "parameters": ["--source", strenv(FSRC), "--target", strenv(FTGT), "--shards", strenv(SHARDS), "--checkpoint", strenv(FCP), "--once"]
          + (strenv(FTB) | select(. != "") | ["--tables", .]) // []}}]' > "$W/job.json"
    JOB_ID=$(dbx jobs create --json @"$W/job.json" -o json | yq '.job_id') || return 1
    link "fan-out job $JOB_NAME (${3:+tables $3 }to $1)" "$HOST/jobs/$JOB_ID"; }
  [ "$BRONZE" = fanout ] && { make_fanout "$T.$BT" "$VOL/_fanout" || { echo "fan-out job create failed"; exit 2; }; }
  run_fanout() { # the fan-out job, when there is one, once over what's in cdc_log; prints its result
    [ -n "${JOB_ID:-}" ] || return 0
    dbx jobs run-now "$JOB_ID" -o json 2>"$W/fanout.err" | yq '.state.result_state // "FAILED"'; }

  run_silver() { # one pipeline update (extra args go to start-update), after the fan-out when there is one; its final state
    local u st f; f=$(run_fanout); [ -n "$f" ] && [ "$f" != SUCCESS ] && { echo "fan-out $f: $(tail -c 300 "$W/fanout.err")" >&2; echo "FANOUT_$f"; return; }
    u=$(dbx pipelines start-update "$PIPELINE_ID" "$@" -o json | yq '.update_id'); echo "$u" > "$W/update_id"
    for _ in $(seq 1 120); do
      st=$(dbx pipelines get-update "$PIPELINE_ID" "$u" -o json | yq '.update.state')
      case $st in COMPLETED|FAILED|CANCELED) break;; esac; sleep 10; done
    [ "$st" = COMPLETED ] || dbx pipelines list-pipeline-events "$PIPELINE_ID" --max-results 50 -o json \
      | yq -r '.[] | select(.level == "ERROR") | .message' | head -3 | cut -c1-300 >&2
    echo "$st"
  }
  # rows_src <table> / rows_dbx <table> [where]: the current source's rows of the table, on the source and in silver
  # (its _source rows), rendered alike by model-sql.py from that source's own schema, sorted as text (the two sides'
  # collations differ). Silver may have more columns (the union's); only the source's are compared.
  rows_src() { msel "$1" --side source --prefix "$SRC_DB" | src | tail -n +2 | LC_ALL=C sort; }
  rows_dbx() { local t=$1 from=${2:-$1} w=${3:-}; q "$(msel "$t" --side databricks --prefix "$T" --from "$from" --where "_source = '$DEST_PREFIX'${w:+ AND $w}")" | LC_ALL=C sort; }
  differ() { diff <(echo "$1") <(echo "$2") | grep '^[<>]' | tr '\t\n' ', ' | cut -c1-300; }
  # each check runs per source and makes one claim: PASS when every source's rows equal
  each() { # each <claim> <what> <compare function> <table> [args]: the comparison on every source
    local name=$1 what=$2 fn=$3 i r bad='' counts=''; shift 3
    for i in $(seq 1 "$NSRC"); do use "$i"; r=$("$fn" "$@") && counts="$counts${counts:+, }$SRC_DB $r" || { bad="$SRC_DB: $r"; break; }; done; use 1
    [ -z "$bad" ] && claim "$name" PASS "$what: $counts" || claim "$name" FAIL "$bad"; }
  cmp_rows() { local a b; a=$(rows_src "$1"); b=$(rows_dbx "$1" "${2:-$1}" "${3:-}"); [ "$a" = "$b" ] && echo "$(echo "$a" | grep -c .) rows" || { differ "$a" "$b"; return 1; }; }
  same_hist() { # same_hist <table> <round>: the history table's current versions equal the source
    keyed "$1" || return 0
    each "history-current-$1-$2" "the current versions in $1_history equal the source" cmp_rows "$1" "${1}_history" '__END_AT IS NULL'; }
  cmp_hist() { # every version of one source's keys, against that source's own history from T (feed-<i>.tsv)
    snap_select "$1" | src > "$W/snap-$I-$1.tsv"
    q "$(msel "$1" --side databricks --prefix "$T" --from "$2" --where "_source = '$DEST_PREFIX'" --order __START_AT)" > "$W/hist-$I-$2.tsv"
    python3 -I "$CHECK" "$W/schema-$I.tsv" "$1" "$W/snap-$I-$1.tsv" "$W/feed-$I.tsv" "$W/hist-$I-$2.tsv" 2>&1; }
  history() { # history <table> <history table> <claim|observe>: every version, against the source's own history from T
    keyed "$1" || return 0
    if [ "$3" = observe ]; then use 1; observe "history-$2" "versions expected, in silver, keys that differ ($SRC_DB): $(cmp_hist "$1" "$2")"
    else each "history-$2" "every version equals the source's changefeed (expected, in silver, keys that differ)" cmp_hist "$1" "$2"; fi; }
  same() { # same <table> <round> [observe]: silver equals the source, row by row (a table without a key: as a multiset)
    if [ "${3:-}" = observe ]; then use 1; observe "silver-$1-$2" "source vs silver ($SRC_DB): $(cmp_rows "$1" || true)"
    else each "silver-$1-$2" "silver $1 equals the source" cmp_rows "$1"; fi; }

  gold() { # gold <round>: the materialized view equals the same query on the source (on each, prefixed with it)
    [ -n "$GOLD" ] || return 0
    local a b i; a=$(if [ "$NSRC" = 1 ]; then echo "$GOLD_Q;" | srcq | tail -n +2
      else for i in $(seq 1 "$NSRC"); do use "$i"; echo "$GOLD_Q;" | srcq | tail -n +2 | sed "s/^/$DEST_PREFIX\t/"; done; use 1; fi | LC_ALL=C sort)
    b=$(q "SELECT * FROM $T.$GOLD" | LC_ALL=C sort)
    if [ "$a" = "$b" ]; then claim "gold-$1" PASS "$GOLD equals the query on the source(s): $(echo "$a" | grep -c .) rows"
    else claim "gold-$1" FAIL "source vs gold: $(differ "$a" "$b")"; fi
  }
  refresh() { # how the last update refreshed the view: the chosen technique, from the pipeline's event log
    q "SELECT CONCAT(details:planning_information:incrementalization_status::STRING, ' ', CONCAT_WS(',', TRANSFORM(FILTER(
        FROM_JSON(details:planning_information:technique_information::STRING, 'ARRAY<STRUCT<maintenance_type STRING, is_chosen BOOLEAN>>'),
        x -> x.is_chosen), x -> x.maintenance_type)))
      FROM event_log('$PIPELINE_ID') WHERE event_type = 'planning_information' AND origin.update_id = '$(cat "$W/update_id")'" 2>&1 | tr '\n' ' '
  }
  [ -z "$GOLD" ] && [ "$PHASE" -ge 3 ] && observe gold "no models/$MODEL-gold$([ "$NSRC" -gt 1 ] && echo -multi).sql: no gold for this model"
  refresh_tables() { # the tables a full refresh of these source tables covers, as a JSON list
    local t; for t in "$@"; do printf '"%s", "%s_history"%s, ' "$t" "$t" "$([ "$t" = "$NODEDUP" ] && echo ", \"${t}_history_nodedup\"")"; done | sed 's/, $//'; }
  drift_rows() { # drift_rows <table> <source>: what silver recorded for it, as "kind:column" lines
    q "SELECT CONCAT(kind, ':', col) FROM $T.schema_drift WHERE tbl = '$1' AND _source = '$2' ORDER BY 1" 2>/dev/null; }
  evolve() { # evolve <round> <table> <source i> <expected kind:column ...>: asynchronous schema evolution
    # 1. silver went on with the old schema and recorded the drift; 2. every source's schema again, and their union:
    # the tables whose union changed get their own _schema/tables/<table>.yaml; 3. a full refresh of only those, which
    # replays them from the append-only change log, then a plain update (the others never stopped)
    local n=$1 tbl=$2 i=$3 st d k miss=; shift 3
    st=$(run_silver 2>"$W/err$n")
    if [ "$ON_DRIFT" = record ]; then
      [ "$st" = COMPLETED ] && claim "drift-flows-on-$n" PASS "silver keeps flowing on the old schema after the source's change: update $st" \
        || claim "drift-flows-on-$n" FAIL "update with the old schema: $st $(cut -c1-200 "$W/err$n" | tr '\n' ' ')"
      d=$(drift_rows "$tbl" "${DESTP[$i]}" | tr '\n' ' ')
      for k in "$@"; do case " $d" in *" $k "*) ;; *) miss="$miss $k";; esac; done
      [ -z "$miss" ] && claim "drift-recorded-$n" PASS "schema_drift has, for $tbl from ${DESTP[$i]}: $d" \
        || claim "drift-recorded-$n" FAIL "missing from schema_drift for $tbl from ${DESTP[$i]}:$miss (has: ${d:-nothing})"
    else
      observe "schema-change-old-flow-$n" "update with the old flow: $st; $(q "SELECT REGEXP_EXTRACT(error.exceptions[0].message, '\\[(INVALID_[A-Z_]+|[A-Z_]+CAST[A-Z_]*)\\][^\\n]*', 0) FROM event_log('$PIPELINE_ID') WHERE event_type = 'flow_progress' AND origin.flow_name LIKE '%.${tbl}_from_changes' AND error IS NOT NULL ORDER BY timestamp DESC LIMIT 1" 2>&1 | cut -c1-300)"
    fi
    schemas evolve || { claim "evolve-$n" FAIL "the schemas didn't come through again: $(head -c 300 "$W/schema.err")"; return; }
    local changed; changed=$(tr '\n' ' ' < "$W/changed.txt" | sed 's/ $//')
    case " $changed " in *" $tbl "*) claim "evolve-$n" PASS "schema-union.py over the $NSRC source(s): only $changed changed, written to _schema/tables/; $tbl now: $(awk -F'\t' -v t="$tbl" '$1==t {printf "%s%s %s", (n++?", ":""), $3, $4}' "$W/schema.tsv")";;
      *) claim "evolve-$n" FAIL "the union didn't change $tbl (changed: ${changed:-none})";; esac
    trace "$((n - 2))-round-$n"
    [ -n "$changed" ] && { st=$(run_silver --json "{\"full_refresh_selection\": [$(refresh_tables $changed)]}" 2>"$W/err${n}b")
      [ "$st" = COMPLETED ] || claim "silver-full-refresh-$n" FAIL "full refresh of $changed: $st $(cut -c1-300 "$W/err${n}b" | tr '\n' ' ')"; }
    # an update with full_refresh_selection runs only the selected tables: a plain update brings the rest and gold along
    st=$(run_silver); [ "$st" = COMPLETED ] || claim "silver-update-$n" FAIL "plain update after the full refresh: $st"
  }

  st=$(run_silver); [ "$st" = COMPLETED ] || claim silver-update-1 FAIL "pipeline update: $st"
  for t in $TABLES; do same "$t" 1; done
  gold 1
  [ -n "$GOLD" ] && observe gold-refresh-1 "update 1: $(refresh)"

  # round 2: two updates of one key, a delete and reinsert of one key, a reinsert of a key deleted in round 1
  round 2; r=$(expect 2before)
  case $r in ok*) claim changes-2 PASS "round 2's changes in the log (within ${r#ok }s): $(expected 2before)";;
    *) claim changes-2 FAIL "fewer events than expected: $r";; esac
  st=$(run_silver); [ "$st" = COMPLETED ] || claim silver-update-2 FAIL "pipeline update: $st"
  for t in $TABLES; do same "$t" 2; done
  gold 2
  [ -n "$GOLD" ] && observe gold-refresh-2 "update 2, after round 2: $(refresh)"
  [ "$PHASE" -ge 3 ] && observe clustering "clustering columns: $(for t in $TABLES $GOLD; do printf '%s %s; ' "$t" "$(q "DESCRIBE TABLE EXTENDED $T.$t" 2>/dev/null | grep -o -E 'clusteringColumns=\[\[[^]]*\]\]' | head -1)"; done | cut -c1-600)"
  if [ "$PHASE" -ge 3 ]; then
    # round 3, retries: changes, then every producer killed (SIGKILL, no offset flush) and started again, then one more change
    N0=$(q "SELECT COUNT(*) FROM $LOGQ")
    round 3; r=$(expect 3before)
    case $r in ok*) ;; *) claim changes-3 FAIL "fewer events than expected before the restart: $r";; esac
    vm "$PODMAN kill $DBZS >/dev/null && $PODMAN start $DBZS >/dev/null" || claim retry-restart FAIL "producer restart failed"
    sleep 40
    round 3 after; N3=$(for i in $(seq 1 "$NSRC"); do yq -p json -oy '.events' "$W/m3before-$i.json" "$W/m3after-$i.json"; done | awk '{n += $1} END {print n}')
    r=$(probes 3after); sleep 10
    R=$(q "SELECT COUNT(*) - $N0, COUNT(*) - COUNT(DISTINCT idempotency_key), (SELECT COUNT(*) FROM (SELECT 1 FROM $LOGQ GROUP BY destination, TO_JSON(key), TO_JSON(value:after), operation HAVING COUNT(*) > 1)) FROM $LOGQ" 2>&1 | tr '\t' ' ')
    observe retry-bronze "after the kill and restart, rows added since round 3 began ($N3 changes), rows sharing an idempotency key, change contents seen more than once: $R"
    [ "$r" = ok ] && claim retry-stream-resumes PASS "a change after the restart reached bronze from every source" || claim retry-stream-resumes FAIL "no event for the change after the restart from some source"
    r=$(expect 3after); case $r in ok*) claim changes-3 PASS "round 3's changes, before and after the restart, in the log: $(expected 3after)";;
      *) claim changes-3 FAIL "fewer events than expected: $r";; esac
    st=$(run_silver); [ "$st" = COMPLETED ] || claim silver-update-3 FAIL "pipeline update: $st"
    for t in $TABLES; do same "$t" 3; done
    gold 3
    # each source's own history: its changefeed from T, with each row's commit time (`updated`), or its audit table
    for i in $(seq 1 "$NSRC"); do use "$i"
      if [ "$SOURCE" = crdb ]; then
        echo "EXPERIMENTAL CHANGEFEED FOR $(for t in $TABLES; do printf '%s."%s", ' "$SRC_DB" "$t"; done | sed 's/, $//') WITH updated, cursor = '$T_HLC';" \
          | vm "timeout ${FEED_SECONDS:-30} $PODMAN exec -i $SRCC cockroach sql --insecure --format=tsv" > "$W/feed-$i.tsv" 2>/dev/null
      else   # the audit table, in the changefeed's form: table, key, \x hex of {"after": row, "updated": commit order}
        echo "SELECT tbl, '', '\\x' || encode(convert_to(jsonb_build_object('after', row_data, 'updated', seq::TEXT)::TEXT, 'UTF8'), 'hex') FROM $SRC_DB.audit ORDER BY seq;" | src > "$W/feed-$i.tsv"
      fi
    done; use 1
    for t in $TABLES; do history "$t" "${t}_history" claim; same_hist "$t" 3; done
    history "$NODEDUP" "${NODEDUP}_history_nodedup" observe

    # a table moved out of the shared log while the others stay (BRONZE=shared, MOVE=1, the default there): the
    # fan-out for that table only, from the log's beginning, into cdc_log_<table>; silver's cdc.bronze_table.<table>
    # points at it; a full refresh of that table rebuilds it from there. The other tables don't stop.
    if [ "$BRONZE" = shared ] && [ "${MOVE:-1}" = 1 ]; then
      MV=${MOVE_TABLE:-$NODEDUP}
      make_fanout "$T.cdc_log_{table}" "$VOL/_fanout_move" "$MV" || claim "move-$MV" FAIL "fan-out job create failed"
      MVKEY="cdc.bronze_table.$MV" yq -i -p json -o json '.configuration[strenv(MVKEY)] = "cdc_log_{table}"' "$W/pipe.json"
      dbx pipelines update "$PIPELINE_ID" --json @"$W/pipe.json" >/dev/null 2>"$W/move.err" || claim "move-$MV" FAIL "pipeline update failed: $(head -c 300 "$W/move.err")"
      st=$(run_silver --json "{\"full_refresh_selection\": [$(refresh_tables "$MV")]}" 2>"$W/err-move")
      a=$(q "SELECT COUNT(*) FROM $LOGQ WHERE substring_index(destination, '.', -1) = '$MV'" 2>&1); b=$(q "SELECT COUNT(*) FROM $T.cdc_log_$MV" 2>&1)
      [ "$st" = COMPLETED ] && [ "$a" = "$b" ] && claim "move-$MV" PASS "$MV moved to its own bronze, cdc_log_$MV (fan-out --tables $MV, from the log's beginning: $b of $a events), and silver rebuilt from it by a full refresh of that table only" \
        || claim "move-$MV" FAIL "update $st; events in cdc_log $a, in cdc_log_$MV $b; $(cut -c1-200 "$W/err-move" | tr '\n' ' ')"
      link "moved table's bronze cdc_log_$MV" "$HOST/explore/data/$CATALOG/$S/cdc_log_$MV"
      st=$(run_silver); [ "$st" = COMPLETED ] || claim silver-update-move FAIL "plain update after the move: $st"
      for t in $TABLES; do same "$t" move; done
      same_hist "$MV" move
      gold move
    fi

    # round 4, schema drift on one host: a column added on source 1 only (model-sql.py: lfc_r4 on the first table with
    # a key), with a default, then a change that sets it
    use 1
    msql alter 4 --part ddl --manifest "$W/a4.json" | src >/dev/null || observe schema-add-ddl "the ALTER failed on $SRC_NAME"
    A4=$(yq -p json -oy -r '.table' "$W/a4.json"); C4=$(yq -p json -oy -r '.column' "$W/a4.json"); V4=$(yq -p json -oy -r '.value' "$W/a4.json")
    D4=$(yq -p json -oy -r '.default' "$W/a4.json"); P4="($(yq -p json -oy -r '.probe' "$W/a4.json")) AND destination LIKE '$DEST_PREFIX.%'"
    sleep 15
    msql alter 4 --part after | src >/dev/null
    r=$(probe "$P4")
    R=$(q "SELECT COUNT(*), COUNT_IF(value:after:$C4::STRING = '$D4') FROM $LOGQ WHERE destination = '$DEST_PREFIX.$A4' AND value:after:$C4 IS NOT NULL" 2>&1 | tr '\t' ' ')
    [ "$r" = ok ] && claim schema-new-column-bronze PASS "the added column reaches bronze with no Databricks DDL ($DEST_PREFIX.$A4 events with $C4, with $C4 = $D4 from a backfill): $R" \
      || claim schema-new-column-bronze FAIL "no event with $C4 = $V4: $R"
    observe schema-backfill-events "$A4 events by operation since the ALTER: $(q "SELECT operation, COUNT(*) FROM $LOGQ WHERE destination = '$DEST_PREFIX.$A4' AND value:after:$C4 IS NOT NULL GROUP BY 1" 2>&1 | tr '\t\n' '= ')"
    evolve 4 "$A4" 1 "new:$C4"
    [ "$NSRC" -gt 1 ] && use 2 && observe "silver-$A4-4-other-source" "${DESTP[2]}, without the column: $C4 in silver is its default for those rows: $(q "SELECT CONCAT_WS(',', COLLECT_SET(CAST($C4 AS STRING))) FROM $T.$A4 WHERE _source = '${DESTP[2]}'" 2>&1)"
    use 1
    for t in $TABLES; do same "$t" 4; same_hist "$t" 4; done
    gold 4

    # round 5 (model-sql.py's rule), schema drift on another host: a dropped column and a retyped one on source NSRC
    # only, then a value only the new type holds
    use "$NSRC"
    msql alter 5 --part ddl --manifest "$W/a5.json" ${GOLD_FILE:+--gold "$GOLD_FILE"} | src >/dev/null || observe schema-change-ddl "the ALTERs failed on $SRC_NAME"
    A5=$(yq -p json -oy -r '.table' "$W/a5.json"); X5=$(yq -p json -oy -r '.drop // ""' "$W/a5.json"); P5=$(yq -p json -oy -r '.probe' "$W/a5.json")
    C5=$(yq -p json -oy -r '.retype.column // ""' "$W/a5.json"); R5="$C5 $(yq -p json -oy -r '.retype.to // ""' "$W/a5.json")"
    sleep 15
    msql alter 5 --part after ${GOLD_FILE:+--gold "$GOLD_FILE"} | src >/dev/null
    [ "$P5" = true ] || probe "($P5) AND destination LIKE '$DEST_PREFIX.%'" >/dev/null
    observe schema-change-bronze "round 5 on $DEST_PREFIX.$A5: dropped ${X5:-nothing}, retyped ${R5% }; its events by operation and whether they have $X5: $([ -n "$X5" ] && q "SELECT CONCAT(operation, ' $X5=', value:after:$X5 IS NOT NULL), COUNT(*) FROM $LOGQ WHERE destination = '$DEST_PREFIX.$A5' GROUP BY 1" 2>&1 | tr '\t\n' '= '); the new value: $([ "$P5" = true ] && echo none || q "SELECT COUNT(*) FROM $LOGQ WHERE $P5" 2>&1)"
    # what drift silver should record: the new value doesn't fit the old type; the dropped column (when it has no
    # default) is missing from the rows
    K5=$([ -n "$C5" ] && echo "type:$C5")
    [ -n "$X5" ] && [ -z "$(DT="$A5" DC="$X5" yq -r '.tables[] | select(.name == strenv(DT)) | .columns[] | select(.name == strenv(DC)) | .default // ""' "$W/schema.yaml")" ] && K5="$K5 missing:$X5"
    evolve 5 "$A5" "$NSRC" $K5
    use 1
    for t in $TABLES; do same "$t" 5; same_hist "$t" 5; done
    gold 5
  fi
fi

# --- result -----------------------------------------------------------------------------------------------------------
{
  echo "# debezium-zerobus run $E ($SRC_NAME)"; echo
  echo "- Date (UTC): $(date -u +%F)"
  echo "- Source: $SRC_NAME $SRC_VERSION, image $SRC_IMAGE ($(vm "$PODMAN inspect -f '{{.ImageDigest}}' $SRCC"))"
  echo "- Sources: $NSRC database(s) on the one host ($(echo "${SDB[*]}" | tr ' ' ',')), merged by silver$([ "$NSRC" -gt 1 ] && echo ', keyed by _source'); bronze $BRONZE${BT:+ (silver reads $BT)}; schema drift: $ON_DRIFT"
  echo "- Model: $MODEL ($(basename "$(dirname "$MODEL_YAML")")/$(basename "$MODEL_YAML")) at SF $SF, filled by lfc-source-datagen's fill.py: $FILLED; gold: ${GOLD:-none}"
  if [ "$SINK" = kafka ]; then
    echo "- Producer: Kafka Connect standalone, $CONNECT_IMAGE ($(vm "$PODMAN inspect -f '{{.ImageDigest}}' $DBZ")), no broker; Yugabyte connector $(basename "$YB_CONNECTOR_URL" .jar | sed 's/-jar-with-dependencies//'), pgoutput on a logical replication slot; StringifyField; into Zerobus's Kafka-compatible endpoint (one change-log table, VARIANT value)"
  else
    echo "- Debezium: $DBZ_IMAGE ($(vm "$PODMAN inspect -f '{{.ImageDigest}}' $DBZ")), $([ "$SOURCE" = crdb ] && echo 'CockroachDB connector, sinkless changefeed' || echo 'PostgreSQL connector, pgoutput on a YugabyteDB logical replication slot'), Zerobus sink (envelope into one change-log table, VARIANT fields, idempotency source)"
  fi
  echo "- Host: $(vm '. /etc/os-release; echo $PRETTY_NAME'), $(vm 'podman --version')"
  echo "- Destination: Zerobus in $CLOUD $REGION, one append-only change-log Delta table, liquid-clustered by destination (the source table)"
  echo; echo "Created in Databricks ($([ "${KEEP:-0}" = 1 ] && echo 'kept, KEEP=1' || echo 'removed at the end of the run: rerun with KEEP=1 to inspect')):"; printf '%s\n' "${LINKS[@]}"
  echo; echo "| Claim | Result | Observation |"; echo "|---|---|---|"
  printf '%s\n' "${RESULTS[@]}"
} | tee "${OUT:-/dev/null}"
exit $FAILED
