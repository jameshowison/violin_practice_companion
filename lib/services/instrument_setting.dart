import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_edition.dart';
import '../models/instrument_profile.dart' show Transcription;
import 'piece_display_prefs.dart' show sharedPreferencesProvider;
import 'players.dart' show playerKeyProvider;

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

  /// The cello: bass clef, C G D A an octave below the viola, its own
  /// fingering (fingers a semitone apart), sound and tuning.
  cello,

  /// The mandolin: fret numbers on every piece, the tab view and chords, and
  /// an instrument layer of its own.
  mandolin,

  /// The soprano recorder (the Windlings app): no strings, so no string
  /// fingering; the score is its written part, sounding an octave higher;
  /// a chromatic tuner (docs/family/windlings-app.md).
  recorder,

  /// The keyless Irish flute in D (docs/plan.md §7.5): the recorder's wind
  /// path, at sounding pitch, with its own six-hole chart.
  irishFlute,
}

/// The kinds of instrument the picker groups its rows by, in the order it
/// shows them (decided 2026-11-23: one row per kind).
enum InstrumentFamily {
  strings('Strings'),
  strummed('Strumming'),
  woodwinds('Woodwinds');

  const InstrumentFamily(this.label);
  final String label;
}

/// The row [set] is picked from.
InstrumentFamily familyOf(InstrumentSet set) => switch (set) {
      InstrumentSet.violin ||
      InstrumentSet.viola ||
      InstrumentSet.cello =>
        InstrumentFamily.strings,
      InstrumentSet.mandolin => InstrumentFamily.strummed,
      InstrumentSet.recorder ||
      InstrumentSet.irishFlute =>
        InstrumentFamily.woodwinds,
    };

/// The stored name of the setting from before the instruments were separate
/// (violin, with a per-piece Violin / Mandolin picker). It turned the
/// mandolin on, so it reads as [InstrumentSet.mandolin], and is rewritten.
const legacyViolinAndMandolin = 'violinAndMandolin';

/// What an [InstrumentSet] turns on. Widgets and providers ask about these
/// capabilities, never about the set itself, so a new set (or splitting one
/// capability out into its own setting) touches only [InstrumentFeatures.of].
class InstrumentFeatures {
  /// The tab view (melody plus a GDAE tab staff).
  final bool tabView;

  /// Chord symbols over the staff, the chord-symbol switch and the chord
  /// diagrams.
  final bool chords;

  /// String fingering: finger labels and string colours on the annotated
  /// staff, the Fingering and Combined views, the open-or-4th choice (the
  /// piece's picker and the measure editor's), the key summary's finger
  /// vocabulary. Off for a wind, whose fingering is a chart (step W2 adds
  /// it; docs/family/windlings-app.md).
  final bool stringFingering;

  /// The tuner tunes open strings (the climber, courses, headstock and
  /// drone); otherwise it is chromatic and names the written note.
  final bool stringTuner;

  const InstrumentFeatures({
    required this.tabView,
    required this.chords,
    this.stringFingering = true,
    this.stringTuner = true,
  });

  factory InstrumentFeatures.of(InstrumentSet set) => switch (set) {
    InstrumentSet.violin || InstrumentSet.viola || InstrumentSet.cello =>
      const InstrumentFeatures(tabView: false, chords: false),
    InstrumentSet.mandolin => const InstrumentFeatures(tabView: true, chords: true),
    InstrumentSet.recorder || InstrumentSet.irishFlute =>
      const InstrumentFeatures(
        tabView: false, chords: false, stringFingering: false, stringTuner: false),
  };
}

/// The instruments [edition] offers, the first its default: the one place
/// that answers it, for Settings, a new player and the stored setting.
///
/// Stringlings, the one app that ships, offers every instrument (decided
/// 2026-11-22: a single app for now). The mandolin and Windlings flavors are
/// kept so the family can still be split into separate apps later: each is
/// a single instrument here, and moving one out of Stringlings is a change to
/// this table alone (plus a migration for those who chose it;
/// docs/family/mandolin-app.md, windlings-app.md).
List<InstrumentSet> instrumentsOffered(AppEdition edition) => switch (edition) {
      AppEdition.stringlings => const [
          InstrumentSet.violin,
          InstrumentSet.viola,
          InstrumentSet.cello,
          InstrumentSet.mandolin,
          InstrumentSet.recorder,
          InstrumentSet.irishFlute,
        ],
      AppEdition.mandolin => const [InstrumentSet.mandolin],
      AppEdition.windlings => const [InstrumentSet.recorder],
    };

/// [instrumentsOffered] for this build's edition.
final instrumentsOfferedProvider = Provider<List<InstrumentSet>>(
    (ref) => instrumentsOffered(ref.watch(appEditionProvider)));

/// A stored `app.instruments` value as an instrument [offered]: the legacy
/// combined setting is the mandolin, and anything missing, unreadable or not
/// offered is the edition's default.
InstrumentSet instrumentFromStored(String? stored, List<InstrumentSet> offered) {
  final set = stored == legacyViolinAndMandolin
      ? InstrumentSet.mandolin
      : InstrumentSet.values.where((s) => s.name == stored).firstOrNull;
  return set != null && offered.contains(set) ? set : offered.first;
}

