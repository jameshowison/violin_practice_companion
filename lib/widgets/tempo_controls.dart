import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tempo_presets.dart';
import '../services/providers.dart';

/// Asks for a tempo: a slider with − / + for single steps, with the Slow,
/// Medium and Performance tempos (at [performance]) marked along it (tap a
/// mark to jump there). Null when cancelled.
Future<int?> showBpmDialog(
  BuildContext context, {
  required String title,
  required int initial,
  required TempoSettings settings,
  required double performance,
}) {
  return showDialog<int>(
    context: context,
    builder: (context) => _BpmDialog(
        title: title,
        initial: initial,
        settings: settings,
        performance: performance),
  );
}

class _BpmDialog extends StatefulWidget {
  const _BpmDialog({
    required this.title,
    required this.initial,
    required this.settings,
    required this.performance,
  });

  final String title;
  final int initial;
  final TempoSettings settings;
  final double performance;

  @override
  State<_BpmDialog> createState() => _BpmDialogState();
}

class _BpmDialogState extends State<_BpmDialog> {
  late int _bpm = clampBpm(widget.initial);

  // Explicit, so the marks below can be placed on the track exactly: with it
  // the track runs from this inset to the same inset from the right.
  static const _inset = 14.0;

  void _set(int v) => setState(() => _bpm = clampBpm(v));

