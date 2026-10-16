# MySQL and MariaDB Source Configuration for Lakeflow Connect

This guide documents the database configuration required for Lakeflow Connect (LFC) query-based ingestion and CDC (Change Data Capture) on MySQL and MariaDB servers.

## Quick Reference

| Requirement | Query-Based | CDC (Binlog) |
|---|---|---|
| **Server Parameter** | `log_bin=ON` | `binlog_format=ROW`, `binlog_row_image=FULL` |
| **User Privilege** | `SELECT`, `INDEX` | + `REPLICATION SLAVE`, `REPLICATION CLIENT` |
| **Cursor Column** | Any `TIMESTAMP` or datetime | Not needed; CDC is event-based |
| **Primary/Unique Key** | Required for SCD1 / SCD2 (declare it as `primary_keys`) | Recommended; without one the table is keyed on all columns and duplicate rows collapse |

### Key Differences: MySQL vs MariaDB

| Aspect | MySQL | MariaDB |
|--------|-------|---------|
| Binary logging | Defaults to ON (8.0+); settable at runtime | Defaults to OFF; read-only; must enable at startup via `--log-bin` |
| GTID variables | `@@gtid_executed` | `@@gtid_binlog_pos` / `@@gtid_slave_pos` |
| Auth plugin | `mysql_native_password` | `mysql_native_password` or `ed25519` |
| Binlog format | Runtime-settable | Runtime-settable |

## Prerequisites for Query-Based Ingestion

### MySQL Server Parameters

The following parameters must be set for binlog CDC to work (required for both query-based and CDC modes):

```sql
-- Check current settings
SELECT @@log_bin, @@binlog_format, @@binlog_row_image, @@require_secure_transport;
```

| Parameter | Required Value | Scope | Platform Notes |
|-----------|----------------|-------|----------------|
| `log_bin` | ON | Startup | AWS RDS/Aurora, GCP Cloud SQL, Azure Flexible Server: set via parameter group/flags |
| `binlog_format` | ROW | Runtime (MySQL 8.0+) / Startup (older) | Must be ROW, not STATEMENT |
| `binlog_row_image` | FULL | Runtime (MySQL 8.0+) / Startup (older) | Required for change capture; FULL includes all columns |
| `require_secure_transport` | OFF | Runtime | Optional but typically OFF for dev/test |
| `sql_generate_invisible_primary_key` | OFF | Runtime | MySQL 8.0.23+; optional; when ON, interferes with PK detection |
| `binlog_expire_logs_seconds` | 604800+ | Runtime | Optional; at least 7 days for recovery window |

**MariaDB-specific:** The first three parameters are runtime-settable in MariaDB; `log_bin` must be enabled at startup.

### Cloud-Specific Parameter Setup

**AWS RDS MySQL/Aurora:**
```
Parameter group -> Create custom group
  binlog_format = ROW (immediate)
  binlog_row_image = FULL (immediate)
  require_secure_transport = 0 (immediate)
```

**GCP Cloud SQL MySQL:**
```
Flags:
  binlog_row_image = full
  binlog_expire_logs_seconds = 604800
```

**Azure Flexible Server MySQL:**
```
Server parameters:
  binlog_row_image = full
  binlog_format = row
  require_secure_transport = off
  sql_generate_invisible_primary_key = off
  binlog_expire_logs_seconds = 604800
```

## LFC User Setup

### Create or Update LFC User

