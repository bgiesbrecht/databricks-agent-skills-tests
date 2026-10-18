# PostgreSQL, query-based ingestion (QBC)

| Setting | Value |
|---|---|
| Workspace | an AWS field demo workspace |
| Connection | an existing PostgreSQL connection to an Azure Database for PostgreSQL Flexible Server |
| Source tables | `intpk` (primary key `pk`, cursor `dt`, SCD type 1) and `dtix` (no key, cursor `dt`, append-only) |
| Pipeline, schema, and job | `janedoe_lfcddemo_azure_pg_<epoch>`, in the default catalog |

Wizard steps seen: Connection (pick the connection), Ingestion setup (Change data capture or **Query based capture**; then pipeline name, event log catalog and schema, compute Serverless or Classic, advanced settings; **Create pipeline and continue** creates the pipeline), Source, Destination, Schedules and notifications.

## Captured runs

Runs are written to `runs/<name>/` (gitignored).

- **2026-10-18, `<name>_1792350190`:** 34 steps, from Add data to the graph of a completed update. Took two updates: the first loaded `intpk` (34K rows upserted) and failed on `dtix`; after `scd_type: APPEND_ONLY` was added in the YAML view, the second loaded `dtix` (39K rows) and completed.

## What the wizard does (seen 2026-10-18)

- **A table without a primary key fails.** History tracking offers only Off (SCD type 1) and On (SCD type 2), both of which need a key; there's no append-only choice. The update fails with "The table ... doesn't have a primary key". Fix: **Edit pipeline → YAML**, add `scd_type: APPEND_ONLY` under that table's `table_configuration`, then **Save and run pipeline**.
- **The primary key isn't filled in from the source**, even for a table that has one: pick it under Primary key(s).
- **It creates a schedule job on its own** when the pipeline is created: every 1 hour, named `<pipeline> job`. "Create schedule" adds a second job, so edit that one instead (Schedule actions → Edit) and rename it to the pipeline's name.
- **Create schema** is offered in the event log schema list when the typed name doesn't exist; the destination step then picks the same schema.
- **The Source step waits for compute** (about a minute) before it can list the database's schemas, and asks for the database name first.
