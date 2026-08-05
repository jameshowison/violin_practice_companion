#!/usr/bin/env bash
# Relaunch the Flutter dev server on a simulator using the fifo control pattern
# documented in CLAUDE.md. Safe to re-run: kills any existing flutter run first.
# Defaults to dev-iphone; pass another simulator name as $1, e.g.
#   scripts/dev_run.sh dev-ipad
# (see README "Simulator names" for how the dev-* aliases are set up)
set -u

DEVICE="${1:-${DEVICE:-dev-iphone}}"
FIFO="/tmp/flutter_ctl"
LOG="flutter_run.log"

pkill -f flutter_tools.snapshot 2>/dev/null
sleep 1

# Ensure the simulator is booted and the Simulator app is open.
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator 2>/dev/null || true
# Give the device a moment to reach Booted.
for _ in $(seq 1 20); do
  xcrun simctl list devices | grep "$DEVICE" | grep -q "Booted" && break
  sleep 1
done

rm -f "$FIFO"
mkfifo "$FIFO"

# Stamp the build before launching, so the AppBar says which build is live and the
# expected value is right here in this script's output. See CLAUDE.md "Verify the
# build is live".
STAMP=$(bash "$(dirname "$0")/gen_build_info.sh")

flutter run -d "$DEVICE" < "$FIFO" > "$LOG" 2>&1 &

# Hold the write end open so the fifo doesn't close. Detached on purpose: `exec 3>`
# would last only as long as THIS shell, so the pipe would lose its only writer the
# moment the script exits — and every later `echo "r" > $FIFO` would be shouting into
# a closed pipe.
nohup sleep 86400 > "$FIFO" 2>/dev/null &

echo "launched (device=$DEVICE, log=$LOG)"
echo "$STAMP"
