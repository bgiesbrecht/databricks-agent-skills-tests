# Replay the source's queries on the copy

[`replay.py`](../scripts/replay.py) plans the source's top queries on the copy (EXPLAIN only: nothing runs) and compares each plan with the source's. A copy that plans like the source behaves like it under the workload; a different plan says where the copy's size or statistics change the optimizer's choices.

```bash
PY="uv run"; S=skills/lfc-source-statschema/scripts
$PY $S/replay.py yaml queries.json > queries.yaml                     # statschema's queries.yaml (tables found by parsing)
# Postgres copy: generic plans, no values needed
$PY $S/replay.py explain queries.json --dialect postgres > explain.sql
psql -X -At -c "SET search_path = sales_s" -f explain.sql > plans.json
$PY $S/replay.py compare queries.json plans.json --dialect postgres --scale 0.01
# MySQL copy: each placeholder becomes a variable set from the column it is compared with
$PY $S/replay.py explain queries.json --dialect mysql --schema shaped.yaml > explain.sql
mysql --force -N -B sales_s < explain.sql > plans.txt                 # -B without -r: each plan on one line
$PY $S/replay.py compare queries.json plans.txt --dialect mysql --scale 0.01
```

- **Parsing and transpiling**: sqlglot parses each query in the source dialect (Postgres' `date $1` is read as `CAST($1 AS date)`) and writes it for the copy's, so a Postgres workload replays on MySQL and the other way.
- **Placeholders**: on Postgres, `$1, $2, …` stay and `EXPLAIN (GENERIC_PLAN, FORMAT JSON)` plans without values (16+). On MySQL, each becomes `@lfc_pN`, set to a value of the column it is compared with (`SELECT col FROM table LIMIT 1`, using `--schema` to find the table); a `LIMIT` placeholder becomes 10 and a Postgres interval placeholder 30 days.
- **The comparison** per query: whether it planned; the access to each table (full scan or index); the join methods; and, for queries without grouping, aggregates, or `LIMIT`, the estimated rows against the source's times `--scale` (within 3×).

Measured: TPC-H's top 10 queries from Postgres SF 1, on a 1% copy. All 10 plan on the Postgres copy, 8 with the source's plan shape: the other 2 use a nested loop instead of a hash join, and an index instead of a scan, on 100× less data. All 10 plan on a MySQL copy, 5 with the same shape: MySQL has an index on every foreign key and joins differently. Two placeholders compared with one column get the same sample value, so a `BETWEEN $1 AND $2` plans a 1-row range on MySQL.
