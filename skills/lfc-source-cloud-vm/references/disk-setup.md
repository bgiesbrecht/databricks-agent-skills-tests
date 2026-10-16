# Disk Setup for Podman and Native Databases

## For Podman: XFS data disk at `/var/lib/containers`

**Every Podman VM puts its data on an XFS data disk**, mounted at `/var/lib/containers`, before Podman is installed. That's where rootful Podman keeps images, containers, and named volumes (the database files), so all of it lands on XFS. Format with `ftype=1` (required by the overlay driver) and `reflink=1` (cheap copies).

Find the disk by its **stable path**, never by `/dev/sdb`. On Azure, `/dev/sdb` is usually the VM's temporary resource disk (on sizes like `Standard_B4ms`), which is wiped when the VM is deallocated; device letters can also change between boots.

| Cloud | Data disk path |
|---|---|
| Azure, disk at LUN 0 (`az vm disk attach --lun 0` or `--data-disk-sizes-gb`) | `/dev/disk/azure/scsi1/lun0` |
| Azure, NVMe sizes (v6 and later) | `/dev/disk/azure/data/by-lun/0` |
| GCP, created with `device-name=data` | `/dev/disk/by-id/google-data` |

Run [`scripts/disk-setup.sh`](../scripts/disk-setup.sh) from the laptop right after the VM is created. It's safe to rerun: it formats only a blank disk, keeps a disk that's already XFS, and stops on any other filesystem rather than wiping it.

```bash
# Azure: USER_HOST=azureuser@$AZURE_PUBLIC_IP DISK=/dev/disk/azure/scsi1/lun0
# GCP:   USER_HOST=ubuntu@$GCP_PUBLIC_IP     DISK=/dev/disk/by-id/google-data
ssh -i ~/.ssh/lfc_test_rsa "$USER_HOST" DISK="$DISK" MNT=/var/lib/containers 'bash -s' < skills/lfc-source-cloud-vm/scripts/disk-setup.sh
```

If `/var/lib/containers` already has content on the OS disk (Podman was installed first), stop Podman, move it aside (`sudo mv /var/lib/containers /var/lib/containers.old`), then run the script, which mounts the XFS disk in its place.

After installing Podman, confirm it's using that disk:

```bash
ssh -i ~/.ssh/lfc_test_rsa "$USER_HOST" \
  'sudo podman info --format "{{.Store.GraphRoot}} {{.Store.GraphDriverName}}"; findmnt -no FSTYPE --target /var/lib/containers/storage'
# /var/lib/containers/storage overlay
# xfs
```

Always run Podman with `sudo`. Rootless Podman stores everything under `~/.local/share/containers`, on the OS disk, not on XFS.

## For Native Databases: Use OS Disk

Native MySQL, PostgreSQL, and SQL Server packages use the OS disk for database files. Ensure `/` has at least 50 GB free:

```bash
df -h /
```

The 64 GB OS disk allocated during VM creation should be sufficient for test databases.

## Advanced: Separate data volume for native databases

To keep a native database's files off the OS disk, use the same block with `MNT` set to the database's data directory (for example `MNT=/var/lib/mysql`), **before** installing the database package. Then set ownership after install (`sudo chown mysql:mysql /var/lib/mysql && sudo chmod 750 /var/lib/mysql`).
