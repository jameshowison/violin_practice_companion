import 'package:flutter/material.dart';

import '../models/note_event.dart';

/// Horizontal row of large, tappable note cards for the measure being edited.
/// Each card shows the pitch (or "rest"), the duration, and the fingering label
/// if present. Generous ~72×96 cards — touch targets for editing, distinct from
/// the dense playback-tuned cells of the jianpu/fingering views.
class MeasureEditRow extends StatelessWidget {
  final List<NoteEvent> notes;
  final int? selectedIndex;
  final ValueChanged<int> onSelect;

  const MeasureEditRow({
    super.key,
    required this.notes,
    required this.selectedIndex,
    required this.onSelect,
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
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < notes.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _NoteEditCard(
                    note: notes[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoteEditCard extends StatelessWidget {
  final NoteEvent note;
  final bool selected;
  final VoidCallback onTap;

  const _NoteEditCard({
    required this.note,
    required this.selected,
    required this.onTap,
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
          color: theme.colorScheme.surface,
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
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            if (note.fingerNumber != null) ...[
              const SizedBox(height: 2),
              // Rendered verbatim — the L/H suffix is meaningful (see CLAUDE.md).
              Text(
                note.fingerNumber!,
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
