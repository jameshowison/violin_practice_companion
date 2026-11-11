#!/usr/bin/env bash
# Build and install a release build on a physical iPhone/iPad.
#
# Defaults to the phone, JamzJamzJamzz ("Jamz" works as shorthand); pass
# another device name or UDID as $1:
#   scripts/device_install.sh JamzJamzJamzz
#   scripts/device_install.sh 00008110-001C2D160AA0401E
#   scripts/device_install.sh --no-build   # retry the install of the last build
#
# Two things this exists to get right — see README "Installing on a physical
# device" for the full reasoning:
#
#   1. It ALWAYS builds first. `flutter install` on its own silently reuses
#      whatever is already in build/ios/iphoneos/Runner.app and does NOT rebuild,
#      so it will happily exit 0 having installed a binary from hours ago.
#      `flutter build` itself is incremental, so re-running on an unchanged
#      tree is cheaper than the first build.
#
#   2. It installs with `devicectl`, not `flutter install`. flutter uninstalls
#      the old copy first, and iOS drops the developer-trust record as soon as
#      the last app signed by that certificate leaves the device — which is why
#      the phone demands Settings → VPN & Device Management → Trust on every
#      install. devicectl installs over the top and the trust survives.
set -euo pipefail

# The dev library (../violin_dev_library) is synced onto the device after every
# install — see scripts/sync_dev_library.sh; it relaunches the app, which merges
# it. --no-sync skips that (--sync is still accepted, and is the default). With
# no library checked out next to this repo the sync is skipped with a note.
# --no-build: skip the build and install what is already in $APP — for when the
# build succeeded but devicectl lost the phone. The "built at" line below still
# prints, so you can see how old the reused binary is.
SYNC=1
NO_BUILD=""
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --sync) SYNC=1 ;;
    --no-sync) SYNC="" ;;
    --no-build) NO_BUILD=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
DEVICE="${ARGS[0]:-${DEVICE:-JamzJamzJamzz}}"
# "Jamz" is shorthand for the phone, whose device name is JamzJamzJamzz.
[[ "$DEVICE" == "Jamz" ]] && DEVICE="JamzJamzJamzz"
APP="build/ios/iphoneos/Runner.app"

cd "$(dirname "$0")/.."

# --- Progress you can watch ---------------------------------------------------
# A release build plus a wireless install can take many minutes with long
# silences, which look exactly like a hang. So everything also goes to
# device_install.log (watch it from another terminal: tail -f device_install.log),
# each phase is announced with the time, and while a phase is quiet a heartbeat
# line says which phase it is still in and for how long. The last line says
# where it ended: done, or FAILED in which phase.
LOG="device_install.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
T0=$(date +%s)
PHASE_FILE=$(mktemp -t device_install_phase)
elapsed() { local s=$(( $(date +%s) - $1 )); printf '%dm%02ds' $((s / 60)) $((s % 60)); }
phase() {
  printf '%s %s\n' "$(date +%s)" "$1" > "$PHASE_FILE"
  echo "[$(date +%H:%M:%S)] ▶ $1 (total $(elapsed "$T0"))"
}
( while sleep 30; do
    read -r since name < "$PHASE_FILE" 2>/dev/null || continue
    echo "[$(date +%H:%M:%S)]   … still $name ($(elapsed "$since"), total $(elapsed "$T0"))"
  done ) &
HEARTBEAT=$!
finish() {
  local code=$?
  kill "$HEARTBEAT" 2>/dev/null || true
  wait "$HEARTBEAT" 2>/dev/null || true
  local name; name=$(cut -d' ' -f2- "$PHASE_FILE" 2>/dev/null || echo "?")
  rm -f "$PHASE_FILE"
  if [[ $code -eq 0 ]]; then
    echo "[$(date +%H:%M:%S)] ✔ done in $(elapsed "$T0")"
  else
    echo "[$(date +%H:%M:%S)] ✘ FAILED while $name, after $(elapsed "$T0") (exit $code)"
  fi
}
trap finish EXIT
echo "device_install → $DEVICE (log: $LOG)"

# Fail in seconds, not after a full build, if the device can't be reached
# (asleep, locked off Wi-Fi, CoreDevice tunnel wedged).
phase "checking $DEVICE is reachable"
if ! xcrun devicectl device info details --timeout 30 --device "$DEVICE" >/dev/null 2>&1; then
  echo "can't reach $DEVICE — wake and unlock it (or plug it in), then retry" >&2
  exit 1
fi

if [[ -n "$NO_BUILD" ]]; then
  if [[ ! -d "$APP" ]]; then
    echo "--no-build: no $APP to install — run without --no-build first" >&2
    exit 1
  fi
else

# No gen_build_info.sh here, unlike dev_run.sh. A RELEASE build does not show
# kBuildRef (it is debug-only), and the stamp's timestamp changes a Dart file on
# every run, which forces flutter's otherwise-incremental build to recompile the
# whole program. Confirm the build by the feature you came to test instead.

# Scanning loads homr's models from the app's own assets; a build without them
# installs fine and then fails at the first scan. Refuse rather than ship that.
if [[ $(ls assets/engine/omr_models/*.onnx 2>/dev/null | wc -l) -lt 3 ]]; then
  echo "assets/engine/omr_models/ is missing homr's models — run: bash scripts/fetch_omr_models.sh" >&2
  exit 1
fi

# A simulator dev server holds build/ios/; the two contend.
pkill -f flutter_tools.snapshot 2>/dev/null || true

phase "building (flutter build ios --release)"
flutter build ios --release

fi

# Prove the artifact is from this run rather than trusting the exit code. Cheap,
# and it is exactly the check that caught a two-hour-old binary going onto the
# phone with a clean exit 0.
echo "installing artifact built at: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$APP/Frameworks/App.framework/App")"

# --timeout: when CoreDevice's tunnel to the phone wedges (seen after a USB
# drop: the device sits at "connecting" and every request queues behind a stuck
# Xcode one), devicectl otherwise hangs forever. Fail loudly instead.
phase "installing on $DEVICE"
xcrun devicectl device install app --timeout 300 --device "$DEVICE" "$APP"

# The profile is the thing with a shelf life on a free Apple ID team: 7 days,
# after which the app stops launching until it is rebuilt and reinstalled.
if EXPIRY=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
    | plutil -extract ExpirationDate raw -o - - 2>/dev/null); then
  echo "provisioning profile expires: $EXPIRY"
fi

SYNC_FAILED=""
if [[ -n "$SYNC" ]]; then
  if [[ ! -f "${DEV_LIBRARY:-../violin_dev_library}/state.json" ]]; then
    echo "no dev library at ${DEV_LIBRARY:-../violin_dev_library}; installed without it"
  elif phase "syncing the dev library" && ! bash scripts/sync_dev_library.sh "$DEVICE"; then
    SYNC_FAILED=1
  fi
fi

cat <<'EOF'

If the app refuses to launch ("invalid code signature ... or its profile has not
been explicitly trusted"), trust the developer once on the device:
  Settings → General → VPN & Device Management → Developer App → Trust
EOF

# Installed, but the library didn't make it: say so loudly and fail, so nobody
# walks away thinking the device has the shared pieces. The install itself
# stands; re-run just the sync once the device is unlocked.
if [[ -n "$SYNC_FAILED" ]]; then
  echo >&2
  echo "INSTALLED, BUT THE DEV LIBRARY SYNC FAILED (see above)." >&2
  echo "Unlock the device and run: bash scripts/sync_dev_library.sh \"$DEVICE\"" >&2
  exit 1
fi
