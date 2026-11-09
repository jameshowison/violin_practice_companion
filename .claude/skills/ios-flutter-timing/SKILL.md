---
name: ios-flutter-timing
description: How to measure timing and performance of this Flutter app on the iOS simulators and on the physical phone (JamzJamzJamzz), and get the numbers back in a form the agent can read. Use this whenever the task involves timing, benchmarking, latency, startup time, spinners, frame/jank analysis, "how long does X take", or comparing performance before/after a change, even if the user doesn't say "profile" or "benchmark".
---

# Timing this app on iOS

Two rules:

1. **Absolute numbers come from the phone, on an AOT build** (release or profile).
   Debug builds run JIT with asserts on, so they can be several times slower.
2. **Simulator debug runs are still worth doing.** The simulators only run debug
   builds; there is no profile or release mode on them. They are good for finding
   *where* time goes, the order of stages, and what is contending with what, and
   for before/after on the same build. Don't quote their milliseconds as what the
   user will see.

Device names, not UDIDs: `dev-iphone-se` (primary compact simulator, same model as
the user's phone), `dev-iphone`, `dev-ipad`, and the phone `JamzJamzJamzz` ("Jamz"
is accepted by the scripts). `simctl`, `devicectl` and `flutter -d` all resolve
names. See CLAUDE.md.

## Phone constraints (read before choosing a method)

- **Don't install with `flutter run` / `flutter drive` / `flutter install` on the
  phone by default.** They uninstall first, and iOS drops the developer-trust
  record when the last app from the certificate leaves, so the user has to
  re-trust in Settings afterwards. Install with `scripts/device_install.sh`
  (builds, then `devicectl device install app` over the top). If you build by
  hand, install the same way:
  `xcrun devicectl device install app --timeout 300 --device JamzJamzJamzz build/ios/iphoneos/Runner.app`.
- `flutter install` does not rebuild. Check the artifact time:
  `stat -f '%Sm' build/ios/iphoneos/Runner.app/Frameworks/App.framework/App`.
- **`print` is invisible on a release build on the phone.**
  `devicectl device process launch --console` shows nothing from Dart. Get numbers
  off as a file (method D).
- **The phone must be unlocked to launch.** `devicectl` fails with
  `BSErrorCodeDescription = Locked` otherwise. Ask the user to unlock it and keep it
  awake before a run.
- **`device_install.sh` syncs the dev library and relaunches the app**, which
  closes whatever the user had open. Say so before running it. Never pass
  `--remove-existing-content` to `devicectl` (it wiped the app container on
  iOS 27).
- Free Apple ID team: a build stops launching 7 days after signing.
- A dev server on a simulator holds `build/ios/`. `device_install.sh` kills it
  (`pkill -f flutter_tools.snapshot`); restart it afterwards with
  `scripts/dev_run.sh`.

## Choosing a method

| Goal | Where | Method |
|---|---|---|
| Where does startup/open time go (stage breakdown) | simulator | S: log stream |
| Real startup / open time, before vs after | phone | D: file pulled with devicectl |
| Time before `main()` (engine start, launch screen) | phone | B: `--trace-startup` (costs a re-trust) |
| Scripted flow, repeatable samples | phone | A: integration_test (costs a re-trust; not set up yet) |
| Spans in DevTools' timeline | phone, profile | C: `dart:developer` Timeline |
| Native / plugin / pre-engine cost | phone | E: os_signpost + xctrace |
| Frame build/raster, jank | either | F: FrameTiming, reported via D |

## S. Simulator: unified log stream

On the simulator `print`/`debugPrint` does reach the unified log, even without
`flutter run` attached. Tag every line (`[launch] +123ms stage`) and filter for it:

```bash
S=<scratchpad>; B=name.howison.violinPracticeCompanion
pkill -f flutter_tools.snapshot          # no debugger attached while timing
for n in 1 2 3 4 5 6; do
  xcrun simctl terminate dev-iphone-se $B 2>/dev/null; sleep 2
  xcrun simctl spawn dev-iphone-se log stream --style compact \
    --predicate 'eventMessage CONTAINS "[launch]"' > $S/run$n.log 2>&1 & LP=$!
  sleep 2; xcrun simctl launch dev-iphone-se $B >/dev/null; sleep 8; kill $LP
  grep -o '\[launch\] .*' $S/run$n.log
done
```

- `simctl launch` runs the **last full install**, not hot-restarted code. Install
  with `bash scripts/dev_run.sh dev-iphone-se` first (`--no-sync` to skip the
  library sync), then kill the dev server so the runs aren't under the debugger.
- The first launch after `dev_run.sh` is under `flutter run` and right after a
  library push. Discard it.
- `simctl launch --console-pty` does NOT show Dart output. Use `log stream`.

The app already has opt-in timing lines for piece open:
`VerovioEngraver.timingLogging` (`[timing]`, `[open]`) in
`lib/services/verovio_engraver.dart`. Follow the same pattern for new
instrumentation: a static flag that is off by default, one tagged line per stage.

## D. Phone: buffer in memory, write a file, pull with devicectl

Works in release. Record marks with a `Stopwatch` into an in-memory list. **Don't
write the file at each mark.** File I/O in the measured path (especially startup)
changes what you are measuring. Write once, after the thing being timed is done
(for startup: a post-frame callback plus a ~2s delay), appending one JSON or tagged
line per mark.

