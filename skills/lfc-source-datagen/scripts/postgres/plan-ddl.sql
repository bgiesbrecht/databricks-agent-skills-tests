-- cat cast.sql plan-ddl.sql | psql -v schema=lfc -v ops=10 [-v new_rows=10000] -At > ddl.sql; psql -v ON_ERROR_STOP=0 < ddl.sql
-- Emits :ops random DDL operations on :schema, weighted like real schema changes: add column 25%, modify column 20%,
-- create index 15%, truncate 15%, create table 10%, drop column 10%, drop table 5%. Each picks an object that keeps
-- the generator working: added columns are nullable and tagged 'lfc:added' (the audit accepts NULL there); modify only
-- widens varchar(L >= 38), widens int to bigint, or drops NOT NULL; drop and truncate only touch tables no foreign key
-- points at; drop column never takes the key or a foreign key. Operations planned together can still clash (one drops
-- a column another modifies): run the file without stopping on errors, then re-plan the fill.
\if :{?new_rows} \else \set new_rows 10000 \endif
WITH RECURSIVE
menu(types) AS (SELECT ARRAY['int', 'bigint', 'numeric(18,2)', 'double precision', 'varchar(60)', 'varchar(200)', 'text',
                             'date', 'timestamp', 'timestamptz', 'boolean', 'bytea', 'uuid', 'jsonb']),
tbl AS (SELECT r.oid, r.relname FROM pg_class r JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
        JOIN pg_constraint pk ON pk.conrelid = r.oid AND pk.contype = 'p' AND cardinality(pk.conkey) = 1 WHERE r.relkind = 'r'),
col AS (SELECT t.oid, t.relname, a.attnum, a.attname, a.atttypid::regtype::text AS ty, a.atttypmod AS m, a.attnotnull AS notnull,
               EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = t.oid AND c.contype IN ('p', 'f') AND a.attnum = ANY (c.conkey)) AS keyish,
               EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = t.oid AND i.indkey[0] = a.attnum) AS indexed
        FROM tbl t JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped),
leaf AS (SELECT * FROM tbl t WHERE NOT EXISTS (SELECT 1 FROM pg_constraint f WHERE f.confrelid = t.oid AND f.contype = 'f' AND f.conrelid <> t.oid)),
op AS (SELECT i, CASE WHEN p < 25 THEN 'add' WHEN p < 45 THEN 'modify' WHEN p < 60 THEN 'index' WHEN p < 75 THEN 'truncate'
                      WHEN p < 85 THEN 'create' WHEN p < 95 THEN 'drop_column' ELSE 'drop_table' END AS op
       FROM (SELECT i, floor(random() * 100) AS p FROM generate_series(1, :ops) i) q)
SELECT format('/* ddl %s %s */ %s', op.i, op.op, x.sql) FROM op, menu m, LATERAL (
  SELECT CASE op.op
    WHEN 'add' THEN (SELECT format('ALTER TABLE %I.%I ADD COLUMN %I %s; COMMENT ON COLUMN %I.%I.%I IS ''lfc:added'';',
                               :'schema', t.relname, nm, ty, :'schema', t.relname, nm)
                     FROM (SELECT t.relname, m.types[1 + floor(random() * cardinality(m.types) + 0 * op.i)::int] AS ty,
                                  format('a%s_%s', op.i, to_char(clock_timestamp(), 'HH24MISS')) AS nm
                           FROM tbl t ORDER BY random() + 0 * op.i LIMIT 1) t)
    WHEN 'modify' THEN (SELECT CASE WHEN c.ty = 'character varying' THEN format('ALTER TABLE %I.%I ALTER COLUMN %I TYPE varchar(%s);', :'schema', c.relname, c.attname, least((c.m - 4) * 2, 10485760))
                                    WHEN c.ty = 'integer' THEN format('ALTER TABLE %I.%I ALTER COLUMN %I TYPE bigint;', :'schema', c.relname, c.attname)
                                    ELSE format('ALTER TABLE %I.%I ALTER COLUMN %I DROP NOT NULL;', :'schema', c.relname, c.attname) END
                        FROM col c WHERE NOT c.keyish AND ((c.ty = 'character varying' AND c.m - 4 >= 38) OR c.ty = 'integer' OR c.notnull)
                        ORDER BY random() + 0 * op.i LIMIT 1)
    WHEN 'index' THEN (SELECT format('CREATE INDEX ON %I.%I (%I);', :'schema', c.relname, c.attname) FROM col c
                       WHERE NOT c.indexed AND c.ty IN ('smallint', 'integer', 'bigint', 'numeric', 'character varying', 'date',
                                                        'timestamp without time zone', 'timestamp with time zone', 'uuid', 'boolean')
                       ORDER BY random() + 0 * op.i LIMIT 1)
    WHEN 'truncate' THEN (SELECT format('TRUNCATE %I.%I;', :'schema', relname) FROM leaf ORDER BY random() + 0 * op.i LIMIT 1)
    WHEN 'create' THEN (SELECT format('CREATE TABLE %I.%I (id bigint PRIMARY KEY, %s); COMMENT ON TABLE %I.%I IS %L;', :'schema', nm,
                                      (SELECT string_agg(format('c%s %s', j, m.types[1 + (j * 5 + op.i * 3) % cardinality(m.types)]), ', ') FROM generate_series(1, 6) j),
                                      :'schema', nm, 'lfc:rows=' || (1 + floor(random() * :new_rows))::bigint)
                        FROM (SELECT format('n%s_%s', op.i, to_char(clock_timestamp(), 'HH24MISS')) AS nm) q)
    WHEN 'drop_column' THEN (SELECT format('ALTER TABLE %I.%I DROP COLUMN %I;', :'schema', c.relname, c.attname) FROM col c
                             WHERE NOT c.keyish AND (SELECT count(*) FROM col c2 WHERE c2.oid = c.oid) > 2 ORDER BY random() + 0 * op.i LIMIT 1)
    WHEN 'drop_table' THEN (SELECT format('DROP TABLE %I.%I;', :'schema', relname) FROM leaf ORDER BY random() + 0 * op.i LIMIT 1)
  END AS sql) x
WHERE x.sql IS NOT NULL ORDER BY op.i;
