#!/usr/bin/env bash
# Emulator smoke test: installs the APK, opens every main screen through the `demo` intent extra,
# saves screenshots, and fails if the app crashed (FATAL EXCEPTION) or died.
#   emulator-smoke.sh <apk> <out-dir>
set -u
APK="$1"
OUT="$2"
PKG=com.moltstrong.asbuilt.android
mkdir -p "$OUT"
adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done'
adb shell settings put global window_animation_scale 0 || true
adb shell settings put global transition_animation_scale 0 || true
adb shell settings put global animator_duration_scale 0 || true
adb shell wm size || true
adb shell getprop ro.build.version.sdk

# -g grants runtime permissions (camera, notifications) so no system dialog covers the screens.
adb install -r -g "$APK" || { echo "::error::install failed"; exit 1; }
adb logcat -c || true

fail=0
shot() {
  local name="$1" wait="$2"; shift 2
  adb shell am force-stop "$PKG"
  adb shell am start -W -n "$PKG/.MainActivity" "$@" > /dev/null
  sleep "$wait"
  adb exec-out screencap -p > "$OUT/$name.png"
  if ! adb shell pidof "$PKG" > /dev/null; then
    echo "::error::app not running after $name"
    fail=1
  fi
  echo "screenshot $name ($(wc -c < "$OUT/$name.png") bytes)"
}

shot 01-jobs-empty 4 --es demo empty
shot 02-jobs 4 --es demo jobs
adb shell input swipe 540 1700 540 700 300
sleep 2
adb exec-out screencap -p > "$OUT/02b-jobs-scrolled.png"
shot 03-capture-intro 5 --es demo intro
shot 04-capture-unsupported 4 --es demo unsupported
shot 05-progress-states 4 --es demo progress
adb shell input swipe 540 1900 540 500 400
sleep 2
adb exec-out screencap -p > "$OUT/05b-progress-states-scrolled.png"
adb shell input swipe 540 1900 540 500 400
sleep 2
adb exec-out screencap -p > "$OUT/05c-progress-states-end.png"
shot 06-coach-scanning 4 --es demo coach
shot 07-coach-too-fast 4 --es demo coach-fast
shot 08-coach-too-far 4 --es demo coach-far
shot 09-capture-review 4 --es demo review
shot 10-model-3d 15 --es demo model
# Orbit the model a bit and capture again (gesture path through the Filament camera manipulator).
adb shell input swipe 300 1200 800 1100 600
sleep 3
adb exec-out screencap -p > "$OUT/10b-model-3d-orbited.png"
shot 11-settings 4 --es demo settings

adb logcat -d > "$OUT/logcat.txt" 2>/dev/null || true
if grep -E "FATAL EXCEPTION|Process: $PKG" "$OUT/logcat.txt" | grep -q .; then
  echo "::error::crash in logcat"
  grep -A30 "FATAL EXCEPTION" "$OUT/logcat.txt" | head -80
  fail=1
fi
grep -E "AsBuiltViewer|Filament|AsBuiltAR" "$OUT/logcat.txt" | tail -40 || true
exit $fail
