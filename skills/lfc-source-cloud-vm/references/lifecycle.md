# VM Lifecycle Management

## Stop VM (pause compute charges)

**Azure:**
```bash
az vm deallocate \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME"
```

**GCP:**
```bash
gcloud compute instances stop "$VM_NAME" --zone="$ZONE"
```

Storage charges continue while the VM is stopped.

## Start VM

**Azure:**
```bash
az vm start \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME"

# Get new public IP (may change)
eval "$(az vm list-ip-addresses \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" -o json \
  | yq -p json -o shell '{"AZURE_PUBLIC_IP": (.[0].virtualMachine.network.publicIpAddresses[0].ipAddress // "")}')"
echo "VM now at: $AZURE_PUBLIC_IP"
```

**GCP:**
```bash
gcloud compute instances start "$VM_NAME" --zone="$ZONE"

# Get public IP
eval "$(gcloud compute instances describe "$VM_NAME" \
  --zone="$ZONE" --format=json \
  | yq -p json -o shell '{"GCP_PUBLIC_IP": (.networkInterfaces[0].accessConfigs[0].natIP // "")}')"
echo "VM now at: $GCP_PUBLIC_IP"
```

## Delete VM and all resources

### Azure

```bash
# Delete VM
az vm delete \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --yes

# Delete disks explicitly if not auto-deleted
az disk delete \
  --resource-group "$RESOURCE_GROUP" \
  --name "${VM_NAME}-os" \
  --yes

az disk delete \
  --resource-group "$RESOURCE_GROUP" \
  --name "${VM_NAME}-data" \
  --yes

# Optional: delete resource group if no longer needed
az group delete \
  --name "$RESOURCE_GROUP" \
  --yes
```

### GCP

```bash
# Delete instance (disks auto-deleted)
gcloud compute instances delete "$VM_NAME" \
  --zone="$ZONE" \
  --quiet
```

## Delete UC connection

After deleting the VM, remove the UC connection from Databricks:

```bash
databricks connections delete "jane-doe-mysql-vm-<epoch>" --profile <PROFILE>
```

## Cleanup checklist

- [ ] Stop the VM (if pausing, not deleting)
- [ ] Delete the VM and disks
- [ ] Delete the UC connection in Databricks
- [ ] Remove firewall/NSG rules (if they were VM-specific)
- [ ] Delete password files locally: `rm admin.pw lfc_user.pw /tmp/podman-secrets/*`
- [ ] Remove resource group (Azure only, if applicable)
