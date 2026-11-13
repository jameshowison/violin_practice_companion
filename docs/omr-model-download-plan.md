# Plan: download homr's models on first scan

Status: planned, not started (2026-11-12). Today the three ONNX models are
bundled (`assets/engine/omr_models/`): 142 MB of an app that is ~215 MB
since the audio and soundfont were trimmed.

## Why

| | App size |
|---|---|
| Bundled models (today) | ~215 MB |
| Downloaded on first scan | ~73 MB |

Today's ~215 MB is over the 200 MB line where iOS asks before an App Store download over cellular;
73 MB is well under it. And people who never scan never pay for the models. Scanning is one feature
among several; the play-along, fingering and score views don't need them.

## Is it allowed

Yes. App Review guideline 2.5.2 forbids downloading *executable code*; model
weights are data, and downloading ML models after install is common. Google
Play has no rule against it either. homr's licence (AGPL) permits
redistributing the models; its maintainer links approvingly to an app built
on homr, so no need to ask (and the maintainer does not want such emails —
see homr's `LICENSE_FAQ.md`).

Apple-hosted alternatives (On-Demand Resources; iOS 26 Background Assets) and
Play Asset Delivery would need two native integrations, and Background Assets
needs a fallback for the iOS 16 deployment target. Not worth it: a plain HTTPS
download works the same on both platforms.

## Design

**Hosting.** A release on our own GitHub repo (e.g. `omr-models-v1`) holding
the three files exactly as `tool/fetch_models.py` verifies them, not homr's
`onnx_checkpoints` release: a mirror we control can't move under the app, and
installs don't load homr's hosting. Pin the URL and SHA-256 per homr_flutter
version (the hashes already live in `OmrModels.sha256`).

**homr_flutter (package change, new tag).** `OmrModels` holds asset keys and the
runners call `OnnxRuntime().createSessionFromAsset`. Add a file-path form —
`OmrModels.inDirectory(String path)` and `createSession(filePath)` — keeping
the asset form for the demo app and tests. Bump the app's `ref:` after.

**App.**
- `OmrModelStore` (`lib/services/`, `_io`/`_web` split): `status` (absent /
  downloading(progress) / ready / failed), `ensure()`, `delete()`.
  Files under Application Support/`omr_models/`, excluded from iCloud backup
  (they can be fetched again). Download to `.part`, verify SHA-256, then rename
  — never leave a half-file looking ready. Resume with HTTP Range where the
  server supports it; retry on failure.
- **First scan:** before the camera/picker opens, if not ready, a sheet:
  "Scanning needs a one-time download of the music-reading models (142 MB).
  Wi-Fi recommended." [Download] [Not now]. Progress in the sheet; scanning
  continues automatically when it finishes. Offline: say so plainly and keep
  the sheet's retry.
- **Settings:** a "Scanning models" row — size, Delete, or Download — so
  space can be reclaimed.
- `omr_service_io.dart` asks the store for the directory instead of
  `OmrModels.inAssetDir('assets/engine/omr_models')`.
- Remove `assets/engine/omr_models/` from `pubspec.yaml`; keep
  `scripts/fetch_omr_models.sh` for tests and integration tests that load the
  models from disk.

**Dev and tests.**
- Unit-test the store against a local HTTP server: checksum mismatch → failed
  and no file left; interrupted download resumes; delete.
- Simulator: dev builds could seed the store from the repo's fetched models to
  skip the download (debug only, `kDebugMode`).
- Android emulator: run the first-scan flow on `dev-android-low` too (memory
  while downloading and then scanning).

## Privacy

The download is a plain GET to GitHub; it sends no user data, but GitHub sees
the device's IP. App Store privacy answers stay "data not collected". Mention
the one-time download in the Thanks/licences page alongside homr's credit.

## Order of work

1. homr_flutter: file-path loading, tag, bump.
2. Publish the models release; record URL + hashes.
3. `OmrModelStore` + tests.
4. First-scan sheet, Settings row, drop the asset bundle.
5. Device check on dev-iphone-se and dev-android-low; then TestFlight.
