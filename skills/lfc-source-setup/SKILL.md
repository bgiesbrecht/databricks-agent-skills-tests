---
name: lfc-source-setup
description: "Create a source database for Lakeflow Connect testing and demos on AWS (RDS, Aurora), Azure (Flexible Server, Azure SQL, SQL Managed Instance), GCP (Cloud SQL), a cloud VM, or local Podman; configure it for query-based or CDC ingestion; and register the Unity Catalog connection. Use when a Lakeflow Connect test or demo needs a real external database and none exists yet."
---

# Source databases for Lakeflow Connect

Lakeflow Connect needs a source: a SaaS app or a database. This skill and its children create a **database** source in a cloud account (or locally), configure it the way Lakeflow Connect expects, and register the Unity Catalog connection. After that, the **databricks-lakeflow-connect** skill builds the pipeline.

Use it for testing and demos. For a customer's production database, the customer owns the database: use the source-setup sections of **databricks-lakeflow-connect** instead (CDC / change tracking, replication user, grants).

**No Databricks credentials or database are needed for a Lakebase source:** if a Postgres stand-in is enough, use the Lakebase demo in **databricks-lakeflow-connect** (`references/6-lakebase-as-postgres-source.md`). Use this skill when you need SQL Server, MySQL, Oracle, or Postgres with CDC, or a specific managed service.

## Pick the target

| Target | Skill | Engines | Notes |
|---|---|---|---|
| AWS RDS | **lfc-source-aws-rds** | MySQL, PostgreSQL, SQL Server, Oracle | Stop/start supported |
| AWS Aurora | **lfc-source-aws-aurora** | Aurora MySQL, Aurora PostgreSQL | Cluster + writer instance |
| Azure Flexible Server | **lfc-source-azure-flexserver** | MySQL, PostgreSQL | Stop/start supported |
| Azure SQL Database / SQL Managed Instance | **lfc-source-azure-sql** | SQL Server | Change tracking or CDC; MI is slow to create and costly |
| Google Cloud SQL | **lfc-source-gcp-cloudsql** | MySQL, PostgreSQL, SQL Server | Stop/start via activation policy |
| Cloud VM (Azure, GCP) | **lfc-source-cloud-vm** | MySQL, PostgreSQL, SQL Server (native); more via Podman on the VM | Full control of versions and CDC settings |
| Firewall rules for any of the above | **lfc-source-firewall** | — | Laptop IP + workspace serverless egress (+ classic egress when known) |
| Local Podman (Lima on macOS) | **lfc-source-podman** | MySQL, MariaDB, PostgreSQL, SQL Server (incl. Availability Groups), Oracle, Db2, Informix, MongoDB | **Local testing only:** Databricks serverless can't reach a laptop container, and an SSH tunnel doesn't change that. To ingest from Databricks, use a managed service or a cloud VM |

How to choose:

- **The user names a cloud or service:** use it.
- **Otherwise, match the workspace's cloud and region.** Lakeflow Connect reads the whole source on every snapshot and keeps reading for CDC, and that traffic is billed as network egress when it crosses clouds or regions. Find the workspace's cloud and region with `databricks metastores summary --profile <PROFILE> -o json` (`global_metastore_id` is `<cloud>:<region>:<id>`), then prefer a source there: a workspace on Azure means an Azure source, on AWS an AWS source, on GCP a GCP source, in the same region. Say so if the user picks another cloud or region, so they know it adds egress cost.
- **The engine decides it:** Oracle on a managed service means RDS. Db2, Informix, and SQL Server Availability Groups need a cloud VM to be reachable from Databricks (local Podman is for testing the engine setup only).
- **The Lakeflow Connect mode decides it:** CDC needs server settings that some tiers don't allow (for example SQL Server CDC on Azure SQL needs a tier that supports it; Postgres CDC needs logical replication). Each child skill says what its target supports.
- **One source shared by workspaces in many clouds or regions:** some reads will cross clouds whatever you pick, so pick by firewall capacity: an **Azure** VM's NSG can hold every region's serverless ranges (about 760 CIDRs). Put it in the cloud and region of the workspace that reads it most.
- Ask which cloud the user has an account in before creating anything; don't create anything in a cloud they didn't confirm.

Engine-specific database setup (users, grants, change tracking / CDC, replication, binlog) is the same on every target and lives in shared references, which each child skill links to:

| Engine | Reference |
|---|---|
| MySQL, MariaDB | [engine-mysql.md](references/engine-mysql.md) |
| PostgreSQL | [engine-postgres.md](references/engine-postgres.md) |
| SQL Server (incl. Availability Groups) | [engine-sqlserver.md](references/engine-sqlserver.md) |
| Oracle | [engine-oracle.md](references/engine-oracle.md) |
| Db2 | [engine-db2.md](references/engine-db2.md) |
| Informix | [engine-informix.md](references/engine-informix.md) |
| MongoDB | [engine-mongodb.md](references/engine-mongodb.md) |

## Rules for every target

