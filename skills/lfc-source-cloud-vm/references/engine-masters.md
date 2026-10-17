# Masters and branches per engine

What each engine needs for a reusable master, with either approach:
- [master-snapshots.md](master-snapshots.md): rclone pull plus an XFS reflink clone.
- [juicefs-branches.md](juicefs-branches.md): `juicefs clone`.

How to start each engine in Podman is in **lfc-source-podman**'s `references/engines.md`.

[`scripts/branch-test.sh`](../scripts/branch-test.sh) runs both approaches for one engine and checks the results. It builds a 5M-row master, then clones it, verifies, writes, times a cold full read, and discards.

## What differs per engine

| Engine | Image | Data path | Runs as | Stop cleanly | Ready when |
|---|---|---|---|---|---|
| Postgres 16 | `library/postgres:16` | `/var/lib/postgresql/data` | root, then 999 (fixes owners on start) | `podman stop -t 60` | `pg_isready` |
| SQL Server 2022 | `mssql/server:2022-latest` | `/var/opt/mssql` | **10001** | `SHUTDOWN` in T-SQL, then `podman stop` | the database answers a query (not just the server) |
| Oracle 23ai Free | `gvenzl/oracle-free:23-slim` | `/opt/oracle/oradata` | **54321** (a pulled copy started without the chown; chown anyway, since root-owned directories block any new file, such as a datafile or archive log) | `podman stop -t 120` (the image shuts the database down on SIGTERM) | a query as the app user on `FREEPDB1` (the user is created after the database opens) |
| Db2 11.5 | `db2_community/db2:11.5.9.0` (`--privileged`) | `/database` | root, instance as **db2inst1** (uid 1000), with setgid directories and setuid programs | `su - db2inst1 -c 'db2 force applications all; db2stop force'`, then `podman stop` | a query after `connect to <db>` (first start about 2.5 min, restart about 40 s) |
| CockroachDB 25 | `cockroachdb/cockroach:latest` | `/cockroach/cockroach-data` | root | `cockroach node drain --self --insecure --shutdown`, then `podman stop` | `cockroach sql -e 'SELECT 1'` |
| YugabyteDB 2025 | `yugabytedb/yugabyte:latest` | `--base_dir`, e.g. `/yb` | **10001** (group 100) | `podman stop -t 60` | `ysqlsh -h 127.0.0.1 -c 'SELECT 1'` |

- **Runs as.** In bold: engines that fail on an rclone pull unless the directory owners and modes are put back. Save them with the master and reapply them after the pull (`.lfc-dirs` in [master-snapshots.md](master-snapshots.md)); a `chown -R` is enough for SQL Server, Oracle and YugabyteDB, but not for Db2. `juicefs clone -p` keeps owners and modes, so a branch needs nothing.
- **Stop cleanly** before you upload, clone or delete. SQL Server and the Db2 image ignore SIGTERM: `podman stop -t 120` waits the full 120 s and then kills them. CockroachDB did the same once after a big load. The database survives a kill, as after a crash, but it has to recover on the next start, and every clone repeats that recovery.
- **Ready when.** SQL Server answers `SELECT 1` while its user databases are still recovering, and queries fail with `Msg 904 ... cannot be autostarted during server shutdown or startup`. Wait for a query on your own table.

## TPC masters: all six workloads per engine

[`scripts/tpc-master.sh`](../scripts/tpc-master.sh) builds one master per engine holding TPC-B, C, H, DS, E, and DI at a scale factor, ready to clone with `juicefs clone -p`. Each workload is its own database (MySQL, SQL Server), schema (Postgres), or user (Oracle, in `FREEPDB1`). Every row is generated inside the database with `INSERT ... SELECT` over the engine's own row generator: no data crosses the network.

```bash
# on a machine with uv: the DDL, from lfc-source-statschema (shape once, then one file per dialect)
S=skills/lfc-source-statschema/scripts
for w in tpcb tpcc tpch tpcds tpce tpcdi; do uv run $S/shape.py $S/../schemas/$w.yaml --sf 1 > $w.yaml
  for d in postgres mysql tsql oracle; do uv run $S/ddl.py $w.yaml --dialect $d > ddl/$w-$d.sql; done; done
# on the VM: the DDL in $DDL, lfc-source-datagen's scripts/ in $DG, admin passwords in $SECRETS/<engine>.env
sudo systemd-run --unit=lfc-master-pg --collect -E SECRETS=/root/lfc-src/masters \
  bash -c 'bash tpc-master.sh postgres postgres16-tpc-sf1 > master-pg.out 2>&1'
```

