#!/usr/bin/env bash
# lfc-setup.sh pg|mysql: the test user and seed tables on an Azure Database for PostgreSQL or MySQL Flexible Server
#   (after flex.sh create set the CDC parameters).
#   Needs HOST (the server's FQDN), DB, ADMIN_PW_FILE (lfcadmin's password), LOGIN_PW_FILE (a private file with the test
#   user's password). Optional: LOGIN (lfc_user), SCHEMA (pg: public). Needs psql / mysql; passwords go through
#   PGPASSWORD / MYSQL_PWD, never the command line. TLS is required by the server, and used; psql checks the server's
#   certificate and name against PG_CA (default /etc/ssl/cert.pem, the OS bundle: a ~/.postgresql/root.crt kept for
#   another server would otherwise fail it with "certificate verify failed").
#   pg     the user with REPLICATION, owner of intpk (primary key, cursor dt) and dtix (no key, REPLICA IDENTITY FULL), so
#          it can make the pipeline's own publication and slot; 10 rows each; a trigger bumps dt on update
#   mysql  the user with the CDC grants from the docs (REPLICATION SLAVE and CLIENT, SELECT on *.*, mysql.user plugin),
#          the same two tables with dt ON UPDATE CURRENT_TIMESTAMP; 10 rows each
#   Idempotent: rerun after a fix. Ends by reading the row counts as the test user.
set -euo pipefail
E=${1:?pg|mysql}
: "${HOST:?}" "${DB:?}" "${ADMIN_PW_FILE:?}" "${LOGIN_PW_FILE:?}"
LOGIN=${LOGIN:-lfc_user}
for f in "$ADMIN_PW_FILE" "$LOGIN_PW_FILE"; do [ -r "$f" ] || { echo "can't read $f"; exit 2; }; done
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT; umask 077
LPW=$(sed "s/'/''/g" "$LOGIN_PW_FILE")
case $E in
pg)
  SC=${SCHEMA:-public}
  TLS="sslmode=verify-full sslrootcert=${PG_CA:-/etc/ssl/cert.pem}"
  ad() { PGPASSWORD="$(cat "$ADMIN_PW_FILE")" psql "host=$HOST port=5432 dbname=$DB user=lfcadmin $TLS" -v ON_ERROR_STOP=1 -qAt "$@"; }
  cat > "$T/s.sql" <<EOF
DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$LOGIN') THEN CREATE ROLE $LOGIN LOGIN; END IF; END \$\$;
ALTER ROLE $LOGIN WITH LOGIN REPLICATION PASSWORD '$LPW';
GRANT CONNECT, CREATE ON DATABASE "$DB" TO $LOGIN;
CREATE SCHEMA IF NOT EXISTS $SC;
GRANT USAGE, CREATE ON SCHEMA $SC TO $LOGIN;
CREATE TABLE IF NOT EXISTS $SC.intpk (pk SERIAL PRIMARY KEY, dt TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, ops VARCHAR(255) DEFAULT 'insert');
CREATE INDEX IF NOT EXISTS idx_intpk_dt ON $SC.intpk (dt);
CREATE TABLE IF NOT EXISTS $SC.dtix (pk BIGINT, dt TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, ops VARCHAR(255) DEFAULT 'insert');
CREATE INDEX IF NOT EXISTS idx_dtix_dt ON $SC.dtix (dt);
ALTER TABLE $SC.dtix REPLICA IDENTITY FULL;
CREATE OR REPLACE FUNCTION $SC.set_dt() RETURNS trigger LANGUAGE plpgsql AS \$f\$ BEGIN NEW.dt := CURRENT_TIMESTAMP; RETURN NEW; END \$f\$;
DROP TRIGGER IF EXISTS intpk_set_dt ON $SC.intpk; CREATE TRIGGER intpk_set_dt BEFORE UPDATE ON $SC.intpk FOR EACH ROW EXECUTE FUNCTION $SC.set_dt();
DROP TRIGGER IF EXISTS dtix_set_dt ON $SC.dtix; CREATE TRIGGER dtix_set_dt BEFORE UPDATE ON $SC.dtix FOR EACH ROW EXECUTE FUNCTION $SC.set_dt();
INSERT INTO $SC.intpk (ops) SELECT 'insert' FROM generate_series(1, 10) WHERE NOT EXISTS (SELECT 1 FROM $SC.intpk);
INSERT INTO $SC.dtix (pk) SELECT g FROM generate_series(1, 10) g WHERE NOT EXISTS (SELECT 1 FROM $SC.dtix);
-- the test user owns the tables: a publication on a table needs its owner
GRANT $LOGIN TO lfcadmin;
ALTER TABLE $SC.intpk OWNER TO $LOGIN; ALTER TABLE $SC.dtix OWNER TO $LOGIN; ALTER SEQUENCE $SC.intpk_pk_seq OWNER TO $LOGIN;
EOF
  ad -f "$T/s.sql" > "$T/out" || { tail -5 "$T/out"; exit 2; }
  ad -c "SHOW wal_level" | sed 's/^/wal_level /'
  PGPASSWORD="$(cat "$LOGIN_PW_FILE")" psql "host=$HOST port=5432 dbname=$DB user=$LOGIN $TLS" -qAt \
    -c "SELECT '$LOGIN reads ' || (SELECT count(*) FROM $SC.intpk) || ' + ' || (SELECT count(*) FROM $SC.dtix) || ' rows; replication ' || rolreplication FROM pg_roles WHERE rolname = current_user" ;;
