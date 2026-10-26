---
name: lfc-source-azure-flexserver
description: "Provision Azure Database for MySQL/PostgreSQL Flexible Server as a source for Databricks Lakeflow Connect."
parent: lfc-source-setup
---

# Azure Database for MySQL / PostgreSQL Flexible Server Setup for LFC

Provision a managed MySQL or PostgreSQL Flexible Server instance on Azure and configure it as a Lakeflow Connect (LFC) source.

## When to use

- You have a Databricks workspace and Azure subscription.
- You want managed MySQL 5.7+ or PostgreSQL 12+ (not self-hosted or podman-local).
- You want LFC to replicate data via binlog (MySQL) or logical replication (PostgreSQL).

**Not suitable for:**
- Azure SQL Database or SQL Server Managed Instance — use `lfc-source-azure-sql` instead.
- Local testing on a single machine — use local Docker/podman instead.

## Inputs to collect

| Input | Example | Notes |
|-------|---------|-------|
| Azure subscription ID | `12345678-1234-1234-1234-123456789012` | Run `az account show --query id -o tsv` |
| Azure region | `eastus`, `westeurope` | Keep close to Databricks workspace |
| Resource group | `<resource-group>` | Ask whether the user has their own; otherwise the team's shared test group, `<resource-group>` (check it with `az group show -n <resource-group>`). The user is free to choose a different one. Don't create one without asking |
| Engine | `mysql` or `postgres` | Binlog (MySQL) or logical replication (PostgreSQL) |
| Version | MySQL `8.0` / PostgreSQL `15`, `16` | Use LTS for stability |
| SKU | `Standard_B1s` or `Standard_B2ms` | Compute size; verify availability in region |
| Storage (GB) | `32` (minimum) | Scales automatically if enabled |
| Access type | `public` or `private-endpoint` | Default: public firewall rules; private endpoint alternative |

## Ask before creating

Confirm with the user what will be created (Flexible Server, VNet, firewall/PE rules) and estimated monthly cost ($50–200 for dev/test). See [flexserver-create-details.md](references/flexserver-create-details.md) for full prerequisites and naming details.

## Create the server

### Quick start (core steps)

```bash
# Set environment variables (see flexserver-create-details.md for full setup)
export LOCATION="eastus"
export RESOURCE_GROUP="<resource-group>"     # or the user's own group: they are free to choose
export ENGINE="mysql"                   # or "postgres"
export VERSION="8.0"
export PREFIX="jane-doe"
export EPOCH="$(date +%s)"
export SERVER_NAME="${PREFIX}-${ENGINE}-${LOCATION}-${EPOCH}"
export DB_NAME="${PREFIX}_${ENGINE}_db_${EPOCH}"
export ADMIN_USER="mysqladmin"          # "pgadmin" for PostgreSQL
export SKU="Standard_B2ms"
export STORAGE_GB="32"

# Resource group: the user's own, or the team's shared test group. Check it exists; create one only if the user asks
az group show --name "${RESOURCE_GROUP}" --query name -o tsv

# Create VNet and subnet
az network vnet create --resource-group "${RESOURCE_GROUP}" \
  --name "lfc-test-vnet" --address-prefix "10.10.0.0/16" || true

az network vnet subnet create --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "lfc-test-vnet" --name "${PREFIX}-${ENGINE}-pe-subnet-${EPOCH}" \
  --address-prefix "10.10.2.0/24" \
  --disable-private-endpoint-network-policies false || true

# Create Flexible Server
ADMIN_PASSWORD="$(openssl rand -base64 12 | cut -c1-16)"

if [ "${ENGINE}" = "mysql" ]; then
  az mysql flexible-server create --resource-group "${RESOURCE_GROUP}" \
    --name "${SERVER_NAME}" --location "${LOCATION}" \
    --admin-user "${ADMIN_USER}" --admin-password "${ADMIN_PASSWORD}" \
    --sku-name "${SKU}" --tier "Burstable" --storage-size "${STORAGE_GB}" \
    --version "${VERSION}" --backup-retention "1" \
    --storage-auto-grow "Disabled" --public-access "Enabled" --yes
elif [ "${ENGINE}" = "postgres" ]; then
  az postgres flexible-server create --resource-group "${RESOURCE_GROUP}" \
    --name "${SERVER_NAME}" --location "${LOCATION}" \
    --admin-user "${ADMIN_USER}" --admin-password "${ADMIN_PASSWORD}" \
    --sku-name "${SKU}" --tier "Burstable" --storage-size "${STORAGE_GB}" \
    --version "${VERSION}" --backup-retention "1" \
    --storage-auto-grow "Disabled" --public-access "Enabled" --yes
fi

# Wait for Ready state (~5–15 minutes)
az resource wait --resource-group "${RESOURCE_GROUP}" --name "${SERVER_NAME}" \
  --resource-type "Microsoft.DBfor${ENGINE^}/flexibleServers" --updated

# Save password to a temp file for next steps
echo "${ADMIN_PASSWORD}" > /tmp/admin_password.txt
chmod 600 /tmp/admin_password.txt
```

See [flexserver-create-details.md](references/flexserver-create-details.md) for prerequisite checks and detailed provisioning.

## Server parameters for LFC

Run the commands in [flexserver-parameters.md](references/flexserver-parameters.md) to configure binlog/logical replication parameters.

