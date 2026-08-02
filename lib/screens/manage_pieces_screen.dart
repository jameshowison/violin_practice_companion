import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/collection_palette.dart';
import '../models/piece.dart';
import '../models/piece_library.dart';
import '../models/piece_library_view.dart';
import '../services/abc_exporter.dart';
import '../services/providers.dart';
import '../widgets/abc_export_dialog.dart';
import '../widgets/checkbox_picker_dialog.dart';
import '../widgets/collection_filter_bar.dart';
import '../widgets/library_dialogs.dart';
import '../widgets/manage_piece_row.dart';

/// The parent's curation surface: file pieces into collections, rename bad OCR
/// titles, hide the bundled demos, delete bad scans, and hand-order a
/// collection.
///
/// ## Immediate-commit, not Cancel/Save
///
/// The shell matches [EditMeasureScreen] — full-screen route, `Divider(height:
/// 1)` bands, the same 20×20 in-flight indicator in the AppBar — but it
/// deliberately does NOT copy its buffer-then-commit model. A library edit has
/// no coherent commit boundary (what would Cancel mean after deleting three
/// pieces and reordering a fourth?), and a half-applied buffer lost to a crash
/// is worse than no buffer at all. So every action writes through, and the
/// leading widget is the ordinary back arrow rather than `Icons.close`.
class ManagePiecesScreen extends ConsumerStatefulWidget {
  const ManagePiecesScreen({super.key});

  @override
  ConsumerState<ManagePiecesScreen> createState() => _ManagePiecesScreenState();
}

class _ManagePiecesScreenState extends ConsumerState<ManagePiecesScreen> {
  bool _busy = false;

  /// The order a drag just produced, held until the provider re-emits it.
  ///
  /// Without this the row snaps back to where it started for the duration of the
  /// write, which reads as "the drag didn't take".
  List<String>? _pendingOrder;

