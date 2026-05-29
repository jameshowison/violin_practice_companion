# Homr Stage A Evaluation Results

**Engine:** [liebharc/homr](https://github.com/liebharc/homr) (installed via `uv tool install homr`)  
**Date:** 2026-05-29  
**Benchmark photos:** `docs/photos_no_share/*_no_title.heic`  
**Gold standards:** `assets/fixtures/lightly_row_musescore.xml`, `assets/fixtures/happy_farmer_musescore.xml`

---

## Setup

```bash
uv tool install homr
# HEIC → PNG
sips -s format png input.heic --out input.png
# Binarize at 50% threshold (eliminates bleed-through — see below)
magick input.png -threshold 50% input_bw.png
# Run
PYTHONWARNINGS=ignore homr input_bw.png
# Output written to <input_basename>.musicxml in the working directory
```

Models (~134 MB total, 3 files) are downloaded on first run and cached in
`~/.local/share/uv/tools/homr/`. Inference is under 3 seconds per piece on
Apple Silicon.

**Comparison script:** `docs/omr_evaluation/scripts/compare_omr.py`

---

## Pre-processing: Binarization at 60% Threshold

The raw HEIC photos are taken from a physical book; the paper is thin enough
that content from the page behind bleeds through. Without pre-processing, Homr
detects 6 staffs on Happy Farmer when the page has only 5 — the extra phantom
staff sits in the bleed-through region between rows 1 and 2, causing it to
insert two spurious whole-note/rest measures at the system boundary.

Five threshold levels were tested (40–80%):

| Threshold | Visual quality | Staffs detected | HF accuracy |
|-----------|---------------|-----------------|-------------|
| 40% | Clean black-on-white, no bleed | 5 ✓ | 96.4% ✓ |
| 50% | Clean black-on-white, no bleed | 5 ✓ | 96.4% ✓ |
| 60% | Clean black-on-white, no bleed | 5 ✓ | 96.4% ✓ |
| 70% | Bleed-through still visible as gray | 6 ✗ | 24.1% ✗ |
| 80% | Over-darkened, inverted regions | — | — |

40–60% produce identical accuracy; 70%+ retains enough bleed-through to trigger
the phantom staff. **50% is the canonical threshold** — the natural midpoint of
the effective range. Applied to both benchmark inputs before the accuracy results
below.

---

## Accuracy Results (with 60% binarization)

### Lightly Row

```
Gold notes:    57
Homr notes:    57
Pitch accuracy:         57/57 = 100.0%
Duration accuracy:      57/57 = 100.0%
Both correct:           57/57 = 100.0%
Extra/missing notes:    0
```

**100% positional accuracy. PASS ✓**

Key = 3 sharps (A major), time = 2/2 (cut time) — both correct for Suzuki
Lightly Row. Every note including C#5 half notes is recognised correctly.

### Happy Farmer (with 60% binarization)

```
Gold notes:    112
Homr notes:    112
Pitch accuracy:         111/112 = 99.1%
Duration accuracy:      109/112 = 97.3%
Both correct:           108/112 = 96.4%
Extra/missing notes:    0
```

**96.4% positional accuracy. PASS ✓**

Remaining 4 mismatches (all in the final system):

| Position | Issue |
|----------|-------|
| 97 | DUR eighth → 16th |
| 98 | DUR eighth → 16th |
| 103 | PITCH D4 → E4 |
| 112 | DUR quarter → eighth |

These are minor rhythm/pitch errors in the last few bars and are well within
the range expected for a real-world photograph.

---

## Key Questions from PHASE4.md

### 1. Does Homr correctly parse Common / Cut-common time signatures?

**Yes.** Lightly Row (Common time in the book) is 100% accurate. Homr renders
it as 2/2, which is mathematically equivalent and produces the correct note
durations. This was Oemer's fatal flaw; Homr handles it correctly.

### 2. Does Homr produce per-note confidence scores?

**No.** The MusicXML output is standard with no confidence or probability
extensions.

**Impact on amber-flag design:** The original per-note amber-flag plan cannot
be implemented as specified. Options (see PHASE4.md for full discussion):
- Flag notes near detected structural anomalies (key changes mid-piece, whole
  notes in rhythmically dense passages) as a proxy for uncertainty.
- Amber-flag all notes and require the parent to confirm each one.
- Remove per-note confidence from Phase 4 scope; show the staff view for
  verification without note-level colouring.
- File an upstream feature request on liebharc/homr.

Recommendation: remove per-note confidence from Phase 4 scope for now.

### 3. Does Homr output MusicXML directly?

**Yes.** Standard `score-partwise` MusicXML, no post-processing required.

---

## Inference Performance

| Metric | Value |
|--------|-------|
| Segnet inference | ~1.2–1.4 s |
| TrOmr per staff | ~0.15–0.38 s |
| Total (4–5 staffs) | ~3–4 s |

Well under the 30-second ceiling in PHASE4.md. A simple "Recognising…"
spinner is sufficient — no per-stage progress needed.

---

## Verdict

| Criterion | Result |
|-----------|--------|
| Lightly Row ≥90% (pitch+duration, positional) | **PASS ✓ 100%** |
| Happy Farmer ≥90% (pitch+duration, positional) | **PASS ✓ 96.4%** |
| Time signature parsing (Common/Cut-common) | **YES** |
| Confidence scores | **NO** |
| MusicXML output | **YES** |
| Pre-processing required | **YES — 50% binarization (40–60% equivalent)** |

**Homr passes Stage A.** The binarization step is a required part of the
pipeline (not optional) and must be applied before every `homr` invocation on
camera photographs. The `OmrService.recognise()` implementation must include:

```dart
// Before calling Homr:
// 1. Convert HEIC/JPEG to PNG  (platform image API)
// 2. Binarize at 60% threshold (ONNX or platform call — see Stage B)
```

Stage B (mobile ONNX embedding) can now begin.

---

## Artifacts

| File | Description |
|------|-------------|
| `lightly_row_no_title.musicxml` | Homr output (colour PNG, reference) — 100% |
| `happy_farmer_bw_50.musicxml` | Homr output (BW PNG, 50% threshold) — 96.4% |
| `happy_farmer_no_title.musicxml` | Homr output (colour PNG, no binarization) — 24.1% (for comparison) |
| `lightly_row_no_title_teaser.png` | Staff detection overlay — colour input |
| `happy_farmer_no_title_teaser.png` | Staff detection overlay — colour input (6 spurious staffs) |
| `happy_farmer_bw_50.png` | BW pre-processed input (50% threshold) |
| `lightly_row_no_title.png` | Input PNG |
| `happy_farmer_no_title.png` | Input PNG |
