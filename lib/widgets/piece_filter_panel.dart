import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/piece_filter.dart';
import '../models/piece_library.dart';
import 'piece_actions.dart';
import '../services/piece_list_providers.dart';
import '../services/providers.dart';
import '../theme/skin_style.dart';
import '../ui/adaptive/adaptive.dart';

/// The piece list's filters: one panel, two homes.
///
/// On a phone it is the content of a drawer that slides in over most of the
/// screen ([dismissible]: a Done button and a "Show N pieces" footer close
/// it). On a tablet it is a sidebar that is always out, and also holds the
/// Recents / All switch that the phone keeps above its list.
class PieceFilterPanel extends ConsumerWidget {
  const PieceFilterPanel({super.key, required this.dismissible});

  final bool dismissible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final skin = SkinStyle.of(context);
    final filter = ref.watch(pieceFilterProvider);
    final result = ref.watch(pieceListProvider).valueOrNull;
    final library = ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty;
    final metas = ref.watch(allPieceMetaProvider).valueOrNull ?? const {};
    final notifier = ref.read(pieceFilterProvider.notifier);

    void update(PieceFilter Function(PieceFilter) f) {
      appSelectionHaptic();
      notifier.state = f(notifier.state);
    }

    void close() => Navigator.of(context).maybePop();

