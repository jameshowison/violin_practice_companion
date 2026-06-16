import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'app.dart';
import 'spike/verovio_harness.dart';

// THROWAWAY: branch spike/verovio-rendering boots the Verovio harness instead
// of the real app. Flip to false (or revert) to get the normal app back.
const bool _kVerovioSpike = false;

void main() {
  if (kDebugMode) {
    MarionetteBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
  if (_kVerovioSpike) {
    runApp(const VerovioHarnessApp());
    return;
  }
  runApp(const ProviderScope(child: ViolinPracticeApp()));
}
