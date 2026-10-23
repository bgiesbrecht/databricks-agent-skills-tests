#!/usr/bin/env python3
"""Many sources' canonical schemas (statschema's schema.yaml, one per source database) -> the one silver is built from.

usage: schema-union.py <source1.yaml> [<source2.yaml> ...] [--current schema.yaml --changed-dir DIR] > union.yaml

A table is in the union when any source has it; a column too (in the first source's order, then the others' new ones).
A column's type is the widest the sources have: integer < long < decimal (the most integer digits and the most scale
any source has) < string; types that don't widen into each other (a date and a number) become string. Its default
is the first one given; not_null only when every source that has the column says so. The primary key must be the
same in every source that has the table (exit 1 if not: the tables aren't identical, so they can't merge).

--current and --changed-dir: compare the union with the schema silver is built from now, and write each table that
changed to DIR/<table>.yaml (one table per file, statschema's format), for silver-from-schema.py's
_schema/tables/: an evolution of only those tables. Prints the changed tables on stderr, one per line.
"""
import argparse
import os
import sys

import yaml

RANK = {"integer": 0, "long": 1, "decimal": 2}


def widen(a, b):
    """Two column definitions of one column -> the type that holds both."""
    ta, tb = a["type"], b["type"]
    if ta == tb and ta != "decimal":
        out = {k: v for k, v in a.items() if k != "length"}
        if a.get("length") and b.get("length"):   # a length only when both have one (none is unbounded)
            out["length"] = max(a["length"], b["length"])
        return out
    if ta in RANK and tb in RANK:
        if "decimal" not in (ta, tb):
            return dict(a, type="long")
        # integers as decimal(10,0) / (19,0)
        def ds(c):
            if c["type"] == "decimal":
                p, s = int(c.get("precision") or 38), int(c.get("scale") or 0)
                return p - s, s
            return (10, 0) if c["type"] == "integer" else (19, 0)
        (ia, sa), (ib, sb) = ds(a), ds(b)
        i, s = max(ia, ib), max(sa, sb)
        return dict(a, type="decimal", precision=min(i + s, 38), scale=s)
    if {ta, tb} <= {"string", "char"}:
        return dict({k: v for k, v in a.items() if k != "length"}, type="string")
    return dict({k: v for k, v in a.items() if k not in ("length", "precision", "scale")}, type="string")


def union(schemas):
    tables, order = {}, []
    for s in schemas:
        for t in s["tables"]:
            n = t["name"]
            if n not in tables:
                tables[n] = {"name": n, "columns": [dict(c) for c in t["columns"]]}
                order.append(n)
                continue
            u = tables[n]
            pk_u = [c["name"] for c in u["columns"] if c.get("primary_key")]
            pk_t = [c["name"] for c in t["columns"] if c.get("primary_key")]
            if pk_u != pk_t:
                sys.exit(f"table {n}: primary key {pk_u} in one source, {pk_t} in another: not identical tables")
            by = {c["name"]: i for i, c in enumerate(u["columns"])}
            seen = set()
            for c in t["columns"]:
                seen.add(c["name"])
                if c["name"] in by:
                    i = by[c["name"]]
                    w = widen(u["columns"][i], c)
                    w["not_null"] = bool(u["columns"][i].get("not_null") and c.get("not_null"))
                    if not w["not_null"]:
                        w.pop("not_null")
                    w.pop("native_type", None)
                    u["columns"][i] = w
                else:
                    u["columns"].append({k: v for k, v in c.items() if k != "not_null"})
            for c in u["columns"]:   # in an earlier source only: nullable here
                if c["name"] not in seen:
                    c.pop("not_null", None)
    return [tables[n] for n in order]


def same(a, b):
    def key(t):
        return [{k: v for k, v in c.items() if k != "native_type"} for c in t["columns"]]
    return key(a) == key(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sources", nargs="+")
    ap.add_argument("--current")
    ap.add_argument("--changed-dir")
    a = ap.parse_args()
    out = union([yaml.safe_load(open(f)) for f in a.sources])
    doc = {"version": "1.0", "tables": out}
    print(f"# statschema canonical schema (lfc-source-statschema): the union of {len(a.sources)} sources' schemas")
    yaml.safe_dump(doc, sys.stdout, sort_keys=False, width=10**9)
    if a.current:
        cur = {t["name"]: t for t in yaml.safe_load(open(a.current))["tables"]}
        os.makedirs(a.changed_dir, exist_ok=True)
        for t in out:
            if t["name"] not in cur or not same(t, cur[t["name"]]):
                with open(os.path.join(a.changed_dir, f"{t['name']}.yaml"), "w") as f:
                    yaml.safe_dump({"version": "1.0", "tables": [t]}, f, sort_keys=False, width=10**9)
                print(t["name"], file=sys.stderr)


if __name__ == "__main__":
    main()
