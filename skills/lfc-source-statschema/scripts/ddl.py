#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pyyaml", "sqlglot"]
# ///
# uv run ddl.py schema.yaml --dialect postgres > schema.sql
# A statschema schema.yaml (canonical, from shape.py or any source) -> DDL for any dialect sqlglot knows (postgres, mysql,
# tsql, oracle, databricks, snowflake, bigquery, duckdb, ...): CREATE TABLE with types, NOT NULL, defaults, identity,
# primary and unique keys, checks; comments (the lfc tags: table comment from lfc_tags, column comments); foreign keys and indexes
# after every table exists; on Postgres, REPLICA IDENTITY FULL for a table without a primary key (CDC needs it); on MySQL,
# tags longer than a comment holds go to lfc_seed.tags, which the MySQL planners read with the comments.
# Each statement is a sqlglot syntax tree rendered for the dialect, so quoting, type names, and comment syntax follow it.
# The lfc formulas in the comments are written in MySQL syntax and transpiled the same way (DIV stays integer division).
# lfc-source-datagen fills Postgres and MySQL; other dialects get the DDL.
import argparse, re
import sqlglot, yaml
from sqlglot import exp

ap = argparse.ArgumentParser(); ap.add_argument("schema"); ap.add_argument("--dialect", required=True)
ap.add_argument("--source-dialect", help="keep native_type when the target is the dialect the schema was collected from")
a = ap.parse_args()
D = {"postgresql": "postgres", "sqlserver": "tsql", "mssql": "tsql"}.get(a.dialect, a.dialect)
SRC = {"postgresql": "postgres", "sqlserver": "tsql", "mssql": "tsql"}.get(a.source_dialect, a.source_dialect)
tables = yaml.safe_load(open(a.schema))["tables"]

CANON = {"integer": "INT", "int": "INT", "smallint": "SMALLINT", "tinyint": "SMALLINT", "long": "BIGINT", "bigint": "BIGINT",
         "float": "REAL", "double": "DOUBLE", "boolean": "BOOLEAN", "date": "DATE", "timestamp": "TIMESTAMP",
         "timestamptz": "TIMESTAMPTZ", "time": "TIME", "timetz": "TIMETZ"}
def dtype(c):
    if c.get("native_type") and SRC == D: return exp.DataType.build(c["native_type"], dialect=D)
    t, n = str(c.get("type", "string")).lower(), c.get("length")
    if t in ("decimal", "numeric", "number"):
        return exp.DataType.build(f"DECIMAL({c['precision']}, {c.get('scale') or 0})" if c.get("precision") else "DECIMAL(38, 10)")
    if t == "char": return exp.DataType.build(f"CHAR({n or 1})")
    if t in ("string", "varchar", "text"): return exp.DataType.build(f"VARCHAR({n})" if n else "TEXT")
    if t in ("binary", "varbinary", "blob"): return exp.DataType.build(f"VARBINARY({n})" if n else "BLOB")
    if c.get("unsigned") and t in ("integer", "int"): return exp.DataType.build("BIGINT")
    return exp.DataType.build(CANON.get(t, "TEXT"))

def ident(s): return exp.to_identifier(s, quoted=D != "oracle")
def table(s): return exp.Table(this=ident(s))
EPOCH = {"postgres": "CAST(EXTRACT(EPOCH FROM {}) AS BIGINT)", "mysql": "TIMESTAMPDIFF(SECOND, '1970-01-01 00:00:00', {})"}
DAYS = {"postgres": "({} - DATE '1970-01-01')", "mysql": "DATEDIFF({}, '1970-01-01')"}
def formula(e):                               # an lfc formula (MySQL syntax) in the target dialect
    if D != "mysql":
        e = sqlglot.parse_one(e, read="mysql").transform(lambda n: exp.cast(n, "bigint") if isinstance(n, exp.IntDiv) else n)
        e = e.sql(D, identify=True).replace(exp.column("n", "x", quoted=True).sql(D), "x.n")   # quoted names (mixed case); x.n as is
    # LFC_EPOCH(ts) / LFC_DAYS(date): seconds / days since 1970, which no transpiler maps the same on every engine
    e = re.sub(r"LFC_DAYS\(([^()]+)\)", lambda m: DAYS.get(D, "DATEDIFF({}, '1970-01-01')").format(m.group(1)), e, flags=re.I)
    return re.sub(r"LFC_EPOCH\(([^()]+)\)", lambda m: EPOCH.get(D, "EXTRACT(EPOCH FROM {})").format(m.group(1)), e, flags=re.I)
def tags(s): return re.sub(r"\{([^}]*)\}", lambda m: "{" + (m.group(1) if re.fullmatch(r"\w*", m.group(1)) else formula(m.group(1))) + "}", s or "")
INLINE = D in ("mysql", "databricks", "spark", "bigquery", "snowflake")   # comments inside CREATE TABLE
ON = D in ("postgres", "oracle", "duckdb")                                 # COMMENT ON statements

