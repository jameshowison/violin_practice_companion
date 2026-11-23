import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Lengthens the platform's idle timer while a piece or the tuner is on screen,
/// without disabling it outright.
///
/// The score is read from for minutes at a time without a touch, so the
/// system's own auto-lock (30 s – 1 min on most phones) is far too short. But
/// a phone left on the music stand with a piece open must still go to sleep
/// eventually, so the lock is released [idleTimeout] after the last touch
/// anywhere in the app, and taken again by the next one. While something is
/// playing ([busy]) the countdown does not run: the player is listening, not
/// touching.
///
/// Screens [enable] on entry and [disable] on exit. The calls are counted, so
/// the tuner pushed over a piece does not release the piece's lock when it is
/// popped.
///
/// ## Why the plugin calls are guarded
///
/// Some platform stubs throw, synchronously or from the future. A screen that
/// dims early is a nuisance; a piece that won't open is a broken app. So every
/// call is best-effort, and the failure is swallowed in exactly one place.
///
/// The calls are fire-and-forget on purpose: nothing downstream waits on the
/// idle timer, and awaiting them in `initState`/`dispose` would mean either an
/// async lifecycle method or an unawaited future warning at each caller.
abstract final class KeepAwake {
  /// How long after the last touch the screen is allowed to sleep.
  static const idleTimeout = Duration(minutes: 5);

  static int _holders = 0;
  static bool _busy = false;
  static bool _sleepNow = false;
  static bool _idle = false;
  static bool _locked = false;
  static Timer? _timer;
  static bool _routed = false;

  /// The platform call, swappable so a test can watch it.
  @visibleForTesting
  static Future<void> Function(bool on) platform =
      (on) => WakelockPlus.toggle(enable: on);

  /// Whether the wakelock is currently held (for tests and debugging).
  static bool get isLocked => _locked;

  static void enable() {
    _ensureRouted();
    _holders++;
    _activity();
  }

  static void disable() {
    if (_holders == 0) return;
    _holders--;
    if (_holders == 0) {
      _timer?.cancel();
      _timer = null;
    }
    _apply();
  }

  /// Playback in progress: hold the lock regardless of touches. When it stops,
  /// the [idleTimeout] countdown starts afresh from that moment.
  static set busy(bool value) {
    if (value == _busy) return;
    _busy = value;
    _activity();
  }

  /// Practice mode's black screen: let the phone sleep on its own auto-lock
  /// straight away instead of after [idleTimeout], unless something is
  /// playing ([busy] still holds the lock, so the music goes on).
  static set sleepWhenIdle(bool value) {
    if (value == _sleepNow) return;
    _sleepNow = value;
    _apply();
  }

  /// A touch (or the end of playback): restarts the countdown.
  static void _activity() {
    _idle = false;
    _timer?.cancel();
    _timer = _holders > 0 && !_busy
        ? Timer(idleTimeout, () {
            _idle = true;
            _apply();
          })
        : null;
    _apply();
  }

  static void _apply() {
    final want = _holders > 0 && (_busy || (!_idle && !_sleepNow));
    if (want == _locked) return;
    _locked = want;
    _attempt(want);
  }

  static void _ensureRouted() {
    if (_routed) return;
    _routed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  static void _onPointer(PointerEvent e) {
    if (_holders == 0) return;
    if (e is PointerDownEvent || e is PointerSignalEvent) _activity();
  }

  /// Resets all state, for tests.
  @visibleForTesting
  static void reset() {
    _timer?.cancel();
    _timer = null;
    _holders = 0;
    _busy = false;
    _sleepNow = false;
    _idle = false;
    _locked = false;
    if (_routed) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      _routed = false;
    }
  }

  static void _attempt(bool on) {
    final what = on ? 'enable' : 'disable';
    try {
      platform(on).catchError((Object e) => _complain(what, e));
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
