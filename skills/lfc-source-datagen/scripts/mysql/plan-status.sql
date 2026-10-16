-- mysql -N -B -r -e "SET @db='lfc'; SOURCE my-plan-status.sql" > status.sql
-- Emits SELECTs (500 tables each) returning table, min key, max key, rows (= max - min + 1, no COUNT(*)), target ('lfc:rows=', if set).
SET SESSION group_concat_max_len = 16777216;
-- Tags longer than a MySQL comment holds (1,024 characters for a column) live in lfc_seed.tags, one row per table ('') or
-- column; a table's or column's tags are its comment and that row together.
CREATE DATABASE IF NOT EXISTS lfc_seed;
CREATE TABLE IF NOT EXISTS lfc_seed.tags (db VARCHAR(64), tbl VARCHAR(64), col VARCHAR(64), tag MEDIUMTEXT, PRIMARY KEY (db, tbl, col));
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
  FROM (SELECT t.table_schema, t.table_name, CONCAT(t.table_comment, ' ', COALESCE((SELECT g.tag FROM lfc_seed.tags g WHERE g.db = t.table_schema AND g.tbl = t.table_name AND g.col = ''), '')) AS cm, p.column_name, p.npk,           -- a one-column key, or a key formula
               REGEXP_SUBSTR(CONCAT(t.table_comment, ' ', COALESCE((SELECT g.tag FROM lfc_seed.tags g WHERE g.db = t.table_schema AND g.tbl = t.table_name AND g.col = ''), '')), '(?<=lfc:n=\\{)[^}]*') AS nkey,
               COALESCE(REGEXP_SUBSTR(CONCAT(t.table_comment, ' ', COALESCE((SELECT g.tag FROM lfc_seed.tags g WHERE g.db = t.table_schema AND g.tbl = t.table_name AND g.col = ''), '')), '(?<=lfc:by=\\{)[^}]*'), p.column_name) AS byc
        FROM information_schema.tables t
        LEFT JOIN (SELECT table_schema, table_name, MAX(IF(seq_in_index = 1, column_name, NULL)) AS column_name, COUNT(*) AS npk
                   FROM information_schema.statistics WHERE table_schema = @db AND index_name = 'PRIMARY' GROUP BY table_schema, table_name) p
          ON p.table_schema = t.table_schema AND p.table_name = t.table_name
        WHERE t.table_schema = @db AND t.table_type = 'BASE TABLE'
          AND (p.npk = 1 OR CONCAT(t.table_comment, ' ', COALESCE((SELECT g.tag FROM lfc_seed.tags g WHERE g.db = t.table_schema AND g.tbl = t.table_name AND g.col = ''), '')) LIKE '%lfc:n={%')) s
  LEFT JOIN information_schema.columns c ON c.table_schema = s.table_schema AND c.table_name = s.table_name AND c.column_name = s.column_name
  JOIN LATERAL (SELECT IF(c.data_type IN ('char', 'varchar'), CONCAT('CAST(LEFT(`', c.column_name, '`, 19) AS UNSIGNED)'),
                          CONCAT('`', c.column_name, '`')) AS i) x ON TRUE
) q GROUP BY k DIV 500 ORDER BY k DIV 500;
