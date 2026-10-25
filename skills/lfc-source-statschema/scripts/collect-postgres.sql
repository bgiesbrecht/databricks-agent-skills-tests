-- psql -X -At -v schema=public [-v values=none|ranges|all] -f collect-postgres.sql > stats.json
-- Reads only the catalog and the planner's statistics (pg_class, pg_stats, pg_constraint, pg_index): no table is scanned, so
-- it is as cheap on 10,000 tables as on 10. Statistics are as fresh as the last ANALYZE (autovacuum runs it; run ANALYZE
-- for exact numbers). Values: pg_stats holds real data values (most common values, histogram bounds), so
--   values=none (default): no data values at all, only their shape: frequencies, distinct counts, null fractions, widths
--   values=ranges: also min and max, and histogram bounds, for numeric and date/time columns; no text values
--   values=all: also the most common values and histogram bounds of every column
-- Field names follow statschema's stats.yaml. Needs SELECT on pg_stats rows for the tables (the table owner, or
-- pg_read_all_stats).
\if :{?values} \else \set values none \endif
WITH c AS (
  SELECT r.oid, r.relname, a.attnum, a.attname, format_type(a.atttypid, a.atttypmod) AS data_type, t.typcategory, a.attnotnull,
         CASE a.attgenerated WHEN 's' THEN 'stored' WHEN 'v' THEN 'virtual' END AS generated,
         s.null_frac, s.n_distinct, s.avg_width, s.correlation,
         s.most_common_vals::text::text[] AS mcv, s.most_common_freqs AS mcf, s.histogram_bounds::text::text[] AS hist
  FROM pg_class r
  JOIN pg_namespace n ON n.oid = r.relnamespace AND n.nspname = :'schema'
  JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped
  JOIN pg_type t ON t.oid = a.atttypid
  LEFT JOIN pg_stats s ON s.schemaname = n.nspname AND s.tablename = r.relname AND s.attname = a.attname AND NOT s.inherited
  WHERE r.relkind IN ('r', 'p')
), col AS (
  SELECT oid, json_agg(json_strip_nulls(json_build_object(
           'name', attname, 'data_type', data_type, 'nullable', NOT attnotnull, 'generated', generated,
           'null_fraction', null_frac, 'n_distinct', n_distinct, 'avg_width_bytes', avg_width, 'correlation', round(correlation::numeric, 4),
           'min_value', CASE WHEN :'values' <> 'none' AND (typcategory IN ('N', 'D') OR :'values' = 'all') THEN coalesce(hist[1], (SELECT v FROM unnest(mcv) v ORDER BY CASE WHEN typcategory = 'N' THEN v::numeric END, v LIMIT 1)) END,
           'max_value', CASE WHEN :'values' <> 'none' AND (typcategory IN ('N', 'D') OR :'values' = 'all') THEN coalesce(hist[cardinality(hist)], (SELECT v FROM unnest(mcv) v ORDER BY CASE WHEN typcategory = 'N' THEN v::numeric END DESC, v DESC LIMIT 1)) END,
           'most_common_values', (SELECT json_agg(json_build_object('value', CASE WHEN :'values' = 'all' OR (:'values' = 'ranges' AND typcategory IN ('N', 'D')) THEN v END,
                                                                     'frequency', round(f::numeric, 6)) ORDER BY i)
                                  FROM unnest(mcv, mcf) WITH ORDINALITY AS m(v, f, i)),
           'histogram_bounds', CASE WHEN :'values' = 'all' OR (:'values' = 'ranges' AND typcategory IN ('N', 'D')) THEN to_json(hist) END,
           'histogram_buckets', CASE WHEN hist IS NOT NULL THEN cardinality(hist) - 1 END)) ORDER BY attnum) AS columns
  FROM c GROUP BY oid
)
SELECT json_build_object('version', '1', 'source_dialect', 'postgres', 'source_version', current_setting('server_version'),
         'schema', :'schema', 'values', :'values', 'collected_at', now(),
         'tables', json_agg(json_strip_nulls(json_build_object(
           'name', r.relname, 'row_count', greatest(r.reltuples, 0)::bigint, 'size_bytes', pg_table_size(r.oid), 'comment', obj_description(r.oid, 'pg_class'),
           'primary_key', (SELECT json_agg(a.attname ORDER BY array_position(k.conkey, a.attnum)) FROM pg_constraint k
                           JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = ANY (k.conkey) WHERE k.conrelid = r.oid AND k.contype = 'p'),
           'unique', (SELECT json_agg((SELECT json_agg(a.attname ORDER BY array_position(k.conkey, a.attnum)) FROM pg_attribute a
                                       WHERE a.attrelid = k.conrelid AND a.attnum = ANY (k.conkey))) FROM pg_constraint k WHERE k.conrelid = r.oid AND k.contype = 'u'),
           'foreign_keys', (SELECT json_agg(json_build_object(
                              'columns', (SELECT json_agg(a.attname ORDER BY array_position(k.conkey, a.attnum)) FROM pg_attribute a WHERE a.attrelid = k.conrelid AND a.attnum = ANY (k.conkey)),
                              'ref_table', (SELECT relname FROM pg_class WHERE oid = k.confrelid),
                              'ref_columns', (SELECT json_agg(a.attname ORDER BY array_position(k.confkey, a.attnum)) FROM pg_attribute a WHERE a.attrelid = k.confrelid AND a.attnum = ANY (k.confkey)),
                              'on_delete', CASE k.confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' WHEN 'r' THEN 'RESTRICT' ELSE 'NO ACTION' END,
                              'on_update', CASE k.confupdtype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' WHEN 'r' THEN 'RESTRICT' ELSE 'NO ACTION' END))
                            FROM pg_constraint k WHERE k.conrelid = r.oid AND k.contype = 'f'),
           'checks', (SELECT json_agg(pg_get_constraintdef(k.oid)) FROM pg_constraint k WHERE k.conrelid = r.oid AND k.contype = 'c'),
           'indexes', (SELECT json_agg((SELECT json_agg(a.attname ORDER BY array_position(i.indkey::int2[], a.attnum)) FROM pg_attribute a
                                        WHERE a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey))) FROM pg_index i WHERE i.indrelid = r.oid AND NOT i.indisprimary AND NOT i.indisunique),
           'columns', col.columns)) ORDER BY r.relname))
FROM pg_class r JOIN pg_namespace n ON n.oid = r.relnamespace AND n.nspname = :'schema' JOIN col ON col.oid = r.oid
WHERE r.relkind IN ('r', 'p');
