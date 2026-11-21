// A performance tempo set by hand for a piece overrides every recording of
// it. These pin down the two things that keep that from going unnoticed: the
// tray says so, and a recording asks (once) whether to be followed instead.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/tempo_presets.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/services/tempo_store.dart';
import 'package:violin_practice_companion/widgets/tempo_controls.dart';

void main() {
  group('offerRecordingTempo', () {
    test('asks when a pin disagrees with the recording', () {
      // The case that prompted it: pinned 118, teacher video ~79.
      expect(offerRecordingTempo(118, 79.4), isTrue);
    });

    test('not without a pin, or without a measured recording', () {
      expect(offerRecordingTempo(null, 79.4), isFalse);
      expect(offerRecordingTempo(118, null), isFalse);
      expect(offerRecordingTempo(118, 0), isFalse);
    });

    test('not when they already agree to within a bpm', () {
      expect(offerRecordingTempo(79, 79.4), isFalse);
      expect(offerRecordingTempo(80, 79.4), isFalse);
      expect(offerRecordingTempo(81, 79.4), isTrue);
    });
  });

  test('asked once per recording, per piece', () async {
    SharedPreferences.setMockInitialValues({});
    final store = TempoStore();
    expect(await store.wasAskedAboutRecording('p', 'm1'), isFalse);
    await store.markAskedAboutRecording('p', 'm1');
    await store.markAskedAboutRecording('p', 'm1'); // no duplicate
    final fresh = TempoStore();
    expect(await fresh.wasAskedAboutRecording('p', 'm1'), isTrue);
    expect(await fresh.wasAskedAboutRecording('p', 'm2'), isFalse);
    expect(await fresh.wasAskedAboutRecording('q', 'm1'), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('tempo.askedRecording.p'), ['m1']);
  });

  group('the tray shows a pinned tempo', () {
    const piece =
        Piece(id: 'p', title: 'P', musicXmlAssetPath: 'x.xml', sections: []);

    Future<ProviderContainer> pump(WidgetTester tester,
        {int? pinned}) async {
      SharedPreferences.setMockInitialValues(
          {if (pinned != null) 'flutter.tempo.piece.p': pinned});
      final c = ProviderContainer(overrides: [
        pieceRecordingBpmProvider.overrideWith((ref, id) async => 79.4),
        parsedPieceProvider.overrideWith((ref) async => const ParsedPiece(
            keySignature: 'C',
            keyFifths: 0,
            keyMode: KeyMode.major,
            measures: [])),
      ]);
      addTearDown(c.dispose);
      c.read(selectedPieceProvider.notifier).state = piece;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
            home: Scaffold(body: Center(child: TempoPresetPicker()))),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('pinned: a pin on the chip, "set by hand" in the menu',
        (tester) async {
      await pump(tester, pinned: 118);
      expect(find.byKey(const ValueKey('tempo_pinned')), findsOneWidget);
      await tester.tap(find.byType(TempoPresetPicker));
      await tester.pumpAndSettle();
      expect(find.text('Performance (118, set by hand)'), findsOneWidget);
      expect(find.text('Use recording (79)'), findsOneWidget);
    });

    testWidgets('following the recording: no pin', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('tempo_pinned')), findsNothing);
      await tester.tap(find.byType(TempoPresetPicker));
      await tester.pumpAndSettle();
      expect(find.text('Performance (79)'), findsOneWidget);
    });

    testWidgets('"Use recording" takes the pin off', (tester) async {
      final c = await pump(tester, pinned: 118);
      await tester.tap(find.byType(TempoPresetPicker));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use recording (79)'));
      await tester.pumpAndSettle();
      expect(c.read(piecePerformanceOverrideProvider('p')), isNull);
      expect(find.byKey(const ValueKey('tempo_pinned')), findsNothing);
    });
  });
}
