import 'section_run.dart';

/// One displayed section in the section picker: every pass of it, as indices
/// into the unfolded run list. A plain section has one entry; a section inside
/// a folded repeat ([RunGroup.isLoop]) has one per pass, in performance order.
class RunSlot {
  final String label;
  final List<int> runs;

  const RunSlot({required this.label, required this.runs});
}

/// A stretch of the section picker: a single section; a block of sections the
/// performance plays [passes] times over (`A A` → `A`, `B C B C` → `B C`),
/// drawn once under a loop; or, with [jumpLabel], everything played after a
/// D.C./D.S., drawn as plain sections under that instruction.
class RunGroup {
  final List<RunSlot> slots;
  final int passes;

  /// The navigation instruction this stretch is played under (`D.C. al
  /// Fine`), or null for a stretch reached in the ordinary way.
  final String? jumpLabel;

  const RunGroup({required this.slots, required this.passes, this.jumpLabel});

  bool get isLoop => passes > 1;
  bool get isJump => jumpLabel != null;

  /// Unfolded run indices of the group's first and last runs (pass 1's first,
  /// the last pass's last) — the whole stretch, as performed.
  int get firstRun => slots.first.runs.first;
  int get lastRun => slots.last.runs.last;

  /// Which pass (0-based) unfolded run [run] belongs to, or null if it isn't
  /// in this group.
  int? passOf(int? run) {
    if (run == null) return null;
    for (final s in slots) {
      final p = s.runs.indexOf(run);
      if (p >= 0) return p;
    }
    return null;
  }
}

/// Folds the unfolded section runs for display. A section or block of
/// sections that the performance repeats back-to-back is shown once, under a
/// loop: `A A B C B C` → `[A] [B C]`.
///
/// Matching is by label sequence, scanning left to right and taking the
/// shortest block that repeats at each position, then as many further passes
/// of it as follow.
///
/// [jump] is the piece's D.C./D.S. ([ParsedPiece.navigationJump]): the runs
/// from its performance index on are the return, played straight through, so
/// they're never folded — they become one [RunGroup.isJump] group instead.
List<RunGroup> foldRunGroups(List<SectionRun> runs,
    {({int perfIndex, String label})? jump}) {
  var n = runs.length;
  if (jump != null) {
    final at = runs.indexWhere((r) => r.perfStart >= jump.perfIndex);
    if (at >= 0) n = at;
  }
  final labels = [for (final r in runs) r.label];

  bool same(int a, int b, int k) {
    for (var j = 0; j < k; j++) {
      if (labels[a + j] != labels[b + j]) return false;
    }
    return true;
  }

  final groups = <RunGroup>[];
  var i = 0;
  while (i < n) {
    var found = false;
    for (var k = 1; i + 2 * k <= n; k++) {
      if (!same(i, i + k, k)) continue;
      var p = 2;
      while (i + (p + 1) * k <= n && same(i, i + p * k, k)) {
        p++;
      }
      groups.add(RunGroup(passes: p, slots: [
        for (var j = 0; j < k; j++)
          RunSlot(
            label: labels[i + j],
            runs: [for (var pass = 0; pass < p; pass++) i + pass * k + j],
          ),
      ]));
      i += k * p;
      found = true;
      break;
    }
    if (!found) {
      groups.add(RunGroup(
          passes: 1, slots: [RunSlot(label: labels[i], runs: [i])]));
      i++;
    }
  }
  if (n < runs.length) {
    groups.add(RunGroup(
      passes: 1,
      jumpLabel: jump!.label,
      slots: [
        for (var j = n; j < runs.length; j++)
          RunSlot(label: labels[j], runs: [j]),
      ],
    ));
  }
  return groups;
}
