"""Lyrics spike, steps 2-3: put OCR'd lyrics onto a scanned score's notes.

    python3 -I docs/omr_evaluation/scripts/lyrics_align_spike.py \
        ocr.json scan.musicxml [answer_key] [out.musicxml] [homr.log] [page.png]
    python3 -I lyrics_align_spike.py --template scan.musicxml homr.log out.gt.txt

answer_key is a filled-in template (.gt.txt) or gt.json; "-" for none.

ocr.json is from ocr.swift; scan.musicxml from homr (one `<print new-system>`
per system). Upstream Python homr drops slurs from its MusicXML (homr_flutter,
which the app uses, keeps them), so pass its stdout as homr.log to restore them
from the token dump. page.png (needs Pillow) lets it see extender lines, which
Vision does not report as text. See docs/lyrics_from_scans.md for what it found.

Pipeline:
  1. Lines: OCR observations clustered by y; a line is lyrics unless most of
     its tokens look like chord symbols. Margin measure numbers are dropped.
  2. Syllables: split on spaces and hyphens; merged words ("Wheremy") are split
     against /usr/share/dict/words, since this engraving kerns words together
     and Vision's per-character boxes are only word boxes.
  3. Notes: per system, every pitched onset that isn't a tie continuation.
     homr reports ties as slurs, so a slur-stop on the previous pitch counts.
  4. Alignment: per system, a monotone DP placing every syllable on a note.
     Leftover notes are skipped; a skip is cheap inside a slur (melisma) and
     cheap where the text has a wide gap (a missing syllable or an extender).
     Note x-positions are NOT used: on this page the lyrics are not set under
     their notes, so x would mislead.
"""
import json
import math
import os
import re
import sys
import xml.etree.ElementTree as ET

CHORD = re.compile(r"^([A-G][#b♯♭]?(m|maj|min|dim|aug|sus|M)?\d*)+$")
LABELS = {"intro", "chorus", "solo", "verse", "fine", "coda", "repeat", "d.s.",
          "d.c.", "segno", "al", "to", "time", "last", "3x", "2x"}
HOMOGLYPHS = str.maketrans("туоаесрхі", "myoaecpxi")  # Cyrillic Vision returns


def load_words():
    try:
        with open("/usr/share/dict/words") as f:
            words = {w.strip().lower() for w in f if len(w.strip()) > 1}
    except OSError:
        words = set()
    # web2 lacks plenty of plain words and is full of junk 2-letter ones.
    words = {w for w in words if len(w) > 2} | {
        "an", "as", "at", "be", "by", "do", "go", "he", "if", "in", "is", "it",
        "me", "my", "no", "of", "oh", "on", "or", "so", "to", "up", "us", "we"}
    return words | {"a", "i", "an", "and", "the", "to", "of", "my", "me", "is",
                    "in", "on", "at", "for", "home", "where", "there's", "that's"}


WORDS = load_words()


def is_word(w):
    """web2 has no inflections or contractions, so allow the common ones."""
    if "'" in w:
        base, _, tail = w.partition("'")
        return is_word(base) and tail in ("s", "m", "re", "ll", "d", "t", "ve")
    return (w in WORDS
            or (w.endswith("s") and w[:-1] in WORDS)
            or (w.endswith("ed") and (w[:-2] in WORDS or w[:-1] in WORDS))
            or (w.endswith("ing") and (w[:-3] in WORDS or w[:-3] + "e" in WORDS)))


# ── 1-2. Lyric lines and syllables ──────────────────────────────────────────

