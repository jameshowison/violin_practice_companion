#!/usr/bin/env bash
# Build and install a release build on a physical iPhone/iPad.
#
# Defaults to the phone named Jamz; pass another device name or UDID as $1:
#   scripts/device_install.sh JamzJamzJamzz
#   scripts/device_install.sh 00008110-001C2D160AA0401E
#
# Two things this exists to get right — see README "Installing on a physical
# device" for the full reasoning:
#
#   1. It ALWAYS builds first. `flutter install` on its own silently reuses
#      whatever is already in build/ios/iphoneos/Runner.app and does NOT rebuild,
#      so it will happily exit 0 having installed a binary from hours ago.
#
#   2. It installs with `devicectl`, not `flutter install`. flutter uninstalls
#      the old copy first, and iOS drops the developer-trust record as soon as
#      the last app signed by that certificate leaves the device — which is why
#      the phone demands Settings → VPN & Device Management → Trust on every
#      install. devicectl installs over the top and the trust survives.
set -euo pipefail

DEVICE="${1:-${DEVICE:-JamzJamzJamzz}}"
APP="build/ios/iphoneos/Runner.app"

cd "$(dirname "$0")/.."

# Stamp first, same as dev_run.sh — though note a RELEASE build does not show
# kBuildRef in the AppBar (it is debug-only), so confirm the build by the feature
# you came to test, not by reading the stamp off the screen.
STAMP=$(bash scripts/gen_build_info.sh)
echo "$STAMP"

# A simulator dev server holds build/ios/; the two contend.
pkill -f flutter_tools.snapshot 2>/dev/null || true

flutter build ios --release

# Prove the artifact is from this run rather than trusting the exit code. Cheap,
# and it is exactly the check that caught a two-hour-old binary going onto the
# phone with a clean exit 0.
echo "installing artifact built at: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$APP/Frameworks/App.framework/App")"

xcrun devicectl device install app --device "$DEVICE" "$APP"

# The profile is the thing with a shelf life on a free Apple ID team: 7 days,
# after which the app stops launching until it is rebuilt and reinstalled.
if EXPIRY=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
    | plutil -extract ExpirationDate raw -o - - 2>/dev/null); then
  echo "provisioning profile expires: $EXPIRY"
fi

cat <<'EOF'

If the app refuses to launch ("invalid code signature ... or its profile has not
been explicitly trusted"), trust the developer once on the device:
  Settings → General → VPN & Device Management → Developer App → Trust
EOF
