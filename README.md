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
flutter build web            # Web / PWA
```

iOS requires an Apple developer account for device installation. The web build
works on iPhone Safari as a PWA with no account required.

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

See `docs/PHASE1.md` through `docs/PHASE4.md` for the implementation roadmap.

## OMR Engine Status

Phase 4 (scan pipeline) is evaluating OMR engines before mobile embedding:

| Engine | Lightly Row | Happy Farmer | Status |
|--------|-------------|--------------|--------|
| [Oemer](https://github.com/BreezeWhite/oemer) | 30.4% | 0% | **Rejected** — time signatures not parsed |
| [Homr](https://github.com/liebharc/homr) | **100%** | **96.4%** | **Selected** — requires 50% binarization pre-processing; also 100% on Gossec Gavotte (193 notes) |

Full findings in `docs/omr_evaluation/`.

## Licence

GPL-3.0. You may use, modify, and redistribute this code freely. You may not
wrap it in a proprietary or subscription product.
