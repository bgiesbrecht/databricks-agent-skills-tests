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
