## Flutter Web Dev Server Pattern

Treat `flutter run -d chrome` as a persistent dev server for the session, not a one-shot command.

**Start once:**
```bash
flutter run -d chrome 2>&1 | tee flutter_run.log &
```

**After code edits**, trigger hot reload via stdin instead of restarting:
```bash
# Hot reload (UI/logic changes)
echo "r" > /proc/$(pgrep -f "flutter_tools.snapshot run")/fd/0

# Hot restart (state reset needed)
echo "R" > /proc/$(pgrep -f "flutter_tools.snapshot run")/fd/0
```

**Read output** by tailing the log:
```bash
tail -n 50 flutter_run.log
```

**Full restart only when necessary:** changes to `main()`, `pubspec.yaml`, new assets, or native code. Kill with `pkill -f flutter_tools.snapshot` before relaunching.

**Never spawn a new `flutter run` without killing the existing one first.**

To avoid multiple user chrome, instruct user to open chrome manually and provide URL.
