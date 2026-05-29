## Flutter Web Dev Server Pattern

Treat `flutter run` as a persistent dev server for the session, not a one-shot command.

**Start once:**
```bash
mkfifo /tmp/flutter_ctl
flutter run -d web-server --web-port=8080 < /tmp/flutter_ctl 2>&1 | tee flutter_run.log &
exec 3>/tmp/flutter_ctl  # hold the pipe open
```

**Open once in browser:** `http://localhost:5000`

**After code edits:**
```bash
echo "r" > /tmp/flutter_ctl   # hot reload
echo "R" > /tmp/flutter_ctl   # hot restart
```

**Read output:**
```bash
tail -n 50 flutter_run.log
```

**Full restart only when necessary:** changes to `main()`, `pubspec.yaml`, new assets. Kill with `pkill -f flutter_tools.snapshot` before relaunching, and recreate the fifo.

**Never spawn a new `flutter run` without killing the existing one first.**

To avoid multiple user chrome, instruct user to open chrome manually and provide URL.

## Fingering Label Format

Fingering labels are defined canonically in the piece asset files (e.g., `A1`, `A2L`, `E2H`). The L/H suffix indicates low/high finger position and is meaningful data — **never strip, transform, or replace it with ♭/♯ symbols**. Both the staff annotation view and the fingering view must render the full label verbatim as stored in `NoteEvent.fingerNumber`.

## Multi-Platform Posture

This is a solo "vibe coding" project. There is no PR workflow, no CI, no code review gate. Currently shipping **web-only**, but mobile (iOS / Android / macOS) is a deferred-but-real target — `flutter_midi_pro` and the GeneralUser GS soundfont are already in the dependency set, and the codebase uses the conditional-import pattern (`*_io.dart` / `*_web.dart`).

The stance: web-first while features are churning is fine, **as long as** the prototype keeps the multi-platform plumbing clean so the eventual first mobile build doesn't surface architecture-level surprises.

### Smell check after every commit

After each commit, **agents should run this quick checklist and flag anything that fails**. It's a 30-second scan, not a review.

1. **No `dart:io` or `dart:html` in shared code.** Platform-specific APIs belong behind the `_io.dart` / `_web.dart` conditional-import split (see `staff_view*.dart`, `playback_service*.dart` for the pattern).
2. **No `kIsWeb` or `Platform.is*` branching inside shared widgets or services.** That's the canonical smell — branch via conditional imports instead.
3. **New plugin dependencies must declare iOS, Android, macOS, and Web support** on pub.dev. If a plugin is web-only or mobile-only, it needs a conditional-import sibling, not a direct dependency in shared code.
4. **No hard-coded desktop-browser pixel widths.** Layouts should be responsive / percentage-based so they survive a phone viewport.

Suggested phrasing when something fails: *"Multi-platform smell: `<file>:<line>` does `<thing>`. Suggest moving to a conditional-import split (see `playback_service_web.dart` / `playback_service_io.dart` for the pattern)."*

### Mobile build milestone (deferred, not abandoned)

Before any "v1 / feature freeze" moment, do the first real mobile build: `flutter build apk` + `flutter build ios --no-codesign` (+ `flutter build macos`). This is when the `ios/Podfile`, `macos/Podfile`, and the `Pods-Runner.*.xcconfig` includes in `ios/Flutter/*.xcconfig` and `macos/Flutter/Flutter-*.xcconfig` should be **committed** — they exist in the working tree today as pod-install side effects, but they're only meaningful once a verified mobile build has produced them. Don't commit them speculatively.
