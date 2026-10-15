# Disk Setup for Podman and Native Databases

## For Podman: XFS Data Graphroot

Podman requires an XFS filesystem for its graphroot at `/var/lib/containers`. The data disk attached during VM creation must be formatted and mounted.

### SSH into VM

```bash
# Azure
ssh -i ~/.ssh/lfc_test_rsa azureuser@${AZURE_PUBLIC_IP}

# GCP
ssh -i ~/.ssh/lfc_test_rsa ubuntu@${GCP_PUBLIC_IP}
```

### Find the extra disk

```bash
lsblk -dn -o NAME,SIZE,TYPE | grep -v sda1
```

Output should show `/dev/sdb` or similar (the data disk).

### Format XFS

```bash
DISK="/dev/sdb"  # Adjust if your disk has a different name

# Install xfsprogs
sudo apt-get update && sudo apt-get install -y xfsprogs

# Format XFS (ftype=1 required for Podman overlay2 driver; reflink=1 for COW)
sudo mkfs.xfs -f -n ftype=1 -m reflink=1 "$DISK"

# Create mount directory
sudo mkdir -p /var/lib/containers

# Mount
sudo mount "$DISK" /var/lib/containers

# Make permanent via fstab
UUID=$(sudo blkid -s UUID -o value "$DISK")
echo "UUID=$UUID /var/lib/containers xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab

# Verify mount
mount | grep containers
```

## For Native Databases: Use OS Disk

Native MySQL, PostgreSQL, and SQL Server packages use the OS disk for database files. Ensure `/` has at least 50 GB free:

```bash
df -h /
```

The 64 GB OS disk allocated during VM creation should be sufficient for test databases.

## Advanced: Separate data volume for native databases

If you need to separate database files from the OS:

```bash
# Mount the data disk at /var/lib/mysql (for example)
sudo mkdir -p /var/lib/mysql

sudo mount /dev/sdb /var/lib/mysql

# Ensure directory ownership (MySQL example)
sudo chown mysql:mysql /var/lib/mysql
sudo chmod 750 /var/lib/mysql
```

For production, consider ext4 or xfs with proper tuning. Test environments can use the default ext4.
