# Violin Practice Companion

A free, open-source practice companion for children learning violin — built for
the non-music-reading parent trying to help a frustrated six-year-old.

Useful for families following any structured violin method, including Suzuki,
Colourstrings, and others that use a fixed beginner repertoire.

## The Problem

Many violin methods are built around listening and imitation, with a teacher at
the centre. But between lessons, a parent who cannot read Western staff notation
is largely helpless. They cannot tell their child which notes to play, cannot
identify where the child has gone wrong, and cannot follow along with the score
while the child practises.

At the same time, many families learning violin come from musical traditions
where **jianpu** (簡譜, numbered musical notation) is the common written
language for music. A B is not a B — it is "A1", first finger on the A string.

This app bridges that gap.

## What It Does

**Scan a page from your violin method book** and the app converts it into the
notation that works for your family:

- **Staff notation** — a clean re-rendering of what was scanned, useful for
  verifying the scan was correct
- **Jianpu** — numbered notation (1–7) with octave dots and rhythm underlines,
  familiar to many East Asian musical traditions
- **Fingering notation** — shows each note as its string and finger: `A1`, `D2`,
  `E0` (open string), etc., directly useful for a beginner child

**Practise smarter:**

- Select any measure or range of measures for targeted practice
- Pieces can be annotated with their section structure (ABAA etc.) so you can
  work on just one part at a time
- MIDI playback at adjustable tempo, with a bouncing ball or measure highlight
  following along
- Import a short video of your teacher playing the piece; the app aligns it to
  the score so tapping any measure jumps the video to the right moment

## What It Does Not Do

- Connect to the internet — ever
- Require a subscription or account
- Contain any sheet music — you supply your own legally purchased book
- Make editorial choices about fingerings — it computes first-position
  fingerings from music theory, independently of any published edition

## Philosophy

No company at the centre. No server costs. No lock-in. The app is a piece of
code you can build yourself, inspect, modify, and share freely.

The scanning approach is deliberate: rather than distributing copyrighted
musical arrangements, the app processes a copy you already own. The underlying
melodies in most beginner repertoire are public domain; what is copyrighted is
the publisher's specific editorial choices (fingerings, bowings, articulation).
The app reads your copy to recover the notes and rhythms, then generates its
own notation independently.

*This project is not affiliated with or endorsed by the International Suzuki
Association or any other method organisation.*

## Building

```bash
flutter pub get
flutter run                  # development
flutter build apk            # Android
flutter build ios --no-codesign  # iOS
flutter build macos          # macOS
flutter build web            # Web / PWA
```

iOS requires an Apple developer account for device installation. The web build
works on iPhone Safari as a PWA with no account required.

The scan-to-MusicXML (OMR) feature requires the sibling `homr_flutter` repo and
its ONNX models — see [OMR (Scan-to-MusicXML)](#omr-scan-to-musicxml) below. It
is not available on the web build.

## Distribution

- **Android**: F-Droid (pending submission) or direct APK
- **Web**: self-host the `build/web` output; works as an installable PWA
- **iOS**: build from source with your own developer account, or use AltStore

## Contributing

Contributions welcome. The most useful contributions right now:

- Section (ABAA) annotations for beginner pieces
- Verified first-position fingering lookup table corrections
- Language translations (the UI targets English and Simplified Chinese)
- Testing the OMR pipeline against real book photos

See `docs/explore.md` for the development history and decisions made so far,
and `docs/plan.md` for the remaining roadmap.

## OMR (Scan-to-MusicXML)

The "scan a page" feature is powered by [`homr`](https://github.com/liebharc/homr),
ported to a self-contained on-device Flutter package (`homr_omr`) and consumed
as a sibling path dependency:

```yaml
homr_omr:
  path: ../homr_flutter/packages/homr_omr
```

This means **the `homr_flutter` repo must be checked out next to this one**
(as a sibling directory) for `flutter pub get` to resolve.

Pipeline (`lib/services/omr_service*.dart`): document scan
(`flutter_doc_scanner`) → binarize (`preprocessImage`) → crop to the music
region (`image_cropper`) → on-device ONNX inference (segmentation +
transformer recognition) → assembled MusicXML, parsed by `MusicXmlParser` into
a `ParsedPiece`.

**Mobile/desktop only.** `flutter_onnxruntime` and `flutter_doc_scanner` don't
support web, so `omr_service.dart` conditional-imports a stub on web
(`omr_service_web.dart`) that throws `UnsupportedError`. A server-side `homr`
(Python) backend for a future web/laptop-camera path is planned but not built.

**Platform requirements** (set by `flutter_onnxruntime`):
- iOS deployment target 16.0+
- macOS deployment target 14.0+

**Models** (~147MB of FP16 ONNX weights, AGPL-licensed via `liebharc/homr`) are
fetched by `homr_flutter/tools/fetch_models.py` into
`homr_flutter/packages/homr_omr/assets/models/` and bundled as package assets —
run that script once in the sibling `homr_flutter` checkout before building.

OMR accuracy on Suzuki Book 1 (homr_flutter, 2026-06-09): **17/18 perfect**
(SER=0%). Full findings in `homr_flutter/docs/omr_evaluation/`.

## Licence

GPL-3.0. You may use, modify, and redistribute this code freely. You may not
wrap it in a proprietary or subscription product.
