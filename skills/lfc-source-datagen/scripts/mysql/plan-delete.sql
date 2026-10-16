-- { echo "SET @db='lfc', @rows=100, @end='head'"; cat cast.sql plan-delete.sql; } | mysql -N -B -r > deletes.sql
-- Emits, per table, a DELETE that removes @rows keys from one end of the key range (head or tail), never the middle, and
-- never the last rows: it deletes the keys before the (@rows + 1)-th, so a table with @rows rows or fewer is left alone.
-- Dimension first: before a table loses keys, every one-column foreign key that points at them is re-pointed into the
-- range that stays (an UPDATE of a non-key column). Every probe is a LIMIT-ed derived table, which MySQL materializes, so
-- a statement can read the table it changes. Tables go in level order.
-- Skipped: tables whose key comes from a formula (lfc:n), and parents of a foreign key that is part of the child's key or
-- has a formula (lfc:v), since re-pointing those would change a key or break the formula.
WITH RECURSIVE e AS (SELECT DISTINCT table_name AS child, referenced_table_name AS parent FROM information_schema.key_column_usage
                     WHERE table_schema = @db AND referenced_table_schema = @db AND referenced_table_name <> table_name),
l (tbl, lvl) AS (SELECT table_name, 0 FROM information_schema.tables WHERE table_schema = @db
                 UNION ALL SELECT e.child, l.lvl + 1 FROM e JOIN l ON l.tbl = e.parent WHERE l.lvl < 50),
lv AS (SELECT tbl, MAX(lvl) AS lvl FROM l GROUP BY tbl),
t AS (SELECT k.*, lv.lvl,
             -- the first key that stays, and the ends of the range that stays, as n
             CONCAT('(SELECT v FROM (SELECT `', k.pk, '` AS v FROM `', k.db, '`.`', k.tbl, '` ORDER BY `', k.pk, '` ',
                    IF(@end = 'tail', 'DESC', 'ASC'), ' LIMIT 1 OFFSET ', @rows, ') d)') AS keep,
             CONCAT('(SELECT v FROM (SELECT ', k.pk_int, ' AS v FROM `', k.db, '`.`', k.tbl, '` ORDER BY `', k.pk, '` ',
                    IF(@end = 'tail', 'ASC LIMIT 1', CONCAT('ASC LIMIT 1 OFFSET ', @rows)), ') d)') AS lo,
             CONCAT('(SELECT v FROM (SELECT ', k.pk_int, ' AS v FROM `', k.db, '`.`', k.tbl, '` ORDER BY `', k.pk, '` ',
                    IF(@end = 'tail', CONCAT('DESC LIMIT 1 OFFSET ', @rows), 'DESC LIMIT 1'), ') d)') AS hi
      FROM lfc_keys k JOIN lv ON lv.tbl = k.tbl WHERE k.db = @db
        AND NOT k.has_n                                           -- spec-formula keys (TPC schemas): not yet
        AND NOT EXISTS (SELECT 1 FROM information_schema.key_column_usage u JOIN information_schema.columns c
                          ON c.table_schema = u.table_schema AND c.table_name = u.table_name AND c.column_name = u.column_name
                        WHERE u.table_schema = @db AND u.referenced_table_name = k.tbl      -- a child that can't be re-pointed: the
                          AND (c.column_key = 'PRI' OR c.column_comment LIKE '%lfc:v={%' OR c.column_comment LIKE '%lfc:ref%'))),  -- FK is part of its key, or a formula
fk AS (SELECT table_name AS ctbl, column_name AS ccol, referenced_table_name AS ptbl FROM information_schema.key_column_usage u
       WHERE table_schema = @db AND referenced_table_schema = @db
         AND (SELECT COUNT(*) FROM information_schema.key_column_usage u2 WHERE u2.constraint_schema = u.constraint_schema
                AND u2.constraint_name = u.constraint_name AND u2.table_name = u.table_name) = 1)
-- one row per table (a temporary table can't be read twice in one MySQL query): its children's re-point UPDATEs, then its DELETE
SELECT CONCAT(COALESCE(GROUP_CONCAT(CONCAT('/* lfc level ', t.lvl, ' */ UPDATE `', t.db, '`.`', fk.ctbl, '` SET `', fk.ccol, '` = ',
         REPLACE(t.pk_expr, 'x.n', CONCAT('(', t.lo, ' + ', REPLACE(t.pk_int, CONCAT('`', t.pk, '`'), CONCAT('`', fk.ccol, '`')),
                                          ' % (', t.hi, ' - ', t.lo, ' + 1))')),
         ' WHERE `', fk.ccol, '` ', IF(@end = 'tail', '>', '<'), ' ', t.keep, ';') ORDER BY fk.ctbl, fk.ccol SEPARATOR '\n'), ''),
       IF(COUNT(fk.ctbl) > 0, '\n', ''),
       '/* lfc level ', t.lvl, ' */ DELETE FROM `', t.db, '`.`', t.tbl, '` WHERE `', t.pk, '` ', IF(@end = 'tail', '>', '<'), ' ', t.keep, ';')
FROM t LEFT JOIN fk ON fk.ptbl = t.tbl
GROUP BY t.lvl, t.db, t.tbl, t.pk, t.pk_int, t.pk_expr, t.keep, t.lo, t.hi
ORDER BY t.lvl, t.tbl;
