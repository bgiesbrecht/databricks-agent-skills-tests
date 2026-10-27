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
-- 1. Recovery area and ARCHIVELOG (restarts the database; the container keeps running). 10G filled in one
--    schema-change test round (ORA-19809, then ORA-00257 archiver error, which stops the extractor): use 50G
host mkdir -p /opt/oracle/oradata/fra
ALTER SYSTEM SET db_recovery_file_dest_size = 50G SCOPE=BOTH;
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

**Gateway `source_catalog`:** set it in the gateway's `connection_parameters` as the base service name, `{"source_catalog": "FREE"}`. The gateway's message (`NO_CONNECTION_PARAMETER`) says to use the literal `CDB$ROOT`, which fails with `INGESTION_GATEWAY_CONNECTION_ERROR.SOURCE_AUTHENTICATION_FAILURE` ("Oracle service name 'CDB$ROOT' is invalid"). A `source_catalog` set under `gateway_definition` is dropped by the CLI ("unknown field: source_catalog"), and the gateway then fails with `NO_CONNECTION_PARAMETER` again. Tested 2026-10-25 on Oracle Free 23.26.3: with `FREE` the gateway ran and the snapshot completed with 10 rows.

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

**Restart the gateway after a logging change.** The gateway keeps the connection's supplemental-logging state until it restarts. After primary-key logging was added to two tables (checked in `DBA_LOG_GROUPS`), updates kept failing with `INGESTION_GATEWAY_CDC_NOT_ENABLED` ("Primary Key supplemental logging is not enabled on this table."); after a restart, other tables reported it (tested 2026-10-25, Oracle Free 23.26.3). Restart the gateway after each logging change, then start the update.

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

