---
name: zerobus-debezium-test
description: "Test database change data capture through Debezium Server's Zerobus sink: CockroachDB in Podman on a cloud VM, a snapshot as of T into a Volume, Debezium Server 3.7 streaming the changes from T through Zerobus into one append-only bronze change log, and silver AUTO CDC tables built from the source schema read through a UC connection. Checks that silver equals the source after inserts, updates and deletes, records the versions, and cleans up. Phases 1 and 2 of the Debezium -> Zerobus -> bronze -> silver -> gold test."
parent: lfc-source-cloud-vm
---

# Debezium -> Zerobus -> bronze -> silver

[scripts/crdb-debezium-zerobus.sh](scripts/crdb-debezium-zerobus.sh) runs the whole test from your laptop. It drives a cloud VM over SSH, and the VM runs the source database and Debezium Server in Podman. Debezium pushes each change to Zerobus, which appends it to one change-log Delta table for all source tables. Debezium needs only outbound 443 to the Zerobus endpoint. Phase 2 adds a snapshot as of T, taken with `EXPORT INTO PARQUET` and copied into a Volume, and a silver pipeline. The pipeline is generated from the source's schema, read through a UC connection, so serverless reaches CockroachDB on `CRDB_PORT`. `PHASE=1` stops after bronze.

This isn't Lakeflow Connect. It's for sources Lakeflow Connect doesn't cover, or for teams that want the change log itself as an append-only bronze table. Gold is the next phase.

## What it creates, and removes at the end

