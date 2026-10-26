# SQL Server Source Configuration for Lakeflow Connect

This guide documents the database configuration required for Lakeflow Connect (LFC) query-based ingestion and CDC on SQL Server instances.

## Quick Reference

| Requirement | Query-Based | Change Tracking (CT) | Change Data Capture (CDC) |
|---|---|---|---|
| **Server Feature** | None | Database-level flag | SQL Server Agent + CDC |
| **Table Primary Key** | Recommended | Required | Required for LFC |
| **User Privilege** | `SELECT` | + `VIEW CHANGE TRACKING` | + `CDC_ADMIN` role |
| **Data Capture** | Full rows | Row IDs only (which changed) | Before/after values |

## Overview

SQL Server supports two change-tracking mechanisms for LFC:
- **Change Tracking (CT):** Lightweight; tracks which rows changed (not values).
- **Change Data Capture (CDC):** Captures before/after values; requires SQL Server Agent.

LFC can use CT, CDC, or both modes. T-SQL batch separators (`GO`) must be split during execution.

### Modes Supported

| Mode | Platform | Change Values | Performance | Notes |
|------|----------|----------------|-------------|-------|
| CT only | All | No | Light | Best for DELETE tracking only |
| CDC only | All | Yes | Heavy | Full audit trail; requires SQL Server Agent |
| BOTH | All | Yes (CDC); tracking (CT) | Heavy | Full coverage; redundant |

## Prerequisites for Query-Based Ingestion

### SQL Server Edition & Features

| Feature | Express | Standard | Enterprise |
|---------|---------|----------|------------|
| Change Tracking | Yes | Yes | Yes |
| CDC (basic) | No | Yes | Yes |
| CDC (clustered columnstore) | No | No | Yes |
| Server audits | Limited | Yes | Yes |

> **GCP Cloud SQL SQL Server:** Express edition does not support CDC; use Change Tracking only.

### Server Configuration

No startup parameters required for CT/CDC. However, SQL Server Agent must run for CDC (not required for CT):

```sql
-- Check if SQL Server Agent is running
EXEC xp_servicecontrol N'QueryState', N'SQLServerAgentn';

-- Start SQL Server Agent (Windows only; managed platforms handle this)
EXEC xp_servicecontrol N'Start', N'SQLServerAgentn';
```

## LFC User Setup

LFC needs both a **login** (server-level) and a **user** (database-level) with appropriate roles.

### Create or Update LFC Login and User

```sql
-- Connect as DBA (e.g., sa or equivalent)

-- The database, if it doesn't exist yet
IF DB_ID(N'<database>') IS NULL CREATE DATABASE [<database>];
GO

-- ── CREATE LOGIN (server-level, in master) ──
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'<lfc_user>')
  CREATE LOGIN [<lfc_user>] WITH PASSWORD = N'<password-from-file>';

-- ALTER LOGIN to update password
ALTER LOGIN [<lfc_user>] WITH PASSWORD = N'<password-from-file>';

-- ── CREATE DATABASE USER (in target database) ──
USE [<database>];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'<lfc_user>')
  CREATE USER [<lfc_user>] FOR LOGIN [<lfc_user>] WITH DEFAULT_SCHEMA = dbo;

-- ── GRANT ROLES ──
ALTER ROLE db_owner ADD MEMBER [<lfc_user>];
ALTER ROLE db_ddladmin ADD MEMBER [<lfc_user>];

-- Verify roles
SELECT dp.name, r.name 
  FROM sys.database_role_members drm
  JOIN sys.database_principals dp ON drm.member_principal_id = dp.principal_id
  JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
  WHERE dp.name = N'<lfc_user>';
```

### Verify LFC User

```sql
-- Connect as LFC user to target database
USE [<database>];
SELECT SYSTEM_USER;
SELECT USER;
SELECT 1;
```

## Seed Tables for Demo/Testing

Two seed tables for query-based ingestion and CDC (tested end to end, SQL Server 2022 Developer). `dt` is the query-based cursor: `NOT NULL` with a default (so inserts never leave it NULL), indexed, and bumped on every update by a trigger.

