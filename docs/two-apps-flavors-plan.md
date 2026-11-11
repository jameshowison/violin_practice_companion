# Plan: violin and mandolin as two apps from one codebase

Status: planned, not started. Written 2026-11-11, after the repo restructure
(`assets/engine/` + a catalogued `assets/library/`), which this builds on.

## Why

The two instruments want different apps. The violin app is for families
following a structured method, starting with public-domain Book 1 repertoire. The
mandolin app is for fiddle tunes, chord shapes and tab. They share nearly
everything: engraving, playback, alignment, scanning, the library. What differs
is the default instrument, which pieces are bundled, and the store identity
(name, icon, bundle id).

Today a single app does both, with mandolin as a per-piece "Instrument" setting
(`NoteNumberMode`, `lib/models/note_number_mode.dart`). Its default is
`mandolinFret` (`noteNumberModeProvider`, `lib/services/providers.dart`), which
is wrong for a violin app.

## Approach: Flutter flavors, not two codebases

One repo, one `lib/`, two **flavors**, `violin` and `mandolin`.

| | violin | mandolin |
|---|---|---|
| iOS bundle id | `name.howison.violinPracticeCompanion` (unchanged, keeps the TestFlight record) | `name.howison.mandolinPracticeCompanion` |
| Android applicationId | `name.howison.violinpracticecompanion` | `name.howison.mandolinpracticecompanion` |
| Display name | Violin Practice Companion | Mandolin Practice Companion |
| Default `NoteNumberMode` | violin fingering | `mandolinFret` |
| Instrument toggle in drawer | hidden (or behind a debug flag) | hidden |
| Bundled pieces | public-domain method repertoire | fiddle tunes with chords |

Android's `applicationId` is still `com.example.violin_practice_companion`.
Change it before any Play upload; it can never change after publishing.

A later split into a shared package plus two thin apps (`packages/core`) stays
possible; flavors don't rule it out. Do it only if the apps' screens diverge
enough that flags in shared widgets become the smell CLAUDE.md warns about.

## Steps

1. **Catalog: which app gets which piece.** Add `"apps": ["violin"]` /
   `["mandolin"]` / both to each entry in `assets/library/catalog.json`, and to
   `CatalogPiece` (`lib/models/piece_catalog.dart`).
   `test/release_content_test.dart` checks that every entry names at least one
   known app.
2. **Per-flavor bundling.** Flutter (3.19+) supports
   ```yaml
   - path: assets/library/lightly_row/
     flavors: [violin]
   ```
   Every piece folder already has its own pubspec line, so each line gains a
   `flavors:` list. Extend the release guard's pubspec check so each line's
   flavors equal the catalog entry's `apps`. `assets/engine/` and
   `assets/library/catalog.json` stay unflavored.
3. **AppConfig.** New `lib/app_config.dart` reads `appFlavor` from
   `package:flutter/services.dart`. No `Platform.is*`, and no conditional import
   is needed, since this is not a platform split. It exposes:
   - `instrument` (violin | mandolin)
   - the default `NoteNumberMode`
   - `showInstrumentToggle`
   - the display name

   `PieceRepository.loadAll` filters the catalog by `apps` containing the
   flavor. That keeps it from offering a piece whose folder isn't bundled; a
   missing asset would fail at open.
4. **iOS.** Add schemes `violin` and `mandolin`, plus build configurations
   `Debug-violin`, `Release-violin`, `Debug-mandolin`, `Release-mandolin` and the
   matching `ios/Flutter/*-<flavor>.xcconfig`, setting
   `PRODUCT_BUNDLE_IDENTIFIER` and `PRODUCT_NAME` / `CFBundleDisplayName` (via a
   build setting in `Info.plist`). Each flavor needs its own app icon set
   (`AppIcon-violin`, `AppIcon-mandolin`). Mandolin needs a new App ID and
   provisioning; see the "new device / provisioning" notes. This needs the paid
   Apple Developer team, as TestFlight does anyway.
5. **Android.** In `android/app/build.gradle.kts`, add
   `flavorDimensions += "app"` and `productFlavors { create("violin") {...};
   create("mandolin") {...} }`, each with its own `applicationId` and a
   `resValue("string", "app_name", ...)`. Point `android:label` at
   `@string/app_name`.
6. **macOS / web.** macOS takes the same schemes as iOS. Web has no flavors:
   build it with `--dart-define=APP=violin` and have `AppConfig` fall back to
   that when `appFlavor` is null.
7. **Scripts.** `scripts/dev_run.sh` and `scripts/device_install.sh` take
   `--flavor` (default `violin`) and pass it to `flutter run` / `flutter build`.
   The build stamp gains the flavor, so the AppBar shows which app is live.
8. **Data on existing devices.** The violin bundle id is unchanged, so
   installed libraries carry over. The mandolin app starts empty, apart from
   whatever the dev-library sync pushes. `sync_dev_library.sh` needs the
   bundle id per flavor.
9. **Docs.** Cover flavors in CLAUDE.md (dev server, device install, which
   simulator for which app) and in the README.

## Content split (first cut)

- **violin:** Lightly Row, The Happy Farmer, Gavotte (Gossec), plus more
  public-domain Book 1 repertoire as clean encodings are added (Song of the
  Wind, Go Tell Aunt Rhody, O Come Little Children, May Song, Long Long Ago,
  the Bach minuets).
- **mandolin:** Old Joe Clark, The Wellerman, Galopede, Salt Creek
  (`docs/salt_creek.abc`, to be bundled as a real piece rather than
  `audioOnly`).

## Verification

- `flutter build ios --flavor violin` and `--flavor mandolin`; `flutter build
  apk --debug --flavor mandolin`. Each installs side by side on one simulator.
- Each app's piece list shows only its own catalog entries. The release guard's
  pubspec-flavors check passes.
- The violin app opens in violin-fingering mode, and the mandolin app in fret
  mode.