  /// Every mutation goes through here: busy state, one error dialog shape.
  Future<void> _run(Future<void> Function() op, {required String failure}) async {
    setState(() => _busy = true);
    try {
      await op();
    } catch (e) {
      if (mounted) await showErrorDialog(context, title: failure, error: e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  PieceLibraryNotifier get _library => ref.read(libraryProvider.notifier);

  // ── Collection actions ────────────────────────────────────────────────────

  Future<Collection?> _createCollection() async {
    final name = await showTextEntryDialog(
      context,
      title: 'New collection',
      label: 'Name',
      saveLabel: 'Create',
    );
    if (name == null) return null;
    await _run(() => _library.createCollection(name),
        failure: 'Could not create collection');
    final collections = ref.read(collectionsProvider);
    return collections.isEmpty ? null : collections.last;
  }

  Future<void> _renameCollection(Collection collection) async {
    final name = await showTextEntryDialog(
      context,
      title: 'Rename collection',
      label: 'Name',
      initial: collection.name,
    );
    if (name == null) return;
    await _run(() => _library.renameCollection(collection.id, name),
        failure: 'Could not rename collection');
  }

  Future<void> _deleteCollection(Collection collection) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Delete "${collection.name}"?',
      // Spelled out because the button says Delete on a screen where Delete
      // also means "erase a piece" — the two must not be confusable.
      body: 'The "${collection.name}" label is removed from every piece. The '
          'pieces themselves stay in your library. This cannot be undone.',
    );
    if (!confirmed) return;
    await _run(() => _library.deleteCollection(collection.id),
        failure: 'Could not delete collection');
    if (mounted) ref.read(activeCollectionProvider.notifier).state = null;
  }

  /// The transpose of the per-piece tag dialog: pick many pieces for one
  /// collection. Turns "put eight pieces in Suzuki 1" from 24 taps into about
  /// eleven, and reuses the same widget.
  Future<void> _addPiecesTo(Collection collection, List<Piece> allPieces) async {
    final chosen = await showCheckboxPicker(
      context,
      title: 'Pieces in "${collection.name}"',
      items: [
        for (final p in allPieces) (id: p.id, label: p.title, dot: null)
      ],
      initiallySelected: collection.pieceIds.toSet(),
      keyPrefix: 'add_pieces',
      emptyMessage: 'No pieces yet.',
    );
    if (chosen == null) return;
    await _run(() async {
      for (final p in allPieces) {
        final tags = ref.read(pieceCollectionsProvider(p.id));
        final shouldHave = chosen.contains(p.id);
        if (tags.contains(collection.id) == shouldHave) continue;
        await _library.setTags(
          p.id,
          shouldHave ? {...tags, collection.id} : (tags..remove(collection.id)),
        );
      }
    }, failure: 'Could not update collection');
  }

  // ── Piece actions ─────────────────────────────────────────────────────────

  Future<void> _editTags(Piece piece) async {
    final collections = ref.read(collectionsProvider);
    final colors = CollectionPalette.colorsFor(collections);
    final chosen = await showCheckboxPicker(
      context,
      title: 'Collections',
      subtitle: piece.title,
      items: [
        for (final c in collections)
          (id: c.id, label: c.name, dot: colors[c.id])
      ],
      initiallySelected: ref.read(pieceCollectionsProvider(piece.id)),
      keyPrefix: 'collection_checkbox',
      createLabel: 'New collection…',
      emptyMessage: 'No collections yet.',
      onCreate: () async {
        final created = await _createCollection();
        return created == null
            ? null
            : (
                id: created.id,
                label: created.name,
                dot: CollectionPalette.colorsFor(
                    ref.read(collectionsProvider))[created.id]
              );
      },
    );
    if (chosen == null) return;
    await _run(() => _library.setTags(piece.id, chosen),
        failure: 'Could not update collections');
  }

  Future<void> _rename(Piece piece) async {
    final title = await showTextEntryDialog(
      context,
      title: 'Rename piece',
      label: 'Title',
      initial: piece.title,
    );
    if (title == null || title == piece.title) return;
    await _run(() => _library.renamePiece(piece.id, title),
        failure: 'Could not rename piece');
  }

  Future<void> _toggleHidden(LibraryRow row) async {
    final hide = !row.hidden;
    await _run(() => _library.setHidden(row.piece.id, hide),
        failure: 'Could not update piece');
    if (!mounted || !hide) return;
    // Informational only — no SnackBarAction, because there is no undo anywhere
    // in this app and hiding is reversible from the row itself, which stays
    // right where it was and merely dims.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('"${row.piece.title}" hidden from the piece list.'),
    ));
  }

  /// Renders the piece as ABC and shows it for copying.
  ///
  /// The MusicXML is loaded and parsed here rather than read from
  /// [parsedPieceProvider], because that provider is keyed to the *selected*
  /// piece — using it would mean silently changing which piece the detail screen
  /// is showing as a side effect of exporting a different one. Export also has
  /// no use for the jianpu numbers or fingerings that provider layers on.
  Future<void> _exportAbc(Piece piece) async {
    String? abc;
    await _run(() async {
      final xml = await ref.read(pieceRepositoryProvider).loadMusicXml(piece);
      abc = AbcExporter.export(
        ref.read(musicXmlParserProvider).parse(xml),
        title: piece.title,
      );
    }, failure: 'Could not export "${piece.title}"');
    final text = abc;
    if (text == null || !mounted) return;
    // Outside _run so the AppBar spinner stops while the dialog is up.
    await showAbcExportDialog(context, title: piece.title, abc: text);
  }

  Future<void> _delete(Piece piece) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Delete "${piece.title}"?',
      body: 'The score and its section markers are removed from this device. '
          'This cannot be undone.',
    );
    if (!confirmed) return;
    await _run(() => ref.read(libraryActionsProvider).deletePiece(piece.id),
        failure: 'Could not delete piece');
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final collections = ref.watch(collectionsProvider);
    final active =
        resolveActiveCollection(ref.watch(activeCollectionProvider), collections);
    final activeCollection =
        active == null ? null : collections.firstWhere((c) => c.id == active);
    final library = ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty;
    final repo = ref.watch(pieceRepositoryProvider);
    final allAsync = ref.watch(libraryPiecesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Pieces'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final labeled = manageRowUsesLabeledActions(constraints.maxWidth);
            return allAsync.when(
              data: (all) {
                final visible =
                    _orderedRows(library, all, active, (id) => repo.isBundled(id));
                return Column(
                  children: [
                    CollectionFilterBar(
                      collections: collections,
                      colors: CollectionPalette.colorsFor(collections),
                      activeId: active,
                      keyPrefix: 'manage_collection_chip',
                      onSelect: (id) {
                        _pendingOrder = null;
                        ref.read(activeCollectionProvider.notifier).state = id;
                      },
                      onCreate: _createCollection,
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: activeCollection == null
                          ? _unorderedList(visible, labeled)
                          : _reorderableList(
                              visible, labeled, activeCollection.id),
                    ),
                    if (activeCollection != null) ...[
                      const Divider(height: 1),
                      _collectionActions(activeCollection, all),
                    ],
                  ],
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, st) => Center(child: Text('Error: $e')),
            );
          },
        ),
      ),
    );
  }

  /// The rows to show, with any pending optimistic drag applied.
  ///
  /// Hidden pieces are ALWAYS included here — dimmed, with their row button
  /// reading "Show in list". This screen exists to change hide state, so
  /// filtering hidden rows out of it is self-defeating: hiding a piece would
  /// make it vanish from the one screen that can bring it back. The everyday
  /// list is where hidden means hidden; this is the curation surface behind it.
  List<LibraryRow> _orderedRows(
    PieceLibrary library,
    List<Piece> all,
    String? activeId,
    bool Function(String) isBundled,
  ) {
    final pieces = activeId == null
        ? all
        : applyLibrary(library, all, collectionId: activeId, showHidden: true);

    final pending = _pendingOrder;
    if (pending != null && pending.length == pieces.length) {
      final byId = {for (final p in pieces) p.id: p};
      if (pending.every(byId.containsKey)) {
        return libraryRows(library, [for (final id in pending) byId[id]!],
            isBundled);
      }
      // The provider caught up (or the set changed): drop the optimism.
      _pendingOrder = null;
    }
    return libraryRows(library, pieces, isBundled);
  }

  Widget _row(LibraryRow row, bool labeled, int index, bool draggable) =>
      ManagePieceRow(
        key: ValueKey('manage_row_${row.piece.id}'),
        row: row,
        subtitle: pieceSubtitle(row.piece, row.collectionNames,
            includeCollections: true),
        index: index,
        showDragHandle: draggable,
        labeledActions: labeled,
        onTags: () => _editTags(row.piece),
        onRename: () => _rename(row.piece),
        onExportAbc: () => _exportAbc(row.piece),
        onHideOrDelete: () =>
            row.isBundled ? _toggleHidden(row) : _delete(row.piece),
      );

  Widget _unorderedList(List<LibraryRow> rows, bool labeled) =>
      ListView.builder(
        itemCount: rows.length + 1,
        itemBuilder: (context, index) {
          if (index == rows.length) return const _ReorderHint();
          return _row(rows[index], labeled, index, false);
        },
      );

  Widget _reorderableList(
          List<LibraryRow> rows, bool labeled, String collectionId) =>
      ReorderableListView.builder(
        // Handles only, via ReorderableDragStartListener in ManagePieceRow.
        // The default long-press-anywhere gesture would fight the three trailing
        // buttons and give no sign that reordering exists.
        buildDefaultDragHandles: false,
        itemCount: rows.length,
        itemBuilder: (context, index) => _row(rows[index], labeled, index, true),
        // onReorderItem, not the deprecated onReorder: it reports the FINAL
        // destination index, so the old off-by-one adjustment stays the SDK's
        // business rather than being duplicated in `reorderedIds`.
        onReorderItem: (oldIndex, newIndex) {
          final ids = [for (final r in rows) r.piece.id];
          setState(() => _pendingOrder = reorderedIds(ids, oldIndex, newIndex));
          _run(
            () => _library.reorderInCollection(
                collectionId, ids, oldIndex, newIndex),
            failure: 'Could not save the new order',
          );
        },
      );

  Widget _collectionActions(Collection collection, List<Piece> all) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton.icon(
              key: const ValueKey('manage_add_pieces_button'),
              onPressed: () => _addPiecesTo(collection, all),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add pieces'),
            ),
            TextButton.icon(
              key: const ValueKey('manage_collection_rename_button'),
              onPressed: () => _renameCollection(collection),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Rename'),
            ),
            TextButton.icon(
              key: const ValueKey('manage_collection_delete_button'),
              onPressed: () => _deleteCollection(collection),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete'),
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error),
            ),
          ],
        ),
      );
}

/// Why there are no drag handles in the "All" view.
///
/// The handles are absent rather than greyed out — a disabled handle invites a
/// tap that does nothing — so the reason has to be said somewhere.
class _ReorderHint extends StatelessWidget {
  const _ReorderHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      key: const ValueKey('reorder_hint_footer'),
      dense: true,
      leading: Icon(Icons.info_outline, size: 18, color: theme.hintColor),
      title: Text(
        'Sorted automatically. Pick a collection to arrange its own order.',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
      ),
    );
  }
}
