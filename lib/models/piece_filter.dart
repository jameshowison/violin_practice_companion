/// The piece list's filtering and ordering, as pure functions over values.
///
/// Everything the list screen shows — which rows, in what order, what number
/// a book gives each, and the counts beside every filter — is computed here
/// from the library, the pieces' header metadata, this device's Recents and
/// the filter state. The screen only renders the result, so all of it is
/// unit-testable without a widget.
library;

import 'piece.dart';
import 'piece_library.dart';
import 'piece_library_view.dart' show matchesSearch;
import 'piece_meta.dart';
import '../services/piece_activity_store.dart' show PieceActivity;

/// The list's three views. [books] is the shelf of ordered keywords until
/// one is picked, then that book in its own order; [all] is every piece.
enum PieceTab { recent, books, all }

/// How a selected book is ordered on the All tab.
enum BookSort { book, az }

/// What the list is narrowed by. Session state; nothing here is stored.
class PieceFilter {
  final PieceTab tab;

  /// The one selected book (an ordered keyword), by collection id.
  final String? bookId;

  /// Plain keywords, all of which must apply.
  final Set<String> tagIds;

  /// A display key name, as [PieceMeta.keyName]: `A major`.
  final String? keyName;

  final bool hasRecording;

  final BookSort bookSort;

  /// The list turned upside down: last book number first, Z–A, or oldest
  /// first on Recents. Independent of [bookSort], so "reverse" never also
  /// means "switch to A–Z".
  final bool reversed;

  const PieceFilter({
    this.tab = PieceTab.recent,
    this.bookId,
    this.tagIds = const {},
    this.keyName,
    this.hasRecording = false,
    this.bookSort = BookSort.book,
    this.reversed = false,
  });

  PieceFilter copyWith({
    PieceTab? tab,
    String? bookId,
    bool clearBook = false,
    Set<String>? tagIds,
    String? keyName,
    bool clearKey = false,
    bool? hasRecording,
    BookSort? bookSort,
    bool? reversed,
  }) =>
      PieceFilter(
        tab: tab ?? this.tab,
        bookId: clearBook ? null : (bookId ?? this.bookId),
        tagIds: tagIds ?? this.tagIds,
        keyName: clearKey ? null : (keyName ?? this.keyName),
        hasRecording: hasRecording ?? this.hasRecording,
        bookSort: bookSort ?? this.bookSort,
        reversed: reversed ?? this.reversed,
      );

  /// Picking a book opens it on Books, in book order. Picking the selected
  /// one again clears it (back to the shelf, if on Books).
  PieceFilter toggleBook(String id) => bookId == id
      ? copyWith(clearBook: true)
      : copyWith(
          bookId: id, tab: PieceTab.books, bookSort: BookSort.book, reversed: false);

  /// On Books with no book picked: the screen shows the shelf, not rows.
  bool get onShelf => tab == PieceTab.books && bookId == null;

  PieceFilter toggleTag(String id) => copyWith(
        tagIds: tagIds.contains(id)
            ? ({...tagIds}..remove(id))
            : {...tagIds, id},
      );

  PieceFilter toggleKey(String name) =>
      keyName == name ? copyWith(clearKey: true) : copyWith(keyName: name);

  /// Everything but the tab and the sort cleared.
  PieceFilter cleared() => PieceFilter(tab: tab, bookSort: bookSort);

  /// How many filters are on: the badge on the phone's Filters button.
  int get activeCount =>
      (bookId == null ? 0 : 1) +
      tagIds.length +
      (keyName == null ? 0 : 1) +
      (hasRecording ? 1 : 0);

  @override
  bool operator ==(Object other) =>
      other is PieceFilter &&
      other.tab == tab &&
      other.bookId == bookId &&
      other.keyName == keyName &&
      other.hasRecording == hasRecording &&
      other.bookSort == bookSort &&
      other.reversed == reversed &&
      other.tagIds.length == tagIds.length &&
      other.tagIds.containsAll(tagIds);

  @override
  int get hashCode => Object.hash(tab, bookId, keyName, hasRecording, bookSort, reversed,
      Object.hashAllUnordered(tagIds));
}

/// One rendered row.
class PieceListRow {
  final Piece piece;

  /// The piece's place in the selected book, 1-based, counted over the whole
  /// book — NOT renumbered after other filters, so "book 1 + D major" reads
  /// 4, 7, 8. Null with no book selected.
  final int? bookNumber;

