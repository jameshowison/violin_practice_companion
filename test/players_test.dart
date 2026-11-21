import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/display_mode.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/services/instrument_setting.dart';
import 'package:violin_practice_companion/services/piece_activity_store.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';
import 'package:violin_practice_companion/services/players.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/screens/settings_screen.dart';
import 'package:violin_practice_companion/theme/app_skin.dart';
import 'package:violin_practice_companion/widgets/player_badge.dart';

Piece _piece(String id) =>
    Piece(id: id, title: id, musicXmlFilePath: '/x/$id.musicxml', sections: const []);

/// The player layer (docs/family/layers.md): what is the player's follows
/// who is playing; what is the piece's or the instrument's does not.
void main() {
  late SharedPreferences prefs;

  Future<ProviderContainer> containerWith(Map<String, Object> saved) async {
    SharedPreferences.setMockInitialValues(saved);
    prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('one unnamed player: every key is as it always was', () async {
    final c = await containerWith({'app.instruments': 'viola'});
    expect(c.read(playersProvider), isEmpty);
    expect(c.read(currentPlayerProvider), isNull);
    expect(c.read(multiplePlayersProvider), isFalse);
    expect(c.read(playerKeyProvider)('display.view.a'), 'display.view.a');
    expect(c.read(instrumentSetProvider), InstrumentSet.viola);
  });

  test('adding a player names the first, who keeps everything stored',
      () async {
    final c = await containerWith({
      'app.instruments': 'viola',
      'display.view.a': 'jianpu',
    });
    final theo = c.read(playersProvider.notifier).add('Theo', colour: 1);
    final players = c.read(playersProvider);
    expect(players.map((p) => p.name), ['Player 1', 'Theo']);
    expect(theo.initials, 'T');
    expect(c.read(multiplePlayersProvider), isTrue);
    // Still the first player playing, with their settings.
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    expect(c.read(instrumentSetProvider), InstrumentSet.viola);
    expect(c.read(displayModeProvider), DisplayMode.jianpu);
  });

  test('switching player switches what is theirs, and only that', () async {
    final c = await containerWith({
      'app.instruments': 'viola',
      'display.view.a': 'jianpu',
      'display.violinStrings.a': 'fourthFinger',
      'app.skin': 'playful',
      'pieceActivity': '{"a":{"openedAt":1}}',
    });
    final theo = c.read(playersProvider.notifier).add('Theo', colour: 1);
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    c.read(currentPlayerIdProvider.notifier).state = theo.id;
    expect(prefs.getString(currentPlayerKey), theo.id);

    // Theo's own: a fresh instrument, view, skin and recents.
    expect(c.read(instrumentSetProvider), InstrumentSet.violin);
    expect(c.read(displayModeProvider), isNot(DisplayMode.jianpu));
    expect(c.read(appSkinProvider), AppSkin.classic);
    expect(c.read(pieceActivityProvider), isEmpty);
    // The instrument's, shared: the open/4th preference.
    expect(c.read(violinStringPreferenceProvider).name, 'fourthFinger');

    // Theo picks the mandolin; it is stored under Theo's key only.
    c.read(instrumentSetProvider.notifier).state = InstrumentSet.mandolin;
    expect(prefs.getString('player.${theo.id}.app.instruments'), 'mandolin');
    expect(prefs.getString('app.instruments'), 'viola');

    // Back to the first player: as they left it.
    c.read(currentPlayerIdProvider.notifier).state = null;
    expect(c.read(instrumentSetProvider), InstrumentSet.viola);
    expect(c.read(appSkinProvider), AppSkin.playful);
  });

  test('initials: up to two words, else one letter', () {
    expect(const Player(id: 'x', name: 'Maya Ruth', colour: 0).initials, 'MR');
    expect(const Player(id: 'x', name: 'ivy', colour: 0).initials, 'I');
    expect(const Player(id: 'x', name: '  ', colour: 0).initials, '?');
  });

  testWidgets('adding a player in Settings names the first and switches',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final sp = await SharedPreferences.getInstance();
    final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(sp)]);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(375, 667) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
          home: Scaffold(
              appBar: _BadgeBar(), body: SettingsScreen())),
    ));
    expect(find.byKey(const ValueKey('player_badge')), findsNothing);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('add_player')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Add a second player'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add_player')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('add_player_name')), 'Theo');
    await tester.pump();
    await tester.tap(find.text('Viola: alto clef, C G D A').last);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('add_player_confirm')));
    await tester.pumpAndSettle();

    expect(container.read(playersProvider).map((p) => p.name),
        ['Player 1', 'Theo']);
    expect(container.read(currentPlayerProvider)!.name, 'Theo');
    expect(container.read(instrumentSetProvider), InstrumentSet.viola);
    expect(find.byKey(const ValueKey('player_badge')), findsOneWidget);
    await tester.scrollUntilVisible(find.text("Theo's instrument"), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text("Theo's instrument"), findsOneWidget);
  });
}

class _BadgeBar extends StatelessWidget implements PreferredSizeWidget {
  const _BadgeBar();
  @override
  Size get preferredSize => const Size.fromHeight(56);
  @override
  Widget build(BuildContext context) =>
      AppBar(actions: const [PlayerBadge()]);
}
