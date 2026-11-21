import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/app_edition.dart';
import 'package:violin_practice_companion/services/instrument_setting.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';
import 'package:violin_practice_companion/services/players.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/screens/settings_screen.dart';
import 'package:violin_practice_companion/widgets/player_badge.dart';

/// Two apps from one codebase (docs/family/mandolin-app.md): Stringlings
/// offers violin and viola, the mandolin app the mandolin alone.
void main() {
  late SharedPreferences prefs;

  Future<ProviderContainer> containerWith(
      AppEdition edition, Map<String, Object> saved) async {
    SharedPreferences.setMockInitialValues(saved);
    prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      appEditionProvider.overrideWithValue(edition),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('the flavor names the edition; none, or an unknown one, is Stringlings',
      () {
    expect(AppEdition.fromFlavor('mandolin'), AppEdition.mandolin);
    expect(AppEdition.fromFlavor('stringlings'), AppEdition.stringlings);
    expect(AppEdition.fromFlavor(null), AppEdition.stringlings);
    expect(AppEdition.fromFlavor('banjo'), AppEdition.stringlings);
    expect(AppEdition.mandolin.appName, 'Mandolings');
    expect(AppEdition.stringlings.appName, 'Stringlings');
  });

  group('Stringlings', () {
    test('offers the violin and the viola only', () async {
      final c = await containerWith(AppEdition.stringlings, {});
      expect(c.read(instrumentsOfferedProvider),
          [InstrumentSet.violin, InstrumentSet.viola]);
      expect(c.read(instrumentSetProvider), InstrumentSet.violin);
    });

    test('a stored mandolin falls back to the violin, and is left alone',
        () async {
      final c =
          await containerWith(AppEdition.stringlings, {instrumentSetKey: 'mandolin'});
      expect(c.read(instrumentSetProvider), InstrumentSet.violin);
      expect(c.read(instrumentProfileProvider).id, 'violin');
      expect(c.read(instrumentFeaturesProvider).tabView, isFalse);
      expect(prefs.getString(instrumentSetKey), 'mandolin');
    });

    test('the old combined setting falls back to the violin too', () async {
      final c = await containerWith(
          AppEdition.stringlings, {instrumentSetKey: legacyViolinAndMandolin});
      expect(c.read(instrumentSetProvider), InstrumentSet.violin);
      expect(prefs.getString(instrumentSetKey), legacyViolinAndMandolin);
    });

    testWidgets('Settings offers violin and viola, not the mandolin',
        (tester) async {
      final c = await containerWith(AppEdition.stringlings, {});
      await tester.pumpWidget(UncontrolledProviderScope(
          container: c, child: const MaterialApp(home: SettingsScreen())));
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('instrument_setting_viola')), 200,
          scrollable: list);
      expect(find.byKey(const ValueKey('instrument_setting_violin')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('instrument_setting_mandolin')),
          findsNothing);
      expect(find.textContaining('Mandolin'), findsNothing);
      expect(find.textContaining('Stringlings collects no data'), findsOneWidget);
    });
  });

  group('Mandolin', () {
    test('is the mandolin, whatever was stored', () async {
      final c =
          await containerWith(AppEdition.mandolin, {instrumentSetKey: 'violin'});
      expect(c.read(instrumentsOfferedProvider), [InstrumentSet.mandolin]);
      expect(c.read(instrumentSetProvider), InstrumentSet.mandolin);
      expect(c.read(instrumentProfileProvider).id, 'mandolin');
      final f = c.read(instrumentFeaturesProvider);
      expect((f.tabView, f.chords), (true, true));
    });

    test('a fresh install is the mandolin, without writing it', () async {
      final c = await containerWith(AppEdition.mandolin, {});
      expect(c.read(instrumentSetProvider), InstrumentSet.mandolin);
      expect(prefs.getString(instrumentSetKey), isNull);
    });

    testWidgets('Settings has no instrument choice, and names the app',
        (tester) async {
      final c = await containerWith(AppEdition.mandolin, {});
      await tester.pumpWidget(UncontrolledProviderScope(
          container: c, child: const MaterialApp(home: SettingsScreen())));
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('add_player')), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const ValueKey('instrument_setting')), findsNothing);
      expect(find.byType(RadioListTile<InstrumentSet>), findsNothing);
      expect(find.textContaining('Mandolings collects no data'), findsOneWidget);
    });

    testWidgets('a new player gets the mandolin, with no choice offered',
        (tester) async {
      final c = await containerWith(AppEdition.mandolin, {});
      await tester.pumpWidget(UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
              home: Builder(
                  builder: (context) => Scaffold(
                      body: TextButton(
                          onPressed: () => showAddPlayerSheet(context),
                          child: const Text('open')))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add_player_instrument')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('add_player_name')), 'Ada');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('add_player_confirm')));
      await tester.pumpAndSettle();
      final ada = c.read(playersProvider).last;
      expect(c.read(currentPlayerIdProvider), ada.id);
      expect(c.read(instrumentSetProvider), InstrumentSet.mandolin);
    });
  });
}
