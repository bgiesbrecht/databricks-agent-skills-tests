# Build, fill, and check the copy

`shape.py` turns a stats file (from either collector) into the target's DDL with **lfc-source-datagen** tags, and `compare.sql` checks the filled copy. Both run on the test side, never on the customer's database. `shape.py` needs only Python and sqlglot (`uv run --with sqlglot`); `compare.sql` needs DuckDB.

```bash
cat > shape.py <<'SS_EOF'
# uv run -q --with sqlglot python3 -I shape.py stats.json --target pg|my --scale 0.01 [--keep-small 1000] [--checks]
#   > shape.sql, and writes expected.json: the source's tables at a smaller scale, as DDL with lfc tags (lfc:rows, lfc:v,
#   lfc:len, lfc:n, lfc:by) that the datagen planners fill to the source's shape. Types and keys come from the stats file;
#   sqlglot maps types across engines and turns the formulas (written in MySQL syntax) into Postgres.
#   Rows: tables up to --keep-small rows keep their size, the rest are multiplied by --scale. A distinct count of at least
#   10% of the rows grows with the table (Postgres keeps these as a negative fraction), a smaller one stays (categories).
#   Values: null fraction and most-common-value frequencies are reproduced exactly (each a share of a permutation of the
#   rows); numeric and date values (min, max, most
#   common) when the stats file has them (values=ranges or all), otherwise only the counts; text values never, only how
#   many there are and how often each occurs. Foreign keys spread over the parent's keys, hot parents first if skewed.
import argparse, datetime, decimal, json, math, sys, zlib
import sqlglot
from sqlglot import exp

ap = argparse.ArgumentParser()
ap.add_argument("stats"); ap.add_argument("--target", choices=["pg", "my"], required=True)
ap.add_argument("--scale", type=float, default=0.01); ap.add_argument("--keep-small", type=int, default=1000)
ap.add_argument("--checks", action="store_true", help="copy CHECK constraints (cross-column ones may fail: not in the stats)")
ap.add_argument("--expected", default="expected.json")
a = ap.parse_args()
st = json.load(open(a.stats))
src, tgt = st["source_dialect"], {"pg": "postgres", "my": "mysql"}[a.target]
T = {t["name"]: t for t in st["tables"]}
R = {n: (int(t.get("row_count") or 0) if (t.get("row_count") or 0) <= a.keep_small else max(1, round(t["row_count"] * a.scale)))
     for n, t in T.items()}
log = lambda *m: print("--", *m, file=sys.stderr)

def primes(k, start=2147483647):            # large primes: coprime with 1,000,000 and with any distinct count, x.n * p fits 63 bits
    out, n = [], start
    while len(out) < k:
        if all(n % d for d in range(3, int(n ** 0.5) + 1, 2)): out.append(n)
        n -= 2
    return out
P = primes(64)
def K(*key): return P[zlib.crc32(":".join(key).encode()) % len(P)]

def dtype(c):                               # the column's type on the target, as a sqlglot DataType
    d = exp.DataType.build(c["data_type"], dialect=src)
    t = d.this
    if tgt == "mysql":
        if t in (exp.DataType.Type.TIMESTAMPTZ, exp.DataType.Type.TIMESTAMP): d = exp.DataType.build("DATETIME", dialect="mysql")
        elif t in (exp.DataType.Type.UUID,): d = exp.DataType.build("CHAR(36)", dialect="mysql")
        elif t in (exp.DataType.Type.JSONB, exp.DataType.Type.ARRAY): d = exp.DataType.build("JSON", dialect="mysql")
        elif t == exp.DataType.Type.INET: d = exp.DataType.build("VARCHAR(45)", dialect="mysql")
        elif t == exp.DataType.Type.VARBINARY and not d.expressions: d = exp.DataType.build("BLOB", dialect="mysql")
        elif t == exp.DataType.Type.DECIMAL and not d.expressions: d = exp.DataType.build("DECIMAL(38,10)", dialect="mysql")
    else:
        m = {"UTINYINT": "SMALLINT", "TINYINT": "SMALLINT", "USMALLINT": "INT", "MEDIUMINT": "INT", "UMEDIUMINT": "INT", "UINT": "BIGINT",
             "UBIGINT": "NUMERIC(20)", "YEAR": "SMALLINT", "ENUM": "TEXT", "SET": "TEXT"}.get(t.name)
        if m: d = exp.DataType.build(m, dialect="postgres")
    return d

def typesql(c):                             # same engine: the source's own type text (keeps uuid, jsonb, inet, arrays, unsigned)
    return c["data_type"] if src == tgt else dtype(c).sql(tgt)

def cat(c):
    t = dtype(c).this.name
    if t in ("TINYINT", "SMALLINT", "MEDIUMINT", "INT", "BIGINT", "UTINYINT", "USMALLINT", "UMEDIUMINT", "UINT", "UBIGINT"): return "int"
    if t in ("DECIMAL", "NUMERIC", "MONEY"): return "dec"
    if t in ("FLOAT", "DOUBLE"): return "float"
    if t == "DATE": return "date"
    if t in ("DATETIME", "TIMESTAMP", "TIMESTAMPTZ", "TIMESTAMPLTZ"): return "ts"
    if t in ("TIME", "TIMETZ"): return "time"
    if t == "BOOLEAN": return "bool"
    if t in ("CHAR", "VARCHAR", "TEXT", "NCHAR", "NVARCHAR", "MEDIUMTEXT", "LONGTEXT", "TINYTEXT"): return "str"
    return "other"

def scale_of(c):
    e = dtype(c).expressions
    return int(e[1].name) if len(e) > 1 else 0

def to_u(c, v):                             # a source value -> the integer the target's cast turns back into it
    if v is None: return None
    k = cat(c)
    try:
        if k in ("int", "float"): return round(float(v))
        if k == "dec": return int(decimal.Decimal(v).scaleb(scale_of(c)).to_integral_value())
        if k == "date": return (datetime.date.fromisoformat(v[:10]) - datetime.date(1970, 1, 1)).days
        if k == "ts": return int((datetime.datetime.fromisoformat(v[:19]) - datetime.datetime(1970, 1, 1)).total_seconds())
        if k == "time": h, m, s = v[:8].split(":"); return int(h) * 3600 + int(m) * 60 + int(float(s))
        if k == "bool": return 1 if str(v).lower() in ("t", "true", "1") else 0
    except (ValueError, decimal.InvalidOperation):
        return None
    return None

def to_pg(e):                               # a formula: MySQL syntax -> Postgres; DIV stays integer division
    t = sqlglot.parse_one(e, read="mysql").transform(lambda n: exp.cast(n, "bigint") if isinstance(n, exp.IntDiv) else n)
    return t.sql("postgres")
def F(e): return e if tgt == "mysql" else to_pg(e)

order, seen = [], set()                     # parents first
def visit(n, stack=()):
    if n in seen or n in stack or n not in T: return
    for fk in T[n].get("foreign_keys", []): visit(fk["ref_table"], stack + (n,))
    seen.add(n); order.append(n)
for n in sorted(T): visit(n)

keyf = {}                                   # table -> {key column: formula in x.n}, for children of composite keys
out, expected = [], []
for tn in order:
    t, rows, rs = T[tn], R[tn], int(T[tn].get("row_count") or 0)
    cols = {c["name"]: c for c in t["columns"]}
    pk = t.get("primary_key") or []
    fks = t.get("foreign_keys") or []
    fk1 = {f["columns"][0]: f for f in fks if len(f["columns"]) == 1}
    fkn = [f for f in fks if len(f["columns"]) > 1]
    uniq = {u[0] for u in (t.get("unique") or []) if len(u) == 1}
    v, ln, tags, exp_cols = {}, {}, [f"lfc:rows={rows}"], []

    def dist(c):                            # the column's distinct count at this scale, or None if unknown
        d = c.get("n_distinct")
        if d is None: return None
        d = math.ceil(-d * rows) if d < 0 else (math.ceil(d / rs * rows) if rs and d >= 0.1 * rs else int(d))
        return max(1, min(d, rows))

    # keys: a composite key -> the first two columns from n (k1 = (n - 1) DIV f + 1, k2 = (n - 1) % f + 1, spread over a
    # parent's keys when it is a foreign key); a table without a key -> its first integer column is n
    if len(pk) > 1:
        k1, k2 = pk[0], pk[1]
        p1 = R.get(fk1[k1]["ref_table"]) if k1 in fk1 else None
        d1 = dist(cols[k1]) or rows
        if p1: d1 = min(d1, p1)
        f = max(1, math.ceil(rows / d1))
        p2 = R.get(fk1[k2]["ref_table"]) if k2 in fk1 else None
        step = max(1, p2 // f) if p2 else 1
        if p2 and f > p2: log(f"{tn}: {f} {k2} per {k1} but only {p2} in the parent; the key can't be unique")
        v[k1] = f"(x.n - 1) DIV {f} + 1"
        v[k2] = f"((x.n - 1) % {f}) * {step} + 1"
        for k in pk[2:]: v[k] = "1"
        tags.append(f"lfc:n={{({k1} - 1) * {f} + ({k2} - 1) DIV {step} + 1}}")
        keyf[tn] = dict(v)
    elif not pk:
        n_col = next((c["name"] for c in t["columns"] if cat(c) == "int" and c["name"] not in fk1), None)
        if not n_col:
            log(f"{tn}: no primary key and no integer column to number the rows: skipped"); continue
        v[n_col] = "x.n"; tags += [f"lfc:n={{{n_col}}}", f"lfc:by={{{n_col}}}"]
        log(f"{tn}: no primary key; {n_col} numbers the rows (1, 2, ...), so its own statistics are not kept")

    # a foreign key of several columns -> the parent's key formulas at a parent row m
    for f in fkn:
        p = f["ref_table"]
        if p not in keyf: log(f"{tn}: foreign key to {p}{tuple(f['ref_columns'])} isn't a generated composite key: left to the planner"); continue
        m = f"(1 + x.n * {K(tn, *f['columns'])} % {R[p]})"
        for cc, pc in zip(f["columns"], f["ref_columns"]):
            if cc not in v: v[cc] = keyf[p][pc].replace("x.n", m)

    for c in t["columns"]:
        name, k = c["name"], cat(c)
        e = {"name": name}
        if k == "str" and c.get("avg_width_bytes"):           # Postgres widths include a 1-byte header for short values
            L = max(1, c["avg_width_bytes"] - 1)
            decl = dtype(c).expressions
            if not (dtype(c).this.name == "CHAR") and (not decl or int(decl[0].name) > L): ln[name] = L
        if name in v or (len(pk) == 1 and name == pk[0]) or name in uniq:
            exp_cols.append(e); continue
        nullable = c.get("nullable", True)
        p = (c.get("null_fraction") or 0) if nullable else 0
        d = dist(c)
        par = R.get(fk1[name]["ref_table"]) if name in fk1 else None
        if par:                                               # the share of parents that have children, as in the source
            ps, nd = int(T[fk1[name]["ref_table"]].get("row_count") or 0), c.get("n_distinct")
            share = (-nd * rs if nd is not None and nd < 0 else nd) / ps if nd is not None and ps else 1
            d = max(1, min(par, math.ceil(min(share, 1) * par)))
        mcv = [m for m in (c.get("most_common_values") or []) if m.get("frequency")]
        e.update(null_fraction=round(p, 4), n_distinct=d)
        if mcv: e["top_frequency"] = round(mcv[0]["frequency"], 4)
        exp_cols.append(e)
        if p >= 1: v[name] = "NULL"; continue
        if d is None and not p and not mcv: continue          # nothing known: the planner's own scramble (or FK probe)
        if d is None: d = par or rows
        lo = to_u(c, c.get("min_value")); hi = to_u(c, c.get("max_value"))
        if lo is not None and hi is not None and hi >= lo and not par: d = min(d, hi - lo + 1)   # no more values than the range holds
        e["n_distinct"] = d
        def place(i):                                         # value index 0 .. d-1 -> the integer for the cast
            if par: return f"1 + ({i}) * {par} DIV {d}"
            if lo is not None and hi is not None and hi > lo:
                return f"{lo} + ({i}) * {hi - lo} DIV {max(d - 1, 1)}"
            return f"({i})"
        cap = 10 if tgt == "mysql" else 100                   # MySQL column comments hold 1,024 characters
        # when the most common values are every value, the ones past the cap are drawn evenly from a list (MySQL ELT)
        extra = [to_u(c, m.get("value")) for m in mcv[cap:]] if len(mcv) > cap and len(mcv) >= d and not par else []
        if None in extra or len(",".join(map(str, extra))) > 300: extra = []
        if len(mcv) > cap: log(f"{tn}.{name}: {len(mcv)} most common values, {cap} kept" + (f", {len(extra)} more drawn evenly" if extra else ""))
        mcv = mcv[:min(len(mcv), d, cap)]
        if mcv and len(mcv) >= d:                             # they are every value: their frequencies are the whole column
            tot = sum(m["frequency"] for m in mcv)
            mcv = [dict(m, frequency=m["frequency"] / tot * (1 - p)) for m in mcv]
        if mcv:
            # (n - 1) * prime mod rows is a permutation of the rows: exact frequencies at any size, scattered over the keys
            r, cum, whens = f"(x.n - 1) * {K(tn, name, 'm')} % {rows}", 0.0, []
            for i, m in enumerate(mcv):
                cum += m["frequency"] / max(1 - p, 1e-9)
                u = to_u(c, m.get("value"))
                whens.append(f"WHEN {r} < {min(round(cum * rows), rows)} THEN {u if (u is not None and not par) else place(i)}")
            rest = (f"ELT(1 + x.n * {K(tn, name, 'j')} % {len(extra)}, {', '.join(map(str, extra))})" if extra else
                    place(f"{len(mcv)} + x.n * {K(tn, name, 'j')} % {d - len(mcv)}") if d > len(mcv) else place(len(mcv) - 1))
            val = f"CASE {' '.join(whens)} ELSE {rest} END"
        else:
            val = place(f"x.n * {K(tn, name, 'j')} % {d}")
        if p > 0:
            val = f"CASE WHEN (x.n - 1) * {K(tn, name, 'z')} % {rows} < {round(p * rows)} THEN NULL ELSE {val} END"
        v[name] = val

    # DDL
    defs = []
    for c in t["columns"]:
        com = []
        if c["name"] in v: com.append(f"lfc:v={{{F(v[c['name']])}}}")
        if c["name"] in ln: com.append(f"lfc:len={{{ln[c['name']]}}}")
        nn = "" if c.get("nullable", True) else " NOT NULL"
        defs.append((c["name"], f"{typesql(c)}{nn}", " ".join(com)))
    q = (lambda s: "`" + s + "`") if tgt == "mysql" else (lambda s: '"' + s + '"')
    body = [f"{q(n)} {ty}" + (f" COMMENT '{cm}'" if tgt == "mysql" and cm else "") for n, ty, cm in defs]
    if pk: body.append(f"PRIMARY KEY ({', '.join(map(q, pk))})")
    body += [f"UNIQUE ({', '.join(map(q, u))})" for u in (t.get("unique") or [])]
    body += [f"FOREIGN KEY ({', '.join(map(q, f['columns']))}) REFERENCES {q(f['ref_table'])} ({', '.join(map(q, f['ref_columns']))})"
             for f in fks if f["ref_table"] in R and f["ref_table"] in seen]
    if a.checks: body += [ch if ch.upper().startswith("CHECK") else f"CHECK ({ch})" for ch in (t.get("checks") or [])]
    tc = " ".join(tags[:1] + [tg if tgt == "mysql" else tg.split("={")[0] + "={" + F(tg.split("={", 1)[1][:-1]) + "}" for tg in tags[1:]])
    out.append(f"CREATE TABLE {q(tn)} (\n  " + ",\n  ".join(body) + ")" + (f" COMMENT='{tc}'" if tgt == "mysql" else "") + ";")
    if tgt == "postgres":
        out.append(f"COMMENT ON TABLE {q(tn)} IS '{tc}';")
        out += [f"COMMENT ON COLUMN {q(tn)}.{q(n)} IS '{cm}';" for n, _, cm in defs if cm]
        if not pk: out.append(f"ALTER TABLE {q(tn)} REPLICA IDENTITY FULL;")
    for i, ix in enumerate(t.get("indexes") or []):
        if tgt == "mysql" and any(cat(cols[x]) in ("str", "other") and not dtype(cols[x]).expressions for x in ix): continue
        out.append(f"CREATE INDEX {q(tn + '_x' + str(i + 1))} ON {q(tn)} ({', '.join(map(q, ix))});")
    expected.append({"name": tn, "row_count": rows, "columns": exp_cols})

print("\n".join(out))
json.dump({"scale": a.scale, "keep_small": a.keep_small, "tables": expected}, open(a.expected, "w"), indent=1)
log(f"{len(expected)} tables, {sum(R[t['name']] for t in expected):,} rows (source: {sum(int(T[t['name']].get('row_count') or 0) for t in expected):,})")
SS_EOF
```