1. **Ask before creating anything.** Cloud databases bill by the hour, and some (SQL Managed Instance, large VMs) cost a lot or take hours to create. Collect every input in one message, list every resource you'll create (server or instance, shared network pieces, firewall rules, parameter groups, the UC connection) with the expected cost class, and wait for one "yes".
2. **Check the cloud login first:** `aws sts get-caller-identity`, `az account show`, or `gcloud config list`. Never pick an account, subscription, or project for the user: show what's active and ask.
3. **Passwords:** generate them into a file (`umask 077; openssl rand -hex 24 > admin.pw`), pass them to the CLI from the file, and never print them or paste them into the conversation. Delete the files once the UC connection exists, and tell the user where any remaining copy is.
4. **Reachability:** the database has to accept your laptop (for setup) and the workspace's serverless egress, plus its classic egress if any part of the pipeline runs on classic compute. Use **lfc-source-firewall** to find those IPs and add them. Open only the database port, never `0.0.0.0/0`, and say what you opened.
5. **Azure resource group:** ask whether the user has a resource group of their own. If not, use the shared test group `forgedb-rg` (check it exists: `az group show -n forgedb-rg`); the user is free to choose a different one. Don't create a resource group without asking. Shared groups can run out of quota: if creation fails with a quota or limit error, ask for another group rather than removing other people's resources.
6. **Tag everything** you create (owner, purpose `lfc-test`, and a creation date), so it can be found and cleaned up later.
7. **Clean up when done**, or tell the user exactly what's still running and billing.
8. **Large test databases (tens of GB and up):** populate once, keep the stopped data directory in object storage in the workspace's cloud and region, and clone it per test on a cloud VM's XFS disk instead of every user loading their own. See **lfc-source-cloud-vm** `references/master-snapshots.md`.
9. **Shell and scripts:** ask every CLI for JSON and turn it into shell variables with `eval "$(<cli> ... -o json | yq -p json -o shell '{"NAME": (.path // "")}')"` (yq quotes the values, so `eval` is safe), not `--query ... -o tsv` or `awk`. Use the simplest tool per step: yq for one-input filters, plain shell for short list loops, and DuckDB SQL files (inputs via `getvariable()`, shared by shell and Python) only for IP-range math, joins across inputs, and ranking. See **shell-json-scripting** for the pattern and gotchas.

## Names

Every name starts from a short owner prefix, so resources from different people never collide:

| Part | Rule | Example |
|---|---|---|
| `<pfx>` | The cloud identity's user name (email without the domain), lowercased, `.` / `_` → `-`, other characters dropped, at most 12 characters (shorten by dropping trailing vowels, then truncate) | `jane-doe` |
| `<service>` | Short engine name: `mysql`, `pg`, `mssql`, `ora`, `mysql-aurora`, `pg-aurora`, `mssql-mi` | `pg` |
| `<epoch>` | Unix seconds when the resource was first created, kept for the resource's lifetime | `1778687039` |

Server and instance names combine these, for example `<pfx>-<service>-<location>-<epoch>`. Each child skill gives the exact pattern its cloud allows (length limits, allowed characters, global uniqueness). Shared network pieces (security groups, subnet groups, parameter groups, firewall rules) use a shared prefix such as `lfc-test` instead of `<pfx>`, so every user reuses them.

The Unity Catalog connection follows the pipeline naming rule in **databricks-lakeflow-connect**: `<firstname><lastname>-<engine>-<target>`, with `-2`, `-3` if taken.

## After the database exists

1. **Configure the engine** for the ingestion mode (engine reference above): the Lakeflow Connect user, grants, and CDC / change tracking / replication where needed.
2. **Register the UC connection** from a request body in a private file, then delete it:

   ```bash
   umask 077
   cat > conn.json <<EOF
   {"name": "<connection>", "connection_type": "<POSTGRESQL|MYSQL|SQLSERVER|ORACLE>",
    "options": {"host": "<host>", "port": "<port>", "user": "<lfc_user>", "password": "$(cat lfc_user.pw)"}}
   EOF
   databricks connections create --json @conn.json --profile <PROFILE> && rm conn.json
   ```

3. **Verify** through the connection with a read-only `remote_query` (see Step 0 of `references/3-query-based-connectors.md` in **databricks-lakeflow-connect**).
4. **Hand off** to **databricks-lakeflow-connect** for the pipeline, its pre-flight checks, and the rows-per-run report.

## Lifecycle

| Action | Where |
|---|---|
| Stop / start (to stop billing compute) | Each child skill; not every target supports it |
| Delete | Each child skill. Delete the UC connection too (`databricks connections delete <connection>`), and drop any Postgres replication slot first |
| Find leftovers | List resources by the owner tag and `<pfx>` in each cloud |

Each child skill is a plain-CLI recipe (`aws`, `az`, `gcloud`, SQL clients, and the Databricks CLI), derived from provisioning logic that's been used to stand up these sources for Lakeflow Connect testing.
