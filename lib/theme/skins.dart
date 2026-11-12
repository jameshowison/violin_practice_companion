import 'package:flutter/material.dart';

import 'app_skin.dart';
import 'skin_style.dart';

/// The [ThemeData] for [skin]. Everything a skin changes on every screen is
/// here; what only the piece list needs (row style, card colours, friendlier
/// words) rides along as the [SkinStyle] extension.
ThemeData themeFor(AppSkin skin) => switch (skin) {
      AppSkin.classic => classicTheme(),
      AppSkin.playful => playfulTheme(),
    };

/// iOS-flavoured Material: grouped grey behind white groups, a system-blue
/// accent, system type.
ThemeData classicTheme() {
  const accent = Color(0xFF0066D6);
  final scheme = ColorScheme.fromSeed(seedColor: accent).copyWith(
    primary: accent,
    onPrimary: Colors.white,
    surface: Colors.white,
    // The grouped background behind lists and the filter panel.
    surfaceContainerLow: const Color(0xFFF2F2F7),
    // Search and text fields.
    surfaceContainerHighest: const Color(0xFFE3E3E8),
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    // iOS-style segments: the chosen one in the accent's pale tint.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? const Color(0xFFE5F0FF) : null),
        foregroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? const Color(0xFF0057B8) : null),
      ),
    ),
    extensions: const [SkinStyle.classic],
  );
}

const _cream = Color(0xFFFFF8EC);
const _ink = Color(0xFF2B2340);
const _purple = Color(0xFF5B3FD6);
const _line = Color(0xFFD9CFBE);

/// Board 3 of the design canvas: warm cream, Nunito, a purple accent, rounder
/// and bordered shapes, colourful cards and friendlier words.
///
/// Every text style here is DERIVED from the geometry-merged text theme
/// (`copyWith`), never a bare `TextStyle(...)` or the raw `base.textTheme`. The theme animates when the skin changes, and
/// `TextStyle.lerp` asserts when one side is a full style (`inherit: false`,
/// as Material's typography is) and the other a partial one — which threw on
/// every switch and once left a red screen.
ThemeData playfulTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: _purple).copyWith(
    primary: _purple,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFEDE7FF),
    onPrimaryContainer: const Color(0xFF4129A8),
    surface: Colors.white,
    onSurface: _ink,
    onSurfaceVariant: const Color(0xFF5A516E),
    surfaceContainerLow: _cream,
    surfaceContainerHighest: Colors.white,
    outline: _line,
    outlineVariant: const Color(0xFFE8DFCF),
  );

  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'Nunito',
  );
  // Nunito reads light at Material's default weights; the kid look is bold.
  // Two views of the same type, because the skin switch animates at two
  // levels and TextStyle.lerp needs matching `inherit` at each:
  //  - [raw] becomes ThemeData.textTheme, which AnimatedTheme lerps against
  //    Classic's equally raw one (partial styles, `inherit: true`);
  //  - [text], merged onto the English geometry as Theme.of's localize step
  //    does, is what the component themes below take their styles from.
  //    Those lerp against the FULL defaults (`inherit: false`) a Classic
  //    widget resolves when its component theme leaves the style null.
  final raw = base.textTheme.apply(bodyColor: _ink, displayColor: _ink);
  final text = Typography.englishLike2021.merge(raw);
  TextStyle? heavier(TextStyle? s, FontWeight w) => s?.copyWith(fontWeight: w);

  const pill = StadiumBorder();
  final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(18));

  return base.copyWith(
    scaffoldBackgroundColor: _cream,
    textTheme: raw.copyWith(
      headlineSmall: heavier(raw.headlineSmall, FontWeight.w900),
      titleLarge: heavier(raw.titleLarge, FontWeight.w900),
      titleMedium: heavier(raw.titleMedium, FontWeight.w800),
      titleSmall: heavier(raw.titleSmall, FontWeight.w800),
      bodyLarge: heavier(raw.bodyLarge, FontWeight.w700),
      bodyMedium: heavier(raw.bodyMedium, FontWeight.w600),
      bodySmall: heavier(raw.bodySmall, FontWeight.w600),
      labelLarge: heavier(raw.labelLarge, FontWeight.w800),
      labelMedium: heavier(raw.labelMedium, FontWeight.w800),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: _cream,
      foregroundColor: _ink,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w900),
    ),
    chipTheme: ChipThemeData(
      shape: pill,
      side: const BorderSide(color: _line, width: 2),
      backgroundColor: Colors.white,
      selectedColor: _purple,
      secondarySelectedColor: _purple,
      checkmarkColor: Colors.white,
      labelStyle: text.labelLarge!.copyWith(fontWeight: FontWeight.w800, color: _ink),
      secondaryLabelStyle:
          text.labelLarge!.copyWith(fontWeight: FontWeight.w800, color: Colors.white),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
        shape: WidgetStatePropertyAll(rounded),
        side: const WidgetStatePropertyAll(BorderSide(color: _line, width: 2)),
        textStyle: WidgetStatePropertyAll(text.labelLarge!
            .copyWith(fontWeight: FontWeight.w900, fontSize: 16)),
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? _purple : Colors.white),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? Colors.white : _ink),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: pill,
        minimumSize: const Size(0, 48),
        textStyle: text.labelLarge!
            .copyWith(fontWeight: FontWeight.w800, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: pill,
        side: const BorderSide(color: _line, width: 2),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: _line, width: 2),
      ),
    ),
    cardTheme: CardThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: text.bodyLarge!
          .copyWith(fontWeight: FontWeight.w800, fontSize: 16, color: _ink),
    ),
    extensions: const [playfulSkinStyle],
  );
}

const playfulSkinStyle = SkinStyle(
  rowStyle: PieceRowStyle.cards,
  cardColors: [
    Color(0xFFFFD166),
    Color(0xFF8BD3C7),
    Color(0xFFF7B2C1),
    Color(0xFFB5CBFF),
    Color(0xFFC8E89F),
    Color(0xFFFFC49B),
  ],
  cardInk: _ink,
  friendlyCopy: true,
  groupRadius: 20,
);
