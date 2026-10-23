# /// script
# dependencies = ["pyyaml"]
# ///
"""plan.py: what it takes to go from the plan silver was built from (current) to an edited one (desired).

    plan.py diff <current.yaml> <desired.yaml> [--schema schema.yaml] [--activity activity.yaml] [--json]

For each table whose silver changed, an action and whether it can be done without asking:
  add      a target the table didn't have (scd1 -> <table>, scd2 -> <table>_history): a new streaming table, which reads
           the snapshot and the change log from T on the next update (refreshed, so it's rebuilt the same way each time)
  rebuild  <table> changes kind (scd1 <-> append): a full refresh of that table alone, from the snapshot and the change
           log, which holds every event from T (it's never truncated in these tests: with a retention it couldn't be)
  drop     a target no longer wanted: the pipeline stops defining it and drops it; asks first (it can be undropped
           for a while, but its readers lose it now)
  refuse   what the pipeline can't build: scd1 or scd2 without a primary key, append together with scd1 or scd2
  warn     append for a table the activity shows updated or deleted: those changes would be left out
A table only in desired needs its producer to capture it first (refused here); one only in current is dropped.
Prints a table, or with --json {"refresh": [...], "drop": [...], "refuse": [...], "warn": [...], "auto": bool}: the
targets to full-refresh, and whether everything can go ahead without asking. Exit 0 auto, 1 needs asking, 2 refused.
"""
import argparse
import json
import sys

import yaml

HIST = "_history"


def load(p):
    with open(p) as f:
        return yaml.safe_load(f) or {}


def targets(table, silver):
    return {("scd1" if s == "scd1" else "append"): table for s in silver if s in ("scd1", "append")} | \
        ({"scd2": table + HIST} if "scd2" in silver else {})


def diff(cur, des, keyed, activity):
    acts = []
    ct, dt = cur.get("tables") or {}, des.get("tables") or {}
    for t in sorted(set(ct) | set(dt)):
        a, b = list((ct.get(t) or {}).get("silver") or []), list((dt.get(t) or {}).get("silver") or [])
        if t not in ct:
            acts.append(("refuse", t, "", f"{t} is new: its producer must capture it, and its snapshot be taken, first"))
            continue
        if sorted(a) == sorted(b):
            continue
        if not b or set(b) - {"scd1", "scd2", "append"} or "append" in b and len(b) > 1:
            acts.append(("refuse", t, "", f"silver {b}: scd1 and/or scd2, or append alone"))
            continue
        if keyed is not None and not keyed.get(t, True) and set(b) & {"scd1", "scd2"}:
            acts.append(("refuse", t, "", "no primary key: scd1 and scd2 need one; append only"))
            continue
        ta, tb = targets(t, a), targets(t, b)
        if ("scd1" in ta) != ("scd1" in tb) and ("append" in ta) != ("append" in tb) and t in dt:
            acts.append(("rebuild", t, t, f"{'+'.join(a)} -> {'+'.join(b)}: {t} changes kind, a full refresh of it alone"))
        else:
            for k in ("scd1", "append"):
                if k in tb and k not in ta:
                    acts.append(("add", t, tb[k], f"new {k} table {tb[k]}"))
                if k in ta and k not in tb and not (set(tb) & {"scd1", "append"}):
                    acts.append(("drop", t, ta[k], f"{ta[k]} is no longer wanted"))
        if "scd2" in tb and "scd2" not in ta:
            acts.append(("add", t, tb["scd2"], f"new history table {tb['scd2']}"))
        if "scd2" in ta and "scd2" not in tb:
            acts.append(("drop", t, ta["scd2"], f"{ta['scd2']} is no longer wanted: its history goes with it"))
        act = (activity or {}).get(t) or {}
        if "append" in b and (act.get("updates") or act.get("deletes")):
            acts.append(("warn", t, t, f"append, but the source had {act.get('updates', 0)} updates and "
                                       f"{act.get('deletes', 0)} deletes: silver would leave those out"))
    return acts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["diff"]); ap.add_argument("current"); ap.add_argument("desired")
    ap.add_argument("--schema"); ap.add_argument("--activity"); ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    keyed = None
    if a.schema:
        keyed = {t["name"]: any(c.get("primary_key") for c in t["columns"]) for t in load(a.schema)["tables"]}
    acts = diff(load(a.current), load(a.desired), keyed, load(a.activity) if a.activity else None)
    refuse = [x for x in acts if x[0] == "refuse"]
    ask = [x for x in acts if x[0] in ("drop", "warn")]
    if a.json:
        print(json.dumps({"refresh": sorted({x[2] for x in acts if x[0] in ("add", "rebuild")}),
                          "drop": [x[2] for x in acts if x[0] == "drop"], "refuse": [x[1] for x in refuse],
                          "warn": [x[1] for x in acts if x[0] == "warn"], "auto": not refuse and not ask,
                          "actions": [dict(zip(("action", "table", "target", "why"), x)) for x in acts]}))
    else:
        print("| Action | Table | Target | Why |\n|---|---|---|---|")
        for x in acts:
            print(f"| {x[0]} | `{x[1]}` | {'`' + x[2] + '`' if x[2] else ''} | {x[3]} |")
        if not acts:
            print("| none | | | the plans build the same silver |")
    sys.exit(2 if refuse else 1 if ask else 0)


if __name__ == "__main__":
    main()
