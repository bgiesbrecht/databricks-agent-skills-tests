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

**Leftovers.** A run removes what it created when it exits, but a killed run, or one kept with `KEEP=1`, leaves its containers, pipeline, connection, service principal, folder and schema. Every name carries the run's epoch, and [`scripts/sweep.sh`](scripts/sweep.sh) finds them by name, on the VM (`VM_IP`) or the laptop (`LIMA`) and in the workspace. It prints its plan and removes nothing without `--apply`. It leaves runs younger than `MIN_AGE` seconds (default 7200, as one may still be running) and the epochs in `KEEP_RUNS`.

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
