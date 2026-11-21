# Moving code into libraries: how each step is done

Status: steps 0–3 and 4a done (2026-11-21). The plan itself, meaning which libraries,
what goes in each and in what order, is [`family/libraries.md`](family/libraries.md).
This page covers how a step is carried out, so that Stringlings keeps
building, passing its tests and shipping at every commit.

## The workspace

The repo is a **Dart pub workspace**:

- The root `pubspec.yaml` is the app, and it lists its libraries under
  `workspace:`.
- Each library is a directory under `packages/` whose pubspec says
  `resolution: workspace`.
- There is one resolution and one `pubspec.lock`, at the root.
- `flutter pub get` at the root resolves everything.

Rules that follow from it:

- **A library's dependencies must resolve together with the app's.** The
  first `pub get` failed for this reason: the libraries' `test` dev
  dependency could not coexist with the Flutter SDK's pinned `test_api` while
  the unused `riverpod_generator` held `analyzer` at ^7. Those code-generation
  dependencies were removed. If a library dependency clashes again, change
  the library's constraint first, and the app's only after that.
- **`packages/jovial_svg` is not a member.** It is vendored third-party code
  with an old SDK floor, so it stays a plain path dependency.
- **The `homr_flutter` override works unchanged.**
  `pubspec_overrides.yaml.off` sits at the workspace root, which is where pub
  reads overrides. With it moved into place, `pubspec.lock` records the path;
  with it moved back and `pub get` re-run, the lock is restored byte for
  byte. Checked 2026-11-20.
- **Nothing runs a library's tests except the library**, because the root
  `flutter test` only runs `test/`. Use the script, which runs the app's
  tests and then `dart test` in every member:
  ```bash
  bash scripts/test_all.sh
  VPC_RESTRICTED_DIR=/nonexistent bash scripts/test_all.sh   # as a clone would
  ```
- **A member needs a README, a CHANGELOG and a LICENSE.** The libraries are
  GPL-3.0, except `pitch_tuner` (once `string_tuner`), which is BSD-3-Clause. A
  member also needs `publish_to: none` until the pub.dev decision is
  revisited, and an `analysis_options.yaml` that includes
  `package:lints/recommended.yaml`.

## The three commits of an extraction

1. **Safety net.** Before anything moves, pin today's behaviour in a snapshot
   test. For musicxml_tools, that is every bundled piece parsed, plus its
   fingerings and the output of each repair or injector. For score_sync, it is
   the synthetic alignment anchors. Each of the next commits must leave the
   snapshot identical. The two that exist: `test/migration_snapshot_test.dart`
   (every bundled score and OMR fixture through every MusicXML stage) and
   `test/alignment_snapshot_test.dart` (four bundled scores, synthesized and
   aligned, to full double precision).
2. **Seam, in the app.** Cut whatever stops the files from being a library,
   without moving them:
   - a Flutter import
   - a `rootBundle` read (the data becomes a parameter, and the app does the
     loading)
   - an app field on a library type
