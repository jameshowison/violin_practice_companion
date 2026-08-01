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
flutter build ios --no-codesign  # iOS
flutter build macos          # macOS
flutter build web            # Web / PWA
```

iOS requires an Apple developer account for device installation. The web build
works on iPhone Safari as a PWA with no account required. For the day-to-day
simulator loop, see [From a cold Mac to the app on the iPad
simulator](#from-a-cold-mac-to-the-app-on-the-ipad-simulator) below.

The scan-to-MusicXML (OMR) feature requires the sibling `homr_flutter` repo and
its ONNX models — see [OMR (Scan-to-MusicXML)](#omr-scan-to-musicxml) below. It
is not available on the web build.

## Simulator names

The docs and scripts refer to two simulators by name rather than by UDID:

| Name         | Device                |
| ------------ | --------------------- |
| `dev-iphone` | iPhone 17             |
| `dev-ipad`   | iPad Pro 11-inch (M5) |

These are ordinary simulators that have been *renamed*. Both `simctl` and
`flutter -d` accept a device name wherever they accept a UDID, so the name is
all you ever need to type:

```bash
xcrun simctl boot dev-ipad
xcrun simctl io dev-ipad screenshot shot.png
flutter run -d dev-ipad
```

UDIDs are per-machine, so on a new Mac set the names up once — pick whatever
iPhone/iPad you actually have and rename them:

```bash
xcrun simctl list devices available          # find the UDIDs
xcrun simctl rename <iphone-udid> dev-iphone
xcrun simctl rename <ipad-udid>   dev-ipad
```

The rename is stored with the device, so it survives reboots and shows up in
Xcode too. Nothing else needs to change. If you have no suitable device,
create one (`xcrun simctl create dev-ipad "iPad Pro 11-inch (M5)"`); if the iOS
runtime is missing entirely, install it with `xcodebuild -downloadPlatform iOS`.

Renaming hides the hardware model, so to check what a `dev-*` name actually is:

```bash
xcrun simctl list devices -j | grep -B2 dev-ipad     # deviceTypeIdentifier
```

`flutter -d` matches an exact name or a **name prefix**, not a substring — so
`-d dev-ip` is ambiguous across the two, and `-d ipad` matches neither.

## From a cold Mac to the app on the iPad simulator

The full sequence after a reboot. Nothing here survives a restart, so it's all
of it, in order.

**1. Point the command-line tools at Xcode.** Only needed once per machine, but
it's the failure that looks like everything else being broken:

```bash
xcode-select -p          # should print .../Xcode.app/Contents/Developer
# if it prints /Library/Developer/CommandLineTools:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

**2. Boot the iPad.** A reboot shuts every simulator down, and `flutter devices`
only lists *booted* ones — so this comes before anything Flutter-side:

```bash
xcrun simctl boot dev-ipad
open -a Simulator          # bring the simulator window up
```

Wait for it to reach `Booted` (the first boot after a restart is the slow one):

```bash
xcrun simctl list devices | grep dev-ipad   # want "(Booted)"
```

