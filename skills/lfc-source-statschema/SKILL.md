---
name: lfc-source-statschema
description: "When a customer can't share data but can share their schema and database statistics, build a scaled-down test database with the same shape: collect the statistics from the catalog (no table is scanned, and no data values unless the customer allows them), turn them into tables with lfc-source-datagen formulas (row counts, null fractions, distinct counts, most-common-value frequencies, value ranges, string widths, keys, foreign keys and their skew), fill it inside the database, and check the copy's statistics against the source's. Postgres and MySQL, either direction."
parent: lfc-source-setup
---

# A test database shaped like the customer's, from statistics only

Customers often say: *"I can't give you my data, but you can look at my schema and statistics."* That's enough to build a database that **behaves** like theirs for Lakeflow Connect testing (the same tables and keys, row counts at a chosen scale, the same nulls, cardinalities, and skew) without a single real row leaving their site. The design follows [statschema](https://github.com/rsleedbx/statschema); this skill does it with SQL and two short scripts, and generates the data inside the target with **lfc-source-datagen**.

**FIRST**: use **lfc-source-datagen** for the planners and `fill.sh`; this skill only writes the tables and their formulas.

## How it works

1. **The customer collects statistics** with one read-only query ([collect-postgres.md](references/collect-postgres.md), [collect-mysql.md](references/collect-mysql.md)). It reads only the catalog and the optimizer's statistics, so it is cheap on 10,000 tables and touches no table data. The output is one JSON file in statschema's `stats.yaml` field names.
2. **They review the file and send it.** It's plain JSON; `jq` shows what's in it (below). Data values are in it only if they chose `values=ranges` or `all`.
3. **`shape.py` writes the tables** ([build.md](references/build.md)): the same columns, keys, unique keys, foreign keys, and indexes, with types mapped by sqlglot when the target engine differs, and a formula per column (an `lfc:v` tag) that reproduces its statistics at the chosen scale. It also writes `expected.json`, the statistics the copy should have.
4. **`fill.sh` fills the copy** inside the target database, parents first.
5. **`compare.sql` checks the copy**: collect its statistics with the same collector and compare them with `expected.json` in DuckDB. It prints only what's off.

## What the copy reproduces

| Statistic | How | Notes |
|---|---|---|
| Row count | `--scale` × the source's; tables of `--keep-small` rows or fewer (default 1,000: lookup tables) keep their size | Postgres: `reltuples`; MySQL: InnoDB's estimate (can be 10% off) |
| Null fraction | Exactly: the first share of a permutation of the rows is `NULL` | |
| Distinct count | Exactly, at most the rows and the value range: one that is at least 10% of the rows grows with the table, a smaller one stays (categories) | Postgres keeps growing ones as a negative fraction |
| Most common values and their frequencies | Exactly: each value takes its share of a permutation of the rows. Numeric and date values are the real ones if the file has them; otherwise, and always for text, a stand-in value per entry | Up to 100 per column on Postgres, 10 on MySQL (its 1,024-character column comment); when they are every value, the rest are drawn evenly |
| Value range | Numeric and date values spread evenly between min and max (with `values=ranges` or `all`) | Histograms beyond min and max aren't used yet |
| String width | The average width (Postgres `avg_width`), as an `lfc:len` tag | MySQL has no per-column width |
| Keys | One-column keys are numbered 1, 2, …; composite keys from the first two columns (the second runs fastest, spread over its parent if it is a foreign key); a table without a key stays without one and its first integer column numbers the rows | |
| Foreign keys | Every value is a parent key: the source's share of parents with children, the hot parents first if the column has most common values | A composite foreign key to a composite key follows the parent's key formulas |
| Indexes | Created as in the source | MySQL: not on unbounded text |
| Check constraints | Left out unless `--checks` | A cross-column check (`ship <= receipt`) can fail: the statistics don't relate columns |

**Not reproduced:** cross-column relationships (dates in order, totals that sum lines), real text values, histograms beyond the range, and the physical order of rows (`correlation`). Values are never sequential in the key: every draw is a permutation `(n − 1) × p mod rows` with a large prime `p` per column.

