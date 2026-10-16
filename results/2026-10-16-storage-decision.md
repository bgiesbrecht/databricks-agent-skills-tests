# Which storage for master databases: XFS reflink, JuiceFS, or copies, 2026-10-16

Question: masters of TPC-H at several scale factors live once per cloud; each test should start from a fresh copy in a couple of seconds. Is JuiceFS (master in object storage, branched in place) good enough, given that Lakeflow Connect may pull slower than local disk serves? Postgres 16 on an Azure Standard_D4s_v5, 128 GB Premium SSD (P10) with XFS, Blob Hot in the same region, JuiceFS 1.4 with Redis metadata; masters built with `lfc-source-datagen` (`tpc-schema.sh tpch <sf>`, `fill.sh`), stopped cleanly, WAL trimmed with `pg_resetwal`. Every run started cold (page cache dropped; for JuiceFS, the cache emptied unless "warm"). Lakeflow Connect: one query-based pipeline (serverless, all eight tables SCD1 with their primary keys, no cursor), full refresh per run. Records: `recall.py --run 2026-10-16-storage-decision --all`.

| TPC-H | Clone to Postgres ready: XFS reflink / JuiceFS / pull from Blob | Raw full read: XFS / JuiceFS cold / JuiceFS warm | Lakeflow Connect ingest: XFS / JuiceFS cold / warm | Whole update |
|---|---|---|---|---|
| SF 1: 8.66M rows, 1.4 GB | 2.6 s / 2.8 s / 18 s | 105 / 88 / 107 MB/s | 58 / 61 / 74 s | 105 / 106 / 135 s |
| SF 2: 17.3M rows, 2.8 GB | 2.6 s / 2.8 s / 29 s | 109 / 48 / 52 MB/s | 104 / 138 / 158 s | 157 / 195 / 250 s |
| SF 4: 34.6M rows, 5.6 GB | 2.7 s / 2.9 s / 51 s | 112 / 109 / 120 MB/s | 181 / 209 / 199 s | 238 / 261 / 255 s |

- **Both clone paths start a database in under 3 seconds** at every size; a copy from object storage takes 18-51 s and needs disk for every master.
- **Lakeflow Connect is the bottleneck:** 110k-190k rows/s (about 25-30 MB/s), a quarter of what either storage serves. End to end, a JuiceFS-backed snapshot ran about 10% longer than XFS at SF 4; the spread between repeated runs is as large as the storage difference (a warm JuiceFS cache wasn't reliably faster than a cold one).
- **Building the masters:** fills took 4.5 min (SF 1), 9.5 min (SF 2) and 22 min (SF 4); publishing to Blob 19-36 s, into JuiceFS 23-63 s. The build's WAL (GBs) must be trimmed before publishing, or every clone carries it.

**Decision:** keep masters in JuiceFS, one volume per cloud, and branch per test; use an XFS reflink clone of a local copy for long, write-heavy runs (see [JuiceFS write tuning](2026-10-16-juicefs-write-tuning.md)); plain copies in object storage only to seed XFS.

Not yet: the same on AWS (S3), MySQL / SQL Server / Oracle masters, larger scale factors, and CDC at fixed change rates (Postgres CDC isn't enabled on the test workspaces).
