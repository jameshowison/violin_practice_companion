# Brief: take the Google document scanner out of the Android build

**For a fresh session in the app repo.** The title-OCR work (commit 44520a2,
`docs/title_ocr.md`) has to be on the branch you start from, so check
`git log --oneline | grep "PaddleOCR on both platforms"` first.

## Why

`docs/plan.md` ("Android goes cleanly GPL") lists two closed Google components
in the Android APK. Title recognition (ML Kit text recognition) is gone. This
is the other one.

`flutter_doc_scanner` on Android uses `play-services-mlkit-document-scanner`.
Its UI and processing run inside Google Play Services, but a closed client
library still ships in our APK. Play Services is a Google app, not part of
Android, and it's absent on de-Googled and Huawei phones. Since text
recognition went, this scanner is also the only reason the APK still carries
`com.google.mlkit.common` and the Firebase data transport, which tries to send
usage logs to `firebaselogging.googleapis.com`. `docs/privacy.md` discloses
that today. Removing it should make the Android build GPL-clean and meet
F-Droid's no-proprietary-dependency rule, and the privacy paragraph can go.

## The constraint that shapes the design

**A Flutter plugin can't be dropped for one platform.** As long as
`flutter_doc_scanner` is in `pubspec.yaml`, its Android half links the ML Kit
scanner into the APK, whatever the Dart code calls. So the dependency has to
go entirely, and iOS needs its own replacement.

Beware look-alikes: other Flutter document-scanner plugins
(`cunning_document_scanner`, `google_mlkit_document_scanner` and others) are
ML Kit on Android too. Before adopting any plugin, read its
`android/build.gradle` dependencies.

## Recommended design (confirm the open questions with the user first)

All of this is in `lib/services/omr_service_io.dart`, `_acquireFromCamera`,
around line 120. The photo, file and PDF sources and the crop step
(`_cropToMusic`, image_cropper/uCrop) are untouched.

- **iOS: keep VisionKit, without the plugin.** Write an app-local
  `ios/Runner/DocumentCameraPlugin.swift` that presents
  `VNDocumentCameraViewController` and returns each page as a JPEG. Register
  it in `AppDelegate.swift` like `BundledAssetPlugin`.
  - VisionKit is an OS framework, so it counts as a GPL-3 §1 System Library.
    `docs/explore.md` §9 records why the full VisionKit scanner stays: its
    edge detection, perspective correction and contrast cleanup were clearly
    better than the plugin's auto-capture mode.
  - **Trap:** a new Swift file has to be added to the Runner target in
    `ios/Runner.xcodeproj/project.pbxproj`, with a file reference, a build
    file, a group entry and a Sources phase entry. Copy the four lines of an
    existing plugin such as `BundledAssetPlugin.swift`.
  - Check `VNDocumentCameraViewController.isSupported` and return a channel
    error instead of presenting. Today the simulator crash is avoided through
    `device_info_plus` (`_isPhysicalDevice`). As of 44520a2 that is the
    package's only use, so it can go too.
  - Match today's output: JPEG pages in order, and cancel returns null.
    Return bytes or temporary files that the Dart side deletes.
    `StorageCleanup._scannerOutput` (`lib/services/storage_cleanup_io.dart`
    around line 87) matches the old plugin's file names; update or remove it
    to fit.
- **Android: the system camera app, then the existing crop.**
  `ImagePicker().pickImage(source: ImageSource.camera)` (image_picker is
  already a dependency) sends an intent to whatever camera app the phone has.
  That pulls in no Google library, and uCrop already follows.
  - **What's lost:** automatic edge detection, perspective correction and
    contrast cleanup. The user's crop replaces the first. homr_flutter
    already applies CLAHE and its own staff dewarping, so check the result
    on a real photo before adding anything.
  - **Open question for the user: multi-page.** The ML Kit scanner allowed
    several pages per session. Options: (a) one page per camera scan, with
    multi-page through Photos; (b) after each crop, ask "Add another page?"
    and loop. Ask; don't assume.
  - The fallback if the intent route proves poor is a capture screen built
    on the `camera` package, which is CameraX, open, and already used for
    teacher videos. That's more UI work, so take it only if needed.
