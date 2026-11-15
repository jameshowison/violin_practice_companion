# /// script
# requires-python = ">=3.10"
# dependencies = ["markdown"]
# ///
"""Build the stringlings.app website into build/site/.

    uv run scripts/build_site.py              # build
    uv run scripts/build_site.py --serve      # build, then serve on :8000

Each site/*.html (not starting with _) is a page body, wrapped in
site/_template.html; its first two lines are `<!-- title: ... -->` and
`<!-- description: ... -->`. privacy.html is built from docs/privacy.md, so the
policy has a single source. The icons are copied from the iOS asset catalog at
build time rather than committed again (repo_content_policy_test).

Deployed by .github/workflows/pages.yml on every push to main that touches it.
"""

import html
import re
import shutil
import sys
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "site"
OUT = ROOT / "build" / "site"
ICONS = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"

META = re.compile(r"<!--\s*(title|description):\s*(.*?)\s*-->\s*\n?")


def render(template: str, slug: str, title: str, description: str, body: str) -> str:
    return (
        template.replace("{title}", html.escape(title))
        .replace("{description}", html.escape(description))
        .replace("{slug}", slug)
        .replace("{body}", body.strip())
    )


def main() -> None:
    template = (SRC / "_template.html").read_text()
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    for page in sorted(SRC.glob("*.html")):
        if page.name.startswith("_"):
            continue
        text = page.read_text()
        meta = dict(META.findall(text))
        body = META.sub("", text)
        for key in ("title", "description"):
            if key not in meta:
                sys.exit(f"{page.name}: missing <!-- {key}: ... -->")
        (OUT / page.name).write_text(
            render(template, page.stem, meta["title"], meta["description"], body)
        )

    policy = markdown.markdown((ROOT / "docs/privacy.md").read_text())
    (OUT / "privacy.html").write_text(
        render(
            template,
            "privacy",
            "Stringlings Privacy Policy",
            "Stringlings collects no personal data and has no ads or analytics.",
            f'<article class="prose">\n{policy}\n</article>',
        )
    )

    shutil.copy(SRC / "style.css", OUT / "style.css")
    shutil.copy(ICONS / "Icon-App-1024x1024@1x.png", OUT / "icon-1024.png")
    shutil.copy(ICONS / "Icon-App-60x60@3x.png", OUT / "icon-180.png")
    # Custom domain for GitHub Pages (also set in the repo's Pages settings).
    (OUT / "CNAME").write_text("stringlings.app\n")

    print(f"built {len(list(OUT.iterdir()))} files into {OUT.relative_to(ROOT)}")

    if "--serve" in sys.argv:
        import functools
        import http.server

        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=OUT)
        print("serving http://localhost:8000")
        http.server.ThreadingHTTPServer(("127.0.0.1", 8000), handler).serve_forever()


if __name__ == "__main__":
    main()
