#!/usr/bin/env python3
"""The test's SQL for any model, from its canonical schema (statschema's schema.yaml, lfc-source-statschema): nothing
here names a table, a column or a type, so a new model needs a schema.yaml and nothing else.

usage: model-sql.py <schema.yaml> <command> [options]
  state  --prefix P                     one SELECT on the source: table, column, MAX for every integer key column that
                                        isn't a foreign key; save its output (with the header row) for --state
  round N --state F --prefix P [--part before|after] [--manifest out.json]
                                        the DML of round N (1, 2, 3) on the source, and what it should produce
  alter N --prefix P [--part ddl|after] [--gold gold.sql] [--manifest out.json]
                                        round 4 (a column added, with a default) or 5 (a column dropped, one retyped)
  select T --side source|databricks --prefix P
                                        table T's columns, every value rendered as the same text on both sides (NULL as
                                        <null>), ordered by the key (by every column for a table without one)
  --dialect crdb|pg (default pg, which is also YugabyteDB); --only t1,t2 limits the workload to those tables.

The workload, generic over keys and foreign keys:
  - a table with a primary key gets inserts of new keys (each integer key column that isn't a foreign key at its MAX
    plus n, so the rows are new), updates of one column that isn't a key, a foreign key or unique, and deletes only of
    rows the workload inserted itself, so no foreign key ever blocks one. A foreign key column takes an existing parent
    row's value (the parent's first row by its key), so every insert is valid.
    round 1: insert keys 1, 2, 3, update the table's first row, delete key 3
    round 2: two updates of the first row, delete and reinsert key 1, reinsert key 3 (deleted in round 1)
    round 3: insert key 4, two updates of key 2; --part after (once the producer is restarted): update key 4
  - a table whose key is all foreign keys gets the updates only; a table without a key gets inserts only (append-only).
  Round 4 adds lfc_r4 (VARCHAR(20) NOT NULL DEFAULT 'none') to the first table with a key, then sets it on one row.
  Round 5 retypes the first non-key decimal column (two more digits; else an integer becomes BIGINT, but not on
  CockroachDB, whose INT is already 8 bytes), drops another column of that table (not a key, a foreign key, nor named in
  --gold), then writes a value only the new type holds.
The manifest (JSON): "expect", each table's events through this round {table: {create, update, delete}}; "events", how
many this part adds; "probe", a predicate on the normalized change log that holds once the part's last change arrived;
for alter, also "table", "column", "value", and for round 5 "retype" and "drop".
"""
import argparse
import datetime
import json
import re

import yaml

ALIAS = {"int": "integer", "smallint": "integer", "tinyint": "integer", "bigint": "long", "numeric": "decimal",
         "varchar": "string", "text": "string", "real": "float", "double precision": "double", "bool": "boolean"}
INTS = ("integer", "long")


def ctype(c):
    return ALIAS.get(c["type"], c["type"])


def qi(n):   # a source identifier, quoted: names keep their case (TPC-DI's are mixed case)
    return '"' + n.replace('"', '""') + '"'


def bq(n):   # a Databricks identifier
    return "`" + n.replace("`", "``") + "`"


def vpath(base, n):   # a VARIANT field: the plain form for simple names, brackets otherwise
    return f"{base}:{n}" if re.fullmatch(r"[a-z_][a-z0-9_]*", n) else f"{base}['{n}']"


class Model:
    def __init__(self, path, only=None):
        tables = yaml.safe_load(open(path))["tables"]
        self.t = {}
        for t in tables:
            cols = t["columns"]
            fks = [(list(f["columns"]), f["parent_table"], list(f["parent_columns"])) for f in t.get("fk_constraints") or []]
            fks += [([c["name"]], c["references"][0], [c["references"][1]]) for c in cols if c.get("references")]
            self.t[t["name"]] = {"cols": cols, "keys": [c["name"] for c in cols if c.get("primary_key")], "fks": fks}
        names = [n for n in self.t if not only or n in only]
        self.order = []   # parents before children
        seen = set()

        def visit(n, stack=()):
            if n in seen or n in stack or n not in self.t:
                return
            for _, p, _ in self.t[n]["fks"]:
                visit(p, stack + (n,))
            seen.add(n)
            self.order.append(n)
        for n in self.t:
            visit(n)
        self.order = [n for n in self.order if n in names]
        for n, t in self.t.items():
            fkc = {c for cs, _, _ in t["fks"] for c in cs}
            t["fkc"] = fkc
            t["free"] = [k for k in t["keys"] if k not in fkc]
            t["upd"] = next((c for c in t["cols"] if c["name"] not in t["keys"] and c["name"] not in fkc
                             and not c.get("unique") and not (c.get("generation") or {}).get("unique")
                             and ctype(c) != "binary"), None)

    def col(self, t, n):
        return next(c for c in self.t[t]["cols"] if c["name"] == n)


