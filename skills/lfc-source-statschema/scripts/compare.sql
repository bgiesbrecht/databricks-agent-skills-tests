-- duckdb -c "SET VARIABLE expected = 'expected.json'; SET VARIABLE actual = 'stats-target.json'; .read compare.sql"
-- The target's statistics (the collector, run on the generated copy after ANALYZE) against what shape.py aimed for:
-- rows, null fraction, distinct count, and the most common value's frequency. Prints only what's off by more than the
-- tolerance: null fraction and top frequency 0.02 (or 3 standard errors in a small table), distinct
-- count 20% (estimated from a sample).
CREATE TEMP TABLE e AS (
  SELECT t.name AS tbl, t.row_count AS rows, c.name AS col, c.null_fraction AS nf, c.n_distinct AS nd, c.top_frequency AS tf, c.median AS med, c.low AS lo, c.high AS hi
  FROM (SELECT unnest(tables) AS t FROM read_json(getvariable('expected'), maximum_object_size = 1000000000)) , unnest(t.columns) AS u(c)
);
CREATE TEMP TABLE a AS (
  SELECT t.name AS tbl, t.row_count AS rows, c.name AS col, c.null_fraction AS nf,
         CASE WHEN c.n_distinct < 0 THEN -c.n_distinct * t.row_count ELSE c.n_distinct END AS nd,
         c.most_common_values[1].frequency AS tf, c.histogram_bounds AS hb, c.most_common_values AS mcv
  FROM (SELECT unnest(tables) AS t FROM read_json(getvariable('actual'), maximum_object_size = 1000000000)), unnest(t.columns) AS u(c)
);
SELECT e.tbl, e.col, e.nf AS null_want, round(a.nf, 4) AS null_got,
       e.nd AS distinct_want, round(a.nd) AS distinct_got, e.tf AS top_want, round(a.tf, 4) AS top_got
FROM e LEFT JOIN a USING (tbl, col)
WHERE a.tbl IS NULL
   OR abs(coalesce(a.nf, 0) - coalesce(e.nf, 0)) > greatest(0.02, 3 * sqrt(e.nf * (1 - e.nf) / e.rows))
   OR (e.nd IS NOT NULL AND abs(a.nd - e.nd) > 0.2 * e.nd)
   OR (e.tf IS NOT NULL AND abs(coalesce(a.tf, 0) - e.tf) > greatest(0.02, 3 * sqrt(e.tf * (1 - e.tf) / e.rows)))
ORDER BY 1, 2;
-- histograms: the median of the copy's common values and histogram together, against the source's (as the integers the
-- casts use: numbers as is, dates as days since 1970), as a share of the source's range
CREATE TEMP MACRO num(x) AS coalesce(TRY_CAST(x AS DOUBLE), epoch(TRY_CAST(x AS TIMESTAMP)) / 86400);
ALTER TABLE a ADD COLUMN e_med VARCHAR;
UPDATE a SET e_med = e.med FROM e WHERE e.tbl = a.tbl AND e.col = a.col;
CREATE TEMP TABLE pts AS
  SELECT tbl, col, num(m.value) AS v, m.frequency AS w FROM a, unnest(a.mcv) AS u(m) WHERE e_med IS NOT NULL
  UNION ALL
  SELECT tbl, col, num(b), greatest(1 - coalesce(a.nf, 0) - coalesce(list_sum([m.frequency FOR m IN a.mcv]), 0), 0) / len(a.hb)
  FROM a, unnest(a.hb) AS u(b) WHERE e_med IS NOT NULL;
SELECT e.tbl, e.col, e.med AS median_want, m.med AS median_got, round(abs(m.med - num(e.med)) / nullif(num(e.hi) - num(e.lo), 0), 3) AS off_by
FROM e JOIN (SELECT tbl, col, min(v) FILTER (WHERE c >= t / 2) AS med
             FROM (SELECT *, sum(w) OVER (PARTITION BY tbl, col ORDER BY v) AS c, sum(w) OVER (PARTITION BY tbl, col) AS t FROM pts)
             GROUP BY tbl, col) m USING (tbl, col)
WHERE abs(m.med - num(e.med)) > greatest(0.05, 1 / sqrt(e.rows)) * (num(e.hi) - num(e.lo))   -- small tables: sampling noise
ORDER BY 1, 2;
-- tables whose row count is off (the statistics' estimate: InnoDB's can be several percent off; exact counts are in
-- the datagen status)
SELECT DISTINCT e.tbl, e.rows AS rows_want, a.rows AS rows_got FROM e JOIN a USING (tbl, col)
WHERE abs(a.rows - e.rows) > 0.1 * e.rows ORDER BY 1;