  Widget tick(ThemeData theme) => Container(
        width: 2,
        height: 6,
        color: theme.colorScheme.outline,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final marks = [
      for (final p in const [
        TempoPreset.slow,
        TempoPreset.medium,
        TempoPreset.performance,
      ])
        (preset: p, bpm: widget.settings.bpmFor(p, widget.performance)),
    ];

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filledTonal(
                  tooltip: 'Slower',
                  icon: const Icon(Icons.remove),
                  onPressed: _bpm > minBpm ? () => _set(_bpm - 1) : null,
                ),
                SizedBox(
                  width: 96,
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                          text: '$_bpm',
                          style: theme.textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ])),
                      TextSpan(
                          text: ' BPM', style: theme.textTheme.bodySmall),
                    ]),
                    textAlign: TextAlign.center,
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Faster',
                  icon: const Icon(Icons.add),
                  onPressed: _bpm < maxBpm ? () => _set(_bpm + 1) : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            // The presets' tempos, marked where they fall on the track.
            // Medium goes above and the other two below: the defaults are
            // only 20 bpm apart, too close for three labels in one row on a
            // phone-width dialog.
            LayoutBuilder(builder: (context, box) {
              final track = box.maxWidth - 2 * _inset;
              double xOf(int bpm) =>
                  _inset + track * (bpm - minBpm) / (maxBpm - minBpm);
              const labelWidth = 44.0;

              Widget lane(List<({TempoPreset preset, int bpm})> ms,
                  {required bool above}) {
                return SizedBox(
                  height: 44,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (final m in ms)
                        Positioned(
                          // Kept inside the dialog at the ends of the range.
                          left: (xOf(m.bpm) - labelWidth / 2)
                              .clamp(0.0, box.maxWidth - labelWidth),
                          width: labelWidth,
                          top: 0,
                          bottom: 0,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () => _set(m.bpm),
                            child: Column(
                              mainAxisAlignment: above
                                  ? MainAxisAlignment.end
                                  : MainAxisAlignment.start,
                              children: [
                                if (!above) tick(theme),
                                Text(m.preset.shortLabel,
                                    style: theme.textTheme.labelSmall,
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.visible),
                                Text('${m.bpm}',
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(
                                            color: theme.colorScheme.outline),
                                    maxLines: 1,
                                    softWrap: false),
                                if (above) tick(theme),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }

              return Column(
                children: [
                  lane([
                    for (final m in marks)
                      if (m.preset == TempoPreset.medium) m
                  ], above: true),
                  Slider(
                    value: _bpm.toDouble(),
                    min: minBpm.toDouble(),
                    max: maxBpm.toDouble(),
                    divisions: maxBpm - minBpm,
                    padding: const EdgeInsets.symmetric(horizontal: _inset),
                    label: '$_bpm',
                    onChanged: (v) => _set(v.round()),
                  ),
                  lane([
                    for (final m in marks)
                      if (m.preset != TempoPreset.medium) m
                  ], above: false),
                ],
              );
            }),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_bpm),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// What the play tray's tempo menu can do besides picking a preset.
enum _TempoAction { setPerformance, followRecording }

/// The play tray's tempo control: Slow / Medium / Performance at this piece's
/// tempo, each showing its bpm, and Custom, which asks for a number. Picking
/// Custom always asks, even when it is already selected — that is the only way
/// to change it from here. Below them, the piece's performance tempo can be set
/// by hand, or handed back to its recordings.
class TempoPresetPicker extends ConsumerWidget {
  const TempoPresetPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(tempoSettingsProvider);
    final notifier = ref.read(tempoSettingsProvider.notifier);
    final perf = ref.watch(performanceTempoProvider);
    final piece = ref.watch(selectedPieceProvider);
    final recorded = piece == null
        ? null
        : (ref.watch(loadedRecordingBpmProvider) ??
            ref.watch(pieceRecordingBpmProvider(piece.id)).valueOrNull);
    final style = Theme.of(context).textTheme.bodyMedium;

    Future<void> onSelected(Object choice) async {
      switch (choice) {
        case TempoPreset.custom:
          final bpm = await showBpmDialog(context,
              title: 'Custom tempo',
              initial: settings.custom,
              settings: settings,
              performance: perf.bpm);
          if (bpm == null) return;
          notifier
            ..setCustom(bpm)
            ..select(TempoPreset.custom);
        case TempoPreset p:
          notifier.select(p);
        case _TempoAction.setPerformance:
          if (piece == null) return;
          final bpm = await showBpmDialog(context,
              title: 'Performance tempo for this piece',
              initial: perf.bpm.round(),
              settings: settings,
              performance: perf.bpm);
          if (bpm != null) {
            ref
                .read(piecePerformanceOverrideProvider(piece.id).notifier)
                .set(bpm);
          }
        case _TempoAction.followRecording:
          if (piece == null) return;
          ref
              .read(piecePerformanceOverrideProvider(piece.id).notifier)
              .set(null);
      }
    }

    String presetLabel(TempoPreset p) => switch (p) {
          TempoPreset.custom => 'Custom (${settings.custom})…',
          TempoPreset.performance =>
            '${p.label} (${settings.bpmFor(p, perf.bpm)})',
          _ => '${p.label} (${settings.bpmFor(p, perf.bpm)}, '
              '${settings.percentFor(p)}%)',
        };

    return PopupMenuButton<Object>(
      tooltip: switch (perf.source) {
        PerformanceSource.piece => 'Tempo — performance set for this piece',
        PerformanceSource.recording =>
          'Tempo — performance from the recording',
        PerformanceSource.defaultTempo => 'Tempo',
      },
      initialValue: settings.preset,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final p in TempoPreset.values)
          PopupMenuItem<Object>(value: p, child: Text(presetLabel(p))),
        if (piece != null) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<Object>(
            value: _TempoAction.setPerformance,
            child: Text('Set performance tempo…'),
          ),
          if (perf.source == PerformanceSource.piece)
            PopupMenuItem<Object>(
              value: _TempoAction.followRecording,
              child: Text(recorded == null
                  ? 'Use default (${settings.performance})'
                  : 'Use recording (${recorded.round()})'),
            ),
        ],
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.music_note, size: 16),
            const SizedBox(width: 2),
            Flexible(
              child: Text(
                '${settings.preset.shortLabel} · ${settings.bpmAt(perf.bpm)}',
                style: style?.copyWith(fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }
}

/// The drawer's settings for what the named tempos mean: Slow and Medium as
/// shares of the piece's performance tempo, and the performance tempo for a
/// piece with no recording and none set by hand.
class TempoSettingsPanel extends ConsumerWidget {
  const TempoSettingsPanel({super.key});

  static const _percents = [40, 50, 60, 70, 75, 80, 85, 90];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(tempoSettingsProvider);
    final notifier = ref.read(tempoSettingsProvider.notifier);
    final perf = ref.watch(performanceTempoProvider);

    Widget percentRow(TempoPreset p) => Row(
          children: [
            Expanded(child: Text(p.label)),
            PopupMenuButton<int>(
              tooltip: '${p.label}: share of the performance tempo',
              initialValue: settings.percentFor(p),
              onSelected: (v) => notifier.setPercent(p, v),
              itemBuilder: (context) => [
                for (final v in _percents)
                  PopupMenuItem(value: v, child: Text('$v%')),
              ],
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Text(
                  '${settings.percentFor(p)}% · '
                  '${settings.bpmFor(p, perf.bpm)} BPM',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.primary),
                ),
              ),
            ),
          ],
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Tempo presets', style: Theme.of(context).textTheme.titleSmall),
        percentRow(TempoPreset.slow),
        percentRow(TempoPreset.medium),
        Row(
          children: [
            const Expanded(child: Text('Performance, if no recording')),
            TextButton(
              onPressed: () async {
                final bpm = await showBpmDialog(context,
                    title: 'Default performance tempo',
                    initial: settings.performance,
                    settings: settings,
                    performance: settings.performance.toDouble());
                if (bpm != null) notifier.setDefaultPerformance(bpm);
              },
              child: Text('${settings.performance} BPM'),
            ),
          ],
        ),
      ],
    );
  }
}
