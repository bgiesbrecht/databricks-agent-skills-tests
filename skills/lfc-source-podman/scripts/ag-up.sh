#!/usr/bin/env bash
# ag-up.sh <utility_script.sql>: two SQL Server 2022 containers as an Always On availability group with a readable
# secondary (CLUSTER_TYPE = NONE, synchronous commit), a test database with keyed tables, the connection's login with
# the same SID on both nodes, the Lakeflow Connect utility objects and CDC on the primary, and an Extended Events
# session per node that records the gateway's statements and errors (read them with ag-sql.sh <node> --xe).
# Runs on a podman host (the source VM, or podman on a laptop). Prints the two endpoints at the end.
#
# Environment (all optional)
#   AG_NAME     name prefix for containers, network and AG (default lfc-ag): containers <AG_NAME>-p, <AG_NAME>-s
#   AG_DIR      state directory (default $HOME/<AG_NAME>): data, certs, ag.env (passwords, mode 600)
#   PORT_P, PORT_S   host ports of the primary and the secondary (default 1533, 1534)
#   AG_DB       database (default lfcag); AG_TABLES  keyed tables to create (default "t1 t2 t3"); ROWS (default 3000)
#   LFC_USER    the UC connection's login (default lfc_user)
#   IMAGE       default mcr.microsoft.com/mssql/server:2022-latest; MEM_MB  memory limit per node (default 4096)
#   PODMAN      container CLI (default podman; docker works too)
set -euo pipefail
UTIL=${1:?usage: ag-up.sh <utility_script.sql> (the Lakeflow Connect SQL Server utility objects script)}
[ -f "$UTIL" ] || { echo "no file $UTIL" >&2; exit 2; }
N=${AG_NAME:-lfc-ag}; D=${AG_DIR:-$HOME/$N}; PP=${PORT_P:-1533}; PS=${PORT_S:-1534}
DB=${AG_DB:-lfcag}; TABLES=${AG_TABLES:-t1 t2 t3}; ROWS=${ROWS:-3000}; U=${LFC_USER:-lfc_user}
IMAGE=${IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}; MEM=${MEM_MB:-4096}; PM=${PODMAN:-podman}
case "$N$DB$U${TABLES// /}" in (*[!A-Za-z0-9_-]*) echo "names: letters, digits, _ and - only" >&2; exit 2;; esac
log(){ echo "$(date -u +%H:%M:%SZ) $*" >&2; }
here=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$D/p" "$D/s" "$D/certs"
if [ ! -f "$D/ag.env" ]; then
  pw(){ printf 'Lf%s#9' "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"; }
  ( umask 077; printf 'SA_PW=%s\nLFC_PW=%s\nCERT_PW=%s\n' "$(pw)" "$(pw)" "$(pw)" > "$D/ag.env" )
fi
# shellcheck disable=SC1091
. "$D/ag.env"
# the containers run as uid 10001 (mssql)
$PM unshare chown -R 10001:0 "$D/p" "$D/s" "$D/certs" 2>/dev/null || chown -R 10001:0 "$D/p" "$D/s" "$D/certs" 2>/dev/null || true

$PM network inspect "$N-net" >/dev/null 2>&1 || $PM network create "$N-net" >/dev/null
for r in p s; do
  port=$PP; [ $r = s ] && port=$PS
  # a container left "Created" by an earlier failed start (port taken) is removed and started again
  if $PM container inspect "$N-$r" >/dev/null 2>&1 \
     && [ "$($PM container inspect -f '{{.State.Status}}' "$N-$r")" != running ]; then
    $PM rm -f "$N-$r" >/dev/null
  fi
  if ! $PM container inspect "$N-$r" >/dev/null 2>&1; then
    log "starting $N-$r on port $port"
    $PM run -d --name "$N-$r" --hostname "${N//-/}$r" --network "$N-net" -p "$port:1433" \
      --label lfc.purpose=ag-test --label lfc.ag="$N" \
      -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_ENABLE_HADR=1 -e MSSQL_AGENT_ENABLED=true \
      -e MSSQL_MEMORY_LIMIT_MB="$MEM" -e MSSQL_SA_PASSWORD="$SA_PW" \
      -v "$D/$r:/var/opt/mssql" -v "$D/certs:/var/opt/mssql/certs" "$IMAGE" >/dev/null \
      || { $PM rm -f "$N-$r" >/dev/null 2>&1; echo "could not start $N-$r: is port $port free? (PORT_P / PORT_S)" >&2; exit 1; }
  fi
