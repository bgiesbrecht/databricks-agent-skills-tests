#!/usr/bin/env bash
# secondary.sh <command> [args]: run a Lakeflow Connect SQL Server CDC gateway on an Always On readable secondary,
# and move it to the primary for the steps that write to the source (schema change, full refresh), then back.
#
# Commands
#   log-delivery                 add cluster log delivery to $LOG_VOLUME to the gateway (saving it starts the gateway)
#   where                        connection host/port, gateway state, and the gateway's sessions on each node
#   switch primary|secondary     point the UC connection at that node, restart the gateway, wait until it runs
#   stop | start                 stop the gateway / start it and wait until it runs
#   full-refresh <table>...      start an ingestion update that fully refreshes these destination tables
#   ci <schema.table>            the table's capture-instance state from the source (tracker row + capture instances)
#   wait-ci <schema.table> [<ci>]  wait until no old capture instance is left, one capture instance, and (with
#                                <ci>) the current one is no longer <ci>: the ADD COLUMN merge or the reset is done
#   wait-reset <since-epoch>     wait for "Reinitialization completed successfully" after <since-epoch> (UTC seconds)
#                                in the gateway driver log delivered to $LOG_VOLUME
#   caught-up                    wait until the secondary has applied everything it received (redo queue 0)
#   ddl <schema.table> <file>    planned schema change: switch primary, run <file> on the primary, wait-ci,
#                                caught-up, switch secondary
#   recover <schema.table>       after an unplanned schema change (the table stopped updating): switch primary,
#                                wait-ci, caught-up, switch secondary
#   refresh <schema.table> <destination table>  full refresh with the snapshot read from the secondary: switch
#                                primary, full-refresh, wait-ci (+ wait-reset when $LOG_VOLUME is set), stop,
#                                caught-up, switch secondary
#
# Environment
#   GATEWAY_ID, PIPELINE_ID      gateway pipeline id, ingestion pipeline id
#   CONNECTION                   the UC connection the gateway uses
#   DATABASE                     the source database
#   PRIMARY, SECONDARY           <host>,<port> of each node, as the gateway reaches them
#   SQL_USER, SQL_PASSWORD       the connection's login (a connection update must repeat them); never printed
#   PRIMARY_SQL_CMD, SECONDARY_SQL_CMD  optional: a command that reads T-SQL on stdin and takes sqlcmd's -d/-h/-W/-s/-b
#                                flags (default: sqlcmd -C -S <node> with SQL_USER / SQL_PASSWORD)
#   LOG_VOLUME                   /Volumes/<catalog>/<schema>/<volume> for the gateway's cluster logs (optional)
#   DATABRICKS_CONFIG_PROFILE    CLI profile (optional); WAIT  seconds before a wait gives up (default 3600)
set -euo pipefail
WAIT=${WAIT:-3600}
need(){ local v; for v in "$@"; do [ -n "${!v:-}" ] || { echo "set $v" >&2; exit 2; }; done; }
log(){ echo "$(date -u +%H:%M:%SZ) $*" >&2; }
# Databricks CLI with retries on connection failures (DNS, TLS, reset, 429/5xx), backoff 5, 10, 20, 40 s.
# A request body on stdin (--json @/dev/stdin) is kept in a file so a retry sends it again.
dbx(){
  local a i rc body="" err out; local args=()
  for a in "$@"; do
    if [ "$a" = @/dev/stdin ]; then body=$(mktemp); cat > "$body"; args+=("@$body"); else args+=("$a"); fi
  done
  err=$(mktemp)
  for i in 1 2 3 4 5; do
    rc=0; out=$(databricks ${args[@]+"${args[@]}"} 2>"$err") || rc=$?
    if [ $rc -eq 0 ] || ! grep -qiE 'dial tcp|i/o timeout|connection (reset|refused)|TLS handshake|EOF|timed out|429|50[0234]|temporarily' "$err"; then break; fi
    [ $i -lt 5 ] && { log "retry $i: $(head -c 160 "$err")"; sleep $((5 * (1 << (i - 1)))); }
  done
  cat "$err" >&2; rm -f "$err" ${body:+"$body"}
  [ -n "$out" ] && printf '%s\n' "$out"
  return $rc
}

