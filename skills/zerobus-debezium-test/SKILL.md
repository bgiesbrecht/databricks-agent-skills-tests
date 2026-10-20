---
name: zerobus-debezium-test
description: "Test database change data capture through Debezium Server's Zerobus sink into append-only bronze tables: CockroachDB in Podman on a cloud VM, Debezium Server 3.7 with the CockroachDB connector, Zerobus into Unity Catalog. Checks that the initial snapshot and inserts, updates and deletes land, records the versions, and cleans up. Phase 1 of the Debezium -> Zerobus -> bronze -> silver -> gold test."
parent: lfc-source-cloud-vm
---

# Debezium -> Zerobus -> bronze

[scripts/crdb-debezium-zerobus.sh](scripts/crdb-debezium-zerobus.sh) runs the whole test from your laptop. It drives a cloud VM over SSH, and the VM runs the source database and Debezium Server in Podman. Debezium pushes each change to Zerobus, which appends it to one change-log Delta table for all source tables. Nothing listens for inbound connections: the VM only needs outbound 443 to the Zerobus endpoint.

This isn't Lakeflow Connect. It's for sources Lakeflow Connect doesn't cover, or for teams that want the change log itself as an append-only bronze table. Silver (AUTO CDC over the snapshot and the change log) and gold are the next phases.

## What it creates, and removes at the end

| Where | What |
|---|---|
| Workspace | Schema `<prefix>_crdb_dbz_<epoch>` in `CATALOG`, with one table, `cdc_log`: `target_table`, `operation` (`read` for the snapshot, `create`, `update`, `delete`), `idempotency_key`, and `key`, `value` (the Debezium event: `before`, `after`, `op`, `source`), `source_position` and `headers` as `VARIANT`. `CLUSTER BY (destination)`, the source table's topic (`target_table` is always the log itself) |
| Workspace | Service principal `<prefix>-zerobus-dbz-<epoch>` with an OAuth secret, granted `USE CATALOG`, `USE SCHEMA`, `SELECT` and `MODIFY` on `cdc_log`. Zerobus writes as it |
| VM | Podman network `crdb-dbz-<epoch>`, containers `<prefix>-crdb-<epoch>` (CockroachDB, single node, insecure) and `<prefix>-debezium-<epoch>` |

The OAuth secret is never printed. It goes from the CLI's response into Debezium's `application.properties` in 0600 temp files, on the laptop and on the VM, which are deleted when the run ends. `KEEP=1` keeps everything for a look afterwards.

## Before running

1. **A VM with Podman** from **lfc-source-cloud-vm**, reachable over SSH, with outbound 443.
2. **A Databricks CLI profile** for a workspace in a Zerobus region (see the **databricks-zerobus-ingest** skill), where you can create service principals.
3. **A catalog with its own storage**, which you can create schemas in.

## Run

```bash
cd skills/zerobus-debezium-test
export PROFILE=<cli-profile> CATALOG=<catalog> VM_IP=<vm-ip>
C=/tmp/crdb-dbz-$(date +%s).sh; cp scripts/crdb-debezium-zerobus.sh $C && OUT=/tmp/crdb-dbz-result.md bash $C
```

Run a copy with its own name, as above, so that editing the script, or starting another run, can't change a run in progress (bash reads a script as it runs). It exits 0 when every claim passed, 1 when one failed and 2 when a prerequisite is missing. The images are pinned by default: `CRDB_IMAGE` (CockroachDB v25.4.13) and `DBZ_IMAGE` (Debezium Server 3.7.0.Final).

## The Debezium settings that matter

- `debezium.sink.type=zerobus`, with `endpoint`, `workspace.url`, `client.id` and `client.secret` (the service principal) under `debezium.sink.zerobus.`.
- `payload.mode=envelope` with `debezium.sink.zerobus.table=<catalog>.<schema>.cdc_log`: every source table's events go to one table, so a new source table or column needs no DDL in Databricks.
- `json.flexible.fields.encoding=string` into `VARIANT` columns: the sink sends `key`, `value`, `source_position` and `headers` as JSON text, and Zerobus parses it into `VARIANT`. `object` (nested JSON) is rejected by Zerobus: "Record decoder/encoder error: invalid type: map, expected a string" (`NonRetriableException`). Read the fields with paths, for example `value:after:tier::STRING`; the record's `key` holds the primary key columns. The source table is in `destination` (`crdb.<schema>.<table>`); `target_table` is always the log itself.
- Each delete is followed by a `tombstone` event (`tombstone.handling.mode=event`); silver skips them, or set `drop`.
- No transforms: the Debezium Server 3.7.0.Final image doesn't include `io.debezium.transforms.ExtractNewRecordState` (`ClassNotFoundException`), which typed mode needs.
- `idempotency.mode=source`: retries after a failure don't duplicate rows.
- CockroachDB: `kv.rangefeed.enabled = true`; the connector uses a sinkless changefeed (`changefeed.sink.type=sinkless`), so no Kafka or cloud storage sits in between.

## CockroachDB licensing

`start-single-node` is enough; `cockroach demo` isn't needed. Tested on v25.4.13 with no license key (2026-10-20): a sinkless changefeed (what the connector uses), a changefeed into `nodelocal://self` with `initial_scan = 'only'`, and `EXPORT INTO PARQUET ... AS OF SYSTEM TIME` all work. Current CockroachDB has no Core edition. A cluster without a license key has a 7-day grace period, after which it's throttled to 5 concurrent open transactions, and Free and Trial licenses need telemetry. For anything that runs longer than a week, set a free Enterprise Trial key with `SET CLUSTER SETTING enterprise.license = '<key>'`.

## After running

Add the result table and the environment lines (images with digests, the CockroachDB version, the host) to the run record. Compare the per-op counts with the workload: 5 snapshot rows per table, then `customers` 2 inserts, 1 update, 1 delete, and `orders` 1 insert, 2 updates, 1 delete.
