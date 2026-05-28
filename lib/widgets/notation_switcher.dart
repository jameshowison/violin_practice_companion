import 'package:flutter/material.dart';
import '../models/note_event.dart';

class NotationSwitcher extends StatelessWidget {
  final DisplayMode current;
  final ValueChanged<DisplayMode> onChanged;

  const NotationSwitcher({
    super.key,
    required this.current,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<DisplayMode>(
      segments: const [
        ButtonSegment(
          value: DisplayMode.staff,
          label: Text('Staff'),
          icon: Icon(Icons.music_note),
        ),
        ButtonSegment(
          value: DisplayMode.staffFingering,
          label: Text('Ann.'),
          icon: Icon(Icons.queue_music),
        ),
        ButtonSegment(
          value: DisplayMode.jianpu,
          label: Text('Jianpu'),
          icon: Icon(Icons.format_list_numbered),
        ),
        ButtonSegment(
          value: DisplayMode.fingering,
          label: Text('Finger'),
          icon: Icon(Icons.back_hand),
        ),
        ButtonSegment(
          value: DisplayMode.combined,
          label: Text('+'),
          icon: Icon(Icons.layers),
        ),
      ],
      selected: {current},
      onSelectionChanged: (set) => onChanged(set.first),
    );
  }
}
