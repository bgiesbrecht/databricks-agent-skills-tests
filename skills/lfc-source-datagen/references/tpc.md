# TPC schemas

Most people don't know what schema to test with. The TPC benchmarks define well-known ones, with exact row counts per scale factor, keys, foreign keys, and check constraints. This reference builds them with the planners in [postgres.md](postgres.md) and [mysql.md](mysql.md): the **sizes, keys, foreign keys, and constraints follow the spec**, and so do the spec's key formulas and value ranges, but the data comes from the planners' casts, not from TPC's `dbgen`, so text columns (names, comments, flags) don't use the spec's word lists. The benchmark queries run, but their answers won't match TPC's. This is "a TPC-H schema filled by lfc-source-datagen", never a TPC result (TPC's fair-use policy).

| Workload | Spec | Tables | Status |
|---|---|---|---|
| TPC-B (also TPC-A: the same 4 tables) | 2.0.0 | branch, teller, account, history | ✓ Postgres 16 and MySQL 8.4 |
| TPC-H (also TPC-D 2.1.0 and TPC-R 2.1.0: the same 8 tables) | 3.0.1 | region, nation, supplier, part, partsupp, customer, orders, lineitem | ✓ Postgres 16 and MySQL 8.4 |
| TPC-C | 5.11.0 | 9 tables, composite keys per warehouse | Next |
| TPC-W / TPC-APP | 2.0.0 / 1.3.0 | 8-table online bookstore | Planned |
| TPC-DS | 4.0.0 | 7 fact and 17 dimension tables | Planned (row counts per scale factor need parsing from the spec) |
| TPC-DI | 1.1.0 | warehouse Dim and Fact tables with history rows | Planned |
| TPC-E | 1.14.0 | 33 tables | Planned |
| TPC-VMS, TPCx-* | | No schema of their own (VMS runs C, E, H, DS; HS is a sort, IoT key-value, AI files; BB is DS plus logs; V is based on E) | Not applicable |

The specs are free PDFs at `https://www.tpc.org/TPC_Documents_Current_Versions/pdf/<name>.pdf` (for example `TPC-H_v3.0.1.pdf`); only the tools need TPC's download form, and these schemas don't use them.

## How the spec maps onto the planners

The planners need each row to come from one integer `n`. Three comment tags let a schema say how, so no planner code is specific to a workload:

| Tag | On | Meaning | Example |
|---|---|---|---|
| `lfc:v={formula}` | a column | The column's value is its usual cast of this integer formula in `x.n`, instead of `n` or scrambled `n`. Never scrambled; the audit checks it against the formula | `o_orderkey`: `((x.n - 1) DIV 8) * 32 + (x.n - 1) % 8 + 1` (the spec's sparse keys); `l_discount`: `h(n) % 11` (0.00 … 0.10) |
| `lfc:n={formula}` | a table | `n` back from a row, for a composite key, a key from a formula, or a table without a primary key | `lineitem`: `(((l_orderkey - 1) DIV 32) * 8 + (l_orderkey - 1) % 32) * 4 + l_linenumber` |
| `lfc:by={column}` | a table | The column `n` rises with, for the min and max probes (default: the first key column); the probes read the rows with the highest (lowest) value of it and take the max (min) of `lfc:n` | `history` (no key): `h_time` |

