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
# apply. The staging copy is a mirror: files gone from the library go from the
# staging folder too, and the app then works out what that means per item.
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
echo "library: $(find "$STAGE" -type f | wc -l | tr -d ' ') files, $(du -sh "$STAGE" | cut -f1)"

if xcrun simctl list devices | grep -q "^ *$DEVICE ("; then
  # Re-resolved every time: a reinstall relocates the container.
  DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)
  mkdir -p "$DATA/Documents/dev_library"
  rsync -a --delete "$STAGE/" "$DATA/Documents/dev_library/"
else
  xcrun devicectl device copy to --device "$DEVICE" --quiet \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$STAGE" --destination Documents/dev_library \
    --remove-existing-content true >/dev/null
fi
echo "push: staged on $DEVICE"
