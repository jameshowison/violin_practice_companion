import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'debug/realign_all.dart';
import 'services/launch_timing.dart';
import 'services/piece_display_prefs.dart';
import 'services/providers.dart';
import 'spike/verovio_harness.dart';
import 'services/verovio_engraver.dart';

// THROWAWAY: branch spike/verovio-rendering boots the Verovio harness instead
// of the real app. Flip to false (or revert) to get the normal app back.
const bool _kVerovioSpike = false;

Future<void> main() async {
  LaunchTiming.clock.start();
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
  LaunchTiming.mark('prefs ready');
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  // Load the piece list BEFORE the first frame, so the app opens on the list
  // rather than a spinner. Started after runApp, the load queued behind
  // building and painting that first frame, and the spinner stayed up ~120ms
  // on the phone (release) — now the first frame IS the list, ~43ms. Capped, so a slow disk falls back to the spinner rather
  // than holding the launch screen; errors surface in the list as before.
  try {
    await Future.wait([
      container.read(piecesProvider.future),
      container.read(libraryProvider.future),
    ]).timeout(const Duration(milliseconds: 600));
  } catch (_) {}
  if (kDebugMode) registerRealignAll(container);
  LaunchTiming.mark('pieces ready, runApp');
  runApp(UncontrolledProviderScope(
    container: container,
    child: const ViolinPracticeApp(),
  ));
  // Spawn the engraver's worker once the list is up, off the first tap's path.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    LaunchTiming.mark('first frame');
    VerovioEngraver.instance.warmUp();
  });
}
