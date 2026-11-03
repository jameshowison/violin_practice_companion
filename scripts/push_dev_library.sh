#!/usr/bin/env bash
# The push half of the dev-library sync: stage the library in the app's
# Documents/dev_library/. Normally run by scripts/sync_dev_library.sh.
#
#   bash scripts/push_dev_library.sh dev-ipad                 # simulator
#   bash scripts/push_dev_library.sh "Hazel iPad"             # physical device
#
# This ONLY copies files. The app merges the staged library into its own
# Documents and prefs on its next launch (lib/services/dev_library_io.dart), so
# unlike sim_add_media.sh there is no prefs plist to edit and none of its traps
# apply. On a physical device the staging folder is NOT a mirror (see the copy
# below): manifest.json lists what this push sent, and the app ignores the
# rest, then works out per item what the library's changes mean.
#
# The app must already be installed (there is no data container before that),
# and it only looks at launch — relaunch it after pushing.
set -euo pipefail

DEVICE="${1:?usage: push_dev_library.sh <device> [library_dir]}"
cd "$(dirname "$0")/.."
LIB="${2:-../violin_dev_library}"
BUNDLE="name.howison.violinPracticeCompanion"

[[ -f "$LIB/state.json" ]] || { echo "no state.json in $LIB — pull from a device first" >&2; exit 1; }

# Stage without .git (devicectl copies a directory verbatim).
STAGE=$(mktemp -d)/dev_library
trap 'rm -rf "$(dirname "$STAGE")"' EXIT
rsync -a --exclude .git --exclude .gitattributes --exclude .gitignore --exclude .DS_Store "$LIB/" "$STAGE/"
# What this push sent. The device copy below can't clear old staging first (see
# there), so a file deleted from the library lingers on the device; the app
# reads only the files listed here (DevLibraryIngester._readManifest).
python3 - "$STAGE" <<'PY'
import json, os, sys
root = sys.argv[1]
files = sorted(
    os.path.relpath(os.path.join(d, f), root)
    for d, _, fs in os.walk(root) for f in fs
    if not f.startswith('.') and f not in ('state.json', 'manifest.json')
    and os.path.dirname(os.path.join(d, f)) != root)
json.dump({'files': files}, open(os.path.join(root, 'manifest.json'), 'w'), indent=0)
PY
echo "library: $(find "$STAGE" -type f | wc -l | tr -d ' ') files, $(du -sh "$STAGE" | cut -f1)"

if xcrun simctl list devices | grep -q "^ *$DEVICE ("; then
  # Re-resolved every time: a reinstall relocates the container.
  DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)
  mkdir -p "$DATA/Documents/dev_library"
  rsync -a --delete "$STAGE/" "$DATA/Documents/dev_library/"
else
  # --timeout: a wedged CoreDevice tunnel otherwise hangs here forever (see
  # device_install.sh). Generous, since this copies the whole library.
  #
  # NEVER --remove-existing-content. Its help says it clears the destination
  # directory; on iOS 27.0.1 (2026-11-03, JamzJamzJamzz) it emptied the whole
  # app data container instead — every piece, recording and the prefs plist —
  # leaving only this staging folder. The copy merges over the old staging, and
  # manifest.json (above) tells the app which staged files are current.
  xcrun devicectl device copy to --timeout 300 --device "$DEVICE" --quiet \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$STAGE" --destination Documents/dev_library >/dev/null
fi
echo "push: staged on $DEVICE"
