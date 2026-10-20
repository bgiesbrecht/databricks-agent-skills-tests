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
| [scripts/sqlserver-add-column.sh](scripts/sqlserver-add-column.sh) | When does adding a column to a SQL Server table need a full refresh? Covers tables with and without a primary key, change tracking and CDC, columns with and without defaults, identity and computed columns, and `auto_full_refresh_policy`. `MODE=integrated` runs it on integrated CDC (one pipeline) instead of standard CDC | About 40 minutes per mode |

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
MODE=integrated OUT=/tmp/addcol-result-integrated.md scripts/sqlserver-add-column.sh   # the same on integrated CDC
```

It exits 0 when every claim passed, 1 when one failed, 2 when a prerequisite is missing (nothing is left behind in either case).

## Tables, and the path each covers

| Table | Shape | Storage | Covers |
|---|---|---|---|
| `intpk` | primary key, change tracking | SCD type 1 | the keyed change-tracking path |
| `cdcpk` | primary key, CDC | SCD type 1 | the keyed CDC path |
| `dtix` | no key, CDC, non-unique index on a column whose values repeat | SCD type 1 | the keyless path (keyed on every column) |
| `afrpk` | primary key, change tracking, `auto_full_refresh_policy` on | SCD type 1 | automatic full refresh |
| `scd2pk` | primary key, change tracking | SCD type 2 | the SCD type 2 path |

`APPEND_ONLY` isn't a CDC path: pipeline create refuses it ("APPEND_ONLY can only be used for incremental ingestion of query based connector"). It's covered by the query-based tests.

## What the runs taught

- **On integrated CDC, `dtix` loads 0 rows, with no error,** and a full refresh of it fails the whole update (`INGESTION_GATEWAY_INTERNAL_ERROR`), which stops every later claim. It loads on standard CDC. Narrowed down: a keyless table with no index, or with a unique index, or with a non-unique index whose values are all distinct, loads; one whose non-unique index column has repeated values doesn't. `EXCLUDE_DTIX=1` leaves it out so the other tables' claims run; test it in its own pipeline.
- **Wait for the change, don't sleep.** A fixed wait let updates run before the gateway had the DDL, and two cases looked inline. `settle` runs updates until one errors or the new column shows.
- **Errors are read per table** (`errs_for`): one update can carry several tables' errors.
- **Integrated CDC updates run at least 20 minutes** (smart closure), so the integrated run takes hours; standard CDC takes about 40 minutes.
- **Each result records the runtime** each pipeline ran on (`LFC_RUNTIME`, `bin/lfc-runtime.sh`): the version, the channel and even the CPU architecture can change between updates.
- **Run a uniquely named copy:** bash reads a script as it runs, and overwriting the copy a run is using breaks that run.

## With an agent

Give Isaac (or another coding agent with this repository and a Databricks CLI login) this prompt:

> Re-validate the SQL Server ADD COLUMN FAQ: follow `skills/lfc-schema-change-test/SKILL.md` in rsleedbx/databricks-agent-skills-tests. Use CLI profile `<profile>`, connection `<connection>`, catalog `<catalog>`. Start the test VM and its SQL Server container first and stop the VM afterwards. Report the claim table and anything that differs from the last run.

## After running

Each result also records the Lakeflow runtime every pipeline ran on (DBR version, channel and the image build, from the update's `runtime_details` event). Workspaces on different releases can behave differently, and settings appear, disappear and change between releases. [bin/lfc-runtime.sh](../../bin/lfc-runtime.sh) saves the full list of settings each update ran with on this machine and prints what changed since the last run on that workspace; the run log shows it. Run it yourself on any pipeline: `bin/lfc-runtime.sh <profile> <pipeline-id> [update-id]`.

`SRC_ENV` adds the host OS, the Podman version and the container image with its digest to the result, so a reader can run the same image. Copy them into the run file and the FAQ entry's test section.

Add the claim table as a new run file next to the FAQ entry's `validation.yaml`, update the entry's `## Validation` line and its `last_validated`, and say what changed since the last run.