mysql)
  ad() { MYSQL_PWD="$(cat "$ADMIN_PW_FILE")" mysql -h "$HOST" -u lfcadmin --ssl-mode=REQUIRED -N "$@"; }
  cat > "$T/s.sql" <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB\`;
CREATE USER IF NOT EXISTS '$LOGIN'@'%' IDENTIFIED BY '$LPW';
ALTER USER '$LOGIN'@'%' IDENTIFIED BY '$LPW';
GRANT ALTER, CREATE, DROP, INDEX, SELECT, INSERT, DELETE, UPDATE ON \`$DB\`.* TO '$LOGIN'@'%';
GRANT REPLICATION SLAVE, REPLICATION CLIENT, SELECT ON *.* TO '$LOGIN'@'%';
GRANT SELECT (plugin, user) ON mysql.user TO '$LOGIN'@'%';
USE \`$DB\`;
CREATE TABLE IF NOT EXISTS intpk (pk SERIAL PRIMARY KEY, dt TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, ops VARCHAR(255) DEFAULT 'insert', INDEX idx_dt (dt));
CREATE TABLE IF NOT EXISTS dtix (pk BIGINT, dt TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, ops VARCHAR(255) DEFAULT 'insert', INDEX idx_dt (dt));
INSERT INTO intpk (ops) SELECT 'insert' FROM (SELECT 1 FROM information_schema.columns LIMIT 10) t WHERE (SELECT COUNT(*) FROM intpk) = 0;
INSERT INTO dtix (pk) SELECT ROW_NUMBER() OVER () FROM (SELECT 1 FROM information_schema.columns LIMIT 10) t WHERE (SELECT COUNT(*) FROM dtix) = 0;
EOF
  ad < "$T/s.sql" > "$T/out" 2>&1 || { tail -5 "$T/out"; exit 2; }
  ad -e "SELECT CONCAT('binlog_row_image ', @@binlog_row_image, ', expire ', @@binlog_expire_logs_seconds, ' s, invisible pk ', @@sql_generate_invisible_primary_key)"
  MYSQL_PWD="$(cat "$LOGIN_PW_FILE")" mysql -h "$HOST" -u "$LOGIN" --ssl-mode=REQUIRED -N "$DB" \
    -e "SELECT CONCAT('$LOGIN reads ', (SELECT COUNT(*) FROM intpk), ' + ', (SELECT COUNT(*) FROM dtix), ' rows')" ;;
*) echo "pg or mysql"; exit 2 ;;
esac
