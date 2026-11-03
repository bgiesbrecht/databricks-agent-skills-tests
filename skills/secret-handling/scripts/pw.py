#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["keyring"]
# ///
"""pw.py: test-database passwords in the OS keyring (macOS Keychain, Windows Credential Manager, Linux Secret Service)
instead of a plain-text file. Every script that takes a password file (ADMIN_PW_FILE, LOGIN_PW_FILE, sync.sh's
password_file column) also takes keyring:<name>, read through pw.sh.

  uv run pw.py new <name>            # a random password (Lfc1 + 24 hex: the three classes Azure SQL and SQL Server want)
  uv run pw.py set <name> < file     # store what's on standard input (trailing newline dropped)
  uv run pw.py import <name> <file>  # store a password file's content; then delete the file yourself
  uv run pw.py get <name>            # print it (for a pipe or $(...); never on a terminal you share)
  uv run pw.py rm <name>

The password never goes on a command line. Service name: lfc-test (LFC_KEYRING_SERVICE to change it). A headless Linux
VM usually has no keyring backend: keep a private file there (umask 077).
"""
import os
import secrets
import sys

import keyring
from keyring.errors import KeyringError, NoKeyringError

SERVICE = os.environ.get("LFC_KEYRING_SERVICE", "lfc-test")


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[0] not in ("new", "set", "import", "get", "rm"):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    what, name = argv[0], argv[1]
    try:
        if what == "get":
            pw = keyring.get_password(SERVICE, name)
            if pw is None:
                print(f"pw.py: no password {name!r} in the keyring (service {SERVICE}): uv run pw.py new {name}", file=sys.stderr)
                return 1
            sys.stdout.write(pw + "\n")
        elif what == "rm":
            keyring.delete_password(SERVICE, name)
        else:
            if what == "new":
                pw = "Lfc1" + secrets.token_hex(12)
            elif what == "set":
                pw = sys.stdin.read().rstrip("\n")
            else:
                with open(argv[2]) as f:
                    pw = f.read().rstrip("\n")
            if not pw:
                print("pw.py: empty password, nothing stored", file=sys.stderr)
                return 2
            keyring.set_password(SERVICE, name, pw)
            print(f"stored {name} (service {SERVICE}); use keyring:{name} where a password file goes", file=sys.stderr)
    except NoKeyringError:
        print("pw.py: no keyring backend on this machine; use a private password file (umask 077)", file=sys.stderr)
        return 2
    except KeyringError as e:
        print(f"pw.py: keyring {what} {name}: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
