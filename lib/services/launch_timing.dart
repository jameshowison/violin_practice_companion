import 'package:flutter/foundation.dart' show debugPrint;

/// Opt-in `[launch] +<ms> <stage>` lines for the cold-start path: main →
/// prefs → dev-library merge → piece list → first frame. Off by default; flip
/// [enabled] to measure (see `.claude/skills/ios-flutter-timing`). The clock
/// starts in `main()`, so process and engine start are not included.
class LaunchTiming {
  static bool enabled = false;
  static final Stopwatch clock = Stopwatch();
  static final Set<String> _once = {};

  static void mark(String stage) {
    if (!enabled) return;
    debugPrint('[launch] +${clock.elapsedMilliseconds}ms $stage');
  }

  /// [mark], but only the first time [stage] is seen.
  static void markOnce(String stage) {
    if (_once.add(stage)) mark(stage);
  }

  /// Times [body] as `<stage> (<n>ms)`.
  static Future<T> span<T>(String stage, Future<T> Function() body) async {
    if (!enabled) return body();
    final sw = Stopwatch()..start();
    final r = await body();
    mark('$stage (${sw.elapsedMilliseconds}ms)');
    return r;
  }
}
