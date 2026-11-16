import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/collection_palette.dart';
import '../models/piece.dart';
import '../models/piece_library.dart';
import '../services/abc_exporter.dart';
import '../services/piece_list_providers.dart';
import '../services/providers.dart';
import 'abc_export_dialog.dart';
import 'checkbox_picker_dialog.dart';
import 'library_dialogs.dart';

/// Every edit to a piece or a keyword, wherever it is started from: the piece
/// list's press-and-hold menu, its swipe actions and Select toolbar, the
/// filter panel, and the piece screen's drawer. These used to live on the
/// Manage screen, and the bodies are lifted from it.
///
/// Every action writes through at once, as Manage did (a library edit has no
/// coherent commit boundary). Failures show the house error dialog.
///
/// Built per use from a live [context] and [ref]; the [context] must outlive
/// the dialogs it opens, so build it from the screen, not from a menu or a
/// sheet that closes first.
class PieceActions {
  PieceActions(this.context, this.ref);

  final BuildContext context;
  final WidgetRef ref;

  PieceLibraryNotifier get _library => ref.read(libraryProvider.notifier);

  /// Whether [piece] ships with the app (hidden, never deleted). Asked while
  /// building menus, so it must not throw: before the catalog has loaded the
  /// answer is "bundled", which offers the reversible Hide rather than Delete.
  bool isBundled(Piece piece) {
    try {
      return ref.read(pieceRepositoryProvider).isBundled(piece.id);
    } on StateError {
      return true;
    }
  }

  Future<bool> _run(Future<void> Function() op, {required String failure}) async {
    try {
      await op();
      return true;
    } catch (e) {
      if (context.mounted) {
        await showErrorDialog(context, title: failure, error: e);
      }
      return false;
    }
  }

