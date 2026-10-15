# Lifecycle: Pause, Resume, and Delete

## Pause / Resume (SQL Database only)

```bash
# Pause (stops billing for compute; storage still charged)
az sql db pause \
  --resource-group <resource_group> \
  --server <pfx>-mssql-<location>-<epoch> \
  --name <pfx>_mssql_db_<epoch>

# Resume
az sql db resume \
  --resource-group <resource_group> \
  --server <pfx>-mssql-<location>-<epoch> \
  --name <pfx>_mssql_db_<epoch>
```

SQL Managed Instance **does not support pause/resume**; delete and recreate to stop billing.

## Delete UC connection first

```bash
databricks connections delete --name <connection_name> --profile <PROFILE>
```

## Delete SQL Database

```bash
az sql db delete \
  --resource-group <resource_group> \
  --server <pfx>-mssql-<location>-<epoch> \
  --name <pfx>_mssql_db_<epoch> \
  --yes

az sql server delete \
  --resource-group <resource_group> \
  --name <pfx>-mssql-<location>-<epoch> \
  --yes
```

## Delete SQL Managed Instance (long operation)

```bash
az sql mi delete \
  --resource-group <resource_group> \
  --name <pfx>-mssql-mi-<location>-<epoch> \
  --yes
```

**Monitor deletion** (takes ~30–60 minutes):

```bash
az sql mi show \
  --resource-group <resource_group> \
  --name <pfx>-mssql-mi-<location>-<epoch> \
  --query "provisioningState" -o tsv
# Once deleted, this command will return an error (404).
```

## Clean up shared resources (optional)

Only delete if no other users or tests are using them:

```bash
az network private-dns zone delete \
  --resource-group <resource_group> \
  --name privatelink.database.windows.net \
  --yes

az network vnet delete \
  --resource-group <resource_group> \
  --name lfc-test-vnet \
  --yes
```
