# SQL Server, standard CDC (gateway + ingestion pipeline)

| Setting | Value |
|---|---|
| Workspace | an AWS field demo workspace |
| Connection | the same SQL Server connection as integrated CDC ([../cdc/README.md](../cdc/README.md)) |
| Source | schema `lfcddemo`: `intpk` (primary key `pk`) and `dtix` (no key) |
| Names | gateway `janedoe_lfcddemo_azure_sqlserver_gw_<epoch>`, ingestion pipeline (applier) `..._ap_<epoch>`, schema, staging, and job `..._<epoch>` |
| Compute | serverless for both (the gateway switched by the script, see below) |

Captured with `python -m lfc_ui.wizard sqlserver --mode gateway --launch`.

## Captured runs

- **2026-10-18, `<name>_1792370583`:** 28 steps in 3.7 minutes: the applier's update completed in under a minute; the last two screenshots are the applier's completed graph (with the gateway's status, Running) and the gateway itself, running. `intpk` 4,894 rows, `dtix` 1,381 (deduplicated, as with integrated CDC). Job, applier, and gateway deleted afterwards.

## What the wizard does (seen 2026-10-18)

- **Ingestion setup:** Change data capture, then Advanced settings → Pipeline mode **Gateway + ingestion pipeline connector**. The form then has a separate *Ingestion gateway configuration*: Gateway name and its own staging location. **The Serverless/Classic choice disappears**, and the new schema isn't selected for you in either schema box: pick it in both. **Create pipelines and continue** creates both pipelines; the gateway starts at once, and runs continuously.
- **The gateway is created on classic compute** (`serverless` unset, waiting for a classic cluster). The script sets `serverless: true` on it right away through the API (the same as editing its YAML); it restarts on serverless.
- Source, Destination, Database setup (Validate: the same 2 warnings), and Schedules are as for integrated CDC; the hourly job is named after the applier, rename it to the schema's name.
- **The applier's run is short** (21 to 42 seconds here), unlike integrated CDC's ~20 minutes: the gateway does the reading. Its page shows an *Ingestion gateway* panel with the gateway's status and a link that **opens the gateway in a new tab**.
- **Clean up promptly:** the gateway bills until it's stopped. Deleting it stops it.
