# Lakeflow Connect, tested end to end

**End-to-end testing of Databricks Lakeflow Connect, made easy.** Stand up a real source database with change capture on, reachable from your workspace, in minutes. Fill it with data shaped like a customer's, run every ingestion mode against it, check what landed, and record the result, so the next person knows what's been tested and what still needs testing.

## What's unique

- **A fresh copy of any database, in a fraction of a second.** One approach for every engine, with the master in your own bucket and only a cache on the VM, built from open-source parts (Podman, JuiceFS).
- **Data generated inside the database, from any schema, with zero bytes of data over the network.** The schema and its statistics go into one canonical format, so a MySQL schema can be built and filled on Oracle (or any of six engines), with valid parent/child keys. Only the SQL travels; every row is made inside the database.
- **A copy shaped like the customer's database, without their data.** A DBA won't hand over real data without an NDA. Built from the catalog's statistics only, the copy behaves like their database without a single real row leaving their site.
- **Answers tested as claims, on the runtime they ran on.** Each answer is a rerunnable PASS or FAIL on a fresh source, tied to the exact runtime and settings of every update. It catches behavior that differs from the docs, and when a release changes it.

How these compare with other tools, and their limits: [docs/what-is-unique.md](docs/what-is-unique.md).

## Tested end to end: Lakeflow Connect modes, by database

Every ✅ ran end to end in a real workspace: source database, UC connection, pipeline, and the rows checked against the source. Tested on AWS and Azure, on serverless-only workspaces and on workspaces with classic compute.

