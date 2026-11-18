import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/piece_library_view.dart';

void main() {
  group('libraryEmptyMessage', () {
    test('an empty library is an onboarding problem', () {
      // Scan and Import are already on screen, behind the app bar's + button.
      expect(libraryEmptyMessage(hasAnyPieces: false, hiddenCount: 0),
          contains('Scan a page'));
    });

    test('an all-hidden list says so and leaves the footer to do the work', () {
      expect(libraryEmptyMessage(hasAnyPieces: true, hiddenCount: 3),
          'All pieces are hidden.');
    });

    test('pieces, none hidden, but nothing in this list', () {
      expect(libraryEmptyMessage(hasAnyPieces: true, hiddenCount: 0),
          'Nothing to show.');
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
