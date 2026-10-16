#!/bin/bash
# disk-setup.sh (DISK=<stable device path> MNT=<mount point>): run on the VM, e.g.
#   ssh <host> DISK=/dev/disk/azure/scsi1/lun0 MNT=/var/lib/containers 'bash -s' < disk-setup.sh
# Formats a blank data disk as XFS with reflink (ftype=1), mounts it by UUID through /etc/fstab, and checks it. Safe to
# rerun: keeps a disk that's already XFS, and stops on any other filesystem rather than wiping it.
set -e
[ -b "$DISK" ] || { echo "no disk at $DISK: check it's attached (lsblk)"; exit 1; }
DEV=$(readlink -f "$DISK")
case "$(sudo blkid -s TYPE -o value "$DEV" || true)" in
  xfs) echo "$DEV is already XFS: keeping it" ;;
  "")  command -v mkfs.xfs > /dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq xfsprogs; }
       sudo mkfs.xfs -n ftype=1 -m reflink=1 "$DEV" ;;       # no -f: refuses a disk with a partition table
  *)   echo "$DEV already has a $(sudo blkid -s TYPE -o value "$DEV") filesystem: not formatting it"; exit 1 ;;
esac
UUID=$(sudo blkid -s UUID -o value "$DEV")
sudo mkdir -p "$MNT"
grep -q "UUID=$UUID" /etc/fstab || echo "UUID=$UUID $MNT xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab > /dev/null
findmnt "$MNT" > /dev/null || sudo mount "$MNT"
[ "$(findmnt -no FSTYPE "$MNT")" = xfs ] && sudo xfs_info "$MNT" | grep -q 'ftype=1' \
  || { echo "FAIL: $MNT is not XFS with ftype=1"; exit 1; }
echo "OK: $MNT is XFS (ftype=1) on $DEV"
