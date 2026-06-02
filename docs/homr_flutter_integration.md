# homr Flutter Integration — Build Plan

## Status
Phase 0 complete (model audit done via source inspection). Ready to begin Phase 1.

## Project goal
On-device optical music recognition for single-staff printed sheet music (Suzuki Book 1 level),
producing MusicXML. Zero server cost, fully open source (AGPL).

## Repo
`git_root/homr_flutter/` — standalone Flutter app, sibling to `git_root/homr/` (Python reference) and the violin practice companion. Created with:
```
flutter create homr_flutter --org dev.homr --platforms android,ios
```

## Architecture overview

```
OS document scanner (VisionKit / ML Kit) →
Binary threshold (50%) + CLAHE + resize →
SegNet ONNX inference (patch-based) →
Staff detection + bounding boxes →
Transformer ONNX inference (encoder + autoregressive decoder) →
MusicXML output
```

Pipeline stages:
1. **Capture** — OS-native document scanner handles deskew, perspective, crop
2. **Preprocessing** — binary threshold + CLAHE + resize in Dart (homr-specific, not replaceable by OS)
3. **Segmentation** — SegNet UNet detects 6 semantic classes in 320×320 patches
4. **Staff detection** — builds staff geometry from segmentation masks
5. **Recognition** — encoder+decoder transformer converts staff strip to note tokens
6. **Assembly** — note tokens → MusicXML

---

## Phase 0 — Model audit (COMPLETE)

### Models

All models are hosted at **GitHub releases of `liebharc/homr`**:
`https://github.com/liebharc/homr/releases/download/onnx_checkpoints/{name}.zip`

| File | Stage | Notes |
|------|-------|-------|
| `segnet_308-3296ccd40960f90ca6ab9c035cca945675d30a0f.onnx` | Segmentation | FP32; `_fp16` variant available |
| `encoder_pytorch_model_367-575b4737bca815d3a7b37169269fc548d7e945b9.onnx` | Transformer encoder | FP32; `_fp16` variant available |
| `decoder_pytorch_model_367-575b4737bca815d3a7b37169269fc548d7e945b9.onnx` | Transformer decoder | FP32; `_fp16` variant available |

**Bundle strategy:** Use FP16 variants (~67 MB total estimated). Bundle in `assets/models/` — not a hard
platform limit (Google Play AAB supports >150 MB assets; iOS App Store accepts large bundles with a
Wi-Fi-required flag above 200 MB). Bundling preferred over on-demand download to support offline use
without first-launch friction.

### Tensor specs

**SegNet:**
- Input `"input"`: `[batch, 3, 320, 320]` float16
- Output `"output"`: `[batch, 6, 320, 320]` — 6-class logits; argmax → class mask
  - 0=background, 1=stems/rests, 2=noteheads, 3=clefs/keys, 4=staff lines, 5=other symbols

**Transformer encoder:**
- Input `"input"`: `[1, 1, 256, 1280]` float16 (1-channel grayscale staff strip)
- Output `"output"`: `[1, seq_len, 512]`

**Transformer decoder (autoregressive, per step):**
- Inputs: `rhythms`, `pitchs`, `lifts`, `articulations` each `[batch, 1]`; `context`; `cache_len [1]`; 32 cache tensors `cache_in0`–`cache_in31`
- Outputs: logits for each head; 32 cache outputs; `attention`
- Stop at EOS (token id=2) on rhythm stream; max 608 tokens

### Vocabularies

| Stream | Size | Key tokens |
|--------|------|------------|
| Rhythm | ~200 | PAD=0, BOS=1, EOS=2; note/rest durations in Humdrum \*\*kern (e.g. `note_4.` = dotted quarter) |
| Pitch | 71 | nonote=0; C0–B9 |
| Lift (accidentals) | 7 | nonote, ♯, ♯♯, ♮, ♭, ♭♭ |
| Position | 3 | nonote, upper, lower (grand staff) |
| Articulation | ~250 | combinations; `_` = none |

### Image preprocessing pipeline (Python reference, to be ported)

