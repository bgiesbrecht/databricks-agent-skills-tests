# Per-engine Podman startup details

This file contains detailed startup commands, environment variables, readiness timing, and memory/CPU requirements for each supported database engine.

> **Passwords:** each engine below reads its password from a private env file, never from the command line (where it would show in the process list and in `podman inspect`). Create both files once per engine, for example for MySQL:
>
> ```bash
> umask 077
> echo "Lfc1$(openssl rand -hex 12)" > mysql.pw                                  # for SQL clients (MYSQL_PWD / PGPASSWORD / SQLCMDPASSWORD)
> printf 'MYSQL_ROOT_PASSWORD=%s\n' "$(cat mysql.pw)" > mysql.env   # for podman run --env-file (printf is a shell builtin)
> ```
>
> The variable in each `<engine>.env` file: MySQL `MYSQL_ROOT_PASSWORD`, PostgreSQL `POSTGRES_PASSWORD`, SQL Server `MSSQL_SA_PASSWORD`, Oracle `ORACLE_PASSWORD`, MariaDB `MARIADB_ROOT_PASSWORD`, Db2 `DB2INST1_PASSWORD`. Delete both files when you tear the container down.

## MySQL (8.0, 8.4)

**Environment:**
- `MYSQL_ROOT_PASSWORD` — admin password (required; set securely via password file)

**Volume path:** `/var/lib/mysql`

**CPU/Memory:** 2 CPUs, 2 GiB

**Startup:**

```bash
# Create password file with restricted permissions
umask 077
echo "root_password_here" > mysql.pw

# Run container with password from file
podman run -d \
  --name jane-doe-mysql-8.0-dockerhub-host-local-812 \
  --cpus 2 --memory 2g \
  -p 30001:3306 \
  --env-file mysql.env \
  -v jane-doe-mysql-8.0-dockerhub-host-local-812-data:/var/lib/mysql \
  docker.io/library/mysql:8.0

rm mysql.pw
```

**Readiness:** MySQL accepts TCP connections on port 3306 and responds to `SELECT 1`.

## PostgreSQL (14, 15, 16, 17)

**Environment:**
- `POSTGRES_PASSWORD` — `postgres` user password (required; set securely via password file)
- `POSTGRES_INITDB_ARGS` — init args (optional)

**Volume path:** `/var/lib/postgresql/data`

**CPU/Memory:** 2 CPUs, 2 GiB

**Startup:**

```bash
# Create password file with restricted permissions
umask 077
echo "pg_password_here" > postgres.pw

# Run container with password from file
podman run -d \
  --name jane-doe-pg-16-dockerhub-host-local-812 \
  --cpus 2 --memory 2g \
  -p 30002:5432 \
  --env-file postgres.env \
  -v jane-doe-pg-16-dockerhub-host-local-812-data:/var/lib/postgresql/data \
  docker.io/library/postgres:16

rm postgres.pw
```

**Readiness:** PostgreSQL responds to `pg_isready` health check; verify with `pg_isready -h 127.0.0.1 -p 30002`.

## SQL Server (2017, 2019, 2022, 2025)

> **Unverified:** SQL Server x86_64-only; on macOS Apple Silicon, runs under Rosetta2 in Lima. Empirically confirmed to work; timing notes below.

**Image:** `mcr.microsoft.com/mssql/server:{version}-latest` or specific tag (e.g., `2025-CU7-ubuntu-24.04`)

**Environment:**
- `ACCEPT_EULA=Y` — accept the license (required)
- `MSSQL_SA_PASSWORD` — `sa` password (required; minimum 8 chars, uppercase + digit + symbol)

**Volume path:** `/var/opt/mssql` (database files)

**CPU/Memory:** 4 CPUs, 4 GiB minimum

**Startup:**

```bash
# Create password file with restricted permissions (must meet MSSQL requirements)
umask 077
echo "SqlPassword1" > mssql.pw

# Run container with password from file
podman run -d \
  --name jane-doe-mssql-2022-mcr-host-local-812 \
  --cpus 4 --memory 4g \
  -p 30003:1433 \
  -e ACCEPT_EULA=Y \
  --env-file mssql.env \
  -v jane-doe-mssql-2022-mcr-host-local-812-data:/var/opt/mssql \
  mcr.microsoft.com/mssql/server:2022-latest

rm mssql.pw
```

**Readiness timing:**
- Native amd64 Linux: ~4 s first start, ~90 s timeout
- Rosetta2 (macOS): ~30 s first start, ~300 s timeout (includes Rosetta warmup)

**SQL Server Always On Availability Groups (Podman only):** Setup involves three containers on a shared Podman network: two replicas (primary + secondary) and a Linux-based load-balancer sidecar. Requires network creation, multi-node cluster configuration, and T-SQL setup for availability group membership. Consult the Lakeflow Connect database connectors reference for current support.

