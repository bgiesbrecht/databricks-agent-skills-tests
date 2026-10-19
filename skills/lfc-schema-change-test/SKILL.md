---
name: lfc-schema-change-test
description: "Re-run a Lakeflow Connect schema-change test end to end: make a fresh source database, run the DDL, check what the pipeline does (inline, or which full-refresh error), recover, and delete everything. Use to re-validate an FAQ answer about schema evolution, or after a product release. First test: does ADD COLUMN on SQL Server need a full refresh."
parent: lfc-source-setup
---

# Schema-change tests

Each script answers one schema-evolution question by running it: it creates a **fresh database** on a source you control, standard CDC pipelines on serverless, makes the source change, reads back the pipeline's state, error class and destination rows, and prints one PASS or FAIL row per claim. It deletes the pipelines, the schemas and the source database at the end, also on failure (`KEEP=1` keeps them).

Never point these at a shared source: the DDL forces a full refresh on everyone's pipelines that read the table.

| Script | Question | Time |
|---|---|---|
| [scripts/sqlserver-add-column.sh](scripts/sqlserver-add-column.sh) | When does adding a column to a SQL Server table need a full refresh? | About 25 minutes |

## Before running

1. **A SQL Server source you can run DDL on**, reachable from serverless. The tested one is the SQL Server 2022 Podman container on the cloud VM from **lfc-source-cloud-vm**: start the VM and the container, and open the firewall with **lfc-source-firewall** if serverless can't reach it. Stop the VM afterwards.
2. **A UC `SQLSERVER` connection** to that source (**lfc-connection-sync** or **lfc-source-setup**), and the login it uses on the source.
3. **A catalog with its own storage.** CDC refuses Default Storage, and a catalog whose storage credential is broken fails at create ("Azure storage credential was not found"). The script checks for Default Storage before it creates anything.
4. **A command that runs T-SQL on the source as an admin**, reading stdin, first argument the database. For the VM container, [scripts/vm-mssql.sh](scripts/vm-mssql.sh) does it over SSH and keeps the `sa` password on the VM.

## Run

```bash
cd skills/lfc-schema-change-test
export PROFILE=<cli-profile> CONNECTION=<uc-connection> CATALOG=<catalog> CONN_USER=<connection-login>
export SRC_SQL="$PWD/scripts/vm-mssql.sh" SRC_ENV="$PWD/scripts/vm-mssql.sh --env" VM_IP=<vm-ip> MSSQL_CONTAINER=<container-name>
OUT=/tmp/addcol-result.md scripts/sqlserver-add-column.sh
```

It exits 0 when every claim passed, 1 when one failed, 2 when a prerequisite is missing (nothing is left behind in either case).

## With an agent

Give Isaac (or another coding agent with this repository and a Databricks CLI login) this prompt:

> Re-validate the SQL Server ADD COLUMN FAQ: follow `skills/lfc-schema-change-test/SKILL.md` in rsleedbx/databricks-agent-skills-tests. Use CLI profile `<profile>`, connection `<connection>`, catalog `<catalog>`. Start the test VM and its SQL Server container first and stop the VM afterwards. Report the claim table and anything that differs from the last run.

## After running

`SRC_ENV` adds the host OS, the Podman version and the container image with its digest to the result, so a reader can run the same image. Copy them into the run file and the FAQ entry's test section.

Add the claim table as a new run file next to the FAQ entry's `validation.yaml`, update the entry's `## Validation` line and its `last_validated`, and say what changed since the last run.
