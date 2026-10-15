# PostgreSQL Source Configuration for Lakeflow Connect

This guide documents the database configuration required for Lakeflow Connect (LFC) query-based ingestion and CDC (Logical Replication) on PostgreSQL servers.

## Quick Reference

| Requirement | Query-Based | CDC (Logical Replication) |
|---|---|---|
| **Server Parameter** | `wal_level=logical` | Same + `max_replication_slots ≥1` |
| **User Privilege** | `CONNECT`, `SELECT` | + `REPLICATION` or `rds_replication` |
| **Cursor Column** | Any non-null `TIMESTAMP` | Not needed; slots track LSN |
| **Primary/Unique Key** | Recommended | Required: set `REPLICA IDENTITY DEFAULT` or `FULL` |

## Overview

PostgreSQL uses logical replication slots and WAL (Write-Ahead Log) decoding for Lakeflow Connect's CDC. All platforms (AWS RDS, GCP Cloud SQL, Azure Database for PostgreSQL, self-managed) support the same core configuration; replication privileges differ slightly between managed and self-managed instances.

## Prerequisites for Query-Based Ingestion

### PostgreSQL Server Parameters

The following parameters control replication and audit logging:

| Parameter | Required Value | Scope | Notes |
|-----------|----------------|-------|-------|
| `max_replication_slots` | ≥1 | Startup | Defines number of logical replication slots; default may be 10 |
| `max_wal_senders` | ≥2 | Startup | Walsender processes for replication; default may be 10 |
| `wal_level` | logical | Startup | Required for logical replication; enables WAL decoding |
| `log_connections` | on | Runtime | Optional; logs connection events |
| `log_disconnections` | on | Runtime | Optional; logs disconnections |
| `log_statement` | 'all' (or 'ddl') | Runtime | Optional; logs SQL statements |

**Check current settings:**
```sql
SELECT name, setting, unit FROM pg_settings 
  WHERE name IN ('max_replication_slots', 'max_wal_senders', 'wal_level', 'log_connections');
```

### Cloud-Specific Parameter Setup

**AWS RDS PostgreSQL:**
```
Parameter group:
  rds.logical_replication = 1  (enables wal_level=logical)
  max_replication_slots = 10  (default; adjust if needed)
  max_wal_senders = 10
```

> **Note:** RDS has a custom parameter `rds.logical_replication`. Setting `wal_level` directly may be ignored.

**GCP Cloud SQL PostgreSQL:**
```
Flags:
  cloudsql.enable_cloudsql_logs = on  (optional, for Cloud Logging audit)
  max_replication_slots = 10
  max_wal_senders = 10
Database flags typically include: cloudsql_logical_replication = on
```

**Azure Database for PostgreSQL:**
```
Server parameters:
  azure.replication_support = on  (enables logical replication)
  max_replication_slots = 10
  max_wal_senders = 10
```

## LFC User Setup

### Create or Update LFC Role

```sql
-- Connect as superuser (postgres) or with CREATEUSER privilege

-- Create LFC user (idempotent)
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '<lfc_user>') THEN
    CREATE USER <lfc_user> PASSWORD '<password-from-file>';
  END IF;
END $$;

-- Update password
ALTER USER <lfc_user> WITH PASSWORD '<password-from-file>';

-- Grant connection to target database
GRANT CONNECT ON DATABASE "<database>" TO <lfc_user>;
GRANT ALL PRIVILEGES ON DATABASE "<database>" TO <lfc_user>;

-- Grant schema privileges
GRANT USAGE, CREATE ON SCHEMA public TO <lfc_user>;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public TO <lfc_user>;

-- Grant default future table privileges
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO <lfc_user>;
```

### Grant Replication Privilege

Replication privilege depends on whether you are superuser or using managed privileges (AWS RDS, GCP Cloud SQL, Azure).

**Self-Managed / Superuser Path:**
```sql
-- Connect as superuser
ALTER ROLE <lfc_user> WITH REPLICATION;
```

**AWS RDS (Non-Superuser) Path:**
```sql
-- If the admin user is not superuser, use rds_replication role
GRANT rds_replication TO <lfc_user>;
```

**Verify replication capability:**
```sql
-- Connect as LFC user
SELECT rolreplication FROM pg_roles WHERE rolname = '<lfc_user>';
-- Should return 't' (true)
```

### Verify LFC User

```sql
-- Connect as LFC user to target database
SELECT 1;
SELECT current_user;
SELECT has_database_privilege('<lfc_user>', '<database>', 'CONNECT');
```

## Seed Tables for Demo/Testing

LFC uses two seed tables for testing ingestion (run as <lfc_user>):

```sql
-- Connect as <lfc_user> to <database>

-- intpk: integer primary key for query-based ingestion
CREATE TABLE IF NOT EXISTS public.intpk (
  pk  SERIAL PRIMARY KEY,
  dt  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  ops VARCHAR(255) DEFAULT 'insert'
);
CREATE INDEX IF NOT EXISTS idx_dt ON public.intpk (dt);

-- dtix: no primary key, REPLICA IDENTITY FULL for CDC testing
CREATE TABLE IF NOT EXISTS public.dtix (
  pk  BIGINT,
  dt  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  ops VARCHAR(255) DEFAULT 'insert'
);
CREATE INDEX IF NOT EXISTS idx_dt ON public.dtix (dt);

-- Seed 10 rows
INSERT INTO public.intpk (dt) VALUES (NOW()), (NOW()), (NOW()), (NOW()), (NOW()),
  (NOW()), (NOW()), (NOW()), (NOW()), (NOW());
INSERT INTO public.dtix (pk, dt) SELECT i, NOW() FROM generate_series(1, 10) i;
```

