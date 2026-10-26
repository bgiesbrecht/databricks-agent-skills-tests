# Branching a master database with JuiceFS

[master-snapshots.md](master-snapshots.md) pulls the whole master onto the VM's disk and reflink-clones it there. With **JuiceFS**, the master stays in object storage: the VM's disk holds only a cache and the blocks a test changes, and `juicefs clone` makes a copy-on-write branch of any size in about 0.1 s. It works like a Lakebase branch for any engine that keeps its data in files.

| | rclone pull + XFS reflink | JuiceFS clone |
|---|---|---|
| VM disk needed | the whole master, plus changes | a cache (for example 2 GB), plus changes |
| First use on a new VM | pull everything (5.5 GB in about 45 s) | mount: ready in seconds, blocks fetched as read |
| Branch | `cp --reflink`, 0.01–8 s (more files, longer) | `juicefs clone -p`, 0.05–0.3 s |
| Writes (pgbench, 8 clients, default Postgres) | 514-575 TPS, 864-1,718 with durability off | 188-234 TPS; up to 1,952 with more Postgres memory (see [Write performance](#write-performance)) |
| Full-table read (snapshot) | limited by the VM disk | limited by the network to Blob; matched or beat a small Premium SSD |
| Save | upload whole changed files | nothing to upload: rename the branch |
| Moving parts | rclone | JuiceFS client, Redis (metadata), FUSE |

Pick **JuiceFS** for masters larger than you want on each VM's disk, for many masters, and for snapshot (initial load) tests, which mostly read. Pick **rclone + reflink** for write-heavy tests (CDC with high change rates), where JuiceFS writes are 2–4 times slower.

Tested on Azure (Ubuntu 24.04, Standard_D4s_v5, JuiceFS 1.4, Redis 7, Blob Hot, same region) with Postgres 16, SQL Server 2022, Oracle 23ai Free, Db2 11.5, CockroachDB 25 and YugabyteDB 2025: see the engine table at the end and [engine-masters.md](engine-masters.md).

## Rules

- **One metadata database per volume, forever.** The blocks in the bucket only make sense with the metadata that wrote them. Never mount the same bucket with a second or older metadata copy: the two delete each other's blocks, and reads fail with `input/output error`. Moving metadata (SQLite to Redis) is `juicefs dump` + `juicefs load`, after which the old copy must be deleted.
- **Branch with `juicefs clone -p`.** Without `-p` every file in the branch belongs to whoever ran the clone (root). Postgres hides this because its entrypoint chowns the data directory; YugabyteDB fails with `Permission denied: '/yb/conf/yugabyted.conf'`, and any engine that doesn't run as root is at risk.
- **Stop the database before cloning it**, as for any file copy (see each engine's stop command in [engine-masters.md](engine-masters.md)).
- **Let writeback finish before unmounting or deleting the cache.** With `--writeback`, a written block sits in the cache's `rawstaging` directory until it's uploaded. Wait until it's empty (`find <cache> -path '*rawstaging*' -type f` prints nothing).
- **Back up the metadata before deleting the VM.** The metadata lives on the VM, and without it the bucket is unreadable. `juicefs dump` writes it to a file; JuiceFS also uploads a dump to the bucket (`meta/`) every hour.
- **No reflink on the mount.** `cp --reflink` on a FUSE mount fails with `Operation not supported`; `juicefs clone` is the equivalent.
- **Same engine major version and CPU architecture** as the master, as in [master-snapshots.md](master-snapshots.md).

## Set up (once per VM)

As root on the VM. The cache and Redis's files go on the XFS data disk ([disk-setup.md](disk-setup.md)).

```bash
V=$(curl -fsSL https://api.github.com/repos/juicedata/juicefs/releases/latest | jq -r .tag_name)
cd /tmp && curl -fsSLO https://github.com/juicedata/juicefs/releases/download/$V/juicefs-${V#v}-linux-amd64.tar.gz \
  && curl -fsSLO https://github.com/juicedata/juicefs/releases/download/$V/checksums.txt \
  && grep " juicefs-${V#v}-linux-amd64.tar.gz" checksums.txt | sha256sum -c - \
  && tar xzf juicefs-${V#v}-linux-amd64.tar.gz juicefs && install juicefs /usr/local/bin/
apt-get install -y fuse3
J=/var/lib/containers/jfs; install -d $J/cache $J/redis /mnt/jfs
podman run -d --name jfs-redis --restart=always -p 127.0.0.1:6379:6379 -v $J/redis:/data \
  docker.io/library/redis:7 redis-server --appendonly yes --appendfsync everysec
```

Redis keeps the metadata in memory and appends every change to `$J/redis` (about 130 KB of metadata for 6.6 GB of Postgres data). SQLite also works, but writes were 25% slower.

**Access (Azure Blob).** A container in the storage account, for example `juicefs`, and a container SAS (`racwdl`), held in a shell variable on your laptop and piped straight into a root-only file on the VM, so it's never printed or written on the laptop. The connection string must be quoted, since it contains `;` and `&`:

```bash
SAS=$(az storage container generate-sas --account-name <account> -n juicefs --auth-mode key \
  --permissions racwdl --expiry "$(date -u -v+2d '+%Y-%m-%dT%H:%MZ')" --https-only -o tsv)
printf "AZURE_STORAGE_CONNECTION_STRING='BlobEndpoint=https://%s.blob.core.windows.net;SharedAccessSignature=%s'\n" \
  <account> "$SAS" \
  | ssh -i ~/.ssh/lfc_test_rsa azureuser@<VM_IP> 'sudo install -d -m 700 /etc/juicefs; sudo sh -c "umask 077; cat > /etc/juicefs/azure.env"'
unset SAS
```

(Linux `date`: `-d '+2 days'`.) When the SAS expires the mount stops reading blocks it hasn't cached; write a new file and remount.

**Create the volume** (once; the bucket URL is `https://<container>.core.windows.net`, and the account comes from the connection string):

```bash
set -a; . /etc/juicefs/azure.env; set +a
juicefs format --storage wasb --bucket https://juicefs.core.windows.net --trash-days 0 redis://127.0.0.1:6379/1 lfcmasters
```

`--trash-days 0` frees a deleted branch's blocks right away instead of keeping them for a day.

## Mount

```bash
set -a; . /etc/juicefs/azure.env; set +a
juicefs mount -d --writeback --cache-dir /var/lib/containers/jfs/cache --cache-size 2048 -o allow_other \
  --log /var/log/juicefs.log redis://127.0.0.1:6379/1 /mnt/jfs
```

- `-o allow_other` lets the database containers' users (uid 999, 10001, 54321, ...) use the mount.
- `--writeback` uploads written blocks in the background: Postgres writes went from 180 to 234 TPS.
- `--cache-size` is in MiB. Reads past the cache come from Blob; see "Read performance" below.

## Use

```bash
M=/mnt/jfs/masters; B=/mnt/jfs/branches; mkdir -p $M $B
cp -a /var/lib/containers/lfc-data/master $M/<name>        # once: put a stopped master in (or pull it with rclone)
juicefs clone -p $M/<name> $B/test-1                       # branch: 0.1 s for any size
podman run -d --name <container> -v $B/test-1:<data path> ... <image>
# ... test ...
podman stop -t 60 <container>; podman rm <container>
rm -rf "${B:?}/test-1"                                           # throw it away (0.1 s)
mv $B/test-1 $M/<name>-v2                                  # or keep it as a new master (instant)
```

Data paths and stop commands per engine are in [engine-masters.md](engine-masters.md).

**Before deleting the VM or its data disk**, put the metadata in the bucket. The disk being deleted holds Redis and the cache, so a dump left on it is lost with it:

```bash
for c in $(podman ps --format '{{.Names}}' | grep -v '^jfs-redis$'); do podman stop -t 120 $c; done
until ! find /var/lib/containers/jfs/cache -path '*rawstaging*' -type f | grep . > /dev/null; do sleep 2; done   # writeback uploaded
umount /mnt/jfs
juicefs dump redis://127.0.0.1:6379/1 /var/tmp/meta.json.gz              # /var/tmp is on the OS disk
rclone copy /var/tmp/meta.json.gz jfs:juicefs/meta-manual/               # a container SAS: paths start with the container name
podman stop -a; systemctl stop podman.socket podman.service; umount /var/lib/containers
```

`rclone` here is the container from [master-snapshots.md](master-snapshots.md), with a remote for the JuiceFS container: `RCLONE_CONFIG_JFS_TYPE=azureblob` and `RCLONE_CONFIG_JFS_SAS_URL=https://<account>.blob.core.windows.net/juicefs?<sas>`. JuiceFS also uploads a dump every hour while mounted (`<volume>/meta/dump-<time>.json.gz` in the bucket). That's a fallback, up to an hour old. Stop `podman.socket` too, or a later `podman` call recreates `storage/` on the root disk under the empty mount point.

**On a new data disk, or a new VM** (tested: old disk detached, a blank one attached, [disk-setup.md](disk-setup.md), then this):

```bash
rclone copy jfs:juicefs/meta-manual/meta.json.gz /var/tmp/
podman run -d --name jfs-redis --restart=always -p 127.0.0.1:6379:6379 -v /var/lib/containers/jfs/redis:/data \
  docker.io/library/redis:7 redis-server --appendonly yes --appendfsync everysec
juicefs load redis://127.0.0.1:6379/1 /var/tmp/meta.json.gz              # an empty Redis db; 0.1 s for 7 masters
# then mount as above, and branch: juicefs clone -p /mnt/jfs/masters/<name> /mnt/jfs/branches/<test>
```

On the blank disk, a Postgres branch of a 30M-row master was ready in 1 s and returned every row (the first full count took 14 s, all from Blob). A SQL Server branch returned its 5M rows. In this setup, use one VM at a time on a volume: Redis, the metadata engine, runs on the VM and listens only on 127.0.0.1. That's a choice here, not a JuiceFS limit. With a metadata engine every VM can reach (a shared Redis, or a SQL database), several VMs can mount the volume; that isn't tested here. One VM can run many branches of one master at once, each in its own container. To give another VM a copy today, `cp -a` the master out of the mount and use rclone.

## Read performance (snapshot tests)

A snapshot reads every row once, which is the case JuiceFS handles best. Postgres 16, `COPY pgbench_accounts TO STDOUT` of 30M rows (3.8 GB table), page cache dropped before each run:

| Where the data came from | Time |
|---|---|
| JuiceFS, empty cache (all from Blob) | 17.4–19.9 s |
| JuiceFS, cache disabled (`--cache-size 0`) | 17.4 s |
| JuiceFS, from its local cache (10 GB) | 24.0 s |
| Local XFS, 32 GB Premium SSD (P4) | 37.9–45.7 s |
| Everything in memory | 11.9 s (Postgres's own COPY cost) |

- On this VM, Blob (about 300 MB/s) was **faster than the small Premium SSD** (P4: 25 MB/s baseline, 170 MB/s burst). So a big cache on a small disk makes reads slower, not faster. Keep the cache small, or put it on a faster disk (a larger Premium SSD, or the local NVMe of a `d` VM size such as D4ds_v5).
- Raising `--buffer-size`, `--max-downloads` and `--prefetch` changed nothing measurable: Postgres's own COPY work is most of the time.
- The first read after a mount pays the download; with a cache that fits the data, the next read comes from local disk.
- Starting a database on a branch with an empty cache took 2.4 s (Postgres).

## Write performance

Postgres 16 branch of a 30M-row master (3.8 GB table), pgbench with 8 clients, Standard_D4s_v5. The JuiceFS client is CPU-bound: about 2.7 of 4 cores during pgbench, writing hundreds of MB/s into its cache and Blob for small row updates. The fix is in Postgres, not in the storage layout:

| Change | JuiceFS TPS | XFS reflink TPS |
|---|---|---|
| Defaults (2 GB cache, `shared_buffers` 128 MB) | 188-225 | 555-575 |
| WAL (`pg_wal`) copied to local XFS, data on JuiceFS | 195; 222 with durability off | |
| Mount `--buffer-size 1024`, `--upload-delay 10m`, `--prefetch 0`, a bigger or RAM cache, each alone | 225-238 | |
| 10 GB cache warmed (`juicefs warmup`) + `--buffer-size 1024 --prefetch 0` | 288-359 | |
| + Postgres `shared_buffers=4GB`, `max_wal_size=8GB`, `checkpoint_timeout=30min`, 60 s run | **1,952**; 6,265 with durability off | 940; 3,853 with durability off |
| Same, 6 min with a checkpoint every 2 min | 1,719-1,730 until the first checkpoint, then 154-389 (average 758) | 732-1,329 (average 1,053) |

- **Give Postgres the memory.** With the working set in `shared_buffers` and checkpoints spread out, JuiceFS is faster than the local disk until a checkpoint writes the dirty pages, then several times slower while it does. Good for short write-heavy tests (minutes); for long ones, a reflink clone on XFS is steadier.
- **Don't split the WAL onto local disk.** It didn't help (the WAL isn't the bottleneck), and it makes a branch two places to manage. Postgres also won't start on an empty `pg_wal`, even after a clean shutdown (`PANIC: could not locate a valid checkpoint record`): the WAL has to be copied, and copied back before keeping a branch.
- **Durability off** (`fsync=off`, `synchronous_commit=off`, `full_page_writes=off`) helps XFS a lot and JuiceFS only once Postgres has the memory: with `--writeback` an fsync already returns once the block is in the local cache.
- **Stopping takes longer** with big `shared_buffers`: the shutdown checkpoint writes them (46 s here), and writeback then uploads (57 s). Wait for both before cloning or unmounting.

## Engines tested

Every engine started on a branch, returned the master's rows, took writes, and left the master and later branches unchanged.

| Engine | `juicefs clone -p` | Start on the branch | Cold full count of 5M rows (empty cache) |
|---|---|---|---|
| SQL Server 2022 | 0.13 s | 6.1 s | 8.9 s (includes recovery) |
| Oracle 23ai Free | 0.09 s | 30.5 s | 4.6 s |
| Db2 11.5 | 0.20 s | 71 s | 4.7 s |
| CockroachDB 25 | 0.10 s | 1.9 s | 3.8 s |
| YugabyteDB 2025 | 0.22 s | 6.0 s | 7.5 s |

Per-engine details (owners, clean stops, readiness) and the rclone comparison: [engine-masters.md](engine-masters.md).
