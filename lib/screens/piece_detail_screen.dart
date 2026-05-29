import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/piece.dart';
import '../models/piece_layout.dart'; // for PieceLayout type
import '../models/string_label_style.dart';
import '../services/midi_generator.dart';
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
        toolbarHeight: 36,
        title: Text(piece.title,
            style: const TextStyle(fontSize: 14),
            overflow: TextOverflow.ellipsis),
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
              ],
            ),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
          final n = measuresPerRowForWidth(constraints.maxWidth);
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (ref.read(measuresPerRowProvider) != n) {
              ref.read(measuresPerRowProvider.notifier).state = n;
            }
          });
          // Phone in any orientation: short side < 600pt. iPad min is 768pt.
          final useCompact =
              constraints.maxWidth < 600 || constraints.maxHeight < 600;

          return layoutAsync.when(
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

              final notationView = _buildNotationView(
                context,
                ref,
                displayMode,
                layout,
                selectedMeasureNumbers,
                sectionLabels,
                piece,
                service: service,
                parsedPiece: parsedPiece,
              );

              if (useCompact) {
                return _CompactPieceLayout(
                  notationView: notationView,
                  layout: layout,
                  piece: piece,
                  service: service,
                  displayMode: displayMode,
                  selection: selection,
                );
              }

              return Column(
                children: [
                  const _PalettePanel(),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    child: NotationSwitcher(
                      current: displayMode,
                      onChanged: (mode) =>
                          ref.read(displayModeProvider.notifier).state = mode,
                    ),
                  ),
                  if (displayMode == DisplayMode.staffFingering)
                    _StringLabelPicker(ref: ref),
                  Expanded(
                    child: notationView,
                  ),
                  SectionBar(
                    sections: piece.sections,
                    selection: selection,
                    onSectionTap: (sel) =>
                        ref.read(measureSelectionProvider.notifier).state =
                            sel,
                  ),
                  ValueListenableBuilder<int?>(
                    valueListenable: service.currentMeasureNotifier,
                    builder: (_, activeMeasure, _) => MeasureSelector(
                      measureCount: layout.measureCount,
                      sections: piece.sections,
                      selection: selection,
                      onSelectionChanged: (sel) =>
                          ref.read(measureSelectionProvider.notifier).state =
                              sel,
                      activeMeasure: activeMeasure,
                    ),
                  ),
                  const PlaybackControls(),
                ],
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, st) => Center(child: Text('Error: $e')),
          );
        },
        ),
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
              ? StaffView(
                  musicXml: xml,
                  highlightNotifier: service.currentHighlightNotifier)
              : const Center(child: CircularProgressIndicator()),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
        );

      case DisplayMode.staffFingering:
        return ref.watch(staffFingeringXmlProvider).when(
          data: (xml) => xml != null
              ? StaffView(
                  musicXml: xml,
                  highlightNotifier: service.currentHighlightNotifier)
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
          currentMeasureNotifier: service.currentMeasureNotifier,
        );

      case DisplayMode.fingering:
        return FingeringView(
          layout: layout,
          selectedMeasures: selectedMeasures,
          sectionLabels: sectionLabels,
          onMeasureTap: (m) => _toggleMeasure(ref, m),
          notifierForMeasure: service.notifierForMeasure,
          currentMeasureNotifier: service.currentMeasureNotifier,
        );

      case DisplayMode.combined:
        return FingeringView(
          layout: layout,
          selectedMeasures: selectedMeasures,
          sectionLabels: sectionLabels,
          onMeasureTap: (m) => _toggleMeasure(ref, m),
          combined: true,
          notifierForMeasure: service.notifierForMeasure,
          currentMeasureNotifier: service.currentMeasureNotifier,
        );
    }
  }

  // "Am" → "A minor", "Bb" → "B♭ major", "G" → "G major"
  static String _formatKey(String sig) {
    final isMinor = sig.endsWith('m');
    final root = isMinor ? sig.substring(0, sig.length - 1) : sig;
    return '${root.replaceAll('b', '♭')} ${isMinor ? 'minor' : 'major'}';
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

class _StringLabelPicker extends StatelessWidget {
  final WidgetRef ref;
  const _StringLabelPicker({required this.ref});

  @override
  Widget build(BuildContext context) {
    final style = ref.watch(stringLabelStyleProvider);
    void pick(StringLabelStyle v) =>
        ref.read(stringLabelStyleProvider.notifier).set(v);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('String labels:', style: TextStyle(fontSize: 13)),
          const SizedBox(width: 12),
          for (final (value, label, example) in [
            (StringLabelStyle.always,   'Always',    'A1 A2'),
            (StringLabelStyle.onChange, 'On change', 'A1 2'),
            (StringLabelStyle.never,    'Never',     '1 2'),
          ]) ...[
            Radio<StringLabelStyle>(
              value: value,
              groupValue: style,
              onChanged: (v) => pick(v!),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            GestureDetector(
              onTap: () => pick(value),
              child: Text(
                '$label ($example)',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 12),
          ],
        ],
      ),
    );
  }
}

