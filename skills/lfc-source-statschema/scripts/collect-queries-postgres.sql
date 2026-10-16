-- psql -X -At -v top=50 -v search_path=sales -f collect-queries-postgres.sql > queries.json
-- The top statements from pg_stat_statements (most total time first), each with its plan from EXPLAIN (GENERIC_PLAN,
-- FORMAT JSON): planned, never run, so no data is read, and the text has no data values (pg_stat_statements replaces
-- literals with $1, $2, ...). GENERIC_PLAN needs Postgres 16+; older versions record the error instead of a plan.
-- Set search_path to what the application uses, so unqualified table names resolve (the extension's schema is added). Needs pg_stat_statements loaded
-- (shared_preload_libraries) and the pg_read_all_stats role to see other users' statements.
\if :{?top} \else \set top 50 \endif
\if :{?search_path}
SELECT set_config('search_path', :'search_path' || ', ' || extnamespace::regnamespace::text, false) AS lfc_path   -- and the extension's schema
FROM pg_extension WHERE extname = 'pg_stat_statements' \gset
\endif
CREATE FUNCTION pg_temp.lfc_plan(q text) RETURNS json LANGUAGE plpgsql AS $f$
DECLARE p json;
BEGIN
  -- pg_stat_statements writes date '1995-03-15' as date $1, which isn't valid SQL to plan: make it $1::date
  EXECUTE 'EXPLAIN (GENERIC_PLAN, FORMAT JSON) ' || regexp_replace(q, '\m(date|timestamp|time|interval)\s+(\$\d+)', '\2::\1', 'gi') INTO p;
  RETURN p;
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('error', SQLERRM);
END
$f$;
SELECT json_build_object('source_dialect', 'postgres', 'source_version', current_setting('server_version'),
         'queries', coalesce(json_agg(json_build_object('id', q.queryid::text, 'sql', q.query, 'calls', q.calls,
                                        'total_elapsed_ms', round(q.total_exec_time::numeric, 3), 'mean_elapsed_ms', round(q.mean_exec_time::numeric, 3),
                                        'rank_by', 'total_time', 'plan', pg_temp.lfc_plan(q.query)) ORDER BY q.total_exec_time DESC), '[]'))
FROM (SELECT s.queryid, s.query, s.calls, s.total_exec_time, s.mean_exec_time
      FROM pg_stat_statements s JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
      WHERE s.query ~* '^\s*(select|with|insert|update|delete)\M' AND s.query !~* 'pg_stat_statements|pg_catalog|information_schema|pg_extension'
      ORDER BY s.total_exec_time DESC LIMIT :top) q;
