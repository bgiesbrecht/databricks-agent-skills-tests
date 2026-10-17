-- { echo "DEFINE schema = 'TPCH' ..."; cat cast.sql skipped.sql; } | sqlplus -s ...
-- Tables the planner skips: no primary key, a composite key, or a key that can't be turned back into n, unless the table
-- has a key formula (lfc:n={...} in lfc_tags).
BEGIN
  init;
  FOR t IN (SELECT table_name tn FROM all_tables WHERE owner = sch AND table_name NOT IN ('LFC_TAGS') AND temporary = 'N'
              AND nested = 'NO' AND secondary = 'N' AND dropped = 'NO' ORDER BY table_name) LOOP
    CONTINUE WHEN kint(t.tn) IS NOT NULL;
    DBMS_OUTPUT.PUT_LINE(t.tn || '|' || CASE WHEN g(npk, t.tn) IS NULL THEN 'no primary key' WHEN g(npk, t.tn) <> '1' THEN 'composite key'
                                             ELSE 'key type cannot map back to n' END);
  END LOOP;
END;
/
