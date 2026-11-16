import 'dart:async';

import 'package:flutter/services.dart';

/// Share files (`.stringlings`) the system has opened in the app — from
/// AirDrop, Files, Messages, Mail or Quick Share — as local paths.
///
/// The native halves (`ios/Runner/IncomingSharePlugin.swift`,
/// `android/.../IncomingSharePlugin.kt`) QUEUE paths rather than pushing
/// them, because the file that launches the app arrives before Dart is
/// listening. [start] drains that queue once, then again on every `pending`
/// nudge. Where there is no native half (web, macOS) the channel throws
/// [MissingPluginException] and this simply never emits.
class IncomingShareChannel {
  IncomingShareChannel._();
  static final instance = IncomingShareChannel._();

  static const _channel = MethodChannel('stringlings/incoming_share');
  final _paths = StreamController<String>.broadcast();
  bool _started = false;

  Stream<String> get paths => _paths.stream;

  void start() {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pending') await _drain();
    });
    _drain();
  }

  Future<void> _drain() async {
    try {
      final list = await _channel.invokeListMethod<String>('takePending');
      for (final p in list ?? const <String>[]) {
        _paths.add(p);
      }
    } on MissingPluginException {
      // No native half on this platform.
    } on PlatformException {
      // Nothing to take.
    }
  }
}
