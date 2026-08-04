import 'note_event.dart';

/// How much fingering the annotation view shows. A three-stop slider, because
/// the useful amount changes as a piece is learned: everything while sight-
/// reading it, then only the places you actually get wrong.
///
/// The three levels are strictly nested — `least ⊆ fewer ⊆ all` — so moving the
/// slider only ever removes labels. A level that both added and removed would
/// make the control unreadable, and both policies below are built to preserve
/// that (see [showFingering]).
enum FingeringDensity { all, fewer, least }

/// Which rule decides what "crucial" means.
///
/// Two policies rather than one because "crucial fingering" is a pedagogical
/// judgement, not a fact, and it needs playing feedback to settle. They are
/// exposed side by side in the settings drawer so the two can be compared on
/// real music; the weights and thresholds here are the tuning surface.
enum FingeringDensityPolicy {
  /// Score each note against weighted difficulty signals, show above a
  /// per-level threshold. One knob, retunable by editing the weights.
  difficulty,

  /// Boolean union of the same signals — no arithmetic, so what shows is
  /// predictable from the rules alone.
  changesAndLandmarks,
}

// ── Difficulty weights ───────────────────────────────────────────────────────
// The tuning surface. These are a starting point from first principles, NOT
// measured: a string change is the most consequential thing a label can tell you
// (wrong string = wrong note, and the bow arm has to move), an L/H finger is the
// most easily forgotten (the suffix IS the information), and a wide finger jump
// is where the hand has to reorganise. Everything else is a landmark — useful
// for finding your place, not for getting the note right.

/// The first note of the piece. Always worth showing: there is no previous note
/// to infer the hand position from.
const int fingeringWeightFirstNote = 4;

/// The string changed from the previous sounding note.
const int fingeringWeightStringChange = 3;

/// The finger moved by more than [fingeringJumpSpan] positions (e.g. 1 → 4).
const int fingeringWeightFingerJump = 2;

/// The finger carries an L or H suffix (low/high position).
const int fingeringWeightLowHigh = 2;

/// First sounding note after a rest — the hand has left the string.
const int fingeringWeightAfterRest = 1;

/// First note of a measure. A pure landmark.
const int fingeringWeightMeasureStart = 1;

/// The label differs from the previous note's label, i.e. this is not a repeat.
const int fingeringWeightLabelChanged = 1;

/// A finger move of MORE than this many positions counts as a jump. 2, so
/// `1 → 4` and `0 → 3` qualify but `1 → 3` does not.
const int fingeringJumpSpan = 2;

/// Minimum difficulty score shown at each level.
///
/// `all` is 0 rather than "no filter" so that every note scores at or above it —
/// a plain repeat scores exactly 0. `fewer` at 1 therefore drops exactly the
/// repeats. `least` at 3 keeps string changes outright, and keeps the
/// combinations that add up (an L/H finger at a measure start, a jump after a
/// rest) while dropping either signal on its own.
int fingeringScoreThreshold(FingeringDensity density) => switch (density) {
      FingeringDensity.all => 0,
      FingeringDensity.fewer => 1,
      FingeringDensity.least => 3,
    };

/// One note plus the context the rules need. [prev] is the previous **sounding**
/// note, across the barline — the previous note in the music, not the previous
/// note that happened to get a label, so what shows at one density level can
/// never change what shows at another.
typedef FingeringNoteContext = ({
  NoteEvent note,
  NoteEvent? prev,
  bool isFirstNote,
  bool isMeasureStart,
  bool afterRest,
});

// ── Predicates (shared by both policies) ─────────────────────────────────────

/// The string changed from [prev]. False at the start of the piece, where
/// `isFirstNote` carries that case instead.
bool fingeringStringChanged(FingeringNoteContext c) =>
    c.prev != null && c.note.fingerString != c.prev!.fingerString;

/// The finger moved by more than [fingeringJumpSpan]. Compares the NUMERIC part
/// only, so `2L → 4` is a jump of 2 (not a jump at all) rather than a string
/// comparison that can't subtract.
bool fingeringJumped(FingeringNoteContext c) {
  final a = fingerPosition(c.prev?.fingerNumber);
  final b = fingerPosition(c.note.fingerNumber);
  if (a == null || b == null) return false;
  return (b - a).abs() > fingeringJumpSpan;
}

/// The finger is a low/high variant (`2L`, `3H`).
bool fingeringIsLowHigh(NoteEvent note) {
  final f = note.fingerNumber;
  if (f == null) return false;
  return f.contains('L') || f.contains('H');
}

/// The full label (string + finger) differs from [prev]'s — i.e. this note is
/// not a plain repeat of the one before it.
bool fingeringLabelChanged(FingeringNoteContext c) {
  final p = c.prev;
  if (p == null) return true;
  return p.fingerString != c.note.fingerString ||
      p.fingerNumber != c.note.fingerNumber;
}

/// The leading digits of a finger label as an int — `'2L'` → 2, `'0'` → 0. Null
/// when there is no digit to read.
int? fingerPosition(String? fingerNumber) {
  if (fingerNumber == null) return null;
  final m = _leadingDigits.firstMatch(fingerNumber);
  return m == null ? null : int.tryParse(m[0]!);
}

final _leadingDigits = RegExp(r'^\d+');

// ── Scoring & selection ──────────────────────────────────────────────────────

/// Weighted difficulty of showing [c]'s fingering. Higher = more worth showing.
int fingeringDifficulty(FingeringNoteContext c) {
  var score = 0;
  if (c.isFirstNote) score += fingeringWeightFirstNote;
  if (fingeringStringChanged(c)) score += fingeringWeightStringChange;
  if (fingeringJumped(c)) score += fingeringWeightFingerJump;
  if (fingeringIsLowHigh(c.note)) score += fingeringWeightLowHigh;
  if (c.afterRest) score += fingeringWeightAfterRest;
  if (c.isMeasureStart) score += fingeringWeightMeasureStart;
  if (fingeringLabelChanged(c)) score += fingeringWeightLabelChanged;
  return score;
}

/// Whether [c]'s fingering shows at [density] under [policy].
///
/// Both policies are monotone in density by construction — the difficulty one
/// because it only lowers a threshold on a fixed score, the boolean one because
/// each level is a superset of the one below it — which is what makes the
/// slider mean "less, then less again".
bool showFingering(
  FingeringNoteContext c, {
  required FingeringDensity density,
  required FingeringDensityPolicy policy,
}) {
  if (density == FingeringDensity.all) return true;
  return switch (policy) {
    FingeringDensityPolicy.difficulty =>
      fingeringDifficulty(c) >= fingeringScoreThreshold(density),
    FingeringDensityPolicy.changesAndLandmarks =>
      _crucial(c) || (density == FingeringDensity.fewer && _landmark(c)),
  };
}

/// The `changesAndLandmarks` floor — what shows even at `least`.
bool _crucial(FingeringNoteContext c) =>
    c.isFirstNote ||
    fingeringStringChanged(c) ||
    fingeringIsLowHigh(c.note) ||
    fingeringJumped(c) ||
    c.afterRest;

/// What `fewer` adds on top of [_crucial].
bool _landmark(FingeringNoteContext c) =>
    fingeringLabelChanged(c) || c.isMeasureStart;
