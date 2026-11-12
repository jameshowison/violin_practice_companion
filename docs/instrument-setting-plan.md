# Plan: one app, violin-only by default, with an Instruments setting

Status: implemented 2026-11-11 (first cut). This replaces the earlier plan for two
store apps built as Flutter flavors (`docs/two-apps-flavors-plan.md`, renamed
to this file). Flavors are kept below as a later option.

## Why one app

The violin and mandolin uses want different apps. Violin families follow a
structured method and should see nothing else. Fiddle and mandolin players want
fret numbers, tab and chords. The two share nearly everything: engraving,
playback, alignment, scanning, the library.

Two flavored apps would give each audience its own store listing, name and icon.
They would also cost:
- Xcode schemes and build configurations, and the matching Podfile mapping
- a second App ID
- Gradle product flavors
- a bundle id in every device script
- App Store review risk (guideline 4.3, near-duplicate apps)

One app with an app-wide setting gets the product split for a fraction of that.
Libraries carry over, and a violinist who takes up the mandolin turns on one
setting instead of installing a second app.

## The setting

`lib/services/instrument_setting.dart`:

- `InstrumentSet { violin, violinAndMandolin }`, stored app-wide under
  `app.instruments`. The default is **`violin`**. It is read synchronously from
  `sharedPreferencesProvider`, so the first frame is already right.
- `InstrumentFeatures { fretNumbers, tabView, chords }` is built from the set.
  Code asks about **capabilities, never the set**, so adding a set (or exposing
  one capability as its own setting) touches only `InstrumentFeatures.of`.
- The setting is an enum, not a bool, because a third value is expected:
  **`fiddle`**, the violin plus chords, without frets.

| | violin | violinAndMandolin |
|---|---|---|
| Per-piece Instrument picker (Violin / Mandolin) and fret style | hidden | shown |
| Tab view | hidden | shown |
| Chord symbols, their switch, chord diagrams | hidden | shown |
| Library | everything (fiddle tunes show with violin fingering) | everything |

## Force, don't just default

A piece can already have mandolin choices saved (`display.numbers.<id> =
mandolinFret`, `display.view.<id> = tab`, chords on). Hiding a control is not
enough on its own, because the piece would still open in frets with no picker to
leave them. So each of these display prefs is split in two:

- `…PrefProvider`: the stored per-piece choice, unchanged, with the same keys.
  The drawer's controls write here.
- The public name (`noteNumberModeProvider`, `displayModeProvider`,
  `showChordsProvider`): a derived provider that applies the features. Violin
  mode reads as violin fingering, a saved tab view opens annotated, and chords
  are off.

The stored choice is never rewritten, so switching to "Violin and mandolin"
brings each piece back as it was (`test/instrument_setting_test.dart`).

With chords off, `<harmony>` is stripped under either renderer. Otherwise
Verovio would reserve an empty chord band above every staff.
`pieceChordShapesProvider` returns nothing, which also removes the phone's chord
tray.

## Screens

- **Home** (`piece_list_screen.dart`): a settings gear at the top right opens
  `SettingsScreen`. Manage pieces moved out of the AppBar to sit beside the
  search box, with the same key (`manage_pieces_button`).
- **Settings** (`settings_screen.dart`): app-wide only. It starts with
  Instruments. Count-in, recording lead-in and tempo presets are app-wide too,
  but stay in the piece drawer, where they are used mid-practice. Move them
  only if the drawer gets crowded.

## Next

- **Fiddle set:** add `fiddle` to the enum with `chords: true`, and a radio tile.
- **Library tags,** if the list gets crowded: give each catalog entry
  `instruments: [...]` and have `PieceRepository.loadAll` or
  `visiblePiecesProvider` filter on it. Not needed while every piece is
  playable on the violin.
- **Android `applicationId`** is `name.howison.violinPracticeCompanion`, matching
  the iOS bundle id (changed 2026-11-12, before any Play upload).

## Later: store flavors

If a separate store listing for violin families is ever wanted, add Flutter
flavors on top of this. The flavor then only decides the setting's **starting
value** and the store identity. Nothing above changes. What that involves:

1. **iOS:**
   - Schemes `violin` / `multi`, and configurations `Debug-<flavor>` /
     `Release-<flavor>` (the `RunnerTests` target too). Create them in the Xcode
     UI, not by editing `project.pbxproj`.
   - Map each configuration in `ios/Podfile`
     (`project 'Runner', {'Debug-violin' => :debug, …}`), or `pod install`
     won't know them.
   - Per-flavor `PRODUCT_BUNDLE_IDENTIFIER`, display name and app icon set.
   - The existing bundle id `name.howison.violinPracticeCompanion` should stay
     with whichever app current installs should become.
   - A free team can register the new App ID for development. TestFlight and
     the store need the paid team.
2. **Android:** `flavorDimensions` and `productFlavors` in
   `android/app/build.gradle.kts`, each with its own `applicationId` and a
   `resValue` app name, with `android:label` set to `@string/app_name`.
3. **Assets:** per-piece pubspec lines take `flavors: [...]`. Extend
   `test/release_content_test.dart` so each line's flavors match the catalog.
4. **Dart:** read `appFlavor` (null under `flutter test`, web and an unflavored
   run) and fall back to `--dart-define=APP`, then to `violin`. Use it only to
   seed `instrumentSetProvider`, and to hide the setting in a flavor that
   shouldn't offer it.
5. **Scripts:** `BUNDLE=` is hardcoded in `sync_dev_library.sh`,
   `push_dev_library.sh`, `pull_dev_library.sh`, `pull_sync_trace.sh` and
   `sim_add_media.sh`. Derive all five from one `--flavor` argument, which
   `dev_run.sh` and `device_install.sh` take too. Put the flavor in the build
   stamp.
6. **Review risk:** a violin app that is only the multi-instrument app with
   features removed reads as a near-duplicate under App Store guideline 4.3.
   Give it its own identity (its library, a method-focused flow) before
   submitting both.
