#!/usr/bin/env bash
# tpc-master.sh <postgres|mysql|sqlserver|oracle> <master> [workload ...]: build a master holding TPC workloads (default all
# six: tpcb tpcc tpch tpcds tpce tpcdi) in one engine, filled inside the database by lfc-source-datagen, then stop it
# cleanly and copy it into JuiceFS as $OUT/<master>.
#   Each workload is its own database (MySQL, SQL Server), schema (Postgres, in database postgres), or user (Oracle, in
#   FREEPDB1), named after the workload. Its DDL is $DDL/<workload>-<dialect>.sql, written by lfc-source-statschema's
#   shape.py and ddl.py (dialects postgres, mysql, tsql, oracle). Rows come from INSERT ... SELECT over the engine's own
#   generator: generate_series (Postgres, SRC=series), a seed table filled by doubling (MySQL), GENERATE_SERIES (SQL
#   Server 2022), CONNECT BY LEVEL (Oracle).
#   The build runs on local disk ($DATA/build-<master>), tuned for loading (no fsync, no binary log, SIMPLE recovery);
#   the settings are the image defaults again when a clone starts. The lfc tags (lfc_seed.tags, lfc_tags) stay, so a
#   clone can be topped up or appended to with the same planners.
#   Admin passwords come from env files ($SECRETS/<engine>.env, mode 600): POSTGRES_PASSWORD; MYSQL_ROOT_PASSWORD;
#   ACCEPT_EULA=Y and MSSQL_SA_PASSWORD; ORACLE_PASSWORD. Run it as a systemd unit (watch-progress): it takes an hour or more.
#   The data directory is mounted with :Z, for hosts with SELinux enforcing (Fedora, as in a Lima VM); elsewhere it's a no-op.
set -uo pipefail
E=$1; NAME=$2; shift 2; WL=${*:-tpcb tpcc tpch tpcds tpce tpcdi}
DDL=${DDL:-/tmp/dg/ddl}; DG=${DG:-/tmp/dg}; DATA=${DATA:-/var/lib/containers/lfc-data}; OUT=${OUT:-/mnt/jfs/masters}
SECRETS=${SECRETS:-/root/lfc-src}; JC=${JC:-/var/lib/containers/jfs/cache}; SESSIONS=${SESSIONS:-4}
M=$DATA/build-$NAME; C=build-$NAME; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# wait until a check passes, while the container is still running (else show why it stopped, and stop)
wait_for() { until "$@" > /dev/null 2>&1; do
  [ "$(podman container inspect -f '{{.State.Running}}' $C 2>/dev/null)" = true ] || { echo "$C stopped:"; podman logs --tail 20 $C 2>&1; exit 1; }
  sleep 3; done; }
t() { local s=$(date +%s); "$@"; local r=$?; echo "  [$(( $(date +%s) - s )) s] $*" | cut -c1-120; return $r; }
[ -f "$SECRETS/$E.env" ] || { echo "missing $SECRETS/$E.env"; exit 2; }
[ -e "$OUT/$NAME" ] && { echo "$OUT/$NAME exists: remove it first"; exit 2; }
podman rm -f $C > /dev/null 2>&1; rm -rf $M; mkdir -p $M
case $E in
postgres)
  podman run -d --name $C --shm-size 4g --env-file $SECRETS/$E.env -v $M:/var/lib/postgresql/data:Z docker.io/library/postgres:16 \
    -c shared_buffers=4GB -c maintenance_work_mem=1GB -c max_wal_size=16GB -c fsync=off -c synchronous_commit=off -c full_page_writes=off > /dev/null
  wait_for podman exec $C pg_isready -h 127.0.0.1 -q; sleep 2
  PG="podman exec -i $C psql -X -U postgres -d postgres -q -v ON_ERROR_STOP=1"
  load() { { echo "CREATE SCHEMA $1; SET search_path = $1;"; cat $DDL/$1-postgres.sql; } | $PG > /dev/null &&
           PSQL="podman exec -i $C psql -U postgres -d postgres" DIR=$DG/postgres SRC=series SESSIONS=$SESSIONS bash $DG/fill.sh pg $1; }
  finish() { $PG -c "VACUUM ANALYZE" && $PG -c CHECKPOINT && podman stop -t 300 $C > /dev/null &&
             # after a clean stop (no replication slots), pg_resetwal drops the load's WAL to one segment; data is untouched
             podman run --rm --user postgres -v $M:/var/lib/postgresql/data:Z docker.io/library/postgres:16 pg_resetwal -D /var/lib/postgresql/data; } ;;
