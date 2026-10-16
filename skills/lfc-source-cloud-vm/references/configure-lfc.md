# Configure a VM's databases for Lakeflow Connect

Tested end to end on an Azure VM (Ubuntu 24.04, rootful Podman) in the workspace's region: MySQL 8.4, PostgreSQL 16, SQL Server 2022 and Oracle 23ai Free, each with query-based ingestion, plus integrated CDC on SQL Server and MySQL. The SQL for users, grants, seed tables and CDC is the same on every target and lives in **lfc-source-setup**'s engine references; this page covers what's specific to a VM.

## Start the engines ready for CDC

Turn on what CDC needs when the container is created, so no restart is needed later. Publish each engine on a port in `30000-30063`, the range the shared NSG opens (**lfc-source-firewall**):

| Engine | Port | Flags beyond **lfc-source-podman** `references/engines.md` |
|---|---|---|
| MySQL 8.4 | 30001 | server options: `--server-id=1 --log-bin=mysql-bin --binlog-format=ROW --binlog-row-image=FULL --binlog-expire-logs-seconds=172800 --gtid-mode=ON --enforce-gtid-consistency=ON` |
| PostgreSQL 16 | 30002 | server options: `-c wal_level=logical -c max_replication_slots=10 -c max_wal_senders=10 -c max_slot_wal_keep_size=4096` |
| SQL Server 2022 | 30003 | env `MSSQL_AGENT_ENABLED=true` (CDC needs SQL Server Agent) and `MSSQL_PID=Developer` |
| Oracle 23ai Free | 30004 | `docker.io/gvenzl/oracle-free:23`, the full image (`-slim` drops optional components and wasn't tested with CDC); ARCHIVELOG is turned on afterwards with SQL, see engine-oracle.md |

Generate every password on the VM into a root-only directory (`install -d -m 700 /root/lfc-src`, then `umask 077` and `echo "Lfc1$(openssl rand -hex 12)"` per file; SQL Server's container exits on a password without three character classes) and pass it with `--env-file`. To register the UC connection from your laptop, copy only the ingestion user's password file back, into a private file, without printing it: `ssh <vm> 'sudo cat /root/lfc-src/<engine>.lfc.pw' > ~/.lfc-test/src/<engine>.lfc.pw`.

## Users, seeds and CDC

Follow the engine references in **lfc-source-setup**. Run each SQL script inside the container (`podman exec -i <container> <client>`). The admin password stays in the container's environment: `MYSQL_PWD=$MYSQL_ROOT_PASSWORD`, `SQLCMDPASSWORD=$MSSQL_SA_PASSWORD`, `sqlplus / as sysdba`.

| Engine | Ingestion user | CDC setup |
|---|---|---|
| MySQL | `lfc_user`, grants in engine-mysql.md (CDC adds `SELECT ON *.*` and `SELECT (plugin, user) ON mysql.user`) | the binlog flags above |
| PostgreSQL | `lfc_user` with `REPLICATION` | publication and slot per pipeline (engine-postgres.md); gateway CDC must be enabled on the workspace |
| SQL Server | login `lfc_user`, plus a user in the database **and in `master`** | the Lakeflow utility script (engine-sqlserver.md): change tracking for tables with a primary key, CDC for the rest |
| Oracle | `C##LFC_USER`, created by `DBX_ORACLE_SETUP_UTIL` | ARCHIVELOG, supplemental logging and the setup package (engine-oracle.md) |

## Register and check the connections

Register each connection with the **VM's public IP** and the published port (**lfc-source-setup**, step 2). SQL Server and MySQL use self-signed certificates in these images, so add `"trustServerCertificate": "true"`. SQL Server needs it for every query, and MySQL for CDC: query-based ingestion from MySQL works without it, but the CDC extractor fails with `TLS_VALIDATION_FAILURE`. Then check each connection from serverless with the `remote_query` in step 3.

If serverless can't connect (`FAILED_JDBC.CONNECTION`):
1. `nc -z <vm-ip> <port>` from the laptop. If that fails too, the NSG isn't letting traffic in: check the NIC's NSG is the shared one (`az network nic show ... networkSecurityGroup.id`).
2. `sudo ss -ltn | grep 3000` on the VM shows the published ports.
3. For SQL Server, check `trustServerCertificate`.
