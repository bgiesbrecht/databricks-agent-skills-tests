# Masters restored onto a new data disk from object storage only, 2026-10-16

The VM's data disk was detached (later deleted) and a blank 32 GB Premium SSD attached at the same LUN. Before the swap: every container stopped, JuiceFS writeback flushed, the mount unmounted, a metadata dump uploaded to the bucket. Afterwards nothing came from the old disk: the local copy of the dump was deleted, images re-pulled, Redis started empty. Steps: lfc-source-cloud-vm `references/disk-setup.md` ("Replace the data disk") and `juicefs-branches.md`. Records: `recall.py --run 2026-10-16-disk-restore --all`.

| Master | Path | Result |
|---|---|---|
| Postgres, 30M rows | metadata dump from Blob → fresh Redis → mount → `juicefs clone -p` | ready in 1 s, all rows correct, first full read 14 s (all from Blob) |
| SQL Server, 5M rows | JuiceFS branch | correct |
| Db2, 5M rows | rclone pull (3.4 s), `.lfc-dirs` reapplied, reflink clone | correct |

All seven JuiceFS masters intact afterwards. Fixed along the way: `disk-setup.sh` didn't mount a replacement disk (the old disk's fstab line came first); the az CLI's `vm disk detach/attach` fail with `InvalidApiVersionParameter`, so the swap used `az rest`, and the attach must wait for the old disk to be `Unattached`.
