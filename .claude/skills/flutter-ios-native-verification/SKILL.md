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
| Ground truth | What actually happened outside the phone | An external observer: a test AirPlay receiver, the file on disk, a log line |

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
but **no `RunnerUITests` target yet**. Creating one changes the Xcode project
and its signing, so ask the user once before adding it. On the simulator,
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
- Cloud device farms can't test AirPlay or anything else on the local network.

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
CLAUDE.md "Audio on iOS" lists six traps. Several (the loop stall, a stale
speaker) need **many passes or hours idle** to show, so one clean pass proves
nothing.

**How the app does it:** the speaker button is a Flutter widget, so
Marionette can find it. It calls `showPicker` on the
`violin_practice_companion/audio_route` channel (`AudioRoutePlugin.swift`),
which presses a hidden, near-transparent `AVRoutePickerView`. There's no
native button with an accessibility id for a UI test to find. A UI test taps
the Flutter button by its semantics label, then picks the receiver in the
system sheet. Dump the trees to see where the sheet's rows live.

**App belief:** the same channel's `getRoute` returns
`{portName, portType, uid, outputLatency, ioBufferDuration}`, and the plugin
pushes `routeChanged` on every switch. On the simulator, a debug extension
that returns `getRoute` is a five-line addition. On the phone, read the sync
trace instead.

**Ground truth:** the real receiver (the Kitchen speaker) for a by-ear check.
For a check that needs no ears, a software receiver that logs what arrives:
`scripts/airplay_receiver.sh` (start/stop/freeze/thaw/status/summary), whose
`tool/airplay/pcm_monitor.py` writes one line per 100 ms of audio (level in
dBFS) plus GAP/RESUME when the stream stops. Found on 2026-11-22:

- **iOS 27 refuses an AirPlay-1-only receiver.** Homebrew's shairport-sync
  (no nqptp) shows up in the route sheet, but Jamz said "Unable to connect"
  and never opened a connection. AirPlay 2's nqptp is Linux-only, and Docker
  Desktop can't pass mDNS or PTP to the LAN. A receiver on another LAN host
  was rejected (it would see too much of the home network), so the receiver
  is the Mac's own (System Settings ▸ AirDrop & Handoff ▸ AirPlay Receiver,
  Current User).
- **No tap reaches the Mac's receiver.** It renders in `AirPlayXPCHelper`
  (root), which isn't in a user's Core Audio process list; even a global tap
  recorded silence. So the ear is the Mac's microphone:
  `tool/airplay/tap_monitor.swift` (`swiftc -O … -o /tmp/vpc_airplay/tap_monitor`,
  then `tap_monitor mic /tmp/vpc_airplay/mic.log`; summarize with
  `pcm_monitor.py --summarize … --silent-db -45`, room noise is ~-55 dB).
  It heard the simulator and Jamz's own speaker clearly.
- **The Mac's receiver was too unreliable to test against** (2026-11-22): it
  took streams but played nothing audible, then dropped the connection and
  refused even YouTube until restarted. Use the Kitchen speaker, with the
  mic as the ear if it's within earshot.
- **Check the phone's media volume first.** Jamz's was 0 (the trace's
  `vol=`), so every run was silent. Before Play the volume buttons set the
  ringer, so the test presses them after Play.

**Hands: `ios/RunnerUITests/AirPlayHarnessTests.swift`** (a UI-test target,
added 2026-11-22) opens a piece, picks the receiver in the system route sheet
(its rows are reachable through the app's own tree as "<name>, volume high",
not through SpringBoard; never query `com.apple.MediaRemoteUI`, which fails
the test outright), sets Loop on a section and plays for MINUTES. Settings
come in as `TEST_RUNNER_PIECE`, `_RECEIVER`, `_SECTION`, `_MINUTES` (and
`_SKIP_ROUTE` for a simulator smoke run). On the phone:

```bash
flutter build ios --release --config-only --dart-define=TUNER_RECORDING=true
cd ios && xcodebuild build-for-testing -workspace Runner.xcworkspace \
  -scheme stringlings -configuration Release-stringlings \
  -destination "platform=iOS,name=JamzJamzJamzz" -only-testing:RunnerUITests \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=V8MB2893V6
xcodebuild test-without-building … \
  -only-testing:RunnerUITests/AirPlayHarnessTests/testLoopOnAirPlay
```

- `DEVELOPMENT_TEAM` on the command line because `RunnerTests` has no team.
- This installs a release build over the top, like `device_install.sh`,
  without killing anyone's `flutter run`.
- First run on a device: Settings ▸ Developer ▸ **Enable UI Automation**,
  phone unlocked, someone present to approve the passcode prompt. Otherwise
  "Timed out while enabling automation mode".
- Flutter keeps off-screen list rows in the tree with empty frames, so a
  test must scroll until a row is on screen, not just until it `exists`.

**Verified when:** the route is selected, the app reports an AirPlay
`portType` with the receiver's `portName`, and the receiver gets audio. For
playback timing, the calibration trace agrees as well.

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