# --- source SQL -----------------------------------------------------------------------------------
sqlrun(){ # sqlrun primary|secondary: T-SQL on stdin -> rows, "|" separated, no header
  local node=$1 cmd
  if [ "$node" = primary ]; then cmd=${PRIMARY_SQL_CMD:-}; else cmd=${SECONDARY_SQL_CMD:-}; fi
  if [ -z "$cmd" ]; then
    need SQL_USER SQL_PASSWORD
    local srv; if [ "$node" = primary ]; then srv=$PRIMARY; else srv=$SECONDARY; fi
    SQLCMDPASSWORD=$SQL_PASSWORD sqlcmd -C -S "$srv" -U "$SQL_USER" -d "$DATABASE" -h -1 -W -s '|' -b
  else
    bash -c "$cmd \"\$@\"" sql-cmd -d "$DATABASE" -h -1 -W -s '|' -b
  fi
}
split_name(){ SCH=${1%%.*}; TBL=${1#*.}; [ "$SCH" != "$1" ] || SCH=dbo
  case "$SCH$TBL" in (*[!A-Za-z0-9_]*) echo "bad table name: $1" >&2; exit 2;; esac; }
ci(){ # ci <schema.table> [node]: "<old>|<current>|<capture instance count>" from the utility objects' tracker
  split_name "$1"
  sqlrun "${2:-primary}" <<SQL | grep '|' | head -1
SET NOCOUNT ON;
DECLARE @t sysname = (SELECT TOP 1 name FROM sys.tables WHERE schema_id = SCHEMA_ID('dbo')
                      AND name LIKE 'lakeflowCaptureInstanceInfo%' ORDER BY name DESC);
DECLARE @r TABLE (o sysname NULL, n sysname NULL);
IF @t IS NOT NULL INSERT @r EXEC (N'SELECT oldCaptureInstance, newCaptureInstance FROM dbo.' + @t
  + N' WHERE schemaName = ''$SCH'' AND tableName = ''$TBL''');
SELECT ISNULL((SELECT TOP 1 o FROM @r), 'NULL') + '|'
     + ISNULL((SELECT TOP 1 capture_instance FROM cdc.change_tables
               WHERE source_object_id = OBJECT_ID('[$SCH].[$TBL]') ORDER BY create_date DESC), 'NULL') + '|'
     + CAST((SELECT COUNT(*) FROM cdc.change_tables WHERE source_object_id = OBJECT_ID('[$SCH].[$TBL]')) AS varchar(10));
SQL
}
wait_ci(){ # wait_ci <schema.table> [<ci it must move away from>]
  local t=$1 from=${2:-} s last="" end=$((SECONDS + WAIT))
  while [ $SECONDS -lt $end ]; do
    s=$(ci "$t" primary || true)
    [ "$s" != "$last" ] && { log "$t capture instances (old|current|count): $s"; last=$s; }
    case "$s" in (NULL\|*\|1) [ -z "$from" ] || [ "${s#NULL|}" != "$from|1" ] && return 0;; esac
    sleep 10
  done; log "gave up after $WAIT s"; return 1
}
caught_up(){
  local s end=$((SECONDS + WAIT))
  while [ $SECONDS -lt $end ]; do
    s=$(sqlrun secondary <<'SQL' | grep '|' | head -1 || true
SET NOCOUNT ON;
SELECT synchronization_state_desc + '|' + CAST(ISNULL(log_send_queue_size, 0) AS varchar(20)) + '|'
     + CAST(ISNULL(redo_queue_size, 0) AS varchar(20))
FROM sys.dm_hadr_database_replica_states WHERE is_local = 1 AND database_id = DB_ID();
SQL
)
    log "secondary (state|log send queue KB|redo queue KB): ${s:-no AG state for $DATABASE}"
    case "$s" in (*\|0\|0) return 0;; esac
    sleep 10
  done; log "gave up after $WAIT s"; return 1
}
sessions(){ # where the gateway's sessions are (program_name lakeflow-connect-<mode>:<replication>)
  local node
  for node in primary secondary; do
    echo "$node: $(sqlrun $node <<'SQL' | grep '|' | head -1 || echo unreachable
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS varchar(10)) + ' gateway sessions|'
     + CAST(DATABASEPROPERTYEX(DB_NAME(), 'Updateability') AS varchar(20))
FROM sys.dm_exec_sessions WHERE program_name LIKE 'lakeflow-connect-%';
SQL
)"
  done
}

