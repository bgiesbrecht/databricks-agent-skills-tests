# Reusable master database: object storage + XFS clones

Populating a large test database (100 GB and up) takes hours, and keeping it on a premium SSD while nobody uses it costs about ten times more than object storage. So populate it **once**, keep the stopped data directory in object storage, and on each VM:

1. **Pull** it once to a cache on the VM's XFS data disk.
2. **Clone** it for each test with `cp --reflink=always`: instant, and the clone takes no space until it's changed.
3. When the test is done, **throw the clone away**, or **save** it back to object storage.

| Where a 100 GB master sits idle | About |
|---|---|
| Azure Premium SSD (P10, 128 GB) | $20/month |
| Azure Blob, Hot tier | $2/month, no fee per read in the same region |

Keep the object storage in **the same cloud and region as the VM** (and the VM in the workspace's region, see **lfc-source-setup**), so pulls aren't billed as egress. Use the Hot tier: a master is read often and written rarely, and Cool charges per GB read plus a 30-day minimum, which every save resets.

Tested end to end with Azure Blob from an Azure VM (Ubuntu 24.04, XFS data disk) with Postgres 16, SQL Server 2022, Oracle 23ai Free, Db2 11.5, CockroachDB 25 and YugabyteDB 2025 ([engine-masters.md](engine-masters.md) has each engine's details). S3 and GCS use the same steps with their own directory-marker flag, but haven't been tested.

## Rules

- **Cache and clones on the same XFS filesystem**, under `/var/lib/containers` (see [disk-setup.md](disk-setup.md)). A reflink can't cross filesystems: `cp --reflink=always` from an `rclone mount` or into `/tmp` (often tmpfs) fails with `Invalid cross-device link`.
- **Stop the database cleanly** (`podman stop -t 60`) before uploading, saving, cloning, or deleting its files. Copying a running database's files gives a torn copy.
- **Keep empty directories, symlinks and file metadata.** Object storage has no empty directories or symlinks. Postgres won't start without its 12 empty directories (`could not open directory "pg_notify"`), and YugabyteDB keeps `data/pg_data` as a symlink. Always pass `--create-empty-src-dirs --metadata --links` and turn on directory markers. `--links` stores each symlink as a small `.rclonelink` object. On the pull, the first attempt logs `failed to set xattr key "user.tier"` for each symlink, and rclone's automatic retry succeeds; that's expected.
- **Save directory owners and modes with the master.** `--metadata` keeps each file's owner and mode, but directories come back owned by root with mode 755, and setuid, setgid and sticky bits are lost. Engines that run as root, or that fix owners on start (Postgres, MySQL, CockroachDB), don't mind. The others fail: SQL Server crashes (`chmod: changing permissions of '/var/opt/mssql/log'`), YugabyteDB gets `Permission denied: '/yb/conf/yugabyted.conf'`, and Db2's instance (uid 1000, setgid directories, setuid security programs) won't start, even after a `chown -R`. So write a list of those entries into the master before uploading (`.lfc-dirs`, below), and reapply it after every pull.
- **Same engine major version and CPU architecture** as the master. A Postgres 16 master doesn't start in Postgres 17, and amd64 and arm64 data files aren't guaranteed compatible.
- **Use a recent rclone.** Ubuntu 24.04's package (1.60) is too old for directory markers; run the `rclone/rclone` image, as below.

## Access (Azure Blob)

A storage account (`--kind StorageV2 --access-tier Hot --allow-blob-public-access false`) and a container, for example `masters`, tagged `purpose=lfc-test`.

- **Preferred:** give the VM a managed identity with **Storage Blob Data Reader** (pull only) or **Contributor** (save) on the container, and set `RCLONE_CONFIG_AZ_ENV_AUTH=true` instead of a SAS. Assigning roles needs Owner or User Access Administrator; if you don't have it, ask someone who does.
- **Otherwise:** a container SAS with a short expiry, generated into a private file and never printed:

```bash
umask 077
az storage container generate-sas --account-name <account> -n masters --auth-mode key \
  --permissions racwdl --expiry "$(date -u -d '+8 hours' '+%Y-%m-%dT%H:%MZ')" --https-only -o json \
  | yq -p json -o json -r '.' > sas.token
{ echo "RCLONE_CONFIG_AZ_TYPE=azureblob"
  echo "RCLONE_CONFIG_AZ_ACCOUNT=<account>"
  echo "RCLONE_CONFIG_AZ_SAS_URL=https://<account>.blob.core.windows.net/masters?$(cat sas.token)"
  echo "RCLONE_AZUREBLOB_DIRECTORY_MARKERS=true"; } > rclone.env
ssh -i ~/.ssh/lfc_test_rsa azureuser@<VM_IP> "sudo sh -c 'umask 077; cat > /var/tmp/lfc-rclone.env'" < rclone.env
rm rclone.env sas.token
```

(macOS `date`: `-v+8H` instead of `-d '+8 hours'`. Use `--permissions rl` for a pull-only token.) For S3 or GCS, set `RCLONE_S3_DIRECTORY_MARKERS=true` or `RCLONE_GCS_DIRECTORY_MARKERS=true` instead.

## On the VM

Every block runs on the VM as root (`sudo bash`). `NAME` is the master's name in the container, for example `pg16-orders-100g`.

```bash
D=/var/lib/containers/lfc-data; NAME=<master-name>
F="--create-empty-src-dirs --metadata --links"
rclone() { podman run --rm --env-file /var/tmp/lfc-rclone.env -v $D:$D:z docker.io/rclone/rclone:latest "$@"; }
mkdir -p $D/cache
[ "$(findmnt -no FSTYPE --target $D)" = xfs ] || echo "STOP: $D is not on XFS"
```

**Create the master** (once, by whoever populates it): run the database with its data directory at `$D/master`, load it, stop it, upload:

```bash
podman stop -t 60 <container>
(cd $D/master && find . \( -type d -o -perm /7000 \) -printf '%m %U %G %P\n' > .lfc-dirs)   # owners and modes object storage drops
rclone sync $D/master az:masters/$NAME $F --transfers 16 --checkers 16
```

**Pull** (once per VM, and after someone saves a new version):

```bash
rclone copy az:masters/$NAME $D/cache/$NAME $F --transfers 16 --checkers 16
(cd $D/cache/$NAME && while read -r m u g p; do chown $u:$g "./$p" && chmod $m "./$p"; done < .lfc-dirs)
```

**Clone and run** a test (as many clones at once as the disk has room for their changes):

```bash
cp -a --reflink=always $D/cache/$NAME $D/run-1
podman run -d --name <container> -v $D/run-1:/var/lib/postgresql/data:Z ... docker.io/library/postgres:16
```

Data directory paths, users and stop commands for each engine are in [engine-masters.md](engine-masters.md). To keep the master in object storage and branch it without pulling it whole, see [juicefs-branches.md](juicefs-branches.md).

**Throw it away:**

```bash
podman rm -f <container>; rm -rf $D/run-1
```

**Save it**, under a **new name** so you don't change a master other people are cloning, then make it the local cache:

```bash
podman stop -t 60 <container>; podman rm <container>
(cd $D/run-1 && find . \( -type d -o -perm /7000 \) -printf '%m %U %G %P\n' > .lfc-dirs)
rclone sync $D/run-1 az:masters/$NAME-v2 $F --transfers 16 --checkers 16
mv $D/run-1 $D/cache/$NAME-v2
```

Overwrite the same name only for a master that's yours alone: `rclone sync` uploads only the files that changed.

## What to expect

From the tests (Postgres 16, 975 files):

| Step | Result |
|---|---|
| Pull 43 MB, Azure VM in the same region | 2 s (12 s from a laptop; small files dominate, so raise `--transfers`) |
| Clone, 43 MB / 510 MB | under 1.5 s / 0.2 s, about 1 MB of disk |
| Two clones running at once, one changed | independent; the cache is unchanged |
| Save after a small change | 10 of 975 files, 18 MB (one WAL segment and the changed table) |
| Save after updating 1% of rows spread across a 510 MB table | 24 files, 422 MB |
| Fresh pull of a saved copy | starts, with the changes |
| Pull onto a blank, newly attached data disk (Db2, 862 MB, 61 files), `.lfc-dirs` reapplied | 3.4 s; starts and returns all 5M rows |
| Round trip without directory markers | 0 of 12 empty directories back; Postgres won't start |

`rclone` uploads **whole changed files**, not changed blocks. Postgres stores a table in 1 GB segment files, so scattered updates re-upload most of each segment they touch, and every save includes some 16 MB WAL segments. Small, local changes save quickly; wide updates cost close to a full upload.
