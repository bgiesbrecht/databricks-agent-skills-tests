#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""finding.py: the findings register, results/findings/<id>.json, one file per finding.

  uv run finding.py add [--update] < finding.json      # one JSON object per line (or one JSON array)
  uv run finding.py --check                             # validate every finding
  uv run finding.py [--source mysql] [--route debezium-zerobus] [--layer silver] [--topology n:1]
                    [--kind ...] [--status ...] [--long] [--with-test]   # the findings for a combination
  uv run finding.py --md > docs/findings.md             # the table for people

A finding is anything a test turned up that a real deployment of the same combination would also meet: a source's
behavior, a connector's, a Databricks limit or bug, a gap in the pattern (bronze, silver, gold), or a defect in the
test tooling that made a check wrong. Not a typo. Each says which combination it applies to, so before building a
customer's combination you can list what's known for it. A query matches a finding when every value given is in the
finding's list for that axis, or the list has "*".
"""
import json, re, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from record import leaks   # the same public-repo check as the run records

REPO = Path(__file__).resolve().parents[3]
DIR = REPO / "results" / "findings"

KINDS = {"source-behavior", "connector-behavior", "databricks-limit", "databricks-bug", "pattern", "tooling"}
STATUSES = {"fixed", "workaround", "by-design", "documented-limit", "open"}
AXES = {   # the combination: what a customer chooses. "*": any value
    "source": {"postgres", "mysql", "mariadb", "sqlserver", "oracle", "db2", "informix", "cockroachdb", "yugabytedb",
               "lakebase", "*"},   # the run records' subject.engine
    "route": {"lfc-qbc", "lfc-icdc", "lfc-scdc", "debezium-zerobus", "kafka-connect-zerobus", "*"},
    "layer": {"source", "capture", "producer", "bronze", "silver", "gold", "test", "*"},
    "topology": {"1:1", "n:1", "1:n", "*"},   # sources : targets. n:1 many databases into one silver; 1:n one into many
}
REQUIRED = {"id", "title", "kind", "status", "applies", "found", "symptom", "cause", "effect", "fix"}
ALLOWED = REQUIRED | {"versions", "not_affected", "where", "refs", "notes"}


def problems(f):
    out = []
    if not isinstance(f, dict): return ["not a JSON object"]
    if REQUIRED - f.keys(): out.append(f"missing {sorted(REQUIRED - f.keys())}")
    if f.keys() - ALLOWED: out.append(f"unknown keys {sorted(f.keys() - ALLOWED)}")
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", str(f.get("id", ""))): out.append("id must be lowercase kebab case")
    if f.get("kind") not in KINDS: out.append(f"kind must be one of {sorted(KINDS)}")
    if f.get("status") not in STATUSES: out.append(f"status must be one of {sorted(STATUSES)}")
    a = f.get("applies")
    if not isinstance(a, dict): out.append("applies must be an object")
    else:
        for ax, ok in AXES.items():
            v = a.get(ax)
            if not isinstance(v, list) or not v: out.append(f"applies.{ax} must be a non-empty list"); continue
            if set(v) - ok: out.append(f"applies.{ax}: unknown {sorted(set(v) - ok)}; add new values to AXES in the same PR")
        if a.keys() - AXES.keys(): out.append(f"applies: unknown axes {sorted(a.keys() - AXES.keys())}")
    fd = f.get("found")
    if not isinstance(fd, dict) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(fd.get("date", ""))) or not fd.get("by"):
        out.append("found needs date (YYYY-MM-DD) and by (the test and its settings, or the run's name)")
    for k in ("not_affected", "where", "refs"):
        if k in f and not isinstance(f[k], list): out.append(f"{k} must be a list")
    return out + [f"looks internal: {w}" for w in leaks(f)]


def load(text):
    text = text.strip()
    if not text: return []
    return json.loads(text) if text.startswith("[") else [json.loads(l) for l in text.splitlines() if l.strip()]


def all_findings():
    return [json.loads(p.read_text()) for p in sorted(DIR.glob("*.json"))] if DIR.exists() else []


def arg(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None


def matches(f):
    # findings only about the test itself (layer "test") show with --with-test or --layer test: a lookup for a
    # customer's combination lists what a deployment meets
    if f["applies"]["layer"] == ["test"] and "--with-test" not in sys.argv and arg("--layer") != "test" and "--md" not in sys.argv:
        return False
    for ax in AXES:
        v = arg(f"--{ax}")
        if v and not ({v, "*"} & set(f["applies"][ax])): return False
    return all(not arg(f"--{k}") or f[k] == arg(f"--{k}") for k in ("kind", "status"))


def cell(v):
    return ", ".join(v) if isinstance(v, list) else str(v)


def md(fs):
    order = {k: i for i, k in enumerate(["source-behavior", "connector-behavior", "databricks-limit", "databricks-bug", "pattern", "tooling"])}
    fs = sorted(fs, key=lambda f: (order[f["kind"]], f["id"]))
    print("# Findings: what the tests turned up, by combination\n")
    print("Generated by `uv run skills/lfc-test-results/scripts/finding.py --md` from `results/findings/*.json`; edit those, "
          "not this file. Each finding applies to the combination in its columns (`*`: any). List the ones for a "
          "combination with `finding.py --source <s> --route <r> --topology <t>`. Back to the [README](../README.md).\n")
    print("| Finding | Kind | Source | Route | Layer | Topology | Status |\n|---|---|---|---|---|---|---|")
    for f in fs:
        a = f["applies"]
        print(f"| [{f['title']}](#{f['id']}) | {f['kind']} | {cell(a['source'])} | {cell(a['route'])} | {cell(a['layer'])} "
              f"| {cell(a['topology'])} | {f['status']} |")
    for f in fs:
        print(f"\n<a id=\"{f['id']}\"></a>\n### {f['title']}\n")
        for k, label in (("versions", "Versions"), ("symptom", "Seen"), ("cause", "Cause"), ("effect", "Effect"),
                         ("fix", "Fix or workaround"), ("not_affected", "Not affected"), ("where", "Where"), ("refs", "References"),
                         ("notes", "Notes")):
            if f.get(k): print(f"- **{label}:** {cell(f[k])}")
        print(f"- **Found:** {f['found']['date']}, {f['found']['by']}")


def main():
    if "--check" in sys.argv or "add" in sys.argv:
        fs = all_findings() if "--check" in sys.argv else load(sys.stdin.read())
        bad = [(f.get("id", i) if isinstance(f, dict) else i, p) for i, f in enumerate(fs) for p in problems(f)]
        ids = [f.get("id") for f in fs if isinstance(f, dict)]
        bad += [(i, "duplicate id") for i in {i for i in ids if ids.count(i) > 1}]
        for i, p in bad: print(f"{i}: {p}", file=sys.stderr)
        if bad: sys.exit(1)
        if "--check" in sys.argv: print(f"{len(fs)} findings OK"); return
        DIR.mkdir(parents=True, exist_ok=True)
        for f in fs:
            p = DIR / f"{f['id']}.json"
            if p.exists() and "--update" not in sys.argv: print(f"{p.name} exists: --update to replace it", file=sys.stderr); sys.exit(1)
            p.write_text(json.dumps(f, indent=2, ensure_ascii=False) + "\n"); print(f"wrote {p.relative_to(REPO)}")
        return
    fs = [f for f in all_findings() if matches(f)]
    if "--md" in sys.argv: md(fs); return
    for f in fs:
        print(f"{f['id']}\t{f['kind']}\t{f['status']}\t{f['title']}")
        if "--long" in sys.argv: print(f"  effect: {f['effect']}\n  fix: {f['fix']}")


if __name__ == "__main__":
    main()
