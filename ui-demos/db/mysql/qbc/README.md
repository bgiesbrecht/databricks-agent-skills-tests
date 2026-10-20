# MySQL, query-based ingestion (QBC)

| Setting | Value |
|---|---|
| Workspace | an AWS field demo workspace |
| Connection | an existing MySQL connection to an Azure Database for MySQL Flexible Server |
| Source | database `lfcddemo` (MySQL has no schema level): `intpk` (primary key `pk`, cursor `dt`, SCD type 1) and `dtix` (no key, cursor `dt`, append-only) |
| Pipeline and schema | `janedoe_lfcddemo_azure_mysql_<epoch>`, in the default catalog |

The wizard is the same as for PostgreSQL and SQL Server (see [../../postgres/qbc/README.md](../../postgres/qbc/README.md#what-the-wizard-does-seen-2026-10-18) and [../../sqlserver/qbc/README.md](../../sqlserver/qbc/README.md#what-the-wizard-does-seen-2026-10-18)), with these differences.

## Captured runs

- **Committed: [`runs/robertlee_lfcddemo_azure_mysql_1792373142/png/`](runs/robertlee_lfcddemo_azure_mysql_1792373142/png/)** (2026-10-18, masked in the page): 24 steps in 2.0 minutes; update Completed.
Runs are written to `runs/<name>/` (gitignored).

- **2026-10-18, `<name>_1792358722`:** 25 steps with red boxes. One update, completed in 32 s: `intpk` 10 rows upserted, `dtix` 10 rows, both matching the source. The pipeline was deleted after the capture; no job was created.

## What the wizard does (seen 2026-10-18)

- **The Source step lists the server's databases directly**; there's no database name to type. Expand `lfcddemo`.
- **Destination's button reads "Save and continue"** on the first pass too, and it validates: with `dtix` still SCD type 1 and no key, it failed ("`lfcddemo`.`dtix` ... doesn't have a primary key"), but it saved the tables.
- **Switching to YAML before that save drops the tables**: the YAML then has the connection but no `objects`. Order that works: pick the tables in the wizard, **Save and continue** (fails on `dtix`, saves the tables), switch to YAML (accept the browser dialog), add `scd_type: APPEND_ONLY` under `dtix`, **Save and run pipeline**.
