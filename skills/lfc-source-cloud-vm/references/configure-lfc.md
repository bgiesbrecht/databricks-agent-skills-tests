# Configure Database for Lakeflow Connect

> Passwords come from files created with `umask 077; openssl rand -hex 24 > admin.pw` (and `lfc_user.pw`). Where SQL needs the password as a literal, paste it from the file into the client session; don't type it on a shell command line.

## Create LFC user and schema

For engine-specific grants, CDC setup, and replication configuration, see the parent skill **lfc-source-setup** → `references/engine-*.md`.

Quick examples for user creation:

### MySQL

```bash
export MYSQL_PWD="$(cat admin.pw)"
mysql -h <vm-ip> -u root <<'EOF'
CREATE USER IF NOT EXISTS 'lfc_user'@'%' IDENTIFIED BY '<password from lfc_user.pw>';
GRANT ALL PRIVILEGES ON *.* TO 'lfc_user'@'%';
GRANT REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO 'lfc_user'@'%';
CREATE DATABASE IF NOT EXISTS lfc_test_db;
FLUSH PRIVILEGES;
EOF
unset MYSQL_PWD
```

### PostgreSQL

```bash
export PGPASSWORD="$(cat admin.pw)"
psql -h <vm-ip> -U postgres <<'EOF'
CREATE USER lfc_user WITH PASSWORD '<password from lfc_user.pw>';
ALTER ROLE lfc_user WITH CREATEDB CREATEROLE;
CREATE DATABASE lfc_test_db OWNER lfc_user;
EOF
unset PGPASSWORD
```

### SQL Server

```bash
export SQLCMDPASSWORD="$(cat admin.pw)"
sqlcmd -S <vm-ip> -U sa <<'EOF'
CREATE LOGIN lfc_user WITH PASSWORD = '<password from lfc_user.pw>';
CREATE USER lfc_user FOR LOGIN lfc_user;
GRANT CONTROL ON SERVER::lfc_test_db TO lfc_user;
GO
EOF
unset SQLCMDPASSWORD
```

## Enable replication mode

### MySQL

Edit `/etc/mysql/mysql.conf.d/mysqld.cnf`:

```
server-id = 1
log_bin = /var/log/mysql/mysql-bin.log
binlog_format = ROW
binlog_row_image = FULL
```

Restart:

```bash
sudo systemctl restart mysql
```

### PostgreSQL

Edit `/etc/postgresql/*/main/postgresql.conf`:

```
wal_level = logical
max_wal_senders = 4
max_replication_slots = 2
```

Restart:

```bash
sudo systemctl restart postgresql
```

### SQL Server

Enable change tracking or CDC (see parent skill `references/engine-sqlserver.md`):

```bash
export SQLCMDPASSWORD="$(cat admin.pw)"
sqlcmd -S <vm-ip> -U sa <<'EOF'
USE master;
GO
EXEC sp_replicationdboption @dbname = N'lfc_test_db', @optname = N'publish', @value = N'true';
GO
EOF
unset SQLCMDPASSWORD
```

### Oracle (Podman)

Inside container:

```bash
sudo podman exec <container> sqlplus -v

# Or via SQL:
# ALTER SYSTEM SET db_recovery_file_dest_size=50G scope=both;
# ALTER SYSTEM SET db_recovery_file_dest='/opt/oracle/oradata/FRA' scope=both;
# ALTER DATABASE ARCHIVELOG;
# ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
```

## Verify replication settings

### MySQL

```bash
export MYSQL_PWD="$(cat lfc_user.pw)"
mysql -h <vm-ip> -u lfc_user lfc_test_db -e "SHOW MASTER STATUS;"
unset MYSQL_PWD
```

### PostgreSQL

```bash
export PGPASSWORD="$(cat lfc_user.pw)"
psql -h <vm-ip> -U lfc_user -d lfc_test_db -c "SELECT version();"
unset PGPASSWORD
```

### SQL Server

```bash
export SQLCMDPASSWORD="$(cat lfc_user.pw)"
sqlcmd -S <vm-ip> -U lfc_user -d lfc_test_db -Q "SELECT @@VERSION"
unset SQLCMDPASSWORD
```
