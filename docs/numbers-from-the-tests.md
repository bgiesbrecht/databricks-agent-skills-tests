# Numbers from the tests

Measured in this repo's runs, each with its source. Back to the [README](../README.md).

- **A database branch in a fraction of a second.** `juicefs clone` branched a master in 0.05–0.3 s.
  - **Reads:** a full read of a 30M-row Postgres table (3.8 GB) took 17–20 s from object storage. Local XFS took 38–46 s, on a 32 GB Premium SSD (P4) running on burst I/O, not a provisioned-performance disk.
  - **Writes:** JuiceFS writes were 2–4 times slower, so XFS reflink clones are the choice for high change rates ([benchmark](../skills/lfc-source-cloud-vm/references/juicefs-branches.md)).
- **110 million rows without moving a byte over the network.** All six TPC workloads at scale factor 1 (B, C, H, DS, E, DI) were generated inside SQL Server 2022 with `INSERT … SELECT` in 19 minutes (1,125 s), every table at its target size ([2026-10-17-tpc-sf1-masters](../results/2026-10-17-tpc-sf1-masters.md)).
- **Change events half the size.** Debezium events into Zerobus went from 700 to 336 bytes per insert, 52% smaller, with nothing silver needs lost ([what each setting saved](../skills/zerobus-debezium-test/SKILL.md#event-size-what-each-setting-saved)).
- **Schema-change claims in under an hour.** The full SQL Server ADD COLUMN test takes about 40 minutes on standard CDC, and 1–2 hours on integrated CDC. Integrated updates are stopped as soon as nothing is left to apply, instead of waiting the 20 minutes or more each would otherwise run.
