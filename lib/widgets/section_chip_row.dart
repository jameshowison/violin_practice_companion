import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/note_event.dart'; // DisplayMode
import '../models/section_run.dart';
import '../services/midi_generator.dart'; // HighlightEvent
import '../services/playback_service_base.dart';
import '../services/providers.dart';
import 'section_minimap.dart';

/// The phone's section picker: a row of chips on top of the play controls —
/// `All · A¹ · A² · B …`, one per **unfolded** [SectionRun], the same runs the
/// wide layout's [SectionMinimap] rail shows.
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
  final Map<String, Color> sectionColors;
  final PlaybackServiceBase service;
  final ValueChanged<int> onTapRun;

  /// Fixed, so selecting a measure (which brings Edit/Delete in) never changes
  /// the tray's height and nudges the score's autoscroll inset.
  static const double height = 36;

  const SectionChipRow({
    super.key,
    required this.runs,
    required this.sectionColors,
    required this.service,
    required this.onTapRun,
  });

  @override
  ConsumerState<SectionChipRow> createState() => _SectionChipRowState();
}

class _SectionChipRowState extends ConsumerState<SectionChipRow> {
  final _keys = <int, GlobalKey>{};
  int? _shownCurrent;

  GlobalKey _keyFor(int i) => _keys.putIfAbsent(i, GlobalKey.new);

  // Bring the newly current chip into view, after the frame that lights it.
  void _follow(int? current) {
    if (current == null || current == _shownCurrent) return;
    _shownCurrent = current;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[current]?.currentContext;
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

    return SizedBox(
      height: SectionChipRow.height,
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
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: Row(
                          // Full row height: a taller target than the label.
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _Chip(
                              label: 'All',
                              color: null,
                              active: selection == null,
                              tooltip: 'Play the whole piece',
                              onTap: () => ref
                                  .read(measureSelectionProvider.notifier)
                                  .state = null,
                            ),
                            for (var i = 0; i < runs.length; i++)
                              _Chip(
                                key: _keyFor(i),
                                label: sectionRunLabel(runs[i]),
                                color: widget.sectionColors[runs[i].label] ??
                                    Colors.blueGrey,
                                active: i == current,
                                onTap: () => widget.onTapRun(i),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const MeasureActions(direction: Axis.horizontal),
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