  final PieceMeta? meta;
  final PieceActivity? activity;
  final bool hasRecording;

  /// Every keyword and book the piece carries, in library order.
  final List<String> keywordNames;

  const PieceListRow({
    required this.piece,
    this.bookNumber,
    this.meta,
    this.activity,
    this.hasRecording = false,
    this.keywordNames = const [],
  });
}

class PieceListResult {
  final List<PieceListRow> rows;

  /// Whether [rows] are in the selected book's own order (so the screen says
  /// "In book order" and numbers read top to bottom).
  final bool inBookOrder;

  /// The selected book, resolved; null when none is selected or its id no
  /// longer exists.
  final Collection? book;

  /// How many pieces the selected book holds, counting only pieces that
  /// exist (hidden ones included). 0 with no book.
  final int bookLength;

  /// Facet counts. Each applies every filter EXCEPT its own facet, within the
  /// current tab, so a count always says how many rows picking it would give.
  final Map<String, int> bookCounts;
  final Map<String, int> tagCounts;
  final Map<String, int> keyCounts;

  /// Rows each tab would show with the current filters (the iPad sidebar).
  final Map<PieceTab, int> tabCounts;

  const PieceListResult({
    required this.rows,
    required this.inBookOrder,
    required this.book,
    this.bookLength = 0,
    required this.bookCounts,
    required this.tagCounts,
    required this.keyCounts,
    required this.tabCounts,
  });
}

/// Title for A–Z: case-folded, a leading "The"/"A"/"An" ignored, so
/// "The Happy Farmer" sorts under H.
String sortTitle(String title) => title
    .trim()
    .toLowerCase()
    .replaceFirst(RegExp(r'^(the|a|an)\s+'), '');

enum _Facet { book, tags, key, recording }

/// The list for [filter] and [query].
///
/// [pieces] is the repository's list; the library's titles and hiding are
/// applied here. [meta] may be partial while it loads: a piece without
/// metadata simply fails a key filter and shows no key.
PieceListResult filterPieces({
  required List<Piece> pieces,
  required PieceLibrary library,
  required Map<String, PieceMeta> meta,
  required Map<String, PieceActivity> activity,
  required Set<String> recorded,
  required PieceFilter filter,
  required String query,
}) {
  final visible = applyLibrary(library, pieces);
  final existing = {for (final p in pieces) p.id};
  final bookRaw =
      filter.bookId == null ? null : library.collectionById(filter.bookId!);
  final book = (bookRaw != null && bookRaw.ordered) ? bookRaw : null;
  // Numbering skips ids whose piece is gone, so a deleted piece leaves no gap.
  final bookOrder = book == null
      ? const <String>[]
      : [for (final id in book.pieceIds) if (existing.contains(id)) id];
  final bookIndex = {for (var i = 0; i < bookOrder.length; i++) bookOrder[i]: i};

  final namesOf = <String, List<String>>{};
  for (final c in library.collections) {
    for (final id in c.pieceIds) {
      (namesOf[id] ??= []).add(c.name);
    }
  }

  bool inTab(Piece p, PieceTab tab) =>
      tab != PieceTab.recent || activity.containsKey(p.id);

  bool matchesQuery(Piece p) {
    if (query.trim().isEmpty) return true;
    final m = meta[p.id];
    return matchesSearch(
      [p.title, m?.composer ?? '', ...?namesOf[p.id]].join(' '),
      query,
    );
  }

  bool passes(Piece p, {_Facet? except}) =>
      matchesQuery(p) &&
      (except == _Facet.book || book == null || bookIndex.containsKey(p.id)) &&
      (except == _Facet.tags ||
          filter.tagIds.every((t) =>
              library.collectionById(t)?.pieceIds.contains(p.id) ?? false)) &&
      (except == _Facet.key ||
          filter.keyName == null ||
          meta[p.id]?.keyName == filter.keyName) &&
      (except == _Facet.recording ||
          !filter.hasRecording ||
          recorded.contains(p.id));

  final inThisTab = [for (final p in visible) if (inTab(p, filter.tab)) p];

  final rowsSrc = [for (final p in inThisTab) if (passes(p)) p];
  final inBookOrder = book != null &&
      filter.tab != PieceTab.recent &&
      filter.bookSort == BookSort.book;
  if (filter.tab == PieceTab.recent) {
    rowsSrc.sort((a, b) =>
        activity[b.id]!.openedAt.compareTo(activity[a.id]!.openedAt));
  } else if (inBookOrder) {
    rowsSrc.sort((a, b) => bookIndex[a.id]!.compareTo(bookIndex[b.id]!));
  } else {
    rowsSrc.sort((a, b) => sortTitle(a.title).compareTo(sortTitle(b.title)));
  }

  final ordered = filter.reversed ? rowsSrc.reversed : rowsSrc;
  final rows = [
    for (final p in ordered)
      PieceListRow(
        piece: p,
        bookNumber: book == null ? null : bookIndex[p.id]! + 1,
        meta: meta[p.id],
        activity: activity[p.id],
        hasRecording: recorded.contains(p.id),
        keywordNames: namesOf[p.id] ?? const [],
      ),
  ];

  int countWhere(_Facet facet, bool Function(Piece) also) =>
      inThisTab.where((p) => passes(p, except: facet) && also(p)).length;

  final bookCounts = {
    for (final c in library.collections)
      if (c.ordered) c.id: countWhere(_Facet.book, (p) => c.pieceIds.contains(p.id)),
  };
  final tagCounts = {
    for (final c in library.collections)
      if (!c.ordered) c.id: countWhere(_Facet.tags, (p) => c.pieceIds.contains(p.id)),
  };
  final keyNames = {for (final m in meta.values) m.keyName};
  final keyCounts = {
    for (final k in keyNames)
      k: countWhere(_Facet.key, (p) => meta[p.id]?.keyName == k),
  };
  // Books counts books, not pieces: what the shelf would show.
  final tabCounts = {
    for (final t in PieceTab.values)
      t: t == PieceTab.books
          ? bookCounts.length
          : visible.where((p) => inTab(p, t) && passes(p)).length,
  };

  return PieceListResult(
    rows: rows,
    inBookOrder: inBookOrder,
    book: book,
    bookLength: bookOrder.length,
    bookCounts: bookCounts,
    tagCounts: tagCounts,
    keyCounts: keyCounts,
    tabCounts: tabCounts,
  );
}

