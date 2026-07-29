#!/usr/bin/env bash
# Relaunch the Flutter dev server on the iPhone 17 simulator using the fifo
# control pattern documented in CLAUDE.md. Safe to re-run: kills any existing
# flutter run first.
set -u

DEVICE="AE8AEC05-B7AE-4A80-873E-426EF51146F1"
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

flutter run -d "$DEVICE" < "$FIFO" > "$LOG" 2>&1 &
# Hold the write end open so the fifo doesn't close.
exec 3>"$FIFO"

echo "launched (device=$DEVICE, log=$LOG)"
