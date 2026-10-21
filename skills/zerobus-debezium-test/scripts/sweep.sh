#!/usr/bin/env bash
# sweep.sh [--apply]: remove what debezium-zerobus.sh runs left behind.
#   A run cleans up when it exits; a run that's killed, or kept with KEEP=1, leaves its objects. Each object's name has
#   the run's epoch, so the sweep finds them by name:
#     host (VM_IP over SSH, or LIMA):  containers <prefix>-{crdb,yb,debezium,debezium<i>}-<E>, networks {crdb,yb}-dbz-<E>, /tmp/dbz-*-<E>
#     workspace (PROFILE, CATALOG):    pipelines <prefix>-{crdb,yb}-dbz-silver-<E>, connections <prefix>-{crdb,yb}-dbz-<E>,
#                                      fan-out jobs <prefix>-{crdb,yb}-<model>-dbz-fanout-<E>,
#                                      service principals <prefix>-zerobus-dbz-<E>, folders /Users/<me>/{crdb,yb}_dbz_<E>,
#                                      schemas <prefix>_{crdb,yb}[_<model>]_dbz_<E> in CATALOG
#   It skips runs younger than MIN_AGE seconds (default 7200: one may still be running) and runs in KEEP_RUNS
#   ("<epoch> <epoch>"). Prints the plan; removes nothing without --apply.
set -uo pipefail
export PATH=/opt/homebrew/bin:$PATH
: "${PROFILE:?}" "${CATALOG:?}"; APPLY=no; [ "${1:-}" = --apply ] && APPLY=yes
MIN_AGE=${MIN_AGE:-7200}; KEEP_RUNS=" ${KEEP_RUNS:-} "; NOW=$(date +%s)
PODMAN=${PODMAN:-podman --remote --url unix:///run/podman/podman.sock}   # as debezium-zerobus.sh
rmc() { case $1 in /*/?*) ;; *) echo "rmc: '$1' isn't an absolute path below a folder" >&2; echo false; return;; esac   # never / or empty
  echo "$PODMAN run --rm -v $(dirname "$1"):/p docker.io/library/alpine:3 rm -rf /p/$(basename "$1")"; }
dbx() { databricks "$@" --profile "$PROFILE"; }
if [ -n "${LIMA:-}" ]; then host() { limactl shell "$LIMA" -- bash -c "$*"; }
elif [ -n "${VM_IP:-}" ]; then host() { ssh -i "${SSH_KEY:-$HOME/.ssh/lfc_test_rsa}" -o BatchMode=yes -o ConnectTimeout=10 "${VM_USER:-azureuser}@$VM_IP" "$@"; }
else host() { :; }; fi
ME=$(dbx current-user me -o json | yq '.userName'); PREFIX=${PREFIX:-$(echo "$ME" | cut -d@ -f1 | tr -d '.-' | tr 'A-Z' 'a-z')}
old() { local e=$1; case "$KEEP_RUNS" in *" $e "*) return 1;; esac; [ $((NOW - e)) -ge "$MIN_AGE" ]; }   # old <epoch>: sweep it?
n=0
act() { # act <what> <command...>: print, and run it with --apply
  n=$((n + 1)); local what=$1; shift
  if [ $APPLY = yes ]; then "$@" >/dev/null 2>&1 && echo "removed  $what" || echo "FAILED   $what"; else echo "would remove  $what"; fi; }
epoch() { echo "$1" | grep -o -E '[0-9]{10}' | tail -1; }

for c in $(host "$PODMAN ps -a --format '{{.Names}}'" 2>/dev/null | grep -E "^$PREFIX-(crdb|yb|debezium[0-9]*)-[0-9]{10}\$"); do
  old "$(epoch "$c")" && act "container $c" host "$PODMAN rm -f --ignore $c"; done
for x in $(host "$PODMAN network ls --format '{{.Name}}'" 2>/dev/null | grep -E '^(crdb|yb)-dbz-[0-9]{10}$'); do
  old "$(epoch "$x")" && act "network $x" host "$PODMAN network rm $x"; done
for d in $(host "ls -d /tmp/dbz-* 2>/dev/null"); do e=$(epoch "$d"); [ -n "$e" ] && old "$e" && act "host dir $d" host "$(rmc $d)"; done

for p in $(dbx pipelines list-pipelines -o json | yq -r ".[] | select(.name | test(\"^$PREFIX-(crdb|yb)(-[a-z0-9]+)?-dbz-silver-[0-9]{10}\$\")) | .name + \"|\" + .pipeline_id"); do
  old "$(epoch "${p%%|*}")" && act "pipeline ${p%%|*}" dbx pipelines delete "${p##*|}"; done
for j in $(dbx jobs list -o json | yq -r ".[] | select(.settings.name | test(\"^$PREFIX-(crdb|yb)-[a-z0-9]+-dbz-fanout-[0-9]{10}\$\")) | .settings.name + \"|\" + (.job_id | tostring)"); do
  old "$(epoch "${j%%|*}")" && act "job ${j%%|*}" dbx jobs delete "${j##*|}"; done
for c in $(dbx connections list -o json | yq -r ".[] | select(.name | test(\"^$PREFIX-(crdb|yb)-dbz-[0-9]{10}\$\")) | .name"); do
  old "$(epoch "$c")" && act "connection $c" dbx connections delete "$c"; done
for s in $(dbx service-principals list --filter "displayName sw \"$PREFIX-zerobus-dbz-\"" -o json | yq -r '.[] | .displayName + "|" + .id'); do
  old "$(epoch "${s%%|*}")" && act "service principal ${s%%|*}" dbx service-principals delete "${s##*|}"; done
for w in $(dbx workspace list "/Users/$ME" -o json 2>/dev/null | yq -r '.[] | select(.path | test("/(crdb|yb)_dbz_[0-9]{10}$")) | .path'); do
  old "$(epoch "$w")" && act "folder $w" dbx workspace delete "$w" --recursive; done
for s in $(dbx schemas list "$CATALOG" -o json | yq -r ".[] | select(.name | test(\"^${PREFIX}_(crdb|yb)(_[a-z0-9]+)?_dbz_[0-9]{10}\$\")) | .name"); do
  old "$(epoch "$s")" && act "schema $CATALOG.$s" dbx schemas delete "$CATALOG.$s" --force; done

[ $n -eq 0 ] && echo "nothing to sweep (runs younger than ${MIN_AGE}s and KEEP_RUNS are left)"
[ $APPLY = yes ] || [ $n -eq 0 ] || echo "plan only: run again with --apply"
