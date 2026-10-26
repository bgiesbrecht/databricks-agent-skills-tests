# Removing the VM

### Remove the VM, and get the laptop's disk back

The VM's disk is one file on the laptop: `podman machine` keeps it under `~/.local/share/containers/podman/machine/<provider>/` (for example `podman-machine-default-arm64.raw`), Lima under `~/.lima/<name>/`. It's sparse, so it grows as the databases inside it write, and it **doesn't shrink** when you drop tables or containers in the VM. Check how much it really takes with `du -h <image>`, not `ls -l`. To give the space back, remove the whole VM, in this order:

```bash
podman machine stop && podman machine rm          # or: limactl stop lfc-test-podman && limactl delete lfc-test-podman
df -h /                                            # the space is back once the VM process has exited
```

**Never delete those folders while the VM runs.** A running VM keeps its disk file open: deleting it doesn't free the space, the VM goes on writing to it, and no folder shows it any more, so the disk fills while `du` finds nothing big. Seen in practice: `rm -rf ~/.local/share/containers` with the machine running left a 50 GB image held open by Apple's virtualization service; the laptop ran out of space repeatedly over a day, and stopping the VM gave back about 55 GB. With the files gone, `podman machine stop` can't reach the VM (`failed to read identity ... machine: no such file or directory`), so find it and stop its processes:

```bash
lsof +L1 -nP 2>/dev/null | grep -iE '\.raw|\.img|podman|lima'                 # deleted files still open, with the pid
for p in $(pgrep -f 'Virtualization.VirtualMachine'); do lsof -nP -p $p | grep -E '\.raw|\.img'; done
pgrep -fl 'vfkit|krunkit|gvproxy|qemu|limactl'                                  # the VM's own processes
kill <vfkit-or-krunkit-pid> <gvproxy-pid>                                       # Lima: limactl stop --force <name>
```

Watch the result with `df -k /` a minute apart: the space comes back as the virtualization service exits, sometimes in two steps.