creates, comments, after = [], [], []
side = []                                     # MySQL: tags longer than a comment holds go to lfc_seed.tags (the planners read both)
def fit(tbl, col, text, limit):
    if D != "mysql" or len(text) <= limit: return text
    side.append(f"REPLACE INTO lfc_seed.tags VALUES (DATABASE(), {exp.Literal.string(tbl).sql(D)}, {exp.Literal.string(col).sql(D)}, {exp.Literal.string(text).sql(D)})")
    keep = " ".join(x for x in text.split() if x.startswith("lfc:rows="))
    return (keep + " lfc:ref").strip()
for t in tables:
    defs = []
    for c in t["columns"]:
        cons = []
        if c.get("auto_increment"): cons.append(exp.ColumnConstraint(kind=exp.GeneratedAsIdentityColumnConstraint(this=False)))
        if c.get("not_null") or c.get("primary_key"): cons.append(exp.ColumnConstraint(kind=exp.NotNullColumnConstraint()))
        if c.get("default") is not None: cons.append(exp.ColumnConstraint(kind=exp.DefaultColumnConstraint(this=sqlglot.parse_one(str(c["default"])))))
        if c.get("unique") and not c.get("primary_key"): cons.append(exp.ColumnConstraint(kind=exp.UniqueColumnConstraint()))
        com = fit(t["name"], c["name"], tags(c.get("comment")), 1000)
        if com and INLINE: cons.append(exp.ColumnConstraint(kind=exp.CommentColumnConstraint(this=exp.Literal.string(com))))
        if com and ON: comments.append(exp.Comment(this=exp.Column(this=ident(c["name"]), table=ident(t["name"])), kind="COLUMN", expression=exp.Literal.string(com)))
        defs.append(exp.ColumnDef(this=ident(c["name"]), kind=dtype(c), constraints=cons))
    pk = [c["name"] for c in t["columns"] if c.get("primary_key")]
    if pk: defs.append(exp.PrimaryKey(expressions=[ident(k) for k in pk]))
    for ck in t.get("checks") or []:              # CHECK constraints (MySQL syntax in the file, like the formulas)
        defs.append(exp.CheckColumnConstraint(this=sqlglot.parse_one(ck, read="mysql")))
    tc = fit(t["name"], "", tags(t.get("lfc_tags")), 2000)
    props = exp.Properties(expressions=[exp.SchemaCommentProperty(this=exp.Literal.string(tc))]) if tc and INLINE else None
    creates.append(exp.Create(this=exp.Schema(this=table(t["name"]), expressions=defs), kind="TABLE", properties=props))
    if tc and ON: comments.append(exp.Comment(this=table(t["name"]), kind="TABLE", expression=exp.Literal.string(tc)))
    if tc and not INLINE and not ON: comments.append(f"-- {t['name']}: {tc}")
    if D == "postgres" and not pk: after.append(f"ALTER TABLE {table(t['name']).sql(D)} REPLICA IDENTITY FULL")
    for i in t.get("lfc_indexes") or []:
        after.append(exp.Create(this=exp.Index(this=ident(i["name"]), table=table(t["name"]),
                                               params=exp.IndexParameters(columns=[exp.Ordered(this=ident(x)) for x in i["columns"]])),
                                kind="INDEX", unique=bool(i.get("unique"))))
    for f in t.get("fk_constraints") or []:
        pairs = list(zip(f["columns"], f["parent_columns"]))
        ppk = [c["name"] for c in next(x for x in tables if x["name"] == f["parent_table"])["columns"] if c.get("primary_key")]
        if set(f["parent_columns"]) == set(ppk): pairs.sort(key=lambda p: ppk.index(p[1]))   # MySQL: the parent key's order
        fk = exp.ForeignKey(expressions=[ident(c) for c, _ in pairs],
                            reference=exp.Reference(this=exp.Schema(this=table(f["parent_table"]), expressions=[ident(p) for _, p in pairs])))
        after.append(exp.Alter(this=table(t["name"]), kind="TABLE", actions=[exp.AddConstraint(expressions=[fk])]))

if side: after = ["CREATE DATABASE IF NOT EXISTS lfc_seed", "CREATE TABLE IF NOT EXISTS lfc_seed.tags (db VARCHAR(64), tbl VARCHAR(64), "
                  "col VARCHAR(64), tag MEDIUMTEXT, PRIMARY KEY (db, tbl, col))"] + side + after
for s in creates + comments + after:
    if isinstance(s, str): print(s if s.startswith("--") else s + ";")
    else: print(s.sql(D, pretty=isinstance(s, exp.Create) and s.kind == "TABLE") + ";")
