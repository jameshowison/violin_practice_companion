/// The ONE place the app looks at which platform it is on.
///
/// Screens call these wrappers instead of branching themselves, so every
/// iOS-versus-Android difference is here, auditable in one file. The rule
/// (CLAUDE.md, "Multi-Platform Posture"): no platform checks outside
/// `lib/ui/adaptive/`.
///
/// The platform comes from [Theme.of]`(context).platform`, never `dart:io`'s
/// `Platform`: that keeps this file web-safe, and lets a test or a golden
/// render either platform by setting `ThemeData(platform: …)`.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Whether to use Apple conventions here: iOS and macOS.
bool isCupertino(BuildContext context) => switch (Theme.of(context).platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => true,
      _ => false,
    };

// Page transitions need nothing here: Material's default
// PageTransitionsTheme already uses CupertinoPageTransitionsBuilder (slide,
// edge-swipe back) on iOS and macOS, and predictive back on Android.

/// A light tick for a selection change (a filter picked, a tab switched).
/// A no-op where the platform has no haptics.
void appSelectionHaptic() => HapticFeedback.selectionClick();

/// One choice in [showAppActionSheet].
class AppSheetAction<T> {
  const AppSheetAction({
    required this.value,
    required this.label,
    required this.icon,
    this.key,
  });

  final T value;
  final String label;

  /// Shown on Android only; an iOS action sheet is text.
  final IconData icon;
  final Key? key;
}

/// A short menu of actions: a Cupertino action sheet on Apple platforms, a
/// Material bottom sheet elsewhere. Resolves to the chosen [AppSheetAction.value],
/// or null if dismissed.
Future<T?> showAppActionSheet<T>(
  BuildContext context, {
  required List<AppSheetAction<T>> actions,
  String? title,
}) {
  if (isCupertino(context)) {
    return showCupertinoModalPopup<T>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: title == null ? null : Text(title),
        actions: [
          for (final a in actions)
            CupertinoActionSheetAction(
              key: a.key,
              onPressed: () => Navigator.of(ctx).pop(a.value),
              child: Text(a.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
            ),
          for (final a in actions)
            ListTile(
              key: a.key,
              leading: Icon(a.icon),
              title: Text(a.label),
              onTap: () => Navigator.of(ctx).pop(a.value),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
