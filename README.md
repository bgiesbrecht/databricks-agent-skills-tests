# Lakeflow Connect, tested end to end

**End-to-end testing of Databricks Lakeflow Connect, made easy.** Stand up a real source database with change capture on, reachable from your workspace, in minutes. Fill it with data shaped like a customer's, run every ingestion mode against it, check what landed, and record the result, so the next person knows what's been tested and what still needs testing.

It also tests the [databricks-agent-skills](https://github.com/databricks/databricks-agent-skills) with headless Claude Code sessions: does a prompt reach the right skill, does the skill ask before creating anything, and does what it builds work in a workspace.

## Tested end to end: Lakeflow Connect modes, by database

Every cell ran end to end in a real workspace: source, UC connection, pipeline, rows checked against the source. ✅ passed; workspaces: AWS and Azure, serverless-only and classic.

| Database | UC connection, queried with [`remote_query`](https://docs.databricks.com/aws/en/query-federation/remote-queries) | Query-based | Query-based via foreign catalog | Integrated CDC | Standard CDC (gateway) |
|---|---|---|---|---|---|
| Lakebase | ✅ Azure (the query-based demo creates it) | ✅ Azure, with a DML round trip | ✅ Azure | not offered | Lakebase refuses `CREATE PUBLICATION`: the skill stops |
| MySQL 8.4 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not enabled on any test workspace |
| Oracle 23ai Free | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not offered |
| PostgreSQL 16 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not offered | not enabled on any test workspace |
| SQL Server 2022 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure (serverless gateway) |

Some combinations are refused by the product, by design: CDC into a Default Storage catalog, classic compute on a serverless-only workspace, and modes a source doesn't offer. These, every other axis that's been tested (source host, version, compute, network path, storage, data) and what's planned are in [docs/coverage.md](docs/coverage.md).

## A skill for each step of the customer's journey

Organized like the Lakeflow Connect database FAQ: each step a customer goes through has a skill here that sets it up or tests it.

| Step | What you get |
|---|---|
| **Scope and support** | A shared results notebook ([lfc-test-results](skills/lfc-test-results/SKILL.md)): what passed, by database, mode, cloud, workspace and compute. Check it before testing, and add to it. |
| **Architecture and deployment** | All four ingestion patterns: query-based, query-based through a foreign catalog, integrated CDC and standard CDC. Serverless and classic, on AWS and Azure. [lfc-workspace-setup](skills/lfc-workspace-setup/SKILL.md) turns on the connector previews and picks a catalog CDC accepts. |
| **Network connectivity** | [lfc-source-firewall](skills/lfc-source-firewall/SKILL.md) opens the source to the workspace's serverless egress IPs and your laptop's IP, on Azure, AWS and GCP. Tested on public IPs and across clouds. |
| **Connection and authentication** | [lfc-connection-sync](skills/lfc-connection-sync/SKILL.md) keeps the same UC connections in many workspaces. [account-token-fallback](skills/account-token-fallback/SKILL.md) keeps expired CLI profiles working. |
| **Source setup, security and change capture** | [lfc-source-setup](skills/lfc-source-setup/SKILL.md) creates the source anywhere: AWS RDS and Aurora, Azure SQL and Flexible Server, GCP Cloud SQL, a cloud VM, or Podman on your laptop. It covers MySQL, PostgreSQL, SQL Server and Oracle, plus Db2, Informix, CockroachDB and YugabyteDB for data generation. Each skill creates the user and grants and turns on change capture. |
| **Initial snapshot, at size** | Data without moving it over the network. [lfc-source-datagen](skills/lfc-source-datagen/SKILL.md) generates it inside the database. [lfc-source-statschema](skills/lfc-source-statschema/SKILL.md) shapes a source like a customer's database (from its schema and statistics) or like TPC-B, -C, -H, -DS, -E or -DI. **Podman with JuiceFS** keeps a master database in object storage, with only a cache and the changed blocks on the VM, and branches it in about 0.1 s. See [juicefs-branches.md](skills/lfc-source-cloud-vm/references/juicefs-branches.md) for the benchmark against local XFS reflink clones: the XFS side was a small Premium SSD (P4) on burst I/O, not a provisioned-performance disk. |
| **Ongoing incremental ingestion** | DML round trips and rows-per-table-per-run checks in the [deploy matrix](MATRIX.md). [zerobus-debezium-test](skills/zerobus-debezium-test/SKILL.md) streams database changes through Debezium Server into a Lakeflow Connect Zerobus change log. |
| **Full refresh, recovery, schema evolution** | [lfc-schema-change-test](skills/lfc-schema-change-test/SKILL.md) states each claim as a rerunnable PASS or FAIL on a fresh source: inline or full refresh for every ADD COLUMN case, the recovery and `auto_full_refresh_policy`, on standard and integrated CDC. JuiceFS branches and XFS reflink clones reset a source in seconds. |
| **Target table semantics** | Test tables for SCD type 1, SCD type 2, keyless and append-only. The Zerobus test lands one `VARIANT` change log for a silver AUTO CDC flow. |
| **Sizing and cost** | [lfc-source-sizing](skills/lfc-source-sizing/SKILL.md) measures how much Lakeflow Connect will move, per table and in total. `bin/compute_report.sh` reports what compute each pipeline ran on. The Zerobus test measures bytes per event. |
| **Operations and troubleshooting** | `bin/lfc-runtime.sh` records the runtime and settings of every update, and what changed between runs. [lfc-ui-capture](skills/lfc-ui-capture/SKILL.md) captures the wizard as masked screenshots for demos and docs. [watch-progress](skills/watch-progress/SKILL.md) checks long jobs. |

## How to use this repo

The test space is large: where the source runs, which database and version, which ingestion mode, which cloud and kind of workspace, which compute, network path, credentials, storage under the database, and how much data. Nobody can run every combination, so the repo works like a shared notebook:

1. **Check what's already known** before testing anything: `uv run skills/lfc-test-results/scripts/recall.py --coverage` (test × database), or `--all` with filters (`--engine` for the database, `--workspace`, `--host`, `--storage`, `--compute`). [docs/coverage.md](docs/coverage.md) summarizes it.
2. **Pick the values you want to cover**, one per axis, preferably ones nobody has tested yet. The axes and their planned values are in [test-matrix.md](skills/lfc-test-results/references/test-matrix.md).
3. **Run** the Lakeflow Connect matrix against one workspace (see [Deploy tests](docs/running-tests.md#deploy-tests-the-lakeflow-connect-matrix)), or one of the skills' own scripts.
4. **Record** each cell with `record.py`, and write up the run in `results/<date>-<topic>.md` ([Test results](docs/running-tests.md#test-results)). Records are per run, so people testing in parallel never edit the same file.

## More

- [docs/coverage.md](docs/coverage.md): every axis tested, what's refused by design, and what's not tested yet.
- [docs/running-tests.md](docs/running-tests.md): repo layout, setup, script tests, guidance tests, the deploy matrix, prompt format, permissions for headless sessions, the workspace file bridge, recording results.
- [MATRIX.md](MATRIX.md): every deploy-test cell and its pass criteria.
- [pr-notes/](pr-notes/): one write-up per skills-repo PR these tests back, with the full matrix and results.
