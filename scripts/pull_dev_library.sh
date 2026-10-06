#!/usr/bin/env bash
# The pull half of the dev-library sync: take this device's changes into the
# library. Normally run by scripts/sync_dev_library.sh, not by hand.
#
#   bash scripts/pull_dev_library.sh dev-iphone                  # simulator
#   bash scripts/pull_dev_library.sh "Hazel iPad"                # physical device
#   bash scripts/pull_dev_library.sh dev-iphone ../lib --dry-run # print the plan only
#
# Three-way merge per item (a file, a media row, a title, the library blob)
# between the library (L), the device (D) and the device's base (B, what it
# held at its last sync — `devLibrary.base` in its prefs):
#
#   L == D          nothing to do
#   D == B          the device hasn't moved; the push will bring it up to date
#   L == B, D != B  the device moved on: take D (write or delete)
#   all differ      conflict: take D, warn — the library's version is in git
#
# The push half (lib/services/dev_library_io.dart) runs the same table the
# other way. Fingerprints MUST match it: fnv1a and canonical_json below mirror
# `fnv1a` and `canonicalJson` there (pinned by test/dev_library_test.dart).
#
# The app should be stopped first (sync_dev_library.sh does this): it holds
# NSUserDefaults in memory, so a running app's prefs plist can be stale.
set -euo pipefail

DEVICE="${1:?usage: pull_dev_library.sh <device> [library_dir] [--dry-run]}"
cd "$(dirname "$0")/.."
LIB="../violin_dev_library"
DRY=""
for arg in "${@:2}"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    *) LIB="$arg" ;;
  esac
done
BUNDLE="name.howison.violinPracticeCompanion"
FOLDERS=(scanned_pieces editable_fixtures section_overrides media teacher_recordings scan_sources)

if xcrun simctl list devices | grep -q "^ *$DEVICE ("; then
  DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)
  DOCS="$DATA/Documents"
  PLIST="$DATA/Library/Preferences/$BUNDLE.plist"
else
  # A physical device: copy just the synced folders and the prefs plist off it
  # (not all of Documents, which also holds the staged library itself).
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  DOCS="$TMP/Documents"
  PLIST="$TMP/prefs.plist"
  mkdir -p "$DOCS"
  # A copy can fail because the item doesn't exist (CoreDevice error 7000:
  # "Failed to retrieve the file node"), which is fine: a fresh install has no
  # media/, no prefs yet. ANY other failure (a locked iPad, a dropped tunnel)
  # must stop the sync: a folder that silently failed to copy looks exactly
  # like a folder the user emptied, and the merge would delete it all from the
  # library.
  copy_from() {
    local out
    if ! out=$(xcrun devicectl device copy from --device "$DEVICE" --quiet \
        --domain-type appDataContainer --domain-identifier "$BUNDLE" \
        --source "$1" --destination "$2" 2>&1); then
      if grep -q "error 7000" <<<"$out"; then return 0; fi
      echo "copy of $1 from $DEVICE failed; stopping before anything is merged:" >&2
      echo "$out" | grep -m3 -E "ERROR|error" >&2
      echo "(is the device unlocked and awake?)" >&2
      exit 1
    fi
  }
  for f in "${FOLDERS[@]}"; do
    copy_from "Documents/$f" "$DOCS/$f"
  done
  copy_from "Library/Preferences/$BUNDLE.plist" "$PLIST"
fi

mkdir -p "$LIB"
python3 - "$DOCS" "$PLIST" "$LIB" "$DRY" "${FOLDERS[@]}" <<'PY'
import json, os, plistlib, shutil, sys

docs, plist, lib, dry, *folders = sys.argv[1:]

def fnv1a(data: bytes) -> str:
    h = 0x811c9dc5
    for b in data:
        h = ((h ^ b) * 0x01000193) & 0xffffffff
    return format(h, "x")

def canonical_json(v) -> str:
    return json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

def file_fp(rel, path):
    if rel.startswith(("media/", "teacher_recordings/", "scan_sources/")):
        return f"s{os.path.getsize(path)}"
    return "h" + fnv1a(open(path, "rb").read())

def value_fp(v):
    return "j" + fnv1a(canonical_json(v).encode("utf-8"))

