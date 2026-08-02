/// The three dialog shapes the library screens share.
///
/// Extracted so the piece list and the Manage screen can't drift apart on the
/// wording or the button treatment of a destructive action. Each one is the
/// established in-app pattern, generalised rather than invented:
/// [showTextEntryDialog] from `_editSectionMarker` in `edit_measure_screen.dart`
/// and [confirmDestructive] from `_confirmAndDelete` in
/// `piece_detail_screen.dart`.
library;

import 'package:flutter/material.dart';

/// A prefilled single-field dialog. Returns the trimmed text, or null if the
/// user cancelled — an empty result is never returned, so callers needn't
/// distinguish "cleared" from "cancelled".
Future<String?> showTextEntryDialog(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String saveLabel = 'Save',
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _TextEntryDialog(
      title: title,
      label: label,
      initial: initial,
      saveLabel: saveLabel,
    ),
  );
  return (result == null || result.isEmpty) ? null : result;
}

/// A StatefulWidget purely so the [TextEditingController] outlives the dialog's
/// exit animation.
///
/// Disposing it right after `showDialog` returns looks equivalent and is not:
/// the route is still animating out, the `TextField` still rebuilds during that,
/// and it throws "A TextEditingController was used after being disposed" —
/// which then cascades into a framework assertion and a red screen.
class _TextEntryDialog extends StatefulWidget {
  const _TextEntryDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.saveLabel,
  });

  final String title;
  final String label;
  final String initial;
  final String saveLabel;

  @override
  State<_TextEntryDialog> createState() => _TextEntryDialogState();
}

class _TextEntryDialogState extends State<_TextEntryDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          key: const ValueKey('text_entry_field'),
          controller: _controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: widget.label),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            key: const ValueKey('text_entry_cancel'),
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('text_entry_save'),
            onPressed: () =>
                Navigator.pop(context, _controller.text.trim()),
            child: Text(widget.saveLabel),
          ),
        ],
      );
}

/// The house confirm for anything irreversible: an error-tinted confirm button
/// and body copy that ends by saying so. There is no undo anywhere in this app,
/// which is exactly why the dialog has to carry the weight.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String body,
  String confirmLabel = 'Delete',
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          key: const ValueKey('destructive_cancel_button'),
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('destructive_confirm_button'),
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

Future<void> showErrorDialog(
  BuildContext context, {
  required String title,
  required Object error,
}) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text('$error'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