How a column's formula is chosen (in order): a key or unique column keeps the planner's plain `n`; a composite key or a keyless table gets its numbering formula; a composite foreign key follows the parent's key formula; otherwise, when the statistics say anything, the value is `NULL` for the null fraction's share, then each most common value for its share, then the rest spread over the distinct count (between min and max, or over the parent's keys for a foreign key). A column with no statistics gets no tag: the planner fills it as usual.

```bash
cat > compare.sql <<'SS_EOF'
-- duckdb -c "SET VARIABLE expected = 'expected.json'; SET VARIABLE actual = 'stats-target.json'; .read compare.sql"
-- The target's statistics (the collector, run on the generated copy after ANALYZE) against what shape.py aimed for:
-- rows, null fraction, distinct count, and the most common value's frequency. Prints only what's off by more than the
-- tolerance: null fraction and top frequency 0.02 (or 3 standard errors in a small table), distinct
-- count 20% (estimated from a sample).
CREATE TEMP TABLE e AS (
  SELECT t.name AS tbl, t.row_count AS rows, c.name AS col, c.null_fraction AS nf, c.n_distinct AS nd, c.top_frequency AS tf
  FROM (SELECT unnest(tables) AS t FROM read_json(getvariable('expected'), maximum_object_size = 1000000000)) , unnest(t.columns) AS u(c)
);
CREATE TEMP TABLE a AS (
  SELECT t.name AS tbl, t.row_count AS rows, c.name AS col, c.null_fraction AS nf,
         CASE WHEN c.n_distinct < 0 THEN -c.n_distinct * t.row_count ELSE c.n_distinct END AS nd,
         c.most_common_values[1].frequency AS tf
  FROM (SELECT unnest(tables) AS t FROM read_json(getvariable('actual'), maximum_object_size = 1000000000)), unnest(t.columns) AS u(c)
);
SELECT e.tbl, e.col, e.nf AS null_want, round(a.nf, 4) AS null_got,
       e.nd AS distinct_want, round(a.nd) AS distinct_got, e.tf AS top_want, round(a.tf, 4) AS top_got
FROM e LEFT JOIN a USING (tbl, col)
WHERE a.tbl IS NULL
   OR abs(coalesce(a.nf, 0) - coalesce(e.nf, 0)) > greatest(0.02, 3 * sqrt(e.nf * (1 - e.nf) / e.rows))
   OR (e.nd IS NOT NULL AND abs(a.nd - e.nd) > 0.2 * e.nd)
   OR (e.tf IS NOT NULL AND abs(coalesce(a.tf, 0) - e.tf) > greatest(0.02, 3 * sqrt(e.tf * (1 - e.tf) / e.rows)))
ORDER BY 1, 2;
-- tables whose row count is off (the statistics' estimate: InnoDB's can be several percent off; exact counts are in
-- the datagen status)
SELECT DISTINCT e.tbl, e.rows AS rows_want, a.rows AS rows_got FROM e JOIN a USING (tbl, col)
WHERE abs(a.rows - e.rows) > 0.1 * e.rows ORDER BY 1;
SS_EOF
```

## Run

```bash
uv run -q --with sqlglot python3 -I shape.py stats.json --target my --scale 0.01 > shape.sql      # MySQL target
mysql -e "CREATE DATABASE sales_s" && mysql sales_s < shape.sql
DIR=my bash fill.sh my sales_s
# statistics on the copy: refresh row counts and build histograms, then collect
mysql -N sales_s -e "SELECT CONCAT('ANALYZE TABLE \`', table_name, '\`;') FROM information_schema.tables WHERE table_schema = 'sales_s'" | mysql sales_s
mysql -N sales_s -e "SELECT CONCAT('ANALYZE TABLE \`', table_name, '\` UPDATE HISTOGRAM ON ', GROUP_CONCAT(CONCAT('\`', column_name, '\`')), ' WITH 100 BUCKETS;') FROM information_schema.columns WHERE table_schema = 'sales_s' GROUP BY table_name" | mysql sales_s
mysql -N -B -r -e "SET @db='sales_s', @vals='ranges'; SOURCE collect.sql" sales_s | jq -f my-normalize.jq > got.json
duckdb -c "SET VARIABLE expected = 'expected.json'; SET VARIABLE actual = 'got.json';" -c ".read compare.sql"
```

A flagged column on a MySQL copy is often MySQL's estimate, not the data: check it with `SELECT COUNT(DISTINCT c) FROM t` on the copy (it's test data).
