#!/usr/bin/env bash
# Stop the dev servers a Claude Code session started with dev_run.sh, and shut
# down the simulators its launches booted. The SessionEnd hook runs it on /clear
# and on exit (.claude/hooks/session_end_sims.sh); by hand:
#   bash scripts/dev_stop.sh                  # this session ($CLAUDE_CODE_SESSION_ID)
#   bash scripts/dev_stop.sh --session <id>
#   bash scripts/dev_stop.sh --list           # every session's claims
# A simulator is left running when another live session's claim names it, when
# some other flutter run is still on it, or when it was already booted before
# any of our launches (someone else's, or booted by hand).
set -u
. "$(dirname "$0")/dev_claims.sh"

SID=${CLAUDE_CODE_SESSION_ID:-}
LIST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SID=${2:-}; shift ;;
    --list) LIST=1 ;;
    *) echo "usage: $0 [--session <id>] [--list]" >&2; exit 2 ;;
  esac
  shift
done

if [[ -n "$LIST" ]]; then
  for f in "$CLAIMS_DIR"/*.tsv; do
    [[ -f "$f" ]] && awk -v s="$(basename "$f" .tsv)" '{print s "\t" $0}' "$f"
  done
  exit 0
fi

[[ -n "$SID" ]] || { echo "no session id (pass --session)" >&2; exit 2; }
CLAIM="$CLAIMS_DIR/$SID.tsv"
[[ -f "$CLAIM" ]] || { echo "session $SID: nothing to stop"; exit 0; }

echo "$(date '+%F %T') stopping session $SID"
SHUTDOWN=()
while IFS=$'\t' read -r fifo device booted _; do
  pids=$(fifo_pids "$fifo")
  if [[ -n "$pids" ]]; then
    echo "  $device: killing flutter run + pipe holder on $fifo (pid $(echo $pids))"
    kill $pids 2>/dev/null
  fi
  rm -f "$fifo"
  [[ "$booted" == 1 ]] && SHUTDOWN+=("$device")
done < "$CLAIM"
rm -f "$CLAIM"

# Let the killed runs exit before asking whether anything else is on the device.
[[ ${#SHUTDOWN[@]} -gt 0 ]] && sleep 2
for device in $(printf '%s\n' ${SHUTDOWN[@]+"${SHUTDOWN[@]}"} | sort -u); do
  if claim_device_elsewhere "$device" "$SID"; then
    echo "  $device: another session claims it, leaving it booted"
  elif pgrep -f "flutter_tools.snapshot run .*-d $device( |\$)" >/dev/null; then
    echo "  $device: another flutter run is on it, leaving it booted"
  else
    echo "  $device: shutting down"
    xcrun simctl shutdown "$device" 2>&1 | sed 's/^/    /'
  fi
done
