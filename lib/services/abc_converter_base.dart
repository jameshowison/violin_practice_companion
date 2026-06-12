import 'dart:convert';

/// Result of converting an ABC-notation string to MusicXML.
class AbcConversionResult {
  /// The MusicXML document, ready for [MusicXmlParser].
  final String musicXml;

  /// The tune title from the ABC `T:` header, if any.
  final String? title;

  /// Non-fatal notes about the conversion (e.g. a tuplet approximated, a
  /// second voice dropped). Safe to show the user; the import still succeeds.
  final List<String> warnings;

  const AbcConversionResult({
    required this.musicXml,
    this.title,
    this.warnings = const [],
  });
}

/// Thrown when ABC cannot be converted (parse failure, empty/invalid input).
class AbcConversionException implements Exception {
  final String message;
  AbcConversionException(this.message);
  @override
  String toString() => message;
}

/// Converts ABC notation to MusicXML by running a bundled, DOM-free JavaScript
/// converter (abcjs parser + `assets/abc/abc_to_musicxml.js` emitter).
///
/// Two implementations share this interface via a conditional import (see
/// `abc_converter.dart`): web runs the JS with `dart:js_interop`; mobile/desktop
/// runs it with `flutter_js` (QuickJS / JavaScriptCore — **not** a WebView).
abstract class AbcConverterBase {
  /// Converts [abc] to MusicXML. Lazily loads the JS engine on first call.
  /// Throws [AbcConversionException] on invalid input.
  Future<AbcConversionResult> convert(String abc);

  /// Releases any JS-runtime resources.
  void dispose();
}

/// Asset paths for the bundled JS. Loaded via `rootBundle` by both platforms.
const String abcjsAsset = 'assets/abc/abcjs-basic-min.js';
const String abcEmitterAsset = 'assets/abc/abc_to_musicxml.js';

/// Decodes the JSON envelope returned by `globalThis.abcToMusicXml(...)`.
/// Shared by both platform implementations.
AbcConversionResult parseConverterResult(String jsonString) {
  final Map<String, dynamic> map;
  try {
    map = json.decode(jsonString) as Map<String, dynamic>;
  } catch (_) {
    throw AbcConversionException('ABC converter returned malformed output.');
  }
  if (map['ok'] != true) {
    throw AbcConversionException(
        (map['error'] ?? 'ABC conversion failed.').toString());
  }
  return AbcConversionResult(
    musicXml: map['xml'] as String,
    title: map['title'] as String?,
    warnings: (map['warnings'] as List?)
            ?.map((e) => e.toString())
            .toList(growable: false) ??
        const [],
  );
}