def files(root):
    out = {}
    for folder in folders:
        top = os.path.join(root, folder)
        for dirpath, _, names in os.walk(top):
            for n in names:
                if n.startswith("."):
                    continue
                path = os.path.join(dirpath, n)
                rel = os.path.relpath(path, root)
                if rel == "scanned_pieces/index.json":
                    continue
                out["file:" + rel] = file_fp(rel, path)
    return out

# ── Library ──
state_path = os.path.join(lib, "state.json")
state = json.load(open(state_path)) if os.path.exists(state_path) else {}
state.setdefault("version", 2)
state.setdefault("titles", {})
state.setdefault("pieceMedia", {})
state.setdefault("pieceLibrary", None)

def state_values(st):
    v = {f"title:{k}": t for k, t in st["titles"].items()}
    for pid, rows in st["pieceMedia"].items():
        for r in rows:
            v[f"media:{pid}/{r['id']}"] = r
    if st["pieceLibrary"] is not None:
        v["pieceLibrary"] = st["pieceLibrary"]
    return v

# ── Device ──
prefs = plistlib.load(open(plist, "rb")) if os.path.exists(plist) else {}
dev_values = {}
idx = os.path.join(docs, "scanned_pieces/index.json")
if os.path.exists(idx):
    try:
        for r in json.load(open(idx))["pieces"]:
            if r.get("title"):
                dev_values[f"title:{r['id']}"] = r["title"]
    except Exception:
        pass
for k, raw in prefs.items():
    if k.startswith("flutter.pieceMedia."):
        pid = k[len("flutter.pieceMedia."):]
        for r in json.loads(raw):
            if isinstance(r, dict) and isinstance(r.get("id"), str):
                dev_values[f"media:{pid}/{r['id']}"] = r
if "flutter.pieceLibrary" in prefs:
    try:
        dev_values["pieceLibrary"] = json.loads(prefs["flutter.pieceLibrary"])
    except Exception:
        pass
base = json.loads(prefs.get("flutter.devLibrary.base", "{}"))

lib_values = state_values(state)
L = {**files(lib), **{k: value_fp(v) for k, v in lib_values.items()}}
D = {**files(docs), **{k: value_fp(v) for k, v in dev_values.items()}}

taken, conflicts = [], []
for key in sorted(set(L) | set(D) | set(base)):
    l, d, b = L.get(key), D.get(key), base.get(key)
    if key == "pieceLibrary" and b is None and l is not None:
        b = d  # a never-synced device's blob is only its first-launch seed
    if l == d or d == b:
        continue
    taken.append(key)
    if l != b:
        conflicts.append(key)

for key in taken:
    present = key in D
    print(f"  {'take' if present else 'drop'}  {key}{'   CONFLICT: took the device version' if key in conflicts else ''}")
    if dry:
        continue
    if key.startswith("file:"):
        rel = key[5:]
        dst = os.path.join(lib, rel)
        if present:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(os.path.join(docs, rel), dst)
        elif os.path.exists(dst):
            os.remove(dst)
            parent = os.path.dirname(dst)
            while os.path.abspath(parent) != os.path.abspath(lib) and not os.listdir(parent):
                os.rmdir(parent)
                parent = os.path.dirname(parent)
    elif key.startswith("title:"):
        pid = key[6:]
        if present:
            state["titles"][pid] = dev_values[key]
        else:
            state["titles"].pop(pid, None)
    elif key.startswith("media:"):
        pid, mid = key[6:].split("/", 1)
        rows = state["pieceMedia"].setdefault(pid, [])
        i = next((n for n, r in enumerate(rows) if r["id"] == mid), None)
        if present:
            if i is None:
                rows.append(dev_values[key])
            else:
                rows[i] = dev_values[key]
        elif i is not None:
            rows.pop(i)
        if not rows:
            del state["pieceMedia"][pid]
    elif key == "pieceLibrary":
        state["pieceLibrary"] = dev_values.get(key)

if not dry:
    state["titles"] = dict(sorted(state["titles"].items()))
    json.dump(state, open(state_path, "w"), indent=2, ensure_ascii=False)
    open(state_path, "a").write("\n")
print(f"pull: {len(taken)} taken from the device, {len(conflicts)} conflicts"
      f"{' (dry run, nothing written)' if dry else ''}")
PY
