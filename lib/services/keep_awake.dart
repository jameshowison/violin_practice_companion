import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Holds off the platform's idle timer while a piece is on screen.
///
/// ## Why this wrapper exists rather than calling `WakelockPlus` directly
///
/// On web the plugin routes to the browser's Screen Wake Lock API, which is
/// absent outside a secure context and in some browsers, and throws there. A
/// screen that dims early is a nuisance; a piece that won't open is a broken
/// app. So every call is best-effort, and the failure is swallowed in exactly
/// one place instead of a `try` at each call site.
///
/// The calls are fire-and-forget on purpose: nothing downstream waits on the
/// idle timer, and awaiting them in `initState`/`dispose` would mean either an
/// async lifecycle method or an unawaited future warning at each caller.
abstract final class KeepAwake {
  static void enable() => _attempt(WakelockPlus.enable, 'enable');

  static void disable() => _attempt(WakelockPlus.disable, 'disable');

  static void _attempt(Future<void> Function() op, String what) {
    try {
      op().catchError((Object e) => _complain(what, e));
    } catch (e) {
      // Some platform stubs throw synchronously rather than returning a
      // rejected future.
      _complain(what, e);
    }
  }

  static void _complain(String what, Object e) {
    if (kDebugMode) debugPrint('KeepAwake.$what failed (ignored): $e');
  }
}
