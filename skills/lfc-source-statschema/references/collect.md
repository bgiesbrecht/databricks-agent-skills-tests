# Collect schema, statistics, and queries

Every collector reads only the catalog and the optimizer's statistics: no table is scanned, so it costs the same on 10 tables as on 10,000, and touches no row data. Each prints one JSON document; [`to-canonical.py`](../scripts/to-canonical.py) turns a statistics collector's output into statschema's `schema.yaml` and `stats.yaml`.

## Postgres

[`collect-postgres.sql`](../scripts/collect-postgres.sql): `psql -X -At -v schema=sales -v values=none -f collect-postgres.sql > raw.json`

- **Needs** `SELECT` on the tables' `pg_stats` rows: the table owner, or the `pg_read_all_stats` role.
- **Fresh as the last `ANALYZE`**, which autovacuum runs; run `ANALYZE` first only if they're stale (it samples 30,000 rows per table at the default `default_statistics_target`).

| Field | From |
|---|---|
| `row_count`, `size_bytes` | `pg_class.reltuples` (the planner's estimate), `pg_table_size` |
| `primary_key`, `unique`, `foreign_keys`, `checks`, `indexes` | `pg_constraint`, `pg_index` |
| `null_fraction`, `n_distinct` (negative: a fraction of the rows), `avg_width_bytes`, `correlation` | `pg_stats` |
| `most_common_values`, `min_value`, `max_value`, `histogram_bounds` | `pg_stats` (min and max: the histogram's ends, or the extreme common values); values only as `values` allows |

[`collect-queries-postgres.sql`](../scripts/collect-queries-postgres.sql): `psql -X -At -v top=50 -v search_path=sales -f collect-queries-postgres.sql > queries.json`

- The top statements from `pg_stat_statements` (by total time), each with its plan from `EXPLAIN (GENERIC_PLAN, FORMAT JSON)`: planned, never run.
- **Needs** `pg_stat_statements` loaded (`shared_preload_libraries`) and Postgres 16+ for generic plans (older versions record the error instead); `pg_read_all_stats` to see other users' statements.
- **`search_path`**: what the application uses, so unqualified names resolve; the extension's schema is added.
- `pg_stat_statements` writes `date '1995-03-15'` as `date $1`, which isn't valid SQL to plan; the collector plans it as `$1::date`.

## MySQL 8.0+

[`collect-mysql.sql`](../scripts/collect-mysql.sql) with [`mysql-normalize.jq`](../scripts/mysql-normalize.jq): `mysql -N -B -r -e "SET @db='sales', @vals='none'; SOURCE collect-mysql.sql" sales | jq -f mysql-normalize.jq > raw.json`

- **Row counts and index cardinalities** are InnoDB's estimates (often 5–10% off); the collector sets `information_schema_stats_expiry = 0`, or they could be a day old.
- **Null fractions, distinct counts, most common values, and ranges exist only for columns with a histogram.** The DBA builds them once, sampling each table (`histogram_generation_max_mem_size`, 20 MB by default; TPC-H's 8.6M rows took 3 s):

  ```sql
  SELECT CONCAT('ANALYZE TABLE `', table_name, '` UPDATE HISTOGRAM ON ', GROUP_CONCAT(CONCAT('`', column_name, '`')), ' WITH 100 BUCKETS;')
  FROM information_schema.columns WHERE table_schema = 'sales' AND column_key <> 'PRI' GROUP BY table_name;
  ```

  A column that leads an index gets its distinct count from the index without one.
- Found while testing: `JSON_TABLE` can't read `information_schema.column_statistics` directly (error 1210), so the query materializes it first; buckets hold *cumulative* frequencies (singleton `[value, cumulative]`, equi-height `[low, high, cumulative, distinct]`); text values in histograms are base64-encoded and may be truncated.

[`collect-queries-mysql.sql`](../scripts/collect-queries-mysql.sql): `mysql -N -B -r -e "SET @db='sales', @top=50; SOURCE collect-queries-mysql.sql" > queries.json`

- The top digests from `performance_schema.events_statements_summary_by_digest`, with `?` for every literal. MySQL can't plan a statement with `?`, so there are no source plans; with `@vals='all'`, each entry also carries MySQL's sample of the statement, with its real literals.

## The canonical files

`to-canonical.py raw.json schema.yaml stats.yaml` writes:

- **`schema.yaml`**: canonical types (`integer`, `long`, `decimal` with precision and scale, `string` with length, `char`, `boolean`, `date`, `timestamp`, `timestamptz`, `time`, `binary`), `not_null`, `primary_key`, `unique`, the source's type as `native_type` (kept when the target is the same engine), `fk_constraints`, `load_after`.
- **`stats.yaml`**: per column `null_fraction`, `n_distinct`, `avg_width_bytes`, `min_value`, `max_value`, `most_common_values` (frequencies as fractions of the **non-null** rows, statschema's convention; Postgres and MySQL store fractions of all rows), `histogram_bounds`, `correlation`; per table `indexes` and `foreign_keys` (with `avg_children_per_parent`). The file also says which `values` level it holds.

[`validate.py`](../scripts/validate.py) loads them with statschema's own model.
