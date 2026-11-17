/// The ONE place the app's UI looks at which platform it is on. (Services'
/// `_io.dart` halves still check `Platform.is*` for capabilities, e.g.
/// `audio_decoder_io.dart`, `omr_service_io.dart`.)
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
    this.destructive = false,
  });

  final T value;
  final String label;

  /// Shown on Android, and as the trailing icon of an iOS context menu; an
  /// iOS action sheet is text.
  final IconData icon;
  final Key? key;

  /// Red, and by convention listed last: Delete, Hide.
  final bool destructive;
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
              isDestructiveAction: a.destructive,
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
              iconColor: a.destructive ? Theme.of(ctx).colorScheme.error : null,
              textColor: a.destructive ? Theme.of(ctx).colorScheme.error : null,
              onTap: () => Navigator.of(ctx).pop(a.value),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Press and hold on [child] for a short menu of [actions] about that one
/// thing (a piece, a keyword).
///
/// On Apple platforms this is the system context menu: the child lifts out as
/// a preview with the actions beneath. Elsewhere a long press opens the same
/// actions in a bottom sheet ([showAppActionSheet]) titled [title] — Material
/// has no lifted-preview menu, and a sheet is the familiar shape there.
///
/// [actions] is a builder so the menu reflects the item when it is opened.
/// When [enabled] is false the child is returned untouched, so a select mode
/// can have the press to itself.
///
/// [preview] dresses the lifted copy, which is drawn in the root overlay,
/// outside the list's own Material: give it a surface and corners.
class AppContextMenu<T> extends StatefulWidget {
  const AppContextMenu({
    super.key,
    required this.child,
    required this.actions,
    required this.onSelected,
    this.title,
    this.enabled = true,
    this.preview,
  });

  final Widget child;
  final List<AppSheetAction<T>> Function() actions;
  final void Function(T value) onSelected;
  final String? title;
  final bool enabled;
  final Widget Function(BuildContext context, Widget child)? preview;

  @override
  State<AppContextMenu<T>> createState() => _AppContextMenuState<T>();
}

class _AppContextMenuState<T> extends State<AppContextMenu<T>> {
  final _inPlace = GlobalKey();

  /// The size the item has in its list, for the lifted copy. The system menu
  /// lays its preview out against the whole screen, where a Column fills the
  /// height and a card's Spacer has nothing to divide; pinned to the size it
  /// had in place, it lifts out looking the same.
  Size? get _placedSize {
    final box = _inPlace.currentContext?.findRenderObject() as RenderBox?;
    return box != null && box.hasSize ? box.size : null;
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child;
    final actions = widget.actions;
    final onSelected = widget.onSelected;
    if (!widget.enabled) return child;
    if (isCupertino(context)) {
      final dress = widget.preview;
      return KeyedSubtree(
        key: _inPlace,
        child: CupertinoContextMenu.builder(
        actions: [
          for (final a in actions())
            CupertinoContextMenuAction(
              key: a.key,
              isDestructiveAction: a.destructive,
              trailingIcon: a.icon,
              onPressed: () {
                // The menu's route is pushed on the root navigator.
                Navigator.of(context, rootNavigator: true).pop();
                onSelected(a.value);
              },
              child: Text(a.label),
            ),
        ],
        builder: (ctx, animation) {
          final dressed = dress == null ? child : dress(ctx, child);
          // At rest (value 0) the child is in its list, sized by it. Lifted,
          // it keeps that size and is scaled to whatever box the menu's
          // press-and-grow animation gives it, as the default menu does.
          final size = animation.value > 0 ? _placedSize : null;
          return size == null
              ? dressed
              // A point of height slack: on the way back down a row measured
              // in place came out 0.19pt short and drew the overflow stripe.
              : FittedBox(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: size.width,
                      maxWidth: size.width,
                      minHeight: size.height,
                      maxHeight: size.height + 1,
                    ),
                    child: dressed,
                  ),
                );
        },
      ),
      );
    }
    return GestureDetector(
      onLongPress: () async {
        appSelectionHaptic();
        final choice = await showAppActionSheet<T>(context,
            title: widget.title, actions: actions());
        if (choice != null) onSelected(choice);
      },
      child: child,
    );
  }
}