mysql)
  podman run -d --name $C --env-file $SECRETS/$E.env -v $M:/var/lib/mysql:Z docker.io/library/mysql:8.4 \
    --skip-log-bin --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 --innodb-redo-log-capacity=2G > /dev/null
  wait_for podman exec $C bash -c 'MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysql -uroot -e "SELECT 1"'
  podman exec $C bash -c 'umask 077; printf "[client]\nuser=root\npassword=%s\n" "$MYSQL_ROOT_PASSWORD" > /root/.my.cnf'   # not on a command line
  MY="podman exec -i $C mysql"
  { echo "CREATE DATABASE IF NOT EXISTS lfc_seed; CREATE TABLE lfc_seed.seed (i bigint PRIMARY KEY);"   # 1..2^20, by doubling
    echo "INSERT INTO lfc_seed.seed (i) VALUES $(printf '(%s),' $(seq 1 1024) | sed 's/,$//');"
    for k in $(seq 10); do echo "INSERT INTO lfc_seed.seed (i) SELECT s.i + b.m FROM lfc_seed.seed s, (SELECT MAX(i) AS m FROM lfc_seed.seed) b;"; done
    echo "CREATE TABLE lfc_seed.seed_r (i bigint PRIMARY KEY, r bigint NOT NULL);"       # r: a random permutation, for shuffled keys
    echo "INSERT INTO lfc_seed.seed_r SELECT i, ROW_NUMBER() OVER (ORDER BY RAND()) FROM lfc_seed.seed;"
    echo "DROP TABLE lfc_seed.seed; RENAME TABLE lfc_seed.seed_r TO lfc_seed.seed;"; } | $MY || exit 1
  load() { { echo "CREATE DATABASE $1; USE $1;"; cat $DDL/$1-mysql.sql; } | $MY && MYSQL="$MY" DIR=$DG/mysql SESSIONS=2 bash $DG/fill.sh my $1; }
  finish() { for w in $WL; do $MY -N -e "SELECT CONCAT('ANALYZE TABLE \`', table_schema, '\`.\`', table_name, '\`;') FROM information_schema.tables WHERE table_schema = '$w'" | $MY > /dev/null; done
             $MY -e "DROP TABLE lfc_seed.seed" && podman stop -t 300 $C > /dev/null; } ;;
sqlserver)
  chown 10001:0 $M
  podman run -d --name $C --memory 6g --env-file $SECRETS/$E.env -e MSSQL_MEMORY_LIMIT_MB=5120 -v $M:/var/opt/mssql:Z mcr.microsoft.com/mssql/server:2022-latest > /dev/null
  # the client: a script, since a command in a variable can't hold quotes; sqlcmd gets a file (-i): it splits long stdin lines
  cat > $W/sq <<Q
#!/bin/bash
exec podman exec -i $C bash -c 'f=\$(mktemp); cat > \$f; SQLCMDPASSWORD=\$MSSQL_SA_PASSWORD /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -d "\$0" -y 0 -i \$f; r=\$?; rm -f \$f; exit \$r' "\${1:-master}"
Q
  chmod 700 $W/sq; SQ=$W/sq
  sq_ok() { echo "SELECT 1" | $SQ; }; wait_for sq_ok
  load() { echo "CREATE DATABASE [$1]; ALTER DATABASE [$1] SET RECOVERY SIMPLE;" | $SQ > /dev/null && $SQ $1 < $DDL/$1-tsql.sql > $W/ddl.out &&
           { printf '#!/bin/bash\nexec %s %s\n' $SQ $1 > $W/sq-$1; chmod 700 $W/sq-$1; MSSQL=$W/sq-$1 DIR=$DG/sqlserver SESSIONS=$SESSIONS bash $DG/fill.sh ms dbo; }; }
  finish() { for w in $WL; do echo "EXEC sp_updatestats;" | $SQ $w > /dev/null; done; echo "SHUTDOWN;" | $SQ > /dev/null; podman stop -t 120 $C > /dev/null; } ;;
oracle)
  chown 54321:54321 $M
  podman run -d --name $C --memory 4g --shm-size 2g --env-file $SECRETS/$E.env -v $M:/opt/oracle/oradata:Z docker.io/gvenzl/oracle-free:23-slim > /dev/null
  cat > $W/sq <<Q
#!/bin/bash
exec podman exec -i $C bash -c '{ echo "SET FEEDBACK OFF"; echo "ALTER SESSION SET CONTAINER = FREEPDB1;"; cat; } | sqlplus -s / as sysdba'
Q
  chmod 700 $W/sq; SQ=$W/sq
  ora_ok() { podman logs $C 2>&1 | grep "DATABASE IS READY TO USE"; }; wait_for ora_ok
  load() { local S=$(echo $1 | tr a-z A-Z)
           { echo "SET DEFINE OFF"; echo "CREATE USER $S NO AUTHENTICATION QUOTA UNLIMITED ON USERS DEFAULT TABLESPACE USERS;"
             echo "ALTER SESSION SET CURRENT_SCHEMA = $S;"; cat $DDL/$1-oracle.sql; } | $SQ > $W/ddl.out
           grep -E "^(ORA|SP2)-" $W/ddl.out | sort | uniq -c
           ORACLE=$SQ DIR=$DG/oracle SESSIONS=$SESSIONS bash $DG/fill.sh ora $S; }
  finish() { for w in $WL; do printf "EXEC DBMS_STATS.GATHER_SCHEMA_STATS('%s')\n" $(echo $w | tr a-z A-Z) | $SQ; done; podman stop -t 120 $C > /dev/null; } ;;
*) echo "engine: postgres, mysql, sqlserver, or oracle"; exit 2 ;;
esac
for w in $WL; do echo "== $w"; t load $w > $W/load.out 2>&1; r=$?; grep -v -E "^\(?[0-9]+ rows? affected\)?$|^$" $W/load.out | tail -40
                  [ $r = 0 ] || { echo "$w failed"; exit 1; }; done
echo "== statistics, clean stop"; t finish
podman rm $C > /dev/null 2>&1
echo "master on disk: $(du -sh $M | cut -f1), files $(find $M -type f | wc -l)"
# into JuiceFS (then wait until its write-back staging is uploaded), or a reflink copy when $OUT is on the same XFS
t cp -a --reflink=auto $M $OUT/$NAME && until ! find $JC -path '*rawstaging*' -type f 2>/dev/null | grep . > /dev/null; do sleep 2; done
echo "copied to $OUT/$NAME: $(juicefs info -r $OUT/$NAME 2>/dev/null | awk '/size:/ {print $2 $3; exit}')"
rm -rf $M
echo "MASTER DONE $NAME"
