import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'providers.dart' show selectedPieceProvider;

/// The app's preferences, opened once in `main()` before the first frame so the
/// per-piece display settings below can be read synchronously — a setting that
/// arrived a frame late would engrave the piece twice.
///
/// Null when not overridden (tests, the Verovio harness): the settings then live
/// for the session only, exactly as they did before they were saved.
final sharedPreferencesProvider = Provider<SharedPreferences?>((_) => null);

/// A display setting remembered PER PIECE: the view, staff spacing, chord
/// symbols, lyric verse, and the annotation view's number / colour / detail
/// choices.
///
/// A plain [StateProvider], so every existing `.notifier).state = v` writer
/// persists without being touched. Keyed on the selected piece's id (not the
/// piece, which is a new object after every edit), so opening another piece
/// rebuilds it from that piece's saved value or [fallback].
///
/// Stored as `display.<name>.<pieceId>` strings. A write is skipped when it
/// would change nothing — the stored value already matches, or there is none
/// and the value is still [fallback] — so merely opening a piece never writes,
/// and changing the default later still reaches pieces nobody customised.
StateProvider<T> pieceDisplayPref<T>(
  String name,
  T fallback, {
  required String Function(T) encode,
  required T Function(String) decode,
}) {
  return StateProvider<T>((ref) {
    final prefs = ref.watch(sharedPreferencesProvider);
    final id = ref.watch(selectedPieceProvider.select((p) => p?.id));
    if (prefs == null || id == null) return fallback;
    final key = 'display.$name.$id';

    ref.listenSelf((_, next) {
      final stored = prefs.getString(key);
      final value = encode(next);
      if (stored == value || (stored == null && next == fallback)) return;
      prefs.setString(key, value);
    });

    final stored = prefs.getString(key);
    if (stored == null) return fallback;
    try {
      return decode(stored);
    } catch (_) {
      return fallback; // unreadable: written by an older build, say
    }
  });
}

/// [pieceDisplayPref] for an enum, stored by name. An unknown name (a value
/// since renamed or removed) throws in `byName`, so reads as [fallback].
StateProvider<T> pieceDisplayEnumPref<T extends Enum>(
  String name,
  T fallback,
  List<T> values,
) => pieceDisplayPref<T>(
  name,
  fallback,
  encode: (v) => v.name,
  decode: values.byName,
);