    final books = [for (final c in library.collections) if (c.ordered) c];
    final tags = [for (final c in library.collections) if (!c.ordered) c];
    final signatures = {for (final m in metas.values) m.keyName: m.signature};
    final keys = signatures.keys.toList()..sort();
    final shown = result?.rows.length ?? 0;

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(dismissible ? 'Filters' : 'Library',
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  if (dismissible)
                    TextButton(
                      key: const ValueKey('filter_done_button'),
                      onPressed: close,
                      child: const Text('Done'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  if (!dismissible)
                    for (final (tab, label, icon) in [
                      (PieceTab.recent, skin.recentsLabel, Icons.schedule),
                      (PieceTab.books, skin.booksLabel, Icons.menu_book_outlined),
                      (PieceTab.all, skin.allLabel, Icons.library_music_outlined),
                    ])
                      _ViewTile(
                        key: ValueKey('filter_view_${tab.name}'),
                        icon: icon,
                        label: label,
                        count: result?.tabCounts[tab],
                        selected: filter.tab == tab,
                        onTap: () => update((f) => f.copyWith(tab: tab)),
                      ),
                  const _SectionHeader('Books and sets'),
                  if (books.isEmpty)
                    const _Hint('Press and hold a keyword and choose "Make it '
                        'a book" to keep its pieces in order.')
                  else
                    _Group(children: [
                      for (final b in books)
                        _CollectionMenu(
                          collection: b,
                          preview: _surfacePreview,
                          child: _OptionTile(
                            key: ValueKey('filter_book_${b.id}'),
                            leading: Icons.format_list_numbered,
                            label: b.name,
                            count: result?.bookCounts[b.id],
                            selected: filter.bookId == b.id,
                            onTap: () => update((f) => f.toggleBook(b.id)),
                          ),
                        ),
                    ]),
                  const _SectionHeader('Keywords'),
                  if (tags.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: _Hint('No keywords yet. Press and hold a piece '
                          'to give it one, or make one here.'),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final t in tags)
                        _CollectionMenu(
                          collection: t,
                          preview: _chipPreview,
                          child: FilterChip(
                            key: ValueKey('filter_tag_${t.id}'),
                            label: Text(_countLabel(t.name, result?.tagCounts[t.id])),
                            selected: filter.tagIds.contains(t.id),
                            onSelected: (_) => update((f) => f.toggleTag(t.id)),
                          ),
                        ),
                      ActionChip(
                        key: const ValueKey('filter_new_keyword_chip'),
                        avatar: const Icon(Icons.add, size: 18),
                        label: const Text('New'),
                        tooltip: 'New keyword',
                        onPressed: () => PieceActions(context, ref).createKeyword(),
                      ),
                    ],
                  ),
                  const _SectionHeader('Key'),
                  if (keys.isEmpty)
                    const _Hint('Reading keys…')
                  else
                    _Group(children: [
                      for (final k in keys)
                        _OptionTile(
                          key: ValueKey('filter_key_$k'),
                          label: k,
                          detail: signatures[k],
                          count: result?.keyCounts[k],
                          selected: filter.keyName == k,
                          onTap: () => update((f) => f.toggleKey(k)),
                        ),
                    ]),
                  const _SectionHeader('Media'),
                  _Group(children: [
                    SwitchListTile.adaptive(
                      key: const ValueKey('filter_recording_switch'),
                      title: const Text('Has a recording'),
                      value: filter.hasRecording,
                      onChanged: (v) =>
                          update((f) => f.copyWith(hasRecording: v)),
                    ),
                  ]),
                ],
              ),
            ),
            if (dismissible)
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                      top: BorderSide(color: theme.colorScheme.outlineVariant)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
                  child: Row(
                    children: [
                      TextButton(
                        key: const ValueKey('filter_clear_button'),
                        onPressed: filter.activeCount == 0
                            ? null
                            : () => update((f) => f.cleared()),
                        child: const Text('Clear all'),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          key: const ValueKey('filter_show_button'),
                          onPressed: close,
                          child: Text(
                              'Show $shown ${shown == 1 ? 'piece' : 'pieces'}'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _countLabel(String name, int? count) =>
    count == null ? name : '$name  $count';

/// A lifted book row needs the white of its group behind it.
Widget _surfacePreview(BuildContext context, Widget child) => Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(SkinStyle.of(context).groupRadius),
      clipBehavior: Clip.antiAlias,
      child: child,
    );

/// A lifted chip draws itself; it only needs a Material to draw in.
Widget _chipPreview(BuildContext context, Widget child) =>
    Material(type: MaterialType.transparency, child: child);

enum _CollectionAction { rename, book, keyword, addPieces, delete }

/// Press and hold on a keyword chip or a book row: rename it, turn a keyword
/// into a book or back, add pieces to it, or delete it. These were the
/// retired Manage screen's keyword controls.
class _CollectionMenu extends ConsumerWidget {
  const _CollectionMenu({
    required this.collection,
    required this.child,
    this.preview,
  });

  final Collection collection;
  final Widget child;
  final Widget Function(BuildContext, Widget)? preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = collection;
    return AppContextMenu<_CollectionAction>(
      key: ValueKey('collection_menu_${c.id}'),
      title: c.name,
      preview: preview,
      actions: () => [
        const AppSheetAction(
            key: ValueKey('collection_menu_rename'),
            value: _CollectionAction.rename,
            label: 'Rename…',
            icon: Icons.edit_outlined),
        if (c.ordered)
          const AppSheetAction(
              key: ValueKey('collection_menu_keyword'),
              value: _CollectionAction.keyword,
              label: 'Make it a keyword',
              icon: Icons.sell_outlined)
        else
          const AppSheetAction(
              key: ValueKey('collection_menu_book'),
              value: _CollectionAction.book,
              label: 'Make it a book',
              icon: Icons.format_list_numbered),
        const AppSheetAction(
            key: ValueKey('collection_menu_add_pieces'),
            value: _CollectionAction.addPieces,
            label: 'Add pieces…',
            icon: Icons.playlist_add),
        AppSheetAction(
            key: const ValueKey('collection_menu_delete'),
            value: _CollectionAction.delete,
            label: c.ordered ? 'Delete book' : 'Delete keyword',
            icon: Icons.delete_outline,
            destructive: true),
      ],
      onSelected: (choice) async {
        final actions = PieceActions(context, ref);
        // A keyword that stops being one (deleted, or now a book) must not
        // stay behind as an active filter nobody can see to clear.
        void dropFromFilter() {
          final n = ref.read(pieceFilterProvider.notifier);
          var f = n.state;
          if (f.tagIds.contains(c.id)) f = f.toggleTag(c.id);
          if (f.bookId == c.id) f = f.toggleBook(c.id);
          n.state = f;
        }

        switch (choice) {
          case _CollectionAction.rename:
            await actions.renameKeyword(c);
          case _CollectionAction.book:
            dropFromFilter();
            await actions.setBook(c, true);
          case _CollectionAction.keyword:
            dropFromFilter();
            await actions.setBook(c, false);
          case _CollectionAction.addPieces:
            await actions.addPiecesTo(c);
          case _CollectionAction.delete:
            if (await actions.deleteKeyword(c)) dropFromFilter();
        }
      },
      child: child,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(text.toUpperCase(),
          style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant, letterSpacing: 0.6)),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(text,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

/// A rounded group of rows, the iOS inset-grouped look.
class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkinStyle.of(context).groupRadius)),
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 16),
          children[i],
        ],
      ]),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.leading,
    this.detail,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? leading;
  final String? detail;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimary : scheme.onSurface;
    return ListTile(
      dense: true,
      selected: selected,
      tileColor: selected ? scheme.primary : null,
      selectedTileColor: scheme.primary,
      selectedColor: scheme.onPrimary,
      leading: leading == null ? null : Icon(leading, size: 20),
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (detail != null)
            Text(detail!, style: TextStyle(color: fg.withValues(alpha: 0.8))),
          if (count != null) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 22,
              child: Text('$count',
                  textAlign: TextAlign.right,
                  style: TextStyle(color: fg.withValues(alpha: 0.8))),
            ),
          ],
        ],
      ),
      onTap: onTap,
    );
  }
}

class _ViewTile extends StatelessWidget {
  const _ViewTile({
    super.key,
    required this.icon,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(SkinStyle.of(context).groupRadius)),
        selected: selected,
        selectedTileColor: scheme.primary,
        selectedColor: scheme.onPrimary,
        leading: Icon(icon),
        title: Text(label),
        trailing: count == null ? null : Text('$count'),
        onTap: onTap,
      ),
    );
  }
}