1. `autocrop()` — background margin removal (subsumed by OS scanner)
2. `resize_image()` — target width **1920 px**, aspect-ratio preserving
3. **Binary threshold at 127** — critical for book bleed-through suppression
4. `cv2.createCLAHE(clipLimit=1.0, tileGridSize=(8,8))` — contrast normalisation

---

## Phase 1 — Flutter project scaffold

### Dependencies (pubspec.yaml)

```yaml
dependencies:
  flutter_onnxruntime: ^1.5.1     # 16 KB page-size compliant for Google Play
  flutter_doc_scanner: latest     # wraps VisionKit (iOS 13+) + ML Kit (Android API 21+)
  image: latest                   # pure-Dart image processing
  path_provider: latest
  xml: latest                     # MusicXML generation
```

Model files → `assets/models/` (pubspec assets block), FP16 variants only.

### Model fetch script

Write `tools/fetch_models.py`:
- Downloads the three FP16 `.onnx.zip` files from the GitHub releases URL above
- Unzips to `assets/models/`
- Prints tensor input/output names from each model for verification

---

## Phase 2 — Document capture

### Capture screen (`lib/capture/capture_screen.dart`)

Thin wrapper around `flutter_doc_scanner`:
- Launches the OS scanner UI (VisionKit on iOS → perspective-corrected JPEG; ML Kit on Android → corrected JPEG)
- Returns a single `File` (the scanned page)
- OS handles edge detection, deskew, and perspective correction automatically

**What the OS scanner does NOT do** (handled in Phase 3):
- Binary threshold (50% — critical, specific to book bleed-through)
- CLAHE normalisation
- Resize to 1920 px

---

## Phase 3 — Image preprocessing

### Preprocessor (`lib/capture/image_preprocessor.dart`)

Pure Dart using the `image` package:

1. Decode JPEG from scanner
2. Resize to 1920 px wide (aspect-ratio preserving)
3. Convert to grayscale
4. **Binary threshold at 127** — do not skip; evaluation showed this is essential for printed book pages
5. CLAHE — tile-based: split into 8×8 tiles, histogram-equalise each with clip limit 1.0, bilinear blend at boundaries
6. Return preprocessed image ready for SegNet patch extraction

**CLAHE note:** The `image` package lacks built-in CLAHE. Implement as a utility:
```dart
Uint8List clahe(Uint8List gray, int width, int height,
    {double clipLimit = 1.0, int tileSize = 8})
```
Split → per-tile histogram eq → bilinear blend at tile edges.

---

## Phase 4 — ONNX inference layer

Both runners: lazy-load on first use, cache sessions as singletons, run in a Flutter `Isolate`, report inference time to a debug overlay.

### Segmentation runner (`lib/inference/segmentation_runner.dart`)

```dart
Future<Uint8List> runSegmentation(Uint8List imageGray, int width, int height)
// Returns class mask [H×W], one byte per pixel (argmax class index)
```

Patch loop:
1. Extract 320×320 region; pad edges with 255 (white)
2. Replicate grayscale → 3-channel; cast to Float16List
3. Batch up to 8 patches → run SegNet session
4. Argmax along class axis → class index per pixel
5. Paste back into full-resolution class mask

### Transformer runner (`lib/inference/transformer_runner.dart`)

```dart
Future<List<EncodedSymbol>> runTransformer(Uint8List staffGray, int w, int h)
```

1. Letterbox to 256×1280; cast to Float16List
2. Encoder: `[1, 1, 256, 1280]` → `[1, seq_len, 512]`
3. Decoder loop (max 608 steps):
   - Feed previous tokens + context + cache tensors
   - Argmax each output head → token indices
   - Reverse-lookup token strings from vocabulary tables
   - Append `EncodedSymbol`; break on EOS rhythm token
4. Return `List<EncodedSymbol>`

---

## Phase 5 — Symbolic pipeline

Reference Python files (all in `../homr/homr/`):

| Python file | Dart target |
|-------------|-------------|
| `segmentation/inference_segnet.py` | mask → bounding boxes |
| `staff_detection.py` | staff grid construction |
| `model.py` | data structures |
| `bounding_boxes.py` | RotatedBoundingBox, BoundingEllipse |
| `note_detection.py` | notehead ellipse fitting |
| `transformer/vocabulary.py` | EncodedSymbol, SymbolDuration |
| `music_xml_generator.py` | MusicXML assembly |

