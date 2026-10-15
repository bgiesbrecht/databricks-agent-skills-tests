# Lifecycle Operations for Azure Flexible Server

## Stop the server (pause billing)

```bash
az mysql flexible-server stop \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${SERVER_NAME}"

echo "==> Stopped. Use 'az mysql flexible-server start' to resume."
```

Stopped servers retain data but do not incur compute charges (~1–2 min to stop/start).

## Start the server

```bash
az mysql flexible-server start \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${SERVER_NAME}"
```

## Delete the server and per-DB resources

```bash
# Delete the server (also deletes the database and firewall rules)
az mysql flexible-server delete \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${SERVER_NAME}" \
  --yes

# Delete the private endpoint
az network private-endpoint delete \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${PE_NAME}"

# Delete the PE subnet (if no other servers use it)
az network vnet subnet delete \
  --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "${VNET_NAME}" \
  --name "${PE_SUBNET_NAME}"

# Shared infrastructure (VNet, DNS zones) is NOT deleted and can be reused
```

## Cleanup: Tagging and TTL (for cost tracking)

Resources are tagged with `RemoveAfter` to support auto-cleanup policies:

```bash
# Add a RemoveAfter tag (expires in 30 days)
az resource tag --ids "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DBfor${ENGINE^}/flexibleServers/${SERVER_NAME}" \
  --tags "RemoveAfter=$(date -d '+30 days' -u +'%Y-%m-%d')"
```

Use Azure Policy or a scheduled deletion scan to automatically delete expired resources.

## Delete the UC connection

Before deleting the database:

```bash
databricks connections delete --name <connection_name> --profile <PROFILE>
```

For PostgreSQL CDC, drop any replication slots:

```bash
psql -h "${SERVER_NAME}.postgres.database.azure.com" -U "${ADMIN_USER}" -c \
  "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE NOT active;"
```
