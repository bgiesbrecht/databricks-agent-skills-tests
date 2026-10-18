"""A long-lived Playwright browser with the saved workspace session, for working out a new wizard flow by hand.

    ../.venv/bin/python -m lfc_ui.browse serve [--headed]   # starts it (keep it running); debug port 9333
    ../.venv/bin/python -m lfc_ui.browse do '<python>'      # runs code with `p` (the page) and `re`, then prints the
                                                            # page's main accessibility tree and saves /tmp/browse.png

Each `do` attaches, acts, and detaches; the page stays where it was. Unlike your own Chrome, this browser takes any
number of clients and shows no Allow prompt. Once a flow works, move the steps into wizard.py.
"""

from __future__ import annotations

import re
import sys
import time

from playwright.sync_api import sync_playwright

from .auth import AUTH

PORT = 9333


def serve(headed: bool) -> None:
    with sync_playwright() as pw:
        b = pw.chromium.launch(headless=not headed, args=[f"--remote-debugging-port={PORT}"])
        ctx = b.new_context(storage_state=str(AUTH), viewport={"width": 1600, "height": 900})
        ctx.new_page().goto("about:blank")
        print(f"serving on {PORT}", flush=True)
        while True:
            time.sleep(3600)


def do(code: str) -> None:
    with sync_playwright() as pw:
        b = pw.chromium.connect_over_cdp(f"http://127.0.0.1:{PORT}")
        p = b.contexts[0].pages[-1]
        p.set_default_timeout(30_000)
        p.on("dialog", lambda d: d.accept())
        try:
            exec(code, {"p": p, "re": re, "time": time})
        except Exception as e:
            print(f"ERROR {type(e).__name__}: {str(e)[:500]}")
        print("url:", p.url)
        root = p.locator("main") if p.locator("main").count() else p.locator("body")
        print(root.first.aria_snapshot()[:6000])
        p.screenshot(path="/tmp/browse.png")


if __name__ == "__main__":
    if sys.argv[1] == "serve":
        serve("--headed" in sys.argv)
    else:
        do(sys.argv[2])
