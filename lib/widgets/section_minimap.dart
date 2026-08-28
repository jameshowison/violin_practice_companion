import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/note_event.dart'; // DisplayMode
import '../models/section.dart'; // sectionsAfterMeasureDelete
import '../models/section_run.dart';
import '../screens/edit_measure_screen.dart';
import '../services/measure_xml_editor.dart';
import '../services/midi_generator.dart';
import '../services/playback_service_base.dart';
import '../services/providers.dart';
import '../services/staff_zoom.dart';

/// Right-hand navigation strip: one emblem per **unfolded** [SectionRun] (so a
/// `|: A :|` repeat shows two A emblems — `A A B B`). This is the single place
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
  final Map<String, Color> sectionColors;
  final PlaybackServiceBase service;
  final ValueChanged<int> onTapRun;

  /// Fixed strip width — wide enough for a two-glyph label (e.g. `A¹`) at the
  /// largest marker scale. See the class doc for why this must not vary.
  static const double width = 44;

  const SectionMinimap({
    super.key,
    required this.runs,
    required this.sectionColors,
    required this.service,
    required this.onTapRun,
  });

  int? _resolveCurrent(bool isCustom, int? scrollMeasure, HighlightEvent? play,
      MeasureSelection? sel) {
    if (play != null) {
      // Pass-accurate: match the run whose performance-order slice is playing.
      final i = runs.indexWhere((r) => r.containsPerf(play.performanceIndex));
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
      final exact = runs.indexWhere((r) =>
          r.firstMeasure == sel.startMeasure && r.lastMeasure == sel.endMeasure);
      if (exact >= 0) return exact;
      final inside = runs.indexWhere((r) =>
          sel.startMeasure >= r.firstMeasure &&
          sel.startMeasure <= r.lastMeasure);
      if (inside >= 0) return inside;
    }
    return null;
  }

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
          const _MeasureActionsHeader(),
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
                  final current = _resolveCurrent(
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
                            for (var i = 0; i < runs.length; i++)
                              _Emblem(
                                run: runs[i],
                                color: sectionColors[runs[i].label] ??
                                    Colors.blueGrey,
                                active: i == current,
                                scale: scale,
                                onTap: () => onTapRun(i),
                              ),
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
/// Edit + Delete, stacked to fit the rail's fixed width. Renders nothing when
/// no single editable measure is selected — the caller still reserves this
/// column so the actions have somewhere to appear the moment one is (see
/// piece_detail_screen.dart's `canEditSelection`).
class _MeasureActionsHeader extends ConsumerWidget {
  const _MeasureActionsHeader();

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

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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

class _Emblem extends StatelessWidget {
  final SectionRun run;
  final Color color;
  final bool active;

  /// Multiplier on the label size and emblem height, so the marker grows with
  /// the notation zoom. Horizontal metrics stay fixed — the strip's width must
  /// not vary (see [SectionMinimap]).
  final double scale;
  final VoidCallback onTap;

  const _Emblem({
    required this.run,
    required this.color,
    required this.active,
    required this.scale,
    required this.onTap,
  });

  // Unicode superscripts for numbered passes (e.g. C¹ / C²).
  static const _sup = ['', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'];

  String get _railLabel {
    if (run.passCount <= 1) return run.label;
    final n = run.passIndex + 1;
    final suffix = n < _sup.length ? _sup[n] : '$n';
    return '${run.label}$suffix';
  }

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
                  _railLabel,
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
