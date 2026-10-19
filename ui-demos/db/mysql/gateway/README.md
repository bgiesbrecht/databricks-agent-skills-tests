# MySQL, standard CDC (gateway + ingestion pipeline)

| Setting | Value |
|---|---|
| Workspace | an AWS field demo workspace |
| Connection | the same MySQL connection as integrated CDC ([../cdc/README.md](../cdc/README.md)) |
| Source | database `lfcddemo`: `intpk` (primary key `pk`) and `dtix` (no key), 10 rows each |
| Names | gateway `janedoe_lfcddemo_azure_mysql_gw_<epoch>`, applier `..._ap_<epoch>`, schema, staging, and job `..._<epoch>` |
| Compute | serverless for both (the gateway switched by the script) |

Captured with `python -m lfc_ui.wizard mysql --mode gateway --launch`. The wizard is the same as for SQL Server standard CDC ([../../sqlserver/gateway/README.md](../../sqlserver/gateway/README.md)).

## Captured runs

- **2026-10-18, `<name>_1792370956`:** 28 steps in 3.6 minutes; the applier's update completed in 0.9 minutes, then the gateway was captured running. Unlike integrated CDC on this idle source (still running after 10 minutes), the applier ends on its own: the gateway does the reading. Job, applier, and gateway deleted afterwards.
