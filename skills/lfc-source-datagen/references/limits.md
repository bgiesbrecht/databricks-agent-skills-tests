# Quick limits per engine

Answer from this table; don't look the docs up. ✓ = tested on the engine (Postgres 16, MySQL 8.4); the rest come from the vendor docs and aren't tested yet.

| Limit | PostgreSQL | MySQL (InnoDB) | SQL Server | Oracle |
|---|---|---|---|---|
| Columns per table | **1,600** ✓ (dropped columns still count) | **1,017** ✓ (the server's 4,096 is unreachable with InnoDB) | 1,024; 30,000 with sparse columns | 1,000; 4,096 with `MAX_COLUMNS = EXTENDED` (recent releases, 23ai/26ai) |
| Row size | Must fit an 8 KB page: **8,160 bytes** ✓ in-row; long values move out of row (TOAST) | **65,535** bytes declared ✓; about **8,126** in-page ✓ (16 KB pages) | 8,060 bytes in-row; `varchar(max)` and row overflow move off-row | Rows larger than a block chain across blocks |
| Rows in one `INSERT ... VALUES` | No fixed limit: 1M rows (8.9 MB of SQL) ✓ | Bounded by `max_allowed_packet` (**64 MB** default ✓, 1 GB max): 1M rows ✓ | **1,000** (more only in a `VALUES` derived table) | One row per `VALUES` before 23ai (use `INSERT ALL` or `UNION ALL` from `DUAL`); 23ai allows several |
| Bind parameters | 65,535 | 65,535 | 2,100 per call | — |
| Identifier length | 63 bytes | 64 characters | 128 characters | 128 bytes (30 before 12.2) |
| Row generator | `generate_series` | Recursive CTE (`cte_max_recursion_depth`, default 1,000) | `GENERATE_SERIES` (2022+, compatibility level 160); recursive CTE (`MAXRECURSION` 100 default, up to 32,767 or 0) | `CONNECT BY LEVEL <= n` from `DUAL`; recursive `WITH` |
| Seed table for big loads | Optional (same speed as `generate_series`) ✓ | Recommended: 1,000-row `VALUES` list, then double with `INSERT ... SELECT` ✓ | Same (`VALUES` limit is 1,000) | Same |
| Longest exact decimal | `numeric`: 1,000 declared digits | `DECIMAL(65,30)` ✓ | `decimal(38)` | `NUMBER(38)` |
| Longest in-row string | `varchar(10485760)`; `text` up to 1 GB | `VARCHAR(16383)` in utf8mb4 (but the 65,535-byte row limit applies) ✓ | `varchar(8000)`; `varchar(max)` 2 GB | `VARCHAR2(4000)` bytes; 32,767 with `MAX_STRING_SIZE = EXTENDED` |
