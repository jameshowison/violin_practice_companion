import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/note_event.dart';
import '../services/providers.dart';
import '../services/staff_zoom.dart';

/// Whether [mode] is one the size and layout menu speaks for: the engraved
/// staff views. Jianpu and the fingering views lay out by their own rows.
bool staffViewMenuAppliesTo(DisplayMode mode) =>
    mode == DisplayMode.staff ||
    mode == DisplayMode.staffFingering ||
    mode == DisplayMode.tab;

/// The piece screen's "how the score looks" button: a magnifier in the app bar
/// that opens a small panel with the note size (Fit whole piece, or Small,
/// Medium, Large) and the layout (Flowing, Sections, Page).
///
/// The panel is non-modal: no barrier, and taps inside it don't close it, so
/// the score re-engraves underneath as each choice is made and the reader can
/// see the result before deciding. A tap anywhere outside closes it (and still
/// reaches what was tapped), as does the button again.
class StaffViewMenuButton extends StatefulWidget {
  const StaffViewMenuButton({super.key, required this.mode});

  final DisplayMode mode;

  @override
  State<StaffViewMenuButton> createState() => _StaffViewMenuButtonState();
}

/// Panel width: fits inside an SE's 375pt with [_edgeMargin] either side.
const double _panelWidth = 300;

/// Gap kept between the panel and the screen's edge. The menu only clamps the
/// panel to the screen, which leaves it flush, so the offset is worked out
/// from where the button is when it opens.
const double _edgeMargin = 8;

class _StaffViewMenuButtonState extends State<StaffViewMenuButton> {
  Offset _offset = const Offset(0, 4);

  void _open(MenuController controller, BuildContext buttonContext) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      final left = box.localToGlobal(Offset.zero).dx;
      final screenWidth = MediaQuery.sizeOf(buttonContext).width;
      final dx = screenWidth - _edgeMargin - _panelWidth - left;
      setState(() => _offset = Offset(dx < 0 ? dx : 0, 4));
    }
    controller.open();
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      alignmentOffset: _offset,
      style: const MenuStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      menuChildren: [_StaffViewPanel(mode: widget.mode)],
      builder: (context, controller, _) => IconButton(
        key: const ValueKey('staff_view_menu_button'),
        tooltip: 'Size and layout',
        isSelected: controller.isOpen,
        icon: const Icon(Icons.zoom_in),
        onPressed: () => controller.isOpen
            ? controller.close()
            : _open(controller, context),
      ),
    );
  }
}

class _StaffViewPanel extends ConsumerWidget {
  const _StaffViewPanel({required this.mode});

  final DisplayMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall;
    final heading = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final size = ref.watch(staffSizeProvider);
    void setSize(StaffSize s) => ref.read(staffSizeProvider.notifier).state = s;

    // Tab has no section or printed-page layout (its xml is never broken by
    // section — see [staffBySectionProvider]), so it gets the sizes alone.
    final layouts = mode == DisplayMode.tab
        ? const <StaffLayout>[]
        : [
            StaffLayout.flowing,
            if (ref.watch(sectionLayoutAvailableProvider)) StaffLayout.sections,
            if (ref.watch(printedLayoutAvailableProvider)) StaffLayout.page,
          ];
    final layout = ref.watch(staffLayoutProvider);
    // Page keeps the printed lines exactly, so the widest one sets the size.
    final sizeFixed = layout == StaffLayout.page;

    return SizedBox(
      width: _panelWidth,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Size', style: heading),
            const SizedBox(height: 6),
            // Fit stands apart from the three fixed sizes: it is worked out per
            // piece, so it isn't a step on the Small–Large scale.
            SegmentedButton<StaffSize>(
              key: const ValueKey('staff_size_fit'),
              showSelectedIcon: false,
              emptySelectionAllowed: true,
              segments: const [
                ButtonSegment(
                  value: StaffSize.fit,
                  label: Text('Fit whole piece'),
                  icon: Icon(Icons.fit_screen_outlined),
                ),
              ],
              selected: {if (size == StaffSize.fit) StaffSize.fit},
              onSelectionChanged:
                  sizeFixed ? null : (_) => setSize(StaffSize.fit),
            ),
            const SizedBox(height: 6),
            SegmentedButton<StaffSize>(
              key: const ValueKey('staff_size_fixed'),
              showSelectedIcon: false,
              emptySelectionAllowed: true,
              segments: [
                for (final s in const [
                  StaffSize.small,
                  StaffSize.medium,
                  StaffSize.large,
                ])
                  ButtonSegment(value: s, label: Text(s.label)),
              ],
              selected: {if (size != StaffSize.fit) size},
              onSelectionChanged: sizeFixed
                  ? null
                  : (v) {
                      if (v.isNotEmpty) setSize(v.first);
                    },
            ),
            if (layouts.length > 1) ...[
              const SizedBox(height: 14),
              Text('Layout', style: heading),
              const SizedBox(height: 6),
              SegmentedButton<StaffLayout>(
                key: const ValueKey('staff_layout'),
                showSelectedIcon: false,
                segments: [
                  for (final l in layouts)
                    ButtonSegment(value: l, label: Text(l.label)),
                ],
                selected: {layout},
                onSelectionChanged: (v) => setStaffLayout(ref, v.first),
              ),
              const SizedBox(height: 6),
              Text(switch (layout) {
                StaffLayout.flowing => 'Bars run on from line to line.',
                StaffLayout.sections => 'Each section starts a new line.',
                StaffLayout.page => 'The lines as printed in the original: '
                    'the widest one sets the size.',
              }, style: caption),
            ],
          ],
        ),
      ),
    );
  }
}
