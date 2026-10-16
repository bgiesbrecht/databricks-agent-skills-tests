# JuiceFS write tuning for Postgres branches, 2026-10-16

Question: can a JuiceFS branch get closer to local XFS for write-heavy tests, keeping the setup simple? Postgres 16 branch of a pgbench scale-300 master (30M rows), 8 clients, Azure Standard_D4s_v5. Details: [juicefs-branches.md](../skills/lfc-source-cloud-vm/references/juicefs-branches.md) "Write performance". Records: `recall.py --run 2026-10-16-juicefs-write-tuning --all`.

| Change | JuiceFS | XFS reflink |
|---|---|---|
| Defaults | 188-225 TPS | 555-575 |
| WAL on local XFS (copied), data on JuiceFS | 195; 222 durability off | |
| Empty local `pg_wal` (an idea from a generated script) | doesn't start: `PANIC: could not locate a valid checkpoint record` | |
| One mount option at a time (`--buffer-size`, `--upload-delay`, `--prefetch 0`, bigger or RAM cache) | 225-238 | |
| Warmed 10 GB cache + `--buffer-size 1024 --prefetch 0` | 288-359 | |
| + Postgres `shared_buffers=4GB`, fewer checkpoints (60 s run) | **1,952**; 6,265 durability off | 940; 3,853 |
| Same, 6 min, checkpoint every 2 min | 1,719-1,730, then 154-389 at checkpoints (avg 758) | 732-1,329 (avg 1,053) |

The JuiceFS client was CPU-bound (about 2.7 of 4 cores) writing every evicted Postgres page. Giving Postgres the memory is the simplest and biggest win; for long write-heavy runs the XFS reflink clone stays steadier.
