import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tempo_presets.dart';
import '../services/providers.dart';

/// Asks for a tempo: a slider with − / + for single steps, with the Slow,
/// Medium and Performance tempos marked along it (tap a mark to jump there).
/// Null when cancelled.
Future<int?> showBpmDialog(
  BuildContext context, {
  required String title,
  required int initial,
  required TempoSettings settings,
}) {
  return showDialog<int>(
    context: context,
    builder: (context) =>
        _BpmDialog(title: title, initial: initial, settings: settings),
  );
}

class _BpmDialog extends StatefulWidget {
  const _BpmDialog({
    required this.title,
    required this.initial,
    required this.settings,
  });

  final String title;
  final int initial;
  final TempoSettings settings;

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
        (preset: p, bpm: widget.settings.bpmFor(p)),
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

/// The play tray's tempo control: Slow / Medium / Performance, each showing its
/// bpm, and Custom, which asks for a number. Picking Custom always asks, even
/// when it is already selected — that is the only way to change it from here.
class TempoPresetPicker extends ConsumerWidget {
  const TempoPresetPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(tempoSettingsProvider);
    final notifier = ref.read(tempoSettingsProvider.notifier);
    final style = Theme.of(context).textTheme.bodyMedium;

    return PopupMenuButton<TempoPreset>(
      tooltip: 'Tempo',
      initialValue: settings.preset,
      onSelected: (p) async {
        if (p != TempoPreset.custom) {
          notifier.select(p);
          return;
        }
        final bpm = await showBpmDialog(context,
            title: 'Custom tempo',
            initial: settings.custom,
            settings: settings);
        if (bpm == null) return;
        notifier
          ..setBpm(TempoPreset.custom, bpm)
          ..select(TempoPreset.custom);
      },
      itemBuilder: (context) => [
        for (final p in TempoPreset.values)
          PopupMenuItem(
            value: p,
            child: Text(p == TempoPreset.custom
                ? 'Custom (${settings.custom})…'
                : '${p.label} (${settings.bpmFor(p)})'),
          ),
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
                '${settings.preset.shortLabel} · ${settings.bpm}',
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

/// The drawer's settings for what each named tempo means. Tapping a value asks
/// for a new one.
class TempoSettingsPanel extends ConsumerWidget {
  const TempoSettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(tempoSettingsProvider);
    final notifier = ref.read(tempoSettingsProvider.notifier);

    Widget row(TempoPreset p) => Row(
          children: [
            Expanded(child: Text(p.label)),
            TextButton(
              onPressed: () async {
                final bpm = await showBpmDialog(context,
                    title: '${p.label} tempo',
                    initial: settings.bpmFor(p),
                    settings: settings);
                if (bpm != null) notifier.setBpm(p, bpm);
              },
              child: Text('${settings.bpmFor(p)} BPM'),
            ),
          ],
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Tempo presets', style: Theme.of(context).textTheme.titleSmall),
        row(TempoPreset.slow),
        row(TempoPreset.medium),
        row(TempoPreset.performance),
      ],
    );
  }
}
