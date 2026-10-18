# databricks-agent-skills tests

Headless Claude Code sessions that test the skills in
[databricks-agent-skills](https://github.com/databricks/databricks-agent-skills): does a prompt
route to the right skill, does the skill ask before creating anything, and does what it builds
actually work in a workspace.

Kept separate from the skills repo so test scripts, prompts, and results don't clutter it. The
skills repo keeps its own hook unit tests (`tests/*_test.py`).

Each skills-repo PR that these tests back has a summary in [pr-notes/](pr-notes/), for example
[lfc-query-based-lakebase-demo](pr-notes/lfc-query-based-lakebase-demo.md), with the full test
matrix and results.

## Test axes: what's been tested and works

From `results/runs/*.jsonl`, 2026-10. Each line is a value that passed at least once; a value that's missing hasn't been tested yet, which doesn't mean it fails. Blocked results aren't listed: a mode the workspace hasn't enabled, a missing grant, or a firewall that doesn't allow the compute's IP all work once fixed.

| Axis | Tested and works |
|---|---|
| Where the source runs | Azure managed databases (Azure SQL Database; Flexible Server for MySQL and PostgreSQL); Lakebase; Podman on an AWS VM and on an Azure VM; Podman in a laptop Lima VM (data generation only) |
| Database and version | Lakebase, MySQL 8.4, Oracle 23ai Free, PostgreSQL 16, SQL Server 2022. For data generation and branch layers only: CockroachDB 25, Db2 11.5, Informix 14.10, YugabyteDB 2025 |
| Workspace | AWS and Azure field sandboxes (FEVM), each serverless-only and with classic compute; target catalog with its own managed storage (every mode) or on Default Storage (query-based only) |
| Compute | `serverless: true` on every pipeline and gateway. Left unset: query-based ran serverless; integrated CDC and the gateway ran classic on a classic workspace (Azure), which needs the classic egress IP in the source's firewall: that path isn't tested yet |
| Network path | public IP, firewall open to the workspace's serverless egress ranges; also cross-cloud (an AWS workspace reading the Azure VM) |
| Credentials | password stored in the UC connection |
| Storage under the database | local XFS; XFS reflink clones of a master; JuiceFS branches (object storage); rclone copies of a master |
| Data | seed tables (`intpk`, `dtix`); TPC-B, -C, -H, -DS, -E and -DI at SF 0.1 and SF 1; pgbench |
| Data generation | the CLI planners (psql, mysql, sqlcmd, sqlplus) and the Python planner through pip drivers, on six databases |

Lakeflow Connect modes, by database (✅ passed; workspaces: AWS and Azure, serverless-only and classic):

| Database | UC connection, queried with [`remote_query`](https://docs.databricks.com/aws/en/query-federation/remote-queries) | Query-based | Query-based via foreign catalog | Integrated CDC | Standard CDC (gateway) |
|---|---|---|---|---|---|
| Lakebase | ✅ Azure (the query-based demo creates it) | ✅ Azure, with a DML round trip | ✅ Azure | not offered | Lakebase refuses `CREATE PUBLICATION`: the skill stops |
| MySQL 8.4 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not enabled on any test workspace |
| Oracle 23ai Free | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not offered |
| PostgreSQL 16 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | not offered | not enabled on any test workspace |
| SQL Server 2022 | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure | ✅ AWS, Azure (serverless gateway) |

**Doesn't work, by design** (the product refuses it; as of 2026-10):

- CDC (integrated or standard) into a catalog on Default Storage: `Default Storage for Unity Catalog is not supported on LakeFlow Connect pipelines`. Query-based works there.
- Classic compute, including a classic gateway, on a serverless-only workspace: `You must use serverless compute in this workspace`.
- `system` and `hive_metastore` as the target catalog.
- Modes the product doesn't offer for a source (integrated CDC from PostgreSQL or Lakebase; standard CDC from Oracle), and standard CDC from Lakebase, which refuses the publication it needs: the skill should say so and create nothing, which the matrix checks.

GCP, private network paths (private network gateway, PrivateLink), secrets by reference, other database versions, managed services on AWS and GCP, and larger data volumes aren't tested yet: see the plan in [test-matrix.md](skills/lfc-test-results/references/test-matrix.md#planned).

## How to use this repo

The test space is large: where the source runs, which database and version, which ingestion mode, which cloud and kind of workspace, which compute, network path, credentials, storage under the database, and how much data. Nobody can run every combination, so the repo works like a shared notebook:

1. **Check what's already known** before testing anything: `uv run skills/lfc-test-results/scripts/recall.py --coverage` (test × database), or `--all` with filters (`--engine` for the database, `--workspace`, `--host`, `--storage`, `--compute`). The tables above summarize it.
2. **Pick the values you want to cover**, one per axis, preferably ones nobody has tested yet. The axes and their planned values are in [test-matrix.md](skills/lfc-test-results/references/test-matrix.md).
3. **Run** the Lakeflow Connect matrix against one workspace (see [Deploy tests](#deploy-tests-the-lakeflow-connect-matrix)), or one of the skills' own scripts.
4. **Record** each cell with `record.py`, and write up the run in `results/<date>-<topic>.md` ([Test results](#test-results)). Records are per run, so people testing in parallel never edit the same file.

## Layout

```
run.sh                 # runner: one headless `claude -p` session per prompt, multi-turn via `tag+|`
summarize.py           # skills loaded, reference files read, answer preview
env.sh                 # sources env.local.sh, sets SKILLS_REPO / OMNIGENT_WS / PIPELINE_WS
env.example.sh         # copy to env.local.sh (gitignored) and fill in
sync.sh                # workspace file bridge for sandboxes without git push
bin/run_matrix.sh      # the whole Lakeflow Connect matrix, one batch per mode, then a compute readback
bin/run_batch.sh       # run several prompt files in parallel, each in its own scratch dir
bin/compute_report.sh  # per pipeline: serverless asked, ran on, started, reached the source
bin/stop_after.sh      # stop pipeline updates that run past N minutes
bin/test_scripts.sh    # regression tests for the skills' scripts (offline, or on Postgres and MySQL)
bin/check_links.py     # every relative link in every skill
pr-notes/              # PR descriptions with the test matrix, one per skills-repo branch
prompts/
  lakeflow-connect.txt # routing / guidance prompts (no resources created)
  lfc-matrix/          # Lakeflow Connect deploy tests: 5 sources x 4 modes, plus DML (MATRIX.md)
results/               # runs/<run>.jsonl records and <date>-<topic>.md write-ups
skills/                # test-only skills: source setup, data generation, firewall, results
```

## Setup

Check out this repo next to the skills repo (or set `SKILLS_REPO`):

```
~/github/databricks-agent-skills
~/github/databricks-agent-skills-tests
```

```bash
cp env.example.sh env.local.sh    # fill in profiles, catalog, connections (never committed)
source env.sh
```

`run.sh` copies the skills repo's `skills/` into the Claude plugin cache before each run, so
sessions test your local edits. Sessions run in a scratch `WORK_DIR` under `/tmp`, outside both
repos, so skills load from the plugin cache and generated bundles stay out of git.

## Script tests

The skills' scripts (planners, `fill.sh`, the statschema pipeline, the firewall DuckDB queries) have their own regression tests:

```bash
bin/test_scripts.sh                    # offline: syntax, links, the six TPC schemas through shape.py and ddl.py, round trips
PSQL="podman exec -i dg-pg psql -U postgres" MYSQL="podman exec -i dg-my mysql -uroot" bin/test_scripts.sh   # and fill on both engines
bin/check_links.py                     # every relative link in every skill
```

With databases, it fills TPC-C and the TPC-H spec schema on each engine (schemas named `test_*`) and checks every table's target, the spec's rules, and the audit. Run it after changing a skill's scripts.

## Guidance tests

No resources created:

```bash
./run.sh "$SKILLS_REPO" prompts/lakeflow-connect.txt
./summarize.py /tmp/lakeflow-connect-results
```

## Deploy tests: the Lakeflow Connect matrix

**These create real, billable resources in `PIPELINE_WS`.** Each prompt file is two turns: a
plain request (the skill must ask before creating anything), then the answers and go-ahead.
`${VAR}` placeholders come from `env.local.sh`.

Run the whole matrix with `bin/run_matrix.sh` ([MATRIX.md](MATRIX.md) has every cell and its pass criteria). It runs one mode per batch, so tests on the same connection don't race for the same default pipeline name (the skill names pipelines `<firstname><lastname>-<connection>`, then `-2`, `-3`; standard CDC uses `-gw` / `-ap`), and ends by reading back what compute each pipeline ran on:

```bash
LFC_ENV=<name> source env.sh
bin/run_matrix.sh                                  # qbc -> fcqbc -> icdc -> scdc -> dml
bin/run_matrix.sh icdc scdc                        # only some modes
LFC_SERVERLESS=unset bin/run_matrix.sh icdc        # take the product's compute default instead of serverless: true
bin/run_batch.sh prompts/lfc-matrix/qbc-*.txt      # one batch by hand
```

The prompts ask for `serverless: true` by default (`LFC_SERVERLESS`), because the test firewall allows only the serverless ranges; see "Workspace requirements" in MATRIX.md. Check the workspace first with the skills repo's `ready.sh` (databricks-lakeflow-connect `scripts/`): previews, compute, target catalog, grants, egress ranges.

Integrated CDC updates can run a long time on an idle source. Stop them after 30 minutes:

```bash
bin/stop_after.sh 30 <pipeline-id> <pipeline-id>
```

What to check in each result (`/tmp/<name>-results/p1.json`, or the session's final answer):

- **Pipeline names** follow the convention, and nothing was created before the go-ahead.
- **The rows-per-run report** matches the source: snapshot counts equal source row counts
  (distinct rows for tables without a primary key under CDC).
- **Expected failures leave nothing behind**, especially Postgres replication slots and
  publications.
- **No secrets on disk:** the Lakebase demo writes `conn.json` with a generated password and must
  delete it.

### Clean up

After a deploy test: `databricks bundle destroy` in each `/tmp/<name>-work`, stop any standard
CDC gateway (`databricks pipelines stop <gateway-id>`), and drop any Postgres slot a test
created. The skill's own cleanup steps cover this; check they ran.

## Prompt file format

One `tag|prompt` per line. A `tag+|text` line is a follow-up turn: it resumes the session started
by `tag` and appends to the same `/tmp/<name>-results/<tag>.json`.

```
p1|Set up a Lakeflow Connect query-based ingestion pipeline from the existing connection ${LFC_PG_CONNECTION} in the workspace for Databricks CLI profile ${PIPELINE_WS}.
p1+|Use the source tables intpk and dtix ... Yes, create everything, run it once, then show the rows per table per run report.
```

## Permissions for headless sessions

Headless sessions can't answer permission prompts. `bin/run_batch.sh` passes a scoped allowlist
through `CLAUDE_ALLOWED_TOOLS`, as a single `--allowedTools` argument so rules with spaces
survive. That covers the Databricks CLI, file tools, `jq`, `WebFetch` (skills check current docs),
and `rm` of `conn.json` by every path a session might use (`/tmp` resolves to `/private/tmp` on
macOS). Don't put rules with spaces in `CLAUDE_ARGS`: it's split on spaces.

## Workspace file bridge

When editing in a sandbox (Omnigent, Solution Builder) with no git push access, `sync.sh`
uploads and downloads individual files through a Databricks workspace (`push` / `pull` for skill
files, `push-tests` / `pull-tests` for this repo). See "Exporting skill changes from a sandbox" in
the skills repo's CLAUDE.md.

## Test results

Every run is recorded in [`results/`](results/): `runs/<run>.jsonl` holds one record per test cell (what, where, outcome, counts, the exact error, both repos' commits), and `results/<date>-<topic>.md` is the write-up. See what's been tested before running anything:

```bash
uv run skills/lfc-test-results/scripts/recall.py                    # latest result per test x engine x host
uv run skills/lfc-test-results/scripts/recall.py --engine oracle --all
```

Record new results with `skills/lfc-test-results/scripts/record.py`, which refuses anything that looks internal (this repo is public). The [lfc-test-results](skills/lfc-test-results/SKILL.md) skill has the format and rules.

