#!/bin/bash
# Installs the asbuilt-recon build server on this Mac. It does not call launchctl (see recon-launchd.sh):
#   ~/Library/Application Support/asbuilt-recon/bin/{asbuilt-recon, asbuilt-recon-server.py, recon_tunnel.py, recon-launchd.sh}
#   ~/bin/asbuilt-recon (+ asbuilt-recon-server.py next to it, so `asbuilt-recon serve` works from PATH)
#   ~/Library/LaunchAgents/com.moltstrong.asbuilt-recon.plist         HTTP server on 127.0.0.1:8765
#   ~/Library/LaunchAgents/com.moltstrong.asbuilt-recon-tunnel.plist  public HTTPS (cloudflared quick tunnel)
#   ~/.config/asbuilt-recon/api_key (0600; generated once, never printed) -> GitHub secret RECON_API_KEY
#   ~/.config/asbuilt-recon/config.json (iMessage on done/failed via the local BlueBubbles server)
# Usage: scripts/install-recon-server.sh [--no-tunnel] [--no-secret] [--no-notify]
# Then, from Terminal.app: "$HOME/Library/Application Support/asbuilt-recon/bin/recon-launchd.sh" load   (or restart)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MR="$ROOT/MacRecon"
APP="$HOME/Library/Application Support/asbuilt-recon"
BIN="$APP/bin"
CONF="$HOME/.config/asbuilt-recon"
LA="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/asbuilt-recon"
REPO="moltstrong/asbuilt"
TUNNEL=1; SECRET=1; NOTIFY=1
for a in "$@"; do case "$a" in --no-tunnel) TUNNEL=0;; --no-secret) SECRET=0;; --no-notify) NOTIFY=0;; *) echo "unknown option $a"; exit 2;; esac; done

echo "== build"
(cd "$MR" && swift build -c release 2>&1 | tail -1)
mkdir -p "$BIN" "$LOGS" "$LA" "$HOME/bin"
mkdir -p "$CONF" && chmod 700 "$CONF"
install -m 755 "$MR/.build/release/asbuilt-recon" "$BIN/asbuilt-recon"
install -m 644 "$MR/server/recon_server.py" "$BIN/asbuilt-recon-server.py"
install -m 644 "$MR/server/recon_tunnel.py" "$BIN/recon_tunnel.py"
install -m 755 "$ROOT/scripts/recon-launchd.sh" "$BIN/recon-launchd.sh"
install -m 755 "$BIN/asbuilt-recon" "$HOME/bin/asbuilt-recon"
install -m 644 "$BIN/asbuilt-recon-server.py" "$HOME/bin/asbuilt-recon-server.py"
echo "installed to $BIN and ~/bin"

echo "== api key"
if [ ! -s "$CONF/api_key" ]; then (umask 077; openssl rand -hex 32 > "$CONF/api_key"); echo "generated a new key"; fi
chmod 600 "$CONF/api_key"
if [ "$SECRET" = 1 ]; then
  gh secret set RECON_API_KEY -R "$REPO" < "$CONF/api_key" && echo "GitHub secret RECON_API_KEY set"
fi

if [ "$NOTIFY" = 1 ] && [ ! -f "$CONF/config.json" ]; then
  cat > "$CONF/config.json" <<'JSON'
{
 "notify": {
  "bluebubbles": true,
  "chatGuid": "any;-;eamonn@armstrong.nyc",
  "envFile": "~/.hermes/.env"
 }
}
JSON
  chmod 600 "$CONF/config.json"
  echo "wrote $CONF/config.json (iMessage notifications on)"
fi

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
plist() { # label program-args...
  local label="$1"; shift
  local f="$LA/$label.plist"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$label</string>"
    echo '  <key>ProgramArguments</key><array>'
    for x in "$@"; do echo "    <string>$(xml "$x")</string>"; done
    echo '  </array>'
    echo '  <key>RunAtLoad</key><true/>'
    echo '  <key>KeepAlive</key><true/>'
    echo '  <key>ThrottleInterval</key><integer>10</integer>'
    echo '  <key>ExitTimeOut</key><integer>20</integer>'
    echo '  <key>ProcessType</key><string>Interactive</string>'
    echo "  <key>WorkingDirectory</key><string>$(xml "$APP")</string>"
    echo '  <key>EnvironmentVariables</key><dict>'
    echo '    <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>'
    echo "    <key>ASBUILT_RECON_BIN</key><string>$(xml "$BIN/asbuilt-recon")</string>"
    echo '  </dict>'
    echo "  <key>StandardOutPath</key><string>$LOGS/$label.out.log</string>"
    echo "  <key>StandardErrorPath</key><string>$LOGS/$label.err.log</string>"
    echo '</dict></plist>'
  } > "$f"
  plutil -lint "$f" >/dev/null
  echo "wrote $f"
}

echo "== LaunchAgents"
plist com.moltstrong.asbuilt-recon "$BIN/asbuilt-recon" serve --port 8765
if [ "$TUNNEL" = 1 ]; then
  plist com.moltstrong.asbuilt-recon-tunnel /usr/bin/python3 -u "$BIN/recon_tunnel.py"
fi
echo
echo "Next, in Terminal.app (first time: load; after re-installing: restart):"
echo "  \"$BIN/recon-launchd.sh\" load"