### Segmentation postprocessor (`lib/pipeline/segmentation_postprocessor.dart`)

Port `bounding_boxes.py` + `staff_detection.py`:
- Per-class binary mask → contour detection → `RotatedBoundingBox` objects
  (no OpenCV in Dart; use `image` package morphology + custom minAreaRect)
- Group staff-line fragments (class 4) into 5-line staves by y-distance clustering
- Compute `avgUnitSize` (median inter-line spacing in pixels)
- Build `StaffGrid` (list of `StaffPoint`: x, y[5], angle, unitSize)

Key constants from `../homr/homr/constants.py`:
- `toleranceForStaffLine` = `unitSize / 3`
- `maxLineGap` = `5 * unitSize`
- `barLineMaxWidth` = `2 * unitSize`

### Symbol classifier (`lib/pipeline/symbol_classifier.dart`)

- Parse rhythm token string → `SymbolDuration` (Humdrum kern: base duration + dots + tuplet ratio)
- Map pitch token → MIDI note number
- Map lift token → accidental
- Assign symbols to staves by bounding-box y-overlap with `StaffGrid`

### MusicXML assembler (`lib/pipeline/musicxml_assembler.dart`)

Uses the `xml` Dart package; emits MusicXML 4.0 `<score-partwise>`.

Handles: notes, rests, time signatures, key signatures, barlines, clefs.
Out of scope for Suzuki Book 1: dynamics, articulations, double sharps/flats, tuplets.

---

## Phase 6 — Integration

### OMR orchestrator (`lib/omr_orchestrator.dart`)

```dart
Future<String> recognise(File image)  // returns MusicXML string
```

Progress events (stream): `preprocessing → segmenting → detecting → recognising → assembling`

Error handling: return partial result if segmentation succeeds but transformer fails; clear `OmrError` enum otherwise.

---

## Phase 7 — Performance and optimisation

### Benchmarking harness (`test/benchmark_omr.dart`)

- 10 test images from `../violin_practice_companion/docs/omr_evaluation/` corpus
- Per-stage timing
- Note-level accuracy vs hand-corrected ground truth MusicXML

### If inference too slow

Target: <15 s end-to-end on a 3-year-old mid-range phone.

1. FP16 models (already selected above) — first gain
2. Hardware delegates: CoreML (iOS), NNAPI (Android) via `flutter_onnxruntime` execution provider options
3. INT8 quantisation via ONNX Runtime Python API if FP16 + delegates still insufficient

---

## Key risks and mitigations

| Risk | Mitigation |
|------|------------|
| No OpenCV in Dart for contour/minAreaRect | Port from scratch; test each function against Python reference outputs on the same scan |
| CLAHE not in `image` package | Implement tile-based approximation (see Phase 3 note) |
| Transformer attention coordinates unreliable | Use sequential symbol ordering; accept minor x-position imprecision |
| Dart port of staff detection diverges subtly | Keep Python reference runnable; diff outputs on same scan |
| FP16 accuracy regression vs FP32 | Validate on evaluation corpus; fall back to FP32 if accuracy drops |

---

## Recommended sequence

```
Phase 0 (done) →
Phase 1 (scaffold + fetch script) →
Phase 2 (capture screen) →
Phase 3 (preprocessor) →
Phase 4 (inference runners — seg and transformer can be parallelised) →
Phase 5 (pipeline — sequential: postprocessor → classifier → assembler) →
Phase 6 (orchestrator) →
Phase 7 (benchmarking + optimisation if needed)
```

Do not start Phase 5 until Phase 4 produces tensor outputs verified against the Python reference on the same image.

## Discipline notes

- Each agent task = one deliverable file or small set of files
- Before writing any Dart port, read the corresponding Python source in `../homr/homr/`
- Write unit tests alongside each module using evaluation-corpus images as fixtures
- Keep the Python reference pipeline runnable throughout — use it to generate ground truth