```sql
USE [<database>];

-- intpk: identity primary key (change tracking needs a primary key)
CREATE TABLE dbo.intpk (
  pk  INT IDENTITY NOT NULL PRIMARY KEY,
  dt  DATETIME NOT NULL DEFAULT GETDATE(),
  ops VARCHAR(255) DEFAULT 'insert'
);
CREATE INDEX idx_intpk_dt ON dbo.intpk (dt);

-- dtix: no primary key (query-based: APPEND_ONLY; CDC: SQL Server CDC, not change tracking)
CREATE TABLE dbo.dtix (
  pk  BIGINT,
  dt  DATETIME NOT NULL DEFAULT GETDATE(),
  ops VARCHAR(255) DEFAULT 'insert'
);
CREATE INDEX idx_dtix_dt ON dbo.dtix (dt);
GO
CREATE OR ALTER TRIGGER dbo.intpk_set_dt ON dbo.intpk AFTER UPDATE AS
  BEGIN SET NOCOUNT ON; UPDATE t SET dt = GETDATE() FROM dbo.intpk t JOIN inserted i ON i.pk = t.pk; END
GO
CREATE OR ALTER TRIGGER dbo.dtix_set_dt ON dbo.dtix AFTER UPDATE AS
  BEGIN SET NOCOUNT ON; UPDATE t SET dt = GETDATE() FROM dbo.dtix t JOIN inserted i ON i.pk = t.pk; END
GO
-- Seed 10 rows each
INSERT INTO dbo.intpk (ops) SELECT TOP 10 'insert' FROM sys.all_objects;
INSERT INTO dbo.dtix (pk) SELECT TOP 10 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects;
```

## Set up CT and CDC with the Lakeflow utility script (recommended)

The [public setup](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/sql-server-utility) is a Databricks script that installs three procedures in the source database: `lakeflowSetupChangeTracking`, `lakeflowSetupChangeDataCapture`, and `lakeflowFixPermissions`. It replaces the manual statements in the next two sections. Tested on SQL Server 2022 in a container:

1. Download the script from the page (`utility_script-<hash>.sql`) and run it **in the source database** as a `db_owner` (for example `sa`): `sqlcmd ... -d <database> -i utility_script.sql`. It prints `✓` per object; check `SELECT dbo.lakeflowUtilityVersion()`.
2. Give the ingestion user a user in `master` too, or the server-scoped grants fail (`⚠ Could not grant EXECUTE on sys.sp_statistics_100 in master: Cannot find the user`):
   ```sql
   USE master; CREATE USER [<lfc_user>] FOR LOGIN [<lfc_user>];
   ```
3. Enable tracking and grant, per table. Change tracking needs a primary key; use CDC for tables without one, or for SCD Type 2:
   ```sql
   USE [<database>];
   EXEC dbo.lakeflowSetupChangeTracking @Tables = 'dbo.intpk', @User = '<lfc_user>', @Retention = '2 DAYS', @CreateDdlSupportingObjects = 1;
   EXEC dbo.lakeflowSetupChangeDataCapture @Tables = 'dbo.dtix', @User = '<lfc_user>';
   EXEC dbo.lakeflowFixPermissions @User = '<lfc_user>', @Tables = 'dbo.intpk,dbo.dtix';
   ```
   `@Tables` also takes `'ALL'` and `'SCHEMAS:Sales,HR'`. CDC needs SQL Server Agent running; in the `mcr.microsoft.com/mssql/server` image, set `MSSQL_AGENT_ENABLED=true`.
4. The ingestion user doesn't need `db_owner` once this is done: `ALTER ROLE db_owner DROP MEMBER [<lfc_user>]`. `db_owner` is only for whoever runs the setup.
5. **Integrated CDC on many tables:** `lakeflowFixPermissions` doesn't grant `VIEW DATABASE PERFORMANCE STATE`. A 450-table integrated pipeline failed its first update with `PIPELINE_NON_RETRYABLE_ANALYSIS_INTERNAL_ERROR` and `GENERIC_SNAPSHOT_FAILURE` ("STREAM_FAILED ... VIEW DATABASE PERFORMANCE STATE permission denied in database <database>"). A 20-row table ran without it. Grant it, then start a new update, since the failed one doesn't create one: `GRANT VIEW DATABASE PERFORMANCE STATE TO [<lfc_user>];` (tested 2026-10-25, SQL Server 2022 CU27). `VIEW DATABASE STATE` implies `VIEW DATABASE PERFORMANCE STATE`: while the login holds the first, revoking the second alone changes nothing (tested 2026-10-26, SQL Server 2022 CU27).
6. **Utility 1.5 installed, then 1.7 with no flag:** the update fails with `INGESTION_GATEWAY_DDL_OBJECTS_MISSING` ("DDL objects missing on table ... Execute the DDL objects script and full refresh the table"), then `PIPELINE_NON_RETRYABLE_ANALYSIS_CLIENT_ERROR`. Tested 2026-10-25, SQL Server 2022 CU27, on a database with a non-default collation. Run the DDL objects script the message names, then full refresh the table. A rerun with the flag on the change-tracking setup passed; the cause isn't isolated.