`n` must rise with the `lfc:by` column (rows sharing a value can come in any order: a `partsupp` part's 4 suppliers). Formulas use only integer arithmetic, `DIV`, `%`, and `CASE`, so they mean the same on every engine; `h(e, a)` in `tpc-schema.sh` is the non-linear scramble `(e mod p)((e mod p + a) mod p) mod p`, `p = 2³¹ − 1`, for the spec's "random value" columns, the same on every run.

Rules that follow from the spec:

- **Tables the spec gives no primary key keep none** (TPC-B's `history`; TPC-C's `history` too). On Postgres they get `REPLICA IDENTITY FULL`, which CDC needs for such tables, as customers' keyless tables do. Their min and max probes scan the table unless the `lfc:by` column has an index; add a plain index for large ones (an index, not a key).
- **Parents first, completely.** A formula like `l_partkey = 1 + h(n) % 200000` assumes `part` is full, so `fill.sh` (in the skill's "Fill level by level") fills one level at a time and moves on only when every table of the level is at its target.
- **Not yet:** deletes. The delete planners skip tables with `lfc:n` and parents whose children's foreign key is part of the child's key or has a formula (re-pointing those would change a key). TPC-H's refresh functions (RF1, RF2) would delete an order with its lines; that's the next step.

Where it differs from the spec:

| Spec | Here | Why |
|---|---|---|
| TPC-H `lineitem`: 1 to 7 lines per order, random (6,001,215 at SF 1) | Exactly 4 (6,000,000 at SF 1) | `n` maps to (order, line) only with a fixed count |
| TPC-H `o_totalprice`, `o_orderstatus`, `l_returnflag`, `l_linestatus`: derived from other rows and dates | Ordinary casts (non-negative, the right type and length) | Derived from other rows; not needed for size or constraints |
| Text columns (`p_name`, `c_phone`, comments, …): word lists and formats | Zero-padded `n` and MD5 filler, at the declared length | The planners' auditable strings |
| TPC-B `history` size: storage for the measurement interval | `HISTORY` rows (default: as many as accounts) | The spec ties it to the benchmark run |
| TPC-B `h_delta`: the transaction's amount | `n` / 100 | Gives `history`, which has no key, a column that maps back to `n` |

## Files

Create these in one directory (each block writes one file).

### tpc-schema.sh

The workloads as MySQL DDL with the tags; `bash tpc-schema.sh tpch 10` for scale factor 10.

```bash
cat > tpc-schema.sh <<'TPC_EOF'
# tpc-schema.sh <tpcb|tpch> [SF]: prints the workload's tables as MySQL DDL, with the lfc tags in the comments
# (cast.sql): lfc:rows= target, lfc:v={...} a column's value as an integer formula in x.n, lfc:n={...} n from a row (for
# composite keys, key formulas, and tables without a key), lfc:by={...} the column n rises with. Keys, foreign keys, and
# checks are the spec's; a table the spec gives no primary key has none. tpc-ddl.py turns it into Postgres DDL.
# Formulas use only integer arithmetic, DIV, %, and CASE, which transpile exactly.
W=$1; SF=${2:-1}
calc() { awk "BEGIN { printf \"%d\", $1 }"; }
# h e a: a non-linear scramble of integer expression e (constant a), 0 .. 2^31 - 2, the same on every engine
h() { echo "((($1) % 2147483647) * ((($1) % 2147483647 + $2) % 2147483647) % 2147483647)"; }
case $W in
tpcb)   # per branch: 10 tellers and 100,000 accounts (clause 4.2); records padded to the minimum lengths (clause 3.2)
  B=$(calc "$SF"); T=$((B * 10)); A=$((B * 100000)); H=$(calc "${HISTORY:-$A}")
  cat <<EOF
CREATE TABLE branch (b_id int NOT NULL, b_balance decimal(12,2) NOT NULL, b_filler char(88),
  PRIMARY KEY (b_id)) COMMENT='lfc:rows=$B';
CREATE TABLE teller (t_id int NOT NULL, t_b_id int NOT NULL COMMENT 'lfc:v={(x.n - 1) DIV 10 + 1}',
  t_balance decimal(12,2) NOT NULL, t_filler char(84),
  PRIMARY KEY (t_id), FOREIGN KEY (t_b_id) REFERENCES branch (b_id)) COMMENT='lfc:rows=$T';
CREATE TABLE account (a_id int NOT NULL, a_b_id int NOT NULL COMMENT 'lfc:v={(x.n - 1) DIV 100000 + 1}',
  a_balance decimal(12,2) NOT NULL, a_filler char(84),
  PRIMARY KEY (a_id), FOREIGN KEY (a_b_id) REFERENCES branch (b_id)) COMMENT='lfc:rows=$A';
CREATE TABLE history (h_t_id int NOT NULL COMMENT 'lfc:v={1 + $(h x.n 101) % $T}',
  h_b_id int NOT NULL COMMENT 'lfc:v={($(h x.n 101) % $T) DIV 10 + 1}',
  h_a_id int NOT NULL COMMENT 'lfc:v={1 + $(h x.n 103) % $A}',
  h_delta decimal(12,2) NOT NULL COMMENT 'lfc:v={x.n}', h_time datetime NOT NULL COMMENT 'lfc:v={1700000000 + x.n}', h_filler char(22),
  FOREIGN KEY (h_t_id) REFERENCES teller (t_id), FOREIGN KEY (h_b_id) REFERENCES branch (b_id),
  FOREIGN KEY (h_a_id) REFERENCES account (a_id)) COMMENT='lfc:rows=$H lfc:n={CAST(h_delta * 100 AS SIGNED)} lfc:by={h_time}';
EOF
  ;;
tpch)   # clause 1.4 layouts, 1.4.2 constraints, 4.2.3 population; LINEITEM has 4 lines per order (the spec: 1 to 7, random)
  S=$(calc "$SF * 10000"); P=$(calc "$SF * 200000"); C=$(calc "$SF * 150000"); O=$(calc "$SF * 1500000")
  ok="(x.n - 1) DIV 4 + 1"                                              # a line's order number
  odate="8035 + $(h "$ok" 11) % 2406"                                   # 1992-01-01 .. 1998-08-02 (ENDDATE - 151)
  lpk="(1 + $(h x.n 13) % $P)"
  ship="$odate + 1 + $(h x.n 17) % 121"
  cat <<EOF
CREATE TABLE region (r_regionkey int NOT NULL COMMENT 'lfc:v={x.n - 1}', r_name char(25) NOT NULL, r_comment varchar(152),
  PRIMARY KEY (r_regionkey), CHECK (r_regionkey >= 0)) COMMENT='lfc:rows=5 lfc:n={r_regionkey + 1}';
CREATE TABLE nation (n_nationkey int NOT NULL COMMENT 'lfc:v={x.n - 1}', n_name char(25) NOT NULL,
  n_regionkey int NOT NULL COMMENT 'lfc:v={CASE x.n - 1 WHEN 0 THEN 0 WHEN 1 THEN 1 WHEN 2 THEN 1 WHEN 3 THEN 1 WHEN 4 THEN 4 WHEN 5 THEN 0 WHEN 6 THEN 3 WHEN 7 THEN 3 WHEN 8 THEN 2 WHEN 9 THEN 2 WHEN 10 THEN 4 WHEN 11 THEN 4 WHEN 12 THEN 2 WHEN 13 THEN 4 WHEN 14 THEN 0 WHEN 15 THEN 0 WHEN 16 THEN 0 WHEN 17 THEN 1 WHEN 18 THEN 2 WHEN 19 THEN 3 WHEN 20 THEN 4 WHEN 21 THEN 2 WHEN 22 THEN 3 WHEN 23 THEN 3 ELSE 1 END}',
  n_comment varchar(152),
  PRIMARY KEY (n_nationkey), FOREIGN KEY (n_regionkey) REFERENCES region (r_regionkey), CHECK (n_nationkey >= 0))
  COMMENT='lfc:rows=25 lfc:n={n_nationkey + 1}';
CREATE TABLE supplier (s_suppkey int NOT NULL, s_name char(25) NOT NULL, s_address varchar(40) NOT NULL,
  s_nationkey int NOT NULL COMMENT 'lfc:v={$(h x.n 19) % 25}', s_phone char(15) NOT NULL,
  s_acctbal decimal(15,2) NOT NULL COMMENT 'lfc:v={$(h x.n 23) % 1099999 - 99999}', s_comment varchar(101) NOT NULL,
  PRIMARY KEY (s_suppkey), FOREIGN KEY (s_nationkey) REFERENCES nation (n_nationkey), CHECK (s_suppkey >= 0))
  COMMENT='lfc:rows=$S';
CREATE TABLE part (p_partkey int NOT NULL, p_name varchar(55) NOT NULL, p_mfgr char(25) NOT NULL, p_brand char(10) NOT NULL,
  p_type varchar(25) NOT NULL, p_size int NOT NULL COMMENT 'lfc:v={1 + $(h x.n 29) % 50}', p_container char(10) NOT NULL,
  p_retailprice decimal(15,2) NOT NULL COMMENT 'lfc:v={90000 + (x.n DIV 10) % 20001 + 100 * (x.n % 1000)}', p_comment varchar(23) NOT NULL,
  PRIMARY KEY (p_partkey), CHECK (p_partkey >= 0), CHECK (p_size >= 0), CHECK (p_retailprice >= 0)) COMMENT='lfc:rows=$P';
CREATE TABLE partsupp (ps_partkey int NOT NULL COMMENT 'lfc:v={(x.n - 1) DIV 4 + 1}',
  ps_suppkey int NOT NULL COMMENT 'lfc:v={(((x.n - 1) DIV 4 + 1) + ((x.n - 1) % 4) * ($S DIV 4 + ((x.n - 1) DIV 4) DIV $S)) % $S + 1}',
  ps_availqty int NOT NULL COMMENT 'lfc:v={1 + $(h x.n 31) % 9999}',
  ps_supplycost decimal(15,2) NOT NULL COMMENT 'lfc:v={100 + $(h x.n 37) % 99901}', ps_comment varchar(199) NOT NULL,
  PRIMARY KEY (ps_partkey, ps_suppkey), FOREIGN KEY (ps_partkey) REFERENCES part (p_partkey),
  FOREIGN KEY (ps_suppkey) REFERENCES supplier (s_suppkey),
  CHECK (ps_partkey >= 0), CHECK (ps_availqty >= 0), CHECK (ps_supplycost >= 0))
  COMMENT='lfc:rows=$((P * 4)) lfc:n={(ps_partkey - 1) * 4 + ((ps_suppkey - 1 - ps_partkey) % $S + $S) % $S DIV ($S DIV 4 + (ps_partkey - 1) DIV $S) + 1}';
CREATE TABLE customer (c_custkey int NOT NULL, c_name varchar(25) NOT NULL, c_address varchar(40) NOT NULL,
  c_nationkey int NOT NULL COMMENT 'lfc:v={$(h x.n 41) % 25}', c_phone char(15) NOT NULL,
  c_acctbal decimal(15,2) NOT NULL COMMENT 'lfc:v={$(h x.n 43) % 1099999 - 99999}', c_mktsegment char(10) NOT NULL,
  c_comment varchar(117) NOT NULL,
  PRIMARY KEY (c_custkey), FOREIGN KEY (c_nationkey) REFERENCES nation (n_nationkey), CHECK (c_custkey >= 0))
  COMMENT='lfc:rows=$C';
CREATE TABLE orders (o_orderkey bigint NOT NULL COMMENT 'lfc:v={((x.n - 1) DIV 8) * 32 + (x.n - 1) % 8 + 1}',
  o_custkey int NOT NULL COMMENT 'lfc:v={(($(h x.n 47) % $((C * 2 / 3))) DIV 2) * 3 + $(h x.n 47) % 2 + 1}',
  o_orderstatus char(1) NOT NULL, o_totalprice decimal(15,2) NOT NULL,
  o_orderdate date NOT NULL COMMENT 'lfc:v={8035 + $(h x.n 11) % 2406}', o_orderpriority char(15) NOT NULL,
  o_clerk char(15) NOT NULL, o_shippriority int NOT NULL COMMENT 'lfc:v={0}', o_comment varchar(79) NOT NULL,
  PRIMARY KEY (o_orderkey), FOREIGN KEY (o_custkey) REFERENCES customer (c_custkey), CHECK (o_totalprice >= 0))
  COMMENT='lfc:rows=$O lfc:n={((o_orderkey - 1) DIV 32) * 8 + (o_orderkey - 1) % 32 + 1}';
CREATE TABLE lineitem (l_orderkey bigint NOT NULL COMMENT 'lfc:v={((($ok) - 1) DIV 8) * 32 + (($ok) - 1) % 8 + 1}',
  l_partkey int NOT NULL COMMENT 'lfc:v={$lpk}',
  l_suppkey int NOT NULL COMMENT 'lfc:v={($lpk + ($(h x.n 53) % 4) * ($S DIV 4 + ($lpk - 1) DIV $S)) % $S + 1}',
  l_linenumber int NOT NULL COMMENT 'lfc:v={(x.n - 1) % 4 + 1}',
  l_quantity decimal(15,2) NOT NULL COMMENT 'lfc:v={100 * (1 + $(h x.n 59) % 50)}',
  l_extendedprice decimal(15,2) NOT NULL COMMENT 'lfc:v={(1 + $(h x.n 59) % 50) * (90000 + ($lpk DIV 10) % 20001 + 100 * ($lpk % 1000))}',
  l_discount decimal(15,2) NOT NULL COMMENT 'lfc:v={$(h x.n 61) % 11}', l_tax decimal(15,2) NOT NULL COMMENT 'lfc:v={$(h x.n 67) % 9}',
  l_returnflag char(1) NOT NULL, l_linestatus char(1) NOT NULL,
  l_shipdate date NOT NULL COMMENT 'lfc:v={$ship}', l_commitdate date NOT NULL COMMENT 'lfc:v={$odate + 30 + $(h x.n 71) % 61}',
  l_receiptdate date NOT NULL COMMENT 'lfc:v={$ship + 1 + $(h x.n 73) % 30}',
  l_shipinstruct char(25) NOT NULL, l_shipmode char(10) NOT NULL, l_comment varchar(44) NOT NULL,
  PRIMARY KEY (l_orderkey, l_linenumber), FOREIGN KEY (l_orderkey) REFERENCES orders (o_orderkey),
  FOREIGN KEY (l_partkey) REFERENCES part (p_partkey), FOREIGN KEY (l_suppkey) REFERENCES supplier (s_suppkey),
  FOREIGN KEY (l_partkey, l_suppkey) REFERENCES partsupp (ps_partkey, ps_suppkey),
  CHECK (l_quantity >= 0), CHECK (l_extendedprice >= 0), CHECK (l_tax >= 0), CHECK (l_discount BETWEEN 0.00 AND 1.00),
  CHECK (l_shipdate <= l_receiptdate))
  COMMENT='lfc:rows=$((O * 4)) lfc:n={((((l_orderkey - 1) DIV 32) * 8 + (l_orderkey - 1) % 32) * 4 + l_linenumber)}';
EOF
  ;;
*) echo "unknown workload: $W" >&2; exit 1 ;;
esac
TPC_EOF
```

### tpc-ddl.py

MySQL DDL to Postgres with sqlglot.

```bash
cat > tpc-ddl.py <<'TPC_EOF'
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
TPC_EOF
```

### tpcb-verify.sql

TPC-B checks.

```bash
cat > tpcb-verify.sql <<'TPC_EOF'
-- tpcb-verify.sql: TPC-B scaling (clause 4.2) and relationships, checked on the data; every "bad" should be 0.
SELECT 'rows branch teller account history', (SELECT COUNT(*) FROM branch), (SELECT COUNT(*) FROM teller), (SELECT COUNT(*) FROM account), (SELECT COUNT(*) FROM history);
SELECT 'bad: tellers per branch <> 10', COUNT(*) FROM (SELECT t_b_id FROM teller GROUP BY t_b_id HAVING COUNT(*) <> 10) x;
SELECT 'bad: accounts per branch <> 100000', COUNT(*) FROM (SELECT a_b_id FROM account GROUP BY a_b_id HAVING COUNT(*) <> 100000) x;
SELECT 'bad: history branch is not its teller''s', COUNT(*) FROM history h JOIN teller t ON t.t_id = h.h_t_id WHERE t.t_b_id <> h.h_b_id;
TPC_EOF
```

### tpch-verify.sql

TPC-H checks.

```bash
cat > tpch-verify.sql <<'TPC_EOF'
-- tpch-verify.sql (MySQL; for Postgres: sed -E 's/DATEDIFF\(([^,]+), ([^)]+)\)/(\1 - \2)/g'): the spec's population rules (TPC-H clause 4.2.3) and keys, checked on the data; every "bad" should be 0.
SELECT 'rows region nation supplier part partsupp customer orders lineitem',
  (SELECT COUNT(*) FROM region), (SELECT COUNT(*) FROM nation), (SELECT COUNT(*) FROM supplier), (SELECT COUNT(*) FROM part),
  (SELECT COUNT(*) FROM partsupp), (SELECT COUNT(*) FROM customer), (SELECT COUNT(*) FROM orders), (SELECT COUNT(*) FROM lineitem);
SELECT 'keys 0..4, 0..24; bad nation->region', (SELECT MIN(r_regionkey) FROM region), (SELECT MAX(r_regionkey) FROM region),
  (SELECT MIN(n_nationkey) FROM nation), (SELECT MAX(n_nationkey) FROM nation),
  (SELECT COUNT(*) FROM nation WHERE n_regionkey <> CASE WHEN n_nationkey IN (0, 5, 14, 15, 16) THEN 0 WHEN n_nationkey IN (1, 2, 3, 17, 24) THEN 1
     WHEN n_nationkey IN (8, 9, 12, 18, 21) THEN 2 WHEN n_nationkey IN (6, 7, 19, 22, 23) THEN 3 ELSE 4 END);
SELECT 'bad: sparse orderkey, custkey%3=0, orderdate range', (SELECT COUNT(*) FROM orders WHERE (o_orderkey - 1) % 32 >= 8),
  (SELECT COUNT(*) FROM orders WHERE o_custkey % 3 = 0),
  (SELECT COUNT(*) FROM orders WHERE o_orderdate < DATE '1992-01-01' OR o_orderdate > DATE '1998-08-02');
SELECT 'bad: partsupp 4 distinct suppliers per part', COUNT(*) FROM (SELECT ps_partkey FROM partsupp GROUP BY ps_partkey HAVING COUNT(DISTINCT ps_suppkey) <> 4) x;
SELECT 'bad: lines per order', COUNT(*) FROM (SELECT l_orderkey FROM lineitem GROUP BY l_orderkey HAVING COUNT(*) <> 4) x;
SELECT 'bad: lineitem->partsupp, extendedprice, qty, discount, tax', COUNT(*) - COUNT(ps.ps_partkey),
  SUM(CASE WHEN l.l_extendedprice <> l.l_quantity * p.p_retailprice THEN 1 ELSE 0 END),
  SUM(CASE WHEN l.l_quantity NOT BETWEEN 1 AND 50 THEN 1 ELSE 0 END), SUM(CASE WHEN l.l_discount NOT BETWEEN 0 AND 0.10 THEN 1 ELSE 0 END),
  SUM(CASE WHEN l.l_tax NOT BETWEEN 0 AND 0.08 THEN 1 ELSE 0 END)
FROM lineitem l LEFT JOIN partsupp ps ON ps.ps_partkey = l.l_partkey AND ps.ps_suppkey = l.l_suppkey JOIN part p ON p.p_partkey = l.l_partkey;
SELECT 'bad: retailprice formula, size 1..50', SUM(CASE WHEN p_retailprice * 100 <> 90000 + (p_partkey / 10 - (p_partkey / 10) % 1) % 20001 + 100 * (p_partkey % 1000) THEN 1 ELSE 0 END),
  SUM(CASE WHEN p_size NOT BETWEEN 1 AND 50 THEN 1 ELSE 0 END) FROM part;
SELECT 'bad: ship = order+1..121, commit = order+30..90, receipt = ship+1..30',
  SUM(CASE WHEN DATEDIFF(l.l_shipdate, o.o_orderdate) NOT BETWEEN 1 AND 121 THEN 1 ELSE 0 END),
  SUM(CASE WHEN DATEDIFF(l.l_commitdate, o.o_orderdate) NOT BETWEEN 30 AND 90 THEN 1 ELSE 0 END),
  SUM(CASE WHEN DATEDIFF(l.l_receiptdate, l.l_shipdate) NOT BETWEEN 1 AND 30 THEN 1 ELSE 0 END)
FROM lineitem l JOIN orders o ON o.o_orderkey = l.l_orderkey;
TPC_EOF
```

## Run

`tpc-schema.sh` writes a workload's tables as MySQL DDL, with the tags in the column and table comments; for Postgres, `tpc-ddl.py` transpiles it with [sqlglot](https://github.com/tobymao/sqlglot) (each `CREATE TABLE`, and each formula, so `DIV` stays integer division) and moves the comments to `COMMENT ON`. Then `fill.sh` (in the skill's "Fill level by level") fills it with the engine's planners, one level at a time, and the verify file checks the spec's rules on the data.

```bash
# Postgres: schema tpch at scale factor 1 (8.66M rows)
{ echo "CREATE SCHEMA tpch; SET search_path = tpch;"; bash tpc-schema.sh tpch 1 | uv run -q --with sqlglot python3 -I tpc-ddl.py; } | psql -v ON_ERROR_STOP=1
DIR=pg bash fill.sh pg tpch
{ echo "SET search_path = tpch;"; sed -E 's/DATEDIFF\(([^,]+), ([^)]+)\)/(\1 - \2)/g' tpch-verify.sql; } | psql -At
# MySQL: database tpch
{ echo "CREATE DATABASE tpch; USE tpch;"; bash tpc-schema.sh tpch 1; } | mysql
DIR=my bash fill.sh my tpch
mysql -N tpch < tpch-verify.sql
```

Then the engine's audit (`plan-audit` with `plain_every=4`) checks every column with a formula and every plain block: 0 bad rows. The planner files come from [postgres.md](postgres.md) or [mysql.md](mysql.md), created in the `pg` or `my` directory, and both need the seed table `lfc_seed.seed` with its random column `r`.

## Measured (4 vCPUs, Podman VM, Postgres 16 and MySQL 8.4, one engine at a time)

| Workload | Rows | Postgres fill | MySQL fill | Checks |
|---|---|---|---|---|
| TPC-B, scale 10 | 2,000,110 | 23 s | 1 min 25 s | 10 tellers and 100,000 accounts per branch; every history row's branch is its teller's; `history` has no primary key (Postgres: replica identity FULL); audit 0 bad on both |
| TPC-H, SF 1 | 8,660,030 | 3 min 39 s | 38 min 30 s | Exact row counts; region and nation keys 0 … 4 and 0 … 24 with the spec's nation-to-region map; sparse order keys; `o_custkey % 3 <> 0`; 4 distinct suppliers per part; every line's (part, supplier) in `partsupp`; `l_extendedprice = l_quantity × p_retailprice`; the spec's retail price formula; quantity, discount, and tax ranges; ship, commit, and receipt dates within the spec's days of the order date; audit 0 bad, on both engines |

Postgres ran 1M-row statements and MySQL 100k (see [calibrate.md](calibrate.md)). Lineitem dominates: one table, so one session, with five foreign keys and a composite key checked per row. MySQL took 10 times as long, waiting on the disk; InnoDB stores rows in key order, so `order=random` (the default) splits pages across lineitem's whole clustered key. Try `ORDER=asc` for a large MySQL load (not measured yet).
