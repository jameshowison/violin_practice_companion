import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/support_level.dart';
import '../services/practice_mode.dart';
import '../services/providers.dart' show displayModeProvider;

/// What each step is called on the practice bar.
String supportLevelLabel(SupportLevel level) => switch (level) {
      SupportLevel.full => 'Full',
      SupportLevel.letters => 'Letters',
      SupportLevel.staff => 'Staff',
      SupportLevel.bowings => 'Bowings',
      SupportLevel.dimmed => 'Dimmed',
      SupportLevel.black => 'Black',
    };

/// Practice mode's strip above the transport: where the supports have got to,
/// the Fade button, and the way out. Nothing while practice mode is off.
class PracticeBar extends ConsumerWidget {
  const PracticeBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final level = ref.watch(practiceLevelProvider);
    if (level == null) return const SizedBox.shrink();
    final ladder = ref.watch(practiceLadderProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final atBottom = level == ladder.last;
    return Padding(
      key: const ValueKey('practice_bar'),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
      child: Row(
        children: [
          // One dot per step, the current one filled and named.
          for (final l in ladder)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: l == level ? 10 : 7,
                height: l == level ? 10 : 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: l.index <= level.index
                      ? scheme.primary
                      : scheme.outlineVariant,
                ),
              ),
            ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              supportLevelLabel(level),
              key: const ValueKey('practice_level_label'),
              style: theme.textTheme.labelLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          FilledButton.tonalIcon(
            key: const ValueKey('practice_fade'),
            onPressed: atBottom ? null : () => PracticeMode.fade(ref),
            icon: const Icon(Icons.blur_on, size: 18),
            label: const Text('Fade'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          ),
          IconButton(
            key: const ValueKey('practice_exit'),
            tooltip: 'Leave practice mode',
            visualDensity: VisualDensity.compact,
            onPressed: () => PracticeMode.exit(ref),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// Practice mode on and off, from the transport row: the same icon as the
/// Fade button, filled while the mode is on. Absent in the views practice
/// mode doesn't apply to.
class PracticeToggleButton extends ConsumerWidget {
  const PracticeToggleButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!practiceModeAppliesTo(ref.watch(displayModeProvider))) {
      return const SizedBox.shrink();
    }
    final on = ref.watch(practiceModeProvider).active;
    return IconButton(
      key: const ValueKey('practice_toggle'),
      isSelected: on,
      icon: const Icon(Icons.blur_on),
      style: on
          ? IconButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              foregroundColor:
                  Theme.of(context).colorScheme.onSecondaryContainer,
            )
          : null,
      visualDensity: VisualDensity.compact,
      tooltip: on ? 'Leave practice mode' : 'Practice mode: fade the help',
      onPressed: () =>
          on ? PracticeMode.exit(ref) : PracticeMode.enter(ref),
    );
  }
}

/// Calls [onPass] each time [passes] goes up: the playing service's loop
/// counter, which changes service as the player switches what plays.
class LoopPassWatcher extends StatefulWidget {
  const LoopPassWatcher({
    super.key,
    required this.passes,
    required this.onPass,
    required this.child,
  });

  final ValueListenable<int> passes;
  final VoidCallback onPass;
  final Widget child;

  @override
  State<LoopPassWatcher> createState() => _LoopPassWatcherState();
}

class _LoopPassWatcherState extends State<LoopPassWatcher> {
  @override
  void initState() {
    super.initState();
    widget.passes.addListener(_changed);
  }

  @override
  void didUpdateWidget(LoopPassWatcher old) {
    super.didUpdateWidget(old);
    if (old.passes != widget.passes) {
      old.passes.removeListener(_changed);
      widget.passes.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.passes.removeListener(_changed);
    super.dispose();
  }

  void _changed() => widget.onPass();

  @override
  Widget build(BuildContext context) => widget.child;
}
