# Images on Apple Silicon, and Rosetta

**Which image runs how on Apple Silicon.** Every engine runs in the Lima VM. Use the arm64 image wherever one exists, and Rosetta only for x86_64-only images:

| Engine | Image on macOS | Runs as |
|---|---|---|
| PostgreSQL, MySQL, MariaDB, MongoDB | Docker Hub official images | arm64, native |
| Oracle 23ai / 26ai Free | `docker.io/gvenzl/oracle-free:latest` (default), or `container-registry.oracle.com/database/free:latest` | arm64, native |
| Oracle 19c Enterprise | `container-registry.oracle.com/database/enterprise:19.19.0.0` (needs `podman login`) | arm64, native |
| Oracle 18c / 21c XE | `docker.io/gvenzl/oracle-xe:18` / `:21` | x86_64, Rosetta |
| SQL Server 2017–2025 | `mcr.microsoft.com/mssql/server:<version>-latest` | x86_64, Rosetta (2025 needs a Lima kernel of 6.17 or later) |
| Db2, Informix | `icr.io` images | x86_64, Rosetta |

**Register Rosetta with the preserve-argv0 flag** (`P`), once per VM. Lima registers it with `OCF`, which drops a program's `argv[0]`: then `su -` in an x86_64 container isn't a login shell, never reads the user's profile, and Db2's setup (which runs everything through `su - db2inst1`) fails with `db2: command not found`. Check `grep flags /proc/sys/fs/binfmt_misc/rosetta` in the VM (`limactl shell lfc-test-podman`); to fix it at every boot, add this to `~/.lima/lfc-test-podman/lima.yaml` and restart the VM (`limactl stop` / `start`). Tested: `flags: POCF` after the restart, and Db2 then set up cleanly.

```yaml
provision:
- mode: system
  script: |
    #!/bin/bash
    f=/proc/sys/fs/binfmt_misc/rosetta
    for i in $(seq 30); do [ -e $f ] && break; sleep 1; done
    [ -e $f ] && ! grep -q "flags: P" $f || exit 0
    M=$(awk '/^magic/ {print $2}' $f); K=$(awk '/^mask/ {print $2}' $f); I=$(awk '/^interpreter/ {print $2}' $f)
    hex() { echo "$1" | sed 's/../\\x&/g'; }
    echo -1 > $f
    printf ':rosetta:M::%s:%s:%s:POCF' "$(hex $M)" "$(hex $K)" "$I" > /proc/sys/fs/binfmt_misc/register
```

**Tested together** on a MacBook (Apple Silicon, 32 GB) in one 4-CPU, 10 GiB Lima VM: SQL Server 2022, Db2 11.5 and Informix 14.10 under Rosetta and Oracle 26ai Free on arm64 side by side, each reached from the Mac on `127.0.0.1`, and each filled with TPC-H SF 1 (8,660,030 rows) inside the database by **lfc-source-datagen**: SQL Server in 202 s (as fast as a 4-vCPU Azure VM: 179 s), Oracle in 320 s.

Don't run x86_64-only engines in Podman machine (`podman machine`): its Fedora CoreOS kernel (6.12) crashes SQL Server 2025 with an AVX signal-frame bug, and Podman is deprecating its Rosetta support. The Lima VM's newer kernel doesn't have these bugs, and Lima keeps Rosetta: running SQL Server on macOS is the same as running its container in Podman on Lima.
