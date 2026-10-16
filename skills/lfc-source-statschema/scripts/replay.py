#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pyyaml", "sqlglot"]
# ///
# Replay the source's top queries on the copy (plans only: EXPLAIN never runs a query) and compare the plans.
#   replay.py yaml    queries.json > queries.yaml        statschema's queries.yaml (tables found by parsing, not regex)
#   replay.py explain queries.json --dialect postgres|mysql [--schema shaped.yaml] > explain.sql
#       one script that plans every query on the copy: Postgres plans them as generic plans (no values needed); MySQL
#       can't plan a placeholder, so each one becomes @lfc_pN, set from the column it is compared with
#   replay.py compare queries.json plans.json [--scale 0.01] [--dialect mysql]   (MySQL: the output of mysql --force -N -B)
#       per query: whether it planned, and how the copy's plan differs from the source's: the access to each table (full
#       scan or index), the join methods, and the estimated rows against the source's at the copy's scale
# queries.json comes from collect-queries-postgres.sql (with source plans) or collect-queries-mysql.sql. sqlglot parses
# and transpiles each query, so a Postgres workload replays on MySQL and the other way.
import argparse, json, re, sys
import sqlglot, yaml
from sqlglot import exp

ap = argparse.ArgumentParser(); ap.add_argument("cmd", choices=["yaml", "explain", "compare"]); ap.add_argument("queries")
ap.add_argument("plans", nargs="?"); ap.add_argument("--dialect", default="postgres"); ap.add_argument("--schema")
ap.add_argument("--scale", type=float, default=1.0)
a = ap.parse_args()
W = json.load(open(a.queries)); SRC = W["source_dialect"]; D = a.dialect

def parse(q):                                   # Postgres' typed placeholders (date $1) aren't parseable: CAST($1 AS date)
    if SRC == "postgres": q = re.sub(r"\b(date|timestamp|time|interval)\s+(\$\d+)", r"CAST(\2 AS \1)", q, flags=re.I)
    return sqlglot.parse_one(q, read=SRC)
def tables(t): return sorted({x.name for x in t.find_all(exp.Table) if x.name})

if a.cmd == "yaml":                             # statschema's QueryWorkload format
    out = [{"id": str(q["id"]), "source_dialect": SRC, "sql": q["sql"], "tables": tables(parse(q["sql"])), "calls": q.get("calls", 0),
            "total_elapsed_ms": q.get("total_elapsed_ms", 0.0), "mean_elapsed_ms": q.get("mean_elapsed_ms", 0.0),
            "rank_by": q.get("rank_by", "total_time")} for q in W["queries"]]
    yaml.safe_dump({"source_dialect": SRC, "queries": out}, sys.stdout, sort_keys=False, width=10**9); sys.exit()

if a.cmd == "explain":
    cols = {}                                   # column -> its table, to set a MySQL placeholder from the column
    if a.schema:
        for t in yaml.safe_load(open(a.schema))["tables"]:
            for c in t["columns"]: cols.setdefault(c["name"].lower(), t["name"])
    lit = lambda s: "'" + s.replace("'", "''") + "'"
    if D == "postgres":
        print("CREATE FUNCTION pg_temp.lfc_plan(q text) RETURNS json LANGUAGE plpgsql AS $f$ DECLARE p json; BEGIN\n"
              "  EXECUTE 'EXPLAIN (GENERIC_PLAN, FORMAT JSON) ' || q INTO p; RETURN p;\n"
              "EXCEPTION WHEN OTHERS THEN RETURN json_build_object('error', SQLERRM); END $f$;")
    rows = []
    for q in W["queries"]:
        try:
            t = parse(q["sql"])
        except sqlglot.errors.ParseError as err:
            rows.append((q["id"], None, str(err).splitlines()[0])); continue
        sets, n, seen = [], [0], set()
        def param(node):
            if not isinstance(node, (exp.Parameter, exp.Placeholder)): return node
            k = node.name if isinstance(node, exp.Parameter) and node.name.isdigit() else None
            if not k: n[0] += 1; k = str(n[0])               # MySQL's ? in order; Postgres keeps $k
            if D == "postgres": return exp.Parameter(this=exp.Var(this=k))              # $1, $2, ... for a generic plan
            if isinstance(node.parent, exp.Cast) and node.parent.to.this == exp.DataType.Type.INTERVAL: return node
            if node.find_ancestor(exp.Limit, exp.Offset): return exp.Literal.number(10)  # MySQL: LIMIT takes no variable
            var = f"@lfc_p{k}"
            if k not in seen:                                # the value: one from the column it is compared with
                seen.add(k); p = node.find_ancestor(exp.Predicate, exp.Between, exp.In, exp.Like)
                col = next((c for c in (p.find_all(exp.Column) if p is not None else []) if not isinstance(c.parent, exp.Dot)), None)
                tb = (col.table or cols.get(col.name.lower())) if col else None
                sets.append(f"SET {var} = " + (f"(SELECT `{col.name}` FROM `{tb}` LIMIT 1)" if tb else "1") + ";")
            return exp.Var(this=var)
        t = t.transform(param)
        if D != "postgres":                     # an interval placeholder (Postgres only): a fixed 30 days
            t = t.transform(lambda x: exp.Interval(this=exp.Literal.number(30), unit=exp.Var(this="DAY"))
                            if isinstance(x, exp.Cast) and x.to.this == exp.DataType.Type.INTERVAL else x)
        rows.append((q["id"], t.sql(D), sets))
    if D == "postgres":
        print("SELECT json_agg(json_build_object('id', id, 'sql', q, 'plan', CASE WHEN q IS NULL THEN json_build_object('error', e) "
              "ELSE pg_temp.lfc_plan(q) END)) FROM (VALUES " +
              ",\n  ".join(f"({lit(str(i))}, {lit(s) if s else 'NULL'}, {lit(x) if not s else 'NULL'})" for i, s, x in rows) + ") v(id, q, e);")
    else:                                       # mysql --force -N -B (not -r): a marker line, then the plan on one line
        for i, s, sets in rows:
            print(f"SELECT '#lfc {i}';")
            if s: print("\n".join(sets)); print(f"EXPLAIN FORMAT=JSON {s};")
    sys.exit()

