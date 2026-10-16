# uv run --no-project --with pyyaml --with sqlglot python3 to-canonical.py raw.json schema.yaml stats.yaml
# A collector's output (collect-postgres.sql, or collect-mysql.sql through mysql-normalize.jq) -> statschema's canonical schema.yaml and stats.yaml, the format every other step reads and writes.
# Types become statschema's canonical types (integer, long, decimal, string, date, ...), with the source's own type kept as
# native_type. Most-common-value frequencies become fractions of the non-null rows (statschema's convention; Postgres and
# MySQL store fractions of all rows). Hidden values (values=none) stay null, and the file says which values it holds.
import json, sys
import sqlglot, yaml
from sqlglot import exp

raw = json.load(open(sys.argv[1]))
src = raw["source_dialect"]
T = exp.DataType.Type
CANON = {T.TINYINT: "integer", T.SMALLINT: "integer", T.MEDIUMINT: "integer", T.INT: "integer", T.UTINYINT: "integer",
         T.USMALLINT: "integer", T.UMEDIUMINT: "integer", T.UINT: "integer", T.BIGINT: "long", T.UBIGINT: "long",
         T.FLOAT: "float", T.DOUBLE: "double", T.DECIMAL: "decimal", T.MONEY: "decimal", T.BOOLEAN: "boolean",
         T.DATE: "date", T.DATETIME: "timestamp", T.TIMESTAMP: "timestamp", T.TIMESTAMPTZ: "timestamptz",
         T.TIME: "time", T.TIMETZ: "timetz", T.BINARY: "binary", T.VARBINARY: "binary", T.BLOB: "binary",
         T.MEDIUMBLOB: "binary", T.LONGBLOB: "binary", T.TINYBLOB: "binary"}

def canon(native):
    d = exp.DataType.build(native, dialect=src)
    args = [int(e.name) for e in d.expressions if e.name.isdigit()]
    c = {"type": CANON.get(d.this, "string")}                  # text, char, json, uuid, enum, ... are strings
    if d.this.name.startswith("U"): c["unsigned"] = True
    if c["type"] == "decimal" and args: c["precision"], c["scale"] = args[0], (args[1] if len(args) > 1 else 0)
    if c["type"] in ("string", "binary") and args and d.this.name in ("CHAR", "VARCHAR", "NCHAR", "NVARCHAR", "BINARY", "VARBINARY"):
        c["length"] = args[0]
    if src == "mysql" and native.lower().startswith("tinyint(1)"): c = {"type": "boolean"}
    return c

schema, stats = [], []
for t in raw["tables"]:
    pk, rows = t.get("primary_key") or [], int(t.get("row_count") or 0)
    uniq = {u[0] for u in (t.get("unique") or []) if len(u) == 1}
    cols, cstats = [], []
    for c in t["columns"]:
        col = {"name": c["name"], **canon(c["data_type"]), "not_null": not c.get("nullable", True), "native_type": c["data_type"]}
        if c["name"] in pk: col["primary_key"] = True
        if c["name"] in uniq: col["unique"] = True
        cols.append(col)
        nf = c.get("null_fraction") or 0.0
        s = {"name": c["name"], "null_fraction": nf, "n_distinct": c.get("n_distinct") or 0.0}
        for k in ("avg_width_bytes", "min_value", "max_value", "correlation", "histogram_bounds"):
            if c.get(k) is not None: s[k] = c[k]
        if c.get("most_common_values"):
            s["most_common_values"] = [{"value": m.get("value"), "frequency": round(m["frequency"] / max(1 - nf, 1e-9), 6)}
                                       for m in c["most_common_values"]]
        cstats.append(s)
    tbl = {"name": t["name"], "row_count": rows, "columns": cols}
    if t.get("comment"): tbl["description"] = t["comment"]
    fks = t.get("foreign_keys") or []
    if fks:
        tbl["fk_constraints"] = [{"columns": f["columns"], "parent_table": f["ref_table"], "parent_columns": f["ref_columns"],
                                  "fk_distribution": "uniform"} for f in fks]
        tbl["load_after"] = sorted({f["ref_table"] for f in fks if f["ref_table"] != t["name"]})
    schema.append(tbl)
    by = {s["name"]: s for s in cstats}
    ts = {"name": t["name"], "row_count": rows, "columns": cstats}
    if t.get("size_bytes"): ts["data_size_bytes"] = t["size_bytes"]
    ix = [{"name": f"{t['name']}_ix{i + 1}", "columns": cs, "unique": False} for i, cs in enumerate(t.get("indexes") or [])]
    ix += [{"name": f"{t['name']}_uq{i + 1}", "columns": cs, "unique": True} for i, cs in enumerate(t.get("unique") or [])]
    if ix: ts["indexes"] = ix
    if fks:                                                     # children per parent, from the FK column's distinct count
        ts["foreign_keys"] = []
        for f in fks:
            nd = (by.get(f["columns"][0]) or {}).get("n_distinct") or 0
            nd = -nd * rows if nd < 0 else nd
            ts["foreign_keys"].append({"columns": f["columns"], "parent_table": f["ref_table"], "parent_columns": f["ref_columns"],
                                       **({"avg_children_per_parent": round(rows / nd, 3)} if nd else {})})
    stats.append(ts)

yaml.safe_dump({"version": "1.0", "tables": schema}, open(sys.argv[2], "w"), sort_keys=False, allow_unicode=True)
yaml.safe_dump({"version": "1.0", "source_dialect": src, "values": raw.get("values", "none"), "tables": stats},
               open(sys.argv[3], "w"), sort_keys=False, allow_unicode=True)
print(f"{len(schema)} tables -> {sys.argv[2]}, {sys.argv[3]}", file=sys.stderr)
