# Master databases on local storage

## Reusable master database (local storage)

Load a large test database once, keep the stopped data directory as a master, and clone it for each test instead of reloading it. Locally, the master stays on the Podman VM's own disk: no object storage, no rclone. (For cloud VMs shared by several people, keep masters in object storage instead: see **lfc-source-cloud-vm** `references/master-snapshots.md`.)

Run these inside the Podman VM as root: `podman machine ssh 'sudo bash -s' < steps.sh` (Podman machine) or `limactl shell lfc-test-podman sudo bash -s < steps.sh` (Lima).

```bash
D=/var/lib/lfc-data; NAME=<master-name>        # for example pg16-orders
findmnt -no FSTYPE --target /var                # xfs: clones are instant; ext4: --reflink=auto makes full copies
mkdir -p $D/masters
# Master: run the database with its data directory at $D/masters/$NAME, load it, then stop it cleanly
podman stop -t 60 <container>; podman rm <container>
# Each test: clone, run
cp -a --reflink=auto $D/masters/$NAME $D/run-1
podman run -d --name <container> -v $D/run-1:/var/lib/postgresql/data:Z ... docker.io/library/postgres:16
```

When the test is done, stop the container (`podman stop -t 60 <container>; podman rm <container>`), then either throw the clone away (`rm -rf $D/run-1`) or keep it as a new master (`mv $D/run-1 $D/masters/$NAME-v2`).

- **Clone speed depends on the VM's filesystem.** Podman machine on macOS (Fedora CoreOS) has an XFS `/var` with reflinks: a 510 MB Postgres master cloned in 0.03 s. Lima's default disk is ext4, so `--reflink=auto` falls back to a full copy.
- **Keep the master and its clones on the same filesystem** (both under `$D`). Reflinks can't cross filesystems; `/tmp` is tmpfs on Podman machine.
- **Always stop the database cleanly** before cloning, keeping, or deleting its files.
- Use `:Z` on the volume: Podman machine enforces SELinux, and without it the database can't open its data directory.