No `dev-ipad` on this machine? See [Simulator names](#simulator-names) above.

**3. Confirm Flutter sees it:**

```bash
flutter devices          # dev-ipad should now be in the list
```

**4. Fetch packages and stamp the build:**

```bash
flutter pub get
bash scripts/gen_build_info.sh    # writes lib/build_info.dart
```

`build_info.dart` is gitignored, so it won't exist on a fresh clone and the
build fails without it. It puts the git hash + timestamp in the AppBar on debug
builds, which is how you tell which build is actually live.

**5. Launch the dev server** on the iPad. The helper script does the fifo dance
from `CLAUDE.md` (kill any existing run, boot the device, open the control
pipe):

```bash
bash scripts/dev_run.sh dev-ipad     # omit the argument for dev-iphone
```

Or by hand, if you want the run in your own shell:

```bash
rm -f /tmp/flutter_ctl && mkfifo /tmp/flutter_ctl
flutter run -d dev-ipad < /tmp/flutter_ctl 2>&1 | tee flutter_run.log &
exec 3>/tmp/flutter_ctl     # hold the pipe open so the fifo doesn't close
```

**6. Watch it come up.** The first build after a reboot is a cold one — a couple
of minutes is normal:

```bash
tail -f flutter_run.log
```

You're up when the log prints `Flutter run key commands` and a `VM Service`
URL.

**7. Drive it from there.** Treat `flutter run` as a dev server for the rest of
the session rather than restarting it:

```bash
echo "r" > /tmp/flutter_ctl    # hot reload — keeps widget state
echo "R" > /tmp/flutter_ctl    # hot restart — resets state
```

A full relaunch (steps 4–5 again) is needed for changes to `main()`,
`pubspec.yaml`, or **anything under `assets/`** — assets are baked into the
`.app` at `flutter run` time, so a hot restart will keep serving the old one.

To screenshot the running iPad, including the notation WebView, see
[Screenshots & UI debugging](#screenshots--ui-debugging-ios-simulator) below —
`xcrun simctl io dev-ipad screenshot shot.png`.

## Screenshots & UI debugging (iOS Simulator)

The staff is rendered by OSMD inside a `WKWebView` (a Flutter "platform view").
Tools that screenshot via Flutter's `RepaintBoundary.toImage()` — including the
Marionette MCP used for agent-driven UI inspection — capture platform views as
**blank white** (a Flutter engine limitation; see `CLAUDE.md`). So they can
verify the surrounding Flutter chrome but **not** the notation itself.

To capture what's actually on screen, including the WebView, screenshot the
simulator's framebuffer directly:

```bash
xcrun simctl io booted screenshot screenshot.png        # the running sim
# or target one by name, if several are booted:
xcrun simctl io dev-ipad screenshot screenshot.png
```

The raw image is in the device's native (portrait) orientation, so if the app
is running in landscape the PNG comes out rotated 90°. Correct it with the
built-in macOS tool:

```bash
sips -r 90 screenshot.png
```

For a quick manual capture you can also use Simulator.app → **File ▸ Save
Screen** (⌘S), which writes a PNG to the Desktop.

This is the only reliable way to verify staff/notation rendering — beaming,
accidentals, the playback cursor — that the WebView draws.

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

See `docs/explore.md` for the development history and decisions made so far,
and `docs/plan.md` for the remaining roadmap.

## OMR (Scan-to-MusicXML)

The "scan a page" feature is powered by [`homr`](https://github.com/liebharc/homr),
ported to a self-contained on-device Flutter package (`homr_omr`) and consumed
as a sibling path dependency:

```yaml
homr_omr:
  path: ../homr_flutter/packages/homr_omr
```

This means **the `homr_flutter` repo must be checked out next to this one**
(as a sibling directory) for `flutter pub get` to resolve.

Pipeline (`lib/services/omr_service*.dart`): document scan
(`flutter_doc_scanner`) → binarize (`preprocessImage`) → crop to the music
region (`image_cropper`) → on-device ONNX inference (segmentation +
transformer recognition) → assembled MusicXML, parsed by `MusicXmlParser` into
a `ParsedPiece`.

**Mobile/desktop only.** `flutter_onnxruntime` and `flutter_doc_scanner` don't
support web, so `omr_service.dart` conditional-imports a stub on web
(`omr_service_web.dart`) that throws `UnsupportedError`. A server-side `homr`
(Python) backend for a future web/laptop-camera path is planned but not built.

**Platform requirements** (set by `flutter_onnxruntime`):
- iOS deployment target 16.0+
- macOS deployment target 14.0+

**Models** (~147MB of FP16 ONNX weights, AGPL-licensed via `liebharc/homr`) are
fetched by `homr_flutter/tools/fetch_models.py` into
`homr_flutter/packages/homr_omr/assets/models/` and bundled as package assets —
run that script once in the sibling `homr_flutter` checkout before building.

OMR accuracy on Suzuki Book 1 (homr_flutter, 2026-06-09): **17/18 perfect**
(SER=0%). Full findings in `homr_flutter/docs/omr_evaluation/`.

## Licence

GPL-3.0. You may use, modify, and redistribute this code freely. You may not
wrap it in a proprietary or subscription product.

## Profile run (logged to a file)

To install and run on the `dev-iphone` simulator in **profile** mode while
capturing all output to a file an agent can read back, run this from the repo
root:

```bash
flutter run --profile -d dev-iphone 2>&1 | tee flutter_profile.log
```

- `--profile` builds the release-grade engine with profiling enabled (no debug
  asserts, no hot reload, and the debug-only Marionette binding is disabled).
- `2>&1 | tee flutter_profile.log` mirrors stdout **and** stderr to the terminal
  and to `flutter_profile.log`, so the agent can `tail`/`grep` that file (e.g.
  `tail -n 50 flutter_profile.log`) without watching the live session.

Swap in another device name from `flutter devices` (e.g. `-d dev-ipad`, or
`-d macos`) as needed. The plain debug dev-server pattern (hot reload via a
fifo) lives in `CLAUDE.md`.
