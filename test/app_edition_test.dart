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

/// One codebase, several possible apps (docs/family/mandolin-app.md):
/// Stringlings offers every instrument; the mandolin flavor, kept for a later
/// split, the mandolin alone.
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
    test('offers every instrument, the violin first', () async {
      final c = await containerWith(AppEdition.stringlings, {});
      expect(c.read(instrumentsOfferedProvider), [
        InstrumentSet.violin,
        InstrumentSet.viola,
        InstrumentSet.mandolin,
        InstrumentSet.recorder,
        InstrumentSet.irishFlute,
      ]);
      expect(c.read(instrumentSetProvider), InstrumentSet.violin);
    });

    test('a stored mandolin is the mandolin', () async {
      final c =
          await containerWith(AppEdition.stringlings, {instrumentSetKey: 'mandolin'});
      expect(c.read(instrumentSetProvider), InstrumentSet.mandolin);
      expect(c.read(instrumentProfileProvider).id, 'mandolin');
      expect(c.read(instrumentFeaturesProvider).tabView, isTrue);
    });

    test('the old combined setting is the mandolin, rewritten', () async {
      final c = await containerWith(
          AppEdition.stringlings, {instrumentSetKey: legacyViolinAndMandolin});
      expect(c.read(instrumentSetProvider), InstrumentSet.mandolin);
      expect(prefs.getString(instrumentSetKey), InstrumentSet.mandolin.name);
    });

    testWidgets('Settings offers every instrument', (tester) async {
      final c = await containerWith(AppEdition.stringlings, {});
      await tester.pumpWidget(UncontrolledProviderScope(
          container: c, child: const MaterialApp(home: SettingsScreen())));
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('instrument_setting_irishFlute')), 200,
          scrollable: list);
      for (final s in InstrumentSet.values) {
        expect(find.byKey(ValueKey('instrument_setting_${s.name}')),
            findsOneWidget, reason: s.name);
      }
      await tester.scrollUntilVisible(
          find.textContaining('Stringlings collects no data'), 200,
          scrollable: list);
      expect(find.textContaining('Stringlings collects no data'), findsOneWidget);
    });

    testWidgets('the picker: one row per family, in order; a tap picks',
        (tester) async {
      InstrumentSet? picked;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: InstrumentPicker(
        offered: instrumentsOffered(AppEdition.stringlings),
        selected: InstrumentSet.viola,
        onChanged: (s) => picked = s,
      ))));
      double y(Finder f) => tester.getCenter(f).dy;
      Finder chip(InstrumentSet s) => find.byKey(ValueKey('instrument_${s.name}'));
      final strings = y(find.text('Strings'));
      final strummed = y(find.text('Strumming'));
      final winds = y(find.text('Woodwinds'));
      expect(strings < strummed && strummed < winds, isTrue);
      expect(y(chip(InstrumentSet.violin)), closeTo(strings, 2));
      expect(y(chip(InstrumentSet.viola)), closeTo(strings, 2));
      expect(y(chip(InstrumentSet.mandolin)), closeTo(strummed, 2));
      expect(y(chip(InstrumentSet.recorder)), closeTo(winds, 2));
      expect(y(chip(InstrumentSet.irishFlute)), closeTo(winds, 2));
      expect(tester.widget<ChoiceChip>(chip(InstrumentSet.viola)).selected, isTrue);
      expect(find.text('Alto clef, C G D A'), findsOneWidget);
      await tester.tap(chip(InstrumentSet.irishFlute));
      expect(picked, InstrumentSet.irishFlute);
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
      expect(find.byType(InstrumentPicker), findsNothing);
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
