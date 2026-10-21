# Lakeflow Connect, tested end to end

**End-to-end testing of Databricks Lakeflow Connect, made easy.** Stand up a real source database with change capture on, reachable from your workspace, in minutes. Fill it with data shaped like a customer's, run every ingestion mode against it, check what landed, and record the result, so the next person knows what's been tested and what still needs testing.

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
| MySQL 8.4 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not enabled on any test workspace |
| Oracle 23ai Free | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not offered |
| PostgreSQL 16 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not offered | not enabled on any test workspace |
| SQL Server 2022 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure (serverless gateway) |

## Tested end to end: Lakeflow Connect Zerobus, by database

Database changes through Zerobus Ingest into bronze, silver (current rows and every version) and gold, each checked against the source after five rounds of changes, a producer restart and schema changes included. The runs, and how to repeat them: [docs/lakeflow-connect-zerobus.md](docs/lakeflow-connect-zerobus.md).

| Database | Producer into Zerobus | Bronze | Silver SCD 1 and 2 | Gold | Producer restart | Schema changes | No cloud storage (laptop) |
|---|---|---|---|---|---|---|---|
| CockroachDB v25.4.13 | Debezium Server, Zerobus sink | ✅ Azure | ✅ Azure | ✅ Azure | ✅ Azure | ✅ Azure | ✅ |
| YugabyteDB 2026.1.2.0 | Kafka Connect (no broker), Zerobus Kafka endpoint | ✅ Azure | ✅ Azure | ✅ Azure | ✅ Azure | ✅ Azure | not run yet |

## Quick start

Open Claude Code (or another coding agent) in this repo, with a Databricks CLI login, and ask in plain words:

> Set up a SQL Server 2022 source in Podman on an Azure VM for Lakeflow Connect, with change tracking on, TPC-C at scale factor 1, and its firewall open to my workspace. Then create the UC connection.

> Run the integrated CDC test for that connection, and show me the rows per table per run.

The skills ask before creating anything, and clean up after themselves. To run the tests as scripts instead, see [docs/running-tests.md](docs/running-tests.md).

## How to use this repo

The test space is large: where the source runs, the database and version, the ingestion mode, the cloud and kind of workspace, compute, network path, storage and data size. Nobody can run every combination, so the repo works like a shared notebook:

1. **Check what's already known:** `uv run skills/lfc-test-results/scripts/recall.py --coverage`, or the summary in [docs/coverage.md](docs/coverage.md).
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
- [docs/running-tests.md](docs/running-tests.md): setup, the deploy matrix, schema-change and script tests, recording results.
- [MATRIX.md](MATRIX.md): every deploy-test cell and its pass criteria.
- The repo also tests the [databricks-agent-skills](https://github.com/databricks/databricks-agent-skills) with headless Claude Code sessions: does a prompt reach the right skill, does the skill ask before creating anything, and does what it builds work. See [docs/running-tests.md](docs/running-tests.md#guidance-tests).
- UI walkthroughs of the Lakeflow Connect wizard, as masked screenshots: [ui-demos/](ui-demos/) ([lfc-ui-capture](skills/lfc-ui-capture/SKILL.md)).
