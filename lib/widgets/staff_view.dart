// Conditionally export the right StaffView implementation.
// Web uses HtmlElementView + postMessage; non-web uses webview_flutter.
export 'staff_view_io.dart' if (dart.library.html) 'staff_view_web.dart';