**Quick summary:**
- **MySQL:** `binlog_format=ROW`, `binlog_row_image=FULL`, `require_secure_transport=OFF`
- **PostgreSQL:** `wal_level=logical`, requires server restart

## Networking

> **Firewall rules:** use **lfc-source-firewall** to add your laptop IP and the workspace's serverless egress IPs (and classic compute egress, when the pipeline uses classic compute) to this database. It covers rule limits and keeps the rules in sync.

**Default: Public firewall rules.** Add your laptop IP and Databricks workspace egress CIDR to allow inbound connections on 3306 (MySQL) or 5432 (PostgreSQL).

**Alternative: Private endpoint.** For Databricks serverless, use a private endpoint in the VNet for encrypted network isolation. See [flexserver-networking.md](references/flexserver-networking.md) for both options.

## Configure the database and enable LFC

Create the database:

```bash
ADMIN_PASSWORD="$(cat /tmp/admin_password.txt)"

if [ "${ENGINE}" = "mysql" ]; then
  mysql -h "${SERVER_NAME}.mysql.database.azure.com" -u "${ADMIN_USER}" \
    -p"${ADMIN_PASSWORD}" --ssl-mode=REQUIRED \
    -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
elif [ "${ENGINE}" = "postgres" ]; then
  export PGPASSWORD="${ADMIN_PASSWORD}"
  psql -h "${SERVER_NAME}.postgres.database.azure.com" -U "${ADMIN_USER}" \
    -c "CREATE DATABASE \"${DB_NAME}\" WITH ENCODING 'UTF8';"
  unset PGPASSWORD
fi
```

Then follow the engine-specific guide to create the LFC user, enable CDC, and seed tables:
- **MySQL:** [engine-mysql.md](../lfc-source-setup/references/engine-mysql.md)
- **PostgreSQL:** [engine-postgres.md](../lfc-source-setup/references/engine-postgres.md)

## Register the UC connection

```bash
# Read the admin password
ADMIN_PASSWORD="$(cat /tmp/admin_password.txt)"

# Create connection JSON (restricted permissions)
umask 077
cat > /tmp/uc_connection.json <<EOF
{
  "name": "<connection-name>",
  "connection_type": "MYSQL" or "POSTGRES",
  "options": {
    "host": "${SERVER_NAME}.mysql.database.azure.com",
    "port": "3306" or "5432",
    "user": "${ADMIN_USER}",
    "password": "${ADMIN_PASSWORD}",
    "database": "${DB_NAME}",
    "ssl": "require"
  }
}
EOF

# Create and verify the UC connection
databricks connections create --json @/tmp/uc_connection.json --profile <PROFILE>
rm /tmp/uc_connection.json /tmp/admin_password.txt
unset ADMIN_PASSWORD
```

## Verify connectivity

### From your laptop

```bash
if [ "${ENGINE}" = "mysql" ]; then
  mysql -h "${SERVER_NAME}.mysql.database.azure.com" -u "${ADMIN_USER}" -p \
    --ssl-mode=REQUIRED -e "SELECT VERSION();"
elif [ "${ENGINE}" = "postgres" ]; then
  export PGPASSWORD="<password>"
  psql -h "${SERVER_NAME}.postgres.database.azure.com" -U "${ADMIN_USER}" \
    -c "SELECT version();"
fi
```

### From Databricks (test the UC connection)

Use a read-only remote query to verify the connection:

```bash
cat > /tmp/test_query.sql <<'EOF'
SELECT * FROM remote_query('<connection-name>', 
  database => '<database-name>', 
  query => "SELECT 1 AS ok")
EOF

databricks experimental aitools tools query --file /tmp/test_query.sql \
  --profile <PROFILE> -o csv
```

(For MySQL, omit the `database =>` argument.)

## Lifecycle

See [flexserver-lifecycle.md](references/flexserver-lifecycle.md) for stopping, starting, and deleting servers, plus cleanup.

## Top gotchas

1. **Server creation slow:** Provisioning takes 5–15 minutes. Check status with `az mysql flexible-server show`.
2. **PostgreSQL parameters require restart:** `wal_level` changes need `az postgres flexible-server restart`.
3. **Password rotation:** Use `az mysql flexible-server update --admin-password`.
4. **Firewall rules incomplete:** Verify Databricks workspace egress CIDR is added.
5. **SSL certificate errors:** Download Azure's CA certificate if clients fail verification.

See [flexserver-gotchas.md](references/flexserver-gotchas.md) for more troubleshooting.

## Reference

- Parent skill **lfc-source-setup**: overview, naming, shared infrastructure
- [engine-mysql.md](../lfc-source-setup/references/engine-mysql.md) — MySQL user, grants, binlog setup
- [engine-postgres.md](../lfc-source-setup/references/engine-postgres.md) — PostgreSQL user, grants, logical replication setup
- [flexserver-create-details.md](references/flexserver-create-details.md) — prerequisites, resource provider registration, detailed provisioning steps
- [flexserver-parameters.md](references/flexserver-parameters.md) — server parameter configuration for CDC
- [flexserver-networking.md](references/flexserver-networking.md) — private endpoint and firewall rule setup
- [flexserver-lifecycle.md](references/flexserver-lifecycle.md) — stop, start, delete, cleanup
- [flexserver-gotchas.md](references/flexserver-gotchas.md) — troubleshooting
