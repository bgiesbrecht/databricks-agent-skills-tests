---
name: lfc-test-results
description: Record and recall Lakeflow Connect test results (source setup, UC connections, query-based and CDC ingestion, branch layers, performance) so anyone can see what was tested, where, with which skill versions, and what happened. Use after any test run, and before testing something, to check what's already known.
parent: lfc-source-setup
---

# Test results: record and recall

Every test run leaves two things in this repo's `results/`, so the next person (or agent) can find out what's been tested without rerunning it:

| File | What | Who reads it |
|---|---|---|
| `results/runs.jsonl` | One JSON record per test cell (engine × mode × host), append-only | `recall.py`, `jq`, DuckDB, agents |
| `results/<date>-<topic>.md` | The write-up of one run: setup, a results table, what broke, which skill fixes came out of it | people |

The repo is **public**: records and write-ups hold outcomes, counts, versions and error text, never IPs, hostnames, IDs, emails, catalog or workspace names, or credentials. `record.py` refuses a record that looks like it holds any of these.

## Before testing: recall

```bash
S=skills/lfc-test-results/scripts
uv run $S/recall.py                                   # current status: the latest result per test x engine x host
uv run $S/recall.py --engine oracle                   # everything about one engine, newest first
uv run $S/recall.py --test icdc,scdc --outcome blocked,fail --all
uv run $S/recall.py --grep "not supported in your workspace"
```

Then read the run's write-up (`--run` names it) for the details. If a cell already passed with the current skill commits (`skills` in the record), don't rerun it unless the user asks or the docs changed.

`jq` and DuckDB work on the file directly:

```bash
jq -c 'select(.subject.engine == "mysql" and .test == "icdc")' results/runs.jsonl
duckdb -c "SELECT test, subject.engine, outcome, count(*) FROM read_json('results/runs.jsonl') GROUP BY ALL ORDER BY ALL"
```

## After testing: record

Record every cell you ran, including the ones that stopped (`expected-stop`) or were refused by the workspace (`blocked`). A record is one line of JSON:

| Field | Required | Content |
|---|---|---|
| `date` | yes | `YYYY-MM-DD` of the run |
| `run` | yes | the run's name, the same as its write-up: `<date>-<topic>` |
| `test` | yes | `connection`, `qbc`, `fcqbc` (QBC via foreign catalog), `icdc` (integrated CDC), `scdc` (standard CDC), `dml`, `source-setup`, `rclone-pull`, `reflink-isolation`, `juicefs-clone`, `disk-restore`, `snapshot-read`, `write-tps`, `other` |
| `subject` | yes | `{"engine": "oracle", "version": "23ai Free 23.26"}`, plus `image`, `edition` where they matter |
| `outcome` | yes | `pass`, `fail`, `blocked` (the workspace or environment refused it), `expected-stop` (the skill correctly stopped), `partial` |
| `result` | yes | what happened, with counts: `snapshot 10/10; 3 inserts, 2 updates, 2 deletes applied (11/11)` |
| `host` | | where the source ran: `azure-vm-podman`, `azure-flexserver`, `aws-rds`, `local-podman`, `lakebase` |
| `workspace` | | `{"cloud": "azure", "region": "centralus", "compute": "serverless-only", "catalog": "own storage"}`; descriptions, never names or IDs |
| `metrics` | | numbers: `{"rows": 5000000, "clone_s": 0.1, "tps": 234}` |
| `error` | non-pass | the exact error text, with names and IDs replaced (`<connection>`, `<pipeline-id>`) |
| `skills` | auto | both repos' commits; `record.py` fills it in from the checkouts next to each other |
| `docs` | | the skill files the test exercised or fixed |
| `notes` | | anything else: a workaround, a doc defect found |

```bash
cat > /tmp/rec.jsonl <<'EOF'
{"date": "2026-10-16", "run": "2026-10-16-azvm-sources", "test": "icdc", "host": "azure-vm-podman",
 "subject": {"engine": "oracle", "version": "23ai Free 23.26"}, "workspace": {"cloud": "azure", "compute": "serverless-only"},
 "outcome": "pass", "result": "snapshot 10/10; 3 inserts, 2 updates, 2 deletes applied (11/11)"}
EOF
uv run $S/record.py < /tmp/rec.jsonl            # validates the batch, appends it, or prints what's wrong and appends nothing
uv run $S/record.py --check                     # re-validate the whole file (bin/test_scripts.sh runs this)
```

Write each record on one line in the file you pipe in (or pass a JSON array). Then write or extend `results/<run>.md`: the environment (cloud, region, workspace type, catalog type, VM size), a results table, what broke and how it was fixed, and the skill fixes. Commit both with the skill fixes they led to.

## Rules

- **Placeholders, not names.** IPs as `203.0.113.x`, `<connection>`, `<catalog>`, `<pipeline-id>`, `<workspace>`. Describe a catalog by its kind ("Default Storage", "own managed storage"), not its name.
- **Exact errors.** Copy the product's error text, after replacing names and IDs; that's what the next person will search for.
- **One record per cell per run.** A rerun after a fix is a new record with a new date or run name; don't edit old ones (the file is append-only, and `recall.py` shows the newest).
- **Say what wasn't tested.** A cell that was skipped, or tested only partly, is a `partial` or `blocked` record with a note, not a silent gap.
- **Results come from real runs only.** Never record a predicted or expected outcome as a result.
