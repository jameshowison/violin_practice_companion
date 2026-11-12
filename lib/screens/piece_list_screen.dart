import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../build_info.dart';
import '../models/piece.dart';
import '../models/piece_filter.dart';
import '../models/piece_library.dart';
import '../models/piece_library_view.dart';
import '../models/piece_layout.dart';
import '../services/piece_list_providers.dart';
import '../services/providers.dart';
import '../services/verovio_engraver.dart';
import '../theme/skin_style.dart';
import '../ui/adaptive/adaptive.dart';
import '../widgets/piece_filter_panel.dart';
import '../widgets/piece_row.dart';
import '../widgets/search_token_field.dart';
import 'abc_import_screen.dart';
import 'manage_pieces_screen.dart';
import 'piece_detail_screen.dart';
import 'scan_screen.dart';
import 'settings_screen.dart';
import '../services/launch_timing.dart';
import '../ui/stringlings/stringlings_tile.dart';

/// The everyday list — what the child opens the app to.
///
/// One screen, two layouts. A phone keeps the filters (books, keywords, key,
/// recording) in a drawer that slides in over most of the screen; a tablet
/// keeps the same panel out as a sidebar. Either way the active filters show
/// as tokens in the search field, and the list is Recents or All.
///
/// Read-only apart from the filters and a book's order: renaming, hiding,
/// deleting and keywording live behind Manage (in the filter panel), so the
/// surface a kid taps to pick a piece can't accidentally lose one. The gear
/// opens the app-wide [SettingsScreen].
class PieceListScreen extends ConsumerWidget {
  const PieceListScreen({super.key});

  Future<void> _addPiece(BuildContext context) async {
    final choice = await showAppActionSheet<String>(
      context,
      title: 'Add a piece',
      actions: const [
        AppSheetAction(
          key: ValueKey('scan_page_fab'),
          value: 'scan',
          label: 'Scan a page',
          icon: Icons.document_scanner,
        ),
        AppSheetAction(
          key: ValueKey('import_abc_fab'),
          value: 'abc',
          label: 'Import from ABC',
          icon: Icons.library_music,
        ),
      ],
    );
    if (!context.mounted || choice == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          choice == 'scan' ? const ScanScreen() : const AbcImportScreen(),
    ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = isWideLayout(width);
    final skin = SkinStyle.of(context);
    final activeCount =
        ref.watch(pieceFilterProvider.select((f) => f.activeCount));
    final book = ref.watch(pieceListProvider).valueOrNull?.book;

    final grouped = Theme.of(context).colorScheme.surfaceContainerLow;
    return Scaffold(
      // The grouped background the white rows and panel groups sit on. Set
      // here, not app-wide, so the piece screen keeps a plain page.
      backgroundColor: grouped,
      drawer: wide
          ? null
          : Drawer(
              key: const ValueKey('piece_filter_drawer'),
              width: width * 0.86,
              shape: const RoundedRectangleBorder(),
              child: const PieceFilterPanel(dismissible: true),
            ),
      appBar: AppBar(
        backgroundColor: grouped,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        // Top left, the app's icon: on a tablet with its name, the width of
        // the sidebar beneath (the panel is already out, so no Filters button);
        // on a phone beside Filters, or alone where Playful has put Filters in
        // the search field.
        leadingWidth: wide
            ? sidebarWidth(width)
            : skin.filtersInSearch
                ? 56
                // Icon and Filters icon: 96, the two actions' width, so the
                // title stays on the true centre.
                : 100,
        leading: wide
            ? const _AppBadge()
            : Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 16, right: 4),
                    child: StringlingsTile(size: 32),
                  ),
                  if (!skin.filtersInSearch)
                    Builder(
                      builder: (ctx) => IconButton(
                        key: const ValueKey('filters_button'),
                        tooltip: 'Filters',
                        onPressed: () => Scaffold.of(ctx).openDrawer(),
                        icon: Badge(
                          isLabelVisible: activeCount > 0,
                          label: Text('$activeCount'),
                          child: const Icon(Icons.filter_list),
                        ),
                      ),
                    ),
                ],
              ),
        // The build stamp rides on the FIRST screen, not just the piece detail
        // one, so "is my change actually running?" can be answered before
        // navigating anywhere. See CLAUDE.md "Verify the build is live".
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Shrinks rather than truncates: "What shall we play?" beside
            // the Filters button and two icons is a tight fit at 375pt.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(book?.name ?? skin.listTitle, maxLines: 1),
            ),
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
            key: const ValueKey('add_piece_button'),
            icon: const Icon(Icons.add),
            tooltip: 'Add a piece',
            onPressed: () => _addPiece(context),
          ),
          IconButton(
            key: const ValueKey('app_settings_button'),
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  key: const ValueKey('piece_filter_sidebar'),
                  width: sidebarWidth(width),
                  child: const PieceFilterPanel(dismissible: false),
                ),
                const VerticalDivider(width: 1),
                const Expanded(child: _PieceListBody(wide: true)),
              ],
            )
          : const _PieceListBody(wide: false),
    );
  }
}

