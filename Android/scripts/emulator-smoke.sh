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
# Slow CI emulators often show "Pixel Launcher isn't responding" over the app; suppress it.
adb shell settings put global hide_error_dialogs 1 || true
adb shell wm size || true
adb shell getprop ro.build.version.sdk

# Let the freshly booted system settle (launcher ANRs are common in the first minute on CI).
sleep 20
# -g grants runtime permissions (camera, notifications) so no system dialog covers the screens.
adb install -r -g "$APK" || { echo "::error::install failed"; exit 1; }
adb logcat -c || true

fail=0
# Dismiss any system ANR dialog ("... isn't responding") by tapping "Wait", so it can't cover a screenshot.
dismiss_anr() {
  local i
  for i in 1 2 3; do
    adb shell uiautomator dump /sdcard/ui.xml > /dev/null 2>&1 || return 0
    local xml
    xml=$(adb shell cat /sdcard/ui.xml 2>/dev/null)
    case "$xml" in
      *"isn't responding"*|*"isn&apos;t responding"*) ;;
      *) return 0 ;;
    esac
    local b
    b=$(printf '%s' "$xml" | tr '>' '\n' | grep 'text="Wait"' | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1 | tr -c '0-9\n' ' ')
    if [ -n "$b" ]; then
      set -- $b
      adb shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
      echo "dismissed ANR dialog"
    else
      adb shell input keyevent KEYCODE_BACK
    fi
    sleep 2
  done
}
# Wait (up to N s) for a logcat line, e.g. the viewer's "model ready" (software GL on CI is slow).
wait_log() {
  local pattern="$1" max="$2" t=0
  while [ $t -lt "$max" ]; do
    adb logcat -d -s AsBuiltViewer:I 2>/dev/null | grep -q "$pattern" && { echo "'$pattern' after ${t}s"; return 0; }
    sleep 2; t=$((t + 2))
  done
  echo "::warning::'$pattern' not seen within ${max}s"
}
shot() {
  local name="$1" wait="$2"; shift 2
  adb shell am force-stop "$PKG"
  adb shell am start -W -n "$PKG/.MainActivity" "$@" > /dev/null
  sleep "$wait"
  [ -n "${WAIT_LOG:-}" ] && wait_log "$WAIT_LOG" 90
  dismiss_anr
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
dismiss_anr
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
adb logcat -c || true
WAIT_LOG="model ready" shot 10-model-3d 5 --es demo model
# Orbit the model a bit and capture again (gesture path through the Filament camera manipulator).
adb shell input swipe 300 1200 800 1100 600
sleep 3
dismiss_anr
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
