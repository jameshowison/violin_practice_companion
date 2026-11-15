# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow"]
# ///
"""Put a caption above each raw App Store screenshot.

    uv run scripts/frame_screenshots.py            # every device folder in build/screenshots/raw/
    uv run scripts/frame_screenshots.py iphone     # just one

Reads   build/screenshots/raw/<device>/NN.png  (straight `simctl io screenshot`
        captures, already rotated if the sim was in landscape)
Writes  build/screenshots/out/<device>/NN.png  at exactly the App Store size
        for that device and orientation, RGB with no alpha (ASC rejects alpha).

Captions come from docs/app-store-listing.md, section "Screenshots": the table
row whose # is NN. The colours are the app icon's (scripts/app_icon/
stringlings_icon.mjs) and the font is the Playful skin's Nunito, from
assets/engine/fonts/. README, "App Store screenshots", has the whole procedure.
"""
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "build/screenshots/raw"
OUT = ROOT / "build/screenshots/out"
LISTING = ROOT / "docs/app-store-listing.md"
FONT = ROOT / "assets/engine/fonts/Nunito-ExtraBold.ttf"

# Portrait sizes App Store Connect takes for the 6.9" iPhone and 13" iPad
# slots; landscape is the same pair swapped.
SIZES = {"iphone": (1320, 2868), "ipad": (2064, 2752)}

PAPER_TOP, PAPER_BOTTOM = (0xFF, 0xF9, 0xEE), (0xF2, 0xE5, 0xCE)
INK = (0x2B, 0x23, 0x40)


def captions() -> dict[str, str]:
    md = LISTING.read_text()
    m = re.search(r"\n## Screenshots\n(.*?)(?=\n## |\Z)", md, re.S)
    if not m:
        sys.exit("listing: no '## Screenshots' section")
    rows = {}
    for line in m.group(1).splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if line.startswith("|") and len(cells) >= 2 and re.fullmatch(r"\d+[a-z]?", cells[0]):
            rows[cells[0].zfill(2)] = cells[1].replace("**", "")
    return rows


def gradient(size):
    w, h = size
    col = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        col.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(PAPER_TOP, PAPER_BOTTOM)))
    return col.resize(size)


def wrap(draw, text, font, width):
    lines, line = [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if draw.textlength(trial, font=font) <= width or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    return lines + [line]


def frame(raw: Path, caption: str, device: str) -> Image.Image:
    shot = Image.open(raw).convert("RGB")
    pw, ph = SIZES[device]
    size = (pw, ph) if shot.height >= shot.width else (ph, pw)
    W, H = size
    canvas = gradient(size)
    draw = ImageDraw.Draw(canvas)

    # Caption band: the top ~17% of the canvas, text centred in it.
    band = round(H * (0.17 if H > W else 0.16))
    font = ImageFont.truetype(str(FONT), round(min(W, H) * (0.072 if device == "iphone" else 0.05)))
    lines = wrap(draw, caption, font, W * 0.86)
    if len(lines) == 2:
        # Balance the two lines, so a short word isn't left alone under a long one.
        words = caption.split()
        splits = [(" ".join(words[:i]), " ".join(words[i:])) for i in range(1, len(words))]
        fits = [s for s in splits if max(draw.textlength(l, font=font) for l in s) <= W * 0.86]
        lines = list(min(fits, key=lambda s: abs(draw.textlength(s[0], font=font)
                                                 - draw.textlength(s[1], font=font))))
    line_h = font.size * 1.18
    y = (band - line_h * len(lines)) / 2 + band * 0.08
    for line in lines:
        draw.text((W / 2, y), line, font=font, fill=INK, anchor="ma")
        y += line_h

    # The capture, scaled to fit below the band, with rounded corners and a soft shadow.
    margin = round(min(W, H) * 0.06)
    box_w, box_h = W - 2 * margin, H - band - margin
    scale = min(box_w / shot.width, box_h / shot.height)
    sw, sh = round(shot.width * scale), round(shot.height * scale)
    shot = shot.resize((sw, sh), Image.LANCZOS)
    x, y = (W - sw) // 2, band + (box_h - sh) // 2
    radius = round(min(sw, sh) * 0.06)
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw - 1, sh - 1), radius, fill=255)

    shadow = Image.new("L", size, 0)
    blur = round(min(W, H) * 0.02)
    ImageDraw.Draw(shadow).rounded_rectangle((x, y + blur // 2, x + sw, y + sh + blur // 2), radius, fill=90)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas.paste(Image.new("RGB", size, INK), (0, 0), shadow)
    canvas.paste(shot, (x, y), mask)
    return canvas


def main():
    only = sys.argv[1:]
    text = captions()
    devices = [d for d in SIZES if not only or d in only]
    made = 0
    for device in devices:
        for raw in sorted((RAW / device).glob("*.png")):
            key = raw.stem.zfill(2)
            if key not in text:
                print(f"skip {device}/{raw.name}: no caption row '{raw.stem}' in the listing")
                continue
            out = OUT / device / raw.name
            out.parent.mkdir(parents=True, exist_ok=True)
            img = frame(raw, text[key], device)
            img.save(out, optimize=True)
            print(f"{device}/{raw.name}  {img.width}×{img.height}  “{text[key]}”")
            made += 1
    if not made:
        sys.exit(f"nothing framed; put captures in {RAW.relative_to(ROOT)}/<iphone|ipad>/NN.png")


if __name__ == "__main__":
    main()
