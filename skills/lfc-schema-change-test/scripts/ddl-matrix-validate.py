#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
"""ddl-matrix-validate.py [FILES...]: check schema-change matrix result files (results/ddl-matrix/*.yaml).

  uv run ddl-matrix-validate.py results/ddl-matrix/*.yaml     # one line per problem; exit 1 if any, else "ok" per file

Checks the file name against its environment (engine, mechanism, setup, date), each case's id against ddl-cases.yaml
(and that the mechanism applies to the engine), the enums, the field types, the rules that tie fields together (a
restart needs no full refresh, a stop needs one, a confounded row is unverified, a not-run case lands nothing), and
that no internal name, address, identifier or path is in the text. A file that fails is not rendered or written.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
ENGINES = {"sqlserver", "postgres", "mysql", "oracle"}
MECHANISMS = {"ct", "cdc", "logical-replication", "binlog", "logminer", "query-based"}
PIPELINE_MODES = {"integrated", "standard", "query-based"}
COMPUTE = {"serverless", "classic"}
SETUPS = {"none", "utility-1.7", "utility-1.7-cleanup", "setup-package"}
METHODS = {"batch", "one-case-at-a-time", "not-recorded"}
OUTCOMES = {"restart-no-full-refresh", "no-interruption", "table-stops-full-refresh", "pipeline-fails",
            "not-applicable", "not-run"}
LEVELS = {"error", "warning", "info"}
BASIS = {"tested", "confounded", "code-only", "partial"}
ENV_KEYS = {"engine", "product", "edition_tier", "version", "mechanism", "setup", "source_setup", "pipeline_mode",
            "compute", "runtime", "workspace", "date", "who_ran", "method", "caveats"}
CASE_KEYS = {"id", "ddl", "column_before", "column_after", "source_accepted", "events", "outcome",
             "full_refresh_needed", "auto_full_refresh_applies", "destination_type_after", "post_change_row_landed",
             "value_check", "basis", "notes"}
# Generic identifiers that must not be in a public results file: IPv4 addresses, GUIDs and user home paths. The internal
# names and tickets are not listed here: the public-repo guard keeps that list, and it runs on the file text when
# PUBLIC_REPO_GUARD names its check script (the pre-commit hook runs it on the staged lines in any case).
FORBIDDEN = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b|"
                       r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|/Users/|/home/", re.I)
NAME_RE = re.compile(r"^(?P<engine>[a-z]+)-(?P<mech>[a-z-]+?)-(?P<setup>none|utility-1\.7(?:-cleanup)?|setup-package)-"
                     r"(?P<date>\d{4}-\d{2}-\d{2})(?:-(?P<n>\d+))?\.yaml$")


def catalog() -> dict:
    return yaml.safe_load((HERE / "ddl-cases.yaml").read_text())


def case_index(cat: dict) -> dict:
    return {c["id"]: c for c in cat["cases"]}


def problems(path: Path, cat: dict | None = None) -> list[str]:
    """Problems in a result file on disk: its name and text, then its content."""
    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as e:
        return [f"not YAML: {e}"]
    return check_doc(path.name, doc, cat, path.read_text())


def check_doc(name: str, doc: object, cat: dict | None = None, text: str | None = None) -> list[str]:
    """Problems in a result document; name is the file name it will be written under; text is scanned for internal names."""
    cat = cat or catalog()
    cases_by_id = case_index(cat)
    out: list[str] = []
    if isinstance(doc, dict) and isinstance(doc.get("environment"), dict) and hasattr(doc["environment"].get("date"), "isoformat"):
        doc["environment"]["date"] = doc["environment"]["date"].isoformat()   # an unquoted 2026-10-26 is a YAML date
    m = NAME_RE.match(name)
    if not m:
        return [f"file name must be <engine>-<mechanism>-<setup>-<yyyy-mm-dd>[-<n>].yaml: {name}"]
    if not isinstance(doc, dict) or set(doc) != {"environment", "cases"}:
        return ["top level must be exactly environment and cases"]
    env = doc["environment"]
    if not isinstance(env, dict):
        return ["environment must be a mapping"]
    if env.keys() - ENV_KEYS:
        out.append(f"environment has unknown keys {sorted(env.keys() - ENV_KEYS)}")
    for k in ("engine", "product", "version", "mechanism", "setup", "source_setup", "pipeline_mode", "compute",
              "workspace", "date", "method"):
        if k not in env or env[k] in (None, ""):
            out.append(f"environment.{k} is required")
    if env.get("engine") not in ENGINES:
        out.append(f"environment.engine must be one of {sorted(ENGINES)}")
    if env.get("mechanism") not in MECHANISMS:
        out.append(f"environment.mechanism must be one of {sorted(MECHANISMS)}")
    if env.get("setup") not in SETUPS:
        out.append(f"environment.setup must be one of {sorted(SETUPS)}")
    if env.get("pipeline_mode") not in PIPELINE_MODES:
        out.append(f"environment.pipeline_mode must be one of {sorted(PIPELINE_MODES)}")
    if env.get("compute") not in COMPUTE:
        out.append(f"environment.compute must be one of {sorted(COMPUTE)}")
    if env.get("method") not in METHODS:
        out.append(f"environment.method must be one of {sorted(METHODS)}")
    if not isinstance(env.get("workspace"), dict) or not {"cloud", "region"} <= set(env["workspace"]):
        out.append("environment.workspace needs cloud and region")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(env.get("date", ""))):
        out.append("environment.date must be YYYY-MM-DD")
    rt = env.get("runtime")
    if rt is not None and (not isinstance(rt, dict) or rt.keys() - {"dbr", "channel", "image"}):
        out.append("environment.runtime must be a mapping of dbr, channel, image (null when not recorded)")
    # the name matches the environment
    want = {"engine": m["engine"], "mechanism": m["mech"], "setup": m["setup"], "date": m["date"]}
    for k, v in want.items():
        if env.get(k) != v:
            out.append(f"file name says {k}={v}, environment says {env.get(k)}")
    cases = doc["cases"]
    if not isinstance(cases, list) or not cases:
        return out + ["cases must be a non-empty list"]
    seen: set[str] = set()
    for i, c in enumerate(cases):
        where = f"cases[{i}] ({c.get('id') if isinstance(c, dict) else '?'})"
        if not isinstance(c, dict):
            out.append(f"{where}: not a mapping")
            continue
        if c.keys() - CASE_KEYS or CASE_KEYS - c.keys():
            out.append(f"{where}: keys must be exactly {sorted(CASE_KEYS)}; extra {sorted(c.keys() - CASE_KEYS)}, "
                       f"missing {sorted(CASE_KEYS - c.keys())}")
        cid = c.get("id")
        if cid in seen:
            out.append(f"{where}: duplicate id")
        seen.add(cid)
        spec = cases_by_id.get(cid)
        if spec is None:
            out.append(f"{where}: not in ddl-cases.yaml")
        elif m["mech"] not in spec.get("applies", {}).get(m["engine"], []) and c.get("outcome") != "not-run":
            out.append(f"{where}: case does not apply to {m['engine']} {m['mech']} in ddl-cases.yaml")
        o = c.get("outcome")
        if o not in OUTCOMES:
            out.append(f"{where}: outcome must be one of {sorted(OUTCOMES)}")
        if c.get("basis") not in BASIS and not (o == "not-run" and c.get("basis") is None):
            out.append(f"{where}: basis must be one of {sorted(BASIS)} (null for a case not run)")
        frn = c.get("full_refresh_needed")
        if frn is not None and not isinstance(frn, bool):
            out.append(f"{where}: full_refresh_needed is true, false or null")
        if o == "restart-no-full-refresh" and frn is not False:
            out.append(f"{where}: a restart needs no full refresh (full_refresh_needed false)")
        if o == "table-stops-full-refresh" and frn is not True:
            out.append(f"{where}: a stopped table needs a full refresh (full_refresh_needed true)")
        sa = c.get("source_accepted")
        if sa is not None and sa is not True and not (isinstance(sa, str) and sa):
            out.append(f"{where}: source_accepted is true, the refusal text, or null (not recorded)")
        plr = c.get("post_change_row_landed")
        if plr not in (True, False, "unverified", None):
            out.append(f"{where}: post_change_row_landed is true, false, \"unverified\" or null")
        if spec is not None and spec.get("post") is None and plr is not None:
            out.append(f"{where}: the case has no post-change insert, so post_change_row_landed is null")
        if o == "not-run" and plr not in (None, "unverified"):
            out.append(f"{where}: a case not run can't have a landed row")
        stop_like = o in ("table-stops-full-refresh", "pipeline-fails", "not-applicable")
        evidence = any(isinstance(e, dict) and e.get("class") for e in (c.get("events") if isinstance(c.get("events"), list) else [])) or \
            (o == "not-applicable" and isinstance(c.get("source_accepted"), str))
        if stop_like and evidence and plr == "unverified":
            out.append(f"{where}: a stop or refusal with its error class or refusal seen is a row not landed (false), not unverified")
        if c.get("basis") == "confounded" and plr not in ("unverified", None):
            out.append(f"{where}: a confounded case's row is unverified")
        evs = c.get("events")
        if not isinstance(evs, list):
            out.append(f"{where}: events must be a list (empty when none)")
        else:
            for e in evs:
                if not isinstance(e, dict) or set(e) != {"class", "level", "message"}:
                    out.append(f"{where}: each event has class, level, message")
                    continue
                if e["class"] is not None and not isinstance(e["class"], str):
                    out.append(f"{where}: event class is a string or null")
                if e["level"] not in LEVELS:
                    out.append(f"{where}: event level must be one of {sorted(LEVELS)}")
                if not isinstance(e["message"], str):
                    out.append(f"{where}: event message is text")
        for k in ("column_before", "column_after", "destination_type_after", "value_check", "ddl", "notes"):
            if c.get(k) is not None and not isinstance(c.get(k), str):
                out.append(f"{where}: {k} is text or null")
        if c.get("auto_full_refresh_applies") not in (True, False, None):
            out.append(f"{where}: auto_full_refresh_applies is true, false or null")
    text = text if text is not None else yaml.safe_dump(doc, allow_unicode=True)
    version = str(env.get("version", "")) if isinstance(env, dict) else ""
    if version:   # the server's version string is recorded verbatim; it is a four-part number, not an address
        text = text.replace(version, "")
    for hit in sorted({h.group(0) for h in FORBIDDEN.finditer(text)}):
        out.append(f"address, identifier or path in the file: {hit!r}")
    guard = os.environ.get("PUBLIC_REPO_GUARD")
    if guard:
        r = subprocess.run([guard, "--scan"], input=text, capture_output=True, text=True)
        out += [line for line in r.stderr.splitlines()[1:] if line.strip()] if r.returncode else []
    return out


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.split("\n\n")[0])
        return 2
    cat = catalog()
    bad = 0
    for f in argv:
        probs = problems(Path(f), cat)
        if probs:
            bad += 1
            for p in probs:
                print(f"{f}: {p}")
        else:
            print(f"ok {f}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
