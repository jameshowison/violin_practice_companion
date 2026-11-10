import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/note_event.dart'; // DisplayMode
import '../models/section.dart'; // sectionsAfterMeasureDelete
import '../models/section_run.dart';
import '../models/section_run_groups.dart';
import '../screens/edit_measure_screen.dart';
import '../services/measure_xml_editor.dart';
import '../services/midi_generator.dart';
import '../services/playback_service_base.dart';
import '../services/providers.dart';
import '../services/staff_zoom.dart';
import 'section_loop.dart';

/// Which unfolded run is "where we are": the playing pass (by performance
/// index), else the top-most scrolled run in the custom views, else the
/// selection. Shared by [SectionMinimap] and the phone's section chip row so
/// both light the same run.
int? resolveCurrentRun(List<SectionRun> runs, bool isCustom,
    int? scrollMeasure, HighlightEvent? play, MeasureSelection? sel) {
  if (play != null) {
    // Pass-accurate: match the run whose performance-order slice is playing.
    final i = runs.indexWhere((r) =>
        r.containsPerf(play.performanceIndex, noteIndex: play.noteIndex));
    if (i >= 0) return i;
    // Fallback (e.g. a run with no perf slice): match by measure number.
    final byMeasure = runs.indexWhere((r) =>
        play.measureNumber >= r.firstMeasure &&
        play.measureNumber <= r.lastMeasure);
    if (byMeasure >= 0) return byMeasure;
  }
  if (isCustom && scrollMeasure != null) {
    final i = runs.indexWhere((r) =>
        scrollMeasure >= r.firstMeasure && scrollMeasure <= r.lastMeasure);
    if (i >= 0) return i;
  }
  if (sel != null) {
    final exact = runs.indexWhere((r) => MeasureSelection.ofRun(r) == sel);
    if (exact >= 0) return exact;
    // A selection pinned to a pass (a whole repeat, or the D.C. return) starts
    // in a run by playing position — its bars alone may also be an earlier
    // pass's (the D.C. return's A is the first A's bars).
    if (sel.startPerf >= 0) {
      final pinned = runs.indexWhere((r) => r.containsPerf(sel.startPerf,
          noteIndex: sel.startNote));
      if (pinned >= 0) return pinned;
    }
    final inside = runs.indexWhere((r) =>
        sel.startMeasure >= r.firstMeasure &&
        sel.startMeasure <= r.lastMeasure);
    if (inside >= 0) return inside;
  }
  return null;
}

/// The run a double-tap on [measure] selects, as an index into [runs], or null
/// when no run holds that bar (a piece without sections).
///
/// Every pass of a repeated section holds the same written bars, so several
/// runs can match. If [before] — the selection as it was before the double-tap
/// began — was one of them, step to the next (A¹ → A² → A¹), so double-tapping
/// again walks the passes; otherwise take the first.
int? sectionRunForDoubleTap(
    List<SectionRun> runs, int measure, MeasureSelection? before) {
  final matches = [
    for (var i = 0; i < runs.length; i++)
      if (measure >= runs[i].firstMeasure && measure <= runs[i].lastMeasure) i,
  ];
  if (matches.isEmpty) return null;
  final at = before == null
      ? -1
      : matches.indexWhere((i) => MeasureSelection.ofRun(runs[i]) == before);
  return matches[(at + 1) % matches.length];
}

/// The run a tap on [slot] (a folded section's chip) selects, as an index into
/// [runs]: its first pass, or — when one of its passes is the selection — the
/// next one. The last pass maps to itself, so the caller's "tap the selected
/// section again to clear" takes over: B¹ → B² → nothing.
int runForSlotTap(
    List<SectionRun> runs, RunSlot slot, MeasureSelection? selection) {
  final at = selection == null
      ? -1
      : slot.runs
          .indexWhere((i) => MeasureSelection.ofRun(runs[i]) == selection);
  if (at < 0) return slot.runs.first;
  return slot.runs[(at + 1).clamp(0, slot.runs.length - 1)];
}

