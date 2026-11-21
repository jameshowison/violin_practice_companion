import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:musicxml_tools/musicxml_tools.dart';

/// Asks for the key signature the bar at document index [measureIndex]
/// starts, given that it currently starts [current] (null: none, it carries
/// on in the key before it). Returns null if the user cancelled or kept what
/// was there; otherwise `(fifths: …)`, where a null `fifths` means "no change
/// here". The first bar always has a key.
Future<({int? fifths})?> showKeySignatureDialog(
  BuildContext context, {
  required ParsedPiece piece,
  required int measureIndex,
  required int? current,
}) async {
  final result = await showDialog<({int? fifths})>(
    context: context,
    builder: (_) => KeySignatureDialog(
        piece: piece, measureIndex: measureIndex, current: current),
  );
  if (result == null || result.fifths == current) return null;
  return result;
}

/// Every key signature, sharps first: a violin student's music is mostly in
/// them.
const _choices = [0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7];

/// Picks the key signature a bar starts — for a scan that misread it.
///
/// ## Matching, not music theory
///
/// Nobody fixing a scan needs to know what key a tune is in: they need to
/// count the ♯ or ♭ at the start of the printed line and pick the chip that
/// says the same. So the chips are counts (`2♯`), the line under them names
/// the signs (`F♯ C♯`), and the key's name comes last.
///
/// ## What it changes
///
/// MusicXML stores sounding pitch, so the notes a misread key spelt wrong are
/// wrong in the file too, and fixing the key re-spells them
/// ([KeySignature.rekeyBar]). The dialog runs that same rule over the bars
/// this choice governs and says which notes move — "C → C♯ (6)" — so the
/// effect is visible before anything is drafted.
class KeySignatureDialog extends StatefulWidget {
  const KeySignatureDialog({
    super.key,
    required this.piece,
    this.measureIndex = 0,
    this.current,
  });

  final ParsedPiece piece;

  /// Document index of the bar being edited.
  final int measureIndex;

  /// The key this bar starts now, or null if it starts none.
  final int? current;

  @override
  State<KeySignatureDialog> createState() => _KeySignatureDialogState();
}

class _KeySignatureDialogState extends State<KeySignatureDialog> {
  bool get _isFirst => widget.measureIndex <= 0;

  /// The key before this bar: what "No change" leaves it in.
  late final int _before = _isFirst
      ? widget.piece.keyAt(0)
      : widget.piece.keyAt(widget.measureIndex - 1);

  /// The key this bar's notes are spelt in now.
  late final int _now = widget.piece.keyAt(widget.measureIndex);

  /// Null for "No change" (never on the first bar).
  late int? _choice = widget.current ?? (_isFirst ? _now : null);

  /// The bars [_choice] governs, and the re-spellings it makes in them, as
  /// "C → C♯" with a count.
  ({List<int> bars, Map<String, int> moves}) _effect() {
    final p = widget.piece;
    final to = _choice ?? _before;
    final span = p.keySpanFrom(widget.measureIndex).toList();
    final moves = <String, int>{};
    if (to != _now) {
      KeyCarry? carry;
      if (widget.measureIndex > 0) {
        carry = KeySignature.unchangedCarry(p
            .measures[widget.measureIndex - 1].notes
            .map(KeySignature.keyedOf)
            .whereType<KeyedNote>()
            .lastOrNull);
      }
      for (final i in span) {
        final keyed = p.measures[i].notes.map(KeySignature.keyedOf).toList();
        final (alters, last) =
            KeySignature.rekeyBar(keyed, _now, to, carryIn: carry);
        carry = last;
        for (var n = 0; n < keyed.length; n++) {
          final was = keyed[n], a = alters[n];
          if (was == null || a == null || a == was.alter) continue;
          final move = '${_name(was.step, was.alter)} → ${_name(was.step, a)}';
          moves[move] = (moves[move] ?? 0) + 1;
        }
      }
    }
    return (bars: [for (final i in span) p.measures[i].number], moves: moves);
  }

  /// A compact chip: fifteen of the default size wrapped to three rows and
  /// filled a landscape phone's dialog.
  static Widget _chip(Key key, String label,
          {required bool selected, required VoidCallback onSelected}) =>
      ChoiceChip(
        key: key,
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onSelected: (_) => onSelected(),
      );

  static String _name(String step, int alter) =>
      '$step${alter > 0 ? '♯' : alter < 0 ? '♭' : '♮'}';

  static String _keyNames(int fifths) =>
      '${MusicXmlParser.keyName(fifths, KeyMode.major)} major or '
      '${MusicXmlParser.keyName(fifths, KeyMode.minor).replaceAll('m', '')} '
      'minor';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effect = _effect();
    final shown = _choice ?? _before;
    final barNumber = widget.piece.measures.isEmpty
        ? 1
        : widget.piece.measures[widget.measureIndex].number;
    final bars = effect.bars;
    final range = bars.length <= 1
        ? 'Bar $barNumber'
        : 'Bars ${bars.first}–${bars.last}';
    final moved = effect.moves.values.fold(0, (a, b) => a + b);
    final signs = KeySignature.signs(shown);

    return AlertDialog(
      title: Text(_isFirst ? 'Key signature' : 'Key signature from bar $barNumber'),
      content: SizedBox(
        width: math.min(360, MediaQuery.sizeOf(context).width * 0.9),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Count the ♯ or ♭ at the start of the line on the printed '
                'page.',
                style: theme.textTheme.bodySmall,
              ),
              // What the choice means and does sits ABOVE the chips: on a
              // phone in landscape the chips fill the dialog, and a summary
              // under them scrolled out of sight.
              const SizedBox(height: 12),
              Text(
                key: const ValueKey('key_sig_description'),
                '${KeySignature.label(shown)}: '
                '${signs.isEmpty ? 'no sharps or flats' : signs} — '
                '${_keyNames(shown)}',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Row(
                key: const ValueKey('key_sig_effect'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.music_note_outlined,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      moved == 0
                          ? '$range: no notes change.'
                          : '$range: $moved ${moved == 1 ? 'note changes' : 'notes change'}'
                              ' — ${effect.moves.entries.map((e) => '${e.key} (${e.value})').join(', ')}.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (!_isFirst)
                    _chip(
                      const ValueKey('key_sig_no_change'),
                      'No change (${KeySignature.label(_before)})',
                      selected: _choice == null,
                      onSelected: () => setState(() => _choice = null),
                    ),
                  for (final f in _choices)
                    _chip(
                      ValueKey('key_sig_$f'),
                      KeySignature.label(f),
                      selected: _choice == f,
                      onSelected: () => setState(() => _choice = f),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Notes with their own ♯, ♭ or ♮ keep it.',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('key_sig_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('key_sig_save_button'),
          onPressed: () => Navigator.of(context).pop((fifths: _choice)),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
