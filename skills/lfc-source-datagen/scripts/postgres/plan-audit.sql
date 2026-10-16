-- cat cast.sql plan-audit.sql | psql -v schema=lfc [-v plain_every=k -v block=B] -At > audit.sql; psql -At < audit.sql
-- Emits one query per table that decodes every checkable column back to n and compares it with the key, over the rows
-- that hold plain values (all rows if plain_every is 0, else the plain blocks). Prints table|rows checked|bad rows|columns checked.
\if :{?plain_every} \else \set plain_every 0 \endif
\if :{?block} \else \set block 1000 \endif
WITH c AS (
  SELECT s.nspname, r.relname, a.attnum, a.attname, coalesce(a.attnum = ANY (pk.conkey), false) AS is_pk,
         pg_temp.lfc_tag(obj_description(r.oid, 'pg_class'), 'n') AS nkey, pg_temp.lfc_tag(col_description(r.oid, a.attnum), 'v') AS v,
         pg_temp.lfc_tag(col_description(r.oid, a.attnum), 'e') AS e,
         pg_temp.lfc_to_int(a.atttypid, a.atttypmod, quote_ident(a.attname)) AS to_int, a.atttypid, pg_temp.lfc_mod(r.oid, a.attnum, a.atttypmod) AS atttypmod
  FROM pg_attribute a
  JOIN pg_class r ON r.oid = a.attrelid AND r.relkind = 'r'
  JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
  LEFT JOIN pg_constraint pk ON pk.conrelid = r.oid AND pk.contype = 'p'
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
  WHERE a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''              -- the same columns plan-insert.sql fills
    AND (coalesce(a.attnum = ANY (pk.conkey), false) OR (a.attidentity = '' AND NOT coalesce(pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval(%', false)))
    AND (coalesce(a.attnum = ANY (pk.conkey), false) OR pg_temp.lfc_tag(col_description(r.oid, a.attnum), 'v') IS NOT NULL
         OR pg_temp.lfc_tag(col_description(r.oid, a.attnum), 'e') IS NOT NULL OR NOT EXISTS (SELECT 1 FROM pg_constraint f WHERE f.conrelid = r.oid AND f.contype = 'f'
                                                  AND a.attnum = ANY (f.conkey)))      -- FK values depend on the parent, unless a formula
), k AS (SELECT nspname, relname, CASE WHEN max(nkey) IS NOT NULL THEN max(nkey) WHEN count(*) FILTER (WHERE is_pk) = 1 THEN max(to_int) FILTER (WHERE is_pk) END AS key
         FROM c GROUP BY 1, 2
         HAVING max(nkey) IS NOT NULL OR (count(*) FILTER (WHERE is_pk) = 1 AND max(to_int) FILTER (WHERE is_pk) IS NOT NULL)),
ch AS (SELECT c.nspname, c.relname, c.attnum,   -- a column with a formula (lfc:v) is checked against the formula at n
              -- a column added after rows existed (tagged 'lfc:added' by plan-ddl.sql) may be NULL in the older rows
              CASE WHEN c.e IS NOT NULL THEN format('%I IS NOT DISTINCT FROM (%s)', c.attname, replace(c.e, 'x.n', '(' || k.key || ')::bigint'))
                   WHEN col_description(format('%I.%I', c.nspname, c.relname)::regclass, c.attnum) LIKE '%lfc:added%'
                   THEN format('(%I IS NULL OR %s)', c.attname, pg_temp.lfc_check(c.atttypid, c.atttypmod, quote_ident(c.attname), '(' || coalesce(replace(c.v, 'x.n', '(' || k.key || ')::bigint'), k.key) || ')'))
                   ELSE pg_temp.lfc_check(c.atttypid, c.atttypmod, quote_ident(c.attname), '(' || coalesce(replace(c.v, 'x.n', '(' || k.key || ')::bigint'), k.key) || ')') END AS chk
       FROM c JOIN k USING (nspname, relname) WHERE NOT c.is_pk)
SELECT format('SELECT %L, count(*), count(*) FILTER (WHERE NOT (%s)), %s FROM %I.%I%s;',
              relname, string_agg('coalesce(' || chk || ', false)', ' AND ' ORDER BY attnum), count(*), nspname, relname,
              CASE WHEN :plain_every > 0 THEN format(' WHERE (%s - 1) / %s %% %s = 0', max(k.key), :block, :plain_every) ELSE '' END)
FROM ch JOIN k USING (nspname, relname) WHERE chk IS NOT NULL GROUP BY nspname, relname ORDER BY relname;
