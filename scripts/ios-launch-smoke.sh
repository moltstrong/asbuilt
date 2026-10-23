#!/usr/bin/env bash
# Launch smoke test, run the way a real user starts the app: fresh install, launch with NO launch
# arguments, wait, then make sure the process is still alive and no crash report was written.
# Then it opens the 3D model screen (-AsBuiltScreen model) and checks the same things again.
# Screenshots, console output and any crash reports go to <output-dir>.
# Usage: scripts/ios-launch-smoke.sh <path/to/AsBuilt.app> <simulator-udid> <output-dir>
set -uo pipefail

APP="$1"
UDID="$2"
OUT="$3"
BUNDLE_ID="com.moltstrong.asbuilt"
WAIT="${SMOKE_WAIT:-15}"
DIAG="$HOME/Library/Logs/DiagnosticReports"
mkdir -p "$OUT" "$DIAG"
FAILED=0

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 2>/dev/null || true
xcrun simctl ui "$UDID" appearance light 2>/dev/null || true

# Fresh install: drop any previous copy (and its data container) first.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

MARKER="$OUT/.smoke-start"
touch "$MARKER"
sleep 1

new_crash_reports() {
  find "$DIAG" -maxdepth 2 -type f \( -name 'AsBuilt*' -o -name '*AsBuilt*' \) -newer "$MARKER" 2>/dev/null
}

check_alive() {
  local name="$1" pid="$2"
  local ok=1
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "[$name] host process $pid is alive"
  else
    echo "::error::[$name] AsBuilt process ${pid:-?} is not running after ${WAIT}s"
    ok=0
  fi
  local entry
  entry=$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep "$BUNDLE_ID" || true)
  echo "[$name] launchctl: ${entry:-<no entry>}"
  if [[ -z "$entry" ]] || ! awk '{print $1}' <<<"$entry" | grep -qE '^[0-9]+$'; then
    echo "::error::[$name] launchctl has no running AsBuilt job"
    ok=0
  fi
  local crashes
  crashes=$(new_crash_reports)
  if [[ -n "$crashes" ]]; then
    echo "::error::[$name] crash report(s) found:"
    mkdir -p "$OUT/crash-reports"
    while IFS= read -r f; do
      echo "---- $f"
      cp "$f" "$OUT/crash-reports/" || true
      head -c 6000 "$f" | grep -E '"exception"|Exception|reason|objectAtIndex|USDKit|SceneKit|AsBuilt' | head -40 || true
    done <<<"$crashes"
    ok=0
  fi
  [[ $ok -eq 1 ]]
}

run_case() {
  local name="$1"; shift
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  sleep 1
  local out pid
  out=$(xcrun simctl launch --terminate-running-process \
          --stdout="$OUT/$name.stdout.log" --stderr="$OUT/$name.stderr.log" \
          "$UDID" "$BUNDLE_ID" "$@" 2>&1)
  echo "[$name] simctl launch: $out"
  pid=$(sed -nE 's/.*: ([0-9]+)$/\1/p' <<<"$out" | tail -1)
  sleep "$WAIT"
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" || true
  if check_alive "$name" "$pid"; then
    echo "[$name] PASS: still running after ${WAIT}s"
  else
    echo "[$name] FAIL"
    FAILED=1
    for f in "$OUT/$name.stdout.log" "$OUT/$name.stderr.log"; do
      [[ -s "$f" ]] && { echo "---- $f"; tail -40 "$f"; }
    done
  fi
}

# 1) Exactly like a real user: first launch after install, no launch arguments.
run_case 01-first-launch
# 2) Second cold launch, still no arguments (catches crash loops that only show on relaunch).
run_case 02-relaunch
# 3) The 3D model screen (SceneKit loads model.usdz).
run_case 03-model -AsBuiltScreen model

DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)
if [[ -n "$DATA" && -d "$DATA/Documents/Jobs" ]]; then
  find "$DATA/Documents/Jobs" -type f -exec ls -la {} \; | sed "s|$DATA/||"
  find "$DATA/Documents/Jobs" -name model.usdz -exec cp {} "$OUT/" \; -quit || true
fi

rm -f "$MARKER"
if [[ $FAILED -ne 0 ]]; then
  echo "::error::Launch smoke test FAILED (app crashed or was not running)"
  exit 1
fi
echo "Launch smoke test PASSED"