def value(c, seed):
    """A literal of the column's canonical type, from seed (PostgreSQL syntax: PostgreSQL, YugabyteDB, CockroachDB)."""
    ty = ctype(c)
    if ty == "integer":
        return str(seed % 30000 + 1)   # fits SMALLINT too
    if ty == "long":
        return str(seed)
    if ty == "decimal":
        p, s = int(c.get("precision") or 18), int(c.get("scale") or 0)
        ip = seed % 10 ** min(max(p - s, 0), 6)
        return f"{ip}.{seed % 10 ** s:0{s}d}" if s else str(ip)
    if ty in ("float", "double"):
        return f"{seed}.5"
    if ty == "boolean":
        return "TRUE" if seed % 2 else "FALSE"
    epoch = datetime.datetime(2030, 1, 1)
    if ty == "date":
        return f"DATE '{(epoch + datetime.timedelta(days=seed % 3000)).date()}'"
    if ty in ("timestamp", "timestamptz"):
        ts = epoch + datetime.timedelta(seconds=seed)
        return f"TIMESTAMP '{ts:%Y-%m-%d %H:%M:%S}'" + ("" if ty == "timestamp" else "::TIMESTAMPTZ")
    if ty in ("time", "timetz"):
        return f"TIME '{datetime.timedelta(seconds=seed % 86400)}'".replace("TIME '0:", "TIME '00:")
    if ty == "binary":
        return f"decode('{seed:08x}', 'hex')"
    s = f"r{seed}"
    n = c.get("length")
    return "'" + (s[-int(n):] if n else s) + "'"


class Rounds:
    def __init__(self, m, prefix, state):
        self.m, self.p = m, prefix
        self.base = {}
        for line in (open(state).read().splitlines()[1:] if state else []):
            f = line.split("\t")
            if len(f) >= 3:
                self.base[(f[0], f[1])] = int(f[2] or 0) if f[2] not in ("", "NULL") else 0

    def tbl(self, t):
        return f"{self.p}.{qi(t)}"

    def keylit(self, t, k, n):
        c = self.m.col(t, k)
        if ctype(c) in INTS:
            return str(self.base.get((t, k), 0) + n)
        if ctype(c) in ("string", "char"):   # 'zz..n': after the generated keys (lfc-source-datagen numbers from 0)
            L = int(c.get("length") or 0)
            return "'" + ("zyxw"[n - 1] if L == 1 else ("z" * L + str(n))[-L:] if L else f"zz{n}") + "'"
        return value(c, 900000 + n)

    def first(self, t):   # the table's first row by its key: never one the workload inserts (those keys come after MAX)
        ks = ", ".join(qi(k) for k in self.m.t[t]["keys"])
        return f"({ks}) IN (SELECT {ks} FROM {self.tbl(t)} ORDER BY {ks} LIMIT 1)"

    def at(self, t, n):
        return " AND ".join(f"{qi(k)} = {self.keylit(t, k, n)}" for k in self.m.t[t]["free"])

    def insert(self, t, n, rnd):
        d = self.m.t[t]
        names, vals, froms = [], [], []
        for i, (cs, parent, pcs) in enumerate(d["fks"]):
            if parent not in self.m.t:
                continue
            pk = ", ".join(qi(x) for x in pcs)
            froms.append(f"(SELECT {pk} FROM {self.tbl(parent)} ORDER BY {pk} LIMIT 1) f{i}")
            for c, pc in zip(cs, pcs):
                if c not in names:
                    names.append(c)
                    vals.append(f"f{i}.{qi(pc)}")
        for c in d["cols"]:
            if c["name"] in names:
                continue
            names.append(c["name"])
            vals.append(self.keylit(t, c["name"], n) if c["name"] in d["free"] else value(c, n * 10 + rnd))
        cols = ", ".join(qi(x) for x in names)
        if froms:
            return f"INSERT INTO {self.tbl(t)} ({cols}) SELECT {', '.join(vals)} FROM {', '.join(froms)};"
        return f"INSERT INTO {self.tbl(t)} ({cols}) VALUES ({', '.join(vals)});"

    def update(self, t, where, seed):
        u = self.m.t[t]["upd"]
        return f"UPDATE {self.tbl(t)} SET {qi(u['name'])} = {value(u, seed)} WHERE {where};"

    def delete(self, t, n):
        return f"DELETE FROM {self.tbl(t)} WHERE {self.at(t, n)};"

    def plan(self, rnd, part):
        """[(table, sql, op)] for one round and part, parents first (deletes, of rows nothing refers to, in any order)."""
        out = []
        for t in self.m.order:
            d = self.m.t[t]
            ins = bool(d["keys"]) and bool(d["free"])
            upd = bool(d["keys"]) and d["upd"] is not None
            s = []
            if not d["keys"]:   # append-only
                s = {1: [1, 2], 2: [3], 3: [4] if part == "before" else []}[rnd]
                out += [(t, self.insert(t, n, rnd), "create") for n in s]
                continue
            if rnd == 1:
                s = [("create", n) for n in (1, 2, 3)] if ins else []
                s += [("update", "first")] if upd else []
                s += [("delete", 3)] if ins else []
            elif rnd == 2:
                s = [("update", "first"), ("update", "first")] if upd else []
                s += [("delete", 1), ("create", 1), ("create", 3)] if ins else []
            elif part == "before":
                s = [("create", 4)] if ins else []
                s += [("update", 2), ("update", 2)] if ins and upd else []
            else:
                s = [("update", 4)] if ins and upd else []
            for i, (op, n) in enumerate(s):
                if op == "create":
                    out.append((t, self.insert(t, n, rnd), op))
                elif op == "delete":
                    out.append((t, self.delete(t, n), op))
                else:
                    where = self.first(t) if n == "first" else self.at(t, n)
                    out.append((t, self.update(t, where, 1000 * rnd + 100 * i + (7 if part == "after" else 0)), op))
        return out

    def probe(self, rnd, part):
        """A predicate on the normalized change log: the part's last change for the first table with an insertable key."""
        m = self.m
        for t in m.order:
            d = m.t[t]
            if d["keys"] and d["free"] and d["upd"] and all(ctype(m.col(t, k)) in INTS for k in d["free"]):
                n = {1: 2, 2: 3, 3: 2 if part == "before" else 4}[rnd]
                op = "update" if (rnd, part) in ((3, "before"), (3, "after")) else "create"
                cond = " AND ".join(f"{vpath('key', k)}::STRING = '{self.keylit(t, k, n)}'" for k in d["free"])
                return f"destination LIKE '%.{t}' AND operation = '{op}' AND {cond}"
        return "true"


