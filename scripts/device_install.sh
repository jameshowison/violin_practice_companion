#!/usr/bin/env bash
# Build and install a release build on a physical iPhone/iPad.
#
# Defaults to the phone named Jamz; pass another device name or UDID as $1:
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

# --sync: afterwards, sync the dev library with the device (see
# scripts/sync_dev_library.sh) — it relaunches the app, which merges it.
# --no-build: skip the build and install what is already in $APP — for when the
# build succeeded but devicectl lost the phone. The "built at" line below still
# prints, so you can see how old the reused binary is.
SYNC=""
NO_BUILD=""
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --sync) SYNC=1 ;;
    --no-build) NO_BUILD=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
DEVICE="${ARGS[0]:-${DEVICE:-JamzJamzJamzz}}"
APP="build/ios/iphoneos/Runner.app"

cd "$(dirname "$0")/.."

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
if [[ $(ls assets/omr_models/*.onnx 2>/dev/null | wc -l) -lt 3 ]]; then
  echo "assets/omr_models/ is missing homr's models — run: bash scripts/fetch_omr_models.sh" >&2
  exit 1
fi

# A simulator dev server holds build/ios/; the two contend.
pkill -f flutter_tools.snapshot 2>/dev/null || true

flutter build ios --release

fi

# Prove the artifact is from this run rather than trusting the exit code. Cheap,
# and it is exactly the check that caught a two-hour-old binary going onto the
# phone with a clean exit 0.
echo "installing artifact built at: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$APP/Frameworks/App.framework/App")"

# --timeout: when CoreDevice's tunnel to the phone wedges (seen after a USB
# drop: the device sits at "connecting" and every request queues behind a stuck
# Xcode one), devicectl otherwise hangs forever. Fail loudly instead.
xcrun devicectl device install app --timeout 300 --device "$DEVICE" "$APP"

# The profile is the thing with a shelf life on a free Apple ID team: 7 days,
# after which the app stops launching until it is rebuilt and reinstalled.
if EXPIRY=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
    | plutil -extract ExpirationDate raw -o - - 2>/dev/null); then
  echo "provisioning profile expires: $EXPIRY"
fi

if [[ -n "$SYNC" ]]; then
  bash scripts/sync_dev_library.sh "$DEVICE"
fi

cat <<'EOF'

If the app refuses to launch ("invalid code signature ... or its profile has not
been explicitly trusted"), trust the developer once on the device:
  Settings → General → VPN & Device Management → Developer App → Trust
EOF
