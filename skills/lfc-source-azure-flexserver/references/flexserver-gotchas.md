# Gotchas and Troubleshooting for Azure Flexible Server

## Server creation hangs or times out

**Problem:** `az ... create` appears stuck after "Creating" for >15 min.

**Cause:** Azure provisioning is slow; check actual status with:

```bash
az mysql flexible-server show -g "${RESOURCE_GROUP}" -n "${SERVER_NAME}" \
  -q "properties.state"
```

**Fix:** If stuck in "Updating" or "Creating" for >20 min, contact Azure support. The instance may be unreachable until it reaches "Ready."

## Parameter change requires server restart

**Problem:** Parameter value set with `az ... parameter set` shows old value on reconnect.

**Cause:** Some parameters (e.g., PostgreSQL `wal_level`) require a restart. Azure doesn't auto-restart.

**Fix:** Manually restart with `az postgres flexible-server restart`.

## Admin password reset

**Problem:** Forgot or need to rotate the admin password.

**Fix:**

```bash
az mysql flexible-server update \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${SERVER_NAME}" \
  --admin-password "NewPassword123!"
```

Wait for the server to settle (~30 sec).

## SSL/TLS certificate issues

**Problem:** `ssl: CERTIFICATE_VERIFY_FAILED` or `sslmode=require` errors.

**Cause:** Azure Flexible Server enforces SSL. Some clients don't trust Azure's CA certificate.

**Fix:** Download the CA certificate:

```bash
# MySQL
curl https://dl.cacerts.digicert.com/DigiCertGlobalRootCA.crt > ~/ca.pem
mysql -h ... --ssl-ca=~/ca.pem ...

# PostgreSQL
export PGSSLCERT=~/.postgresql/root.crt
curl https://cacerts.digicert.com/DigiCertGlobalRootCA.crt > ~/.postgresql/root.crt
psql -h ... ...
```

## Firewall rule not working

**Problem:** Connection from Databricks serverless fails with "IP not allowed."

**Cause:** The egress CIDR you added is incorrect or incomplete.

**Fix:** Verify the Databricks workspace's NCC egress CIDR and add all CIDRs:

```bash
# Check NCC settings in Databricks
databricks network_connectivity_configs get --config_id <ncc_id>
```

## "No API versions found" for resource type

**Problem:** `az resource wait` or other CLI commands fail with "No API versions found for 'Microsoft.DBforMySQL/flexibleServers'."

**Cause:** Resource provider not registered or typo in resource type.

**Fix:**

```bash
az provider register --namespace Microsoft.DBforMySQL
az provider show -n Microsoft.DBforMySQL --query registrationState
```

Wait for "Registered" status, then retry.

## Terraform / IaC: Invalid SKU tier combination

**Problem:** Terraform or ARM template fails with "The SKU `Standard_B2ms` with tier `Burstable` is invalid."

**Cause:** Tier names in Azure APIs differ from CLI names.

**Fix:** Use correct tier names in ARM templates:

- CLI `--tier "Burstable"` → ARM `"tier": "Burstable"`
- CLI `--tier "GeneralPurpose"` → ARM `"tier": "GeneralPurpose"`

Verify with `az mysql flexible-server sku list`.
