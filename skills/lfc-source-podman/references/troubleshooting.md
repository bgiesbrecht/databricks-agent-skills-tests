# Troubleshooting

## Common issues

1. **Container name too long:** Names must be ≤ 63 characters. Use a shorter prefix (e.g., `jd` instead of `jane-doe-test`).

2. **Oracle hostname validation:** Oracle may reject underscores in container hostnames. Container names use hyphens only.

3. **The VM's disk fills up**: every row loaded is also written to the engine's change log (MySQL binary logs, Postgres WAL), which CDC needs and so is kept: 25 GB of binary logs filled a 50 GB `podman machine` in testing, and Podman itself then fails (`no space left`). Check with `podman machine ssh df -h /`. Without a CDC reader on the container, purge them (`PURGE BINARY LOGS BEFORE NOW()`, or `SET PERSIST binlog_expire_logs_seconds = 86400`); with one, give the VM more disk (`podman machine init --disk-size`) instead.

4. **Port already in use:** If port `30001` is already bound, pick a free port ≥30000. Check with `podman port {container-name}` or `ss -tlnp | grep 30001`.

5. **Lima VM frozen or unresponsive (macOS):**

   ```bash
   limactl stop lfc-test-podman
   limactl start lfc-test-podman
   ```

6. **SQL Server or Oracle taking > 10 min to start:** Normal for first run. Monitor with `podman logs {container-name}`.

7. **UC connection fails ("Authentication failed"):** Verify the password is correct by connecting directly with SQL client. If direct connection works but UC fails, check that the password in the connection file is exactly the same and has no trailing whitespace.
8. **The laptop's disk keeps filling, and nothing big shows up:** a VM whose disk file was deleted while it ran is still writing to it. See [Remove the VM, and get the laptop's disk back](remove-vm.md#remove-the-vm-and-get-the-laptops-disk-back). If Podman Desktop is installed, it may have started a VM you didn't: **podman-desktop-remove** reports every machine and its disk use.
