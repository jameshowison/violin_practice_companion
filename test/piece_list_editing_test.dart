// Editing pieces where they are: press and hold, swipe, Select, the hidden
// pieces sheet, and the filter panel's keyword menu. These replaced the
// Manage screen.
import 'package:flutter/cupertino.dart' show CupertinoContextMenuAction;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/piece_library.dart';
import 'package:violin_practice_companion/models/piece_meta.dart';
import 'package:violin_practice_companion/screens/piece_list_screen.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';
import 'package:violin_practice_companion/services/piece_list_providers.dart';
import 'package:violin_practice_companion/services/piece_repository.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/theme/skins.dart';

Piece piece(String id, String title) =>
    Piece(id: id, title: title, musicXmlAssetPath: 'a/$id.xml', sections: const []);

final pieces = [
  piece('tw', 'Twinkle'),
  piece('lr', 'Lightly Row'),
  piece('sj', "Soldier's Joy"), // the only user piece: deletable
];

PieceMeta meta(String key) =>
    PieceMeta(keyShort: key[0], keyName: key, signature: '2♯', time: '4/4');

const baseLibrary = PieceLibrary(collections: [
  Collection(id: 'fiddle', name: 'fiddle', pieceIds: ['sj'], ordered: false),
]);

/// Everything but Soldier's Joy ships with the app.
class _FakeRepo extends PieceRepository {
  @override
  bool isBundled(String id) => id != 'sj';
}

/// Records deletions instead of touching files.
class _FakeActions extends LibraryActions {
  _FakeActions(super.ref, this.deleted);
  final List<String> deleted;

  @override
  Future<void> deletePiece(String pieceId) async => deleted.add(pieceId);
}

class _Library extends PieceLibraryNotifier {
  _Library(this.initial);
  final PieceLibrary initial;

  @override
  Future<PieceLibrary> build() async => initial;
}

late ProviderContainer container;
late List<String> deleted;

Future<void> pumpList(WidgetTester tester,
    {TargetPlatform platform = TargetPlatform.android,
    ThemeData? theme,
    PieceLibrary library = baseLibrary}) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final sp = await SharedPreferences.getInstance();
  deleted = [];
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sp),
      pieceRepositoryProvider.overrideWithValue(_FakeRepo()),
      libraryActionsProvider.overrideWith((ref) => _FakeActions(ref, deleted)),
      piecesProvider.overrideWith((ref) async => pieces),
      libraryProvider.overrideWith(() => _Library(library)),
      allPieceMetaProvider.overrideWith((ref) async =>
          {for (final p in pieces) p.id: meta('D major')}),
      recordedPiecesProvider.overrideWith((ref) async => <String>{}),
    ],
    child: Builder(builder: (context) {
      container = ProviderScope.containerOf(context);
      return MaterialApp(
        theme: theme ?? ThemeData(platform: platform),
        home: const PieceListScreen(),
      );
    }),
  ));
  await tester.pumpAndSettle();
}

Finder row(String id) => find.byKey(ValueKey('piece_row_$id'));

PieceLibrary lib() => container.read(libraryProvider).value!;

