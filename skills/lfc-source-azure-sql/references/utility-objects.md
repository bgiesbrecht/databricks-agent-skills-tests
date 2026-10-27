# The utility objects script: when it's needed, what it adds, how to remove it

Tested 2026-10-26 on Azure SQL Database (serverless GP_S_Gen5_1) and Azure SQL Managed Instance (General Purpose, 4 vCores), with the published utility script 1.7, integrated CDC on serverless. Schema-change outcomes per case: **lfc-schema-change-test** `references/ddl-matrix-results.md`.

## When it's needed

| Tables read through | Utility script | What the pipeline does |
|---|---|---|
| Change tracking (table has a primary key) | Not installed: CT and grants done by hand | Loads; a validate-only update completes; schema changes are detected the same way as with the script |
| Change tracking | Installed, with or without `@CreateDdlSupportingObjects = 1` | The same: CT schema changes are found from the source's column metadata, not from the DDL audit table |
| CDC (keyed or keyless) | Not installed (CDC enabled with `sys.sp_cdc_enable_table`) | The first update fails at once: `INGESTION_GATEWAY_DDL_OBJECTS_MISSING`, then `SNAPSHOT_FAILED_DUE_TO_CDC_FAILURE` and `INTEGRATED_CDC_ALL_SOURCE_TABLES_FATALLY_FAILED`; nothing loads |
| CDC and CT tables in one database | CDC objects removed by `CLEANUP` | Every table fails with `INGESTION_GATEWAY_DDL_OBJECTS_MISSING`, the CT tables too |

Grants that were enough for change tracking without the script: `SELECT` and `VIEW CHANGE TRACKING` on each table, `VIEW DEFINITION`, `VIEW DATABASE STATE`.

## What it adds

| Step | Objects |
|---|---|
| Install the script | 3 functions (`lakeflowDetectPlatform`, `lakeflowUtilityVersion`, `lakeflowVersionComponent`) and 3 procedures (`lakeflowFixPermissions`, `lakeflowSetupChangeTracking`, `lakeflowSetupChangeDataCapture`) in `dbo`; CT and CDC stay off |
| `lakeflowSetupChangeTracking` | CT on the database and on each table with a primary key; `VIEW CHANGE TRACKING` and `VIEW DEFINITION` for the user. With `@CreateDdlSupportingObjects = 1` also `dbo.lakeflowDdlAudit_<v>` (CT on) and the database trigger `lakeflowDdlAuditTrigger_<v>` |
| `lakeflowSetupChangeDataCapture` | CDC on the database (the `cdc` schema and user, `tr_MScdc_ddl_event`; on MI also the msdb jobs `cdc.<db>_capture` and `cdc.<db>_cleanup`), a capture instance `lakeflow_<schema>_<table>_1` per table, `dbo.lakeflowCaptureInstanceInfo_<v>`, three procedures and the database trigger `lakeflowAlterTableTrigger_<v>`, and the CDC grants |
| `lakeflowFixPermissions` | `SELECT` on the catalog views and tables, `EXECUTE` on the functions. On MI and SQL Server also five grants in `master` (SELECT on `sys.change_tracking_databases`, EXECUTE on `sp_tables`, `sp_columns_100`, `sp_pkeys`, `sp_statistics_100`); skipped on SQL Database |

Every `ALTER TABLE` in the database fires the two database triggers when they exist. An `ALTER TABLE` on a table with neither CT nor CDC ran without error.

## What `CLEANUP` does

`EXEC dbo.lakeflowSetupChangeTracking @Mode = 'CLEANUP'` and `EXEC dbo.lakeflowSetupChangeDataCapture @Mode = 'CLEANUP'` drop only the DDL support objects: the audit table and its trigger; the tracker table, the three procedures and the ALTER TABLE trigger. They keep CT and CDC on, the capture instances, the six utility objects and every grant. After `CLEANUP` changes are still captured, but a column added afterwards isn't added to the capture instance.

## Remove everything

[`scripts/uninstall-lakeflow.sql`](../scripts/uninstall-lakeflow.sql), run as a `db_owner` member after the pipelines that read the database are deleted: `CLEANUP` for both procedures, then the six utility objects, the `lakeflow_*` capture instances (and CDC on the database when none is left), CT on the tables and the database, the database user, and on MI and SQL Server the five `master` grants. Skip the CT and CDC steps if anything else uses them; skip the `master` step if another database's pipeline uses the same login (those grants belong to the login, not the database).

How it was checked: [`scripts/catalog-snapshot.sql`](../scripts/catalog-snapshot.sql) on a new database before the install and after the removal, plus [`scripts/server-snapshot.sql`](../scripts/server-snapshot.sql) for `master` and msdb. On SQL Database 462 lines before, 596 after the install and every setup step, 464 after the removal; on MI the 5 `master` grants and 2 msdb jobs came and went. The only lines left were the test's own `ADD COLUMN`s: removal doesn't undo schema changes. A second run changed nothing.
