# Mandolings: the mandolin as a second app, by flavor

An experiment on `next_gen` (step 5b in
[`../libraries-migration.md`](../libraries-migration.md)). One codebase, one
Runner, and two installable apps that can sit side by side on one phone:

| Flavor | Name on the home screen | iOS bundle id / Android applicationId | Instruments |
|---|---|---|---|
| `stringlings` (default) | Stringlings | `name.howison.violinPracticeCompanion` (unchanged) | violin, viola |
| `mandolin` | Mandolings | `name.howison.violinPracticeCompanion.mandolin` | mandolin only |

The user chose flavors over a separate `apps/mandolin` target: it proves the
product split with almost no native work, and leaves the bigger move (below)
for when it is wanted.

## Running each flavor

```bash
# Simulator, with the fifo dev server (a pipe of its own per session):
FLUTTER_FLAVOR=mandolin FLUTTER_FIFO=/tmp/flutter_ctl_mandolin bash scripts/dev_run.sh dev-ipad
bash scripts/dev_run.sh dev-iphone-se                 # stringlings, as before

# By hand:
flutter run -d dev-ipad --flavor mandolin
flutter run -d dev-ipad                               # = --flavor stringlings
flutter build ios --simulator --debug --flavor mandolin
flutter build apk --debug --flavor mandolin           # build/app/outputs/flutter-apk/app-mandolin-debug.apk
```

`pubspec.yaml` sets `default-flavor: stringlings`, because Android's
`productFlavors` need a flavor on every build. So a plain `flutter run` or
`flutter build` (no `--flavor`) still builds Stringlings, on both platforms,
and the existing scripts keep working unchanged: `device_install.sh` builds
`flutter build ios --release`, which is now the `Release-stringlings`
configuration with the same bundle id, team and output path.

`dev_run.sh` passes `FLUTTER_FLAVOR` through as `--flavor`. For a flavor other
than stringlings it skips the dev-library sync, whose scripts know only
Stringlings' bundle id.

## How it is wired

**Android** (`android/app/build.gradle.kts`): a flavor dimension `edition` with
`stringlings` and `mandolin`. Mandolin adds `applicationIdSuffix = ".mandolin"`.
Each sets the label as `manifestPlaceholders["appName"]`, which the manifest
reads as `${appName}`. (`resValue` would need `buildFeatures.resValues`, which
AGP now turns off by default; the build failed on it.)

**iOS** (`ios/Runner.xcodeproj`):

- Six build configurations beside Debug/Release/Profile:
  `Debug-stringlings`, `Release-stringlings`, `Profile-stringlings`, and the
  same for `mandolin`. Each copies its base's settings, so signing stays
  automatic with team V8MB2893V6.
- Two shared schemes, `stringlings` and `mandolin`, named after the flavors
  (Flutter picks the scheme by flavor name). The `Runner` scheme is kept, on
  the plain configurations, for opening the project in Xcode.
- The flavor's settings live in `ios/Flutter/<flavor>.xcconfig`:
  `PRODUCT_BUNDLE_IDENTIFIER` and `APP_DISPLAY_NAME`. Info.plist's
  `CFBundleDisplayName` is `$(APP_DISPLAY_NAME)`. `CFBundleName` stays
  `Stringlings` in both, since it is limited to 15 characters and not shown on
  the home screen.
- `Debug-<flavor>.xcconfig` and `Release-<flavor>.xcconfig` include CocoaPods'
  per-configuration file, `Generated.xcconfig` and the flavor file. Profile
  uses the Release file, as Flutter's template does. The plain
  `Debug.xcconfig` and `Release.xcconfig` include `stringlings.xcconfig`.
- The flavor configurations of the Runner target leave out
  `PRODUCT_BUNDLE_IDENTIFIER`, so the xcconfig's value applies.
- The Podfile maps the new configurations to `:debug` or `:release`.
  CocoaPods re-sorted `project.pbxproj` on its first `pod install` after the
  change; that churn is generated, not hand-made.

**Dart** (`lib/models/app_edition.dart`): `AppEdition { stringlings, mandolin }`
from Flutter's `appFlavor`, through `appEditionProvider`, which tests
override. No flavor, or an unknown one, is Stringlings: that covers tests, the
harness and a run from Xcode's Runner scheme.

## What differs, and the one place it is decided

`instrumentsOffered(edition)` in `lib/services/instrument_setting.dart` (and
`instrumentsOfferedProvider`) answers "which instruments does this edition
offer". The first in the list is the default. Everything else asks it:

- **`instrumentSetProvider`** reads the stored setting through
  `instrumentFromStored`. A value the edition doesn't offer reads as the
  default. So the tuner, the instrument profile and layer, frets, tab and
  chords all follow without being touched.
- **Settings** shows the edition's choices. With a single choice (the mandolin
  app) the whole Instrument section is hidden.
- **Add a player** offers the same choices, and hides them with only one. A
  new player gets the default.
