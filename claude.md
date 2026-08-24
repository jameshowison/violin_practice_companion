## Flutter iOS Simulator Dev Server Pattern

Do not use flutter-all:flutter-device-orchestrator to launch the app; it doesn't know the fifo pattern.

Treat `flutter run` as a persistent dev server for the session, not a one-shot command.

Simulators are referred to by name, never by UDID: **`dev-iphone`** (iPhone 17) is the primary dev target, **`dev-ipad`** (iPad Pro 11-inch M5) is the secondary. Both `simctl` and `flutter -d` resolve these names. See the README "Simulator names" section. If a name doesn't resolve, the simulator hasn't been renamed on this machine — check `xcrun simctl list devices` rather than guessing a UDID.

**Start once:**
```bash
bash scripts/dev_run.sh dev-iphone   # kills any existing run, boots the device,
                                     # stamps the build, opens the control pipe
```

By hand, if you want to see the parts — note the **detached** pipe holder.
`exec 3>/tmp/flutter_ctl` holds the write end open only as long as the shell that ran
it, and each Bash tool call is a fresh shell, so a script or tool call that returns
takes the fifo's only writer with it:
```bash
rm -f /tmp/flutter_ctl && mkfifo /tmp/flutter_ctl
nohup sleep 86400 > /tmp/flutter_ctl 2>/dev/null &   # holds the write end open
nohup bash -c 'flutter run -d dev-iphone < /tmp/flutter_ctl > flutter_run.log 2>&1' \
  >/dev/null 2>&1 &
```

**After code edits:**
```bash
echo "r" > /tmp/flutter_ctl   # hot reload (preserves widget state)
echo "R" > /tmp/flutter_ctl   # hot restart (resets all state)
```

**Read output:**
```bash
tail -n 50 flutter_run.log | grep -v "◢\|◤\|════"
```

**Full restart only when necessary:** changes to `main()`, `pubspec.yaml`, or **any file under `assets/`** (HTML, JS, JSON, images). Kill with `pkill -f flutter_tools.snapshot` before relaunching, and recreate the fifo.

> **Why assets need a full restart on iOS:** Hot restart only re-executes the Dart VM — it does NOT rebuild or reinstall the native `.app` bundle. Static assets (including `osmd_bridge.html` and any JS files) are bundled into the `.app` at `flutter run` time and read from there by WKWebView. A hot restart will always serve the old asset. Always do a full restart after editing anything in `assets/`.

**Before a full restart, regenerate build info** — `scripts/dev_run.sh` does this for
you, so a full relaunch is just:
```bash
bash scripts/dev_run.sh dev-iphone   # stamps, kills the old run, relaunches
```

The running git hash + timestamp is shown in the AppBar (debug builds only), so you can confirm which build is live without committing.

**Verify the build is live — do not trust the reload output.**

When a change appears to have no effect, suspect the build before the code.
`Reloaded 0 libraries`, or a sub-second `Restarted application` after an edit you can't
see on screen, means the tool did not compile your change. A `flutter run` inherited
from an earlier session can stop noticing file changes for the rest of its life — and
then every "verification" you do is against old code. This has cost a session ~40
minutes and produced two false bug reports.

The stamp is the only proof, and it only moves when you regenerate it, so re-stamp
before **every** reload or restart:
```bash
bash scripts/gen_build_info.sh   # prints e.g. "build_info.dart: 1271eba* 11:06:21"
echo "R" > /tmp/flutter_ctl
tail -n 5 flutter_run.log        # want "Restarted application"
```

Then read the stamp back off the device. `kBuildRef` renders as a plain `Text` in the
AppBar of the piece list and the piece detail screen (debug only), so Marionette can
read it without a screenshot:
```
mcp__marionette__get_interactive_elements   # look for Text: "1271eba* 11:06:21"
```

Stamp on screen ≠ stamp just printed → the build is stale. Nothing but a cold relaunch
reliably clears it (`bash scripts/dev_run.sh dev-ipad`). And since `build_info.dart`
changes on every stamp, `Reloaded 0 libraries` *right after stamping* is proof on its
own that the watcher is dead.