  void _snack(String message, {String? action, VoidCallback? onAction}) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: undoWindow,
        persist: _persist,
        action: action == null
            ? null
            : SnackBarAction(label: action, onPressed: onAction ?? () {}),
      ));
  }

  /// How long Undo is offered after a delete or a hide.
  static const undoWindow = Duration(seconds: 5);

  /// A snackbar with an action stays up until dismissed by default, which
  /// would leave a delete waiting forever. Let it time out, except for a
  /// screen-reader user, who needs time to reach the Undo button.
  bool get _persist =>
      context.mounted && MediaQuery.accessibleNavigationOf(context);

  static String _name(List<Piece> pieces) => pieces.length == 1
      ? '"${pieces.single.title}"'
      : '${pieces.length} pieces';

  // ── Pieces ────────────────────────────────────────────────────────────────

  /// The keyword checkboxes for one piece, or for several at once.
  ///
  /// With several, a box starts ticked only when every piece has that keyword.
  /// Ticking adds it to all of them; unticking a box that started ticked takes
  /// it off all of them; a keyword only some of them have, left unticked, is
  /// left alone on each.
  Future<void> editKeywords(List<Piece> pieces) async {
    if (pieces.isEmpty) return;
    final collections = ref.read(collectionsProvider);
    final colors = CollectionPalette.colorsFor(collections);
    final tagsOf = {
      for (final p in pieces) p.id: ref.read(pieceCollectionsProvider(p.id))
    };
    final common = tagsOf.values.reduce((a, b) => a.intersection(b));
    final chosen = await showCheckboxPicker(
      context,
      title: 'Keywords',
      subtitle: pieces.length == 1 ? pieces.single.title : '${pieces.length} pieces',
      items: [
        for (final c in collections) (id: c.id, label: c.name, dot: colors[c.id])
      ],
      initiallySelected: common,
      keyPrefix: 'collection_checkbox',
      createLabel: 'New keyword…',
      emptyMessage: 'No keywords yet.',
      onCreate: () async {
        final created = await createKeyword();
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
    final removed = common.difference(chosen);
    await _run(() async {
      for (final p in pieces) {
        final next = {...tagsOf[p.id]!.difference(removed), ...chosen};
        if (next.length == tagsOf[p.id]!.length &&
            next.containsAll(tagsOf[p.id]!)) {
          continue;
        }
        await _library.setTags(p.id, next);
      }
    }, failure: 'Could not update keywords');
  }

  Future<void> rename(Piece piece) async {
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

  /// Hides pieces from the list, with Undo. Reversible later from the hidden
  /// pieces sheet, so no confirmation.
  Future<void> hide(List<Piece> pieces) async {
    if (pieces.isEmpty) return;
    final ok = await _run(() async {
      for (final p in pieces) {
        await _library.setHidden(p.id, true);
      }
    }, failure: 'Could not hide ${_name(pieces)}');
    if (!ok) return;
    _snack('${_name(pieces)} hidden from the list.', action: 'Undo',
        onAction: () {
      for (final p in pieces) {
        _library.setHidden(p.id, false);
      }
    });
  }

  Future<void> show(Piece piece) => _run(
      () => _library.setHidden(piece.id, false),
      failure: 'Could not show "${piece.title}"');

  /// Built-in pieces are hidden; the user's own are deleted. Returns whether
  /// anything happened (the user may cancel the delete).
  Future<bool> hideOrDelete(Piece piece) async {
    if (isBundled(piece)) {
      await hide([piece]);
      return true;
    }
    return delete([piece]);
  }

  /// Confirms, then deletes with an Undo snackbar. Returns once confirmed
  /// (true) or cancelled (false), without waiting for the snackbar.
  ///
  /// The pieces leave the list at once ([pendingDeletesProvider]); the files
  /// go when the snackbar closes any way other than Undo. Bundled pieces are
  /// never passed here — they can only be hidden.
  Future<bool> delete(List<Piece> pieces) async {
    if (pieces.isEmpty) return false;
    final one = pieces.length == 1;
    final confirmed = await confirmDestructive(
      context,
      title: 'Delete ${_name(pieces)}?',
      body: one
          ? 'The score and its section markers are removed from this device.'
          : 'Their scores and section markers are removed from this device.',
    );
    if (!confirmed || !context.mounted) return false;

    final ids = {for (final p in pieces) p.id};
    final pending = ref.read(pendingDeletesProvider.notifier);
    pending.state = {...pending.state, ...ids};
    // Not awaited: callers get on with closing a sheet or popping a screen
    // while the snackbar runs its course.
    unawaited(_deleteAfterUndoWindow(pieces, ids));
    return true;
  }

  Future<void> _deleteAfterUndoWindow(List<Piece> pieces, Set<String> ids) async {
    // Read now: the snackbar outlives this context if the user navigates.
    final pending = ref.read(pendingDeletesProvider.notifier);
    final actions = ref.read(libraryActionsProvider);
    final messenger = ScaffoldMessenger.of(context);
    final persist = _persist;
    messenger.hideCurrentSnackBar();
    final reason = await messenger
        .showSnackBar(SnackBar(
          content: Text('Deleted ${_name(pieces)}.'),
          duration: undoWindow,
          persist: persist,
          action: SnackBarAction(label: 'Undo', onPressed: () {}),
        ))
        .closed;
    if (reason == SnackBarClosedReason.action) {
      pending.state = pending.state.difference(ids);
      return;
    }
    Object? error;
    for (final id in ids) {
      try {
        await actions.deletePiece(id);
      } catch (e) {
        error ??= e;
      }
    }
    pending.state = pending.state.difference(ids);
    if (error != null && context.mounted) {
      await showErrorDialog(context,
          title: 'Could not delete ${_name(pieces)}', error: error);
    }
  }

  /// Renders the piece as ABC and shows it for copying.
  ///
  /// The MusicXML is loaded and parsed here rather than read from
  /// [parsedPieceProvider], which is keyed to the *selected* piece and layers
  /// jianpu numbers and fingerings that export has no use for.
  Future<void> exportAbc(Piece piece) async {
    String? abc;
    await _run(() async {
      final xml = await ref.read(pieceRepositoryProvider).loadMusicXml(piece);
      abc = AbcExporter.export(
        ref.read(musicXmlParserProvider).parse(xml),
        title: piece.title,
      );
    }, failure: 'Could not export "${piece.title}"');
    final text = abc;
    if (text == null || !context.mounted) return;
    await showAbcExportDialog(context, title: piece.title, abc: text);
  }

  // ── Keywords and books ────────────────────────────────────────────────────

  Future<Collection?> createKeyword() async {
    final name = await showTextEntryDialog(
      context,
      title: 'New keyword',
      label: 'Name',
      saveLabel: 'Create',
    );
    if (name == null) return null;
    await _run(() => _library.createCollection(name),
        failure: 'Could not create keyword');
    final collections = ref.read(collectionsProvider);
    return collections.isEmpty ? null : collections.last;
  }

  Future<void> renameKeyword(Collection collection) async {
    final name = await showTextEntryDialog(
      context,
      title: collection.ordered ? 'Rename book' : 'Rename keyword',
      label: 'Name',
      initial: collection.name,
    );
    if (name == null) return;
    await _run(() => _library.renameCollection(collection.id, name),
        failure: 'Could not rename "${collection.name}"');
  }

  /// A book is numbered and keeps a hand-set order; a keyword sorts A–Z.
  Future<void> setBook(Collection collection, bool book) => _run(
      () => _library.setOrdered(collection.id, book),
      failure: 'Could not update "${collection.name}"');

  Future<bool> deleteKeyword(Collection collection) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Delete "${collection.name}"?',
      // Spelled out because Delete also means "erase a piece" — the two must
      // not be confusable.
      body: 'The "${collection.name}" label is removed from every piece. The '
          'pieces themselves stay in your library. This cannot be undone.',
    );
    if (!confirmed) return false;
    return _run(() => _library.deleteCollection(collection.id),
        failure: 'Could not delete "${collection.name}"');
  }

  /// The transpose of [editKeywords]: pick many pieces for one keyword.
  Future<void> addPiecesTo(Collection collection) async {
    final lib = ref.read(libraryProvider).valueOrNull ?? PieceLibrary.empty;
    final all = applyLibrary(
        lib, ref.read(piecesProvider).valueOrNull ?? const <Piece>[],
        showHidden: true);
    final chosen = await showCheckboxPicker(
      context,
      title: 'Pieces in "${collection.name}"',
      items: [for (final p in all) (id: p.id, label: p.title, dot: null)],
      initiallySelected: collection.pieceIds.toSet(),
      keyPrefix: 'add_pieces',
      emptyMessage: 'No pieces yet.',
    );
    if (chosen == null) return;
    await _run(() async {
      for (final p in all) {
        final tags = ref.read(pieceCollectionsProvider(p.id));
        final shouldHave = chosen.contains(p.id);
        if (tags.contains(collection.id) == shouldHave) continue;
        await _library.setTags(
          p.id,
          shouldHave ? {...tags, collection.id} : ({...tags}..remove(collection.id)),
        );
      }
    }, failure: 'Could not update "${collection.name}"');
  }
}

