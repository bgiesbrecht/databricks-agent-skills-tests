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

LFC uses two seed tables for testing (run as LFC user):

```sql
USE [<database>];

-- intpk: integer identity PK for query-based ingestion
CREATE TABLE dbo.intpk (
  pk  INT IDENTITY NOT NULL PRIMARY KEY,
  dt  DATETIME,
  ops VARCHAR(255) DEFAULT 'insert'
);
CREATE INDEX idx_dt ON dbo.intpk (dt);

-- dtix: no explicit PK, for CDC testing
CREATE TABLE dbo.dtix (
  pk  BIGINT,
  dt  DATETIME,
  ops VARCHAR(255) DEFAULT 'insert'
);
CREATE INDEX idx_dt ON dbo.dtix (dt);

-- Seed 10 rows
INSERT INTO dbo.intpk (dt) VALUES (GETDATE()), (GETDATE()), (GETDATE()), (GETDATE()), (GETDATE()),
  (GETDATE()), (GETDATE()), (GETDATE()), (GETDATE()), (GETDATE());
INSERT INTO dbo.dtix (pk, dt) VALUES (1, GETDATE()), (2, GETDATE()), (3, GETDATE()), (4, GETDATE()), (5, GETDATE()),
  (6, GETDATE()), (7, GETDATE()), (8, GETDATE()), (9, GETDATE()), (10, GETDATE());
```

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
