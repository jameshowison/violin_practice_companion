// The README promises the app never connects to the internet. This holds the
// parts of that promise the repo controls:
//
// - the app's code carries no network client;
// - no networking package is a direct dependency.
//
// Links the user taps (url_launcher, in the external browser) are not the app
// connecting, and stay allowed. What no test here can see: native SDKs —
// ML Kit's diagnostics on Android, disclosed in docs/privacy.md.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the app carries no network client', () {
    final banned = RegExp(
        r'''package:(http|dio|web_socket_channel|grpc|socket_io_client)/'''
        r'''|\bHttpClient\b|\bWebSocket\b|\bHttpRequest\b|\bRawSocket\b|\bSocket\.connect\b''');
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first; // comments may name them
        if (banned.hasMatch(code)) hits.add('${f.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(hits, isEmpty);
  });

  test('no networking package is a direct dependency', () {
    final deps = RegExp(r'^  (http|dio|web_socket_channel|grpc|socket_io_client|'
        r'firebase_[a-z_]+|sentry[a-z_]*|connectivity_plus):', multiLine: true);
    expect(deps.allMatches(File('pubspec.yaml').readAsStringSync()).map((m) => m[1]),
        isEmpty);
  });
}
