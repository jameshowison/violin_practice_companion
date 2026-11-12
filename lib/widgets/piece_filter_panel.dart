import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/piece_filter.dart';
import '../models/piece_library.dart';
import '../screens/manage_pieces_screen.dart';
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
                    const _Hint('Make a keyword a book in Manage to keep '
                        'its pieces in order.')
                  else
                    _Group(children: [
                      for (final b in books)
                        _OptionTile(
                          key: ValueKey('filter_book_${b.id}'),
                          leading: Icons.format_list_numbered,
                          label: b.name,
                          count: result?.bookCounts[b.id],
                          selected: filter.bookId == b.id,
                          onTap: () => update((f) => f.toggleBook(b.id)),
                        ),
                    ]),
                  const _SectionHeader('Keywords'),
                  if (tags.isEmpty)
                    const _Hint('No keywords yet. Add them in Manage.')
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final t in tags)
                          FilterChip(
                            key: ValueKey('filter_tag_${t.id}'),
                            label: Text(_countLabel(t.name, result?.tagCounts[t.id])),
                            selected: filter.tagIds.contains(t.id),
                            onSelected: (_) => update((f) => f.toggleTag(t.id)),
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
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('manage_pieces_button'),
                      icon: const Icon(Icons.edit_note),
                      label: const Text('Manage pieces and keywords…'),
                      onPressed: () {
                        if (dismissible) close();
                        Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => const ManagePiecesScreen()));
                      },
                    ),
                  ),
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
