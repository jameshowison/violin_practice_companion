# Sourced by dev_run.sh and dev_stop.sh: which Claude Code session launched
# which dev server, so the session's SessionEnd hook can stop exactly those
# (.claude/hooks/session_end_sims.sh, CLAUDE.md "Parallel Claude sessions").
#
# One file per session, $CLAIMS_DIR/<session id>.tsv, one line per pipe:
#   fifo <TAB> device <TAB> booted (1 = one of our launches booted it) <TAB> claude pid
# Launches outside Claude Code (no $CLAUDE_CODE_SESSION_ID) record nothing.

CLAIMS_DIR="${VPC_CLAIMS_DIR:-/tmp/vpc_sim_claims}"

# The flutter run reading fifo $1 and the `sleep 86400` holding its write end.
# Matched by inode (lsof can't look a fifo up by path), so a run on another
# session's pipe is never touched.
fifo_pids() {
  local fifo=$1 inode pid
  [[ -p "$fifo" ]] || return 0
  inode=$(stat -f '%i' "$fifo")
  for pid in $(pgrep -f 'flutter_tools.snapshot run') $(pgrep -fx 'sleep 86400'); do
    lsof -p "$pid" -a -d 0,1 2>/dev/null | awk -v n="$inode" '$(NF-1)==n {f=1} END {exit !f}' \
      && echo "$pid"
  done
}

# Record that this session now owns fifo $1, running on device $2; $3 is 1 if
# this launch booted the device. The pipe changes hands, so it is dropped from
# every other session's claim; "booted" is inherited from any earlier claim on
# the device, so whichever session holds it last shuts it down.
claim_record() {
  local fifo=$1 device=$2 booted=$3 sid=${CLAUDE_CODE_SESSION_ID:-} f tmp
  [[ -n "$sid" ]] || return 0
  mkdir -p "$CLAIMS_DIR" || return 0
  for f in "$CLAIMS_DIR"/*.tsv; do
    [[ -f "$f" ]] || continue
    awk -F'\t' -v d="$device" '$2==d && $3==1 {x=1} END {exit !x}' "$f" && booted=1
    tmp=$(mktemp "$CLAIMS_DIR/.tmp.XXXXXX") || continue
    awk -F'\t' -v p="$fifo" '$1!=p' "$f" > "$tmp" && mv "$tmp" "$f"
    [[ -s "$f" ]] || rm -f "$f"
  done
  printf '%s\t%s\t%s\t%s\n' "$fifo" "$device" "$booted" "${CLAUDE_PID:-}" >> "$CLAIMS_DIR/$sid.tsv"
}

# Is device $1 named by a live claim of a session other than $2? A claim whose
# claude process has gone (a crash, no hook) doesn't count.
claim_device_elsewhere() {
  local device=$1 sid=$2 f pid
  for f in "$CLAIMS_DIR"/*.tsv; do
    [[ -f "$f" && "$f" != "$CLAIMS_DIR/$sid.tsv" ]] || continue
    for pid in $(awk -F'\t' -v d="$device" '$2==d {print ($4=="" ? "?" : $4)}' "$f"); do
      [[ "$pid" == "?" ]] && return 0
      kill -0 "$pid" 2>/dev/null && return 0
    done
  done
  return 1
}
