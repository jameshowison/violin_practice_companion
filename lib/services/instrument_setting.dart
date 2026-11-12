import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'piece_display_prefs.dart' show sharedPreferencesProvider;

/// Which instruments the app is set up for — the app-wide "Instruments" setting
/// on the home screen's Settings page. Not per piece: it is a fact about who is
/// using the app.
///
/// An enum rather than a bool because a third answer is expected: a `fiddle`
/// set would be the violin plus chords (symbols and diagrams), without frets.
enum InstrumentSet {
  /// The violin alone: no mandolin frets, no tab view, no chords. Default — a
  /// family following a method should not meet any of them.
  violin,

  /// Everything: the per-piece Violin / Mandolin picker, fret numbers, the tab
  /// view and chords.
  violinAndMandolin,
}

/// What an [InstrumentSet] turns on. Widgets and providers ask about these
/// capabilities, never about the set itself, so a new set (or splitting one
/// capability out into its own setting) touches only [InstrumentFeatures.of].
class InstrumentFeatures {
  /// Mandolin fret numbers: the per-piece Instrument picker and fret style.
  /// Off forces violin fingering.
  final bool fretNumbers;

  /// The tab view (melody plus a GDAE tab staff).
  final bool tabView;

  /// Chord symbols over the staff, the chord-symbol switch and the chord
  /// diagrams.
  final bool chords;

  const InstrumentFeatures({
    required this.fretNumbers,
    required this.tabView,
    required this.chords,
  });

  factory InstrumentFeatures.of(InstrumentSet set) => switch (set) {
    InstrumentSet.violin =>
      const InstrumentFeatures(fretNumbers: false, tabView: false, chords: false),
    InstrumentSet.violinAndMandolin =>
      const InstrumentFeatures(fretNumbers: true, tabView: true, chords: true),
  };
}

/// The preference key, `app.instruments`, holding the [InstrumentSet]'s name.
const instrumentSetKey = 'app.instruments';

/// The app-wide [InstrumentSet]. Read synchronously from
/// [sharedPreferencesProvider], so the first frame is already right — a value
/// that arrived late would draw the mandolin controls and then take them away.
///
/// A missing or unreadable value reads as [InstrumentSet.violin]. A write is
/// skipped when it would change nothing, as for the per-piece prefs. With no
/// preferences (tests, the harness) it lives for the session only.
final instrumentSetProvider = StateProvider<InstrumentSet>((ref) {
  const fallback = InstrumentSet.violin;
  final prefs = ref.watch(sharedPreferencesProvider);
  if (prefs == null) return fallback;

  ref.listenSelf((_, next) {
    final stored = prefs.getString(instrumentSetKey);
    if (stored == next.name || (stored == null && next == fallback)) return;
    prefs.setString(instrumentSetKey, next.name);
  });

  final stored = prefs.getString(instrumentSetKey);
  if (stored == null) return fallback;
  try {
    return InstrumentSet.values.byName(stored);
  } catch (_) {
    return fallback;
  }
});

/// The capabilities of the current [instrumentSetProvider].
final instrumentFeaturesProvider = Provider<InstrumentFeatures>(
  (ref) => InstrumentFeatures.of(ref.watch(instrumentSetProvider)),
);
