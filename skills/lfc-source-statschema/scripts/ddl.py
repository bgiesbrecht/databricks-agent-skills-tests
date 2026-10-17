#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pyyaml", "sqlglot"]
# ///
# uv run ddl.py schema.yaml --dialect postgres > schema.sql
# A statschema schema.yaml (canonical, from shape.py or any source) -> DDL for any dialect sqlglot knows (postgres, mysql,
# tsql, oracle, databricks, snowflake, bigquery, duckdb, ...): CREATE TABLE with types, NOT NULL, defaults, identity,
# primary and unique keys, checks; comments (the lfc tags: table comment from lfc_tags, column comments); foreign keys and indexes
# after every table exists; on Postgres, REPLICA IDENTITY FULL for a table without a primary key (CDC needs it); on MySQL,
# tags longer than a comment holds go to lfc_seed.tags, which the MySQL planners read with the comments; on SQL Server
# (lfc_seed.tags) and Oracle (lfc_tags in the schema) every tag goes to a side table, since a column comment there is an
# extended property or 4,000 bytes at most.
# Each statement is a sqlglot syntax tree rendered for the dialect, so quoting, type names, and comment syntax follow it.
# The lfc formulas in the comments are written in MySQL syntax and transpiled the same way (DIV stays integer division),
# with the rewrites sqlglot leaves out: T-SQL has no LPAD and its int arithmetic overflows, Oracle has no LEFT, PI, or
# CONCAT of more than two arguments.
# lfc-source-datagen fills Postgres, MySQL, SQL Server, and Oracle; other dialects get the DDL.
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
EPOCH.update({"tsql": "DATEDIFF_BIG(SECOND, '1970-01-01', {})", "oracle": "ROUND((CAST({} AS DATE) - DATE '1970-01-01') * 86400)"})
DAYS.update({"tsql": "DATEDIFF(DAY, '1970-01-01', {})", "oracle": "ROUND(CAST({} AS DATE) - DATE '1970-01-01')"})
INTS = ("integer", "int", "smallint", "tinyint", "long", "bigint")
def sql(e): return e if isinstance(e, str) else e.sql(D, identify=D != "oracle")
def node(text): return sqlglot.parse_one(text, read=D)          # a rewrite, written in the target dialect
def rewrite(n, ints):                                           # one node of a MySQL formula -> the target dialect
    if isinstance(n, exp.IntDiv):                               # DIV: integer division, truncated toward zero
        if D == "tsql": return node(f"CAST({sql(n.this)} AS BIGINT) / CAST({sql(n.expression)} AS BIGINT)")
        if D == "oracle": return node(f"TRUNC(({sql(n.this)}) / ({sql(n.expression)}))")
        return exp.cast(n, "bigint")
    if isinstance(n, exp.Anonymous) and n.name.upper() in ("LFC_DAYS", "LFC_EPOCH"):
        # seconds / days since 1970, which no transpiler maps the same on every engine
        f = (DAYS if n.name.upper() == "LFC_DAYS" else EPOCH).get(D, "DATEDIFF({}, '1970-01-01')" if n.name.upper() == "LFC_DAYS" else "EXTRACT(EPOCH FROM {})")
        return node(f.format(sql(n.expressions[0])))
    if D == "tsql":
        # CASE (CASE WHEN c1 THEN 0 WHEN c2 THEN 1 ... END) WHEN 0 THEN 'a' ...: SQL Server expands a simple CASE into one
        # comparison per WHEN, copying the inner CASE into each (150 values: error 8632, expression services limit), so
        # fold it into one searched CASE: WHEN c1 THEN 'a' WHEN c2 THEN 'b' ...
        inner = n.this.unnest() if isinstance(n, exp.Case) and n.this is not None else None
        if isinstance(inner, exp.Case) and inner.this is None and all(isinstance(i.args.get("true"), exp.Literal) for i in inner.args["ifs"]):
            out = {sql(i.this): i.args["true"] for i in n.args["ifs"]}
            pick = lambda v: (out.get(sql(v)) or n.args.get("default") or exp.null()).copy()
            d = inner.args.get("default")
            return exp.Case(ifs=[exp.If(this=i.this, true=pick(i.args["true"])) for i in inner.args["ifs"]],
                            default=pick(d) if d is not None else n.args.get("default"))
        if isinstance(n, exp.Round) and n.args.get("decimals") is None: n.set("decimals", exp.Literal.number(0))  # 2 arguments
        if isinstance(n, exp.Pow):                             # POWER returns its base's type: an int base truncates
            return node(f"POWER(CAST({sql(n.this)} AS FLOAT), {sql(n.expression)})")
        if isinstance(n, exp.Column) and n.name.lower() in ints:   # int * a large constant overflows int in T-SQL
            return node(f"CAST({sql(n)} AS BIGINT)")
        if isinstance(n, exp.Concat): return exp.Anonymous(this="CONCAT", expressions=n.expressions)   # not +, which adds numbers
        if isinstance(n, exp.Pad) and n.args.get("is_left"):   # LPAD: MySQL also cuts a longer string to the length
            s_, l_, p_ = sql(n.this), sql(n.expression), sql(n.args.get("fill_pattern") or exp.Literal.string(" "))
            return node(f"CASE WHEN LEN({s_}) >= {l_} THEN LEFT({s_}, {l_}) ELSE RIGHT(REPLICATE({p_}, {l_}) + {s_}, {l_}) END")
    if D == "oracle":
        if isinstance(n, exp.Left): return node(f"SUBSTR({sql(n.this)}, 1, {sql(n.expression)})")
        if isinstance(n, exp.Pi): return node("ACOS(-1)")
        if isinstance(n, exp.Concat) and len(n.expressions) != 2:
            return node("(" + " || ".join(sql(x) for x in n.expressions) + ")") if n.expressions else exp.Literal.string("")
    return n
