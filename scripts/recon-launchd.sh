#!/bin/bash
# Load / restart / stop the asbuilt-recon LaunchAgents written by scripts/install-recon-server.sh.
# Run this from Terminal.app (agents running inside the Hermes gateway are not allowed to call launchctl).
#   recon-launchd.sh load      first time (the agents also auto-load at every login: RunAtLoad)
#   recon-launchd.sh restart   after re-running the installer (picks up new binaries)
#   recon-launchd.sh status | unload
set -u
D="gui/$(id -u)"
LA="$HOME/Library/LaunchAgents"
if [ "${1:-status}" = load ]; then
  # Stop copies started by hand (e.g. during testing) so launchd's copies can bind 127.0.0.1:8765
  # and own the tunnel. Matches only these two scripts.
  pkill -TERM -f "asbuilt-recon-server.py --port 8765" 2>/dev/null && echo "stopped a server started outside launchd"
  pkill -TERM -f "bin/recon_tunnel.py" 2>/dev/null && echo "stopped a tunnel started outside launchd"
  sleep 3
fi
for l in com.moltstrong.asbuilt-recon com.moltstrong.asbuilt-recon-tunnel; do
  f="$LA/$l.plist"
  [ -f "$f" ] || { echo "skip $l (no plist; run install-recon-server.sh)"; continue; }
  case "${1:-status}" in
    load)    launchctl bootstrap "$D" "$f" && echo "loaded $l" ;;
    restart) launchctl kickstart -k "$D/$l" && echo "restarted $l" ;;
    unload)  launchctl bootout "$D/$l" && echo "unloaded $l" ;;
    status)  (launchctl print "$D/$l" 2>/dev/null | grep -E "^[[:space:]]*(state|pid|last exit code) =" | sed "s/^[[:space:]]*/$l: /") || echo "$l: not loaded" ;;
    *) echo "usage: $0 load|restart|unload|status"; exit 2 ;;
  esac
done
sleep 2
printf 'local health: '; curl -fsS -m 3 http://127.0.0.1:8765/v1/health || echo "not answering"
echo
[ -s "$HOME/.config/asbuilt-recon/base_url" ] && echo "public base URL: $(cat "$HOME/.config/asbuilt-recon/base_url")"
