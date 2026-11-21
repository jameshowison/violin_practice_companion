import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_mode.dart';
import '../services/providers.dart';
import '../services/staff_zoom.dart';

/// Whether [mode] is one the size and layout menu speaks for: the engraved
/// staff views. Jianpu and the fingering views lay out by their own rows.
bool staffViewMenuAppliesTo(DisplayMode mode) =>
    mode == DisplayMode.staff ||
    mode == DisplayMode.staffFingering ||
    mode == DisplayMode.tab;

/// The piece screen's "how the score looks" button: a magnifier in the app bar
/// that opens a small panel of three modes ([StaffViewMode]): Fit whole piece;
/// Custom, with its size (Small, Medium, Large) and layout (Flowing,
/// Sections); and, for a scan, Like original scan.
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
    final heading = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final viewMode = ref.watch(effectiveStaffViewModeProvider);
    void choose(StaffViewMode m) =>
        ref.read(staffViewModeProvider.notifier).state = m;

    // Tab has no section or printed-page layout (its xml is never broken by
    // section — see [staffBySectionProvider]), so it gets Fit and a size.
    final sectionsPossible =
        mode != DisplayMode.tab && ref.watch(sectionLayoutAvailableProvider);
    final originalOffered =
        mode != DisplayMode.tab && ref.watch(printedLayoutAvailableProvider);
    final size = ref.watch(customStaffSizeProvider);
    final sections = ref.watch(sectionLayoutProvider);

    return SizedBox(
      width: _panelWidth,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: RadioGroup<StaffViewMode>(
          groupValue: viewMode,
          onChanged: (m) {
            if (m != null) choose(m);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ModeGroup(
                mode: StaffViewMode.fit,
                chosen: viewMode,
                onChoose: choose,
                caption: ref.watch(fitTooLongProvider) &&
                        viewMode == StaffViewMode.fit
                    ? 'Too long for one screen: smallest readable size, '
                        'and it scrolls.'
                    : 'The biggest notes that keep it all on one screen.',
              ),
              const Divider(height: 9, indent: 10, endIndent: 10),
              _ModeGroup(
                mode: StaffViewMode.custom,
                chosen: viewMode,
                onChoose: choose,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Size', style: heading),
                    const SizedBox(height: 6),
                    SegmentedButton<StaffSize>(
                      key: const ValueKey('staff_size_fixed'),
                      showSelectedIcon: false,
                      segments: [
                        for (final s in const [
                          StaffSize.small,
                          StaffSize.medium,
                          StaffSize.large,
                        ])
                          ButtonSegment(value: s, label: Text(s.label)),
                      ],
                      selected: {size == StaffSize.fit ? StaffSize.medium : size},
                      // A size is a Custom setting: picking one picks Custom.
                      onSelectionChanged: (v) {
                        ref.read(customStaffSizeProvider.notifier).state =
                            v.first;
                        choose(StaffViewMode.custom);
                      },
                    ),
                    if (sectionsPossible) ...[
                      const SizedBox(height: 10),
                      Text('Layout', style: heading),
                      const SizedBox(height: 6),
                      SegmentedButton<bool>(
                        key: const ValueKey('staff_layout'),
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: false, label: Text('Flowing')),
                          ButtonSegment(value: true, label: Text('Sections')),
                        ],
                        selected: {sections},
                        onSelectionChanged: (v) {
                          ref.read(sectionLayoutProvider.notifier).state =
                              v.first;
                          choose(StaffViewMode.custom);
                        },
                      ),
                    ],
                  ],
                ),
              ),
              if (originalOffered) ...[
                const Divider(height: 9, indent: 10, endIndent: 10),
                _ModeGroup(
                  mode: StaffViewMode.original,
                  chosen: viewMode,
                  onChoose: choose,
                  caption: "The scanned page's own lines; the widest sets "
                      'the size.',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the panel's three modes: a radio heading, and under it a caption or
/// the mode's own controls. The modes not chosen stay in view, dimmed, so the
/// reader can see what they would go back to; a tap anywhere on one chooses it.
class _ModeGroup extends StatelessWidget {
  const _ModeGroup({
    required this.mode,
    required this.chosen,
    required this.onChoose,
    this.caption,
    this.child,
  });

  final StaffViewMode mode;
  final StaffViewMode chosen;
  final ValueChanged<StaffViewMode> onChoose;
  final String? caption;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = mode == chosen;
    final caption = this.caption;
    final child = this.child;
    return Material(
      key: ValueKey('staff_mode_${mode.name}'),
      color: on
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: on ? null : () => onChoose(mode),
        child: AnimatedOpacity(
          opacity: on ? 1 : 0.55,
          duration: const Duration(milliseconds: 150),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Radio<StaffViewMode>(value: mode),
                    Expanded(
                      child: Text(
                        mode.label,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
                if (caption != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(caption, style: theme.textTheme.bodySmall),
                  ),
                if (child != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: child,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