done
sq(){ # sq p|s [db]: T-SQL on stdin as sa
  $PM exec -i -e SQLCMDPASSWORD="$SA_PW" "$N-$1" /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa \
    -d "${2:-master}" -b -h -1 -W -v CERT_PW="$CERT_PW" LFC_PW="$LFC_PW"
}
for r in p s; do
  end=$((SECONDS + 300))
  until echo "SELECT 1" | sq $r >/dev/null 2>&1; do
    [ $SECONDS -lt $end ] || { echo "$N-$r not ready after 300 s" >&2; exit 1; }; sleep 5
  done
done
HP=${N//-/}p; HS=${N//-/}s
log "certificates and endpoints"
[ -f "$D/certs/ag_cert.cer" ] || sq p <<'SQL'
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$(CERT_PW)';
CREATE CERTIFICATE ag_cert WITH SUBJECT = 'lfc ag endpoint';
BACKUP CERTIFICATE ag_cert TO FILE = '/var/opt/mssql/certs/ag_cert.cer'
  WITH PRIVATE KEY (FILE = '/var/opt/mssql/certs/ag_cert.pvk', ENCRYPTION BY PASSWORD = '$(CERT_PW)');
SQL
sq s <<'SQL'
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
  CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$(CERT_PW)';
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'ag_cert')
  CREATE CERTIFICATE ag_cert FROM FILE = '/var/opt/mssql/certs/ag_cert.cer'
    WITH PRIVATE KEY (FILE = '/var/opt/mssql/certs/ag_cert.pvk', DECRYPTION BY PASSWORD = '$(CERT_PW)');
SQL
for r in p s; do sq $r <<'SQL'
IF NOT EXISTS (SELECT 1 FROM sys.endpoints WHERE name = 'hadr_endpoint')
  CREATE ENDPOINT hadr_endpoint STATE = STARTED AS TCP (LISTENER_PORT = 5022)
    FOR DATABASE_MIRRORING (ROLE = ALL, AUTHENTICATION = CERTIFICATE ag_cert, ENCRYPTION = REQUIRED ALGORITHM AES);
SQL
done

log "database $DB with tables: $TABLES"
{ echo "IF DB_ID('$DB') IS NULL BEGIN CREATE DATABASE [$DB]; ALTER DATABASE [$DB] SET RECOVERY FULL; END"; echo GO
  echo "USE [$DB];"
  for t in $TABLES; do
    echo "IF OBJECT_ID('dbo.$t') IS NULL BEGIN CREATE TABLE dbo.$t (id INT PRIMARY KEY, n INT NOT NULL, s NVARCHAR(40) NULL);"
    echo "  INSERT dbo.$t SELECT TOP ($ROWS) ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 1, 'row' FROM sys.all_objects a CROSS JOIN sys.all_objects b; END"
  done
  echo GO; echo "BACKUP DATABASE [$DB] TO DISK = '/var/opt/mssql/data/$DB.bak' WITH INIT, FORMAT;"; } | sq p >/dev/null

log "availability group $N (CLUSTER_TYPE = NONE), secondary readable"
sq p >/dev/null <<SQL
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = '$N')
  CREATE AVAILABILITY GROUP [$N] WITH (CLUSTER_TYPE = NONE) FOR DATABASE [$DB] REPLICA ON
    N'$HP' WITH (ENDPOINT_URL = N'tcp://$HP:5022', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL,
      SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL)),
    N'$HS' WITH (ENDPOINT_URL = N'tcp://$HS:5022', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL,
      SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL));
SQL
sq s >/dev/null <<SQL
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = '$N') BEGIN
  ALTER AVAILABILITY GROUP [$N] JOIN WITH (CLUSTER_TYPE = NONE);
  ALTER AVAILABILITY GROUP [$N] GRANT CREATE ANY DATABASE; END
SQL
end=$((SECONDS + 600))
until [ "$(echo "SET NOCOUNT ON; SELECT synchronization_state_desc FROM sys.dm_hadr_database_replica_states WHERE is_local = 1 AND database_id = DB_ID('$DB')" | sq s | tr -d '[:space:]')" = SYNCHRONIZED ]; do
  [ $SECONDS -lt $end ] || { echo "secondary not SYNCHRONIZED after 600 s" >&2; exit 1; }; sleep 5
