import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'debug/screenshot_mode.dart';
import 'models/app_edition.dart';
import 'screens/piece_list_screen.dart';
import 'theme/app_skin.dart';
import 'theme/skins.dart';
import 'ui/splash/launch_splash.dart';
import 'widgets/incoming_share_handler.dart';

class ViolinPracticeApp extends ConsumerWidget {
  const ViolinPracticeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: ref.watch(appEditionProvider).appName,
      debugShowCheckedModeBanner: kShowDevChrome,
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
      navigatorKey: appNavigatorKey,
      home: const PieceListScreen(),
      // Above the Navigator, so the blink covers the whole first screen. The
      // share handler too, so a piece AirDropped in while any screen is up
      // can be imported and opened.
      builder: (context, child) =>
          IncomingShareHandler(child: LaunchSplash(child: child!)),
    );
  }
}
