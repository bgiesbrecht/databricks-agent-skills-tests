#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""record.py: validate test-result records and append them to results/runs.jsonl.

  uv run record.py < records.jsonl            # one JSON object per line (or one JSON array)
  uv run record.py --check                    # re-validate every record already in runs.jsonl

Fills `skills` with both repos' current commits when it's missing. Refuses the whole batch if any
record is invalid or looks like it holds something internal (the repo is public).
"""
import json, re, subprocess, sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]                 # skills/lfc-test-results/scripts/record.py
RUNS = REPO / "results" / "runs.jsonl"
SKILLS_REPO = REPO.parent / "databricks-agent-skills"

REQUIRED = {"date", "run", "test", "subject", "outcome", "result"}
OUTCOMES = {"pass", "fail", "blocked", "expected-stop", "partial"}
TESTS = {"connection", "qbc", "icdc", "scdc", "fcqbc", "dml", "source-setup",      # ingestion and setup
         "rclone-pull", "reflink-isolation", "juicefs-clone", "disk-restore",      # branch layers
         "snapshot-read", "write-tps", "other"}
ALLOWED_KEYS = REQUIRED | {"host", "workspace", "metrics", "error", "skills", "docs", "notes"}

# Anything matching these is internal or secret; use placeholders (see SKILL.md)
LEAKS = [
    (r"(?<![\d.])(?!(?:192\.0\.2|198\.51\.100|203\.0\.113)\.)(?:\d{1,3}\.){3}\d{1,3}(?![\d.]|/)", "an IP address (use 203.0.113.x)"),
    (r"[\w.+-]+@[\w-]+\.[\w.]+", "an email address"),
    (r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", "a UUID (pipeline, update or subscription ID)"),
    (r"\b\d{15,16}\b", "a workspace or account ID"),
    (r"adb-\d+|\.azuredatabricks\.net|\.cloud\.databricks\.com|\.gcp\.databricks\.com", "a workspace URL"),
    (r"\.(?:blob|dfs)\.core\.windows\.net|\.amazonaws\.com|\.database\.azure\.com", "a cloud resource hostname"),
    (r"\bsig=|SharedAccessSignature|dapi[0-9a-f]{20,}|AKIA[0-9A-Z]{16}", "a credential"),
    (r"Lfc1[0-9a-f]{12,}", "a generated password"),
]

def leaks(rec):
    text = json.dumps(rec)
    return [why for pat, why in LEAKS if re.search(pat, text)]

def problems(rec):
    out = []
    if not isinstance(rec, dict): return ["not a JSON object"]
    missing = REQUIRED - rec.keys()
    if missing: out.append(f"missing {sorted(missing)}")
    extra = rec.keys() - ALLOWED_KEYS
    if extra: out.append(f"unknown keys {sorted(extra)}")
    if rec.get("outcome") not in OUTCOMES: out.append(f"outcome must be one of {sorted(OUTCOMES)}")
    if rec.get("test") not in TESTS: out.append(f"test must be one of {sorted(TESTS)}")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(rec.get("date", ""))): out.append("date must be YYYY-MM-DD")
    if not isinstance(rec.get("subject"), dict) or "engine" not in rec.get("subject", {}): out.append("subject needs an engine")
    if rec.get("outcome") != "pass" and not rec.get("error") and not rec.get("notes"): out.append("a non-pass needs error or notes")
    return out + [f"looks internal: {w}" for w in leaks(rec)]

def head(path):
    try: return subprocess.run(["git", "-C", str(path), "rev-parse", "--short", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    except Exception: return None

def load(text):
    text = text.strip()
    if not text: return []
    return json.loads(text) if text.startswith("[") else [json.loads(l) for l in text.splitlines() if l.strip()]

def main():
    if "--check" in sys.argv:
        recs = load(RUNS.read_text()) if RUNS.exists() else []
    else:
        recs = load(sys.stdin.read())
        auto = {k: v for k, v in {"databricks-agent-skills": head(SKILLS_REPO), "databricks-agent-skills-tests": head(REPO)}.items() if v}
        for r in recs:
            if isinstance(r, dict) and "skills" not in r and auto: r["skills"] = auto
    bad = [(i, p) for i, r in enumerate(recs) for p in problems(r)]
    for i, p in bad: print(f"record {i + 1}: {p}", file=sys.stderr)
    if bad: sys.exit(1)
    if "--check" in sys.argv: print(f"{len(recs)} records OK"); return
    RUNS.parent.mkdir(exist_ok=True)
    with RUNS.open("a") as f:
        for r in recs: f.write(json.dumps(r, separators=(",", ":")) + "\n")
    print(f"appended {len(recs)} records to {RUNS.relative_to(REPO)}")

if __name__ == "__main__":
    main()