/// Right-hand navigation strip: the **unfolded** [SectionRun]s (so a
/// `|: A :|` repeat shows two A emblems — `A¹ A²`), with a repeated block of
/// two or more sections folded under a loop down its left ([foldRunGroups]). This is the single place
/// that conveys the whole-piece structure; the notation itself stays folded.
///
/// Each section is drawn as an emblematic bar in the section's color. The
/// current section is outlined; tapping jumps to it.
///
/// "Where we are" resolves to: the playing pass (live, by performance index —
/// so the 2nd pass of A lights the 2nd A emblem), else the top-most scrolled
/// section in the jianpu/fingering views, else the selected section.
///
/// In the staff/annotation/tab views the label and emblem height scale with the
/// notation zoom (see [sectionMarkerScaleFor]) — zooming in because the notes
/// were too small to read should not leave the part markers unreadable. The
/// custom views (jianpu/finger/+) aren't zoomable, so there the emblems keep
/// their base size.
///
/// The strip's WIDTH is deliberately constant. It is a `Row` sibling of the
/// notation, so its width subtracts from the width the score is engraved to —
/// and the auto zoom's predicted height is proportional to that width. A
/// zoom-dependent width therefore closes a positive feedback loop: wider strip →
/// narrower notation → auto picks fewer measures per line → bigger markers →
/// wider strip. Measured before this was pinned, opening a piece cascaded
/// 6 → 4 → 3 measures per line across three extra engraves, with a visible
/// reflow each time. A constant width makes that structurally impossible.
class SectionMinimap extends ConsumerWidget {
  final List<SectionRun> runs;

  /// [runs] as the rail shows them ([sectionRunGroupsProvider]).
  final List<RunGroup> groups;
  final Map<String, Color> sectionColors;
  final PlaybackServiceBase service;
  final ValueChanged<int> onTapRun;

  /// Selects unfolded runs [first]..[last] as one stretch — a folded
  /// repeat's loop, tapped.
  final void Function(int first, int last) onTapSpan;

  /// Width of the gutter a folded repeat's loop takes from its emblems.
  static const double loopGutter = 12;

  /// Fixed strip width — wide enough for a two-glyph label (e.g. `A¹`) at the
  /// largest marker scale. See the class doc for why this must not vary.
  static const double width = 44;