# compare: a plan -> per-table access ("scan" or "index"), the join methods, the estimated rows
def pg_shape(p):
    acc, joins = {}, []
    def walk(n):
        nt = n.get("Node Type", "")
        if n.get("Relation Name"): acc[n["Relation Name"]] = "scan" if nt == "Seq Scan" else "index"
        if nt in ("Hash Join", "Merge Join", "Nested Loop"): joins.append(nt)
        for c in n.get("Plans", []): walk(c)
    root = p[0]["Plan"]; walk(root)
    return acc, sorted(joins), root.get("Plan Rows")
def my_shape(p):
    acc, joins, rows = {}, [], []
    def walk(n, first=[True]):
        if isinstance(n, dict):
            if "table_name" in n and "access_type" in n:
                acc[n["table_name"]] = "scan" if n["access_type"] == "ALL" else "index"
                rows.append(n.get("rows_produced_per_join") or n.get("rows_examined_per_scan") or 0)
                if "using_join_buffer" in n: joins.append("Hash Join" if "hash" in n["using_join_buffer"].lower() else "Nested Loop")
            for v in n.values(): walk(v)
        elif isinstance(n, list):
            for v in n: walk(v)
    walk(p)
    nl = len(acc) - 1 - len(joins)                # tables joined without a join buffer: nested loops
    return acc, sorted(joins + ["Nested Loop"] * max(nl, 0)), (rows[-1] if rows else None)
def shape(p, dialect):
    if not p or (isinstance(p, dict) and p.get("error")): return None
    return pg_shape(p) if dialect == "postgres" else my_shape(p)

src = {str(q["id"]): q for q in W["queries"]}
if D == "postgres": tgt = {str(r["id"]): r for r in json.load(open(a.plans)) or []}
else:                                            # the mysql output: marker lines, each followed by its plan (or nothing)
    tgt, cur = {}, None
    for line in open(a.plans):
        line = line.rstrip("\n")
        if line.startswith("#lfc "): cur = line[5:]; tgt[cur] = {"plan": None}
        elif cur and line.startswith("{"): tgt[cur]["plan"] = json.loads(line.replace("\\n", "\n"))
print(f"{'query':<12} {'copy':<8} {'source rows':>12} {'copy rows':>10}  differences")
ok = same = 0
for i, q in src.items():
    t = tgt.get(i, {}); ts = shape(t.get("plan"), D); ss = shape(q.get("plan"), SRC)
    text = re.sub(r"\s+", " ", q["sql"])[:60]
    if not ts:
        err = (t.get("plan") or {}).get("error", "no plan") if isinstance(t.get("plan"), dict) else "no plan"
        print(f"{i[:12]:<12} {'FAILED':<8} {'':>12} {'':>10}  {str(err)[:80]}  [{text}]"); continue
    ok += 1
    if not ss: print(f"{i[:12]:<12} {'planned':<8} {'-':>12} {ts[2] or '-':>10}  (no source plan)  [{text}]"); continue
    diff = [f"{tb}: {ss[0][tb]} -> {ts[0].get(tb, '?')}" for tb in ss[0] if ts[0].get(tb) != ss[0][tb]]
    if ss[1] != ts[1]: diff.append(f"joins {'+'.join(ss[1]) or '-'} -> {'+'.join(ts[1]) or '-'}")
    agg = parse(q["sql"]).find(exp.Group, exp.Limit, exp.AggFunc)     # groups and limits don't shrink with the data
    want = ss[2] * a.scale if ss[2] and not agg else None
    if want and ts[2] and not (want / 3 <= max(ts[2], 1) <= max(want, 1) * 3): diff.append(f"rows {ts[2]:.0f} vs {want:.0f} expected")
    same += not diff
    print(f"{i[:12]:<12} {'planned':<8} {ss[2] or '-':>12} {ts[2] or '-':>10}  {'; '.join(diff) or 'same plan'}  [{text}]")
print(f"{ok} of {len(src)} planned on the copy; {same} with the same plan shape as the source")
