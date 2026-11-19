# The Android half of the dev-library sync, sourced by sync_dev_library.sh,
# pull_dev_library.sh and push_dev_library.sh (not run on its own).
#
#   source scripts/dev_library_android.sh
#   if android_resolve "$DEVICE"; then ... "$SERIAL" ...; fi
#
# A device argument is Android when it is an adb serial that `adb devices` lists
# (emulator-5554, or a phone's serial) or the AVD name of a running emulator
# (dev-android, dev-android-low). The serial depends on boot order, so an AVD
# name is resolved by asking each emulator its name, never assumed.
#
# Where the app keeps things (debug build, so `run-as` works):
#   Documents (path_provider)  /data/data/<pkg>/app_flutter
#   prefs (shared_preferences) /data/data/<pkg>/shared_prefs/FlutterSharedPreferences.xml
#                              same `flutter.` keys as the iOS plist; read by
#                              pull_dev_library.sh's load_prefs.
# Files move as one tar each way: `adb exec-out run-as <pkg> tar c` streams off
# the device binary-clean, and the push goes via /data/local/tmp, which the app's
# uid can read once it is world-readable.

ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
ANDROID_PKG="name.howison.violinPracticeCompanion"
ANDROID_PREFS="shared_prefs/FlutterSharedPreferences.xml"

# Sets SERIAL and returns 0 if $1 names a connected Android device; returns 1
# (quietly, without touching SERIAL) otherwise, so iOS names fall through.
android_resolve() {
  local want="$1" s
  [[ -x "$ADB" ]] || return 1
  local serials
  serials=$("$ADB" devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}')
  [[ -n "$serials" ]] || return 1
  for s in $serials; do
    [[ "$s" == "$want" ]] && { SERIAL="$s"; return 0; }
  done
  for s in $serials; do
    [[ "$s" == emulator-* ]] || continue
    if [[ "$("$ADB" -s "$s" emu avd name 2>/dev/null | head -1 | tr -d '\r')" == "$want" ]]; then
      SERIAL="$s"
      return 0
    fi
  done
  return 1
}

android_adb() { "$ADB" -s "$SERIAL" "$@"; }

# run-as only works for a debuggable (debug/profile) build that is installed.
android_check_installed() {
  if ! android_adb shell run-as "$ANDROID_PKG" true >/dev/null 2>&1; then
    echo "$ANDROID_PKG is not installed as a debug build on $SERIAL (run-as fails)." >&2
    echo "Install it first: a flutter run on $SERIAL (CLAUDE.md, \"Android emulator\")." >&2
    exit 1
  fi
}

# Is a `flutter run` attached to this device? Prints its pid(s).
android_flutter_runs() {
  pgrep -f "flutter_tools.snapshot run .*-d ($SERIAL|${1:-$SERIAL})( |\$)" || true
}

android_stop_app() {
  android_adb shell am force-stop "$ANDROID_PKG"
}

# android_pull_docs DEST FOLDER...: copy the synced Documents folders, the prefs
# XML and the staged state.json into DEST (as DEST/app_flutter/..., DEST/shared_prefs/...).
# Absent items are fine (a fresh install has no media/); anything that was there
# but didn't arrive stops the sync — a folder that silently failed to copy looks
# exactly like one the user emptied, and the merge would delete it from the library.
android_pull_docs() {
  local dest="$1"; shift
  local want=() f
  for f in "$@"; do want+=("app_flutter/$f"); done
  want+=("$ANDROID_PREFS" "app_flutter/dev_library/state.json")
  # `adb shell` (unlike exec-out) returns the device command's exit status.
  local present
  if ! present=$(android_adb shell run-as "$ANDROID_PKG" ls -d "${want[@]}" 2>/dev/null | tr -d '\r'); then
    : # ls exits 1 when any item is missing; the listing of the rest still stands
  fi
  mkdir -p "$dest"
  [[ -n "$present" ]] || return 0
  # shellcheck disable=SC2086 # paths are ours, no spaces
  android_adb exec-out run-as "$ANDROID_PKG" tar cf - $present > "$dest/pull.tar"
  if ! tar xf "$dest/pull.tar" -C "$dest" 2>/dev/null; then
    echo "pull from $SERIAL: the tar off the device is unreadable; stopping before anything is merged" >&2
    exit 1
  fi
  rm -f "$dest/pull.tar"
  for f in $present; do
    if [[ ! -e "$dest/$f" ]]; then
      echo "pull from $SERIAL: $f is on the device but didn't copy; stopping before anything is merged" >&2
      exit 1
    fi
  done
}

# android_push_stage STAGE: replace the app's Documents/dev_library with STAGE.
# A mirror, like the simulator's rsync --delete.
android_push_stage() {
  local stage="$1" tarball remote="/data/local/tmp/vpc_dev_library.tar"
  tarball="$(dirname "$stage")/dev_library.tar"
  COPYFILE_DISABLE=1 tar cf "$tarball" -C "$(dirname "$stage")" dev_library
  android_adb push "$tarball" "$remote" >/dev/null
  android_adb shell chmod 644 "$remote"
  if ! android_adb shell run-as "$ANDROID_PKG" sh -c "'rm -rf app_flutter/dev_library && tar xf $remote -C app_flutter'"; then
    android_adb shell rm -f "$remote"
    echo "push to $SERIAL failed while unpacking the library" >&2
    exit 1
  fi
  android_adb shell rm -f "$remote"
  local want got
  want=$(find "$stage" -type f | wc -l | tr -d ' ')
  got=$(android_adb shell run-as "$ANDROID_PKG" find app_flutter/dev_library -type f | wc -l | tr -d ' ')
  if [[ "$want" != "$got" ]]; then
    echo "push to $SERIAL: staged $got files, expected $want" >&2
    exit 1
  fi
}