- **Put the platform difference behind a façade.** Follow CLAUDE.md's smell
  checklist: no new `Platform.is*` in shared code. A small
  `document_camera.dart` plus `document_camera_io.dart`, or a channel with
  per-platform handlers, keeps `omr_service_io.dart` simple. On Android the
  "native" side can just be the Dart image_picker call.
- **`ContentResolverPlugin.kt`** exists only for the scanner's `content://`
  URIs. As of 44520a2 its one caller is `_resolveToFile`, and only
  `_acquireFromCamera` calls that. If the new camera path returns plain
  files, which image_picker does, delete the plugin, its `MainActivity.kt`
  registration and `_resolveToFile` as well.

## Verification

1. **No closed Google code left in the APK.** Build
   `flutter build apk --release --target-platform android-arm64`, then run:

   ```bash
   unzip -p build/app/outputs/flutter-apk/app-release.apk 'classes*.dex' | strings \
     | grep -oE "Lcom/google/(mlkit|firebase|android/gms|android/datatransport)[A-Za-z_/]{0,30}" \
     | cut -d/ -f1-5 | sort | uniq -c
   cd android && ./gradlew :app:dependencies --configuration releaseRuntimeClasspath \
     | grep -iE "gms|firebase|mlkit|datatransport"
   ```

   Before this change the first command shows `mlkit/common`,
   `mlkit/vision/documentscanner` and `firebase/components`. Afterwards it
   should show none of them. If any `gms` remains, find which plugin brings
   it and report it; don't silently accept it.
2. **The Android flow on the emulator.** `dev-android` has a virtual camera
   scene, and CLAUDE.md's "Android emulator" section explains how an agent
   drives native UI (`scripts/android_ui.sh`: `ui_tap`, `ui_wait`; uCrop's
   corner-drag traps). Run Scan → camera → shutter → crop, and check that a
   piece is created and gets a title.
3. **iOS.** The simulator should show the friendly "needs a real device"
   message, with no crash. A real VisionKit scan needs a phone: build with
   `scripts/device_install.sh` and ask the user to scan one page. That script
   kills every `flutter run`, so check for other sessions first.
4. `flutter test`, both normally and with `VPC_RESTRICTED_DIR=/nonexistent`.
   Then `bash scripts/content_audit.sh` and the smell checklist after
   committing.

## Docs to update when done

- `docs/privacy.md` line 13: delete the Google-diagnostics paragraph if
  check 1 comes back clean.
- `CLAUDE.md`:
  - line ~155, "the Play Services scanner runs against the emulator's virtual
    camera scene", becomes the camera app;
  - lines ~181–183, the scanner and Firebase note.
- `README.md` lines ~498 and ~731 (scan pipeline).
- `docs/plan.md` ~208–219: mark the scanner done, and note that the Android
  build has no proprietary dependencies, if check 1 confirms it.
- `docs/explore.md` §9: add a line saying VisionKit now runs through the
  app's own plugin.
- `assets/engine/licenses/android_libraries.txt`: remove the Firebase and
  data-transport entries if they've left the APK. Regenerate or check that
  list against the new dependency tree.
- The comments in `lib/services/omr_service*.dart` and `pubspec.yaml` that
  mention `flutter_doc_scanner` or `device_info_plus`.

## Rules worth repeating

- Never name the method book or its numbering anywhere in the repo, including
  commit messages.
- Scans and photos of printed pages never go in the repo.
- Platform differences go behind `*_io.dart` façades or `lib/ui/adaptive/`.
- Use one worktree per session, with its own simulator and fifo; CLAUDE.md
  has the dev-server pattern.
