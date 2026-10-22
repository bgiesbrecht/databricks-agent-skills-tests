#!/usr/bin/env python3
# mix-models.py: many tables from the TPC models, as one canonical schema.yaml (lfc-source-statschema's format), for
# tests of how many tables a pipeline takes. Copies of the models in order (tpcb, tpcc, tpch, tpcds, tpce, tpcdi: 95
# tables a copy), each table renamed <model><copy>_<table> (tpcc001_customer), until there are --tables of them: the
# last copy may stop partway. Foreign keys, references and load_after follow the renames; one whose parent didn't make
# the cut is dropped.
#
#   python3 mix-models.py --tables 1000 [--schemas <lfc-source-statschema>/schemas] [--models tpcb,tpcc,...] > mix.yaml
import argparse
import copy
import os
import sys

import yaml

ap = argparse.ArgumentParser()
ap.add_argument("--tables", type=int, required=True)
ap.add_argument("--models", default="tpcb,tpcc,tpch,tpcds,tpce,tpcdi")
ap.add_argument("--schemas", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                  "..", "..", "lfc-source-statschema", "schemas"))
a = ap.parse_args()
models = [(m, yaml.safe_load(open(os.path.join(a.schemas, f"{m}.yaml")))["tables"]) for m in a.models.split(",")]
per_copy = sum(len(t) for _, t in models)
copies = -(-a.tables // per_copy)
width = max(3, len(str(copies)))

out = []
for k in range(1, copies + 1):
    for m, tables in models:
        if len(out) >= a.tables:
            break
        take = tables[:a.tables - len(out)]
        name = {t["name"]: f"{m}{k:0{width}d}_{t['name']}" for t in take}
        for t in take:
            t = copy.deepcopy(t)
            t["name"] = name[t["name"]]
            fks = [dict(f, parent_table=name[f["parent_table"]], **({"name": f"{t['name']}_{f['name']}"} if f.get("name") else {}))
                   for f in t.get("fk_constraints") or [] if f["parent_table"] in name]
            if fks:
                t["fk_constraints"] = fks
            else:
                t.pop("fk_constraints", None)
            for c in t["columns"]:
                r = c.get("references")
                if r and r[0] in name:
                    c["references"] = [name[r[0]], r[1]]
                elif r:
                    del c["references"]
            la = [name[p] for p in t.get("load_after") or [] if p in name]
            if la:
                t["load_after"] = la
            else:
                t.pop("load_after", None)
            t.pop("temporal_ordering_constraints", None)   # rules for filling; renamed tables would need them renamed
            out.append(t)
print(f"-- {len(out)} tables: {copies} copies of {a.models} ({per_copy} a copy)", file=sys.stderr)
yaml.safe_dump({"version": "1.0", "tables": out}, sys.stdout, sort_keys=False, allow_unicode=True)
