---
name: lfc-source-azure-sql
description: "Create an Azure SQL Database or SQL Managed Instance for Lakeflow Connect testing, configure it for query-based ingestion (Change Tracking or CDC), and register the UC connection."
parent: lfc-source-setup
---

# Azure SQL Database and SQL Managed Instance for Lakeflow Connect

Provision a SQL Server source on Azure for Lakeflow Connect with either **Azure SQL Database** (cheaper, faster provisioning) or **Azure SQL Managed Instance** (MI: slower, expensive, full control).

## When to use

| Option | Best for | Cost | Provisioning |
|--------|----------|------|--------------|
| **SQL Database** | Testing, demos, time-sensitive work | $$-$$$ per month | Minutes |
| **SQL Managed Instance** | Full SQL Server compatibility, CDC | $$$$-$$$$$$ per month | 4–6 hours (first in subnet) |

Both support Change Tracking (CT) and CDC. Both incur data transfer costs if Databricks is in a different region.

## Inputs to collect

| Input | Source | Example |
|-------|--------|---------|
| Azure region | `az account list-locations` | `eastus`, `westeurope` |
| Resource group | Ask whether the user has their own; otherwise the team's shared test group, `<resource-group>` (check it with `az group show -n <resource-group>`). The user is free to choose a different one. Don't create one without asking | `<resource-group>` |
| Subscription ID | `az account show` | Confirm with user |
| Owner tag | Your name/email prefix | `jane-doe` |
| Replication mode | Query-based only / CT / CDC / BOTH | See parent [engine-sqlserver.md](../lfc-source-setup/references/engine-sqlserver.md) |
| **SQL Database:** Service Objective (SKU) | Default | `GP_S_Gen5_2` for testing |
| **SQL Database:** Storage (GB) | Minimum 32 | `32`, `64` |
| **SQL MI:** vCore count | Must be 4, 8, 16, 24, 32, 40, 64, or 80 | `4` (minimum) |
| **SQL MI:** Storage (GB) | Minimum 32 | `32`, `128` |

## Ask before creating

List every resource (server/instance, VNet, firewall/PE rules) and estimated monthly cost:
- **SQL Database:** ~$50–100/month
- **SQL MI:** ~$400–1000/month (plus provisioning wait time: 4–6 hours first, 30–60 min after)

Wait for a **yes** before proceeding.

## Prerequisites

```bash
# Confirm cloud login
az account show --query "{Name: name, SubscriptionId: id, State: state}" -o table

# Set the subscription if needed
az account set --subscription <subscription_id>

# Resource group: the user's own, or the team's shared test group. Check it exists; create one only if the user asks
az group exists --name <resource_group>
```

## Create: SQL Database vs. SQL Managed Instance

### Option A: SQL Database (recommended for testing)

See [azure-sql-database.md](references/azure-sql-database.md) for full steps (prerequisites, firewall config, verification).

**Quick summary:**
> `az` takes the admin password only as a flag (`--admin-password`), so it's briefly visible in this machine's process list while the command runs. Run it on a machine you control, and delete `admin.pw` once the UC connection exists.

```bash
# Create logical server
umask 077
echo "Lfc1$(openssl rand -hex 12)" > admin.pw
az sql server create --resource-group <rg> --name <pfx>-mssql-<loc>-<epoch> \
  --location <location> --admin-user sqladmin \
  --admin-password "$(cat admin.pw)" --enable-public-network true

# Create database
az sql db create --resource-group <rg> --server <pfx>-mssql-<loc>-<epoch> \
  --name <pfx>_mssql_db_<epoch> --service-objective GP_S_Gen5_2 \
  --collation SQL_Latin1_General_CP1_CI_AS

# Add firewall rule for Databricks egress CIDR
az sql server firewall-rule create --resource-group <rg> \
  --server <pfx>-mssql-<loc>-<epoch> --name "databricks-serverless" \
  --start-ip-address "198.51.100.0" --end-ip-address "198.51.100.255"
```

### Option B: SQL Managed Instance (production-like)

**Warning:** First MI in a new subnet takes **4–6 hours** to provision.

See [azure-sql-mi.md](references/azure-sql-mi.md) for full steps (NSG setup, monitoring, public endpoint).

**Quick summary:**
```bash
# Create MI subnet
az network vnet subnet create --resource-group <rg> --vnet-name lfc-test-vnet \
  --name lfc-test-mi-subnet --address-prefix 10.10.200.0/27 \
  --service-endpoints Microsoft.Sql Microsoft.Storage

# Create Managed Instance
umask 077
echo "Lfc1$(openssl rand -hex 12)" > admin.pw
az sql mi create --resource-group <rg> --name <pfx>-mssql-mi-<loc>-<epoch> \
  --location <location> --admin-user sqladmin \
  --admin-password "$(cat admin.pw)" \
  --subnet "/subscriptions/<sub_id>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/lfc-test-vnet/subnets/lfc-test-mi-subnet" \
  --sku-name GP_Gen5 --vcores 4 --storage 32 \
  --public-data-endpoint-enabled true --enable-minimal-tls-version Tls12

# Monitor (takes hours)
az sql mi show --resource-group <rg> --name <pfx>-mssql-mi-<loc>-<epoch> \
  --query "provisioningState" -o tsv
```

