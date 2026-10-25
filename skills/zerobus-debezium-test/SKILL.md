---
name: zerobus-debezium-test
description: "Test database change data capture through Debezium Server's Zerobus sink: CockroachDB in Podman on a cloud VM, a snapshot as of T into a Volume, Debezium Server 3.7 streaming the changes from T through Zerobus into one append-only bronze change log, and silver AUTO CDC tables built from the source schema read through a UC connection. Checks that silver equals the source after inserts, updates and deletes, records the versions, and cleans up. Silver is kept both ways, current rows (SCD type 1) and every version (SCD type 2), checked against the source's own changefeed. Then gold, a materialized view, and three harder rounds: Debezium killed and restarted, a column added, and a column dropped and another retyped. Phases 1 to 3 of the Debezium -> Zerobus -> bronze -> silver -> gold test."
parent: lfc-source-cloud-vm
---

# Debezium -> Zerobus -> bronze -> silver -> gold

[scripts/debezium-zerobus.sh](scripts/debezium-zerobus.sh) runs the whole test from your laptop. It drives a cloud VM over SSH, and the VM runs the source database and Debezium Server in Podman. Debezium pushes each change to Zerobus, which appends it to one change-log Delta table for all source tables. Debezium needs only outbound 443 to the Zerobus endpoint. Phase 2 adds a snapshot as of T, taken with `EXPORT INTO PARQUET` and copied into a Volume, and a silver pipeline. The pipeline is generated from the source's schema, read through a UC connection, so serverless reaches CockroachDB on `CRDB_PORT`. Phase 3 adds gold and rounds 3 and 4. `PHASE=1` stops after bronze, `PHASE=2` after silver.

This isn't Lakeflow Connect. It's for sources Lakeflow Connect doesn't cover, or for teams that want the change log itself as an append-only bronze table.

## What it creates, and removes at the end

