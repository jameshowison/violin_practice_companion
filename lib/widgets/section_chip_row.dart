import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/note_event.dart'; // DisplayMode
import '../models/section_run.dart';
import '../services/midi_generator.dart'; // HighlightEvent
import '../services/playback_service_base.dart';
import '../services/providers.dart';
import '../models/section_run_groups.dart';
import 'section_loop.dart';
import 'section_minimap.dart';

/// Height of the strip a folded repeat's loop is drawn in, above its chips.
const double _loopStrip = 12;

/// The phone's section picker: a row of chips on top of the play controls —
/// `All · A¹ · A² · B …`, over the **unfolded** [SectionRun]s, the same runs
/// the wide layout's [SectionMinimap] rail shows. A repeated block of two or
/// more sections is folded ([foldRunGroups]): `B C B C` shows as one `B C`
/// under a loop arrow, which shrinks the row and shows the form at a glance.
///
/// It lives in the play tray rather than down the right edge because picking a
/// section is something you do just before pressing Play, and a rail (even
/// put away to a tab) sat over the notes being read. `All` clears the
/// selection, so the whole piece plays — the one way back that is on screen.
///
/// The current run lights up exactly as on the rail ([resolveCurrentRun]), and
/// the row scrolls to keep it in view while playing. Edit/Delete for a single
/// selected measure sit at the right end, outside the scroll.
class SectionChipRow extends ConsumerStatefulWidget {
  final List<SectionRun> runs;

  /// [runs] as the picker shows them ([sectionRunGroupsProvider]).
  final List<RunGroup> groups;
  final Map<String, Color> sectionColors;
  final PlaybackServiceBase service;
  final ValueChanged<int> onTapRun;

  /// Selects unfolded runs [first]..[last] as one stretch — a folded
  /// repeat's loop, tapped.
  final void Function(int first, int last) onTapSpan;

  /// Fixed, so selecting a measure (which brings Edit/Delete in) never changes
  /// the tray's height and nudges the score's autoscroll inset.
  static const double height = 36;

  /// The row's height for a piece with a folded repeat: the chips plus the
  /// loop strip over them. Still fixed for the piece, for the same reason.
  static const double heightWithLoops = height + _loopStrip - 4;

  const SectionChipRow({
    super.key,
    required this.runs,
    required this.groups,
    required this.sectionColors,
    required this.service,
    required this.onTapRun,
    required this.onTapSpan,
  });

  @override
  ConsumerState<SectionChipRow> createState() => _SectionChipRowState();
}

class _SectionChipRowState extends ConsumerState<SectionChipRow> {
  final _keys = <int, GlobalKey>{};
  int? _shownCurrent;

  // Run index → the chip showing it (keyed by that chip's first run), so
  // following the current run finds its chip on any pass. Rebuilt each build.
  final _chipOf = <int, int>{};

  GlobalKey _keyFor(RunSlot slot) {
    for (final r in slot.runs) {
      _chipOf[r] = slot.runs.first;
    }
    return _keys.putIfAbsent(slot.runs.first, GlobalKey.new);
  }

