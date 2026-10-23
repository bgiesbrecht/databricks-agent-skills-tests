---
name: lfc-schema-change-test
description: "Re-run a Lakeflow Connect schema-change test end to end: make a fresh source database, run the DDL, check what the pipeline does (inline, or which full-refresh error), recover, and delete everything. Use to re-validate an FAQ answer about schema evolution, or after a product release. First test: does ADD COLUMN on SQL Server need a full refresh."
parent: lfc-source-setup
---

# Schema-change tests

Each script answers one schema-evolution question by running it: it creates a **fresh database** on a source you control, standard CDC pipelines on serverless, makes the source change, reads back the pipeline's state, error class and destination rows, and prints one PASS or FAIL row per claim. It deletes the pipelines, the schemas and the source database at the end, also on failure (`KEEP=1` keeps them).

**Test it as a black box.** Treat Lakeflow Connect as a process whose behavior isn't known: change the input (rows and DDL on the source, with known values), read the output (the destination rows; the gateway's staging files in between), and compare. Expectations from the docs or the code are what a run checks, not what it assumes. **State each case as a one-line example of input and output**, not as a description: "`id = 1` set to `i0`, `i1` … `i59`, 2 s apart → SCD type 2 kept all 60 versions; SCD type 1: the gateway staged all 60, the destination shows `i59` (one ingestion update applied them all)". A script prints these as `EXAMPLE` observations. Row-by-row tables (`example` in [scripts/lib.sh](scripts/lib.sh), the result's *Input and output* section) are backing evidence, shown only when the line isn't enough (a gap, an order, a timing).

Never point these at a shared source: the DDL forces a full refresh on everyone's pipelines that read the table.

| Script | Question | Time |
|---|---|---|
| [scripts/sqlserver-add-column.sh](scripts/sqlserver-add-column.sh) | When does adding a column to a SQL Server table need a full refresh? Covers tables with and without a primary key, change tracking and CDC, columns with and without defaults, identity and computed columns, and `auto_full_refresh_policy`. `MODE=integrated` runs it on integrated CDC (one pipeline) instead of standard CDC | About 40 minutes standard, 1–2 hours integrated |
| [scripts/integrated-split-boundary.sh](scripts/integrated-split-boundary.sh) | Does integrated CDC load every row when the snapshot splits on a `DATETIME2(7)` column? Prints rows loaded, the extractor's split plan and the rows in its snapshot file | About 10 minutes |
| [scripts/integrated-scd2-ct.sh](scripts/integrated-scd2-ct.sh) | What does integrated CDC do with `SCD_TYPE_2` on a change-tracking table? Plain inserts, more inserts, then an added column, against SCD type 1 and CDC controls. `SERVER_STATE=1` grants the login `VIEW SERVER STATE` for the run, to show its effect | About 30 minutes |
| [scripts/sqlserver-table-lifecycle.sh](scripts/sqlserver-table-lifecycle.sh) | A table's lifecycle on change tracking and CDC: change data feed on the destination, DELETE every row + INSERT, adding a table to the pipeline, TRUNCATE, DROP and recreate, and the recovery of each | About 1 hour standard, 40 minutes integrated |
| [scripts/sqlserver-cdf.sh](scripts/sqlserver-cdf.sh) | Change data feed on the destination tables: is it on, can `table_changes()` read it (not from version 0), and what an insert, update and delete look like on SCD type 1 and 2 | About 15 minutes |
| [scripts/external-reads.sh](scripts/external-reads.sh) | Who else can read a destination streaming table a test kept (`TABLE=`, after `KEEP=1`): dbt models (table, incremental, a view over `table_changes()`), UniForm properties, credential vending, the Iceberg REST catalog, a Delta Sharing share | About 5 minutes |
| [scripts/sqlserver-ddl-afr.sh](scripts/sqlserver-ddl-afr.sh) | Which DDL needs a full refresh (widen, narrow, rename, drop column, primary key change), on CDC and change tracking, and does `auto_full_refresh_policy` do it on its own | About 40 minutes |
| [scripts/sqlserver-permissions.sh](scripts/sqlserver-permissions.sh) | What the pipeline reports when the login can't read a table or its CDC change table, or the table isn't tracked; do the other tables keep loading; does fixing the source and a full refresh recover | About 30 minutes |
| [scripts/sqlserver-cii-deny.sh](scripts/sqlserver-cii-deny.sh) | On a CDC table, does a column added after the first load need the login's UPDATE on the utility objects' `lakeflowCaptureInstanceInfo`? A row, then ADD COLUMN and a row, with the info table's row and the capture instances printed; `CII_DENY=0` is the control | About 30 minutes |
| [scripts/sqlserver-ct-net-changes.sh](scripts/sqlserver-ct-net-changes.sh) | With a gateway that runs all the time, does a change-tracking table get every update of a row, and is every table read on every poll? `TABLES_N` change-tracking SCD type 2 tables and a CDC control, one row updated every `BURST_GAP` seconds for `BURST_N` rounds on `BUSY_PCT`% of the tables, then 5 updates back to back; the kept versions and the gateway's staging files show how often each table was read | About 25 minutes for 22 tables, longer for 200 |
| [scripts/sqlserver-same-name.sh](scripts/sqlserver-same-name.sh) | Two source tables with the same name in different source schemas (`lfcddemo.orders`, `lfcdb.orders`) in one pipeline: `CASE` maps them to two destination schemas, schema objects, one schema renamed, the legacy publishing mode, one destination table, or two names that are equal once `.` becomes `_`; `TRACK=ct\|cdc`. Each destination must keep only its own source's rows and changes | About 10 minutes a case |
| [scripts/sqlserver-scale.sh](scripts/sqlserver-scale.sh) | Many tables in one pipeline (lfc-faq #7): `COPIES` copies of a TPC model, one schema each, kept and reused between runs; `MODE`, `OBJECTS=schema\|table`, `SF`. With [scripts/vm-throttle.sh](scripts/vm-throttle.sh) `<MiB/s> --cold` before (and `off` after) and `DISK_MBPS`, the same run on a slow source disk | 10 minutes to over an hour, by table count |
| [scripts/sqlserver-migrate.sh](scripts/sqlserver-migrate.sh) | Can a pipeline move between integrated CDC and a gateway and keep its tables: `PART=A` integrated → new gateway, `PART=B` gateway → integrated → back, `PART=C` a second pipeline on the same tables | 10–20 minutes each |
| [scripts/postgres-ddl.sh](scripts/postgres-ddl.sh) | PostgreSQL DDL (`ENGINE=postgres`): nullable and default ADD COLUMN, TOAST-able columns and replica identity, DROP, type changes, rename, primary key, TRUNCATE, parse failures, with and without `auto_full_refresh_policy` | About 40 minutes |

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

### Several runs at once

Most of these tests are low volume, so run them side by side, each on its own source: one SQL Server container per two vCPUs of the VM (check `nproc`, `free -g`, `podman stats --no-stream` and the other sessions' containers first; `vm-mssql.sh --env` gives the disk's IOPS and MB/s). A separate source per run keeps one run's reads from slowing another's, which matters for tests that time the gateway. Make another container and its connection with [lfc-source-cloud-vm `add-mssql-container.sh`](../lfc-source-cloud-vm/scripts/add-mssql-container.sh), then queue the runs:

```bash
cat > slots <<'EOF2'
<connection-1> <container-1>
<connection-2> <container-2>
EOF2
cat > jobs <<'EOF2'
ct22   sqlserver-ct-net-changes.sh
ct200  sqlserver-ct-net-changes.sh TABLES_N=200 BURST_N=30
ct20pc sqlserver-ct-net-changes.sh TABLES_N=200 BURST_N=30 BUSY_PCT=20
EOF2
RUNS=/tmp/ct-runs scripts/parallel.sh slots jobs     # PROFILE, CATALOG, CONN_USER, VM_IP exported as above
```

[scripts/parallel.sh](scripts/parallel.sh) starts each job on the next free source, from its own copy of the scripts, with that source's `CONNECTION`, `MSSQL_CONTAINER` and `SRC_SQL`, and prints a line as each starts and ends. It needs bash 4 or later.

It exits 0 when every claim passed, 1 when one failed, 2 when a prerequisite is missing (nothing is left behind in either case).

## Tables, and the path each covers

| Table | Shape | Storage | Covers |
|---|---|---|---|
| `intpk` | primary key, change tracking | SCD type 1 | the keyed change-tracking path |
| `cdcpk` | primary key, CDC | SCD type 1 | the keyed CDC path |
| `dtix` | no key, CDC, non-unique index on a column whose values repeat | SCD type 1 | the keyless path (keyed on every column) |
| `afrpk` | primary key, change tracking, `auto_full_refresh_policy` on | SCD type 1 | automatic full refresh |
| `scd2pk` | primary key, CDC | SCD type 2 | the SCD type 2 path (`SCD_TYPE_2` needs CDC on SQL Server; see below) |

`APPEND_ONLY` isn't a CDC path: pipeline create refuses it ("APPEND_ONLY can only be used for incremental ingestion of query based connector"). It's covered by the query-based tests.

## What the runs taught

- **Every script sources [scripts/lib.sh](scripts/lib.sh):** fresh database, tracking set up and verified, pipelines in either mode, `update` that follows the pipeline's own retries, the integrated-CDC early stop, per-table errors, cleanup and the result table. A new question is a new short script. `ENGINE=postgres` switches the source steps (publication and slot per pipeline, `vm-psql.sh`).
- **SQL Server's own rules come first.** It refuses `TRUNCATE` on a CDC table (Msg 4711), dropping the primary key a CDC capture uses (Msg 22979) and `sp_rename` of a CDC-captured column (Msg 4928). The documented way is CDC off, the change, CDC on, and that's what the scripts do; the pipeline then reports `INGESTION_GATEWAY_CDC_LOG_TRUNCATED` and needs a full refresh.
- **On change tracking, `TRUNCATE` and DROP + recreate are missed, silently** (lfc-faq #26): the destination keeps the old rows. A full refresh recovers. A recreated CDC table is refused instead (`MANAGED_INGESTION_CANNOT_CHANGE_SOURCE_FOR_EXISTING_DESTINATION_TABLE`): it needs a new destination table, and a full refresh reports COMPLETED without changing the rows.
- **A source step that didn't run looks like a product result.** Two things did that: SSH dropping when the laptop's address changed (the helpers now retry exit 255), and CDC setup failing when several runs set it up at once (`track` now checks `is_tracked_by_cdc` / `sys.change_tracking_tables` and retries). Parallel runs also need their own file per SQL call in the container.
- **A Postgres gateway needs SSL on the source,** though `remote_query` through the same connection works without it: "Authentication failure … The server does not support SSL". For a container, turn on `ssl` with a self-signed certificate and add `"trustServerCertificate": "true"` to the connection. Postgres CDC ran on an AWS workspace (us-west-2) with the source on the Azure VM: its serverless egress ranges go in the VM's NSG.
- **Cleanup decides by the database's name** (it ends in the run's epoch): a function at the end of a pipe (`... | src_db`) runs in a subshell, and a flag it set was lost, so four scripts left their source databases behind while reporting none left.
- **Workspaces gate sources:** "Ingestion source 'POSTGRESQL' is not supported in your workspace" on both modes. Record it and use a workspace that has it.
- **On integrated CDC, a snapshot that splits on a `DATETIME2(7)` column with a nonzero 7th digit loses rows, with no error.** The split's upper bound is the largest value cut to 6 digits, so rows above it are never read: with all values equal, 0 of 10; with distinct values, the last row is missing (9 of 10), with or without a primary key on the column. The snapshot file in the staging volume already has the short count, so it's the read, not the apply. 6-digit or zero 7th digits load. A full refresh of such a table fails the whole update (`INGESTION_GATEWAY_INTERNAL_ERROR`). That's why `dtix` (its `dt` defaults to `SYSUTCDATETIME()`) loads 0 rows on integrated CDC and fine on standard CDC. `EXCLUDE_DTIX=1` leaves it out; `integrated-split-boundary.sh` tests the case on its own.
- **`SCD_TYPE_2` on a change-tracking table is accepted, and integrated CDC holds that table's changes until the next schema change on it,** with no error; standard CDC applied them as SCD type 1. The docs say SCD type 2 needs CDC, so `scd2pk` uses CDC. `integrated-scd2-ct.sh` shows the case.
- **The pipeline starts updates itself.** After a schema change it starts one (cause `SCHEMA_CHANGE`); after a failure, often one more (`RETRY_ON_FAILURE`). While it runs, `start-update` is refused. `update()` joins it and waits until the pipeline is idle. `ERRS` covers every update in that chain, `CHAIN` lists each one's cause and state, and the run log has each error's message, so a failure can be read after cleanup.
- **An empty "Extractor error:" right after a start or a schema change** (`INGESTION_GATEWAY_INTERNAL_ERROR`) usually recovers on the pipeline's own retry. With `PIPELINE_NON_RETRYABLE_ANALYSIS_CLIENT_ERROR`, no retry follows. Both were seen with two or more change-tracking tables; the run carries on with its next update.
- **Don't wait for smart closure.** An integrated update runs 20 minutes or more even with nothing to do. In `MODE=integrated` an update is stopped once it has run 3 minutes and the destination row counts, the CDC staging table's row count and the column count haven't changed for 3 polls (`EARLY_STOP=0` turns this off). For a full refresh it also waits until the extractor has read each refreshed table. A check that still fails after an early stop runs one more update (`expect`): a full refresh's new column sometimes appears only then.
- **Full-refresh only what asks for it:** a table is refreshed only for `CDC_INCOMPATIBLE_SCHEMA_CHANGES.*` or `PRIMARY_KEY_CHANGE`. The hand-off errors of a schema change (`CDC_APPLIER_SCHEMA_CHANGED_DURING_STREAMING`, `FLOW_SCHEMA_CHANGED`) don't need one, and a needless refresh resets an SCD type 2 table's history.
- **Read the staging volume to tell a read loss from an apply loss.** Integrated CDC writes to `__databricks_ingestion_gateway_staging_data-<pipeline-id>` in the destination schema (or in the `data_staging_options` schema):
  - `metadata/general_table_schemas/all_tables.json` maps table names to ids;
  - `snapshot/<id>/<ts>/*.parquet` holds the rows read (columns have encoded names, so count with `read_files`);
  - `snapshot/<id>/qbc_checkpoint/<ts>/offsets/0` holds the split plan.

  It goes when the pipeline is deleted, so read it first. yq on a `.json` file prints quoted strings: use `-r`.
- **Wait for the change, don't sleep.** A fixed wait let updates run before the gateway had the DDL, and two cases looked inline. `settle` runs updates until one errors or the new column shows.
- **Errors are read per table** (`errs_for`): one update can carry several tables' errors.
- **Each result records the runtime** each pipeline ran on (`LFC_RUNTIME`, `bin/lfc-runtime.sh`): the version, the channel and even the CPU architecture (x86 or aarch64) can change between updates. Settings snapshots are kept per pipeline kind, so a run is compared only with the same kind.
- **Run a uniquely named copy:** bash reads a script as it runs, and overwriting the copy a run is using breaks that run.
- **A schema lock on one source table stalls more than that table.** While a session held `BEGIN TRAN; ALTER TABLE ...` open, a different pipeline's integrated CDC "Schema Exploration" waited on it (`lakeflow-connect-infer-schemas:fetch-metadata`, `LCK_M_S`) until the lock ended, and so did the test's own `OBJECT_ID()` on that table. Resolve ids before taking a lock, and don't run other tests on the same server during a lock test.
- **A run from a copy of the scripts needs `LFC_RECORD`** (the path of lfc-test-results `record.py`), `LFC_RUNTIME` and `SCENARIO` (the script's own name), or `record_run` can't find them, or records the copy's file name as the scenario.
- **Without `UPDATE` on `lakeflowCaptureInstanceInfo`, a CDC table stops after an ADD COLUMN, silently:** the gateway can't write `committedCursor` to switch to the new capture instance, so both instances stay and new rows don't arrive (lfc-faq #8). A test login that lacks a utility-object grant can look like a product bug. `sqlserver-cii-deny.sh` claims this stop with `CII_DENY=1` (PASS when the row doesn't arrive) and the arrival with `CII_DENY=0`, and fails setup if the DENY doesn't show in `sys.database_permissions`.
- **A check that can't see its subject must say so, not pass.** A lock holder not found in 60 s, a table version that isn't a number, a dbt `--select` that matched no model (dbt exits 0): each is reported as such, not as "blocked nobody" or "dbt run passed".
- **`external-reads.sh`'s UniForm step changes the kept table for good:** turning on Iceberg compatibility upgrades its protocol, which can't be undone. Run it on a table kept for this test only; `UNIFORM=0` skips the step. The incremental dbt model keys on `id`, plus `__START_AT` on an SCD type 2 table, and the run is recorded with the kept table's pipeline mode (a gateway means standard CDC).
- **A bigger TPC-C SF isn't always a bigger table.** `item` is fixed at 100 K rows and there's one warehouse up to SF 1, so SF 0.1 is only 1.5x SF 0.01 per copy; count the source rows before calling a run "large".
- **A disk limit only shows when the reads outlast it.** Divide the source database's size by the limit: if that read time is small next to the load, the limit changes nothing, so lower it until reads dominate. Drop SQL Server's clean buffers first (`vm-throttle.sh <MiB/s> --cold`), or the reads come from memory. After `off`, `io.max` is empty: that's no limit. The numbers stay in the private results store.
- **Many tables: one setup call, not one per table.** `track` sets up change tracking or CDC on all of a script's tables in one call and checks them in one query; one call per table took about 3 SSH connections a table, and one of 200 tables came out untracked with no error.
- **Write values in sequence when the question is what got through.** `i0`, `i1`, `i2` … on one row show a dropped or merged change as a gap you can read (`i2` then `i12`: `i3` … `i11` merged into one); random or repeated values hide it. Use sequential values and log each one with its source time, so every stage can be compared with what was written.
- **Every result records the same baseline:** the captured tables and their columns in all (`src_shape` in lib.sh, the result's "Test schema" line and the run record). Row counts and the change rate depend on what a test is for, so each script records its own.
- **Pipeline create doesn't check where tables land.** Two source tables mapped to one destination table, or two destination names equal once `.` becomes `_` (`<S>_raw.orders`, `<S>.raw_orders`), are accepted at create and fail at the first update (`CDC_MULTIPLE_SOURCE_TABLES_MAPPED_TO_SAME_DESTINATION_TABLE`; `FLOW_DEFINED_IN_MULTIPLE_DATASETS`, then automatic retries). A script whose question is "is it refused?" runs one update, reads the error and stops the pipeline, rather than following the retry chain (`sqlserver-same-name.sh` `CASE=flowname`).
- **`COLLECT_LIST` doesn't keep a subquery's `ORDER BY`.** Comparing destination rows as one string needs `SORT_ARRAY(COLLECT_LIST(...))`; without it, correct data failed the claim in four runs.
- **Bisect a size threshold with the parallel sources.** Between a size that passes and one that fails, run as many sizes per round as there are sources (`parallel.sh`), splitting the interval evenly, until the failing size is within roughly 10-20%. Go to the exact count only when the code suggests a fixed limit near it, and then test both sides of that limit.
- **Test the busy-table mix, not only "all busy".** In real databases a few tables are hot and the hot set moves with the time of day (OLTP by day, batch at night; lfc-source-statschema "When each table is busy"). `sqlserver-ct-net-changes.sh` `BUSY_PCT=20` updates every fifth table and leaves the rest idle; with all tables busy, one table of 202 was read far less often than the rest and its updates between reads merged.
- **An expected answer can be wrong; the data decides.** On 22 change-tracking tables updated every 2 seconds, every update arrived as its own SCD type 2 version, where the expectation was that some would merge. The claim was turned into an observation.
- **Print what a claim rests on.** A row count suggested which rows arrived, but only printing the ids showed it. Print the ids (or the staging counts) whenever a count alone could be read two ways.

## With an agent

Give Isaac (or another coding agent with this repository and a Databricks CLI login) this prompt:

> Re-validate the SQL Server ADD COLUMN FAQ: follow `skills/lfc-schema-change-test/SKILL.md` in rsleedbx/databricks-agent-skills-tests. Use CLI profile `<profile>`, connection `<connection>`, catalog `<catalog>`. Start the test VM and its SQL Server container first and stop the VM afterwards. Report the claim table and anything that differs from the last run.

## After running

Each result also records the Lakeflow runtime every pipeline ran on (DBR version, channel and the image build, from the update's `runtime_details` event). Workspaces on different releases can behave differently, and settings appear, disappear and change between releases. [bin/lfc-runtime.sh](../../bin/lfc-runtime.sh) saves the full list of settings each update ran with on this machine and prints what changed since the last run on that workspace; the run log shows it. Run it yourself on any pipeline: `bin/lfc-runtime.sh <profile> <pipeline-id> [update-id]`.

`SRC_ENV` adds the host OS, the Podman version and the container image with its digest to the result, so a reader can run the same image. Copy them into the run file and the FAQ entry's test section.

Add the claim table as a new run file next to the FAQ entry's `validation.yaml`, update the entry's `## Validation` line and its `last_validated`, and say what changed since the last run.
