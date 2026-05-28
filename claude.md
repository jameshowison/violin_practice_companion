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
