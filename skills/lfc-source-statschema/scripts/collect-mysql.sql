-- mysql -N -B -r -e "SET @db='shop', @vals='none'; SOURCE collect-mysql.sql" | jq -f mysql-normalize.jq > stats.json
--   (@vals: none | ranges | all; mysql-normalize.jq turns the raw catalog rows into the same format as the Postgres collector)
-- Reads only the catalog (information_schema): no table is scanned. Row counts and index cardinalities are InnoDB's
-- estimates (ANALYZE TABLE refreshes them). Null fractions, distinct counts, most common values, and value ranges of a column exist only where the DBA
-- has built a histogram (ANALYZE TABLE t UPDATE HISTOGRAM ON c1, c2 WITH 100 BUCKETS samples the table once; columns with
-- no histogram and no index get only their type). @vals as in the Postgres collector: histograms hold real data values.
-- Field names follow statschema's stats.yaml. Needs SELECT on the tables (information_schema shows only what you can see).
SET SESSION group_concat_max_len = 16777216;
SET SESSION information_schema_stats_expiry = 0;            -- else row counts are cached for up to a day
SET @vals = COALESCE(@vals, 'none');
WITH h AS (                                                -- histograms: one row per bucket
  SELECT cs.table_name, cs.column_name, cs.histogram->>'$."histogram-type"' AS htype,
         CAST(cs.histogram->>'$."null-values"' AS DOUBLE) AS null_frac, b.i, b.v1, b.v2,
         -- singleton buckets are [value, cumulative frequency]; equi-height ones [low, high, cumulative frequency, distinct]
         IF(cs.histogram->>'$."histogram-type"' = 'singleton', CAST(b.v2 AS DOUBLE), b.c3) AS cum, b.nd
  FROM (SELECT schema_name, table_name, column_name, histogram FROM information_schema.column_statistics
        WHERE schema_name = @db LIMIT 1000000000) cs,    -- materialized: JSON_TABLE can't read the information_schema view
       JSON_TABLE(cs.histogram, '$.buckets[*]' COLUMNS (i FOR ORDINALITY, v1 TEXT PATH '$[0]', v2 TEXT PATH '$[1]',
                                                        c3 DOUBLE PATH '$[2]', nd DOUBLE PATH '$[3]')) b
), hb AS (                                                 -- bucket frequency (buckets hold cumulative frequencies)
  SELECT h.*, cum - COALESCE(LAG(cum) OVER (PARTITION BY table_name, column_name ORDER BY i), 0) AS freq FROM h
), hc AS (
  SELECT table_name, column_name, MAX(htype) AS htype, MAX(null_frac) AS null_frac, COUNT(*) AS buckets,
         IF(MAX(htype) = 'singleton', COUNT(*), SUM(nd)) AS n_distinct,
         MIN(IF(i = 1, v1, NULL)) AS lo, MAX(IF(i = (SELECT MAX(i) FROM h h2 WHERE h2.table_name = hb.table_name AND h2.column_name = hb.column_name),
                                             IF(htype = 'singleton', v1, v2), NULL)) AS hi,
         IF(MAX(htype) = 'singleton', JSON_ARRAYAGG(JSON_OBJECT('i', i, 'v', v1, 'f', ROUND(freq, 6))), NULL) AS mcv,
         IF(MAX(htype) = 'equi-height', JSON_ARRAYAGG(JSON_ARRAY(i, v1, v2)), NULL) AS bounds
  FROM hb GROUP BY table_name, column_name
), ix AS (                                                 -- distinct count of a column that leads an index
  SELECT table_name, column_name, MAX(cardinality) AS card FROM information_schema.statistics
  WHERE table_schema = @db AND seq_in_index = 1 GROUP BY table_name, column_name
), col AS (
  SELECT c.table_name,
         JSON_ARRAYAGG(JSON_OBJECT(
           'pos', c.ordinal_position, 'name', c.column_name, 'data_type', c.column_type, 'nullable', c.is_nullable = 'YES',
           'null_fraction', hc.null_frac, 'n_distinct', COALESCE(hc.n_distinct, ix.card),
           'min_value', IF(@vals = 'all' OR (@vals = 'ranges' AND c.data_type IN ('tinyint', 'smallint', 'mediumint', 'int', 'bigint', 'decimal',
                           'float', 'double', 'date', 'datetime', 'timestamp', 'time', 'year')), hc.lo, NULL),
           'max_value', IF(@vals = 'all' OR (@vals = 'ranges' AND c.data_type IN ('tinyint', 'smallint', 'mediumint', 'int', 'bigint', 'decimal',
                           'float', 'double', 'date', 'datetime', 'timestamp', 'time', 'year')), hc.hi, NULL),
           'histogram_type', hc.htype, 'histogram_buckets', hc.buckets,
           'mcv_raw', hc.mcv, 'bounds_raw', IF(@vals = 'all' OR (@vals = 'ranges' AND c.data_type IN ('tinyint', 'smallint', 'mediumint', 'int',
                           'bigint', 'decimal', 'float', 'double', 'date', 'datetime', 'timestamp', 'time', 'year')), hc.bounds, NULL),
           'keep_values', @vals = 'all' OR (@vals = 'ranges' AND c.data_type IN ('tinyint', 'smallint', 'mediumint', 'int', 'bigint', 'decimal',
                           'float', 'double', 'date', 'datetime', 'timestamp', 'time', 'year')))) AS columns
  FROM information_schema.columns c
  LEFT JOIN hc ON hc.table_name = c.table_name AND hc.column_name = c.column_name
  LEFT JOIN ix ON ix.table_name = c.table_name AND ix.column_name = c.column_name
  WHERE c.table_schema = @db GROUP BY c.table_name
), k AS (                                                  -- primary key, unique keys, foreign keys
  SELECT tc.table_name, tc.constraint_type, tc.constraint_name,
         JSON_ARRAYAGG(JSON_ARRAY(u.ordinal_position, u.column_name, u.referenced_table_name, u.referenced_column_name)) AS cols
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage u ON u.constraint_schema = tc.constraint_schema AND u.table_name = tc.table_name
                                             AND u.constraint_name = tc.constraint_name
  WHERE tc.constraint_schema = @db AND tc.constraint_type IN ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY')
  GROUP BY tc.table_name, tc.constraint_type, tc.constraint_name
)
SELECT JSON_OBJECT('version', '1', 'source_dialect', 'mysql', 'source_version', VERSION(), 'schema', @db, 'values', @vals,
         'collected_at', NOW(),
         'tables', (SELECT JSON_ARRAYAGG(JSON_OBJECT(
           'name', t.table_name, 'row_count', t.table_rows, 'size_bytes', t.data_length + t.index_length, 'comment', t.table_comment,
           'avg_row_bytes', t.avg_row_length,
           'keys', (SELECT JSON_ARRAYAGG(JSON_OBJECT('type', k.constraint_type, 'cols', k.cols)) FROM k WHERE k.table_name = t.table_name),
           'checks', (SELECT JSON_ARRAYAGG(cc.check_clause) FROM information_schema.table_constraints tc
                      JOIN information_schema.check_constraints cc ON cc.constraint_schema = tc.constraint_schema AND cc.constraint_name = tc.constraint_name
                      WHERE tc.constraint_schema = @db AND tc.table_name = t.table_name AND tc.constraint_type = 'CHECK'),
           'indexes', (SELECT JSON_ARRAYAGG(s.cols) FROM (SELECT index_name, JSON_ARRAYAGG(JSON_ARRAY(seq_in_index, column_name)) AS cols
                       FROM information_schema.statistics WHERE table_schema = @db AND table_name = t.table_name AND non_unique = 1
                       GROUP BY index_name) s),
           'columns', col.columns))
           FROM information_schema.tables t JOIN col ON col.table_name = t.table_name
           WHERE t.table_schema = @db AND t.table_type = 'BASE TABLE'));