  const SectionMinimap({
    super.key,
    required this.runs,
    required this.groups,
    required this.sectionColors,
    required this.service,
    required this.onTapRun,
    required this.onTapSpan,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(displayModeProvider);
    final isCustom = mode == DisplayMode.jianpu ||
        mode == DisplayMode.fingering ||
        mode == DisplayMode.combined;
    final scrollMeasure = ref.watch(scrollMeasureProvider);
    final selection = ref.watch(measureSelectionProvider);
    final theme = Theme.of(context);
    // Only the Verovio-rendered views zoom, so only they scale their markers.
    final scale = isCustom
        ? 1.0
        : sectionMarkerScaleFor(ref.watch(effectiveMeasuresPerLineProvider));

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(60),
        border: Border(
            left: BorderSide(color: theme.dividerColor.withAlpha(120))),
      ),
      // The action header is a plain (non-scrolling) sibling of the emblem
      // list rather than its first child, so it stays pinned at the rail's
      // top edge — level with the first staff line — instead of scrolling
      // away with the sections.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const MeasureActions(direction: Axis.vertical),
          Expanded(
            // A plain SingleChildScrollView always top-aligns short content
            // within its viewport (the viewport fills the Expanded height
            // regardless of content length) — that's what used to read as
            // "centered" when the header didn't yet exist and ate none of
            // that height. The ConstrainedBox(minHeight)+Center below is the
            // standard trick to keep the emblems centered when they fit,
            // while still scrolling if a piece has enough sections to
            // overflow.
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  ValueListenableBuilder<HighlightEvent?>(
                valueListenable: service.currentHighlightNotifier,
                builder: (_, play, _) {
                  final current = resolveCurrentRun(runs,
                      isCustom, scrollMeasure, play, selection);
                  return SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 3, vertical: 8),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          minHeight:
                              (constraints.maxHeight - 16).clamp(0, double.infinity)),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Back to the whole piece. Only offered while
                            // something is selected — with nothing selected
                            // it would be a no-op taking a row.
                            if (selection != null && runs.isNotEmpty)
                              _AllEmblem(
                                scale: scale,
                                onTap: () => ref
                                    .read(measureSelectionProvider.notifier)
                                    .state = null,
                              ),
                            for (final g in groups)
                              _group(context, g, current, play, selection, scale),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One stretch of the rail: a lone emblem; a folded repeat's emblems with
  /// its loop in a gutter down their left; or the D.C. return's emblems under
  /// its instruction. Tapping the loop or the instruction selects the whole
  /// stretch.
  Widget _group(BuildContext context, RunGroup g, int? current,
      HighlightEvent? play, MeasureSelection? selection, double scale) {
    final st = RunGroupState.of(g, runs, current, play, selection);
    final emblems = [
      for (final slot in g.slots)
        _Emblem(
          label: slot.label,
          color: sectionColors[slot.label] ?? Colors.blueGrey,
          active: st.wholeSelected || slot.runs.contains(current),
          scale: scale,
          onTap: () => onTapRun(runForSlotTap(runs, slot, selection)),
        ),
    ];
    final onSurface = Theme.of(context).colorScheme.onSurface;
    if (g.isJump) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onTapSpan(g.firstRun, g.lastRun),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 3),
              // The rail is narrow: the instruction shrinks to fit it.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(g.jumpLabel!,
                    maxLines: 1,
                    style: sectionJumpLabelStyle(
                        st.lit ? onSurface : onSurface.withAlpha(170),
                        fontSize: 9 * scale)),
              ),
            ),
          ),
          ...emblems,
        ],
      );
    }
    if (!g.isLoop) return emblems.single;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onTapSpan(g.firstRun, g.lastRun),
            child: SizedBox(
              width: loopGutter,
              child: CustomPaint(
                painter: SectionLoopPainter(
                  axis: Axis.vertical,
                  color: st.lit ? onSurface : onSurface.withAlpha(130),
                  dotColor: onSurface,
                  passes: g.passes,
                  filled: st.filled,
                  endInset: 4, // the last emblem's margin
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: emblems,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Edit/Delete-measure actions ────────────────────────────────────────────
//
// Measure selection happens directly on the notation (staff/jianpu/
// fingering). The §6 note editor is reachable from a button here that
// appears whenever exactly one measure is selected on a platform with
// writable storage — independent of the drawer/tray state, so it's
// discoverable the moment you tap a measure. Fixtures are materialized to
// an editable file on first save (see EditMeasureScreen._save); web has no
// file storage so editing is disabled there via `supportsEditing` — no
// `kIsWeb` needed in shared code.
//
// These used to be FABs floating over the notation itself, which covered the
// music being edited (worst on iPhone portrait). They then moved to the
// title bar, which crowded the piece title. This rail is already the
// narrowest fixed-width column in the layout and reads as "controls for the
// selected measure" on its own, so it's their home now.
/// Edit + Delete for the single selected measure. [Axis.vertical] stacks them
/// to fit the rail's fixed width (with a rule under them); [Axis.horizontal]
/// lays them side by side for the phone's section chip row. Renders nothing
/// when no single editable measure is selected — the caller still reserves
/// room so the actions have somewhere to appear the moment one is (see
/// piece_detail_screen.dart's `canEditSelection`).
class MeasureActions extends ConsumerWidget {
  final Axis direction;

  const MeasureActions({super.key, required this.direction});

  static const _buttonConstraints =
      BoxConstraints.tightFor(width: 36, height: 32);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sel = ref.watch(measureSelectionProvider);
    final canEdit = sel != null &&
        sel.isSingle &&
        ref.watch(pieceRepositoryProvider).supportsEditing;
    if (!canEdit) return const SizedBox.shrink();
    // A part must keep at least one measure (see MeasureXmlEditor.deleteMeasure).
    final measureCount =
        ref.watch(parsedPieceProvider).valueOrNull?.measures.length ?? 0;

    final buttons = [
          IconButton(
            icon: const Icon(Icons.edit, size: 16),
            tooltip: 'Edit measure ${sel.startMeasure}',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: _buttonConstraints,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    EditMeasureScreen(measureNumber: sel.startMeasure),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 16),
            tooltip: 'Delete measure ${sel.startMeasure}',
            color: Theme.of(context).colorScheme.error,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: _buttonConstraints,
            onPressed: measureCount > 1
                ? () => _confirmAndDelete(context, ref, sel.startMeasure)
                : null,
          ),
    ];
    if (direction == Axis.horizontal) {
      return Row(mainAxisSize: MainAxisSize.min, children: buttons);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...buttons,
          const Divider(height: 8, thickness: 1),
        ],
      ),
    );
  }

  /// Confirms, then removes the measure from the piece's MusicXML. Destructive
  /// and there's no undo, hence the dialog.
  Future<void> _confirmAndDelete(
      BuildContext context, WidgetRef ref, int measureNumber) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete measure $measureNumber?'),
        content: const Text(
            'The bar and its notes are removed and the following bars shift '
            'back one. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final piece = ref.read(selectedPieceProvider);
    if (piece == null) return;
    final repo = ref.read(pieceRepositoryProvider);
    try {
      final original = await repo.loadMusicXml(piece);
      final newXml = MeasureXmlEditor.deleteMeasure(original, measureNumber);
      final updated = await repo.writeEditedMusicXml(piece, newXml);
      // Markers past the deleted bar shift back with it.
      final sections =
          sectionsAfterMeasureDelete(piece.sections, measureNumber);
      await repo.saveSections(piece.id, sections);
      ref.read(selectedPieceProvider.notifier).state =
          updated.copyWith(sections: sections);
      // The selected bar no longer exists (and the numbers around it moved).
      ref.read(measureSelectionProvider.notifier).state = null;
      ref.invalidate(piecesProvider);
      ref.invalidate(parsedPieceProvider);
    } catch (e) {
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Could not delete measure'),
          content: Text('$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }
}

/// The rail's "whole piece" entry: clears the selection so everything plays.
class _AllEmblem extends StatelessWidget {
  final double scale;
  final VoidCallback onTap;

  const _AllEmblem({required this.scale, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: 'Play the whole piece',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 26 * scale,
          margin: const EdgeInsets.only(bottom: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: theme.dividerColor),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'All',
              maxLines: 1,
              style: TextStyle(
                fontSize: 11 * scale,
                height: 1.0,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurface.withAlpha(170),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Emblem extends StatelessWidget {
  final String label;
  final Color color;
  final bool active;

  /// Multiplier on the label size and emblem height, so the marker grows with
  /// the notation zoom. Horizontal metrics stay fixed — the strip's width must
  /// not vary (see [SectionMinimap]).
  final double scale;
  final VoidCallback onTap;

  const _Emblem({
    required this.label,
    required this.color,
    required this.active,
    required this.scale,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final barColor = active ? color : color.withAlpha(150);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 26 * scale,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          color: active ? color.withAlpha(28) : null,
          border: Border.all(
            color: active ? color : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            // Reply-quote rail bar, matching the staff's section margin bar.
            Container(
              width: 4,
              height: double.infinity,
              decoration: BoxDecoration(
                color: barColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 3),
            Expanded(
              // scaleDown guarantees a long label (or a superscripted pass, e.g.
              // `A¹`) can never overflow the fixed-width strip, whatever the zoom.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11 * scale,
                    height: 1.0,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurface.withAlpha(170),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