## Run

The customer, on their database:

```bash
# Postgres: catalog only; ANALYZE first only if the statistics are stale
psql -X -At -v schema=sales -v values=none -f collect.sql > stats.json
# MySQL: the DBA builds histograms once (ANALYZE TABLE t UPDATE HISTOGRAM ON ... samples the table), then
mysql -N -B -r -e "SET @db='sales', @vals='none'; SOURCE collect.sql" sales | jq -f my-normalize.jq > stats.json
# what's in the file: tables, rows, and which columns carry values
jq -r '.values, (.tables[] | "\(.name) \(.row_count) rows, \(.columns | length) columns")' stats.json
jq -r '.tables[] | .name as $t | .columns[] | select(.min_value or (.most_common_values // [] | any(.value))) | "\($t).\(.name)"' stats.json
```

**Ask the customer which `values` level they accept** before they run it:

| `values` | The file has | The copy gets |
|---|---|---|
| `none` (default) | No data values: names, types, keys, counts, null fractions, distinct counts, frequencies, widths | The shape, with stand-in values |
| `ranges` | Also min, max, and most common values of numeric and date columns | Also real numeric and date ranges and peaks |
| `all` | Also the most common values of text columns (Postgres, MySQL histograms) | The same as `ranges`: text values are never copied |

Table and column names are in the file at every level; if they are sensitive, rename them in the file (consistently) before sending it.

Then, on the test database (see [build.md](references/build.md) for the files):

```bash
uv run -q --with sqlglot python3 -I shape.py stats.json --target pg --scale 0.01 > shape.sql   # also writes expected.json
psql -v ON_ERROR_STOP=1 -c "CREATE SCHEMA sales_s" -c "SET search_path = sales_s" -f shape.sql
DIR=pg bash fill.sh pg sales_s                                 # lfc-source-datagen
psql -c "ANALYZE" && psql -X -At -v schema=sales_s -v values=ranges -f collect.sql > got.json
duckdb -c "SET VARIABLE expected = 'expected.json'; SET VARIABLE actual = 'got.json';" -c ".read compare.sql"
```

Show the plan before creating anything: the tables, total rows (`shape.py` prints them), and where. `shape.py` also prints what it changed: lists of most common values it cut, tables without a key, foreign keys it left to the planner.

## Measured

TPC-H at scale factor 1 (8.66M rows, 8 tables, composite keys and foreign keys) as the "customer", copied at `--scale 0.01` (86,630 rows), `values=ranges`, 4 vCPUs:

| Statistics from | Copy on | Fill | Columns within tolerance |
|---|---|---|---|
| Postgres 16 | Postgres 16 | 6 s | 61 of 61; every table's rows exact |
| Postgres 16 | MySQL 8.4 | 21 s | 55 of 61; the 6 others are high-cardinality columns where MySQL's sampled histograms estimate the distinct count; exact `COUNT(DISTINCT)` on the copy: all within 0.5% |
| MySQL 8.4 | Postgres 16 | 5 s | 61 of 61 |

Tolerances: null fraction and top frequency 0.02 (or 3 standard errors on a small table), distinct count 20%, rows 10%.

## Gotchas

- **Statistics are estimates.** Postgres samples 30,000 rows per table by default (`default_statistics_target` 100); its distinct counts on big tables can be well off. MySQL row counts are InnoDB's estimate, and its histograms are sampled too (`histogram_generation_max_mem_size`). The copy reproduces what the statistics say, not the true numbers.
- **MySQL caches row counts** in `information_schema` for up to a day: the collector sets `information_schema_stats_expiry = 0`, and `ANALYZE TABLE` refreshes them.
- **MySQL columns without a histogram or an index have only their type**: the copy fills them like any datagen column (scrambled, unique-ish). Ask the DBA for histograms on the columns that matter.
- **Checking a MySQL copy:** its statistics are estimates, so a flagged high-cardinality column needs an exact `COUNT(DISTINCT)` before it counts as a miss.
- **Keys are renumbered** from 1 (a source's nation keys 0 … 24 become 1 … 25), and every foreign key follows, so joins work the same.
