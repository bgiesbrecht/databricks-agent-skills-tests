# 2026-10-17: TPC SF 1 masters, four engines, three hosts (baseline timings)

All six TPC workloads (B, C, H, DS, E, DI) at scale factor 1, built as reusable masters by `lfc-source-cloud-vm` [`scripts/tpc-master.sh`](../skills/lfc-source-cloud-vm/scripts/tpc-master.sh) on PostgreSQL 16, MySQL 8.4, SQL Server 2022 and Oracle 23ai Free. Every row is generated inside the database with `INSERT ... SELECT` over the engine's own row generator (Postgres `generate_series`, MySQL a seed table filled by doubling, SQL Server `GENERATE_SERIES`, Oracle `CONNECT BY LEVEL`): only SQL text crosses the network. Every table of every master reached its target (109,712,237 rows in 95 tables per engine), with every foreign key enforced, **except Oracle's TPC-DI**: `DimTime` was never created (a `TIME` column from `ddl.py`, which Oracle rejects), found on 2026-10-17 when the AWS masters were read back ([AWS end to end](2026-10-17-aws-two-workspaces.md)). Fixed in `ddl.py` and rebuilt in the AWS master; the Azure master still needs the same rebuild. Records: `results/runs/2026-10-17-tpc-sf1-masters.jsonl`.

Use these as the **baseline for how long a load should take**: a build far slower than its row here is disk-bound or starved (see [disk-io-limits.md](../skills/lfc-source-cloud-vm/references/disk-io-limits.md)).

## Hosts

| Host | CPU / RAM | Data disk | fio 4k random write / read, 1 MB sequential write |
|---|---|---|---|
| Laptop: MacBook (Apple Silicon), Lima VZ VM, rootful Podman | 4 vCPU / 10 GiB | virtio disk on APFS | 3,585 / 270,103 IOPS, 192 MB/s |
| AWS m6i.xlarge | 4 vCPU / 16 GB | gp3 128 GiB, default 3,000 IOPS / 125 MB/s | 3,096 / 3,027 IOPS, 129 MB/s |
| Azure Standard_D4s_v5 | 4 vCPU / 16 GB | Premium SSD P10 128 GiB, 500 IOPS / 100 MB/s | 3,482 / 8,848 IOPS, 165 MB/s **on burst credits** (measured after the builds; the builds themselves got about 500 writes/s) |

SQL Server runs as x86_64 under Rosetta on the laptop; Oracle Free uses at most 2 CPUs everywhere. Oracle's TPC-E is a master of its own (Oracle Free holds 12 GB of user data).

## Fill time per workload (seconds)

| Engine | Workload (rows) | Laptop | AWS gp3 | Azure P10 |
|---|---|---|---|---|
| Postgres 16 | TPC-B (200,011) | 1 | 2 | 2 |
| | TPC-C (599,011) | 9 | 14 | 20 |
| | TPC-H (8,660,030) | 119 | 165 | 173 |
| | TPC-DS (19,559,359) | 216 | 343 | 336 |
| | TPC-E (80,482,507) | 584 | 892 | 940 |
| | TPC-DI (211,319) | 6 | 7 | 9 |
| MySQL 8.4 | TPC-B | 2 | 4 | 7 |
| | TPC-C | 11 | 18 | 65 |
| | TPC-H | 174 | 227 | 1,001 |
| | TPC-DS | 317 | 406 | 1,117 |
| | TPC-E | 921 | 1,173 | 3,857 |
| | TPC-DI | 11 | 14 | 43 |
| SQL Server 2022 | TPC-B | 8 | 5 | 8 |
| | TPC-C | 30 | 24 | 30 |
| | TPC-H | 207 | 168 | 175 |
| | TPC-DS | 214 | 168 | 199 |
| | TPC-E | 626 | 514 | 698 |
| | TPC-DI | 23 | 12 | 15 |
| Oracle 23ai Free | TPC-B | 7 | 11 | 13 |
| | TPC-C | 21 | 19 | 24 |
| | TPC-H | 307 | 424 | 676 |
| | TPC-DS | 493 | 744 | 1,190 |
| | TPC-E | 5,175 | 7,702 | 13,509 |
| | TPC-DI | 10 | 15 | 18 |

## Masters on disk

| Master | Workloads | Size (laptop / AWS / Azure in JuiceFS) |
|---|---|---|
| `postgres16-tpc-sf1` | all six | 14 GB / 14 GB / 14 GB (after `pg_resetwal`) |
| `mysql84-tpc-sf1` | all six | 21 GB / 21 GB / 20.7 GiB |
| `mssql2022-tpc-sf1` | all six | 11 GB / 11 GB / 10.4 GiB |
| `oracle23ai-tpc-sf1` | B, C, H, DS, DI | 11 GB / 11 GB / 9.3 GiB |
| `oracle23ai-tpce-sf1` | E | 15 GB / 14 GB / 13.0 GiB |

## What the numbers say

- **The disk decides MySQL and Oracle; SQL Server and Postgres barely notice.** Postgres (`fsync=off`) and SQL Server (`SIMPLE` recovery, `TABLOCK`) took about the same time on all three hosts (SQL Server's TPC-E: 514 to 698 s). MySQL and Oracle write much more per row: on the Azure P10 they took 2.2 to 5.8 times as long as on the laptop (MySQL TPC-H 1,001 s against 174 s).
- **The Azure P10 was faster in short tests than in this run.** Its burst credits gave up to 1,426 writes/s (5-minute average) in earlier, shorter tests; after four hours of builds it stayed at its 500 baseline (Azure Monitor). An Oracle TPC-H fill took 585 s in a short test and 676 s here.
- **The laptop is the fastest host for these loads**, though its writes are only at gp3's level: reads are a hundred times faster, and the CPUs are faster. SQL Server under Rosetta was within 25% of native x86_64.
- **Oracle Free's 2-CPU cap dominates TPC-E** (80M rows): 1.4 hours on the laptop, 2.1 on AWS, 3.75 on Azure, against 10 to 65 minutes for the other engines.
- **A short benchmark on a burstable disk predicts the wrong time.** `fio` on the Azure P10 right after the builds read 3,482 write IOPS and 165 MB/s, its burst ceiling, because the light Postgres rebuild had let the credits refill; the long builds before it ran at about 500. On Azure Premium SSD v1, judge from the disk's baseline, not from a 30-second test. The masters on Azure are in JuiceFS (Blob); on AWS, on the VM's gp3 volume (no instance profile for S3 yet).

## What broke, and the fixes

| Problem | Fix |
|---|---|
| TPC-E `daily_market`: duplicate keys at SF 1 on every engine | `shape.py`: a date or timestamp key counts the values in its rule's range (1,826 trading days); it took one day per row and ran past 9999-12-31 |
| Postgres with `generate_series`: `integer out of range` | the Postgres planner casts the series to `bigint` (the seed table's column already was) |
| Oracle TPC-E: SQL\*Plus asked `Enter value for defense:` | `fill.sh` runs Oracle statements with `SET DEFINE OFF` (a value list holds `& defense`) |
| The build hung on a container that had exited (SELinux in the Lima VM denied its data directory) | `tpc-master.sh` mounts with `:Z` and checks the container is still running while it waits |
| On the cloud VMs, stopping a unit left its `podman exec` sessions running and holding locks | watch-progress documents it: end them in the database |