done

log "login $U with the same SID on both nodes"
sid=$(sq p <<SQL | tr -d '[:space:]'
SET NOCOUNT ON;
IF SUSER_ID('$U') IS NULL CREATE LOGIN [$U] WITH PASSWORD = '\$(LFC_PW)', CHECK_POLICY = OFF;
SELECT CONVERT(varchar(200), SUSER_SID('$U'), 1);
SQL
)
sq s >/dev/null <<SQL
IF SUSER_ID('$U') IS NULL CREATE LOGIN [$U] WITH PASSWORD = '\$(LFC_PW)', SID = $sid, CHECK_POLICY = OFF;
SQL
sq p "$DB" >/dev/null <<SQL
IF USER_ID('$U') IS NULL CREATE USER [$U] FOR LOGIN [$U];
SQL

# a user for the login in master first, so lakeflowFixPermissions can make its server-scoped grants on the primary
sq p >/dev/null <<SQL
IF USER_ID('$U') IS NULL CREATE USER [$U] FOR LOGIN [$U];
SQL
log "utility objects and CDC on the primary"
# -x: the utility script is run as is (no sqlcmd $(var) substitution)
$PM exec -i -e SQLCMDPASSWORD="$SA_PW" "$N-p" /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -d "$DB" -b -x \
  < "$UTIL" >/dev/null
csv=$(for t in $TABLES; do printf 'dbo.%s,' "$t"; done); csv=${csv%,}
sq p "$DB" <<SQL | grep -E '✓|⚠|ERROR|RESULT' >&2 || true
EXEC dbo.lakeflowSetupChangeDataCapture @Tables = '$csv', @User = '$U';
EXEC dbo.lakeflowFixPermissions @User = '$U', @Tables = '$csv';
SQL
# the AG copies the database, not master: the utility script's server-scoped grants are repeated on each node
for r in p s; do sq $r >/dev/null <<SQL
IF USER_ID('$U') IS NULL CREATE USER [$U] FOR LOGIN [$U];
GRANT SELECT ON sys.change_tracking_databases TO [$U];
GRANT EXECUTE ON sys.sp_tables TO [$U]; GRANT EXECUTE ON sys.sp_columns_100 TO [$U];
GRANT EXECUTE ON sys.sp_pkeys TO [$U]; GRANT EXECUTE ON sys.sp_statistics_100 TO [$U];
SQL
done
log "server-scoped grants for $U in master on both nodes (the availability group doesn't copy master)"

log "Extended Events session lfc_watch on both nodes (gateway statements and errors)"
for r in p s; do sq $r >/dev/null <<'SQL'
IF NOT EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'lfc_watch') BEGIN
  CREATE EVENT SESSION lfc_watch ON SERVER
    ADD EVENT sqlserver.error_reported (ACTION (sqlserver.client_app_name, sqlserver.sql_text)
      WHERE sqlserver.like_i_sql_unicode_string(sqlserver.client_app_name, N'lakeflow-connect%')),
    ADD EVENT sqlserver.rpc_completed (ACTION (sqlserver.client_app_name)
      WHERE sqlserver.like_i_sql_unicode_string(sqlserver.client_app_name, N'lakeflow-connect%')),
    ADD EVENT sqlserver.sql_batch_completed (ACTION (sqlserver.client_app_name)
      WHERE sqlserver.like_i_sql_unicode_string(sqlserver.client_app_name, N'lakeflow-connect%'))
    ADD TARGET package0.event_file (SET filename = N'/var/opt/mssql/log/lfc_watch.xel', max_file_size = 64)
    WITH (STARTUP_STATE = ON);
  ALTER EVENT SESSION lfc_watch ON SERVER STATE = START; END
SQL
done

host=$(hostname -I 2>/dev/null | awk '{print $1}'); host=${host:-<this host>}
echo "addresses as seen on this host; the UC connection needs the address the workspace reaches (public IP or DNS name)"
echo "primary   $host,$PP  (container $N-p)"
echo "secondary $host,$PS  (container $N-s, readable)"
echo "login     $U; passwords in $D/ag.env; SQL:  AG_NAME=$N $here/ag-sql.sh p|s [db] < file.sql"