void main() {
  testWidgets('Android: press and hold a user piece, delete, then Undo',
      (tester) async {
    await pumpList(tester);

    await tester.longPress(row('sj'));
    await tester.pumpAndSettle();
    for (final k in ['rename', 'keywords', 'select', 'delete']) {
      expect(find.byKey(ValueKey('piece_menu_$k')), findsOneWidget, reason: k);
    }
    expect(find.byKey(const ValueKey('piece_menu_hide')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('piece_menu_delete')));
    await tester.pumpAndSettle();
    // Always asks first.
    expect(find.text('Delete "Soldier\'s Joy"?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('destructive_confirm_button')));
    await tester.pumpAndSettle();

    // Gone from the list at once, but nothing deleted while Undo is offered.
    expect(row('sj'), findsNothing);
    expect(find.text('Deleted "Soldier\'s Joy".'), findsOneWidget);
    expect(deleted, isEmpty);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(row('sj'), findsOneWidget);
    expect(deleted, isEmpty);
  });

  testWidgets('the delete happens when the snackbar times out',
      (tester) async {
    await pumpList(tester);
    await tester.longPress(row('sj'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('piece_menu_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('destructive_confirm_button')));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(deleted, ['sj']);
    expect(container.read(pendingDeletesProvider), isEmpty);
  });

  testWidgets('cancelling the confirm deletes nothing', (tester) async {
    await pumpList(tester);
    await tester.longPress(row('sj'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('piece_menu_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('destructive_cancel_button')));
    await tester.pumpAndSettle();
    expect(row('sj'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(deleted, isEmpty);
  });

  testWidgets('a built-in piece offers Hide, never Delete, with Undo',
      (tester) async {
    await pumpList(tester);
    await tester.longPress(row('lr'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('piece_menu_delete')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('piece_menu_hide')));
    await tester.pumpAndSettle();
    expect(row('lr'), findsNothing);
    expect(lib().hiddenIds, contains('lr'));

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(row('lr'), findsOneWidget);
    expect(lib().hiddenIds, isNot(contains('lr')));
  });

  testWidgets('iOS: press and hold opens the context menu', (tester) async {
    await pumpList(tester, platform: TargetPlatform.iOS);
    // The system menu opens after a longer hold than a plain long press.
    final g = await tester.startGesture(tester.getCenter(row('lr')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(CupertinoContextMenuAction, 'Hide from list'),
        findsOneWidget);
    expect(find.widgetWithText(CupertinoContextMenuAction, 'Delete'),
        findsNothing);
  });

  testWidgets('Playful on iOS: a card lifts into the context menu',
      (tester) async {
    await pumpList(tester,
        platform: TargetPlatform.iOS,
        theme: playfulTheme().copyWith(platform: TargetPlatform.iOS));
    final g = await tester.startGesture(tester.getCenter(row('sj')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(CupertinoContextMenuAction, 'Delete'),
        findsOneWidget);
    // Cards don't swipe; the grid has no swipe actions at all.
    expect(find.byKey(const ValueKey('swipe_delete_sj')), findsNothing);
  });

  testWidgets('iOS: swipe left reveals Delete, which still asks',
      (tester) async {
    await pumpList(tester, platform: TargetPlatform.iOS);
    await tester.drag(row('sj'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('swipe_delete_sj')));
    await tester.pumpAndSettle();
    expect(find.text('Delete "Soldier\'s Joy"?'), findsOneWidget);
  });

  testWidgets('Android rows do not swipe', (tester) async {
    await pumpList(tester);
    await tester.drag(row('sj'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('swipe_delete_sj')), findsNothing);
  });

  testWidgets('Select several, then hide them; Delete waits for user pieces',
      (tester) async {
    await pumpList(tester);
    await tester.tap(find.byKey(const ValueKey('piece_select_button')));
    await tester.pumpAndSettle();
    await tester.tap(row('tw'));
    await tester.tap(row('sj'));
    await tester.pumpAndSettle();
    expect(find.text('2 SELECTED'), findsOneWidget);

    // Twinkle ships with the app, so the selection can't be deleted.
    final del = tester
        .widget<TextButton>(find.byKey(const ValueKey('select_delete_button')));
    expect(del.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('select_hide_button')));
    await tester.pumpAndSettle();
    expect(lib().hiddenIds, containsAll(['tw', 'sj']));
    expect(find.byKey(const ValueKey('select_hide_button')), findsNothing);
  });

  testWidgets('the hidden footer opens a sheet that shows a piece again',
      (tester) async {
    await pumpList(tester,
        library: const PieceLibrary(hiddenIds: {'tw'}));
    expect(row('tw'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('show_hidden_footer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hidden_row_tw')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hidden_show_tw')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing is hidden.'), findsOneWidget);
    expect(lib().hiddenIds, isEmpty);
  });

  testWidgets('filter panel: press and hold a keyword to make it a book',
      (tester) async {
    await pumpList(tester);
    await tester.tap(find.byKey(const ValueKey('filters_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('manage_pieces_button')), findsNothing);

    await tester.longPress(find.byKey(const ValueKey('filter_tag_fiddle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('collection_menu_book')));
    await tester.pumpAndSettle();
    expect(lib().collections.single.ordered, isTrue);
    expect(find.byKey(const ValueKey('filter_book_fiddle')), findsOneWidget);
  });
}