## Configure for LFC

Create the LFC user and enable Change Tracking or CDC via T-SQL (see parent [engine-sqlserver.md](../lfc-source-setup/references/engine-sqlserver.md)):

```sql
-- Create LFC user
CREATE LOGIN [lfc_user] WITH PASSWORD = N'<password-from-file>';
CREATE USER [lfc_user] FOR LOGIN [lfc_user] WITH DEFAULT_SCHEMA = dbo;
ALTER ROLE db_owner ADD MEMBER [lfc_user];
ALTER ROLE db_ddladmin ADD MEMBER [lfc_user];

-- Enable Change Tracking (or CDC; see parent reference)
ALTER DATABASE [<db>] SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 3 DAYS, AUTO_CLEANUP = ON);

-- Create seed tables (see parent reference)
CREATE TABLE dbo.intpk (pk INT IDENTITY NOT NULL PRIMARY KEY, dt DATETIME, ops VARCHAR(255) DEFAULT 'insert');
CREATE TABLE dbo.dtix (pk BIGINT, dt DATETIME, ops VARCHAR(255) DEFAULT 'insert');
```

## Register the UC connection

```bash
# Read the LFC user password from the secure file
LFC_PASSWORD="$(cat lfc_user.pw)"

# Create connection JSON (restricted permissions)
umask 077
cat > conn.json <<EOF
{
  "name": "<connection-name>",
  "connection_type": "SQLSERVER",
  "options": {
    "host": "<server-fqdn>",
    "port": "<1433-or-3342>",
    "user": "lfc_user",
    "password": "${LFC_PASSWORD}"
  }
}
EOF

# Create the UC connection and delete the files immediately
databricks connections create --json @conn.json --profile <PROFILE> && rm conn.json lfc_user.pw

# Clear the password variable
unset LFC_PASSWORD
```

**Host and port:**
- **SQL Database:** `<pfx>-mssql-<location>-<epoch>.database.windows.net:1433`
- **SQL MI (public endpoint):** `<public_fqdn>:3342`

## Verify connectivity

### From your laptop

```bash
sqlcmd -S <server>,<port> -U <user> -P <password> -d <database> -Q "SELECT 1;"
```

### From Databricks (test the UC connection)

```bash
cat > /tmp/test_query.sql <<'EOF'
SELECT * FROM remote_query('<connection-name>', 
  database => '<database-name>', 
  query => "SELECT 1 AS ok")
EOF

databricks experimental aitools tools query --file /tmp/test_query.sql \
  --profile <PROFILE> -o csv
```

## Networking

> **Firewall rules:** use **lfc-source-firewall** to add your laptop IP and the workspace's serverless egress IPs (and classic compute egress, when the pipeline uses classic compute) to this database. It covers rule limits and keeps the rules in sync.

**Default: Public firewall rules** (SQL Database) or **public endpoint on port 3342** (SQL MI). Add Databricks workspace egress CIDR to allow inbound connections.

**Alternative: Private endpoint** (both Database and MI). Link the private DNS zone (`privatelink.database.windows.net`) to the VNet. See [mi-networking.md](references/mi-networking.md) for detailed private endpoint setup.

## Lifecycle

See [azure-sql-lifecycle.md](references/azure-sql-lifecycle.md):
- **Pause/Resume** (SQL Database only)
- **Delete** (Database vs. MI; MI takes 30–60 minutes)
- **Cleanup** shared resources (VNet, DNS zones)

## Top gotchas

1. **MI provisioning is slow:** 4–6 hours for first MI in a new subnet.
2. **SQL Database CDC tier required:** Not available on `Basic` or `S0`–`S2`; use `GP_S_Gen5` or higher.
3. **Password complexity:** Uppercase, lowercase, digits, symbols; no spaces. Test before provisioning.
4. **LFC user grants:** Must have `db_owner` and `db_ddladmin` roles.
5. **Collation is fixed at creation:** Changing collation later requires migration. Specify at database creation time if you need case-sensitive.

See [azure-sql-gotchas.md](references/azure-sql-gotchas.md) for more troubleshooting.

## Reference

- Parent skill **lfc-source-setup**: overview, naming, shared infrastructure
- [engine-sqlserver.md](../lfc-source-setup/references/engine-sqlserver.md) — user, grants, CT/CDC, seed tables
- [azure-sql-database.md](references/azure-sql-database.md) — SQL Database detailed setup (server, database, firewall, PE)
- [azure-sql-mi.md](references/azure-sql-mi.md) — SQL MI detailed setup (subnet, NSG, provisioning monitoring)
- [mi-networking.md](references/mi-networking.md) — NSG, private endpoint, public endpoint networking details
- [azure-sql-lifecycle.md](references/azure-sql-lifecycle.md) — pause, resume, delete, cleanup
- [azure-sql-gotchas.md](references/azure-sql-gotchas.md) — troubleshooting
