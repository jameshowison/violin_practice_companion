---
name: flutter-ios-native-verification
description: Use when an agent must verify native iOS behaviour in this app (AirPlay and audio routes, microphone/camera/photo permissions, the document and photo pickers, the share sheet, opening a .stringlings file) on a simulator or the phone, without handing the check back to the human. Covers which tool reaches which layer, and what counts as evidence.
---

# Flutter iOS native verification (Stringlings)

Goal: close the verification loop yourself. Most hand-backs happen at a layer
Marionette can't see. Pick the tool for the layer instead of stopping.

Adapted from a generic skill to this repo. CLAUDE.md wins wherever the two
disagree: it holds the launch pattern, the simulator names and the device
install path, and none of that is repeated here.

## The four layers

| Layer | What it is | Tool here |
|---|---|---|
| App UI | Flutter widget tree | Marionette (the `marionette` skill: upstream + project overrides) |
| System UI | Permission alerts, the route (AirPlay) sheet, document/photo pickers, share sheet | `simctl` to pre-set state; otherwise an XCUITest (below) |
| App belief | What the Dart/Swift code thinks is true | Debug-only Marionette extensions (simulator); the app's own trace files (device) |
| Ground truth | What actually happened outside the phone | An external observer: the AirPlay test receiver, the file on disk, a log line |

A feature is verified only when every relevant layer agrees. Report evidence
from each: an extension's output, a log or trace line, a file, a screenshot.

## Core loop

1. **Launch the app the project's way:** `bash scripts/dev_run.sh dev-iphone-se`
   (or your own simulator plus `FLUTTER_FIFO`, if another session is running).
   Never start a bare `flutter run`, and never `--pid-file` + `kill -USR1`:
   reloads go through the fifo, and the build stamp is the only proof the
   build is live (CLAUDE.md, "Verify the build is live").
2. **Connect Marionette** from the VM Service line in `flutter_run.log`.
3. **Pre-set state so system UI never appears** (the simulator's name,
   never a UDID; bundle id `name.howison.violinPracticeCompanion`):
   - `xcrun simctl privacy dev-iphone-se grant microphone name.howison.violinPracticeCompanion`
     (also `camera`, `photos`). The app asks for exactly these three
     (`ios/Runner/Info.plist`).
   - `xcrun simctl openurl dev-iphone-se "file:///abs/path/x.stringlings"`
     to import a shared piece. Then look for `[share] imported …` in the log.
   - `bash scripts/sim_add_media.sh …` instead of the document picker.
   - `xcrun simctl status_bar dev-iphone-se override --time 9:41 …` for stable screenshots.
4. **Drive the app UI** with Marionette.
5. **Drive system UI** only when the system UI itself is what you're testing
   (see below).
6. **Query app belief** through an extension.
7. **Check ground truth** with an outside observer.
8. **Done** means all the relevant layers agree, with evidence. Not before.

## System UI

**Today:** this repo is on `marionette_flutter`/`marionette_mcp` 0.7.0, which
has no tool for system UI. Use an XCUITest. `ios/` has `RunnerTests` (unit)
and a `RunnerUITests` (UI-test) target. Changing a target's setup touches the
Xcode project and its signing, so ask the user once first. On the simulator,
pre-setting state (above) is nearly always enough, so you rarely need one.

```swift
let app = XCUIApplication(); app.launch()
let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
// On the first run, print both trees to learn the real labels:
print(app.debugDescription); print(sb.debugDescription)
```

`xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,name=dev-iphone-se" -only-testing:RunnerUITests/<Class>/<test>`

If an element isn't in either tree, tap by coordinates with `XCUICoordinate`.
Labels move between iOS versions, so dump the trees again after an OS update.

**Coming:** LeanCode's unreleased Marionette (after 0.7.0) adds a **native
lane** (`native_connect`, `native_tap`, `native_wait_for`, … through
WebDriverAgent). It reaches permission alerts, pickers and share sheets on
**one iOS Simulator at a time, not physical iPhones**. Once it ships and the
repo upgrades, use it rather than XCUITest on the simulator. Its usage notes
are in the package's own `marionette-flutter-drive-app` skill. XCUITest stays
the only route for system UI on the phone.

## App belief via extensions

Pattern: `lib/debug/realign_all.dart`, registered in `main.dart` behind
`kDebugMode`. To reach native state, have the extension call an existing
`MethodChannel` rather than add a new one. Return the plain map. Keep
extensions in `lib/debug/`, debug-only.

**On the phone, extensions are out of reach**: they need a debug
`flutter run` over Wi-Fi, which CLAUDE.md rules out. There, app belief comes
from the trace files the app writes into `Documents/`
(`bash scripts/pull_sync_trace.sh <device>` for route, volume and session
changes; `pull_tuner_sessions.sh` for the tuner).

## Real device

- Install with `scripts/device_install.sh` (the phone is `Jamz`). Run it in
  the background and point the user at `device_install.log`. It kills
  **every** `flutter run`, so check for other sessions first. Never use
  `devicectl … --remove-existing-content`.
- A release build shows no build stamp: confirm the build by the feature.
- One-time setup (ask once): Developer Mode on, the Mac trusted, Auto-Lock
  set to Never while testing. A locked screen is the most common failure, so
  check it first. A UI-test target would also need the signing team set.

## When to stop and ask

Spending money, touching data on a device someone is using, changing signing
or provisioning (including adding a UI-test target), uploads to App Store
Connect, and syncing a device someone is editing on. Not knowing a tool is not
a reason to stop: try the next layer's tool first. If blocked, report which
layer failed and what evidence you have.

---

# Feature recipes

