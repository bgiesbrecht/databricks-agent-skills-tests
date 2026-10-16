-- cat cast.sql boundary.sql | psql -v table=lfc.mytable -At > bnd.sql; psql -v ON_ERROR_STOP=0 < bnd.sql
-- Writes one SELECT per column that casts n at its boundaries (1 up to 2^63 - 2) to the column's type; any ERROR is a bad cast.
SELECT format('SELECT %L AS col, %L AS ty, n, (%s)::text AS v FROM (VALUES (1::bigint), (2), (1000003), (1000000000039), (4611686018427387904), (9223372036854775806)) x(n);',
              a.attname, format_type(a.atttypid, a.atttypmod), coalesce(pg_temp.lfc_cast(a.atttypid, a.atttypmod), 'NULL') || '::' || format_type(a.atttypid, a.atttypmod))
FROM pg_attribute a WHERE a.attrelid = :'table'::regclass AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum;
