#!/usr/bin/env bash
# profiles-check.sh [--json FILE] [--verify]: for every workspace profile in ~/.databrickscfg, does it log in, and if not, can an
#   account login cover it (ws-token.sh)? Read-only: one `databricks auth profiles -o json`, which validates each
#   profile (a few seconds for dozens). --json FILE reads a saved copy of that output instead.
#   Prints TSV, one line per workspace profile:
#     profile  cloud  account (first 8)  login (valid | expired)  status  next step
#   status: ok (its own login works) | try (expired, but a fallback may work: a valid account profile for its account,
#   or on Azure the Azure CLI: ws-token.sh <profile>) | account-expired (an account profile exists, its login has expired) | no-account-profile
#   (none for that account: add-account.sh <account-id> <cloud>) | no-account-id (the profile doesn't say its account).
#   --verify runs ws-token.sh for every expired profile and replaces try / account-expired / no-account-profile with
#   covered (it got a working token) or needs-login (it didn't; the reason follows). It reads and writes nothing in
#   ~/.databrickscfg, and deletes each token file. Then one line per account that workspace profiles need but no valid
#   account profile covers. Exit 1 if any workspace profile is neither ok nor covered/try.
set -uo pipefail
J=; VERIFY=; while [ $# -gt 0 ]; do case $1 in --json) J=$2; shift 2;; --verify) VERIFY=1; shift;; *) echo "unknown $1" >&2; exit 2;; esac; done
D=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
if [ -n "$J" ]; then cp "$J" "$T/ap.json"; else databricks auth profiles -o json > "$T/ap.json" 2> "$T/err" || { cat "$T/err" >&2; exit 1; }; fi
# one row per profile: kind (account | workspace), name, cloud, account_id, valid, auth_type
yq -p json -o tsv '.profiles[] | [(.host | test("^https://accounts\.") | tostring),
  .name, (.cloud // ""), (.account_id // ""), (.valid | tostring), (.auth_type // "")]' "$T/ap.json" \
  | awk -F'\t' -v OFS='\t' '{ $1 = ($1 == "true" ? "account" : "workspace"); print }' > "$T/rows"   # yq's // misreads false
# accounts: the first valid account profile per account_id, or any profile of that account (all expired)
awk -F'\t' '$1=="account" && $4!="" { if ($5=="true" && !(($4) in ok)) ok[$4]=$2; if (!(($4) in any)) any[$4]=$2 }
  END { for (a in any) print a "\t" (a in ok ? ok[a] : "") "\t" any[a] }' "$T/rows" > "$T/acct"
{
printf 'profile\tcloud\taccount\tlogin\tstatus\tnext\n'
awk -F'\t' -v D="$D" 'NR==FNR { okp[$1]=$2; anyp[$1]=$3; next }
  $1!="workspace" { next }
  { p=$2; c=$3; a=$4; v=($5=="true" ? "valid" : "expired"); a8=(a=="" ? "-" : substr(a,1,8))
    if (v=="valid") { s="ok"; n="" }
    else if (a=="") { s="no-account-id"; n="databricks auth login --profile " p "  (a new login writes account_id)" }
    else if (okp[a]!="" || c=="azure") { s="try"; n="bash " D "/ws-token.sh " p (okp[a]!="" ? "  (via " okp[a] ")" : "  (Azure CLI)") }
    else if (anyp[a]!="") { s="account-expired"; n="databricks auth login --profile " anyp[a]; need[a]=c }
    else { s="no-account-profile"; n="bash " D "/add-account.sh " a " " c; need[a]=c }
    print p "\t" c "\t" a8 "\t" v "\t" s "\t" n; if (s!="ok" && s!="covered") bad=1 }
  END { for (a in need) printf "# account %s (%s): no valid account profile; %s\n", a, need[a], (anyp[a]!="" ? "log in again: databricks auth login --profile " anyp[a] : "add one: bash " D "/add-account.sh " a " " need[a]) > "/dev/stderr"
        exit bad }' "$T/acct" "$T/rows"
} > "$T/out" 2> "$T/accts"; rc=$?
if [ -z "$VERIFY" ]; then cat "$T/out"; cat "$T/accts" >&2; exit $rc; fi
head -1 "$T/out"
tail -n +2 "$T/out" | while IFS=$'\t' read -r p c a v st nx; do
  if [ "$st" = ok ]; then printf '%s\t%s\t%s\t%s\t%s\t\n' "$p" "$c" "$a" "$v" "$st"; continue; fi
  cfg=$(bash "$D/ws-token.sh" "$p" 2> "$T/why" < /dev/null); why=$(grep -v -e ': using a token' -e 'its login has expired and no account profile' "$T/why" | sed 's/^ws-token: //' | paste -sd ';' - | sed 's/;/; /g'); [ -n "$why" ] || why=$(tail -1 "$T/why" | sed 's/^ws-token: //')
  if [ -n "$cfg" ]; then rm -f "$cfg"; printf '%s\t%s\t%s\t%s\tcovered\t%s\n' "$p" "$c" "$a" "$v" "$(sed 's/^ws-token: [^:]*: //' "$T/why" | tail -1)"
  else printf '%s\t%s\t%s\t%s\tneeds-login\t%s\n' "$p" "$c" "$a" "$v" "$why"; touch "$T/bad"; fi
done
[ -f "$T/bad" ] && exit 1; exit 0
