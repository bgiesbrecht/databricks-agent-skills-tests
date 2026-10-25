#!/usr/bin/env python3
"""fk-actions.py <schema.yaml> --target <catalog>.<schema> [--plan _plan.yaml] [--history-suffix _history] [--source-key]
[--log fk_actions] [--count | --edges i,j]: the SQL that applies to silver the rows foreign keys' ON DELETE actions changed at the source and
its change log doesn't carry (MySQL through 9.5, MariaDB: InnoDB's own cascades aren't in the binlog). Run after each
silver update; prints one statement per line (a pass), which the caller repeats until a pass changes nothing (chains:
a child deleted is a parent the next pass).

The rule is the source's own: it enforces its foreign keys, so at a consistent point no child row references a
parent that's gone. For each foreign key with ON DELETE CASCADE or SET NULL whose child and parent both have current
rows in silver (scd1), the child rows whose key columns are all set and match no parent row (of their own source, with
--source-key) are:
  CASCADE   deleted from <child>; their open version in <child><history-suffix> closed at the parent's last version's
            end (the parent's delete), or at the version's own start when the parent keeps no history
  SET NULL  given NULL in those columns in <child>; in the history, the open version closed and a new one opened with
            the columns NULL, at the same point
--count prints instead one query, every foreign key's orphan rows counted ("edge<TAB>rows"), so a pass runs only the
statements of the keys with some (--edges: their numbers); Mautic's 190 such keys make 636 statements, nearly all of
them with nothing to do after a round.
Each change is first recorded in the log table (created when missing): table, source, key (JSON), operation, the
foreign key, and when the pass ran: the trace. Tables silver appends to aren't changed (the plan gives them scd1
when such a foreign key acts on them: cdc-table-plan).
"""
import argparse
import json

import yaml

ap = argparse.ArgumentParser()
ap.add_argument("schema")
ap.add_argument("--target", required=True)
ap.add_argument("--plan")
ap.add_argument("--history-suffix", default="_history")
ap.add_argument("--source-key", action="store_true")
ap.add_argument("--log", default="fk_actions")
ap.add_argument("--count", action="store_true")
ap.add_argument("--edges", help="only these foreign keys (their numbers in --count's output)")
a = ap.parse_args()


def bq(n):
    return "`" + n.replace("`", "``") + "`"


T = ".".join(bq(p) for p in a.target.split(".", 1)) if not a.target.startswith("`") else a.target
tables = {t["name"]: t for t in yaml.safe_load(open(a.schema))["tables"]}
plan = ((yaml.safe_load(open(a.plan)) or {}).get("tables") or {}) if a.plan else {}


def silver(t):
    pk = [c["name"] for c in tables[t]["columns"] if c.get("primary_key")]
    return set((plan.get(t) or {}).get("silver") or (["scd1", "scd2"] if pk else ["append"]))


def keys(t):
    return [c["name"] for c in tables[t]["columns"] if c.get("primary_key")]


def depth(t, seen=()):   # parents first: a table's level in the foreign key graph
    ps = [f["parent_table"] for f in tables[t].get("fk_constraints") or [] if f["parent_table"] in tables
          and f["parent_table"] != t and f["parent_table"] not in seen]
    return 1 + max((depth(p, seen + (t,)) for p in ps), default=0)


H = a.history_suffix
out = [f"CREATE TABLE IF NOT EXISTS {T}.{bq(a.log)} (tbl STRING, _source STRING, key STRING, operation STRING, "
       "foreign_key STRING, at TIMESTAMP) COMMENT 'The rows foreign keys'' ON DELETE actions changed at the source, which "
       "its change log does not carry: applied to silver by fk-actions.py after each update (the trace)'"]
