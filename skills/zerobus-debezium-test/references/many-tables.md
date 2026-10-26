# Many tables: MERGE silver, measured limits, and placements

`merge-silver.py` reads the same volume as the pipeline: `_sources.yaml`, `_schema/` and `_snapshot.tsv`. One stream reads the change log, and each micro-batch MERGEs only the tables it has events for:
- **Current rows** take each key's newest change, applied only when it's newer than the row.
- **Deletes** leave a row in `_cdc_tombstones`, so a replayed older change can't bring the row back.
- **History:** each version ends at its key's next change (the next version or a delete), recomputed for the keys a batch touches, so a version that arrives late still lands in order.
- **Producer replays:** after a restart, Debezium resends events under a new sequence. Each change carries a fingerprint of its event (`_idem`: idempotency key, operation, row image), and a replay of one already applied is dropped, as the pipeline's dedup view does.
- **Schema drift** is recorded in `schema_drift`, as by the pipeline. A full refresh is `--refresh <tables>`: those tables are replaced with the schema in the volume, loaded from their snapshot, then from every event in their change log.
- **A moved table** reads its own log (`--bronze-table t=cdc_log_t`), in a stream of its own.
- **Gold** is the same materialized view, made and refreshed by SQL after each run. Tables have row tracking and deletion vectors on, so it refreshes incrementally (`GROUP_AGGREGATE` after round 2).

Through rounds 1 to 5 (`SILVER=merge` on `shop`), MERGE silver passes the same checks as the pipeline: changes, producer restart and history, the moved table, an added column, a dropped and a retyped one, and gold. There's no `_history_nodedup` table.

Tested on the Azure VM with empty tables, 2026-10-22 (outcomes in `results/runs/2026-10-22-zerobus-scale.jsonl`):

| Silver | Source tables that passed | Where it stopped |
|---|---|---|
| Pipeline (AUTO CDC) | 10, 100, and 1000 on 4 pipelines | Not tried higher: start-up grows with the tables in a pipeline |
| MERGE job | 10, 100, 1000, 2000, 4000 | 8000 in one schema: Unity Catalog's 10,000 tables per schema |
| MERGE jobs, a schema each (`PIPES=4 SPLIT=1`) | 8000 (15,746 silver tables in 4 schemas) | Not tried higher |

A pipeline declares every table, view and flow when each update starts, and resolving that graph is most of each update, even one with no changes. MERGE declares nothing per table, so a run with no changes doesn't grow with the table count. Above about 5000 source tables, silver has to span more than one schema (`SPLIT=1`), or the account team raises the quota (it isn't fixed).

Found on the way, and fixed:
- TPC-E has both `holding` and `holding_history`, so the history tables' suffix is a setting (`cdc.history_suffix`); the run uses `__history` when `_history` would clash with a source table.
- On a VARIANT column a bracketed field follows a colon: `key:['SK_TimeID']`.
- An append-only table with a `TIMESTAMP_NTZ` column needs the `timestampNtz` table feature turned on.
- A `once` append flow takes a batch source only, so only the AUTO CDC snapshot flows are `once`.

**Producer limit.** Debezium Server 3.7.0 waits a fixed 40 s for its connector task to start, and doesn't read `task.management.timeout.ms`: the log says "Waiting max. for 40000 ms" whatever it's set to. At start, the CockroachDB connector runs the JDBC column-metadata query once per table, which is slow on CockroachDB, so one producer starts only a few hundred tables at most: 100 started, 1000 didn't, nor did 4 producers of 250 against the one node.

**More producers, started one at a time.** `DBZ_SHARDS=K` splits the tables over K Debezium Servers, one changefeed each, and starts them one after another: each waits for the one before to reach `POLLING_TASKS` (or fail). Started all at once, the servers' JVMs compete for the host's CPU and spend the 40 s starting up. On the 4-vCPU test VM, 1000 tables streamed on 20 servers of about 50 tables each; 12 servers of about 83 tables, started one at a time, got only 4 to stream, and 12 started at once got none. Keep a server's tables well under what starts in 40 s, and count its changefeed against CockroachDB's recommended maximum per cluster (see lfc-source-sizing's limits).

## Composite: a placement per table group

`PLACEMENT=<placement.yaml>` replaces the global `BRONZE`, `SILVER`, `PIPES` and `DBZ_SHARDS` with one choice per table group ([scripts/placement.py](../scripts/placement.py); an example: [placements/mix20-busy-quiet.yaml](../placements/mix20-busy-quiet.yaml)). Each group lists its tables or a pattern, and says:
- its producers: how many Debezium Servers, started one at a time;
- its bronze: `own` (`cdc_log_<table>`, written by the fan-out from `cdc_log`) or `shared` (`cdc_log`);
- its silver: `pipeline` (AUTO CDC, one pipeline for the group) or `merge` (`merge-silver.py` jobs).

The run writes `_placement.tsv` (one row per table) to the volume; the pipeline (`cdc.placement_group`) and each MERGE job (`--placement-group`) read their tables from it. Each silver update runs the fan-out once, then the pipelines and the MERGE jobs; a full refresh goes to whichever builds the table. A MERGE group records drift in `schema_drift_<group>` (the pipeline owns `schema_drift`), and keeps its own state tables (`_cdc_tombstones_<group>`, ...). One pipeline group so far, and gold is made by SQL after both silvers, over both. A producer server the placement gives no tables isn't started. With `ROUNDS=5`, `BRONZE=shared`; no table move.
