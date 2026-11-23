#!/bin/bash
# Run the AirPlay UI-test harness (ios/RunnerUITests/AirPlayHarnessTests.swift)
# on the phone. --build builds first; the run's output goes to
# airplay_harness.log. Settings (see the test's header) are KEY=VALUE
# arguments, without their TEST_RUNNER_ prefix, e.g.
#   bash scripts/airplay_harness.sh --build RECEIVER="AirPlay Test Speaker" MINUTES=5
# Usage: airplay_harness.sh [--build] [KEY=VALUE…] [test, default testLoopOnAirPlay]
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE=${DEVICE:-JamzJamzJamzz}
DD=build/harness_dd
LOG=airplay_harness.log
BUILD=0
TEST=testLoopOnAirPlay
MINUTES=5
for a in "$@"; do
  case $a in
    --build) BUILD=1 ;;
    PIECE=*|RECEIVER=*|SECTION=*|MINUTES=*|SKIP_ROUTE=*|REPICK=*|VOLUME_UP=*)
      export "TEST_RUNNER_$a"
      if [[ $a == MINUTES=* ]]; then MINUTES=${a#MINUTES=}; fi ;;
    test*) TEST=$a ;;
    *) echo "unknown argument: $a"; exit 2 ;;
  esac
done

if (( BUILD )); then
  flutter build ios --release --config-only --dart-define=TUNER_RECORDING=true
  (cd ios && xcodebuild build-for-testing -workspace Runner.xcworkspace \
    -scheme stringlings -configuration Release-stringlings \
    -destination "platform=iOS,name=$DEVICE" -only-testing:RunnerUITests \
    -allowProvisioningUpdates DEVELOPMENT_TEAM=V8MB2893V6 \
    -derivedDataPath "../$DD") > airplay_harness_build.log 2>&1 \
    || { echo "build failed: airplay_harness_build.log"; exit 1; }
fi

run=$(ls "$DD"/Build/Products/*.xctestrun 2>/dev/null | head -1)
[[ -n $run ]] || { echo "no build: run with --build"; exit 1; }

# The test runner can hang after a failure, and macOS has no `timeout`.
limit=$(( ${MINUTES%.*} * 60 + 420 ))
xcodebuild test-without-building -xctestrun "$run" \
  -destination "platform=iOS,name=$DEVICE" \
  -only-testing:"RunnerUITests/AirPlayHarnessTests/$TEST" > "$LOG" 2>&1 &
pid=$!
( sleep "$limit"; kill "$pid" 2>/dev/null && echo "KILLED after ${limit}s" >> "$LOG" ) &
watchdog=$!
status=0; wait "$pid" || status=$?
kill "$watchdog" 2>/dev/null || true
grep -E '\[harness\]|Test Case|error:|Executed|KILLED' "$LOG" | tail -40
exit "$status"
