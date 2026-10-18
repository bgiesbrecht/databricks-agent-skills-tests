# PostgreSQL, query-based ingestion (QBC)

| Setting | Value |
|---|---|
| Workspace | an AWS field demo workspace |
| Connection | an existing PostgreSQL connection to an Azure Database for PostgreSQL Flexible Server |
| Source tables | `intpk` (primary key `pk`, cursor `dt`, SCD type 1) and `dtix` (no key, cursor `dt`, append-only) |
| Pipeline and schema | `janedoe_lfcddemo_azure_pg`, in the default catalog |

Wizard steps seen: Connection (pick the connection), Ingestion setup (Change data capture or **Query based capture**; then pipeline name, event log catalog and schema, compute Serverless or Classic, advanced settings; **Create pipeline and continue** creates the pipeline), Source, Destination, Schedules and notifications.

## Captured runs

None complete yet: the first capture stopped after the first screenshot. Runs are written to `runs/<name>/` (gitignored).