def lyric_lines(ocr):
    def texty(o):  # noteheads read as text: "........e", "•La lo", "1."
        text = re.sub(r"^\s*\d+\.?\s", "", o["text"])  # a verse number: "1. On"
        chars = [c for c in text if not c.isspace() and c not in "-–'’,._"]
        letters = sum(c.isalpha() for c in chars)
        return letters >= 1 and letters * 4 >= len(chars) * 3
    for o in ocr["observations"]:
        # A spaced bullet is a hyphen read as a dot ("Moun • tain").
        o["text"] = re.sub(r"(?<=\w) [•·] (?=\w)", " - ", o["text"].strip("|"))
    sure = [o for o in ocr["observations"] if o["conf"] >= 0.5 and texty(o)]
    # A low-confidence read is admitted only onto a line a confident one made:
    # alone, those are noteheads read as letters.
    unsure = [o for o in ocr["observations"] if o["conf"] < 0.5 and texty(o)]
    obs = sure + [o for o in unsure if any(
        abs((o["box"][1] + o["box"][3] / 2) - (q["box"][1] + q["box"][3] / 2)) < 8
        and o["box"][3] < 2 * q["box"][3] for q in sure)]
    # Cluster on the baseline (box bottom): a read that swallowed the notes
    # above it is tall, but still sits on its line. Each line is then one text
    # height tall, ending at its baseline.
    heights = sorted(o["box"][3] for o in obs)
    h = heights[len(heights) // 2]
    obs.sort(key=lambda o: o["box"][1] + o["box"][3])
    lines = []
    for o in obs:
        bottom = o["box"][1] + o["box"][3]
        if lines and bottom - lines[-1]["bottom"] < 0.6 * h:
            lines[-1]["obs"].append(o)
        else:
            lines.append({"bottom": bottom, "obs": [o]})
    for line in lines:
        line["top"], line["cy"] = line["bottom"] - h, line["bottom"] - h / 2
    out = []
    for line in lines:
        line["obs"].sort(key=lambda o: o["box"][0])
        toks = [t for o in line["obs"] for t in o["text"].split()]
        chordish = sum(bool(CHORD.match(t)) or t.lower() in LABELS or t.isdigit()
                       or set(t) <= set(".•|") for t in toks)
        letters = sum(c.isalpha() for t in toks for c in t)
        if re.search(r"\b(repeat|coda|d\.s\.|d\.c\.)\b", " ".join(toks).lower()):
            continue
        if chordish * 2 < len(toks) and letters >= 6:
            out.append(line)
    return out


class Rules:
    """Horizontal rules on the page (staff lines), from row darkness."""

    def __init__(self, page):
        self.page, self.px, self.W, self.dark = page, page.load(), page.width, {}

    def row(self, y):  # dark pixels across the page; scans are faint, so < 180
        if y not in self.dark:
            y = max(0, min(self.page.height - 1, y))
            self.dark[y] = sum(self.px[x, y] < 180 for x in range(0, self.W, 2)) * 2
        return self.dark[y]

    def ruled(self, y):  # a rule, tolerating a tilt that spreads it over rows
        return self.row(y) + self.row(y - 1) + self.row(y - 2) > 0.3 * self.W

    def peaks(self, lo, hi):
        """Thin rules in [lo, hi): unlike a band of lettering, a rule has light
        rows a few pixels either side. Adjacent rows are one rule."""
        out = []
        for y in range(lo, hi):
            d = self.row(y)
            if d > 0.2 * self.W and max(self.row(y - 3), self.row(y + 3)) < 0.5 * d:
                if not out or y - out[-1] > 3:
                    out.append(y)
        return out


def on_staff(line, rules):
    """Text with staff lines through it is noteheads read as letters. (One
    rule can be a text baseline or a long extender; two cannot.)"""
    return len(rules.peaks(int(line["top"]) + 3, int(line["bottom"]) + 6)) >= 2


def staff_above(line, lines, rules):
    """Scanning up from the line, is a staff the first thing met, before any
    other text? True for lyrics; false for credits, chord rows and the extra
    verses many songbooks print as plain stanzas below the music."""
    top = int(line["top"])
    others = [(l["top"], l["bottom"]) for l in lines if l is not line]
    for y in range(top - 3, max(3, top - 400), -1):
        if any(a <= y <= b for a, b in others):
            return False
        if rules.ruled(y):
            # Lettering can be dark too; a staff is a stack of thin rules.
            span = int(line["bottom"] - line["top"]) * 5
            return len(rules.peaks(max(3, y - span), y + 4)) >= 4
    return False


def verse_groups(lines, n_systems, page=None):
    """Lyric lines stacked close together are verses under one system; a group
    counts only if a staff sits directly above its first line. If there are
    still more groups than systems, the extras are at the top: credits."""
    if page is not None:
        rules = Rules(page)
        lines = [l for l in lines if not on_staff(l, rules)]
    hs = sorted(o["box"][3] for l in lines for o in l["obs"])
    h = hs[len(hs) // 2]
    def extent(l):
        return (min(o["box"][0] for o in l["obs"]),
                max(o["box"][0] + o["box"][2] for o in l["obs"]))

    def stacks_under(line, first):
        """A stacked verse spans the music like verse 1; the stanzas many books
        print after the music are indented and narrower."""
        (a0, a1), (b0, b1) = extent(first), extent(line)
        return abs(b0 - a0) < 0.1 * (a1 - a0) and (b1 - b0) > 0.6 * (a1 - a0)

    groups = []
    for line in lines:
        if groups and line["cy"] - groups[-1][-1]["cy"] < 2.2 * h \
                and stacks_under(line, groups[-1][0]):
            groups[-1].append(line)
        else:
            groups.append([line])
    if page is not None:
        groups = [g for g in groups if staff_above(g[0], lines, rules)]
    return groups[max(0, len(groups) - n_systems):]


def segment(part, hyphen_before, hyphen_after):
    """Split a run of merged words. The piece touching a hyphen may be a bare
    syllable ("lin"), so it alone may be a non-word."""
    low = part.lower().translate(HOMOGLYPHS)
    if is_word(low) or len(low) < 4 or (hyphen_before and hyphen_after):
        return [part]  # between two hyphens is one syllable ("-shion-")
    n = len(low)
    best = {0: (0.0, 0, [])}  # end -> (cost, -sum len^2, pieces)

    def ok(piece, start, end):
        if is_word(piece) or piece == "l":  # "l": Vision's capital I
            return 1.0
        if (start == 0 and hyphen_before) or (end == n and hyphen_after):
            # A bare syllable; long ones unlikely, one letter never.
            # Each letter not covered by a word costs, so dictionary words
            # are peeled off a run ("oldfasion" -> old + fasion).
            return 1 + 0.5 * len(piece) if len(piece) > 1 else None
        return None

    for end in range(1, n + 1):
        for start in range(max(0, end - 12), end):
            if start not in best:
                continue
            c = ok(low[start:end], start, end)
            if c is None:
                continue
            cost, sq, pieces = best[start]
            cand = (cost + c, sq - (end - start) ** 2, pieces + [(start, end)])
            if end not in best or cand[:2] < best[end][:2]:
                best[end] = cand
    if n not in best or len(best[n][2]) == 1:
        return [part]
    return ["I" if part[s:e] in ("l", "1") else part[s:e] for s, e in best[n][2]]


def syllables(line):
    """([(text, x_start, x_end, hyphen_after)] left to right, [extender_after]).
    "-" and "–" are hyphens; "_" and "—" are extender lines read as text."""
    out, ext = [], []
    for o in line["obs"]:
        x, _, w, _ = o["box"]
        # "time.I", "ride_With": words joined by a dot or an extender.
        text = re.sub(r"(?<=\w)([.,;])(?=[A-Za-z])", r"\1 ", o["text"].translate(HOMOGLYPHS))
        text = re.sub(r"(?<=\w)([_—])(?=\w)", r"\1 ", text)
        # x of each character, by proportion across the observation box.
        cx = lambda i: x + w * i / max(1, len(text))
        for m in re.finditer(r"\S+", text):
            tok, base = m.group(), m.start()
            if re.fullmatch(r"\d+\.?", tok) and (tok != "1" or not out):
                continue  # bar or verse number ("1. Chick-ens"), not the word I
            if not out and re.fullmatch(r"[Il1|]\.", tok):
                continue  # a line's first token "I." is the verse number "1."
            if re.fullmatch(r"[_—.,]+", tok):
                if ext:
                    ext[-1] = True
                continue
            if tok[0] in "-–" and out:  # "court -ing"
                out[-1][3] = True
            parts = [p for p in re.finditer(r"[^-–]+", tok)]
            for k, p in enumerate(parts):
                core = p.group().strip(".,;:!?_|—")
                if not core:
                    continue
                hb = k > 0
                ha = k < len(parts) - 1 or tok.rstrip(".,").endswith(("-", "–"))
                pieces = segment(core, hb, ha)
                pos = base + p.start()
                for j, piece in enumerate(pieces):
                    s = pos
                    pos += len(piece)
                    if piece in ("1", "/"):  # Vision's I, plain and italic
                        piece = "I"
                    out.append([piece, cx(s), cx(pos), ha and j == len(pieces) - 1])
                    ext.append(False)
                if re.search(r"[_—]", p.group()) and ext:
                    ext[-1] = True
            # A lone hyphen token ("me-mo - ry") joins its neighbours.
            if re.fullmatch(r"[-–—]+", tok) and out:
                out[-1][3] = True
    return [tuple(s) for s in out], ext


def ink_words(line, page, x0, x1):
    """Word-shaped patches of ink in a lyric line's text band, as (x0, x1).
    Lyrics are spaced out to sit under their notes, so on most pages words are
    separate patches. Hyphens, dots and extender lines are too short to count."""
    h = line["bottom"] - line["top"]
    px = page.load()
    # Find the x-height band from the line's own row profile: every letter has
    # ink there, while extenders and underscores sit on or below the baseline
    # (they would join a word to the blank after it), and a hyphen is a sliver.
    lo, hi = int(line["top"]) - 4, int(line["bottom"]) + 8
    prof = [sum(px[x, y] < 120 for x in range(max(0, int(x0)), min(page.width, int(x1))))
            for y in range(lo, hi)]
    dense = [i for i, v in enumerate(prof) if v >= 0.4 * max(prof or [0])]
    if not dense:
        return []
    y0, y1 = lo + dense[0], lo + dense[-1]  # x-height top .. baseline (exclusive)
    band = max(1, y1 - y0)
    # Columns join a word by ink anywhere from ascender height down to the
    # baseline, so a T's crossbar or an apostrophe ("I'm") holds a word
    # together; but only x-height ink counts toward the word's height.
    asc = y0 - int(0.7 * band)
    cols = []
    for x in range(max(0, int(x0)), min(page.width, int(x1))):
        if not any(px[x, y] < 120 for y in range(asc, y1)):
            cols.append(None)
            continue
        ys = [y for y in range(y0, y1) if px[x, y] < 120]
        cols.append((x, min(ys), max(ys)) if ys else (x, y1, y0))
    blobs, cur, gap = [], None, 0
    for c in cols + [None]:
        if c:
            if cur and gap < 0.35 * h:
                cur = [cur[0], c[0], min(cur[2], c[1]), max(cur[3], c[2])]
            else:
                if cur:
                    blobs.append(cur)
                cur = [c[0], c[0], c[1], c[2]]
            gap = 0
        else:
            gap += 1
    if cur:
        blobs.append(cur)
    # Letters fill most of the band; hyphens and dots don't. Nothing wider than
    # a long word (that is a rule or a staff line crossing the band).
    return [(a, b + 1) for a, b, top, bot in blobs
            if bot - top >= 0.5 * band and 1 <= b - a <= 8 * h]


def unread_words(line, page, left, right):
    """Ink that no recognised word accounts for: words Vision dropped. Within
    each Vision box, its words are matched to the patches inside it by order
    and width (a box can hold a word its text leaves out); patches outside
    every box were never seen. Returns the (x0, x1) of each."""
    if page is None:
        return []
    blobs = ink_words(line, page, left, right)
    boxes = [(o["box"][0], o["box"][0] + o["box"][2], o["text"]) for o in line["obs"]]
    unread = [b for b in blobs
              if not any(a <= (b[0] + b[1]) / 2 <= z for a, z, _ in boxes)]
    for a, z, text in boxes:
        inside = [b for b in blobs if a <= (b[0] + b[1]) / 2 <= z]
        # Words as printed: Vision runs some together ("gumare"), so split them.
        words = [len(p) for t in re.findall(r"[^\s\-–—_]+", text) if re.search(r"\w", t)
                 for p in segment(t.strip(".,;:!?'’\"()"), False, False)]
        if not words or len(inside) <= len(words):
            continue
        k = sum(z2 - a2 for a2, z2 in inside) / max(1, sum(words))  # px per char
        r = lambda c, w: abs(math.log(max(w, 1) / max(k * c, 1)))
        # DP: words onto patches in order; a patch may go unmatched (cost 0.8);
        # two words may share a patch (kerned together).
        INF = math.inf
        W, B = len(words), len(inside)
        D = [[INF] * (B + 1) for _ in range(W + 1)]
        bk = [[None] * (B + 1) for _ in range(W + 1)]
        D[0][0] = 0
        for i in range(W + 1):
            for j in range(B + 1):
                if D[i][j] == INF:
                    continue
                w = (inside[j][1] - inside[j][0]) if j < B else 0
                moves = []
                if j < B:
                    moves.append((i, j + 1, 0.8, "skip"))
                if i < W and j < B:
                    moves.append((i + 1, j + 1, r(words[i], w), "one"))
                if i + 1 < W and j < B:
                    moves.append((i + 2, j + 1, r(words[i] + words[i + 1], w) + 0.2, "two"))
                for ni, nj, c, m in moves:
                    if D[i][j] + c < D[ni][nj]:
                        D[ni][nj], bk[ni][nj] = D[i][j] + c, m
        i, j = W, B
        while i or j:
            m = bk[i][j]
            if m is None:
                break
            if m == "skip":
                unread.append(inside[j - 1])
            i, j = {"skip": (i, j - 1), "one": (i - 1, j - 1), "two": (i - 2, j - 1)}[m]
    return sorted(unread)


def with_unread(sy, text_ext, unread):
    """Insert a "?" syllable for each unread word, in x order."""
    items = [(s, e) for s, e in zip(sy, text_ext)]
    items += [(("?", a, b, False), False) for a, b in unread]
    items.sort(key=lambda it: it[0][1])
    return [s for s, _ in items], [e for _, e in items]


def extenders(line, sylls, right, page, text_ext=None):
    """Per syllable: is the space after it (to the next syllable, or to the
    line's end) crossed by a thin horizontal stroke? That is an extender — the
    syllable is held — not a missing word."""
    if page is None:
        return list(text_ext or [False] * len(sylls))
    y0, y1 = int(line["top"]), int(line["bottom"]) + 4
    out = []
    for i, (_, _, end, _) in enumerate(sylls):
        nxt = sylls[i + 1][1] if i + 1 < len(sylls) else right
        x0, x1 = int(end) + 3, int(nxt) - 3
        if x1 - x0 < 15:
            out.append(False)
            continue
        if text_ext and text_ext[i]:
            out.append(True)
            continue
        best = 0
        for y in range(y0, min(y1, page.height)):
            run = longest = 0
            for x in range(x0, x1):
                if page.getpixel((x, y)) < 128:
                    run += 1
                    longest = max(longest, run)
                else:
                    run = 0
            best = max(best, longest)
        # A hyphen is a short stroke; an extender is longer than the text is tall.
        out.append(best >= 0.5 * (x1 - x0) and best >= 1.2 * (y1 - y0 - 4))
    return [a or b for a, b in zip(out, text_ext or out)]


VOWELS = re.compile(r"[aeiouy]+", re.I)


def polysyllable(text):
    """A non-word with two vowel groups, e.g. "fasion" where Vision dropped the
    hyphen in "fa-shion". A trailing silent "-ed"/"-es" doesn't count."""
    t = re.sub(r"(?<=[^td])e[ds]$", "", text.lower())
    return not is_word(text.lower()) and len(VOWELS.findall(t)) >= 2


def split_syllable(text):
    """Hyphenate at the first vowel-consonant-vowel: V-CV, or VC-CV."""
    groups = list(VOWELS.finditer(text))
    a, b = groups[0].end(), groups[1].start()
    cut = a if b - a <= 1 else a + 1
    return text[:cut], text[cut:]


# ── 3. Notes ────────────────────────────────────────────────────────────────

def lyricable_notes(root):
    """[[(note_element, measure_no, slur_inner)]] per system."""
    part = root.find("part")
    systems, prev_pitch, prev_slur_open = [[]], None, False
    for mi, m in enumerate(part.findall("measure")):
        pr = m.find("print")
        if mi and pr is not None and pr.get("new-system") == "yes":
            systems.append([])
        for n in m.findall("note"):
            if n.find("chord") is not None:
                continue
            p = n.find("pitch")
            if p is None:
                prev_pitch = None
                continue
            pitch = (p.findtext("step"), p.findtext("alter"), p.findtext("octave"))
            slurs = [s.get("type") for s in n.findall("notations/slur")]
            ties = [t.get("type") for t in n.findall("tie")]
            tie_cont = "stop" in ties or ("stop" in slurs and pitch == prev_pitch)
            if not tie_cont:
                systems[-1].append((n, m.get("number"), prev_slur_open, quarters(n)))
            if "start" in slurs:
                prev_slur_open = True
            elif "stop" in slurs:
                prev_slur_open = "start" in slurs
            prev_pitch = pitch
    return systems


def inject_slurs(root, log_text):
    """Copy slurStart/slurStop from homr's token dump onto the notes, in order."""
    m = re.search(r"Writing XML \[\[(.*)\]\]", log_text)
    toks = [t.strip() for t in m.group(1).split(",")] if m else []
    toks = [t for t in toks if t.startswith(("note_", "rest_"))]
    notes = [n for n in root.iter("note") if n.find("chord") is None]
    if len(toks) != len(notes):
        print(f"homr.log: {len(toks)} tokens for {len(notes)} notes — slurs not restored")
        return
    for n, t in zip(notes, toks):
        art = t.split()[3] if len(t.split()) > 3 else ""  # rhythm pitch accidental ARTIC position
        for kind in ("slurStart", "slurStop"):
            if kind in art:
                nt = n.find("notations")
                if nt is None:
                    nt = ET.SubElement(n, "notations")
                ET.SubElement(nt, "slur", type="start" if kind == "slurStart" else "stop")


TYPE_Q = {"whole": 4, "half": 2, "quarter": 1, "eighth": 0.5, "16th": 0.25, "32nd": 0.125}


def quarters(n):
    q = TYPE_Q.get(n.findtext("type"), 1)
    return q * (2 - 0.5 ** len(n.findall("dot")))


# ── 4. Alignment ────────────────────────────────────────────────────────────

def align(sylls, notes, left, right, ext=None):
    """Monotone DP: every syllable on its own note, leftover notes skipped.
    [left, right] is the x-extent of lyric text on the page, so blank space
    after the last syllable reads as missing words. (Not before the first: a
    line's indent depends on its clef and pickup, so says nothing.)
    Returns list of note index per syllable, or None if impossible."""
    S, N = len(sylls), len(notes)
    if S == 0:
        return None
    unit = sorted(e - s for _, s, e, _ in sylls)[S // 2] or 1
    gap = [max(0.0, sylls[i + 1][1] - sylls[i][2]) for i in range(S - 1)]
    gap.append(max(0.0, right - sylls[-1][2]))
    poly = [polysyllable(t) for t, _, _, _ in sylls]

    def skip_cost(i, j):  # skipping note j after syllable i (i = -1: leading)
        # A melisma: inside a slur, or under the held syllable's extender.
        held = notes[j][2] or (i >= 0 and ext and ext[i])
        c = (0.25 if held else 1.0) * notes[j][3] ** 0.5  # unsung long notes are rare
        if i >= 0 and poly[i]:
            c *= 0.2  # the next note probably carries this word's lost syllable
        if i < 0 or (ext and ext[i]):
            return c  # an extender's blank is not a missing word; nor is an indent
        return c / (1 + (gap[i] / unit) ** 2)

    def merge_cost(i):  # syllable i shares syllable i-1's note
        a, b = sylls[i - 1][0].lower(), sylls[i][0].lower()
        base = 0.3 if not is_word(a) and not is_word(b) and not sylls[i - 1][3] else 3.0
        return base + gap[i - 1] / unit  # halves of one syllable nearly touch

    INF = math.inf
    # D[i][j]: syllables 0..i-1 placed within notes 0..j-1.
    D = [[INF] * (N + 1) for _ in range(S + 1)]
    back = [[None] * (N + 1) for _ in range(S + 1)]
    D[0][0] = 0.0
    for i in range(S + 1):
        for j in range(N + 1):
            if D[i][j] == INF:
                continue
            if j < N:
                c = D[i][j] + skip_cost(i - 1, j)
                if c < D[i][j + 1]:
                    D[i][j + 1], back[i][j + 1] = c, "skip"
                if i < S and D[i][j] < D[i + 1][j + 1]:
                    D[i + 1][j + 1], back[i + 1][j + 1] = D[i][j], "place"
            # Vision split one syllable in two ("shi on"): share the note.
            if 0 < i < S and back[i][j] in ("place", "merge"):
                c = D[i][j] + merge_cost(i)
                if c < D[i + 1][j]:
                    D[i + 1][j], back[i + 1][j] = c, "merge"
    if D[S][N] == INF:
        return None
    i, j, placed = S, N, [None] * S
    while i or j:
        if back[i][j] == "place":
            placed[i - 1] = j - 1
            i, j = i - 1, j - 1
        elif back[i][j] == "merge":
            placed[i - 1] = j - 1
            i -= 1
        else:
            j -= 1
    return placed


def add_lyric(note, text, syllabic, verse=1):
    lyr = ET.SubElement(note, "lyric", number=str(verse))
    ET.SubElement(lyr, "syllabic").text = syllabic
    ET.SubElement(lyr, "text").text = text


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower().translate(HOMOGLYPHS))


QMARKS = [0, 0]  # "?" placeholders: [on a note that needs a word, on one that doesn't]


def score(pred, want):
    """(exact, close, scored, marks) for one verse of one system."""
    ex = fz = sc = 0
    marks = []
    for p, w in zip(pred, want):
        if p == "?" and w != "?":
            QMARKS[0 if w else 1] += 1  # on a note that needs a word / that doesn't
        if w == "?":
            marks.append("·")
            continue
        sc += 1
        a, b = norm(p), norm(w)
        if a == b:
            ex += 1; fz += 1; marks.append(p or "_")
        elif a and b and ((min(len(a), len(b)) >= 3 and (a in b or b in a))
                          or sum(x != y for x, y in zip(a, b)) + abs(len(a) - len(b)) <= 2):
            fz += 1; marks.append(f"~{p}")
        else:
            marks.append(f"✗{p or '_'}≠{w or '_'}")
    return ex, fz, sc, marks


# Lyrics are usually copyrighted. By default the report is numbers only, so
# running this (by hand or by an agent) never copies lyric text anywhere.
# LYRICS_SHOW=1 prints the text too, for a person looking locally.
SHOW = os.environ.get("LYRICS_SHOW") == "1"


def write_template(systems, path):
    """A fill-in answer key: one row per lyric-bearing note, syllables typed
    after the bars (one column per verse). Blank = no syllable, ? = unscored."""
    with open(path, "w") as f:
        f.write("# One row per note that can carry a syllable (ties excluded).\n"
                "# Type each verse's syllable after a '|':  12  D5 quarter | v1 | v2\n"
                "# Leave blank for no syllable; '?' to leave a note unscored.\n")
        for k, notes in enumerate(systems):
            f.write(f"\n# system {k + 1}\n")
            for n, m, _, _ in notes:
                p = n.find("pitch")
                acc = {"1": "#", "-1": "b"}.get(p.findtext("alter") or "", "")
                f.write(f"{m:>4}  {p.findtext('step')}{acc}{p.findtext('octave'):<3}"
                        f"{n.findtext('type'):<8}|\n")


def read_template(path):
    """The filled-in template, as gt.json's shape: per system, per verse."""
    systems = []
    for line in open(path):
        if line.startswith("# system"):
            systems.append([])
        elif systems and "|" in line and not line.startswith("#"):
            cells = [c.strip() for c in line.split("|")[1:]]
            systems[-1].append([c or None for c in cells] or [None])
    out = []
    for rows in systems:
        nv = max((len(r) for r in rows), default=1)
        out.append([[r[v] if v < len(r) else None for r in rows] for v in range(nv)])
    return out


def main():
    if sys.argv[1] == "--template":  # --template scan.musicxml homr.log out.gt.txt
        root = ET.parse(sys.argv[2]).getroot()
        inject_slurs(root, open(sys.argv[3]).read())
        write_template(lyricable_notes(root), sys.argv[4])
        print(f"wrote {sys.argv[4]}")
        return
    ocr = json.load(open(sys.argv[1]))
    xml_path = sys.argv[2]
    gt = None
    if len(sys.argv) > 3 and sys.argv[3] != "-":
        gt = read_template(sys.argv[3]) if sys.argv[3].endswith(".txt") \
            else json.load(open(sys.argv[3]))
    out_path = sys.argv[4] if len(sys.argv) > 4 else None
    log_path = sys.argv[5] if len(sys.argv) > 5 else None
    page = None
    if len(sys.argv) > 6:
        from PIL import Image
        page = Image.open(sys.argv[6]).convert("L")

    root = ET.parse(xml_path).getroot()
    if log_path:
        inject_slurs(root, open(log_path).read())
    systems = lyricable_notes(root)
    lines = lyric_lines(ocr)
    groups = verse_groups(lines, len(systems), page)
    left = min(o["box"][0] for l in lines for o in l["obs"])
    right = max(o["box"][0] + o["box"][2] for l in lines for o in l["obs"])
    print(f"{len(lines)} lyric lines in {len(groups)} groups, {len(systems)} systems")
    totals = [0, 0, 0]  # exact, close, scored
    # LYRICS_ALIGN=global: one stream of verse-1 syllables against every note in
    # the piece, no system boundaries. Lines are laid end to end in x, so the
    # gap across a line break is the blank after one line plus the indent of
    # the next. (Per-system is the default.)
    preset = {}
    if os.environ.get("LYRICS_ALIGN") == "global":
        all_sy, all_ext, all_notes, owner, offset = [], [], [], [], 0.0
        for k, (group, notes) in enumerate(zip(groups, systems)):
            sy, text_ext = with_unread(*syllables(group[0]),
                                       unread_words(group[0], page, left, right))
            all_ext += extenders(group[0], sy, right, page, text_ext)
            all_sy += [(t, x0 + offset, x1 + offset, ha) for t, x0, x1, ha in sy]
            owner += [k] * len(sy)
            all_notes += [(k, j, n) for j, n in enumerate(notes)]
            offset += right - left
        placed = align(all_sy, [n for _, _, n in all_notes], left, right + offset - (right - left),
                       all_ext) or []
        # Each syllable goes with the system its note is in, wherever it was read.
        for syl, g in zip(all_sy, placed):
            nk, j, _ = all_notes[g]
            sy_k, pl_k = preset.setdefault(nk, ([], []))
            sy_k.append(syl)
            pl_k.append(j)

    for k, (group, notes) in enumerate(zip(groups, systems)):
        want_sys = gt[k] if gt and k < len(gt) else []
        # A system's ground truth is one verse (a list of syllables) or several.
        if want_sys and not isinstance(want_sys[0], list):
            want_sys = [want_sys]
        print(f"\nsystem {k + 1}: {len(notes)} notes, {len(group)} verse(s)")
        for v, line in enumerate(group):
            sy, text_ext = with_unread(*syllables(line), unread_words(line, page, left, right))
            ext = extenders(line, sy, right, page, text_ext)
            placed = align(sy, notes, left, right, ext)
            if v == 0 and preset:
                sy, placed = preset.get(k, ([], []))
            # (note index, text, hyphen_after), splitting a polysyllable over
            # the free note after it.
            flat = []
            for k2, ((text, _, _, ha), j) in enumerate(zip(sy, placed or [])):
                nxt = placed[k2 + 1] if k2 + 1 < len(sy) else len(notes)
                if flat and flat[-1][0] == j:  # merged: one syllable, read in two
                    flat[-1] = (j, flat[-1][1] + text, ha)
                elif polysyllable(text) and nxt > j + 1:
                    a, b = split_syllable(text)
                    flat += [(j, a, True), (j + 1, b, ha)]
                else:
                    flat.append((j, text, ha))
            pred = [None] * len(notes)
            prev_ha = False
            for j, text, ha in flat:
                pred[j] = text
                syl = ("middle" if prev_ha else "begin") if ha else ("end" if prev_ha else "single")
                add_lyric(notes[j][0], text, syl, verse=v + 1)
                prev_ha = ha
            read = " ".join(t + ("-" if ha else "") + ("___" if e else "")
                            for (t, _, _, ha), e in zip(sy, ext))
            print(f"  v{v + 1} {len(sy)} syl, {sum(ext)} extenders"
                  f"{'' if placed else '  FAILED'}{': ' + read if SHOW else ''}")
            if v < len(want_sys):
                want = want_sys[v]
                if len(want) != len(notes):
                    print(f"     ground truth has {len(want)} notes — not scored")
                    continue
                ex, fz, sc, marks = score(pred, want)
                totals[0] += ex; totals[1] += fz; totals[2] += sc
                if SHOW:
                    print(f"     {' '.join(marks)}")
                print(f"     exact {ex}/{sc}, close {fz}/{sc}")
    if gt and totals[2]:
        e, f, n = totals
        print(f"\nTOTAL exact {e}/{n} ({100*e/n:.0f}%), close {f}/{n} ({100*f/n:.0f}%), "
              f"? right {QMARKS[0]}, ? wrong {QMARKS[1]}")
    if out_path:
        ET.ElementTree(root).write(out_path, encoding="UTF-8", xml_declaration=True)
        print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
