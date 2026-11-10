#!/usr/bin/env bash
# Copy the speaker-calibration trace off a physical device and print the last
# run. The app appends one block per Calibrate tap to Documents/sync_cal_trace.txt
# (ios/Runner/AudioCalibrationPlugin.swift, "Trace"): every output-volume change,
# route change and engine reconfiguration, with the calibration step it fell in.
#   bash scripts/pull_sync_trace.sh "Hazel iPad"      # → sync_cal_trace.txt here
set -euo pipefail
DEVICE="${1:-JamzJamzJamzz}"
[[ "$DEVICE" == "Jamz" ]] && DEVICE="JamzJamzJamzz"
BUNDLE="name.howison.violinPracticeCompanion"
cd "$(dirname "$0")/.."
OUT="sync_cal_trace.txt"
xcrun devicectl device copy from --timeout 60 --device "$DEVICE" --quiet \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source Documents/sync_cal_trace.txt --destination "$OUT"
echo "copied to $OUT; last run:"
awk '/^=== calibration/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$OUT"
