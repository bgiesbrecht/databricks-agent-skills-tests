-- server-snapshot.sql: the server-level part of a before\/after diff on a Managed Instance or SQL Server: the login's user and
-- grants in master, and the SQL Agent jobs in msdb (CDC adds cdc.<db>_capture and cdc.<db>_cleanup).
-- sqlcmd ... -d master -h -1 -W -v LOGIN=<ingestion user> -i server-snapshot.sql
SET NOCOUNT ON;
SELECT 'master_principal|' + type COLLATE DATABASE_DEFAULT + '|' + name FROM sys.database_principals WHERE name = N'$(LOGIN)' ORDER BY 1;
SELECT 'master_permission|' + USER_NAME(p.grantee_principal_id) + '|' + p.state_desc COLLATE DATABASE_DEFAULT + ' ' + p.permission_name COLLATE DATABASE_DEFAULT + '|' + ISNULL(OBJECT_SCHEMA_NAME(p.major_id) + '.' + OBJECT_NAME(p.major_id), p.class_desc COLLATE DATABASE_DEFAULT)
  FROM sys.database_permissions p WHERE USER_NAME(p.grantee_principal_id) = N'$(LOGIN)' ORDER BY 1;
SELECT 'msdb_job|' + j.name FROM msdb.dbo.sysjobs j ORDER BY 1;
SELECT 'msdb_cdc_job|' + DB_NAME(database_id) + '|' + job_type FROM msdb.dbo.cdc_jobs ORDER BY 1;
