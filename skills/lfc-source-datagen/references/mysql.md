# MySQL

Tested on MySQL 8.4 (Podman, arm64) in its default strict mode (`STRICT_TRANS_TABLES`). Uses `information_schema` and recursive CTEs (MySQL 8.0+). `ORDER BY key DESC LIMIT 1` is a backward index scan, and `DELETE ... ORDER BY key LIMIT k` deletes from one end through the index.

## Connect

```bash
SQL="mysql -h <host> -u <user> -N -B -r <database>"                            # password via MYSQL_PWD from a umask 077 file
# Local Podman: SQL="podman exec -i <container> mysql -uroot -N -B -r <database>"
```

`-N -B -r` prints bare values with no escaping, so the planners' output is runnable SQL. **Connect with a default database** (any one that exists, normally the target): `cast.sql` creates session-only temporary tables (`lfc_cols`, `lfc_keys`) in it.

## Files

**`cast.sql`: the cast table.** Builds the session table `lfc_cols`: for every column of every table in `@db` with a one-column key, the expression that turns `x.n` into a valid value, and for the key, the reverse. It disappears when the session ends.

```bash
cat > cast.sql <<'EOF'
-- Builds the session table lfc_cols: for every column of every table in @db with a one-column primary key, the SQL
-- expression that turns x.n (BIGINT, any n >= 1) into a valid value in strict mode, and for the key, the reverse.
-- Non-key AUTO_INCREMENT and generated columns are left out; is_unique marks columns that must keep plain n.
-- The insert, status, and boundary queries all read lfc_cols; it disappears when the session ends.
SET SESSION group_concat_max_len = 16777216;
-- Tags in comments, in braces: a column's lfc:v={integer expression in x.n} replaces n in its cast (spec formulas: sparse
-- keys, composite keys, value ranges); a table's lfc:n={expression of its columns} gives n back from a row, for composite
-- keys or tables without a primary key, and lfc:by={column} names the column n rises with (default: the first key column).
-- lfc_tabs: the tables that qualify (a one-column primary key, or lfc:n), with their key formula.
DROP TEMPORARY TABLE IF EXISTS lfc_tabs;
CREATE TEMPORARY TABLE lfc_tabs AS
SELECT t.table_schema AS db, t.table_name AS tbl, REGEXP_SUBSTR(t.table_comment, '(?<=lfc:n=\\{)[^}]*') AS nkey,
       REGEXP_SUBSTR(t.table_comment, '(?<=lfc:by=\\{)[^}]*') AS byc,
       (SELECT COUNT(*) FROM information_schema.statistics s WHERE s.table_schema = t.table_schema AND s.table_name = t.table_name
          AND s.index_name = 'PRIMARY') AS npk,
       (SELECT s.column_name FROM information_schema.statistics s WHERE s.table_schema = t.table_schema AND s.table_name = t.table_name
          AND s.index_name = 'PRIMARY' AND s.seq_in_index = 1) AS pk1
FROM information_schema.tables t WHERE t.table_schema = @db AND t.table_type = 'BASE TABLE'
HAVING npk = 1 OR nkey IS NOT NULL;
DROP TEMPORARY TABLE IF EXISTS lfc_cols;
CREATE TEMPORARY TABLE lfc_cols AS
SELECT c.table_schema AS db, c.table_name AS tbl, c.column_name AS col, c.ordinal_position AS pos, c.column_key = 'PRI' AS is_pk,
  c.column_key IN ('PRI', 'UNI') AS is_unique, fk.referenced_table_schema AS fk_db, fk.referenced_table_name AS fk_tbl,
  c.column_comment LIKE '%lfc:added%' AS added, REGEXP_SUBSTR(c.column_comment, '(?<=lfc:v=\\{)[^}]*') AS v,
  CASE c.data_type
    -- integers (signed / unsigned)
    WHEN 'tinyint'   THEN IF(c.column_type LIKE '%unsigned%', 'x.n % 255', 'x.n % 127')
    WHEN 'smallint'  THEN IF(c.column_type LIKE '%unsigned%', 'x.n % 65535', 'x.n % 32767')
    WHEN 'mediumint' THEN IF(c.column_type LIKE '%unsigned%', 'x.n % 16777215', 'x.n % 8388607')
    WHEN 'int'       THEN IF(c.column_type LIKE '%unsigned%', 'x.n % 4294967295', 'x.n % 2147483647')
    WHEN 'bigint'    THEN 'x.n'
    -- exact numeric: p digits of n times an exact 10^-s (no division: it would round to 4 decimals)
    WHEN 'decimal'   THEN CONCAT('CAST((x.n % 1', REPEAT('0', LEAST(c.numeric_precision, 18)), ')',
                                 IF(c.numeric_scale > 0, CONCAT(' * 0.', REPEAT('0', c.numeric_scale - 1), '1'), ''),
                                 ' AS DECIMAL(', c.numeric_precision, ',', c.numeric_scale, '))')
    WHEN 'float'     THEN 'CAST(x.n AS FLOAT)'
    WHEN 'double'    THEN 'CAST(x.n AS DOUBLE)'
    WHEN 'bit'       THEN IF(c.numeric_precision = 64, 'x.n', CONCAT('x.n % ', CAST(POW(2, c.numeric_precision) AS UNSIGNED)))
    -- date/time: epoch plus n days or seconds, wrapped to stay inside the type's range
    WHEN 'date'      THEN 'DATE_ADD(''1970-01-01'', INTERVAL x.n % 2932896 DAY)'
    WHEN 'datetime'  THEN 'DATE_ADD(''1970-01-01 00:00:00'', INTERVAL x.n % 253402300800 SECOND)'
    WHEN 'timestamp' THEN 'FROM_UNIXTIME(1 + x.n % 2147483646)'
    WHEN 'time'      THEN 'SEC_TO_TIME(x.n % 86400)'
    WHEN 'year'      THEN '1901 + x.n % 255'
    -- strings: 19-digit zero-padded n first (so a key maps back to n), then MD5 filler, cut to the length
    WHEN 'char' THEN 's' WHEN 'varchar' THEN 's' WHEN 'tinytext' THEN 's' WHEN 'text' THEN 's'
    WHEN 'mediumtext' THEN 's' WHEN 'longtext' THEN 's'
    -- binary: 8-byte big-endian n at the start and (from 16 bytes) the end, MD5 bytes between, to the length
    WHEN 'binary' THEN 'b' WHEN 'varbinary' THEN 'b' WHEN 'tinyblob' THEN 'b' WHEN 'blob' THEN 'b'
    WHEN 'mediumblob' THEN 'b' WHEN 'longblob' THEN 'b'
    -- other scalars
    WHEN 'json'      THEN 'JSON_OBJECT(''n'', x.n)'
    WHEN 'enum'      THEN CONCAT('1 + x.n % ', LENGTH(c.column_type) - LENGTH(REPLACE(c.column_type, ',', '')) + 1)
    WHEN 'set'       THEN CONCAT('x.n % ', CAST(POW(2, LENGTH(c.column_type) - LENGTH(REPLACE(c.column_type, ',', '')) + 1) AS UNSIGNED))
    -- spatial: coordinates 0..89, valid as latitude and longitude, in the column's SRID
    WHEN 'point'      THEN CONCAT('ST_GeomFromText(CONCAT(''POINT('', x.n % 90, '' '', x.n % 89, '')''), ', COALESCE(c.srs_id, 0), ')')
    WHEN 'geometry'   THEN CONCAT('ST_GeomFromText(CONCAT(''POINT('', x.n % 90, '' '', x.n % 89, '')''), ', COALESCE(c.srs_id, 0), ')')
    WHEN 'linestring' THEN CONCAT('ST_GeomFromText(CONCAT(''LINESTRING(0 0, '', 1 + x.n % 89, '' '', 1 + x.n % 89, '')''), ', COALESCE(c.srs_id, 0), ')')
    WHEN 'polygon'    THEN CONCAT('ST_GeomFromText(CONCAT(''POLYGON((0 0, '', 1 + x.n % 89, '' 0, '', 1 + x.n % 89, '' '', 1 + x.n % 89, '', 0 '', 1 + x.n % 89, '', 0 0))''), ', COALESCE(c.srs_id, 0), ')')
    WHEN 'multipoint' THEN CONCAT('ST_GeomFromText(CONCAT(''MULTIPOINT(0 0, '', x.n % 90, '' '', x.n % 89, '')''), ', COALESCE(c.srs_id, 0), ')')
    WHEN 'multilinestring' THEN CONCAT('ST_GeomFromText(CONCAT(''MULTILINESTRING((0 0, '', 1 + x.n % 89, '' '', 1 + x.n % 89, ''))''), ', COALESCE(c.srs_id, 0), ')')
    WHEN 'multipolygon' THEN CONCAT('ST_GeomFromText(CONCAT(''MULTIPOLYGON(((0 0, '', 1 + x.n % 89, '' 0, '', 1 + x.n % 89, '' '', 1 + x.n % 89, '', 0 '', 1 + x.n % 89, '', 0 0)))''), ', COALESCE(c.srs_id, 0), ')')
    WHEN 'geomcollection' THEN CONCAT('ST_GeomFromText(CONCAT(''GEOMETRYCOLLECTION(POINT('', x.n % 90, '' '', x.n % 89, ''))''), ', COALESCE(c.srs_id, 0), ')')
  END AS expr0,
  -- audit: the column decoded back to n, compared with the key's n ({k}) modulo the cast's wrap; NULL if not exact
  CASE c.data_type
    WHEN 'tinyint'   THEN CONCAT('`', c.column_name, '` = {k} % ', IF(c.column_type LIKE '%unsigned%', 255, 127))
    WHEN 'smallint'  THEN CONCAT('`', c.column_name, '` = {k} % ', IF(c.column_type LIKE '%unsigned%', 65535, 32767))
    WHEN 'mediumint' THEN CONCAT('`', c.column_name, '` = {k} % ', IF(c.column_type LIKE '%unsigned%', 16777215, 8388607))
    WHEN 'int'       THEN CONCAT('`', c.column_name, '` = {k} % ', IF(c.column_type LIKE '%unsigned%', 4294967295, 2147483647))
    WHEN 'bigint'    THEN CONCAT('`', c.column_name, '` = {k}')
    WHEN 'decimal'   THEN CONCAT('`', c.column_name, '` * 1', REPEAT('0', c.numeric_scale), ' = {k} % 1', REPEAT('0', LEAST(c.numeric_precision, 18)))
    WHEN 'double'    THEN CONCAT('`', c.column_name, '` = {k}')
    WHEN 'bit'       THEN CONCAT('`', c.column_name, '` + 0 = ', IF(c.numeric_precision = 64, '{k}', CONCAT('{k} % ', CAST(POW(2, c.numeric_precision) AS UNSIGNED))))
    WHEN 'date'      THEN CONCAT('DATEDIFF(`', c.column_name, '`, ''1970-01-01'') = {k} % 2932896')
    WHEN 'datetime'  THEN CONCAT('TIMESTAMPDIFF(SECOND, ''1970-01-01 00:00:00'', `', c.column_name, '`) = {k} % 253402300800')
    WHEN 'timestamp' THEN CONCAT('UNIX_TIMESTAMP(`', c.column_name, '`) = 1 + {k} % 2147483646')
    WHEN 'time'      THEN CONCAT('TIME_TO_SEC(`', c.column_name, '`) = {k} % 86400')
    WHEN 'year'      THEN CONCAT('`', c.column_name, '` - 1901 = {k} % 255')
    WHEN 'json'      THEN CONCAT('JSON_EXTRACT(`', c.column_name, '`, ''$.n'') = {k}')
    WHEN 'enum'      THEN CONCAT('`', c.column_name, '` + 0 - 1 = {k} % ', LENGTH(c.column_type) - LENGTH(REPLACE(c.column_type, ',', '')) + 1)
    WHEN 'set'       THEN CONCAT('`', c.column_name, '` + 0 = {k} % ', CAST(POW(2, LENGTH(c.column_type) - LENGTH(REPLACE(c.column_type, ',', '')) + 1) AS UNSIGNED))
    ELSE CASE
      -- strings and binaries: decided after len is known (see the UPDATE below)
      WHEN c.data_type IN ('char', 'varchar', 'tinytext', 'text', 'mediumtext', 'longtext') THEN 's'
      WHEN c.data_type IN ('binary', 'varbinary', 'tinyblob', 'blob', 'mediumblob', 'longblob') THEN 'b'
    END
  END AS chk,
  -- length to generate: the declared length, or @lob_len (default 100) for text and blob types, capped at the type's max
  -- (or the column's lfc:len={L}, for a source's average width)
  COALESCE(CAST(REGEXP_SUBSTR(c.column_comment, '(?<=lfc:len=\\{)[0-9]+') AS UNSIGNED),
           CASE WHEN c.data_type IN ('char', 'varchar', 'binary', 'varbinary') THEN c.character_maximum_length
                ELSE LEAST(GREATEST(COALESCE(@lob_len, 100), 38), c.character_maximum_length) END) AS len,
  CASE WHEN c.data_type IN ('tinyint', 'smallint', 'mediumint', 'int', 'bigint') THEN CONCAT('`', c.column_name, '`')
       WHEN c.data_type IN ('char', 'varchar') AND c.character_maximum_length >= 19 THEN CONCAT('CAST(LEFT(`', c.column_name, '`, 19) AS UNSIGNED)')
  END AS to_int
FROM information_schema.columns c
JOIN lfc_tabs tb ON tb.db = c.table_schema AND tb.tbl = c.table_name
LEFT JOIN (SELECT table_schema, table_name, column_name, MAX(referenced_table_schema) AS referenced_table_schema,     -- one-column FKs
                  MAX(referenced_table_name) AS referenced_table_name
           FROM information_schema.key_column_usage k
           WHERE table_schema = @db AND referenced_table_name IS NOT NULL
             AND (SELECT COUNT(*) FROM information_schema.key_column_usage k2 WHERE k2.constraint_schema = k.constraint_schema
                    AND k2.constraint_name = k.constraint_name AND k2.table_name = k.table_name) = 1
           GROUP BY table_schema, table_name, column_name) fk
  ON fk.table_schema = c.table_schema AND fk.table_name = c.table_name AND fk.column_name = c.column_name AND c.column_key <> 'PRI'
WHERE c.table_schema = @db AND c.generation_expression = ''
  AND NOT (c.extra LIKE '%auto_increment%' AND c.column_key <> 'PRI');     -- the database numbers a non-key AUTO_INCREMENT column
-- strings: zero-padded n at the start and (from 38 characters) the end, MD5 filler between, to the length;
-- the audit checks both ends and the length, so a truncated value shows up. A non-digit where n should be is a mismatch.
UPDATE lfc_cols SET
  expr0 = CASE WHEN len < 19 THEN CONCAT('RIGHT(LPAD(x.n, 19, ''0''), ', len, ')')
               WHEN len < 38 THEN CONCAT('LEFT(CONCAT(LPAD(x.n, 19, ''0''), MD5(x.n)), ', len, ')')
               ELSE CONCAT('CONCAT(LPAD(x.n, 19, ''0''), LEFT(REPEAT(MD5(x.n), ', GREATEST(CEIL((len - 38) / 32), 1), '), ', len - 38,
                           '), LPAD(x.n, 19, ''0''))') END,
  chk = CASE WHEN len < 19 THEN CONCAT('IF(`', col, '` REGEXP ''^[0-9]+$'', CAST(`', col, '` AS UNSIGNED), NULL) = {k} % 1', REPEAT('0', len))
             -- from 38 characters both ends carry n, which is enough to catch truncation and keeps values written before
             -- a column was widened valid; shorter strings must have the exact length
             WHEN len >= 38 THEN CONCAT('IF(LEFT(`', col, '`, 19) REGEXP ''^[0-9]{19}$'', CAST(LEFT(`', col, '`, 19) AS UNSIGNED), NULL) = {k} AND RIGHT(`', col, '`, 19) = LPAD({k}, 19, ''0'')')
             ELSE CONCAT('IF(LEFT(`', col, '`, 19) REGEXP ''^[0-9]{19}$'', CAST(LEFT(`', col, '`, 19) AS UNSIGNED), NULL) = {k} AND CHAR_LENGTH(`', col, '`) = ', len) END
WHERE expr0 = 's';
UPDATE lfc_cols SET
  expr0 = IF(len < 16, CONCAT('LEFT(CONCAT(UNHEX(LPAD(HEX(x.n), 16, ''0'')), UNHEX(MD5(x.n))), ', len, ')'),
             CONCAT('CONCAT(UNHEX(LPAD(HEX(x.n), 16, ''0'')), LEFT(REPEAT(UNHEX(MD5(x.n)), ', GREATEST(CEIL((len - 16) / 16), 1), '), ', len - 16,
                    '), UNHEX(LPAD(HEX(x.n), 16, ''0'')))')),
  chk = IF(len < 8, NULL, CONCAT('CAST(CONV(HEX(LEFT(`', col, '`, 8)), 16, 10) AS UNSIGNED) = {k} AND LENGTH(`', col, '`) = ', len,
                                 IF(len >= 16, CONCAT(' AND RIGHT(`', col, '`, 8) = UNHEX(LPAD(HEX({k}), 16, ''0''))'), '')))
WHERE expr0 = 'b';
-- a column added after rows existed (tagged 'lfc:added' by plan-ddl.sql) may be NULL in the older rows
UPDATE lfc_cols SET chk = CONCAT('(`', col, '` IS NULL OR ', chk, ')') WHERE added AND chk IS NOT NULL;
-- a column with a formula (lfc:v): its cast of the formula, checked against the formula at n
UPDATE lfc_cols SET expr0 = REPLACE(expr0, 'x.n', CONCAT('(', v, ')')), chk = REPLACE(chk, '{k}', CONCAT('(', REPLACE(v, 'x.n', '{k}'), ')'))
WHERE v IS NOT NULL;
-- each table's key: the column to probe, n from a row (the key decoded, or lfc:n), and the cast from n for a one-column key
-- (a temporary table can't appear twice in one MySQL query, so the FK, audit, and delete queries join this copy)
DROP TEMPORARY TABLE IF EXISTS lfc_keys;
CREATE TEMPORARY TABLE lfc_keys AS
SELECT tb.db, tb.tbl, COALESCE(tb.byc, tb.pk1) AS pk, COALESCE(tb.nkey, c.to_int) AS pk_int, IF(tb.npk = 1, c.expr0, NULL) AS pk_expr,
       tb.nkey IS NOT NULL AS has_n
FROM lfc_tabs tb LEFT JOIN lfc_cols c ON c.db = tb.db AND c.tbl = tb.tbl AND c.col = tb.pk1
WHERE tb.nkey IS NOT NULL OR c.to_int IS NOT NULL;
-- foreign keys: parent_min + scramble(n) % (parent_max - parent_min + 1), cast to the parent key's type, with the parent's
-- range probed when the INSERT runs, so every value is an existing key (NULL while the parent is empty)
UPDATE lfc_cols c JOIN lfc_keys k ON k.db = c.fk_db AND k.tbl = c.fk_tbl AND k.pk_expr IS NOT NULL AND c.v IS NULL
SET c.expr0 = REPLACE(k.pk_expr, 'x.n', CONCAT(
      '((SELECT ', k.pk_int, ' FROM `', k.db, '`.`', k.tbl, '` ORDER BY `', k.pk, '` LIMIT 1) + ((((x.n % 2147483647) * ((x.n % 2147483647 + ',
      FLOOR(1 + RAND() * 2147483645), ') % 2147483647)) % 2147483647 + ', FLOOR(RAND() * 2147483647), ') % 2147483647) % ((SELECT ', k.pk_int,
      ' FROM `', k.db, '`.`', k.tbl, '` ORDER BY `', k.pk, '` DESC LIMIT 1) - (SELECT ', k.pk_int, ' FROM `', k.db, '`.`', k.tbl,
      '` ORDER BY `', k.pk, '` LIMIT 1) + 1))')),
    c.chk = NULL;                                                 -- FK values depend on the parent, so the audit skips them
