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

## Size and cost

Sizes of the masters (same bytes in each place; JuiceFS doesn't compress by default):

| Master | On XFS | Plain copy in Blob | In JuiceFS (logical) |
|---|---|---|---|
| TPC-H SF 1 | 1.9 GB | 1.9 GB | 1.8 GiB |
| TPC-H SF 2 | 3.7 GB | 3.7 GB | 3.6 GiB |
| TPC-H SF 4 | 7.4 GB | 7.4 GB | 7.2 GiB |

Prices (Azure retail API, centralus, list price): Premium SSD is bought by disk size, P10 128 GB $19.71/month ($0.154/GB-month, used or not), P4 32 GB $5.28; Blob Hot LRS $0.0184/GB-month for what's stored (about 8x cheaper), plus $0.05 per 10,000 writes and $0.004 per 10,000 reads. All three masters (13 GB) cost about $0.24/month in Blob, once per region, whether as plain copies or in JuiceFS; keeping them on every VM needs disk on every VM (a P10 is $19.71/month each).

**Extra space for each person's clone** (SF 4, 7.2 GB master; JuiceFS: object storage and Redis metadata; XFS: local disk):

| Step | JuiceFS bucket | JuiceFS metadata | XFS reflink |
|---|---|---|---|
| Clone | 0 MB | 570 KB | 0 MB |
| Start, read all of `lineitem`, stop | 0 MB | 0.2 MB | 0 MB |
| Update 1% of `lineitem` (240,000 rows spread over the table) | +7,978 MB | +0.6 MB | +5,994 MB |
| Delete the clone | back to +8 MB | back to 0 | back to 0 |

What a clone costs depends on how many **pages** the test changes, not how many rows: reads and snapshots cost nothing, appends and changes to a narrow key range cost little, and an update spread across a table rewrites most of its pages (plus WAL), which here made the clone as big as a full copy (larger on JuiceFS, which stores rewritten data in whole 4 MB blocks). Budget a full master per concurrent person for wide-update tests, nothing extra for snapshot and read tests; the space comes back when the clone is deleted. On JuiceFS that space is Blob at $0.018/GB-month; on XFS it's provisioned SSD.

**Decision:** keep masters in JuiceFS, one volume per cloud, and branch per test; use an XFS reflink clone of a local copy for long, write-heavy runs (see [JuiceFS write tuning](2026-10-16-juicefs-write-tuning.md)); plain copies in object storage only to seed XFS.

Not yet: the same on AWS (S3), MySQL / SQL Server / Oracle masters, larger scale factors, and CDC at fixed change rates (Postgres CDC isn't enabled on the test workspaces).
