# 2026-10-17: Python fill planner, six engines, through drivers

**lfc-source-datagen**'s fill, rewritten in Python ([`scripts/python/fill.py`](../skills/lfc-source-datagen/scripts/python/fill.py)) and run through pip-installable drivers instead of each database's CLI. This is the path for managed services and Databricks serverless, which have no `psql` or `sqlplus`, and for Db2 and Informix, which have no SQL planner. Records: `results/runs/2026-10-17-python-fill-planner.jsonl`. Details: [python-drivers.md](../skills/lfc-source-datagen/references/python-drivers.md).

## Setup

- **Host:** the laptop (MacBook, Apple Silicon), Lima VZ VM, 4 vCPU and 10 GiB, rootful Podman.
- **Engines:** PostgreSQL 16, MySQL 8.4, SQL Server 2022, Oracle 23ai Free, Db2 11.5.8 and Informix 14.10. SQL Server, Db2 and Informix run as x86_64 under Rosetta.
- **Client:** Python on the Mac, through Lima's forwarded ports.
- **Drivers:** `psycopg2-binary` 2.9.12, `pymysql` 1.2.0, `mssql-python` 1.11.0, `oracledb` 4.0.2 (thin), `ibm-db` 3.2.9, `informix-driver` 2026.5.8.1. All six installed with `uv pip`, with no OS packages; `ibm-db` downloaded its C client during the install.
- **Schemas:** the six TPC workloads from **lfc-source-statschema** (`shape.py`, then `ddl.py`, with the new `--dialect db2` and `informix`).

## Results

| Check | Postgres | MySQL | SQL Server | Oracle | Db2 | Informix |
|---|---|---|---|---|---|---|
| Plan identical to the SQL planner's (6 TPC schemas) | ✓ | ✓ | ✓ | ✓ | (none) | (none) |
| SF 0.1, all six workloads, every table at target (13,035,445 rows, 95 tables) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| TPC-H SF 1 (8,660,030 rows), `fill.py` | 118 s | 151 s | 208 s | 372 s | 583 s | 1,150 s |
| TPC-H SF 1, `fill.sh` baseline ([TPC masters](2026-10-17-tpc-sf1-masters.md)) | 119 s | 174 s | 207 s | 307 s | | |
| TPC-E SF 0.1 (8,062,150 rows) | 45 s | 44 s | 64 s | 774 s | 433 s | 1,650 s |

- "Plan identical" means the same statements as the SQL planner, byte for byte, apart from the scramble's constants. Before the plan, the driver test ran a TPC-H SF 1 fill planned by `psql` with its statements sent through `psycopg2`: 121 s, against 142 s for `fill.sh` on the same container.
- Sessions: Postgres and SQL Server ran 4, the other engines 2. The baselines (`tpc-master.sh`) ran 4 on every engine but MySQL (2). Oracle's 2 sessions here against 4 then are the likely reason for its gap; not measured.

## What broke, and the fixes

Each was found by a failing fill and fixed in the planner, the drivers, or `ddl.py`. The full list is in [python-drivers.md](../skills/lfc-source-datagen/references/python-drivers.md) and **lfc-source-statschema**'s SKILL.md.

| Problem | Fix |
|---|---|
| Oracle TPC-DI: `ddl.py --dialect oracle` wrote a `TIME` column (`DimTime`), which Oracle doesn't have, so the tables after it were never created | `TIMESTAMP(0)`. The Oracle TPC-DI master's DimTime table and the ones after it should be checked |
| Db2: nothing committed, not even DDL | `ibm_db_dbi` needs `set_autocommit(True)`; setting `.autocommit` does nothing |
| Db2: SQL0964C (log full) building a seed table by doubling, and with two sessions of wide rows | No seed table (a recursive CTE makes 1M rows in 0.5 s); `LOGSECOND 200` on the container |
| Db2: SQL0973N on TPC-H's 19 KB `part` INSERT | `PCKCACHESZ 16384`, fixed: self-tuning memory shrank `AUTOMATIC` back to 320 pages |
| Db2: SQL0420N in TPC-H's phone formula | `\|\|` binds like `+` in Db2 (Postgres binds `+` first): `ddl.py` parenthesizes arithmetic inside concatenation |
| Db2: SQL0413N in `o_totalprice` | sqlglot's Postgres `ROUND` adds `CAST(... AS DECIMAL)`, which is DECIMAL(5,0) in Db2: `ROUND` written as is; bare `DECIMAL` casts get (31, 0) |
| Db2: no `PI()`; `RAND()` refused in `ROW_NUMBER() OVER (ORDER BY ...)` | `ACOS(-1)`; random key order sorts by a hash of n |
| Informix: `CREATE DATABASE` failed with -377 | `informix_db.connect(..., autocommit=True)`; set later, a transaction is already open |
| Informix: TPC-H's `part` took over 10 minutes for 20,000 rows | A 150-value list's nested CASE re-evaluates the inner CASE for every WHEN (2.5 ms a row): folded into one searched CASE, as for SQL Server |
| Informix: -202 (an illegal `%`) | `MOD`. A rewrite's re-parse turned `MOD()` back into `%`, and sqlglot's `transform` missed a `MOD` inside a `MOD`: replaced one at a time |
| Informix: -1215 (INTEGER overflow) | `INT8 * INT` is a DECIMAL, and `MOD` of a DECIMAL returns INTEGER: `ddl.py` casts the dividend to BIGINT (sqlglot writes `INT8` as SMALLINT, so `BIGINT`) |
| Informix: -391 (NULL in NOT NULL) for timestamps | `NUMTODSINTERVAL(n, 'DAY')` gives NULL for large n: days by `MDY()` arithmetic. Separately, n from a DECIMAL key formula made `MOD` return NULL: n is cast to INT8 |
| Informix: -1213 in the epoch key formula | sqlglot rewrote `TO_CHAR`'s `'%H'` to Postgres's `'HH24'`: the formula is kept out of sqlglot and written in afterwards |
| Informix: -1266 for `HOUR TO SECOND` | `EXTEND` of the full timestamp |
| Informix: the root dbspace (1.6 GB) filled with the six SF 0.1 databases | A 6 GB dbspace for SF 1 (`onspaces -c -d datadbs`, `CREATE DATABASE ... IN datadbs`) |

## Not covered

- Delete, audit, boundary and `make-dataset` are still SQL-only (Postgres and MySQL).
- Managed services and Databricks serverless: not run yet. This was the laptop, with Python on the same machine.
- JDBC through JPype: documented, not built.