**Never spawn a new `flutter run` without killing the existing one first.**

**The device can lie too, not just the build.**

The simulator can desync from the app: **Device ▸ Orientation** showed Landscape Left
ticked while the app went on laying itself out at portrait dimensions, and further
menu clicks (and `Rotate Left`, and the Cmd-arrow keystrokes) all reported success
and did nothing.

Screenshot dimensions cannot tell you the app's orientation — `simctl io screenshot`
always captures in the device's **native** frame, so a landscape app comes out
portrait-shaped and rotated. Ask the app instead: `constraints.maxWidth`, or the `w=`
field of the `[auto]` debug line (`VerovioEngraver.debugLogging`). Measured: `w=358`
portrait and `w=706` landscape on `dev-iphone`, `w=790` portrait on `dev-ipad`.
When the menu and the app disagree, only a device reboot clears it:
```bash
xcrun simctl shutdown dev-iphone && xcrun simctl boot dev-iphone
```

**Worktrees: two traps.** They branch from `origin/main`, *not* your current HEAD, so
work based on an unmerged branch must `git checkout -b <name> <sha>` first and check
`git log --oneline -1` before touching anything. And `flutter test` cannot resolve the
`../homr_flutter` path dependency from inside a worktree without the symlink at
`.claude/worktrees/homr_flutter` (it is there; leave it).

## Marionette MCP — Live UI Inspection

Marionette lets agents interact with the running simulator (screenshots, taps, text input, scroll) without touching the physical device.

**MCP server:** registered in `.claude.json` as `marionette`. The `marionette_mcp` binary is at `~/.pub-cache/bin/marionette_mcp`. The Flutter binding is initialised in `lib/main.dart` via `MarionetteBinding.ensureInitialized()` (debug mode only).

**Connect at the start of every session:**
```
1. Get the current VM Service URL:
   grep "VM Service" flutter_run.log | tail -1

2. Connect (the URL changes on every cold start):
   mcp__marionette__connect(uri: "ws://127.0.0.1:<PORT>/<TOKEN>=/ws")
```

The connection is lost on cold restarts (pubspec changes, new assets). Hot reloads and hot restarts keep the same URL.

**Common operations:**
```
mcp__marionette__take_screenshots()          # see current UI state
mcp__marionette__get_interactive_elements()  # list tappable widgets
mcp__marionette__tap(text: "Lightly Row")    # tap by visible text
mcp__marionette__tap(coordinates: {x, y})   # tap by screen coords
mcp__marionette__get_logs()                  # app stdout/flutter: logs
mcp__marionette__hot_reload()                # trigger reload via MCP
```