## Change Tracking (CT) Configuration

### Enable Change Tracking on Database

```sql
-- Connect as DBA to target database
USE [<database>];

IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = db_id())
BEGIN
  ALTER DATABASE [<database>] SET CHANGE_TRACKING = ON
    (CHANGE_RETENTION = 3 DAYS, AUTO_CLEANUP = ON);
END;

-- Verify
SELECT database_id, min_valid_version, time_of_earliest_change 
  FROM sys.change_tracking_databases 
  WHERE database_id = db_id();
```

### Enable Change Tracking on Tables

```sql
-- Connect as LFC user

-- Enable CT on intpk (with column tracking)
IF NOT EXISTS (
  SELECT 1 FROM sys.change_tracking_tables ctt
  JOIN sys.tables t ON ctt.object_id = t.object_id
  WHERE t.schema_id = SCHEMA_ID('dbo') AND t.name = 'intpk'
)
  ALTER TABLE dbo.intpk ENABLE CHANGE_TRACKING 
    WITH (TRACK_COLUMNS_UPDATED = ON);

-- Verify
SELECT t.name, ctt.track_columns_updated 
  FROM sys.change_tracking_tables ctt
  JOIN sys.tables t ON ctt.object_id = t.object_id
  WHERE t.schema_id = SCHEMA_ID('dbo');
```

### Query Change Tracking

```sql
-- Get version range for consistency
SELECT CHANGE_TRACKING_MIN_VALID_VERSION('dbo', 'intpk') AS min_version,
       CHANGE_TRACKING_CURRENT_VERSION() AS current_version;

-- Get changes for intpk
SELECT * FROM CHANGETABLE(CHANGES dbo.intpk, 0) AS ct
  WHERE ct.SYS_CHANGE_VERSION > <last_processed_version>;

-- Output columns: SYS_CHANGE_ID, SYS_CHANGE_OPERATION (0=DELETE, 1=INSERT, 2=UPDATE),
--                 SYS_CHANGE_COLUMNS (bitmap), SYS_CHANGE_CONTEXT (NULL)
```

## Change Data Capture (CDC) Configuration

### Enable CDC on Database

```sql
-- Connect as DBA to target database
USE [<database>];

-- CDC requires SQL Server Agent to be running
EXEC xp_servicecontrol N'Start', N'SQLServerAgent';

-- Enable CDC
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = db_name() AND is_cdc_enabled = 1)
BEGIN
  EXEC sys.sp_cdc_enable_db;
END;

-- Verify
SELECT is_cdc_enabled FROM sys.databases WHERE name = db_name();
```

### Platform-Specific CDC Enable

**Azure SQL / Self-Managed:**
```sql
EXEC sys.sp_cdc_enable_db;
```

**AWS RDS:** `EXEC msdb.dbo.rds_cdc_enable_db '<database>';`

**GCP Cloud SQL:** `EXEC msdb.dbo.gcloudsql_cdc_enable_db '<database>';`

### Enable CDC on Tables

```sql
-- Connect as LFC user

-- Enable CDC on dtix table
IF NOT EXISTS (
  SELECT 1 FROM sys.tables t
  JOIN sys.schemas s ON t.schema_id = s.schema_id
  WHERE t.is_tracked_by_cdc = 1 AND s.name = 'dbo' AND t.name = 'dtix'
)
BEGIN
  EXEC sys.sp_cdc_enable_table
    @source_schema = N'dbo',
    @source_name = N'dtix',
    @role_name = NULL,  -- No specific role; uses db_datareader
    @supports_net_changes = 0;  -- Aggregate changes (1 = net changes only)
END;

-- Verify
SELECT t.name, cdc.source_schema, cdc.captured_column_list
  FROM sys.tables t
  JOIN cdc.change_tables cdc ON t.object_id = cdc.source_object_id
  WHERE t.schema_id = SCHEMA_ID('dbo');
```

