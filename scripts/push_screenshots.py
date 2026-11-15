# /// script
# requires-python = ">=3.10"
# dependencies = ["pyjwt", "cryptography", "requests"]
# ///
"""Upload the framed App Store screenshots to App Store Connect.

    uv run scripts/push_screenshots.py           # compare: what's live vs. what would go up
    uv run scripts/push_screenshots.py --apply   # replace each set with build/screenshots/out/

Takes build/screenshots/out/<device>/NN.png (made by frame_screenshots.py) in
file-name order. --apply deletes what is in that device's slot first, so the
slot ends up exactly the local set. Same API key as push_listing.py (1Password,
Touch ID); only the version in Prepare for Submission is touched.

The app icon is not uploaded here: App Store Connect takes it from the build's
asset catalog (AppIcon 1024×1024), so it appears once a build is attached.
"""
import hashlib
import sys
import time
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
from push_listing import Asc, editable, one_locale  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "build/screenshots/out"
# Folder → App Store Connect slot. APP_IPHONE_67 is the 6.9" slot (1320×2868),
# APP_IPAD_PRO_3GEN_129 the 13" one (2064×2752).
SLOTS = {"iphone": "APP_IPHONE_67", "ipad": "APP_IPAD_PRO_3GEN_129"}


def upload(asc: Asc, set_id: str, png: Path) -> str:
    data = png.read_bytes()
    shot = asc.call("POST", "/v1/appScreenshots", json={"data": {
        "type": "appScreenshots",
        "attributes": {"fileName": png.name, "fileSize": len(data)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
    }})["data"]
    for op in shot["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders") or []}
        # The upload URLs are pre-signed: no API token on these.
        r = requests.request(op["method"], op["url"], headers=headers, data=chunk)
        if not r.ok:
            sys.exit(f"upload of {png.name} failed: {r.status_code} {r.text[:300]}")
    asc.patch("appScreenshots", shot["id"],
              {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()})
    return shot["id"]


def wait_processed(asc: Asc, ids: list[str]):
    pending = set(ids)
    for _ in range(60):
        for i in list(pending):
            state = asc.call("GET", f"/v1/appScreenshots/{i}")["data"]["attributes"]["assetDeliveryState"]
            if state["state"] == "COMPLETE":
                pending.discard(i)
            elif state["state"] == "FAILED":
                sys.exit(f"screenshot {i} failed processing: {state.get('errors')}")
        if not pending:
            return
        time.sleep(3)
    print(f"  still processing after 3 min: {len(pending)} (they usually finish on their own)")


def main():
    apply = "--apply" in sys.argv
    local = {d: sorted((OUT / d).glob("*.png")) for d in SLOTS}
    if not any(local.values()):
        sys.exit(f"nothing in {OUT}; run frame_screenshots.py first")

    asc = Asc()
    apps = asc.get("/v1/apps")
    app = apps[0]["id"]
    ver = editable(asc.get(f"/v1/apps/{app}/appStoreVersions"), "App Store version")
    loc = one_locale(asc.get(f"/v1/appStoreVersions/{ver['id']}/appStoreVersionLocalizations"), "version")
    print(f"{apps[0]['attributes']['name']} {ver['attributes']['versionString']}, {loc['attributes']['locale']}\n")
    sets = {s["attributes"]["screenshotDisplayType"]: s
            for s in asc.get(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")}

    for device, slot in SLOTS.items():
        pngs = local[device]
        if not pngs:
            continue
        live = asc.get(f"/v1/appScreenshotSets/{sets[slot]['id']}/appScreenshots") if slot in sets else []
        print(f"{slot}: live {len(live)} → local {len(pngs)} ({', '.join(p.name for p in pngs)})")
        if not apply:
            continue
        if slot not in sets:
            sets[slot] = asc.call("POST", "/v1/appScreenshotSets", json={"data": {
                "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": slot},
                "relationships": {"appStoreVersionLocalization": {
                    "data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]
        for old in live:
            asc.call("DELETE", f"/v1/appScreenshots/{old['id']}")
        ids = []
        for png in pngs:
            ids.append(upload(asc, sets[slot]["id"], png))
            print(f"  ↑ {png.name}")
        asc.call("PATCH", f"/v1/appScreenshotSets/{sets[slot]['id']}/relationships/appScreenshots",
                 json={"data": [{"type": "appScreenshots", "id": i} for i in ids]})
        wait_processed(asc, ids)
        print(f"  ✔ {len(ids)} processed, in order")

    if not apply:
        print("\nCompared only. --apply replaces each slot with the local set.")


if __name__ == "__main__":
    main()
