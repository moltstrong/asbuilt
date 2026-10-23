#!/usr/bin/env bash
# Boots an iOS Simulator, installs AsBuilt, opens demo screens via launch arguments and saves screenshots.
# Usage: scripts/capture-screenshots.sh <path/to/AsBuilt.app> <simulator-udid> <output-dir>
set -euo pipefail

APP="$1"
UDID="$2"
OUT="$3"
BUNDLE_ID="com.moltstrong.asbuilt"
mkdir -p "$OUT"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
# Clean status bar for review screenshots.
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 2>/dev/null || true
xcrun simctl ui "$UDID" appearance light 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

shoot() {
  local name="$1"; shift
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@"
  sleep "${SHOT_DELAY:-6}"
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png"
  echo "captured $OUT/$name.png"
}

# First launch creates the demo job and its exports; give it a little longer.
SHOT_DELAY=10 shoot 01-job-list -AsBuiltResetDemo YES
shoot 02-demo-job -AsBuiltScreen job
shoot 03-plan-bedroom -AsBuiltScreen plan
shoot 04-takeoff -AsBuiltScreen takeoff
shoot 05-takeoff-walls -AsBuiltScreen takeoff-walls
shoot 06-plan-kitchen -AsBuiltScreen kitchen
SHOT_DELAY=8 shoot 07-3d-model -AsBuiltScreen model
shoot 08-files-export -AsBuiltScreen files
shoot 09-capabilities -AsBuiltScreen capabilities
SHOT_DELAY=8 shoot 10-mesh-3d -AsBuiltScreen mesh
shoot 11-mesh-files -AsBuiltScreen mesh-files
SHOT_DELAY=10 shoot 12-mesh-quicklook -AsBuiltScreen mesh-quicklook
# Build 6: Detail scan (TSDF fusion demo), Measure list, Capture Coach HUD preview + grade card.
SHOT_DELAY=10 shoot 13-detail-3d -AsBuiltScreen detail
shoot 14-measurements -AsBuiltScreen measurements
shoot 15-coach-hud -AsBuiltScreen coach
shoot 16-coach-fast -AsBuiltScreen coach-fast
shoot 17-coach-far -AsBuiltScreen coach-far
shoot 18-coach-band -AsBuiltScreen coach-band
shoot 19-coach-grade -AsBuiltScreen coach-grade
# Build 7: full-detail Mac build card.
shoot 20-mac-build -AsBuiltScreen mac-build
shoot 21-mac-build-upload -AsBuiltScreen mac-build-upload
shoot 22-mac-build-done -AsBuiltScreen mac-build-done

# Copy the files the app generated for the demo job, as proof that exports work in the Simulator.
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
mkdir -p "$OUT/app-exports"
cp -R "$DATA/Documents/Jobs" "$OUT/app-exports/" || true
find "$OUT/app-exports" -type f | sed "s|$OUT/||" | sort
ls -la "$OUT"
