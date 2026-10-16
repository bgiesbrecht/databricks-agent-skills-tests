# Four engines on a cloud VM: connections, query-based and CDC, 2026-10-16

Azure serverless-only workspace (centralus). Sources in Podman on an Azure VM in the same region (Standard_D4s_v5, XFS data disk), reached through the shared NSG (ports 30000-30063, laptop + centralus serverless ranges): MySQL 8.4, PostgreSQL 16, SQL Server 2022 Developer, Oracle 23ai Free (`gvenzl/oracle-free:23`, now 26ai Free 23.26). Query-based targets on a Default Storage catalog; CDC targets on a catalog with its own managed storage. Records: `recall.py --run 2026-10-16-azvm-four-engines --all`.

| Engine | Source setup | UC connection | Query-based | Integrated CDC | Standard CDC |
|---|---|---|---|---|---|
| MySQL 8.4 | ✅ | ✅ | ✅ 10/10, then 15 (3 updated) / 16 | ✅ 10/10, then 11/11 | ⛔ not enabled on the workspace |
| PostgreSQL 16 | ✅ | ✅ | ✅ same | — no integrated mode | ⛔ not enabled on the workspace |
| SQL Server 2022 | ✅ | ✅ | ✅ same | ✅ change tracking + CDC tables | ✅ serverless gateway + applier |
| Oracle 23ai Free | ✅ | ✅ | ✅ same | ✅ after the workspace enabled it | — no standard mode |

Query-based: `intpk` SCD_TYPE_1 (key `pk`, cursor `dt`), `dtix` (no key) APPEND_ONLY; between runs 5 inserts into each, 3 updates of `intpk`, 1 of `dtix`. CDC: both tables SCD_TYPE_1; after the snapshot 3 inserts, 2 updates, 2 deletes in each, all applied, including the table without a primary key.

## How it was run

1. With the skills as they were; every failure was fixed in the skill.
2. Torn down and repeated from scratch: every source-setup statement extracted verbatim from the engine references and run as is. That found more doc defects (below), which were fixed and rerun.
3. After a data disk swap ([disk restore](2026-10-16-disk-restore.md)), rebuilt again from the corrected references: no errors, no patches. Integrated and standard CDC ran on this build.

An agent-run repeat (a separate session told to follow only the skills) didn't follow the run instructions and reported defects that weren't real (its pipeline had been created without the cursor settings it said the API dropped). It was discarded.

## What broke, and the skill fix

| Symptom | Cause | Fixed in |
|---|---|---|
| `FAILED_JDBC.CONNECTION` from serverless, laptop also blocked | `az network nic update --network-security-group <name>` exited 0 but left the VM's own NSG attached | lfc-source-firewall azure.md: attach by ID, check it |
| 0 missing firewall rules | `WANT` never set | lfc-source-firewall: guard |
| SQL Server: `FAILED_JDBC.CONNECTION` | self-signed certificate | `trustServerCertificate: true` (lfc-source-setup, query-based reference) |
| MySQL CDC: `Extractor FAILED ... TLS_VALIDATION_FAILURE` | same, enforced only by the CDC extractor | same, via `connections update` |
| Oracle CDC: `Missing service_name option in the connection` | connection had no service | `service_name` = the CDB's service (`FREE`); the listener doesn't serve the docs' `CDB$ROOT` |
| CDC create: `Default Storage for Unity Catalog is not supported` | Default Storage catalog | already in the skill; check before CDC |
| CDC create: `Azure storage credential was not found` | catalog with a broken credential | noted in the skill |
| MySQL integrated CDC on serverless | docs say classic only; the workspace forces serverless and it worked | 2-database-connectors.md |
| Classic gateway: `You must use serverless compute in this workspace` | serverless-only workspace | `serverless: true` on the gateway works |
| SQL Server container exits | `openssl rand -hex` password has only two character classes | every skill: `Lfc1` + hex |
| Updates never arrive (query-based), would have | seed cursor `dt` not bumped on update; SQL Server `dt` nullable | engine references: NOT NULL + update trigger |
| Postgres / SQL Server setup SQL fails | no CREATE DATABASE step | engine references |
| Oracle supplemental logging silently skipped | Oracle 23 rejects a comment after `;` (`ORA-03405`); `VALIDATE_SETUP` still printed "passed" | engine-oracle.md |
| Utility script warnings in SQL Server | ingestion user has no user in `master` | engine-sqlserver.md |
| `databricks connections test` | the command doesn't exist | lfc-source-podman |
