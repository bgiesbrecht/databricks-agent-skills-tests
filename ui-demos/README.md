# Lakeflow Connect UI demos

Screenshots of the Lakeflow Connect UI for database sources, one folder per database and mode, captured from your own Chrome through the Chrome DevTools tools (not Playwright: see Sign-in). Each run writes numbered PNGs (one per step), a clear and a redacted GIF, and `metrics.yaml`. At the end it opens the pipeline after its first run and saves the graph view of a successful update.

**Captures stay local.** Every run goes to `runs/` next to its script, and `runs/` and `auth.json` are gitignored: screenshots show workspace URLs and other people's objects, and this repository is public. Commit scripts and READMEs only.

| Database | Mode | Folder |
|---|---|---|
| PostgreSQL | query-based (QBC) | [db/postgres/qbc](db/postgres/qbc/README.md) |
| SQL Server | query-based (QBC) | [db/sqlserver/qbc](db/sqlserver/qbc/README.md) |
| MySQL | query-based (QBC) | [db/mysql/qbc](db/mysql/qbc/README.md) |

Planned, one at a time: QBC for Oracle; then integrated CDC (gateway) and QBC through a foreign catalog for each.

`lfc_ui/` holds the shared helpers: `capture.py` (after the screenshots: redacted copies, the time between screenshots in `metrics.yaml`, GIFs) and `image_redact.py` (redacted copies: known digit IDs, such as account and workspace IDs, are masked with the last four digits kept; names and hosts stay readable). Both come from the lfc-faq notes' Google Ads demo.

## Setup (once)

From the repository root:

```bash
brew install tesseract                          # OCR for the redacted copies
python3 -m venv .venv                           # gitignored
.venv/bin/python -m pip install -r ui-demos/requirements.txt
.venv/bin/python -c "import PIL, yaml, pytesseract; print('ok')"
```

## Sign-in: attach to your own Chrome

The step-by-step procedure, including a check script and when to reconnect, is the [lfc-ui-capture](../skills/lfc-ui-capture/SKILL.md) skill.

On workspaces whose single sign-on checks the device (seen: Okta device trust on the field demo workspaces), a browser that automation starts (Playwright's Chromium, or a Chrome started by the Chrome DevTools tools) is refused or closed during sign-in. What works is attaching the Chrome DevTools tools (`chrome-devtools-mcp`) to the Chrome you already use:

1. In Claude Code's MCP settings, start `chrome-devtools-mcp` with `--autoConnect` (Chrome 144 or later), and reconnect it with `/mcp`.
2. In your Chrome, open `chrome://inspect/#remote-debugging` and turn remote debugging on; accept Chrome's prompt to allow the connection.
3. Sign in to the workspace yourself, in that Chrome. Then each step's screenshot is taken from that tab.
4. **Turn remote debugging off when done:** while it's on, any local program can drive that Chrome and its signed-in sessions.

Don't use Playwright for these demos: its browser can't sign in, and its saved logins (`auth.json`) don't help.

## Source tables

By convention every demo source has the same two tables in a schema named `lfcddemo` (in MySQL, which has no schema level, the database `lfcddemo`): `intpk` (primary key `pk`, cursor `dt`, ingested as SCD type 1) and `dtix` (no key, cursor `dt`, ingested append-only). Only the connection and, where there is one, the database differ.

## Names

The pipeline, its schema, and its schedule job get the same name, the one the **databricks-lakeflow-connect** skill gives them from a bundle or the REST API (see **Default names** there), so a UI demo and a scripted run line up: `[firstname][lastname]_[connection name]_[epoch]`, every character that isn't a letter or digit turned into `_`, and `[epoch]` the seconds since the epoch, taken once (`date +%s`) before the first click and reused for every object and the run folder. For example `janedoe_lfcddemo_azure_pg_1792351234`. The event log and the tables go into that schema in the workspace's default catalog.

## Run a capture with the script (QBC: PostgreSQL, SQL Server, MySQL)

`lfc_ui/wizard.py` drives the wizard with Playwright **attached to your own signed-in Chrome** (it never launches a browser, so single sign-on isn't involved), boxes each step in red, saves the PNGs, runs the pipeline once, then deletes the job and the pipeline (`--keep` keeps them; the schema always stays). Measured: 27 steps in 2.5 minutes on PostgreSQL, against about 20 by hand.

**Usual way, no prompt:** save the workspace session once, then each run starts Playwright's own browser with it (headless, 1600x900; `--headed` to watch). The Chrome DevTools MCP server can stay on.

```bash
cd ui-demos
../.venv/bin/python -m lfc_ui.auth save      # once, and again when check fails: attaches to your Chrome, click Allow
../.venv/bin/python -m lfc_ui.auth check     # Playwright's Chromium opens the workspace signed in
../.venv/bin/python -m lfc_ui.wizard postgres --launch      # or sqlserver, mysql
```

`auth save` keeps only the workspace host's cookies, in `auth.json` (mode 600, gitignored): a live session, so never share it, and `rm auth.json` when done. Tested 2026-10-18: Playwright's Chromium with it opened the workspace signed in, and a PostgreSQL run completed in 2.4 minutes.

**Without a saved session:** run without `--launch` to attach to your own Chrome: `chrome://inspect/#remote-debugging` on, the Chrome DevTools MCP server **off** (Chrome allows one client on its debug socket; a second gets 403), and click **Allow** in Chrome's "Allow remote debugging?" prompt (Chrome's own, so no script can click it).

On failure it stops and leaves `fail.png`, `fail.aria.txt` (the accessibility tree) and `trace.zip` (`../.venv/bin/playwright show-trace <run>/trace.zip`) in the run folder. Turn the MCP server back on, get past the changed screen by hand (the steps below), then fix that step in `wizard.py`.

## Run by hand

1. Take the epoch once (`date +%s`) and make the name (see Names); the run folder is `db/<database>/<mode>/runs/<name>/`.
2. Drive the wizard in the attached Chrome with the Chrome DevTools tools. Before each click, save a screenshot with `take_screenshot` to `runs/<name>/clear/NNN_<step>.png` (`001_add_data.png`, `002_select_connection.png`, ...).
3. After the first run of the pipeline, save its graph view as the last screenshot.
4. Finish the run from the demo's folder: redacted copies, `metrics.yaml`, and GIFs.

```bash
cd ui-demos/db/postgres/qbc
PYTHONPATH=../../.. ../../../../.venv/bin/python -m lfc_ui.capture runs/<name> \
  --secret <account-id> --secret <workspace-id> --meta workspace=<host> --meta pipeline_id=<id>
```

Each run ends with `clear/` and `redacted/` PNGs, `clear.gif`, `redacted.gif`, and `metrics.yaml` (the `--meta` values, and the seconds between screenshots, taken from the files' times).

## Rules

- **Ask before creating anything** in a shared workspace: say the pipeline and schema name (see Names) and the tables first. Once the completed update's graph is captured, delete the schedule job, then the pipeline.
- **Share only the redacted copies** outside the team: the clear ones keep account and workspace identifiers.
- The UI depends on the webapp version deployed to the workspace, not on DBR: `metrics.yaml` records the UI commit when the page exposes it.