/// The icon and the app's name, top left of the tablet piece list.
class _AppBadge extends StatelessWidget {
  const _AppBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Row(
        children: [
          const StringlingsTile(size: 36),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              'Stringlings',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Playful card grid, for pieces and books alike: as many columns as fit
/// at 220pt or narrower (two on a phone, three beside the sidebar on a portrait
/// iPad, four in landscape), each card only as tall as its content needs, so
/// wider than it is tall.
///
/// Not a fixed count and aspect ratio: four columns beside the sidebar on a
/// portrait iPad made 114×88pt cards, too short for the badge row, a two-line
/// title and the subtitle, and every card overflowed.
SliverGridDelegate _cardGrid(BuildContext context) {
  // 12 + 12 padding, the 30pt badge (or 28pt book icon) row and a 6pt gap,
  // then room for the two-line title, the gap and the subtitle, which scale
  // with the text.
  final textScale = MediaQuery.textScalerOf(context);
  return SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 220,
    mainAxisSpacing: 12,
    crossAxisSpacing: 12,
    mainAxisExtent: 60 + textScale.scale(56),
  );
}

class _PieceListBody extends ConsumerStatefulWidget {
  const _PieceListBody({required this.wide});

  final bool wide;

  @override
  ConsumerState<_PieceListBody> createState() => _PieceListBodyState();
}

class _PieceListBodyState extends ConsumerState<_PieceListBody> {
  /// Rearranging the selected book.
  bool _editing = false;

  /// The order just dragged to, shown until the library catches up — the same
  /// optimism as Manage's reorderable list.
  List<String>? _pendingOrder;

  double get _gutter => widget.wide ? 24 : 16;

  void _update(PieceFilter Function(PieceFilter) f) {
    appSelectionHaptic();
    final n = ref.read(pieceFilterProvider.notifier);
    n.state = f(n.state);
  }

  Future<void> _open(Piece piece) async {
    VerovioEngraver.openClock..reset()..start();
    // Seed the rows the detail screen would otherwise push after its first
    // frame: that push reloads the layout, and the reload blanks the body and
    // throws away the staff's first engrave. The detail screen is full width
    // even beside the sidebar, so measure the whole window.
    ref.read(measuresPerRowProvider.notifier).state = measuresPerRowForWidth(
        MediaQuery.sizeOf(context).width -
            MediaQuery.paddingOf(context).horizontal);
    ref.read(selectedPieceProvider.notifier).state = piece;
    ref.read(measureSelectionProvider.notifier).state = null;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PieceDetailScreen()),
    );
    // Media is added and removed inside a piece; refresh the recording marks.
    if (mounted) ref.invalidate(recordedPiecesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(pieceListProvider);
    return async.when(
      data: (result) {
        LaunchTiming.markOnce('piece list built with data');
        if (LaunchTiming.enabled) {
          WidgetsBinding.instance.addPostFrameCallback(
              (_) => LaunchTiming.markOnce('list painted'));
        }
        return _content(result);
      },
      loading: () {
        LaunchTiming.markOnce('spinner shown');
        return Center(child: CircularProgressIndicator.adaptive());
      },
      error: (e, st) => Center(child: Text('Error loading pieces: $e')),
    );
  }

  Widget _content(PieceListResult result) {
    final filter = ref.watch(pieceFilterProvider);
    final skin = SkinStyle.of(context);
    final book = result.book;
    final editing = _editing && book != null;
    if (book == null && _editing) _editing = false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(_gutter, 8, _gutter, 0),
          child: SearchTokenField(
              showFilters: !widget.wide && skin.filtersInSearch),
        ),
        if (!widget.wide)
          Padding(
            padding: EdgeInsets.fromLTRB(_gutter, 12, _gutter, 0),
            child: SegmentedButton<PieceTab>(
              key: const ValueKey('piece_tab_switch'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                    value: PieceTab.recent,
                    label: Text(skin.recentsTab,
                        key: const ValueKey('piece_tab_recent'))),
                ButtonSegment(
                    value: PieceTab.books,
                    label: Text(skin.booksTab,
                        key: const ValueKey('piece_tab_books'))),
                ButtonSegment(
                    value: PieceTab.all,
                    label: Text(skin.allTab,
                        key: const ValueKey('piece_tab_all'))),
              ],
              selected: {filter.tab},
              onSelectionChanged: (s) {
                setState(() => _editing = false);
                _update((f) => f.copyWith(tab: s.single));
              },
            ),
          ),
        if (book != null) _bookStrip(result, filter, book, editing),
        Expanded(
            child: editing
                ? _editList(book)
                : filter.onShelf
                    ? _shelf(result)
                    : _list(result, filter)),
      ],
    );
  }

  Widget _bookStrip(
      PieceListResult result, PieceFilter filter, Collection book, bool editing) {
    final theme = Theme.of(context);
    final line = filter.tab == PieceTab.recent
        ? 'Recently played from ${book.name}'
        : _orderLine(result, filter);
    // One line even on a 375pt phone, so the two orderings are icons, each a
    // toggle that shows when it is on: A–Z (versus book order) and reverse.
    // Separate on purpose — one up/down arrow that meant "switch to A–Z"
    // read as "reverse" and confused.
    return Padding(
      padding: EdgeInsets.fromLTRB(_gutter, 6, _gutter - 8, 0),
      child: Row(
        children: [
          if (filter.tab == PieceTab.books && !editing)
            IconButton(
              key: const ValueKey('book_shelf_button'),
              icon: const Icon(Icons.chevron_left),
              tooltip: 'All books',
              onPressed: () => _update((f) => f.copyWith(clearBook: true)),
            ),
          Expanded(
            child: Text(editing ? 'Drag to change the book order' : line,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          if (filter.tab != PieceTab.recent && !editing)
            IconButton(
              key: const ValueKey('book_sort_button'),
              isSelected: filter.bookSort == BookSort.az,
              icon: const Icon(Icons.sort_by_alpha),
              tooltip: filter.bookSort == BookSort.az
                  ? 'Back to book order'
                  : 'Sort A–Z',
              onPressed: () => _update((f) => f.copyWith(
                  bookSort: f.bookSort == BookSort.book
                      ? BookSort.az
                      : BookSort.book)),
            ),
          if (!editing)
            IconButton(
              key: const ValueKey('book_reverse_button'),
              isSelected: filter.reversed,
              icon: const Icon(Icons.swap_vert),
              tooltip: filter.reversed ? 'Undo reverse' : 'Reverse order',
              onPressed: () =>
                  _update((f) => f.copyWith(reversed: !f.reversed)),
            ),
          TextButton(
            key: const ValueKey('book_edit_order_button'),
            onPressed: () {
              setState(() {
                _editing = !_editing;
                _pendingOrder = null;
              });
              if (_editing && filter.tab == PieceTab.recent) {
                _update((f) => f.copyWith(tab: PieceTab.books));
              }
            },
            child: Text(editing ? 'Done' : 'Edit order'),
          ),
        ],
      ),
    );
  }

  /// Books with no book picked: every book as a row (or a card, in Playful)
  /// with its size and first few titles. Narrowing by search or a filter
  /// leaves out the books with nothing left in them.
  Widget _shelf(PieceListResult result) {
    final skin = SkinStyle.of(context);
    final theme = Theme.of(context);
    final library = ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty;
    final pieces = ref.watch(piecesProvider).valueOrNull ?? const <Piece>[];
    final filter = ref.watch(pieceFilterProvider);
    final narrowed =
        ref.watch(pieceSearchProvider).trim().isNotEmpty || filter.activeCount > 0;
    final titles = {for (final p in applyLibrary(library, pieces)) p.id: p.title};
    final books = [
      for (final c in library.collections)
        if (c.ordered && (!narrowed || (result.bookCounts[c.id] ?? 0) > 0)) c
    ];

    if (books.isEmpty) {
      return narrowed
          ? _EmptyState(
              message: 'No books match.',
              action: (
                key: 'empty_state_clear_button',
                label: 'Clear filters',
                onPressed: () {
                  ref.read(pieceSearchProvider.notifier).state = '';
                  _update((f) => f.cleared());
                },
              ),
            )
          : const _EmptyState(
              message: 'No books yet. In Manage, turn on "Book: keeps its own '
                  'order" for a keyword to shelve it here.',
              offerManage: true,
            );
    }

    String countOf(Collection b) {
      final n = result.bookCounts[b.id] ?? 0;
      return '$n ${n == 1 ? 'piece' : 'pieces'}';
    }

    String firstTitles(Collection b) => [
          for (final id in b.pieceIds)
            if (titles[id] case final t?) t
        ].take(3).join(', ');

    void open(Collection b) => _update((f) => f.toggleBook(b.id));

    if (skin.rowStyle == PieceRowStyle.cards) {
      return GridView.builder(
        padding: EdgeInsets.fromLTRB(_gutter, 14, _gutter, 24),
        gridDelegate: _cardGrid(context),
        itemCount: books.length,
        itemBuilder: (_, i) => _BookCard(
          key: ValueKey('shelf_book_${books[i].id}'),
          name: books[i].name,
          detail: countOf(books[i]),
          color: skin.cardColors[i % skin.cardColors.length],
          onTap: () => open(books[i]),
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(_gutter, 4, _gutter, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
          child: Text(
              '${books.length} ${books.length == 1 ? 'BOOK' : 'BOOKS'}',
              style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 0.6)),
        ),
        Material(
          color: theme.colorScheme.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(skin.groupRadius)),
          child: Column(children: [
            for (var i = 0; i < books.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 58),
              ListTile(
                key: ValueKey('shelf_book_${books[i].id}'),
                leading: Icon(Icons.menu_book_outlined,
                    color: theme.colorScheme.primary),
                title: Text(books[i].name),
                subtitle: Text(
                  [countOf(books[i]), firstTitles(books[i])]
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => open(books[i]),
              ),
            ],
          ]),
        ),
      ],
    );
  }

  /// Short enough for the ~116pt the strip's buttons leave on an SE. Book
  /// order goes unsaid (the numbers show it); only a departure from it does.
  static String _orderLine(PieceListResult result, PieceFilter filter) {
    final n = result.rows.length;
    final count = n == result.bookLength
        ? '$n ${n == 1 ? 'piece' : 'pieces'}'
        : '$n of ${result.bookLength}';
    final how = [
      if (!result.inBookOrder) 'A–Z',
      if (filter.reversed) result.inBookOrder ? 'Reversed' : 'reversed',
    ].join(', ');
    return how.isEmpty ? count : '$how · $count';
  }

  Widget _editList(Collection book) {
    final library = ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty;
    final pieces = ref.watch(piecesProvider).valueOrNull ?? const <Piece>[];
    var members =
        applyLibrary(library, pieces, collectionId: book.id, showHidden: true);
    final pending = _pendingOrder;
    if (pending != null && pending.length == members.length) {
      final byId = {for (final p in members) p.id: p};
      if (pending.every(byId.containsKey)) {
        members = [for (final id in pending) byId[id]!];
      }
    }
    final ids = [for (final p in members) p.id];
    final theme = Theme.of(context);
    return ReorderableListView.builder(
      key: const ValueKey('book_order_list'),
      buildDefaultDragHandles: false,
      padding: EdgeInsets.fromLTRB(_gutter, 12, _gutter, 24),
      itemCount: members.length,
      itemBuilder: (context, i) => Material(
        key: ValueKey('book_order_row_${members[i].id}'),
        color: theme.colorScheme.surface,
        child: ListTile(
          leading: BookNumberBadge(number: i + 1),
          title: Text(members[i].title),
          trailing: ReorderableDragStartListener(
            index: i,
            child: const Icon(Icons.drag_handle),
          ),
        ),
      ),
      onReorderItem: (oldIndex, newIndex) {
        setState(() => _pendingOrder = reorderedIds(ids, oldIndex, newIndex));
        ref
            .read(libraryProvider.notifier)
            .reorderInCollection(book.id, ids, oldIndex, newIndex);
      },
    );
  }

  Widget _list(PieceListResult result, PieceFilter filter) {
    final skin = SkinStyle.of(context);
    final query = ref.watch(pieceSearchProvider);
    final library = ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty;
    final pieces = ref.watch(piecesProvider).valueOrNull ?? const <Piece>[];
    final hidden = hiddenCount(library, pieces, collectionId: result.book?.id);
    final narrowed = query.trim().isNotEmpty || filter.activeCount > 0;
    final recents = filter.tab == PieceTab.recent;

    if (result.rows.isEmpty) {
      if (narrowed) {
        return _EmptyState(
          message: 'No pieces match.',
          action: (
            key: 'empty_state_clear_button',
            label: 'Clear filters',
            onPressed: () {
              ref.read(pieceSearchProvider.notifier).state = '';
              _update((f) => f.cleared());
            },
          ),
        );
      }
      if (recents) {
        return _EmptyState(
          message: 'Pieces you open will show up here.',
          action: (
            key: 'empty_state_all_button',
            label: 'See all pieces',
            onPressed: () => _update((f) => f.copyWith(tab: PieceTab.all)),
          ),
        );
      }
      final state = libraryEmptyState(
        hasAnyPieces: pieces.isNotEmpty,
        collectionName: null,
        hiddenCount: hidden,
      );
      return Column(children: [
        Expanded(
            child: _EmptyState(message: state.message, offerManage: state.offerManage)),
        if (hidden > 0) _HiddenFooter(count: hidden),
      ]);
    }

    final now = DateTime.now();
    String subtitleOf(PieceListRow r) =>
        pieceRowSubtitle(r, recents: recents, wide: widget.wide);

    final footer = [
      if (hidden > 0 && !narrowed) _HiddenFooter(count: hidden),
    ];

    if (skin.rowStyle == PieceRowStyle.cards) {
      return GridView.builder(
        padding: EdgeInsets.fromLTRB(_gutter, 14, _gutter, 24),
        gridDelegate: _cardGrid(context),
        itemCount: result.rows.length + footer.length,
        itemBuilder: (_, i) {
          if (i >= result.rows.length) return footer[i - result.rows.length];
          final r = result.rows[i];
          return PieceCard(
            key: ValueKey('piece_row_${r.piece.id}'),
            row: r,
            subtitle: recents
                ? [
                    lastPlayedLabel(r.activity!.openedAt, now),
                    ?r.activity?.lastSection,
                  ].join(' · ')
                : (r.meta?.composer ?? ''),
            color: skin.cardColors[i % skin.cardColors.length],
            onTap: () => _open(r.piece),
          );
        },
      );
    }

    // Classic: inset groups. Recents (with no book) by day; otherwise one group.
    final groups = <(String, List<PieceListRow>)>[];
    if (recents && result.book == null) {
      for (final label in const ['Today', 'Yesterday', 'Earlier']) {
        final rows = [
          for (final r in result.rows)
            if (recentBucket(r.activity!.openedAt, now) == label) r
        ];
        if (rows.isNotEmpty) groups.add((label, rows));
      }
    } else if (result.book != null && !recents) {
      // The book strip above already says the order and the count.
      groups.add(('', result.rows));
    } else {
      final n = result.rows.length;
      final order = result.inBookOrder
          ? 'book order'
          : recents
              ? 'most recent first'
              : 'A–Z';
      final rev = filter.reversed ? ', reversed' : '';
      groups.add(('$n ${n == 1 ? 'piece' : 'pieces'} · $order$rev', result.rows));
    }

    final theme = Theme.of(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(_gutter, 4, _gutter, 24),
      children: [
        for (final (label, rows) in groups) ...[
          if (label.isEmpty)
            const SizedBox(height: 14)
          else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
            child: Text(label.toUpperCase(),
                style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.6)),
          ),
          Material(
            color: theme.colorScheme.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(skin.groupRadius)),
            child: Column(children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0)
                  Divider(
                      height: 1,
                      indent: rows[i].bookNumber == null ? 16 : 58),
                PieceListTile(
                  key: ValueKey('piece_row_${rows[i].piece.id}'),
                  row: rows[i],
                  subtitle: subtitleOf(rows[i]),
                  wide: widget.wide,
                  lastPlayed: rows[i].activity == null
                      ? null
                      : lastPlayedLabel(rows[i].activity!.openedAt, now),
                  onTap: () => _open(rows[i].piece),
                ),
              ],
            ]),
          ),
        ],
        ...footer,
      ],
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

/// A book on the Playful shelf: a coloured card like the piece cards.
class _BookCard extends StatelessWidget {
  const _BookCard({
    super.key,
    required this.name,
    required this.detail,
    required this.color,
    required this.onTap,
  });

  final String name;
  final String detail;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = SkinStyle.of(context).cardInk;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.menu_book, color: ink, size: 28),
              const Spacer(),
              Text(name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                      color: ink, fontWeight: FontWeight.w900, height: 1.15)),
              const SizedBox(height: 4),
              Text(detail,
                  style: theme.textTheme.bodySmall?.copyWith(color: ink)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.message,
    this.offerManage = false,
    this.action,
  });

  final String message;
  final bool offerManage;
  final ({String key, String label, VoidCallback onPressed})? action;

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
              message,
              textAlign: TextAlign.center,
              style:
                  theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
            ),
            if (action case final a?) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(
                key: ValueKey(a.key),
                onPressed: a.onPressed,
                child: Text(a.label),
              ),
            ],
            if (offerManage) ...[
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
