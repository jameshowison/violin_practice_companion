# /// script
# requires-python = ">=3.10"
# dependencies = ["pyjwt", "cryptography", "requests"]
# ///
"""Push docs/app-store-listing.md into App Store Connect.

    uv run scripts/push_listing.py             # offline preview + length checks, no key
    uv run scripts/push_listing.py --compare   # live vs. new, field by field
    uv run scripts/push_listing.py --apply     # writes the fields that changed

--compare and --apply need the API key. It lives in 1Password (item "App Store Connect API" in the Private
vault: key_id, issuer_id, and the AuthKey_<key_id>.p8 attachment). It is read
with `op read` at run time and never written to disk.

App Store fields are plain text, so the markdown is flattened: bold markers go,
"- " bullets become "• ", and line breaks are kept.
"""
import re
import subprocess
import sys
import time
from pathlib import Path

import jwt
import requests

LISTING = Path(__file__).resolve().parent.parent / "docs" / "app-store-listing.md"
OP_ITEM = "op://Private/App Store Connect API"
API = "https://api.appstoreconnect.apple.com"
LOCALE = "en-US"
LIMITS = {"name": 30, "subtitle": 30, "promotionalText": 170, "keywords": 100,
          "description": 4000, "whatsNew": 4000}


# ---------------------------------------------------------------- the listing

def plain(md: str) -> str:
    lines = []
    for line in md.strip().splitlines():
        line = line.replace("**", "")
        if line.startswith("- "):
            line = "• " + line[2:]
        lines.append(line.rstrip())
    return "\n".join(lines)


def table(section: str, text_col: int) -> dict:
    rows = {}
    for line in section.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) > text_col and line.startswith("|") and not set(cells[0]) <= {"-"}:
            rows[cells[0]] = cells[text_col]
    return rows


def parse_listing(md: str) -> dict:
    sections = {}
    for chunk in md.split("\n## ")[1:]:
        heading, _, body = chunk.partition("\n")
        sections[heading.strip()] = body
    def section(prefix):
        hits = [k for k in sections if k.startswith(prefix)]
        if len(hits) != 1:
            sys.exit(f"listing: expected one section starting {prefix!r}, found {hits}")
        return hits[0], sections[hits[0]]

    _, top = section("Name, subtitle")
    fields = table(top, 2)
    _, links = section("Links and contact")
    link = table(links, 1)
    _, beta = section("TestFlight beta app description")
    test_heading, what_to_test = section("What to Test")
    build = re.search(r"\+(\d+)\)", test_heading)
    if not build:
        sys.exit(f"listing: no build number like '(build 1.0.0+4)' in {test_heading!r}")
    _, store = section("App Store description")
    desc = re.search(r"\*\*Description\*\*\n(.*?)\n\*\*Keywords\*\*", store, re.S)
    kw = re.search(r"```\n(.*?)\n```", store, re.S)

    return {
        "appInfo": {"name": fields["App name"], "subtitle": fields["Subtitle"],
                    "privacyPolicyUrl": link["Privacy policy URL"]},
        "version": {"description": plain(desc.group(1)), "keywords": kw.group(1).strip(),
                    "promotionalText": fields["Promotional text"],
                    "supportUrl": link["Support URL"]},
        "beta": {"description": plain(beta), "feedbackEmail": link["TestFlight feedback email"],
                 "privacyPolicyUrl": link["Privacy policy URL"]},
        "build": build.group(1),
        "whatsNew": plain(what_to_test),
    }


# ---------------------------------------------------------------- the API

def op_read(field: str) -> str:
    return subprocess.run(["op", "read", f"{OP_ITEM}/{field}"], check=True,
                          capture_output=True, text=True).stdout.strip()


class Asc:
    def __init__(self):
        key_id, issuer = op_read("key_id"), op_read("issuer_id")
        key = op_read(f"AuthKey_{key_id}.p8")
        now = int(time.time())
        token = jwt.encode({"iss": issuer, "iat": now, "exp": now + 1200,
                            "aud": "appstoreconnect-v1"},
                           key, algorithm="ES256", headers={"kid": key_id})
        self.s = requests.Session()
        self.s.headers["Authorization"] = f"Bearer {token}"

    def call(self, method, path, **kw):
        r = self.s.request(method, API + path, **kw)
        if not r.ok:
            sys.exit(f"{method} {path} → {r.status_code}\n{r.text}")
        return r.json() if r.content else None

    def get(self, path, **params):
        return self.call("GET", path, params=params)["data"]

    def patch(self, kind, id, attrs):
        self.call("PATCH", f"/v1/{kind}/{id}",
                  json={"data": {"type": kind, "id": id, "attributes": attrs}})

    def create(self, kind, attrs, rel_name, rel_type, rel_id):
        self.call("POST", f"/v1/{kind}", json={"data": {
            "type": kind, "attributes": attrs,
            "relationships": {rel_name: {"data": {"type": rel_type, "id": rel_id}}}}})


def one_locale(locs, what):
    hit = [l for l in locs if l["attributes"]["locale"] == LOCALE]
    return hit[0] if hit else None


