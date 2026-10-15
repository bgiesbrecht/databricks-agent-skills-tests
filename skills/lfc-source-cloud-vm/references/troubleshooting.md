# Troubleshooting

## SSH connection refused

**Symptom:** `Permission denied (publickey)` or `Connection refused`

**Check:**
- Verify the public IP from cloud console
- Verify SSH key path and permissions: `ls -la ~/.ssh/lfc_test_rsa`
- Check firewall/NSG allows SSH (port 22) from your IP
- Try verbose SSH: `ssh -i ~/.ssh/lfc_test_rsa -vvv azureuser@<IP>`

**Fix:**
```bash
# Regenerate SSH key
ssh-keygen -t rsa -b 4096 -f ~/.ssh/lfc_test_rsa -N ""

# Tear down and recreate the VM with the new key
```

## Database port not reachable from Databricks

**Symptom:** LFC pipeline times out connecting to database

**Check:**
1. Verify database is running:
   ```bash
   sudo systemctl status mysql   # or postgresql, mssql-server
   sudo podman ps                 # for containers
   ```

2. Verify it's listening on the correct interface:
   ```bash
   sudo netstat -tuln | grep 3306  # MySQL
   sudo netstat -tuln | grep 5432  # PostgreSQL
   sudo netstat -tuln | grep 1433  # SQL Server
   ```

3. Verify bind_address is `0.0.0.0`, not `127.0.0.1` or `localhost`

4. Verify firewall/NSG rule exists and covers Databricks serverless CIDR:
   ```bash
   # Azure NSG rules
   az network nsg rule list \
     --resource-group "$RESOURCE_GROUP" \
     --nsg-name lfc-test-nsg \
     --query "[*].{name:name, sourceAddressPrefix:sourceAddressPrefix, destinationPortRange:destinationPortRange}"

   # GCP firewall rules
   gcloud compute firewall-rules list --filter="allow-db"
   ```

**Fix:**
```bash
# Ensure database is running
sudo systemctl restart mysql   # MySQL
sudo systemctl restart postgresql  # PostgreSQL
sudo podman restart <container>  # Podman

# Restart database after bind_address change
sudo systemctl restart mysql
```

## Podman image pull timeout

**Symptom:** `podman pull` hangs or fails after timeout

**Cause:** Large images (Oracle ~5 GB) or slow network connection

**Fix:**
```bash
# Increase timeout to 10 minutes
sudo podman pull --timeout 10m container-registry.oracle.com/database/free:latest
```

## XFS formatting fails

**Symptom:** the disk block in [disk-setup.md](disk-setup.md) stops with `no disk at ...`, `already has a ... filesystem`, or `FAIL: /var/lib/containers is not XFS`.

**Check:**
- The disk is attached at the expected LUN or device name: `lsblk -o NAME,SIZE,TYPE,MOUNTPOINT`, `ls -l /dev/disk/azure/scsi1/` (Azure) or `ls -l /dev/disk/by-id/ | grep google-` (GCP).
- What's on it: `sudo blkid "$(readlink -f <disk-path>)"`. The block never formats a disk that already has a filesystem. Don't wipe it unless the user confirms it holds nothing they need.
- On Azure, `/dev/sdb` is usually the temporary resource disk. If an older run formatted that, the data was on a disk that's wiped on deallocate: rerun the block with the LUN path.

**Fix (Azure, disk not attached):**
```bash
az vm disk attach \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --name "${VM_NAME}-data" \
  --new \
  --size-gb 128 \
  --sku Premium_LRS \
  --lun 0
```

Then rerun the disk block; no reboot is needed.

## LFC CDC not capturing changes

**Symptom:** Rows inserted into the source table are not appearing in Databricks

**Check:**
1. Verify the replication mode is enabled:
   ```bash
   # MySQL
   mysql -u lfc_user -p -e "SHOW MASTER STATUS;"

   # PostgreSQL
   psql -U lfc_user -d lfc_test_db -c "SELECT setting FROM pg_settings WHERE name='wal_level';"

   # Oracle
   sqlplus "SHOW PARAMETER log_archive_dest"
   ```

2. Verify the LFC user has replication privileges (see parent skill `references/engine-*.md`)

**Fix:**
- Enable replication in database config (see `configure-lfc.md`)
- Restart database after config changes:
  ```bash
  sudo systemctl restart mysql
  sudo systemctl restart postgresql
  sudo podman restart <container>
  ```

## Container permission errors

**Symptom:** `podman run: permission denied: /var/lib/containers`

**Cause:** running `podman` without `sudo`. Rootless Podman can't use `/var/lib/containers`, and it would store data on the OS disk instead of the XFS disk.

**Fix:** run every Podman command with `sudo` (`sudo podman run …`).

## VM disk fills up

**Symptom:** Database slows or fails to start; "no space left on device"

**Check:**
```bash
df -h /
du -sh /var/lib/containers/*   # Podman
du -sh /var/lib/mysql/*         # MySQL native
```

**Fix:**
- Add another data disk
- Archive or delete old container/database snapshots
- Clean up log files

## Firewall rule syntax errors

**Azure NSG:**
```bash
# Verify rule was created
az network nsg rule show \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name lfc-test-nsg \
  --name "Allow-DB-Port"
```

**GCP:**
```bash
# Verify firewall rule
gcloud compute firewall-rules describe allow-db-inbound
```

## Permission denied when executing SQL

**Symptom:** SQL client connects but commands fail with "permission denied" or "access denied"

**Check:**
- Verify LFC user has required grants (see parent skill `references/engine-*.md`)
- Verify password is correct (doesn't match admin password)
- For SQL Server, verify user is in the correct role

**Fix:**
- Reconnect with correct credentials
- Run grants again as admin user (see parent skill)
