---
name: lfc-source-sizing
description: "How big is a source database, and how much of it will Lakeflow Connect move? Per table and in total: rows, data on disk, indexes, large values (TOAST / LOB), the database's total size for the infrastructure team, and the average row size, read from the catalog through the UC connection (no table scans, no count(*)), with row counts cross-checked when statistics are stale. PostgreSQL, MySQL, SQL Server, Oracle."
parent: lfc-source-setup
---

# Size a source database

Most people replicating a database don't know how big it is, and the two audiences need different numbers: the **infrastructure team** wants everything on disk (tables, indexes, large values, free space, logs), while **Lakeflow Connect** moves only the table data: rows and their large values, never indexes or free space. This skill reports both, plus rows and the average row size for estimating snapshot time and CDC volume.

It reads the database's own catalog **through the UC connection** with `remote_query` (read-only, from serverless), so it needs nothing beyond the connection a pipeline would use, and it never scans a table: no `count(*)`, which on a large table is expensive and slow.

```bash
S=skills/lfc-source-sizing/scripts
bash $S/size.sh <PROFILE> <connection> postgres  --database <database>
bash $S/size.sh <PROFILE> <connection> mysql                                   # every user database at once
bash $S/size.sh <PROFILE> <connection> sqlserver --database <database>
bash $S/size.sh <PROFILE> <pdb-connection> oracle --service <PDB>              # a connection whose service is the PDB
```

[`size.sh`](scripts/size.sh) runs the engine's query ([`postgres.sql`](scripts/postgres.sql), [`mysql.sql`](scripts/mysql.sql) / [`mysql-process.sql`](scripts/mysql-process.sql), [`sqlserver.sql`](scripts/sqlserver.sql), [`oracle.sql`](scripts/oracle.sql)), keeps one row per table in `tables.csv`, and prints, with DuckDB:

| Line | For | What it counts |
|---|---|---|
| database total | infrastructure | the database's files: tables, indexes, large values, free space; logs and WAL where the engine reports them in the same figure (SQL Server includes its log file) |
| tables + indexes + large values | infrastructure | the tables' own storage |
| **data Lakeflow Connect moves** | Lakeflow Connect | table data plus large values; no indexes, no free space |
| indexes (not moved) | both | rebuilt or not needed in Delta |
| logical data from row widths | Lakeflow Connect | rows x the average width of a row's values (Postgres `pg_stats`, MySQL, Oracle statistics): close to what a snapshot reads, before compression |
| rows, average row bytes (on disk / logical) | both | for snapshot time and CDC volume |

Then the largest tables, and every table whose row sources disagree or that has no statistics.

## When statistics are wrong

Bytes always come from storage (file, page, or segment sizes), which is always current. Row counts come from statistics, which can be stale (rows added since the last `ANALYZE`) or missing (never gathered). So each engine has a second source that goes stale differently, and `size.sh` uses it and flags the table when they disagree by more than 1.5x:

