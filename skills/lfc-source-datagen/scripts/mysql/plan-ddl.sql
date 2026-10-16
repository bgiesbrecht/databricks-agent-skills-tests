-- { echo "SET @db='lfc', @ops=10, @new_rows=10000"; cat plan-ddl.sql; } | mysql -N -B -r > ddl.sql; mysql --force < ddl.sql
-- Emits @ops random DDL operations on @db, weighted like real schema changes: add column 25%, modify column 20%,
-- create index 15%, truncate 15%, create table 10%, drop column 10%, drop table 5%. Each picks an object that keeps the
-- generator working: added columns are nullable and tagged 'lfc:added' (the audit accepts NULL there); modify only widens
-- varchar(L >= 38), widens int to bigint, or drops NOT NULL (restating the column's comment, since MODIFY replaces the
-- whole definition); drop and truncate only touch tables no foreign key points at; drop column never takes the key or a
-- foreign key. Operations planned together can still clash: run the file with --force, then re-plan the fill.
SET SESSION cte_max_recursion_depth = 10000;
WITH RECURSIVE ops(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM ops WHERE i < @ops),
op AS (SELECT i, CASE WHEN p < 25 THEN 'add' WHEN p < 45 THEN 'modify' WHEN p < 60 THEN 'index' WHEN p < 75 THEN 'truncate'
                      WHEN p < 85 THEN 'create' WHEN p < 95 THEN 'drop_column' ELSE 'drop_table' END AS op
       FROM (SELECT i, FLOOR(RAND() * 100) AS p FROM ops) q),
tbl AS (SELECT table_name FROM information_schema.statistics WHERE table_schema = @db AND index_name = 'PRIMARY'
        GROUP BY table_name HAVING COUNT(*) = 1),
leaf AS (SELECT t.table_name FROM tbl t WHERE NOT EXISTS (SELECT 1 FROM information_schema.key_column_usage u
         WHERE u.referenced_table_schema = @db AND u.referenced_table_name = t.table_name AND u.table_name <> t.table_name)),
col AS (SELECT c.table_name, c.column_name, c.data_type, c.column_type, c.character_maximum_length AS len, c.is_nullable,
               c.column_comment, c.column_key,
               EXISTS (SELECT 1 FROM information_schema.key_column_usage u WHERE u.table_schema = @db AND u.table_name = c.table_name
                       AND u.column_name = c.column_name AND (u.referenced_table_name IS NOT NULL OR u.constraint_name = 'PRIMARY')) AS keyish,
               (SELECT COUNT(*) FROM information_schema.columns c2 WHERE c2.table_schema = @db AND c2.table_name = c.table_name) AS ncols
        FROM information_schema.columns c JOIN tbl t ON t.table_name = c.table_name WHERE c.table_schema = @db AND c.generation_expression = ''),
cand AS (   -- every (operation, candidate SQL) pair; one candidate per operation is drawn at random below
  SELECT op.i, op.op, CONCAT('ALTER TABLE `', @db, '`.`', t.table_name, '` ADD COLUMN `a', op.i, '_', DATE_FORMAT(NOW(), '%H%i%s'), '` ',
                             ELT(1 + FLOOR(RAND() * 12), 'int', 'bigint', 'decimal(18,2)', 'double', 'varchar(60)', 'varchar(200)', 'text', 'date', 'datetime', 'tinyint', 'varbinary(64)', 'json'), ' NULL COMMENT ''lfc:added'';') AS sql_text
  FROM op JOIN tbl t WHERE op.op = 'add'
  UNION ALL
  SELECT op.i, op.op, CONCAT('ALTER TABLE `', @db, '`.`', c.table_name, '` MODIFY COLUMN `', c.column_name, '` ',
           CASE WHEN c.data_type = 'varchar' THEN CONCAT('varchar(', LEAST(c.len * 2, 16000), ')')
                WHEN c.data_type = 'int' THEN REPLACE(c.column_type, 'int', 'bigint') ELSE c.column_type END,
           ' NULL', IF(c.column_comment <> '', CONCAT(' COMMENT ''', REPLACE(c.column_comment, '''', ''''''), ''''), ''), ';')
  FROM op JOIN col c WHERE op.op = 'modify' AND NOT c.keyish
    AND ((c.data_type = 'varchar' AND c.len >= 38) OR c.data_type = 'int' OR c.is_nullable = 'NO')
  UNION ALL
  SELECT op.i, op.op, CONCAT('CREATE INDEX `i', op.i, '_', DATE_FORMAT(NOW(), '%H%i%s'), '` ON `', @db, '`.`', c.table_name, '` (`', c.column_name, '`);')
  FROM op JOIN col c WHERE op.op = 'index' AND c.column_key = ''
    AND (c.data_type IN ('tinyint', 'smallint', 'int', 'bigint', 'decimal', 'date', 'datetime', 'timestamp') OR (c.data_type = 'varchar' AND c.len <= 768))
  UNION ALL
  SELECT op.i, op.op, CONCAT('TRUNCATE TABLE `', @db, '`.`', l.table_name, '`;') FROM op JOIN leaf l WHERE op.op = 'truncate'
  UNION ALL
  SELECT op.i, op.op, CONCAT('CREATE TABLE `', @db, '`.`n', op.i, '_', DATE_FORMAT(NOW(), '%H%i%s'), '` (id bigint PRIMARY KEY, ',
           (SELECT GROUP_CONCAT(CONCAT('c', j, ' ', ELT(1 + (j * 5 + op.i * 3) % 12, 'int', 'bigint', 'decimal(18,2)', 'double', 'varchar(60)', 'varchar(200)', 'text', 'date', 'datetime', 'tinyint', 'varbinary(64)', 'json')) SEPARATOR ', ')
            FROM (SELECT 1 j UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6) jj),
           ') COMMENT ''lfc:rows=', 1 + FLOOR(RAND() * COALESCE(@new_rows, 10000)), ''';')
  FROM op WHERE op.op = 'create'
  UNION ALL
  SELECT op.i, op.op, CONCAT('ALTER TABLE `', @db, '`.`', c.table_name, '` DROP COLUMN `', c.column_name, '`;')
  FROM op JOIN col c WHERE op.op = 'drop_column' AND NOT c.keyish AND c.ncols > 2
  UNION ALL
  SELECT op.i, op.op, CONCAT('DROP TABLE `', @db, '`.`', l.table_name, '`;') FROM op JOIN leaf l WHERE op.op = 'drop_table'
)
SELECT CONCAT('/* ddl ', i, ' ', op, ' */ ', sql_text) FROM (
  SELECT cand.*, ROW_NUMBER() OVER (PARTITION BY i ORDER BY RAND()) AS rn FROM cand) q
WHERE rn = 1 ORDER BY i;
