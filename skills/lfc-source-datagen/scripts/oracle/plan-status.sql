-- { echo "DEFINE schema = 'TPCH' ..."; cat cast.sql plan-status.sql; } | sqlplus -s ... > status.sql; sqlplus -s ... < status.sql
-- Emits SELECTs (500 tables each) returning TABLE|min|max|rows|target (from lfc:rows, if set). Keys only ever change at the
-- ends, so rows = max - min + 1 without COUNT(*); each min and max is one probe of the key's index.
BEGIN
  init;
  DECLARE
    s CLOB; k PLS_INTEGER := 0;
  BEGIN
    FOR t IN (SELECT table_name tn FROM all_tables WHERE owner = sch AND table_name NOT IN ('LFC_TAGS') AND temporary = 'N'
                AND nested = 'NO' AND secondary = 'N' AND dropped = 'NO' ORDER BY table_name) LOOP
      CONTINUE WHEN kint(t.tn) IS NULL;
      s := s || CASE WHEN MOD(k, 500) <> 0 THEN ' UNION ALL ' END || 'SELECT ''' || t.tn || '|'' || lo || ''|'' || hi || ''|'' || COALESCE(hi - lo + 1, 0) || ''|'
             || tg(t.tn, NULL, 'rows') || ''' FROM (SELECT ' || hiq(t.tn, FALSE) || ' AS lo, ' || hiq(t.tn, TRUE) || ' AS hi FROM DUAL)';
      k := k + 1;
      IF MOD(k, 500) = 0 THEN emit(s || ';'); s := NULL; END IF;
    END LOOP;
    IF s IS NOT NULL THEN emit(s || ';'); END IF;
  END;
END;
/
