-- mssql-cdc.sql: CDC on the database and every dbo table, after the fill (so only changes from T are captured), and
-- the history check's truth: an audit trigger per table writing every change, in commit order, as JSON to dbo.audit,
-- which CDC doesn't capture. SQL Server Agent (MSSQL_AGENT_ENABLED) runs the capture jobs this creates.
EXEC sys.sp_cdc_enable_db;
GO
CREATE TABLE dbo.audit (seq BIGINT IDENTITY(1, 1) PRIMARY KEY, tbl NVARCHAR(128) NOT NULL, op CHAR(1) NOT NULL, row_data NVARCHAR(MAX));
GO
DECLARE @t sysname, @n nvarchar(300), @q nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT table_name FROM information_schema.tables
  WHERE table_schema = 'dbo' AND table_type = 'BASE TABLE' AND table_name NOT IN ('audit', 'systranschemas');
OPEN c; FETCH NEXT FROM c INTO @t;
WHILE @@FETCH_STATUS = 0 BEGIN
  EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = @t, @role_name = NULL, @supports_net_changes = 0;
  SET @n = N'N''' + REPLACE(@t, '''', '''''') + N'''';
  SET @q = N'CREATE TRIGGER dbo.' + QUOTENAME(@t + N'_audit') + N' ON dbo.' + QUOTENAME(@t) + N' AFTER INSERT, UPDATE, DELETE AS BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.audit (tbl, op, row_data) SELECT ' + @n + N', ''W'', (SELECT i.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) FROM inserted i;
    INSERT INTO dbo.audit (tbl, op, row_data) SELECT ' + @n + N', ''D'', NULL FROM deleted WHERE NOT EXISTS (SELECT 1 FROM inserted);
  END';
  EXEC sp_executesql @q;
  FETCH NEXT FROM c INTO @t;
END
CLOSE c; DEALLOCATE c;
GO
