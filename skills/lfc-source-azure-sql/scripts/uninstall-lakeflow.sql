-- uninstall-lakeflow.sql: remove what the Lakeflow Connect utility objects script and its setup procedures added to one database.
-- sqlcmd -S <host>,<port> -U <admin> -d <db> -C -b -v LOGIN=<ingestion user> -i uninstall-lakeflow.sql   (idempotent; tested on SQL Database and MI)
-- Remove everything the Lakeflow Connect utility objects script and its setup procedures added to this database.
-- Run as a db_owner member, after the Lakeflow Connect pipelines that read this database are deleted.
-- Steps 3 and 4 turn off CDC and change tracking: skip them if anything else (ADF, replication, an ETL job) uses them.
SET NOCOUNT ON;
DECLARE @user SYSNAME = N'$(LOGIN)';   -- the ingestion user given to the setup procedures (sqlcmd -v LOGIN=...)
DECLARE @sql NVARCHAR(MAX);

-- 1. The DDL support objects (DDL audit table and trigger; capture instance tracker, its three procedures and trigger)
IF OBJECT_ID('dbo.lakeflowSetupChangeTracking', 'P') IS NOT NULL EXEC dbo.lakeflowSetupChangeTracking @Mode = 'CLEANUP';
IF OBJECT_ID('dbo.lakeflowSetupChangeDataCapture', 'P') IS NOT NULL EXEC dbo.lakeflowSetupChangeDataCapture @Mode = 'CLEANUP';

-- 2. The utility procedures and functions themselves (CLEANUP keeps them)
SET @sql = N'';
SELECT @sql += N'DROP ' + CASE type WHEN 'P' THEN N'PROCEDURE' ELSE N'FUNCTION' END + N' dbo.' + QUOTENAME(name) + N';'
  FROM sys.objects
 WHERE schema_id = SCHEMA_ID('dbo') AND type IN ('P', 'FN')
   AND (name IN (N'lakeflowFixPermissions', N'lakeflowSetupChangeTracking', N'lakeflowSetupChangeDataCapture',
                 N'lakeflowDetectPlatform', N'lakeflowVersionComponent', N'lakeflowUtilityVersion')
        OR name LIKE N'lakeflowUtilityVersion[_]%');
EXEC sp_executesql @sql;

-- 3. CDC: the Lakeflow capture instances (named lakeflow_<schema>_<table>_<1|2>), then CDC on the database if none is left
IF (SELECT is_cdc_enabled FROM sys.databases WHERE database_id = DB_ID()) = 1
BEGIN
    SET @sql = N'';
    SELECT @sql += N'EXEC sys.sp_cdc_disable_table @source_schema = N' + QUOTENAME(OBJECT_SCHEMA_NAME(source_object_id), '''')
                 + N', @source_name = N' + QUOTENAME(OBJECT_NAME(source_object_id), '''')
                 + N', @capture_instance = N' + QUOTENAME(capture_instance, '''') + N';'
      FROM cdc.change_tables WHERE capture_instance LIKE N'lakeflow[_]%';
    EXEC sp_executesql @sql;
    IF NOT EXISTS (SELECT 1 FROM cdc.change_tables) EXEC sys.sp_cdc_disable_db;
END

-- 4. Change tracking: off on the tables the setup turned it on for, then on the database if no table is left.
--    The script doesn't record which tables it enabled: list yours here, or keep this as it is for every table.
SET @sql = N'';
SELECT @sql += N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + N'.' + QUOTENAME(OBJECT_NAME(object_id)) + N' DISABLE CHANGE_TRACKING;'
  FROM sys.change_tracking_tables;
EXEC sp_executesql @sql;
IF EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
   AND NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables)
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(DB_NAME()) + N' SET CHANGE_TRACKING = OFF;';
    EXEC sp_executesql @sql;
END

-- 5. The ingestion user's grants: dropping the database user removes them all (the login in master stays)
IF USER_ID(@user) IS NOT NULL
BEGIN
    SET @sql = N'DROP USER ' + QUOTENAME(@user) + N';';
    EXEC sp_executesql @sql;
END

-- 6. Managed Instance and SQL Server (not Azure SQL Database): the server-scoped grants lakeflowFixPermissions made in
--    master. Needs grant authority in master (sysadmin). Skip it if the user needs these for anything else.
IF CAST(SERVERPROPERTY('EngineEdition') AS INT) <> 5
BEGIN
    SET @sql = N'USE master;
IF USER_ID(' + QUOTENAME(@user, '''') + N') IS NOT NULL
BEGIN
    REVOKE SELECT ON sys.change_tracking_databases FROM ' + QUOTENAME(@user) + N';
    REVOKE EXECUTE ON sys.sp_tables FROM ' + QUOTENAME(@user) + N';
    REVOKE EXECUTE ON sys.sp_columns_100 FROM ' + QUOTENAME(@user) + N';
    REVOKE EXECUTE ON sys.sp_pkeys FROM ' + QUOTENAME(@user) + N';
    REVOKE EXECUTE ON sys.sp_statistics_100 FROM ' + QUOTENAME(@user) + N';
END';
    EXEC sp_executesql @sql;
END
