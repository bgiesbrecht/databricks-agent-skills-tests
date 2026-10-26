#!/usr/bin/env bash
# lfc-setup.sh: the test login, seed tables, and change tracking + CDC on an Azure SQL Database or Managed Instance.
#   Needs HOST (SQL Database: <server>.database.windows.net; MI: mi.sh endpoint's host), DB, ADMIN_PW_FILE (sqladmin's
#   password), LOGIN_PW_FILE (a private file with the test login's password). Optional: PORT (1433; MI 3342), LOGIN
#   (lfc_user), SCHEMA (dbo). Needs sqlcmd (go-sqlcmd); passwords go through SQLCMDPASSWORD, never the command line.
#   go-sqlcmd doesn't read a batch from standard input: each batch is a private file passed with -i.
#   Steps: the login and a user for it in master (the utility's server-scoped grants need one); the database (MI only:
#   SQL Database already has it); the user in DB, db_owner while the setup runs; intpk (primary key, cursor dt) and dtix
#   (no key) with 10 rows each; the Lakeflow utility objects from the docs; change tracking on intpk, CDC on dtix,
#   lakeflowFixPermissions; then db_owner is dropped again. Idempotent: rerun after a fix.
set -euo pipefail
: "${HOST:?}" "${DB:?}" "${ADMIN_PW_FILE:?}" "${LOGIN_PW_FILE:?}"
PORT=${PORT:-1433}; LOGIN=${LOGIN:-lfc_user}; SC=${SCHEMA:-dbo}
for f in "$ADMIN_PW_FILE" "$LOGIN_PW_FILE"; do [ -r "$f" ] || { echo "can't read $f"; exit 2; }; done
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT; umask 077
sq() { SQLCMDPASSWORD="$(cat "$ADMIN_PW_FILE")" sqlcmd -S "$HOST,$PORT" -U sqladmin -d "$1" -C -l 60 -b -h -1 -W "${@:2}"; }
# the login's password goes into a private batch file, not onto the command line
LPW=$(sed "s/'/''/g" "$LOGIN_PW_FILE")
cat > "$T/master.sql" <<EOF
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'$LOGIN') CREATE LOGIN [$LOGIN] WITH PASSWORD = N'$LPW';
ELSE ALTER LOGIN [$LOGIN] WITH PASSWORD = N'$LPW';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$LOGIN') CREATE USER [$LOGIN] FOR LOGIN [$LOGIN];
IF DB_ID(N'$DB') IS NULL AND SERVERPROPERTY('EngineEdition') = 8 EXEC (N'CREATE DATABASE [$DB]');
EOF
sq master -i "$T/master.sql" > "$T/master.out" || { tail -5 "$T/master.out"; exit 2; }
echo "login $LOGIN (and its user in master)"
cat > "$T/db.sql" <<EOF
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$LOGIN') CREATE USER [$LOGIN] FOR LOGIN [$LOGIN] WITH DEFAULT_SCHEMA = [$SC];
ALTER ROLE db_owner ADD MEMBER [$LOGIN];
IF SCHEMA_ID(N'$SC') IS NULL EXEC (N'CREATE SCHEMA [$SC]');
IF OBJECT_ID(N'$SC.intpk') IS NULL BEGIN
  CREATE TABLE [$SC].intpk (pk INT IDENTITY NOT NULL PRIMARY KEY, dt DATETIME NOT NULL DEFAULT GETDATE(), ops VARCHAR(255) DEFAULT 'insert');
  CREATE INDEX idx_intpk_dt ON [$SC].intpk (dt);
  INSERT INTO [$SC].intpk (ops) SELECT TOP 10 'insert' FROM sys.all_objects;
END
IF OBJECT_ID(N'$SC.dtix') IS NULL BEGIN
  CREATE TABLE [$SC].dtix (pk BIGINT, dt DATETIME NOT NULL DEFAULT GETDATE(), ops VARCHAR(255) DEFAULT 'insert');
  CREATE INDEX idx_dtix_dt ON [$SC].dtix (dt);
  INSERT INTO [$SC].dtix (pk) SELECT TOP 10 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects;
END
GO
CREATE OR ALTER TRIGGER [$SC].intpk_set_dt ON [$SC].intpk AFTER UPDATE AS
  BEGIN SET NOCOUNT ON; UPDATE t SET dt = GETDATE() FROM [$SC].intpk t JOIN inserted i ON i.pk = t.pk; END
GO
CREATE OR ALTER TRIGGER [$SC].dtix_set_dt ON [$SC].dtix AFTER UPDATE AS
  BEGIN SET NOCOUNT ON; UPDATE t SET dt = GETDATE() FROM [$SC].dtix t JOIN inserted i ON i.pk = t.pk; END
GO
EOF
sq "$DB" -i "$T/db.sql" > "$T/db.out" || { tail -5 "$T/db.out"; exit 2; }
echo "seed tables $SC.intpk, $SC.dtix"
curl -fsSL -o "$T/utility_script.sql" https://learn.microsoft.com/en-us/azure/databricks/_extras/documents/utility_script.sql
sq "$DB" -i "$T/utility_script.sql" > "$T/util.out" || { tail -5 "$T/util.out"; echo "utility objects install failed"; exit 2; }
echo "utility $(sq "$DB" -Q "SET NOCOUNT ON; SELECT dbo.lakeflowUtilityVersion()" | head -1)"
cat > "$T/setup.sql" <<EOF
EXEC dbo.lakeflowSetupChangeTracking @Tables = '$SC.intpk', @User = '$LOGIN', @Retention = '2 DAYS', @CreateDdlSupportingObjects = 1;
EXEC dbo.lakeflowSetupChangeDataCapture @Tables = '$SC.dtix', @User = '$LOGIN';
EXEC dbo.lakeflowFixPermissions @User = '$LOGIN', @Tables = '$SC.intpk,$SC.dtix';
ALTER ROLE db_owner DROP MEMBER [$LOGIN];
EOF
sq "$DB" -i "$T/setup.sql" > "$T/setup.out" || { tail -8 "$T/setup.out"; exit 2; }
grep -E '⚠|Error|Msg [0-9]' "$T/setup.out" | head -5 || true
sq "$DB" -Q "SET NOCOUNT ON; SELECT 'ct ' + STRING_AGG(OBJECT_NAME(object_id), ',') FROM sys.change_tracking_tables; SELECT 'cdc ' + STRING_AGG(name, ',') FROM sys.tables WHERE is_tracked_by_cdc = 1"
SQLCMDPASSWORD="$(cat "$LOGIN_PW_FILE")" sqlcmd -S "$HOST,$PORT" -U "$LOGIN" -d "$DB" -C -l 60 -b -h -1 -W \
  -Q "SET NOCOUNT ON; SELECT '$LOGIN reads ' + CAST((SELECT COUNT(*) FROM [$SC].intpk) AS varchar) + ' + ' + CAST((SELECT COUNT(*) FROM [$SC].dtix) AS varchar) + ' rows'"
