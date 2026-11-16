/// Swipe actions on a list row, Apple-style: drag the row sideways to reveal
/// a button, then tap it. On other platforms rows don't swipe (it is rare on
/// Android), and the same actions are reached by press and hold.
///
/// Part of `lib/ui/adaptive/`, the only place that branches on platform.
library;

import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import 'adaptive.dart';

/// One button revealed by a swipe.
class SwipeAction {
  const SwipeAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.key,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;
  final Key? key;
}

/// Wraps a row with a [leading] action (swipe right) and a [trailing] one
/// (swipe left, where Delete belongs).
///
/// A full swipe never acts by itself: the row opens to show the button, and
/// the button has to be tapped. A child's stray swipe can't delete anything,
/// and the delete still asks first. Put rows that should close each other
/// under one [AppSwipeGroup].
class AppSwipeActions extends StatelessWidget {
  const AppSwipeActions({
    super.key,
    required this.child,
    this.leading,
    this.trailing,
    this.enabled = true,
  });

  final Widget child;
  final SwipeAction? leading;
  final SwipeAction? trailing;
  final bool enabled;

  static const _extent = 84.0;

  @override
  Widget build(BuildContext context) {
    if (!enabled || !isCupertino(context)) return child;
    return LayoutBuilder(builder: (context, c) {
      final ratio = (_extent / c.maxWidth).clamp(0.15, 0.5);
      ActionPane? pane(SwipeAction? a) => a == null
          ? null
          : ActionPane(
              motion: const DrawerMotion(),
              extentRatio: ratio,
              children: [
                SlidableAction(
                  key: a.key,
                  onPressed: (_) => a.onPressed(),
                  backgroundColor: a.color,
                  foregroundColor: Colors.white,
                  icon: a.icon,
                  label: a.label,
                ),
              ],
            );
      return Slidable(
        groupTag: AppSwipeGroup.tag,
        startActionPane: pane(leading),
        endActionPane: pane(trailing),
        child: child,
      );
    });
  }
}

/// Opening one row's actions closes any other row's, and so does tapping
/// elsewhere in the list.
class AppSwipeGroup extends StatelessWidget {
  const AppSwipeGroup({super.key, required this.child});

  final Widget child;

  static const tag = 'app_swipe_group';

  @override
  Widget build(BuildContext context) => isCupertino(context)
      ? SlidableAutoCloseBehavior(child: child)
      : child;
}