## Oracle (18c, 19c, 21c, 23ai, 26ai)

> **Unverified:** Container arch varies by source. First-run database creation can take 5–60 min depending on edition and VM.

**Image source options:**

- **gvenzl (default):** Free/XE editions, no login required
  - 18c, 21c XE: amd64-only; runs under Rosetta2 on macOS
  - 23ai, 26ai Free: arm64 + amd64; uses native arm64 on Apple Silicon

- **oci:** Official Oracle Enterprise/Standard (login required: `podman login container-registry.oracle.com`)
  - Most versions are x86_64-only; 19c Enterprise is ARM64-only
  - First run: 20–60 min (DBCA creates database from scratch)

**Image examples:**
- `docker.io/gvenzl/oracle-xe:21` (gvenzl 21c XE)
- `docker.io/gvenzl/oracle-free:latest` (gvenzl 23ai/26ai Free)
- `container-registry.oracle.com/database/enterprise:19.3.0.0` (OCI 19c Enterprise)

**Environment:**
- `ORACLE_PASSWORD` (gvenzl) or `ORACLE_PWD` (OCI): admin password (required; max 30 bytes for Enterprise)
- `ENABLE_ARCHIVELOG=false` (OCI Enterprise): skip ARCHIVELOG in DBCA

**Extra flags (OCI Enterprise):**
```
--ulimit nofile=1024:65536 --ulimit nproc=2047:16384 \
--ulimit stack=10485760:33554432 --ulimit memlock=3221225472
```

**Volume path:** `/opt/oracle/oradata`

**CPU/Memory:** 2 CPUs, 4 GiB; `--shm-size 3g`

**Startup (gvenzl 26ai Free, arm64 native):**

```bash
# Create password file with restricted permissions
umask 077
echo "OraclePassword1" > oracle.pw

# Run container with password from file
podman run -d \
  --name jane-doe-ora-26ai-gvenzl-host-local-812 \
  --cpus 2 --memory 4g \
  --shm-size 3g \
  -p 30004:1521 \
  --env-file oracle.env \
  -v jane-doe-ora-26ai-gvenzl-host-local-812-data:/opt/oracle/oradata \
  docker.io/gvenzl/oracle-free:latest

rm oracle.pw
```

**Readiness:**
- Fresh start: 5–10 min (arm64 native), 5–60 min (Enterprise DBCA)
- Restart from snapshot: ~30 s

**PDB/CDB names (for UC connection):**
- gvenzl 26ai Free: CDB=`FREE`, PDB=`FREEPDB1`
- gvenzl 21c XE: CDB=`XE`, PDB=`XEPDB1`
- OCI 19c Enterprise: CDB=`ORCLCDB`, PDB=`ORCLPDB1`

## MariaDB (11.4, 11.6)

**Environment:**
- `MARIADB_ROOT_PASSWORD` — root password (required; set securely via password file)

**Volume path:** `/var/lib/mysql`

**CPU/Memory:** 2 CPUs, 2 GiB

**Startup:**

```bash
# Create password file with restricted permissions
umask 077
echo "mariadb_password" > mariadb.pw

# Run container with password from file
podman run -d \
  --name jane-doe-mariadb-11.4-dockerhub-host-local-812 \
  --cpus 2 --memory 2g \
  -p 30005:3306 \
  --env-file mariadb.env \
  -v jane-doe-mariadb-11.4-dockerhub-host-local-812-data:/var/lib/mysql \
  docker.io/library/mariadb:11.4

rm mariadb.pw
```

## MongoDB (7, 8)

> **Unverified:** Lakeflow Connect CDC uses oplog; requires replica set mode.

**Environment:** None required (no password by default)

**Volume path:** `/data/db`

**CPU/Memory:** 2 CPUs, 2 GiB

**Extra flags for CDC:** `--replSet rs0` to enable replica set

**Startup:**

```bash
podman run -d \
  --name jane-doe-mongo-8-dockerhub-host-local-812 \
  --cpus 2 --memory 2g \
  --replSet rs0 \
  -p 30006:27017 \
  -v jane-doe-mongo-8-dockerhub-host-local-812-data:/data/db \
  docker.io/library/mongo:8

# Initialize replica set (one-time after first start)
podman exec jane-doe-mongo-8-dockerhub-host-local-812 \
  mongosh --eval "rs.initiate()"
```

## Db2 (11.5, 12.1)

> **Unverified:** Db2 x86_64-only; on macOS Apple Silicon, runs under Rosetta2. Timing and stability TBD on Apple Silicon.

