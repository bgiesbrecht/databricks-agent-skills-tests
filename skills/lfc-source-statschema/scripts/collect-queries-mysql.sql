-- mysql -N -B -r -e "SET @db='sales', @top=50, @vals='none'; SOURCE collect-queries-mysql.sql" > queries.json
-- The top statements from performance_schema's digest table (most total time first). The digest text has ? for every
-- literal, so it holds no data values; with @vals='all' each entry also gets MySQL's sample of the statement as it ran,
-- which does (QUERY_SAMPLE_TEXT, real literals). MySQL can't plan a statement with ? in it, so source plans are only
-- collected for samples; replay.py plans every query on the copy. Needs SELECT on performance_schema.
SET @top = COALESCE(@top, 50), @vals = COALESCE(@vals, 'none');
SELECT JSON_OBJECT('source_dialect', 'mysql', 'source_version', VERSION(),
         'queries', COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id', d.digest, 'sql', d.digest_text, 'calls', d.count_star,
                       'total_elapsed_ms', ROUND(d.sum_timer_wait / 1e9, 3), 'mean_elapsed_ms', ROUND(d.avg_timer_wait / 1e9, 3),
                       'rank_by', 'total_time', 'sample', IF(@vals = 'all', d.query_sample_text, NULL))), JSON_ARRAY()))
FROM (SELECT *, ROW_NUMBER() OVER (ORDER BY sum_timer_wait DESC) AS rn FROM performance_schema.events_statements_summary_by_digest
      WHERE schema_name = @db AND digest_text REGEXP '^(SELECT|WITH|INSERT|UPDATE|DELETE) '
        AND digest_text NOT REGEXP 'performance_schema|information_schema') d
WHERE d.rn <= @top;
