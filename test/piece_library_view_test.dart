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
      var lib = addCollection(PieceLibrary.empty, name: 'Suzuki 1', nowMillis: 1);
      lib = addCollection(lib, name: 'This week', nowMillis: 2);
      for (final c in lib.collections) {
        lib = tagPiece(lib, pieceId: 'a', collectionId: c.id);
      }
      lib = setHidden(lib, 'a', true);

      final rows = libraryRows(lib, [piece('a'), piece('b')], (_) => false);

      expect(rows[0].hidden, isTrue);
      expect(rows[0].collectionNames, ['Suzuki 1', 'This week']);
      expect(rows[1].hidden, isFalse);
      expect(rows[1].collectionNames, isEmpty);
    });
  });

  group('pieceSubtitle', () {
    test('lists collections when no chip is selected', () {
      expect(
        pieceSubtitle(piece('a', sections: 4), ['Suzuki 1', 'This week'],
            includeCollections: true),
        '4 sections · Suzuki 1 · This week',
      );
    });

    test('drops them when a chip is already selected', () {
      // Repeating "Suzuki 1" on every row under the Suzuki 1 filter is noise.
      expect(
        pieceSubtitle(piece('a', sections: 4), ['Suzuki 1'],
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
      // The seeded install opens with "OMR demos" holding ten hidden pieces.
      // Saying "No pieces in OMR demos yet" there is simply false, and it sends
      // the user to Manage instead of to the show-hidden footer.
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
      // The Scan and Import FABs are already on screen.
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
      const Collection(id: 'suzuki_1', name: 'Suzuki 1'),
    ];

    test('keeps a live id', () {
      expect(resolveActiveCollection('suzuki_1', collections), 'suzuki_1');
    });

    test('drops an id that no longer exists', () {
      // Otherwise deleting the selected collection leaves a filter that hides
      // everything, with no chip left to deselect.
      expect(resolveActiveCollection('deleted_9', collections), isNull);
      expect(resolveActiveCollection('suzuki_1', const []), isNull);
    });
  });

  test('manage rows label their actions only when there is room', () {
    expect(manageRowUsesLabeledActions(393), isFalse); // phone portrait
    expect(manageRowUsesLabeledActions(599), isFalse);
    expect(manageRowUsesLabeledActions(600), isTrue);
    expect(manageRowUsesLabeledActions(1194), isTrue); // iPad landscape
  });
}
