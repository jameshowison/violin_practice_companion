import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/abc_exporter.dart';

/// Shows the ABC notation for one piece, with a single button that puts the
/// whole tune on the clipboard.
Future<void> showAbcExportDialog(
  BuildContext context, {
  required String title,
  required String abc,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => AbcExportDialog(title: title, abc: abc),
    );

/// A read-only view of a piece's exported ABC.
///
/// ## Why one Copy button and not "select the text yourself"
///
/// The text IS selectable — but hand-selecting forty lines of monospace inside a
/// scrolling dialog on a phone is a fight, and the only realistic thing anyone
/// wants to do with this screen is take *all* of it somewhere else. So the
/// button copies the whole document in one tap and the drag-select is left in
/// place for the rare partial grab.
///
/// The confirmation lives on the button rather than in a `SnackBar`, because a
/// SnackBar is rendered by the [ScaffoldMessenger] *under* this dialog's route
/// and would be hidden by the modal barrier.
class AbcExportDialog extends StatefulWidget {
  const AbcExportDialog({super.key, required this.title, required this.abc});

  final String title;
  final String abc;

  @override
  State<AbcExportDialog> createState() => _AbcExportDialogState();
}

class _AbcExportDialogState extends State<AbcExportDialog> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.abc));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: const Text('ABC notation'),
      // Cap the height so a long tune scrolls inside the box instead of pushing
      // the buttons off a phone in landscape, and the width so a wide iPad
      // doesn't stretch monospace lines across the whole screen — but take the
      // smaller of each and the viewport, so the caps never become a minimum on
      // a small screen.
      content: SizedBox(
        width: math.min(520, screen.width * 0.9),
        height: math.min(340, screen.height * 0.5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(8),
                    child: SelectableText(
                      widget.abc,
                      key: const ValueKey('abc_export_text'),
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12, height: 1.4),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AbcExporter.lossyFeatureNote,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('abc_export_close_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          key: const ValueKey('abc_export_copy_button'),
          onPressed: _copy,
          icon: Icon(_copied ? Icons.check : Icons.copy_all_outlined, size: 18),
          label: Text(_copied ? 'Copied' : 'Copy all'),
        ),
      ],
    );
  }
}