def walk(n, ints):                                              # bottom up, so a rewrite sees its arguments already rewritten
    for k, v in list(n.args.items()):
        if isinstance(v, exp.Expression): n.set(k, walk(v, ints))
        elif isinstance(v, list): n.set(k, [walk(x, ints) if isinstance(x, exp.Expression) else x for x in v])
    return rewrite(n, ints)
def formula(e, ints=frozenset()):                               # an lfc formula (MySQL syntax) in the target dialect
    if D != "mysql":
        e = sql(walk(sqlglot.parse_one(e, read="mysql"), ints))
        e = e.replace(exp.column("n", "x", quoted=True).sql(D), "x.n")   # quoted names (mixed case); x.n as is
        return e
    e = re.sub(r"LFC_DAYS\(([^()]+)\)", lambda m: DAYS["mysql"].format(m.group(1)), e, flags=re.I)
    return re.sub(r"LFC_EPOCH\(([^()]+)\)", lambda m: EPOCH["mysql"].format(m.group(1)), e, flags=re.I)
def tags(s, t=None):
    ints = frozenset(c["name"].lower() for c in (t or {}).get("columns", []) if str(c.get("type", "")).lower() in INTS)
    return re.sub(r"\{([^}]*)\}", lambda m: "{" + (m.group(1) if re.fullmatch(r"\w*", m.group(1)) else formula(m.group(1), ints)) + "}", s or "")
