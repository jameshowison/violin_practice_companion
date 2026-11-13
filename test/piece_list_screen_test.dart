import 'package:flutter/cupertino.dart' show CupertinoActionSheet;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/piece_filter.dart';
import 'package:violin_practice_companion/models/piece_library.dart';
import 'package:violin_practice_companion/models/piece_meta.dart';
import 'package:violin_practice_companion/screens/piece_list_screen.dart';
import 'package:violin_practice_companion/services/piece_activity_store.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';
import 'package:violin_practice_companion/services/piece_list_providers.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/theme/skins.dart';
import 'package:violin_practice_companion/widgets/piece_row.dart';
import 'package:violin_practice_companion/widgets/search_token_field.dart';

Piece piece(String id, String title) =>
    Piece(id: id, title: title, musicXmlAssetPath: 'a/$id.xml', sections: const []);

final pieces = [
  piece('tw', 'Twinkle'),
  piece('lr', 'Lightly Row'),
  piece('ar', 'Go Tell Aunt Rhody'),
  piece('sj', "Soldier's Joy"),
];

PieceMeta meta(String key) =>
    PieceMeta(keyShort: key[0], keyName: key, signature: '2♯', time: '4/4');

const library = PieceLibrary(collections: [
  Collection(id: 'book', name: 'book 1', pieceIds: ['tw', 'lr', 'ar']),
  Collection(id: 'fiddle', name: 'fiddle', pieceIds: ['sj', 'ar'], ordered: false),
]);

class _FixedLibrary extends PieceLibraryNotifier {
  @override
  Future<PieceLibrary> build() async => library;
}

Future<void> pumpList(WidgetTester tester, Size size,
    {Map<String, Object> prefs = const {}, ThemeData? theme}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sp),
      piecesProvider.overrideWith((ref) async => pieces),
      libraryProvider.overrideWith(_FixedLibrary.new),
      allPieceMetaProvider.overrideWith((ref) async => {
            'tw': meta('A major'),
            'lr': meta('A major'),
            'ar': meta('D major'),
            'sj': meta('D major'),
          }),
      recordedPiecesProvider.overrideWith((ref) async => {'lr'}),
    ],
    child: MaterialApp(theme: theme, home: const PieceListScreen()),
  ));
  await tester.pumpAndSettle();
}

const phone = Size(375, 667);
const ipad = Size(1194, 834);

List<int> badgeNumbers(WidgetTester tester) => [
      for (final b in tester.widgetList<BookNumberBadge>(find.byType(BookNumberBadge)))
        b.number
    ];

