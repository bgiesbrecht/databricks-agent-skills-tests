# Lakeflow Connect UI demos

Screenshots of the Lakeflow Connect UI for database sources, one folder per database and mode, captured with Playwright. Each run writes numbered PNGs (one per click), a clear and a redacted GIF, and `metrics.yaml`. At the end it opens the pipeline after its first run and saves the graph view of a successful update.

**Captures stay local.** Every run goes to `runs/` next to its script, and `runs/` and `auth.json` are gitignored: screenshots show workspace URLs and other people's objects, and this repository is public. Commit scripts and READMEs only.

| Database | Mode | Folder |
|---|---|---|
| PostgreSQL | query-based (QBC) | [db/postgres/qbc](db/postgres/qbc/README.md) |

Planned, one at a time: QBC for SQL Server, MySQL and Oracle; then integrated CDC (gateway) and QBC through a foreign catalog for each.

`lfc_ui/` holds the shared helpers: `capture.py` (a numbered screenshot at each click, click timing in `metrics.yaml`, GIFs) and `image_redact.py` (redacted copies: known digit IDs, such as account and workspace IDs, are masked with the last four digits kept; names and hosts stay readable). Both come from the lfc-faq notes' Google Ads demo.

## Setup (once)

From the repository root:

```bash
brew install tesseract                          # OCR for the redacted copies
python3 -m venv .venv                           # gitignored
.venv/bin/python -m pip install -r ui-demos/requirements.txt
.venv/bin/playwright install chromium
.venv/bin/python -c "import playwright, PIL, yaml, pytesseract; print('ok')"
```

## Sign-in: attach to your own Chrome when SSO blocks automation

On workspaces whose single sign-on checks the device (seen: Okta device trust on the field demo workspaces), a browser started by Playwright or by the Chrome DevTools tools is refused or closed during sign-in. What works is attaching the Chrome DevTools tools (`chrome-devtools-mcp`) to the Chrome you already use:

1. In Claude Code's MCP settings, start `chrome-devtools-mcp` with `--autoConnect` (Chrome 144 or later), and reconnect it with `/mcp`.
2. In your Chrome, open `chrome://inspect/#remote-debugging` and turn remote debugging on; accept Chrome's prompt to allow the connection.
3. Sign in to the workspace yourself, in that Chrome. Then each step's screenshot is taken from that tab.
4. **Turn remote debugging off when done:** while it's on, any local program can drive that Chrome and its signed-in sessions.

Playwright replay (below) still works on workspaces that don't check the device.

## Names

The pipeline and its schema get the same name, so one finds the other: `[firstname][lastname]-[connector name]` with every character that isn't a letter or digit turned into `_`, plus `_2`, `_3`, ... when it's taken (check both the pipeline and the schema). For example `janedoe_lfcddemo_azure_pg`. The event log and the tables go into that schema in the workspace's default catalog.

## Save a browser login (once per workspace, again when it expires)

Playwright reuses a saved login, `auth.json` in the demo's folder (gitignored; never share it). This opens a Chromium window: sign in, wait for the workspace home page, then **close the window** to save it.

```bash
cd ui-demos/db/postgres/qbc
../../../../.venv/bin/python -m playwright open --save-storage=auth.json "https://<workspace-host>"
```

To refresh an expired one, add `--load-storage=auth.json`. To record a new flow as a starting point for a script, use `codegen` instead of `open`:

```bash
../../../../.venv/bin/python -m playwright codegen --target python --output=new-demo.py \
  --load-storage=auth.json --save-storage=auth.json "https://<workspace-host>"
```

## Run

From the demo's folder, with the workspace's CLI profile (used to check the connection before the UI steps, and to read the pipeline after):

```bash
cd ui-demos/db/postgres/qbc
DATABRICKS_PROFILE=<profile> ../../../../.venv/bin/python demo.py
```

Each run goes into `runs/<pipeline-name>/`: `clear/` and `redacted/` PNGs, `clear.gif`, `redacted.gif`, and `metrics.yaml` (workspace, pipeline ID, time between clicks).

## Rules

- **Ask before creating anything** in a shared workspace: say the pipeline and schema name (see Names) and the tables first. Stop the pipeline after the capture, and delete it when the demo is no longer needed.
- **Share only the redacted copies** outside the team: the clear ones keep account and workspace identifiers.
- The UI depends on the webapp version deployed to the workspace, not on DBR: `metrics.yaml` records the UI commit when the page exposes it.
