-- psql -v schema=lfc -At -f pg-plan-status.sql > status.sql; psql -At -f status.sql
-- Emits SELECTs (500 tables each) returning table|min key|max key|rows|target (from 'lfc:rows=', if set). Keys only ever change at the
-- ends, so rows = max - min + 1 without COUNT(*); each min and max is one index probe.
WITH t AS (                                                    -- a one-column key, or a key formula (lfc:n={...}, see cast.sql)
  SELECT s.nspname, r.relname, a.attname, a.atttypid::regtype::text AS ty,
         coalesce(substring(obj_description(r.oid, 'pg_class') from 'lfc:rows=([0-9]+)'), '') AS target,
         substring(obj_description(r.oid, 'pg_class') from 'lfc:n=\{([^}]*)\}') AS nkey,
         quote_ident(coalesce(substring(obj_description(r.oid, 'pg_class') from 'lfc:by=\{([^}]*)\}'), a.attname)) AS byc,
         row_number() OVER (ORDER BY r.relname) - 1 AS k
  FROM pg_class r
  JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
  LEFT JOIN pg_constraint pk ON pk.conrelid = r.oid AND pk.contype = 'p'
  LEFT JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum = pk.conkey[1]
  WHERE r.relkind = 'r' AND (cardinality(pk.conkey) = 1 OR obj_description(r.oid, 'pg_class') LIKE '%lfc:n={%')
), q AS (
  SELECT k / 500 AS chunk, format('SELECT %L, lo, hi, coalesce(hi - lo + 1, 0), %L FROM (SELECT %s lo, %s hi) m', relname, target,
           CASE WHEN nkey IS NULL THEN format('(SELECT %s FROM %I.%I ORDER BY %I LIMIT 1)', i, nspname, relname, attname)
                ELSE format('(SELECT min(%1$s) FROM %2$I.%3$I WHERE %4$s = (SELECT %4$s FROM %2$I.%3$I ORDER BY %4$s LIMIT 1))', nkey, nspname, relname, byc) END,
           CASE WHEN nkey IS NULL THEN format('(SELECT %s FROM %I.%I ORDER BY %I DESC LIMIT 1)', i, nspname, relname, attname)
                ELSE format('(SELECT max(%1$s) FROM %2$I.%3$I WHERE %4$s = (SELECT %4$s FROM %2$I.%3$I ORDER BY %4$s DESC LIMIT 1))', nkey, nspname, relname, byc) END) AS sel
  FROM (SELECT *, CASE ty WHEN 'uuid' THEN format('(''x'' || right(replace(%I::text, ''-'', ''''), 16))::bit(64)::bigint', attname)
                          WHEN 'character varying' THEN format('left(%I, 19)::bigint', attname)
                          WHEN 'character' THEN format('left(%I, 19)::bigint', attname)
                          WHEN 'text' THEN format('left(%I, 19)::bigint', attname)
                          ELSE format('%I::bigint', attname) END AS i FROM t) t2
)
SELECT string_agg(sel, E'\nUNION ALL ') || ';' FROM q GROUP BY chunk ORDER BY chunk;