### Query CDC

```sql
-- Get CDC capture instance name
SELECT source_schema, source_table, capture_instance
  FROM cdc.change_tables
  WHERE source_schema = 'dbo' AND source_table = 'dtix';

-- Get changes (assume capture_instance is 'dbo_dtix_CT')
SELECT * FROM cdc.fn_cdc_get_all_changes_dbo_dtix(
  <start_lsn>,  -- Last LSN processed by LFC
  <end_lsn>,    -- Current end of log
  'all'         -- Return 'all' or 'net' (net changes only)
);

-- Get current max LSN
SELECT sys.fn_cdc_get_max_lsn() AS max_lsn;
SELECT sys.fn_cdc_increment_lsn(<lsn>);  -- Increment LSN for next query
```


## Password Rotation

```sql
-- Rotate LFC login password
-- Connect as DBA to master database

ALTER LOGIN [<lfc_user>] WITH PASSWORD = N'<new-password>';

-- Verify by connecting as LFC user
sqlcmd -S <host>,<port> -U <lfc_user> -P <new-password> -d <database> -Q "SELECT 1;"
```

## Troubleshooting & Gotchas

### SQL Server Agent Not Running (CDC Only)

**Symptom:** `sp_cdc_enable_db` or `sp_cdc_enable_table` fails; "Cannot find procedure sp_cdc_*".

**Fix:** Start SQL Server Agent (managed platforms handle this automatically):
```sql
EXEC xp_servicecontrol N'Start', N'SQLServerAgent';
```

### Cannot Enable CDC on Express Edition

**Symptom:** `sp_cdc_enable_db` fails on SQL Server Express.

**Fix:** Use Change Tracking (CT) mode only:
```sql
ALTER DATABASE [<database>] SET CHANGE_TRACKING = ON;
```

### CDC Capture Instance Name Mismatch

**Symptom:** Query references wrong capture instance name.

**Fix:** Query `cdc.change_tables` to get the correct instance:
```sql
SELECT capture_instance FROM cdc.change_tables WHERE source_table = 'dtix';
```

On a case-insensitive database, a capture instance named in a different case from its table fails the update with `INGESTION_GATEWAY_CDC_LOG_TRUNCATED` ("CDC log truncated, full refresh required"), not a missing-table error (tested 2026-10-25, SQL Server 2022 CU27). Fix the name from `cdc.change_tables`, then full refresh the table.

### Cannot Alter User Role (RDS/Managed)

**Symptom:** `ALTER ROLE db_owner ADD MEMBER` fails; permission denied.

**Fix (AWS RDS):** Use `sp_grantdbaccess`:
```sql
EXEC sp_grantdbaccess @loginame = '<lfc_user>', @name_in_db = '<lfc_user>';
```

### Change Tracking Retention Too Short

**Symptom:** LFC cannot query changes; "Change tracking version too old".

**Fix:** Increase retention:
```sql
ALTER DATABASE [<database>] SET CHANGE_TRACKING (CHANGE_RETENTION = 7 DAYS);
```

### Login Failed - User Does Not Exist

**Symptom:** Connection fails; "Login failed for user '<lfc_user>'".

**Fix:** Verify both login and user exist:
```sql
USE master;
SELECT 1 FROM sys.sql_logins WHERE name = '<lfc_user>';
USE [<database>];
SELECT 1 FROM sys.database_principals WHERE name = '<lfc_user>';
```

### TRUNCATE on a Change-Tracking Table

**Symptom:** After `TRUNCATE TABLE` on a change-tracking table and five inserts, the update FAILED with `INGESTION_GATEWAY_UNTRACEABLE_TABLE_MODIFICATION`, and no new rows arrived (tested 2026-10-25, SQL Server 2022 CU27).

**Fix:** Full refresh that table. The full refresh matched the source.

### Capture Instance Dropped

**Symptom:** After `sp_cdc_disable_table` on a table's capture instance, two updates COMPLETED with no error event, and a changed row didn't arrive (tested 2026-10-25, SQL Server 2022 CU27). After CDC was re-enabled, a full refresh of the table delivered the row.

**Fix:** After changing a capture instance, full refresh the table.

### Query-Based Cursor on datetime2(7)