INLINE = D in ("mysql", "databricks", "spark", "bigquery", "snowflake")   # comments inside CREATE TABLE
ON = D in ("postgres", "duckdb")                                           # COMMENT ON statements
SIDE = D in ("tsql", "oracle")                                             # every tag in a side table the planners read

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
        com = fit(t["name"], c["name"], tags(c.get("comment"), t), 1000)
        if com and SIDE: side.append((t["name"], c["name"], com))
        if com and INLINE: cons.append(exp.ColumnConstraint(kind=exp.CommentColumnConstraint(this=exp.Literal.string(com))))
        if com and ON: comments.append(exp.Comment(this=exp.Column(this=ident(c["name"]), table=ident(t["name"])), kind="COLUMN", expression=exp.Literal.string(com)))
        defs.append(exp.ColumnDef(this=ident(c["name"]), kind=dtype(c), constraints=cons))
    pk = [c["name"] for c in t["columns"] if c.get("primary_key")]
    if pk: defs.append(exp.PrimaryKey(expressions=[ident(k) for k in pk]))
    for ck in t.get("checks") or []:              # CHECK constraints (MySQL syntax in the file, like the formulas)
        defs.append(exp.CheckColumnConstraint(this=sqlglot.parse_one(ck, read="mysql")))
    tc = fit(t["name"], "", tags(t.get("lfc_tags"), t), 2000)
    if tc and SIDE: side.append((t["name"], "", tc))
    props = exp.Properties(expressions=[exp.SchemaCommentProperty(this=exp.Literal.string(tc))]) if tc and INLINE else None
    creates.append(exp.Create(this=exp.Schema(this=table(t["name"]), expressions=defs), kind="TABLE", properties=props))
    if tc and ON: comments.append(exp.Comment(this=table(t["name"]), kind="TABLE", expression=exp.Literal.string(tc)))
    if tc and not INLINE and not ON and not SIDE: comments.append(f"-- {t['name']}: {tc}")
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

def lit(text):                                 # a string literal; Oracle's hold 4,000 bytes and SQL*Plus reads lines of at most
    if D != "oracle" or len(text) <= 3000: return exp.Literal.string(text).sql(D)   # 4,999, so longer tags are CLOB pieces, a line each
    return " ||\n".join(f"TO_CLOB({exp.Literal.string(text[i:i + 3000]).sql(D)})" for i in range(0, len(text), 3000))
if side and D == "tsql":                      # lfc_seed.tags (schema, table, column or '', tags)
    after = ["IF SCHEMA_ID('lfc_seed') IS NULL EXEC('CREATE SCHEMA lfc_seed')",
             "IF OBJECT_ID('lfc_seed.tags') IS NULL CREATE TABLE lfc_seed.tags (sch SYSNAME NOT NULL, tbl SYSNAME NOT NULL, "
             "col SYSNAME NOT NULL, tag NVARCHAR(MAX), PRIMARY KEY (sch, tbl, col))"] + \
            [f"DELETE FROM lfc_seed.tags WHERE sch = SCHEMA_NAME() AND tbl = {lit(x)}" for x in dict.fromkeys(r[0] for r in side)] + \
            [f"INSERT INTO lfc_seed.tags VALUES (SCHEMA_NAME(), {lit(r[0])}, {lit(r[1])}, {lit(r[2])})" for r in side] + after
elif side and D == "oracle":                  # lfc_tags in the schema (table and column names as stored: upper case; '-' for the table)
    after = ["CREATE TABLE IF NOT EXISTS lfc_tags (tbl VARCHAR2(128) NOT NULL, col VARCHAR2(128) NOT NULL, tag CLOB, PRIMARY KEY (tbl, col))"] + \
            [f"DELETE FROM lfc_tags WHERE tbl = {lit(x.upper())}" for x in dict.fromkeys(r[0] for r in side)] + \
            [f"INSERT INTO lfc_tags VALUES ({lit(r[0].upper())}, {lit(r[1].upper() or '-')}, {lit(r[2])})" for r in side] + after + ["COMMIT"]
elif side: after = ["CREATE DATABASE IF NOT EXISTS lfc_seed", "CREATE TABLE IF NOT EXISTS lfc_seed.tags (db VARCHAR(64), tbl VARCHAR(64), "
                  "col VARCHAR(64), tag MEDIUMTEXT, PRIMARY KEY (db, tbl, col))"] + side + after
for s in creates + comments + after:
    if isinstance(s, str): print(s if s.startswith("--") else s + ";")
    else: print(s.sql(D, pretty=isinstance(s, exp.Create) and s.kind == "TABLE") + ";")
