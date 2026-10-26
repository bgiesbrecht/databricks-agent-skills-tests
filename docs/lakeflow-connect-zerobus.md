# Lakeflow Connect Zerobus: database changes, tested end to end

A source database's changes reach the lakehouse through Zerobus Ingest, with nothing else in between: no Kafka broker, no staging storage, no ingestion cluster. A snapshot as of a time T goes into a Unity Catalog volume. The changes from T stream into one append-only bronze change log. Silver AUTO CDC tables (current rows and every version) and a gold materialized view are built from those two, and each is checked against the source, row by row and version by version. Back to the [README](../README.md).

## Tested end to end, by database

Every ✅ ran end to end on Azure, into a serverless workspace, from the committed skills with no local changes ([the runs](#successful-runs)).

| Database | Producer into Zerobus | Bronze: inserts, updates, deletes | Silver, current rows (SCD 1) | Silver, every version (SCD 2) | Gold | Producer killed and restarted | Column added | Column dropped, column retyped | No cloud storage (laptop) |
|---|---|---|---|---|---|---|---|---|---|
| CockroachDB v25.4.13 | Debezium Server 3.7.0.Final, Zerobus sink (gRPC) | ✅ | ✅ | ✅ replays removed | ✅ incremental | ✅ replays 4 of 5 changes; silver right | ✅ backfilled by the source | ✅ | ✅ |
| YugabyteDB 2026.1.2.0 | Kafka Connect 3.7.2 (standalone, no broker), Yugabyte's connector, into the Zerobus Kafka-compatible endpoint | ✅ | ✅ | ✅ | ✅ incremental | ✅ no replays | ✅ from the column's default | ✅ | not run yet |
| Db2 11.5.9 | Debezium Server 3.7, Zerobus sink | ✅ | ✅ | ✅ | no TPC gold yet | ✅ | not run yet | not run yet | not run yet |
| Informix 14.10 | Debezium Server 3.7, Zerobus sink | ✅ | ✅ | ✅ | no TPC gold yet | ✅ | not run yet | not run yet | not run yet |
| MySQL 8.4.11 | Debezium Server 3.7, Zerobus sink | ✅ | ✅ | ✅ | no TPC gold yet | ✅ | ✅ | ✅ | not run yet |
| Oracle 26ai Free 23.26.3 | Debezium Server 3.7, Zerobus sink | ✅ | ✅ | ✅ | no TPC gold yet | ✅ | not run yet | not run yet | not run yet |
| PostgreSQL 16.15 | Debezium Server 3.7, Zerobus sink | ✅ | ✅ | ✅ | no TPC gold yet | ✅ | ✅ | ✅ | not run yet |
| SQL Server 2022 (16.0.4305) | Debezium Server 3.7, Zerobus sink | ✅ | ✅ | ✅ | no TPC gold yet | ✅ | not run yet | not run yet | not run yet |

- **The six databases from Db2 to SQL Server** each ran the six TPC models (TPC-B, TPC-C, TPC-DI, TPC-DS, TPC-E, TPC-H) at scale factor 0.001, one source into one set of tables, on Azure serverless. MySQL and PostgreSQL ran all five rounds; the other four ran rounds 1 to 3 (their schema-change rounds are next). Several sources into one set of tables passed too: TPC-H with 2 sources on Db2, Informix, MySQL, PostgreSQL and SQL Server, and the Mautic schema with 2 and 4 MySQL sources. The grid per model: `uv run skills/lfc-test-results/scripts/recall.py --combos --test zerobus`.
- **Each ✅ is a claim the test checks**, not a guess. Silver and gold are compared with the source table by table, after each of five rounds of changes. Every SCD 2 version is compared with the source's own change history, in commit order. Each round's changes:

  | Round | Changes |
  |---|---|
  | 1 | Inserts, updates, deletes |
  | 2 | Two updates of one key, a delete and reinsert, a reinsert of a deleted key |
  | 3 | The producer killed (SIGKILL) and started again |
  | 4 | A column added with a default |
  | 5 | A column dropped and another retyped from `DECIMAL(10,2)` to `DECIMAL(12,2)` |

- **Producer killed and restarted.**
  - Debezium Server on CockroachDB re-sends the changes since its last saved position. Zerobus keeps them as new rows, and an SCD 2 table without deduplication records them as versions that never happened.
  - The history tables drop replays by key and row image, within a 10-minute watermark.
  - Kafka Connect on YugabyteDB resumed from the replication slot's confirmed position, with no replays.
- **Column added.**
  - CockroachDB re-sends every row with the new column.
  - YugabyteDB, like PostgreSQL, doesn't, so silver fills the column's default where an event lacks the field.
  - Either way, silver needs its flows regenerated and that table full-refreshed, then a plain update.
- **Column dropped.** The old flow fails (`INVALID_VARIANT_CAST`): that's the signal to regenerate.
- **No cloud storage.** The source and the producer run in Podman on a laptop. The snapshot and the schema (statschema's `schema.yaml`) go to a managed volume with `databricks fs cp`, and the pipeline builds itself from that file. Zerobus still needs a service principal; someone who can create one hands over its ID and secret.

## Successful runs

| Date (UTC) | Commit | Database | Route | Where | Claims | Run |
|---|---|---|---|---|---|---|
| 2026-10-21 | `cc88fc3` | CockroachDB v25.4.13 | Debezium Server → Zerobus (gRPC) | Cloud VM (Ubuntu 24.04.4 LTS, podman version 4.9.3) → azure centralus serverless | 33 of 33 | 1792596852, [run-all.sh](../skills/zerobus-debezium-test/scripts/run-all.sh) |
| 2026-10-21 | `cc88fc3` | YugabyteDB 2026.1.2.0 | Kafka Connect → Zerobus Kafka endpoint | Cloud VM (Ubuntu 24.04.4 LTS, podman version 4.9.3) → azure centralus serverless | 33 of 33 | 1792596857, [run-all.sh](../skills/zerobus-debezium-test/scripts/run-all.sh) |
| 2026-10-21 | `cc88fc3` | CockroachDB v25.4.13 | Debezium Server → Zerobus (gRPC) | Laptop, a Lima VM `<lima-vm>`, no cloud storage (Ubuntu 25.10, podman version 5.4.2) → azure centralus serverless | 33 of 33 | 1792596848, [run-all.sh](../skills/zerobus-debezium-test/scripts/run-all.sh) |
| 2026-10-21 | `a3d478a` | CockroachDB v25.4.13 | Debezium Server → Zerobus (gRPC) | Cloud VM (Ubuntu 24.04.4 LTS, podman version 4.9.3) → azure centralus serverless | 33 of 33 | 1792595214, [run-all.sh](../skills/zerobus-debezium-test/scripts/run-all.sh) |
| 2026-10-21 | `a3d478a` | YugabyteDB 2026.1.2.0 | Kafka Connect → Zerobus Kafka endpoint | Cloud VM (Ubuntu 24.04.4 LTS, podman version 4.9.3) → azure centralus serverless | 33 of 33 | 1792595219, [run-all.sh](../skills/zerobus-debezium-test/scripts/run-all.sh) |
| 2026-10-21 | `a3d8c16` | CockroachDB v25.4.13 | Debezium Server → Zerobus (gRPC) | Laptop, a Lima VM `<lima-vm>`, no cloud storage (Ubuntu 25.10, podman version 5.4.2) → azure centralus serverless | 33 of 33 | 1792594109, [run-all.sh](../skills/zerobus-debezium-test/scripts/run-all.sh) |
| 2026-10-21 | `e1720c0` | CockroachDB v25.4.13 | Debezium Server → Zerobus (gRPC) | Cloud VM (Ubuntu 24.04.4 LTS, podman version 4.9.3) → azure centralus serverless | 30 of 30 | 1792591170, [run-all.sh](../skills/zerobus-debezium-test/scripts/run-all.sh) |
| 2026-10-21 | `e1720c0` | YugabyteDB 2026.1.2.0 | Kafka Connect → Zerobus Kafka endpoint | Cloud VM (Ubuntu 24.04.4 LTS, podman version 4.9.3) → azure centralus serverless | 30 of 30 | 1792591175, [run-all.sh](../skills/zerobus-debezium-test/scripts/run-all.sh) |
| 2026-10-21 | `e1720c0` | CockroachDB v25.4.13 | Debezium Server → Zerobus (gRPC) | Laptop, a Lima VM `<lima-vm>`, no cloud storage (Ubuntu 25.10, podman version 5.4.2) → azure centralus serverless | 30 of 30 | 1792591183, [run-all.sh](../skills/zerobus-debezium-test/scripts/run-all.sh) |
| 2026-10-21 | `e6a64fc` | CockroachDB v25.4.13 | Debezium Server → Zerobus (gRPC) | Laptop, a Lima VM `<lima-vm>`, no cloud storage (Ubuntu 25.10, podman version 5.4.2) → azure centralus serverless | 30 of 30 | 1792586012, [run-all.sh](../skills/zerobus-debezium-test/scripts/run-all.sh) |
| 2026-10-21 | `96c5547` | CockroachDB v25.4.13 | Debezium Server → Zerobus (gRPC) | Azure VM (Ubuntu 24.04, Podman 4.9.3) → Azure serverless, centralus | 30 of 30 | 1792582600, [run-all.sh](../skills/zerobus-debezium-test/scripts/run-all.sh) |
| 2026-10-21 | `96c5547` | YugabyteDB 2026.1.2.0 | Kafka Connect → Zerobus Kafka endpoint | Azure VM → Azure serverless, centralus | 30 of 30 | 1792582605, [run-all.sh](../skills/zerobus-debezium-test/scripts/run-all.sh) |
| 2026-10-20 | `f0f9bbb` | CockroachDB v25.4.13 | Debezium Server → Zerobus (gRPC) | Laptop, Lima (Ubuntu 25.10 arm64, Podman 5.4.2), no cloud storage → Azure serverless | 30 of 30 | 1792541354 |
| 2026-10-20 | `f0f9bbb` | CockroachDB v25.4.13 | Debezium Server → Zerobus (gRPC) | Azure VM → Azure serverless, centralus | 30 of 30 | 1792541366 |

Images, digests and versions for each run are in its result table (`~/.lfc-test/results/zerobus-<commit>/<source>.md`).

## Run it again

```bash
# from the repo root, with no uncommitted changes in the skills
PROFILE=<cli-profile> CATALOG=<catalog> VM_IP=<vm-ip> bash skills/zerobus-debezium-test/scripts/run-all.sh
```

1. **A VM with Podman**, from **lfc-source-cloud-vm**, reachable over SSH from this laptop's IP. Or a laptop with Lima: see the skill.
2. **A workspace prepared for Zerobus.** Check it with **zerobus-workspace-setup** `check.sh`, and turn on missing previews with `enable.sh` (the Kafka endpoint for YugabyteDB: error 4062 until it's on).
3. **`run-all.sh`** runs the workspace check, then both databases in parallel, and writes a summary with the commit. It exits 0 only when every claim passed.

| Skill | What it does |
|---|---|
| [zerobus-debezium-test](../skills/zerobus-debezium-test/SKILL.md) | The test: snapshot, producer, bronze, silver SCD 1 and 2, gold, the five rounds; every finding with its evidence |
| [zerobus-workspace-setup](../skills/zerobus-workspace-setup/SKILL.md) | Zerobus previews (Settings API), the target table, direct grants, a minted table-scoped token, the network path |
| [lfc-source-statschema](../skills/lfc-source-statschema/SKILL.md) | The canonical `schema.yaml` that the laptop route sends through the volume |

How the data moves, layer by layer, is in [zerobus-debezium.md](zerobus-debezium.md).
