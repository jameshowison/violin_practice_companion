# Brief: make homr_flutter's TextReader fast enough on low-end Android

**For a session in the homr_flutter repo**, on top of 0.5.0
(`856ba2d`, branch `worktree-vectorized-baking-trinket`). Background:
`docs/title_ocr.md`, which is the earlier handoff plus a results section.

## Where things stand

The app now reads scan titles with `TextReader` (PP-OCRv5 mobile on ONNX
Runtime) instead of ML Kit and Vision. It is more accurate on every device
(14/22 titles against 11 for ML Kit and 13 for Vision), and the 2 s on a low-end phone was
accepted for now. The goal of this round is speed. The table below is
per title read, which is one `readText` call per scan: open both sessions,
read, dispose.

| Device | Median | Worst |
|---|---|---|
| iOS simulator (`dev-ipad`) | 256 ms | 724 ms |
| `dev-android`, 8 GB AVD | 888 ms | 3.5 s |
| `dev-android-low`, 4 GB AVD | 2238 ms | 8.4 s (a page with 69 detected lines) |

**Target:** median **≤ 1 s** and worst **≤ 2 s** on `dev-android-low`, with **no
loss of accuracy** on the corpus.

## Measure before changing anything

Nobody knows yet where the time goes. Add timing (debug-only, or a
`Stopwatch` record returned next to the lines) for each of these:
1. Decoding the whole page. `ui.instantiateImageCodec` decodes the full JPEG,
   often 12 MP, although only the top 18–40 % of it is searched.
2. Opening the detector session.
3. Running the detector.
4. Opening the recogniser session.
5. Each recogniser run, and how many runs there are.

Then pick from the list below by what the numbers show.

## Candidate speed-ups, likeliest first

1. **Recognise only what the app needs: the largest type first.** The app's
   `pickTitle` (`lib/services/title_region.dart` in the app) wants the line
   in the largest type. Among lines within 5 % of that height it takes the
   topmost, and only if the line is "wordy": at least 4 Latin letters, a
   letter share of at least 0.6, length up to 50, confidence at least 0.3.
   - The detector's boxes give heights before any recognition. Merge boxes
     into lines by geometry first. `mergeLines` does this today *after*
     recognition, but `_sameLine` needs only the boxes. Then recognise lines
     in descending height and stop once an accepted line has been read and
     the next candidate is more than 5 % shorter.
   - Suggested API: keep `readText` and add an optional
     `readText(image, region:, accept: bool Function(OcrLine), sameSizeTolerance: 0.05)`.
     When `accept` is given, it switches to largest-first with early stop and
     returns only the lines it read. Without it, behaviour is unchanged.
   - The app will pass `pickTitle`'s word test, which it will export.
   - On the 69-line page this should cut recognition from 69 runs to a
     handful.
2. **Batch the recogniser.** One `session.run` per line pays per-call
   overhead, and on Android that includes a platform-channel round trip for
   every tensor. Batch lines of similar width into one `[N,3,48,W]` input.
   RapidOCR batches 6.
3. **Decode at reduced size.** Decode the page at, say, its longest side
   ≤ 2000 px (`instantiateImageCodec(targetWidth:)`). Or have the caller pass
   the region already cropped. Check first that recognition doesn't lose
   accuracy on small type. A title strip at full width is far more than the
   detector's 960 px anyway.
4. **Smaller detector input for a strip.** `maxDetSide` is 960. A title
   strip that is wide and short may detect just as well at 640. Measure it.
5. **Session options.** Thread count, and graph optimisation level, if
   `flutter_onnxruntime` exposes them. NNAPI or XNNPACK only if measured; they
   often make small models slower.

Don't cache the sessions for the life of the app. The app frees them before
OMR, which peaks at about 1.7 GB, and that stays.

## How to measure

Use the app's corpus test, which compares engines and prints per-page timing
and a median:

```bash
# in the app checkout, with pubspec_overrides.yaml pointing at your homr_flutter worktree
# (it must also repeat `xml: ^7.0.1` under dependency_overrides)
bash scripts/push_title_corpus.sh <path>/violin_dev_library emulator-5554
flutter test integration_test/title_recognition_test.dart -d emulator-5554 \
  --dart-define=TITLE_CORPUS_DIR=/data/local/tmp/title_corpus
```

- Boot `dev-android-low` with
  `~/Library/Android/sdk/emulator/emulator -avd dev-android-low`.
- `scripts/push_title_corpus.sh` is in the app repo (on the app branch until
  merged). The scans stay on the emulator.
- Report a before/after table in the same format as `docs/title_ocr.md`.
  **Accuracy must stay at 14/22**, and the titles each page reads should be
  identical, or any change explained.
- The test prints only chosen titles, never raw OCR text (pages carry
  lyrics). Keep it that way.

## Also, before tagging

- `packages/homr_flutter/test/ocr_postprocess_test.dart` lines 103 and 107 use
  a method book's brand name as sample text. Swap it for a neutral word
  ("Andante").
- Keep the package's unit tests green. Add tests for the largest-first
  ordering and early stop, using synthetic boxes; no models needed.
- Bump to 0.5.1 (or 0.6.0 if the API grows), update the README, and tag. The
  app then bumps its `ref:`.
