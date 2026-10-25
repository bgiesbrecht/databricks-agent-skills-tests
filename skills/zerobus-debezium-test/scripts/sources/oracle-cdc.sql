-- oracle-cdc.sql (oracle-sq.sh <user>): after the fill, in the source's schema: every column of every table in the
-- redo log (Debezium's before images, and tables without a key), and the history check's truth: an audit trigger per
-- table writing each change, in commit order, as JSON to LFC_AUDIT (AUDIT is a reserved word), which Debezium doesn't
-- capture (no LFC_ table is).
CREATE TABLE lfc_audit (seq NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, tbl VARCHAR2(128) NOT NULL, op VARCHAR2(1) NOT NULL, row_data CLOB);
DECLARE
  cols CLOB;
BEGIN
  FOR t IN (SELECT table_name FROM user_tables WHERE table_name NOT LIKE 'LFC\_%' ESCAPE '\' ORDER BY 1) LOOP
    EXECUTE IMMEDIATE 'ALTER TABLE "' || t.table_name || '" ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS';
    cols := NULL;
    FOR c IN (SELECT column_name FROM user_tab_columns WHERE table_name = t.table_name ORDER BY column_id) LOOP
      cols := cols || CASE WHEN cols IS NOT NULL THEN ', ' END || '''' || c.column_name || ''' VALUE :NEW."' || c.column_name || '"';
    END LOOP;
    EXECUTE IMMEDIATE 'CREATE OR REPLACE TRIGGER "' || SUBSTR(t.table_name, 1, 120) || '_AUD" AFTER INSERT OR UPDATE OR DELETE ON "'
      || t.table_name || '" FOR EACH ROW BEGIN IF DELETING THEN INSERT INTO lfc_audit (tbl, op, row_data) VALUES (''' || t.table_name
      || ''', ''D'', NULL); ELSE INSERT INTO lfc_audit (tbl, op, row_data) VALUES (''' || t.table_name || ''', ''W'', JSON_OBJECT('
      || cols || ' NULL ON NULL RETURNING CLOB)); END IF; END;';
  END LOOP;
END;
/
