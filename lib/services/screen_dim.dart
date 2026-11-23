import 'package:flutter/foundation.dart';
import 'package:screen_brightness/screen_brightness.dart';

/// Turns the screen's brightness all the way down for practice mode's black
/// step, and back to what it was.
///
/// The app's brightness only, never the system setting: the plugin puts the
/// screen back on its own when the app leaves the foreground, and clearing
/// [dimmed] hands control back to the system's own brightness.
///
/// Best-effort like `KeepAwake`: a screen that won't dim is a nuisance, a
/// practice session that throws is a broken app. Every call is guarded, and a
/// failure is swallowed in one place.
abstract final class ScreenDim {
  static bool _dimmed = false;

  /// The platform calls, swappable so a test can watch them.
  @visibleForTesting
  static Future<void> Function(double level) setLevel =
      (level) => ScreenBrightness.instance.setApplicationScreenBrightness(level);
  @visibleForTesting
  static Future<void> Function() reset =
      () => ScreenBrightness.instance.resetApplicationScreenBrightness();

  /// Whether the screen is currently turned down (for tests and debugging).
  static bool get isDimmed => _dimmed;

  static set dimmed(bool on) {
    if (on == _dimmed) return;
    _dimmed = on;
    _attempt(on ? 'dim' : 'restore', on ? () => setLevel(0) : reset);
  }

  static void _attempt(String what, Future<void> Function() call) {
    try {
      call().catchError((Object e) => _complain(what, e));
    } catch (e) {
      _complain(what, e);
    }
  }

  static void _complain(String what, Object e) {
    if (kDebugMode) debugPrint('ScreenDim.$what failed (ignored): $e');
  }
}