| Database | UC connection, queried with [`remote_query`](https://docs.databricks.com/aws/en/query-federation/remote-queries) | Query-based | Query-based via foreign catalog | Integrated CDC | Standard CDC (gateway) |
|---|---|---|---|---|---|
| Lakebase | ✅ Azure | ✅ Azure, with a DML round trip | ✅ Azure | not offered | Lakebase refuses `CREATE PUBLICATION`: the skill stops |
| MySQL 8.4 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not enabled on any test workspace |
| Oracle 23ai Free | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not offered |
| PostgreSQL 16 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not offered | not enabled on any test workspace |
| SQL Server 2022 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure (serverless gateway) |

## Quick start

Open Claude Code (or another coding agent) in this repo, with a Databricks CLI login, and ask in plain words:

> Set up a SQL Server 2022 source in Podman on an Azure VM for Lakeflow Connect, with change tracking on, TPC-C at scale factor 1, and its firewall open to my workspace. Then create the UC connection.

> Run the integrated CDC test for that connection, and show me the rows per table per run.

The skills ask before creating anything, and clean up after themselves. To run the tests as scripts instead, see [docs/running-tests.md](docs/running-tests.md).

## A skill for each step of the test and validation journey

| Step | What you get |
|---|---|
| **Is my source supported?** | Sources on AWS RDS and Aurora, Azure SQL and Flexible Server, GCP Cloud SQL, a cloud VM, or Podman on a laptop ([lfc-source-setup](skills/lfc-source-setup/SKILL.md)). MySQL, PostgreSQL, SQL Server and Oracle, plus Db2, Informix, CockroachDB and YugabyteDB for data generation. Each source comes with its user, grants and change capture (binlog, publication and slot, change tracking or CDC, LogMiner). |
| **Can my workspace reach it?** | [lfc-source-firewall](skills/lfc-source-firewall/SKILL.md) opens the source to the workspace's serverless egress IPs and your IP, on Azure, AWS and GCP. Tested on public IPs and across clouds (an AWS workspace reading an Azure VM). |
| **Which ingestion mode?** | All four: query-based, query-based through a foreign catalog, integrated CDC and standard CDC, on serverless or classic. [lfc-workspace-setup](skills/lfc-workspace-setup/SKILL.md) turns on the connector previews and picks a catalog CDC accepts. |
| **How does the first load behave at size?** | Data that never crosses the network: generated inside the database ([lfc-source-datagen](skills/lfc-source-datagen/SKILL.md)), shaped like a customer's database from its schema and statistics, or like TPC-B, -C, -H, -DS, -E or -DI ([lfc-source-statschema](skills/lfc-source-statschema/SKILL.md)). [lfc-source-sizing](skills/lfc-source-sizing/SKILL.md) tells you how much Lakeflow Connect will move. |
| **Fresh copy of a big database, in seconds** | **Podman with JuiceFS** keeps a master database in object storage. The VM holds only a cache and the blocks a test changes, and a new copy-on-write branch takes 0.05–0.3 s. XFS reflink clones of a master are the option for write-heavy tests ([juicefs-branches.md](skills/lfc-source-cloud-vm/references/juicefs-branches.md)). |
| **Do changes arrive?** | Insert, update and delete round trips, with rows per table per run checked against the source ([MATRIX.md](MATRIX.md)). |
| **What happens when the source schema changes?** | [lfc-schema-change-test](skills/lfc-schema-change-test/SKILL.md) answers it by running it. Each ADD COLUMN case (with and without a key, change tracking or CDC, with and without defaults, identity, computed) comes out as a PASS or FAIL: applied in place, or needs a full refresh. It also checks the recovery and `auto_full_refresh_policy`, on standard and integrated CDC. |
| **SCD type 1, SCD type 2, keyless, append-only** | Test tables for each, and what each target table holds after changes. |
| **Database changes through Zerobus** | [zerobus-debezium-test](skills/zerobus-debezium-test/SKILL.md): Debezium Server's Zerobus sink into one `VARIANT` change-log table, with the snapshot kept out of it, ready for a silver AUTO CDC flow. |
| **Which runtime did it run on?** | `bin/lfc-runtime.sh` records each update's runtime (DBR, release, CPU architecture) and settings, and what changed since the last run. Behavior can change between releases, and even between updates. |

## Numbers from the tests

- **A database branch in a fraction of a second.** `juicefs clone` branched a master in 0.05–0.3 s.
  - **Reads:** a full read of a 30M-row Postgres table (3.8 GB) took 17–20 s from object storage. Local XFS took 38–46 s, on a 32 GB Premium SSD (P4) running on burst I/O, not a provisioned-performance disk.
  - **Writes:** JuiceFS writes were 2–4 times slower, so XFS reflink clones are the choice for high change rates ([benchmark](skills/lfc-source-cloud-vm/references/juicefs-branches.md)).
- **110 million rows without moving a byte over the network.** All six TPC workloads at scale factor 1 (B, C, H, DS, E, DI) were generated inside SQL Server 2022 with `INSERT … SELECT` in 19 minutes (1,125 s), every table at its target size ([2026-10-17-tpc-sf1-masters](results/2026-10-17-tpc-sf1-masters.md)).
- **Change events half the size.** Debezium events into Zerobus went from 700 to 336 bytes per insert, 52% smaller, with nothing silver needs lost ([what each setting saved](skills/zerobus-debezium-test/SKILL.md#event-size-what-each-setting-saved)).
- **Schema-change claims in under an hour.** The full SQL Server ADD COLUMN test takes about 40 minutes on standard CDC, and 1–2 hours on integrated CDC. Integrated updates are stopped as soon as nothing is left to apply, instead of waiting the 20 minutes or more each would otherwise run.

## How to use this repo

The test space is large: where the source runs, the database and version, the ingestion mode, the cloud and kind of workspace, compute, network path, storage and data size. Nobody can run every combination, so the repo works like a shared notebook:

1. **Check what's already known:** `uv run skills/lfc-test-results/scripts/recall.py --coverage`, or the summary in [docs/coverage.md](docs/coverage.md).
2. **Pick what to cover,** preferably values nobody has tested yet ([test-matrix.md](skills/lfc-test-results/references/test-matrix.md)).
3. **Run** the deploy matrix against one workspace, or one skill's own test ([docs/running-tests.md](docs/running-tests.md)).
4. **Record** each result with `record.py`. Records are per run, so people testing in parallel never edit the same file.

## More

- [docs/coverage.md](docs/coverage.md): every axis tested, what the product refuses by design, and what's not tested yet.
- [docs/running-tests.md](docs/running-tests.md): setup, the deploy matrix, schema-change and script tests, recording results.
- [MATRIX.md](MATRIX.md): every deploy-test cell and its pass criteria.
- The repo also tests the [databricks-agent-skills](https://github.com/databricks/databricks-agent-skills) with headless Claude Code sessions: does a prompt reach the right skill, does the skill ask before creating anything, and does what it builds work. See [docs/running-tests.md](docs/running-tests.md#guidance-tests).
- UI walkthroughs of the Lakeflow Connect wizard, as masked screenshots: [ui-demos/](ui-demos/) ([lfc-ui-capture](skills/lfc-ui-capture/SKILL.md)).