```sql
-- Connect as admin (root or equivalent)

-- Create LFC user (idempotent)
CREATE USER IF NOT EXISTS '<lfc_user>'@'%' IDENTIFIED BY '<password-from-file>';
ALTER USER '<lfc_user>'@'%' IDENTIFIED BY '<password-from-file>';

-- Grant privileges on target schema
GRANT ALTER, CREATE, CREATE ROUTINE, ALTER ROUTINE, DROP, EXECUTE,
      INDEX, SELECT, INSERT, DELETE, UPDATE ON <database>.* 
  TO '<lfc_user>'@'%';

-- Grant replication privileges (required for binlog CDC)
GRANT REPLICATION CLIENT ON *.* TO '<lfc_user>'@'%';
GRANT REPLICATION SLAVE ON *.* TO '<lfc_user>'@'%';

-- Grant auxiliary privileges
GRANT RELOAD, SHOW DATABASES ON *.* TO '<lfc_user>'@'%';

-- CDC (from the public mysql-privileges page): read every user database, and the auth plugin column
GRANT SELECT ON *.* TO '<lfc_user>'@'%';
GRANT SELECT (plugin, user) ON mysql.user TO '<lfc_user>'@'%';

FLUSH PRIVILEGES;
```

For CDC only, the [public page](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/mysql-privileges) needs just `REPLICATION SLAVE, REPLICATION CLIENT ON *.*`, `SELECT ON *.*`, and `SELECT (plugin, user) ON mysql.user`; the write grants above are for seeding test data as this user.

**MySQL in a container:** pass the binlog settings as server options, for example `docker.io/library/mysql:8.4 --server-id=1 --log-bin=mysql-bin --binlog-format=ROW --binlog-row-image=FULL --binlog-expire-logs-seconds=172800 --gtid-mode=ON --enforce-gtid-consistency=ON` (tested with integrated CDC).

### Verify LFC User

```sql
-- Connect as LFC user and run:
SELECT 1;
SELECT @@gtid_executed;
SHOW BINARY LOGS;
SHOW MASTER STATUS;
```

## Seed Tables for Demo/Testing

LFC uses two seed tables for testing ingestion:

```sql
-- Create schema/database (if needed)
CREATE SCHEMA IF NOT EXISTS <database>;

USE <database>;

-- Create intpk (integer primary key for query-based ingestion)
CREATE TABLE IF NOT EXISTS intpk (
  pk  SERIAL PRIMARY KEY,
  dt  TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  ops VARCHAR(255) DEFAULT 'insert',
  INDEX idx_dt (dt)
);

-- Create dtix (no explicit PK, for CDC testing)
CREATE TABLE IF NOT EXISTS dtix (
  pk  BIGINT,
  dt  TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  ops VARCHAR(255) DEFAULT 'insert',
  INDEX idx_dt (dt)
);

-- Seed 10 rows into each (run as <lfc_user>)
INSERT INTO intpk (dt) VALUES (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP()),
  (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP());

INSERT INTO dtix (pk, dt) SELECT @i := @i+1, CURRENT_TIMESTAMP() FROM (SELECT @i:=0) x, 
  (SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t;
```

## CDC Requirements (Binlog-based)

### Enable Binlog (Platform-Specific)

The binlog must be enabled **before** CDC is configured.

**Self-Managed / Podman:**
```
Edit my.cnf or start with:
  mysqld --log-bin=[path]  # Enables binary logging
  
Or if already running, verify:
  SHOW VARIABLES LIKE 'log_bin';  # Should return 'ON'
```

**AWS RDS MySQL/Aurora:**
```
RDS automatically enables binlog when you create the instance.
Verify: SHOW VARIABLES LIKE 'log_bin';
```

**GCP Cloud SQL MySQL:**
```
Binary logging is enabled by default.
Set flags: binlog_row_image = full
```

**Azure Flexible Server MySQL:**
```
Parameter: binlog_format = ROW
Parameter: binlog_row_image = full
Binary logging is enabled by default.
```

### Enable Binlog Parameters (Runtime)

```sql
-- For MySQL 8.0+ (most cloud instances)
SET GLOBAL binlog_format = 'ROW';
SET GLOBAL binlog_row_image = 'FULL';

-- Verify:
SHOW VARIABLES LIKE 'binlog_format';
SHOW VARIABLES LIKE 'binlog_row_image';
```

### Check Binlog Status

