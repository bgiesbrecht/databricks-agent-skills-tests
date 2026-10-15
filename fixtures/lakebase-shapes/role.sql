-- Reader role + UC connection body, same pattern as the skill (password generated in Postgres).
-- Run with: -X -At -v ON_ERROR_STOP=1 -v host=<endpoint-host> -f role.sql   (writes conn.json; delete it after use)
SELECT replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') AS pw \gset
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lfc_shapes_reader') AS role_exists \gset
\if :role_exists
ALTER ROLE lfc_shapes_reader WITH LOGIN PASSWORD :'pw';
\else
CREATE ROLE lfc_shapes_reader WITH LOGIN PASSWORD :'pw';
\endif
GRANT CONNECT ON DATABASE databricks_postgres TO lfc_shapes_reader;
\o conn.json
SELECT json_build_object('name', 'lfc_shapes_pg_conn', 'connection_type', 'POSTGRESQL',
  'options', json_build_object('host', :'host', 'port', '5432', 'user', 'lfc_shapes_reader', 'password', :'pw'));
\o
