// Conditionally export the right AbcConverter implementation.
// Web runs the JS converter via dart:js_interop; mobile/desktop runs it via
// flutter_js (QuickJS / JavaScriptCore). Neither uses a WebView.
export 'abc_converter_base.dart';
export 'abc_converter_io.dart' if (dart.library.html) 'abc_converter_web.dart';
