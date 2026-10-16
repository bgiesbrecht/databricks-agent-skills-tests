-- Tables the planner skips: no primary key, a composite key, or a text key shorter than 19 characters, unless the table
-- has a key formula (lfc:n={...} in its comment).
SELECT r.relname, CASE WHEN pk.oid IS NULL THEN 'no primary key' WHEN cardinality(pk.conkey) > 1 THEN 'composite key'
                       ELSE 'key type ' || format_type(a.atttypid, a.atttypmod) END AS reason
FROM pg_class r
JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
LEFT JOIN pg_constraint pk ON pk.conrelid = r.oid AND pk.contype = 'p'
LEFT JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum = pk.conkey[1] AND cardinality(pk.conkey) = 1
WHERE r.relkind = 'r' AND coalesce(obj_description(r.oid, 'pg_class'), '') NOT LIKE '%lfc:n={%'     -- lfc:n: a key formula
  AND (pk.oid IS NULL OR cardinality(pk.conkey) > 1
       OR NOT (a.atttypid IN ('smallint'::regtype, 'integer'::regtype, 'bigint'::regtype, 'numeric'::regtype, 'uuid'::regtype, 'text'::regtype)
               OR (a.atttypid IN ('varchar'::regtype, 'bpchar'::regtype) AND (a.atttypmod = -1 OR a.atttypmod - 4 >= 19))))
ORDER BY 1;
