# Phase 4: OMR Scanning Pipeline

## Prerequisites

Phase 3 complete. The following are assumed stable:

- `PieceRepository` saves user-imported pieces to the app documents directory
  (the hook for this was noted in Phase 1; Phase 3 wires it up for section
  sidecars; Phase 4 adds full-piece import)
- `StaffView` (OSMD WebView) accepts per-note colour overrides via JavaScript
  bridge (new capability added in this phase)
- `ParsedPiece` and `NoteEvent` data models unchanged

## Goal

A parent photographs a page from their violin method book. The app runs on-device
OMR, produces a MusicXML representation, shows a re-rendered staff view for
verification, highlights uncertain notes in amber so the parent knows exactly
which notes to check, and saves the corrected piece to the library. Fully offline
at every step.

Long inference time (>30 seconds) is acceptable — this is a one-time operation
per piece. Speed is not a goal; correctness and uncertainty signalling are.

---

## Additional Stack

| Concern | Choice |
|---------|--------|
| OMR engine | ~~Oemer~~ → **Homr ([liebharc/homr](https://github.com/liebharc/homr))** — see evaluation below |
| Web inference | Local Homr HTTP server (Python subprocess on the host machine; Chrome sandbox blocks in-process subprocess calls) |
| Mobile inference | ONNX Runtime Mobile + C++ orchestration layer (see Stage B notes below) |
| Camera / file picker | `image_picker` Flutter plugin |
| File I/O | `path_provider` (already used) |

**Engine selection rationale (updated):** Oemer was evaluated against both benchmark
pieces and failed Stage A due to a fundamental architectural gap: time signature
symbols (Common 'C', Cut-common '₵') are detected by the segmentation model but
**never parsed** — no code in the pipeline reads them to set beats-per-measure.
This causes half-note misdetection and spurious notehead insertion on any standard
beginner violin piece. Full findings: `docs/omr_evaluation/oemer/results.md`.

Homr is a transformer-based fork of Oemer with claimed better robustness on
real-world image quality. It must now pass Stage A before Stage B begins.

**Audiveris** is not used: it is a Java/Swing desktop application (not
embeddable on mobile), and its AGPL license may conflict with GPL + F-Droid
distribution. See "Considered But Decided Against" below.

---

## Additional Lookup Tables

### `assets/lookup_tables/omr_params.json`

```json
{
  "comment": "OMR recognition parameters. confidenceThreshold: notes with confidence below this value are flagged amber in the correction screen. Adjust to trade false-positive warnings against missed errors.",
  "confidenceThreshold": 0.75
}
```

No other OMR constants appear in Dart source code.

---

## Stage A — Benchmark Before Mobile Embedding

### Oemer: FAILED ✗

Oemer was evaluated. Full findings in `docs/omr_evaluation/oemer/results.md`.
Summary: time signature symbols are segmented but never parsed; any piece in
Common or Cut-common time produces unreliable note durations. Lightly Row scored
30% positional accuracy; Happy Farmer was 0% positional (95% after removing one
spurious note). Engine rejected.

### Homr: EVALUATED — system-boundary artefact on Happy Farmer

Run [liebharc/homr](https://github.com/liebharc/homr) against the same benchmark.

**Benchmark inputs** (crop to staff lines, no title above first staff):

```
docs/photos_no_share/lightly_row_from_book_crop_no_title.heic
docs/photos_no_share/happy_farmer_from_book_crop_no_title.heic
```

**Gold standards** (exclude `print-object="no"` notes when parsing):

```
assets/fixtures/lightly_row_musescore.xml
assets/fixtures/happy_farmer_musescore.xml
```

**Accuracy target**: ≥90% of notes correct (pitch + duration), positional
(no alignment offset tricks), on both pieces.

**Key questions for Homr:**
1. Does it correctly parse Common / Cut-common time signatures?
2. Does it produce per-note confidence scores (Oemer did not)?
3. Does it output MusicXML directly, or require post-processing?

Store results in `docs/omr_evaluation/homr/results.md` using the same format
as the Oemer results. Do not proceed to Stage B until Homr passes Stage A or
a different engine decision is made.

**Setup notes from Oemer evaluation (likely applicable to Homr):**
- Use a Python venv; system Python on macOS is Homebrew-managed
- Convert HEIC → PNG via `sips` before running
- Suppress sklearn/onnxruntime warnings: `PYTHONWARNINGS=ignore` +
  `grep -E "^202[0-9]" | grep -v CoreML` on output

---

## Data Model

```dart
class RecognizedNote {
  final String pitch;        // "D5", "A4", "R" (rest) — same as NoteEvent.pitch
  final NoteValue noteValue;
  final bool dotted;
  final bool isRest;
  final double confidence;   // 0.0–1.0 from OMR engine; below threshold → amber
}

class OmrResult {
  final String keySignature;        // e.g. "D major"
  final int keyFifths;
  final int beatsPerMeasure;
  final List<List<RecognizedNote>>  // outer = measures, inner = notes
      measures;
  final double overallConfidence;   // mean confidence across all notes
}
```

`OmrResult` is converted to `ParsedPiece` (via existing services) once the
parent accepts the correction screen.

---

## `OmrService` Interface

Follows the existing conditional-import pattern (`staff_view.dart`,
`playback_service.dart`).

```dart
// omr_service.dart — conditional import dispatcher
abstract class OmrService {
  Future<OmrResult> recognise(File imageFile);
  bool get isSupported;   // false on web
}
```

```dart
// omr_service_io.dart — Android / iOS / macOS
// Calls ONNX Runtime Mobile via Dart FFI with the Oemer model bundle
class OmrServiceImpl implements OmrService {
  final bool isSupported = true;

  @override
  Future<OmrResult> recognise(File imageFile) async { ... }
}
```

```dart
// omr_service_web.dart — web stub
class OmrServiceImpl implements OmrService {
  final bool isSupported = false;

  @override
  Future<OmrResult> recognise(File imageFile) =>
      throw UnsupportedError('OMR is not available in the web build. '
          'Use the mobile app to scan a piece.');
}
```

No `dart:io` in `omr_service.dart` or `omr_service_web.dart`.
No `dart:html` in `omr_service_io.dart`.

---

## ONNX Model Bundle

Homr's models are **already in ONNX format** — no export step required. They
ship inside the `homr` Python package and are downloaded on first run:

```
assets/omr_models/
  segnet_*.onnx          (55 MB) — CNN pixel segmentation, 320×320 sliding window
  encoder_*.onnx         (50 MB) — ConvNext encoder: image strip → context vector
  decoder_*.onnx         (45 MB) — Autoregressive transformer decoder: context → note tokens
```

Total: **~150 MB**. Acceptable as bundled assets; document in build notes for
APK/IPA size impact.

The models use `onnxruntime` directly (no PyTorch at runtime). FP32 variants
are used for CPU inference (mobile); FP16 variants exist for CUDA/GPU and are
not needed on mobile.

One item to verify before Stage B commit: the decoder uses a dynamic KV-cache
(`cache_in0..N` / `cache_out0..N`, growing each autoregressive step up to
`max_seq_len=608`). ONNX Runtime Mobile supports dynamic shapes in principle;
test with a real staff-strip image before assuming compatibility.

### Two-layer architecture

Homr's pipeline has two distinct layers:

**Layer 1 — ONNX inference** (the three models above): fully portable via
ONNX Runtime Mobile.

**Layer 2 — Orchestration** (~15 Python modules using OpenCV + NumPy):
image preprocessing (autocrop, CLAHE), sliding-window tiling, contour/bounding-
box detection, staff line detection and dewarping, barline detection, per-staff
encoder+decoder calls, token-sequence → note-position mapping, and MusicXML
generation. None of this is in ONNX.

For mobile embedding, the orchestration must be ported. Two realistic options:

| Option | Approach | Notes |
|--------|----------|-------|
| **C++ wrapper** | Rewrite orchestration in C++; link OpenCV for mobile + ONNX RT; expose one FFI function `run_homr(image_path) → xml_string` | Mechanical but substantial; algorithms already debugged in OpenCV terms |
| **Dart port** | Rewrite orchestration in Dart using the `image` package + an ONNX RT Dart binding | Purest approach; avoids native toolchain; more re-implementation risk |

Decision deferred to Stage B. A third option (subprocess) is not viable on iOS
(see below).

### Web (Chrome): no subprocess — use a local HTTP server instead

Chrome's sandbox blocks all OS subprocess calls. Flutter web running in Chrome
**cannot** call `Process.run()` or any equivalent. The workaround for the
web-only dev workflow:

1. Run Homr as a minimal local HTTP server on the host machine (e.g. a 20-line
   FastAPI endpoint that accepts a multipart image upload and returns MusicXML).
2. Flutter web POSTs the image to `http://localhost:PORT/recognise` and reads
   the MusicXML response.
3. `omr_service_web.dart` implements this HTTP call; no native code needed for
   the web build.

This keeps the web build useful during feature development without requiring
mobile embedding to be done first. The server must be running locally — this
is a developer/parent-on-desktop workflow, not a hosted web app.

---

## Scan Flow

```
1. Parent taps "Scan a piece" on PieceListScreen
2. image_picker opens camera (or photo library as fallback)
3. OmrService.recognise(imageFile) — may take 30+ seconds
   → progress spinner with stage label (detecting staves, finding notes, …)
4. OmrResult returned → convert to draft MusicXML
5. ScanCorrectionScreen opens
6. Parent reviews, corrects uncertain notes, names the piece
7. Accept → PieceRepository saves MusicXML + piece metadata to documents dir
8. Piece appears in PieceListScreen
```

---

## Correction UX (`scan_correction_screen.dart`)

```
┌────────────────────────────────────────────────────────┐
│  [Photo thumbnail — tap to expand]    [Piece name ___] │
├────────────────────────────────────────────────────────┤
│                                                         │
│   [Staff view — OSMD re-render of recognized MusicXML] │
│    Confident notes: black                               │
│    Uncertain notes (confidence < threshold): amber      │
│                                                         │
│   Tap any note to correct:                              │
│   [pitch picker]  [rhythm picker]  [delete]  [♩+ rest] │
│                                                         │
│   N uncertain notes remaining                           │
├────────────────────────────────────────────────────────┤
│  [Cancel]                             [Save to library] │
└────────────────────────────────────────────────────────┘
```

**Behaviour:**
- Screen opens with the first amber (uncertain) note already selected
- The "N uncertain notes remaining" counter decrements as the parent confirms
  or corrects each flagged note; confirmed-but-unchanged notes turn black
- The photo thumbnail stays visible as reference; tapping it opens full-screen
- "Save to library" is available immediately (parent may trust the result)
- OSMD bridge gets a new JavaScript function:
  `window.setNoteColour(noteId, colour)` — called from Flutter to paint amber
  on uncertain notes and black on confirmed ones

---

## `PieceRepository` Changes

After the correction screen, `OmrResult` is assembled into a `ParsedPiece` via
the existing `JianpuConverter` + `FingeringMapper` pipeline (no changes to those
services). The MusicXML and a piece metadata JSON are written to:

```
{documentsDir}/
  pieces/
    {pieceId}/
      score.xml
      piece_meta.json      ← title, id
```

`PieceRepository.loadAll()` scans `{documentsDir}/pieces/` in addition to
`assets/fixtures/` and merges the results.

---

## Multi-Platform Notes

- **Web (Chrome)**: `omr_service_web.dart` POSTs the image to a local Homr
  HTTP server (`http://localhost:PORT/recognise`). If the server is unreachable,
  show a friendly error: "Start the local OMR server — see README." Also expose
  an "Import MusicXML" file picker as a fallback for users who already have XML.
- **macOS desktop**: `omr_service_io.dart` is used; can call a subprocess
  directly (no iOS sandbox restriction). Camera access may not be available;
  fall back to file picker gracefully.
- **iOS/Android**: Full camera + native inference path (ONNX RT Mobile).

---

## Phase 4 Acceptance Criteria

**Stage A (must pass before Stage B begins):**
- [x] Oemer evaluated — **FAILED** (time signature not parsed; see `docs/omr_evaluation/oemer/results.md`)
- [x] Homr produces ≥90% note accuracy (positional, no offset) on `lightly_row_from_book_crop_no_title.heic` — **100% ✓**
- [x] Homr produces ≥90% note accuracy (positional, no offset) on `happy_farmer_from_book_crop_no_title.heic` — **96.4% ✓ (with 60% binarization pre-processing)**
- [x] Homr confidence scores assessed; amber-flag design updated — **no confidence scores; see results.md §Key Questions**
- [x] Homr produces ≥90% note accuracy (positional) on `gossec_gavotte.HEIC` — **100% ✓** (additional benchmark, full-page photo, 193 notes)
- [x] Homr Stage A results documented in `docs/omr_evaluation/homr/results.md`

**Stage B (web HTTP server — implement first):**
- [ ] FastAPI (or equivalent) local server wraps `homr` CLI; accepts multipart image, returns MusicXML
- [ ] `omr_service_web.dart` POSTs to `http://localhost:PORT/recognise` and parses response
- [ ] Web build compiles clean; fallback "Import MusicXML" picker present
- [ ] No `dart:io` or `dart:html` in shared code (multi-platform smell check)

**Stage B (mobile embedding — deferred):**
- [ ] Choose orchestration strategy: C++ wrapper or Dart port (see ONNX Model Bundle section)
- [ ] `OmrService.recognise()` runs end-to-end on Android and iOS without crashing
- [ ] Inference completes (no timeout); progress spinner shows stage label
- [ ] Decoder KV-cache dynamic shapes verified on ONNX Runtime Mobile

**Stage C (correction UX):**
- [ ] Uncertain notes (below `omr_params.json` threshold) appear amber in OSMD
- [ ] Tapping an amber note opens the correction picker
- [ ] Corrected piece saves to documents directory and appears in piece list
- [ ] Saved piece plays back correctly via Phase 2 MIDI playback
- [ ] "Import MusicXML" file picker works on web build

---

## Considered But Decided Against

### Audiveris

The mature, widely-used desktop OMR application. Excellent accuracy, MusicXML
output, active community. Not used here because: (1) it is a Java/Swing desktop
application — embedding on Android/iOS would require extracting the core pipeline
and rewriting the native layer, estimated at months of work; (2) AGPL license
may be incompatible with F-Droid + GPL distribution without legal review.

### TensorFlow Moonlight (Google)

Apache 2.0, TensorFlow-native (TFLite path plausible). Not used: explicitly
described as "no official release; not ready for end users" as of 2025. Revisit
if it reaches production readiness.

### Bouncing Ball (playback indicator)

*(Moved here from the Phase 3 document for completeness.)*
A sub-beat visual indicator for playback. Decided against: measure highlight is
sufficient for the target user; bouncing ball adds `PlaybackService` API surface
and widget complexity without commensurate benefit. Cannot be used in staff view
(OSMD WebView), creating an inconsistent cross-mode experience.

---

## Deferred to Phase 5

Teacher video import and audio-to-score alignment (originally Phase 2B):

- Video import (`file_picker`, `ffmpeg_kit_flutter`)
- Chroma feature extraction (`fftea`) + DTW alignment
- Alignment progress UX
- Video playback with score following (`video_player`)
- Lookup tables: `chroma_params.json`, `dtw_params.json`