| Where | What |
|---|---|
| Workspace | Schema `<prefix>_<source>_<model>_dbz_<epoch>` in `CATALOG` (for example `robertlee_crdb_shop_dbz_<epoch>`; `MODEL` is `shop` for this test's own `customers` and `orders`, or the TPC model from **lfc-source-statschema** a run uses: `tpcb`, `tpcc`, `tpch`, `tpcds`, `tpce`, `tpcdi`; see [Models](#models)), with the bronze table `cdc_log`: `target_table`, `operation` (`create`, `update`, `delete`), `idempotency_key`, and `key`, `value` (the Debezium event: `after`, `op`, `ts_ns` with the default `DROP_FIELDS`), `source_position` and `headers` as `VARIANT`. `CLUSTER BY (destination)`, the source table's topic (`target_table` is always the log itself) |
| Workspace (phase 2) | In the same schema: Volume `snapshot`, one folder per source table, and for traceability `_schema/` (the canonical `schema.yaml` the views were built from: `schema-at-T.yaml`, the current `schema.yaml`, and `history/<step>-schema.yaml` for each regeneration, each checked with statschema's `validate.py`) and `_pipeline/<step>/` (the pipeline files built from it); silver streaming tables `<table>` for every source table (SCD type 1; append-only for a table without a key), `<table>_history` (SCD type 2, replays removed), `<first table with a key>_history_nodedup` (SCD type 2 without that), and the model's gold materialized view (`customer_orders` for `shop`), made by the serverless pipeline `<prefix>-<source>-<model>-dbz-silver-<epoch>` from `silver-from-schema.py` and `gold.sql` in a workspace folder `<source>_dbz_<epoch>` in your home; UC connection `<prefix>-<source>-dbz-<epoch>` (POSTGRESQL, to the VM's `SRC_PORT`, or the next free port up to 30063) |
| Workspace | Service principal `<prefix>-zerobus-dbz-<epoch>` with an OAuth secret, granted `USE CATALOG`, `USE SCHEMA`, `SELECT` and `MODIFY` on `cdc_log`. Zerobus writes as it |
| VM | Podman network `crdb-dbz-<epoch>`, containers `<prefix>-crdb-<epoch>` (CockroachDB, single node, insecure, published on `CRDB_PORT`, default 30026) and `<prefix>-debezium-<epoch>` |

The OAuth secret is never printed. It goes from the CLI's response into Debezium's `application.properties` in 0600 temp files, on the laptop and on the VM, which are deleted when the run ends. `KEEP=1` keeps everything for a look afterwards.

## Models

One canonical `schema.yaml` per model (statschema's format, **lfc-source-statschema**) drives the whole run, and no script names a table or a column. `MODEL=<name>` reads [models/](models/)`<name>.yaml`, or **lfc-source-statschema**'s `schemas/<name>.yaml` (`tpcb`, `tpcc`, `tpch`, `tpcds`, `tpce`, `tpcdi`). `shop`, the default, is [models/shop.yaml](models/shop.yaml). `SF` (default 0.001) scales the TPC models' `row_count_per_sf`.

| Step | Script |
|---|---|
| Size it, and tag each column for the data generator | **lfc-source-statschema** `shape.py --sf $SF` |
| The DDL | **lfc-source-statschema** `ddl.py --dialect cockroachdb` or `postgres` |
| Fill it, before T | **lfc-source-datagen** `fill.py pg`, in a container on the run's Podman network |
| The changes of rounds 1 to 3, the schema changes of rounds 4 and 5, and the queries every check compares | [scripts/model-sql.py](scripts/model-sql.py) |
| Silver | [scripts/silver-from-schema.py](scripts/silver-from-schema.py), from the canonical schema read back from the source |
| Gold | `models/<name>-gold.sql`, when there is one: `-- name:`, `-- cluster_by:`, `-- comment:` header lines and a query on the model's tables. No file, no gold claims |

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

## What a production pipeline meets

Behaviors these tests found in the sources, Debezium, and the bronze and silver layers. Each would break the same pipeline outside the test; the fix the harness uses is in the scripts named. Every finding, with the combination it applies to (source, route, layer, topology), is also in the findings register, [docs/findings.md](../../docs/findings.md): record a new one with **lfc-test-results** `finding.py add` as it's found, and look up a customer's combination with `finding.py --source <s> --route debezium-zerobus --topology <t>`.

**Source and change capture**
- **MySQL through 9.5 and MariaDB don't log foreign key actions.** InnoDB's own `ON DELETE CASCADE` and `SET NULL` changes aren't in the binlog, so no binlog reader sees them, and silver keeps child rows the source deleted. PostgreSQL, SQL Server, Oracle and MySQL 9.6+ log them. Silver applies them after each update and records each one ([MySQL and an application's schema](#mysql-and-an-applications-schema-sourcemysql-appmautic), `scripts/fk-actions.py`).
- **Oracle 23+ and Db2 tables with a `BOOLEAN` column aren't captured, and nothing says so.** Debezium's Oracle connector doesn't support Oracle 23's native `BOOLEAN`, and Db2's SQL Replication can't capture `BOOLEAN` (both documented). On Oracle those tables simply never change in bronze; on Db2 the first change to such a table stops the capture program for every table (`ASN0552E` SQLCODE -804, then `ASN0008I` in `ASNCDC.IBMSNAP_CAPTRACE`), while the registrations still show active and Debezium still reports streaming. Check the schema for `BOOLEAN` columns first; use `NUMBER(1)` (with Debezium's `NumberOneToBooleanConverter`) or `SMALLINT` 0/1. The harness maps the models' booleans to `SMALLINT` 0/1 on both.
- **SQL Server logs no update that changes nothing**, so CDC and Debezium have no event for it; PostgreSQL and Oracle send one. Nothing is lost (the row didn't change), but an event count or a trigger-based audit won't match the change log.
- **A column added on SQL Server needs a new CDC capture instance**, and Oracle's LogMiner with the online catalog doesn't follow DDL (the redo-log catalog does). Plan schema changes before relying on them.
- **Db2's capture agent:** started through `ASNCDC.ASNCDCSERVICES` from a driver, the call never returns. Start `asncap` as the instance user, and register tables (`ADDTABLE`) with the agent running, then reinitialize it (`asnccmd ... reinit`); registrations made otherwise stay inactive.
- **Informix ignores a string's trailing blanks** in comparisons and in `LENGTH`; the change stream and silver keep them as stored.
- **The snapshot is consistent with the log position only while nothing writes** (PostgreSQL, SQL Server, Oracle, Db2, Informix here): see [Trade-offs](#trade-offs).

**Debezium**
- **A connector whose start fails leaves Debezium Server running and capturing nothing** (Oracle's version check timing out, `ORA-17002`, with two databases starting at once). No error reaches Zerobus. Check each server's log for `Starting streaming` and restart it on `Engine has failed`.
- **Temporal values arrive as numbers whose unit depends on the column's precision:** days for a date; milliseconds (3 digits or fewer), microseconds (4 to 6, and PostgreSQL's default) or nanoseconds (7 to 9: SQL Server's `DATETIME2` and `TIME` default) for timestamps and times; Oracle's `DATE` holds a time and comes as epoch milliseconds. Silver must decode each by the column's type and precision (`decode()` in `scripts/silver-from-schema.py`).
- **Oracle and Db2 send unquoted names in upper case** (`ORACLE1.TPCH1.ORDERS`); silver's schema has to match.
- **What orders a key's changes differs per source**: the LSN, change LSN, SCN, or binlog position (`cdc.seq`, the sources table below). CockroachDB's connector drops the commit time ([Commit time](#commit-time-not-in-the-event-cockroachdb-connector-370final)).

**Bronze and silver**
- **Read every temporal type from the source's schema.** A `time` column read as a string keeps Debezium's microseconds (`1300000000` for `00:21:40`); `information_schema`'s `time without time zone` must map to a time.
- **Liquid clustering needs stats on its columns, and Delta collects them for the first 32 only.** With many sources the key starts with `_source`, which comes last, so a wide table's first update fails with `DELTA_CLUSTERING_COLUMN_MISSING_STATS`. Name the stats columns (`delta.dataSkippingStatsColumns`): the clustering columns first.
- **A table that foreign key actions change can't be append-only**: its rows must be deletable. cdc-table-plan gives such tables SCD type 1.

## Many sources, bronze layouts, schema drift

The common case: N identical tables on many hosts, merged into one silver table per table. The design aims at 10,000s of source tables and many hosts, without a schema change stopping anything upstream.

**Many sources (`NSRC=N`).** The test runs N databases with the model, `<MODEL>1` to `<MODEL>N`, side by side on one host.
- **Producers:** each database has its own producer (a Debezium Server each; on the Kafka route, every source's connector runs in one worker). Each producer's destination prefix is `<SOURCE><i>.<schema>`.
- **Volume:** [`_sources.yaml`](scripts/silver-from-schema.py) lists each source's prefix, T and snapshot format. Snapshots go to `<table>/<prefix>/`, so the folder names the source.
- **Silver:** every row carries `_source`. With more than one source the key is (`_source`, primary key), so identical keys from different hosts stay apart, and each key's changes are ordered within its own source.
- **Gold:** with more than one source, gold is `models/<MODEL>-gold-multi.sql` (the same query, grouped by `_source` too). It's checked against the single-source query run on each source.

**Bronze (`BRONZE`).** Only where silver reads from changes; silver, gold and the schema don't.

| `BRONZE` | Producers write | Silver reads | When |
|---|---|---|---|
| `shared` (default) | `cdc_log` | `cdc_log`, filtered by table | Few tables or low volume: each table's flows re-read the whole log |
| `fanout` | `cdc_log` | `cdc_log_<table>`, or `cdc_log_s<k>` with `BRONZE_SHARDS=K`, written by [scripts/fanout.py](scripts/fanout.py) | Many tables or high volume. The shared log needs no DDL for a new table or column, and the fan-out creates a table's bronze table on its first events, so nothing upstream stops. `{table}` suits up to hundreds of tables; for 10,000s, `{shard}` with K about the number of silver pipelines |
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
2. merge them with [scripts/schema-union.py](scripts/schema-union.py), which widens types (integer < long < decimal < string) and refuses tables whose primary keys differ;
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

## Many tables: silver by pipeline or by MERGE

`MIX=N` builds N tables from copies of the TPC models (`scripts/mix-models.py`: `tpcb001_branch` ... `tpcdi085_DimMessage`, 95 tables a copy). The settings for this test:

| Setting | What it does |
|---|---|
| `EMPTY=1` | Creates the tables with no rows (no fill.py, and the datagen tags are left out of the DDL) |
| `FKS=0` | Leaves the foreign keys out: CockroachDB takes much longer to add a foreign key than to create a table |
| `ROUNDS=0` | No changes. The run stops after the snapshot and silver's first update, then checks every silver table at once (columns and row counts against the source), times a second update with nothing new, and checks that each producer is streaming |
| `PIPES=K` | K silver pipelines (or K MERGE jobs), each with the tables of `crc32(name) % K` |
| `SPLIT=1` | With `SILVER=merge` and `PIPES=K`: job k writes its silver tables to their own schema, `<S>_s<k>` (bronze and the volume stay in `<S>`) |
| `SILVER=merge` | Silver without a pipeline: `scripts/merge-silver.py` as a serverless job, with MERGE instead of AUTO CDC (`BRONZE=shared` only so far) |
| `DBZ_SHARDS=K` | K Debezium Servers per source, each with the tables of `crc32(name) % K`, started one at a time (each waits up to `DBZ_START_WAIT` s for the one before) |

`ROUNDS=0 PHASE=1` runs the producers only.

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

`PLACEMENT=<placement.yaml>` replaces the global `BRONZE`, `SILVER`, `PIPES` and `DBZ_SHARDS` with one choice per table group ([scripts/placement.py](scripts/placement.py); an example: [placements/mix20-busy-quiet.yaml](placements/mix20-busy-quiet.yaml)). Each group lists its tables or a pattern, and says:
- its producers: how many Debezium Servers, started one at a time;
- its bronze: `own` (`cdc_log_<table>`, written by the fan-out from `cdc_log`) or `shared` (`cdc_log`);
- its silver: `pipeline` (AUTO CDC, one pipeline for the group) or `merge` (`merge-silver.py` jobs).

The run writes `_placement.tsv` (one row per table) to the volume; the pipeline (`cdc.placement_group`) and each MERGE job (`--placement-group`) read their tables from it. Each silver update runs the fan-out once, then the pipelines and the MERGE jobs; a full refresh goes to whichever builds the table. A MERGE group records drift in `schema_drift_<group>` (the pipeline owns `schema_drift`), and keeps its own state tables (`_cdc_tombstones_<group>`, ...). One pipeline group so far, and gold is made by SQL after both silvers, over both. A producer server the placement gives no tables isn't started. With `ROUNDS=5`, `BRONZE=shared`; no table move.

## MySQL and an application's schema (`SOURCE=mysql APP=mautic`)

`SOURCE=mysql` runs MySQL 8.4 (`SRC_IMAGE`) with Debezium Server's MySQL connector. `APP=mautic` installs Mautic, an open-source marketing application, into each source database (**mautic-source**). The test collects the installed schema back as the model, and **cdc-table-plan** guesses each table's silver, written to `<volume>/_plan.yaml`. The rounds are the application's own traffic (`ROUNDS=app`). Silver orders events by binlog file, position and row (`cdc.seq=binlog`). The snapshot is taken as of a binlog position T, in one consistent-snapshot transaction.

**Foreign key actions aren't in the binlog through MySQL 9.5.** InnoDB carries out `ON DELETE CASCADE` and `SET NULL` itself and doesn't log the child rows it changes, so a binlog reader never sees those changes. The MySQL manual, "Replication and CASCADE": "the cascading deletes are handled internally by the InnoDB storage engine, which means that none of the changes are logged." From 9.6 the server handles foreign keys and logs those rows, unless `innodb_native_foreign_keys=ON`. Waiting doesn't help: the changes never arrive. [scripts/fk-cascade-check.sh](scripts/fk-cascade-check.sh) tests an engine. Each engine deletes a parent and changes a referenced key, and the script reads the change log right away and again after a wait:

| Engine | Change log | CASCADE child deletes | SET NULL child updates | ON UPDATE CASCADE |
|---|---|---|---|---|
| MySQL 8.4 | binlog | missing | missing | missing |
| MariaDB 11.4 | binlog | missing | missing | missing |
| MySQL 9.7 | binlog | logged | logged | logged |
| PostgreSQL 16 | logical decoding | logged | logged | logged |
| SQL Server 2022 | CDC, Change Tracking | logged | logged | logged |
| Oracle 23 | LogMiner | logged | logged | (no such action) |

So on MySQL 8.4 a contact deleted in Mautic leaves its segment memberships and event-log rows in silver. Mautic's schema has 125 CASCADE and 65 SET NULL foreign keys.

How silver handles it (the harness turns it on for MySQL before 9.6 and MariaDB):
- **The rules:** the collector records each foreign key's `on_delete` in the canonical schema.
- **After each silver update** ([scripts/fk-actions.py](scripts/fk-actions.py)): the source enforces its foreign keys, so at a consistent point no child row references a parent that's gone. For each CASCADE or SET NULL foreign key, the child rows whose key matches no current parent row are deleted (CASCADE) or get the columns NULL (SET NULL), in current rows and in the history (the open version closed at the parent's delete, a new one opened for SET NULL). One query first counts every key's such rows, so a pass runs only the statements of the keys with some; passes repeat until one finds none (chains).
- **The trace:** each change is first a row in `fk_actions`: the table, source, key, operation, the foreign key, and when.
- **In the pipeline instead** (`FK_IN_PIPELINE=1`, silver's `cdc.fk_actions=apply`): the changes derived from each parent delete in the change log, at its sequence, into the child's own change views, with each child's versions computed once per update (`_fkv_<child>`). Exact to the parent's sequence, but it made Mautic's first update run past an hour.
- **The plan:** a table such a foreign key changes can't be `[append]`. `classify.py` makes it `[scd1]`, and `plan.py` warns about an edit that appends it.

## PostgreSQL, SQL Server, Oracle, Db2, Informix and MySQL with the TPC models (`SOURCE=pg`, `mssql`, `oracle`, `db2`, `informix`, `mysql`)

Each runs the TPC models through Debezium Server's own connector and the Zerobus sink. The same model, rounds and checks apply to every source; only these parts differ:

| Source | Change capture | T, and silver's sequence | Snapshot as of T | Rounds |
|---|---|---|---|---|
| PostgreSQL 16 | `wal_level=logical`, a publication and a `pgoutput` slot per database | the slot's LSN; `source.lsn` (`cdc.seq=lsn`) | `COPY ... CSV` | 1 to 5 |
| SQL Server 2022 Developer | CDC on the database and every table, SQL Server Agent running the capture job | the log's last LSN; `source.change_lsn` as one number (`cdc.seq=change_lsn`) | `export.py` | 1 to 3 (`ROUNDS=3`) |
| Oracle AI Database 26ai Free (23.26) | ARCHIVELOG, supplemental logging (all columns), LogMiner with the online catalog | the database's SCN; `source.scn` (`cdc.seq=scn`) | `export.py` | 1 to 3 (`ROUNDS=3`) |
| Db2 11.5 Community | archive logging; ASN capture with Debezium's management scripts (debezium-examples, pinned): `ADDTABLE` per table, the capture agent started and reinitialized | the capture's synch point; `source.change_lsn`'s low 8 bytes (`cdc.seq=db2_lsn`) | `export.py` | 1 to 3 (`ROUNDS=3`) |
| Informix 14.10 Developer (14.10.FC7W1DE) | `syscdcv1` (the image's script), a logged database per source; Debezium Server with the Informix JDBC driver and change-stream client added | 0: Debezium starts after the snapshot; `source.change_lsn` (`cdc.seq=ifx_lsn`) | `export.py` | 1 to 3 (`ROUNDS=3`) |
| MySQL 8.4 | binlog in row format with GTIDs (as for Mautic) | the snapshot's binlog position, taken after the producers start; `cdc.seq=binlog` | `INTO OUTFILE` | 1 to 5 |

- **T is taken while nothing writes.** PostgreSQL can't read as of an earlier LSN, and neither SQL Server nor Oracle reads as of a log position the way the snapshot needs. So the harness writes nothing between the fill and the snapshot: the snapshot is the state at T. The rows at T for the history check are kept from that moment (`snapT` files).
- **Clients.** SQL Server and Oracle use their own command-line clients in their containers (`sources/mssql-sq.sh`, `sources/oracle-sq.sh`). Db2's CLP prints space-padded columns and Informix's `dbaccess` no columns at all, so those two use lfc-source-datagen's `scripts/python/sq.py`: SQL on stdin, tab-separated rows out, through the same drivers as `fill.py`, in a container kept for the run.
- **The snapshot exporter.** lfc-source-datagen's `scripts/python/export.py` reads each table through the same driver as `fill.py` and writes CSV with a header: NULL as `\N`, a quote doubled inside quotes. It runs in a container on the run's network.
- **The history check's truth.** Each source records its own changes: audit triggers write every row change, in commit order, as JSON, to a table its change capture leaves out (`sources/mssql-cdc.sql`, `sources/oracle-cdc.sql`, `sources/audit-triggers.py` for MySQL, Db2 and Informix; YugabyteDB's and PostgreSQL's `cdc_sql`). Informix has no `JSON_OBJECT`, so its triggers build the JSON as text.
- **Names.** Oracle keeps unquoted names in upper case, and its change events carry them that way (`ORACLE1.TPCH1.ORDERS`). `model-sql.py --dialect oracle` folds every name it writes, and silver's schema for Oracle is the model in upper case.
- **Types.**
  - SQL Server's `DATETIME2` and `TIME` default to 7 digits of fraction, which Debezium sends as nanoseconds: silver reads 7 to 9 digits as nanoseconds.
  - Oracle's `DATE` holds a time and comes as epoch milliseconds: silver's schema gives it as a timestamp to the second.
- **Not yet: rounds 4 and 5 on SQL Server and Oracle.** A column added to a CDC table needs a new capture instance in SQL Server. In Oracle, the online catalog doesn't follow DDL; the redo-log catalog would.

Found while building the test (what a pipeline itself meets is in [What a production pipeline meets](#what-a-production-pipeline-meets)):
- **The workload's updates always set a new value**, since SQL Server logs no update that changes nothing (`model-sql.py`'s values are base 36 of the seed, so a 1-character column gets a different one each time).
- **`mssql-python` on Linux needs OS libraries**: `libltdl7`, `libkrb5-3` and `libgssapi-krb5-2`, none of them in `python:3.12-slim`. The harness builds an image with them once on the VM (`localhost/lfc-datagen-mssql:3.12-2`).
- **Containers that run as their own user** (SQL Server's `mssql`, Oracle's `oracle`) can't read a mounted file the run wrote at mode 0600, so the client scripts (no secrets in them) are mounted readable.
- **`AUDIT` is a reserved word in Oracle**: the audit table there is `LFC_AUDIT`, which the test's table list and capture leave out with every `LFC_` table.
- **Db2 names an unnamed result column `1`, `2`, ...**: a query's header row then reads like data; the harness names every column it parses.
- **Informix's developer image needs its volumes given to its user**: `/opt/ibm/data` and `/opt/ibm/config` mounted with `:U` (lfc-source-podman's engines.md), without `--privileged`; otherwise its start script's `sudo` fails and the server goes offline. The tested image, 14.10.FC7W1DE, is the harness's default.
- **The checks trim strings on both sides for Informix**, which ignores trailing blanks.
- **Informix's `VARCHAR` stops at 255 bytes, and a row's casts share a size limit** (error -361 on TPC-DS's `catalog_returns`): the checks cast a string column to `LVARCHAR` of its own length, and other types to `LVARCHAR(40)`.
- **Informix pads a `CASE` that mixes a literal with an `LVARCHAR` cast** to 2048 characters: the audit trigger's JSON for TPC-DS's `date_dim` (16 integers) passed the audit column's 32000 and was cut off. Each value is trimmed.
- **At a small scale a composite key can need more child rows than its parents allow.** TPC-E at SF 0.001 has 7 securities but gives each watch list 15 items, so `watch_item.wi_s_symb` pointed at securities that don't exist; TPC-DI's `FactWatches` hit the same problem. statschema's `shape.py` now caps the rows per first-key value at the second key column's values, and the table's rows at the pairs both parents allow.
- **The laptop's route to the VM drops for half an hour and more** (sleep, VPN reconnects): an answer lost then reads as an empty source and fails a check. The VM client retries for `VM_RETRY_MIN` minutes (default 120).

### Many sources and models at once: `matrix.sh`

[scripts/matrix.sh](scripts/matrix.sh) runs every combination of `SOURCES` × `MODELS` × `NSRCS` (how many source databases merge into one silver), at most `PARALLEL` at once:

```bash
PROFILE=<cli-profile> CATALOG=<catalog> VM_IP=<vm-ip> SOURCES="pg mssql oracle" MODELS="tpch tpcb tpcc" NSRCS="1 2 4" PARALLEL=2 \
  bash skills/zerobus-debezium-test/scripts/matrix.sh
```

- **Isolation:** each run gets its own copy of the skills folder, its own log, result file and port.
- **Output:** `summary.md` has one row per run: exit status, claims passed and failed, the first failure, minutes.
- **Coverage records:** each run writes the combination it tested and its outcome as an **lfc-test-results** record (`RECORD_OUT`); `records.jsonl` collects them. Look them over, then `record.py < records.jsonl`, so `recall.py --coverage` shows the combination as tested.
- **Choosing `PARALLEL`:** one run per two vCPUs of the VM (2 on the 4-vCPU test VM), when memory allows. Check first: `nproc`, `free -m` (available), `podman stats --no-stream` for other sessions' containers (they share the VM), and that the disk is idle (`iostat -dx`). Memory per run: the database (PostgreSQL about 0.5 GB, MySQL 1 GB, Db2 and Informix 1 to 2 GB, SQL Server and Oracle 2 to 4 GB: **lfc-source-podman**'s engines.md), plus about 0.4 GB per Debezium Server, one per source database (`NSRC=4` Mautic: about 5 GB in all). Leave 2 GB free. Two Oracle databases starting at once can time out a connector's start (`ORA-17002`); the harness restarts it, but mixing engines in a pair avoids it.
- **Runs on a laptop-driven VM stop when the laptop sleeps.** The harness drives the VM over SSH and waits out an outage for `VM_RETRY_MIN` minutes; start long matrices when the laptop stays awake, or from a host that does.

## Trade-offs

What silver gives up, and where, so a result can be read for what it is:

- **T while nothing writes (PostgreSQL, SQL Server, Oracle).** The snapshot is consistent only because the test stops writing between the fill and the snapshot. A source with live traffic would need the snapshot tied to the log position: PostgreSQL's exported snapshot from the slot, SQL Server's and Oracle's flashback or snapshot isolation.
- **SQL Server's sequence fits a BIGINT only while the log's file number is below 2^15.** `change_lsn` is 10 bytes; silver packs the three parts into 64 bits, which a test database never outgrows.

- **Foreign key actions applied after each update (`fk-actions.py`).** Silver re-applies what MySQL through 9.5 doesn't log, from the rules in the collected schema:
  - **Source rules only:** they have to match the source's. A rule added at the source after the schema was collected isn't applied until the schema is collected again.
  - **At the update, not at the parent's sequence:** between an update and the step after it, silver has the child rows; a reader then sees them. The history's version ends at the parent's last version's end (its delete) when the parent keeps history, else at the version's own start.
  - **DML on the pipeline's tables:** the step deletes and updates rows in tables AUTO CDC builds (Databricks allows it). A full refresh rebuilds them from bronze, orphans included, and the step after it removes them again.
  - **A consistent point:** the rule holds when silver has every source change up to some position; a parent's delete in bronze whose child's earlier insert isn't yet in silver can't happen with one ordered log per source (one producer per source database).
  - **Not handled:** `ON UPDATE CASCADE`, SET DEFAULT, and a parent's primary key change (Debezium sends it as a delete and an insert). Mautic has none of these.
  - **Turned off** for logs that carry the changes (`FK_ACTIONS=logged`).

- **Replays and identical changes.** A producer resends changes after a restart, under a new sequence. Silver drops a change as a replay when it has the same event (destination, key, operation, row image, and idempotency key where the producer gives one) within 10 minutes of one already applied (the pipeline's dedup watermark; `merge-silver.py`'s `REPLAY_NS`). So:
  - in the history (SCD type 2), a real update that sets a row to the same values within 10 minutes counts once; the history check counts consecutive identical versions once on both sides;
  - in a table without a key (append-only), two identical rows inserted within 10 minutes count as one;
  - current rows (SCD type 1) keep every change: a replay comes in order with a newer sequence and converges.
  - the history checks pass a key whose versions, with consecutive identical ones counted once, are the source's, as long as silver has no more versions than the source (a replay it failed to drop is one more);
  CockroachDB's connector on the Kafka route gives no idempotency key, so there replays are matched on the row image alone: a key deleted, reinserted and deleted again within 10 minutes has its second delete taken for a replay in the history (the reinserted version stays open). Current rows and the tombstones keep every delete. Debezium Server's key isn't unique per change either ([Round 3](#round-3-debezium-killed-and-restarted)), so it's never used on its own.
- **Sequence.** CockroachDB's connector drops the commit time, so silver orders by `ts_ns`, when Debezium processed the change. Each key's changes stay in order, and the snapshot (sequenced by T, the database's clock) compares correctly only while the two clocks agree.
- **Timestamps as numbers.** A timestamp column without a declared precision is read as microseconds (6 digits, PostgreSQL's and CockroachDB's default). A producer that sends milliseconds for such a column (Debezium's `time.precision.mode=connect`) would be read wrong.
- **Schema drift on record.** Until a table is evolved and refreshed, a value its column type can't hold is NULL, a dropped column gets its default, and a new column waits. A refresh rebuilds the table from its snapshot and every change since T, so the change log has to be kept back to T.
- **MERGE in place of AUTO CDC.**
  - Every delete is kept (`_cdc_tombstones`), as is every appended fingerprint (`_cdc_appended`): they grow with the deletes and inserts. AUTO CDC drops its tombstones after a set time.
  - Silver tables carry `_seq` (current rows) and `_idem` (history), which AUTO CDC keeps hidden.
  - A batch rewrites the end of every version of each key it touches, from that key's whole history: more work for keys with long histories.
  - There's no `_history_nodedup` table.
- **Producers sharded.** Each Debezium Server has its own changefeed (CockroachDB recommends a maximum per cluster: lfc-source-sizing's limits), the servers start one after another (start-up grows with their number), and commit order holds per key, not across servers.
- **Own bronze on the direct route.** Debezium Server's Zerobus sink writes one table, so a table's own bronze is copied from the shared log by the fan-out: one more hop, and its changes stored twice.
- **Silver across schemas (`SPLIT`).** Readers and gold name each table's schema.
- **The Kafka route.** Zerobus's Kafka API takes the record value only, so the event is wrapped (`HoistField`, `StringifyField`) and nothing is dropped from it (no `DROP_FIELDS`): larger events than the direct route's.
- **Retries.** A call that fails to connect is retried, up to 5 times with backoff: ssh to the VM when ssh itself can't connect (the input is kept, so a retry gets all of it), and the Databricks CLI when the request was never sent (DNS, refused, dial, TLS handshake) or the workspace answered that it's temporarily unavailable (a 503, which a volume upload got once: the request wasn't taken). A connection lost after a request was sent isn't retried for a create or a run-now, which may have gone through; a read (get, list) is, after a timeout or reset too, since sending it again changes nothing (a job run's poll timed out once and failed a table move).
- **Test data on CockroachDB.** For the PostgreSQL dialect the generator casts `POWER`'s arguments, and any expression plus or minus a decimal constant, to double precision (CockroachDB doesn't mix float and decimal). On plain PostgreSQL that arithmetic was NUMERIC before, so a generated value can differ in its last digits, or round to the other side of an exact `FLOOR` boundary.

## Before running

1. **A VM with Podman** from **lfc-source-cloud-vm**, reachable over SSH, with outbound 443.
2. **A Databricks CLI profile** for a workspace in a Zerobus region (see the **databricks-zerobus-ingest** skill), where you can create service principals.
3. **A catalog with its own storage**, which you can create schemas in.
4. **Phase 2:** `CRDB_PORT` (default 30026) free on the VM and open to the workspace's serverless egress. The shared NSG from **lfc-source-cloud-vm** opens 30000-30063. Only one run at a time can publish the port, so a `KEEP=1` run holds it until you remove its containers. You also need permission to create connections and pipelines.

## Run

```bash
cd skills/zerobus-debezium-test
export PROFILE=<cli-profile> CATALOG=<catalog> VM_IP=<vm-ip>   # SOURCE=yb for YugabyteDB (see below)
C=/tmp/dbz-$(date +%s).sh; cp scripts/debezium-zerobus.sh $C && OUT=/tmp/dbz-result.md bash $C
```

Run a copy with its own name, as above, so that editing the script, or starting another run, can't change a run in progress (bash reads a script as it runs). It exits 0 when every claim passed, 1 when one failed and 2 when a prerequisite is missing. The images are pinned by default: `CRDB_IMAGE` (CockroachDB v25.4.13) and `DBZ_IMAGE` (Debezium Server 3.7.0.Final).

## Traceability: the schema and the pipeline files, next to the snapshot

A run's volume holds everything silver was built from, so a table can be traced back to its inputs. The snapshot as of T is there. The canonical schema is in `_schema/`: statschema's `schema.yaml`, from the UC connection ([scripts/schema-tsv-to-canonical.py](scripts/schema-tsv-to-canonical.py)) or from the source's DDL (**lfc-source-statschema** `ddl-to-schema.py`), and checked with that skill's `validate.py`. The pipeline files generated from that schema are in `_pipeline/<step>/`. Steps: `1-at-T`, `2-round-4` (a column added), `3-round-5` (a column dropped, another retyped). Each is a claim (`trace-<step>`).

## Links to inspect

Every Databricks object a run creates gets a clickable link, printed as `LINK <what>: <url>` when it's created: the schema, the change log, the service principal, the snapshot volume, the UC connection, the pipeline and its source folder, and the silver and gold tables. The result file lists them under "Created in Databricks". The run removes them when it ends, so to inspect them, run with `KEEP=1`; the links are printed again at the end, and `sweep.sh` removes the run later. On a VM, `run-all.sh` also writes **lfc-source-cloud-vm**'s `cloud-links.sh` links (the VM, its network rules, its disks) into `summary.md`.

## The repeatable test

[scripts/run-all.sh](scripts/run-all.sh) runs the committed skills unchanged and records which commit passed. Use it after any change, and before relying on these skills:

```bash
PROFILE=<cli-profile> CATALOG=<catalog> VM_IP=<vm-ip> bash skills/zerobus-debezium-test/scripts/run-all.sh   # from the repo root
```

On the laptop, with no cloud VM or storage: `PROFILE=... CATALOG=... LIMA=<instance> SP_CLIENT_ID=<application id> SP_SECRET_FILE=<file> bash skills/zerobus-debezium-test/scripts/run-all.sh` (CockroachDB only so far).

1. **Pre-flight.** It refuses to run with uncommitted changes in `zerobus-debezium-test`, `zerobus-workspace-setup`, `lfc-source-statschema`, `lfc-source-datagen` or `lfc-source-podman`: commit them, or run from a clean checkout (`git worktree add <dir> HEAD`). `ALLOW_DIRTY=1` runs anyway and marks it in the summary. It also checks SSH to the VM first. When the laptop's public IP changes, the VM's firewall drops SSH, every source query comes back empty, and every claim fails. It runs **lfc-source-podman**'s `ensure-podman-socket.sh` on the VM (on the laptop, `ensure-lima-podman.sh`, which runs it inside Lima). So every container runs rootful through the root Podman socket (`$PODMAN`, default `podman --remote --url unix:///run/podman/podman.sock`), in the same store as the database sources, and with no `sudo` anywhere in the test. Files that containers write are removed from a container. `PODMAN=podman` runs rootless, on a host with no rootful store. `SWEEP=1` first removes what earlier runs left behind ([`sweep.sh`](scripts/sweep.sh) below).
2. **The workspace.** **zerobus-workspace-setup** `check.sh`: the Zerobus previews, and TCP 443 and 9092 from the VM to the endpoint.
3. **Every source**, `SOURCES="crdb yb"` by default, in parallel on their own ports (CockroachDB 30026, YugabyteDB 30031). Each run cleans up after itself.
4. **The results**, in `~/.lfc-test/results/zerobus-<UTC time>/`: `check.txt`, `<source>.md` (the result table, with images and digests), `<source>.log`, and `summary.md` (the commit, claims passed and failed per source). The exit code is 0 only when everything passed. When everything passed, it also writes one row per source into the "Successful runs" table of [docs/lakeflow-connect-zerobus.md](../../docs/lakeflow-connect-zerobus.md), newest first (`RECORD=0` to skip): commit that change with the run.

**Leftovers.** A run removes what it created when it exits, but a killed run, or one kept with `KEEP=1`, leaves its containers, pipeline, connection, service principal, folder and schema. Every name carries the run's epoch, and [`scripts/sweep.sh`](scripts/sweep.sh) finds them by name, on the VM (`VM_IP`) or the laptop (`LIMA`) and in the workspace. It prints its plan and removes nothing without `--apply`. It leaves runs younger than `MIN_AGE` seconds (default 7200, as one may still be running) and the epochs in `KEEP_RUNS`; `ONLY_RUNS="<epoch> ..."` sweeps just those runs, whatever their age. It covers every source the harness runs.

## Without cloud storage or service principal permissions: the laptop

Many users can't create object storage (an S3 bucket, an Azure storage account), can't get the Databricks permissions that reach it (a storage credential, an external location), or can't create service principals. They can still run the whole test:

| Piece | On a cloud VM (above) | On the laptop |
|---|---|---|
| Source and Debezium | Podman on a VM over SSH (`VM_IP`) | Podman in a local Lima VM (`LIMA=<instance>`). Images and the Zerobus native library exist for arm64 |
| Change log | Zerobus | Zerobus, the same. Zerobus authenticates only with a service principal's OAuth secret, and Debezium's sink takes only `client.id` and `client.secret`. So someone who can create one makes it once and hands over its application ID and secret: `SP_CLIENT_ID` and `SP_SECRET_FILE` (a 0600 file). The script then creates no service principal; as the owner of `cdc_log`, you grant it `SELECT` and `MODIFY` |
| Snapshot | `databricks fs cp` into a Volume | The same: dumped on the laptop, then `databricks fs cp` into a **managed** Volume. A managed Volume uses the catalog's own storage, so it needs no storage credential or external location: only `CREATE SCHEMA` (or a schema you own) in a catalog you can use |
| Schema | `remote_query` through a UC connection (serverless must reach the database) | **Through the Volume too** (`SCHEMA_VIA=volume`, the default with `LIMA`). The source's DDL becomes statschema's canonical `schema.yaml` with the **lfc-source-statschema** skill's `ddl-to-schema.py`, and goes to `<volume>/_schema/schema.yaml`, with a copy as at T, `schema-at-T.yaml` |
| Silver | The same: [scripts/silver-from-schema.py](scripts/silver-from-schema.py) | The same |

```bash
cd skills/zerobus-debezium-test
export PROFILE=<cli-profile> CATALOG=<a catalog you can create a schema in> LIMA=<lima instance with podman>
export SP_CLIENT_ID=<application id> SP_SECRET_FILE=<file with its OAuth secret>
C=/tmp/dbz-$(date +%s).sh; cp scripts/debezium-zerobus.sh $C && OUT=/tmp/dbz-result.md bash $C
```

Passed all 30 claims on 2026-10-20, run 1792541354 (Lima `forgedb-lima-rosetta2-podman`, Ubuntu 25.10 arm64, Podman 5.4.2), the same claims as on the VM (run 1792541366 after the `SOURCE` change, also 30). The schema changes in rounds 4 and 5 went through a new `schema.yaml` in the Volume and a full refresh.

`ddl-to-schema.py` runs with `uv`. sqlglot's postgres dialect rejects two things in CockroachDB's `SHOW CREATE ALL TABLES`: `PRIMARY KEY (id ASC)` and typed literals such as `DEFAULT 'none':::STRING`. So the script removes `ASC`, `DESC` and `:::<type>` first. When the dump fails, the round fails (`schema-refetch`), rather than checking against the old schema. `SCHEMA_VIA=volume` dumps DDL for `SOURCE=crdb` only, so far.

## Silver (phase 2)

The full run (rounds 1 to 5, SCD types 1 and 2, gold) passed all 30 claims on 2026-10-20, run 1792534627.

**One generator, for every source and model.** [scripts/silver-from-schema.py](scripts/silver-from-schema.py) is the whole silver pipeline, on both routes. It reads the canonical `schema.yaml` (statschema's format) from the volume's `_schema/` when the pipeline starts, and defines every view, table and flow in a loop. Nothing in it names a table, a column or a type. On the VM route, the schema read through the UC connection becomes that `schema.yaml` ([scripts/schema-tsv-to-canonical.py](scripts/schema-tsv-to-canonical.py)); on the laptop route, the source's DDL does (**lfc-source-statschema** `ddl-to-schema.py`). The tables come from the source as well (every base table in its schema), so the same script runs a TPC model from **lfc-source-statschema** unchanged. What stays per model is the source's setup, the workload and its checks (rounds 1 to 5), and gold, which is written for one reader's question. A schema change is: a new `schema.yaml` in the volume, then a full refresh of the changed tables. No code is regenerated.

For each source table, it defines two temporary views and two AUTO CDC flows into one streaming table, SCD type 1, `CLUSTER BY` the key:

| Flow | Reads | Columns | Sequence |
|---|---|---|---|
| `<table>_from_snapshot` | `STREAM read_files('<volume>/<table>', format => 'parquet')` | `CAST(<column> AS <type>)` | T, the snapshot time, in nanoseconds |
| `<table>_from_changes` | `STREAM(cdc_log) WHERE destination = 'crdb.public.<table>'` | keys from `key:<column>`, the rest from `value:after:<column>`, with the type; `APPLY AS DELETE WHEN operation = 'delete'` | `value:ts_ns` |

**Both SCD types from one change log.** Each table also gets `<table>_history`, `STORED AS SCD TYPE 2`, fed by the same snapshot view and by `<table>_changes_dedup`. That view reads `cdc_log_dedup`, a temporary view in the same file that drops replays: `dropDuplicatesWithinWatermark` on `destination`, `idempotency_key`, `operation` and the row image (`TO_JSON(value:after)`), with a 10-minute watermark on `ts_ns`. The key alone can't be used, since two different updates can share it ([Round 3](#round-3-debezium-killed-and-restarted)). SCD type 1 reads the change log as it is, because replays don't change its result. `customers_history_nodedup` is SCD type 2 without the deduplication, to show what a restart does.

[scripts/scd2-history-check.py](scripts/scd2-history-check.py) checks every version. The truth is CockroachDB's own changefeed from T (`EXPERIMENTAL CHANGEFEED FOR ... WITH updated, cursor = T`), which has each row's commit time. Each key's expected versions are its row at T, then its row after every insert or update, in commit order. The check compares those with the history table ordered by `__START_AT`. It runs from the skill folder, or set `CHECK=<path>`.

The types and the key come from CockroachDB's `information_schema` through `remote_query` on a POSTGRESQL UC connection: `bigint`, `numeric(p,s)`, `text` map to `BIGINT`, `DECIMAL(p,s)`, `STRING`. An insecure node takes any password. The keys come from `key`, not `after`, because a delete's `after` is null.

The check compares every row of every table, source and silver, ordered by the key. It runs after the phase 1 changes, then again after a second round with two updates of one key, a delete and reinsert of one key, a reinsert of a key deleted in round 1, and a decimal update. Passed on 2026-10-20 (run 1792530422): `customers` 6 then 7 rows, `orders` 5 then 5, all equal.

**CockroachDB `EXPORT INTO PARQUET` corrupts DECIMAL (v25.4.13).** It writes a DECIMAL column as `BYTE_ARRAY` annotated `DECIMAL(10,2)`, but fills it with the number's text. Readers decode the text as the unscaled integer: `21.00` (`0x32312E3030`) reads as `2155734753.76`, in Databricks and in DuckDB alike. Silver was wrong only for the snapshot rows; the change log's decimals were right. The script exports DECIMAL columns as `STRING` (`<column>::STRING`, from `information_schema`), and silver casts them back.

## Gold (phase 3)

`customer_orders` is a materialized view over silver: each customer with the count and total of their orders, `CLUSTER BY (tier)`. The check runs the same query on CockroachDB and compares every row. Results on 2026-10-20 (run 1792531795):

- **Gold equals the source** after every round (6, 7, 8 and 8 rows).
- **The view refreshes incrementally.** The first update is `COMPLETE_RECOMPUTE` (`FIRST_COMPUTATION`), and the second is `GROUP_AGGREGATE`, `INCREMENTALIZATION_STATUS_INCREMENTAL`. That works because AUTO CDC's backing tables have row tracking and change data feed on. Read it from `event_log('<pipeline id>')`, `event_type = 'planning_information'`: `list-pipeline-events` returns those events without `details`.
- **Clustering** is as declared: bronze on `destination`, silver on `id`, gold on `tier`. `DESCRIBE DETAIL` fails on a materialized view; `DESCRIBE TABLE EXTENDED` shows `clusteringColumns` for all three.

## Round 3: Debezium killed and restarted

After 4 changes reach bronze, Debezium gets SIGKILL (no offset flush) and is started again. Then one more change.

- **The stream resumes**, and silver and gold equal the source.
- **The restart replays events.** 5 changes gave 9 bronze rows: after the restart, Debezium re-sent the 4 changes made since its last offset (the resolved timestamp), with new `ts_ns`. Zerobus doesn't deduplicate by `idempotency_key`; the replays landed as new rows. SCD type 1 silver is still right, because the replay comes in commit order and AUTO CDC keeps the latest `ts_ns`.
- **SCD type 2 needs the replays removed.** Without deduplication, `customers_history_nodedup` recorded the replay as history that never happened: customer 4 went bronze, silver, gold, then silver and gold again, 17 versions where the source had 15. With `cdc_log_dedup`, `customers_history` matched the changefeed version for version (15 of 15), as did `orders_history` (11 of 11), and the current versions (`__END_AT IS NULL`) equal the source.
- **`idempotency_key` isn't unique per change.** Two different updates of one row, made in quick succession, get the same key: customer 1 `platinum` then `diamond`, and customer 4 `silver` then `gold`, each pair one key. The key seems to come from the table, the operation and the connector's offset time, which is the missing commit time again ([Commit time](#commit-time-not-in-the-event-cockroachdb-connector-370final)). **Don't deduplicate by `idempotency_key`:** it would drop real changes, and could keep `platinum` instead of `diamond`. To remove replays, deduplicate on `destination`, `key`, `value:after` and `operation` within a short window, or let AUTO CDC absorb them, as here.

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

## The Debezium settings that matter

- `debezium.sink.type=zerobus`, with `endpoint`, `workspace.url`, `client.id` and `client.secret` (the service principal) under `debezium.sink.zerobus.`.
- `payload.mode=envelope` with `debezium.sink.zerobus.table=<catalog>.<schema>.cdc_log`: every source table's events go to one table, so a new source table or column needs no DDL in Databricks.
- `json.flexible.fields.encoding=string` into `VARIANT` columns: the sink sends `key`, `value`, `source_position` and `headers` as JSON text, and Zerobus parses it into `VARIANT`. `object` (nested JSON) is rejected by Zerobus: "Record decoder/encoder error: invalid type: map, expected a string" (`NonRetriableException`). Read the fields with paths, for example `value:after:tier::STRING`; the record's `key` holds the primary key columns. The source table is in `destination` (`crdb.<schema>.<table>`); `target_table` is always the log itself.
- No tombstones: `tombstones.on.delete=false` and `tombstone.handling.mode=drop`. A delete is one `delete` event.
- Only Kafka's own transforms: the Debezium Server 3.7.0.Final image ships `connect-transforms` 4.3.1 but not `io.debezium.transforms.ExtractNewRecordState` (`ClassNotFoundException`), which typed mode needs. `ReplaceField` (what `DROP_FIELDS` uses) removes top-level fields only. Of the Kafka transforms, only `ExtractField` takes nested paths, so `source` can be dropped whole but not trimmed field by field.
- `snapshot.mode=no_data` with `cockroachdb.changefeed.cursor=<T>`: the feed starts at the snapshot time and Debezium takes no snapshot.
- `idempotency.mode=source` gives each row an `idempotency_key`, but Zerobus doesn't deduplicate by it, and with this connector it isn't unique per change ([Round 3](#round-3-debezium-killed-and-restarted)).
- CockroachDB: `kv.rangefeed.enabled = true`; the connector uses a sinkless changefeed (`changefeed.sink.type=sinkless`), so no Kafka or cloud storage sits in between.

## Event size: what each setting saved

Measured on 2026-10-20 (CockroachDB v25.4.13, Debezium Server 3.7.0.Final, `json.flexible.fields.encoding=string`). The table shows average bytes per event in the change log; `value` is the event body, and `total` adds the key, the position and the headers.

| Run | Top-level keys in `value` | create: total / value | update: total / value | delete: total / value |
|---|---|---|---|---|
| Envelope, `extended.headers.enabled=false`, `include.diff=false`, tombstones off | after, before, op, source, transaction, ts_ms, ts_ns, ts_us | 700 / 459 | 748 / 507 | 695 / 454 |
| Same, plus `DROP_FIELDS=before,transaction,ts_ms,ts_us` | after, op, source, ts_ns | 620 / 379 | 625 / 384 | 576 / 335 |
| **Saved by `DROP_FIELDS`** | | **80 (11%)** | **123 (16%)** | **119 (17%)** |
| Same, plus `source`: `DROP_FIELDS=before,transaction,ts_ms,ts_us,source` | after, op, ts_ns | 336 / 95 | 342 / 101 | 292 / 51 |
| **Saved by dropping `source`** | | **284 (46%)** | **283 (45%)** | **284 (49%)** |
| **Saved in all, from the first row** | | **364 (52%)** | **406 (54%)** | **403 (58%)** |

How the create event splits up before `source` is dropped: `source` 274 B, position 160 B, `after` 48 B, key 8 B, headers 2 B. The first runs, before extended headers and the before-image were off, measured about 1.2 KB per event.

Dropping `source` loses nothing silver can use. The source table is in `destination`, and `source`'s times aren't the commit time (see [Commit time](#commit-time-not-in-the-event-cockroachdb-connector-370final)). All claims passed with it dropped. Keep the top-level `ts_ns`: silver sequences by it. Most of what's left is the position (160 B), which the sink writes and `DROP_FIELDS` can't reach.

## Commit time: not in the event (CockroachDB connector 3.7.0.Final)

CockroachDB's changefeed sends each row's commit time (`updated`, or `source.ts_hlc` with `enriched_properties = 'source'`, a nanosecond HLC). The connector drops it. In the event, `source.ts_hlc` is null, and `source.ts_ns` / `ts_ms` and the position's `offset.cursor` hold the connector's offset time, which advances only on resolved timestamps. Measured on 2026-10-20: 8 changes committed within 4 ms of each other, at `...511.329226021` s, all carried `source.ts_ns = ...481000000000`, a whole second 30 s earlier. Setting `cockroachdb.changefeed.enriched.properties=source` (`ENRICHED_PROPERTIES=source`) changed nothing: the same null `ts_hlc`, the same bytes. In the bytecode, the connector reads only `schema_name` and `table_name` from the changefeed's source block, and nothing calls `SourceInfo.setHlc`.

So silver can't sequence by the commit time. What's left is the top-level `ts_ns`: when Debezium processed the event, in nanoseconds, distinct for all 8 changes. It still orders each key's changes. A changefeed emits each key's changes in commit order, and one Debezium Server processes them one at a time. After a restart, Debezium re-sends the changes after its offset, in order, with later `ts_ns`. It's Debezium's clock, though, not the database's. The snapshot is sequenced by T, from the database's clock, so the two only compare correctly when the clocks agree, as they do on one VM.

## YugabyteDB (`SOURCE=yb`): Kafka Connect into the Zerobus Kafka endpoint

`SOURCE=yb` runs the same test on YugabyteDB 2026.1.2.0 (`yugabytedb/yugabyte:2026.1.2.0-b137`), tables in a schema named `shop`. All 30 claims passed on 2026-10-21 (run 1792582605, commit `96c5547`, from `run-all.sh`).

**What works:**

| Step | How |
|---|---|
| T | Create the publication and the logical replication slot first (`pg_create_logical_replication_slot('dbz_slot', 'pgoutput')`). The slot's consistent snapshot is `pg_replication_slots.yb_restart_commit_ht`, a hybrid time: shift it right by 12 bits for microseconds (it matches `yb_restart_time`). Logical replication is on by default in 2026.1 (`wal_level=logical`, `yb_enable_replication_commands=on`) |
| Snapshot as of T | `SET yb_read_time TO <microseconds>`, then `COPY (SELECT * FROM shop.<table>) TO STDOUT WITH (FORMAT csv, HEADER)`. A row updated after the slot was created still reads as it was at T. Silver reads the CSV with `read_files(..., format => 'csv', header => true)` |
| Schema | `remote_query` on a POSTGRESQL UC connection (port 5433, user `yugabyte`) |
| History truth | An audit trigger writes every change to `shop.audit`, which isn't in the publication |

**Debezium Server 3.7 can't read the slot** (tested 2026-10-20):

| Connector in Debezium Server 3.7.0.Final | Result |
|---|---|
| Debezium's PostgreSQL connector | Fails and retries forever: "ERROR: pg_current_wal_lsn() is not yet supported", [yugabyte-db#30243](https://github.com/yugabyte/yugabyte-db/issues/30243) |
| Yugabyte's connector `dz.2.5.2.yb.2026.1.2.0.1`, in place of the PostgreSQL connector jar | Doesn't start: `ClassNotFoundException: io.debezium.connector.postgresql.PostgresConnector` (Quarkus expects it) |
| The same jar next to the PostgreSQL connector jar | Starts and connects to Zerobus, but the engine never runs (health `DOWN`): the jar bundles Debezium core 2.5.2 |

**So `SINK=kafka`** (the default for `SOURCE=yb`): Kafka Connect, without a broker, runs Yugabyte's connector, which is built for Kafka Connect. Its producer writes straight to Zerobus's Kafka-compatible endpoint.

| Piece | How |
|---|---|
| Kafka Connect | `apache/kafka:3.7.2`, `connect-standalone.sh`: offsets in a file, so no broker. The worker's admin client only describes the cluster, which Zerobus answers; `topic.creation.enable=false` |
| Producer settings | `bootstrap.servers=<workspace-id>.zerobus.<region>.<domain>:9092`, `SASL_SSL`, `OAUTHBEARER`, `acks=all`, `compression.type=none`, `enable.idempotence=false`; the same for `admin.` and `producer.` |
| Token | `sasl.login.callback.handler.class=io.debezium.server.databricks.zerobus.ZerobusOAuthBearerLoginCallbackHandler`, from Debezium's Zerobus sink jar on the worker's `CLASSPATH`. JAAS options `clientId`, `clientSecret`, `workspaceUrl`, `workspaceId`, `tables`: it mints and refreshes the table-scoped token |
| Workspace | The `zerobus_kafka_endpoint` preview on (**zerobus-workspace-setup** `enable.sh kafka --apply`); without it, SASL fails with error 4062 |
| Record shape | The Kafka API ingests only the record value. `HoistField` wraps the event as `value`, `InsertField` adds the topic as `destination`, [`StringifyField`](scripts/kafka-connect/StringifyField.java) (in this skill, built with `javac` on the VM) makes `value` JSON text, and `RegexRouter` sends every topic to `<catalog>.<schema>.cdc_log`. A nested object for a `VARIANT` column is refused: "invalid type: map, expected a string" (error 4044) |
| Source | The tables get `REPLICA IDENTITY DEFAULT` before the slot is created. `pgoutput` refuses YugabyteDB's default `CHANGE` ("replica identity CHANGE ... is not supported for output plugin pgoutput"), and a slot keeps the identity it was created with. `decimal.handling.mode=string`, `snapshot.mode=never` |

**What's different from the Debezium Server route:**
- **Bronze has two columns**, `destination` and `value` (`VARIANT`). The pipeline reads it through `cdc_log_norm`, which gives both routes the same shape:
  - the operation comes from `value:op`;
  - a delete's key comes from `before`, because its `after` is a JSON null, which `COALESCE` keeps;
  - the sequence is `source.lsn`. It follows commit order, and the snapshot is sequence 0. That's better than CockroachDB, whose connector drops the commit time.
- **No replays after a restart:** 5 changes, 5 rows. Kafka Connect resumed from the slot's confirmed position. SCD type 2 without deduplication matched the history exactly (15 of 15).
- **An added column isn't resent** (PostgreSQL protocol). Rows from the snapshot, and changes made before the `ALTER`, have no field. Silver uses the column's default, read through the connection, when the field is missing, but keeps an explicit JSON null as NULL.
- **Event size:** about 690 B per event, with `before`, `source` and `transaction` still in. Kafka Connect has no `DROP_FIELDS` here yet.

## CockroachDB licensing

`start-single-node` is enough; `cockroach demo` isn't needed. Tested on v25.4.13 with no license key (2026-10-20): a sinkless changefeed (what the connector uses), a changefeed into `nodelocal://self` with `initial_scan = 'only'`, and `EXPORT INTO PARQUET ... AS OF SYSTEM TIME` all work. Current CockroachDB has no Core edition. A cluster without a license key has a 7-day grace period, after which it's throttled to 5 concurrent open transactions, and Free and Trial licenses need telemetry. For anything that runs longer than a week, set a free Enterprise Trial key with `SET CLUSTER SETTING enterprise.license = '<key>'`.

## After running

Add the result table and the environment lines (images with digests, the CockroachDB version, the host) to the run record. Compare the per-op counts with the workload: the claims `changes-1` to `changes-3` list what each round's manifest expected, per table.
