import 'package:flutter/material.dart';
import '../models/note_event.dart';

/// The view picker, as a wrapping row of chips.
///
/// It lives in the settings tray now rather than on a strip above the score, so
/// it has a drawer's width to work in and not a tablet's — a six-segment
/// [SegmentedButton] can't fit there, but chips reflow onto as many lines as
/// they need. Labels are spelled out for the same reason: "Ann." only ever made
/// sense as an abbreviation forced by the old strip.
class NotationSwitcher extends StatelessWidget {
  final DisplayMode current;
  final ValueChanged<DisplayMode> onChanged;

  const NotationSwitcher({
    super.key,
    required this.current,
    required this.onChanged,
  });

  static const _modes = [
    (DisplayMode.staff, Icons.music_note, 'Staff'),
    (DisplayMode.staffFingering, Icons.queue_music, 'Annotated'),
    (DisplayMode.jianpu, Icons.format_list_numbered, 'Jianpu'),
    (DisplayMode.fingering, Icons.back_hand, 'Fingering'),
    (DisplayMode.combined, Icons.layers, 'Combined'),
    (DisplayMode.tab, Icons.grid_4x4, 'Tab'),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final (mode, icon, label) in _modes)
          ChoiceChip(
            avatar: Icon(icon, size: 16),
            // The avatar carries the identity; the tick would displace it.
            showCheckmark: false,
            label: Text(label),
            labelStyle: const TextStyle(fontSize: 12),
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            selected: current == mode,
            onSelected: (_) => onChanged(mode),
          ),
      ],
    );
  }
}
