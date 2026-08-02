import 'package:flutter/material.dart';

/// One selectable row.
typedef PickerItem = ({String id, String label, Color? dot});

/// A buffered multi-select dialog: check several rows, one Save.
///
/// Buffered rather than write-per-checkbox so a whole re-tagging is one write,
/// one invalidate and no flicker — and so Cancel means something. The tri-state
/// return mirrors `_editSectionMarker` in `edit_measure_screen.dart`: null is
/// cancelled, a set (possibly empty) is the new selection.
///
/// `CheckboxListTile` is the sibling of the `SwitchListTile` already used in the
/// detail drawer, so this is barely a new convention — multi-select simply needs
/// a checkbox rather than a switch.
class CheckboxPickerDialog extends StatefulWidget {
  const CheckboxPickerDialog({
    super.key,
    required this.title,
    required this.items,
    required this.initiallySelected,
    required this.keyPrefix,
    this.subtitle,
    this.createLabel,
    this.onCreate,
    this.emptyMessage = 'Nothing to choose from yet.',
  });

  final String title;
  final String? subtitle;
  final List<PickerItem> items;
  final Set<String> initiallySelected;

  /// Namespaces the per-row keys, e.g. `collection_checkbox_<id>`.
  final String keyPrefix;

  /// Non-null adds a trailing create row. [onCreate] returns the new item (and
  /// it arrives already checked — that is why you created it), or null if the
  /// user backed out.
  final String? createLabel;
  final Future<PickerItem?> Function()? onCreate;

  final String emptyMessage;

  @override
  State<CheckboxPickerDialog> createState() => _CheckboxPickerDialogState();
}

class _CheckboxPickerDialogState extends State<CheckboxPickerDialog> {
  late final Set<String> _selected = {...widget.initiallySelected};
  late List<PickerItem> _items = [...widget.items];

  Future<void> _create() async {
    final created = await widget.onCreate!();
    if (created == null || !mounted) return;
    setState(() {
      _items = [..._items, created];
      _selected.add(created.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.title),
          if (widget.subtitle != null)
            Text(widget.subtitle!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor)),
        ],
      ),
      // No width is set: AlertDialog sizes to its content and the platform caps
      // it, so this survives a phone viewport. Only the HEIGHT is bounded, so a
      // long list scrolls rather than overflowing a landscape phone with the
      // keyboard up.
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(widget.emptyMessage,
                      style: TextStyle(color: theme.hintColor)),
                ),
              for (final item in _items)
                CheckboxListTile(
                  key: ValueKey('${widget.keyPrefix}_${item.id}'),
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  value: _selected.contains(item.id),
                  title: Text(item.label,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  secondary: item.dot == null
                      ? null
                      : Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: item.dot, shape: BoxShape.circle),
                        ),
                  onChanged: (checked) => setState(() => checked == true
                      ? _selected.add(item.id)
                      : _selected.remove(item.id)),
                ),
              if (widget.onCreate != null) ...[
                const Divider(height: 1),
                ListTile(
                  key: ValueKey('${widget.keyPrefix}_new'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.add),
                  title: Text(widget.createLabel ?? 'New…'),
                  onTap: _create,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: ValueKey('${widget.keyPrefix}_cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: ValueKey('${widget.keyPrefix}_save'),
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Shows [CheckboxPickerDialog]. Null means cancelled.
Future<Set<String>?> showCheckboxPicker(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<PickerItem> items,
  required Set<String> initiallySelected,
  required String keyPrefix,
  String? createLabel,
  Future<PickerItem?> Function()? onCreate,
  String emptyMessage = 'Nothing to choose from yet.',
}) =>
    showDialog<Set<String>>(
      context: context,
      builder: (_) => CheckboxPickerDialog(
        title: title,
        subtitle: subtitle,
        items: items,
        initiallySelected: initiallySelected,
        keyPrefix: keyPrefix,
        createLabel: createLabel,
        onCreate: onCreate,
        emptyMessage: emptyMessage,
      ),
    );
