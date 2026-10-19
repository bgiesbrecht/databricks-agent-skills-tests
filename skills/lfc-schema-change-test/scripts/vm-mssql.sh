#!/usr/bin/env bash
# vm-mssql.sh [database]: run T-SQL from stdin as sa on a SQL Server Podman container on a cloud VM (lfc-source-cloud-vm).
#   Needs VM_IP and MSSQL_CONTAINER; optional VM_USER (azureuser), SSH_KEY (~/.ssh/lfc_test_rsa).
#   The sa password stays on the VM: sqlcmd reads it from the container's own MSSQL_SA_PASSWORD.
set -euo pipefail
: "${VM_IP:?set VM_IP}" "${MSSQL_CONTAINER:?set MSSQL_CONTAINER}"
#   vm-mssql.sh --env prints the host OS, the Podman version and the container's image and digest instead.
SSH=(ssh -i "${SSH_KEY:-$HOME/.ssh/lfc_test_rsa}" -o BatchMode=yes "${VM_USER:-azureuser}@$VM_IP")
if [ "${1:-}" = --env ]; then
  "${SSH[@]}" ". /etc/os-release; echo \"Host: \$PRETTY_NAME\"; echo \"Podman: \$(podman --version)\"; sudo podman inspect --format 'Image: {{.ImageName}} ({{.ImageDigest}})' $MSSQL_CONTAINER"
  exit
fi
"${SSH[@]}" \
  "sudo podman exec -i $MSSQL_CONTAINER sh -c 'cat > /tmp/q.sql; /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P \"\$MSSQL_SA_PASSWORD\" -b -W -h -1 -d ${1:-master} -i /tmp/q.sql'"
