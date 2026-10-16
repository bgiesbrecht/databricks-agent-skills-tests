#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""recall.py: look up recorded test results (results/runs.jsonl).

  uv run recall.py                                  # latest result per test x engine x host (the current status)
  uv run recall.py --engine oracle --test icdc      # every Oracle integrated-CDC result, newest first
  uv run recall.py --outcome fail,blocked --since 2026-10-01 --all
  uv run recall.py --grep TLS                       # free text in result, error, notes
  uv run recall.py --coverage                       # test x engine grid: latest outcome per cell, across every setup
  uv run recall.py --workspace serverless --storage juicefs   # filter on workspace and setup fields too

Filters combine. --all lists every matching record instead of the latest per cell. --json prints records.
"""
import argparse, json
from pathlib import Path

RUNS = Path(__file__).resolve().parents[3] / "results" / "runs"
ICON = {"pass": "✅", "fail": "❌", "blocked": "⛔", "expected-stop": "✅ stop", "partial": "⚠️"}

def main():
    ap = argparse.ArgumentParser()
    for k in ("engine", "test", "outcome", "host", "run", "grep", "since", "workspace", "storage"): ap.add_argument(f"--{k}")
    ap.add_argument("--all", action="store_true"); ap.add_argument("--json", action="store_true"); ap.add_argument("--coverage", action="store_true")
    a = ap.parse_args()
    lines = [l for f in sorted(RUNS.glob("*.jsonl")) for l in f.read_text().splitlines() if l.strip()] if RUNS.exists() else []
    recs = [dict(json.loads(l), _line=i) for i, l in enumerate(lines)]
    def keep(r):
        s = r.get("subject", {})
        return ((not a.engine or a.engine.lower() in s.get("engine", "").lower())
            and (not a.test or r["test"] in a.test.split(","))
            and (not a.outcome or r["outcome"] in a.outcome.split(","))
            and (not a.host or a.host.lower() in r.get("host", "").lower())
            and (not a.run or a.run in r["run"])
            and (not a.since or r["date"] >= a.since)
            and (not a.workspace or a.workspace.lower() in json.dumps(r.get("workspace", {})).lower())
            and (not a.storage or a.storage.lower() in str(r.get("setup", {}).get("storage", "")).lower())
            and (not a.grep or a.grep.lower() in " ".join(str(r.get(k, "")) for k in ("result", "error", "notes")).lower()))
    recs = sorted(filter(keep, recs), key=lambda r: (r["date"], r["_line"]), reverse=True)   # newest first; later lines win ties
    if a.coverage:                                   # newest outcome per test x engine, any host or setup
        cell = {}
        for r in recs: cell.setdefault((r["test"], r["subject"].get("engine", "")), r)
        tests = sorted({t for t, _ in cell}); engines = sorted({e for _, e in cell})
        print("| test | " + " | ".join(engines) + " |\n|---|" + "---|" * len(engines))
        for t in tests: print(f"| {t} | " + " | ".join(ICON.get(cell[(t, e)]["outcome"], "?") if (t, e) in cell else "" for e in engines) + " |")
        print("\nempty = never recorded; each cell is the newest result for that test and engine (see --all for setups)")
        return
    if not a.all:                                    # newest per cell; the file is append-only, so later lines win ties
        seen, latest = set(), []
        for r in recs:
            key = (r["test"], r["subject"].get("engine"), r.get("host", ""))
            if key not in seen: seen.add(key); latest.append(r)
        recs = sorted(latest, key=lambda r: (r["subject"].get("engine", ""), r["test"]))
    if a.json:
        for r in recs: r.pop("_line"); print(json.dumps(r))
        return
    print("| Date | Test | Engine | Host | Outcome | Result | Run |\n|---|---|---|---|---|---|---|")
    for r in recs:
        s = r["subject"]; eng = " ".join(x for x in (s.get("engine"), s.get("version")) if x)
        res = r["result"] + (f" — {r['error']}" if r.get("error") else "")
        print(f"| {r['date']} | {r['test']} | {eng} | {r.get('host', '')} | {ICON.get(r['outcome'], r['outcome'])} | {res} | {r['run']} |")
    print(f"\n{len(recs)} result(s)")

if __name__ == "__main__":
    main()
