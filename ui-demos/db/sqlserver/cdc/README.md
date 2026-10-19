# SQL Server, integrated CDC

| Setting | Value |
|---|---|
| Workspace | an AWS field demo workspace |
| Connection | an existing SQL Server connection to an Azure SQL Database (database CDC and change tracking on; `dtix` has CDC, `intpk` change tracking) |
| Source | schema `lfcddemo`: `intpk` (primary key `pk`) and `dtix` (no key) |
| Pipeline, schema, job | `janedoe_lfcddemo_azure_sqlserver_<epoch>`, in the default catalog; the staging volume goes in the same schema |
| Compute | serverless (the wizard defaults CDC to Classic) |

Captured with `python -m lfc_ui.wizard sqlserver --mode cdc --launch`.

## Captured runs

- **2026-10-18, `<name>_1792366433`:** 26 steps; the wizard took 4.2 minutes, then the update 20.8 minutes to Completed. `intpk` 4,894 rows (all), `dtix` 1,381 (see below). Job and pipeline deleted afterwards.

## What the wizard does (seen 2026-10-18)

- **Ingestion setup:** pick **Change data capture**, then **Serverless** (Classic is the default for CDC). Advanced settings has **Pipeline mode**: *Integrated CDC connector* (Recommended, the default) or *Gateway + ingestion pipeline connector*. The staging location fills in with the event log's schema.
- **Source:** the connection's database is listed directly (no database name to type); the schema list is long and virtualized, so scroll to `lfcddemo`. Per table there's nothing to pick: keys and order come from the source. Options: History tracking (Off = SCD type 1), Sequence by, Auto full refresh.
- **Database setup** (new step): **Validate** checks the source. Here it gave 2 warnings: the database's Lakeflow utility and DDL-support objects are version 1.5 and 1.7 is expected, and change-tracking DDL objects that aren't needed. "Complete configuration" shows the scripts to run on the source (it runs nothing). Warnings don't block Next; ingestion worked without the upgrade.
- **Schedules:** Pipeline schedule *Continuous* or *Schedule*; the hourly job `<name> job` already exists (rename it). **Save and run pipeline**.
- **A keyless table is deduplicated.** `dtix` has one column and no key: SCD type 1 keeps one row per distinct row, 1,381 of the source's 5,494 (its distinct `dt` values). `APPEND_ONLY` isn't allowed for CDC: "APPEND_ONLY can only be used for incremental ingestion of query based connector. The cursor_columns must be set in such cases."
- **The update runs about 20 minutes** even for a 10k-row snapshot: smart closure ends it once the change lag converges (two runs: 21 and 20.8 minutes, the snapshot itself under a minute).
