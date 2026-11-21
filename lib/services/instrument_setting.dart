import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/instrument_profile.dart' show Transcription;
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

  /// The viola: alto clef, its own fingering a string lower, the viola's
  /// sound and tuning (docs/family/layers.md).
  viola,

  /// The mandolin: fret numbers on every piece, the tab view and chords.
  mandolin,

  /// The setting before the instruments were separate: violin with a
  /// per-piece Violin / Mandolin picker, frets, tab and chords. Still read
  /// and honoured where it is stored; Settings offers it only while chosen.
  violinAndMandolin,
}

/// What an [InstrumentSet] turns on. Widgets and providers ask about these
/// capabilities, never about the set itself, so a new set (or splitting one
/// capability out into its own setting) touches only [InstrumentFeatures.of].
class InstrumentFeatures {
  /// The per-piece Violin / Mandolin picker (only [InstrumentSet
  /// .violinAndMandolin]). Which numbers a piece shows is
  /// `noteNumberModeProvider`'s answer.
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
    InstrumentSet.violin || InstrumentSet.viola =>
      const InstrumentFeatures(fretNumbers: false, tabView: false, chords: false),
    InstrumentSet.mandolin =>
      const InstrumentFeatures(fretNumbers: false, tabView: true, chords: true),
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

/// The preference key holding how violin music is shown to a viola: the
/// [Transcription]'s name.
const violaTranscriptionKey = 'app.violaTranscription';

/// How a part written for another clef is transcribed for the viola
/// (decided 2026-11-21: configurable). App-wide, like [instrumentSetProvider].
final violaTranscriptionProvider = StateProvider<Transcription>((ref) {
  const fallback = Transcription.none;
  final prefs = ref.watch(sharedPreferencesProvider);
  if (prefs == null) return fallback;
  ref.listenSelf((_, next) {
    if (prefs.getString(violaTranscriptionKey) != next.name) {
      prefs.setString(violaTranscriptionKey, next.name);
    }
  });
  final stored = prefs.getString(violaTranscriptionKey);
  return Transcription.values.where((t) => t.name == stored).firstOrNull ??
      fallback;
});

/// The capabilities of the current [instrumentSetProvider].
final instrumentFeaturesProvider = Provider<InstrumentFeatures>(
  (ref) => InstrumentFeatures.of(ref.watch(instrumentSetProvider)),
);
