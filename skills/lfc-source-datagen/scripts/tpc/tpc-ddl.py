# uv run --with sqlglot python3 -I tpc-ddl.py < schema.sql > schema-pg.sql: MySQL DDL from tpc-schema.sh -> Postgres.
# sqlglot transpiles each CREATE TABLE and each lfc formula; this script only moves the comments, which Postgres sets
# with COMMENT ON, and gives a table without a primary key REPLICA IDENTITY FULL, which CDC needs for it.
import re, sys
import sqlglot
from sqlglot import exp

def formula(e):   # integer division stays integer: MySQL's DIV is Postgres div(), which returns numeric
    t = sqlglot.parse_one(e, read="mysql").transform(lambda n: exp.cast(n, "bigint") if isinstance(n, exp.IntDiv) else n)
    return t.sql("postgres")

def tags(c):
    return "'" + re.sub(r"\{([^}]*)\}", lambda m: "{" + formula(m.group(1)) + "}", c).replace("'", "''") + "'"

for t in sqlglot.parse(sys.stdin.read(), read="mysql"):
    name = t.this.this.sql("postgres")
    comments = []
    for p in list(t.find_all(exp.SchemaCommentProperty)):
        comments.append(f"COMMENT ON TABLE {name} IS {tags(p.this.name)};"); p.pop()
    for c in t.find_all(exp.ColumnDef):
        for k in list(c.constraints):
            if isinstance(k.kind, exp.CommentColumnConstraint):
                comments.append(f"COMMENT ON COLUMN {name}.{c.name} IS {tags(k.kind.this.name)};"); k.pop()
    print(t.sql("postgres") + ";")
    print("\n".join(comments))
    if not t.find(exp.PrimaryKey):
        print(f"ALTER TABLE {name} REPLICA IDENTITY FULL;")
