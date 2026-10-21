#!/usr/bin/env bash
# remove-podman-desktop.sh [--yes] [--machines]: remove Podman Desktop from a Mac so it stops starting its own
#   podman machine VM (a second VM next to Lima, whose disk image grows and doesn't shrink).
#   Without --yes it only reports: the app, its Homebrew cask, its files, podman machines and their disk use, and
#   VM disk files that were deleted while still open. --yes quits the app, uninstalls the cask (--zap) and deletes
#   its files. --machines also stops and removes every `podman machine` VM (their databases are lost) and the
#   downloaded VM images. Kept: the podman CLI, Lima and its VMs, ~/.config/containers (system connections).
set -uo pipefail
YES=; MACH=
while [ $# -gt 0 ]; do case $1 in --yes) YES=1; shift;; --machines) MACH=1; shift;; *) echo "unknown $1" >&2; exit 2;; esac; done
[ "$(uname)" = Darwin ] || { echo "macOS only" >&2; exit 2; }
ID=io.podmandesktop.PodmanDesktop
MD=~/.local/share/containers/podman/machine
FILES=(
  "/Applications/Podman Desktop.app" "$HOME/Applications/Podman Desktop.app"
  ~/.local/share/containers/podman-desktop
  "$HOME/Library/Application Support/Podman Desktop"
  ~/Library/Preferences/$ID.plist
  "$HOME/Library/Saved Application State/$ID.savedState"
  ~/Library/Caches/$ID ~/Library/Caches/$ID.ShipIt
  ~/Library/HTTPStorages/$ID
  "$HOME/Library/Logs/Podman Desktop"
  ~/Library/LaunchAgents/io.podman_desktop.PodmanDesktop.plist
)
run() { if [ -n "$YES" ]; then echo "+ $*"; "$@"; else echo "would run: $*"; fi; }
free() { df -k / | awk 'NR == 2 {printf "%.1f GB free", $4 / 1048576}'; }
echo "disk: $(free)"

echo "== Podman Desktop"
pgrep -f 'Podman Desktop.app' > /dev/null && echo "running"
cask=; brew list --cask podman-desktop > /dev/null 2>&1 && cask=1 && echo "Homebrew cask: podman-desktop (auto-updates, and 'brew bundle' reinstalls it from a Brewfile that lists it)"
for b in ~/Brewfile ~/.Brewfile ~/.config/homebrew/Brewfile; do grep -qs '"podman-desktop"' "$b" && echo "listed in $b: remove that line too"; done
for f in "${FILES[@]}"; do [ -e "$f" ] && echo "  $(du -sh "$f" 2> /dev/null | cut -f1)	$f"; done

echo "== podman machines (Podman Desktop starts podman-machine-default)"
machines=$(podman machine list --format '{{.Name}}' 2> /dev/null | tr -d '*')
for m in $machines; do echo "  $m"; done
[ -d "$MD" ] && find "$MD" -type f \( -name '*.raw' -o -name '*.img' -o -name '*.qcow2' -o -name '*.zst' -o -name '*.xz' \) -exec du -h {} + 2> /dev/null | sed 's/^/  /'
[ -z "$machines" ] && pgrep -fl 'vfkit|krunkit' | sed 's/^/  running with no machine: /'
open=$(lsof +L1 -nP 2> /dev/null | grep -iE '\.raw|\.img|podman' | awk '{print $1 " pid " $2 ": " $NF}' | sort -u)
[ -n "$open" ] && { echo "deleted while open (still taking space; stop these processes):"; echo "$open" | sed 's/^/  /'; }

[ -z "$YES" ] && { echo; echo "nothing changed: rerun with --yes to remove Podman Desktop${machines:+, and --machines to remove the machines too}"; exit 0; }

echo "== removing"
# quit first: a running app restarts its machine and rewrites its files
osascript -e "quit app id \"$ID\"" 2> /dev/null; sleep 2; pkill -f 'Podman Desktop.app' 2> /dev/null
if [ -n "$MACH" ]; then
  # remove machines before their files: a running VM keeps writing to a deleted disk image
  for m in $machines; do run podman machine stop "$m"; run podman machine rm -f "$m"; done
  for c in "$MD"/*/cache; do [ -d "$c" ] && run rm -rf "${c:?}"; done
fi
[ -n "$cask" ] && run brew uninstall --cask --zap podman-desktop
for f in "${FILES[@]}"; do [ -e "$f" ] && run rm -rf "${f:?}"; done
sleep 3; echo "disk: $(free) (the virtualization service can take a minute to give the space back)"
