---
name: lfc-source-podman
description: "Run source databases locally in Podman containers (Lima VM on macOS, native on Linux). Covers setup, 8 database engines (MySQL, MariaDB, PostgreSQL, SQL Server, Oracle, Db2, Informix, MongoDB), networking for local testing, and UC connection registration."
parent: lfc-source-setup
---

# Source database in local Podman (Lima on macOS, native on Linux)

Local Podman containers provide fast iteration for Lakeflow Connect development and demos. This skill sets up databases on your laptop or Linux machine, configures them for testing, and registers the Unity Catalog connection.

**Reachability limitation:** Local Podman databases **cannot** be reached from Databricks serverless compute by default. Laptop containers are isolated by design (gvproxy on macOS, firewall on Linux). Use this skill for **local testing only**. For Lakeflow Connect to access a database from Databricks, use a **cloud-managed** service or place the database on a public cloud VM with firewall rules.

If you need SQL Server Always On Availability Groups, Db2, Informix, or specific open-source engine versions not in managed services, Podman is the fastest way to get them running for local testing.

## Setup

### macOS

**Tools:** Podman, Lima, and the SQL clients; see **lfc-source-setup** "Tools" (`bash scripts/check-tools.sh local` and `clients` there). In short:

```bash
brew install podman lima libpq mysql-client sqlcmd mongosh
export PATH="$(brew --prefix libpq)/bin:$(brew --prefix mysql-client)/bin:$PATH"     # both are keg-only
```

Oracle's `sqlplus` isn't in Homebrew: use the one inside the container (`podman exec -it <container> sqlplus ...`).

Create and start the Lima VM with Rosetta and the rootful Podman template (it runs arm64 images natively and x86_64-only images under Rosetta), then register its Podman socket:

```bash
limactl start --tty=false --name lfc-test-podman --arch aarch64 --vm-type vz --rosetta --cpus 4 --memory 10 --disk 60 template:podman-rootful
podman system connection add lfc-test-podman "unix://$HOME/.lima/lfc-test-podman/sock/podman.sock"
```

Size it for what runs at once: SQL Server and Oracle take 4 GB each (`--memory 10` holds both plus a small engine; the default is 4 GiB). `--tty=false` skips the interactive confirmation, for scripts and agents. Tested (macOS 26, Apple Silicon, Lima 2.1): the VM starts in 44 s, rootful Podman on Fedora 44 with kernel 6.19 and Rosetta registered (`/proc/sys/fs/binfmt_misc/rosetta`). Container ports bound in the VM (`-p 30003:1433`) are forwarded to the Mac's `127.0.0.1` with nothing more to set up.

You don't need Podman Desktop for any of this. If it's installed, remove it first: it starts its own `podman machine` VM next to Lima, whose disk keeps growing (**podman-desktop-remove**).

Without `template:podman-rootful` the VM has no Podman and no socket. Don't assume an existing VM has it: `forgedb-lima-rosetta2-podman`, an Ubuntu 25.10 VM, had none, and no Rosetta registered (2026-10-21). [`scripts/ensure-lima-podman.sh <instance>`](scripts/ensure-lima-podman.sh) makes any Lima VM ready: it starts the instance (or creates it with the command above, `--create`), installs Podman with `apt-get` or `dnf` if it's missing, and checks rootful Podman and Rosetta. It prints one line per step (`PASS`, `FIXED`, `FAIL`, `WARN`). Scripts then run containers as the login user, with plain `podman`.

**Rootless, so scripts need no `sudo`.** None of the test containers need root: their ports are above 1024 and none is privileged. [`scripts/ensure-podman-rootless.sh --on "<prefix>"`](scripts/ensure-podman-rootless.sh) prepares any Linux host once, on a cloud VM (`--on "ssh <user>@<vm>"`) or in Lima (`--on "limactl shell <instance> --"`). It's the only place `sudo` is used:
- **Subordinate user and group IDs** for the user (`/etc/subuid`, `/etc/subgid`), which rootless containers map users to. Ubuntu cloud images and Lima have them.
- **Linger** (`loginctl enable-linger`). Without it, systemd stops a rootless user's containers when the user's last session ends, and a script that drives the host over many short `ssh` or `limactl` sessions loses them. The Azure test VM had it off.
- **`~/.cache` owned by the user.** Earlier rootful runs had left 5 root-owned files there.
- **Checks:** a rootless container runs, and container names resolve on a Podman network.

