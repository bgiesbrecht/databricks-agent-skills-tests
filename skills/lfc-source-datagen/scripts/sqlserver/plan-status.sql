-- { echo "DECLARE @schema sysname = N'dbo';"; cat cast.sql plan-status.sql; } | sqlcmd -h -1 -y 0 > status.sql; sqlcmd -h -1 -y 0 -i status.sql
-- Emits SELECTs (500 tables each) returning table|min|max|rows|target (from lfc:rows, if set). Keys only ever change at the
-- ends, so rows = max - min + 1 without COUNT(*); each min and max is one probe of the clustered key.
WITH q AS (
  SELECT (ROW_NUMBER() OVER (ORDER BY tbl) - 1) / 500 AS chunk, tbl,
         CONCAT(CAST('SELECT CONCAT(''' AS nvarchar(max)), tbl, '|'', lo, ''|'', hi, ''|'', COALESCE(hi - lo + 1, 0), ''|', COALESCE(CAST(target AS varchar(20)), ''),
                ''') FROM (SELECT ',
                IIF(has_n = 1,
                    CONCAT('(SELECT MIN(', pk_int, ') FROM ', QUOTENAME(@schema), '.', QUOTENAME(tbl), ' WHERE ', pk, ' = (SELECT TOP (1) ', pk, ' FROM ', QUOTENAME(@schema), '.',
                           QUOTENAME(tbl), ' ORDER BY ', pk, ')) AS lo, (SELECT MAX(', pk_int, ') FROM ', QUOTENAME(@schema), '.', QUOTENAME(tbl), ' WHERE ', pk,
                           ' = (SELECT TOP (1) ', pk, ' FROM ', QUOTENAME(@schema), '.', QUOTENAME(tbl), ' ORDER BY ', pk, ' DESC)) AS hi'),
                    CONCAT('(SELECT TOP (1) ', pk_int, ' FROM ', QUOTENAME(@schema), '.', QUOTENAME(tbl), ' ORDER BY ', pk, ') AS lo, (SELECT TOP (1) ', pk_int, ' FROM ',
                           QUOTENAME(@schema), '.', QUOTENAME(tbl), ' ORDER BY ', pk, ' DESC) AS hi')), ') m') AS sel
  FROM #lfc_keys)
SELECT CONCAT(STRING_AGG(sel, ' UNION ALL ') WITHIN GROUP (ORDER BY tbl), ';') FROM q GROUP BY chunk ORDER BY chunk;
