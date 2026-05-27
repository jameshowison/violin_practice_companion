import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/providers.dart';
import 'piece_detail_screen.dart';

class PieceListScreen extends ConsumerWidget {
  const PieceListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final piecesAsync = ref.watch(piecesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Violin Practice Companion'),
        centerTitle: true,
      ),
      body: piecesAsync.when(
        data: (pieces) => ListView.builder(
          itemCount: pieces.length,
          itemBuilder: (context, index) {
            final piece = pieces[index];
            return ListTile(
              title: Text(piece.title),
              subtitle: Text('${piece.sections.length} sections'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                ref.read(selectedPieceProvider.notifier).state = piece;
                ref.read(measureSelectionProvider.notifier).state = null;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const PieceDetailScreen(),
                  ),
                );
              },
            );
          },
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error loading pieces: $e')),
      ),
    );
  }
}
