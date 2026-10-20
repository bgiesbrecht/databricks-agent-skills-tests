#!/usr/bin/env python3
"""Compare an SCD type 2 silver table with the source's own history.

usage: scd2-history-check.py <schema.tsv> <table> <snapshot.tsv> <changefeed.tsv> <history.tsv>

  schema.tsv     table, ordinal, column, Databricks type, 1 when in the primary key (from the UC connection)
  snapshot.tsv   the table as of T, with a header row (cockroach sql --format=tsv)
  changefeed.tsv CockroachDB's changefeed from T WITH updated: table, key and value, the last two as \\x hex JSON
  history.tsv    the silver history table's columns in schema order, ordered by the key and __START_AT

The expected versions of a key are its row at T, then the row after every insert or update, in commit order (the
changefeed's `updated` HLC). A delete adds no version. Prints one line, "<versions expected> <versions in silver>
<keys that differ>: <first differences>", and exits 0 when they're equal, 1 when not.
"""
import json
import sys
from decimal import Decimal, InvalidOperation


def norm(v):
    if v is None or v == "null" or v == "NULL":
        return None
    s = str(v)
    try:
        return str(Decimal(s).normalize())
    except InvalidOperation:
        return s


def main():
    schema_f, table, snap_f, feed_f, hist_f = sys.argv[1:6]
    cols, keys = [], []
    for line in open(schema_f):
        t, _, col, _, pk = line.rstrip("\n").split("\t")
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
        value = json.loads(bytes.fromhex(parts[2][2:]))
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
