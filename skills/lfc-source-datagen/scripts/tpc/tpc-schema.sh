# tpc-schema.sh <tpcb|tpch> [SF]: prints the workload's tables as MySQL DDL, with the lfc tags in the comments
# (cast.sql): lfc:rows= target, lfc:v={...} a column's value as an integer formula in x.n, lfc:n={...} n from a row (for
# composite keys, key formulas, and tables without a key), lfc:by={...} the column n rises with. Keys, foreign keys, and
# checks are the spec's; a table the spec gives no primary key has none. lfc-source-statschema's ddl-to-schema.py turns
# it into schema.yaml, and its ddl.py into any engine's DDL.
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
  # partsupp's key is read back from the spec's supplier formula, which needs 3 * (S/4 + 19) < S: at least 230 suppliers
  [ "$S" -ge 230 ] || { echo "tpc-schema.sh: TPC-H needs scale factor 0.03 or more (230 suppliers); got $SF" >&2; exit 1; }
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
