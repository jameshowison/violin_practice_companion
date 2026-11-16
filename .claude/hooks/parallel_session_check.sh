#!/usr/bin/env bash
# SessionStart hook: warn when another Claude Code session is already working in
# this same checkout (not a worktree of it). See CLAUDE.md, "Parallel Claude
# sessions". Prints hook JSON; exits 0 whatever happens so it never blocks a start.

dir=$(pwd -P)

# Inside a linked worktree the session is already isolated.
[[ "$(git rev-parse --git-dir 2>/dev/null)" != "$(git rev-parse --git-common-dir 2>/dev/null)" ]] && exit 0

# This session's own claude process: walk up from the hook.
me=$$
while [[ -n "$me" && "$me" != 1 ]]; do
  [[ "$(ps -o comm= -p "$me" 2>/dev/null)" == claude ]] && break
  me=$(ps -o ppid= -p "$me" 2>/dev/null | tr -d ' ')
done

others=()
for pid in $(ps -Ao pid=,comm= | awk '$2=="claude" {print $1}'); do
  [[ "$pid" == "$me" ]] && continue
  cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
  [[ "$cwd" == "$dir" ]] && others+=("$pid")
done
[[ ${#others[@]} -eq 0 ]] && exit 0

dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
msg="Another Claude Code session (pid ${others[*]}) is already working in this checkout ($dir); $dirty uncommitted path(s) here may be its work in progress."
ctx="$msg Before editing ANY file, tell the user and recommend moving this session into a git worktree (EnterWorktree, or \`git worktree add\`); wait for their answer. Read-only work is fine meanwhile. If you do stay here, never commit, stash, checkout or reset files you did not change yourself, and stage only your own paths explicitly (no \`git add -A\`/\`commit -a\`). For running the app, follow CLAUDE.md \"Parallel Claude sessions\": your own simulator and FLUTTER_FIFO."

python3 -c 'import json,sys; print(json.dumps({"systemMessage": "⚠ "+sys.argv[1]+" Consider a worktree.", "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.argv[2]}}))' "$msg" "$ctx"
exit 0
