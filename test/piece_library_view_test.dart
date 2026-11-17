import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/piece_library.dart';
import 'package:violin_practice_companion/models/piece_library_view.dart';
import 'package:violin_practice_companion/models/section.dart';

Piece piece(String id, {int sections = 0}) => Piece(
      id: id,
      title: id,
      musicXmlAssetPath: 'a/$id.xml',
      sections: [
        for (var i = 0; i < sections; i++)
          Section(label: 'S$i', startMeasure: i + 1)
      ],
    );

void main() {
  group('libraryRows', () {
    test('carries the bundled flag from the caller, not from the path', () {
      // The trap: an EDITED fixture is file-backed and so indistinguishable
      // from a scan by field inspection. Origin has to be told, not inferred.
      final editedFixture = Piece(
          id: 'lightly_row',
          title: 'Lightly Row',
          musicXmlFilePath: '/docs/editable_fixtures/lightly_row.musicxml',
          sections: const []);

      final rows = libraryRows(PieceLibrary.empty, [editedFixture],
          (id) => id == 'lightly_row');

      expect(rows.single.isBundled, isTrue);
    });

    test('reports hidden state and collection names in display order', () {
      var lib = addCollection(PieceLibrary.empty, name: 'Book 1', nowMillis: 1);
      lib = addCollection(lib, name: 'This week', nowMillis: 2);
      for (final c in lib.collections) {
        lib = tagPiece(lib, pieceId: 'a', collectionId: c.id);
      }
      lib = setHidden(lib, 'a', true);

      final rows = libraryRows(lib, [piece('a'), piece('b')], (_) => false);

      expect(rows[0].hidden, isTrue);
      expect(rows[0].collectionNames, ['Book 1', 'This week']);
      expect(rows[1].hidden, isFalse);
      expect(rows[1].collectionNames, isEmpty);
    });
  });

  group('pieceSubtitle', () {
    test('lists collections when no chip is selected', () {
      expect(
        pieceSubtitle(piece('a', sections: 4), ['Book 1', 'This week'],
            includeCollections: true),
        '4 sections · Book 1 · This week',
      );
    });

    test('drops them when a chip is already selected', () {
      // Repeating "Book 1" on every row under the Book 1 filter is noise.
      expect(
        pieceSubtitle(piece('a', sections: 4), ['Book 1'],
            includeCollections: false),
        '4 sections',
      );
    });

    test('a piece in no collection just shows its sections', () {
      expect(pieceSubtitle(piece('a', sections: 0), const [],
              includeCollections: true),
          '0 sections');
    });
  });

  group('libraryEmptyState', () {
    test('an empty collection is a curation problem, so it offers Manage', () {
      final s = libraryEmptyState(
          hasAnyPieces: true, collectionName: 'This week', hiddenCount: 0);

      expect(s.message, contains('This week'));
      expect(s.offerManage, isTrue);
    });

    test('a collection whose pieces are all hidden does not claim to be empty',
        () {
      // The retired OMR-demos seed opened with "OMR demos" holding ten hidden
      // pieces. Saying "No pieces in OMR demos yet" there is simply false, and
      // it offers Manage instead of the show-hidden footer.
      final s = libraryEmptyState(
          hasAnyPieces: true, collectionName: 'OMR demos', hiddenCount: 10);

      expect(s.message, 'All 10 pieces in "OMR demos" are hidden.');
      expect(s.message, isNot(contains('No pieces')));
      expect(s.offerManage, isFalse);
    });

    test('one hidden piece reads as singular', () {
      final s = libraryEmptyState(
          hasAnyPieces: true, collectionName: 'This week', hiddenCount: 1);

      expect(s.message, 'The one piece in "This week" is hidden.');
    });

    test('an empty library is an onboarding problem, so it does not', () {
      // Scan and Import are already on screen, behind the app bar's + button.
      final s = libraryEmptyState(
          hasAnyPieces: false, collectionName: null, hiddenCount: 0);

      expect(s.message, contains('Scan a page'));
      expect(s.offerManage, isFalse);
    });

    test('an all-hidden list says so and leaves the footer to do the work', () {
      final s = libraryEmptyState(
          hasAnyPieces: true, collectionName: null, hiddenCount: 3);

      expect(s.message, 'All pieces are hidden.');
      expect(s.offerManage, isFalse);
    });
  });

  group('resolveActiveCollection', () {
    final collections = [
      const Collection(id: 'book_1', name: 'Book 1'),
    ];

    test('keeps a live id', () {
      expect(resolveActiveCollection('book_1', collections), 'book_1');
    });

    test('drops an id that no longer exists', () {
      // Otherwise deleting the selected collection leaves a filter that hides
      // everything, with no chip left to deselect.
      expect(resolveActiveCollection('deleted_9', collections), isNull);
      expect(resolveActiveCollection('book_1', const []), isNull);
    });
  });

  test('the wide layout starts at 600pt', () {
    expect(isWideLayout(393), isFalse); // phone portrait
    expect(isWideLayout(599), isFalse);
    expect(isWideLayout(600), isTrue);
    expect(isWideLayout(1194), isTrue); // iPad landscape
  });

  test('search matches every word, ignoring case, order and punctuation', () {
    expect(matchesSearch("The Devil's Dream", ''), isTrue);
    expect(matchesSearch("The Devil's Dream", '  '), isTrue);
    expect(matchesSearch("The Devil's Dream", 'devils dream'), isTrue);
    expect(matchesSearch("The Devil's Dream", 'DREAM devil'), isTrue);
    expect(matchesSearch('I love the mountains', 'mount'), isTrue);
    expect(matchesSearch('Bridal Chorus (Wagner) - "Here Comes the Bride"',
        'wagner bride'), isTrue);
    expect(matchesSearch("The Devil's Dream", 'devil spear'), isFalse);
  });
}
