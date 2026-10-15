# IBM Informix

> **Lakeflow Connect support:** check the current [connector list](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/) before promising ingestion from this engine. This page covers preparing the database; whether and how Lakeflow Connect ingests from it (query-based, CDC, or a community connector) changes between releases.


## Overview

IBM Informix uses **Replication and High Availability features** for CDC, with special setup via **PAM / OS authentication** on Linux. Similar to Db2, Informix is self-managed / Podman-only. **LFC support is experimental / limited.**

## Prerequisites

- Informix Developer Edition (onconfig.std)
- Running in a container (Podman/Docker)
- OS users created and PAM authentication configured

## User Setup (OS + SQL)

Informix uses **PAM / OS authentication**: OS password and Informix password must sync:

```sql
-- OS user creation (run on host):
# podman exec <informix-container> useradd -m <lfc_user>
# printf '%s:%s\n' <lfc_user> "$(cat lfc_user.pw)" | podman exec -i <informix-container> chpasswd   # password from a file

-- SQL side (inside container):
# dbaccess <database>

CREATE USER <lfc_user>;
GRANT CONNECT, RESOURCE, DBA TO <lfc_user>;

-- Verify
SELECT USERNAME FROM SYSUSERS WHERE USERNAME = '<lfc_user>';
```

## Seed Tables

Informix does not support multi-row VALUES syntax:

```sql
-- dbaccess <database>

CREATE TABLE <lfc_user>.intpk (pk SERIAL NOT NULL PRIMARY KEY, dt DATETIME YEAR TO FRACTION DEFAULT CURRENT, ops VARCHAR(255) DEFAULT 'insert');
CREATE TABLE <lfc_user>.dtix (pk INTEGER, dt DATETIME YEAR TO FRACTION DEFAULT CURRENT, ops VARCHAR(255) DEFAULT 'insert');
CREATE INDEX idx_intpk_dt ON <lfc_user>.intpk (dt);
CREATE INDEX idx_dtix_dt ON <lfc_user>.dtix (dt);

-- Seed data (one row at a time)
INSERT INTO <lfc_user>.intpk (dt) VALUES (CURRENT);  -- Repeat 10 times
INSERT INTO <lfc_user>.dtix (pk, dt) VALUES (1, CURRENT);  -- Repeat with pk 1..10
```

## CDC Requirements

Informix CDC requires **log replication** or **Replication and High Availability** (HA) features. These are **not commonly integrated with external tools** like LFC.

```sql
-- Informix replication setup (advanced; not recommended for LFC)
-- LFC likely uses query-based ingestion instead
```

## Gotchas

- **OS + Informix sync:** PAM authentication requires OS users and Informix users to have matching passwords. Changes require both.
- **Single-row inserts:** Informix does not support multi-row `VALUES (...), (...)` syntax.
- **No cloud managed services:** Informix is self-managed only (typically Podman).
- **Limited CDC ecosystem:** Informix replication is mature but not widely integrated into modern data pipeline tools.
- **Query-based fallback:** LFC likely uses timestamp-based incremental queries instead of true CDC.

## LFC Support Status

✓ Query-based ingestion  
✗ Standard CDC (Replication setup complex; not recommended)  
✗ Integrated CDC (not available)

---

## Troubleshooting

- **Can't connect:** check reachability (`nc -zv <host> <port>`), the firewall / security group, and the credentials.
- **Login fails for a user that exists in the database:** Informix authenticates against the OS (PAM), so the OS user must exist with the same name and password.
- **Password rotation:** change the OS user's password; there's no separate SQL password.

## When to use

Legacy on-premises OLTP systems. For new Lakeflow Connect sources, prefer MySQL, PostgreSQL, SQL Server, or Oracle.
