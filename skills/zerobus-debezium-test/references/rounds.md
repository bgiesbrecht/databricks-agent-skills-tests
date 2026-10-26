# The workload, and rounds 3 to 5

`model-sql.py`'s workload, the same for every model:

- **Tables with a key** get inserts of new keys (after each key column's maximum), updates of one column that isn't a key, a foreign key or unique, and deletes only of rows the workload inserted, so a foreign key never blocks one. A foreign key column takes the parent's first row.
  - Round 1: 3 inserts, 1 update, 1 delete.
  - Round 2: two updates of one row, a delete and reinsert, and a reinsert of the key deleted in round 1.
  - Round 3: an insert and two updates, then, after the producer restarts, one more update.
- **Tables whose key is all foreign keys** get the updates only.
- **Tables without a key** (TPC-B's `history`) get inserts only. Silver keeps them append-only and compares them as a multiset.
- **Round 4** adds `lfc_r4 VARCHAR(20) NOT NULL DEFAULT 'none'` to the first table with a key.
- **Round 5** retypes that model's first non-key decimal column (two more digits; else an integer becomes `BIGINT`, but not on CockroachDB, where `INT` is already 8 bytes). It drops another column that isn't a key, a foreign key or named in the gold file.

A manifest per round lists every table's expected events, which the change-log claims wait for. Both sides render each value alike: NULL as `<null>`, timestamps in UTC to the microsecond, `char` without its padding, booleans as `true`/`false`. The rows are compared sorted, since the two sides' collations differ.
## Round 3: Debezium killed and restarted

After 4 changes reach bronze, Debezium gets SIGKILL (no offset flush) and is started again. Then one more change.

- **The stream resumes**, and silver and gold equal the source.
- **The restart replays events.** 5 changes gave 9 bronze rows: after the restart, Debezium re-sent the 4 changes made since its last offset (the resolved timestamp), with new `ts_ns`. Zerobus doesn't deduplicate by `idempotency_key`; the replays landed as new rows. SCD type 1 silver is still right, because the replay comes in commit order and AUTO CDC keeps the latest `ts_ns`.
- **SCD type 2 needs the replays removed.** Without deduplication, `customers_history_nodedup` recorded the replay as history that never happened: customer 4 went bronze, silver, gold, then silver and gold again, 17 versions where the source had 15. With `cdc_log_dedup`, `customers_history` matched the changefeed version for version (15 of 15), as did `orders_history` (11 of 11), and the current versions (`__END_AT IS NULL`) equal the source.
- **`idempotency_key` isn't unique per change.** Two different updates of one row, made in quick succession, get the same key: customer 1 `platinum` then `diamond`, and customer 4 `silver` then `gold`, each pair one key. The key seems to come from the table, the operation and the connector's offset time, which is the missing commit time again ([Commit time](debezium.md#commit-time-not-in-the-event-cockroachdb-connector-370final)). **Don't deduplicate by `idempotency_key`:** it would drop real changes, and could keep `platinum` instead of `diamond`. To remove replays, deduplicate on `destination`, `key`, `value:after` and `operation` within a short window, or let AUTO CDC absorb them, as here.

## Round 4: a column added on the source

`ALTER TABLE shop.customers ADD COLUMN email STRING NOT NULL DEFAULT 'none'`, then one update that sets `email`.

| Step | What happened |
|---|---|
| Bronze | The column arrives with no Databricks DDL: `value:after:email`. CockroachDB's changefeed backfills the new column, so every existing row came again as an `update` with `email = 'none'` (8 rows), plus the real update: 9 events |
| Silver, old flow | The update runs; silver keeps `id, name, tier` and leaves `email` out |
| Silver, regenerated | The schema is fetched again through the connection, and the new `schema.yaml` goes into the volume (snapshot rows get the column's default, or `NULL`, for a column added after T). A plain update adds the column but fills it only for changes after that update: every row had `email` null, because the backfill events were already behind the flow's checkpoint |
| Full refresh of `customers` | `full_refresh_selection` with `customers` and its history tables replays the snapshot and the whole change log, backfill included. Silver equals the source, `email` too |
| Plain update | An update with `full_refresh_selection` runs only the selected tables; gold and the rest catch up in the next plain update |

So, after a schema change: regenerate the table's flows, **full-refresh that table and its history**, then run a plain update for everything downstream. Silver can always be rebuilt from the snapshot and bronze, so this is cheap at this size.

## Round 5: a dropped column and a retyped one

`ALTER TABLE shop.orders DROP COLUMN status`, then `ALTER COLUMN amount TYPE DECIMAL(12,2)` (from `DECIMAL(10,2)`, with `enable_experimental_alter_column_type_general`). Then an update to `1234567890.12`, which only the new type holds.

| Step | What happened |
|---|---|
| Bronze | No DDL needed. Unlike an added column, neither change made the changefeed send the existing rows again: the only new event is the update, without `status` |
| Silver, old flow | The update **fails**: `orders_from_changes` and `orders_history_from_changes` stop on `INVALID_VARIANT_CAST`. The dropped column's `value:after:status::STRING` can't be cast. The type change wasn't reached |
| Silver, regenerated | The schema again through the connection: `status` gone, `amount DECIMAL(12,2)`. Full refresh of `orders` and `orders_history`, then a plain update: silver, the current history and gold equal the source |

A failed flow is the signal to regenerate, as the design expects. An added column doesn't fail anything, so it needs the column check.
