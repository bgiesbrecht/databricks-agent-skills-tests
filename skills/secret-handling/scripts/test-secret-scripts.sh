#!/usr/bin/env bash
# test-secret-scripts.sh: checks secret-run.sh, secret-find.sh, secret-perms.sh and block-secret-prints.py on throwaway
#   files with a fake secret (never a real one). Prints one PASS/FAIL line per check; exit 1 on any FAIL.
set -uo pipefail
S=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT; fail=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
FAKE="fake-$(openssl rand -hex 8)"
printf '{"host":"h","dba":{"user":"u","password":"%s"}}\n' "$FAKE" > "$T/app_credentials.json"
printf '%s\n' "$FAKE" > "$T/db.pw"
mkdir -p "$T/a/repo"; G=(git -C "$T/a/repo" -c user.email=t@example.com -c user.name=t)
"${G[@]}" init -q; printf 'x=%s\n' "$FAKE" > "$T/a/repo/leak.txt"
"${G[@]}" add leak.txt; "${G[@]}" commit -q -m leak; "${G[@]}" rm -q leak.txt; "${G[@]}" commit -q -m clean

out=$("$S/secret-run.sh" "$T/app_credentials.json" .dba.password P -- sh -c 'echo "${#P}"')
ok "run: json field reaches the command" '[ "$out" = ${#FAKE} ]'
out=$("$S/secret-run.sh" "$T/db.pw" - P -- sh -c 'echo "${#P}"')
ok "run: plain file, newline removed" '[ "$out" = ${#FAKE} ]'
out=$("$S/secret-run.sh" "$T/app_credentials.json" .dba.password P -- true 2>&1)
ok "run: prints nothing itself" '[ -z "$out" ]'

out=$("$S/secret-find.sh" "$T/app_credentials.json" .dba.password "$T"); rc=$?
ok "find: exit 1 on a leak" '[ $rc = 1 ]'
ok "find: the other file" '[[ "$out" == *"file: $T/db.pw"* ]]'
ok "find: the commit that removed the file" '[[ "$out" == *"commit: $T/a/repo"*leak* ]]'
ok "find: never prints the value" '[[ "$out" != *"$FAKE"* ]]'

chmod 644 "$T/db.pw"
"$S/secret-perms.sh" "$T/db.pw" >/dev/null; rc=$?
ok "perms: 644 reported" '[ $rc = 1 ]'
"$S/secret-perms.sh" --fix "$T/db.pw" >/dev/null; "$S/secret-perms.sh" "$T/db.pw" >/dev/null; rc=$?
ok "perms: --fix makes it 600" '[ $rc = 0 ]'

ok "hook: self-test" 'python3 -I "$S/block-secret-prints.py" --self-test >/dev/null'
printf '{"tool_name":"Bash","tool_input":{"command":"cat %s"}}' "$T/db.pw" | python3 -I "$S/block-secret-prints.py" 2>/dev/null; rc=$?
ok "hook: exit 2 on cat of a .pw file" '[ $rc = 2 ]'
exit $fail