counts, edge = [], -1
only = {int(x) for x in a.edges.split(",")} if a.edges else None
for child in sorted(tables, key=depth):
    for f in tables[child].get("fk_constraints") or []:
        act = str(f.get("on_delete") or "").upper().replace("_", " ")
        parent = f["parent_table"]
        if act not in ("CASCADE", "SET NULL") or parent not in tables or "scd1" not in silver(child) or "scd1" not in silver(parent):
            continue
        fc, pc = f["columns"], f["parent_columns"]
        src = ["_source"] if a.source_key else []
        # the child rows (alias o) whose key columns are set and match no current parent row: an anti join
        pj = " AND ".join([f"p.{bq(p)} = o.{bq(c)}" for c, p in zip(fc, pc)] + [f"p.{x} = o.{x}" for x in src])
        nn = " AND ".join(f"o.{bq(c)} IS NOT NULL" for c in fc)
        orphans = lambda frm, extra="": f"SELECT o.* FROM {frm} o LEFT ANTI JOIN {T}.{bq(parent)} p ON {pj} WHERE {nn}{extra}"
        edge += 1
        counts.append(f"SELECT {edge} AS edge, COUNT(*) AS n FROM ({orphans(f'{T}.{bq(child)}')}) s")
        if only is not None and edge not in only:
            continue
        rule = f"{child}({','.join(fc)}) -> {parent}({','.join(pc)}) ON DELETE {act}"
        pk = keys(child)
        km = " AND ".join([f"c.{bq(k)} = s.{bq(k)}" for k in pk] + ["c._source = s._source"])
        key = "to_json(named_struct(" + ", ".join(f"'{k}', s.{bq(k)}" for k in pk) + "))"
        op = "delete" if act == "CASCADE" else "update"
        out.append(f"INSERT INTO {T}.{bq(a.log)} SELECT '{child}', s._source, {key}, '{op}', {json.dumps(rule)}, current_timestamp() "
                   f"FROM ({orphans(f'{T}.{bq(child)}')}) s")
        if "scd2" in silver(child):
            # the open version ends at the parent's delete: its last version's end, when the parent keeps history
            if "scd2" in silver(parent):
                hj = " AND ".join([f"h.{bq(p)} = s.{bq(c)}" for c, p in zip(fc, pc)] + [f"h.{x} = s.{x}" for x in src])
                ends = (f"SELECT s.*, (SELECT MAX(h.__END_AT) FROM {T}.{bq(parent + H)} h WHERE {hj}) AS _end "
                        f"FROM ({orphans(f'{T}.{bq(child + H)}', ' AND o.__END_AT IS NULL')}) s")
            else:
                ends = f"SELECT s.*, CAST(NULL AS BIGINT) AS _end FROM ({orphans(f'{T}.{bq(child + H)}', ' AND o.__END_AT IS NULL')}) s"
            hm = km + " AND c.__START_AT = s.__START_AT"
            if act == "SET NULL":   # a new version with the columns NULL, from where the open one ends
                cols = [c["name"] for c in tables[child]["columns"]]
                sel = ", ".join(("NULL" if n in fc else f"s.{bq(n)}") for n in cols)
                out.append(f"INSERT INTO {T}.{bq(child + H)} ({', '.join(bq(n) for n in cols)}, _source, __START_AT, __END_AT) "
                           f"SELECT {sel}, s._source, COALESCE(s._end, s.__START_AT), NULL FROM ({ends}) s")
            out.append(f"MERGE INTO {T}.{bq(child + H)} c USING ({ends}) s ON {hm} AND c.__END_AT IS NULL "
                       f"WHEN MATCHED THEN UPDATE SET __END_AT = COALESCE(s._end, s.__START_AT)")
        if act == "CASCADE":
            out.append(f"MERGE INTO {T}.{bq(child)} c USING ({orphans(f'{T}.{bq(child)}')}) s ON {km} WHEN MATCHED THEN DELETE")
        else:
            out.append(f"MERGE INTO {T}.{bq(child)} c USING ({orphans(f'{T}.{bq(child)}')}) s ON {km} "
                       "WHEN MATCHED THEN UPDATE SET " + ", ".join(f"{bq(x)} = NULL" for x in fc))
print(" UNION ALL ".join(counts) if a.count else "\n".join(out))
