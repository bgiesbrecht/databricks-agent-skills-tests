-- { echo "SET @db='lfc', @tables=100, @max_rows=1000000, @cols=12, @dist='even'"; cat make-dataset.sql; } | mysql -N -B -r | mysql
-- Writes DDL for @tables tables, each with a bigint key and @cols columns cycling through a menu of types (each table
-- starts at a different type), and the table's target row count in its comment:
--   @dist='even': table k gets CEIL(k * @max_rows / @tables) rows; @dist='random': a uniform pseudo-random 1..@max_rows
-- @dims=D, @fks=K (unset: 0): the first D tables are dimensions; every other table gets K foreign-key columns
--   (f1_t01_id ...) referencing the dimensions in turn (InnoDB indexes them)
SET SESSION cte_max_recursion_depth = 100000, group_concat_max_len = 1048576;
SELECT CONCAT('CREATE DATABASE IF NOT EXISTS `', @db, '`;');
WITH RECURSIVE k(k) AS (SELECT 1 UNION ALL SELECT k + 1 FROM k WHERE k < @tables),
     j(j) AS (SELECT 1 UNION ALL SELECT j + 1 FROM j WHERE j < @cols),
     f(f) AS (SELECT 1 UNION ALL SELECT f + 1 FROM f WHERE f < GREATEST(COALESCE(@fks, 0), 1)),
     menu(i, ty) AS (SELECT 0, 'int' UNION ALL SELECT 1, 'bigint' UNION ALL SELECT 2, 'smallint' UNION ALL SELECT 3, 'decimal(18,2)'
       UNION ALL SELECT 4, 'decimal(38,10)' UNION ALL SELECT 5, 'float' UNION ALL SELECT 6, 'double' UNION ALL SELECT 7, 'varchar(50)'
       UNION ALL SELECT 8, 'varchar(255)' UNION ALL SELECT 9, 'char(20)' UNION ALL SELECT 10, 'text' UNION ALL SELECT 11, 'date'
       UNION ALL SELECT 12, 'datetime' UNION ALL SELECT 13, 'timestamp NULL' UNION ALL SELECT 14, 'time' UNION ALL SELECT 15, 'tinyint'
       UNION ALL SELECT 16, 'varbinary(64)' UNION ALL SELECT 17, 'json' UNION ALL SELECT 18, 'enum(''a'',''b'',''c'')' UNION ALL SELECT 19, 'point')
SELECT CONCAT('CREATE TABLE `', @db, '`.`t', LPAD(k.k, LENGTH(@tables), '0'), '` (id bigint PRIMARY KEY, ',
              GROUP_CONCAT(CONCAT('c', j.j, '_', REGEXP_REPLACE(REGEXP_REPLACE(m.ty, '[^a-z0-9]+', '_'), '^_|_$', ''), ' ', m.ty) ORDER BY j.j SEPARATOR ', '),
              IF(k.k > COALESCE(@dims, 0) AND COALESCE(@fks, 0) > 0, (
                SELECT GROUP_CONCAT(CONCAT(', f', f.f, '_t', LPAD(1 + (k.k + f.f) % @dims, LENGTH(@tables), '0'), '_id bigint NOT NULL, FOREIGN KEY (f', f.f, '_t',
                                           LPAD(1 + (k.k + f.f) % @dims, LENGTH(@tables), '0'), '_id) REFERENCES `', @db, '`.`t', LPAD(1 + (k.k + f.f) % @dims, LENGTH(@tables), '0'), '` (id)')
                                    ORDER BY f.f SEPARATOR '') FROM f WHERE f.f <= @fks), ''),
              ') COMMENT ''lfc:rows=',
              IF(@dist = 'random', 1 + CAST(CONV(SUBSTR(MD5(k.k), 1, 15), 16, 10) AS UNSIGNED) % @max_rows, CEIL(k.k * @max_rows / @tables)), ''';')
FROM k JOIN j JOIN menu m ON m.i = (k.k + j.j) % 20
GROUP BY k.k ORDER BY k.k;