  // Bring the newly current chip into view, after the frame that lights it.
  void _follow(int? current) {
    if (current == null || current == _shownCurrent) return;
    _shownCurrent = current;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[_chipOf[current]]?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(ctx,
            alignment: 0.5, duration: const Duration(milliseconds: 200));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(displayModeProvider);
    final isCustom = mode == DisplayMode.jianpu ||
        mode == DisplayMode.fingering ||
        mode == DisplayMode.combined;
    final scrollMeasure = ref.watch(scrollMeasureProvider);
    final selection = ref.watch(measureSelectionProvider);
    final runs = widget.runs;
    final groups = widget.groups;
    _chipOf.clear();
    // Loops and the D.C. label both sit in a strip over their chips.
    final hasLoop = groups.any((g) => g.isLoop || g.isJump);
    final theme = Theme.of(context);

    return SizedBox(
      height: hasLoop ? SectionChipRow.heightWithLoops : SectionChipRow.height,
      child: Row(
        children: [
          Expanded(
            child: runs.isEmpty
                ? const SizedBox.shrink()
                : ValueListenableBuilder<HighlightEvent?>(
                    valueListenable: widget.service.currentHighlightNotifier,
                    builder: (_, play, _) {
                      final current = resolveCurrentRun(
                          runs, isCustom, scrollMeasure, play, selection);
                      _follow(current);

                      Widget slotChip(RunSlot slot, {bool lit = false}) => _Chip(
                            key: _keyFor(slot),
                            label: slot.label,
                            color: widget.sectionColors[slot.label] ??
                                Colors.blueGrey,
                            active: lit || slot.runs.contains(current),
                            onTap: () => widget.onTapRun(
                                runForSlotTap(runs, slot, selection)),
                          );

                      Widget group(RunGroup g) {
                        final st = RunGroupState.of(
                            g, runs, current, play, selection);
                        final chips = Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final s in g.slots)
                              slotChip(s, lit: st.wholeSelected)
                          ],
                        );
                        if (!hasLoop) return chips;
                        if (!g.isLoop && !g.isJump) {
                          return Padding(
                            padding: const EdgeInsets.only(top: _loopStrip),
                            child: chips,
                          );
                        }
                        final onSurface = theme.colorScheme.onSurface;
                        final lineColor =
                            st.lit ? onSurface : onSurface.withAlpha(130);
                        // The strip over the chips: the loop with its pass
                        // dots, or the D.C. instruction in words.
                        final strip = g.isJump
                            ? Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: Text(g.jumpLabel!,
                                      maxLines: 1,
                                      style: sectionJumpLabelStyle(st.lit
                                          ? onSurface
                                          : onSurface.withAlpha(170))),
                                ),
                              )
                            : CustomPaint(
                                painter: SectionLoopPainter(
                                  axis: Axis.horizontal,
                                  color: lineColor,
                                  dotColor: onSurface,
                                  passes: g.passes,
                                  filled: st.filled,
                                  endInset: 6, // the last chip's margin
                                ),
                              );
                        // IntrinsicWidth: the row scrolls, so its width is
                        // unbounded — the strip takes the chips' width.
                        return IntrinsicWidth(
                            child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Tapping the strip selects the whole stretch:
                            // every pass of a repeat, or the D.C. return.
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () =>
                                  widget.onTapSpan(g.firstRun, g.lastRun),
                              child: SizedBox(height: _loopStrip, child: strip),
                            ),
                            Expanded(child: chips),
                          ],
                        ));
                      }

                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        // With loops, the strip itself is the top margin.
                        // The trailing room lets the row's end scroll clear
                        // of the tray's chevron, which the strip tucks beside.
                        padding: EdgeInsets.fromLTRB(
                            8, hasLoop ? 0 : 4, hasLoop ? 44 : 8, 4),
                        child: Row(
                          // Full row height: a taller target than the label.
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: EdgeInsets.only(
                                  top: hasLoop ? _loopStrip : 0),
                              child: _Chip(
                                label: 'All',
                                color: null,
                                active: selection == null,
                                tooltip: 'Play the whole piece',
                                onTap: () => ref
                                    .read(measureSelectionProvider.notifier)
                                    .state = null,
                              ),
                            ),
                            for (final g in groups) group(g),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: EdgeInsets.only(top: hasLoop ? _loopStrip : 0),
            child: const MeasureActions(direction: Axis.horizontal),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// One chip: the section's color as a reply-quote bar (as on the rail and the
/// staff's margin), then its label. [color] null is the uncoloured `All` chip.
class _Chip extends StatelessWidget {
  final String label;
  final Color? color;
  final bool active;
  final String? tooltip;
  final VoidCallback onTap;

  const _Chip({
    super.key,
    required this.label,
    required this.color,
    required this.active,
    required this.onTap,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = color ?? theme.colorScheme.onSurface.withAlpha(150);
    final chip = GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(minWidth: 36),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: active ? accent.withAlpha(28) : null,
          border: Border.all(
            color: active ? accent : theme.dividerColor.withAlpha(120),
            width: active ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (color != null) ...[
              Container(
                width: 4,
                height: 16,
                decoration: BoxDecoration(
                  color: active ? color : color!.withAlpha(150),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: 13,
                height: 1.0,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurface.withAlpha(170),
              ),
            ),
          ],
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}