EOF
```

**`plan-insert.sql`: inserts** (`@mode='append'` adds `@rows` per table; `@mode='fill'` tops each table up to its `lfc:rows=` comment; `@order` and `@data` choose shuffled keys and scrambled or random values):

```bash
cat > plan-insert.sql <<'EOF'
-- { echo "SET @db='lfc', @rows=10000, @src='series', @mode='append'"; cat cast.sql plan-insert.sql; } | mysql -N -B -r > inserts.sql
-- Emits one INSERT per table in @db with a usable one-column primary key (cast.sql builds lfc_cols first).
--   @mode='append': add @rows rows above the current max key.
--   @mode='fill': top the table up to the row count in its comment ('lfc:rows=<n>'), at most @rows per statement.
-- @src='series' uses a recursive CTE (keep @rows <= 100000); @src='seed' reads lfc_seed.seed.
-- @order='random' (default) | 'asc' | 'desc': the order the new keys are inserted in (always exactly max+1 .. max+need).
-- @data='seq' | 'scramble' | 'random': non-key columns from n; from n scrambled per column, (m * ((m + a) mod p) + b) mod p
--   with m = n mod p, p = 2^31 - 1, a and b drawn once per column at plan time (same rows on every run); or from one RAND()
--   value per row, scrambled per column. Unset @data means 'seq'. Key and UNIQUE columns always use plain n.
-- Foreign keys (cast.sql) take values inside the parent's current key range. Each statement starts with /* lfc level N */:
--   parents are level 0, a table referencing them is one level higher; run the levels in order.
-- Tables with a composite key or none qualify when their comment has lfc:n={...}, and a column's lfc:v={...} replaces n in
--   its cast (cast.sql); each INSERT then probes the max of n among the rows with the highest lfc:by column.
-- @plain_every=k, @block=B (unset or 0 is off): every k-th block of B keys ((n - 1) DIV B % k = 0) keeps plain values in
--   every column whatever @data is, so those rows can be audited from the key alone (plan-audit.sql).
WITH RECURSIVE e AS (SELECT DISTINCT table_name AS child, referenced_table_name AS parent FROM information_schema.key_column_usage
                     WHERE table_schema = @db AND referenced_table_schema = @db AND referenced_table_name <> table_name),
