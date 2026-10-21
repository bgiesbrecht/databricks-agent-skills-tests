#!/usr/bin/env bash
# ensure-podman-socket.sh [--on "<command prefix>"]
#   Rootful Podman without sudo: give the login user the root Podman socket through a `podman` group, the way the
#   `docker` group works. After it, `podman --remote --url unix:///run/podman/podman.sock ...` runs rootful containers
#   (storage in /var/lib/containers, --privileged, raised ulimits) as the login user, with no sudo and so no password.
#   Members of the group can do anything root can through the socket: give it only to users who already have sudo.
#   --on runs it on a host: "ssh <user>@<vm>" or "limactl shell <instance> --" (default: this machine). Uses sudo once.
#   Steps (PASS / FIXED / FAIL): the podman group with the user in it; the socket unit's group and mode
#   (/etc/systemd/system/podman.socket.d/group.conf); /run/podman readable by the group at boot (tmpfiles.d);
#   podman.socket active; then, in a new session, the socket answers and a rootful container runs as uid 0.
set -uo pipefail
ON=; [ "${1:-}" = --on ] && ON=$2
fails=0; SOCK=unix:///run/podman/podman.sock
row() { printf "%-5s %-44s %s\n" "$1" "$2" "$3"; [ "$1" = FAIL ] && fails=$((fails + 1)); return 0; }
h() { case "$ON" in "") bash -c "$1";; ssh\ *) $ON "bash -c $(printf '%q' "$1")";; *) $ON bash -c "$1";; esac; }   # see ensure-podman-rootless.sh

U=$(h 'id -un')
h 'command -v podman >/dev/null' || { row FAIL "Podman installed" "run ensure-podman-rootless.sh first (it installs Podman)"; exit 1; }
if h "id -nG $U | tr ' ' '\n' | grep -qx podman"; then row PASS "$U in the podman group" ""
else
  h "sudo groupadd -f podman && sudo usermod -aG podman $U" && row FIXED "$U in the podman group" "added (new sessions get it)" || row FAIL "$U in the podman group" "groupadd/usermod failed"
  # limactl shell reuses one persistent ssh connection, so its sessions never pick up a new group: close it, and the
  # next limactl shell logs in again. That interrupts other limactl commands running then; it's done only this once.
  case "$ON" in "limactl shell "*) I=$(echo "$ON" | awk '{print $3}')
    ssh -F "$HOME/.lima/$I/ssh.config" -O exit "lima-$I" >/dev/null 2>&1 && row FIXED "Lima login refreshed" "closed the persistent ssh connection";; esac
fi
if h 'grep -q "SocketGroup=podman" /etc/systemd/system/podman.socket.d/group.conf 2>/dev/null'; then row PASS "socket group and mode" "podman, 0660"
else h 'sudo mkdir -p /etc/systemd/system/podman.socket.d && printf "[Socket]\nSocketMode=0660\nSocketGroup=podman\n" | sudo tee /etc/systemd/system/podman.socket.d/group.conf >/dev/null && sudo systemctl daemon-reload' \
  && row FIXED "socket group and mode" "podman, 0660" || row FAIL "socket group and mode" "couldn't write the unit override"; fi
if h 'grep -q "root podman" /etc/tmpfiles.d/podman-socket-dir.conf 2>/dev/null'; then row PASS "/run/podman readable by the group" ""
else h 'echo "d /run/podman 0750 root podman -" | sudo tee /etc/tmpfiles.d/podman-socket-dir.conf >/dev/null && sudo systemd-tmpfiles --create /etc/tmpfiles.d/podman-socket-dir.conf' \
  && row FIXED "/run/podman readable by the group" "tmpfiles.d" || row FAIL "/run/podman readable by the group" "tmpfiles failed"; fi
if [ "$(h 'stat -c "%G %a" /run/podman/podman.sock 2>/dev/null || sudo stat -c "%G %a" /run/podman/podman.sock')" = "podman 660" ] && [ "$(h 'systemctl is-active podman.socket')" = active ]; then
  row PASS "podman.socket active, group podman" ""
else h 'sudo systemctl enable podman.socket >/dev/null 2>&1; sudo systemctl restart podman.socket' && row FIXED "podman.socket active, group podman" "restarted" || row FAIL "podman.socket active, group podman" "systemctl failed"; fi
# a new session picks up the group: the check must not run in this one if the group was just added
r=$(h "podman --remote --url $SOCK run --rm docker.io/library/alpine:3 id -u" 2>/dev/null | tail -1)
[ "$r" = 0 ] && row PASS "rootful container without sudo" "uid 0 in the container" \
  || row FAIL "rootful container without sudo" "no answer from $SOCK (a session opened before the group was added doesn't have it: run again)"
exit $((fails > 0))
