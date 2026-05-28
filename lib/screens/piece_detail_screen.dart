import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/note_event.dart';
import '../models/piece.dart';
import '../models/piece_layout.dart'; // for PieceLayout type
import '../services/providers.dart';
import '../widgets/fingering_view.dart';
import '../widgets/jianpu_view.dart';
import '../widgets/measure_selector.dart';
import '../widgets/notation_switcher.dart';
import '../widgets/section_bar.dart';
import '../widgets/staff_view.dart';

class PieceDetailScreen extends ConsumerWidget {
  const PieceDetailScreen({super.key});

  Map<int, String> _sectionLabels(Piece piece) {
    return {for (final s in piece.sections) s.startMeasure: s.label};
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final piece = ref.watch(selectedPieceProvider);
    final layoutAsync = ref.watch(pieceLayoutProvider);
    final displayMode = ref.watch(displayModeProvider);
    final selection = ref.watch(measureSelectionProvider);

    if (piece == null) {
      return const Scaffold(body: Center(child: Text('No piece selected')));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(piece.title),
        actions: [
          Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
        ],
      ),
      endDrawer: Drawer(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Settings',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                const Text('String preference'),
                Consumer(
                  builder: (context, ref, _) {
                    final pref = ref.watch(openStringPreferenceProvider);
                    return Row(
                      children: [
                        const Text('Open strings'),
                        Switch(
                          value: pref == 'fingered',
                          onChanged: (v) {
                            ref
                                .read(openStringPreferenceProvider.notifier)
                                .set(v ? 'fingered' : 'open');
                            ref.invalidate(parsedPieceProvider);
                          },
                        ),
                        const Text('Fingered'),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      body: layoutAsync.when(
        data: (layout) {
          if (layout == null) {
            return const Center(child: Text('No piece loaded'));
          }

          final selectedMeasureNumbers = selection != null
              ? Set<int>.from(layout.rows
                  .expand((r) => r)
                  .where((m) => selection.contains(m.number))
                  .map((m) => m.number))
              : <int>{};

          final sectionLabels = _sectionLabels(piece);

          return Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: NotationSwitcher(
                  current: displayMode,
                  onChanged: (mode) =>
                      ref.read(displayModeProvider.notifier).state = mode,
                ),
              ),
              Expanded(
                child: _buildNotationView(
                  context,
                  ref,
                  displayMode,
                  layout,
                  selectedMeasureNumbers,
                  sectionLabels,
                  piece,
                ),

              ),
              SectionBar(
                sections: piece.sections,
                selection: selection,
                onSectionTap: (sel) =>
                    ref.read(measureSelectionProvider.notifier).state = sel,
              ),
              MeasureSelector(
                measureCount: layout.measureCount,
                sections: piece.sections,
                selection: selection,
                onSelectionChanged: (sel) =>
                    ref.read(measureSelectionProvider.notifier).state = sel,
              ),
              const SizedBox(height: 8),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
      ),
    );
  }

  Widget _buildNotationView(
    BuildContext context,
    WidgetRef ref,
    DisplayMode mode,
    PieceLayout layout,
    Set<int> selectedMeasures,
    Map<int, String> sectionLabels,
    Piece piece,
  ) {
    switch (mode) {
      case DisplayMode.staff:
        return ref.watch(staffXmlProvider).when(
          data: (xml) => xml != null
              ? StaffView(musicXml: xml)
              : const Center(child: CircularProgressIndicator()),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
        );

      case DisplayMode.staffFingering:
        return ref.watch(staffFingeringXmlProvider).when(
          data: (xml) => xml != null
              ? StaffView(musicXml: xml)
              : const Center(child: CircularProgressIndicator()),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
        );

      case DisplayMode.jianpu:
        return JianpuView(
          layout: layout,
          selectedMeasures: selectedMeasures,
          sectionLabels: sectionLabels,
          onMeasureTap: (m) => _toggleMeasure(ref, m),
        );

      case DisplayMode.fingering:
        return FingeringView(
          layout: layout,
          selectedMeasures: selectedMeasures,
          sectionLabels: sectionLabels,
          onMeasureTap: (m) => _toggleMeasure(ref, m),
        );

      case DisplayMode.combined:
        return FingeringView(
          layout: layout,
          selectedMeasures: selectedMeasures,
          sectionLabels: sectionLabels,
          onMeasureTap: (m) => _toggleMeasure(ref, m),
          combined: true,
        );
    }
  }

  void _toggleMeasure(WidgetRef ref, int measure) {
    final current = ref.read(measureSelectionProvider);
    if (current != null &&
        current.startMeasure == measure &&
        current.endMeasure == measure) {
      ref.read(measureSelectionProvider.notifier).state = null;
    } else {
      ref.read(measureSelectionProvider.notifier).state =
          MeasureSelection(measure, measure);
    }
  }
}
