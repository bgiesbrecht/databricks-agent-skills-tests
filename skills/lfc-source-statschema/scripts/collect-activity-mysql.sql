-- collect-activity-mysql.sql: each table's inserts, updates and deletes since the server started (or since
-- performance_schema's table I/O summary was truncated), as one JSON object {"<table>": {"inserts", "updates",
-- "deletes"}}: what cdc-table-plan's classify.py --activity reads to tell insert-only tables from updated ones.
-- Counts are row operations (a multi-row INSERT counts each row). Needs SELECT on performance_schema; @db the schema.
--   mysql -N -B -r -e "SET @db='sales'; SOURCE collect-activity-mysql.sql" > activity.json
SELECT COALESCE(JSON_OBJECTAGG(object_name, JSON_OBJECT('inserts', count_insert, 'updates', count_update,
                                                        'deletes', count_delete)), JSON_OBJECT())
FROM performance_schema.table_io_waits_summary_by_table
WHERE object_type = 'TABLE' AND object_schema = @db;
