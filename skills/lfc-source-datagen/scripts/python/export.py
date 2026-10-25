#!/usr/bin/env python3
# export.py <engine> <schema> --tables t1,t2 --out DIR [connection options as fill.py's]: each table's rows into
# DIR/<table>.csv, one file per table with a header row, through the same drivers as fill.py: the snapshot a CDC test
# loads at T, for an engine with no CSV export of its own that quotes values (SQL Server's bcp, Db2's EXPORT, Informix's
# UNLOAD each write another format).
# One connection reads every table, one after another: the caller keeps the source quiet (no writes) while it runs, so
# the files are one consistent state. Values as text: NULL as \N (unquoted), strings quoted when they need it (a quote
# inside doubled), timestamps as YYYY-MM-DD HH:MM:SS.ffffff, dates and times in ISO form, decimals in plain notation,
# booleans true/false, binary as lower-case hex. Read them back with header, nullValue \N, escape ", multiLine.
# Prints "table<TAB>rows" per table.
import argparse, csv, datetime, decimal, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import drivers
from engines import ENGINES

ap = argparse.ArgumentParser(description="export tables to CSV through a driver")
ap.add_argument("engine"); ap.add_argument("schema"); ap.add_argument("--tables", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int); ap.add_argument("--user"); ap.add_argument("--database")
ap.add_argument("--password-file"); ap.add_argument("--server", help="Informix DBSERVERNAME (default informix)")
ap.add_argument("--trust-server-certificate", action="store_true", help="SQL Server: accept a self-signed certificate")
ap.add_argument("--batch", type=int, default=10000)
a = ap.parse_args()
eng = ENGINES[a.engine]()
if not a.database and hasattr(eng, "default_db"): a.database = eng.default_db(a.schema)
sch = eng.schema(a.schema) if hasattr(eng, "schema") else a.schema
name = {"pg": "postgres", "my": "mysql", "ms": "sqlserver", "mssql": "sqlserver", "ora": "oracle", "ifx": "informix"}.get(a.engine, a.engine)


def text(v):
    if v is None:
        return "\\N"
    if hasattr(v, "read"):                       # Oracle's LOBs
        v = v.read()
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, datetime.datetime):
        return v.strftime("%Y-%m-%d %H:%M:%S.%f")
    if isinstance(v, (datetime.date, datetime.time)):
        return v.isoformat()
    if isinstance(v, datetime.timedelta):        # MySQL's TIME
        s = int(v.total_seconds()); return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}.{v.microseconds:06d}"
    if isinstance(v, decimal.Decimal):
        return format(v, "f")
    if isinstance(v, (bytes, bytearray, memoryview)):
        return bytes(v).hex()
    return str(v)


os.makedirs(a.out, exist_ok=True)
con = drivers.connect(name, a)
cur = con.cursor()
def select_list(t):
    """The columns to read: * but on Informix, a DATETIME starting at HOUR (a time of day) as text: the Python driver
    decodes DATETIME HOUR TO SECOND as if it started at YEAR and fails (ValueError: hour must be in 0..23)."""
    if name != "informix":
        return "*"
    cur.execute("SELECT c.colname, c.coltype, c.collength FROM syscolumns c JOIN systables s ON c.tabid = s.tabid "
                "WHERE s.tabname = '" + t.lower().replace("'", "''") + "' ORDER BY c.colno")
    cols = cur.fetchall()
    return ", ".join(f"{n.strip()}::LVARCHAR AS {n.strip()}" if ct % 256 == 10 and (ln % 256) // 16 == 6 else n.strip()
                     for n, ct, ln in cols) or "*"


for t in a.tables.split(","):
    cur.execute(f"SELECT {select_list(t)} FROM {eng.t(sch, t)}")
    head = [d[0] for d in cur.description]
    n = 0
    with open(os.path.join(a.out, f"{t}.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(head)
        while True:
            rows = cur.fetchmany(a.batch)
            if not rows:
                break
            w.writerows([text(v) for v in r] for r in rows); n += len(rows)
    print(f"{t}\t{n}")
con.close()
