# Windlings: the recorder as a third app, by flavor

> **Decided 2026-11-22: one app for now.** Stringlings, the app that ships,
> offers every instrument: violin, viola, mandolin and recorder
> (`instrumentsOffered` in `lib/services/instrument_setting.dart`). The
> `mandolin` and `windlings` flavors stay, each a single instrument, so the
> family can still be split into separate apps later by changing that table.
> This work is merged to main; `next_gen` is no longer separate.

Step W1 of the winds (approach.md §2.3, "First: recorder or flute"). A third
flavor beside Stringlings and Mandolings ([`mandolin-app.md`](mandolin-app.md)),
on `next_gen`, that runs and offers one instrument: the soprano (descant)
recorder. Everything string-specific is off. Step W2 added the fingering
chart, the hole diagram, the fingering side panel and the colour lane
(below, "Step W2").

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

## Step W2: the fingering chart, the panel and the lane

The design target is the woodwind mockup on the `family-plan` branch
(`docs/design/woodwind-fingering-lane.html`, its "side" layout, recorder),
in landscape with the panel on the right.

- **The chart** (`lib/models/recorder_fingering.dart`):
  `HoleFingeringChart.sopranoBaroque`, keyed on **written** MIDI, C4 (60)
  to D6 (86). Each `ChartEntry` has the thumb and holes 1–7 as
  open / half / closed (half is the pinched thumb, or the larger of a
  double hole 6 or 7), alternates, and a group. Checked against two public
  charts, Dolmetsch's text chart and Wikipedia's table, which agree from C4
  to A5. **B♭5, C♯6 and D6** are `verified: false`: the charts differ (the
  other fingering is kept as an alternate), and C♯6 also needs the bell end
  stopped, which the diagram can't show. `InstrumentProfile.fingeringChart`
  returns it for the recorder, null for the strings.
- **Groups**, for the lane and the bar under the panel's letter: left hand
  only (teal: G4–C5), both hands (amber), thumb off or half-holed (magenta:
  C♯5 up, over the break). Colours from the mockup,
  `fingering_group_palette.dart`.
- **Change words** (`fingeringChangeLines`): "Put down left 2", "Lift
  thumb, left 1", "Half-hole thumb", "Half-cover right 4". Holes are named
  by hand and finger, as the mockup does: hole 4 is "right 1", hole 7
  "right 4".
- **The hole diagram** (`lib/widgets/hole_diagram.dart`): a CustomPainter
  in theme colours, sized from its height. The thumb hole is drawn left of
  hole 1, then 1–3, a gap, 4–7, with 6 and 7 as double holes. With
  `changedFrom`, the holes that changed are ringed: solid in the primary
  colour going down, dashed grey coming up.
- **The panel** (`lib/widgets/recorder_fingering_panel.dart`):
  `FingeringPanelSlot` wraps the score in `piece_detail_screen.dart`. On a
  phone it wraps the whole compact layout, so the play tray spans only the
  score; on a tablet it wraps the notation view. It adds the panel (132pt)
  only for an instrument with a chart and in landscape. Otherwise it returns
  the child as it was, with no LayoutBuilder, so violin, viola and mandolin
  are unchanged. Portrait shows no panel.
- **The current note** (`lib/services/wind_fingering.dart`): the notes in
  playing order come from the player's highlight events
  (`PlaybackServiceBase.highlightEvents`, repeats unfolded), leaving out
  rests, tie continuations and lower chord notes. While playing, the panel
  shows the highlighted note: over a rest, the next note; over a tie, the
  note held. When stopped, it shows the note last tapped on the staff
  (`fingeringFocusProvider`, set by the staff's tap, which already knew the
  note), if that note is inside the selection; otherwise the selection's
  first note, or the piece's first. "Next" is the following note in that
  order, and the change is measured from the note before it.
- **The lane**: one short dash under each note on the Staff and Annotated
  views, coloured by group. It is drawn by `_NoteLanePainter` in
  `staff_view_verovio.dart` from `windLaneDashes`, two staff spaces under
  the bottom line, or lower where a system's stems reach further. The engrave
  reserves no room for it; it sits in the gap between systems. It is not in
  print. The string lane (chips and underline) was not reused: its channel
  is above the staff and reserved by placeholders in the XML.

Not done:
- the mockup's mini diagrams above notes;
- note names as the label in place of the Annotated view's note-name
  toggle;
- breath and tonguing marks;
- the sustained-tone segmenter and clarity threshold for the tuner
  (§2.3).

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

### W2 verified (2026-11-21)

- `bash scripts/test_all.sh`: all pass, with the new
  `test/recorder_fingering_test.dart`. It covers the chart (every
  chromatic note in range, the low octave C4–D5 exactly, the groups and the
  unverified set), the change words, the current-note rules, and a widget
  test: a landscape recorder gets the panel to the right of the score, and
  portrait or the violin gets none. `flutter analyze`: 51, the baseline.
- `dev-iphone`, windlings flavor, own pipe, with the stamp read back.
  **Rotating took a workaround.** The Simulator's windows weren't reachable
  from AppleScript, so the Device menu was disabled. The app was put in
  landscape by a temporary, uncommitted
  `SystemChrome.setPreferredOrientations([landscapeLeft])` in `main()`,
  then a hot restart. Marionette bounds confirmed the layout: 874×402, with
  the panel at x=680, 132 wide. In Lightly Row (written A4–E5) the lane
  read teal for A and B and magenta for C♯, D and E. A tap on bar 3's D
  showed "D / high", "Lift left 1" with hole 1 ringed dashed, and "Next: E"
  with a half-holed thumbnail. With Play, the panel followed the cursor
  (C♯, "Same fingers", "Next: D" on bar 1's third note). Portrait showed
  the lane and no panel.

## Open questions

- **The upper register**: B♭5, C♯6 and D6 need checking against a real
  recorder or a method-neutral teacher's chart, and C♯6's stopped bell
  needs a mark on the diagram.
- **Hole naming**: "right 1" for hole 4 follows the mockup. Some teachers
  count holes 0–7 instead.
- **The lane's room**: no vertical space is reserved below the staff. With
  tight system spacing, a dash could crowd the next system.

- **Written vs concert in `NoteEvent`** (above).
- **The bigger soundfont** ships in Stringlings too. Flavor-specific assets
  would need a split asset bundle, or the bank chosen at build time.
- **The recorder's range**, C4 to D6, is a beginner's comfortable range. The
  octave search favours it; a tune that needs C♯4 or high E6 gets a few notes
  out of range rather than a different octave.
- The App Store, shared data, `.stringlings` files and the dev library are
  the same questions as for Mandolings (`mandolin-app.md`).
