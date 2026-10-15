---
name: lfc-source-cloud-vm
description: Provision databases on Azure and GCP cloud VMs for Lakeflow Connect. Covers native database packages or Podman containers with manual setup steps.
parent: lfc-source-setup
---

# Cloud VMs for Lakeflow Connect

When managed cloud databases don't exist for your engine (Oracle 19c, SQL Server Always On, DB2, Informix) or when you need full control over replication settings, provision a plain Ubuntu VM on your cloud and install the database yourself.

This skill covers **Azure VMs** and **GCP Compute Engine** instances. Both support:
1. **Native packages**: Install MySQL, PostgreSQL, SQL Server from apt/yum
2. **Podman containers**: Run database images in Podman

The workflow is manual so you control every step and understand the configuration.

## When to use

- Your engine has no managed service (Oracle 19c, DB2, Informix)
- You need a specific database version not in managed tiers
- You require unusual replication modes (Always On AGs, full control of CDC)
- You need to run multiple database versions on one host (Podman)
- You're testing before committing to production infrastructure

## Two installation models

| Model | Engines | Setup time | Best for |
|-------|---------|-----------|----------|
| **Native Packages** | MySQL, PostgreSQL, SQL Server | ~5–10 min | Testing, non-critical sources |
| **Podman Containers** | All (Oracle, DB2, Informix, MySQL, PostgreSQL, SQL Server) | ~10–20 min | Production-like, multi-engine hosts |

## Inputs to collect

| Input | Choices | Example | Notes |
|-------|---------|---------|-------|
| **Cloud** | `azure` or `gcp` | — | Determines VM API and firewall |
| **Region** | Azure: `eastus`, `centralus`, `westus`; GCP: `us-central1`, `us-east1` | `eastus` (Azure) / `us-central1` (GCP) | Close to Databricks workspace |
| **VM size** | Azure: `Standard_B4ms`, `Standard_D2s_v3`; GCP: `n1-standard-4`, `e2-standard-4` | `Standard_B4ms` / `n1-standard-4` | 4 vCPU, 8–16 GB recommended |
| **Installation model** | `native` or `podman` | — | Based on engine availability |
| **Engine & version** | MySQL 8.0, PostgreSQL 16, SQL Server 2022, Oracle 23ai, etc. | — | Determines install script |

## Before creating: cost check and approval

Summarize what you're about to create:

```
About to create on <CLOUD>:
  - VM: {VM_NAME} ({SKU}, 4 vCPU, 8 GB)
    Region: {REGION}
    OS disk: 64 GB
    Data disk: 128 GB (for Podman)
    Estimated cost: ~$60–80/month
  - Public IP: {IP_NAME}
  - Firewall rules (allow {DB_PORT} from your IP / Databricks CIDR)
  - Tags: purpose=lfc-test, owner={prefix}, removal_date=YYYY-MM-DD

Proceed? (yes/no)
```

Wait for explicit confirmation before calling cloud APIs.

## Prerequisites

- **Cloud CLI**: `az login` (Azure) or `gcloud auth login` (GCP)
- **SSH key**: `ssh-keygen -t rsa -b 4096 -f ~/.ssh/lfc_test_rsa -N ""`
- **Quotas**: Check regional vCPU limits
- **Network**: Ensure firewall rules can reach your Databricks workspace

## Create the VM

### Azure

See `references/azure-vm.md` for detailed Azure VM creation.

Quick command:

```bash
SUBSCRIPTION="<sub-id>"
RESOURCE_GROUP="forgedb-rg"     # or the user's own group: they are free to choose
LOCATION="eastus"
VM_NAME="jane-doe-mysql-vm-eastus-$(date +%s)"
VM_SIZE="Standard_B4ms"

az account set --subscription "$SUBSCRIPTION"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

az vm create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --image Ubuntu2204 \
  --size "$VM_SIZE" \
  --admin-username azureuser \
  --ssh-key-values ~/.ssh/lfc_test_rsa.pub \
  --data-disk-sizes-gb 128        # data disk at LUN 0: /dev/disk/azure/scsi1/lun0
```

### GCP

See `references/gcp-vm.md` for detailed GCP Compute Engine creation.

Quick command:

```bash
PROJECT="my-project"
ZONE="us-central1-a"
VM_NAME="jane-doe-mysql-vm-uscentral1-$(date +%s)"
VM_TYPE="n1-standard-4"

gcloud compute instances create "$VM_NAME" \
  --zone="$ZONE" \
  --machine-type="$VM_TYPE" \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --create-disk name="${VM_NAME}-data",device-name=data,size=128GB,type=pd-ssd   # /dev/disk/by-id/google-data
```

## Install the database

### Native packages

SSH into the VM and install:

```bash
# Get SSH command from cloud console or:
# Azure: az vm list-ip-addresses ...
# GCP: gcloud compute instances describe ...

ssh -i ~/.ssh/lfc_test_rsa azureuser@<VM_IP>

# Then see references/ for engine-specific install:
# references/install-native.md for MySQL, PostgreSQL, SQL Server
```

### Podman containers

For complex engines or multiple database versions:

1. **Format the data disk as XFS first**, mounted at `/var/lib/containers`: run the block in `references/disk-setup.md` right after the VM is created. It finds the disk by its stable path (not `/dev/sdb`, which on Azure is usually the temporary disk), never wipes a disk that already has a filesystem, and checks for XFS with `ftype=1`. Don't install Podman until it prints `OK`.
2. Install Podman and run the containers with `sudo` (rootful), so images and volumes are stored on the XFS disk: see `references/install-podman.md` for container examples (Oracle, DB2, Informix, MySQL, PostgreSQL, SQL Server).
3. **Large test databases:** don't populate one per person. Pull a shared master from object storage once, then clone it per test with XFS reflinks (instant), and throw the clone away or save it back: see `references/master-snapshots.md`.

## Configure for Lakeflow Connect

After the database is running, see the parent skill **lfc-source-setup** for engine-specific configuration:
- User creation and grants (via shared `references/engine-*.md`)
- CDC / Change Tracking setup
- Replication slot / publication creation

Quick commands in `references/configure-lfc.md`.

## Networking for Databricks serverless

> **Firewall rules:** use **lfc-source-firewall** to add your laptop IP and the workspace's serverless egress IPs (and classic compute egress, when the pipeline uses classic compute) to this database. It covers rule limits and keeps the rules in sync.

Databricks serverless must reach the VM's database via public IP.

### Azure: attach the VM to the shared NSG

Don't create per-VM rules. Attach the VM's NIC (or its subnet) to the region's shared NSG, whose rules already allow your laptop and the workspace's serverless egress on the Podman port range `30000-30063` (and SSH from the laptop only):

```bash
az network nsg list -g "$RESOURCE_GROUP" --query "[?location=='$LOCATION'].name" -o tsv     # the shared NSG for this region, if any
az network nic update -g "$RESOURCE_GROUP" -n <vm-nic> --network-security-group <shared-nsg>
```

If there's no shared NSG in the VM's region yet, or its rules are out of date (new laptop IP, new serverless ranges), set it up with **lfc-source-firewall** ([shared NSG](../lfc-source-firewall/references/azure.md#shared-nsg-vms-and-the-shared-vnet-set-up-once-reuse-everywhere)). A native install on the engine's own port needs that port in the NSG's rules too.

### GCP: VPC firewall rule on the VM's tag

Use **lfc-source-firewall** ([GCP steps](../lfc-source-firewall/references/gcp.md)) to create the `lfc-*` rules for the VM's network tag; every VM with that tag reuses them.

## Register the UC connection

### Create connection JSON (private file)

```bash
umask 077
cat > conn.json <<EOF
{"name": "<firstname><lastname>-mysql-vm", "connection_type": "MYSQL",
 "options": {"host": "<VM_PUBLIC_IP>", "port": "<published-port>", "user": "lfc_user", "password": "$(cat lfc_user.pw)"}}
EOF
```

### Create in Databricks

```bash
databricks connections create --json @conn.json --profile <PROFILE>
```

### Clean up

```bash
rm conn.json /tmp/podman-secrets/* 2>/dev/null
```

## Verify connection

Test the UC connection from Databricks SQL:

```sql
SELECT * FROM <connection_name>.information_schema.tables LIMIT 5;
```

## Lifecycle: stop, start, delete

**Stop:**
```bash
# Azure
az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"

# GCP
gcloud compute instances stop "$VM_NAME" --zone="$ZONE"
```

**Start:**
```bash
# Azure
az vm start --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"

# GCP
gcloud compute instances start "$VM_NAME" --zone="$ZONE"
```

**Delete:**
```bash
# Azure
az vm delete --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --yes

# GCP
gcloud compute instances delete "$VM_NAME" --zone="$ZONE" --quiet
```

For more details, see `references/lifecycle.md`.

## Top gotchas

1. **SSH connection refused**: Verify public IP, SSH key, and firewall allows port 22 from your IP. See `references/troubleshooting.md`.

2. **Database port not reachable from Databricks**: Verify database is running, bind address is `0.0.0.0`, and firewall/NSG allows workspace serverless CIDR. See `references/troubleshooting.md`.

3. **Podman image pull timeout**: Large images (Oracle ~5 GB) may timeout on slow networks. Increase timeout or use a mirror.

4. **Podman data not on XFS**: format the data disk by its stable path (`/dev/disk/azure/scsi1/lun0`, `/dev/disk/by-id/google-data`), never `/dev/sdb`, and check `findmnt -no FSTYPE /var/lib/containers` says `xfs` before installing Podman. See `references/disk-setup.md`.

5. **CDC/Change Tracking not capturing**: Verify replication mode enabled in database config and LFC user has required permissions. See parent skill `references/engine-*.md`.

## Additional resources

- **Parent skill**: [lfc-source-setup](../lfc-source-setup/SKILL.md) — engine-specific configuration
- **VM creation**: [azure-vm.md](references/azure-vm.md), [gcp-vm.md](references/gcp-vm.md)
- **Database install**: [install-native.md](references/install-native.md), [install-podman.md](references/install-podman.md)
- **Reusable master database** (object storage + XFS clones): [master-snapshots.md](references/master-snapshots.md)
- **Configuration**: [configure-lfc.md](references/configure-lfc.md)
- **Lifecycle**: [lifecycle.md](references/lifecycle.md)
- **Troubleshooting**: [troubleshooting.md](references/troubleshooting.md)
