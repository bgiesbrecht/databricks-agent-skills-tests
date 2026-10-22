#!/usr/bin/env python3
"""Compare an SCD type 2 silver table with the source's own history.

usage: scd2-history-check.py <schema.tsv> <table> <snapshot.tsv> <changefeed.tsv> <history.tsv>

  schema.tsv     table, ordinal, column, Databricks type, 1 when in the primary key, and any later fields (ignored)
  snapshot.tsv   the table as of T, with a header row, as model-sql.py's select renders it
  changefeed.tsv CockroachDB's changefeed from T WITH updated: table, key and value, the last two as \\x hex JSON
  history.tsv    the silver history table's columns in schema order (model-sql.py's select), ordered by the key and
                 __START_AT

The expected versions of a key are its row at T, then the row after every insert or update, in commit order (the
changefeed's `updated` HLC). A delete adds no version. Consecutive identical versions (an update that changed nothing) count once, on
both sides. Prints one line, "<versions expected> <versions in silver>
<keys that differ>: <first differences>", and exits 0 when they're equal, 1 when not.
"""
import datetime
import json
import re
import sys
from decimal import Decimal


TS = re.compile(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}(:?\d{2})?)?$")
TOD = re.compile(r"^(\d{2}:\d{2}:\d{2})(\.\d+)?$")


def norm(v):
    """One value, from the changefeed's JSON or as model-sql.py renders it, in one form: numbers normalized, booleans
    true/false, timestamps (in UTC) and times to the microsecond, fixed-length strings without their padding."""
    if v is None or v in ("null", "NULL", "<null>"):
        return None
    if isinstance(v, bool):
        return "true" if v else "false"
    s = str(v).rstrip(" ")
    m = TS.match(s)
    if m:
        d = datetime.datetime.fromisoformat(f"{m.group(1)} {m.group(2)}{m.group(3) or ''}"[:26])
        if m.group(4) and m.group(4) != "Z":
            off = m.group(4).replace(":", "")
            d -= datetime.timedelta(hours=int(off[:3]), minutes=int(off[0] + (off[3:5] or "0")))
        return d.strftime("%Y-%m-%d %H:%M:%S.%f")
    m = TOD.match(s)
    if m:
        return m.group(1) + (m.group(2) or ".")[:7].ljust(7, "0")
    try:
        return str(Decimal(s).normalize())
    except ArithmeticError:   # not a number (InvalidOperation), or text that looks like one with a huge exponent (Overflow)
        return s


def main():
    schema_f, table, snap_f, feed_f, hist_f = sys.argv[1:6]
    cols, keys = [], []
    for line in open(schema_f):
        f = line.rstrip("\n").split("\t")   # table, ordinal, column, type, key flag, then possibly more (a default)
        t, col, pk = f[0], f[2], f[4]
        if t == table:
            cols.append(col)
            if pk == "1":
                keys.append(col)
    others = [c for c in cols if c not in keys]

    expected = {}
    lines = open(snap_f).read().splitlines()
    head = lines[0].split("\t") if lines else []
    for line in lines[1:]:
        row = dict(zip(head, line.split("\t")))
        k = tuple(norm(row[c]) for c in keys)
        expected.setdefault(k, []).append(tuple(norm(row.get(c)) for c in others))

    events = []
    for line in open(feed_f):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 3 or parts[0] != table or not parts[2].startswith("\\x"):
            continue
        value = json.loads(bytes.fromhex(parts[2][2:]), parse_float=Decimal)
        events.append((Decimal(value["updated"]), value))
    for _, value in sorted(events, key=lambda e: e[0]):
        after = value.get("after")
        if after is None:
            continue
        k = tuple(norm(after.get(c)) for c in keys)
        expected.setdefault(k, []).append(tuple(norm(after.get(c)) for c in others))

    actual = {}
    for line in open(hist_f):
        vals = line.rstrip("\n").split("\t")
        row = dict(zip(cols, vals))
        k = tuple(norm(row[c]) for c in keys)
        actual.setdefault(k, []).append(tuple(norm(row[c]) for c in others))

    # an update to the values a row already has isn't a new version: silver can't tell it from a producer's replay
    # (the same row image within the dedup window), so consecutive identical versions count once, on both sides
    def collapse(vs):
        return [v for i, v in enumerate(vs) if i == 0 or v != vs[i - 1]]
    expected = {k: collapse(v) for k, v in expected.items()}
    actual = {k: collapse(v) for k, v in actual.items()}
    differ = sorted(k for k in set(expected) | set(actual) if expected.get(k) != actual.get(k))
    n_exp = sum(len(v) for v in expected.values())
    n_act = sum(len(v) for v in actual.values())
    detail = "; ".join(
        f"{','.join(map(str, k))}: expected {['/'.join(map(str, v)) for v in expected.get(k, [])]} "
        f"got {['/'.join(map(str, v)) for v in actual.get(k, [])]}" for k in differ[:2])
    print(f"{n_exp} {n_act} {len(differ)}: {detail}")
    sys.exit(1 if differ else 0)


if __name__ == "__main__":
    main()