Files that a container writes into a mounted directory belong to the container's mapped user, so remove them with `podman unshare rm -rf <dir>`, not `sudo`. Rootless and rootful containers live in separate stores: `podman ps` doesn't show containers started with `sudo podman`, so remove old rootful ones with `sudo podman`.

Verify:

```bash
podman --connection lfc-test-podman info
limactl list
```

To resize the VM (e.g., after a RAM upgrade):

```bash
limactl stop lfc-test-podman
limactl delete lfc-test-podman
# Edit ~/.lima/lfc-test-podman/lima.yaml to adjust cpus + memory, then re-create
```

**Which image runs how on Apple Silicon.** Every engine runs in the Lima VM. Use the arm64 image wherever one exists, and Rosetta only for x86_64-only images:

| Engine | Image on macOS | Runs as |
|---|---|---|
| PostgreSQL, MySQL, MariaDB, MongoDB | Docker Hub official images | arm64, native |
| Oracle 23ai / 26ai Free | `docker.io/gvenzl/oracle-free:latest` (default), or `container-registry.oracle.com/database/free:latest` | arm64, native |
| Oracle 19c Enterprise | `container-registry.oracle.com/database/enterprise:19.19.0.0` (needs `podman login`) | arm64, native |
| Oracle 18c / 21c XE | `docker.io/gvenzl/oracle-xe:18` / `:21` | x86_64, Rosetta |
| SQL Server 2017–2025 | `mcr.microsoft.com/mssql/server:<version>-latest` | x86_64, Rosetta (2025 needs a Lima kernel of 6.17 or later) |
| Db2, Informix | `icr.io` images | x86_64, Rosetta |

**Register Rosetta with the preserve-argv0 flag** (`P`), once per VM. Lima registers it with `OCF`, which drops a program's `argv[0]`: then `su -` in an x86_64 container isn't a login shell, never reads the user's profile, and Db2's setup (which runs everything through `su - db2inst1`) fails with `db2: command not found`. Check `grep flags /proc/sys/fs/binfmt_misc/rosetta` in the VM (`limactl shell lfc-test-podman`); to fix it at every boot, add this to `~/.lima/lfc-test-podman/lima.yaml` and restart the VM (`limactl stop` / `start`). Tested: `flags: POCF` after the restart, and Db2 then set up cleanly.

```yaml
provision:
- mode: system
  script: |
    #!/bin/bash
    f=/proc/sys/fs/binfmt_misc/rosetta
    for i in $(seq 30); do [ -e $f ] && break; sleep 1; done
    [ -e $f ] && ! grep -q "flags: P" $f || exit 0
    M=$(awk '/^magic/ {print $2}' $f); K=$(awk '/^mask/ {print $2}' $f); I=$(awk '/^interpreter/ {print $2}' $f)
    hex() { echo "$1" | sed 's/../\\x&/g'; }
    echo -1 > $f
    printf ':rosetta:M::%s:%s:%s:POCF' "$(hex $M)" "$(hex $K)" "$I" > /proc/sys/fs/binfmt_misc/register
```

**Tested together** on a MacBook (Apple Silicon, 32 GB) in one 4-CPU, 10 GiB Lima VM: SQL Server 2022, Db2 11.5 and Informix 14.10 under Rosetta and Oracle 26ai Free on arm64 side by side, each reached from the Mac on `127.0.0.1`, and each filled with TPC-H SF 1 (8,660,030 rows) inside the database by **lfc-source-datagen**: SQL Server in 202 s (as fast as a 4-vCPU Azure VM: 179 s), Oracle in 320 s.

Don't run x86_64-only engines in Podman machine (`podman machine`): its Fedora CoreOS kernel (6.12) crashes SQL Server 2025 with an AVX signal-frame bug, and Podman is deprecating its Rosetta support. The Lima VM's newer kernel doesn't have these bugs, and Lima keeps Rosetta: running SQL Server on macOS is the same as running its container in Podman on Lima.