void main() {
  testWidgets('a fresh install opens on All, A–Z', (tester) async {
    await pumpList(tester, phone);

    final titles = [
      for (final p in ['ar', 'lr', 'sj', 'tw'])
        tester.getTopLeft(find.byKey(ValueKey('piece_row_$p'))).dy
    ];
    expect(titles, orderedEquals([...titles]..sort()));
    expect(find.byKey(const ValueKey('filters_button')), findsOneWidget);
    expect(find.byKey(const ValueKey('piece_filter_sidebar')), findsNothing);
  });

  testWidgets('phone: the drawer picks a book, which numbers the list', (tester) async {
    await pumpList(tester, phone);

    await tester.tap(find.byKey(const ValueKey('filters_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('piece_filter_drawer')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('filter_book_book')));
    await tester.pumpAndSettle();
    expect(find.text('Show 3 pieces'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('filter_show_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('piece_filter_drawer')), findsNothing);

    // Book order, numbered, and the book is a token in the search field.
    expect(badgeNumbers(tester), [1, 2, 3]);
    expect(find.byKey(const ValueKey('search_token_book')), findsOneWidget);
    expect(find.text('3 pieces'), findsOneWidget);

    // Reverse turns it over; A–Z is its own toggle.
    await tester.tap(find.byKey(const ValueKey('book_reverse_button')));
    await tester.pumpAndSettle();
    expect(badgeNumbers(tester), [3, 2, 1]);
    expect(find.text('Reversed · 3 pieces'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('book_reverse_button')));
    await tester.tap(find.byKey(const ValueKey('book_sort_button')));
    await tester.pumpAndSettle();
    expect(find.text('A–Z · 3 pieces'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('book_sort_button')));
    await tester.pumpAndSettle();

    // Removing the token clears the filter, back to the Books shelf.
    await tester.tap(find.byTooltip('Remove book 1'));
    await tester.pumpAndSettle();
    expect(badgeNumbers(tester), isEmpty);
    expect(find.byKey(const ValueKey('shelf_book_book')), findsOneWidget);
  });

  testWidgets('a key filter keeps book numbers, with gaps', (tester) async {
    await pumpList(tester, phone);
    await tester.tap(find.byKey(const ValueKey('filters_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter_book_book')));
    await tester.tap(find.byKey(const ValueKey('filter_key_D major')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter_done_button')));
    await tester.pumpAndSettle();

    expect(badgeNumbers(tester), [3]);
  });

  testWidgets('typing suggests a keyword, which becomes a token', (tester) async {
    await pumpList(tester, phone);

    await tester.enterText(find.byKey(const ValueKey('piece_search_field')), 'fid');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search_suggestion_keyword_fiddle')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search_token_tag_fiddle')), findsOneWidget);
    expect(find.byKey(const ValueKey('piece_row_sj')), findsOneWidget);
    expect(find.byKey(const ValueKey('piece_row_tw')), findsNothing);
  });

  testWidgets('Recents lists what was opened, newest first', (tester) async {
    final now = DateTime.now();
    await pumpList(tester, phone, prefs: {
      'flutter.$pieceActivityKey':
          '{"sj":{"openedAt":${now.subtract(const Duration(minutes: 9)).millisecondsSinceEpoch}},'
              '"tw":{"openedAt":${now.millisecondsSinceEpoch},"lastSection":"Variation C"}}',
    });

    expect(find.byKey(const ValueKey('piece_row_tw')), findsOneWidget);
    expect(find.byKey(const ValueKey('piece_row_sj')), findsOneWidget);
    expect(find.byKey(const ValueKey('piece_row_lr')), findsNothing);
    expect(
        tester.getTopLeft(find.byKey(const ValueKey('piece_row_tw'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('piece_row_sj'))).dy));
    expect(find.textContaining('Variation C'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('piece_tab_all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('piece_row_lr')), findsOneWidget);
  });

  testWidgets('the app icon puts the list back where it started', (tester) async {
    final now = DateTime.now();
    await pumpList(tester, phone, prefs: {
      'flutter.$pieceActivityKey': '{"tw":{"openedAt":${now.millisecondsSinceEpoch}}}',
    });
    // Away from the start: another tab, a token, and a half-typed query.
    await tester.tap(find.byKey(const ValueKey('piece_tab_all')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('piece_search_field')), 'fid');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search_suggestion_keyword_fiddle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('piece_search_field')), 'zzz');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search_token_tag_fiddle')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('app_home_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search_token_tag_fiddle')), findsNothing);
    final field = tester.widget<TextField>(find.byKey(const ValueKey('piece_search_field')));
    expect(field.controller!.text, isEmpty);
    // Back on Recents, where it opened: only the piece played.
    expect(find.byKey(const ValueKey('piece_row_tw')), findsOneWidget);
    expect(find.byKey(const ValueKey('piece_row_lr')), findsNothing);
  });

  testWidgets('iPad: the panel is a sidebar, always out', (tester) async {
    await pumpList(tester, ipad);

    expect(find.byKey(const ValueKey('piece_filter_sidebar')), findsOneWidget);
    expect(find.byKey(const ValueKey('filters_button')), findsNothing);
    expect(find.byKey(const ValueKey('piece_tab_switch')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('filter_book_book')));
    await tester.pumpAndSettle();
    expect(badgeNumbers(tester), [1, 2, 3]);

    // Recents with nothing played: with a book still on, that's a filter
    // matching nothing; with it cleared, the onboarding line.
    await tester.tap(find.byKey(const ValueKey('filter_view_recent')));
    await tester.pumpAndSettle();
    expect(find.text('No pieces match.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('empty_state_clear_button')));
    await tester.pumpAndSettle();
    expect(find.text('Pieces you open will show up here.'), findsOneWidget);
  });

  testWidgets('Edit order shows the whole book with drag handles', (tester) async {
    await pumpList(tester, ipad);
    await tester.tap(find.byKey(const ValueKey('filter_book_book')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('book_edit_order_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('book_order_list')), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
  });

  testWidgets('the Playful skin draws cards and says it kindly', (tester) async {
    await pumpList(tester, phone, theme: playfulTheme());

    expect(find.byType(PieceCard), findsNWidgets(4));
    expect(find.byType(PieceListTile), findsNothing);
    expect(find.text('What shall we play?'), findsOneWidget);
    expect(find.text('All songs'), findsOneWidget);
  });

  // A RenderFlex overflow is a test failure, so pumping is the assertion.
  // Four fixed columns beside the sidebar on a portrait iPad overflowed
  // every card.
  for (final (name, size) in [
    ('SE', phone),
    ('portrait iPad', Size(834, 1194)),
    ('landscape iPad', ipad),
  ]) {
    testWidgets('Playful cards fit on a $name', (tester) async {
      await pumpList(tester, size, theme: playfulTheme());
      expect(find.byType(PieceCard), findsNWidgets(4));
      expect(tester.getSize(find.byType(PieceCard).first).width,
          greaterThanOrEqualTo(140));
    });
  }

  testWidgets('Playful phone: Filters sits in the search field, and opens the drawer',
      (tester) async {
    await pumpList(tester, phone, theme: playfulTheme());

    final button = find.byKey(const ValueKey('filters_button'));
    expect(find.descendant(of: find.byType(SearchTokenField), matching: button),
        findsOneWidget);
    expect(find.text('Filters'), findsNothing); // no app-bar button
    expect(find.text('2♯ A maj.'), findsNWidgets(2));

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('piece_filter_drawer')), findsOneWidget);
  });

  for (final (name, theme) in [('Classic', classicTheme()), ('Playful', playfulTheme())]) {
    testWidgets('$name: a filter pill rides in the one-line search field',
        (tester) async {
      await pumpList(tester, phone, theme: theme);
      final before = tester.getSize(find.byType(SearchTokenField)).height;

      await tester.tap(find.byKey(const ValueKey('filters_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter_book_book')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('search_token_book')), findsOneWidget);
      expect(tester.getSize(find.byType(SearchTokenField)).height, before);
    });
  }

  testWidgets('Playful cards are wider than they are tall', (tester) async {
    await pumpList(tester, phone, theme: playfulTheme());
    final card = tester.getSize(find.byType(PieceCard).first);
    expect(card.width, greaterThan(card.height));
  });

  testWidgets('Classic draws list rows', (tester) async {
    await pumpList(tester, phone, theme: classicTheme());

    expect(find.byType(PieceListTile), findsNWidgets(4));
    expect(find.byType(PieceCard), findsNothing);
    expect(find.text('Pieces'), findsOneWidget);
  });

  testWidgets('the add menu is a Cupertino action sheet on iOS', (tester) async {
    await pumpList(tester, phone,
        theme: classicTheme().copyWith(platform: TargetPlatform.iOS));
    await tester.tap(find.byKey(const ValueKey('add_piece_button')));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('scan_page_fab')), findsOneWidget);
  });

  testWidgets('and a bottom sheet on Android', (tester) async {
    await pumpList(tester, phone,
        theme: classicTheme().copyWith(platform: TargetPlatform.android));
    await tester.tap(find.byKey(const ValueKey('add_piece_button')));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsNothing);
    expect(find.byKey(const ValueKey('import_abc_fab')), findsOneWidget);
  });

  testWidgets('Books is a shelf; a book opens in order, and back', (tester) async {
    await pumpList(tester, phone);
    await tester.tap(find.byKey(const ValueKey('piece_tab_books')));
    await tester.pumpAndSettle();

    // Only ordered keywords are on the shelf.
    expect(find.byKey(const ValueKey('shelf_book_book')), findsOneWidget);
    expect(find.byKey(const ValueKey('shelf_book_fiddle')), findsNothing);
    expect(find.textContaining('3 pieces'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shelf_book_book')));
    await tester.pumpAndSettle();
    expect(badgeNumbers(tester), [1, 2, 3]);
    expect(find.text('3 pieces'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('book_shelf_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shelf_book_book')), findsOneWidget);
    expect(badgeNumbers(tester), isEmpty);
  });

  testWidgets('a book picked in the drawer opens on Books', (tester) async {
    await pumpList(tester, phone);
    await tester.tap(find.byKey(const ValueKey('filters_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter_book_book')));
    await tester.tap(find.byKey(const ValueKey('filter_show_button')));
    await tester.pumpAndSettle();
    final seg = tester.widget<SegmentedButton<PieceTab>>(
        find.byKey(const ValueKey('piece_tab_switch')));
    expect(seg.selected, {PieceTab.books});
  });

  for (final (name, theme) in [('Classic', classicTheme()), ('Playful', playfulTheme())]) {
    testWidgets('$name: three tabs fit an SE without overflow', (tester) async {
      await pumpList(tester, phone, theme: theme);
      // The test font is wider than either real one, so actual fit is
      // checked on the SE; here, just that three segments lay out cleanly.
      expect(tester.takeException(), isNull);
      for (final t in ['recent', 'books', 'all']) {
        expect(find.byKey(ValueKey('piece_tab_$t')), findsOneWidget);
      }
    });
  }

  testWidgets('the sidebar takes about a third of a landscape phone', (tester) async {
    await pumpList(tester, const Size(890, 400));
    final w = tester.getSize(find.byKey(const ValueKey('piece_filter_sidebar'))).width;
    expect(w, closeTo(890 * 0.35, 1));
    expect(find.byKey(const ValueKey('filter_view_books')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow wide layout drops columns before squeezing titles',
      (tester) async {
    // A landscape phone: wide enough for the sidebar, not for every column.
    await pumpList(tester, const Size(890, 400));

    final title = tester.getSize(find.text('Lightly Row'));
    expect(title.width, greaterThan(60)); // not "Li…"
    expect(find.text('#book 1'), findsNothing); // keywords column dropped
  });
}
