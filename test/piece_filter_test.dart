import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/piece_filter.dart';
import 'package:violin_practice_companion/models/piece_library.dart';
import 'package:violin_practice_companion/models/piece_meta.dart';
import 'package:violin_practice_companion/services/piece_activity_store.dart';

Piece piece(String id, String title) =>
    Piece(id: id, title: title, musicXmlAssetPath: 'a/$id.xml', sections: const []);

PieceMeta meta(String key, {String? composer}) => PieceMeta(
    keyShort: key.split(' ').first,
    keyName: key,
    signature: '',
    time: '4/4',
    composer: composer);

final pieces = [
  piece('tw', 'Twinkle'),
  piece('lr', 'Lightly Row'),
  piece('ar', 'Go Tell Aunt Rhody'),
  piece('ll', 'Long, Long Ago'),
  piece('hf', 'The Happy Farmer'),
  piece('sj', "Soldier's Joy"),
];

final metas = {
  'tw': meta('A major'),
  'lr': meta('A major'),
  'ar': meta('D major'),
  'll': meta('D major', composer: 'Bayly'),
  'hf': meta('G major', composer: 'Schumann'),
  'sj': meta('D major'),
};

/// "book" (ordered) = tw lr ar ll hf; "fiddle" (plain) = sj ar.
PieceLibrary library() => const PieceLibrary(collections: [
      Collection(id: 'book', name: 'book 1', pieceIds: ['tw', 'lr', 'ar', 'll', 'hf']),
      Collection(id: 'fiddle', name: 'fiddle', pieceIds: ['sj', 'ar'], ordered: false),
    ]);

final now = DateTime(2026, 11, 12, 12);
final activity = {
  'hf': PieceActivity(openedAt: now.subtract(const Duration(hours: 1))),
  'lr': PieceActivity(openedAt: now.subtract(const Duration(minutes: 5))),
  'sj': PieceActivity(openedAt: now.subtract(const Duration(days: 3))),
};

PieceListResult run(PieceFilter f,
        {String query = '', PieceLibrary? lib, Set<String> recorded = const {'lr'}}) =>
    filterPieces(
      pieces: pieces,
      library: lib ?? library(),
      meta: metas,
      activity: activity,
      recorded: recorded,
      filter: f,
      query: query,
    );

List<String> ids(PieceListResult r) => [for (final row in r.rows) row.piece.id];

