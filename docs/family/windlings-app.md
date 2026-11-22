# Windlings: the recorder as a third app, by flavor

Step W1 of the winds (approach.md §2.3, "First: recorder or flute"). A third
flavor beside Stringlings and Mandolings ([`mandolin-app.md`](mandolin-app.md)),
on `next_gen`, that runs and offers one instrument: the soprano (descant)
recorder. Everything string-specific is off. The fingering chart, the hole
diagram and the fingering side panel are step W2.

| Flavor | Name on the home screen | iOS bundle id / Android applicationId | Instruments |
|---|---|---|---|
| `windlings` | Windlings | `name.howison.violinPracticeCompanion.windlings` | recorder only |

## Running it

```bash
# Simulator, with the fifo dev server on a pipe of its own:
FLUTTER_FLAVOR=windlings FLUTTER_FIFO=/tmp/flutter_ctl_wind \
  bash scripts/dev_run.sh dev-iphone --no-sync

# By hand:
flutter run -d dev-iphone --flavor windlings
flutter build ios --simulator --debug --flavor windlings
flutter build apk --debug --flavor windlings   # app-windlings-debug.apk
```

Stringlings and Mandolings run as before (`mandolin-app.md`). `dev_run.sh`
skips the dev-library sync for any flavor but stringlings.

## How it is wired

The same shape as the mandolin flavor, copied:

- **Android:** a `windlings` product flavor with `applicationIdSuffix =
  ".windlings"` and the label as `manifestPlaceholders["appName"]`.
- **iOS:** `Debug-`, `Release-` and `Profile-windlings` configurations on the
  project, Runner and RunnerTests (copies of the mandolin ones, with the
  CocoaPods base configurations already in place so `pod install` has nothing
  to add), a shared `windlings` scheme, and `ios/Flutter/windlings.xcconfig`
  for the bundle id and display name. The Podfile maps the configurations.
- **Dart:** `AppEdition.windlings` (appName "Windlings"), and
  `instrumentsOffered(windlings) == [recorder]`. With one instrument, Settings
  and Add a player hide the choice, as in Mandolings.

## The recorder

`InstrumentSet.recorder` → `InstrumentProfile.recorder`: treble clef, written
C4 to D6 (MIDI 60 to 86), no strings, and a `transposition` of
`Transposition.octaveUp` (from `pitch_tuner`). Every other profile is
`Transposition.concert`, so nothing changes for them.

**Written and sounding pitch:**

