import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/screens/scan_photo_screen.dart';
import 'package:violin_practice_companion/services/omr_service_base.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/services/scan_source_store_io.dart';

void main() {
  late Directory docs;
  setUp(() async => docs = await Directory.systemTemp.createTemp('scan_photo'));
  tearDown(() async => docs.delete(recursive: true));

  final jpg = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0]);

  Future<void> pump(WidgetTester tester, String pieceId) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        scanSourceStoreProvider.overrideWithValue(ScanSourceStore(root: docs)),
      ],
      child: MaterialApp(home: ScanPhotoScreen(pieceId: pieceId, title: 'Tune')),
    ));
    // The pages are read from disk, which fake-async time doesn't advance:
    // let real time pass, then pump to deliver each step of the read.
    for (var i = 0; i < 20 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  testWidgets('pages through the originals, counting them in the title',
      (tester) async {
    await tester.runAsync(() => ScanSourceStore(root: docs).save('tune_1', [
          ScanSourcePage(original: jpg, cropped: jpg),
          ScanSourcePage(original: jpg, cropped: jpg),
        ]));
    await pump(tester, 'tune_1');
    expect(find.text('Original photo · page 1 of 2'), findsOneWidget);
    await tester.fling(find.byKey(const ValueKey('scan_photo_pages')),
        const Offset(-600, 0), 2000);
    await tester.pumpAndSettle();
    expect(find.text('Original photo · page 2 of 2'), findsOneWidget);
  });

  testWidgets('says so when nothing was kept', (tester) async {
    await pump(tester, 'never_scanned');
    expect(find.text('No photo was kept for this piece.'), findsOneWidget);
  });
}
