-- psql -v schema=lfc -v tables=100 -v max_rows=1000000 -v cols=12 [-v dist=even|random] -f make-dataset.sql
-- Creates :tables tables, each with a bigint key and :cols columns cycling through a menu of types (each table starts
-- at a different type, so all types are covered), and records each table's target row count in its comment:
--   dist=even (default): table k gets ceil(k * max_rows / tables) rows, an even spread from small to max_rows
--   dist=random: a uniform pseudo-random count in 1..max_rows, the same on every run
-- dims=D, fks=K (default 0): the first D tables are dimensions; every other table gets K foreign-key columns
--   (f1_t01_id ...) referencing the dimensions in turn, each with an index (the delete planner's re-point UPDATEs use it)
\if :{?dist} \else \set dist even \endif
\if :{?dims} \else \set dims 0 \endif
\if :{?fks} \else \set fks 0 \endif
CREATE SCHEMA IF NOT EXISTS :"schema";
WITH menu(types) AS (SELECT ARRAY['int', 'bigint', 'smallint', 'numeric(18,2)', 'numeric(38,10)', 'real', 'double precision',
       'varchar(50)', 'varchar(255)', 'char(20)', 'text', 'date', 'timestamp', 'timestamptz', 'time', 'interval',
       'boolean', 'bytea', 'uuid', 'jsonb', 'point', 'inet']),
t AS (SELECT k, format('t%s', lpad(k::text, length(:'tables'), '0')) AS name,
             CASE :'dist' WHEN 'random' THEN 1 + ('x' || substr(md5(k::text), 1, 15))::bit(60)::bigint % :max_rows
                          ELSE ceil(k * :max_rows::numeric / :tables)::bigint END AS target
      FROM generate_series(1, :tables) k)
SELECT format('CREATE TABLE %I.%I (id bigint PRIMARY KEY, %s%s); COMMENT ON TABLE %I.%I IS %L;%s',
              :'schema', t.name,
              (SELECT string_agg(format('c%s_%s %s', j, trim(both '_' from regexp_replace(m.types[1 + (t.k + j) % cardinality(m.types)], '[^a-z0-9]+', '_', 'g')),
                                        m.types[1 + (t.k + j) % cardinality(m.types)]), ', ' ORDER BY j)
               FROM generate_series(1, :cols) j),
              (SELECT coalesce(string_agg(format(', f%s_%s_id bigint NOT NULL REFERENCES %I.%I', f, d.name, :'schema', d.name), '' ORDER BY f), '')
               FROM generate_series(1, :fks) f JOIN t d ON d.k = 1 + (t.k + f) % :dims WHERE t.k > :dims),
              :'schema', t.name, 'lfc:rows=' || t.target,
              (SELECT coalesce(string_agg(format(' CREATE INDEX ON %I.%I (f%s_%s_id);', :'schema', t.name, f, d.name), '' ORDER BY f), '')
               FROM generate_series(1, :fks) f JOIN t d ON d.k = 1 + (t.k + f) % :dims WHERE t.k > :dims))
FROM t, menu m ORDER BY t.k \gexec
