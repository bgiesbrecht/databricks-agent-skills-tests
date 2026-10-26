# Lakeflow Connect, tested end to end

**End-to-end testing of Databricks Lakeflow Connect, made easy.** Stand up a real source database with change capture on, reachable from your workspace, in minutes. Fill it with data shaped like a customer's, run every ingestion mode against it, check what landed, and record the result, so the next person knows what's been tested and what still needs testing.

The scripts are the skill, so what was tested is what anyone runs. You can run them, or an agent can run them for you. The agent's job is to run them, and to improve them when they fail.

## What's unique

- **A fresh copy of any database, in a fraction of a second.** One approach for every engine, with the master in your own bucket and only a cache on the VM, built from open-source parts (Podman, JuiceFS).
- **Data generated inside the database, from any schema, with zero bytes of data over the network.** The schema and its statistics go into one canonical format, so a MySQL schema can be built and filled on Oracle (or any of six engines), with valid parent/child keys. Only the SQL travels; every row is made inside the database.
- **A copy shaped like the customer's database, without their data.** A DBA won't hand over real data without an NDA. Built from the catalog's statistics only, the copy behaves like their database without a single real row leaving their site.
- **Scripts, not instructions, and they get better with every failure.** Each skill does its work by running the bash and Python scripts in its own `scripts/` folder, not by an agent improvising commands. So anyone can repeat a test by running the same scripts, without the AI. When a run fails on a case the scripts didn't handle (a database that writes decimals wrong, a cleanup that stops at a missing container, an IP change mid-run), the fix goes into the script, and the next run handles it. A repeatable runner runs the committed scripts on a clean checkout and records which commit passed, so a ✅ means "these scripts, at this commit" ([an example](docs/lakeflow-connect-zerobus.md#run-it-again)).
- **Answers tested as claims, on the runtime they ran on.** Each answer is a rerunnable PASS or FAIL on a fresh source, tied to the exact runtime and settings of every update. It catches behavior that differs from the docs, and when a release changes it.

How these compare with other tools, and their limits: [docs/what-is-unique.md](docs/what-is-unique.md).

## Tested end to end: Lakeflow Connect modes, by database

Every ✅ ran end to end in a real workspace: source database, UC connection, pipeline, and the rows checked against the source. Tested on AWS and Azure, on serverless-only workspaces and on workspaces with classic compute. To run any cell again, with the prompts and a diagram of everything it creates: [docs/lakeflow-connect-database.md](docs/lakeflow-connect-database.md).

