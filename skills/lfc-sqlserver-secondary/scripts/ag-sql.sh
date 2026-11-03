#!/usr/bin/env bash
# ag-sql.sh p|s [db] [--xe [since] [errors|writes|all]]: T-SQL on stdin as sa in the ag-up.sh node <AG_NAME>-<p|s>;
# --xe prints the gateway's statements and errors recorded by the lfc_watch Extended Events session instead
# (since: 'yyyy-mm-ddThh:mm:ss' UTC, default all; default kind errors). Environment: AG_NAME, AG_DIR, PODMAN as in ag-up.sh.
set -euo pipefail
R=${1:?usage: ag-sql.sh p|s [db] [--xe [since] [errors|writes|all]]}; shift
N=${AG_NAME:-lfc-ag}; D=${AG_DIR:-$HOME/$N}; PM=${PODMAN:-podman}
case $R in (p|s) ;; (*) echo "node: p or s" >&2; exit 2;; esac
DB=master; if [ $# -gt 0 ] && [ "$1" != --xe ]; then DB=$1; shift; fi
# shellcheck disable=SC1091
. "$D/ag.env"
run(){ $PM exec -i -e SQLCMDPASSWORD="$SA_PW" "$N-$R" /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -d "$DB" -b -W -s '|' "$@"; }
if [ "${1:-}" != --xe ]; then run; exit; fi
since=${2:-2000-01-01}; kind=${3:-errors}
case "$since$kind" in (*[!0-9A-Za-z:T.-]*) echo "bad since/kind" >&2; exit 2;; esac
run <<SQL
SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON;
WITH x AS (SELECT CAST(event_data AS XML) e, object_name ev
           FROM sys.fn_xe_file_target_read_file('/var/opt/mssql/log/lfc_watch*.xel', NULL, NULL, NULL)),
y AS (SELECT ev, e.value('(event/@timestamp)[1]', 'datetime2') ts,
        e.value('(event/data[@name="error_number"]/value)[1]', 'int') err,
        LEFT(COALESCE(e.value('(event/data[@name="message"]/value)[1]', 'nvarchar(max)'), ''), 200) msg,
        LEFT(COALESCE(e.value('(event/data[@name="batch_text"]/value)[1]', 'nvarchar(max)'),
                      e.value('(event/data[@name="statement"]/value)[1]', 'nvarchar(max)'),
                      e.value('(event/action[@name="sql_text"]/value)[1]', 'nvarchar(max)'), ''), 220) txt
      FROM x)
SELECT CONVERT(varchar(19), ts, 126) ts, ev, err, REPLACE(msg, CHAR(10), ' ') msg, REPLACE(txt, CHAR(10), ' ') txt FROM y
WHERE ts >= '$since' AND (('$kind' = 'errors' AND ev = 'error_reported')
  OR ('$kind' = 'writes' AND (ev = 'error_reported' OR txt LIKE '%UPDATE %' OR txt LIKE '%MERGE %' OR txt LIKE '%INSERT %'
      OR txt LIKE '%DELETE %' OR txt LIKE '%sp_cdc_%able%' OR txt LIKE '%lakeflow%CaptureInstance%'))
  OR '$kind' = 'all')
ORDER BY ts;
SQL
