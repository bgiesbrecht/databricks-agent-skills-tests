#!/usr/bin/env bash
# fk-cascade-check.sh: does a database's change log carry the rows a foreign key's ON DELETE / ON UPDATE action changes?
#
#   VM_IP=<ip> bash fk-cascade-check.sh [mysql mariadb mysql9 postgres sqlserver oracle cockroachdb yugabytedb db2 informix mysql-trigger]
#
# mysql-trigger: MySQL 8.4 with the workaround, a BEFORE DELETE trigger on the parent that deletes c's rows itself
#
# Per engine, in a throwaway container on the VM (removed at the end): a parent p and three children,
#   c  ON DELETE CASCADE      (deleting parent 1 deletes c 1 and 2)
#   n  ON DELETE SET NULL     (deleting parent 1 sets n 1's pid to NULL)
#   u  ON UPDATE CASCADE      (changing parent 2's k from 20 to 21 changes u 1; not in Oracle, which has no ON UPDATE)
# then reads the change log a CDC reader reads (MySQL/MariaDB binlog, PostgreSQL logical decoding, SQL Server CDC and
# Change Tracking, Oracle LogMiner) and prints, per table, the row changes it holds. Read twice: right after, and again
# after WAIT seconds (default 60) and an unrelated later write, so a late entry would show.
# KEEP=1 keeps the containers (robertlee-fkcascade-<time>-<engine>) to look into; remove them with podman rm -f.
# Each line: <engine> <read> <table> <operation> <rows>. Expected in the log for a complete record: p delete 1, p update 1,
# c delete 2, n update 1, u update 1 (the inserts aside).
# CockroachDB: a sinkless changefeed from a cursor (enables kv.rangefeed.enabled on the throwaway node). YugabyteDB, Db2,
# Informix: the FK actions are checked by the rows left behind (c, n, u counts); their change logs are not read here (no
# SQL reader for a yboutput slot in the image; no db2ReadLog or CDC API client in the Db2 or Informix images). Db2 has no
# ON UPDATE CASCADE, so u is left out there. Informix takes the column-level REFERENCES clause (its table-level CONSTRAINT form is a syntax error).
# Results (2026-10-27, shared test VM): cockroachdb: complete record (c delete 2, n update 1, p delete 1, p update 1, u update 1;
# the insert shows after the wait). yugabytedb: cascade effects right (c 1 row, n 1 null, u pk 21); log not read. informix:
# cascade on c right (1 row left); ON DELETE SET NULL is a syntax error there, so no n table; log not read. db2: the throwaway
# container didn't create LFCDB within 30 minutes (two runs), so no result yet; log not read in any case.
set -uo pipefail
: "${VM_IP:?VM_IP}"
WAIT=${WAIT:-60}
TS=$(date +%s)
SSH=(ssh -i "${SSH_KEY:-$HOME/.ssh/lfc_test_rsa}" -o BatchMode=yes "${VM_USER:-azureuser}@$VM_IP")
vm() {   # retried when ssh can't connect (exit 255)
  local i rc
  for i in 1 2 3 4 5 6; do "${SSH[@]}" "$@"; rc=$?; [ $rc -ne 255 ] && return $rc
    echo "ssh $VM_IP: connection failed (attempt $i of 6), retrying in $((i * 10)) s" >&2; sleep $((i * 10)); done
  return 255
}
rm_c() { [ -n "${KEEP:-}" ] && { echo "kept container $1" >&2; return; }; vm "sudo podman rm -f $1 >/dev/null"; }   # KEEP=1 keeps it
ENGINES=("$@"); [ ${#ENGINES[@]} -eq 0 ] && ENGINES=(mysql mariadb mysql9 postgres sqlserver oracle)

DDL_STD='CREATE TABLE p (id INT PRIMARY KEY, k INT NOT NULL UNIQUE);
CREATE TABLE c (id INT PRIMARY KEY, pid INT NOT NULL REFERENCES p(id) ON DELETE CASCADE);
CREATE TABLE n (id INT PRIMARY KEY, pid INT NULL REFERENCES p(id) ON DELETE SET NULL);
CREATE TABLE u (id INT PRIMARY KEY, pk INT NOT NULL REFERENCES p(k) ON UPDATE CASCADE);'
# MySQL and MariaDB ignore an inline REFERENCES: the constraints go at the table level
DDL_MY='CREATE TABLE p (id INT PRIMARY KEY, k INT NOT NULL UNIQUE) ENGINE=InnoDB;
CREATE TABLE c (id INT PRIMARY KEY, pid INT NOT NULL, FOREIGN KEY (pid) REFERENCES p(id) ON DELETE CASCADE) ENGINE=InnoDB;
CREATE TABLE n (id INT PRIMARY KEY, pid INT NULL, FOREIGN KEY (pid) REFERENCES p(id) ON DELETE SET NULL) ENGINE=InnoDB;
CREATE TABLE u (id INT PRIMARY KEY, pk INT NOT NULL, FOREIGN KEY (pk) REFERENCES p(k) ON UPDATE CASCADE) ENGINE=InnoDB;'
LOAD='INSERT INTO p VALUES (1, 10); INSERT INTO p VALUES (2, 20);
INSERT INTO c VALUES (1, 1); INSERT INTO c VALUES (2, 1); INSERT INTO c VALUES (3, 2);
INSERT INTO n VALUES (1, 1); INSERT INTO n VALUES (2, 2); INSERT INTO u VALUES (1, 20);'
CHANGE='DELETE FROM p WHERE id = 1; UPDATE p SET k = 21 WHERE id = 2;'
AFTER='SELECT (SELECT COUNT(*) FROM c) AS c_rows, (SELECT COUNT(*) FROM n WHERE pid IS NULL) AS n_nulls, (SELECT MAX(pk) FROM u) AS u_pk'

# mysql, mariadb, mysql9: the binlog's row events per table
my() {   # my <engine> <image> <client> [server args]
  local e=$1 img=$2 cli=$3; shift 3
  local n=robertlee-fkcascade-$TS-$e
  vm "P=\$(openssl rand -hex 12); sudo podman run -d --name $n -e MYSQL_ROOT_PASSWORD=\$P -e MARIADB_ROOT_PASSWORD=\$P $img $* >/dev/null"
  local q="sudo podman exec -i $n sh -c '$cli -uroot -p\"\${MYSQL_ROOT_PASSWORD:-\$MARIADB_ROOT_PASSWORD}\" -N -B 2>/dev/null'"
  for _ in $(seq 60); do echo 'SELECT 1' | vm "$q" >/dev/null 2>&1 && break; sleep 3; done
  local trig=""   # mysql-trigger: the workaround, a parent's BEFORE DELETE trigger deleting the children (its deletes are logged)
  [ "$e" = mysql-trigger ] && trig="CREATE TRIGGER p_bd BEFORE DELETE ON p FOR EACH ROW DELETE FROM c WHERE pid = OLD.id;"
  vm "$q" <<<"SELECT VERSION(); CREATE DATABASE t; USE t; $DDL_MY $trig $LOAD FLUSH BINARY LOGS; $CHANGE USE t; $AFTER;" |
    sed "s/^/$e source: /"
  read_my() {   # the images have no mysqlbinlog: SHOW BINLOG EVENTS, a Table_map then its rows events (events, not rows)
    local l
    for l in $(vm "$q" <<<"SHOW BINARY LOGS;" | cut -f1); do vm "$q" <<<"SHOW BINLOG EVENTS IN '$l';"; done |
      awk -F'\t' '$3 == "Table_map" && match($6, /\(t\.[a-z]+\)/) {split($6, a, " "); id[a[2]] = substr($6, RSTART + 3, RLENGTH - 4)}
                  $3 ~ /_rows/ {split($6, a, " "); if (a[2] in id) {op = tolower($3); sub(/_rows.*/, "", op); sub(/write/, "insert", op); print id[a[2]], op}}' |
      sort | uniq -c | awk -v e="$e" -v r="$1" '{print e, r, $2, $3 "-events", $1}'; }
  read_my now
  sleep "$WAIT"; vm "$q" <<<"USE t; INSERT INTO p VALUES (9, 90); FLUSH BINARY LOGS;" >/dev/null
  read_my "after-${WAIT}s"
  rm_c $n
}

postgres() {   # logical decoding (test_decoding): "table public.c: DELETE: ..." per row
  local n=robertlee-fkcascade-$TS-postgres
  vm "sudo podman run -d --name $n -e POSTGRES_PASSWORD=\$(openssl rand -hex 12) docker.io/library/postgres:16 -c wal_level=logical >/dev/null"
  local q="sudo podman exec -i $n psql -U postgres -At -q"
  for _ in $(seq 60); do echo 'SELECT 1' | vm "$q" >/dev/null 2>&1 && break; sleep 2; done
  vm "$q" <<<"SELECT version(); $DDL_STD SELECT 'slot' FROM pg_create_logical_replication_slot('s', 'test_decoding'); $LOAD $CHANGE $AFTER;" |
    grep -v '^slot$' | sed "s/^/postgres source: /"
  read_pg() { vm "$q" <<<"SELECT data FROM pg_logical_slot_peek_changes('s', NULL, NULL);" |
    sed -nE 's/^table public\.([a-z]+): (INSERT|UPDATE|DELETE):.*/\1 \2/p' | tr 'A-Z' 'a-z' | sort | uniq -c |
    awk -v r="$1" '{print "postgres", r, $2, $3, $1}'; }
  read_pg now
  sleep "$WAIT"; vm "$q" <<<"INSERT INTO p VALUES (9, 90);" >/dev/null
  read_pg "after-${WAIT}s"
  rm_c $n
}

sqlserver() {   # CDC change tables (__$operation 1 delete, 2 insert, 4 update after) and Change Tracking
  local n=robertlee-fkcascade-$TS-sqlserver
  vm "sudo podman run -d --name $n -e ACCEPT_EULA=Y -e MSSQL_AGENT_ENABLED=true -e MSSQL_SA_PASSWORD=Fk\$(openssl rand -hex 12)! mcr.microsoft.com/mssql/server:2022-latest >/dev/null"
  local q="sudo podman exec -i $n sh -c '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P \"\$MSSQL_SA_PASSWORD\" -h -1 -W -b'"
  for _ in $(seq 60); do echo 'SELECT 1' | vm "$q" >/dev/null 2>&1 && break; sleep 3; done
  vm "$q" >/dev/null <<EOF
CREATE DATABASE t;
GO
ALTER DATABASE t SET CHANGE_TRACKING = ON;
GO
USE t;
EXEC sys.sp_cdc_enable_db;
GO
$DDL_STD
GO
EOF
  for t in p c n u; do vm "$q" >/dev/null <<<"USE t; EXEC sys.sp_cdc_enable_table @source_schema='dbo', @source_name='$t', @role_name=NULL; ALTER TABLE $t ENABLE CHANGE_TRACKING;
GO"; done
  vm "$q" <<<"SET NOCOUNT ON; USE t; $LOAD
GO
SET NOCOUNT ON; USE t; $CHANGE
GO
SET NOCOUNT ON; USE t; $AFTER;
GO" | sed "s/^/sqlserver source: /"
  read_ms() {
    local s="SET NOCOUNT ON; USE t; "
    for t in p c n u; do s+="SELECT '$t', CASE __\$operation WHEN 1 THEN 'delete' WHEN 2 THEN 'insert' ELSE 'update' END, COUNT(*) FROM cdc.dbo_${t}_CT WHERE __\$operation <> 3 GROUP BY __\$operation; "; done
    for t in p c n u; do s+="SELECT '$t', CASE SYS_CHANGE_OPERATION WHEN 'D' THEN 'ct-delete' WHEN 'I' THEN 'ct-insert' ELSE 'ct-update' END, COUNT(*) FROM CHANGETABLE(CHANGES $t, 0) x GROUP BY SYS_CHANGE_OPERATION; "; done
    vm "$q" <<<"$s
GO" | awk -v r="$1" 'NF == 3 {print "sqlserver", r, $1, $2, $3}' | sort; }
  for _ in $(seq 20); do [ "$(read_ms now | grep -c ' c delete ')" -gt 0 ] && break; sleep 3; done   # the capture job's lag
  read_ms now
  sleep "$WAIT"; vm "$q" >/dev/null <<<"USE t; INSERT INTO p VALUES (9, 90);
GO"; sleep 10
  read_ms "after-${WAIT}s"
  rm_c $n
}

oracle() {   # LogMiner over the online redo logs: one DELETE / UPDATE per row
  local n=robertlee-fkcascade-$TS-oracle
  vm "sudo podman run -d --name $n -e ORACLE_PASSWORD=\$(openssl rand -hex 12) -e APP_USER=t -e APP_USER_PASSWORD=Fk\$(openssl rand -hex 12) docker.io/gvenzl/oracle-free:23-slim >/dev/null"
  for _ in $(seq 100); do vm "sudo podman logs $n 2>&1 | grep -q 'DATABASE IS READY TO USE'" && break; sleep 5; done
  local sys="sudo podman exec -i $n sqlplus -s / as sysdba"
  local app="sudo podman exec -i $n sh -c 'sqlplus -s t/\"\$APP_USER_PASSWORD\"@FREEPDB1'"
  vm "$sys" >/dev/null <<<"ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS;
EXIT"
  local ddl   # sqlplus takes one statement per line
  ddl=$(sed '/^CREATE TABLE u /d' <<<"$DDL_STD")   # Oracle has no ON UPDATE CASCADE
  vm "$app" <<<"SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT banner FROM v\$version WHERE ROWNUM = 1;
$ddl
$(sed 's/INSERT INTO u .*//; s/; /;\n/g' <<<"$LOAD")
COMMIT;
$(sed 's/; /;\n/g' <<<"$CHANGE")
COMMIT;
SELECT (SELECT COUNT(*) FROM c), (SELECT COUNT(*) FROM n WHERE pid IS NULL) FROM dual;
EXIT" | sed '/^$/d; s/^/oracle source: /'
  read_ora() { vm "$sys" <<EOF | awk -v r="$1" 'NF == 3 {print "oracle", r, tolower($1), tolower($2), $3}' | sort
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 SERVEROUTPUT OFF LINESIZE 200
DECLARE i INT := 0;
BEGIN
  FOR f IN (SELECT member FROM v\$logfile) LOOP
    DBMS_LOGMNR.ADD_LOGFILE(f.member, CASE WHEN i = 0 THEN DBMS_LOGMNR.NEW ELSE DBMS_LOGMNR.ADDFILE END); i := i + 1;
  END LOOP;
  DBMS_LOGMNR.START_LOGMNR(OPTIONS => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG);
END;
/
SELECT table_name || ' ' || operation || ' ' || COUNT(*) FROM v\$logmnr_contents WHERE seg_owner = 'T' AND operation IN ('INSERT', 'UPDATE', 'DELETE')
  GROUP BY table_name, operation;
EXEC DBMS_LOGMNR.END_LOGMNR;
EXIT
EOF
  }
  read_ora now
  sleep "$WAIT"; vm "$app" >/dev/null <<<"INSERT INTO p VALUES (9, 90);
COMMIT;
EXIT"
  read_ora "after-${WAIT}s"
  rm_c $n
}

cockroachdb() {   # changefeed (rangefeeds on, sinkless): one row per change, the value a JSON with "before" and "after"
  local n=robertlee-fkcascade-$TS-cockroachdb
  vm "sudo podman run -d --name $n docker.io/cockroachdb/cockroach:v25.4.13 start-single-node --insecure >/dev/null"
  local q="sudo podman exec -i $n /cockroach/cockroach sql --insecure --format=tsv"
  for _ in $(seq 60); do echo 'SELECT 1' | vm "$q" >/dev/null 2>&1 && break; sleep 2; done
  vm "$q" <<<"SET CLUSTER SETTING kv.rangefeed.enabled = true;" >/dev/null   # the feed needs rangefeeds (its own statement)
  vm "$q" <<<"SELECT version();" | sed "s/^/cockroachdb source: /"
  vm "$q" <<<"CREATE DATABASE t; USE t; $DDL_STD $LOAD" >/dev/null
  local T
  T=$(vm "$q" <<<"SELECT cluster_logical_timestamp();" | tail -1)   # the feed starts after this: the change, not the load
  vm "$q" <<<"USE t; $CHANGE" >/dev/null
  vm "$q" <<<"USE t; $AFTER;" | sed "s/^/cockroachdb source: /"
  read_crdb() {   # the feed from T, for WAIT-free reads: a sinkless feed runs until the timeout
    vm "timeout 20 sudo podman exec -i $n /cockroach/cockroach sql --insecure --format=tsv -d t -e \"EXPERIMENTAL CHANGEFEED FOR p, c, n, u WITH diff, format=json, no_initial_scan, cursor='$T'\"" |
      grep -E '^[pcnu]	' | while IFS=$'\t' read -r tbl key val; do
        json=$(printf '%s' "$val" | sed 's/^\\x//' | xxd -r -p)
        case $json in *'"after": null'*) op=delete;; *'"before": null'*) op=insert;; *) op=update;; esac
        echo "$tbl $op"; done | sort | uniq -c | awk -v e=cockroachdb -v r="$1" '{print e, r, $2, $3, $1}'; }
  read_crdb now
  sleep "$WAIT"; vm "$q" >/dev/null <<<"USE t; INSERT INTO p VALUES (9, 90);"
  read_crdb "after-${WAIT}s"
  rm_c $n
}

