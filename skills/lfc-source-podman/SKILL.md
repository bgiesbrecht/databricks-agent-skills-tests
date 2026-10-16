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
limactl start --name lfc-test-podman --arch aarch64 --vm-type vz --rosetta template:podman-rootful
podman system connection add lfc-test-podman "unix://$HOME/.lima/lfc-test-podman/sock/podman.sock"
```

Without `template:podman-rootful` the VM has no Podman and no socket. An existing VM created this way under another name (for example `forgedb-lima-rosetta2-podman`) works the same: use its name.

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

Don't run x86_64-only engines in Podman machine (`podman machine`): its Fedora CoreOS kernel (6.12) crashes SQL Server 2025 with an AVX signal-frame bug and has had Rosetta IPC bugs with Db2. The Lima VM's newer kernel doesn't.

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
| Oracle | `ORACLE` | none; the service (PDB) is given per query or per pipeline, not in the connection | the common user in **uppercase**, for example `C##LFC_USER` |

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

### Delete UC connection

```bash
databricks connections delete --name owner-engine-podman --profile DEFAULT
```

## Common issues

1. **Container name too long:** Names must be ≤ 63 characters. Use a shorter prefix (e.g., `jd` instead of `jane-doe-test`).

2. **Oracle hostname validation:** Oracle may reject underscores in container hostnames. Container names use hyphens only.

3. **The VM's disk fills up**: every row loaded is also written to the engine's change log (MySQL binary logs, Postgres WAL), which CDC needs and so is kept: 25 GB of binary logs filled a 50 GB `podman machine` in testing, and Podman itself then fails (`no space left`). Check with `podman machine ssh df -h /`. Without a CDC reader on the container, purge them (`PURGE BINARY LOGS BEFORE NOW()`, or `SET PERSIST binlog_expire_logs_seconds = 86400`); with one, give the VM more disk (`podman machine init --disk-size`) instead.

3. **Port already in use:** If port `30001` is already bound, pick a free port ≥30000. Check with `podman port {container-name}` or `ss -tlnp | grep 30001`.

4. **Lima VM frozen or unresponsive (macOS):**

   ```bash
   limactl stop lfc-test-podman
   limactl start lfc-test-podman
   ```

5. **SQL Server or Oracle taking > 10 min to start:** Normal for first run. Monitor with `podman logs {container-name}`.

6. **UC connection fails ("Authentication failed"):** Verify the password is correct by connecting directly with SQL client. If direct connection works but UC fails, check that the password in the connection file is exactly the same and has no trailing whitespace.

---

**Ready for Lakeflow Connect?** Once the UC connection is registered, use the **databricks-lakeflow-connect** skill to configure the pipeline, apply pre-flight checks, and start ingestion.
