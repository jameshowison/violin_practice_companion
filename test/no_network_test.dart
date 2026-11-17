// The README promises the app never connects to the internet. This holds the
// parts of that promise the repo controls:
//
// - the web page loads every script, worker and data file from its own
//   origin (pdf.js used to come from jsdelivr, and its cMaps still would have
//   through pdfx's default had `pdfRenderOptions` not been a real global);
// - the app's code carries no network client.
//
// Links the user taps (url_launcher, in the external browser) are not the app
// connecting, and stay allowed. What no test here can see: native SDKs —
// ML Kit's diagnostics on Android, disclosed in docs/privacy.md.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _absoluteUrl = RegExp(r'''(?:https?:)?//[a-z0-9-]+(?:\.[a-z0-9-]+)+''',
    caseSensitive: false);

/// [html] without its `<!-- -->` comments, which may cite documentation URLs.
String _withoutHtmlComments(String html) =>
    html.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

void main() {
  test('the web page loads nothing from another host', () {
    for (final f in Directory('web').listSync().whereType<File>()) {
      if (!f.path.endsWith('.html')) continue;
      final hits = _absoluteUrl
          .allMatches(_withoutHtmlComments(f.readAsStringSync()))
          .map((m) => m[0])
          .toList();
      expect(hits, isEmpty,
          reason: '${f.path} loads from another host; vendor it under web/');
    }
  });

  test('pdf.js is vendored, at the version pdfx expects', () {
    // pdfx renders with the page's pdfjsLib; its own fallback cMaps are this
    // version on jsdelivr, so a mismatched copy would be a silent downgrade.
    for (final path in [
      'web/pdfjs/pdf.min.mjs',
      'web/pdfjs/pdf.worker.min.mjs',
      'web/pdfjs/LICENSE',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
    final cmaps = Directory('web/pdfjs/cmaps')
        .listSync()
        .where((f) => f.path.endsWith('.bcmap'));
    expect(cmaps.length, 168); // pdfjs-dist 4.6.82's whole cmaps/ set
    final html = File('web/index.html').readAsStringSync();
    expect(html, contains('globalThis.pdfRenderOptions'));
    expect(html, contains('pdf.js 4.6.82'));
  });

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
