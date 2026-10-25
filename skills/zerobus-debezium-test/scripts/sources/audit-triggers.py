#!/usr/bin/env python3
"""audit-triggers.py --dialect mysql|db2|informix <schema.yaml> [--only TABLE --replace]: the history check's truth, as SQL for the source's schema: an
audit table and three triggers per table (after insert, update, delete) writing every row change, in commit order,
as JSON. Neither engine's triggers can loop over a table's columns, so each table's are listed from the model.
  mysql  audit, backquoted names; a boolean (TINYINT(1)) goes in as JSON true/false, as the other sources write it.
         The binlog captures the audit table too, but no producer's table list names it. One statement per line, none
         with BEGIN ... END, so no DELIMITER is needed.
  db2    LFC_AUDIT (no LFC_ table is put into capture mode), names in upper case as Db2 keeps unquoted ones; decimals
         as text, timestamps and times formatted as ISO (JSON_OBJECT's own forms aren't JSON numbers or ISO); each
         trigger ends with a line "@" (sq.py's terminator for a statement it can't end at ";").
  informix lfc_audit; Informix has no JSON_OBJECT, so each row's JSON is built as text: numbers as they cast to
         LVARCHAR, strings quoted (a quote and a backslash escaped), dates and datetimes as text, booleans true/false,
         NULL as null; each value trimmed (Informix pads the CASE that picks it). Each trigger ends with a line "@", as Db2's.
--only TABLE --replace: that table's triggers only, dropped first and made again from the schema as it is now (MySQL):
a trigger that names a column a schema change dropped fails every change to its table."""
import argparse

import yaml

ap = argparse.ArgumentParser()
ap.add_argument("schema")
ap.add_argument("--dialect", required=True, choices=["mysql", "db2", "informix"])
ap.add_argument("--only"); ap.add_argument("--replace", action="store_true")
a = ap.parse_args()


def lit(s):
    return "'" + s.replace("'", "''") + "'"


tables = [t for t in yaml.safe_load(open(a.schema))["tables"] if not a.only or t["name"] == a.only]
if a.dialect == "mysql":
    def q(n):
        return "`" + n.replace("`", "``") + "`"

    def val(c):
        x = f"NEW.{q(c['name'])}"
        if c.get("type") in ("boolean", "bool"):
            return f"IF({x} IS NULL, NULL, IF({x}, CAST('true' AS JSON), CAST('false' AS JSON)))"
        return x
    if not a.replace:
        print("CREATE TABLE audit (seq BIGINT AUTO_INCREMENT PRIMARY KEY, tbl VARCHAR(128) NOT NULL, op CHAR(1) NOT NULL, row_data JSON);")
    for t in tables:
        n = t["name"]
        obj = "JSON_OBJECT(" + ", ".join(f"{lit(c['name'])}, {val(c)}" for c in t["columns"]) + ")"
        for when, op, data in (("INSERT", "W", obj), ("UPDATE", "W", obj), ("DELETE", "D", "NULL")):
            if a.replace:
                print(f"DROP TRIGGER IF EXISTS {q(n[:58] + '_a' + when[0].lower())};")
            print(f"CREATE TRIGGER {q(n[:58] + '_a' + when[0].lower())} AFTER {when} ON {q(n)} FOR EACH ROW "
                  f"INSERT INTO audit (tbl, op, row_data) VALUES ({lit(n)}, '{op}', {data});")
elif a.dialect == "informix":
    def jv(c):   # a column of the new row as JSON text
        x, ty = f"n.{c['name'].lower()}", c.get("type")
        if ty in ("integer", "long", "int", "bigint", "smallint", "decimal", "numeric", "float", "double", "real"):
            v = f"{x}::LVARCHAR"
        elif ty in ("boolean", "bool"):
            v = f"CASE WHEN {x} = 't' THEN 'true' ELSE 'false' END"
        elif ty == "date":
            v = f"'\"' || TO_CHAR({x}, '%Y-%m-%d') || '\"'"
        elif ty in ("timestamp", "timestamptz", "time"):
            v = f"'\"' || {x}::LVARCHAR || '\"'"
        else:
            v = f"'\"' || REPLACE(REPLACE({x}, '\\', '\\\\'), '\"', '\\\"') || '\"'"
        # trimmed: a CASE of the literal 'null' and an LVARCHAR cast comes back blank-padded to 2048 characters, and
        # TPC-DS's date_dim (16 integers) then passed the audit column's 32000
        return f"TRIM(CASE WHEN {x} IS NULL THEN 'null' ELSE {v} END)"
    print("CREATE TABLE lfc_audit (seq SERIAL8 PRIMARY KEY, tbl VARCHAR(128) NOT NULL, op CHAR(1) NOT NULL, row_data LVARCHAR(32000));")
    for t in tables:
        n = t["name"].lower()
        # keys in lower case, as Informix folds the names (TPC-DI's SK_TimeID is sk_timeid there)
        obj = "'{' || " + " || ',' || ".join(f"'\"{c['name'].lower()}\":' || {jv(c)}" for c in t["columns"]) + " || '}'"
        for when, op, data in (("INSERT", "W", obj), ("UPDATE", "W", obj), ("DELETE", "D", "NULL")):
            ref = "REFERENCING NEW AS n " if when != "DELETE" else ""
            print(f"CREATE TRIGGER {n[:100]}_a{when[0].lower()} {when} ON {n} {ref}FOR EACH ROW "
                  f"(INSERT INTO lfc_audit (tbl, op, row_data) VALUES ({lit(n)}, '{op}', {data}))\n@")
else:
    def q(n):
        return '"' + n.upper().replace('"', '""') + '"'
    print("CREATE TABLE LFC_AUDIT (SEQ BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, TBL VARCHAR(128) NOT NULL, "
          "OP CHAR(1) NOT NULL, ROW_DATA CLOB(1M));")
    for t in tables:
        n = t["name"].upper()
        def dv(c):   # a column as JSON_OBJECT should write it
            x, ty = f"N.{q(c['name'])}", c.get("type")
            if ty in ("decimal", "numeric"):   # as text: JSON_OBJECT writes -999.99 as -0000000000999.99, which isn't JSON
                return f"CAST({x} AS VARCHAR(64))"
            if ty in ("timestamp", "timestamptz"):   # ISO: JSON_OBJECT writes Db2's own 1970-01-01-00.00.01.000000
                return f"VARCHAR_FORMAT({x}, 'YYYY-MM-DD HH24:MI:SS.FF6')"
            if ty in ("time", "timetz"):   # and 00.00.01 for a time
                return f"VARCHAR_FORMAT(TIMESTAMP(DATE('2000-01-01'), {x}), 'HH24:MI:SS.FF6')"
            return x
        obj = ("JSON_OBJECT(" + ", ".join(f"KEY {lit(c['name'].upper())} VALUE {dv(c)}" for c in t["columns"])
               + " NULL ON NULL RETURNING CLOB(1M))")
        for when, op, data in (("INSERT", "W", obj), ("UPDATE", "W", obj), ("DELETE", "D", "NULL")):
            ref = "REFERENCING NEW AS N " if when != "DELETE" else ""
            print(f"CREATE TRIGGER {q(n[:100] + '_A' + when[0])} AFTER {when} ON {q(n)} {ref}FOR EACH ROW "
                  f"INSERT INTO LFC_AUDIT (TBL, OP, ROW_DATA) VALUES ({lit(n)}, '{op}', {data})\n@")
