#!/bin/sh
# mssql-sq.sh <database>: SQL Server statements on stdin (batches split by GO lines) -> tab-separated rows, each
# result's header row first; no dashes, blank lines or row counts. Runs in the SQL Server container (mounted at /lfc),
# with the sa password from the container's own MSSQL_SA_PASSWORD, so it's on no command line. QUOTED_IDENTIFIER on (-I):
# names in double quotes, as the other sources' SQL has them. Exit status: sqlcmd's (-b: 1 on an error).
f=$(mktemp); o=$(mktemp)
{ echo "SET NOCOUNT ON;"; cat; } > "$f"
SQLCMDPASSWORD=$MSSQL_SA_PASSWORD /opt/mssql-tools18/bin/sqlcmd -C -I -S localhost -U sa -d "$1" -b -W -s "$(printf '\t')" -i "$f" > "$o" 2>&1
rc=$?
grep -v -E "^-+($(printf '\t')-+)*\$|^\$" "$o"
rm -f "$f" "$o"; exit $rc
