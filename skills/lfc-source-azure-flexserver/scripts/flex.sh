#!/usr/bin/env bash
# flex.sh pg|mysql plan|create|status|stop|start|delete: an Azure Database for PostgreSQL or MySQL Flexible Server set
#   up for Lakeflow Connect query-based and CDC.
#   Needs RG, LOCATION, SERVER (globally unique), DB. Optional: SUBSCRIPTION (else az's default), SKU (Standard_B1ms),
#   TIER (Burstable), STORAGE_GB (32), VERSION (pg 16, mysql 8.0.21), OWNER ($USER).
#   create also needs ADMIN_PW_FILE (a private file, or keyring:<name>, with the lfcadmin password).
#   create: the server with public access and no firewall rules (closed until lfc-source-firewall's server-fw.py adds
#   the same list as every other source), the database, and the parameters CDC needs, then a restart if one changed:
#     pg     wal_level=logical, max_replication_slots>=10, max_wal_senders>=10
#     mysql  binlog_row_image=FULL, binlog_expire_logs_seconds>=604800 (7 days), sql_generate_invisible_primary_key=OFF
#            (Azure's default ON gives keyless tables a hidden key)
#   TLS stays required (require_secure_transport); the UC connection uses TLS.
#   stop/start: a stopped server costs storage only; Azure starts it again by itself after 7 days.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../lfc-source-setup/scripts/pw.sh"   # pw/pw_check: a password file or keyring:<name>
E=${1:?pg|mysql}; CMD=${2:?plan|create|status|stop|start|delete}
: "${RG:?}" "${SERVER:?}" "${DB:?}"
# public access with no firewall rules: postgres calls that Enabled (its None turns public access off); mysql None
case $E in pg) S=postgres; V=${VERSION:-16}; DBF=-n; PUBLIC=Enabled;; mysql) S=mysql; V=${VERSION:-8.0.21}; DBF=-d; PUBLIC=None;; *) echo "pg or mysql"; exit 2;; esac
A=(--resource-group "$RG"); [ -n "${SUBSCRIPTION:-}" ] && A+=(--subscription "$SUBSCRIPTION")
srv() { az $S flexible-server show "${A[@]}" -n "$SERVER" -o json 2>/dev/null; }
param() { az $S flexible-server parameter show "${A[@]}" --server-name "$SERVER" -n "$1" --query value -o tsv; }
setp() { # name value: set when different; prints the name if it needs a restart
  local cur; cur=$(param "$1"); [ "$(echo "$cur" | tr A-Z a-z)" = "$(echo "$2" | tr A-Z a-z)" ] && return 0
  az $S flexible-server parameter set "${A[@]}" --server-name "$SERVER" -n "$1" --value "$2" -o none; echo "$1"; }
atleast() { local cur; cur=$(param "$1"); [ "${cur:-0}" -ge "$2" ] 2>/dev/null || setp "$1" "$2"; }

case $CMD in
plan|create)
  : "${LOCATION:?}"
  echo "server   $SERVER $S $V ${TIER:-Burstable} ${SKU:-Standard_B1ms} ${STORAGE_GB:-32} GB ($LOCATION), public access, no firewall rules $(srv >/dev/null && echo '(exists)' || echo '(new)')"
  echo "database $DB"
  [ "$CMD" = plan ] && exit 0
  : "${ADMIN_PW_FILE:?}"; pw_check "$ADMIN_PW_FILE" || exit 2
  if ! srv >/dev/null; then
    # az takes the password only as a flag: it's in this machine's process list while the command runs
    az $S flexible-server create "${A[@]}" -n "$SERVER" -l "$LOCATION" --admin-user lfcadmin --admin-password "$(pw "$ADMIN_PW_FILE")" \
      --tier "${TIER:-Burstable}" --sku-name "${SKU:-Standard_B1ms}" --storage-size "${STORAGE_GB:-32}" --version "$V" \
      --public-access "$PUBLIC" --tags owner="${OWNER:-$USER}" purpose=lfc-test created="$(date -u +%Y-%m-%d)" --yes -o none
  fi
  az $S flexible-server db show "${A[@]}" -s "$SERVER" $DBF "$DB" -o none 2>/dev/null \
    || az $S flexible-server db create "${A[@]}" -s "$SERVER" $DBF "$DB" -o none
  if [ $E = pg ]; then
    changed=$(setp wal_level logical; atleast max_replication_slots 10; atleast max_wal_senders 10)
  else
    changed=$(setp binlog_row_image FULL; atleast binlog_expire_logs_seconds 604800; setp sql_generate_invisible_primary_key OFF)
  fi
  if [ -n "$changed" ]; then echo "set: $(echo $changed)"; az $S flexible-server restart "${A[@]}" -n "$SERVER" -o none; echo "restarted"; fi
  echo "ready: $(srv | yq -p json '.fullyQualifiedDomainName') database $DB. Next: lfc-source-firewall scripts/server-fw.py $E $SERVER" ;;
status) srv | yq -p json '{"state": .state, "fqdn": .fullyQualifiedDomainName, "version": .version, "sku": .sku.name}' ;;
stop|start) az $S flexible-server "$CMD" "${A[@]}" -n "$SERVER" -o none && echo "$CMD: $SERVER" ;;
delete) az $S flexible-server delete "${A[@]}" -n "$SERVER" --yes -o none && echo "deleted $SERVER" ;;
*) echo "unknown $CMD"; exit 2 ;;
esac
