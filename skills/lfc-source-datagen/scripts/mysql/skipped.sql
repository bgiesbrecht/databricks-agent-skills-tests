-- Tables the planner skips: no primary key, a composite key, or a key that can't be turned back into n, unless the table
-- has a key formula (lfc:n={...} in its comment).
SELECT t.table_name, CASE WHEN k.n IS NULL THEN 'no primary key' WHEN k.n > 1 THEN 'composite key' ELSE CONCAT('key type ', c.column_type) END
FROM information_schema.tables t
LEFT JOIN (SELECT table_name, COUNT(*) AS n, MAX(column_name) AS col FROM information_schema.statistics
           WHERE table_schema = @db AND index_name = 'PRIMARY' GROUP BY table_name) k ON k.table_name = t.table_name
LEFT JOIN information_schema.columns c ON c.table_schema = @db AND c.table_name = t.table_name AND c.column_name = k.col
WHERE t.table_schema = @db AND t.table_type = 'BASE TABLE' AND t.table_comment NOT LIKE '%lfc:n={%' AND t.table_comment NOT LIKE '%lfc:ref%'     -- lfc:n: a key formula
  AND (k.n IS NULL OR k.n > 1 OR NOT (c.data_type IN ('tinyint', 'smallint', 'mediumint', 'int', 'bigint')
                                      OR (c.data_type IN ('char', 'varchar') AND c.character_maximum_length >= 19)))
ORDER BY 1;
