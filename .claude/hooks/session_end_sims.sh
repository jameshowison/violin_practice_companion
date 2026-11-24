#!/usr/bin/env bash
# SessionEnd hook (/clear, exit, logout): stop the dev servers this session
# launched with scripts/dev_run.sh and shut down the simulators it booted, via
# scripts/dev_stop.sh. Session end gives hooks very little time and simctl
# shutdown takes seconds, so the work runs detached in its own process session
# (it must outlive the claude process on exit). Log: /tmp/vpc_sim_claims/stop.log.
# Exits 0 whatever happens.

claims=${VPC_CLAIMS_DIR:-/tmp/vpc_sim_claims}
sid=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)
[[ -n "$sid" && -f "$claims/$sid.tsv" ]] || exit 0

stop="$(cd "$(dirname "$0")/../.." && pwd)/scripts/dev_stop.sh"
nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' bash "$stop" --session "$sid" \
  >> "$claims/stop.log" 2>&1 < /dev/null &
exit 0
