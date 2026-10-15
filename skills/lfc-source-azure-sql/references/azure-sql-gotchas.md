# Gotchas and Known Issues

## MI provisioning is slow

First MI in a new subnet takes 4–6 hours. If the VNet + subnet already exist (from a prior run by you or another user), subsequent MIs take 30–60 minutes. Plan accordingly.

## MI public endpoint must be explicitly enabled

If you set `--public-data-endpoint-enabled false` and later try to enable it, you need to re-run the MI PATCH operation and wait for the change to propagate (~1 minute).

## SQL Database CDC tier requirement

CDC is only available on certain tiers (e.g., not on `Basic` or `S0`–`S2`). `GP_S_Gen5` (Serverless) supports both CT and CDC.

## Private endpoint DNS is regional

Each private endpoint DNS zone (`privatelink.database.windows.net`) is regional. If you provision resources in multiple regions, each region's VNet must link to the same zone (or a zone per region; Azure manages this automatically).

## Firewall rule IP format

For SQL Database, firewall rules accept CIDR blocks (`198.51.100.0/24`), but the Azure CLI may interpret them as start/end IP ranges. Always validate the rule after creation:

```bash
az sql server firewall-rule list \
  --resource-group <resource_group> \
  --server <pfx>-mssql-<location>-<epoch>
```

## Password complexity

Azure SQL requires passwords with uppercase, lowercase, digits, and symbols (no spaces). `openssl rand -hex 24` produces valid hex; if you use a custom password, test it before provisioning.

## LFC user grants

Ensure `lfc_user` has `db_owner` and `db_ddladmin` roles (or at least `ALTER TABLE`, `CREATE TABLE`, and CDC privileges if using CDC mode).

## Change Tracking retention

Default is 3 days. If your Databricks job runs less frequently, you may miss changes. Adjust `CHANGE_RETENTION` or increase job frequency.

## Collation

Both SQL Database and MI default to `SQL_Latin1_General_CP1_CI_AS` (case-insensitive, accent-insensitive). Changing collation later requires migration. Specify at database creation time if you need a different collation (e.g., case-sensitive).

## TLS version

MI defaults to TLS 1.2 minimum; SQL Database also enforces this. If a legacy client requires TLS 1.0, you will not be able to connect.
