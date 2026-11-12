import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/instrument_setting.dart';

/// App-wide settings, from the gear on the piece list. Per-piece choices (view,
/// spacing, fingering detail) stay in the piece's own drawer; this is for facts
/// about who uses the app.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final set = ref.watch(instrumentSetProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Instruments', style: theme.textTheme.titleSmall),
          ),
          RadioGroup<InstrumentSet>(
            groupValue: set,
            onChanged: (v) {
              if (v != null) ref.read(instrumentSetProvider.notifier).state = v;
            },
            child: const Column(
              key: ValueKey('instrument_setting'),
              children: [
                RadioListTile<InstrumentSet>(
                  key: ValueKey('instrument_setting_violin'),
                  value: InstrumentSet.violin,
                  title: Text('Violin'),
                  subtitle: Text(
                      'Violin fingering only. Mandolin frets, the tab view '
                      'and chords are hidden.'),
                ),
                RadioListTile<InstrumentSet>(
                  key: ValueKey('instrument_setting_violin_mandolin'),
                  value: InstrumentSet.violinAndMandolin,
                  title: Text('Violin and mandolin'),
                  subtitle: Text(
                      'Each piece can show violin fingering or mandolin frets, '
                      'with the tab view and chords.'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
