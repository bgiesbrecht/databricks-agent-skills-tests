-- { echo "SET @db='lfc', @plain_every=4, @block=1000"; cat cast.sql plan-audit.sql; } | mysql -N -B -r > audit.sql; mysql -N -B < audit.sql
-- Emits one query per table that decodes every checkable column back to n and compares it with the key, over the rows
-- that hold plain values (all rows if @plain_every is unset or 0, else the plain blocks); foreign-key columns are skipped. Prints table, rows checked, bad rows, columns checked.
SELECT CONCAT('SELECT ''', k.tbl, ''', COUNT(*), COALESCE(SUM(NOT (',
              GROUP_CONCAT(CONCAT('COALESCE(', REPLACE(l.chk, '{k}', CONCAT('(', k.pk_int, ')')), ', FALSE)') ORDER BY l.pos SEPARATOR ' AND '),
              ')), 0), ', COUNT(*), ' FROM `', k.db, '`.`', k.tbl, '`',
              IF(COALESCE(@plain_every, 0) > 0, CONCAT(' WHERE (', k.pk_int, ' - 1) DIV ', COALESCE(@block, 1000), ' % ', @plain_every, ' = 0'), ''), ';')
FROM lfc_cols l JOIN lfc_keys k ON k.db = l.db AND k.tbl = l.tbl
WHERE NOT l.is_pk AND l.chk IS NOT NULL
GROUP BY k.db, k.tbl, k.pk_int ORDER BY k.tbl;
