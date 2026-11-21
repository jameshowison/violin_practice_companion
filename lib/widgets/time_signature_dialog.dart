import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:musicxml_tools/musicxml_tools.dart';

/// Asks for the time signature the bar at document index [measureIndex]
/// starts, given that it currently starts [current] (null: none, it carries
/// on in the meter before it). Returns null if the user cancelled or kept
/// what was there; otherwise `(meter: …)`, where a null meter means "no
/// change here". The first bar always has a meter.
Future<({Meter? meter})?> showTimeSignatureDialog(
  BuildContext context, {
  required ParsedPiece piece,
  required int measureIndex,
  required Meter? current,
}) async {
  final result = await showDialog<({Meter? meter})>(
    context: context,
    builder: (_) => TimeSignatureDialog(
        piece: piece, measureIndex: measureIndex, current: current),
  );
  if (result == null || result.meter == current) return null;
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
///
/// It works on one stretch of a piece that changes meter: the bars from
/// [measureIndex] to the next change, which are the only ones its choice
/// moves.
class TimeSignatureDialog extends StatefulWidget {
  const TimeSignatureDialog({
    super.key,
    required this.piece,
    this.measureIndex = 0,
    this.current,
  });

  final ParsedPiece piece;

  /// Document index of the bar being edited.
  final int measureIndex;

  /// The meter this bar starts now, or null if it starts none.
  final Meter? current;

  @override
  State<TimeSignatureDialog> createState() => _TimeSignatureDialogState();
}

class _TimeSignatureDialogState extends State<TimeSignatureDialog> {
  bool get _isFirst => widget.measureIndex <= 0;

  /// The meter before this bar: what "No change" leaves it in.
  late final Meter _before = _isFirst
      ? widget.piece.openingMeter
      : widget.piece.meterAt(widget.measureIndex - 1);

  /// False when "No change" is chosen (never on the first bar).
  late bool _changes = _isFirst || widget.current != null;
  late int _beats = (widget.current ?? _before).beats;
  late int _beatType = (widget.current ?? _before).beatType;

  Meter? get _choice => _changes ? Meter(_beats, _beatType) : null;

  /// Bar numbers in the stretch this choice sets, and how many of them would
  /// not add up under it.
  ({List<int> bars, int misfits}) _fit() {
    final trial =
        widget.piece.copyWithTimeChangeAt(widget.measureIndex, _choice);
    final flagged = trial.flaggedMeasureNumbers;
    final bars = [
      for (final i in trial.meterSpanFrom(widget.measureIndex))
        trial.measures[i].number,
    ];
    return (bars: bars, misfits: bars.where(flagged.contains).length);
  }

  void _pick(int beats, int beatType) => setState(() {
        _changes = true;
        _beats = beats;
        _beatType = beatType;
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fit = _fit();
    final total = fit.bars.length;
    final misfits = fit.misfits;
    final fits = misfits == 0;
    final shown = _choice ?? _before;
    final barNumber = widget.piece.measures.isEmpty
        ? 1
        : widget.piece.measures[widget.measureIndex].number;
    final range = total <= 1
        ? 'Bar $barNumber'
        : 'Bars ${fit.bars.first}–${fit.bars.last}';

    return AlertDialog(
      title: Text(_isFirst ? 'Time signature' : 'Time signature from bar $barNumber'),
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
                if (!_isFirst)
                  ChoiceChip(
                    key: const ValueKey('time_sig_no_change'),
                    label: Text('No change ($_before)'),
                    selected: !_changes,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _changes = false),
                  ),
                for (final (beats, beatType) in _presets)
                  ChoiceChip(
                    key: ValueKey('time_sig_preset_${beats}_$beatType'),
                    label: Text('$beats/$beatType'),
                    selected:
                        _changes && _beats == beats && _beatType == beatType,
                    // The tick would push each chip wide enough to wrap the row
                    // onto three lines on a phone; the fill is signal enough.
                    showCheckmark: false,
                    onSelected: (_) => _pick(beats, beatType),
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
                  onChanged: (v) => _pick(v, _beatType),
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
                  onChanged: (v) => _pick(_beats, v),
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
                        ? total <= 1
                            ? '$range adds up to $shown.'
                            : '$range: every bar adds up to $shown.'
                        : '$range: $misfits of $total '
                            '${total == 1 ? 'bar does' : 'bars do'} not add up '
                            'to $shown.',
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
          onPressed: () => Navigator.of(context).pop((meter: _choice)),
          child: const Text('OK'),
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
