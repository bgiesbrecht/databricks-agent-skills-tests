# Networking for Azure Flexible Server

## Option A: Private endpoint (recommended for LFC + Databricks serverless)

Private endpoints provide encrypted network isolation. Databricks serverless can reach the database via Azure's private network backbone.

### Setup private endpoint and DNS A record

```bash
eval "$(az network vnet show -g "${RESOURCE_GROUP}" -n "${VNET_NAME}" -o json \
  | yq -p json -o shell '{"VNET_ID": (.id // "")}')"
PE_NAME="${PREFIX}-${ENGINE}-pe-${EPOCH}"
PE_CONNECTION_NAME="${PE_NAME}-conn"

# Create private endpoint
az network private-endpoint create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${PE_NAME}" \
  --vnet-name "${VNET_NAME}" \
  --subnet "${PE_SUBNET_NAME}" \
  --private-connection-resource-id "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DBfor${ENGINE^}/flexibleServers/${SERVER_NAME}" \
  --group-ids "mysqlServer" \
  --connection-name "${PE_CONNECTION_NAME}"

# Approve the private endpoint connection (auto-approved in same subscription)
# If needed: az network private-endpoint-connection approve ...

# Get the private IP address
eval "$(az network private-endpoint show -g "${RESOURCE_GROUP}" -n "${PE_NAME}" -o json \
  | yq -p json -o shell '{"PE_NIC_ID": (.networkInterfaces[0].id // "")}')"
eval "$(az network nic show --ids "${PE_NIC_ID}" -o json \
  | yq -p json -o shell '{"PRIVATE_IP": (.ipConfigurations[0].privateIpAddress // "")}')"

# Create private DNS A record
DNS_ZONE_NAME="privatelink.mysql.database.azure.com"  # or "privatelink.postgres.database.azure.com" for PostgreSQL
az network private-dns record-a create \
  --resource-group "${RESOURCE_GROUP}" \
  --zone-name "${DNS_ZONE_NAME}" \
  --name "${SERVER_NAME}" \
  --ipv4-address "${PRIVATE_IP}"
```

## Option B: Public firewall rules (simpler, less secure)

Add your laptop IP and Databricks egress CIDR to the firewall allow list:

```bash
# Get your current public IP
MY_IP=$(curl -s https://api.ipify.org)

# Add firewall rule for your laptop (/24 subnet to avoid reconnection updates)
MY_SUBNET="${MY_IP%.*}.0/24"
FW_RULE_NAME="${PREFIX}-${ENGINE}-my-ip-${EPOCH}"

az mysql flexible-server firewall-rule create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${SERVER_NAME}" \
  --rule-name "${FW_RULE_NAME}" \
  --start-ip-address "${MY_SUBNET%/*}.0" \
  --end-ip-address "${MY_SUBNET%/*}.255"

# Add Databricks serverless egress CIDR (get from your workspace's NCC)
DATABRICKS_EGRESS_CIDR="20.0.0.0/8"  # Replace with your workspace's actual CIDR
az mysql flexible-server firewall-rule create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${SERVER_NAME}" \
  --rule-name "databricks-serverless-egress-${EPOCH}" \
  --start-ip-address "${DATABRICKS_EGRESS_CIDR%/*}.*" \
  --end-ip-address "${DATABRICKS_EGRESS_CIDR%/*}.*"
```

## Private endpoint DNS resolution troubleshooting

**Problem:** `nslookup server_name.mysql.database.azure.com` returns the public IP instead of the private IP.

**Fix:** Verify from within the VNet (e.g., a VM or Databricks workspace in the same VNet). If still failing, check DNS zone links.
