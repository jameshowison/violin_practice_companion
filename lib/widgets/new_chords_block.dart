import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/chord_analysis.dart';
import '../services/providers.dart';
import 'chord_diagram.dart';

/// The "New chords" footer: a diagram per distinct chord in the piece, in order
/// of first appearance — echoing the beginner-mandolin ebook's footer block.
///
/// Renders nothing when chord display is off, or when none of the piece's
/// chords have a known shape (see [pieceChordShapesProvider], which is also
/// what the phone tray consults to decide whether to offer a drawer at all).
class NewChordsBlock extends ConsumerWidget {
  /// Draws a hairline above the block. Wanted under the score on a tablet,
  /// where this is a footer and the rule separates it from the staff; unwanted
  /// in the phone's tray, where the drag handle is already the boundary and a
  /// second line reads as a stray rule.
  final bool topBorder;

  const NewChordsBlock({super.key, this.topBorder = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(showChordsProvider)) return const SizedBox.shrink();
    final parsed = ref.watch(parsedPieceProvider).valueOrNull;
    if (parsed == null) return const SizedBox.shrink();

    final shapes = ref.watch(pieceChordShapesProvider);
    if (shapes.isEmpty) return const SizedBox.shrink();

    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        border: topBorder
            ? Border(
                top: BorderSide(color: onSurface.withValues(alpha: 0.12)))
            : null,
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
                // The analysis feeds both the label and the swatch, so a
                // diagram's accent is guaranteed to match its bar on the staff.
                switch (ChordAnalysis.analyze(
                  keyFifths: parsed.keyFifths,
                  keyMode: parsed.keyMode,
                  chordName: s.name,
                )) {
                  final a? => ChordDiagram(
                      s,
                      degree: a.roman,
                      degreeIndex: a.degreeIndex,
                      minorQuality: a.minorQuality,
                    ),
                  _ => ChordDiagram(s),
                },
            ],
          ),
        ],
      ),
    );
  }
}