| Database | UC connection, queried with [`remote_query`](https://docs.databricks.com/aws/en/query-federation/remote-queries) | Query-based | Query-based via foreign catalog | Integrated CDC | Standard CDC (gateway) |
|---|---|---|---|---|---|
| Lakebase | ✅ Azure | ✅ Azure, with a DML round trip | ✅ Azure | not offered | Lakebase refuses `CREATE PUBLICATION`: the skill stops |
| MySQL 8.4 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS (serverless gateway) |
| Oracle 23ai Free | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not offered |
| PostgreSQL 16 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not offered | ✅ AWS (serverless gateway) |
| SQL Server 2022 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure (serverless gateway) |

## Tested end to end: schema changes and table lifecycle, by database

Each ✅ ran on a fresh source database and real pipelines, with the destination checked against the source; the test then recovered the table (full refresh or `auto_full_refresh_policy`) and checked the next change arrived. Scripts: [skills/lfc-schema-change-test](skills/lfc-schema-change-test/SKILL.md).

| Scenario | SQL Server, standard CDC | SQL Server, integrated CDC | PostgreSQL 16, standard CDC |
|---|---|---|---|
| ADD COLUMN (nullable, default, identity, computed; keyed and keyless) | ✅ | ✅ | ✅ |
| Type change, DROP COLUMN, rename, primary key change | ✅ | | ✅ |
| `auto_full_refresh_policy` recovers a stopped table | ✅ | | ✅ |
| DELETE every row + INSERT | ✅ | ✅ | |
| TRUNCATE (CDC and change tracking) | ✅ | ✅ | ✅ |
| DROP and recreate a table | ✅ | ✅ | |
| Add a table to a running pipeline | ✅ | ✅ | |
| Replica identity DEFAULT / FULL / NOTHING, TOAST-able columns | | | ✅ |
| Permissions missing, table not tracked; the other tables keep loading | ✅ | | |
| SCD type 2 on change tracking and CDC | ✅ | ✅ | |
| Change data feed on the destination (`table_changes`) | ✅ | | |
| Move between integrated CDC and a gateway | ✅ | ✅ | |
| Many tables in one pipeline (90, 270, 900; TPC-C copies, one schema each) | ✅ | | |

## Tested end to end: Lakeflow Connect Zerobus, by database

Database changes through Zerobus Ingest into bronze, silver (current rows and every version) and gold, each checked against the source after each round of changes: inserts, updates and deletes, a producer killed and restarted, then a column added and a column dropped and retyped. The six databases from Db2 to SQL Server each ran all six TPC models (TPC-B, TPC-C, TPC-DI, TPC-DS, TPC-E, TPC-H) on Azure, one source into one set of tables. Several sources into one set of tables (n:1): TPC-H with 2 sources on Db2, Informix, MySQL, PostgreSQL and SQL Server, and the Mautic schema with 2 and 4 MySQL sources. The runs, and how to repeat them: [docs/lakeflow-connect-zerobus.md](docs/lakeflow-connect-zerobus.md).

| Database | Producer into Zerobus | Bronze | Silver SCD 1 and 2 | Gold | Producer restart | Schema changes | No cloud storage (laptop) |
|---|---|---|---|---|---|---|---|
| CockroachDB v25.4.13 | Debezium Server, Zerobus sink | ✅ Azure | ✅ Azure | ✅ Azure | ✅ Azure | ✅ Azure | ✅ |
| Db2 11.5.9 | Debezium Server, Zerobus sink | ✅ Azure | ✅ Azure | no TPC gold yet | ✅ Azure | not run yet | not run yet |
| Informix 14.10 | Debezium Server, Zerobus sink | ✅ Azure | ✅ Azure | no TPC gold yet | ✅ Azure | not run yet | not run yet |
| MySQL 8.4 | Debezium Server, Zerobus sink | ✅ Azure | ✅ Azure | no TPC gold yet | ✅ Azure | ✅ Azure | not run yet |
| Oracle 26ai Free (23.26) | Debezium Server, Zerobus sink | ✅ Azure | ✅ Azure | no TPC gold yet | ✅ Azure | not run yet | not run yet |
| PostgreSQL 16 | Debezium Server, Zerobus sink | ✅ Azure | ✅ Azure | no TPC gold yet | ✅ Azure | ✅ Azure | not run yet |
| SQL Server 2022 | Debezium Server, Zerobus sink | ✅ Azure | ✅ Azure | no TPC gold yet | ✅ Azure | not run yet | not run yet |
| YugabyteDB 2026.1.2.0 | Kafka Connect (no broker), Zerobus Kafka endpoint | ✅ Azure | ✅ Azure | ✅ Azure | ✅ Azure | ✅ Azure | not run yet |

## Quick start

Open Claude Code (or another coding agent) in this repo, with a Databricks CLI login, and ask in plain words:

> Set up a SQL Server 2022 source in Podman on an Azure VM for Lakeflow Connect, with change tracking on, TPC-C at scale factor 1, and its firewall open to my workspace. Then create the UC connection.

> Run the integrated CDC test for that connection, and show me the rows per table per run.

The skills ask before creating anything, and clean up after themselves. To run the tests as scripts instead, see [docs/running-tests.md](docs/running-tests.md).

## How to use this repo

The test space is large: where the source runs, the database and version, the ingestion mode, the cloud and kind of workspace, compute, network path, storage and data size. Nobody can run every combination, so the repo works like a shared notebook:

1. **Check what's already known:** `uv run skills/lfc-test-results/scripts/recall.py --coverage`, or the summary in [docs/coverage.md](docs/coverage.md); and what's been found for the combination: `uv run skills/lfc-test-results/scripts/finding.py --source <engine> --route <route>`.
2. **Pick what to cover,** preferably values nobody has tested yet ([test-matrix.md](skills/lfc-test-results/references/test-matrix.md)).
3. **Run** the deploy matrix against one workspace, or one skill's own test ([docs/running-tests.md](docs/running-tests.md)).
4. **Record** each result with `record.py`. Records are per run, so people testing in parallel never edit the same file.

## More

- [A skill for each step of the test and validation journey](docs/test-and-validation-journey.md): sources on every cloud or a laptop, the firewall, the four ingestion modes, data at size, database copies in seconds, changes, schema changes, Zerobus, and the runtime each test ran on.
- [Numbers from the tests](docs/numbers-from-the-tests.md): branch and read/write times, 110M rows generated inside the database, change events half the size, how long the schema-change tests take.
- [docs/lakeflow-connect-zerobus.md](docs/lakeflow-connect-zerobus.md): Lakeflow Connect Zerobus, tested end to end by database, with every successful run.
- [docs/zerobus-debezium.md](docs/zerobus-debezium.md): database changes through Debezium and Zerobus into bronze, silver and gold, what was checked, and the prompts to run it again.
- [docs/lakeflow-connect-database.md](docs/lakeflow-connect-database.md): the prompts that reproduce each cell of the table, and what they create, in order.
- [docs/coverage.md](docs/coverage.md): every axis tested, what the product refuses by design, and what's not tested yet.
- [docs/findings.md](docs/findings.md): what the tests turned up, by source, route, layer and topology, with the fix or workaround for each: look up a combination before building it.
- [docs/running-tests.md](docs/running-tests.md): setup, the deploy matrix, schema-change and script tests, recording results.
- [MATRIX.md](MATRIX.md): every deploy-test cell and its pass criteria.
- [skill-token-budget](skills/skill-token-budget/SKILL.md): how to write a skill so an agent loads few tokens (SKILL.md under 5k tokens, detail in references/, scripts run from their usage line), and the checks that enforce it.
- [SCRIPTS.md](SCRIPTS.md): every script under `skills/` and `bin/`, one line each (path and usage), generated from the scripts' headers. Find a script there, then run it with no arguments for its usage instead of reading it.
- The repo also tests the [databricks-agent-skills](https://github.com/databricks/databricks-agent-skills) with headless Claude Code sessions: does a prompt reach the right skill, does the skill ask before creating anything, and does what it builds work. See [docs/running-tests.md](docs/running-tests.md#guidance-tests).
- UI walkthroughs of the Lakeflow Connect wizard, as masked screenshots: [ui-demos/](ui-demos/) ([lfc-ui-capture](skills/lfc-ui-capture/SKILL.md)).
