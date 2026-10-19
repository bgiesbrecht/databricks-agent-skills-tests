# MySQL, integrated CDC

| Setting | Value |
|---|---|
| Workspace | an AWS field demo workspace |
| Connection | an existing MySQL connection to an Azure Database for MySQL Flexible Server (binlog on, `ROW`, `FULL` row image, GTID off) |
| Source | database `lfcddemo`: `intpk` (primary key `pk`) and `dtix` (no key), 10 rows each, no writes during the run |
| Pipeline, schema, job | `janedoe_lfcddemo_azure_mysql_<epoch>`, in the default catalog |
| Compute | serverless (the wizard defaults CDC to Classic) |

Captured with `python -m lfc_ui.wizard mysql --mode cdc --launch` (it stops the update after `--max-wait`, 10 minutes by default, once Running).

## Captured runs

- **Committed: [`runs/robertlee_lfcddemo_azure_mysql_1792373882/png/`](runs/robertlee_lfcddemo_azure_mysql_1792373882/png/)** (2026-10-18, masked in the page): 27 steps in 16.6 minutes; update Stopped after 10.2 min.
- **2026-10-18, `<name>_1792368468`:** 26 steps, the last one the graph while the update was still running; stopped after 10 minutes. `intpk` 10 rows (all), `dtix` 1. Job and pipeline deleted afterwards.

## What the wizard does (seen 2026-10-18)

The same as SQL Server integrated CDC ([../../sqlserver/cdc/README.md](../../sqlserver/cdc/README.md)), with these differences:

- **Database setup validation takes over 3 minutes** ("Validating pipeline configuration"); the database is shown as `default_catalog`.
- **The update doesn't end on an idle source**: smart closure waits for the change lag to converge, and with no writes it can't. After 10 minutes the run status still read "Setting up tables" although both tables had rows. Earlier tests ran past 79 minutes; stop it after a set time.
- **`dtix` is deduplicated** (SCD type 1 without a key; `APPEND_ONLY` is refused for CDC), as on SQL Server.
