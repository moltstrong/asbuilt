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
ROOM_CAPTURE="6A3B1C2D-0000-4000-8000-00000000B001"   # SampleData.demoCaptureID
MESH_CAPTURE="6A3B1C2D-0000-4000-8000-00000000B003"   # SampleData.demoMeshCaptureID
DETAIL_CAPTURE="6A3B1C2D-0000-4000-8000-00000000B004" # SampleData.demoDetailCaptureID
WAIT="${SMOKE_WAIT:-15}"
DIAG="$HOME/Library/Logs/DiagnosticReports"
mkdir -p "$OUT" "$DIAG"
FAILED=0

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 2>/dev/null || true
xcrun simctl ui "$UDID" appearance light 2>/dev/null || true

# Install what a user gets: the app without the XCTest plug-in, code-signed (ad hoc). Simulator builds
# made with CODE_SIGNING_ALLOWED=NO are unsigned, and newer simulators may refuse to launch those.
STAGE="$(mktemp -d)/AsBuilt.app"
ditto "$APP" "$STAGE"
rm -rf "$STAGE/PlugIns" "$STAGE/Frameworks/XCTest.framework" "$STAGE/Frameworks/libXCTestSwiftSupport.dylib" \
  "$STAGE/Frameworks/XCTestCore.framework" "$STAGE/Frameworks/XCUIAutomation.framework" 2>/dev/null || true
codesign --force --deep --sign - --timestamp=none "$STAGE"
codesign -dv "$STAGE" 2>&1 | grep -E "Identifier|Signature|Format" || true
APP="$STAGE"

# Fresh install: drop any previous copy (and its data container) first.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl listapps "$UDID" 2>/dev/null | grep -A3 "\"$BUNDLE_ID\"" | head -4 || true

# A freshly created simulator keeps migrating data after bootstatus returns; launches during that
# window fail with "did not return a process handle". Wait until a system app launches (max ~3 min).
for i in $(seq 1 18); do
  if xcrun simctl launch "$UDID" com.apple.Preferences 2>&1 | grep -qE ': [0-9]+$'; then
    echo "simulator ready for launches after warm-up attempt $i"
    xcrun simctl terminate "$UDID" com.apple.Preferences 2>/dev/null || true
    break
  fi
  echo "warm-up attempt $i: launch services not ready yet"
  sleep 10
done

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

dump_launch_diagnostics() {
  local name="$1"
  echo "---- [$name] simulator log (last 3 min, AsBuilt / launch related)"
  xcrun simctl spawn "$UDID" log show --last 3m --style compact \
    --predicate 'eventMessage CONTAINS[c] "asbuilt" OR process == "AsBuilt"' 2>/dev/null \
    | tail -60 | tee "$OUT/$name.syslog.txt" || true
}

run_case() {
  local name="$1"; shift
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  sleep 2
  local out="" pid="" attempt
  for attempt in 1 2 3; do
    out=$(xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@" 2>&1)
    echo "[$name] simctl launch (attempt $attempt): $out"
    pid=$(sed -nE 's/^.*: ([0-9]+)$/\1/p' <<<"$out" | tail -1)
    [[ -n "$pid" ]] && break
    sleep 10
  done
  [[ -z "$pid" ]] && dump_launch_diagnostics "$name"
  sleep "$WAIT"
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" || true
  if check_alive "$name" "$pid"; then
    echo "[$name] PASS: still running after ${WAIT}s"
  else
    echo "[$name] FAIL"
    FAILED=1
    dump_launch_diagnostics "$name-after"
  fi
}

# 1) Exactly like a real user: first launch after install, no launch arguments.
run_case 01-first-launch
# 2) Second cold launch, still no arguments (catches crash loops that only show on relaunch).
run_case 02-relaunch
# 3) The 3D model screen (SceneKit loads model.usdz).
run_case 03-model -AsBuiltScreen model
# 4) The demo LiDAR Mesh scan: 3D tab (SceneKit loads the classified mesh USDZ) and Files tab.
run_case 04-mesh-model -AsBuiltScreen mesh
run_case 05-mesh-files -AsBuiltScreen mesh-files
# 5) Build 6: Detail scan demo (real TSDF fusion output), Measure list, Capture Coach HUD preview.
run_case 06-detail-3d -AsBuiltScreen detail
run_case 07-measurements -AsBuiltScreen measurements
run_case 08-coach-hud -AsBuiltScreen coach
run_case 09-coach-fast -AsBuiltScreen coach-fast
run_case 10-coach-far -AsBuiltScreen coach-far
run_case 11-coach-band -AsBuiltScreen coach-band
run_case 12-coach-grade -AsBuiltScreen coach-grade
run_case 13-capabilities -AsBuiltScreen capabilities
# 6) Build 7: "Full detail on your Mac" card (building / done / offline states).
run_case 14-mac-build -AsBuiltScreen mac-build
run_case 15-mac-build-done -AsBuiltScreen mac-build-done
run_case 16-mac-build-offline -AsBuiltScreen mac-build-offline

DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)
if [[ -n "$DATA" && -d "$DATA/Documents/Jobs" ]]; then
  find "$DATA/Documents/Jobs" -type f -exec ls -la {} \; | sed "s|$DATA/||"
  find "$DATA/Documents/Jobs" -path "*$ROOM_CAPTURE*" -name model.usdz -exec cp {} "$OUT/model.usdz" \; -quit || true
  MESH_DIR=$(find "$DATA/Documents/Jobs" -type d -name "$MESH_CAPTURE" | head -1)
  if [[ -n "$MESH_DIR" ]]; then
    cp "$MESH_DIR/model.usdz" "$OUT/mesh-model.usdz" || true
    mkdir -p "$OUT/mesh-exports"
    cp "$MESH_DIR"/* "$OUT/mesh-exports/" 2>/dev/null || true
  else
    echo "::error::demo LiDAR mesh capture folder not found"
    FAILED=1
  fi
  DETAIL_DIR=$(find "$DATA/Documents/Jobs" -type d -name "$DETAIL_CAPTURE" | head -1)
  if [[ -n "$DETAIL_DIR" && -s "$DETAIL_DIR/model.usdz" ]]; then
    cp "$DETAIL_DIR/model.usdz" "$OUT/detail-model.usdz" || true
    mkdir -p "$OUT/detail-exports"
    cp "$DETAIL_DIR"/* "$OUT/detail-exports/" 2>/dev/null || true
  else
    echo "::error::demo Detail scan files not found"
    FAILED=1
  fi
fi

rm -f "$MARKER"
if [[ $FAILED -ne 0 ]]; then
  echo "::error::Launch smoke test FAILED (app crashed or was not running)"
  exit 1
fi
echo "Launch smoke test PASSED"
