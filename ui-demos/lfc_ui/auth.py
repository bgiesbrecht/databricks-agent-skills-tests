"""Save the workspace's browser session from your own Chrome, and check that a Playwright-launched browser can use it.

    ../.venv/bin/python -m lfc_ui.auth save     # attaches once (click Allow in Chrome), writes auth.json (mode 600)
    ../.venv/bin/python -m lfc_ui.auth check    # launches Chromium with auth.json: no Chrome, no Allow prompt

Only the workspace host's cookies are kept, not the whole Chrome profile's. auth.json holds a live session: it's
gitignored; never share it, and delete it when done (rm auth.json).
"""

from __future__ import annotations

import json
import os
import pathlib
import sys

from playwright.sync_api import sync_playwright

from .wizard import HOST, WORKSPACE_ID

AUTH = pathlib.Path(__file__).resolve().parents[1] / "auth.json"
DOMAIN = HOST.split("//")[1]


def save() -> None:
    port, path = (pathlib.Path.home() / "Library/Application Support/Google/Chrome/DevToolsActivePort").read_text().split()[:2]
    with sync_playwright() as pw:
        ctx = pw.chromium.connect_over_cdp(f"ws://127.0.0.1:{port}{path}", timeout=60_000).contexts[0]
        cookies = [c for c in ctx.cookies() if DOMAIN.endswith(c["domain"].lstrip("."))]
    AUTH.touch(mode=0o600)
    os.chmod(AUTH, 0o600)
    AUTH.write_text(json.dumps({"cookies": cookies, "origins": []}))
    print(f"saved {len(cookies)} cookies for {DOMAIN} to {AUTH}")


def check() -> int:
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=False)
        page = browser.new_context(storage_state=str(AUTH), viewport={"width": 1600, "height": 900}).new_page()
        page.goto(f"{HOST}/ingestion/add?o={WORKSPACE_ID}")
        try:
            page.locator('a[href*="sourceType=POSTGRESQL"]').first.wait_for(timeout=30_000)
            ok = True
        except Exception:
            ok = False
        page.screenshot(path=str(AUTH.parent / "auth-check.png"))
        print("signed in" if ok else f"NOT signed in: {page.url[:100]}")
        browser.close()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(save() if sys.argv[1:] == ["save"] else check())
