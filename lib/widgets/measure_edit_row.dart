import 'package:flutter/material.dart';

import '../models/note_event.dart';
import '../models/note_number_mode.dart';
import '../services/chord_editor.dart';
import '../services/fingering_annotation_builder.dart';

/// Horizontal row of large, tappable note cards for the measure being edited.
/// Each card shows the pitch (or "rest"), the duration, and the fingering label
/// if present. Generous ~72×96 cards — touch targets for editing, distinct from
/// the dense playback-tuned cells of the jianpu/fingering views.
///
/// Notes sharing a stem (a chord) are drawn inside one tinted bracket with the
/// gap between them collapsed, so the group reads as a single beat — otherwise
/// a double-stop looks exactly like two sequential notes. Members stay
/// individually tappable, so per-note pitch/accidental editing is unchanged.
class MeasureEditRow extends StatelessWidget {
  final List<NoteEvent> notes;
  final int? selectedIndex;
  final ValueChanged<int> onSelect;

  /// Same switch the piece view's fingering channel and tab staff use — so a
  /// note reads identically here as it does everywhere else, instead of
  /// falling back to the raw violin fingering regardless of mode.
  final NoteNumberMode numberMode;
  final FretStyle fretStyle;

  const MeasureEditRow({
    super.key,
    required this.notes,
    required this.selectedIndex,
    required this.onSelect,
    this.numberMode = NoteNumberMode.violinFingering,
    this.fretStyle = FretStyle.openStrings,
  });

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) {
      return const SizedBox(
        height: 104,
        child: Center(child: Text('No notes — tap + insert to add one')),
      );
    }
    // Centre the cards when they don't fill the width (a short measure), but
    // still scroll horizontally when they overflow (a long one). The
    // ConstrainedBox(minWidth) lets the Row grow to the viewport so
    // MainAxisAlignment.center has room to work.
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final g in ChordEditor.groups(notes))
                Padding(
                  // The same vertical padding on both branches keeps every
                  // child exactly 100 tall, so the row height doesn't jump the
                  // moment a chord is created or broken.
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: g.end - g.start == 1
                      ? _card(g.start)
                      : _chordGroup(cs, g),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(int i, {bool chordMember = false}) => _NoteEditCard(
        key: ValueKey('note_$i'),
        note: notes[i],
        selected: i == selectedIndex,
        chordMember: chordMember,
        numberMode: numberMode,
        fretStyle: fretStyle,
        onTap: () => onSelect(i),
      );

  // A stack drawn as one bracket. Chord chrome uses `tertiary` because
  // `primary` already means "selected" (and labels the fingering) — a selected
  // member must read as a primary border inside a tertiary bracket.
  Widget _chordGroup(ColorScheme cs, ChordRange g) => DecoratedBox(
        key: ValueKey('chord_group_${g.start}'),
        decoration: BoxDecoration(
          color: cs.tertiaryContainer.withValues(alpha: 0.30),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: cs.tertiary.withValues(alpha: 0.55), width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = g.start; i < g.end; i++) ...[
                if (i > g.start) const SizedBox(width: 3),
                _card(i, chordMember: i > g.start),
              ],
            ],
          ),
        ),
      );
}

class _NoteEditCard extends StatelessWidget {
  final NoteEvent note;
  final bool selected;

  /// True for the 2nd+ note of a stack. Only changes the card's look — the
  /// duration is dimmed because it's governed by the primary, not settable here.
  final bool chordMember;
  final NoteNumberMode numberMode;
  final FretStyle fretStyle;
  final VoidCallback onTap;

  const _NoteEditCard({
    super.key,
    required this.note,
    required this.selected,
    required this.onTap,
    required this.numberMode,
    required this.fretStyle,
    this.chordMember = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 96,
        decoration: BoxDecoration(
          color: chordMember
              ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.25)
              : theme.colorScheme.surface,
          border: Border.all(
            // Edit-time selection uses a bold primary border — visually
            // distinct from the amber playback-position convention.
            color: selected ? theme.colorScheme.primary : Colors.grey.shade400,
            width: selected ? 3 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              note.isRest ? 'rest' : _pitchLabel(note.pitch),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: note.isRest ? Colors.grey : theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _durationLabel(note),
              style: TextStyle(
                fontSize: 12,
                color: chordMember ? Colors.black38 : Colors.black54,
                fontStyle: chordMember ? FontStyle.italic : FontStyle.normal,
              ),
            ),
            if (note.fingerString != null && note.fingerNumber != null) ...[
              const SizedBox(height: 2),
              // Resolved through the same mode/style switch as the piece view,
              // so a fret stays a fret here too. In fingering mode this is
              // `note.fingerNumber` verbatim — the L/H suffix is meaningful
              // (see CLAUDE.md) — a fret needs no such suffix.
              Text(
                shownNumber(note, numberMode, fretStyle).number,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Pretty pitch: "F#5" → "F♯5", "Bb3" → "B♭3". (Pitch only — not the
  // fingering label, which must never be transformed.)
  static String _pitchLabel(String pitch) =>
      pitch.replaceAll('#', '♯').replaceAll('b', '♭');

  static String _durationLabel(NoteEvent n) {
    const abbr = {
      NoteValue.whole: 'whole',
      NoteValue.half: 'half',
      NoteValue.quarter: 'quarter',
      NoteValue.eighth: '8th',
      NoteValue.sixteenth: '16th',
    };
    return '${abbr[n.noteValue]}${n.dotted ? '•' : ''}';
  }
}