### Linux

**Prerequisites:** sudo access for one-time userspace networking setup.

Install Podman if missing:

```bash
sudo apt update && sudo apt install -y podman uidmap slirp4netns
sudo usermod -a -G podman $(whoami)
newgrp podman
```

Podman connects natively over the unix socket; no VM or SSH tunnel is needed.

## Naming

Container and volume names follow a pattern to avoid collisions and stay under Podman/DNS limits:

```
{prefix}-{engine-short}-{version}-{source}-{target}-{epoch}
```

| Component | Rule | Example |
|-----------|------|---------|
| `{prefix}` | OS user (normalized: lowercase, `.`/`_` → `-`, max 12 chars) | `jane-doe` |
| `{engine-short}` | 2–4 letter engine ID | `mysql`, `pg`, `mssql`, `ora`, `db2`, `ifx` |
| `{version}` | Major version | `8.0`, `16`, `2022`, `21c` |
| `{source}` | Registry short name | `dockerhub`, `mcr`, `gvenzl`, `oci`, `icr` |
| `{target}` | Deployment target | `host-local` |
| `{epoch}` | Unix timestamp (or `812` for tests) | `1778687039` |

**Maximum length: 63 characters.** Use a shorter prefix if needed (e.g., `jd` instead of `jane-doe-test`).

Data volume appends `-data`: e.g., `jane-doe-mysql-8.0-dockerhub-host-local-812-data`.

## Running containers

**General process for any engine:**

1. **Pull the image** (one-time, cached)
2. **Create and run the container** with:
   - A data volume (persistent across restarts)
   - Port binding (default engine port → a free host port ≥30000)
   - Environment variables (admin password, replication mode, etc.) via `umask 077` + password file
3. **Wait for readiness** (engine startup + initialization)
4. **Configure** (LFC user, grants, CDC, etc.)

**Supported engines:**

| Engine | Version(s) | Default Port | Image | Reference |
|--------|-----------|---|---|---|
| MySQL | 8.0, 8.4 | 3306 | `docker.io/library/mysql:{version}` | [engines.md](references/engines.md) |
| PostgreSQL | 14, 15, 16, 17 | 5432 | `docker.io/library/postgres:{version}` | [engines.md](references/engines.md) |
| SQL Server | 2017, 2019, 2022, 2025 | 1433 | `mcr.microsoft.com/mssql/server:{version}-latest` | [engines.md](references/engines.md) |
| Oracle | 18c, 19c, 21c, 23ai, 26ai | 1521 | `docker.io/gvenzl/oracle-*` or `container-registry.oracle.com/database/*` | [engines.md](references/engines.md) |
| MariaDB | 11.4, 11.6 | 3306 | `docker.io/library/mariadb:{version}` | [engines.md](references/engines.md) |
| MongoDB | 7, 8 | 27017 | `docker.io/library/mongo:{version}` | [engines.md](references/engines.md) |
| Db2 | 11.5, 12.1 | 50000 | `icr.io/db2_community/db2:{version}` | [engines.md](references/engines.md) |
| Informix | 14.10 | 9088 | `icr.io/informix/informix-developer-database:latest` | [engines.md](references/engines.md) |

For per-engine startup commands, environment variables, readiness timing, and memory/CPU requirements, see [references/engines.md](references/engines.md).

**Container registries:**

| Source | Engines | Requires login | Notes |
|--------|---------|---|---|
| `dockerhub` | MySQL, MariaDB, PostgreSQL, MongoDB | No | Official Docker Hub images |
| `mcr` | SQL Server | No | Microsoft Container Registry |
| `gvenzl` | Oracle (default) | No | Community Free/XE; no license agreement |
| `oci` | Oracle (optional) | Yes | Official Enterprise/Standard; requires `podman login container-registry.oracle.com` |
| `icr` | Db2, Informix | No | IBM Container Registry |

## Reusable master database (local storage)

Load a large test database once, keep the stopped data directory as a master, and clone it for each test instead of reloading it. Locally, the master stays on the Podman VM's own disk: no object storage, no rclone. (For cloud VMs shared by several people, keep masters in object storage instead: see **lfc-source-cloud-vm** `references/master-snapshots.md`.)

