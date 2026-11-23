import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_mode.dart';
import '../models/support_level.dart';
import 'instrument_setting.dart' show instrumentFeaturesProvider;
import 'piece_display_prefs.dart' show sharedPreferencesProvider;
import 'players.dart' show playerKeyProvider;
import 'providers.dart';
import 'staff_overlays.dart';

/// Practice mode: the score's supports fade a step at a time (Fade button, or
/// each loop pass), and a tap on the score brings one back. See
/// [SupportLevel] for the steps.
///
/// Session state only: it starts off for every piece opened.
final practiceModeProvider = StateProvider<PracticeState>((ref) {
  ref.watch(selectedPieceProvider.select((p) => p?.id));
  return PracticeState.off;
});

/// Whether practice mode can run in [mode]: the engraved staff views only.
bool practiceModeAppliesTo(DisplayMode mode) =>
    mode == DisplayMode.staff || mode == DisplayMode.staffFingering;

/// Bars lit at [SupportLevel.bowings] (see [cueBarsOf]).
final practiceCueBarsProvider = Provider<Set<int>>((ref) {
  final parsed = ref.watch(parsedPieceProvider).valueOrNull;
  return parsed == null ? const {} : cueBarsOf(parsed);
});

/// The steps this piece and these settings give, in order (see
/// [supportLadder]). Built from the same overlays the staff draws, so "Full"
/// is exactly the player's own view.
final practiceLadderProvider = Provider<List<SupportLevel>>((ref) {
  final parsed = ref.watch(parsedPieceProvider).valueOrNull;
  final mode = ref.watch(displayModeProvider);
  final overlays = staffOverlaysFor(
    ref.watch,
    parsed: parsed,
    mode: mode,
    sections: ref.watch(selectedPieceProvider)?.sections ?? const [],
    sectionColors: const {},
    bySection: ref.watch(staffBySectionProvider),
  );
  final windLane = ref.watch(instrumentProfileProvider).fingeringChart != null;
  // Rows the layout already has: the annotated view's fingering channel, or
  // the chord row (the xml keeps `<harmony>` when the instrument has chords).
  final hasChordRow = ref.watch(instrumentFeaturesProvider).chords &&
      (parsed?.measures.any((m) => m.notes.any((n) => n.chordSymbol != null)) ??
          false);
  return supportLadder(
    fullHasMore: overlays.annotations.isNotEmpty ||
        overlays.stringRuns.isNotEmpty ||
        overlays.chordRuns.isNotEmpty ||
        overlays.colourNoteheads ||
        windLane,
    fullHasNames: overlays.showNoteNames,
    hasCues: ref.watch(practiceCueBarsProvider).isNotEmpty,
    namesHaveRoom: mode == DisplayMode.staffFingering || hasChordRow,
  );
});

/// The step on screen: the stored one, moved onto this ladder if a setting
/// change took its step away. Null when practice mode is off, or the view is
/// one it doesn't apply to (it comes back with the staff).
final practiceLevelProvider = Provider<SupportLevel?>((ref) {
  final state = ref.watch(practiceModeProvider);
  if (!state.active || !practiceModeAppliesTo(ref.watch(displayModeProvider))) {
    return null;
  }
  return snapToLadder(state.level, ref.watch(practiceLadderProvider));
});

// ── Settings (per player, every piece) ──────────────────────────────────────

const practiceAutoFadeKeyBase = 'app.practiceAutoFade';
const practiceRefadeKeyBase = 'app.practiceRefadeAfterPeek';

StateProvider<bool> _playerBoolPref(String keyBase, bool fallback) =>
    StateProvider<bool>((ref) {
      final prefs = ref.watch(sharedPreferencesProvider);
      if (prefs == null) return fallback;
      final key = ref.watch(playerKeyProvider)(keyBase);
      ref.listenSelf((_, next) {
        if (prefs.getBool(key) != next) prefs.setBool(key, next);
      });
      return prefs.getBool(key) ?? fallback;
    });

/// Fade one step each time a looped passage comes round. Off by default: the
/// Fade button is the way in.
final practiceAutoFadeProvider = _playerBoolPref(practiceAutoFadeKeyBase, false);

/// With [practiceAutoFadeProvider] on: whether fading carries on after a tap
/// brought a support back. Off, a tap stops it until the Fade button.
final practiceRefadeAfterPeekProvider =
    _playerBoolPref(practiceRefadeKeyBase, true);

// ── Actions ─────────────────────────────────────────────────────────────────

/// Practice mode's verbs, so every control (Fade button, score tap, loop
/// pass, the drawer's switch) changes the state the one way.
abstract final class PracticeMode {
  static void enter(WidgetRef ref) {
    final ladder = ref.read(practiceLadderProvider);
    ref.read(practiceModeProvider.notifier).state =
        PracticeState(active: true, level: ladder.first);
  }

  static void exit(WidgetRef ref) =>
      ref.read(practiceModeProvider.notifier).state = PracticeState.off;

  static void fade(WidgetRef ref) => _update(
      ref, (s) => s.fade(ref.read(practiceLadderProvider)));

  static void peek(WidgetRef ref) => _update(
      ref,
      (s) => s.peek(ref.read(practiceLadderProvider),
          autoFade: ref.read(practiceAutoFadeProvider),
          refadeAfterPeek: ref.read(practiceRefadeAfterPeekProvider)));

  static void loopPassed(WidgetRef ref) => _update(
      ref,
      (s) => s.loopPassed(ref.read(practiceLadderProvider),
          autoFade: ref.read(practiceAutoFadeProvider)));

  static void _update(WidgetRef ref, PracticeState Function(PracticeState) f) {
    final n = ref.read(practiceModeProvider.notifier);
    if (!n.state.active) return;
    n.state = f(n.state);
  }
}