**Symptom:** A query-based pipeline with a `datetime2(7)` cursor missed rows whose seventh fractional digit changed: 0 of 3 arrived, while the same data with a `datetime2(6)` cursor arrived 2 of 2. The update COMPLETED (tested 2026-10-25, SQL Server 2022 CU27, one run).

**Fix:** Use a `datetime2(6)` or lower cursor until the case is checked.

### Governor Limits on the Gateway's Login

**Symptom:** Two cases, tested 2026-10-25 on SQL Server 2022 CU27 (Developer, scaled down):
- The query governor cost limit (`sp_configure 'query governor cost limit'`) refused the snapshot's full read at compile with error 8649 (estimated cost 91); nothing ran.
- A Resource Governor `REQUEST_MAX_CPU_TIME_SEC` of 1 ended a 10,000,000-row keyless snapshot early. The update reported COMPLETED with 3,574,695 rows and no error event.

Both limits count compile cost or CPU time, not elapsed time.

**Fix:** Remove or raise the limits for the gateway's login, then count the rows after `SNAPSHOT_COMPLETED` (see the checks below).

### Scoping to One Schema

**Symptom:** A pipeline scoped to one 100-table schema of three still shows "Found 300 table(s) in the connection" in Schema Exploration (tested 2026-10-25, SQL Server 2022 CU27). Discovery reads the whole connection; the scope cuts the ingestion reads.

**Fix:** Expect discovery to count the whole connection. Scope the pipeline's tables to limit what is read. The count also includes every other database the login can see in the container: with two pipeline databases of two and three tables, Schema Exploration reported 5 (tested 2026-10-26, SQL Server 2022 CU27).

### Keyless Tables: Duplicate Rows Collapse

**Symptom:** A CDC table without a primary key holds two identical rows, `(1,a)` and `(1,a)`. The snapshot lands one row. After one copy is updated to `(1,c)`, the destination holds `(1,c)` and `(2,b)`, and the other copy is gone; the source still has three rows (tested 2026-10-26, SQL Server 2022 CU27, standard gateway, one run).

**Cause:** For a keyless table the applier uses all non-LOB columns as the merge key, so identical rows count as one key.

**Fix:** Add a primary key before the first load (not tested here). Until then, compare the destination with the distinct source rows.

### Column Added After the First Load

**Symptom:** A column added with `ALTER TABLE ... ADD` after the first load (tested 2026-10-26, SQL Server 2022 CU27, one run per mode):
- Standard CDC and change tracking (standard gateway): the gateway logs `Detected a schema change`; the next update COMPLETED with the column added. Earlier rows are NULL in it, and the new row carries its value. No full refresh.
- Integrated CDC: the running update was cancelled with "... due to a schema change ... will be restarted", and the pipeline started a new one with cause `SCHEMA_CHANGE`. The restart replayed the table's applier snapshot flow; the column and the new row arrived in it, with no full refresh.

**Fix:** No full refresh is needed for the column. On integrated CDC, wait for the restarted update before you count rows.

### Revoked VIEW DATABASE STATE: Added Column's Row Never Arrives

**Symptom:** With `VIEW DATABASE STATE` revoked from the ingestion login, a column was added and one row written. The gateway logged `Detected a schema change`, and the row was absent after two updates. No error appeared in the events or the updates. The control, without the revoke, delivered the row after the second update (tested 2026-10-26, SQL Server 2022 CU27, one run per arm).

**Fix:** Keep `VIEW DATABASE STATE` on the ingestion login, and check the new row's count after each schema change. Whether a full refresh recovers the row wasn't tested.

### Change Tracking DDL Objects Warned as Removable

**Symptom:** With the utility's `@CreateDdlSupportingObjects = 1`, the gateway logs a WARN: "Non-trigger-based DDL for Change Tracking is active and CT DDL support objects were detected ... may be safely removed". The update still COMPLETED (tested 2026-10-26, SQL Server 2022 CU27, change tracking, standard gateway).

**Fix:** Nothing is needed for the run. Removing the objects wasn't tested.

## Column Types

Tested 2026-10-26 on SQL Server 2022 CU27, standard and integrated CDC, with the same destination types in both.