| Where | What |
|---|---|
| Workspace | Schema `<prefix>_crdb_dbz_<epoch>` in `CATALOG`, with the bronze table `cdc_log`: `target_table`, `operation` (`create`, `update`, `delete`), `idempotency_key`, and `key`, `value` (the Debezium event: `after`, `op`, `ts_ns` with the default `DROP_FIELDS`), `source_position` and `headers` as `VARIANT`. `CLUSTER BY (destination)`, the source table's topic (`target_table` is always the log itself) |
| Workspace (phase 2) | In the same schema: Volume `snapshot`, one folder of Parquet per source table; silver streaming tables `customers` and `orders`, made by the serverless pipeline `<prefix>-crdb-dbz-silver-<epoch>` from `/Users/<you>/crdb_dbz_<epoch>/silver.sql`; UC connection `<prefix>-crdb-dbz-<epoch>` (POSTGRESQL, to the VM's `CRDB_PORT`) |
| Workspace | Service principal `<prefix>-zerobus-dbz-<epoch>` with an OAuth secret, granted `USE CATALOG`, `USE SCHEMA`, `SELECT` and `MODIFY` on `cdc_log`. Zerobus writes as it |
| VM | Podman network `crdb-dbz-<epoch>`, containers `<prefix>-crdb-<epoch>` (CockroachDB, single node, insecure, published on `CRDB_PORT`, default 30026) and `<prefix>-debezium-<epoch>` |

The OAuth secret is never printed. It goes from the CLI's response into Debezium's `application.properties` in 0600 temp files, on the laptop and on the VM, which are deleted when the run ends. `KEEP=1` keeps everything for a look afterwards.

## Before running

1. **A VM with Podman** from **lfc-source-cloud-vm**, reachable over SSH, with outbound 443.
2. **A Databricks CLI profile** for a workspace in a Zerobus region (see the **databricks-zerobus-ingest** skill), where you can create service principals.
3. **A catalog with its own storage**, which you can create schemas in.
4. **Phase 2:** `CRDB_PORT` (default 30026) free on the VM and open to the workspace's serverless egress. The shared NSG from **lfc-source-cloud-vm** opens 30000-30063. Only one run at a time can publish the port, so a `KEEP=1` run holds it until you remove its containers. You also need permission to create connections and pipelines.

## Run

```bash
cd skills/zerobus-debezium-test
export PROFILE=<cli-profile> CATALOG=<catalog> VM_IP=<vm-ip>
C=/tmp/crdb-dbz-$(date +%s).sh; cp scripts/crdb-debezium-zerobus.sh $C && OUT=/tmp/crdb-dbz-result.md bash $C
```

Run a copy with its own name, as above, so that editing the script, or starting another run, can't change a run in progress (bash reads a script as it runs). It exits 0 when every claim passed, 1 when one failed and 2 when a prerequisite is missing. The images are pinned by default: `CRDB_IMAGE` (CockroachDB v25.4.13) and `DBZ_IMAGE` (Debezium Server 3.7.0.Final).

## Silver (phase 2)

For each source table, the generated `silver.sql` has two temporary views and two AUTO CDC flows into one streaming table, SCD type 1, `CLUSTER BY` the key:

| Flow | Reads | Columns | Sequence |
|---|---|---|---|
| `<table>_from_snapshot` | `STREAM read_files('<volume>/<table>', format => 'parquet')` | `CAST(<column> AS <type>)` | T, the snapshot time, in nanoseconds |
| `<table>_from_changes` | `STREAM(cdc_log) WHERE destination = 'crdb.public.<table>'` | keys from `key:<column>`, the rest from `value:after:<column>`, with the type; `APPLY AS DELETE WHEN operation = 'delete'` | `value:ts_ns` |

The types and the key come from CockroachDB's `information_schema` through `remote_query` on a POSTGRESQL UC connection: `bigint`, `numeric(p,s)`, `text` map to `BIGINT`, `DECIMAL(p,s)`, `STRING`. An insecure node takes any password. The keys come from `key`, not `after`, because a delete's `after` is null.

The check compares every row of every table, source and silver, ordered by the key. It runs after the phase 1 changes, then again after a second round with two updates of one key, a delete and reinsert of one key, a reinsert of a key deleted in round 1, and a decimal update. Passed on 2026-10-20 (run 1792530422): `customers` 6 then 7 rows, `orders` 5 then 5, all equal.

**CockroachDB `EXPORT INTO PARQUET` corrupts DECIMAL (v25.4.13).** It writes a DECIMAL column as `BYTE_ARRAY` annotated `DECIMAL(10,2)`, but fills it with the number's text. Readers decode the text as the unscaled integer: `21.00` (`0x32312E3030`) reads as `2155734753.76`, in Databricks and in DuckDB alike. Silver was wrong only for the snapshot rows; the change log's decimals were right. The script exports DECIMAL columns as `STRING` (`<column>::STRING`, from `information_schema`), and silver casts them back.

## The Debezium settings that matter

- `debezium.sink.type=zerobus`, with `endpoint`, `workspace.url`, `client.id` and `client.secret` (the service principal) under `debezium.sink.zerobus.`.
- `payload.mode=envelope` with `debezium.sink.zerobus.table=<catalog>.<schema>.cdc_log`: every source table's events go to one table, so a new source table or column needs no DDL in Databricks.
- `json.flexible.fields.encoding=string` into `VARIANT` columns: the sink sends `key`, `value`, `source_position` and `headers` as JSON text, and Zerobus parses it into `VARIANT`. `object` (nested JSON) is rejected by Zerobus: "Record decoder/encoder error: invalid type: map, expected a string" (`NonRetriableException`). Read the fields with paths, for example `value:after:tier::STRING`; the record's `key` holds the primary key columns. The source table is in `destination` (`crdb.<schema>.<table>`); `target_table` is always the log itself.
- No tombstones: `tombstones.on.delete=false` and `tombstone.handling.mode=drop`. A delete is one `delete` event.
- Only Kafka's own transforms: the Debezium Server 3.7.0.Final image ships `connect-transforms` 4.3.1 but not `io.debezium.transforms.ExtractNewRecordState` (`ClassNotFoundException`), which typed mode needs. `ReplaceField` (what `DROP_FIELDS` uses) removes top-level fields only. Of the Kafka transforms, only `ExtractField` takes nested paths, so `source` can be dropped whole but not trimmed field by field.
- `snapshot.mode=no_data` with `cockroachdb.changefeed.cursor=<T>`: the feed starts at the snapshot time and Debezium takes no snapshot.
- `idempotency.mode=source`: retries after a failure don't duplicate rows.
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

## CockroachDB licensing

`start-single-node` is enough; `cockroach demo` isn't needed. Tested on v25.4.13 with no license key (2026-10-20): a sinkless changefeed (what the connector uses), a changefeed into `nodelocal://self` with `initial_scan = 'only'`, and `EXPORT INTO PARQUET ... AS OF SYSTEM TIME` all work. Current CockroachDB has no Core edition. A cluster without a license key has a 7-day grace period, after which it's throttled to 5 concurrent open transactions, and Free and Trial licenses need telemetry. For anything that runs longer than a week, set a free Enterprise Trial key with `SET CLUSTER SETTING enterprise.license = '<key>'`.

## After running

Add the result table and the environment lines (images with digests, the CockroachDB version, the host) to the run record. Compare the per-op counts with the workload: 5 snapshot rows per table, then `customers` 2 inserts, 1 update, 1 delete, and `orders` 1 insert, 2 updates, 1 delete.