- `dart:io` and `path_provider` must not go into shared code (CLAUDE.md smell
  check #1). Either keep the dump as uncommitted, temporary code, or put it behind
  a `_io.dart` / `_web.dart` conditional import.
- Gate it with a `--dart-define` so one source tree builds both variants:
  `const bool kFix = bool.fromEnvironment('FIX', defaultValue: true);`, built with
  `flutter build ios --release --dart-define=FIX=false`.

Run (after the user has unlocked the phone):

```bash
B=name.howison.violinPracticeCompanion
for n in 1 2 3 4 5 6; do
  xcrun devicectl device process launch --device JamzJamzJamzz --terminate-existing $B
  sleep 8
done
xcrun devicectl device copy from --device JamzJamzJamzz \
  --domain-type appDataContainer --domain-identifier $B \
  --source Documents/<file> --destination <scratchpad>/<file>
```

Clear the file between variants: delete it on the device, or tag each line with
the variant and filter. Strip the instrumentation (or set its flag back to off)
before committing.

## B. Startup before `main()`

```bash
flutter run --profile --trace-startup -d JamzJamzJamzz
```

Read `build/start_up_info.json` (engine enter, framework init, time to first
frame). This is the only method here that sees time before Dart starts. It
installs with `flutter run`, so **tell the user first that they will need to
re-trust the developer certificate**, then reinstall with `device_install.sh`
afterwards. Repeat the cold launch several times; the first one isn't
representative.

## A. integration_test with reportData

Not set up in this repo: it needs `integration_test` (sdk: flutter) under
`dev_dependencies` plus `integration_test/` and `test_driver/` directories. In a
profile build `main()` skips `MarionetteBinding` (debug only), so the test binding
won't conflict. `flutter drive` installs like `flutter run`, so it costs a re-trust
too.

```dart
final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
testWidgets('open piece', (tester) async {
  app.main();
  await tester.pumpAndSettle();
  final samples = <int>[];
  for (var i = 0; i < 6; i++) {
    final sw = Stopwatch()..start();
    await tester.tap(find.text('Lightly Row'));
    await tester.pumpAndSettle();
    samples.add(sw.elapsedMicroseconds);
    await tester.pageBack();
    await tester.pumpAndSettle();
  }
  binding.reportData = {...?binding.reportData, 'open_us': samples};
});
// test_driver/perf_driver.dart:
// integrationDriver(responseDataCallback: (d) async =>
//     writeResponseData(d, testOutputFilename: 'perf'));
```

`flutter drive --profile -d JamzJamzJamzz --driver=test_driver/perf_driver.dart --target=integration_test/perf_test.dart`,
then read `build/perf.json`. Wrap an action in
`binding.traceAction(() async {...}, reportKey: 'name')` for a full timeline.

Caveat: `pumpAndSettle` doesn't see work outside Flutter's frame pipeline. The
Verovio engrave runs on a worker isolate, so time "until painted" with an
app-side mark, not until settled.

## C. Timeline spans

```dart
import 'dart:developer';
Timeline.startSync('loadAll');  /* ... */  Timeline.finishSync();
```

These spans show up in DevTools' timeline on a profile build, and in A's
`traceAction`. To get the VM service URI programmatically, use
`flutter run --profile --machine` and parse the JSON events.

## E. Native: os_signpost + xctrace

For Swift/ObjC, plugins, or launch before the engine starts:

```bash
xcrun xctrace record --device JamzJamzJamzz --template 'Time Profiler' \
  --output run.trace --launch -- build/ios/iphoneos/Runner.app
xcrun xctrace export --input run.trace --toc
xcrun xctrace export --input run.trace --xpath '<xpath from toc>' > signposts.xml
```

Parse the exported XML; don't read the trace by eye.

## F. Frame timings

`SchedulerBinding.instance.addTimingsCallback` gives `buildDuration`,
`rasterDuration`, `totalSpan`. Aggregate (count, p50, p90, max, frames over
16.7ms) and report via D. Don't log every frame.

## Measurement hygiene

- `Stopwatch` (monotonic), never `DateTime.now()` differences. Note that a clock
  started in `main()` misses process and engine start (use B for that).
- Discard 1–2 warm-up launches, then take **at least 5 samples**. Report the
  median and p90, not one run or only the mean.
- No debugger attached while timing: kill `flutter run` and launch with
  `simctl` / `devicectl`.
- Phone plugged in, unlocked, screen on, not in Low Power Mode.
- Before vs after: same device, same build mode, same dev-library state
  (the launch path merges a staged library; see CLAUDE.md "Dev library"), and
  interleave the variants if you can.
- Check that you measured the build you think you did: build stamp on the
  simulator (CLAUDE.md "Verify the build is live"), artifact mtime on the phone.

## Reporting

A short table: metric, median, p90, n, for each variant, with the delta. Note the
device, iOS version, build mode, commit (`git rev-parse --short HEAD`, plus `*` if
the tree is dirty), and which variant each column is. Say whether the delta is
bigger than the run-to-run spread; if it isn't, call the result inconclusive.
Label simulator-debug numbers as such.
