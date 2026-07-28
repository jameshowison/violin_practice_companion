import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chord_shape.dart';
import '../services/chord_analysis.dart';
import '../services/chord_shape_library.dart';
import '../services/providers.dart';
import 'chord_diagram.dart';

/// The "New chords" footer: a diagram per distinct chord in the piece, in order
/// of first appearance — echoing the beginner-mandolin ebook's footer block.
///
/// Renders nothing when chord display is off, no chords are present, or none of
/// the piece's chords have a known shape (see [ChordShapeLibrary]).
class NewChordsBlock extends ConsumerWidget {
  const NewChordsBlock({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(showChordsProvider)) return const SizedBox.shrink();
    final parsed = ref.watch(parsedPieceProvider).valueOrNull;
    if (parsed == null) return const SizedBox.shrink();

    // Distinct chord names, first-appearance order.
    final seen = <String>{};
    final names = <String>[];
    for (final m in parsed.measures) {
      for (final n in m.notes) {
        final c = n.chordSymbol;
        if (c != null && seen.add(c)) names.add(c);
      }
    }
    final shapes = <ChordShape>[
      for (final name in names) ?ChordShapeLibrary.lookup(name),
    ];
    if (shapes.isEmpty) return const SizedBox.shrink();

    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        border: Border(
            top: BorderSide(color: onSurface.withValues(alpha: 0.12))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('New chords',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: onSurface.withValues(alpha: 0.7))),
          const SizedBox(height: 8),
          Wrap(
            spacing: 20,
            runSpacing: 12,
            children: [
              for (final s in shapes)
                ChordDiagram(
                  s,
                  degree: ChordAnalysis.romanNumeral(
                    keyFifths: parsed.keyFifths,
                    keyMode: parsed.keyMode,
                    chordName: s.name,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