```sql
-- Show current binary log position (needed to start CDC)
SHOW MASTER STATUS;

-- Show list of binary logs (verify rotation)
SHOW BINARY LOGS;

-- Check retention (for recovery window)
SHOW VARIABLES LIKE 'binlog_expire_logs_seconds';
```

## MariaDB-Specific Configuration

### Enable Binlog at Startup (MariaDB)

```
Edit /etc/mysql/my.cnf:
  [mysqld]
  log-bin         # or log-bin=/path/to/mariadb-bin
  
Restart MariaDB.
```

### MariaDB Runtime Parameters

```sql
-- These are runtime-settable in MariaDB
SET GLOBAL binlog_format = 'row';
SET GLOBAL binlog_row_image = 'full';
SET GLOBAL require_secure_transport = 0;

-- Verify (log_bin should be 'ON' from startup)
SHOW GLOBAL VARIABLES LIKE 'log_bin';
SHOW GLOBAL VARIABLES LIKE 'binlog_format';
SHOW GLOBAL VARIABLES LIKE 'binlog_row_image';
```


## Password Rotation

```sql
-- Rotate LFC user password (via ALTER USER)
-- Connect as admin

ALTER USER '<lfc_user>'@'%' IDENTIFIED BY '<new-password>';

-- Verify by connecting as LFC user:
mysql -h <host> -u <lfc_user> -p<new-password> <database> -e "SELECT 1;"
```

## Troubleshooting

### Binary Log Not Enabled

**Symptom:** `SHOW MASTER STATUS` returns empty.

**Fix:**
- MySQL: Check parameter group (cannot enable at runtime). Requires startup parameter.
- MariaDB: Must set `--log-bin` at startup; cannot be enabled at runtime.

### Wrong Binlog Format

**Symptom:** CDC reports "STATEMENT" or "MIXED" format; changes not captured.

**Fix:**
```sql
SET GLOBAL binlog_format = 'ROW';
SHOW VARIABLES LIKE 'binlog_format';
```

### Binlog Retention Too Short

**Symptom:** Binlog position advances past available logs before CDC catches up.

**Fix:** Increase retention to at least 7 days. Self-managed MySQL 8.0:
```sql
SET PERSIST binlog_expire_logs_seconds = 604800;
```
RDS and Aurora MySQL don't allow `SET GLOBAL` for this. Use the RDS procedure (hours):
```sql
CALL mysql.rds_set_configuration('binlog retention hours', 168);
CALL mysql.rds_show_configuration;
```
Cloud SQL and Azure Flexible Server set retention through their own flags / server parameters (`binlog_expire_logs_seconds`).

### AWS RDS: Replication Privileges Denied

**Symptom:** `GRANT REPLICATION SLAVE` fails.

**Fix:** Run the grant as the RDS master user, which holds both privileges `WITH GRANT OPTION`. A user created by another non-master account can't pass them on:
```sql
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '<lfc_user>'@'%';
```
(`rds_replication` is an RDS **PostgreSQL** role; it doesn't exist on RDS MySQL.)

## Verification Checklist

Before starting LFC ingestion:

1. **Binlog enabled:**
   ```sql
   SHOW MASTER STATUS;  -- Should return pos, file, Binlog_Do_DB, etc.
   ```

2. **Correct parameters:**
   ```sql
   SELECT @@binlog_format, @@binlog_row_image, @@log_bin;
   -- Should be: 'ROW', 'FULL', 'ON'
   ```

3. **LFC user can replicate:**
   ```sql
   -- Connect as <lfc_user>
   SHOW MASTER STATUS;  -- Read-only, but should not error
   ```

4. **Seed tables populated:**
   ```sql
   SELECT COUNT(*) FROM intpk, dtix;
   ```

5. **Audit configured (optional):**
   ```sql
   SELECT * FROM mysql.general_log LIMIT 1;
   -- or check cloud audit logs (CloudWatch, Cloud Logging, Azure Monitor)
   ```
