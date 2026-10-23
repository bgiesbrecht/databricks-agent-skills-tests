-- collect-activity-hourly-sqlserver.sql: changes per table per hour, from SQL Server's own change journal, for the
-- tables that have change tracking or CDC on. Shows which tables are busy when (OLTP by day, batch at night), over the
-- window the journal still holds: change tracking's retention period, CDC's cleanup retention.
--   Change tracking: CHANGETABLE(CHANGES ..., 0) joined to sys.dm_tran_commit_table for each change's commit time
--   (one row per changed key since the oldest kept version: a key changed twice in an hour counts once; it's net).
--   CDC: each change in cdc.<capture instance>_CT, timed by cdc.lsn_time_mapping (every change counts).
-- Run in the database, as a login with VIEW SERVER STATE (sys.dm_tran_commit_table) and SELECT on the tables:
--   sqlcmd -d <database> -W -h -1 -s '|' -i collect-activity-hourly-sqlserver.sql > activity-hourly.psv
-- Output rows: mechanism|schema.table|hour (UTC of the server clock, yyyy-mm-dd HH)|changes
SET NOCOUNT ON;
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql += N'UNION ALL SELECT ''ct'', ''' + s.name + N'.' + t.name + N''', CONVERT(CHAR(13), tc.commit_time, 120), COUNT(*)
  FROM CHANGETABLE(CHANGES ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N', 0) c
  JOIN sys.dm_tran_commit_table tc ON tc.commit_ts = c.SYS_CHANGE_VERSION
  GROUP BY CONVERT(CHAR(13), tc.commit_time, 120) '
FROM sys.change_tracking_tables ctt
JOIN sys.tables t ON t.object_id = ctt.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id;

SELECT @sql += N'UNION ALL SELECT ''cdc'', ''' + s.name + N'.' + t.name + N''', CONVERT(CHAR(13), m.tran_end_time, 120), COUNT(*)
  FROM cdc.' + QUOTENAME(ct.capture_instance + N'_CT') + N' x
  JOIN cdc.lsn_time_mapping m ON m.start_lsn = x.__$start_lsn
  WHERE x.__$operation <> 3
  GROUP BY CONVERT(CHAR(13), m.tran_end_time, 120) '
FROM cdc.change_tables ct
JOIN sys.tables t ON t.object_id = ct.source_object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id;

IF LEN(@sql) = 0
  SELECT 'none|no table has change tracking or CDC on in this database||0';
ELSE
BEGIN
  SET @sql = N'SELECT CONCAT_WS(''|'', m, tbl, hr, n) FROM (' + STUFF(@sql, 1, 10, N'') + N') a (m, tbl, hr, n) ORDER BY hr, n DESC, tbl;';
  EXEC sp_executesql @sql;
END