l (tbl, lvl) AS (SELECT table_name, 0 FROM information_schema.tables WHERE table_schema = @db
                 UNION ALL SELECT e.child, l.lvl + 1 FROM e JOIN l ON l.tbl = e.parent WHERE l.lvl < 50),
lv AS (SELECT tbl, MAX(lvl) AS lvl FROM l GROUP BY tbl)
SELECT CONCAT('/* lfc level ', lv.lvl, ' */ ', IF(@src = 'seed', '', CONCAT('SET SESSION cte_max_recursion_depth = ', GREATEST(@rows, 1000), '; ')),
         'INSERT INTO `', k.db, '`.`', k.tbl, '` (', k.cols, ') ',
         IF(@src = 'seed', '', CONCAT('WITH RECURSIVE g(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM g WHERE i < ', @rows, ') ')),
         'SELECT /*+ NO_MERGE(x) */ ', k.exprs, ' FROM (SELECT b.base + g.', IF(COALESCE(@order, 'random') = 'random' AND @src = 'seed', 'r', 'i'), ' AS n',
         IF(@data = 'random', ', FLOOR(RAND() * 2147483647) AS r', ''), ' FROM ',
         '(SELECT COALESCE(hi, 0) AS base, ',
         IF(@mode = 'fill', CONCAT('LEAST(', @rows, ', GREATEST(', t.target, ' - COALESCE(hi - lo + 1, 0), 0))'), @rows), ' AS need FROM ',
         IF(kk.has_n,
            CONCAT('(SELECT (SELECT MAX(', kk.pk_int, ') FROM `', k.db, '`.`', k.tbl, '` WHERE `', kk.pk, '` = (SELECT `', kk.pk, '` FROM `', k.db, '`.`', k.tbl,
                   '` ORDER BY `', kk.pk, '` DESC LIMIT 1)) AS hi, (SELECT MIN(', kk.pk_int, ') FROM `', k.db, '`.`', k.tbl, '` WHERE `', kk.pk, '` = (SELECT `',
                   kk.pk, '` FROM `', k.db, '`.`', k.tbl, '` ORDER BY `', kk.pk, '` LIMIT 1)) AS lo) m) b, '),
            CONCAT('(SELECT (SELECT ', kk.pk_int, ' FROM `', k.db, '`.`', k.tbl, '` ORDER BY `', kk.pk, '` DESC LIMIT 1) AS hi, ',
                   '(SELECT ', kk.pk_int, ' FROM `', k.db, '`.`', k.tbl, '` ORDER BY `', kk.pk, '` LIMIT 1) AS lo) m) b, ')),
         IF(@src = 'seed', 'lfc_seed.seed g', 'g'), ' WHERE g.', IF(COALESCE(@order, 'random') = 'random' AND @src = 'seed', 'r', 'i'), ' <= b.need',
         CASE COALESCE(@order, 'random') WHEN 'asc' THEN ' ORDER BY g.i' WHEN 'desc' THEN ' ORDER BY g.i DESC'
              ELSE IF(@src <> 'seed', ' ORDER BY RAND()', '') END, ') x;')
