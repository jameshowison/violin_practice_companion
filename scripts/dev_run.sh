#!/usr/bin/env bash
# Relaunch the Flutter dev server on a simulator using the fifo control pattern
# documented in CLAUDE.md. Safe to re-run: kills the previous run on THIS pipe first.
# Defaults to dev-iphone-se; pass another simulator name as $1, e.g.
#   scripts/dev_run.sh dev-ipad
#
# Parallel sessions (CLAUDE.md, "Parallel Claude sessions"): give each its own
# simulator and pipe, e.g.
#   FLUTTER_FIFO=/tmp/flutter_ctl_ipad bash scripts/dev_run.sh dev-ipad
# Only the flutter run and pipe holder attached to $FLUTTER_FIFO are killed. If
# another run already holds the device, the script refuses unless --takeover.
# (see README "Simulator names" for how the dev-* aliases are set up)
#
# Flavors (docs/family/mandolin-app.md): FLUTTER_FLAVOR=mandolin builds the
# Mandolin app, which installs beside Stringlings under its own bundle id.
# Unset, flutter uses pubspec's default-flavor (stringlings). The dev library
# sync knows only Stringlings' bundle id, so it is skipped for mandolin.
#   FLUTTER_FLAVOR=mandolin FLUTTER_FIFO=/tmp/flutter_ctl_mandolin bash scripts/dev_run.sh dev-ipad
set -u

# Before every launch the dev library is synced with this simulator (see
# scripts/sync_dev_library.sh); the app merges it as it starts. --no-sync skips
# it (--sync is still accepted, and is the default). Skipped with a note when
# ../violin_dev_library isn't checked out.
SYNC=1
TAKEOVER=""
ARGS=()
FLUTTER_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --sync) SYNC=1 ;;
    --no-sync) SYNC="" ;;
    --takeover) TAKEOVER=1 ;;
    # Anything else starting with -- goes to flutter run, e.g.
    # --dart-define=SCREENSHOTS=true (README, "App Store screenshots").
    --*) FLUTTER_ARGS+=("$arg") ;;
    *) ARGS+=("$arg") ;;
  esac
done
DEVICE="${ARGS[0]:-${DEVICE:-dev-iphone-se}}"
# The App Store screenshot sims show only the bundled pieces, so they never take
# the dev library (its scanned pieces, and relabels synced back from there).
[[ "$DEVICE" == shots-* ]] && SYNC=""
FIFO="${FLUTTER_FIFO:-/tmp/flutter_ctl}"
FLAVOR="${FLUTTER_FLAVOR:-}"
if [[ -n "$FLAVOR" ]]; then
  FLUTTER_ARGS+=("--flavor" "$FLAVOR")
  if [[ "$FLAVOR" != stringlings && -n "$SYNC" ]]; then
    echo "flavor $FLAVOR: skipping the dev library sync (it targets Stringlings' bundle id)"
    SYNC=""
  fi
fi
LOG="${FLUTTER_LOG:-flutter_run.log}"

# A dev build without homr's models runs, but scanning fails at recognition.
if [[ $(ls "$(dirname "$0")/../assets/engine/omr_models/"*.onnx 2>/dev/null | wc -l) -lt 3 ]]; then
  echo "warning: assets/engine/omr_models/ lacks homr's models; scanning will fail." >&2
  echo "         run: bash scripts/fetch_omr_models.sh" >&2
fi

# Kill only what belongs to this pipe: the flutter run reading it and the
# `sleep 86400` holding its write end. Matched by inode (lsof can't look a fifo
# up by path), so a run on another session's pipe is never touched.
fifo_pids() {
  [[ -p "$FIFO" ]] || return 0
  local inode pid
  inode=$(stat -f '%i' "$FIFO")
  for pid in $(pgrep -f 'flutter_tools.snapshot run') $(pgrep -fx 'sleep 86400'); do
    lsof -p "$pid" -a -d 0,1 2>/dev/null | awk -v n="$inode" '$(NF-1)==n {f=1} END {exit !f}' \
      && echo "$pid"
  done
}
OWN=$(fifo_pids)

# Another flutter run on the same device that isn't ours: two runs would fight
# over the install, so stop rather than kill another session's dev server.
OTHERS=""
for pid in $(pgrep -f "flutter_tools.snapshot run .*-d $DEVICE( |\$)"); do
  grep -qx "$pid" <<<"$OWN" || OTHERS+="$pid "
done
if [[ -n "$OTHERS" ]]; then
  if [[ -n "$TAKEOVER" ]]; then
    echo "taking over $DEVICE from flutter run pid(s) $OTHERS"
    kill $OTHERS 2>/dev/null
  else
    echo "error: $DEVICE already has a flutter run not on $FIFO (pid $OTHERS)." >&2
    echo "       Another session may be using it. Pick another simulator and pipe," >&2
    echo "       e.g. FLUTTER_FIFO=/tmp/flutter_ctl_ipad $0 dev-ipad," >&2
    echo "       or pass --takeover to kill it." >&2
    exit 1
  fi
fi
[[ -n "$OWN" ]] && kill $OWN 2>/dev/null
sleep 1

# Ensure the simulator is booted and the Simulator app is open.
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator 2>/dev/null || true
# Give the device a moment to reach Booted.
for _ in $(seq 1 20); do
  xcrun simctl list devices | grep "$DEVICE" | grep -q "Booted" && break
  sleep 1
done

if [[ -n "$SYNC" ]]; then
  LIBDIR="${DEV_LIBRARY:-$(dirname "$0")/../../violin_dev_library}"
  if [[ ! -f "$LIBDIR/state.json" ]]; then
    echo "no dev library at $LIBDIR; launching without it"
  elif ! bash "$(dirname "$0")/sync_dev_library.sh" "$DEVICE" --no-launch; then
    echo "WARNING: dev library sync failed (see above); launching without it." >&2
  fi
fi

rm -f "$FIFO"
mkfifo "$FIFO"

# Stamp the build before launching, so the AppBar says which build is live and the
# expected value is right here in this script's output. See CLAUDE.md "Verify the
# build is live".
STAMP=$(bash "$(dirname "$0")/gen_build_info.sh")

flutter run -d "$DEVICE" ${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"} < "$FIFO" > "$LOG" 2>&1 &

# Hold the write end open so the fifo doesn't close. Detached on purpose: `exec 3>`
# would last only as long as THIS shell, so the pipe would lose its only writer the
# moment the script exits — and every later `echo "r" > $FIFO` would be shouting into
# a closed pipe.
nohup sleep 86400 > "$FIFO" 2>/dev/null &

echo "launched (device=$DEVICE, pipe=$FIFO, log=$LOG${FLUTTER_ARGS[@]+, ${FLUTTER_ARGS[*]}})"
echo "$STAMP"
