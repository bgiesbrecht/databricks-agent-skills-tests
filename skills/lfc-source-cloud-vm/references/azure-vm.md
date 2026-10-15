# Azure VM Creation

## Variables

```bash
SUBSCRIPTION="<your-subscription-id>"
RESOURCE_GROUP="forgedb-rg"     # or the user's own group: they are free to choose
LOCATION="eastus"
VM_NAME="jane-doe-mysql-vm-eastus-1779207800"
VM_SIZE="Standard_B4ms"              # 4 vCPU, 16 GB
SSH_KEY_PATH="$HOME/.ssh/lfc_test_rsa.pub"
OS_DISK_GB="64"
DATA_DISK_GB="128"
```

## Create VM

```bash
az account set --subscription "$SUBSCRIPTION"

# Create resource group
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

# Create VM with OS disk + data disk
az vm create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --image Ubuntu2204 \
  --size "$VM_SIZE" \
  --os-disk-size-gb "$OS_DISK_GB" \
  --os-disk-name "${VM_NAME}-os" \
  --admin-username azureuser \
  --ssh-key-values "$SSH_KEY_PATH" \
  --public-ip-sku Standard \
  --output table

# Attach data disk
az vm disk attach \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --name "${VM_NAME}-data" \
  --new \
  --size-gb "$DATA_DISK_GB" \
  --sku Premium_LRS \
  --lun 0

# Get public IP
eval "$(az vm list-ip-addresses \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" -o json \
  | yq -p json -o shell '{"AZURE_PUBLIC_IP": (.[0].virtualMachine.network.publicIpAddresses[0].ipAddress // "")}')"

echo "VM ready at: $AZURE_PUBLIC_IP"
```

Next, for Podman: format the data disk (LUN 0, `/dev/disk/azure/scsi1/lun0`) as XFS with the block in [disk-setup.md](disk-setup.md), before installing anything. Don't use `/dev/sdb`: on this size it's the temporary disk.

## Add labels

```bash
az vm update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --set "tags={purpose=lfc-test,owner=jane-doe,removal_date=2025-02-15}"
```
