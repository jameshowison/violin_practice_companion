import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/note_event.dart'; // DisplayMode
import '../models/section_run.dart';
import '../services/playback_service_base.dart';
import '../services/providers.dart';

/// Right-hand navigation strip: one emblem per [SectionRun] in display order.
///
/// Each section is drawn as an emblematic "row and a half" (a full bar + a half
/// bar) in the section's color — a schematic nod to a wrapped section with a
/// ragged last line, not a per-measure map. The current section is outlined;
/// tapping jumps to it.
///
/// "Where we are" resolves to: the playing section (live), else the top-most
/// scrolled section in the jianpu/fingering views, else the selected section.
class SectionMinimap extends ConsumerWidget {
  final List<SectionRun> runs;
  final Map<String, Color> sectionColors;
  final PlaybackServiceBase service;
  final ValueChanged<int> onTapRun;

  static const double width = 30;

  const SectionMinimap({
    super.key,
    required this.runs,
    required this.sectionColors,
    required this.service,
    required this.onTapRun,
  });

  int? _resolveCurrent(
      bool isCustom, int? scrollRun, int? playMeasure, MeasureSelection? sel) {
    if (playMeasure != null) {
      final i = runs.indexWhere(
          (r) => playMeasure >= r.firstMeasure && playMeasure <= r.lastMeasure);
      if (i >= 0) return i;
    }
    if (isCustom && scrollRun != null && scrollRun < runs.length) {
      return scrollRun;
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
    final scrollRun = ref.watch(scrollRunProvider);
    final selection = ref.watch(measureSelectionProvider);
    final theme = Theme.of(context);

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(60),
        border: Border(
            left: BorderSide(color: theme.dividerColor.withAlpha(120))),
      ),
      child: ValueListenableBuilder<int?>(
        valueListenable: service.currentMeasureNotifier,
        builder: (_, playMeasure, _) {
          final current =
              _resolveCurrent(isCustom, scrollRun, playMeasure, selection);
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
  final VoidCallback onTap;

  const _Emblem({
    required this.run,
    required this.color,
    required this.active,
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
        height: 26,
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
              child: Text(
                _railLabel,
                maxLines: 1,
                overflow: TextOverflow.visible,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.0,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurface.withAlpha(170),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