db2sql_run() {   # db2sql_run <container> < SQL: runs as db2inst1, connected to LFCDB (the file is copied in with podman cp)
  local c=$1 f=/tmp/fk-db2-$TS.sql
  { echo "CONNECT TO LFCDB;"; cat; echo "TERMINATE;"; } | vm "cat > $f"
  vm "sudo podman cp $f $c:$f && sudo podman exec $c chmod 644 $f && sudo podman exec $c su - db2inst1 -c 'db2 -x -t -s -f $f'; r=\$?; sudo podman exec $c rm -f $f; rm -f $f; exit \$r"
}
yugabytedb() {   # YSQL with the FK actions; the change log is not read: no SQL reader for a yboutput slot here (see below)
  local n=robertlee-fkcascade-$TS-yugabytedb D=/var/tmp/robertlee-fkcascade-$TS-yugabytedb
  vm "sudo mkdir -p $D && sudo chown 10001:100 $D && sudo podman run -d --name $n -v $D:/yb:Z docker.io/yugabytedb/yugabyte:2026.1.2.0-b137 bin/yugabyted start --base_dir=/yb --advertise_address=127.0.0.1 --background=false >/dev/null"
  local q="sudo podman exec -i $n bin/ysqlsh -h 127.0.0.1 -U yugabyte -v ON_ERROR_STOP=1 -q -At"
  for _ in $(seq 90); do echo 'SELECT 1' | vm "$q" >/dev/null 2>&1 && break; sleep 5; done
  vm "$q" <<<"SELECT version();" | sed 's/ on x86.*//; s/^/yugabytedb source: /'
  vm "$q" <<<"$DDL_STD $LOAD $CHANGE" >/dev/null
  vm "$q" <<<"$AFTER;" | sed "s/^/yugabytedb source: /"
  # pgoutput (yboutput) slots exist, but peek functions refuse them ("WAL segment ... removed") and the image has no
  # pg_recvlogical, so the change log is not read here
  echo "yugabytedb now log not read: yboutput slots aren't readable with SQL here, and the image has no logical replication client"
  vm "sudo rm -rf ${D:?}" 2>/dev/null
  rm_c $n
}
db2() {          # Db2 LUW community: the FK actions with the change log not read (no db2ReadLog or ASN capture in the image)
  local n=robertlee-fkcascade-$TS-db2
  vm "sudo podman run -d --name $n --privileged -e LICENSE=accept -e DB2INSTANCE=db2inst1 -e DB2INST1_PASSWORD=\$(openssl rand -hex 12) -e DBNAME=LFCDB -e BLU=false -e ENABLE_ORACLE_COMPATIBILITY=false -e PERSISTENT_HOME=true -e ARCHIVE_LOGS=false -e AUTOCONFIG=false -e SAMPLEDB=false icr.io/db2_community/db2:11.5.9.0 >/dev/null"
  for _ in $(seq 180); do vm "sudo podman exec $n su - db2inst1 -c 'db2 connect to LFCDB' >/dev/null 2>&1" && break; sleep 10; done
  local ddl="CREATE TABLE p (id INT NOT NULL PRIMARY KEY, k INT NOT NULL UNIQUE);
CREATE TABLE c (id INT NOT NULL PRIMARY KEY, pid INT NOT NULL REFERENCES p(id) ON DELETE CASCADE);
CREATE TABLE n (id INT NOT NULL PRIMARY KEY, pid INT REFERENCES p(id) ON DELETE SET NULL);"   # Db2 has no ON UPDATE CASCADE
  local sql="$ddl $(sed 's/; /;\n/g' <<<"$LOAD" | grep -v '^INSERT INTO u')
$(sed 's/; /;\n/g' <<<"$CHANGE")
SELECT (SELECT COUNT(*) FROM c) AS c_rows, (SELECT COUNT(*) FROM n WHERE pid IS NULL) AS n_nulls FROM sysibm.sysdummy1;"
  printf '%s\n' "$sql" | db2sql_run "$n" | grep -v '^$' | sed 's/  */ /g' | tail -3 | sed 's/^/db2 source: /'
  echo "db2 now log not read: the community image has no db2ReadLog client or ASN capture program"
  rm_c $n
}
informix() {     # Informix Developer: the FK actions with the change log not read (no CDC API client in the image)
  local n=robertlee-fkcascade-$TS-informix
  vm "sudo podman run -d --name $n -e LICENSE=accept -e INFORMIX_PASSWORD=\$(openssl rand -hex 12) docker.io/ibmcom/informix-developer-database:14.10.FC7W1DE >/dev/null"
  for _ in $(seq 120); do vm "sudo podman exec -i $n bash -lc 'echo \"SELECT 1 FROM sysmaster:sysdual;\" | dbaccess sysmaster -' >/dev/null 2>&1" && break; sleep 5; done
  vm "sudo podman exec -i $n bash -lc 'dbaccess sysmaster -'" <<<"CREATE DATABASE fkt WITH LOG;" >/dev/null
  vm "sudo podman exec -i $n bash -lc 'dbaccess fkt -'" >/dev/null <<EOF2
CREATE TABLE p (id INT PRIMARY KEY, k INT NOT NULL UNIQUE);
CREATE TABLE c (id INT PRIMARY KEY, pid INT NOT NULL REFERENCES p(id) ON DELETE CASCADE);
# no n table: Informix rejects ON DELETE SET NULL (syntax error, tested)
EOF2
  vm "sudo podman exec -i $n bash -lc 'dbaccess fkt -'" >/dev/null <<<"$(sed 's/; /;\n/g' <<<"$LOAD" | grep -v '^INSERT INTO u'); $(sed 's/; /;\n/g' <<<"$CHANGE")"
  vm "sudo podman exec -i $n bash -lc 'dbaccess fkt -'" <<<"SELECT (SELECT COUNT(*) FROM c) AS c_rows FROM systables WHERE tabid = 1;" | grep -E "^ *[0-9]" | sed 's/^/informix source: /'
  echo "informix now log not read: the developer image has no CDC API client (onbar / ifx_cdc) for a readable change log"
  rm_c $n
}

for e in "${ENGINES[@]}"; do
  case $e in
    mysql)   my mysql docker.io/library/mysql:8.4 mysql ;;
    mysql-trigger) my mysql-trigger docker.io/library/mysql:8.4 mysql ;;
    mysql9)  my mysql9 docker.io/library/mysql:9 mysql ;;
    mariadb) my mariadb docker.io/library/mariadb:11.4 mariadb --log-bin=mysql-bin --binlog-format=ROW --server-id=1 ;;
    postgres|sqlserver|oracle) $e ;;
    cockroachdb) cockroachdb ;;
    yugabytedb) yugabytedb ;;
    db2) db2 ;;
    informix) informix ;;
    *) echo "unknown engine $e" >&2 ;;
  esac
done