Run these inside the Podman VM as root: `podman machine ssh 'sudo bash -s' < steps.sh` (Podman machine) or `limactl shell lfc-test-podman sudo bash -s < steps.sh` (Lima).

```bash
D=/var/lib/lfc-data; NAME=<master-name>        # for example pg16-orders
findmnt -no FSTYPE --target /var                # xfs: clones are instant; ext4: --reflink=auto makes full copies
mkdir -p $D/masters
# Master: run the database with its data directory at $D/masters/$NAME, load it, then stop it cleanly
podman stop -t 60 <container>; podman rm <container>
# Each test: clone, run
cp -a --reflink=auto $D/masters/$NAME $D/run-1
podman run -d --name <container> -v $D/run-1:/var/lib/postgresql/data:Z ... docker.io/library/postgres:16
```

When the test is done, stop the container (`podman stop -t 60 <container>; podman rm <container>`), then either throw the clone away (`rm -rf $D/run-1`) or keep it as a new master (`mv $D/run-1 $D/masters/$NAME-v2`).

- **Clone speed depends on the VM's filesystem.** Podman machine on macOS (Fedora CoreOS) has an XFS `/var` with reflinks: a 510 MB Postgres master cloned in 0.03 s. Lima's default disk is ext4, so `--reflink=auto` falls back to a full copy.
- **Keep the master and its clones on the same filesystem** (both under `$D`). Reflinks can't cross filesystems; `/tmp` is tmpfs on Podman machine.
- **Always stop the database cleanly** before cloning, keeping, or deleting its files.
- Use `:Z` on the volume: Podman machine enforces SELinux, and without it the database can't open its data directory.

## Configure the database for LFC

LFC requires:
- An LFC-specific user with SELECT + network access
- Replication settings (binlog/WAL/CT/CDC) per engine
- Optional audit tables

**See the Lakeflow Connect reference guide (2-database-connectors.md) for engine-specific configuration details.** The guides cover binlog setup (MySQL/MariaDB), logical replication (PostgreSQL), change tracking (SQL Server), and read-only user setup for query-based connectors (Oracle, Db2, Informix, MongoDB).

**Podman-specific notes:**

- **Container hostname:** SQL clients use `127.0.0.1:<published-port>` (e.g., `30001`).
- **Connect from another container:** Use `{container-name}:{internal-port}` (e.g., `jane-doe-mysql-8.0-dockerhub-host-local-812:3306`).

## Register the Unity Catalog connection

A UC connection on a laptop container is only useful for checking the request body: Databricks serverless can't reach `127.0.0.1` or a laptop's port. To ingest, run the same containers on a cloud VM in the workspace's region (**lfc-source-cloud-vm**), open the published ports to serverless (**lfc-source-firewall**), and register the connection with the VM's public IP, as **lfc-source-setup** "After the database exists" shows. Per engine:

| Engine | `connection_type` | Options beyond `host`, `port`, `user`, `password` | User |
|---|---|---|---|
| MySQL | `MYSQL` | none | `lfc_user` |
| PostgreSQL | `POSTGRESQL` | none | `lfc_user` |
| SQL Server | `SQLSERVER` | `"trustServerCertificate": "true"`: the container's certificate is self-signed, and without it serverless fails with `FAILED_JDBC.CONNECTION` | `lfc_user` |
| Oracle | `ORACLE` | `"service_name"`: the CDB's service (`FREE` for `gvenzl/oracle-free`), needed by CDC; pipelines name the PDB in `source_catalog`. For SQL on the PDB through a connection, a second connection with `service_name` `FREEPDB1` | the common user in **uppercase**, for example `C##LFC_USER` |

There is no `databricks connections test`. Verify with a read-only `remote_query` from serverless (**lfc-source-setup**, step 3).

## Lifecycle

### Stop and restart

```bash
podman stop {container-name}
podman start {container-name}
```

The volume persists; the database restarts with the same data.

### Snapshot: export a volume for reuse

```bash
# Export volume to a tar file
podman volume export {volume-name} > {backup-name}.tar

# Later: import into a new volume
podman volume create {new-volume-name}
podman volume import {new-volume-name} {backup-name}.tar
```

