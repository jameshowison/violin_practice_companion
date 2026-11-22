import 'package:flutter/services.dart' show appFlavor;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which app this build is: one codebase, several installable apps, chosen by
/// the build flavor (docs/family/mandolin-app.md, windlings-app.md). An
/// experiment on `next_gen`.
enum AppEdition {
  /// Violin and viola: the App Store app.
  stringlings,

  /// The mandolin alone, installed beside Stringlings under its own bundle id.
  mandolin,

  /// The winds: the soprano recorder, for now. Its own bundle id too.
  windlings;

  /// The edition for a build flavor. No flavor (tests, the harness, a run
  /// straight from Xcode's Runner scheme) or an unknown one is Stringlings.
  static AppEdition fromFlavor(String? flavor) =>
      values.where((e) => e.name == flavor).firstOrNull ?? stringlings;

  /// What the app calls itself, on screen and on the home screen.
  String get appName => switch (this) {
        stringlings => 'Stringlings',
        mandolin => 'Mandolings',
        windlings => 'Windlings',
      };
}

/// This build's [AppEdition], from Flutter's [appFlavor]. Overridden in tests.
final appEditionProvider =
    Provider<AppEdition>((ref) => AppEdition.fromFlavor(appFlavor));
