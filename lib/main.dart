import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'services/piece_display_prefs.dart';
import 'spike/verovio_harness.dart';

// THROWAWAY: branch spike/verovio-rendering boots the Verovio harness instead
// of the real app. Flip to false (or revert) to get the normal app back.
const bool _kVerovioSpike = false;

Future<void> main() async {
  if (kDebugMode) {
    MarionetteBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
  if (_kVerovioSpike) {
    runApp(const VerovioHarnessApp());
    return;
  }
  // Opened before the first frame so per-piece display settings read
  // synchronously — see [sharedPreferencesProvider]. A failure just means
  // session-only settings, as before they were saved.
  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (_) {}
  runApp(ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    child: const ViolinPracticeApp(),
  ));
}
