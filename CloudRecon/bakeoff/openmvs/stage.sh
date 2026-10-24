#!/bin/bash
# usage: stage.sh <run-dir> <stage-name> <OpenMVS-binary> [args...]
# Runs one OpenMVS stage inside <run-dir> with /usr/bin/time -l; appends "stage seconds peakRSS_GB" to <run-dir>/times.txt
set -u
RUN="$1"; NAME="$2"; BIN="$3"; shift 3
B="$(cd "$(dirname "$0")" && pwd)/${OMVS_BIN:-bin}"
mkdir -p "$RUN"; cd "$RUN" || exit 1
t0=$(python3 -c 'import time;print(time.time())')
/usr/bin/time -l "$B/$BIN" "$@" > "log_$NAME.txt" 2> "time_$NAME.txt"
rc=$?
t1=$(python3 -c 'import time;print(time.time())')
rss=$(awk '/maximum resident set size/{print $1}' "time_$NAME.txt")
pf=$(awk '/peak memory footprint/{print $1}' "time_$NAME.txt")
python3 -c "print('%-14s rc=%d %8.1f s  maxRSS %.2f GB  peakFootprint %.2f GB' % ('$NAME', $rc, $t1-$t0, ${rss:-0}/2**30, ${pf:-0}/2**30))" | tee -a times.txt
exit $rc