/// The piece screen drawer's "This piece" group: every edit the piece list
/// offers by press and hold, here in plain sight (a hidden gesture must never
/// be the only way to do something).
///
/// [host] is the piece screen's own context: each tile closes the drawer
/// first, and the dialogs it then opens need a context that outlives it.
/// After Hide or Delete the piece screen pops back to the list, where the
/// snackbar offers Undo.
class PieceEditTiles extends ConsumerWidget {
  const PieceEditTiles({super.key, required this.host, required this.piece});

  final BuildContext host;
  final Piece piece;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = PieceActions(host, ref);
    final bundled = actions.isBundled(piece);
    final error = Theme.of(context).colorScheme.error;
    void run(void Function() act) {
      Navigator.of(host).pop(); // the drawer
      act();
    }

    Widget tile(String key, IconData icon, String label, VoidCallback onTap,
            {Color? color}) =>
        ListTile(
          key: ValueKey(key),
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(icon, color: color),
          title: Text(label, style: color == null ? null : TextStyle(color: color)),
          onTap: onTap,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tile('piece_edit_rename', Icons.edit_outlined, 'Rename…',
            () => run(() => actions.rename(piece))),
        tile('piece_edit_keywords', Icons.sell_outlined, 'Keywords…',
            () => run(() => actions.editKeywords([piece]))),
        tile('piece_edit_abc', Icons.code, 'Export as ABC…',
            () => run(() => actions.exportAbc(piece))),
        if (bundled)
          tile('piece_edit_hide', Icons.visibility_off_outlined,
              'Hide from list', () => run(() async {
                    final nav = Navigator.of(host);
                    await actions.hide([piece]);
                    nav.maybePop();
                  }),
              color: error)
        else
          tile('piece_edit_delete', Icons.delete_outline, 'Delete…',
              () => run(() async {
                    final nav = Navigator.of(host);
                    if (await actions.delete([piece])) nav.maybePop();
                  }),
              color: error),
      ],
    );
  }
}
