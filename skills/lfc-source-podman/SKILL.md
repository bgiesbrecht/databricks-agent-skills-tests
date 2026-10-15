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

**Prerequisites:** Homebrew installed. If missing, see [brew.sh](https://brew.sh).

Install Podman, Lima, and SQL clients:

```bash
brew install podman lima mysql postgresql mongodb-community-shell sqlplus sqlite
```

Create and start the Lima Rosetta2 VM (supports x86_64 containers on Apple Silicon):

```bash
limactl create --name=lfc-test-podman --vm-type=vz --rosetta
limactl start lfc-test-podman
```

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

**Why Lima Rosetta2?**
- Podman on native Apple Silicon (arm64) cannot run x86_64-only engines like SQL Server, Db2, and Informix directly.
- Lima VZ VM with Rosetta2 translation layer provides near-native performance for amd64 containers.
- arm64-native images (most MySQL, PostgreSQL, Oracle) run natively on the host without translation.

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

Once the database is up and configured, register a UC connection for Lakeflow Connect. Use a temporary `conn.json` file with restricted permissions and delete it immediately after creation.

**Create the UC connection (PostgreSQL example):**

```bash
# Create connection file with restricted permissions
umask 077
cat > conn.json <<'EOF'
{
  "name": "owner-postgres-podman",
  "connection_type": "POSTGRESQL",
  "options": {
    "host": "127.0.0.1",
    "port": "30002",
    "user": "lfc_user",
    "password": "lfc_user_password"
  }
}
EOF

# Create the connection
databricks connections create --json @conn.json --profile DEFAULT

# Delete the temporary file immediately
rm conn.json
```

Replace `POSTGRESQL` with `MYSQL`, `SQLSERVER`, `ORACLE`, etc. as needed. Update the `port` to match your container and the `password` to the LFC user's password.

**Verify the connection:**

```bash
databricks connections test --name owner-postgres-podman --profile DEFAULT
```

The UC connection is now registered and ready for Lakeflow Connect pipelines.

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
