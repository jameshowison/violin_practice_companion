import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/piece_filter.dart';
import '../models/piece_library.dart';
import '../services/piece_list_providers.dart';
import '../services/providers.dart';
import '../theme/skin_style.dart';
import '../ui/adaptive/adaptive.dart';

/// The search box, with every active filter shown in it as a removable token.
///
/// The tokens are why the phone's filter drawer can close without hiding what
/// is filtering the list. Typing offers matching books, keywords and keys as
/// suggestions; picking one turns it into a token and clears the text.
///
/// Stateful only to own the controller, which is seeded from
/// [pieceSearchProvider] so the query survives a trip into a piece and back.
class SearchTokenField extends ConsumerStatefulWidget {
  const SearchTokenField({super.key, this.showFilters = false});

  /// A Filters button at the end of the field that opens the enclosing
  /// Scaffold's drawer (Playful on a phone, where the app bar doesn't have one).
  final bool showFilters;

  @override
  ConsumerState<SearchTokenField> createState() => _SearchTokenFieldState();
}

class _SearchTokenFieldState extends ConsumerState<SearchTokenField> {
  late final _controller =
      TextEditingController(text: ref.read(pieceSearchProvider));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setQuery(String q) {
    if (_controller.text != q) _controller.text = q;
    ref.read(pieceSearchProvider.notifier).state = q;
  }

  void _update(PieceFilter Function(PieceFilter) f) {
    appSelectionHaptic();
    final n = ref.read(pieceFilterProvider.notifier);
    n.state = f(n.state);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final skin = SkinStyle.of(context);
    final filter = ref.watch(pieceFilterProvider);
    final query = ref.watch(pieceSearchProvider);
    // Follow a query changed from outside the field (the app icon's reset).
    ref.listen(pieceSearchProvider, (_, q) {
      if (_controller.text != q) _controller.text = q;
    });
    final library = ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty;
    final metas = ref.watch(allPieceMetaProvider).valueOrNull ?? const {};

    final tokens = <(String, String, VoidCallback)>[
      if (filter.bookId case final id?)
        if (library.collectionById(id) case final c?)
          ('book', c.name, () => _update((f) => f.copyWith(clearBook: true))),
      for (final id in filter.tagIds)
        if (library.collectionById(id) case final c?)
          ('tag_$id', c.name, () => _update((f) => f.toggleTag(id))),
      if (filter.keyName case final k?)
        ('key', k, () => _update((f) => f.copyWith(clearKey: true))),
      if (filter.hasRecording)
        ('recording', 'Recording',
            () => _update((f) => f.copyWith(hasRecording: false))),
    ];

    final suggestions = pieceSuggestions(
        query, library, metas.values.map((m) => m.keyName), filter);

    void pick(FilterSuggestion s) {
      _update((f) => switch (s.kind) {
            SuggestionKind.book => f.toggleBook(s.value),
            SuggestionKind.keyword => f.toggleTag(s.value),
            SuggestionKind.key => f.copyWith(keyName: s.value),
          });
      _setQuery('');
    }

    final radius = BorderRadius.circular(skin.groupRadius);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: scheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(borderRadius: radius),
          // One line, the active filters as pills ahead of the text. They get
          // at most half the width and scroll sideways past that, so there is
          // always room to type.
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
            child: Row(
              children: [
                Icon(Icons.search, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                if (tokens.isNotEmpty)
                  Flexible(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final (key, label, remove) in tokens)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: InputChip(
                                key: ValueKey('search_token_$key'),
                                label: Text(label),
                                onDeleted: remove,
                                deleteButtonTooltipMessage: 'Remove $label',
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: scheme.primary,
                                labelStyle: TextStyle(color: scheme.onPrimary),
                                deleteIconColor: scheme.onPrimary,
                                side: BorderSide.none,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: TextField(
                    key: const ValueKey('piece_search_field'),
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: tokens.isEmpty ? skin.searchHint : null,
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onChanged: _setQuery,
                  ),
                ),
                if (query.isNotEmpty)
                  IconButton(
                    key: const ValueKey('piece_search_clear'),
                    icon: const Icon(Icons.cancel),
                    color: scheme.onSurfaceVariant,
                    tooltip: 'Clear search',
                    onPressed: () => _setQuery(''),
                  )
                else if (!widget.showFilters)
                  const SizedBox(height: 48),
                if (widget.showFilters)
                  IconButton(
                    key: const ValueKey('filters_button'),
                    tooltip: 'Filters',
                    color: scheme.primary,
                    onPressed: () => Scaffold.of(context).openDrawer(),
                    icon: Badge(
                      isLabelVisible: filter.activeCount > 0,
                      label: Text('${filter.activeCount}'),
                      child: const Icon(Icons.tune),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Material(
              color: scheme.surface,
              shape: RoundedRectangleBorder(borderRadius: radius),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final s in suggestions)
                    ListTile(
                      key: ValueKey('search_suggestion_${s.kind.name}_${s.value}'),
                      dense: true,
                      leading: _KindBadge(s.kind),
                      title: Text(s.label),
                      onTap: () => pick(s),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge(this.kind);
  final SuggestionKind kind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        switch (kind) {
          SuggestionKind.book => 'Book',
          SuggestionKind.keyword => 'Keyword',
          SuggestionKind.key => 'Key',
        },
        style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: scheme.onPrimaryContainer),
      ),
    );
  }
}