| Engine | Row generator | Load settings (the build only) |
|---|---|---|
| Postgres 16 | `generate_series` (`SRC=series`) | `fsync=off`, `full_page_writes=off`; `pg_resetwal` after a clean stop drops the load's WAL |
| MySQL 8.4 | a seed table of 2^20 keys, filled by doubling with `INSERT ... SELECT` | no binary log, `innodb_flush_log_at_trx_commit=0` |
| SQL Server 2022 | `GENERATE_SERIES` (compatibility level 160) | `SIMPLE` recovery, `WITH (TABLOCK)` |
| Oracle 23ai Free | `CONNECT BY LEVEL` | `/*+ APPEND */` (direct path), autocommit per statement |

The lfc tags stay in each master, so a clone can be topped up or appended to with the same planners. Results: below, and in `results/runs/` (`recall.py --test other --grep tpc-master`).

## Results

Azure Standard_D4s_v5 (4 vCPU, 16 GB), Ubuntu 24.04, Podman 4.9, 32 GB Premium SSD (XFS), Blob Hot in the same region, JuiceFS 1.4 with Redis metadata and `--writeback`. Each master is a table of 5M rows (id, 80-character text, int). The test updates 100,000 rows. Cold reads start the container with every cache dropped, so they include the engine's startup recovery.

| Engine | Master (files) | rclone upload / pull | Reflink clone | Save after the update | `juicefs clone` | Start on a JuiceFS branch | Cold full count, XFS / JuiceFS |
|---|---|---|---|---|---|---|---|
| Postgres 16 (pgbench, 30M rows) | 5.5 GB | not timed (`cp` out of JuiceFS: 41–56 s) | under 1 s | see master-snapshots.md | 0.1–0.3 s | 2.4 s | — / 13.5 s |
| SQL Server 2022 | 695 MB (36) | 5.9 s / 2.6 s | 4.3 s | 696 MiB, 31 files (everything) | 0.13 s | 6.1 s | 4.4 s / 8.9 s |
| Oracle 23ai Free | 4.0 GB (23) | 8.6 s / 14.6 s | 11.9 s | 3.1 GiB, 13 files (everything) | 0.09 s | 30.5 s (19.4 s on XFS) | 3.5 s / 4.6 s |
| Db2 11.5 | 854 MB (238) | 7.2 s / 3.4 s | 5.6 s | 862 MiB, 61 files (everything) | 0.20 s | 71 s (39 s on XFS) | 5.4 s / 4.7 s |
| CockroachDB 25 | 1.1 GB (83) | 3.1 s / 2.3 s | 5.5 s | 4.7 MiB, 39 files | 0.10 s | 1.9 s | 2.7 s / 3.8 s |
| YugabyteDB 2025 | 2.1 GB (226) | 4.4 s / 3.0 s | 7.8 s | 505 MiB, 144 files | 0.22 s | 6.0 s | 25.6 s / 7.5 s |

Every clone returned the master's rows. After the update it returned the changed rows. A second branch made after the first was discarded had none of the change.

**XFS reflink isolation** (`branch-test.sh <engine> reflink`): each master is pulled from Blob onto a fresh data disk, checksummed (SHA-256 of every file), reflink-cloned, and the clone gets the 100,000-row update. For Db2, CockroachDB, YugabyteDB, SQL Server and Oracle alike:
- the clone added 0 MB to the disk;
- the master's checksum was identical after the write;
- a second clone had none of the write.

JuiceFS branches were checked the same way, minus the checksum (a second `juicefs clone` has none of the write).

Notes:

- **Branch time.** A reflink copy grows with the number of extents: a few seconds for a heavily written 1 GB data file. `juicefs clone` is a metadata copy (0.1–0.3 s).
- **Save size (rclone).** rclone saves whole changed files. CockroachDB writes new small SST files, so a save after the update was 5 MiB. SQL Server, Oracle and Db2 rewrite their large data files, so a save is the whole master again. With JuiceFS there's nothing to upload: `mv` the branch.
- **Cold reads.** The 32 GB Premium SSD (P4) is the slowest part of this VM once its burst credits run out: YugabyteDB's cold count was 25.6 s from it and 7.5 s from JuiceFS (Blob). On a larger disk, or the local NVMe of a `d` VM size, local reads are faster.