def count(steps):
    e = {}
    for t, _, op in steps:
        e.setdefault(t, {"create": 0, "update": 0, "delete": 0})[op] += 1
    return e


def add(a, b):
    for t, ops in b.items():
        for op, n in ops.items():
            a.setdefault(t, {"create": 0, "update": 0, "delete": 0})[op] += n
    return a


def cmd_round(m, a):
    r = Rounds(m, a.prefix, a.state)
    exp = {}
    for n in range(1, a.n + 1):
        add(exp, count(r.plan(n, "before")))
        if n == 3 and a.part == "after":
            add(exp, count(r.plan(n, "after")))
    steps = r.plan(a.n, a.part)
    print("\n".join(s for _, s, _ in steps))
    write(a, {"expect": exp, "events": len(steps), "probe": r.probe(a.n, a.part)})


def first_keyed(m):
    return next(t for t in m.order if m.t[t]["keys"])


def cmd_alter(m, a):
    r = Rounds(m, a.prefix, None)
    gold = set(re.findall(r"\w+", open(a.gold).read())) if a.gold else set()
    if a.n == 4:
        t = first_keyed(m)
        man = {"table": t, "column": "lfc_r4", "value": "r4_set", "default": "none",
               "probe": f"destination LIKE '%.{t}' AND {vpath('value:after', 'lfc_r4')}::STRING = 'r4_set'"}
        sql = (f"ALTER TABLE {r.tbl(t)} ADD COLUMN lfc_r4 VARCHAR(20) NOT NULL DEFAULT 'none';" if a.part == "ddl" else
               f"UPDATE {r.tbl(t)} SET lfc_r4 = 'r4_set' WHERE {r.first(t)};")
    else:
        pick = None
        for want in ("decimal", "integer"):
            for t in m.order:
                d = m.t[t]
                c = next((c for c in d["cols"] if d["keys"] and c["name"] not in d["keys"] and c["name"] not in d["fkc"]
                          and ctype(c) == want), None)
                if c and pick is None and not (want == "integer" and a.dialect == "crdb"):
                    pick = (t, c)
            if pick:
                break
        t, c = pick or (first_keyed(m), None)
        d = m.t[t]
        drop = next((x["name"] for x in reversed(d["cols"]) if x["name"] not in d["keys"] and x["name"] not in d["fkc"]
                     and (c is None or x["name"] != c["name"]) and x["name"] not in gold), None)
        man = {"table": t, "drop": drop, "retype": None, "probe": "true"}
        ddl = ["SET sql_safe_updates = false;", "SET enable_experimental_alter_column_type_general = true;"] if a.dialect == "crdb" else []
        if drop:
            ddl.append(f"ALTER TABLE {r.tbl(t)} DROP COLUMN {qi(drop)};")
        if c is not None:
            if ctype(c) == "decimal":
                p, s = int(c.get("precision") or 18), int(c.get("scale") or 0)
                new, v = f"DECIMAL({p + 2},{s})", "9" * (p - s + 1) + ("." + "1" * s if s else "")
            else:
                new, v = "BIGINT", "3000000000"
            ddl.append(f"ALTER TABLE {r.tbl(t)} ALTER COLUMN {qi(c['name'])} TYPE {new};")
            man.update(retype={"column": c["name"], "to": new}, column=c["name"], value=v,
                       probe=f"destination LIKE '%.{t}' AND {vpath('value:after', c['name'])}::STRING = '{v}'")
        sql = "\n".join(ddl) if a.part == "ddl" else (f"UPDATE {r.tbl(t)} SET {qi(c['name'])} = {man['value']} WHERE {r.first(t)};" if c else "")
    print(sql)
    write(a, man)


