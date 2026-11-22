---
name: marionette
description: Drive and inspect the running app with Marionette (MCP) — screenshots, interactive elements, taps, text entry, scrolling, swipes, hot reload/restart, custom extensions. Use whenever asked to run through, test, tap, screenshot or read the live app on a simulator or emulator; to verify a UI change or a bugfix; to reproduce a bug; to call a debug extension (e.g. realignAll); or whenever a Marionette call fails, can't find a widget, or reports a version mismatch. A shim: it loads LeanCode's upstream skill from the pinned marionette_flutter package, then this project's overrides.
---

# Marionette (shim over the upstream skill)

The real skill is LeanCode's `marionette-flutter-drive-app`, which ships inside
the `marionette_flutter` package. It is **not vendored** here: read it straight
from the version `pubspec.lock` pins, so a version bump updates it too.

## 1. Read the upstream skill, in full

```bash
python3 -I -c "import json;print([p['rootUri'] for p in json.load(open('.dart_tool/package_config.json'))['packages'] if p['name']=='marionette_flutter'][0][7:]+'/skills/marionette-flutter-drive-app/SKILL.md')"
```

Read the file that prints. No `.dart_tool/` (a fresh worktree) → `flutter pub get` first.
Its *Preparing the app* section is already done here (`MarionetteBinding` in
`lib/main.dart`, debug only); skip it unless you are changing the setup.

## 2. Then apply this project's overrides

Where these and upstream disagree, these win. Keyed to upstream's section
names. **Checked against marionette_flutter 0.7.0.**

**Connecting.** Never ask the user for the URI, and never start your own
`flutter run`. The app runs as a dev server through the fifo:
`bash scripts/dev_run.sh dev-iphone-se` (a parallel session: its own simulator
and `FLUTTER_FIFO`; CLAUDE.md "Parallel Claude sessions"). Then:
```
grep "VM Service" flutter_run.log | tail -1
mcp__marionette__connect(uri: "ws://127.0.0.1:<PORT>/<TOKEN>=/ws")
```
The URI changes on every cold start (dev_run.sh, pubspec, new assets); hot
reload and hot restart keep it. Android: `flutter_run_android.log`. A run
launched with `FLUTTER_LOG=…` logs there instead, and a second run in the
same checkout must set it, or it truncates the first run's log.

**Dev workflow (`hot_reload`, `hot_restart`).** The MCP tools or
`echo r|R > $FLUTTER_FIFO` both work, but neither's output proves anything.
Restamp first (`bash scripts/gen_build_info.sh`) and read the stamp back from
`get_interactive_elements` (CLAUDE.md "Verify the build is live").

**Logs for `get_logs`.** No `LogCollector` is configured, so `get_logs`
returns setup instructions, not logs. Read the log instead:
`tail -n 50 flutter_run.log | grep -v "◢\|◤\|════"`. Wherever upstream says
"confirm with `get_logs`", the evidence is a line in that file.

**Device-config sweeps.** No `MarionetteDeviceConfig` is in the tree, so
`set_device_config` only returns setup instructions.

**Reporting what you found.** Session reports are off
(`enableSessionReports` is not set). A `session_title` on `connect` is harmless,
but there is no session directory and no report contract to follow.

**Screenshots.** They cost a lot of context: take them in a subagent where
possible, and prefer `get_interactive_elements` text when a label is all you
need. **The staff is drawn in Flutter's own pipeline**, so screenshots show
the notation: Verovio engraves, `jovial_svg` draws the SVG (`flutter_svg`
rendered it blank), native overlays draw the cursor and highlights
(`lib/widgets/staff_view_verovio.dart`). No WebViews remain.

**Coordinates** are logical pixels at the simulator's reported scale.
`dev-iphone` in landscape reports ~874×402pt for the full screen, AppBar
included, and the body below the AppBar starts at y≈52.

**A `Slider` needs `swipe`, not `tap`.** A synthetic tap moves the label
without firing `onChangeEnd`, so the service never sees the new value. A
coordinate swipe is a real drag, and it does.

