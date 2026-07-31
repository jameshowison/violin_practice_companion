import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/note_event.dart'; // DisplayMode
import '../models/section_run.dart';
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
      child: ValueListenableBuilder<HighlightEvent?>(
        valueListenable: service.currentHighlightNotifier,
        builder: (_, play, _) {
          final current =
              _resolveCurrent(isCustom, scrollMeasure, play, selection);
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < runs.length; i++)
                  _Emblem(
                    run: runs[i],
                    color: sectionColors[runs[i].label] ?? Colors.blueGrey,
                    active: i == current,
                    scale: scale,
                    onTap: () => onTapRun(i),
                  ),
              ],
            ),
          );
        },
      ),
    );
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
