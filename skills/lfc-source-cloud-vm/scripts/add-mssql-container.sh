#!/usr/bin/env bash
# add-mssql-container.sh <port>: one more SQL Server container on the test VM, with the test login and its own Unity
# Catalog connection, so low-volume tests can run in parallel on separate sources (half as many containers as vCPUs).
#   Needs VM_IP, PROFILE, CONNECTION_NAME (the new connection), LOGIN_PW_FILE (a private file with the test login's
#   password; the connection uses it too). Optional: VM_USER (azureuser), SSH_KEY (~/.ssh/lfc_test_rsa), LOGIN
#   (lfc_user), IMAGE (mcr.microsoft.com/mssql/server:2022-latest), CPUS (2), MEMORY (4g).
#   The port must be in the VM's firewall range for serverless (lfc-source-firewall). The sa password is generated on
#   the VM and stays there (~/.<container>.env); the login's password goes through standard input only.
#   Prints the container name and the connection; checks the connection with remote_query.
set -euo pipefail
: "${1:?port}" "${VM_IP:?}" "${PROFILE:?}" "${CONNECTION_NAME:?}" "${LOGIN_PW_FILE:?}"
PORT=$1; LOGIN=${LOGIN:-lfc_user}; IMAGE=${IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
SSH=(ssh -i "${SSH_KEY:-$HOME/.ssh/lfc_test_rsa}" -o BatchMode=yes -o ConnectTimeout=15 "${VM_USER:-azureuser}@$VM_IP")
[ -r "$LOGIN_PW_FILE" ] || { echo "can't read $LOGIN_PW_FILE"; exit 2; }
NAME=$("${SSH[@]}" bash -s "$PORT" "$IMAGE" "${CPUS:-2}" "${MEMORY:-4g}" <<'REMOTE'
set -euo pipefail
P="podman --remote --url unix:///run/podman/podman.sock"
$P ps --format '{{.Ports}}' | grep -q ":$1->" && { echo "port $1 is taken" >&2; exit 2; }
N=mssql-$(echo "$2" | sed 's#.*/##; s#[:.]#-#g')-$1-$(date +%s); umask 077; f=~/.$N.env
printf 'MSSQL_SA_PASSWORD=%sAa1!\nACCEPT_EULA=Y\nMSSQL_PID=Developer\nMSSQL_AGENT_ENABLED=true\n' "$(openssl rand -hex 12)" > "$f"
$P run -d --name "$N" --env-file "$f" --cpus "$3" --memory "$4" -p "$1:1433" -v "$N-data:/var/opt/mssql" "$2" >/dev/null
for _ in $(seq 1 36); do
  $P exec "$N" sh -c '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "SELECT 1" -h -1' >/dev/null 2>&1 && { echo "$N"; exit 0; }
  sleep 5
done
echo "SQL Server in $N didn't start in 3 minutes" >&2; exit 2
REMOTE
)
echo "container $NAME on port $PORT"
# the login, its password from the file through standard input (sqlcmd reads the batch from a temp file in the container)
python3 -I -c '
import sys; login, pwfile = sys.argv[1], sys.argv[2]
pw = open(pwfile).read().rstrip("\n").replace("'"'"'", "'"''"'")
print(f"CREATE LOGIN [{login}] WITH PASSWORD = N'"'"'{pw}'"'"', CHECK_POLICY = OFF;")' "$LOGIN" "$LOGIN_PW_FILE" \
  | "${SSH[@]}" "podman --remote --url unix:///run/podman/podman.sock exec -i $NAME sh -c 'f=\$(mktemp); cat > \$f; /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P \"\$MSSQL_SA_PASSWORD\" -b -h -1 -i \$f >/dev/null 2>&1; rc=\$?; rm -f \$f; exit \$rc'" \
  || { echo "login $LOGIN not created"; exit 2; }
echo "login $LOGIN created"
umask 077; J=$(mktemp)
jq -n --rawfile pw "$LOGIN_PW_FILE" --arg n "$CONNECTION_NAME" --arg h "$VM_IP" --arg p "$PORT" --arg u "$LOGIN" --arg c "$NAME" \
  '{name: $n, connection_type: "SQLSERVER", comment: ("SQL Server container " + $c + " on the test VM, port " + $p),
    options: {host: $h, port: $p, user: $u, password: ($pw | rtrimstr("\n")), trustServerCertificate: "true"}}' > "$J"
databricks connections create --json @"$J" --profile "$PROFILE" -o json >/dev/null; rc=$?; rm -f "$J"
[ $rc = 0 ] || { echo "connection $CONNECTION_NAME not created"; exit 2; }
WH=$(databricks warehouses list --profile "$PROFILE" -o json | yq '[.[] | select(.enable_serverless_compute)][0].id')
Q="SELECT * FROM remote_query('$CONNECTION_NAME', database => 'master', query => 'SELECT SUSER_NAME() AS u')" \
  yq -n -o json ".warehouse_id = \"$WH\" | .wait_timeout = \"50s\" | .statement = strenv(Q)" > "$J"
r=$(databricks api post /api/2.0/sql/statements --json @"$J" --profile "$PROFILE" -o json | yq -r '.status.state + " " + ((.result.data_array[0] // [])[0] // .status.error.message // "")'); rm -f "$J"
echo "connection $CONNECTION_NAME: $r"
echo "LINK connection $(databricks auth describe --profile "$PROFILE" -o json 2>/dev/null | yq -r '.details.host // ""')/explore/connections/$CONNECTION_NAME"
echo "for the test scripts: CONNECTION=$CONNECTION_NAME MSSQL_CONTAINER=$NAME"
[[ "$r" == SUCCEEDED* ]]
