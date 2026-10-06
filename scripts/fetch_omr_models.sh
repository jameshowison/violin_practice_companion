#!/usr/bin/env bash
# Put homr's three ONNX models (~150 MB) into assets/omr_models/, where the app
# bundles them. Run once per checkout, before building:
#
#   bash scripts/fetch_omr_models.sh
#
# The models are not in git (here or in homr_flutter) and the homr_flutter
# package ships none: the app owns its copy, so recognition needs no network.
# This delegates to the RESOLVED homr_flutter package's tool/fetch_models.py
# (git tag or local override alike), so the filenames and SHA-256 checksums
# live in one place: the package version this app is pinned to.
#
# With a sibling ../homr_flutter checkout that already has the models, they're
# copied from there (offline, instant); otherwise they're downloaded from homr's
# GitHub release. Either way every file is checksum-verified, and files already
# present and correct are left alone.
set -euo pipefail
cd "$(dirname "$0")/.."

flutter pub get >/dev/null

PKG_ROOT=$(python3 - <<'PY'
import json, os
from urllib.parse import urlparse, unquote
cfg = json.load(open(".dart_tool/package_config.json"))
pkg = next(p for p in cfg["packages"] if p["name"] == "homr_flutter")
uri = pkg["rootUri"]
if uri.startswith("file://"):
    print(unquote(urlparse(uri).path))
else:  # relative to .dart_tool/
    print(os.path.normpath(os.path.join(".dart_tool", unquote(uri))))
PY
)

FROM=()
SIBLING="../homr_flutter/assets/omr_models"
if compgen -G "$SIBLING/*.onnx" >/dev/null; then
  FROM=(--from "$SIBLING")
fi

python3 "$PKG_ROOT/tool/fetch_models.py" assets/omr_models "${FROM[@]+"${FROM[@]}"}"
