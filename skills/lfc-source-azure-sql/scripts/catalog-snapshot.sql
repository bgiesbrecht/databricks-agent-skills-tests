-- catalog-snapshot.sql: one line per catalog item a setup script can add (objects, columns, indexes, schemas, principals,
-- permissions, triggers, CT/CDC state), without ids or dates. Run before and after a change and diff the two outputs.
-- sqlcmd ... -d <db> -h -1 -W -i catalog-snapshot.sql > before.txt
SET NOCOUNT ON;
-- Everything in the database catalog that a script can add, without ids or dates, one line per item
SELECT 'object|' + o.type COLLATE DATABASE_DEFAULT + '|' + SCHEMA_NAME(o.schema_id) + '.' + o.name + '|ms_shipped=' + CAST(o.is_ms_shipped AS varchar)
  FROM sys.objects o WHERE o.type <> 'IT' OR o.name NOT LIKE 'change_tracking[_]%' ORDER BY 1;
SELECT 'internal_table|' + it.internal_type_desc COLLATE DATABASE_DEFAULT + '|parent=' + ISNULL(OBJECT_SCHEMA_NAME(it.parent_id) + '.' + OBJECT_NAME(it.parent_id), '-') FROM sys.internal_tables it ORDER BY 1;
SELECT 'column|' + OBJECT_SCHEMA_NAME(c.object_id) + '.' + OBJECT_NAME(c.object_id) + '.' + c.name FROM sys.columns c JOIN sys.objects o ON o.object_id = c.object_id WHERE o.is_ms_shipped = 0 ORDER BY 1;
SELECT 'index|' + OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) + '.' + ISNULL(i.name, '(heap)') FROM sys.indexes i JOIN sys.objects o ON o.object_id = i.object_id WHERE o.is_ms_shipped = 0 ORDER BY 1;
SELECT 'schema|' + name FROM sys.schemas ORDER BY 1;
SELECT 'principal|' + type COLLATE DATABASE_DEFAULT + '|' + name FROM sys.database_principals ORDER BY 1;
SELECT 'role_member|' + USER_NAME(role_principal_id) + '|' + USER_NAME(member_principal_id) FROM sys.database_role_members ORDER BY 1;
SELECT 'permission|' + USER_NAME(p.grantee_principal_id) + '|' + p.state_desc COLLATE DATABASE_DEFAULT + ' ' + p.permission_name COLLATE DATABASE_DEFAULT + '|' + p.class_desc COLLATE DATABASE_DEFAULT
       + ISNULL('|' + CASE p.class WHEN 1 THEN OBJECT_SCHEMA_NAME(p.major_id) + '.' + OBJECT_NAME(p.major_id) WHEN 3 THEN SCHEMA_NAME(p.major_id) WHEN 4 THEN USER_NAME(p.major_id) END, '')
  FROM sys.database_permissions p ORDER BY 1;
SELECT 'trigger|' + CAST(parent_class AS varchar) + '|' + name FROM sys.triggers ORDER BY 1;
SELECT 'extended_property|' + CAST(class AS varchar) + '|' + name FROM sys.extended_properties ORDER BY 1;
SELECT 'ct_database|retention=' + CAST(retention_period AS varchar) + ' ' + retention_period_units_desc COLLATE DATABASE_DEFAULT FROM sys.change_tracking_databases WHERE database_id = DB_ID();
SELECT 'ct_table|' + OBJECT_SCHEMA_NAME(object_id) + '.' + OBJECT_NAME(object_id) FROM sys.change_tracking_tables ORDER BY 1;
SELECT 'database|is_cdc_enabled=' + CAST(is_cdc_enabled AS varchar) + '|snapshot_isolation=' + CAST(snapshot_isolation_state AS varchar) + '|rcsi=' + CAST(is_read_committed_snapshot_on AS varchar) FROM sys.databases WHERE database_id = DB_ID();