# --- Databricks -----------------------------------------------------------------------------------
gw_state(){ dbx pipelines list-updates "$GATEWAY_ID" --max-results 1 -o json | jq -r '.updates[0].state // "NONE"'; }
gw_stop(){
  log "stopping gateway $GATEWAY_ID"; dbx pipelines stop "$GATEWAY_ID" >/dev/null
  local end=$((SECONDS + WAIT))
  while [ $SECONDS -lt $end ]; do case $(gw_state) in (COMPLETED|CANCELED|FAILED|NONE) return 0;; esac; sleep 10; done
  return 1
}
gw_start(){
  case $(gw_state) in (RUNNING|INITIALIZING|SETTING_UP_TABLES|WAITING_FOR_RESOURCES|QUEUED|CREATED|RESETTING) ;;
    (*) log "starting gateway $GATEWAY_ID"; dbx pipelines start-update "$GATEWAY_ID" -o json >/dev/null;; esac
  local s last="" end=$((SECONDS + WAIT))
  while [ $SECONDS -lt $end ]; do
    s=$(gw_state); [ "$s" != "$last" ] && { log "gateway $s"; last=$s; }
    case $s in (RUNNING) return 0;; (FAILED|CANCELED) return 1;; esac
    sleep 15
  done; return 1
}
switch(){ # switch primary|secondary
  local node=$1 hp host port opts
  case $node in (primary) hp=$PRIMARY;; (secondary) hp=$SECONDARY;; (*) echo "switch primary|secondary" >&2; exit 2;; esac
  need SQL_USER SQL_PASSWORD
  host=${hp%,*}; port=${hp##*,}
  # keep the connection's other options (trustServerCertificate, ...); the API never returns the password
  opts=$(dbx connections get "$CONNECTION" -o json | jq -c '.options // {} | with_entries(select(.key | test("password"; "i") | not))')
  jq -n --argjson o "$opts" --arg h "$host" --arg p "$port" --arg u "$SQL_USER" --arg pw "$SQL_PASSWORD" \
    '{options: ($o + {host: $h, port: $p, user: $u, password: $pw})}' \
    | dbx connections update "$CONNECTION" --json @/dev/stdin -o json >/dev/null
  log "connection $CONNECTION -> $node ($host:$port)"
  gw_stop; gw_start
}
full_refresh(){
  local u
  u=$(jq -n '{full_refresh_selection: $ARGS.positional}' --args "$@" \
    | dbx api post "/api/2.0/pipelines/$PIPELINE_ID/updates" --json @/dev/stdin | jq -r .update_id)
  log "ingestion update $u: full refresh of $*"
}
log_delivery(){
  need LOG_VOLUME
  dbx api get "/api/2.0/pipelines/$GATEWAY_ID" | jq --arg v "$LOG_VOLUME" '.spec
    | .clusters = ((.clusters // [{label: "default"}]) | map(if (.label // "default") == "default"
        then . + {cluster_log_conf: {volumes: {destination: $v}}} else . end))' \
    | dbx api put "/api/2.0/pipelines/$GATEWAY_ID" --json @/dev/stdin >/dev/null
  log "gateway $GATEWAY_ID: cluster logs -> $LOG_VOLUME/<cluster id>/driver (copied every few minutes)"
}
wait_reset(){ # wait_reset <since epoch>: the driver log line, from the delivered log files
  need LOG_VOLUME
  local since=${1:?since epoch} tmp c f hit end=$((SECONDS + WAIT))
  tmp=$(mktemp -d); trap 'rm -rf "${tmp:?}"' RETURN
  while [ $SECONDS -lt $end ]; do
    c=$(dbx pipelines get "$GATEWAY_ID" -o json | jq -r '.cluster_id // empty')
    [ -n "$c" ] || c=$(dbx fs ls "dbfs:$LOG_VOLUME" 2>/dev/null | sort | tail -1)
    for f in $(dbx fs ls "dbfs:$LOG_VOLUME/$c/driver" 2>/dev/null | grep -E '^log4j-.*\.log(\.gz)?$' || true); do
      dbx fs cp "dbfs:$LOG_VOLUME/$c/driver/$f" "$tmp/$f" --overwrite >/dev/null 2>&1 || continue
      case $f in (*.gz) gzip -dc "$tmp/$f";; (*) cat "$tmp/$f";; esac | grep 'Reinitialization completed successfully' \
        > "$tmp/hits" || true
      # log lines start "yy/MM/dd HH:mm:ss" (driver time, UTC)
      hit=$(jq -R -r --argjson s "$since" '(.[0:17] | strptime("%y/%m/%d %H:%M:%S") | mktime) as $t
              | select($t >= $s) | .' "$tmp/hits" | head -1)
      [ -n "$hit" ] && { log "driver log ($c/driver/$f): ${hit:0:160}"; return 0; }
    done
    sleep 30
  done; log "gave up after $WAIT s"; return 1
}

# --- commands -------------------------------------------------------------------------------------
cmd=${1:-}; shift || true
case $cmd in
  (log-delivery) need GATEWAY_ID; log_delivery;;
  (where) need CONNECTION GATEWAY_ID DATABASE
    dbx connections get "$CONNECTION" -o json | jq -r '"connection \(.name): \(.options.host):\(.options.port)"'
    echo "gateway: $(gw_state)"; sessions;;
  (switch) need CONNECTION GATEWAY_ID PRIMARY SECONDARY; switch "${1:-}";;
  (stop) need GATEWAY_ID; gw_stop;;
  (start) need GATEWAY_ID; gw_start;;
  (full-refresh) need PIPELINE_ID; [ $# -gt 0 ] || { echo "full-refresh <table>..." >&2; exit 2; }; full_refresh "$@";;
  (ci) need DATABASE PRIMARY; ci "${1:?schema.table}" "${2:-primary}";;
  (wait-ci) need DATABASE PRIMARY; wait_ci "${1:?schema.table}" "${2:-}";;
  (wait-reset) need GATEWAY_ID; wait_reset "${1:?since epoch}";;
  (caught-up) need DATABASE SECONDARY; caught_up;;
  (ddl) need CONNECTION GATEWAY_ID DATABASE PRIMARY SECONDARY
    t=${1:?schema.table}; file=${2:?ddl file}; [ -f "$file" ] || { echo "no file $file" >&2; exit 2; }
    switch primary
    before=$(ci "$t" primary | cut -d'|' -f2)
    log "running $file on the primary"; sqlrun primary < "$file" >/dev/null
    wait_ci "$t" "$before"; caught_up; switch secondary;;
  (recover) need CONNECTION GATEWAY_ID DATABASE PRIMARY SECONDARY
    t=${1:?schema.table}; switch primary; wait_ci "$t"; caught_up; switch secondary;;
  (refresh) need CONNECTION GATEWAY_ID PIPELINE_ID DATABASE PRIMARY SECONDARY
    t=${1:?schema.table}; dst=${2:?destination table}
    switch primary
    before=$(ci "$t" primary | cut -d'|' -f2); since=$(date -u +%s)
    full_refresh "$dst"
    wait_ci "$t" "$before"
    [ -n "${LOG_VOLUME:-}" ] && wait_reset "$since"
    gw_stop; caught_up; switch secondary;;
  (*) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; [ -z "$cmd" ] || exit 2;;
esac