**Capturing short-lived UI: arm the screenshots BEFORE the tap.**
Anything transient (the playback count-in, the cursor on a fast note,
autoscroll, a snackbar) can be over before you look. Tool calls are seconds
apart, and a 3-beat count-in at 115 bpm lasts 1.6 s. Tap-then-screenshot
samples an arbitrary moment several seconds late, so it *looks* as if the
feature never fired. Launch a detached burst first, then interact. Each
`simctl io screenshot` takes about 0.5 s, so 20 shots cover about ten seconds:
```bash
rm -rf /tmp/shots && mkdir -p /tmp/shots     # not `rm *.png` — zsh errors on an empty glob
nohup bash -c 'sleep 2; for i in $(seq -w 1 20); do
  xcrun simctl io dev-ipad screenshot /tmp/shots/f$i.png >/dev/null 2>&1; done' \
  >/dev/null 2>&1 &
# ...now send the Marionette tap...
md5 -q /tmp/shots/f*.png | cat -n | uniq -f1   # which frames actually differ
```
Rotate and crop only the interesting frames (`sips -r 90 f07.png`, then
`sips -c <h> <w> --cropOffset <y> <x> f07.png --out f07c.png`), and write
the crops somewhere else: a crop next to its original doubles every entry in
the dedupe list, which then reads like the screen alternating between two
states. Rotation has its own traps; see the simulator-screenshot-rotation memory.
Better still, widen the window: slow the tempo (by `swipe`, as above), or
lengthen the thing itself (e.g. an 8-beat count-in minimum), check the
visual there, and leave the short default to the unit tests. Timing *logic*
belongs in a test (`test/count_in_test.dart`,
`test/count_in_providers_test.dart`); use the capture for appearance only.

**Don't use the burst to verify continuous playback.** Confirming that "the
cursor never jumps backward across a 40-second play-through" would need
dozens of frames, each read into context. Ask the user to press Play and
watch.

**System UI outside Flutter.** 0.7.0 has no native lane (upstream has one
unreleased, on the iOS Simulator only). Marionette can't see or tap the
document picker, the photo picker, a permission alert or the route sheet. See
the `flutter-ios-native-verification` skill. On Android,
`scripts/android_ui.sh` drives native UI (CLAUDE.md "Android emulator").

**Custom extensions.** The pattern is `lib/debug/realign_all.dart`
(`realignAll`), registered in `main.dart` behind `kDebugMode`. Keep new ones
in `lib/debug/`.

**When not to use this (performance).** Use the `ios-flutter-timing` skill.

**Version alignment.** The `marionette_flutter` pin in `pubspec.yaml` must
equal the global `marionette_mcp` (`~/.pub-cache/bin/marionette_mcp
--version`; MCP server `marionette` in `~/.claude.json`). After activating a
new `marionette_mcp`, reconnect it with `/mcp`, or restart Claude Code;
otherwise the running server is still the old binary.

**Troubleshooting (project).** Connection refused → the app crashed or hasn't
launched; read `flutter_run.log`. The piece list shows when you wanted a
piece → `tap(text: "Lightly Row")`. A title that appears twice (scans) traps
`tap(text:)`, so use a key.

## 3. When the pinned version changes (re-sync)

1. Bump both: `marionette_flutter: ^X` in `pubspec.yaml`, then `flutter pub get`,
   then `dart pub global activate marionette_mcp X`, then `/mcp`.
2. Diff upstream:
   `diff ~/.pub-cache/hosted/pub.dev/marionette_flutter-{OLD,NEW}/skills/marionette-flutter-drive-app/SKILL.md`
   (also `ls …-NEW/skills/` for new upstream skills, e.g. `-setup`, `-to-patrol`).
3. Check each override above against the sections that changed. Drop any that
   upstream now covers. For a newly released native lane, revisit
   `flutter-ios-native-verification`.
4. Update "Checked against" above.

Never install the upstream skills into `.claude/skills/` with
`dart run skills@ get`: they would trigger alongside this shim (both paths are
gitignored for that reason).
