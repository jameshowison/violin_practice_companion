import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../build_info.dart';
import '../models/collection_palette.dart';
import '../models/piece_library.dart';
import '../models/piece_library_view.dart';
import '../services/providers.dart';
import '../widgets/collection_filter_bar.dart';
import 'abc_import_screen.dart';
import 'manage_pieces_screen.dart';
import 'piece_detail_screen.dart';
import 'scan_screen.dart';

/// The everyday list — what the child opens the app to.
///
/// Read-only apart from the collection filter: renaming, hiding, deleting and
/// reordering all live behind the Manage button, so the surface a kid taps to
/// pick a piece can't accidentally lose one.
class PieceListScreen extends ConsumerWidget {
  const PieceListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collections = ref.watch(collectionsProvider);
    final active =
        resolveActiveCollection(ref.watch(activeCollectionProvider), collections);
    final piecesAsync = ref.watch(visiblePiecesProvider);
    final hiddenCount = ref.watch(hiddenPieceCountProvider);
    final library = ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty;
    final colors = CollectionPalette.colorsFor(collections);

    return Scaffold(
      appBar: AppBar(
        // The build stamp rides on the FIRST screen, not just the piece detail
        // one, so "is my change actually running?" can be answered before
        // navigating anywhere. See CLAUDE.md "Verify the build is live".
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Violin Practice Companion'),
            if (kDebugMode)
              Text(kBuildRef,
                  style: TextStyle(
                      fontSize: 9,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.45))),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            key: const ValueKey('manage_pieces_button'),
            icon: const Icon(Icons.edit_note),
            tooltip: 'Manage pieces',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                  builder: (_) => const ManagePiecesScreen()),
            ),
          ),
        ],
      ),
      body: piecesAsync.when(
        data: (pieces) => Column(
          children: [
            // Omitted entirely until a collection exists — which is the
            // day-one state, and the reason this is a body band rather than
            // AppBar.bottom (that would need a PreferredSize height fixed
            // before the library resolved, and jump when it did).
            if (collections.isNotEmpty) ...[
              CollectionFilterBar(
                collections: collections,
                colors: colors,
                activeId: active,
                keyPrefix: 'collection_chip',
                onSelect: (id) =>
                    ref.read(activeCollectionProvider.notifier).state = id,
              ),
              const Divider(height: 1),
            ],
            Expanded(
              child: pieces.isEmpty
                  ? _EmptyState(
                      state: libraryEmptyState(
                        hasAnyPieces:
                            (ref.watch(piecesProvider).valueOrNull ?? const [])
                                .isNotEmpty,
                        collectionName: active == null
                            ? null
                            : library.collectionById(active)?.name,
                        hiddenCount: hiddenCount,
                      ),
                    )
                  : ListView.builder(
                      itemCount: pieces.length + (hiddenCount > 0 ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == pieces.length) {
                          return _HiddenFooter(count: hiddenCount);
                        }
                        final piece = pieces[index];
                        return ListTile(
                          key: ValueKey('piece_row_${piece.id}'),
                          title: Text(piece.title),
                          subtitle: Text(
                            pieceSubtitle(
                              piece,
                              [
                                for (final c in collections)
                                  if (c.pieceIds.contains(piece.id)) c.name
                              ],
                              includeCollections: active == null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            ref.read(selectedPieceProvider.notifier).state =
                                piece;
                            ref.read(measureSelectionProvider.notifier).state =
                                null;
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const PieceDetailScreen(),
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),
            // The footer is a list item when there IS a list, but an empty
            // filtered list would otherwise be a dead end: "all 10 pieces in
            // OMR demos are hidden" with no way through to change that. So it
            // also renders below the empty state.
            if (pieces.isEmpty && hiddenCount > 0)
              _HiddenFooter(count: hiddenCount),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error loading pieces: $e')),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            key: const ValueKey('scan_page_fab'),
            heroTag: 'scan_page_fab',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ScanScreen()),
              );
            },
            icon: const Icon(Icons.document_scanner),
            label: const Text('Scan a page'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            key: const ValueKey('import_abc_fab'),
            heroTag: 'import_abc_fab',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AbcImportScreen()),
              );
            },
            icon: const Icon(Icons.library_music),
            label: const Text('Import from ABC'),
          ),
        ],
      ),
    );
  }
}

/// The hidden-piece affordance: a footnote saying how many pieces are hidden,
/// and a way through to the screen that can change that.
///
/// A signpost, NOT a toggle. It used to flip a session-sticky "show hidden"
/// flag, and that was a trap — left on (easily, since the only indication was
/// this footer at the bottom of a long list) hiding silently stopped applying on
/// the child's screen, which is the whole point of hiding. Hidden pieces are
/// always visible and editable on Manage, so this list needs no mode of its own.
///
/// Deliberately a list footer rather than a chip: it costs no horizontal budget,
/// so it can't scroll out of reach on a phone, and it reads as a footnote rather
/// than a control competing with the collections.
class _HiddenFooter extends StatelessWidget {
  const _HiddenFooter({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      key: const ValueKey('show_hidden_footer'),
      dense: true,
      leading:
          Icon(Icons.visibility_off_outlined, size: 20, color: theme.hintColor),
      title: Text(
        '$count hidden ${count == 1 ? 'piece' : 'pieces'} — manage to show '
        '${count == 1 ? 'it' : 'them'}',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ManagePiecesScreen()),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.state});

  final LibraryEmptyState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_note, size: 48, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(
              state.message,
              textAlign: TextAlign.center,
              style:
                  theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
            ),
            if (state.offerManage) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                key: const ValueKey('empty_state_manage_button'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const ManagePiecesScreen()),
                ),
                icon: const Icon(Icons.edit_note),
                label: const Text('Manage pieces'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
