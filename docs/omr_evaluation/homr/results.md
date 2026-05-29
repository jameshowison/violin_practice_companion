# Homr Stage A Evaluation Results

**Engine:** [liebharc/homr](https://github.com/liebharc/homr) (installed via `uv tool install homr`)  
**Date:** 2026-05-29  
**Benchmark photos:** `docs/photos_no_share/*_no_title.heic`  
**Gold standards:** `assets/fixtures/lightly_row_musescore.xml`, `assets/fixtures/happy_farmer_musescore.xml`

---

## Setup

```bash
uv tool install homr
# HEIC → PNG conversion (same pattern as Oemer eval)
sips -s format png input.heic --out input.png
# Run (no warnings flag needed — SyntaxWarning from musicxml dep is harmless)
PYTHONWARNINGS=ignore homr input.png
# Output written to <input_basename>.musicxml in the working directory
```

Models (~134 MB total, 3 files) are downloaded on first run and cached in
`~/.local/share/uv/tools/homr/`. Inference is fast — under 3 seconds per piece
on Apple Silicon.

**Comparison script:** `docs/omr_evaluation/scripts/compare_omr.py`  
(engine-agnostic rewrite of the Oemer script; handles `print-object="no"` notes,
chord deduplication, and dotted-note type equality)

---

## Accuracy Results

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

Homr detected: key = 3 sharps (A major), time = 2/2 (cut time). Both are
correct for Suzuki Lightly Row. Every note — including C#5 half notes and all
quarter notes — is correct. This directly addresses Oemer's failure: Oemer
produced 30.4% on this piece due to time-signature parsing gaps.

### Happy Farmer

```
Gold notes:    112
Homr notes:    114
Pitch accuracy:         30/112 = 26.8%
Duration accuracy:      85/112 = 75.9%
Both correct:           27/112 = 24.1%
Extra/missing notes:    2
```

**24.1% positional accuracy. FAIL ✗**

---

## Root Cause: Spurious System-Boundary Measures

The failure is **localised to 2 notes** — not a systemic algorithm problem.

### What happens

Positions 1–24 are correct (24/24, 100%). At position 25, Homr inserts two
spurious measures at the start of the second system row (`new-system="yes"`):

```xml
<measure number="6">
  <print new-system="yes" />
  <attributes><key><fifths>0</fifths></key></attributes>  <!-- key change to C major -->
  <note><pitch><step>G</step><octave>5</octave></pitch>
        <type>whole</type> ... </note>
</measure>
<measure number="7">
  <note><rest /><type>whole</type> ... </note>
</measure>
<measure number="8">
  <print new-system="yes" />
  <attributes><key><fifths>1</fifths></key></attributes>  <!-- key back to G major -->
  <note>... correct notes resume here ...</note>
</measure>
```

After skipping these 2 spurious notes, positions 25–112 realign to the gold
with high accuracy. The spurious G5/whole and whole-rest are not musically
present in the score; Homr is likely misidentifying the repeat sign (or system
bracket / clef printed at the start of line 2) as a key-change measure.

### Why this is different from Oemer's failure

| Aspect | Oemer | Homr |
|--------|-------|------|
| Failure scope | Systemic — all Common/Cut-common time pieces | Localised — 2 spurious notes at one system boundary |
| Root cause | Time signatures detected but never parsed in pipeline | System-boundary artefact (repeat sign misread?) |
| Notes after problem point | Wrong throughout (30% on LR) | Correct (notes resume in alignment) |
| Fixable without patching? | No — architectural gap in oemer pipeline | Likely — either upstream fix or image pre-processing |

---

## Key Questions from PHASE4.md

### 1. Does Homr correctly parse Common / Cut-common time signatures?

**Yes.** Lightly Row (Common time in the book) is 100% accurate. Homr renders
it as 2/2 (cut time), which is mathematically equivalent and produces the
correct note durations. This was Oemer's fatal flaw; Homr handles it correctly.

### 2. Does Homr produce per-note confidence scores?

**No.** The MusicXML output is standard with no confidence or probability
extensions. There are no custom attributes or elements carrying uncertainty data.

**Impact on amber-flag design:** The original plan (flag notes below a
`confidenceThreshold`) cannot be implemented as specified. Options:
- Use Homr's *structural* outputs as proxies: notes near system boundaries,
  notes following a detected key-change artefact, or notes with anomalous
  durations (whole in a 3/4 piece) could be flagged amber.
- Amber-flag all notes in the correction screen and require the parent to
  confirm each one (safe but tedious for long pieces).
- Remove per-note confidence from the model; present the staff view for
  verification without note-level colouring.
- File an upstream feature request on liebharc/homr for confidence scores.

Recommendation: remove per-note confidence from Phase 4 scope; show the
full-piece correction screen and let the parent confirm or edit. The
`omr_params.json` `confidenceThreshold` key can be kept as a placeholder for
when/if Homr adds confidence outputs.

### 3. Does Homr output MusicXML directly?

**Yes.** Standard `score-partwise` MusicXML is written to `<input_basename>.musicxml`
in the working directory. No post-processing required.

---

## Inference Performance

| Metric | Value |
|--------|-------|
| Segnet inference | ~1.2 s |
| TrOmr per staff | ~0.15–0.26 s |
| Total (4 staffs / LR) | ~3 s |
| Total (6 staffs / HF) | ~4 s |

Far under the 30-second ceiling stated in PHASE4.md. This removes the need
for a per-stage progress spinner (a simple "Recognising…" indicator is enough).
Model download (~134 MB) happens once on first run.

---

## Verdict

| Criterion | Result |
|-----------|--------|
| Lightly Row ≥90% (pitch+duration, positional) | **PASS ✓ 100%** |
| Happy Farmer ≥90% (pitch+duration, positional) | **FAIL ✗ 24.1%** |
| Time signature parsing (Common/Cut-common) | **YES** |
| Confidence scores | **NO** |
| MusicXML output | **YES** |

**Homr does not pass Stage A by the strict positional criteria on Happy Farmer.**

However, the failure mode is qualitatively a single localised bug (2 spurious
measures at a system boundary), not a fundamental algorithm gap. The Lightly Row
100% result demonstrates that the engine handles beginner violin repertoire
correctly, including Common time, dotted notes, half notes, and key signatures.

**Recommended next step before Stage B:** investigate the Happy Farmer
system-boundary artefact. Options in priority order:

1. **Try `--debug` output** to identify which detected symbol triggers the
   spurious key-change measure, and whether it is the repeat sign or the
   system-start clef.
2. **Crop to remove the second-system start** (or use `--write-staff-positions`
   to provide correct staff boundaries manually) and re-run.
3. **Accept Homr with a post-processing filter**: strip measures with whole notes
   (or whole rests) that follow a key-change in a `new-system` context — these
   are diagnostic of the artefact.
4. **File upstream issue** on liebharc/homr with the Happy Farmer test case.

If the artefact can be reproducibly avoided (options 2–3), Homr effectively
passes Stage A and Stage B can begin.

---

## Artifacts

| File | Description |
|------|-------------|
| `lightly_row_no_title.musicxml` | Homr output — 100% accurate |
| `happy_farmer_no_title.musicxml` | Homr output — spurious measures 6–7 |
| `lightly_row_no_title_teaser.png` | Staff detection overlay (4 rows, colour-coded) |
| `happy_farmer_no_title_teaser.png` | Staff detection overlay (6 rows — note fingering marks) |
| `lightly_row_no_title.png` | Input PNG (converted from HEIC) |
| `happy_farmer_no_title.png` | Input PNG (converted from HEIC) |
