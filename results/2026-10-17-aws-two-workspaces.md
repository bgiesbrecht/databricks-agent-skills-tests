# 2026-10-17: AWS end to end, two workspaces on one metastore, and five workspace checks

Everything built so far, run again on AWS. The Python fill planner ran on all six engines on the AWS VM. The TPC SF1 masters were checked, the workspace check (`ready.sh`) ran on five workspaces, and the Lakeflow Connect test matrix ran on two AWS FEVM workspaces in us-east-2 that share one metastore: one serverless-only, one with classic compute. Records: `recall.py --run 2026-10-17-aws-two-workspaces --all`.

**Sources:** the AWS test VM (m6i.xlarge, gp3 128 GiB, XFS, rootful Podman). MySQL 8.4, PostgreSQL 16, SQL Server 2022 and Oracle 23ai Free hold the test tables (`intpk`, `dtix`); Db2 11.5 and Informix 14.10 were added for the planner tests. **Connections:** `<firstname><lastname>-<engine>-awsvm`, created once with lfc-connection-sync and visible in both workspaces, plus `-ora-awsvm-pdb` on `FREEPDB1` for Oracle query-based ingestion. The `-ora-awsvm` connection (service `FREE`) is for CDC.

## Lakeflow Connect, by workspace

| Engine | Connection | QBC | QBC via foreign catalog | Integrated CDC | Standard CDC |
|---|---|---|---|---|---|
| MySQL 8.4 | ✅ ✅ | ✅ ✅ 11/11 | ⛔ ⛔ no CREATE CATALOG | ✅ ✅ 11/11 | ⛔ ⛔ not enabled |
| PostgreSQL 16 | ✅ ✅ | ✅ ✅ 11/11 | ⛔ ⛔ no CREATE CATALOG | — (none; the skill stopped) | ⛔ ⛔ not enabled |
| SQL Server 2022 | ✅ ✅ | ✅ ✅ 12/12 | ⛔ ⛔ no CREATE CATALOG | ✅ ✅ 12/12 | ✅ ✅ serverless gateway, 12/12 |
| Oracle 23ai Free | ✅ ✅ | ✅ ✅ 11/11 | ⛔ ⛔ no CREATE CATALOG | ✅ ✅ 11/11 | — (none) |

Each cell gives the serverless-only workspace first, then the classic one. The foreign-catalog batch ran only on the serverless-only workspace; with no `CREATE CATALOG` on the shared metastore, it couldn't pass on the other.

- **What the system picks when `serverless` is left out** (REST, read back with `pipelines get-update`):

  | Pipeline | Classic workspace | Serverless-only workspace |
  |---|---|---|
  | Query-based | ran serverless (`update.config.serverless=true`) | ran serverless (`update.config.serverless=true`) |
  | Gateway | ran classic (`false`, its own cluster) | refused at create: `You must use serverless compute in this workspace.` |
  | Gateway, `serverless: true` | not needed | started |

  `pipelines get` doesn't show the choice; its `spec.serverless` stays unset. This is now the skill's approach: leave it unset, read it back, and flip it when an error asks for it.
- The test sessions themselves set `serverless: true` everywhere, so the SQL Server gateway ran serverless on both workspaces.

## Workspace checks (`ready.sh`)

| Workspace | Serverless | Classic | Target catalog | Blocked by |
|---|---|---|---|---|
| AWS serverless-only | on | none (`list-zones`: no zones in the serverless worker environment) | default, writable, own storage | `CREATE CATALOG` (foreign catalogs) |
| AWS classic | on | available; you can create clusters (admin) | default, writable, own storage | `CREATE CATALOG` |
| GCP serverless | on | can't tell (`list-zones` answer is ambiguous on GCP) | default writable, but on Default Storage: query-based only | CDC needs another catalog |
| Azure classic | on | available (`Azure worker environment does not support zones`) | default, writable, own storage | **`CREATE CONNECTION`** and `CREATE CATALOG` |
| Azure serverless-only | on | none (`does not have any associated worker environment`) | default on Default Storage | **`CREATE CONNECTION`**, `CREATE CATALOG`, no serverless SQL warehouse |

On every workspace the check turned on the Oracle integrated CDC preview, which was off; turning previews on is now its default (`--no-enable` to skip). Without `CREATE CONNECTION`, the two Azure workspaces can't get connections to a source, so their pipeline tests are recorded as blocked. Azure pipeline tests run on another Azure workspace instead.

## Python fill planner on the VM

All six engines reached every target on all six TPC workloads at SF 0.1 (13,035,445 rows, 95 tables each), with Python and the pip drivers on the VM itself. TPC-E took 52 s (SQL Server), 73 s (MySQL), 111 s (Postgres), 261 s (Oracle), 414 s (Informix) and 416 s (Db2).

## TPC SF1 masters

Each master was started from an XFS reflink clone and read with `fill.py status`:
- **Postgres, MySQL and SQL Server:** every table at its target in all six workloads, 109,712,237 rows each.
- **Oracle TPC-E master:** every table at its target, 80,482,507 rows.
- **Oracle B/C/H/DS/DI master:** B, C, H and DS at target. **TPC-DI had 17 of 18 tables:** `DimTime` was never created, because `ddl.py --dialect oracle` wrote a `TIME` column, which Oracle doesn't have. This corrects the earlier [masters write-up](2026-10-17-tpc-sf1-masters.md). `ddl.py` now writes `TIMESTAMP(0)`, and TPC-DI was rebuilt in the AWS master (18/18 tables, 211,319 rows). The Azure Oracle master probably has the same gap.

## What broke, and the fixes

| Problem | Fix |
|---|---|
| The laptop's VPN egress IP changed between sessions (same day), and SSH to the VM timed out | lfc-source-firewall: check the laptop IP at the start of every session and move the `lfc-myip` rules |
| Oracle source didn't open: `ORA-19809`, recovery area full (10 GB of archived logs from CDC tests) | `db_recovery_file_dest_size` raised to 25 GB while mounted (nothing deleted) |
| A `systemd-run --user` job died a few minutes after the SSH call that started it | watch-progress: user units need lingering (`loginctl enable-linger`), or use a system unit |
| `mssql-python` on Linux: `Failed to load the driver` | its ODBC driver needs the OS package `libltdl7`; python-drivers.md |
| Informix: `-458` long transaction aborted, then the root dbspace filled and the server blocked | a data dbspace, 50,000 rows per statement (the new default) |
| Db2's archived logs and dropped Informix dbspaces kept filling the VM's disk | delete Db2's archived logs after a load; remove a dropped dbspace's chunk file |
| `fill.py <engine> <schema> --options status` failed (argparse) | the action can come after the options |
| `ready.sh` called a GCP catalog read-only, but its owner is the workspace's admins group, which you're in | ownership counts groups, `account users`, and the workspace-admins group |
| `ready.sh` couldn't tell serverless-only from classic | `serverless_compute` setting, `list-zones` answers per cloud, the cluster-creation entitlement, and which compute each mode uses |
