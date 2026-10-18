# SQL Server, query-based ingestion (QBC)

| Setting | Value |
|---|---|
| Workspace | an AWS field demo workspace |
| Connection | an existing SQL Server connection to an Azure SQL Database |
| Source | database chosen in the Source step; schema `lfcddemo`: `intpk` (primary key `pk`, cursor `dt`, SCD type 1) and `dtix` (no key, cursor `dt`, append-only) |
| Pipeline and schema | `janedoe_lfcddemo_azure_sqlserver_<epoch>`, in the default catalog |

The wizard is the same as for PostgreSQL (see [../../postgres/qbc/README.md](../../postgres/qbc/README.md#what-the-wizard-does-seen-2026-10-18)), with these differences.

## Captured runs

Runs are written to `runs/<name>/` (gitignored).

- **2026-10-18, `<name>_1792356311`:** 27 steps, each with red boxes around the field just finished and the next click. One update, completed in 41 s: `intpk` 4.9K rows upserted, `dtix` 5.5K rows, both matching the source. The pipeline was deleted after the capture; no job was created (see below).

## What the wizard does (seen 2026-10-18)

- **The Source step lists every schema in the database**, and a shared demo database has dozens. The search box only filters what's already loaded, and a schema found that way can't be expanded. Scroll the tree to the schema instead (reload the step if a search is stuck: the database name stays in the URL).
- **After a reload, Destination's button reads "Save and continue"** and runs a validation update. With `dtix` still SCD type 1 and no key, that failed ("doesn't have a primary key") before any data moved. Add `scd_type: APPEND_ONLY` in the YAML view first (switching to YAML asks, in a browser dialog, to leave the wizard: accept it), then **Save and run pipeline**.
- **Saving from the YAML view skips the Schedules step**, so no schedule job is created. Add one from the pipeline page (Schedule) if the demo needs it, named like the pipeline.
