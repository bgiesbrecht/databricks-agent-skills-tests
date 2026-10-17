-- { echo "DECLARE @schema sysname = N'dbo';"; cat cast.sql skipped.sql; } | sqlcmd -h -1 -W
-- Tables the planner skips: no primary key, a composite key, or a key that can't be turned back into n, unless the table
-- has a key formula (lfc:n={...} in lfc_seed.tags).
SELECT CONCAT(t.name, '|', CASE WHEN tb.oid IS NULL AND NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1) THEN 'no primary key'
                                WHEN tb.oid IS NULL THEN 'composite key' ELSE 'key type cannot map back to n' END)
FROM sys.tables t LEFT JOIN #lfc_tabs tb ON tb.oid = t.object_id
WHERE t.schema_id = SCHEMA_ID(@schema) AND NOT EXISTS (SELECT 1 FROM #lfc_keys k WHERE k.oid = t.object_id)
ORDER BY t.name;
