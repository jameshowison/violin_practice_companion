import 'package:flutter/foundation.dart';

/// Set by `--dart-define=SCREENSHOTS=true` when capturing App Store
/// screenshots (README, "App Store screenshots"). The app has to stay a debug
/// build for Marionette, so this hides what debug mode adds to the chrome.
const bool kScreenshotMode = bool.fromEnvironment('SCREENSHOTS');

/// Debug-only chrome — the build stamp under titles, the taller toolbar that
/// makes room for it, the DEBUG banner. Off in release and in screenshot mode.
const bool kShowDevChrome = kDebugMode && !kScreenshotMode;
