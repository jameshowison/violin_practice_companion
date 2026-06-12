import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_js/flutter_js.dart';

import 'abc_converter_base.dart';

/// Mobile/desktop implementation: runs the bundled JS converter in `flutter_js`
/// (QuickJS on Android/Windows/Linux, JavaScriptCore on iOS/macOS). No WebView,
/// no DOM — the converter and abcjs's parser are both DOM-free.
class AbcConverter implements AbcConverterBase {
  JavascriptRuntime? _rt;
  Future<void>? _ready;

  Future<void> _ensureReady() => _ready ??= _init();

  Future<void> _init() async {
    final rt = getJavascriptRuntime();
    final abcjs = await rootBundle.loadString(abcjsAsset);
    final emitter = await rootBundle.loadString(abcEmitterAsset);
    // abcjs's UMD wrapper references the browser global `self`; the bare engine
    // has only `globalThis`, so alias it before loading abcjs.
    rt.evaluate('var self = globalThis;');
    final a = rt.evaluate(abcjs);
    if (a.isError) throw AbcConversionException('Failed to load abcjs: ${a.stringResult}');
    final e = rt.evaluate(emitter);
    if (e.isError) throw AbcConversionException('Failed to load converter: ${e.stringResult}');
    _rt = rt;
  }

  @override
  Future<AbcConversionResult> convert(String abc) async {
    await _ensureReady();
    final rt = _rt!;
    // Hand the ABC text to JS as a JSON string literal to avoid escaping issues.
    rt.evaluate('globalThis.__abcInput = ${jsonEncode(abc)};');
    final res = rt.evaluate('abcToMusicXml(globalThis.__abcInput)');
    if (res.isError) {
      throw AbcConversionException('ABC conversion failed: ${res.stringResult}');
    }
    return parseConverterResult(res.stringResult);
  }

  @override
  void dispose() {
    _rt?.dispose();
    _rt = null;
    _ready = null;
  }
}
