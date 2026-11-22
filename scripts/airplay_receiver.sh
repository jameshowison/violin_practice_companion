#!/usr/bin/env bash
# A software AirPlay receiver on this Mac, for testing the app's AirPlay
# playback without ears: shairport-sync advertises "VPC Test Receiver" and
# tool/airplay/pcm_monitor.py logs, every 100 ms, how much audio arrived and
# how loud it was. Drive the phone with ios/RunnerUITests (see
# scripts/airplay_harness.sh); read the log back with `summary`.
#
#   bash scripts/airplay_receiver.sh start | stop | restart | status
#   bash scripts/airplay_receiver.sh freeze | thaw   # stale speaker: alive, not answering
#   bash scripts/airplay_receiver.sh summary [HH:MM:SS]   # gaps + silences since
#
# Needs `brew install shairport-sync` (AirPlay 1; Homebrew has no nqptp for
# AirPlay 2, and iOS still lists AirPlay 1 receivers). Turn off System
# Settings ▸ AirDrop & Handoff ▸ AirPlay Receiver first: it holds port 7000.
# `stop` is also how to fake a speaker going away mid-session.
set -euo pipefail
cd "$(dirname "$0")/.."

# NOTE: iOS 27 won't connect to this AirPlay-1-only receiver ("Unable to
# connect", no connection attempted); see tool/airplay/ for the Mac's own
# AirPlay 2 receiver instead.
NAME="${AIRPLAY_NAME:-VPC Test Receiver}"
DIR="${AIRPLAY_LOG_DIR:-/tmp/vpc_airplay}"
mkdir -p "$DIR"
PCM="$DIR/pcm.log"
SS=/opt/homebrew/opt/shairport-sync/bin/shairport-sync

running() { pgrep -f "shairport-sync.*$NAME" >/dev/null; }

case "${1:-status}" in
  start)
    running && { echo "already running"; exit 0; }
    [[ -x "$SS" ]] || { echo "brew install shairport-sync"; exit 1; }
    MON="$PWD/tool/airplay/pcm_monitor.py"
    nohup bash -c "'$SS' --use-stderr -v -a '$NAME' -o stdout 2>>'$DIR/shairport.log' \
      | python3 -I '$MON' '$PCM'" >/dev/null 2>&1 &
    sleep 2
    running && echo "started '$NAME'; log $PCM" || { echo "failed; see $DIR/shairport.log"; exit 1; }
    ;;
  stop)
    pkill -f "shairport-sync.*$NAME" || true
    echo "stopped"
    ;;
  restart) "$0" stop; sleep 1; "$0" start ;;
  freeze)  # SIGSTOP: the connection stays open but nothing answers (a stale speaker)
    pkill -STOP -f "shairport-sync.*$NAME" && echo "frozen" ;;
  thaw) pkill -CONT -f "shairport-sync.*$NAME" && echo "thawed" ;;
  status)
    running && echo "running ('$NAME')" || echo "not running"
    tail -n 3 "$PCM" 2>/dev/null || true
    ;;
  summary) python3 -I tool/airplay/pcm_monitor.py --summarize "$PCM" ${2:+--since "$2"} ;;
  *) echo "usage: $0 start|stop|restart|freeze|thaw|status|summary [HH:MM:SS]"; exit 2 ;;
esac
