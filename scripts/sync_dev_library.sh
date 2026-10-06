#!/usr/bin/env bash
# Sync the dev library with one device, over the cable: its changes go into the
# library, the library's changes go onto it. No network involved.
#
#   bash scripts/sync_dev_library.sh dev-iphone
#   bash scripts/sync_dev_library.sh "Hazel iPad"
#   bash scripts/sync_dev_library.sh dev-iphone --no-launch   # leave the app stopped
#
# Sync each device in turn ("sync dev-iphone, then sync Hazel iPad") and each
# sees the other's work. The library is ../violin_dev_library, a private git
# repo; every sync commits there locally, so a conflict — the same thing
# changed on two devices — never loses the library's version: it is the
# previous commit. Pushing that repo to GitHub is up to you.
#
#   1. stop the app      a running app holds NSUserDefaults in memory
#   2. pull              device -> library   (scripts/pull_dev_library.sh)
#   3. commit            in the library repo, if anything changed
#   4. push              library -> device staging (scripts/push_dev_library.sh)
#   5. relaunch          the app merges the staged library at launch
#                        (lib/services/dev_library_io.dart) and records the
#                        new base, so the NEXT sync knows what changed since.
set -euo pipefail

DEVICE="${1:?usage: sync_dev_library.sh <device> [--no-launch]}"
LAUNCH=1
[[ "${2:-}" == "--no-launch" ]] && LAUNCH=""
cd "$(dirname "$0")/.."
LIB="${DEV_LIBRARY:-../violin_dev_library}"
BUNDLE="name.howison.violinPracticeCompanion"

if xcrun simctl list devices | grep -q "^ *$DEVICE ("; then
  SIM=1
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  # A dev server on this simulator would relaunch the app under us.
  pgrep -f "flutter run -d $DEVICE" >/dev/null && pkill -f flutter_tools.snapshot || true
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
else
  SIM=""
  PID=$(xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null \
    | awk '/Runner\.app\/Runner$/ {print $1; exit}')
  if [[ -n "$PID" ]]; then
    xcrun devicectl device process terminate --device "$DEVICE" --pid "$PID" >/dev/null 2>&1 || true
  fi
fi
sleep 1 # let the prefs plist land on disk

bash scripts/pull_dev_library.sh "$DEVICE" "$LIB"

if [[ -d "$LIB/.git" ]]; then
  git -C "$LIB" add -A
  if ! git -C "$LIB" diff --cached --quiet; then
    git -C "$LIB" commit -q -m "sync from $DEVICE"
    echo "commit: $(git -C "$LIB" log --oneline -1)"
  fi
fi

bash scripts/push_dev_library.sh "$DEVICE" "$LIB"

[[ -z "$LAUNCH" ]] && { echo "app left stopped; it merges the library at next launch"; exit 0; }
if [[ -n "$SIM" ]]; then
  bash scripts/dev_run.sh "$DEVICE"
else
  xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" >/dev/null
  echo "launched on $DEVICE"
fi
echo "to confirm it converged: bash scripts/pull_dev_library.sh \"$DEVICE\" --dry-run   (want 0 taken)"
