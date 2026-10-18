# 2026-10-17: Azure end to end on a workspace with classic compute

The Lakeflow Connect test matrix on an Azure sandbox workspace in centralus that has both classic and serverless compute, against the four sources on the Azure test VM. Records: `recall.py --run 2026-10-17-azure-classic --all`.

**Sources:** the Azure test VM, rebuilt in zone 1 from snapshots of the old VM's disks; its data disk is now Premium SSD v2 (128 GiB, 3,000 IOPS, 125 MB/s; fio: 3,340 random-write and 3,083 random-read 4k IOPS, 135 MB/s sequential, about the same as AWS gp3). MySQL 8.4, PostgreSQL 16, SQL Server 2022 and Oracle 23ai Free hold the test tables (`intpk`, `dtix`). JuiceFS had been mounted by hand on the old VM, with no fstab entry, so it was mounted again by hand. **Connections:** the existing `<firstname><lastname>-<engine>-azvm` connections in this workspace's metastore, updated to the new VM's address with lfc-connection-sync, plus `-orapdb-azvm` on `FREEPDB1` for Oracle query-based ingestion.

**Workspace check (`ready.sh`):** serverless on; classic available (`Azure worker environment does not support zones`), you can create clusters (admin); the default catalog writable, with its own storage; `CREATE CONNECTION` and `CREATE CATALOG` present, unlike the two earlier Azure workspaces; the Oracle integrated CDC preview was off and was turned on. The VM's NSG already allowed all 31 of the region's serverless egress ranges, but not the workspace's classic egress IP.

## Lakeflow Connect

| Engine | QBC | QBC via foreign catalog | Integrated CDC | Standard CDC |
|---|---|---|---|---|
| MySQL 8.4 | ✅ 11/11 | ✅ 11/11 | ❌ unset → classic, couldn't reach the source; ✅ 11/11 with `serverless: true` | ⛔ not enabled |
| PostgreSQL 16 | ✅ 10/10 | ✅ 10/10 | — (none; the skill stopped) | ⛔ not enabled |
| SQL Server 2022 | ✅ 11/11 | ✅ 11/11 | ❌ unset → classic, couldn't reach the source; ✅ 11/11 with `serverless: true` | ❌ unset → classic gateway; ✅ 11/11 with a serverless gateway |
| Oracle 23ai Free | ✅ 11/11 | ✅ 11/11 | ✅ 11/11 (the session set `serverless: true`) | — (none) |

Every pipeline logged one warning: lineage to the source wasn't recorded, because the user lacks `CREATE EXTERNAL METADATA` on the metastore. Ingestion wasn't affected.

## `serverless` left unset on a workspace with classic compute

The first run followed the skill as it then was: leave `serverless` unset. Read back with `pipelines get-update` (`update.config.serverless`):

| Pipeline | Unset | `serverless: true` |
|---|---|---|
| Query-based (all four) | serverless | not needed |
| Integrated CDC, MySQL and SQL Server | **classic**, its own cluster | serverless, 11/11 |
| Standard CDC gateway, SQL Server | **classic** | serverless, gateway and applier 11/11 |

On AWS, only query-based pipelines and the gateway were checked unset; integrated CDC wasn't. So "integrated CDC defaults to serverless" was wrong on this workspace.

**Two different failures.**

- **Compute not allowed:** at create, in seconds (seen on AWS: `You must use serverless compute in this workspace.` for a gateway on a serverless-only workspace).
- **Compute up, source unreachable:** here. The update waited for its classic cluster, then logged `Extractor STARTED`, and 40 to 80 seconds later `Extractor FAILED` with `INGESTION_GATEWAY_CONNECTION_ERROR.INCORRECT_SOURCE_HOSTNAME_OR_PORT_SPECIFIED_FAILURE ... Could not connect to the source database`, with the IP's last octet masked as `0`. Host and port were right; the NSG didn't allow the classic egress IP. `remote_query` on the same connection, which runs on serverless, still worked.

**Startup time** (`WAITING_FOR_RESOURCES` until `INITIALIZING`, from the event log):

| Compute | Wait |
|---|---|
| Classic, integrated CDC | 7 min 40 s to 8 min 10 s |
| Serverless, pipelines and gateway | 10 s to 1 min 20 s; 3 min 50 s once, for the first serverless start on the workspace |

The CDC sessions ended before the classic failure appeared, so they reported success; the failures were found afterwards in the event logs.

## What changed in the skills

| Problem | Fix |
|---|---|
| Unset, integrated CDC and the gateway ran on classic, which couldn't reach the source | databricks-lakeflow-connect, `2-database-connectors.md`: still leave `serverless` unset everywhere and take the default, read it back, and set the opposite if it fails; the Azure row is in its table. The test prompts now set `serverless: true` on every pipeline and gateway, because the test firewall allows only the serverless ranges (MATRIX.md, "Workspace requirements") |
| The late connection error points at the host | the same reference: the two failure kinds, and to read `update.config.serverless` before checking the host |
| `ready.sh` said integrated CDC runs serverless on a classic workspace | its compute hints now say CDC pipelines and gateways may run classic there, and to set `serverless: true` if one can't reach the source |

## Cleanup

All test pipelines and both gateways were stopped; nothing is left running in the workspace. The VM was deallocated afterwards.
