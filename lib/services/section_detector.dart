import 'dart:math' as math;

import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/section.dart';

/// Detects a tune's sectional form (AABB, ABAA, …) from its parsed measures and
/// returns section START markers (`Section` list). Restated strains reuse the
/// same label, so the existing section machinery renders the form correctly:
/// [SectionPalette] gives a shared color per label and `sectionRuns` unfolds
/// `Measure.repeatStart`/`repeatEnd` into the played order (so `|: A :|` shows as
/// two A-runs in the minimap) — this detector only supplies the *written* markers.
///
/// Pure Dart (no Flutter imports) so it can be unit-tested off-device.
class SectionDetector {
  /// Fewer strains than this → no useful structure; return no sections (the
  /// minimap stays hidden, matching today's behavior for structureless tunes).
  static const _minStrains = 2;

  /// Candidate strain sizes (in bars) for tunes without explicit repeat brackets.
  static const _blockSizes = [8, 4];

  static List<Section> detect(List<Measure> measures) {
    final seg = _segment(measures);
    if (seg == null || seg.strains.length < _minStrains) return const [];
    final prints = [for (final s in seg.strains) _fingerprint(s)];
    final labels = _assignLabels(prints);
    return [
      for (var i = 0; i < seg.strains.length; i++)
        Section(label: labels[i], startMeasure: seg.starts[i]),
    ];
  }

  // ── Segmentation ────────────────────────────────────────────────────────────

  /// Split the measures into strains. Primary signal: repeat brackets (each `|:`
  /// starts a strain). Fallback: equal blocks of 8 then 4 bars.
  static ({List<List<Measure>> strains, List<int> starts})? _segment(
      List<Measure> measures) {
    if (measures.length < 2) return null;

    if (measures.any((m) => m.repeatStart || m.repeatEnd)) {
      // A `|:` begins each strain; leading measures before the first one (a
      // pickup) are left unmarked so they adopt the following section's label.
      final marks = [
        for (var i = 0; i < measures.length; i++)
          if (measures[i].repeatStart) i,
      ];
      if (marks.length < 2) return null; // one strain (or none) → nothing to show
      final strains = <List<Measure>>[];
      final starts = <int>[];
      for (var k = 0; k < marks.length; k++) {
        final s = marks[k];
        final e = k + 1 < marks.length ? marks[k + 1] : measures.length;
        strains.add(measures.sublist(s, e));
        starts.add(measures[s].number);
      }
      return (strains: strains, starts: starts);
    }

    // No repeats: group into equal blocks, optionally dropping a one-measure
    // pickup, preferring 8-bar then 4-bar strains. Require ≥2 whole strains.
    for (final block in _blockSizes) {
      for (final drop in const [0, 1]) {
        if (drop >= measures.length) continue;
        final body = measures.sublist(drop);
        if (body.length >= block * 2 && body.length % block == 0) {
          final strains = <List<Measure>>[];
          final starts = <int>[];
          for (var i = 0; i < body.length; i += block) {
            final chunk = body.sublist(i, i + block);
            strains.add(chunk);
            starts.add(chunk.first.number);
          }
          return (strains: strains, starts: starts);
        }
      }
    }
    return null;
  }

  // ── Fingerprint + matching ──────────────────────────────────────────────────

  /// One token string per measure (its note sequence) so near-match can compare
  /// tails. Chord symbols and ornaments are already absent from the model, so the
  /// melodic content is pre-normalized.
  static List<String> _fingerprint(List<Measure> strain) => [
        for (final m in strain) [for (final n in m.notes) _noteToken(n)].join(','),
      ];

  static String _noteToken(NoteEvent n) => n.isRest
      ? 'R'
      : '${n.midiNumber}.${n.noteValue.index}.${n.dotted ? 1 : 0}';

  /// Greedy first-appearance labeling: A, B, C…; a strain matching an earlier one
  /// (exact or near) reuses its letter.
  static List<String> _assignLabels(List<List<String>> prints) {
    final known = <List<String>>[]; // one fingerprint per distinct label
    final labels = <String>[];
    for (final fp in prints) {
      var idx = -1;
      for (var i = 0; i < known.length; i++) {
        if (_matches(fp, known[i])) {
          idx = i;
          break;
        }
      }
      if (idx < 0) {
        idx = known.length;
        known.add(fp);
      }
      labels.add(String.fromCharCode(65 + idx)); // A, B, C, …
    }
    return labels;
  }

  /// Exact match, or "near" match: equal except the last ≤2 measures (with a
  /// length difference of at most 1) — catches a strain restated with a different
  /// ending/variation (the ABAA case).
  static bool _matches(List<String> a, List<String> b) {
    if (_listEq(a, b)) return true;
    if ((a.length - b.length).abs() > 1) return false;
    final n = math.min(a.length, b.length);
    if (n < 3) return false; // too short to fuzzy-match
    for (var i = 0; i < n - 2; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