### Teardown: remove container and volume

```bash
podman rm {container-name}
podman volume rm {volume-name}
```

All data is lost. To keep the database but remove the container, omit the volume remove step and re-use the volume later.

### Remove the VM, and get the laptop's disk back

The VM's disk is one file on the laptop: `podman machine` keeps it under `~/.local/share/containers/podman/machine/<provider>/` (for example `podman-machine-default-arm64.raw`), Lima under `~/.lima/<name>/`. It's sparse, so it grows as the databases inside it write, and it **doesn't shrink** when you drop tables or containers in the VM. Check how much it really takes with `du -h <image>`, not `ls -l`. To give the space back, remove the whole VM, in this order:

```bash
podman machine stop && podman machine rm          # or: limactl stop lfc-test-podman && limactl delete lfc-test-podman
df -h /                                            # the space is back once the VM process has exited
```

**Never delete those folders while the VM runs.** A running VM keeps its disk file open: deleting it doesn't free the space, the VM goes on writing to it, and no folder shows it any more, so the disk fills while `du` finds nothing big. Seen in practice: `rm -rf ~/.local/share/containers` with the machine running left a 50 GB image held open by Apple's virtualization service; the laptop ran out of space repeatedly over a day, and stopping the VM gave back about 55 GB. With the files gone, `podman machine stop` can't reach the VM (`failed to read identity ... machine: no such file or directory`), so find it and stop its processes:

```bash
lsof +L1 -nP 2>/dev/null | grep -iE '\.raw|\.img|podman|lima'                 # deleted files still open, with the pid
for p in $(pgrep -f 'Virtualization.VirtualMachine'); do lsof -nP -p $p | grep -E '\.raw|\.img'; done
pgrep -fl 'vfkit|krunkit|gvproxy|qemu|limactl'                                  # the VM's own processes
kill <vfkit-or-krunkit-pid> <gvproxy-pid>                                       # Lima: limactl stop --force <name>
```

Watch the result with `df -k /` a minute apart: the space comes back as the virtualization service exits, sometimes in two steps.

### Delete UC connection

```bash
databricks connections delete --name owner-engine-podman --profile DEFAULT
```

## Common issues

1. **Container name too long:** Names must be ≤ 63 characters. Use a shorter prefix (e.g., `jd` instead of `jane-doe-test`).

2. **Oracle hostname validation:** Oracle may reject underscores in container hostnames. Container names use hyphens only.

3. **The VM's disk fills up**: every row loaded is also written to the engine's change log (MySQL binary logs, Postgres WAL), which CDC needs and so is kept: 25 GB of binary logs filled a 50 GB `podman machine` in testing, and Podman itself then fails (`no space left`). Check with `podman machine ssh df -h /`. Without a CDC reader on the container, purge them (`PURGE BINARY LOGS BEFORE NOW()`, or `SET PERSIST binlog_expire_logs_seconds = 86400`); with one, give the VM more disk (`podman machine init --disk-size`) instead.

4. **Port already in use:** If port `30001` is already bound, pick a free port ≥30000. Check with `podman port {container-name}` or `ss -tlnp | grep 30001`.

5. **Lima VM frozen or unresponsive (macOS):**

   ```bash
   limactl stop lfc-test-podman
   limactl start lfc-test-podman
   ```

6. **SQL Server or Oracle taking > 10 min to start:** Normal for first run. Monitor with `podman logs {container-name}`.

7. **UC connection fails ("Authentication failed"):** Verify the password is correct by connecting directly with SQL client. If direct connection works but UC fails, check that the password in the connection file is exactly the same and has no trailing whitespace.

---

**Ready for Lakeflow Connect?** Once the UC connection is registered, use the **databricks-lakeflow-connect** skill to configure the pipeline, apply pre-flight checks, and start ingestion.

8. **The laptop's disk keeps filling, and nothing big shows up:** a VM whose disk file was deleted while it ran is still writing to it. See [Remove the VM, and get the laptop's disk back](#remove-the-vm-and-get-the-laptops-disk-back). If Podman Desktop is installed, it may have started a VM you didn't: **podman-desktop-remove** reports every machine and its disk use.
