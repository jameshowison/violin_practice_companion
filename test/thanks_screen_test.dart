import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/screens/settings_screen.dart';
import 'package:violin_practice_companion/services/bundled_licenses.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';

void main() {
  testWidgets('Settings opens with Thanks at the top, which links GitHub, '
      'thanks homr and reaches the licence page', (tester) async {
    tester.view.physicalSize = const Size(375 * 3, 667 * 3); // dev-iphone-se
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final sp = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(sp)],
      child: const MaterialApp(home: SettingsScreen()),
    ));

    final entry = find.byKey(const ValueKey('thanks_entry'));
    expect(entry, findsOneWidget);
    expect(tester.getTopLeft(entry).dy,
        lessThan(tester.getTopLeft(find.text('Appearance')).dy));

    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('thanks_github')), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('thanks_homr')), 200);
    expect(find.text('A special thank-you to homr'), findsOneWidget);
    expect(find.byKey(const ValueKey('thanks_homr')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('thanks_licenses')), 200);
    await tester.tap(find.byKey(const ValueKey('thanks_licenses')));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });

  test('every bundled licence exists and is declared as an asset', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final (packages, asset) in bundledLicenseAssets) {
      expect(File(asset).existsSync(), isTrue, reason: '$packages: $asset');
      final dir = asset.substring(0, asset.lastIndexOf('/') + 1);
      expect(pubspec.contains('- $asset') || pubspec.contains('- $dir\n'),
          isTrue, reason: '$asset is not in pubspec.yaml assets');
    }
  });

  test('the licence registry carries Stringlings, homr and the bundled JS',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerBundledLicenses();
    final names = <String>{};
    await for (final e in LicenseRegistry.licenses) {
      names.addAll(e.packages);
    }
    expect(names, containsAll(['Stringlings', 'homr', 'OpenSheetMusicDisplay',
        'abcjs', 'GeneralUser GS', 'Nunito']));
  });
}
