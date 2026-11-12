import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/piece_list_screen.dart';
import 'theme/app_skin.dart';
import 'theme/skins.dart';

class ViolinPracticeApp extends ConsumerWidget {
  const ViolinPracticeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Violin Practice Companion',
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en'),
        Locale('zh'),
      ],
      // Settings ▸ Appearance. Switching rebuilds the theme only; every
      // screen's state (filters, the open piece) survives it.
      theme: themeFor(ref.watch(appSkinProvider)),
      home: const PieceListScreen(),
    );
  }
}
