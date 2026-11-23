#!/bin/bash
# Run the AirPlay UI-test harness (ios/RunnerUITests/AirPlayHarnessTests.swift)
# on the phone, a step at a time, so a UI quirk shows in seconds rather than
# at the end of a long recording:
#   preflight  the phone is reachable and unlocked; the receiver is up
#   step 1     the piece opens (search, tap, transport)
#   step 2     the receiver is picked fresh, and the app says so
#   step 3     Loop mode and the section, without playing
#   step 4     ~15 s of play that stays playing, and the receiver got data
#   --long     then the MINUTES-long loop, recorded on the receiver
# It stops at the first failure. Each step's output: airplay_harness_<step>.log.
#
# Settings (see the test's header) are KEY=VALUE arguments, without their
# TEST_RUNNER_ prefix, e.g.
#   bash scripts/airplay_harness.sh --build "RECEIVER=AirPlay Test Speaker" \
#     "PIECE=May Song" SECTION=B --long MINUTES=5
# Usage: airplay_harness.sh [--build] [--long] [--from N] [KEY=VALUE…]
#   --from N   start at step N (the earlier ones passed a moment ago)
#   --only T   run just test T (e.g. testPlayAfterReceiverRestart), no steps
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE=${DEVICE:-JamzJamzJamzz}
DD=build/harness_dd
RECV=tool/airplay_receiver/receiver.sh
BUILD=0 LONG=0 FROM=1 ONLY= MINUTES=5 RECEIVER_SET=0
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  a=${args[i]}
  case $a in
    --build) BUILD=1 ;;
    --long) LONG=1 ;;
    --from) FROM=${args[++i]:?--from needs a step number} ;;
    --only) ONLY=${args[++i]:?--only needs a test name} ;;
    PIECE=*|RECEIVER=*|SECTION=*|MINUTES=*|SKIP_ROUTE=*|REPICK=*|VOLUME_UP=*)
      export "TEST_RUNNER_$a"
      if [[ $a == MINUTES=* ]]; then MINUTES=${a#MINUTES=}; fi
      if [[ $a == RECEIVER=* ]]; then RECEIVER_SET=1; fi ;;
    *) echo "unknown argument: $a"; exit 2 ;;
  esac
done
(( RECEIVER_SET )) || echo "note: no RECEIVER=…; the test's default is used"

say() { echo "▶ $(date +%H:%M:%S) $*"; }

# --- preflight: seconds, before any build -----------------------------------
say "preflight"
lock=$(xcrun devicectl device info lockState --device "$DEVICE" 2>&1) \
  || { echo "✘ $DEVICE not reachable:"; echo "$lock" | tail -3; exit 1; }
if grep -q "passcodeRequired: true" <<<"$lock"; then
  echo "✘ $DEVICE is locked: unlock it (and set Auto-Lock to Never)"; exit 1
fi
if [[ -z ${TEST_RUNNER_SKIP_ROUTE:-} ]]; then
  st=$("$RECV" status 2>&1) || { echo "✘ receiver unreachable:"; echo "$st"; exit 1; }
  for svc in nqptp shairport-sync airplay-capture airplay-firewall; do
    grep -Eq "^$svc +active$" <<<"$st" \
      || { echo "✘ receiver: $svc not active:"; echo "$st"; exit 1; }
  done
  if grep -q "^capturing: yes" <<<"$st"; then
    echo "✘ the receiver is already capturing: $RECV capture stop"; exit 1
  fi
fi
echo "  ok: $DEVICE unlocked, receiver up"

if (( BUILD )); then
  say "building (airplay_harness_build.log)"
  flutter build ios --release --config-only --dart-define=TUNER_RECORDING=true \
    > airplay_harness_build.log 2>&1
  (cd ios && xcodebuild build-for-testing -workspace Runner.xcworkspace \
    -scheme stringlings -configuration Release-stringlings \
    -destination "platform=iOS,name=$DEVICE" -only-testing:RunnerUITests \
    -allowProvisioningUpdates DEVELOPMENT_TEAM=V8MB2893V6 \
    -derivedDataPath "../$DD") >> airplay_harness_build.log 2>&1 \
    || { echo "✘ build failed: airplay_harness_build.log"; exit 1; }