3. **Move and rewrite, in one commit.** `git mv` the files into
   `packages/<lib>/lib/src/`, and point the app's imports at the library's
   barrel file. Don't leave re-export shims at the old paths: a file that
   still exists at its old path stops git from recording the move as a
   rename. Check `git diff --cached -M --name-status`: every moved file should
   be an `R`. The rewrite is a script that resolves each import (relative or
   `package:`) and swaps those that land on a moved file. The tests that move
   switch from `flutter_test` to `package:test`.
   - Tests that need app files or bundled assets stay in the app as
     integration tests.
   - Tests that need the restricted checkout must skip without it, as they do
     in the app today.
   - Never use `dart format`: this repo isn't formatted, and a formatter
     turns a three-line change into hundreds (CLAUDE.md smell #5).
   - zsh doesn't split an unquoted `$FILES`, so a loop or `sed` over a list
     of files sees a single argument. Run such scripts under `bash -c`.

## Branches and merging

- **Each step is a short branch in the main checkout.** When a step is green,
  it is fast-forwarded into main and the branch is deleted. Every step is
  useful to Stringlings alone, so nothing waits for the rest.
- **If main has moved, rebase the step.** The branch is rebased onto main,
  `scripts/test_all.sh` is run again, and then the branch is merged.
- **Use a worktree only when another session holds the main checkout.** It
  then lands with a fast-forward push to `origin/main`, and the main checkout
  catches up with `git pull --ff-only`.
- **Family-only work goes on `next_gen`.** That is the work no use to
  Stringlings alone: the second app, the woodwind prototype, and the move of
  the app to `apps/`. `next_gen` is rebased onto main after each step lands.

## Checklist for every step

- [ ] `bash scripts/test_all.sh`, and again with `VPC_RESTRICTED_DIR=/nonexistent`
- [ ] the snapshot test is unchanged
- [ ] `flutter analyze` at the root has no new issues (it covers the members too)
- [ ] the CLAUDE.md smell check, especially #5: compare
      `git diff --shortstat` with `git diff -w --shortstat`
- [ ] for a step that changes behaviour (not a pure move): on `dev-iphone-se`
      with the stamp verified, open a piece, edit a bar, scan, play with a
      count-in, align a recording (check the anchor span); then `dev-android`

## Progress

| Step | What | State |
|---|---|---|
| 0 | Workspace root, `scripts/test_all.sh`, unused codegen dependencies removed | done |
| 1a | `musicxml_tools`: snapshot, `NoteAnnotation` seam, move | done |
| 1b | `score_sync`: snapshot, `ScoreTiming` seam, move, alignment off the UI isolate | done |
| 2 | Source / instrument / player layers, then viola and players ([`family/layers.md`](family/layers.md)); Annotate deferred | done (Annotate deferred) |
| 3 | `pitch_tuner` (rename, `TunerModel` moved in, chromatic, transposition, drone), `<transpose>`/`<clef>` read | done (library only; no app UI yet) |
| 4a | `score_view` engraving layer: snapshot, seam, move | done |
| 4b | `score_view` widget, without Riverpod | when a second app needs it |
| 5 | `audio_decoder`, `practice_core`, `apps/` | |
| 6 | parts, staves, voices | |

## How steps 1a and 1b came out

Each was a snapshot commit, a seam commit and a move commit; 1b added
background alignment after the move. Where they differ from
`family/libraries.md`:

- **`NoteEvent.annotation`, not a side map.** The note carries one opaque
  `Object?` that the library never reads. The app's `NoteAnnotation`
  (`lib/models/note_annotation.dart`) holds the fingering and the Jianpu.
  Its `NoteAnnotations` extension gives back the old getters
  (`note.fingerString`), so of 45 reads, none changed; only the writers did
  (`withFingering`, `withJianpu`). A side map would have touched every
  reader and every `copyWith`.
- **Jianpu is split.** The digit math (`JianpuDigits`, with the key table
  passed in) is in musicxml_tools. The pass that loads the table and
  annotates the piece (`JianpuConverter`) stays in the app, because it writes
  the app's annotation. `palette_xml_generator` stays in the app too: its
  L/H colouring is violin logic.
- **`pickupUnitsOf` went to musicxml_tools** (`pickup.dart`), because it
  reads a `Measure`. The rest of the count-in math is pure, so it is in
  score_sync.
- **The aligner is generic: `ScoreAligner<S>`.** It is given a
  `ScoreTiming<S>`, a function from a score and a tempo to a `TimedScore`.
  It is not given a 60-bpm timeline to scale, because `MidiGenerator`'s
  seconds at another tempo need not match a scaled timeline bit for bit, and
  the snapshot would drift. The app's `MidiData` and `ScheduledNote` simply
  implement `TimedScore` and `TimedNote`.
  - The app's `AudioScoreAutoAligner` (`lib/services/piece_aligner.dart`) is
    `ScoreAligner<ParsedPiece>` timed by `MidiGenerator`. It keeps
    `alignPcm`, `alignmentReviewMessage` and `alignInBackground` (`compute`).
  - Its call sites didn't change. The static passes are named on
    `ScoreAligner`, because Dart doesn't inherit statics.
- **`AlignmentProfile` is deferred to step 2.** The chroma band and
  `onsetWeight` were already constructor parameters of the extractor and the
  DTW; `ringSeconds` was the one the aligner hid, and it is now a parameter.
  The profile that bundles all three belongs with `InstrumentProfile`.
- **The anchor JSON codecs stayed in the app** (`media_alignment_store`,
  `rendered_score_cache_io`), unchanged: they are persistence, and moving
  them buys nothing yet.
- **`MidiGenerator` kept its `rootBundle` read.** It stays in the app, so
  nothing in a library depends on it.
- **The app lost its direct `fftea` dependency**; score_sync has it.

## How step 3 came out

Four commits on a short branch: the rename, a seam, the move, then the new
features. A fifth commit read `<transpose>` and `<clef>` in musicxml_tools.

- **`string_tuner` became `pitch_tuner`** by a pure rename (every file an
  `R`). It stays BSD-3-Clause.
- **`TunerModel` and `UnisonMeter` moved in.** The seam was small:
  `TunerFrame` moved off the microphone interface (`tuner_input_base.dart`,
  which stays in the app and re-exports it).
- **The words stay in the app.** `tuner_advice.dart` (pegs, fine tuners, a
  mandolin's buttons) is the "strings implementation" that the plan calls
  an advice interface. No interface was cut: with one implementation it
  would be a guess. Do it when a wind app writes its own advice.
- **Tests split by what they test.** The model's group and the meter's
  tests are package tests. The words are `test/tuner_advice_test.dart`.
  `plucked_pair.dart` is copied, because a test helper can't be shared
  across packages.
- **New, library only:**
  - `InstrumentTuning.chromatic`, `InstrumentTuning.note` and `TargetKind`
  - `Transposition` (sounding minus written, as `<transpose>` counts it)
  - `DroneTone`: a seamless loop, written as a WAV, to be played as a file
    and never as a live synth
- **Frame length and clarity were already parameters**
  (`PitchTracker.frameSize`, the YIN threshold, `TunerModel.minClarity`).
- **musicxml_tools reads `ParsedPiece.openingClef` and
  `openingTranspose`.** Nothing applies a transposition yet; that waits for
  the woodwind prototype. `InstrumentView` keeps its own clef reading,
  which compares without the octave change.
- **Deferred, for a decision:** whether Stringlings' tuner gets a chromatic
  mode or a drone button. Both are UI, so mock them first.

## How step 4a came out

The plan moves the score_view widget only when a second app needs it. The
engraving layer could move first on its own, and it has. There were three
commits: a snapshot, a seam, a move.

- **Safety net:** `test/engraving_snapshot_test.dart`, 458 digests. A
  native engrave can't run headlessly, so it pins everything static:
  - every `VerovioEngraver` SVG pass over the five fixture SVGs
  - the `EngravedScore` JSON round trip
  - grids over staff_zoom, the section planner and the paginator
  - for every bundled score: the system-break passes and the section
    layout solver
- **What moved:** `packages/score_view`, a Flutter member, holds
  `verovio_engraver`, `staff_zoom`, `section_line_planner`,
  `section_engraving`, `print_paginator`, the engrave disk cache, and the
  break mechanics split out as `system_breaks.dart`.
- **The seams:**
  - The cache's build stamp is `engraveCacheStamp`, which `main.dart` sets
    from `kBuildRef`.
  - The `staffSpacing*` constants live in staff_zoom; `providers.dart`
    re-exports them.
- **What stayed in the app:**
  - `system_break_injector.dart`, which needs `Section`, `BarSplit` and
    `MovedRepeat`.
  - `verovio_bbox_test` and `verovio_svg_shim_test`. Their SVG fixtures are
    allowed only under `test/fixtures/` (`repo_content_policy_test`), and
    the guard was not widened. To move them, decide on that guard first.
- **`scripts/test_all.sh`** runs `flutter test` for a member that depends
  on the Flutter SDK.
- **Checked on `dev-iphone`.** The stamp in the AppBar matched. Opening
  Lightly Row wrote the cache with the new stamp, and a reopen after a hot
  restart was a disk hit. Android was not run; this is a pure move of Dart
  code.
