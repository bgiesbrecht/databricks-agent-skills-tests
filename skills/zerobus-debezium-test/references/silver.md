# Silver, gold and traceability

## Traceability: the schema and the pipeline files, next to the snapshot

A run's volume holds everything silver was built from, so a table can be traced back to its inputs. The snapshot as of T is there. The canonical schema is in `_schema/`: statschema's `schema.yaml`, from the UC connection ([scripts/schema-tsv-to-canonical.py](../scripts/schema-tsv-to-canonical.py)) or from the source's DDL (**lfc-source-statschema** `ddl-to-schema.py`), and checked with that skill's `validate.py`. The pipeline files generated from that schema are in `_pipeline/<step>/`. Steps: `1-at-T`, `2-round-4` (a column added), `3-round-5` (a column dropped, another retyped). Each is a claim (`trace-<step>`).
## Silver (phase 2)

The full run (rounds 1 to 5, SCD types 1 and 2, gold) passed all 30 claims on 2026-10-20, run 1792534627.

**One generator, for every source and model.** [scripts/silver-from-schema.py](../scripts/silver-from-schema.py) is the whole silver pipeline, on both routes. It reads the canonical `schema.yaml` (statschema's format) from the volume's `_schema/` when the pipeline starts, and defines every view, table and flow in a loop. Nothing in it names a table, a column or a type. On the VM route, the schema read through the UC connection becomes that `schema.yaml` ([scripts/schema-tsv-to-canonical.py](../scripts/schema-tsv-to-canonical.py)); on the laptop route, the source's DDL does (**lfc-source-statschema** `ddl-to-schema.py`). The tables come from the source as well (every base table in its schema), so the same script runs a TPC model from **lfc-source-statschema** unchanged. What stays per model is the source's setup, the workload and its checks (rounds 1 to 5), and gold, which is written for one reader's question. A schema change is: a new `schema.yaml` in the volume, then a full refresh of the changed tables. No code is regenerated.

For each source table, it defines two temporary views and two AUTO CDC flows into one streaming table, SCD type 1, `CLUSTER BY` the key:

| Flow | Reads | Columns | Sequence |
|---|---|---|---|
| `<table>_from_snapshot` | `STREAM read_files('<volume>/<table>', format => 'parquet')` | `CAST(<column> AS <type>)` | T, the snapshot time, in nanoseconds |
| `<table>_from_changes` | `STREAM(cdc_log) WHERE destination = 'crdb.public.<table>'` | keys from `key:<column>`, the rest from `value:after:<column>`, with the type; `APPLY AS DELETE WHEN operation = 'delete'` | `value:ts_ns` |

**Both SCD types from one change log.** Each table also gets `<table>_history`, `STORED AS SCD TYPE 2`, fed by the same snapshot view and by `<table>_changes_dedup`. That view reads `cdc_log_dedup`, a temporary view in the same file that drops replays: `dropDuplicatesWithinWatermark` on `destination`, `idempotency_key`, `operation` and the row image (`TO_JSON(value:after)`), with a 10-minute watermark on `ts_ns`. The key alone can't be used, since two different updates can share it ([Round 3](rounds.md#round-3-debezium-killed-and-restarted)). SCD type 1 reads the change log as it is, because replays don't change its result. `customers_history_nodedup` is SCD type 2 without the deduplication, to show what a restart does.

[scripts/scd2-history-check.py](../scripts/scd2-history-check.py) checks every version. The truth is CockroachDB's own changefeed from T (`EXPERIMENTAL CHANGEFEED FOR ... WITH updated, cursor = T`), which has each row's commit time. Each key's expected versions are its row at T, then its row after every insert or update, in commit order. The check compares those with the history table ordered by `__START_AT`. It runs from the skill folder, or set `CHECK=<path>`.

The types and the key come from CockroachDB's `information_schema` through `remote_query` on a POSTGRESQL UC connection: `bigint`, `numeric(p,s)`, `text` map to `BIGINT`, `DECIMAL(p,s)`, `STRING`. An insecure node takes any password. The keys come from `key`, not `after`, because a delete's `after` is null.

The check compares every row of every table, source and silver, ordered by the key. It runs after the phase 1 changes, then again after a second round with two updates of one key, a delete and reinsert of one key, a reinsert of a key deleted in round 1, and a decimal update. Passed on 2026-10-20 (run 1792530422): `customers` 6 then 7 rows, `orders` 5 then 5, all equal.

**CockroachDB `EXPORT INTO PARQUET` corrupts DECIMAL (v25.4.13).** It writes a DECIMAL column as `BYTE_ARRAY` annotated `DECIMAL(10,2)`, but fills it with the number's text. Readers decode the text as the unscaled integer: `21.00` (`0x32312E3030`) reads as `2155734753.76`, in Databricks and in DuckDB alike. Silver was wrong only for the snapshot rows; the change log's decimals were right. The script exports DECIMAL columns as `STRING` (`<column>::STRING`, from `information_schema`), and silver casts them back.

## Gold (phase 3)

`customer_orders` is a materialized view over silver: each customer with the count and total of their orders, `CLUSTER BY (tier)`. The check runs the same query on CockroachDB and compares every row. Results on 2026-10-20 (run 1792531795):

- **Gold equals the source** after every round (6, 7, 8 and 8 rows).
- **The view refreshes incrementally.** The first update is `COMPLETE_RECOMPUTE` (`FIRST_COMPUTATION`), and the second is `GROUP_AGGREGATE`, `INCREMENTALIZATION_STATUS_INCREMENTAL`. That works because AUTO CDC's backing tables have row tracking and change data feed on. Read it from `event_log('<pipeline id>')`, `event_type = 'planning_information'`: `list-pipeline-events` returns those events without `details`.
- **Clustering** is as declared: bronze on `destination`, silver on `id`, gold on `tier`. `DESCRIBE DETAIL` fails on a materialized view; `DESCRIBE TABLE EXTENDED` shows `clusteringColumns` for all three.