- **A player's instrument**, as listed in Settings, is read the same way.

Per edition:

- **Stringlings:** violin and viola. Mandolin is gone from every choice. A
  stored `mandolin` (or the legacy `violinAndMandolin`) reads as the violin.
  **The stored value is left alone**, not rewritten, so a future migration can
  still see it. A shipped version would need a real migration story for
  existing mandolin users: tell them, point them at the new app, perhaps
  carry their pieces over. The experiment just falls back.
- **Mandolings:** the mandolin, whatever is stored. No instrument choice
  anywhere. The tuner is the mandolin's: courses, pairs and the headstock.
- **The app's name** comes from `AppEdition.appName`, Stringlings or
  Mandolings: the `MaterialApp` title, the tablet piece list's badge, the
  privacy note in Settings and the tuner's microphone message. The Thanks
  screen, licences and PDF creator still say Stringlings: they are about the
  project, which keeps its name.
- **Library and catalog:** the same pieces. The catalog has no `instruments`
  tags yet, and the mandolin plays the violin repertoire as it is.
- **Icons:** the same. A second icon set is optional and was skipped.

## What a real `apps/mandolin` target would still need

A flavor shares everything native. A separate Flutter app under `apps/` would
have its own `ios/` and `android/` projects. The hand-registered native code
lives in this app's Runner and `MainActivity` today:

- iOS (`ios/Runner/`): `VideoTransportPlugin`, `AudioRoutePlugin`,
  `AudioCalibrationPlugin`, `MediaToolsPlugin`, `IncomingSharePlugin`,
  `BundledAssetPlugin`, plus `AppDelegate`'s play-and-record session, which
  `app_audio_session.dart` must match.
- Android (`android/app/src/main/kotlin/…`): `MediaToolsPlugin`,
  `ContentResolverPlugin`, `IncomingSharePlugin`, `BundledAssetPlugin`,
  registered in `MainActivity.kt`.

Each would have to become a plugin package, as `audio_decoder` did in step
5a, or be copied into the second Runner. Copying means two copies of the
AirPlay and calibration fixes in CLAUDE.md's audio section, which is not
worth it. `practice_core` (`libraries.md`) is where the Dart side would go.
The Info.plist usage strings, the document type, the Podfile settings
(static linkage for onnxruntime) and the Gradle workarounds would also be
duplicated. Until there is a reason to diverge natively, the flavor is the
cheaper shape.

## Verified (2026-11-21)

- `dev-ipad`: Mandolings ran from `--flavor mandolin` with the stamp checked
  through Marionette. The piece list badge said Mandolings, Settings had no
  Instrument section, and the tuner was the mandolin's (paired courses, the
  headstock). Then a plain `dev_run.sh` (no flavor) ran Stringlings: Settings
  offered Violin and Viola, and no Mandolin. Both icons sat on the home screen
  as "Stringlings" and "Mandolings", neither truncated on the iPad.
- `flutter build ios --simulator --debug` with each flavor, and
  `flutter build apk --debug` with `--flavor mandolin` and with no flavor:
  `app-mandolin-debug.apk` (package `…mandolin`, label Mandolings) and
  `app-stringlings-debug.apk` (today's package, label Stringlings). Not run on
  the emulator, which another session was using.
- Not tried: a physical device, a release or TestFlight build of Mandolings.

## Open questions

- **App Store listing.** Mandolings would be a second App Store Connect app
  record: its own name, listing, screenshots, privacy answers and TestFlight
  group. `scripts/push_listing.py` and `docs/app-store-listing.md` know one
  app; they would need an app id per flavor. Before any device or TestFlight
  build, the `.mandolin` bundle id has to be registered: Xcode's automatic
  signing can do it with `-allowProvisioningUpdates`. Not tried here: only
  simulators were used. The Android Play listing would be a second package as
  well.
- **Shared data between the two apps.** None: separate containers, so
  separate pieces, recordings, players and prefs. Sharing would need an App
  Group on iOS and a shared user id or content provider on Android. Is a
  family with both a violinist and a mandolinist better served by one app
  with players (as on `main`) than by two apps?
- **`.stringlings` share files.** Both apps declare themselves Owner of the
  same document type (`name.howison.violinPracticeCompanion.piece`), so iOS
  picks one when a file is opened. Should Mandolings get its own extension,
  or should both accept both, with the share sheet offering either?
- **The dev library.** `sync_dev_library.sh` and the pull/push scripts
  hard-code Stringlings' bundle id (as do `pull_sync_trace.sh`,
  `pull_tuner_sessions.sh`, `sim_add_media.sh` and the Android dev-library
  script), so Mandolings is never synced. They would take a bundle id from
  the flavor. A second app on one device would also need its own base pref,
  or the three-way merge would treat it as a new device.
- **Existing mandolin users of Stringlings** (above): a migration, or keep the
  mandolin in Stringlings too until Mandolings ships.
