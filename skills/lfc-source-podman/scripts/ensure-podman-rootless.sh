#!/usr/bin/env bash
# ensure-podman-rootless.sh [--on "<command prefix>"]
#   Make a Linux host ready to run test containers as the login user, with plain `podman` (rootless): the only place
#   that needs sudo, and only once per host. --on runs it there: "ssh <user>@<vm>" or "limactl shell <instance> --"
#   (default: this machine). Steps, one line each (PASS / FIXED / FAIL):
#     Podman installed (apt-get or dnf);
#     subordinate user and group IDs for the user (/etc/subuid, /etc/subgid), which rootless containers map users to;
#     linger on (loginctl enable-linger): without it systemd stops a rootless user's containers when the user's last
#       session ends, and scripts that drive a host over many short ssh or limactl sessions lose their containers;
#     ~/.cache owned by the user (earlier rootful runs can leave root-owned files there);
#     a rootless container runs, and a container's name resolves from another on a Podman network.
#   Exit 1 if anything FAILs.
set -uo pipefail
ON=; [ "${1:-}" = --on ] && ON=$2
fails=0
row() { printf "%-5s %-44s %s\n" "$1" "$2" "$3"; [ "$1" = FAIL ] && fails=$((fails + 1)); return 0; }
# h <command>: run it on the host. ssh joins its arguments into one string for the remote shell, so the command goes
# quoted; limactl shell (and no prefix) passes them as they are
h() { case "$ON" in "") bash -c "$1";; ssh\ *) $ON "bash -c $(printf '%q' "$1")";; *) $ON bash -c "$1";; esac; }

if h 'command -v podman >/dev/null'; then row PASS "Podman installed" "$(h 'podman --version')"
else h 'if command -v apt-get >/dev/null; then sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman;
        elif command -v dnf >/dev/null; then sudo dnf install -y -q podman; else exit 1; fi' >/dev/null 2>&1 \
  && row FIXED "Podman installed" "$(h 'podman --version')" || row FAIL "Podman installed" "no apt-get or dnf, or the install failed"; fi
U=$(h 'id -un')
if h "grep -q '^$U:' /etc/subuid && grep -q '^$U:' /etc/subgid"; then row PASS "subordinate IDs for $U" "$(h "grep '^$U:' /etc/subuid")"
else h "sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $U && podman system migrate" >/dev/null 2>&1 \
  && row FIXED "subordinate IDs for $U" "100000-165535" || row FAIL "subordinate IDs for $U" "usermod failed"; fi
if [ "$(h "loginctl show-user $U -p Linger --value" 2>/dev/null)" = yes ]; then row PASS "linger for $U" "on"
else h "sudo loginctl enable-linger $U" >/dev/null 2>&1 && row FIXED "linger for $U" "turned on" || row FAIL "linger for $U" "loginctl enable-linger failed"; fi
n=$(h 'find "$HOME/.cache" -xdev ! -user "$(id -un)" 2>/dev/null | wc -l | tr -d " "')
if [ "${n:-0}" = 0 ]; then row PASS "~/.cache owned by $U" ""
else h 'sudo chown -R "$(id -un):$(id -gn)" "$HOME/.cache"' && row FIXED "~/.cache owned by $U" "$n files were someone else's" || row FAIL "~/.cache owned by $U" "chown failed"; fi
r=$(h 'podman info --format "{{.Host.Security.Rootless}} {{.Host.Arch}}"' 2>/dev/null)
case "$r" in "true "*) row PASS "rootless Podman" "arch ${r#true }";; *) row FAIL "rootless Podman" "podman info: ${r:-failed}";; esac
d=$(h 'N=ensure-rootless-$$; podman network create $N >/dev/null && podman run -d --rm --name $N-a --network $N --network-alias peer docker.io/library/alpine:3 sleep 30 >/dev/null \
       && podman run --rm --network $N docker.io/library/alpine:3 sh -c "ping -c1 -W3 peer >/dev/null && echo ok"; podman rm -f $N-a >/dev/null 2>&1; podman network rm $N >/dev/null 2>&1' 2>/dev/null)
[ "$d" = ok ] && row PASS "container names resolve on a network" "" || row FAIL "container names resolve on a network" "aardvark-dns missing? (apt-get install aardvark-dns)"
exit $((fails > 0))
