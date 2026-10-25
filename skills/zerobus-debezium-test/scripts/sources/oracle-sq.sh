#!/bin/sh
# oracle-sq.sh <user|sysdba|cdb>: Oracle statements on stdin (SQL*Plus: one statement per line, PL/SQL ending with a
# "/" line) -> tab-separated rows, each result's header row first. Runs in the Oracle container (mounted at /lfc).
# <user>: that schema's user in FREEPDB1; sysdba: SYS in FREEPDB1; cdb: SYS in the root. The password is the
# container's ORACLE_PASSWORD (every user the test makes has it), sent on stdin, so it's on no command line. Each
# statement commits by itself (AUTOCOMMIT): one transaction per change, so no two changes share an SCN. Exit 1 on an
# SQL error.
case $1 in
  sysdba) c="sys/\"$ORACLE_PASSWORD\"@FREEPDB1 AS SYSDBA";;
  cdb) c="sys/\"$ORACLE_PASSWORD\" AS SYSDBA";;
  *) c="$1/\"$ORACLE_PASSWORD\"@FREEPDB1";;
esac
f=$(mktemp); o=$(mktemp)
{ echo "CONNECT $c"
  echo "WHENEVER SQLERROR EXIT FAILURE"
  echo "SET FEEDBACK OFF AUTOCOMMIT ON PAGESIZE 50000 LINESIZE 32767 TRIMSPOOL ON TRIMOUT ON VERIFY OFF DEFINE OFF SQLBLANKLINES ON"
  echo "SET LONG 10000000 LONGCHUNKSIZE 10000000"
  printf 'SET MARKUP CSV ON DELIMITER "\t" QUOTE OFF\n'
  cat; echo "EXIT"; } > "$f"
sqlplus -s /nolog < "$f" > "$o" 2>&1; rc=$?
grep -v '^$' "$o"; rm -f "$f" "$o"; exit $rc
