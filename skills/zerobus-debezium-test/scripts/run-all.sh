#!/usr/bin/env bash
# run-all.sh: the repeatable test. Runs the committed skills, unchanged, on a cloud VM, and records which commit passed.
#
#   PROFILE=<cli profile> CATALOG=<catalog> VM_IP=<vm> bash skills/zerobus-debezium-test/scripts/run-all.sh
#
# 1. Pre-flight: the skill folders (zerobus-debezium-test, zerobus-workspace-setup, lfc-source-statschema) have no
#    uncommitted changes (ALLOW_DIRTY=1 to run anyway, marked in the summary); SSH to the VM answers (a changed laptop IP
#    blocks it at the VM's firewall, and every source query would then come back empty).
# 2. zerobus-workspace-setup/scripts/check.sh: the Zerobus previews, and TCP from the VM to the endpoint (443, 9092).
# 3. debezium-zerobus.sh for every source in SOURCES (default "crdb yb"), in parallel, each on its own port
#    (crdb 30026, yb 30031), each cleaning up after itself.
# 4. The results in RESULTS (default ~/.lfc-test/results/zerobus-<UTC time>): check.txt, <source>.md (the run's result
#    table), <source>.log, and summary.md. Exit 0 only when the check and every claim passed.
set -uo pipefail
export PATH=/opt/homebrew/bin:$PATH
: "${PROFILE:?}" "${CATALOG:?}" "${VM_IP:?}"
SOURCES=${SOURCES:-crdb yb}; SSH_KEY=${SSH_KEY:-$HOME/.ssh/lfc_test_rsa}; VM_USER=${VM_USER:-azureuser}
SKILL=$(cd "$(dirname "$0")/.." && pwd); REPO=$(cd "$SKILL/../.." && pwd)
RESULTS=${RESULTS:-$HOME/.lfc-test/results/zerobus-$(date -u +%Y%m%dT%H%M%SZ)}; mkdir -p "$RESULTS"
cd "$REPO" || exit 2

# --- 1. pre-flight
COMMIT=$(git rev-parse --short HEAD); DIRTY=$(git status --porcelain -- skills/zerobus-debezium-test skills/zerobus-workspace-setup skills/lfc-source-statschema)
if [ -n "$DIRTY" ] && [ "${ALLOW_DIRTY:-0}" != 1 ]; then
  echo "uncommitted changes in the skills; commit them, or run from a clean checkout (git worktree add <dir> HEAD):"; echo "$DIRTY"; exit 2; fi
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$VM_USER@$VM_IP" true 2>/dev/null \
  || { echo "no SSH to $VM_IP: is this laptop's IP ($(curl -s -m 5 https://api.ipify.org)) still allowed by the VM's firewall?"; exit 2; }
echo "commit $COMMIT${DIRTY:+ with uncommitted changes}; results in $RESULTS"

# --- 2. the workspace
bash skills/zerobus-workspace-setup/scripts/check.sh "$PROFILE" --interfaces grpc,kafka \
  --from "ssh -i $SSH_KEY -o BatchMode=yes $VM_USER@$VM_IP" > "$RESULTS/check.txt" 2>&1; CHECK=$?
grep -E '^(PASS|FAIL|WARN)' "$RESULTS/check.txt" | cut -c1-100

# --- 3. the sources, in parallel; each from a copy of the script with its own name (bash reads a script as it runs)
port() { case $1 in crdb) echo 30026;; yb) echo 30031;; *) echo 30040;; esac; }
for s in $SOURCES; do
  C=$RESULTS/run-$s.sh; cp skills/zerobus-debezium-test/scripts/debezium-zerobus.sh "$C"
  ( cd skills/zerobus-debezium-test && SOURCE=$s SRC_PORT=$(port $s) VM_IP=$VM_IP OUT="$RESULTS/$s.md" bash "$C" > "$RESULTS/$s.log" 2>&1
    echo "exit $?" >> "$RESULTS/$s.log" ) &
  sleep 5
done
wait

# --- 4. the summary
FAILED=$((CHECK != 0))
{ echo "# Zerobus CDC test, $(date -u +%F)"; echo
  echo "- Commit: \`$COMMIT\`${DIRTY:+ (with uncommitted changes)} of the tests repo; profile \`$PROFILE\`, catalog \`$CATALOG\`, VM \`$VM_IP\`"
  echo "- Workspace check: $([ $CHECK = 0 ] && echo PASS || echo FAIL) ($(grep -c '^PASS' "$RESULTS/check.txt") passed, $(grep -c '^FAIL' "$RESULTS/check.txt") failed)"; echo
  echo "| Source | Claims passed | Claims failed | Run | Exit |"; echo "|---|---|---|---|---|"
  for s in $SOURCES; do
    p=$(grep -c '^PASS' "$RESULTS/$s.log"); f=$(grep -c '^FAIL' "$RESULTS/$s.log"); x=$(grep -o '^exit [0-9]*' "$RESULTS/$s.log" | tail -1 | cut -d' ' -f2)
    [ "$f" = 0 ] && [ "$x" = 0 ] || FAILED=1
    echo "| $s | $p | $f | $(grep -o '^run [0-9]*' "$RESULTS/$s.log" | head -1 | cut -d' ' -f2) | $x |"; done
  for s in $SOURCES; do f=$(grep '^FAIL' "$RESULTS/$s.log"); [ -n "$f" ] && { echo; echo "## $s failures"; echo; echo "$f" | cut -c1-300 | sed 's/^/- /'; }; done
} > "$RESULTS/summary.md"
cat "$RESULTS/summary.md"; exit $FAILED
