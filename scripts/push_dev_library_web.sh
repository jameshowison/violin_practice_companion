#!/usr/bin/env bash
# The web counterpart of push_dev_library.sh: packs the library's scores,
# titles, section overrides and collections into web/dev_library.json
# (gitignored), which the web build merges at launch
# (lib/services/dev_library_bundle.dart).
#
#   bash scripts/push_dev_library_web.sh            # then reload the browser tab
#   bash scripts/push_dev_library_web.sh --remove   # stop serving it
#
# One-way: there is no pull from a browser. Media, teacher recordings and ABC
# sources are left out — the web build has no file-backed storage for them.
# `flutter build web` copies web/ wholesale, so a release web build made while
# the file exists carries the library too.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="web/dev_library.json"
if [[ "${1:-}" == "--remove" ]]; then rm -f "$OUT"; echo "removed $OUT"; exit 0; fi
LIB="${1:-../violin_dev_library}"

[[ -f "$LIB/state.json" ]] || { echo "no state.json in $LIB — pull from a device first" >&2; exit 1; }

python3 -I - "$LIB" "$OUT" <<'PY'
import json, pathlib, sys
lib, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
state = json.loads((lib / "state.json").read_text())
prefs = {}
def files(folder, suffix):
    d = lib / folder
    return sorted(d.glob("*" + suffix)) if d.is_dir() else []
for f in files("scanned_pieces", ".musicxml"):
    prefs[f"piece.{f.name[:-len('.musicxml')]}.xml"] = f.read_text()
for pid, title in (state.get("titles") or {}).items():
    if f"piece.{pid}.xml" in prefs and title:
        prefs[f"piece.{pid}.title"] = title
for f in files("editable_fixtures", ".musicxml"):
    prefs[f"fixture.{f.name[:-len('.musicxml')]}.xml"] = f.read_text()
for f in files("section_overrides", ".sections.json"):
    prefs[f"sections.{f.name[:-len('.sections.json')]}"] = f.read_text()
if state.get("pieceLibrary") is not None:
    prefs["pieceLibrary"] = json.dumps(state["pieceLibrary"], ensure_ascii=False)
out.write_text(json.dumps({"version": 1, "prefs": prefs}, ensure_ascii=False))
n = sum(k.endswith(".xml") and k.startswith("piece.") for k in prefs)
print(f"{out}: {n} pieces, {len(prefs)} keys, {out.stat().st_size // 1024} KB")
PY
