import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/fingering_group_palette.dart';
import '../models/recorder_fingering.dart';
import '../services/fingering_annotation_builder.dart' show noteNameOf;
import '../services/midi_generator.dart' show HighlightEvent;
import '../services/providers.dart';
import '../services/wind_fingering.dart';
import 'hole_diagram.dart';

/// The side panel's width, in logical pixels (the mockup's ~130pt).
const double fingeringPanelWidth = 132;

/// [child] (the score) with the fingering side panel on its right — in
/// landscape, for an instrument with a fingering chart (the recorder). For
/// every other instrument, and in portrait, [child] exactly as it was.
class FingeringPanelSlot extends ConsumerWidget {
  final Widget child;

  /// The playing note, and the player's notes in playing order (see
  /// `PlaybackServiceBase.highlightEvents`).
  final ValueListenable<HighlightEvent?> highlight;
  final List<HighlightEvent> Function() events;

  const FingeringPanelSlot({
    super.key,
    required this.child,
    required this.highlight,
    required this.events,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chart = ref.watch(instrumentProfileProvider).fingeringChart;
    // The strings never see the LayoutBuilder: their tree is untouched.
    if (chart == null) return child;
    return LayoutBuilder(builder: (context, c) {
      final landscape = c.maxWidth > c.maxHeight &&
          c.maxWidth >= fingeringPanelWidth * 3.5;
      if (!landscape) return child;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: child),
          SizedBox(
            width: fingeringPanelWidth,
            child: RecorderFingeringPanel(
                chart: chart, highlight: highlight, events: events),
          ),
        ],
      );
    });
  }
}

/// The current note, big: its letter and register, the hole diagram with
/// the holes that changed from the note before ringed, the change in words,
/// and the next note with a thumbnail.
///
/// The current note is the playing one while the player runs; stopped, the
/// tapped note, else the selection's first, else the piece's first
/// ([focusIndex]).
class RecorderFingeringPanel extends ConsumerWidget {
  final HoleFingeringChart chart;
  final ValueListenable<HighlightEvent?> highlight;
  final List<HighlightEvent> Function() events;

  const RecorderFingeringPanel({
    super.key = const ValueKey('recorder_fingering_panel'),
    required this.chart,
    required this.highlight,
    required this.events,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parsed = ref.watch(parsedPieceProvider).valueOrNull;
    final tapped = ref.watch(fingeringFocusProvider);
    final sel = ref.watch(measureSelectionProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(left: BorderSide(color: scheme.outlineVariant)),
      ),
      child: parsed == null
          ? const SizedBox.expand()
          : ValueListenableBuilder<HighlightEvent?>(
              valueListenable: highlight,
              builder: (context, playing, _) {
                final order = playingOrder(parsed, events());
                final i = focusIndex(order,
                    playing: playing,
                    tapped: tapped,
                    selection: sel == null
                        ? null
                        : (
                            startMeasure: sel.startMeasure,
                            startNote: sel.startNote,
                            endMeasure: sel.endMeasure,
                            startPerf: sel.startPerf,
                          ));
                if (i == null) return const SizedBox.expand();
                return _PanelBody(
                  chart: chart,
                  current: order[i],
                  previous: i > 0 ? order[i - 1] : null,
                  next: i + 1 < order.length ? order[i + 1] : null,
                );
              },
            ),
    );
  }
}

class _PanelBody extends StatelessWidget {
  final HoleFingeringChart chart;
  final PlayedNote current;
  final PlayedNote? previous;
  final PlayedNote? next;

  const _PanelBody({
    required this.chart,
    required this.current,
    required this.previous,
    required this.next,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entry = chart[current.midi];
    final prevFingering =
        previous == null ? null : chart.fingeringFor(previous!.midi);
    final nextFingering = next == null ? null : chart.fingeringFor(next!.midi);
    final name = noteNameOf(current.pitch);
    final lines = entry == null
        ? const <String>['Not on the chart']
        : previous != null && prevFingering == null
            ? const <String>[]
            : fingeringChangeLines(prevFingering, entry.fingering);
    final muted = scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Column(
        children: [
          Text(name,
              key: const ValueKey('fingering_panel_note'),
              style: theme.textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w800, height: 1.0)),
          Text(registerWord(current.midi),
              style: theme.textTheme.labelMedium?.copyWith(color: muted)),
          const SizedBox(height: 3),
          if (entry != null)
            Container(
              width: 28,
              height: 3,
              decoration: BoxDecoration(
                color: fingeringGroupColor(entry.group, theme.brightness),
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          const SizedBox(height: 4),
          Expanded(
            child: entry == null
                ? const SizedBox.shrink()
                : LayoutBuilder(builder: (context, c) {
                    final h = c.maxHeight
                        .clamp(0.0, c.maxWidth / HoleDiagram.aspect)
                        .toDouble();
                    return Center(
                      child: HoleDiagram(
                        fingering: entry.fingering,
                        changedFrom: prevFingering,
                        showNumbers: true,
                        height: h,
                      ),
                    );
                  }),
          ),
          const SizedBox(height: 4),
          if (lines.isEmpty && previous != null)
            Text('Same fingers',
                style: theme.textTheme.bodySmall?.copyWith(color: muted))
          else
            for (final l in lines)
              Text(l,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: l.startsWith('Lift') ? muted : scheme.onSurface,
                    fontWeight:
                        l.startsWith('Lift') ? FontWeight.w400 : FontWeight.w600,
                  )),
          if (entry != null && entry.note != null)
            Text(entry.note!,
                style: theme.textTheme.labelSmall?.copyWith(color: muted)),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                next == null ? 'Last note' : 'Next: ',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              if (next != null)
                Text(noteNameOf(next!.pitch),
                    key: const ValueKey('fingering_panel_next'),
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              if (nextFingering != null) ...[
                const SizedBox(width: 6),
                HoleDiagram(fingering: nextFingering, height: 40),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
