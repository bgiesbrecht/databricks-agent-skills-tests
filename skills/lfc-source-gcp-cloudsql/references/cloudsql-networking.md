# Cloud SQL Networking

## Verify public IP

```bash
gcloud sql instances describe "${INSTANCE_NAME}" \
  --project="${PROJECT_ID}" \
  --format="value(ipAddresses[0].ipAddress)"
```

## Authorized networks (firewall rules)

GCP Cloud SQL does not use security groups; instead, each instance maintains an authorized networks list (IPv4 CIDR blocks).

### Add workspace serverless CIDR

Get the workspace's serverless egress CIDR ranges from your Databricks admin:

Databricks' published `ip-ranges.json` (outbound, for the workspace's cloud and region; see **lfc-source-firewall**)

Example ranges (documentation placeholders; get your actual ranges):
- `203.0.113.0/24`
- `198.51.100.0/24`

```bash
gcloud sql instances patch "${INSTANCE_NAME}" \
  --authorized-networks="203.0.113.0/24,198.51.100.0/24" \
  --project="${PROJECT_ID}"
```

### View current authorized networks

```bash
gcloud sql instances describe "${INSTANCE_NAME}" \
  --project="${PROJECT_ID}" \
  --format="value(settings.ipConfiguration.authorizedNetworks[*].value)"
```

### Add laptop IP for testing (optional)

For testing from your laptop:

```bash
LAPTOP_IP="203.0.113.10"  # Your laptop's public IP

gcloud sql instances patch "${INSTANCE_NAME}" \
  --authorized-networks="203.0.113.0/24,198.51.100.0/24,${LAPTOP_IP}/32" \
  --project="${PROJECT_ID}"
```

## Private IP (advanced, not covered here)

Private IP connectivity requires a network peering setup and is not covered in this guide. For production environments, consult your Databricks network team about private network connectivity.

## Important security note

The workspace's serverless egress CIDR ranges vary by region and workspace. Never open the database to the internet (`0.0.0.0/0`). Always:
1. Get the exact CIDR ranges from your Databricks admin
2. Add only those ranges to authorized networks
3. Verify connectivity works before removing temporary rules