| Source type | Lands as | Notes |
|---|---|---|
| `HIERARCHYID` | string of the binary's hex | `/1/2/` arrives as `5B40`; the root `/` arrives as an empty string. No warning. |
| `GEOGRAPHY` | binary (WKB) | POINT with SRID 4326 arrives as WKB without the SRID |
| `DATETIMEOFFSET(7)` | timestamp (UTC instant) | the offset and the 100 ns digit are dropped: `2026-10-25 12:34:56.1234567 +05:30` arrives as `2026-10-25 07:04:56.123456` |
| `DATETIME2(7)` | timestamp at microseconds | the 100 ns digit is dropped: `...9999999` arrives as `...999999` |
| `TIME(7)` | string `HH:mm:ss.fffffff` | all 7 digits kept |
| `MONEY` | decimal(19,4) | both extremes exact |
| `UNIQUEIDENTIFIER` | string, upper-case GUID | |
| `XML`, `SQL_VARIANT` | string | `SQL_VARIANT` values arrive as text |
| `ROWVERSION` | binary | never NULL |
| `NVARCHAR(MAX)` | string | Unicode kept |

The losses are silent: the events show no warning. If the offset or the 100 ns digit matters, keep it in another column (not tested).

## Platform-Specific Notes

| Platform | CDC Stored Proc | Notes |
|---|---|---|
| AWS RDS | `msdb.dbo.rds_cdc_enable_db` | Some roles restricted; may need AWS support |
| GCP Cloud SQL | `msdb.dbo.gcloudsql_cdc_enable_db` | Express edition doesn't support CDC; use CT only |
| Azure SQL DB/MI | `sys.sp_cdc_enable_db` | Standard procedure; both CT and CDC supported |
| Availability Groups | Standard proc | Ensure database is ONLINE and HEALTHY before enabling |

## Verification Checklist

Before starting LFC ingestion:

1. **LFC login and user exist:**
   ```sql
   USE master; SELECT 1 FROM sys.sql_logins WHERE name = N'<lfc_user>';
   USE [<database>]; SELECT 1 FROM sys.database_principals WHERE name = N'<lfc_user>';
   ```

2. **LFC user has db_owner and db_ddladmin roles:**
   ```sql
   USE [<database>];
   SELECT r.name FROM sys.database_role_members drm
     JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
     WHERE drm.member_principal_id = (SELECT principal_id FROM sys.database_principals WHERE name = '<lfc_user>');
   ```

3. **Change Tracking enabled (if applicable):**
   ```sql
   SELECT is_change_tracking_enabled FROM sys.databases WHERE name = db_name();
   ```

4. **Tables populated:**
   ```sql
   SELECT COUNT(*) FROM dbo.intpk, dbo.dtix;  -- Both should have 10 rows
   ```

5. **SQL Server Agent running (if using CDC):**
   ```sql
   EXEC xp_servicecontrol N'QueryState', N'SQLServerAgent';
   ```

## Checks for tests on a SQL Server source

Harness mistakes from the 2026-10-25 round. Each one made a case invalid, not a finding:

- **Tracing the gateway's statements:** filter the Extended Events session on the gateway's login (`sqlserver.username`), not `database_name`. Its metadata queries run in other databases too, so a database filter catches 0 rows.
- **`VIEW SERVER STATE` is a server permission:** `GRANT` it in `master`. In a user database it fails with "can only be granted when the current database is master".
- **Enable CDC on the database first:** run `sys.sp_cdc_enable_db` before the utility's CDC setup. Without it the setup creates no `lakeflow_` capture instance.
- **Read effective permissions back after every GRANT or REVOKE:** `EXECUTE AS LOGIN = '<login>'; SELECT permission_name FROM fn_my_permissions(NULL, 'DATABASE'); REVERT;`. `CONCAT_WS` needs at least three arguments, which is what broke the listing in that round. A schema-level grant still covers a table after a table-level REVOKE.
- **Match a literal `_` in `LIKE` with `[_]`:** an `ESCAPE` clause with more than one character fails with Msg 506.
- **Lag can read healthy with an empty destination:** an integrated pipeline showed lag 5 seconds and zero pending snapshots for about 5 hours while its destination tables had 0 rows (tested 2026-10-25, 450 tables, SQL Server 2022). Count the destination rows and read the table's history: `DESCRIBE HISTORY` showed MERGE versions with `numTargetRowsInserted` 0. The grant had been added after a failed first start, so the cause isn't isolated; the gateway's snapshot events show whether rows were read.
