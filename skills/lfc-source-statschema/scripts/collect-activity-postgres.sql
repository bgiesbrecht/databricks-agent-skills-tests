-- collect-activity-postgres.sql: each table's inserts, updates and deletes since the statistics were last reset, as
-- one JSON object {"<table>": {"inserts", "updates", "deletes"}} (cdc-table-plan's classify.py --activity).
--   psql -X -At -v schema=sales -f collect-activity-postgres.sql > activity.json
SELECT COALESCE(json_object_agg(relname, json_build_object('inserts', n_tup_ins, 'updates', n_tup_upd, 'deletes', n_tup_del)), '{}')
FROM pg_stat_user_tables WHERE schemaname = :'schema';
