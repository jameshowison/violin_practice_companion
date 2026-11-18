#!/usr/bin/env bash
# Push the dev library's scan sources to an Android emulator for
# integration_test/title_recognition_test.dart, which can't read the host's disk:
#
#   bash scripts/push_title_corpus.sh <path/to/violin_dev_library> <serial>
#   flutter test integration_test/title_recognition_test.dart -d <serial> \
#     --dart-define=TITLE_CORPUS_DIR=/data/local/tmp/title_corpus
#
# Copies state.json and each scan_sources/<id>/page_1_{original,crop}.* to
# /data/local/tmp/title_corpus (outside the app's dirs, which the test's
# reinstall wipes). The scans stay on the emulator, never in this repo.
set -euo pipefail
SRC="$1"; SERIAL="$2"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
DEST=/data/local/tmp/title_corpus
"$ADB" -s "$SERIAL" shell rm -rf "$DEST"
"$ADB" -s "$SERIAL" shell mkdir -p "$DEST/scan_sources"
"$ADB" -s "$SERIAL" push "$SRC/state.json" "$DEST/" >/dev/null 2>&1
for d in "$SRC"/scan_sources/*/; do
  id=$(basename "$d")
  "$ADB" -s "$SERIAL" shell mkdir -p "$DEST/scan_sources/$id"
  for f in "$d"page_1_original.* "$d"page_1_crop.*; do
    [ -f "$f" ] && "$ADB" -s "$SERIAL" push "$f" "$DEST/scan_sources/$id/" >/dev/null 2>&1
  done
done
"$ADB" -s "$SERIAL" shell chmod -R a+rX "$DEST"
echo "$("$ADB" -s "$SERIAL" shell ls "$DEST/scan_sources" | wc -l | tr -d ' ') scans in $DEST"
