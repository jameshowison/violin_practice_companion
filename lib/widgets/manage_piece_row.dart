import 'package:flutter/material.dart';

import '../models/piece_library_view.dart';

/// One row of the Manage screen: drag handle, title, and three actions.
///
/// ## Why three inline buttons and not a `⋮` menu
///
/// A `PopupMenuButton` would be compact, but it is a widget class this codebase
/// has never used, and it would hide all three actions behind a tap on a screen
/// whose entire purpose is those three actions. Inline buttons cost width and
/// buy visibility — and, crucially, let the third icon *be* the bundled-vs-user
/// signal rather than needing a separate badge:
///
/// | origin | icon | colour | on tap |
/// |---|---|---|---|
/// | bundled, visible | `visibility_off_outlined` | `onSurfaceVariant` | immediate |
/// | bundled, hidden | `visibility_outlined` | `primary` | immediate |
/// | user piece | `delete_outline` | `colorScheme.error` | confirm dialog |
///
/// The error tint is load-bearing: it is the same signal as the delete-measure
/// FAB, so a parent who has used the measure editor already reads red-trash as
/// "gone forever" and grey-eye as "reversible".
///
/// The hide and delete buttons carry DISTINCT keys on purpose, so "does this
/// bundled piece offer Hide and not Delete?" is a key-existence assertion rather
/// than a pixel comparison.
class ManagePieceRow extends StatelessWidget {
  const ManagePieceRow({
    super.key,
    required this.row,
    required this.subtitle,
    required this.index,
    required this.showDragHandle,
    required this.labeledActions,
    required this.onTags,
    required this.onRename,
    required this.onHideOrDelete,
  });

  final LibraryRow row;
  final String subtitle;

  /// Position in the reorderable list; unused when [showDragHandle] is false.
  final int index;

  /// Handles appear only while a collection is filtered — "All" has a derived
  /// order with nowhere to store a hand-set position.
  final bool showDragHandle;

  final bool labeledActions;
  final VoidCallback onTags;
  final VoidCallback onRename;
  final VoidCallback onHideOrDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final id = row.piece.id;

    final (IconData, Color, String, String) lastAction;
    if (!row.isBundled) {
      lastAction = (Icons.delete_outline, scheme.error, 'Delete piece',
          'manage_delete_button_$id');
    } else if (row.hidden) {
      lastAction = (Icons.visibility_outlined, scheme.primary, 'Show in list',
          'manage_hide_button_$id');
    } else {
      lastAction = (Icons.visibility_off_outlined, scheme.onSurfaceVariant,
          'Hide from list', 'manage_hide_button_$id');
    }
    final (icon, color, tooltip, actionKey) = lastAction;

    final actions = <(IconData, Color?, String, String, VoidCallback)>[
      (Icons.sell_outlined, null, 'Collections', 'manage_tags_button_$id', onTags),
      (Icons.edit_outlined, null, 'Rename', 'manage_rename_button_$id', onRename),
      (icon, color, tooltip, actionKey, onHideOrDelete),
    ];

    // No key here: ReorderableListView requires the key on the widget IT is
    // handed, so the screen sets `ValueKey('manage_row_<id>')` on this widget.
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 8),
      child: Row(
        children: [
          if (showDragHandle)
            // ReorderableDragStartListener, not the Delayed variant: press and
            // move starts the drag at once, and only from the handle. With
            // ReorderableListView's defaults a long-press ANYWHERE on the tile
            // arms a drag, so a slightly slow tap on the delete button would
            // become one — and nothing on screen would say reordering exists.
            ReorderableDragStartListener(
              key: ValueKey('manage_drag_handle_$id'),
              index: index,
              child: SizedBox(
                width: 40,
                height: 48,
                child: Icon(Icons.drag_handle,
                    size: 20, color: scheme.onSurfaceVariant),
              ),
            )
          else
            const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    row.piece.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: row.hidden ? theme.disabledColor : null,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                  ),
                ],
              ),
            ),
          ),
          for (final (icon, color, label, key, onTap) in actions)
            if (labeledActions)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: TextButton.icon(
                  key: ValueKey(key),
                  onPressed: onTap,
                  icon: Icon(icon, size: 18),
                  label: Text(label),
                  style: TextButton.styleFrom(foregroundColor: color),
                ),
              )
            else
              IconButton(
                key: ValueKey(key),
                onPressed: onTap,
                icon: Icon(icon),
                color: color,
                tooltip: label,
                visualDensity: VisualDensity.compact,
              ),
        ],
      ),
    );
  }
}
