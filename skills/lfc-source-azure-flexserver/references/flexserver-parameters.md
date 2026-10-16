# Server Parameters for LFC on Azure Flexible Server

Configure server-level parameters to enable CDC and LFC compatibility after server creation.

## MySQL Flexible Server

```bash
# Parameters for Lakeflow Connect (binlog-based CDC)
az mysql flexible-server parameter set \
  --resource-group "${RESOURCE_GROUP}" \
  --server-name "${SERVER_NAME}" \
  --name "binlog_format" \
  --value "ROW"

az mysql flexible-server parameter set \
  --resource-group "${RESOURCE_GROUP}" \
  --server-name "${SERVER_NAME}" \
  --name "binlog_row_image" \
  --value "full"

az mysql flexible-server parameter set \
  --resource-group "${RESOURCE_GROUP}" \
  --server-name "${SERVER_NAME}" \
  --name "require_secure_transport" \
  --value "off"

az mysql flexible-server parameter set \
  --resource-group "${RESOURCE_GROUP}" \
  --server-name "${SERVER_NAME}" \
  --name "binlog_expire_logs_seconds" \
  --value "604800"

# Optional: Enable audit logging
az mysql flexible-server parameter set \
  --resource-group "${RESOURCE_GROUP}" \
  --server-name "${SERVER_NAME}" \
  --name "audit_log_enabled" \
  --value "ON"
```

## PostgreSQL Flexible Server

```bash
# Parameters for Lakeflow Connect (logical replication)
az postgres flexible-server parameter set \
  --resource-group "${RESOURCE_GROUP}" \
  --server-name "${SERVER_NAME}" \
  --name "wal_level" \
  --value "logical"

az postgres flexible-server parameter set \
  --resource-group "${RESOURCE_GROUP}" \
  --server-name "${SERVER_NAME}" \
  --name "require_secure_transport" \
  --value "off"

az postgres flexible-server parameter set \
  --resource-group "${RESOURCE_GROUP}" \
  --server-name "${SERVER_NAME}" \
  --name "pgaudit.log" \
  --value "connections,role,ddl"

# Ensure pgaudit is preloaded (if not already)
az postgres flexible-server parameter set \
  --resource-group "${RESOURCE_GROUP}" \
  --server-name "${SERVER_NAME}" \
  --name "shared_preload_libraries" \
  --value "pgaudit"
```

**Restart required (PostgreSQL only, for wal_level change):**

```bash
az postgres flexible-server restart \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${SERVER_NAME}"

# restart returns when the restart is done; then confirm the server is Ready
az resource wait \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${SERVER_NAME}" \
  --resource-type "Microsoft.DBforPostgreSQL/flexibleServers" \
  --updated
```

> **MySQL:** No restart required; parameter changes applied immediately (or on next connection for some).