- The stored **source** stays concert pitch.
- The **view** (`InstrumentView`) is the written part. For a transposing
  profile, a source in its own clef is moved too: down by the transposition,
  then up or down by whole octaves into the written range (the same search
  the viola uses). A first-position violin tune comes out exactly as written
  (Lightly Row's view is the identity), and so sounds an octave above the
  violin. A tune that dips onto the G string reads an octave higher. Every
  bundled tune lands with at least 95% of its notes in range
  (`test/windlings_test.dart`).
- What is engraved, named, annotated and edited is that view, so
  `parsedPieceProvider`'s notes are **written** pitch. The editor's
  `toSource` takes edits back through the inverse, as for the viola.
- **Sound** is the written note plus the transposition:
  `MidiGenerator.soundingSemitones` (12 for the recorder) is applied in the
  schedule. Playback and the aligner's reference both read the schedule, so
  they agree. The rendered-score cache key covers the schedule, so the
  recorder's renders are its own.
- **Playback** uses GM 74 (0-based 73 in `midi_patch.json`). The soundfont
  cut gains `--keep 0:73` (README, "The soundfont"), 1.7 MB → 2.5 MB, in
  every flavor since they share assets. Re-cut the bank on each checkout.
- **Alignment:** `AlignmentProfile(minFrequencyHz: 400, maxFrequencyHz:
  4000, ringSeconds: 0.15)`. These are first guesses: there is no recorder
  recording to measure them on. Chroma doesn't depend on the octave, so the
  transposition matters for the band, not the reference.

**Where this departs from the plan.** The family plan says `NoteEvent`
carries concert pitch and written pitch is derived. Here the parsed notes
carry the written pitch, and sound is derived. Every note of the editor
compares a note's step and octave with its `midiNumber`, so shifting only
`midiNumber` would break it, and shifting both would make the parsed notes
match neither the source nor the view. The source file is still concert, so
the rule "the shared score is concert pitch" holds. Before a B♭ instrument
uses this, decide whether that is good enough.

## What is off without strings

`InstrumentProfile.hasStrings` is false. Two new `InstrumentFeatures` flags
are false for the recorder: `stringFingering` and `stringTuner`. What they
guard:

- `FingeringMapper.map` returns the piece unfingered: no `fingerString` and
  no `fingerNumber`, so no view draws a string label (`A1`) or a string
  colour. `hasFourthFingerChoice` is false for every note, which also keeps
  `StringChoiceMigration`, the layer store and the measure editor's choice
  away from it.
- The piece screen: Fingering and Combined drop out of the view picker, and
  a saved one opens Annotated. The drawer loses the open-or-4th picker,
  "Colour notes by string", the string colour and letter pickers and the
  fingering density. The key summary shows the key without "All: 1 2H 3".
- The measure editor loses STRING (the open-or-4th toggle, which read
  `strings.first`) and BOW.
- Tab view and chords were already off (`tabView`, `chords`).
- **Tuner:** the tuner button opens `ChromaticTunerScreen`, not the string
  tuner. It uses `InstrumentTuning.chromatic` over the recorder's sounding
  range ±2 semitones and shows the **written** name
  (`Transposition.writtenName`): a sounding C5 is shown as "C", with "C4 as
  written · sounds C5" under it, a cents bar and flat or sharp. No climber,
  headstock or drone, because the drone tunes to a string. No developer
  recording either. The string tuner is untouched.

## What W2 adds, and where

- **The fingering chart:** a lookup keyed on written MIDI, with alternates
  (approach.md §2.3). It would join `InstrumentProfile` (a chart, as the
  strings have a first-position table) and fill the annotations that the
  mapper now leaves empty. `FingeringMapper.map`'s early return for
  `!hasStrings` is where a wind mapper would branch.
- **The hole diagram:** a widget, the wind equivalent of `ChordDiagram`.
- **The side panel / drawer:** the slot is the `features.stringFingering`
  guard round the string picker in the drawer
  (`piece_detail_screen.dart`). Breath and tonguing marks would go where the
  editor's BOW group was.
- A sustained-tone segmenter and a clarity threshold for the tuner
  (§2.3), measured on a real recorder.

## Verified (2026-11-21)

- `bash scripts/test_all.sh`: all pass, with `test/windlings_test.dart`, the
  chromatic tuner group in `test/tuner_test.dart` and the recorder bank
  check in `test/score_renderer_test.dart`. `flutter analyze`: 51 issues,
  the baseline.
- `dev-iphone` (iPhone 17), `--flavor windlings` through `dev_run.sh` on
  its own pipe, with the stamp read back through Marionette. The installed
  app's `CFBundleDisplayName` is Windlings and its bundle id is
  `….windlings`. Settings named the app and had no Instrument section.
  Lightly Row opened in treble at the violin part's notes (written A4 to
  E5), with no string labels and no "All: 1 2H 3". The view picker offered
  Staff, Annotated and Jianpu; there was no open-or-4th picker. Play
  rendered the score (three tempos) and the cursor followed. The tuner
  button opened the Recorder tuner (note, cents bar, Listen) with no
  strings. The microphone was not tried on the simulator, and the
  recorder's sound was not listened to.
- `pod install` (run by `flutter run`) left `project.pbxproj` as written;
  only the Podfile checksum in `Podfile.lock` moved.
- `flutter build apk --debug --flavor windlings`:
  `app-windlings-debug.apk`, package `…windlings`, label Windlings. Not run
  on the emulator.

## Open questions

- **Written vs concert in `NoteEvent`** (above).
- **The bigger soundfont** ships in Stringlings too. Flavor-specific assets
  would need a split asset bundle, or the bank chosen at build time.
- **The recorder's range**, C4 to D6, is a beginner's comfortable range. The
  octave search favours it; a tune that needs C♯4 or high E6 gets a few notes
  out of range rather than a different octave.
- The App Store, shared data, `.stringlings` files and the dev library are
  the same questions as for Mandolings (`mandolin-app.md`).
