#!/usr/bin/env bash
# Copy the tuner's recorded sessions off a device (or simulator) and replay
# the newest. The app writes them only with the developer switch on (a long
# press on the tuner's title): Documents/tuner_sessions/<when>.wav (the
# microphone) and <when>.csv (what the tuner made of each frame, and marks).
# See lib/services/tuner_recording_io.dart and tool/replay_tuner_session.dart.
#
#   bash scripts/pull_tuner_sessions.sh                 # the phone (JamzJamzJamzz)
#   bash scripts/pull_tuner_sessions.sh dev-iphone-se   # a simulator, by name
#   bash scripts/pull_tuner_sessions.sh Jamz <dir>      # somewhere else
#
# They are microphone recordings, so they go to the private restricted
# checkout by default ($VPC_RESTRICTED_DIR, or ../violin_practice_restricted),
# never into this public repo. Files already there are skipped.
set -euo pipefail
DEVICE="${1:-JamzJamzJamzz}"
[[ "$DEVICE" == "Jamz" ]] && DEVICE="JamzJamzJamzz"
BUNDLE="name.howison.violinPracticeCompanion"
cd "$(dirname "$0")/.."
RESTRICTED="${VPC_RESTRICTED_DIR:-../violin_practice_restricted}"
DEST="${2:-$RESTRICTED/tuner_sessions}"
if [[ -z "${2:-}" && ! -d "$RESTRICTED" ]]; then
  echo "no restricted checkout at $RESTRICTED; pass a destination outside this repo" >&2
  exit 1
fi
case "$(cd "$(dirname "$DEST")" 2>/dev/null && pwd)/" in
  "$(pwd)/"*) echo "refusing to copy recordings into this public repo: $DEST" >&2; exit 1 ;;
esac
mkdir -p "$DEST"

if xcrun simctl list devices | grep -q "^ *$DEVICE ("; then
  DATA="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)"
  SRC="$DATA/Documents/tuner_sessions"
  [[ -d "$SRC" ]] || { echo "no sessions on $DEVICE yet"; exit 0; }
  for f in "$SRC"/*; do
    [[ -e "$DEST/$(basename "$f")" ]] || cp "$f" "$DEST/"
  done
else
  LIST="$(mktemp)"
  trap 'rm -f "$LIST"' EXIT
  if ! xcrun devicectl device info files --timeout 60 --device "$DEVICE" --quiet \
      --domain-type appDataContainer --domain-identifier "$BUNDLE" \
      --subdirectory Documents/tuner_sessions --json-output "$LIST" >/dev/null 2>&1; then
    echo "no sessions on $DEVICE yet (or it is asleep / not connected)"; exit 0
  fi
  python3 -I - "$LIST" <<'PY' | while read -r name; do
import json, sys
def walk(o):
    if isinstance(o, dict):
        n = o.get('relativePath') or o.get('name') or ''
        if n.endswith(('.wav', '.csv')): yield n.split('/')[-1]
        for v in o.values(): yield from walk(v)
    elif isinstance(o, list):
        for v in o: yield from walk(v)
print('\n'.join(sorted(set(walk(json.load(open(sys.argv[1])))))))
PY
    [[ -z "$name" || -e "$DEST/$name" ]] && continue
    xcrun devicectl device copy from --timeout 120 --device "$DEVICE" --quiet \
      --domain-type appDataContainer --domain-identifier "$BUNDLE" \
      --source "Documents/tuner_sessions/$name" --destination "$DEST/$name"
  done
fi

NEWEST="$(ls -1 "$DEST"/*.wav 2>/dev/null | sort | tail -1 || true)"
echo "sessions in $DEST: $(ls -1 "$DEST"/*.wav 2>/dev/null | wc -l | tr -d ' ')"
[[ -n "$NEWEST" ]] && dart run tool/replay_tuner_session.dart "$NEWEST"