## CDC Requirements (Logical Replication)

### Enable Logical Replication (Platform-Specific)

Logical replication must be enabled **at the server level** (startup parameter), not per-database.

**Self-Managed PostgreSQL:**

1. Edit `postgresql.conf`:
   ```
   wal_level = logical
   max_replication_slots = 10
   max_wal_senders = 10
   ```

2. Restart PostgreSQL:
   ```bash
   sudo systemctl restart postgresql
   # or
   pg_ctl -D /path/to/data restart
   ```

3. Verify:
   ```sql
   SHOW wal_level;  -- Should return 'logical'
   ```

**AWS RDS PostgreSQL:**
```
1. Parameter group or modify DB instance:
     rds.logical_replication = 1

2. AWS will display a yellow notification to reboot.
   Reboot the DB instance or cluster.

3. Verify post-reboot:
   SELECT setting FROM pg_settings WHERE name = 'wal_level';
   -- Should return 'logical'
```

**GCP Cloud SQL PostgreSQL:**
```
1. Go to Edit instance / Flags
   cloudsql_logical_replication = on

2. Changes apply immediately or on next maintenance window.

3. Verify:
   SELECT setting FROM pg_settings WHERE name = 'wal_level';
```

**Azure Database for PostgreSQL:**
```
1. Server parameters:
     azure.replication_support = on

2. Some changes require server restart (check the UI).

3. Verify:
   SELECT setting FROM pg_settings WHERE name = 'wal_level';
```

### Create Replication Slot

A replication slot tracks the decoder's position in the WAL stream. LFC creates this automatically during pipeline setup. To create manually:

```sql
-- Connect as superuser
SELECT pg_create_logical_replication_slot('<slot_name>', 'test_decoding');
SELECT * FROM pg_replication_slots;  -- List existing slots
```


### Set Replica Identity on Tables

Replica identity determines how PostgreSQL encodes old row values in the WAL for update/delete operations. LFC uses two strategies:

```sql
-- Connect as LFC user

-- DEFAULT: Use primary key (or unique index) for old row identification
ALTER TABLE public.intpk REPLICA IDENTITY DEFAULT;

-- FULL: Use entire row (for tables without obvious PK)
ALTER TABLE public.dtix REPLICA IDENTITY FULL;

-- Verify:
SELECT schemaname, tablename, reptoptions FROM pg_tables
  WHERE schemaname = 'public' AND tablename IN ('intpk', 'dtix');
```


## Password Rotation

```sql
-- Rotate LFC user password (via ALTER USER)
-- Connect as superuser or with CREATEROLE privilege

ALTER USER <lfc_user> WITH PASSWORD '<new-password>';

-- Verify by connecting as LFC user:
psql -h <host> -U <lfc_user> -d <database> -c "SELECT 1;"
```

## Troubleshooting

### Logical Replication Not Enabled

**Symptom:** `pg_create_logical_replication_slot()` fails; "logical replication not supported".

**Fix:** Verify `wal_level = logical` (startup parameter; requires restart):
```sql
SHOW wal_level;
```

### Cannot Create Replication Slot (Permission Denied)

**Symptom:** `pg_create_logical_replication_slot()` fails with permission denied.

**Fix:** User must have REPLICATION role:
```sql
ALTER ROLE <lfc_user> WITH REPLICATION;
```

### Replication Slot Not Active (WAL Accumulation)

**Symptom:** WAL files accumulate; slot lagging.

**Fix:** Check and drop stale slots:
```sql
SELECT slot_name, active FROM pg_replication_slots;
SELECT pg_drop_replication_slot('<slot_name>');  -- if inactive
```

### Cannot Alter Replica Identity (Table Owner)

**Symptom:** `ALTER TABLE ... REPLICA IDENTITY` fails due to permission denied.

**Fix:** Ensure LFC user owns the table:
```sql
ALTER TABLE public.intpk OWNER TO <lfc_user>;
ALTER TABLE public.dtix OWNER TO <lfc_user>;
```

### Connection Timeout (Network/Security)

**Symptom:** `psql` hangs or connection refused.

**Fix:** Verify network reachability and firewall (port 5432):
```bash
nc -zv <host> 5432
```

## Verification Checklist

Before starting LFC ingestion:

1. **Logical replication enabled:**
   ```sql
   SHOW wal_level;  -- Should return 'logical'
   ```

2. **LFC user has replication privilege:**
   ```sql
   SELECT rolreplication FROM pg_roles WHERE rolname = '<lfc_user>';  -- Should be 't'
   ```

3. **Seed tables exist and populated:**
   ```sql
   SELECT COUNT(*) FROM public.intpk, public.dtix;  -- Both should have 10 rows
   ```

4. **Replica identity correctly set:**
   ```sql
   SELECT tablename, reptoptions FROM pg_tables WHERE tablename IN ('intpk', 'dtix');
   ```

5. **No stale replication slots:**
   ```sql
   SELECT slot_name, active FROM pg_replication_slots;
   ```