def render(c, side, dialect):
    """One column as text, the same on both sides: NULL as <null>, times to the microsecond, chars without padding."""
    n, ty = c["name"], ctype(c)
    if side == "source":
        x = qi(n)
        fn, ymd, hms = ("experimental_strftime", "%Y-%m-%d ", "%H:%M:%S.%f") if dialect == "crdb" else \
            ("to_char", "YYYY-MM-DD ", "HH24:MI:SS.US")

        def fmt(e, f=ymd + hms):
            return f"{fn}({e}, '{f}')"
        e = {"boolean": f"CASE WHEN {x} THEN 'true' ELSE 'false' END", "float": f"CAST({x} AS DECIMAL(38,6))::TEXT",
             "double": f"CAST({x} AS DECIMAL(38,6))::TEXT", "timestamp": fmt(x), "timestamptz": fmt(f"{x} AT TIME ZONE 'UTC'"),
             "time": fmt(f"DATE '2000-01-01' + {x}", hms), "char": f"RTRIM({x})",
             "binary": f"encode({x}, 'hex')"}.get(ty, f"{x}::TEXT")
    else:   # silver: a time is already text (silver-from-schema.py renders it as HH:mm:ss.SSSSSS)
        x = bq(n)
        e = {"boolean": f"CASE WHEN {x} THEN 'true' ELSE 'false' END", "float": f"CAST(CAST({x} AS DECIMAL(38,6)) AS STRING)",
             "double": f"CAST(CAST({x} AS DECIMAL(38,6)) AS STRING)",
             "timestamp": f"date_format({x}, 'yyyy-MM-dd HH:mm:ss.SSSSSS')",
             "timestamptz": f"date_format({x}, 'yyyy-MM-dd HH:mm:ss.SSSSSS')", "char": f"RTRIM({x})",
             "binary": f"lower(hex({x}))"}.get(ty, f"CAST({x} AS STRING)")
    return f"COALESCE({e}, '<null>')"


def cmd_select(m, a):
    d = m.t[a.table]
    cols = ", ".join(render(c, a.side, a.dialect) for c in d["cols"])
    q = qi if a.side == "source" else bq
    order = ", ".join(q(k) for k in d["keys"]) if d["keys"] else ", ".join(str(i + 1) for i in range(len(d["cols"])))
    print(f"SELECT {cols} FROM {a.prefix}.{q(a.table)} ORDER BY {order}" + (";" if a.side == "source" else ""))


def cmd_state(m, a):
    r = Rounds(m, a.prefix, None)
    parts = [f"SELECT '{t}' AS tbl, '{k}' AS col, COALESCE(MAX({qi(k)}), 0)::TEXT AS mx FROM {r.tbl(t)}"
             for t in m.order for k in m.t[t]["free"] if ctype(m.col(t, k)) in INTS]
    print(" UNION ALL ".join(parts) + ";" if parts else "SELECT '' AS tbl, '' AS col, '0' AS mx;")


def write(a, man):
    if a.manifest:
        json.dump(man, open(a.manifest, "w"), indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("schema")
    ap.add_argument("cmd", choices=["state", "round", "alter", "select"])
    ap.add_argument("arg", nargs="?")
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--state")
    ap.add_argument("--part", default="before")
    ap.add_argument("--manifest")
    ap.add_argument("--gold")
    ap.add_argument("--side", default="source", choices=["source", "databricks"])
    ap.add_argument("--dialect", default="pg", choices=["pg", "crdb"])
    ap.add_argument("--only")
    a = ap.parse_args()
    m = Model(a.schema, set(a.only.split(",")) if a.only else None)
    if a.cmd in ("round", "alter"):
        a.n = int(a.arg)
        if a.cmd == "alter" and a.part == "before":
            a.part = "ddl"
    if a.cmd == "select":
        a.table = a.arg
    {"state": cmd_state, "round": cmd_round, "alter": cmd_alter, "select": cmd_select}[a.cmd](m, a)


if __name__ == "__main__":
    main()
