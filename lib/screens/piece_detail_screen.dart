import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/piece.dart';
import '../models/piece_layout.dart'; // for PieceLayout type
import '../services/playback_service_base.dart';
import '../services/providers.dart';
import '../widgets/fingering_view.dart';
import '../widgets/jianpu_view.dart';
import '../widgets/measure_selector.dart';
import '../widgets/notation_switcher.dart';
import '../widgets/playback_controls.dart';
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
    final parsedPiece = ref.watch(parsedPieceProvider).valueOrNull;
    final service = ref.watch(playbackServiceProvider);

    // Load piece into PlaybackService whenever parsedPiece changes
    ref.listen(parsedPieceProvider, (_, next) {
      next.whenData((parsed) {
        if (parsed != null) {
          ref.read(playbackServiceProvider).loadPiece(parsed);
        }
      });
    });

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
                  service: service,
                  parsedPiece: parsedPiece,
                ),
              ),
              SectionBar(
                sections: piece.sections,
                selection: selection,
                onSectionTap: (sel) =>
                    ref.read(measureSelectionProvider.notifier).state = sel,
              ),
              ValueListenableBuilder<int?>(
                valueListenable: service.currentMeasureNotifier,
                builder: (_, activeMeasure, _) => MeasureSelector(
                  measureCount: layout.measureCount,
                  sections: piece.sections,
                  selection: selection,
                  onSelectionChanged: (sel) =>
                      ref.read(measureSelectionProvider.notifier).state = sel,
                  activeMeasure: activeMeasure,
                ),
              ),
              const PlaybackControls(),
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
    Piece piece, {
    required PlaybackServiceBase service,
    ParsedPiece? parsedPiece,
  }) {
    final keySignature = parsedPiece?.keySignature;

    switch (mode) {
      case DisplayMode.staff:
        return ref.watch(staffXmlProvider).when(
          data: (xml) => xml != null
              ? Column(children: [
                  _KeyHeader(keySignature: keySignature),
                  Expanded(
                      child: StaffView(
                          musicXml: xml,
                          highlightNotifier: service.currentHighlightNotifier)),
                ])
              : const Center(child: CircularProgressIndicator()),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
        );

      case DisplayMode.staffFingering:
        final legend = parsedPiece != null ? _fingerLegend(parsedPiece) : null;
        return ref.watch(staffFingeringXmlProvider).when(
          data: (xml) => xml != null
              ? Column(children: [
                  _KeyHeader(keySignature: keySignature, fingerLegend: legend),
                  Expanded(
                      child: StaffView(
                          musicXml: xml,
                          highlightNotifier: service.currentHighlightNotifier)),
                ])
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
          keySignature: keySignature,
          notifierForMeasure: service.notifierForMeasure,
        );

      case DisplayMode.fingering:
        return FingeringView(
          layout: layout,
          selectedMeasures: selectedMeasures,
          sectionLabels: sectionLabels,
          onMeasureTap: (m) => _toggleMeasure(ref, m),
          notifierForMeasure: service.notifierForMeasure,
        );

      case DisplayMode.combined:
        return FingeringView(
          layout: layout,
          selectedMeasures: selectedMeasures,
          sectionLabels: sectionLabels,
          onMeasureTap: (m) => _toggleMeasure(ref, m),
          combined: true,
          notifierForMeasure: service.notifierForMeasure,
        );
    }
  }

  // "Am" → "A minor", "Bb" → "B♭ major", "G" → "G major"
  static String _formatKey(String sig) {
    final isMinor = sig.endsWith('m');
    final root = isMinor ? sig.substring(0, sig.length - 1) : sig;
    return '${root.replaceAll('b', '♭')} ${isMinor ? 'minor' : 'major'}';
  }

  // Scan all notes to build "G: 1=A, 2=B, 3♭=C | D: 1=E, 2=F# | ..."
  static String? _fingerLegend(ParsedPiece parsed) {
    final data = <String, Map<String, ({String note, bool isLow})>>{};

    for (final n in parsed.allNotes) {
      if (n.isRest || n.fingerString == null || n.fingerNumber == null) continue;
      final fn = n.fingerNumber!;
      final isLow = fn.endsWith('low');
      final base = fn.replaceAll('low', '');
      if (base == '0') continue;
      final noteName = n.pitch
          .replaceAll(RegExp(r'\d+$'), '')
          .replaceAll(RegExp(r'b$'), '♭');
      (data[n.fingerString!] ??= {})[base] = (note: noteName, isLow: isLow);
    }

    if (data.isEmpty) return null;

    const stringOrder = ['G', 'D', 'A', 'E'];
    final parts = <String>[];
    for (final s in stringOrder) {
      final fingers = data[s];
      if (fingers == null) continue;
      final fParts = ['1', '2', '3', '4']
          .where(fingers.containsKey)
          .map((f) {
            final info = fingers[f]!;
            return info.isLow ? '$f♭=${info.note}' : '$f=${info.note}';
          })
          .join(', ');
      if (fParts.isNotEmpty) parts.add('$s: $fParts');
    }
    return parts.isEmpty ? null : parts.join(' | ');
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

class _KeyHeader extends StatelessWidget {
  final String? keySignature;
  final String? fingerLegend;

  const _KeyHeader({this.keySignature, this.fingerLegend});

  @override
  Widget build(BuildContext context) {
    if (keySignature == null) return const SizedBox.shrink();
    final keyDisplay = PieceDetailScreen._formatKey(keySignature!);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: Colors.grey.shade50,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            keyDisplay,
            style: const TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: Colors.black87),
          ),
          if (fingerLegend != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                fingerLegend!,
                style: const TextStyle(fontSize: 11, color: Colors.black54),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}
