-- cat cast.sql plan-delete.sql | psql -v schema=lfc -v rows=100 -v end=head|tail -At > deletes.sql
-- Emits, per table, a DELETE that removes :rows keys from one end of the key range (head or tail), never the middle, and
-- never the last rows: it deletes the keys before the (:rows + 1)-th, so a table with :rows rows or fewer is left alone.
-- Dimension first: before a table loses keys, every one-column foreign key that points at them is re-pointed into the
-- range that stays (an UPDATE of a non-key column, so the child's key range doesn't change). Tables go in level order.
-- Skipped: tables whose key comes from a formula (lfc:n), and parents of a foreign key that is part of the child's key or
-- has a formula (lfc:v), since re-pointing those would change a key or break the formula.
WITH RECURSIVE e AS (SELECT DISTINCT f.conrelid AS child, f.confrelid AS parent FROM pg_constraint f
                     JOIN pg_class r ON r.oid = f.conrelid JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
                     WHERE f.contype = 'f' AND f.conrelid <> f.confrelid),
l(rel, lvl) AS (SELECT r.oid, 0 FROM pg_class r JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema' WHERE r.relkind = 'r'
                UNION ALL SELECT e.child, l.lvl + 1 FROM e JOIN l ON l.rel = e.parent WHERE l.lvl < 50),
t AS (                                                         -- tables with a one-column key that maps back to n
  SELECT r.oid AS rel, s.nspname, r.relname, a.attname AS pk, a.atttypid, a.atttypmod,
         pg_temp.lfc_to_int(a.atttypid, a.atttypmod, quote_ident(a.attname)) AS pk_int, (SELECT max(lvl) FROM l WHERE l.rel = r.oid) AS lvl,
         -- the first key that stays: head -> the (:rows + 1)-th smallest, tail -> the (:rows + 1)-th largest
         format('(SELECT %I FROM %I.%I ORDER BY %I %s OFFSET %s LIMIT 1)', a.attname, s.nspname, r.relname, a.attname,
                CASE :'end' WHEN 'tail' THEN 'DESC' ELSE 'ASC' END, :rows) AS keep
  FROM pg_constraint pk JOIN pg_class r ON r.oid = pk.conrelid JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
  JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum = pk.conkey[1]
  WHERE pk.contype = 'p' AND cardinality(pk.conkey) = 1
    AND coalesce(obj_description(r.oid, 'pg_class'), '') NOT LIKE '%lfc:n={%'      -- spec-formula keys (TPC schemas): not yet
    AND NOT EXISTS (SELECT 1 FROM pg_constraint f JOIN pg_attribute ca ON ca.attrelid = f.conrelid AND ca.attnum = ANY (f.conkey)
                    LEFT JOIN pg_constraint cpk ON cpk.conrelid = f.conrelid AND cpk.contype = 'p'
                    WHERE f.contype = 'f' AND f.confrelid = r.oid      -- a child that can't be re-pointed: the FK is part of its key,
                      AND (ca.attnum = ANY (cpk.conkey) OR coalesce(col_description(f.conrelid, ca.attnum), '') LIKE '%lfc:v={%'))  -- or a formula
),
fk AS (                                                        -- one-column foreign keys to those tables' keys
  SELECT f.confrelid AS parent, cs.nspname AS cns, cr.relname AS crel, ca.attname AS ccol
  FROM pg_constraint f JOIN pg_constraint ppk ON ppk.conrelid = f.confrelid AND ppk.contype = 'p' AND ppk.conkey = f.confkey
  JOIN pg_class cr ON cr.oid = f.conrelid JOIN pg_namespace cs ON cs.oid = cr.relnamespace
  JOIN pg_attribute ca ON ca.attrelid = f.conrelid AND ca.attnum = f.conkey[1]
  WHERE f.contype = 'f' AND cardinality(f.conkey) = 1
),
stmt AS (
  -- re-point children: v -> lo' + (v % span'), where [lo', hi'] is the range that stays
  SELECT t.lvl, t.relname, 1 AS step, format('UPDATE %I.%I SET %I = %s WHERE %I %s %s;', fk.cns, fk.crel, fk.ccol,
           replace(pg_temp.lfc_cast(t.atttypid, t.atttypmod), 'x.n', format('(%s + %s %% (%s - %s + 1))',
             CASE :'end' WHEN 'tail' THEN format('(SELECT %s FROM %I.%I ORDER BY %I LIMIT 1)', t.pk_int, t.nspname, t.relname, t.pk)
                         ELSE replace(t.pk_int, quote_ident(t.pk), t.keep) END,
             pg_temp.lfc_to_int(t.atttypid, t.atttypmod, quote_ident(fk.ccol)),
             CASE :'end' WHEN 'tail' THEN replace(t.pk_int, quote_ident(t.pk), t.keep)
                         ELSE format('(SELECT %s FROM %I.%I ORDER BY %I DESC LIMIT 1)', t.pk_int, t.nspname, t.relname, t.pk) END,
             CASE :'end' WHEN 'tail' THEN format('(SELECT %s FROM %I.%I ORDER BY %I LIMIT 1)', t.pk_int, t.nspname, t.relname, t.pk)
                         ELSE replace(t.pk_int, quote_ident(t.pk), t.keep) END)),
           fk.ccol, CASE :'end' WHEN 'tail' THEN '>' ELSE '<' END, t.keep) AS sql
  FROM t JOIN fk ON fk.parent = t.rel WHERE t.pk_int IS NOT NULL
  UNION ALL
  SELECT t.lvl, t.relname, 2, format('DELETE FROM %I.%I WHERE %I %s %s;', t.nspname, t.relname, t.pk,
           CASE :'end' WHEN 'tail' THEN '>' ELSE '<' END, t.keep)
  FROM t
)
SELECT format('/* lfc level %s */ %s', lvl, sql) FROM stmt ORDER BY lvl, relname, step;