fi
run=$(ls "$DD"/Build/Products/*.xctestrun 2>/dev/null | head -1)
[[ -n $run ]] || { echo "✘ no build: run with --build"; exit 1; }

# Runs one test; its output goes to airplay_harness_<tag>.log. A watchdog
# kills a hung test runner (macOS has no `timeout`).
run_test() {
  local tag=$1 test=$2 limit=$3 log="airplay_harness_$1.log"
  xcodebuild test-without-building -xctestrun "$run" \
    -destination "platform=iOS,name=$DEVICE" \
    -only-testing:"RunnerUITests/AirPlayHarnessTests/$test" > "$log" 2>&1 &
  local pid=$!
  ( sleep "$limit"; kill "$pid" 2>/dev/null && echo "KILLED after ${limit}s" >> "$log" ) &
  local dog=$!
  local status=0
  wait "$pid" || status=$?
  kill "$dog" 2>/dev/null || true
  wait "$dog" 2>/dev/null || true
  grep -E '\[harness\]|error:|KILLED|Unlock|Test Case.*(passed|failed)' "$log" | sed 's/^/  /'
  if (( status != 0 )); then echo "✘ $tag failed: $log"; return 1; fi
  echo "  ok: $tag"
}

if [[ -n $ONLY ]]; then
  say "$ONLY"
  run_test only "$ONLY" $(( ${MINUTES%.*} * 60 + 420 ))
  exit
fi

# Step 4's receiver check: data arrived, for most of the play.
check_capture() {
  local name=$1 meta
  meta=$("$RECV" meta "$name")
  python3 -I -c '
import json, sys
m = json.loads(sys.stdin.read())
ev = m["events"]
data = [e["t"] for e in ev if e["kind"] == "data"]
if not data:
    sys.exit("✘ the receiver got no audio")
first, last = data[0], ev[-1]["t"] if ev[-1]["kind"] == "quiet" else m["duration_s"]
got = last - first
print(f"  receiver: audio from {first:.1f}s for {got:.1f}s, {len(data)} stretch(es)")
if got < 8:
    sys.exit("✘ the receiver got under 8 s of audio")
' <<<"$meta"
}

steps=(testStep1OpenPiece testStep2PickReceiver testStep3SetLoop testStep4PlayBrief)
for ((n = FROM; n <= 4; n++)); do
  test=${steps[n - 1]}
  say "step $n: $test"
  if (( n == 4 )) && [[ -z ${TEST_RUNNER_SKIP_ROUTE:-} ]]; then
    cap="step4_$(date +%H%M%S)"
    "$RECV" capture start "$cap" >/dev/null
    ok=0; run_test "step$n" "$test" 180 || ok=$?
    "$RECV" capture stop >/dev/null
    (( ok == 0 )) || exit 1
    check_capture "$cap"
    "$RECV" delete "$cap" >/dev/null
  else
    run_test "step$n" "$test" 180 || exit 1
  fi
done

if (( LONG )); then
  name="loop_$(date +%m%d_%H%M)"
  say "long loop, $MINUTES min, capture $name"
  [[ -n ${TEST_RUNNER_SKIP_ROUTE:-} ]] || "$RECV" capture start "$name" >/dev/null
  export TEST_RUNNER_AFTER_STEPS=1
  ok=0; run_test long testLoopOnAirPlay $(( ${MINUTES%.*} * 60 + 420 )) || ok=$?
  if [[ -z ${TEST_RUNNER_SKIP_ROUTE:-} ]]; then
    "$RECV" capture stop >/dev/null
    "$RECV" pull "$name"
  fi
  exit "$ok"
fi
echo "✔ steps passed; add --long for the recorded loop"
