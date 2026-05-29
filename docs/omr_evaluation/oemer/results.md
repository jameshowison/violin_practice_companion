# Oemer Stage A Evaluation Results

**Engine:** [BreezeWhite/oemer](https://github.com/BreezeWhite/oemer) v0.1.5  
**Date:** 2026-05-29  
**Benchmark photos:** `docs/photos_no_share/*_no_title.heic`  
**Gold standards:** `assets/fixtures/lightly_row_musescore.xml`, `assets/fixtures/happy_farmer_musescore.xml`

---

## Setup

System Python 3.14 on macOS requires a venv (Homebrew blocks system-wide pip):

```bash
python3 -m venv /tmp/oemer_venv
/tmp/oemer_venv/bin/pip install oemer
```

**NumPy 2.x compatibility patch required.** Oemer 0.1.5 uses two removed aliases:

| File | Line | Fix |
|------|------|-----|
| `staffline_extraction.py` | 327 | `np.array(rr, dtype=np.int)` → `dtype=int` |
| `symbol_extraction.py` | 243 | `np.int(unit_size//2)` → `int(unit_size//2)` |

**Model download:** ~140 MB on first run (4 checkpoints). Cached in venv after that.

**Run command:**

```bash
sips -s format png input.heic --out input.png
PYTHONWARNINGS=ignore oemer input.png -o output_dir --save-cache 2>&1 | grep -E "^202[0-9]" | grep -v CoreML
```

---

## Photo Preparation Learnings

Three iterations of cropping were needed to isolate good input:

| Crop | Issue |
|------|-------|
| Full page | Oemer picks up notes from adjacent songs; 86 vs 57 gold for Lightly Row |
| Song only (with title) | Title text confuses Oemer — descender of 'g' in "Lightly" detected as a quarter notehead, inserting a spurious note at position 1 and cascading all positions |
| **Song only, no title (final)** | **Used for final benchmark** |

**Instruction for users:** crop to staff lines only, no title above the first staff.

No contrast filtering or binarization was needed — bleed-through from the back of the page was not detected as musical symbols.

---

## Gold Standard Fix

The Happy Farmer MuseScore XML (`assets/fixtures/happy_farmer_musescore.xml`) contains a
`<note print-object="no">` rest at position 1 — an invisible placeholder MuseScore adds
to fill the pickup measure's unused beats. The comparison script must skip
`print-object="no"` notes or the gold will be off by 1.

```python
for note in root.iter('note'):
    if note.get('print-object') == 'no':
        continue
```

---

## Accuracy Results (final, no-title crop, positional, no alignment tricks)

| Piece | Gold notes | Oemer notes | Pitch+Duration | Pitch only |
|-------|-----------|-------------|---------------|------------|
| Lightly Row | 57 | 56 | **30.4%** ❌ | 37.5% |
| Happy Farmer | 112 | 113 | **0%*** ❌ | 0%* |

*Happy Farmer positional 0% is caused by one spurious note at position 0 (C5/quarter before the anacrusis D4/eighth). Skip oemer[0] and the rest is 95%+ correct — see "Root cause" below.

**Neither piece passes the ≥90% target without workarounds.**

---

## Root Cause: Time Signature Misdetection

Both failures trace to the same underlying bug: **Oemer does not parse time signature symbols**.

### What Oemer does

In `constant.py` and `constant_min.py`, time signature glyphs are listed as a
segmentation class (`timeSigs`, label IDs 21–34). The ONNX segmentation model can
*detect* their pixel regions. However, searching the entire codebase:

```
grep -rn "timeSig\|time_sig\|TimeSig" oemer/*.py
```

The only matches are the two constant files. No code in `build_system.py`,
`symbol_extraction.py`, `rhythm_extraction.py`, or `ete.py` reads those labels
or uses them to set beats-per-measure. **Time signatures are detected visually but
silently discarded.**

### What happens instead

Oemer appears to infer beat structure purely from barline spacing and note groupings.
For both pieces, the time signature symbol is printed as a Common time 'C' (or
Cut-common '₵') — the teaser images show a yellow bounding box around the centre of
the symbol, indicating an unclassified detection. Without a known time signature,
Oemer's beat-inference misfires:

- **Lightly Row**: Half notes are dropped or split. The C#5/half at position 3 is
  entirely missing from the output; everything from position 3 onward is shifted or
  wrong. Only 30% positional accuracy.
- **Happy Farmer**: Mostly eighth notes, so beat inference works well. One spurious
  C5/quarter is inserted at position 0 (likely the Common-time 'C' itself being
  misclassified as a notehead). Removing it, the remaining 112 notes are 95%+ correct.

### Why this is unfixable via CLI configuration

There are no CLI flags or config files for Oemer that accept a time signature hint.
The fix would require either:
1. Patching `build_system.py` to consume the timeSig segmentation layer and set
   `beats` / `beat-type` accordingly — substantial internal work.
2. Masking the time signature region in the image before running Oemer, then
   post-processing the MusicXML to inject the correct `<time>` element.

Neither is appropriate for a mobile embedding. This is a known architectural gap
in Oemer; a bug report to the upstream repo is warranted.

---

## Artifacts

| File | Description |
|------|-------------|
| `lightly_row_no_title.musicxml` | Oemer output for Lightly Row (no-title crop) |
| `happy_farmer_no_title.musicxml` | Oemer output for Happy Farmer (no-title crop) |
| `lightly_row_no_title_teaser.png` | Detection overlay — yellow square on time sig visible |
| `happy_farmer_no_title_teaser.png` | Detection overlay — spurious note at position 0 visible |

---

## Verdict

**Oemer is not suitable as the OMR engine for this project** in its current form.
The time signature parsing gap is fundamental: any piece using Common or Cut-common
time (i.e., essentially all beginner violin method book pieces) will produce
unreliable output unless significant patching is applied.

**Next step:** Evaluate [liebharc/homr](https://github.com/liebharc/homr) as the
fallback engine specified in PHASE4.md. Homr is a transformer-based fork with
claimed better robustness; check whether it handles Common/Cut-common time
signatures correctly before running the same benchmark.