FROM (SELECT db, tbl, GROUP_CONCAT(CONCAT('`', col, '`') ORDER BY pos SEPARATOR ', ') AS cols,
             GROUP_CONCAT(COALESCE(IF(is_unique OR fk_tbl IS NOT NULL OR v IS NOT NULL OR COALESCE(@data, 'seq') = 'seq', expr0,
                 CONCAT(IF(COALESCE(@plain_every, 0) > 0, CONCAT('CASE WHEN (x.n - 1) DIV ', COALESCE(@block, 1000), ' % ', @plain_every,
                                                                 ' = 0 THEN ', expr0, ' ELSE '), ''),
                 REPLACE(expr0, 'x.n', CONCAT('((((', @v := IF(@data = 'random', 'x.r', 'x.n'), ' % 2147483647) * ((', @v, ' % 2147483647 + ',
                   FLOOR(1 + RAND() * 2147483645), ') % 2147483647)) % 2147483647 + ', FLOOR(RAND() * 2147483647), ') % 2147483647 + 1)')),
                 IF(COALESCE(@plain_every, 0) > 0, ' END', ''))), 'NULL')
                 ORDER BY pos SEPARATOR ', ') AS exprs
      FROM lfc_cols GROUP BY db, tbl) k
JOIN lfc_keys kk ON kk.db = k.db AND kk.tbl = k.tbl
JOIN (SELECT table_schema, table_name, CAST(REGEXP_SUBSTR(table_comment, '(?<=lfc:rows=)[0-9]+') AS UNSIGNED) AS target
      FROM information_schema.tables WHERE table_schema = @db) t ON t.table_schema = k.db AND t.table_name = k.tbl
