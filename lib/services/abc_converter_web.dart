import 'dart:js_interop';

import 'package:flutter/services.dart' show rootBundle;
import 'package:web/web.dart' as web;

import 'abc_converter_base.dart';

@JS('abcToMusicXml')
external JSString _abcToMusicXml(JSString abc);

/// Web implementation: the JS converter runs directly in the page's JS context
/// via `dart:js_interop` — no WebView, no iframe. abcjs + the emitter are
/// injected as inline `<script>` elements (which execute synchronously) on
/// first use, defining the global `abcToMusicXml`.
class AbcConverter implements AbcConverterBase {
  Future<void>? _ready;

  Future<void> _ensureReady() => _ready ??= _init();

  Future<void> _init() async {
    final abcjs = await rootBundle.loadString(abcjsAsset);
    final emitter = await rootBundle.loadString(abcEmitterAsset);
    _injectInlineScript(abcjs);
    _injectInlineScript(emitter);
  }

  void _injectInlineScript(String source) {
    final script =
        web.document.createElement('script') as web.HTMLScriptElement;
    script.text = source; // inline scripts run synchronously on append
    web.document.head!.appendChild(script);
  }

  @override
  Future<AbcConversionResult> convert(String abc) async {
    await _ensureReady();
    final out = _abcToMusicXml(abc.toJS).toDart;
    return parseConverterResult(out);
  }

  @override
  void dispose() {}
}
