#!/usr/bin/env bash
# Lists every path matching a pattern file, in HEAD and anywhere in history
# (all refs), so files that only ever existed in old commits are caught too.
# The default pattern file is the maintainer's private one
# (../violin_practice_restricted/purge/purge_paths.txt); pass --patterns to
# use another. See CONTRIBUTING.md, "Content and copyright".
#
#   bash scripts/content_audit.sh            # report; exit 1 if anything matches
#   bash scripts/content_audit.sh --list     # print the matching paths only
#   bash scripts/content_audit.sh --repo DIR # audit another clone/mirror
#
# Pattern semantics follow git-filter-repo --paths-from-file: a literal path
# (or directory prefix), `glob:` (fnmatch, `*` crosses `/`), or `regex:`.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
patterns="${VPC_RESTRICTED_DIR:-$here/../../violin_practice_restricted}/purge/purge_paths.txt"
repo="."
mode=report
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) mode=list ;;
    --repo) repo="$2"; shift ;;
    --patterns) patterns="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -f "$patterns" ]] || { echo "no pattern file: $patterns" >&2; exit 2; }

read -r -d '' matcher <<'PY' || true
import base64, fnmatch, re, sys
patterns_file, mode, head_b64 = sys.argv[1], sys.argv[2], sys.argv[3]
head = set(filter(None, base64.b64decode(head_b64).decode().split('\0')))
rules = []
for line in open(patterns_file):
    line = line.rstrip('\n')
    if not line or line.startswith('#'):
        continue
    if line.startswith('glob:'):
        g = line[5:]; rules.append((line, lambda p, g=g: fnmatch.fnmatchcase(p, g)))
    elif line.startswith('regex:'):
        r = re.compile(line[6:]); rules.append((line, lambda p, r=r: r.search(p) is not None))
    else:
        lit = line.rstrip('/')
        rules.append((line, lambda p, l=lit: p == l or p.startswith(l + '/')))
paths = [p for p in sys.stdin.read().splitlines() if p]
hits = []
for p in paths:
    for name, m in rules:
        if m(p):
            hits.append((p, name)); break
if mode == 'list':
    for p, _ in hits: print(p)
else:
    for p, name in hits:
        print(f"{'HEAD   ' if p in head else 'history'}  {p}    [{name}]")
    nh = sum(1 for p, _ in hits if p in head)
    print(f"\n{len(hits)} matching paths ({nh} in HEAD, {len(hits) - nh} history-only)")
sys.exit(1 if hits and mode == 'report' else 0)
PY

head_b64="$(git -C "$repo" ls-tree -r --name-only HEAD 2>/dev/null | tr '\n' '\0' | base64 | tr -d '\n')"
{
  git -C "$repo" log --all --no-renames --format= --name-only
  git -C "$repo" ls-tree -r --name-only HEAD 2>/dev/null || true
} | sort -u | python3 -I -c "$matcher" "$patterns" "$mode" "$head_b64"