def editable(items, what):
    ok = [i for i in items
          if (i["attributes"].get("appStoreState") or i["attributes"].get("state"))
          in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
              "METADATA_REJECTED", "WAITING_FOR_REVIEW", "INVALID_BINARY")]
    if not ok:
        sys.exit(f"no editable {what}; create a new version in App Store Connect first")
    return ok[0]


# ---------------------------------------------------------------- diff + push

def show(label, old, new):
    old = old or ""
    if old == new:
        print(f"  = {label}: unchanged")
        return False
    limit = LIMITS.get(label.split(".")[-1])
    size = f" ({len(new)}/{limit})" if limit else ""
    print(f"  ~ {label}{size}")
    if "\n" in new or len(new) > 70:
        print("      now: " + (f"{len(old)} chars" if old else "(empty)"))
        print("      new:\n" + "\n".join("        | " + l for l in new.splitlines()))
    else:
        print(f"      now: {old or '(empty)'}\n      new: {new}")
    return True


def changes(label, live_attrs, wanted):
    return {k: v for k, v in wanted.items()
            if show(f"{label}.{k}", (live_attrs or {}).get(k), v)}


def main():
    apply = "--apply" in sys.argv
    want = parse_listing(LISTING.read_text())
    for group in ("appInfo", "version"):
        for k, v in want[group].items():
            if k in LIMITS and len(v) > LIMITS[k]:
                sys.exit(f"{k} is {len(v)} characters; the limit is {LIMITS[k]}")
    if len(want["whatsNew"]) > LIMITS["whatsNew"]:
        sys.exit("What to Test is over 4000 characters")

    if not (apply or "--compare" in sys.argv):
        # Offline preview: no key, no network. Shown against empty, so every
        # field prints in full.
        for group in ("appInfo", "version", "beta"):
            print({"appInfo": "App information", "version": "App Store version",
                   "beta": "TestFlight test information"}[group])
            for k, v in want[group].items():
                show(f"{group}.{k}", None, v)
            print()
        print(f"Build {want['build']}: What to Test")
        show("build.whatsNew", None, want["whatsNew"])
        print("\nAll fields within their limits. Offline preview: nothing was read from or "
              "sent to App Store Connect.\n--compare diffs against what's live; --apply "
              "writes (both read the key from 1Password).")
        return

    asc = Asc()
    apps = asc.get("/v1/apps")
    if len(apps) != 1:
        sys.exit(f"expected one app, found {[a['attributes']['name'] for a in apps]}")
    app = apps[0]["id"]
    print(f"{apps[0]['attributes']['name']} ({apps[0]['attributes']['bundleId']})\n")
    todo = []

    info = editable(asc.get(f"/v1/apps/{app}/appInfos"), "app info")
    loc = one_locale(asc.get(f"/v1/appInfos/{info['id']}/appInfoLocalizations"), "app info")
    print("App information")
    diff = changes("appInfo", loc["attributes"], want["appInfo"])
    if diff:
        todo.append(lambda d=diff, i=loc["id"]: asc.patch("appInfoLocalizations", i, d))

    ver = editable(asc.get(f"/v1/apps/{app}/appStoreVersions"), "App Store version")
    loc = one_locale(asc.get(f"/v1/appStoreVersions/{ver['id']}/appStoreVersionLocalizations"),
                     "version")
    print(f"\nVersion {ver['attributes']['versionString']}")
    diff = changes("version", loc["attributes"], want["version"])
    if diff:
        todo.append(lambda d=diff, i=loc["id"]: asc.patch("appStoreVersionLocalizations", i, d))

    loc = one_locale(asc.get(f"/v1/apps/{app}/betaAppLocalizations"), "beta")
    print("\nTestFlight test information")
    diff = changes("beta", loc and loc["attributes"], want["beta"])
    if diff and loc:
        todo.append(lambda d=diff, i=loc["id"]: asc.patch("betaAppLocalizations", i, d))
    elif diff:
        todo.append(lambda d=diff: asc.create("betaAppLocalizations", {"locale": LOCALE, **d},
                                              "app", "apps", app))

    builds = [b for b in asc.get("/v1/builds", **{"filter[app]": app, "sort": "-uploadedDate",
                                                  "limit": 20})
              if b["attributes"]["version"] == want["build"]]
    if not builds:
        sys.exit(f"no build {want['build']} uploaded")
    build = builds[0]
    loc = one_locale(asc.get(f"/v1/builds/{build['id']}/betaBuildLocalizations"), "build")
    print(f"\nBuild {want['build']}: What to Test")
    diff = changes("build", loc and loc["attributes"], {"whatsNew": want["whatsNew"]})
    if diff and loc:
        todo.append(lambda d=diff, i=loc["id"]: asc.patch("betaBuildLocalizations", i, d))
    elif diff:
        todo.append(lambda d=diff, b=build["id"]: asc.create(
            "betaBuildLocalizations", {"locale": LOCALE, **d}, "build", "builds", b))

    if not todo:
        print("\nEverything already matches.")
    elif not apply:
        print(f"\nCompared: {len(todo)} write(s) pending. Re-run with --apply to send them.")
    else:
        for step in todo:
            step()
        print(f"\nApplied {len(todo)} write(s).")


if __name__ == "__main__":
    main()
