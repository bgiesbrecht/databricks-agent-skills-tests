# Disk I/O limits: predict when a load or a CDC test is disk-bound

A database load writes to the VM's data disk, and in the cloud that disk has a provisioned ceiling: a number of I/O operations per second (IOPS) and a throughput (MB/s). The VM has a ceiling of its own. The lower of the two is what the database gets, however many vCPUs it has. Seen in practice: the same MySQL TPC-E SF 1 fill took 1,173 s on an AWS gp3 volume and 3,857 s on an Azure P10 disk, whose writes sat at exactly 500 per second, 100% busy, 119 ms each (`iostat -x`).

## The limits

| Where | Disk or VM | IOPS | MB/s | Burst | Changes |
|---|---|---|---|---|---|
| Azure | Premium SSD **P10** (128 GiB) | 500 | 100 | 3,500 IOPS / 170 MB/s for up to 30 min, from credits | Fixed by size: P15 1,100 / 125, P20 2,300 / 150, P30 5,000 / 200 (P30 and up: paid on-demand bursting to 30,000 / 1,000) |
| Azure | Premium SSD **v2** (any size) | 3,000 included, up to 500 per GiB (80,000) | 125 included, up to 2,000 | none: what you provision | IOPS and MB/s set independently of size, online |
| Azure | VM **Standard_D4s_v5** | 6,400 | 145 | 20,000 / 1,200 (credits) | D8s_v5: 12,800 / 290 |
| AWS | **gp3** (any size) | 3,000 included, up to 500 per GiB (80,000) | 125 included, up to 2,000 (0.25 MB/s per provisioned IOPS) | none | Elastic Volumes: raise IOPS / MB/s online (then about 6 h before the next change) |
| AWS | gp2, for contrast | 3 per GiB (100 to 16,000) | up to 250 | 3,000 IOPS from credits, below 1 TiB | by size |
| AWS | VM **m6i.xlarge** | not verified here | not verified here | instance EBS bursts last 30 min per 24 h | larger sizes |

The effective limit is `min(disk, VM)`. Sources: [Azure disk types](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types), [Azure premium storage performance](https://learn.microsoft.com/en-us/azure/virtual-machines/premium-storage-performance), [Dv5 series](https://learn.microsoft.com/en-us/azure/virtual-machines/dv5-series), [EBS volume types](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-volume-types.html), [EC2 general purpose instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/general-purpose.html). Check prices in each cloud's calculator for your region.

**The trap is Azure Premium SSD v1 at a small size:** its IOPS come with its size, so the 128 GiB disk that's plenty of space is a 500-IOPS disk, six times slower to write than the AWS default. A small burst bucket hides it for the first half hour, so short tests look fine and a long load stalls.

Measured on that P10 (Azure Monitor, `Composite Disk Write Operations/sec`, 5-minute averages): short tests with idle time between them ran at up to **1,426 writes/s**, on burst credits; four hours of back-to-back master builds never got above **~500** once the bucket was empty. The same Oracle TPC-H SF 1 fill took 585 s in a short test and 676 s inside the long run. So **time a load on a burstable disk the way it will really run**, or after the bucket is drained (a 30-second `fio` right after the builds, with the bucket partly refilled, read its burst ceiling: 3,482 IOPS and 165 MB/s); gp3 doesn't burst (it delivers what's provisioned all the time), so its short and long runs agree.

```bash
# the disk's write rate, 5-minute averages (az disk commands may fail on a CLI with a broken compute api-version; this doesn't)
az monitor metrics list --resource /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/disks/<disk> \
  --metrics "Composite Disk Write Operations/sec" --interval PT5M --aggregation Average --start-time <ISO time>
```

## Is this load disk-bound?

Watch the data disk while it runs (`iostat -x 5`, the device of `/var/lib/containers`):

1. **IOPS-bound** when `w/s` (plus `r/s`) is flat at the disk's IOPS: 500 on a P10, 3,000 on a default gp3.
2. **Throughput-bound** when `wkB/s` is flat at the disk's MB/s. The average write is `wkB/s / w/s`: bulk loads write large blocks (a P10 at 500 writes of 30 kB is IOPS-bound at only 15 MB/s).
3. **Either way**, `%util` near 100 and `w_await` far above a few milliseconds confirm it, while the CPUs (`top`) sit partly idle.

Then lift the limit that binds, cheapest first: on Azure, a **Premium SSD v2** data disk (the default in this skill's Azure steps) (3,000 IOPS and 125 MB/s included, at any size; more provisioned without resizing) instead of a P10; on AWS, raise the gp3's IOPS or MB/s online. A bigger VM doesn't help until the disk is no longer the limit.

## Measured

| Host | Disk | 4k random write | 4k random read | 1 MB sequential write | TPC fill: MySQL TPC-E SF 1 |
|---|---|---|---|---|---|
| MacBook (Apple Silicon), Lima VZ VM | virtio on APFS | 3,585 IOPS | 270,103 IOPS | 192 MB/s | 921 s |
| Azure D4s_v5 | P10, 128 GiB | 3,482 IOPS on credits (500 baseline) | 8,848 IOPS (host read cache) | 165 MB/s on credits | 3,857 s |
| AWS m6i.xlarge | gp3, 128 GiB, default | 3,096 IOPS | 3,027 IOPS | 129 MB/s | 1,173 s |

`fio --direct=1 --ioengine=libaio --iodepth=32` (8 for the sequential write), 30 s each, on the disk that holds `/var/lib/containers`. Every engine and workload: [results/2026-10-17-tpc-sf1-masters.md](../../../results/2026-10-17-tpc-sf1-masters.md). The laptop isn't unlimited either: its writes (the VM's virtual disk on the Mac's file system) are at a default gp3's level, while its reads are a hundred times faster.
