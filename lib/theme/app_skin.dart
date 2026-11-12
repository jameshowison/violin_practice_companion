import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/piece_display_prefs.dart' show sharedPreferencesProvider;

/// The app's look. Same screens and controls either way; a skin changes
/// colours, type, shapes and how the piece list draws its rows.
enum AppSkin {
  /// Clean, iOS-flavoured: grey grouped background, blue accent, list rows.
  classic,

  /// Board 3 of the design canvas: warm cream, Nunito, purple accent, rounder
  /// shapes, colourful cards, friendlier words.
  playful,
}

/// The preference key, `app.skin`, holding the [AppSkin]'s name.
const appSkinKey = 'app.skin';

/// The app-wide [AppSkin], copied from `instrumentSetProvider`'s pattern:
/// read synchronously from [sharedPreferencesProvider] so the first frame is
/// already in the right skin, a missing or unreadable value is
/// [AppSkin.classic], and a write that would change nothing is skipped. With
/// no preferences (tests, the harness) it lives for the session only.
final appSkinProvider = StateProvider<AppSkin>((ref) {
  const fallback = AppSkin.classic;
  final prefs = ref.watch(sharedPreferencesProvider);
  if (prefs == null) return fallback;

  ref.listenSelf((_, next) {
    final stored = prefs.getString(appSkinKey);
    if (stored == next.name || (stored == null && next == fallback)) return;
    prefs.setString(appSkinKey, next.name);
  });

  final stored = prefs.getString(appSkinKey);
  if (stored == null) return fallback;
  try {
    return AppSkin.values.byName(stored);
  } catch (_) {
    return fallback;
  }
});
