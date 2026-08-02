import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/parsed_piece.dart';

/// Asks for a new time signature, returning `(beats, beatType)` or null if the
/// user cancelled or picked what the piece already had.
Future<({int beats, int beatType})?> showTimeSignatureDialog(
  BuildContext context, {
  required ParsedPiece piece,
}) async {
  final result = await showDialog<({int beats, int beatType})>(
    context: context,
    builder: (_) => TimeSignatureDialog(piece: piece),
  );
  if (result == null) return null;
  if (result.beats == piece.beatsPerMeasure &&
      result.beatType == piece.beatType) {
    return null;
  }
  return result;
}

/// The meters worth one tap. Everything else is reachable from the two
/// dropdowns underneath — these are just the ones a violin student's music is
/// actually in.
const _presets = <(int, int)>[
  (4, 4),
  (3, 4),
  (2, 4),
  (2, 2),
  (6, 8),
  (9, 8),
  (12, 8),
];

/// Picks a piece's time signature, with a live count of how many bars would
/// still fail to add up under it.
///
/// ## Why the bar-fit count is the main event
///
/// A parent looking at a scanned tune has no way to know whether it is in 2/4 or
/// 2/2 — that is exactly the kind of thing OMR gets wrong and a non-musician
/// can't check by eye. But the score itself knows: under the right meter the
/// bars add up, and under the wrong one they don't. So the dialog does the
/// arithmetic for every candidate and says so in words, turning a music-theory
/// question into a "pick the one that says all bars add up" question.
///
/// It reuses [ParsedPiece.flaggedMeasureNumbers] rather than counting bars
/// itself, so the number here is exactly the number of warnings the measure
/// editor will show afterwards — including its allowances for a pickup bar and
/// for a short bar that pairs with one across a repeat.
class TimeSignatureDialog extends StatefulWidget {
  const TimeSignatureDialog({super.key, required this.piece});

  final ParsedPiece piece;

  @override
  State<TimeSignatureDialog> createState() => _TimeSignatureDialogState();
}

class _TimeSignatureDialogState extends State<TimeSignatureDialog> {
  late int _beats = widget.piece.beatsPerMeasure;
  late int _beatType = widget.piece.beatType;

  /// Bars that don't add up under [beats]/[beatType].
  int _misfits(int beats, int beatType) => widget.piece
      .copyWithTime(beatsPerMeasure: beats, beatType: beatType)
      .flaggedMeasureNumbers
      .length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = widget.piece.measures.length;
    final misfits = _misfits(_beats, _beatType);
    final fits = misfits == 0;

    return AlertDialog(
      title: const Text('Time signature'),
      content: SizedBox(
        // Wide enough for the preset row in two lines, but never wider than the
        // viewport — on a phone the chips wrap instead.
        width: math.min(360, MediaQuery.sizeOf(context).width * 0.9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (beats, beatType) in _presets)
                  ChoiceChip(
                    key: ValueKey('time_sig_preset_${beats}_$beatType'),
                    label: Text('$beats/$beatType'),
                    selected: _beats == beats && _beatType == beatType,
                    // The tick would push each chip wide enough to wrap the row
                    // onto three lines on a phone; the fill is signal enough.
                    showCheckmark: false,
                    onSelected: (_) => setState(() {
                      _beats = beats;
                      _beatType = beatType;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _NumberPicker(
                  key: const ValueKey('time_sig_beats_dropdown'),
                  label: 'Beats',
                  value: _beats,
                  options: const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
                  onChanged: (v) => setState(() => _beats = v),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('/', style: TextStyle(fontSize: 20)),
                ),
                _NumberPicker(
                  key: const ValueKey('time_sig_beat_type_dropdown'),
                  label: 'Beat note',
                  value: _beatType,
                  options: const [1, 2, 4, 8, 16],
                  onChanged: (v) => setState(() => _beatType = v),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              key: const ValueKey('time_sig_fit_summary'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  fits ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                  size: 18,
                  color: fits ? Colors.green.shade700 : theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    fits
                        ? 'Every bar adds up to $_beats/$_beatType.'
                        : '$misfits of $total bars do not add up to '
                            '$_beats/$_beatType.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'This relabels the score. No note values are changed.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('time_sig_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('time_sig_save_button'),
          onPressed: () =>
              Navigator.of(context).pop((beats: _beats, beatType: _beatType)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _NumberPicker extends StatelessWidget {
  const _NumberPicker({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final int value;
  final List<int> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Expanded(
        child: DropdownButtonFormField<int>(
          initialValue: value,
          isDense: true,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          items: [
            for (final o in options)
              DropdownMenuItem(value: o, child: Text('$o')),
          ],
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      );
}