// ── Compact (phone) layout: music fills screen, controls slide up ─────────────

class _CompactPieceLayout extends ConsumerStatefulWidget {
  final Widget notationView;
  final PieceLayout layout;
  final Piece piece;
  final PlaybackServiceBase service;
  final DisplayMode displayMode;
  final MeasureSelection? selection;

  const _CompactPieceLayout({
    required this.notationView,
    required this.layout,
    required this.piece,
    required this.service,
    required this.displayMode,
    required this.selection,
  });

  @override
  ConsumerState<_CompactPieceLayout> createState() =>
      _CompactPieceLayoutState();
}

class _CompactPieceLayoutState extends ConsumerState<_CompactPieceLayout> {
  // One-time peek survives hot reload but resets on cold restart.
  static bool _hasPeeked = false;
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    if (!_hasPeeked) {
      _hasPeeked = true;
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _sheetOpen = true);
        Future.delayed(const Duration(milliseconds: 2500), () {
          if (mounted) setState(() => _sheetOpen = false);
        });
      });
    }
  }

  String _sectionLabel(MeasureSelection? selection) {
    if (selection == null) return 'Whole piece';
    for (final s in widget.piece.sections) {
      if (s.startMeasure == selection.startMeasure &&
          s.endMeasure == selection.endMeasure) {
        return s.label;
      }
    }
    return 'm. ${selection.startMeasure}–${selection.endMeasure}';
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    final displayMode = widget.displayMode;
    final isPlaying = ref.watch(playbackStateProvider).valueOrNull ==
        PlaybackState.playing;
    final theme = Theme.of(context);

    return Column(
      children: [
        // String-label picker only when needed (staffFingering mode).
        if (displayMode == DisplayMode.staffFingering)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: _StringLabelPicker(ref: ref),
          ),
        // ── music + bottom sheet overlay ─────────────────────────
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: widget.notationView),
              // Controls sheet anchored to the bottom.
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Material(
                  elevation: 10,
                  color: theme.colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16)),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ── drawer contents (slides up above play bar) ─
                      AnimatedSize(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                        child: _sheetOpen
                            ? ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxHeight: 280),
                                child: SingleChildScrollView(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _CompactModeSwitcher(
                                        current: displayMode,
                                        onChanged: (mode) => ref
                                            .read(displayModeProvider.notifier)
                                            .state = mode,
                                      ),
                                      const Divider(height: 1),
                                      SectionBar(
                                        sections: widget.piece.sections,
                                        selection: selection,
                                        onSectionTap: (sel) => ref
                                            .read(measureSelectionProvider
                                                .notifier)
                                            .state = sel,
                                      ),
                                      ValueListenableBuilder<int?>(
                                        valueListenable: widget
                                            .service.currentMeasureNotifier,
                                        builder: (_, activeMeasure, _) =>
                                            MeasureSelector(
                                          measureCount:
                                              widget.layout.measureCount,
                                          sections: widget.piece.sections,
                                          selection: selection,
                                          onSelectionChanged: (sel) => ref
                                              .read(measureSelectionProvider
                                                  .notifier)
                                              .state = sel,
                                          activeMeasure: activeMeasure,
                                        ),
                                      ),
                                      const PlaybackControls(),
                                    ],
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      // ── always-visible play bar (drag handle + controls)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () =>
                            setState(() => _sheetOpen = !_sheetOpen),
                        onVerticalDragUpdate: (d) {
                          if (d.delta.dy < -6 && !_sheetOpen) {
                            setState(() => _sheetOpen = true);
                          } else if (d.delta.dy > 6 && _sheetOpen) {
                            setState(() => _sheetOpen = false);
                          }
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 5),
                              child: Container(
                                width: 40,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade400,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                            SizedBox(
                              height: 40,
                              child: Row(
                                children: [
                                  IconButton(
                                    icon: Icon(isPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow),
                                    iconSize: 26,
                                    tooltip:
                                        isPlaying ? 'Pause' : 'Play',
                                    onPressed: () {
                                      if (isPlaying) {
                                        widget.service.pause();
                                      } else {
                                        widget.service.play(
                                          fromMeasure:
                                              selection?.startMeasure ?? 1,
                                          toMeasure: selection?.endMeasure,
                                        );
                                      }
                                    },
                                  ),
                                  Expanded(
                                    child: Text(
                                      _sectionLabel(selection),
                                      style:
                                          const TextStyle(fontSize: 13),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Icon(
                                    _sheetOpen
                                        ? Icons.expand_more
                                        : Icons.expand_less,
                                    size: 18,
                                    color: Colors.grey.shade600,
                                  ),
                                  const SizedBox(width: 12),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Compact mode switcher (always-visible icon bar at top of compact layout) ──

class _CompactModeSwitcher extends StatelessWidget {
  final DisplayMode current;
  final ValueChanged<DisplayMode> onChanged;

  const _CompactModeSwitcher({
    required this.current,
    required this.onChanged,
  });

  static const _modes = [
    (DisplayMode.staff, Icons.music_note, 'Staff'),
    (DisplayMode.staffFingering, Icons.queue_music, 'Ann.'),
    (DisplayMode.jianpu, Icons.format_list_numbered, 'Jianpu'),
    (DisplayMode.fingering, Icons.back_hand, 'Finger'),
    (DisplayMode.combined, Icons.layers, '+'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final showLabels = constraints.maxWidth >= 500;
        return Container(
          height: 36,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: Row(
            children: [
              for (final (mode, icon, label) in _modes)
                Expanded(
                  child: _ModeTab(
                    icon: icon,
                    label: showLabels ? label : null,
                    isSelected: current == mode,
                    onTap: () => onChanged(mode),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ModeTab extends StatelessWidget {
  final IconData icon;
  final String? label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeTab({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  Widget _buildTabContent(IconData icon, String? label, Color color) {
    final l = label;
    if (l != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(l, style: TextStyle(fontSize: 12, color: color)),
        ],
      );
    }
    return Icon(icon, size: 18, color: color);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isSelected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: isSelected
            ? BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                      color: theme.colorScheme.primary, width: 2.5),
                ),
              )
            : null,
        alignment: Alignment.center,
        child: _buildTabContent(icon, label, color),
      ),
    );
  }
}

// ── Note palette panel (staff view of all unique notes in the piece) ──────────

class _PalettePanel extends ConsumerStatefulWidget {
  const _PalettePanel();

  @override
  ConsumerState<_PalettePanel> createState() => _PalettePanelState();
}

class _PalettePanelState extends ConsumerState<_PalettePanel> {
  late final ValueNotifier<HighlightEvent?> _noHighlight;
  bool _expanded = true;
  bool _expandedInitialized = false;

  @override
  void initState() {
    super.initState();
    _noHighlight = ValueNotifier(null);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_expandedInitialized) {
      // Auto-collapse on short screens (landscape phone) to avoid overflow.
      _expanded = MediaQuery.of(context).size.height > 500;
      _expandedInitialized = true;
    }
  }

  @override
  void dispose() {
    _noHighlight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parsed = ref.watch(parsedPieceProvider).valueOrNull;
    if (parsed == null) return const SizedBox.shrink();

    // Watch unconditionally so the data is ready when _expanded becomes true.
    final paletteXml = ref.watch(paletteMusicXmlProvider).valueOrNull;

    final keyTitle = PieceDetailScreen._formatKey(parsed.keySignature);

    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: fixed-width spacer on left balances the button on the right
          // so the title is truly centred.
          Row(
            children: [
              const SizedBox(width: 48),
              Expanded(
                child: Text(
                  keyTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, fontStyle: FontStyle.italic),
                ),
              ),
              IconButton(
                icon: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20),
                tooltip: _expanded ? 'Hide palette' : 'Show palette',
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
            ],
          ),
          if (_expanded && paletteXml != null)
            SizedBox(
              height: 140,
              child: StaffView(
                musicXml: paletteXml,
                highlightNotifier: _noHighlight,
                bridgeAsset: 'assets/osmd/palette_bridge.html',
              ),
            ),
          if (_expanded && paletteXml == null)
            const SizedBox(
                height: 140,
                child: Center(child: CircularProgressIndicator())),
        ],
      ),
    );
  }
}

