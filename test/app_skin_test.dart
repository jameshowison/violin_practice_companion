import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/screens/settings_screen.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';
import 'package:violin_practice_companion/theme/app_skin.dart';
import 'package:violin_practice_companion/theme/skin_style.dart';
import 'package:violin_practice_companion/theme/skins.dart';

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

  test('defaults to Classic and writes nothing until changed', () async {
    final c = await containerWith({});
    expect(c.read(appSkinProvider), AppSkin.classic);
    expect(prefs.getString(appSkinKey), isNull);
  });

  test('a change is saved and read back synchronously', () async {
    final c = await containerWith({});
    c.read(appSkinProvider.notifier).state = AppSkin.playful;
    await Future<void>.delayed(Duration.zero);
    expect(prefs.getString(appSkinKey), 'playful');

    final again = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(again.dispose);
    expect(again.read(appSkinProvider), AppSkin.playful);
  });

  test('an unknown stored value falls back to Classic', () async {
    final c = await containerWith({'flutter.$appSkinKey': 'neon'});
    expect(c.read(appSkinProvider), AppSkin.classic);
  });

  test('without prefs it lasts for the session', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(appSkinProvider.notifier).state = AppSkin.playful;
    expect(c.read(appSkinProvider), AppSkin.playful);
  });

  test('each theme carries its skin style', () {
    expect(classicTheme().extension<SkinStyle>()!.rowStyle, PieceRowStyle.list);
    final playful = playfulTheme();
    expect(playful.extension<SkinStyle>()!.rowStyle, PieceRowStyle.cards);
    expect(playful.extension<SkinStyle>()!.listTitle, 'What shall we play?');
    expect(playful.textTheme.bodyLarge!.fontFamily, 'Nunito');
    expect(playful.colorScheme.primary, const Color(0xFF5B3FD6));
  });

  test('card text keeps 4.5:1 contrast on every card colour', () {
    final style = playfulTheme().extension<SkinStyle>()!;
    double lum(Color c) => c.computeLuminance();
    for (final bg in style.cardColors) {
      final a = lum(bg), b = lum(style.cardInk);
      final ratio = (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
      expect(ratio, greaterThanOrEqualTo(4.5), reason: '$bg');
    }
  });

  // Regression: the theme animates on a switch, and a partial TextStyle in
  // one skin against Material's full ones in the other made TextStyle.lerp
  // assert on every switch (and once leave a red screen).
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('switching skins animates cleanly on ${platform.name}',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final sp = await SharedPreferences.getInstance();
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(sp)],
        child: Consumer(
          builder: (_, ref, _) => MaterialApp(
            theme: themeFor(ref.watch(appSkinProvider)).copyWith(platform: platform),
            home: const SettingsScreen(),
          ),
        ),
      ));

      for (final to in ['playful', 'classic', 'playful']) {
        await tester.tap(find.byKey(ValueKey('skin_setting_$to')));
        await tester.pump(const Duration(milliseconds: 50)); // mid-animation
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'to $to');
      }
      expect(sp.getString(appSkinKey), 'playful');
    });
  }
}
