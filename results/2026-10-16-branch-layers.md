# Branch layers for master databases, 2026-10-16

Can a large master database live in object storage and be branched per test, like a Lakebase branch, for any engine? Azure VM (Standard_D4s_v5, 32 GB Premium SSD, XFS), Blob Hot in the same region, JuiceFS 1.4 with Redis metadata. Each engine master: a 5M-row table. Details and per-engine rules: lfc-source-cloud-vm `references/juicefs-branches.md`, `master-snapshots.md`, `engine-masters.md`; `scripts/branch-test.sh` reruns any cell. Records: `recall.py --run 2026-10-16-branch-layers --all`.

| Engine | rclone pull + XFS reflink | `juicefs clone -p` | Reflink isolation (master checksum unchanged after a write on the clone) |
|---|---|---|---|
| SQL Server 2022 | ✅ owners restored after pull | ✅ | ✅ 0 MB clone |
| Oracle 23ai Free | ✅ | ✅ | ✅ |
| Db2 11.5 | ✅ needs `.lfc-dirs` (setgid, setuid) | ✅ | ✅ |
| CockroachDB 25 | ✅ `--links` | ✅ | ✅ |
| YugabyteDB 2025 | ✅ `--links`, owners | ✅ | ✅ |
| PostgreSQL 16 (30M rows) | ✅ | ✅ 0.1-0.3 s | ✅ (earlier test) |

Performance (Postgres, pgbench 8 clients): JuiceFS 234 TPS (223 with durability off), XFS reflink clone 514 (864 with durability off). Snapshot-style full read of a 3.8 GB table: JuiceFS from Blob 17-20 s, local XFS on the 32 GB P4 SSD 38-46 s, in memory 12 s: Blob beat the small SSD.

Rejected: SeaweedFS (no copy-on-write; a branch is a full copy). `cp --reflink` on a JuiceFS mount: `Operation not supported` (use `juicefs clone`).

Found along the way: `juicefs clone` without `-p` makes root own every file; mounting a bucket with a second, stale metadata copy gives `input/output error` (one metadata database per volume); a harness bug that would have deleted a master was caught before it ran.
