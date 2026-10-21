#!/usr/bin/env python3
"""The schema read through the UC connection -> statschema's canonical schema.yaml (lfc-source-statschema).

usage: schema-tsv-to-canonical.py <schema.tsv> <source description> > schema.yaml

  schema.tsv  table, ordinal, column, Databricks type, 1 when in the primary key, and the column's default (a literal,
              or empty), from debezium-zerobus.sh's fetch_schema

Writes statschema's format (version, tables, columns with a canonical type, not_null is not known here, primary_key,
default), plus a comment saying where it came from. The silver views are built from exactly these columns and types.
"""
import re
import sys

CANON = {"INT": "integer", "SMALLINT": "integer", "BIGINT": "long", "FLOAT": "float", "DOUBLE": "double",
         "BOOLEAN": "boolean", "DATE": "date", "TIMESTAMP_NTZ": "timestamp", "TIMESTAMP": "timestamptz",
         "BINARY": "binary", "STRING": "string"}


def q(v):
    return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    tsv, source = sys.argv[1], sys.argv[2]
    tables = {}
    for line in open(tsv):
        f = line.rstrip("\n").split("\t")
        if len(f) < 5:
            continue
        t, _, col, ty, pk = f[:5]
        default = f[5] if len(f) > 5 else ""
        c = {"name": col}
        m = re.match(r"DECIMAL\((\d+),(\d+)\)", ty)
        if m:
            c.update(type="decimal", precision=int(m.group(1)), scale=int(m.group(2)))
        else:
            c["type"] = CANON.get(ty, "string")
        c["native_type"] = ty
        if pk == "1":
            c["primary_key"] = True
        if default:
            c["default"] = default
        tables.setdefault(t, []).append(c)
    print(f"# statschema canonical schema (lfc-source-statschema), from {source}")
    print("# The silver views in this run are built from exactly these tables, columns and types.")
    print('version: "1.0"')
    print("tables:")
    for t, cols in tables.items():
        print(f"  - name: {t}")
        print("    columns:")
        for c in cols:
            print(f"      - name: {c['name']}")
            print(f"        type: {c['type']}")
            for k in ("precision", "scale"):
                if k in c:
                    print(f"        {k}: {c[k]}")
            print(f"        native_type: {q(c['native_type'])}")
            if c.get("primary_key"):
                print("        primary_key: true")
            if "default" in c:
                print(f"        default: {q(c['default'])}")


if __name__ == "__main__":
    main()