/// The preference key, `app.instruments`, holding the [InstrumentSet]'s name:
/// the first player's as it is, another's under `playerKey` (the instrument
/// is the player's).
const instrumentSetKeyBase = 'app.instruments';

/// Kept for callers that name the first player's key.
const instrumentSetKey = instrumentSetKeyBase;

/// The app-wide [InstrumentSet]. Read synchronously from
/// [sharedPreferencesProvider], so the first frame is already right — a value
/// that arrived late would draw the mandolin controls and then take them away.
///
/// A missing or unreadable value, or one this edition doesn't offer, reads as
/// the edition's default ([instrumentFromStored]): the violin, or in the
/// mandolin app the mandolin. A write is skipped when it would change nothing,
/// as for the per-piece prefs. With no preferences (tests, the harness) it
/// lives for the session only.
final instrumentSetProvider = StateProvider<InstrumentSet>((ref) {
  final offered = ref.watch(instrumentsOfferedProvider);
  final fallback = offered.first;
  final prefs = ref.watch(sharedPreferencesProvider);
  if (prefs == null) return fallback;
  final instrumentSetKey = ref.watch(playerKeyProvider)(instrumentSetKeyBase);

  ref.listenSelf((previous, next) {
    // The first value came from storage (or stands in for one this edition
    // doesn't offer, which is kept for a migration): nothing to write.
    if (previous == null) return;
    final stored = prefs.getString(instrumentSetKey);
    if (stored == next.name || (stored == null && next == fallback)) return;
    prefs.setString(instrumentSetKey, next.name);
  });

  final stored = prefs.getString(instrumentSetKey);
  final set = instrumentFromStored(stored, offered);
  if (stored == legacyViolinAndMandolin && set == InstrumentSet.mandolin) {
    prefs.setString(instrumentSetKey, InstrumentSet.mandolin.name);
  }
  return set;
});

/// The preference key holding how violin music is shown to a viola: the
/// [Transcription]'s name.
const violaTranscriptionKeyBase = 'app.violaTranscription';

/// The same for the cello.
const celloTranscriptionKeyBase = 'app.celloTranscription';

/// A [Transcription] kept per player under [keyBase], [fallback] until one
/// is chosen.
StateProvider<Transcription> _transcriptionPref(
        String keyBase, Transcription fallback) =>
    StateProvider<Transcription>((ref) {
      final prefs = ref.watch(sharedPreferencesProvider);
      if (prefs == null) return fallback;
      final key = ref.watch(playerKeyProvider)(keyBase);
      ref.listenSelf((_, next) {
        if (prefs.getString(key) != next.name) {
          prefs.setString(key, next.name);
        }
      });
      final stored = prefs.getString(key);
      return Transcription.values.where((t) => t.name == stored).firstOrNull ??
          fallback;
    });

/// How a part written for another clef is transcribed for the viola
/// (decided 2026-11-21: configurable). App-wide, like [instrumentSetProvider].
final violaTranscriptionProvider = _transcriptionPref(
    violaTranscriptionKeyBase, defaultTranscriptionOf(InstrumentSet.viola));

/// How a part written for another clef is transcribed for the cello: the
/// same choice as the viola's, kept apart so a player switching between the
/// two keeps each.
final celloTranscriptionProvider = _transcriptionPref(
    celloTranscriptionKeyBase, defaultTranscriptionOf(InstrumentSet.cello));

/// The transcription a player starts with. The viola keeps the violin's key
/// (Transcription.none). The cello starts a fifth lower (decided 2026-11-23):
/// the violin's first pieces are mostly in A and D, which come out in D and
/// G, the keys cello books start in and that fit first position with no
/// extension; kept in A, every C sharp on the G string needs one. The cost,
/// a key that no longer matches a recording of the violin part, matters
/// little: players mostly record their own teacher.
Transcription defaultTranscriptionOf(InstrumentSet set) => switch (set) {
      InstrumentSet.cello => Transcription.fifthDown,
      _ => Transcription.none,
    };

/// The preference key of [set]'s transcription, or null for an instrument
/// that reads a violin part as written.
String? transcriptionKeyBaseOf(InstrumentSet set) => switch (set) {
      InstrumentSet.viola => violaTranscriptionKeyBase,
      InstrumentSet.cello => celloTranscriptionKeyBase,
      _ => null,
    };

/// [set]'s transcription preference, or null ([transcriptionKeyBaseOf]).
StateProvider<Transcription>? transcriptionProviderOf(InstrumentSet set) =>
    switch (set) {
      InstrumentSet.viola => violaTranscriptionProvider,
      InstrumentSet.cello => celloTranscriptionProvider,
      _ => null,
    };

/// The capabilities of the current [instrumentSetProvider].
final instrumentFeaturesProvider = Provider<InstrumentFeatures>(
  (ref) => InstrumentFeatures.of(ref.watch(instrumentSetProvider)),
);