void main() {
  group('ordering', () {
    test('Recents is newest first and only pieces opened on this device', () {
      expect(ids(run(const PieceFilter())), ['lr', 'hf', 'sj']);
    });

    test('All is A–Z, ignoring a leading "The"', () {
      expect(ids(run(const PieceFilter(tab: PieceTab.all))),
          ['ar', 'hf', 'lr', 'll', 'sj', 'tw']);
    });

    test('a book on All is in book order and numbered', () {
      final r = run(const PieceFilter().toggleBook('book'));

      expect(r.inBookOrder, isTrue);
      expect(ids(r), ['tw', 'lr', 'ar', 'll', 'hf']);
      expect([for (final row in r.rows) row.bookNumber], [1, 2, 3, 4, 5]);
    });

    test('A–Z within a book keeps the book numbers', () {
      final r = run(const PieceFilter()
          .toggleBook('book')
          .copyWith(bookSort: BookSort.az));

      expect(r.inBookOrder, isFalse);
      expect(ids(r), ['ar', 'hf', 'lr', 'll', 'tw']);
      expect(r.rows.first.bookNumber, 3);
    });

    test('other filters leave gaps in the numbering, not renumber', () {
      final r = run(const PieceFilter().toggleBook('book').toggleKey('D major'));

      expect([for (final row in r.rows) row.bookNumber], [3, 4]);
    });

    test('a book in Recents keeps recency order but still numbers', () {
      final r = run(const PieceFilter()
          .toggleBook('book')
          .copyWith(tab: PieceTab.recent));

      expect(ids(r), ['lr', 'hf']);
      expect([for (final row in r.rows) row.bookNumber], [2, 5]);
      expect(r.inBookOrder, isFalse);
    });

    test('a deleted piece leaves no gap in a book', () {
      final lib = const PieceLibrary(collections: [
        Collection(id: 'book', name: 'b', pieceIds: ['gone', 'tw', 'lr']),
      ]);
      final r = run(const PieceFilter().toggleBook('book'), lib: lib);

      expect([for (final row in r.rows) row.bookNumber], [1, 2]);
    });

    test('an unordered keyword is never treated as a book', () {
      final r = run(const PieceFilter().toggleBook('fiddle'));

      expect(r.book, isNull);
      expect(r.rows.first.bookNumber, isNull);
    });
  });

  group('filters', () {
    test('keywords must all apply', () {
      final r = run(const PieceFilter(tab: PieceTab.all).toggleTag('fiddle'));
      expect(ids(r), ['ar', 'sj']);
    });

    test('key and recording narrow', () {
      expect(ids(run(const PieceFilter(tab: PieceTab.all).toggleKey('A major'))),
          ['lr', 'tw']);
      expect(
          ids(run(const PieceFilter(tab: PieceTab.all, hasRecording: true))), ['lr']);
    });

    test('search reaches composer and keyword names', () {
      expect(ids(run(const PieceFilter(tab: PieceTab.all), query: 'schumann')),
          ['hf']);
      expect(ids(run(const PieceFilter(tab: PieceTab.all), query: 'fiddle')),
          ['ar', 'sj']);
      expect(ids(run(const PieceFilter(tab: PieceTab.all), query: 'soldiers')),
          ['sj']);
    });

    test('hidden pieces and renamed titles follow the library', () {
      final lib = setTitleOverride(setHidden(library(), 'tw', true), 'lr', 'Zebra');
      final r = run(const PieceFilter(tab: PieceTab.all), lib: lib);

      expect(ids(r).contains('tw'), isFalse);
      expect(ids(r).last, 'lr'); // "Zebra" sorts last
    });

    test('activeCount and cleared', () {
      final f = const PieceFilter(tab: PieceTab.all)
          .toggleBook('book')
          .toggleTag('fiddle')
          .toggleKey('D major')
          .copyWith(hasRecording: true);

      expect(f.activeCount, 4);
      expect(f.cleared(), const PieceFilter(tab: PieceTab.all));
    });

    test('toggling a selected book or key clears it', () {
      final f = const PieceFilter().toggleBook('book').toggleKey('A major');
      expect(f.toggleBook('book').bookId, isNull);
      expect(f.toggleKey('A major').keyName, isNull);
    });
  });

  group('facet counts exclude their own facet', () {
    test('key counts with a key selected count every key', () {
      final r = run(const PieceFilter(tab: PieceTab.all).toggleKey('A major'));

      expect(r.keyCounts, {'A major': 2, 'D major': 3, 'G major': 1});
    });

    test('keyword and book counts apply the other filters', () {
      final r = run(const PieceFilter(tab: PieceTab.all).toggleKey('D major'));

      expect(r.tagCounts, {'fiddle': 2});
      expect(r.bookCounts, {'book': 2});
    });

    test('tab counts apply all filters', () {
      final r = run(const PieceFilter(tab: PieceTab.all).toggleKey('D major'));

      expect(r.tabCounts, {PieceTab.recent: 1, PieceTab.all: 3});
    });
  });

  group('suggestions', () {
    test('books, then keywords, then keys, minus what is applied', () {
      final lib = library();
      final keys = metas.values.map((m) => m.keyName);

      expect(
          pieceSuggestions('d', lib, keys, const PieceFilter()),
          const [
            FilterSuggestion(SuggestionKind.keyword, 'fiddle', 'fiddle'),
            FilterSuggestion(SuggestionKind.key, 'D major', 'D major'),
          ]);
      expect(pieceSuggestions('book', lib, keys, const PieceFilter()).single.kind,
          SuggestionKind.book);
      expect(
          pieceSuggestions('book', lib, keys, const PieceFilter().toggleBook('book')),
          isEmpty);
      expect(pieceSuggestions('  ', lib, keys, const PieceFilter()), isEmpty);
    });
  });

  test('lastPlayedLabel', () {
    final noon = DateTime(2026, 11, 12, 12);
    expect(lastPlayedLabel(DateTime(2026, 11, 12, 1), noon), 'Today');
    expect(lastPlayedLabel(DateTime(2026, 11, 11, 23), noon), 'Yesterday');
    expect(lastPlayedLabel(DateTime(2026, 11, 9), noon), '3 days ago');
    expect(lastPlayedLabel(DateTime(2026, 10, 29), noon), '2 weeks ago');
    expect(lastPlayedLabel(DateTime(2026, 8, 1), noon), '3 months ago');
  });

  test('a book reports its full length, however filtered', () {
    final r = run(const PieceFilter().toggleBook('book').toggleKey('D major'));
    expect(r.bookLength, 5);
    expect(r.rows.length, 2);
  });

  test('recentBucket goes by calendar day', () {
    final noon = DateTime(2026, 11, 12, 12);
    expect(recentBucket(DateTime(2026, 11, 12, 0, 5), noon), 'Today');
    expect(recentBucket(DateTime(2026, 11, 11, 23, 59), noon), 'Yesterday');
    expect(recentBucket(DateTime(2026, 11, 9), noon), 'Earlier');
  });
}
