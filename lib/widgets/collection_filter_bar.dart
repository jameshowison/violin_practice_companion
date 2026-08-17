import 'package:flutter/material.dart';

import '../models/piece_library.dart';

/// The horizontal "All / ●Suzuki 1 / ●This week" chip strip, shared by the piece
/// list and the Manage screen.
///
/// ## Why real `FilterChip`s and not hand-rolled ones
///
/// The retired `SectionBar` built its chips from a `GestureDetector` at
/// `EdgeInsets.symmetric(horizontal: 10, vertical: 2)` — about a 24pt touch
/// target. That was a defensible density trade for a strip crammed alongside
/// notation, and the wrong one here: this is the child's primary navigation
/// control. `FilterChip` also announces its selected state to screen readers
/// and picks up the correct M3 colour roles, neither of which a hand-rolled
/// chip does — so copying that density here would have been a false
/// consistency even while it existed.
///
/// A horizontal `ListView` rather than a `Wrap`, so any number of collections
/// scrolls instead of pushing the list down, and "All" (index 0) is always
/// visible at rest.
class CollectionFilterBar extends StatelessWidget {
  const CollectionFilterBar({
    super.key,
    required this.collections,
    required this.colors,
    required this.activeId,
    required this.onSelect,
    required this.keyPrefix,
    this.onCreate,
  });

  final List<Collection> collections;

  /// Collection ID → dot colour, from `CollectionPalette.colorsFor`.
  final Map<String, Color> colors;

  /// null selects the "All" chip.
  final String? activeId;

  final ValueChanged<String?> onSelect;

  /// Distinguishes the two screens' keys (`collection_chip` /
  /// `manage_collection_chip`) so a Marionette script can target one screen.
  final String keyPrefix;

  /// Non-null renders a trailing "＋ New" chip. The piece list passes null —
  /// creating collections is curation, and curation lives on Manage.
  final VoidCallback? onCreate;

  static const double height = 48;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _chip(
            context,
            key: ValueKey('${keyPrefix}_all'),
            label: 'All',
            selected: activeId == null,
            onSelected: (_) => onSelect(null),
          ),
          for (final c in collections) ...[
            const SizedBox(width: 8),
            _chip(
              context,
              key: ValueKey('$keyPrefix${'_'}${c.id}'),
              label: c.name,
              selected: activeId == c.id,
              dot: colors[c.id],
              // Tapping the selected chip clears the filter — otherwise the only
              // way back to All is to find the All chip, which may have scrolled
              // out of reach on a phone.
              onSelected: (_) => onSelect(activeId == c.id ? null : c.id),
            ),
          ],
          if (onCreate != null) ...[
            const SizedBox(width: 8),
            Center(
              child: ActionChip(
                key: ValueKey('${keyPrefix}_new'),
                avatar: Icon(Icons.add, size: 18, color: scheme.primary),
                label: const Text('New'),
                visualDensity: VisualDensity.compact,
                onPressed: onCreate,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context, {
    required Key key,
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
    Color? dot,
  }) =>
      Center(
        child: FilterChip(
          key: key,
          label: Text(label),
          selected: selected,
          // The dot already carries the collection's identity; a checkmark on
          // top of it just crowds a phone-width strip.
          showCheckmark: false,
          avatar: dot == null
              ? null
              : Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
          // Compact matches the SegmentedButton styling used elsewhere, but the
          // default tap target is kept: ~30pt of visual chip inside a 48pt band.
          visualDensity: VisualDensity.compact,
          onSelected: onSelected,
        ),
      );
}