/// Where a Recents row is grouped: "Today", "Yesterday" or "Earlier", by the
/// calendar day in local time.
String recentBucket(DateTime openedAt, DateTime now) {
  final day = DateTime(now.year, now.month, now.day);
  final opened = DateTime(openedAt.year, openedAt.month, openedAt.day);
  final days = day.difference(opened).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  return 'Earlier';
}

/// The wide list's "Last played" column: "Today", "Yesterday", "3 days ago",
/// "2 weeks ago", by calendar day.
String lastPlayedLabel(DateTime openedAt, DateTime now) {
  final day = DateTime(now.year, now.month, now.day);
  final opened = DateTime(openedAt.year, openedAt.month, openedAt.day);
  final days = day.difference(opened).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 14) return '$days days ago';
  if (days < 60) return '${days ~/ 7} weeks ago';
  return '${days ~/ 30} months ago';
}

enum SuggestionKind { book, keyword, key }

class FilterSuggestion {
  final SuggestionKind kind;
  final String label;

  /// The collection id for a book or keyword; the key name for a key.
  final String value;

  const FilterSuggestion(this.kind, this.label, this.value);

  @override
  bool operator ==(Object other) =>
      other is FilterSuggestion &&
      other.kind == kind &&
      other.label == label &&
      other.value == value;

  @override
  int get hashCode => Object.hash(kind, label, value);
}

/// Filters the search box offers for what is being typed: books, then
/// keywords, then keys whose name contains the query, leaving out any already
/// applied. At most [limit].
List<FilterSuggestion> pieceSuggestions(
  String query,
  PieceLibrary library,
  Iterable<String> keyNames,
  PieceFilter filter, {
  int limit = 4,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  return [
    for (final c in library.collections)
      if (c.ordered && c.id != filter.bookId && c.name.toLowerCase().contains(q))
        FilterSuggestion(SuggestionKind.book, c.name, c.id),
    for (final c in library.collections)
      if (!c.ordered &&
          !filter.tagIds.contains(c.id) &&
          c.name.toLowerCase().contains(q))
        FilterSuggestion(SuggestionKind.keyword, c.name, c.id),
    for (final k in (keyNames.toSet().toList()..sort()))
      if (k != filter.keyName && k.toLowerCase().contains(q))
        FilterSuggestion(SuggestionKind.key, k, k),
  ].take(limit).toList();
}