| Engine | From statistics | Second source | Third |
|---|---|---|---|
| PostgreSQL | `pg_class.reltuples` (last `ANALYZE`) | `n_live_tup`: the statistics collector counts every insert and delete, no `ANALYZE` needed | rows per page at the last `ANALYZE` x the file's current pages (the planner's own extrapolation) |
| MySQL | `table_rows` (InnoDB's sampled estimate, cached a day: `information_schema_stats_expiry`) | `mysql.innodb_table_stats.n_rows` with its own `last_update` | current tablespace file size / average row length (needs `PROCESS`; `size.sh` falls back without it and says so) |
| SQL Server | `sys.dm_db_partition_stats.row_count`, kept by the engine on every change: near exact without statistics | | |
| Oracle | `num_rows` (last `DBMS_STATS` run) | `num_rows` + inserts - deletes since then (`DBA_TAB_MODIFICATIONS`) | segment bytes / `avg_row_len` |

Tested: a Postgres table with 2,000,000 rows whose statistics said 1,000,000 (half loaded after `ANALYZE`, autovacuum off) was flagged "sources differ 2.0x", and both other sources said exactly 2,000,000, which is what the totals used. A TPC-H SF 1 database came out at 8,660,050 rows from statistics (8,660,030 exact), 1.93 GB on disk (the files were 1.9 GB), 1.6 GB of table data (184 bytes a row) and 0.32 GB of indexes, with 1.29 GB of logical data (149 bytes a row; its text export was 1.4 GB).

**No statistics at all** (an Oracle schema whose stats were never gathered, a Postgres table never analyzed and not yet seen by the collector): bytes are still right, rows are unknown, and the table is listed as "no statistics". Options, in order: ask the DBA to gather statistics (`ANALYZE`, `DBMS_STATS.GATHER_SCHEMA_STATS`, `ANALYZE TABLE`); or estimate from a **block sample**, which reads about 1% of the table, never all of it, and works through `remote_query`: Postgres `SELECT count(*) * 100 FROM t TABLESAMPLE SYSTEM (1)`, SQL Server `TABLESAMPLE (1 PERCENT)`, Oracle `SELECT COUNT(*) * 100 FROM t SAMPLE BLOCK (1)`. Never a plain `count(*)` on a production table.

## Per engine

- **PostgreSQL:** one database per run (`--database`). The data size is the table's file plus TOAST; `pg_stats` (and so the logical width) shows only tables the connection's user can `SELECT`.
- **MySQL:** every user database in one run. `data_length` is the clustered index, rows and large values together, so large values aren't split out. Run `ANALYZE TABLE` first, or set `information_schema_stats_expiry = 0` in a session, for current figures; `remote_query` can't set it.
- **SQL Server:** one database per run. Needs `VIEW DATABASE STATE` (the Lakeflow utility script's `lakeflowFixPermissions` grants what's needed). In-row data, LOB and row-overflow pages are reported separately.
- **Oracle:** a connection whose `service_name` is the **PDB**: a connection on the CDB service (as integrated CDC needs) puts `remote_query` in `CDB$ROOT`, where the PDB's tables don't exist, whatever `service_name =>` argument you pass (tested). Needs `SELECT` on the `DBA_` views (the Databricks Oracle setup package grants it).

## Is it possible? Documented limits

Before planning a test or a pipeline around a stated size or table count, check it against the documented limits in [references/limits.md](references/limits.md): the engines, the managed services, Debezium, and Databricks itself. Each row has its kind (hard, soft: raised on request, configurable, recommended, behavior) and the question it raises. For example:

- "100 TB on RDS for PostgreSQL" can't be one instance (RDS caps PostgreSQL and MySQL at 64 TiB): ask whether it's Aurora (128 TiB a cluster), self-managed, or several instances. Self-managed PostgreSQL has no database size limit, but one table can't pass 32 TB: ask for the largest table.
- "8,000 tables": a schema holds 10,000 tables (soft, the account team raises it) and each source table makes 2 silver tables, so plan several schemas or ask; a pipeline holds 1,000 tables (hard), and the SQL Server connector recommends 250 or fewer a pipeline.

The rows are in `references/limits/*.yaml`, each with the page it comes from and a quote from it. [scripts/limits-check.py](scripts/limits-check.py) fetches each page and checks that the quote is still there (a page that changed, or moved, fails); `--find <url> <words>` prints a page's text to quote from; `--markdown` regenerates the tables.

```bash
python3 scripts/limits-check.py references/limits/*.yaml --cache /tmp/limits-cache            # PASS / FAIL per row
python3 scripts/limits-check.py --find https://www.postgresql.org/docs/current/limits.html "relation size"
```

Not covered yet: MySQL's own documentation (it refuses scripted fetches, so MySQL rows come from the managed services' pages), MariaDB, Db2, YugabyteDB and Kafka. Add rows the same way, checked, in the same pull request as the test that needed them.