JOIN lv ON lv.tbl = k.tbl
WHERE @mode <> 'fill' OR t.target IS NOT NULL
ORDER BY lv.lvl, k.tbl;
EOF
```

**`plan-audit.sql`: audit plain rows** (decode every checkable column back to `n` and compare it with the key; with `@plain_every` it checks only the plain blocks):

```bash
cat > plan-audit.sql <<'EOF'
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
EOF
```

**`plan-delete.sql`: deletes from one end** (`@end='head'` or `'tail'`), dimension first: it re-points foreign keys that reference the keys going away, then deletes. It never empties a table:

```bash
cat > plan-delete.sql <<'EOF'
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
                          AND (c.column_key = 'PRI' OR c.column_comment LIKE '%lfc:v={%'))),  -- FK is part of its key, or a formula
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
EOF
```

**`plan-status.sql`: min, max, and rows** for every table, one query per 500 tables:

```bash
cat > plan-status.sql <<'EOF'
-- mysql -N -B -r -e "SET @db='lfc'; SOURCE my-plan-status.sql" > status.sql
-- Emits SELECTs (500 tables each) returning table, min key, max key, rows (= max - min + 1, no COUNT(*)), target ('lfc:rows=', if set).
SET SESSION group_concat_max_len = 16777216;
SELECT CONCAT(GROUP_CONCAT(sel ORDER BY k SEPARATOR ' UNION ALL '), ';') FROM (
  SELECT ROW_NUMBER() OVER (ORDER BY s.table_name) - 1 AS k,
         CONCAT('SELECT ''', s.table_name, ''', lo, hi, COALESCE(hi - lo + 1, 0), ''', COALESCE(REGEXP_SUBSTR(s.cm, '(?<=lfc:rows=)[0-9]+'), ''),
                ''' FROM (SELECT ', IF(s.nkey IS NULL,
                  CONCAT('(SELECT ', i, ' FROM `', s.table_schema, '`.`', s.table_name, '` ORDER BY `', s.column_name, '` LIMIT 1) lo, (SELECT ', i,
                         ' FROM `', s.table_schema, '`.`', s.table_name, '` ORDER BY `', s.column_name, '` DESC LIMIT 1) hi'),
                  CONCAT('(SELECT MIN(', s.nkey, ') FROM `', s.table_schema, '`.`', s.table_name, '` WHERE `', s.byc, '` = (SELECT `', s.byc, '` FROM `',
                         s.table_schema, '`.`', s.table_name, '` ORDER BY `', s.byc, '` LIMIT 1)) lo, (SELECT MAX(', s.nkey, ') FROM `', s.table_schema, '`.`',
                         s.table_name, '` WHERE `', s.byc, '` = (SELECT `', s.byc, '` FROM `', s.table_schema, '`.`', s.table_name, '` ORDER BY `', s.byc,
                         '` DESC LIMIT 1)) hi')), ') m') AS sel
  FROM (SELECT t.table_schema, t.table_name, t.table_comment AS cm, p.column_name, p.npk,           -- a one-column key, or a key formula
               REGEXP_SUBSTR(t.table_comment, '(?<=lfc:n=\\{)[^}]*') AS nkey,
               COALESCE(REGEXP_SUBSTR(t.table_comment, '(?<=lfc:by=\\{)[^}]*'), p.column_name) AS byc
        FROM information_schema.tables t
        LEFT JOIN (SELECT table_schema, table_name, MAX(IF(seq_in_index = 1, column_name, NULL)) AS column_name, COUNT(*) AS npk
                   FROM information_schema.statistics WHERE table_schema = @db AND index_name = 'PRIMARY' GROUP BY table_schema, table_name) p
          ON p.table_schema = t.table_schema AND p.table_name = t.table_name
        WHERE t.table_schema = @db AND t.table_type = 'BASE TABLE'
          AND (p.npk = 1 OR t.table_comment LIKE '%lfc:n={%')) s
  LEFT JOIN information_schema.columns c ON c.table_schema = s.table_schema AND c.table_name = s.table_name AND c.column_name = s.column_name
  JOIN LATERAL (SELECT IF(c.data_type IN ('char', 'varchar'), CONCAT('CAST(LEFT(`', c.column_name, '`, 19) AS UNSIGNED)'),
                          CONCAT('`', c.column_name, '`')) AS i) x ON TRUE
) q GROUP BY k DIV 500 ORDER BY k DIV 500;
EOF
```

**`make-dataset.sql`: create N tables** with a variety of types and a target row count each:

```bash
cat > make-dataset.sql <<'EOF'
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
EOF
```

**`plan-ddl.sql`: random DDL** (see "Schema changes during a load" in the skill):

```bash
cat > plan-ddl.sql <<'EOF'
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
EOF
```

**`skipped.sql`: tables the planner leaves out:**

```bash
cat > skipped.sql <<'EOF'
-- Tables the planner skips: no primary key, a composite key, or a key that can't be turned back into n, unless the table
-- has a key formula (lfc:n={...} in its comment).
SELECT t.table_name, CASE WHEN k.n IS NULL THEN 'no primary key' WHEN k.n > 1 THEN 'composite key' ELSE CONCAT('key type ', c.column_type) END
FROM information_schema.tables t
LEFT JOIN (SELECT table_name, COUNT(*) AS n, MAX(column_name) AS col FROM information_schema.statistics
           WHERE table_schema = @db AND index_name = 'PRIMARY' GROUP BY table_name) k ON k.table_name = t.table_name
LEFT JOIN information_schema.columns c ON c.table_schema = @db AND c.table_name = t.table_name AND c.column_name = k.col
WHERE t.table_schema = @db AND t.table_type = 'BASE TABLE' AND t.table_comment NOT LIKE '%lfc:n={%'     -- lfc:n: a key formula
  AND (k.n IS NULL OR k.n > 1 OR NOT (c.data_type IN ('tinyint', 'smallint', 'mediumint', 'int', 'bigint')
                                      OR (c.data_type IN ('char', 'varchar') AND c.character_maximum_length >= 19)))
ORDER BY 1;
EOF
```

**`boundary.sql`: check the casts for a schema** with real strict-mode INSERTs into the tables of `@db` (any `ERROR` is a bad cast). It inserts test rows, so run it on a scratch database.

```bash
cat > boundary.sql <<'EOF'
-- one strict-mode INSERT per column, for n at the boundaries (id = column position * 10 + row number)
SELECT CONCAT('INSERT INTO `', db, '`.`', tbl, '` (id, `', col, '`) SELECT ', pos, ' * 10 + x.k, ', COALESCE(expr0, 'NULL'),
              ' FROM (VALUES ROW(1, 1), ROW(2, 2), ROW(1000003, 3), ROW(1000000000039, 4), ROW(4611686018427387904, 5), ROW(9223372036854775806, 6)) x(n, k);')
FROM lfc_cols WHERE NOT is_pk ORDER BY pos;
EOF
```

## Run

The planners read user variables, so set them in the same session:

```bash
D=lfc                                                                          # database (schema)
# A dataset: 100 tables, even spread up to 1M rows, 12 columns each; the 10 smallest are dimensions, the rest have 2 FKs each
{ echo "SET @db='$D', @tables=100, @max_rows=1000000, @cols=12, @dist='even', @dims=10, @fks=2;"; cat make-dataset.sql; } | $SQL | $SQL
{ echo "SET @db='$D';"; cat skipped.sql; } | $SQL                              # should print nothing
# Seed table: one 1,000-row VALUES list, then each INSERT ... SELECT doubles it (about 7 KB of SQL for 1,024,000 keys)
want=1000000
{ echo "CREATE DATABASE IF NOT EXISTS lfc_seed; DROP TABLE IF EXISTS lfc_seed.seed; CREATE TABLE lfc_seed.seed (i bigint PRIMARY KEY);"
  echo "INSERT INTO lfc_seed.seed (i) VALUES $(printf '(%s),' $(seq 1 1000) | sed 's/,$//');"
  n=1000; while [ $n -lt $want ]; do
    echo "INSERT INTO lfc_seed.seed (i) SELECT s.i + b.m FROM lfc_seed.seed s, (SELECT MAX(i) AS m FROM lfc_seed.seed) b;"; n=$((n * 2))
  done
  # r: a random permutation of i, for shuffled keys (InnoDB stores rows in i order, so a scan returns r shuffled)
  echo "CREATE TABLE lfc_seed.seed_r (i bigint PRIMARY KEY, r bigint NOT NULL);"
  echo "INSERT INTO lfc_seed.seed_r SELECT i, ROW_NUMBER() OVER (ORDER BY RAND()) FROM lfc_seed.seed;"
  echo "DROP TABLE lfc_seed.seed; RENAME TABLE lfc_seed.seed_r TO lfc_seed.seed;"; } | $SQL
for round in $(seq 1 50); do                      # fill until done: re-plan every round, so DDL and failed INSERTs are picked up
  { echo "SET @db='$D', @rows=100000, @src='seed', @mode='fill', @order='random', @data='scramble', @plain_every=4, @block=1000, @lob_len=100;"; cat cast.sql plan-insert.sql; } | $SQL > inserts.sql
  for l in $(grep -o '^/\* lfc level [0-9]*' inserts.sql | awk '{ print $4 }' | sort -un); do   # levels in order, 2 sessions each (see calibrate.md)
    grep "^/\* lfc level $l \*/" inserts.sql | awk -v n=2 '{ print > ("part-" NR % n ".sql") }'
    for f in part-*.sql; do $SQL < "$f" 2>> fill.err & done; wait; rm -f part-*.sql
  done
  { echo "SET @db='$D';"; cat plan-status.sql; } | $SQL > status.sql && $SQL < status.sql > status.out   # table, min, max, rows, target
  awk -F'\t' '$5 != "" && $4 < $5 { n++ } END { exit n > 0 }' status.out && break
done
awk '{ t += $4 } END { print NR " tables, " t " rows" }' status.out
{ echo "SET @db='$D', @plain_every=4, @block=1000, @lob_len=100;"; cat cast.sql plan-audit.sql; } | $SQL > audit.sql && $SQL < audit.sql   # same @lob_len; bad must be 0
```

Other operations:

```bash
{ echo "SET @db='$D', @rows=10000, @src='series', @mode='append', @order='random', @data='random';"; cat cast.sql plan-insert.sql; } | $SQL > more.sql && $SQL < more.sql   # random data: not auditable
{ echo "SET @db='$D', @rows=1000, @end='tail';"; cat cast.sql plan-delete.sql; } | $SQL > deletes.sql && $SQL < deletes.sql   # one session
{ echo "SET @db='$D', @ops=8;"; cat plan-ddl.sql; } | $SQL > ddl.sql && $SQL --force < ddl.sql 2>&1 | grep ERROR || true   # 8 random DDL; then run the fill loop again
{ echo "SET @db='<scratch-db>';"; cat cast.sql boundary.sql; } | $SQL > bnd.sql && $SQL --force < bnd.sql 2>&1 | grep ERROR || echo "no bad casts"
```

## Types

`n` is the row's `BIGINT`. All casts are in `cast.sql`; this table summarizes them. "Key" types can be the primary key.

| Category | Types | Range | Value from `n` | Key |
|---|---|---|---|---|
| Integer | `tinyint`, `smallint`, `mediumint`, `int`, `bigint`, signed or `unsigned`; `boolean` (= `tinyint(1)`) | signed ±127 / ±32,767 / ±8,388,607 / ±2,147,483,647 / ±9.2 × 10¹⁸; unsigned 255 / 65,535 / 16,777,215 / 4,294,967,295 / 1.8 × 10¹⁹ | `n % <type max>` (`boolean` gets 0 … 126) | yes |
| Exact numeric | `decimal(p,s)` (p ≤ 65, s ≤ 30) | below 10^(p−s) | `(n % 10^min(p,18)) * 0.0…01` (exact; dividing would round to 4 decimals and overflow `decimal(12,10)`) | — |
| Float | `float`, `double` | 7 / 15 significant digits | `CAST(n AS FLOAT)`, `CAST(n AS DOUBLE)` | — |
| Bit | `bit(M)` (M ≤ 64) | 0 … 2^M − 1 | `n % 2^M` | — |
| Date / time | `date`, `datetime(fsp)`, `timestamp(fsp)`, `time(fsp)`, `year` | `date` 1000 … 9999; `timestamp` 1970-01-01 00:00:01 … 2038-01-19 UTC; `time` ±838 h; `year` 1901 … 2155 | 1970-01-01 plus `n % 2,932,896` days or `n % 253,402,300,800` s; `FROM_UNIXTIME(1 + n % 2147483646)`; `SEC_TO_TIME(n % 86400)`; `1901 + n % 255` | — |
| String | `char(L)` (L ≤ 255), `varchar(L)`, `tinytext`, `text`, `mediumtext`, `longtext` | `varchar` up to 65,535 bytes (16,383 utf8mb4 characters), less the rest of the row | exactly L characters (`@lob_len` for text types, capped at the type's max): zero-padded 19-digit `n`, MD5 filler, and from L = 38 the zero-padded `n` again at the end; L < 19: the last L digits | `char`/`varchar` with L ≥ 19 |
| Binary | `binary(L)`, `varbinary(L)`, `tinyblob` … `longblob` | | exactly L bytes (`@lob_len` for blobs): 8-byte big-endian `n`, MD5 bytes, and from 16 bytes the 8-byte `n` again at the end | — |
| JSON | `json` | `max_allowed_packet` | `JSON_OBJECT('n', n)` | — |
| Enum, set | `enum(...)` (≤ 65,535 values), `set(...)` (≤ 64 members) | | value number `1 + n % <count>`; bit mask `n % 2^<members>` | — |
| Spatial | `geometry`, `point`, `linestring`, `polygon`, `multipoint`, `multilinestring`, `multipolygon`, `geometrycollection`, in any `SRID` | | WKT shapes with coordinates 0 … 89 (valid latitude and longitude), in the column's SRID | — |
| Not supported (`NULL`) | `vector` (MySQL 9) and anything else | | | |

Tested: every type above at `n` = 1, 2, 1,000,003, 1,000,000,000,039, 2⁶², and 2⁶³ − 2 with strict-mode INSERTs, no errors (58 columns, 348 rows).

**Audit (`chk` in `lfc_cols`)** decodes these back to `n` modulo their wrap (strings and binaries also at the end, and their exact length, so truncation shows up): integers, `decimal`, `double`, `bit`, `date`, `datetime`, `timestamp`, `time`, `year`, all string types (non-digits where `n` should be count as bad), `binary`/`varbinary` of 8 bytes or more and the blob types, `json`, `enum`, and `set`. `float` and the spatial types aren't checked. Tested: 0 bad rows on plain blocks; a changed date, varchar, JSON value, or binary value each shows up as one bad row, and so does a 5,000-character `mediumtext` cut to 4,096, a 5,000-byte `mediumblob` cut to 4,000, or a `varchar(100)` / `varbinary(50)` one short. A change in the middle filler isn't detected.

## Limits

| Limit | Value | Source |
|---|---|---|
| Columns per table | 1,017 with InnoDB (tested: 1,018 fails "Too many columns"); the server's 4,096 is unreachable with InnoDB | [column count limit](https://dev.mysql.com/doc/refman/8.4/en/column-count-limit.html) |
| Row size | 65,535 bytes declared, BLOB/TEXT counting 9–12 bytes (tested: 1,017 `varchar(100)` fails); about 8,126 bytes in a 16 KB page (tested: a full row of 1,017 `bigint` fails "Row size too large (> 8126)") | [InnoDB limits](https://dev.mysql.com/doc/refman/8.4/en/innodb-limits.html) |
| Rows in one `INSERT ... VALUES` | Bounded by `max_allowed_packet`: 64 MB default in 8.0 and 8.4 (tested), 1 GB max. Tested: 1,000,000 rows (8.9 MB) | [system variables](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html) |
| Placeholders per prepared statement | 65,535 | |
| Recursive CTE depth | `cte_max_recursion_depth`, default 1,000 (the insert planner raises it per statement) | [WITH](https://dev.mysql.com/doc/refman/8.4/en/with.html) |
| `group_concat_max_len` | default 1,024 bytes (the planners raise it) | [system variables](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html) |
| Identifier length | 64 characters | [identifier length](https://dev.mysql.com/doc/refman/8.4/en/identifier-length.html) |
| Index key length | 3,072 bytes (DYNAMIC rows); 64 secondary indexes; 16 columns per index | [InnoDB limits](https://dev.mysql.com/doc/refman/8.4/en/innodb-limits.html) |
| Partitions | 8,192 | [partitioning limits](https://dev.mysql.com/doc/refman/8.4/en/partitioning-limitations.html) |

## Measured (Podman machine, 4 vCPU, XFS)

| Step | Time |
|---|---|
| 100-table dataset, even spread up to 200,000 rows (10.1M rows), 4 sessions | 21 s to finish after an interrupt at 4.7M rows; a third run added nothing |
| Create 10,000 tables | 40 s |
| Plan inserts for 10,000 tables | 1.0 s |
| Insert 100 rows into each of 10,000 tables (1M rows) | 18 s |
| Status of 10,000 tables | 5.1 s (plan 0.5 s) |
| 1M rows into one table, recursive CTE / seed table | 5.5 s / 5.7 s |
| Seed table of 1,024,000 keys (VALUES + 10 doublings) | 2.1 s |

**Foreign keys, tested** with the same star schema as Postgres (a `varchar`-keyed dimension, a fact referencing a fact, a self-referencing table): fill in level order, head and tail deletes with re-pointing and no violations, contiguous key ranges, a refill onto new dimension keys, and a 12-table `@dims=3, @fks=2` dataset filled to its targets with 0 bad rows in the audit.

## Gotchas

- **Disk:** a killed INSERT rolls back, which needs disk too. A full disk crashed MySQL 8.4 during a rollback in testing: check free space first.
- `AUTO_INCREMENT` keys get explicit values; MySQL moves the counter past them. Generated columns are left out; columns with a `DEFAULT CURRENT_TIMESTAMP` get generated values.
- **`@data='random'`** draws one `RAND()` per row in a derived table kept unmerged with `/*+ NO_MERGE(x) */`, so a cast that uses its input twice gets the same value both times.
- `boolean` is `tinyint(1)`, so it gets `n % 127`, not just 0 and 1.
- `timestamp` values are converted from the session time zone: set `time_zone = '+00:00'` for the same values everywhere.
- An `enum` or `set` value list that contains commas inside a value is miscounted.