**Environment:**
- `DB2INST1_PASSWORD` — instance user password (required; set securely via password file)
- `LICENSE=accept` — accept license (required)

**Volume path:** `/database`

**CPU/Memory:** 2 CPUs, 4 GiB minimum

**Startup:**

```bash
# Create password file with restricted permissions
umask 077
echo "Db2Password1" > db2.pw

# Run container with password from file
podman run -d \
  --name jane-doe-db2-11.5-icr-host-local-812 \
  --cpus 2 --memory 4g \
  -p 30007:50000 \
  --env-file db2.env \
  -e LICENSE=accept \
  -v jane-doe-db2-11.5-icr-host-local-812-data:/database \
  icr.io/db2_community/db2:11.5.9.0

rm db2.pw
```

**Readiness:** ~15 min first start (slow initialization); ~60 s restart

## Informix (14.10)

> **Unverified:** Informix x86_64-only; on macOS Apple Silicon, runs under Rosetta2. Timing TBD.

**Environment:**
- `LICENSE=accept` — accept license (required)

**Volume path:** `/opt/informix/data`

**CPU/Memory:** 2 CPUs, 2 GiB minimum

**Startup:**

```bash
podman run -d \
  --name jane-doe-ifx-14.10-icr-host-local-812 \
  --cpus 2 --memory 2g \
  -p 30008:9088 \
  -e LICENSE=accept \
  -v jane-doe-ifx-14.10-icr-host-local-812-data:/opt/informix/data \
  icr.io/informix/informix-developer-database:latest
```

**Readiness:** ~1 min

## CockroachDB (25.x)

> Verified on an Azure VM (amd64, Podman 4.9) with `cockroachdb/cockroach:latest`. Lakeflow Connect has no CockroachDB connector; use it as a Postgres-wire test target.

**Environment:** none. `--insecure` has no passwords; keep the port unpublished, or bound to 127.0.0.1, and use `podman exec`.

**Volume path:** `/cockroach/cockroach-data` (runs as root)

**CPU/Memory:** 2 CPUs, 4 GiB (give `--cache` and `--max-sql-memory` about a quarter of the memory each)

**Startup:**

```bash
podman run -d \
  --name jane-doe-crdb-25-dockerhub-host-local-812 \
  --cpus 2 --memory 4g \
  -p 127.0.0.1:30009:26257 \
  -v jane-doe-crdb-25-dockerhub-host-local-812-data:/cockroach/cockroach-data \
  docker.io/cockroachdb/cockroach:latest start-single-node --insecure --cache=1GiB --max-sql-memory=1GiB
podman exec -i jane-doe-crdb-25-dockerhub-host-local-812 ./cockroach sql --insecure <<< "SELECT 1"
```

**Readiness:** about 3 s.

**Stop:** `podman exec <name> ./cockroach node drain --self --insecure --shutdown`, then `podman stop`. A plain SIGTERM after a large load can take over 120 s and end in SIGKILL.

**Loading:** insert in batches (for example 250,000 rows per `INSERT ... SELECT ... FROM generate_series(...)`); one huge transaction is slow.

## YugabyteDB (2.25, 2025.x)

> Verified on an Azure VM (amd64, Podman 4.9) with `yugabytedb/yugabyte:latest`. Postgres-compatible (YSQL), so the Postgres datagen scripts mostly apply.

**Environment:** none. Without `--secure`, user `yugabyte` has no password; keep the port unpublished, or bound to 127.0.0.1.

**Volume path:** whatever `--base_dir` points at, for example `/yb`. The image runs as **uid 10001** (`yugabyte`, group `users` 100), so a host directory must be owned by 10001.

**CPU/Memory:** 2 CPUs, 4 GiB

**Startup:**

```bash
mkdir -p yb-data && sudo chown 10001:100 yb-data       # or a named volume
podman run -d \
  --name jane-doe-yb-2025-dockerhub-host-local-812 \
  --cpus 2 --memory 4g \
  -p 127.0.0.1:30010:5433 \
  -v $PWD/yb-data:/yb \
  docker.io/yugabytedb/yugabyte:latest \
  bin/yugabyted start --base_dir=/yb --advertise_address=127.0.0.1 --background=false
podman exec -i jane-doe-yb-2025-dockerhub-host-local-812 bin/ysqlsh -h 127.0.0.1 -U yugabyte -c "SELECT 1"
```

- `--background=false` keeps yugabyted in the foreground; without it the container exits.
- `--advertise_address=127.0.0.1` is stored in the data directory. Pin it, so a copy of the directory still starts in another container with a different IP.
- The data directory holds **symlinks** (`data/pg_data`, the log directories); anything that copies it must keep them.

**Readiness:** about 15 s first start, about 6 s restart.