**Known limitation — WebView (platform views) are always blank in screenshots:**
`webview_flutter` on iOS uses a native `WKWebView`, which is a Flutter "platform view" — it renders outside Flutter's own rendering pipeline. Marionette's `take_screenshots` calls `RepaintBoundary.toImage()` internally, which captures platform views as solid white/blank. This is a Flutter engine limitation ([flutter#25306](https://github.com/flutter/flutter/issues/25306), [flutter#163639](https://github.com/flutter/flutter/issues/163639)) with no workaround in the Flutter SDK as of 2026.

Practically: any screen that contains a `StaffView` (the OSMD WebView) will show a blank white rectangle in Marionette screenshots. Use screenshots to verify the surrounding Flutter UI (AppBar, playback controls, tray layout) but **not** to verify staff notation rendering. To verify staff content, screenshot the simulator framebuffer directly — this captures the WebView:

```bash
xcrun simctl io booted screenshot /tmp/staff.png   # or `dev-iphone` / `dev-ipad` instead of `booted`
sips -r 90 /tmp/staff.png                            # raw capture is portrait; rotate if the app is landscape
```

Then read `/tmp/staff.png`. (See the README "Screenshots & UI debugging" section.)

The main Marionette-visible alternatives would be `verovio_flutter` (FFI, outputs SVG rendered via `flutter_svg`) or exporting OSMD's SVG and displaying it with `flutter_svg` instead of a WebView. Both lose live cursor animation and require significant rework. We're staying with OSMD/WebView for rendering quality; accept the blank-screenshot limitation.

**Capturing short-lived UI — arm the screenshots BEFORE the tap.**

Anything transient (the playback count-in, the cursor on a fast note, autoscroll, a
snackbar) can be over before you can look at it: the gap between two agent tool calls is
seconds, and a 3-beat count-in at 115 bpm lasts 1.6. Tap-then-screenshot samples an
arbitrary moment several seconds late — it will *look* like the feature never fired.

Launch a detached burst first, then do the interaction. Each `simctl io screenshot` takes
roughly half a second, so 20 shots cover about ten seconds and bracket the tap wherever
it lands:
```bash
rm -rf /tmp/shots && mkdir -p /tmp/shots     # not `rm *.png` — zsh errors on an empty glob
nohup bash -c 'sleep 2; for i in $(seq -w 1 20); do
  xcrun simctl io dev-ipad screenshot /tmp/shots/f$i.png >/dev/null 2>&1; done' \
  >/dev/null 2>&1 &
# ...now send the Marionette tap...
md5 -q /tmp/shots/f*.png | cat -n | uniq -f1   # which frames actually differ
```
Then rotate/crop only the interesting frames (`sips -r 90 f07.png`, then
`sips -c <h> <w> --cropOffset <y> <x> f07.png --out f07c.png`), writing the crops
somewhere else — a crop sitting next to its original doubles every entry in that dedupe
list and the pattern reads like the screen alternating between two states.

Better still, widen the window before capturing:
- Slow the tempo — but with `mcp__marionette__swipe`, not `tap`. A synthetic tap on a
  `Slider` moves the label without firing `onChangeEnd`, so the service never sees the
  new value; a coordinate swipe is a real drag and does.
- Or lengthen the thing itself (e.g. set the count-in minimum to 8 beats), verify the
  visual there, and leave the short default to the unit tests.

And prefer not to need a picture: `get_interactive_elements` returns `Text` contents, so
a label can be asserted without an image — subject to the same latency, so widen the
window first. Timing-sensitive *logic* belongs in a test (see `test/count_in_test.dart`,
`test/count_in_providers_test.dart`); use the capture for the appearance only.

**Troubleshooting:**
- `Unknown method "ext.flutter.marionette.getVersion"` → version mismatch; ensure `marionette_flutter` in `pubspec.yaml` matches `marionette_mcp` (both should be `^0.5.0`).
- Connection refused → the app crashed or hasn't launched yet; check `flutter_run.log`.
- Screenshots show piece-list screen → navigate to a piece with `mcp__marionette__tap(text: "Lightly Row")`.

**Screen coordinates** in marionette are in logical pixels at whatever scale the simulator reports. `dev-iphone` in landscape reports ~874×402pt for the full screen (including AppBar). The body below the AppBar starts at y≈52.

## Measuring Verovio headlessly

`web/verovio/verovio-toolkit-wasm.js` (Verovio 6.2.0) drives from Node with no
simulator, so it can answer "what does this option actually do" in seconds — and
unlike the dev server it is safe to run while another agent holds the device.

```js
const vrv = require('web/verovio/verovio-toolkit-wasm.js');
// no ready callback — poll for the wasm runtime:
//   vrv.module.calledRun && vrv.module.cwrap('vrvToolkit_getVersion','string',[])
const tk = new vrv.toolkit();
tk.resetOptions();                 // options are CUMULATIVE — see below
tk.loadData(xml);
tk.setOptions({scale: 40, pageWidth: 1975, adjustPageHeight: true, svgViewBox: true});
const svg = tk.renderToSVG(1);
```

**Options are cumulative across `setOptions` calls.** Without `resetOptions()`
between measurements the numbers grow monotonically and look like a real trend.

**Trust it for option yields, not for layout.** It gave exact, reproducible figures
for `spacingSystem` (0.50 staff spaces/unit), `pageMarginTop` (1/18, and silently
reverting to the default above its max of 500) and `harmDist` (no effect on the
harm-to-fing separation). But the same `pageWidth` that gave six systems on the
device gave three headless, and that discrepancy is unexplained — so confirm any
LAYOUT conclusion on a real engrave.

## Fingering Label Format

Fingering labels are defined canonically in the piece asset files (e.g., `A1`, `A2L`, `E2H`). The L/H suffix indicates low/high finger position and is meaningful data — **never strip, transform, or replace it with ♭/♯ symbols**. Both the staff annotation view and the fingering view must render the full label verbatim as stored in `NoteEvent.fingerNumber`.

## Multi-Platform Posture

This is a solo "vibe coding" project. There is no PR workflow, no CI, no code review gate. 

### Smell check after every commit

After each commit, **agents should run this quick checklist and flag anything that fails**. It's a 30-second scan, not a review.

1. **No `dart:io` or `dart:html` in shared code.** Platform-specific APIs belong behind the `_io.dart` / `_web.dart` conditional-import split (see `staff_view*.dart`, `playback_service*.dart` for the pattern).
2. **No `kIsWeb` or `Platform.is*` branching inside shared widgets or services.** That's the canonical smell — branch via conditional imports instead.
3. **New plugin dependencies must declare iOS, Android, macOS, and Web support** on pub.dev. If a plugin is web-only or mobile-only, it needs a conditional-import sibling, not a direct dependency in shared code.
4. **No hard-coded desktop-browser pixel widths.** Layouts should be responsive / percentage-based so they survive a phone viewport.
5. **No whole-file reformatting.** This repo is not `dart format`-clean, so running it on a file rewrites hundreds of unrelated lines. `git diff --shortstat` against `git diff -w --shortstat` is the tell — if they diverge a lot, a formatter has been through. It has twice turned a small change into a huge diff: 582 lines for a 304-line change, and ~180 lines of churn for a 3-line edit in `piece_detail_screen.dart`. Edit surgically; to undo, `git checkout HEAD -- <file>` and re-apply the real change by hand.

Suggested phrasing when something fails: *"Multi-platform smell: `<file>:<line>` does `<thing>`. Suggest moving to a conditional-import split (see `playback_service_web.dart` / `playback_service_io.dart` for the pattern)."*

### Mobile build milestone (iOS done; Android/macOS outstanding)

**iOS is done.** `flutter build ios --release` succeeds and installs on a physical
phone with no source changes (signed automatically, team `V8MB2893V6`), so the
`ios/Podfile` and `ios/Flutter/*.xcconfig` files already in the repo are now backed
by a verified build rather than being speculative pod-install side effects.

Still outstanding before any "v1 / feature freeze" moment: `flutter build apk` and
`flutter build macos`. The `macos/` pod files are committed but unverified — that
build is the thing that would confirm them.

### Installing on a physical device

Use `scripts/device_install.sh` (defaults to the phone named `Jamz`). Two traps it
exists to avoid — full reasoning in the README, "Installing on a physical device":

1. **`flutter install` does not rebuild.** It reuses `build/ios/iphoneos/Runner.app`
   as-is and exits 0, so it will cheerfully install a binary from hours ago. This
   has already happened once. Build explicitly, then check the artifact timestamp
   (`stat -f '%Sm' build/ios/iphoneos/Runner.app/Frameworks/App.framework/App`) —
   the exit code proves nothing.
2. **Install with `devicectl`, not `flutter install`.** flutter uninstalls the old
   copy first, and iOS drops the developer-trust record when the last app signed by
   that certificate leaves the device — which is why the phone demands a re-trust
   every time. `xcrun devicectl device install app` goes over the top and preserves
   it.

Two further facts worth not re-deriving: a **release** build does not render
`kBuildRef` (debug-only), so the stamp trick doesn't work on a device — confirm by
the feature instead. And this is a **free** Apple ID team (`TimeToLive = 7` on the
provisioning profile), so an installed build stops launching a week after it is
signed.
