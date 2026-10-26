# Many sources, bronze layouts, and schema drift

The common case: N identical tables on many hosts, merged into one silver table per table. The design aims at 10,000s of source tables and many hosts, without a schema change stopping anything upstream.

**Many sources (`NSRC=N`).** The test runs N databases with the model, `<MODEL>1` to `<MODEL>N`, side by side on one host.
- **Producers:** each database has its own producer (a Debezium Server each; on the Kafka route, every source's connector runs in one worker). Each producer's destination prefix is `<SOURCE><i>.<schema>`.
- **Volume:** [`_sources.yaml`](../scripts/silver-from-schema.py) lists each source's prefix, T and snapshot format. Snapshots go to `<table>/<prefix>/`, so the folder names the source.
- **Silver:** every row carries `_source`. With more than one source the key is (`_source`, primary key), so identical keys from different hosts stay apart, and each key's changes are ordered within its own source.
- **Gold:** with more than one source, gold is `models/<MODEL>-gold-multi.sql` (the same query, grouped by `_source` too). It's checked against the single-source query run on each source.

**Bronze (`BRONZE`).** Only where silver reads from changes; silver, gold and the schema don't.

| `BRONZE` | Producers write | Silver reads | When |
|---|---|---|---|
| `shared` (default) | `cdc_log` | `cdc_log`, filtered by table | Few tables or low volume: each table's flows re-read the whole log |
| `fanout` | `cdc_log` | `cdc_log_<table>`, or `cdc_log_s<k>` with `BRONZE_SHARDS=K`, written by [scripts/fanout.py](../scripts/fanout.py) | Many tables or high volume. The shared log needs no DDL for a new table or column, and the fan-out creates a table's bronze table on its first events, so nothing upstream stops. `{table}` suits up to hundreds of tables; for 10,000s, `{shard}` with K about the number of silver pipelines |
| `per-table` | `cdc_log_<table>` (Kafka route only) | its own | Lakeflow Connect's layout. A new source table first needs its bronze table, its grant and the producer's routing, so shipping waits on setup |

**The likely path:**
1. Start with `shared`.
2. Move a table out when its volume starts slowing the others. In `shared`, every table's flows read every other table's events, so the hot tables go first.
3. Route a table at the source (`per-table`) when it's known in advance, high-volume and latency-sensitive, or needs its own bronze retention or access.

Moving a table:
- the fan-out runs for that table only (`fanout.py --tables <t>`), from the log's beginning, into `cdc_log_<t>`;
- silver's `cdc.bronze_table.<t>` points that table at it;
- a full refresh of that table rebuilds it.

It needs `cdc_log` kept back to T, and the other tables don't stop. In the test, `BRONZE=shared` moves the first table with a key after round 3 (`MOVE=0` to skip, `MOVE_TABLE` to choose another). The claim is `move-<table>`, and rounds 4 and 5 then run with that table on its own bronze.

The fan-out runs as a serverless job before each silver update in the test. Without `--once` it runs continuously. Each micro-batch writes each target with `txnAppId` and `txnVersion`, so a retried batch writes nothing twice. `cdc.shard=i/n` splits silver's tables over n pipelines, past the number of flows one pipeline holds.

**Schema drift (`ON_DRIFT=record`, the default).** Silver keeps flowing on the columns it knows:
- a value that doesn't fit its type becomes NULL;
- a dropped column gets its default, or NULL;
- a new column waits.

Each drift is recorded once per table, source, kind (`type`, `missing`, `new`) and column in `schema_drift`, with the last position and a sample row. `cdc.drift_sample=n` checks one event in n, for high volume.

Evolution is asynchronous and per table:
1. read every source's schema again;
2. merge them with [scripts/schema-union.py](../scripts/schema-union.py), which widens types (integer < long < decimal < string) and refuses tables whose primary keys differ;
3. write each changed table to `_schema/tables/<table>.yaml`;
4. full-refresh only those tables, which replays them from the append-only change log.

The other tables never stop. `ON_DRIFT=fail` casts strictly instead, and an update stops at the first value that doesn't fit.

In the test:
- **Round 4** adds `lfc_r4` on source 1 only.
- **Round 5** drops and retypes on source N only.
- **Claims:**
  - `drift-flows-on-<n>`: the update with the old schema completes;
  - `drift-recorded-<n>`: `schema_drift` has the expected rows;
  - `evolve-<n>`: the union changed only that table;
  - then silver equals each source on that source's own columns.
