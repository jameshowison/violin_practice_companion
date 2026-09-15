#!/bin/bash
# Attach an audio/video file to a piece on a booted simulator, from the CLI.
#
#   bash scripts/sim_add_media.sh dev-iphone happy_farmer path/to/track.mp3 "Happy Farmer (mp3)"
#
# Why this exists: the in-app "Add audio or video…" route goes through the
# system document picker, which is native iOS. Marionette only sees Flutter
# widgets, so an agent cannot drive it, and dragging a file onto the simulator
# window is unreliable. This does the same two things the importer does —
# copy the file into the medium's folder, and write the PieceMedia row — so
# the app's real load path (decode → chroma → DTW → cache) runs unmodified.
#
# Two traps this encodes:
#
#   * `defaults write <bundle>` does NOT reach the app. On the simulator that
#     writes to the device's shared preferences domain; an iOS app reads
#     NSUserDefaults from its OWN data container's Library/Preferences plist.
#     So the plist is edited directly.
#   * A `flutter run` reinstall RELOCATES the data container (observed three
#     times in one session: 1C074C49 → F930FFA5 → 061911FE). Documents and the
#     prefs plist are carried across, so writing before a relaunch is safe —
#     but never cache the container path across a launch.
#
# The app must be stopped while the plist is edited: a running app holds
# NSUserDefaults in memory and flushes over anything written underneath it.

set -euo pipefail

DEVICE="${1:?usage: sim_add_media.sh <device> <pieceId> <file> [label]}"
PIECE_ID="${2:?missing pieceId (e.g. happy_farmer)}"
SOURCE="${3:?missing source file}"
BUNDLE="name.howison.violinPracticeCompanion"

[ -f "$SOURCE" ] || { echo "no such file: $SOURCE" >&2; exit 1; }

FILENAME="$(basename "$SOURCE")"
EXT="${FILENAME##*.}"
EXT="$(echo "$EXT" | tr '[:upper:]' '[:lower:]')"
LABEL="${4:-${FILENAME%.*}}"
MEDIA_ID="cli_$(date +%s)"

case "$EXT" in
  mp4|mov|m4v) IS_VIDEO=true ;;
  *)           IS_VIDEO=false ;;
esac

echo "→ stopping the app (its in-memory NSUserDefaults would clobber the write)"
pkill -f flutter_tools.snapshot 2>/dev/null || true
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
sleep 1

DATA="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)"
DEST="$DATA/Documents/media/$PIECE_ID/$MEDIA_ID"
mkdir -p "$DEST"
cp "$SOURCE" "$DEST/source.$EXT"
echo "→ copied to Documents/media/$PIECE_ID/$MEDIA_ID/source.$EXT"

python3 - "$DATA/Library/Preferences/$BUNDLE.plist" \
         "$PIECE_ID" "$MEDIA_ID" "$EXT" "$LABEL" "$IS_VIDEO" <<'PY'
import json, plistlib, sys

plist_path, piece_id, media_id, ext, label, is_video = sys.argv[1:7]
rel = f"media/{piece_id}/{media_id}/source.{ext}"
ref = {"storage": "appFile", "path": rel}

entry = {
    "id": media_id,
    "label": label,
    "kind": "imported",
    "alignmentKey": f"media:{piece_id}:{media_id}",
    "audio": ref,
    # The same file is the analysis source — a video's audio track is what gets
    # decoded, which is what makes an imported mp4 behave like a recorded demo.
    "analysis": ref,
    "avOffsetMs": 0,
}
if is_video == "true":
    entry["video"] = ref

with open(plist_path, "rb") as f:
    prefs = plistlib.load(f)

key = f"flutter.pieceMedia.{piece_id}"          # shared_preferences prefixes keys
existing = json.loads(prefs.get(key, "[]"))
existing.append(entry)
prefs[key] = json.dumps(existing, separators=(",", ":"))

with open(plist_path, "wb") as f:
    plistlib.dump(prefs, f, fmt=plistlib.FMT_BINARY)

print(f"→ registered as \"{label}\" ({len(existing)} medium/media on {piece_id})")
PY

echo
echo "Now relaunch:  bash scripts/dev_run.sh $DEVICE"
echo "Then pick it from the tray's media picker on that piece."
