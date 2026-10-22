#!/usr/bin/env python3
"""Check a limits file against the documentation it cites: each row's quote must appear in its page's text.

usage: limits-check.py <limits.yaml> [...] [--cache DIR] [--markdown] [--only-failed]
       limits-check.py --find <url> <words> [--cache DIR]   (the page text around the words, to copy a quote from)

A limits file is a YAML list of rows:

  - product: PostgreSQL            # the engine, or the managed service (Amazon RDS for PostgreSQL)
    limit: relation (table) size   # what is limited
    value: 32 TB
    kind: hard                     # hard | soft (raised on request: say how in note) | configurable (setting) |
                                   # recommended (the vendor's guidance) | behavior (documented, not a cap)
    setting: ""                    # configurable: the setting that changes it
    url: https://www.postgresql.org/docs/current/limits.html
    quote: "relation size | 32 TB | with the default BLCKSZ of 8192 bytes"
    ask: "the biggest table's size: one table can't pass 32 TB"   # optional: the question it raises
    checked: 2026-10-22
    text_url: ""                   # optional: where the page's text is when url renders it with JavaScript

Each page is fetched once (curl; --cache keeps them) and turned into text: tags dropped, a table's cells joined
with " | ", whitespace collapsed. A quote passes when it appears in that text, compared without case, with quotes,
dashes and spaces normalized, with or without the cell separators. Prints PASS or FAIL per row and exits 1 when any
failed; --markdown prints the passing rows as a table instead.
"""
import hashlib
import html
import json
import os
import re
import subprocess
import sys

import yaml


def text_of(page):
    if page.lstrip().startswith("{"):   # a docs API that wraps the page's HTML in JSON: {"content": "<h1>..."}
        try:
            page = json.loads(page).get("content", page)
        except ValueError:
            pass
    page = re.sub(r"(?is)<(script|style|noscript|svg)\b.*?</\1>", " ", page)
    page = re.sub(r"(?is)</t[dh]\s*>", " | ", page)
    page = re.sub(r"(?is)<br\s*/?>|</(tr|p|li|h[1-6]|div|pre|dt|dd)\s*>", "\n", page)
    return html.unescape(re.sub(r"(?s)<[^>]+>", " ", page))


def norm(s, cells=True):
    s = re.sub(r"[\u200b\u200c\u200d\ufeff]", "", s)
    s = s.replace("\u00a0", " ").replace("\u202f", " ").replace("\u2009", " ")
    s = re.sub(r"[\u2018\u2019\u201b`]", "'", s)
    s = re.sub(r"[\u201c\u201d]", '"', s)
    s = re.sub(r"[\u2010-\u2015\u2212]", "-", s)
    if not cells:
        s = s.replace("|", " ")
    # a tag between a word and its punctuation leaves a space: "No , you" is "No, you"
    return re.sub(r"\(\s+", "(", re.sub(r"\s+([,.;:)])", r"\1", " ".join(s.split()))).lower()


def fetch(url, cache):
    path = os.path.join(cache, hashlib.sha1(url.encode()).hexdigest() + ".html") if cache else None
    if path and os.path.exists(path):
        return open(path, encoding="utf-8", errors="replace").read()
    curl = ["curl", "-sSLf", "--max-time", "60"]
    r = subprocess.run(curl + ["-A", "Mozilla/5.0 (limits-check)", url], capture_output=True, check=False)
    if r.returncode in (22, 56):   # HTTP 4xx/5xx (56 over HTTP/2): Salesforce docs refuse any agent but curl's
        r = subprocess.run(curl + [url], capture_output=True, check=False)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.decode(errors="replace").strip()[:200])
    page = r.stdout.decode("utf-8", errors="replace")
    if path:
        os.makedirs(cache, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(page)
    return page


def main():
    args = sys.argv[1:]
    cache = None
    if "--cache" in args:
        i = args.index("--cache")
        cache = args[i + 1]
        del args[i:i + 2]
    if args and args[0] == "--find":   # --find <url> <words>: the page's text around each match, to quote from
        t = " ".join(text_of(fetch(args[1], cache)).split())
        for m in list(re.finditer(re.escape(args[2]), t, re.IGNORECASE))[:20]:
            print("...", t[max(0, m.start() - 200):m.end() + 300], "...\n")
        return
    markdown, only_failed = "--markdown" in args, "--only-failed" in args
    files = [a for a in args if not a.startswith("--")]
    if not files:
        sys.exit(__doc__)
    rows = []
    for f in files:
        with open(f) as fh:
            rows += yaml.safe_load(fh) or []
    texts, good, bad = {}, [], 0
    for r in rows:
        url, quote = r.get("url", ""), str(r.get("quote", ""))
        try:
            src = r.get("text_url") or url
            if src not in texts:
                texts[src] = text_of(fetch(src, cache))
            t = texts[src]
            ok = bool(quote.strip()) and (norm(quote) in norm(t) or norm(quote, False) in norm(t, False))
            why = "" if ok else "quote not on the page"
        except Exception as e:   # noqa: BLE001
            ok, why = False, f"fetch failed: {e}"
        if ok:
            good.append(r)
        else:
            bad += 1
        if not markdown and (not ok or not only_failed):
            print(f"{'PASS' if ok else 'FAIL'}\t{r.get('product')}\t{r.get('limit')}\t{r.get('value')}\t{why}\t{url}")
    if markdown:
        print("| Product | Limit | Value | Kind | What to ask | Source |\n|---|---|---|---|---|---|")
        for r in good:
            kind = r.get("kind", "") + (f" (`{r['setting']}`)" if r.get("setting") else "")
            print(f"| {r.get('product')} | {r.get('limit')} | {r.get('value')} | {kind} | {r.get('ask', '')} | "
                  f"[docs]({r.get('url')}) |")
    print(f"-- {len(good)} of {len(rows)} rows found on their pages", file=sys.stderr)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
