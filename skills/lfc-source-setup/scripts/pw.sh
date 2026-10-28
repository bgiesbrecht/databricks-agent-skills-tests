# pw.sh: source it. A password reference is a private file's path (the default) or keyring:<name> (pw.py, the OS
# keyring). pw <ref> prints the password; pw_check <ref> says whether it can be read, without printing it.
_PW_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pw() {
  case "$1" in
    keyring:*) uv run -q --script "$_PW_DIR/pw.py" get "${1#keyring:}" ;;
    *) cat "$1" ;;
  esac
}
pw_check() {
  case "$1" in
    keyring:*) pw "$1" > /dev/null ;;
    *) [ -r "$1" ] || { echo "can't read $1" >&2; return 1; } ;;
  esac
}
