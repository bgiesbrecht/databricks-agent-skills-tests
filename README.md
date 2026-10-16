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

## Layout

```
run.sh                 # runner: one headless `claude -p` session per prompt, multi-turn via `tag+|`
summarize.py           # skills loaded, reference files read, answer preview
env.sh                 # sources env.local.sh, sets SKILLS_REPO / OMNIGENT_WS / PIPELINE_WS
env.example.sh         # copy to env.local.sh (gitignored) and fill in
sync.sh                # workspace file bridge for sandboxes without git push
bin/run_batch.sh       # run several prompt files in parallel, each in its own scratch dir
bin/stop_after.sh      # stop pipeline updates that run past N minutes
bin/test_scripts.sh    # regression tests for the skills' scripts (offline, or on Postgres and MySQL)
bin/check_links.py     # every relative link in every skill
pr-notes/              # PR descriptions with the test matrix, one per skills-repo branch
prompts/
  lakeflow-connect.txt # routing / guidance prompts (no resources created)
  lfc-matrix/          # Lakeflow Connect deploy tests: 4 sources x 3 modes, plus DML
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

Run one mode per batch, so tests on the same connection don't race for the same default
pipeline name (the skill names pipelines `<firstname><lastname>-<connection>`, then `-2`, `-3`;
standard CDC uses `-gw` / `-ap`):

```bash
bin/run_batch.sh prompts/lfc-matrix/qbc-*.txt     # query-based
bin/run_batch.sh prompts/lfc-matrix/icdc-*.txt    # integrated CDC
bin/run_batch.sh prompts/lfc-matrix/scdc-*.txt    # standard CDC (gateway + ingestion)
bin/run_batch.sh prompts/lfc-matrix/dml-lakebase.txt   # generate DML, run it, check the pipeline saw it
```

Integrated CDC updates can run a long time on an idle source. Stop them after 30 minutes:

```bash
bin/stop_after.sh 30 <pipeline-id> <pipeline-id>
```

Expected results, from a workspace where query-based and integrated CDC are enabled but the
Postgres and MySQL CDC gateways aren't:

| | Query-based | Integrated CDC | Standard CDC |
|---|---|---|---|
| Lakebase | works (bare "demo" prompt creates the Lakebase project) | not available for Postgres; nothing created | publication refused by Lakebase; stops, nothing created |
| Postgres | works | not available for Postgres; nothing created | 403 at deploy; nothing created on the source |
| MySQL | works | works (`-2` name) | 403 at deploy if the gateway isn't enabled |
| SQL Server | works | works (`-2` name) | works (`-gw` / `-ap`) |

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
