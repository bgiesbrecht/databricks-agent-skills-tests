#!/usr/bin/env bash
# check-chrome-attach.sh: before a UI capture, check that the Chrome DevTools tools will attach to your own Chrome.
#   Checks: the chrome-devtools MCP entry in ~/.claude.json has --autoConnect; a running server was started with it
#   (a server started before the flag was added still opens its own blank browser); your Chrome is running.
#   Changes nothing. Exit 0 when all pass, 1 with the fix for the first that fails.
set -uo pipefail
CFG=~/.claude.json
args=$(python3 -c "import json,sys; print(' '.join(json.load(open(sys.argv[1]))['mcpServers']['chrome-devtools']['args']))" "$CFG" 2> /dev/null) \
  || { echo "no chrome-devtools MCP server in $CFG: add it (npx chrome-devtools-mcp --autoConnect)"; exit 1; }
echo "config: $args"
case " $args " in *" --autoConnect "*) ;; *)
  echo "FIX: --autoConnect is missing (something rewrote the entry). Add it to mcpServers.chrome-devtools.args in $CFG, then /mcp -> chrome-devtools -> Reconnect"; exit 1;; esac
# one line per server process: an old one (a session that ended, or a reconnect) can outlive its session
servers=$(ps -axo pid=,lstart=,command= | grep 'node .*bin/chrome-devtools-mcp' | grep -v grep)
if [ -z "$servers" ]; then echo "server: not running yet (Claude Code starts it with the session; /mcp shows its state)"
else
  echo "$servers" | while read -r pid d1 d2 d3 d4 d5 cmd; do
    case " $cmd " in *" --autoConnect "*) f="--autoConnect";; *) f="no --autoConnect: opens its own browser";; esac
    echo "server: pid $pid, started $d2 $d3 $d4, $f"; done
  echo "$servers" | grep -q -- '--autoConnect' \
    || echo "NOTE: no server runs with --autoConnect: /mcp -> chrome-devtools -> Reconnect"
fi
pgrep -xq 'Google Chrome' || { echo "FIX: your Chrome isn't running: start it and sign in to the workspace"; exit 1; }
echo "chrome: running. In it, chrome://inspect/#remote-debugging must be on; accept its prompt when the tools connect"
