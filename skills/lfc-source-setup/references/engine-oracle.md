# Oracle Source Configuration for Lakeflow Connect

This guide documents the database configuration required for Lakeflow Connect (LFC) query-based ingestion and CDC (LogMiner-based) on Oracle 11g through 23c instances.

## Quick Reference

| Requirement | Query-Based | CDC (LogMiner) |
|---|---|---|
| **Database Mode** | Normal | ARCHIVELOG (required) |
| **Supplemental Logging** | None | PRIMARY KEY columns minimum |
| **User Type** | PDB-local | CDB common (C##) or PDB-local (RDS) |
| **User Privilege** | `SELECT` | + `LOGMINING`, `SELECT ANY TRANSACTION` |
| **Cursor Column** | Any `TIMESTAMP` | Not needed; LogMiner tracks LSN/SCN |

## Overview

Oracle uses **LogMiner** for CDC, which reads redo logs to capture DML and DDL changes. Requirements:
1. Database in ARCHIVELOG mode (not NOARCHIVELOG)
2. Supplemental logging enabled (PRIMARY KEY columns minimum)
3. For CDB/PDB (Oracle 12c+): Common user (C##) at CDB$ROOT for LogMiner; local user in PDB for seed tables

### Platform-Specific Strategies

| Platform | User Location | Notes |
|----------|---|---|
| Self-Managed / Podman | C## common user at CDB$ROOT | UC connection string is CDB listener |
| RDS Oracle | PDB-local user | No common users; uses rdsadmin procedures |

## Prerequisites for Query-Based Ingestion

### Database Mode: ARCHIVELOG

Oracle must be in ARCHIVELOG mode to retain redo logs for LogMiner. In NOARCHIVELOG mode, logs are overwritten after checkpoint.

```sql
-- Check current mode
SELECT LOG_MODE FROM V$DATABASE;
-- Should return 'ARCHIVELOG' (not 'NOARCHIVELOG')
```

### Enable ARCHIVELOG (if Needed)

This requires the database to be in MOUNT mode (not OPEN). Plan for downtime.

**Self-Managed / Podman:**

```sql
-- Connect as SYSDBA
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
SELECT LOG_MODE FROM V$DATABASE;  -- Verify
```

Or via `rman`:

```bash
rman target / <<EOF
  SHUTDOWN IMMEDIATE;
  STARTUP MOUNT;
  SQL 'ALTER DATABASE ARCHIVELOG';
  SQL 'ALTER DATABASE OPEN';
  SQL 'SELECT LOG_MODE FROM V$DATABASE';
  EXIT;
EOF
```

**RDS Oracle:**

RDS automatically enables ARCHIVELOG when you set the backup retention window. No manual action needed.

### Archive Log Retention (Flash Recovery Area)

LFC requires archive logs available for ≥48 hours. Set in FRA:

**Self-Managed / Podman:**

```sql
-- Connect as SYSDBA
ALTER SYSTEM SET db_recovery_file_dest = '/opt/oracle/oradata/fra' SCOPE=BOTH;
ALTER SYSTEM SET db_recovery_file_dest_size = 10G SCOPE=BOTH;
ALTER SYSTEM SET db_flashback_retention_target = 2880 SCOPE=BOTH;  -- 2 days

-- Pin LogMiner dictionary into redo
BEGIN DBMS_LOGMNR_D.BUILD(OPTIONS => DBMS_LOGMNR_D.STORE_IN_REDO_LOGS); END;
/
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
```

**RDS Oracle:**

```sql
-- RDS manages FRA automatically; set retention via rdsadmin
BEGIN
  rdsadmin.rdsadmin_util.set_configuration(
    name => 'archivelog retention hours',
    value => '48'
  );
END;
/
```

## Set up with the Databricks setup package (recommended)

The [public setup](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/oracle-integrated-setup) supports Oracle 12c to 26ai (not RAC, standby, or multi-tenant RDS) and uses a Databricks PL/SQL package, `DBX_ORACLE_SETUP_UTIL`, instead of hand-written grants. Tested on `docker.io/gvenzl/oracle-free:23` (which is now 26ai Free 23.26; CDB `FREE`, PDB `FREEPDB1`), as `sqlplus / as sysdba` inside the container: `VALIDATE_SETUP` passes, and both query-based ingestion and integrated CDC (snapshot, then inserts, updates and deletes, on a table with a primary key and one without) run with this user. The UC connection needs `service_name` = the CDB's service (`FREE`), see **lfc-source-setup** step 2. A workspace where Oracle CDC isn't enabled refuses the pipeline with `Ingestion source 'ORACLE' is not supported in your workspace`.

```sql
-- 1. Recovery area and ARCHIVELOG (restarts the database; the container keeps running)
host mkdir -p /opt/oracle/oradata/fra
ALTER SYSTEM SET db_recovery_file_dest_size = 10G SCOPE=BOTH;
ALTER SYSTEM SET db_recovery_file_dest = '/opt/oracle/oradata/fra' SCOPE=BOTH;
SHUTDOWN IMMEDIATE
STARTUP MOUNT
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ALTER PLUGGABLE DATABASE ALL OPEN;
-- SAVE STATE, or the PDB stays MOUNTED after the next restart
ALTER PLUGGABLE DATABASE ALL SAVE STATE;
-- 2. Supplemental logging
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS;
```

Then keep archive logs 48 hours (`rman target /` → `CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 2 DAYS;`), download the package script from the page (`dbx-oracle-setup-package-<hash>.sql`), run it in `CDB$ROOT` as SYSDBA, and create the user with it. The user must be uppercase and, in a CDB, start with `C##`:

```sql
BEGIN DBX_ORACLE_SETUP_UTIL.CREATE_USER('C##LFC_USER', '<password-from-file>', 'USERS', 'TEMP'); END;
/
BEGIN DBX_ORACLE_SETUP_UTIL.GRANT_PERMISSIONS('C##LFC_USER'); END;
/
-- after the tables exist (see the seed below): SELECT on a schema in a PDB
BEGIN DBX_ORACLE_SETUP_UTIL.GRANT_SELECT_PERMISSIONS('C##LFC_USER', '<SCHEMA>', '<PDB>'); END;
/
-- prints "Privilege validation passed"
BEGIN DBX_ORACLE_SETUP_UTIL.VALIDATE_SETUP('C##LFC_USER'); END;
/
```

- **No comment after a `;`** in these scripts. Oracle 23 rejects it (`ORA-03405: End of query reached; no additional text should follow`), and with `whenever sqlerror exit` the rest of the script is skipped. Keep comments on their own lines.
- **Check supplemental logging yourself:** `SELECT supplemental_log_data_min, supplemental_log_data_pk FROM v$database` must show `YES YES`. In one run `VALIDATE_SETUP` printed "Pre-requisite checks passed" while both were `NO`.

`GRANT_SELECT_PERMISSIONS` grants only the tables that exist when it runs: rerun it after adding tables. The same user works for query-based ingestion and CDC: UC connection `user` `C##LFC_USER` with `service_name` `FREE` (the CDB), and the PDB (`FREEPDB1`) as `source_catalog` in pipelines. For SQL through a connection (`remote_query`), use a second connection with `service_name` `FREEPDB1`: a `service_name =>` argument doesn't override the connection's. The manual grants below are the older way and are kept for reference.

## LFC User Setup

### Platform-Specific User Strategies

#### Self-Managed / Podman: Common User (CDB$ROOT)

LogMiner must run as a **common user** (prefixed `C##`) at CDB$ROOT, not in PDB:

```sql
-- Connect as SYSDBA to CDB$ROOT

-- Create common LFC user
CREATE USER C##<lfc_user> IDENTIFIED BY "<password-from-file>" CONTAINER=ALL;
ALTER USER C##<lfc_user> IDENTIFIED BY "<password-from-file>" CONTAINER=ALL;

-- Grant basic privileges
GRANT CONNECT, RESOURCE, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE, UNLIMITED TABLESPACE TO C##<lfc_user> CONTAINER=ALL;

-- Grant CDC / LogMiner privileges
GRANT CREATE SESSION, SELECT ANY TRANSACTION, EXECUTE_CATALOG_ROLE, SELECT ANY DICTIONARY, LOGMINING, FLASHBACK ANY TABLE, SELECT ANY TABLE TO C##<lfc_user> CONTAINER=ALL;
-- Every object the gateway's validator checks, one by one: SELECT ANY DICTIONARY doesn't satisfy the check
-- (without these, CDC_NOT_ENABLED "Requires following permissions : SELECT on GV_$INSTANCE, SELECT on GV_$SESSION, SELECT on DBA_SEGMENTS")
GRANT EXECUTE ON DBMS_LOGMNR TO C##<lfc_user> CONTAINER=ALL;
GRANT EXECUTE ON DBMS_LOGMNR_D TO C##<lfc_user> CONTAINER=ALL;
GRANT SELECT ON DBA_SEGMENTS TO C##<lfc_user> CONTAINER=ALL;
BEGIN
  FOR v IN (SELECT column_value n FROM TABLE(sys.odcivarchar2list('TRANSACTION','DATABASE','CONTAINERS','PDBS','SESSION',
            'INSTANCE','LOGFILE','LOG','ARCHIVED_LOG','LOGMNR_CONTENTS','PARAMETER'))) LOOP
    EXECUTE IMMEDIATE 'GRANT SELECT ON V_$' || v.n || ' TO C##<lfc_user> CONTAINER=ALL';
    EXECUTE IMMEDIATE 'GRANT SELECT ON GV_$' || v.n || ' TO C##<lfc_user> CONTAINER=ALL';
  END LOOP;
END;
/

-- Multi-PDB access (optional):
ALTER USER C##<lfc_user> SET CONTAINER_DATA=ALL CONTAINER=CURRENT;
GRANT SET CONTAINER TO C##<lfc_user> CONTAINER=ALL;
```

#### RDS Oracle: PDB-Local User

RDS does not allow common users. Use a **PDB-local user** and rdsadmin procedures:

```sql
-- Connect as admin (rdsadmin) in the PDB

-- Create PDB-local user
CREATE USER <lfc_user> IDENTIFIED BY "<password-from-file>";
ALTER USER <lfc_user> IDENTIFIED BY "<password-from-file>";

-- Grant basic privileges
GRANT CONNECT, RESOURCE TO <lfc_user>;
GRANT CREATE TABLE, CREATE VIEW, CREATE SEQUENCE, CREATE PROCEDURE TO <lfc_user>;
GRANT UNLIMITED TABLESPACE TO <lfc_user>;

-- Grant CDC / LogMiner privileges
GRANT CREATE SESSION, SELECT ANY TRANSACTION, SELECT ANY DICTIONARY, LOGMINING, FLASHBACK ANY TABLE, SELECT ANY TABLE TO <lfc_user>;
GRANT EXECUTE_CATALOG_ROLE TO <lfc_user>;

-- Grant V$ access via rdsadmin (repeat for other required V$ views)
BEGIN
  rdsadmin.rdsadmin_util.grant_sys_object(p_grantee => UPPER('<lfc_user>'), p_privilege => 'SELECT', p_obj_name => 'V_$DATABASE');
  rdsadmin.rdsadmin_util.grant_sys_object(p_grantee => UPPER('<lfc_user>'), p_privilege => 'SELECT', p_obj_name => 'V_$TRANSACTION');
  rdsadmin.rdsadmin_util.grant_sys_object(p_grantee => UPPER('<lfc_user>'), p_privilege => 'SELECT', p_obj_name => 'GV_$LOGMNR_CONTENTS');
END;
/
```

### Verify LFC User

```sql
-- For common user (CDB$ROOT):
-- Connect as C##<lfc_user> to CDB service
SELECT * FROM DUAL;
SELECT DBMS_LOGMNR_D.BUILD(OPTIONS => DBMS_LOGMNR_D.STORE_IN_REDO_LOGS) FROM DUAL;

-- For PDB-local user:
-- Connect as <lfc_user> to PDB service
SELECT * FROM DUAL;
```

## Seed Tables for Demo/Testing

Seed tables live in a schema in the **PDB**. A table owner with no password (`NO AUTHENTICATION`) keeps the schema separate from the ingestion user. `DT` is the query-based cursor: `NOT NULL`, indexed, and bumped on every update by a trigger. Run as SYSDBA:

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER LFC NO AUTHENTICATION DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;
CREATE TABLE LFC.INTPK (PK NUMBER PRIMARY KEY, DT TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL, OPS VARCHAR2(255) DEFAULT 'insert');
CREATE INDEX LFC.IDX_INTPK_DT ON LFC.INTPK (DT);
CREATE TABLE LFC.DTIX (PK NUMBER, DT TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL, OPS VARCHAR2(255) DEFAULT 'insert');
CREATE INDEX LFC.IDX_DTIX_DT ON LFC.DTIX (DT);
-- no primary key: log every column
ALTER TABLE LFC.DTIX ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
CREATE OR REPLACE TRIGGER LFC.INTPK_SET_DT BEFORE UPDATE ON LFC.INTPK FOR EACH ROW BEGIN :NEW.DT := SYSTIMESTAMP; END;
/
CREATE OR REPLACE TRIGGER LFC.DTIX_SET_DT BEFORE UPDATE ON LFC.DTIX FOR EACH ROW BEGIN :NEW.DT := SYSTIMESTAMP; END;
/
INSERT INTO LFC.INTPK (PK) SELECT LEVEL FROM DUAL CONNECT BY LEVEL <= 10;
INSERT INTO LFC.DTIX (PK) SELECT LEVEL FROM DUAL CONNECT BY LEVEL <= 10;
COMMIT;
```

> **No identity columns:** Oracle has them (12c and later), but LogMiner-based CDC doesn't support them, so use `NUMBER PRIMARY KEY` filled by the application or a sequence. Names are limited to 30 characters, and types added after 12.2 (`BOOLEAN`, `JSON`, `VECTOR`) aren't supported.

## Supplemental Logging Configuration

Supplemental logging captures redo log data for LogMiner. Three levels are available:

| Level | Impact | Use Case |
|-------|--------|----------|
| Minimal | Smallest overhead | Tables with PKs only |
| PRIMARY KEY | Medium overhead | **Recommended**: PK + unique key columns |
| ALL | Large overhead | Needed for non-PK tables in LogMiner |

**Self-Managed / Podman (CDB$ROOT):**

```sql
-- Connect as SYSDBA to CDB$ROOT
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS;

-- Verify
SELECT SUPPLEMENTAL_LOG_DATA_MIN, SUPPLEMENTAL_LOG_DATA_PK FROM V$DATABASE;
```

**RDS Oracle (via rdsadmin):**

```sql
BEGIN
  rdsadmin.rdsadmin_util.alter_supplemental_logging('ADD');
  rdsadmin.rdsadmin_util.alter_supplemental_logging('ADD', 'PRIMARY KEY');
END;
/
```

**Table-Level (if database-level unavailable):**

```sql
ALTER TABLE <owner>.intpk ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS;
ALTER TABLE <owner>.dtix ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
```

## CDC via LogMiner

### Open LogMiner and Query Changes

LogMiner must be opened to query changes from redo logs:

```sql
-- Connect as C##<lfc_user> to CDB$ROOT (self-managed/Podman) or PDB (RDS)

BEGIN
  DBMS_LOGMNR.ADD_LOGFILE(
    LOGFILENAME => '<path-to-archive-log>',
    OPTIONS => DBMS_LOGMNR.NEW
  );
  DBMS_LOGMNR.START_LOGMNR(OPTIONS => DBMS_LOGMNR.DICT_FROM_REDO_LOGS);
END;
/

-- Query changes
SELECT TIMESTAMP, OPERATION, SQL_REDO FROM V$LOGMNR_CONTENTS
  WHERE TABLE_NAME IN ('INTPK', 'DTIX')
  ORDER BY TIMESTAMP;

-- Close when done
BEGIN DBMS_LOGMNR.END_LOGMNR; END;
/
```

### Get Current SCN

```sql
SELECT DBMS_FLASHBACK.GET_SYSTEM_CHANGE_NUMBER AS current_scn FROM DUAL;
```


## Password Rotation

```sql
-- Rotate LFC user password
-- Connect as SYSDBA or user with ALTER USER privilege

ALTER USER <lfc_user> IDENTIFIED BY "<new-password>" [CONTAINER=ALL];

-- For common user:
ALTER USER C##<lfc_user> IDENTIFIED BY "<new-password>" CONTAINER=ALL;

-- Verify by connecting as LFC user:
sqlplus <lfc_user>/"<new-password>"@<service_name>
SELECT 1 FROM DUAL;
```

## Troubleshooting

### Database Not in ARCHIVELOG Mode

**Symptom:** LogMiner cannot find archive logs; `NOARCHIVELOG` in V$DATABASE.

**Fix:** Enable ARCHIVELOG (requires downtime):
```sql
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
```

### Cannot Create Common User (RDS)

**Symptom:** `CREATE USER C##...` fails; "Not a valid common user domain".

**Fix:** Use PDB-local user (RDS does not allow common users):
```sql
CREATE USER <lfc_user> IDENTIFIED BY "<password>";
```

### LogMiner Dictionary Stale

**Symptom:** V$LOGMNR_CONTENTS returns NULL or wrong OPERATION names.

**Fix:** Build dictionary into redo (self-managed):
```sql
BEGIN
  DBMS_LOGMNR_D.BUILD(OPTIONS => DBMS_LOGMNR_D.STORE_IN_REDO_LOGS);
END;
/
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
```

### Insufficient Privileges for LogMining

**Symptom:** V$LOGMNR_CONTENTS query returns 0 rows.

**Fix:** Ensure LOGMINING privilege is granted:
```sql
GRANT LOGMINING TO C##<lfc_user> CONTAINER=ALL;
GRANT SELECT ON GV_$LOGMNR_CONTENTS TO C##<lfc_user> CONTAINER=ALL;
```

### Supplemental Logging Not Enabled

**Symptom:** LogMiner returns missing SQL_REDO.

**Fix:** Enable supplemental logging:
```sql
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS;
ALTER SYSTEM SWITCH LOGFILE;
```

### Archive Logs Deleted Too Quickly

**Symptom:** "Specified Log not in dictionary" error.

**Fix:** Increase FRA retention:
```sql
ALTER SYSTEM SET db_recovery_file_dest_size = 50G SCOPE=BOTH;
ALTER SYSTEM SET db_flashback_retention_target = 2880 SCOPE=BOTH;
```

## Verification Checklist

Before starting LFC ingestion:

1. **Database in ARCHIVELOG mode:**
   ```sql
   SELECT LOG_MODE FROM V$DATABASE;  -- Should return 'ARCHIVELOG'
   ```

2. **Archive logs available:**
   ```sql
   SELECT COUNT(*) FROM V$ARCHIVED_LOG WHERE STATUS = 'A';
   ```

3. **Supplemental logging enabled:**
   ```sql
   SELECT SUPPLEMENTAL_LOG_DATA_MIN, SUPPLEMENTAL_LOG_DATA_PK FROM V$DATABASE;  -- Should be YES, YES
   ```

4. **Seed tables populated:**
   ```sql
   SELECT COUNT(*) FROM intpk, dtix;  -- Both should have 10 rows
   ```

5. **LFC user can connect and has LogMiner privileges:**
   ```sql
   SELECT rolname FROM dba_roles WHERE rolname = 'LOGMINING';
   ```