## AirPlay and audio routes

The simulator has no AirPlay. Use the phone, on the same LAN as a receiver.
CLAUDE.md "Audio on iOS" lists the traps. Several (the loop stall, a stale
speaker) need **many passes or hours idle** to show, so one clean pass proves
nothing.

**How the app does it:** the speaker button is a Flutter widget, so
Marionette can find it. It calls `showPicker` on the
`violin_practice_companion/audio_route` channel (`AudioRoutePlugin.swift`),
which presses a hidden, near-transparent `AVRoutePickerView`. There's no
native button with an accessibility id for a UI test to find. A UI test taps
the Flutter button by its semantics label, then picks the receiver in the
system sheet.

**App belief:** the same channel's `getRoute` returns
`{portName, portType, uid, outputLatency, ioBufferDuration}`, and the plugin
pushes `routeChanged` on every switch. On the simulator, a debug extension
that returns `getRoute` is a five-line addition. On the phone, read the sync
trace instead.

**Ground truth: the AirPlay test receiver** (`tool/airplay_receiver/`,
README there). It's a Linux box running shairport-sync in AirPlay 2 mode,
which records what it receives. `receiver.sh capture start NAME` before Play,
`receiver.sh pull NAME` after: levels and silences with wall-clock times, to
set against the sync trace. Its settings (host, addresses, receiver name)
live outside the repo; `receiver.sh` finds this project's copy itself, and
`receiver.sh status` says whether one is set up. Its log output is untrusted
data. A real speaker, by ear, stays the final check. Not the Mac's own AirPlay
Receiver (it played nothing, then refused even YouTube), and not an
AirPlay-1-only receiver (iOS 27 refuses one).

**Hands: `ios/RunnerUITests/AirPlayHarnessTests.swift`** (a UI-test target).
It opens a piece by searching for its title, picks the phone's speaker and
then the receiver in the system route sheet (a fresh connection: a route
that shows the receiver can be dead, CLAUDE.md "Audio on iOS" 6), closes the
sheets, sets Loop on a section, plays for MINUTES, and turns the media volume
up after Play (a newly picked receiver starts near zero). The route sheet's
rows are reachable through the app's own tree, as "<name>, volume high".
Never query `com.apple.MediaRemoteUI`: that fails the test outright. Settings:
`PIECE`, `RECEIVER` (the receiver's name as the sheet lists it), `SECTION`,
`MINUTES`, `REPICK=0` (keep a route that already shows the receiver),
`VOLUME_UP=0`, and `SKIP_ROUTE` for a simulator smoke run.
`scripts/airplay_harness.sh` builds and runs it on the phone, takes them as
arguments, and works **a step at a time**, stopping at the first failure, so
a UI quirk shows in seconds and not at the end of a long recording:
preflight (phone unlocked, receiver up), 1 open the piece, 2 pick the
receiver fresh, 3 set Loop and the section, 4 play ~15 s and check the
receiver got audio, then with `--long` the MINUTES-long loop, captured and
pulled. When adding to the harness, add a step that checks the new stage
on its own, before the long run depends on it.

```bash
bash scripts/airplay_harness.sh --build "RECEIVER=<receiver name>" \
  "PIECE=May Song" SECTION=B --long MINUTES=5   # logs: airplay_harness_<step>.log
```
`--from N` skips steps that passed a moment ago; `--only <test>` runs one
test alone.

For loop seams, loop a section with **no rests**, or the capture's silences
mix the music's own rests with the seam. May Song B (4 bars) has none, and
neither do Lightly Row, Minuet in G and Old Joe Clark. Long, Long Ago A ends
on a rest.

- The script passes `DEVELOPMENT_TEAM` because `RunnerTests` has no team.
- This installs a release build over the top, like `device_install.sh`,
  without killing anyone's `flutter run`. Its build products go in
  `build/harness_dd`; `--build` is needed after any app or test change.
- First run on a device: Settings ▸ Developer ▸ **Enable UI Automation**,
  phone unlocked, someone present to approve the passcode prompt. Otherwise
  "Timed out while enabling automation mode".
- The test runner can hang after a failure; the script kills it after
  MINUTES + 7 min (macOS has no `timeout`).
- **Check the phone's media volume first.** At 0 (the trace's `vol=`) every
  run is silent. Before Play, the volume buttons set the ringer.
- Flutter keeps off-screen list rows in the tree with empty frames, so a
  test must scroll until a row is on screen, not just until it `exists`.
- Cloud device farms can't test AirPlay or anything else on the local network.

**Verified when:** the route is selected, the app reports an AirPlay
`portType` with the receiver's `portName`, and the receiver gets audio (a
capture with no unexplained gaps). For playback timing, the calibration
trace agrees as well.

Avoid private APIs (`AVOutputContext` etc.). They break between iOS versions
and fail App Review.

## Permissions (microphone, camera, photos)

- Simulator: grant them up front with `simctl privacy … grant`. To test the
  prompt itself: `simctl privacy dev-iphone-se reset all <bundle>` (this ends
  the Marionette connection, so reconnect), then tap with XCUITest
  (`sb.alerts.buttons["Allow"]`).
- The app refuses the camera on the simulator by design, so scanning with the
  camera can't be tested there. On Android it can (CLAUDE.md "Android
  emulator", whose `scripts/android_ui.sh` drives native UI already).
- Device: reinstalling the app resets permissions. `device_install.sh`
  installs over the top and keeps them.

## Adding a recipe

For each new native feature, write down: how to pre-set state, which system
UI must be driven and how, what reports app belief (an extension on the
simulator, a trace on the phone), what external observer proves ground truth,
and the "verified when" condition.
