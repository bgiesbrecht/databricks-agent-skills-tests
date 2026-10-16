#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["duckdb"]
# ///
"""uv run q.py <query.sql>: the same as q.sh, for a Python caller. Or import q and call q.run("dir/step.sql") for a dict."""
import os, re, shlex, sys
import duckdb

def run(path):
    lib = os.path.join(os.path.dirname(path), "lib.sql")
    sql = (open(lib).read() if os.path.exists(lib) else "") + open(path).read()
    con = duckdb.connect()
    for v in sorted(set(re.findall(r"getvariable\('(\w+)'\)", sql))):
        con.execute(f"SET VARIABLE {v} = ?", [os.environ.get(v, "")])
    r = con.execute(sql)
    return dict(zip([d[0] for d in r.description], r.fetchone()))

if __name__ == "__main__":
    for k, v in run(sys.argv[1]).items():
        print(f"{k}={shlex.quote('' if v is None else str(v))}")