**A wrong password:** if the source password changed and the connection still has the old one, the gateway fails with `INGESTION_GATEWAY_CONNECTION_ERROR.SOURCE_AUTHENTICATION_FAILURE` ("Error while creating connection pool for catalog <catalog>. ORA-01017: invalid credential or not authorized; logon denied"). The retries repeat the same error. Update the connection with the current password, then start an update (the fix wasn't run in this round; tested 2026-10-26, Oracle Free 23.26.3).

## Column Types

Tested 2026-10-26 on Oracle Free 23.26.3, standard gateway: the snapshot rows and the CDC rows that arrived.

| Oracle type | Lands as | Notes |
|---|---|---|
| `NUMBER(38,0)`, `NUMBER(10,2)` | decimal, same value | |
| `NUMBER` with no precision or scale | string with the exact digits | not a decimal: `1234.5678`, `0.000001` |
| `TIMESTAMP(9) WITH LOCAL TIME ZONE` | string with the zone name inside | 12:00:00.123456789 in a +00:00 session arrives as `2026-10-25 12:00:00 Etc/UTC.123456789` |
| `TIMESTAMP WITH TIME ZONE` | timestamp, same UTC instant | offset dropped |
| `INTERVAL DAY TO SECOND` | interval | |
| `BINARY_FLOAT`, `BINARY_DOUBLE` | float, double | |
| `RAW(16)` | binary | |
| `NCLOB` | string | |
| `XMLTYPE` | the table is skipped on CDC | [XMLTYPE Column Skips the Table](#xmltype-column-skips-the-table) |

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

**Symptom:** "Specified Log not in dictionary" error. LogMiner's text can also be `No complete archived dictionary found before SCN: <scn>`. With the archive logs removed, the gateway reports `ORACLE_ARCHIVE_LOG_FILES_UNAVAILABLE` ("... Please perform full refresh on all destination tables mapped to catalog <catalog> ..."), and the update can still COMPLETE with the flows failed (tested 2026-10-25, Oracle Free 23.26.3).

**Fix:** Increase FRA retention. If logs are already gone, full refresh the destination tables the message names, and read the gateway's flow events rather than the update's status. The removal is container-wide: a second gateway on the same container, whose CDC had finished, went to `INGESTION_GATEWAY_INTERNAL_ERROR` ("cannot recover") (tested 2026-10-26, Oracle Free 23.26.3).
```sql
ALTER SYSTEM SET db_recovery_file_dest_size = 50G SCOPE=BOTH;
ALTER SYSTEM SET db_flashback_retention_target = 2880 SCOPE=BOTH;
```

### Recovery Area Full

**Symptom:** `ORA-19809: limit exceeded for recovery files`, then `ORA-00257: archiver error`; the extractor stops and its lag grows (tested 2026-10-26, Oracle Free 23.26.3, 10G area, about 20 tables changed and refreshed).

**Fix:** `ALTER SYSTEM SET db_recovery_file_dest_size = 50G SCOPE=BOTH;` (the archiver resumes by itself), then check the extractor catches up.

### PDB Service Shows INTERNAL_ERROR

**Symptom:** A gateway connected through the PDB's service name (`FREEPDB1`) fails with `INGESTION_GATEWAY_INTERNAL_ERROR` ("The Ingestion Gateway has encountered an internal error and cannot recover"). Direct SQL on that service fails at `DBMS_LOGMNR.ADD_LOGFILE` with `ORA-65040`; the pipeline events don't show it (tested 2026-10-25, Oracle Free 23.26.3).

**Fix:** Connect with the CDB's service (`FREE`) and name the PDB in `source_catalog` (see above).

### Missing Privileges Fail in Order

**Symptom:** Four users with different grants (tested 2026-10-25, Oracle Free 23.26.3):
- No `CREATE SESSION`: `ORA-01045: Login denied` at connection (`INGESTION_GATEWAY_CONNECTION_ERROR.SOURCE_AUTHENTICATION_FAILURE`).
- `CREATE SESSION` only: `ORA-00942: table or view SYS.V_$DATABASE does not exist` ("Could not fetch database name").
- A table without `SELECT`: `GENERIC_SNAPSHOT_FAILURE`, "Snapshot failed for table <catalog>.<schema>.<table>", with `ORA-00942`.

None of the three reaches the missing-privilege list.

**Fix:** Grant in this order: `CREATE SESSION`, then the full grant list above (the validator's objects), then `SELECT` on each table. Check with `VALIDATE_SETUP`.

### Restricted User Finds No Tables

**Symptom:** A user with `SELECT` on ten tables only: Schema Exploration says "Found 0 table(s)", and the update stays `INITIALIZING` with every snapshot `SCHEDULED` for more than 10 minutes and no error event. The same database's all-visible user found 4,500 tables in 6.95 s. The restricted user lacked about 45 view grants (tested 2026-10-25, Oracle Free 23.26.3).

**Fix:** Apply the full grant list, then check that exploration finds the tables before starting the update.

### Triggered Update Stays RUNNING

**Symptom:** A triggered integrated update ran 23 minutes without a `COMPLETED` event. Its lag grew from 232 s at 5 minutes to 1,258 s at 23 minutes with no source changes after one probe row; the progress text said "Will stop once the lag converges" (tested 2026-10-25, Oracle Free 23.26.3, one run).

**Fix:** Watch a longer run with a steady trickle of changes, and record the lag over time before stopping it.

### Common User Without Container Grants Shows as Missing Table

**Symptom:** A common user (`C##`) without `SET CONTAINER` and `CONTAINER_DATA=ALL`: the gateway found 0 tables and reported `MISSING_TABLE_IN_SOURCE` ("No catalog or schema was found for replication. Please check your filter file"). The message doesn't name the privilege (tested 2026-10-26, Oracle Free 23.26.3).

**Fix:** Grant the two multi-container privileges from the grant list above (`GRANT SET CONTAINER` and `ALTER USER ... SET CONTAINER_DATA=ALL CONTAINER=CURRENT`), then restart the pipelines. The re-run found the tables.

### XMLTYPE Column Skips the Table

**Symptom:** The gateway's flow reported `TABLE_SKIPPED_DUE_TO_UNSUPPORTED_COLUMN_DATA_TYPE`: "Table contains unsupported column types: XMLTYPE. Oracle LogMiner skips the entire table when any column has these types". The table got no snapshot, and the ingestion update stayed `RUNNING` with its snapshot `SCHEDULED` for about 20 minutes, until the table was removed. A companion table without the column ran normally (tested 2026-10-26, Oracle Free 23.26.3, one run).

**Fix:** Remove the table from the pipeline (tested). Keeping the XML in a table of its own wasn't tested.

### Dropped Table Blocks the Ingestion Pipeline

**Symptom:** After `DROP TABLE`, the first ingestion update with no change to that table COMPLETED with no error. After changes reached the gateway, the gateway reported the table's flow with `TABLE_DROPPED`, and the next update FAILED at analysis: `[INGESTION_GATEWAY_TABLE_DROPPED] Source table <catalog>.<schema>.<table> has been dropped on source`, "A new pipeline update will not be created". Every table in the pipeline stopped until the dropped table was removed (tested 2026-10-26, Oracle Free 23.26.3, one run).

**Fix:** Remove the dropped table from the ingestion pipeline. The pipeline ran again after that.

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

