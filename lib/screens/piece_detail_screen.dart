import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../build_info.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart'; // for ParsedPiece.performanceOrder
import '../models/piece.dart';
import '../models/piece_layout.dart'; // for PieceLayout type
import '../models/section.dart';
import '../models/section_palette.dart';
import '../models/string_label_style.dart';
import '../services/midi_generator.dart';
import '../services/playback_service_base.dart';
import '../services/providers.dart';
import 'edit_measure_screen.dart';
import '../widgets/fingering_view.dart';
import '../widgets/jianpu_view.dart';
import '../widgets/notation_switcher.dart';
import '../widgets/playback_controls.dart';
import '../widgets/section_bar.dart';
import '../widgets/section_minimap.dart';
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
        toolbarHeight: kDebugMode ? 44 : 36,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(piece.title,
                style: const TextStyle(fontSize: 14),
                overflow: TextOverflow.ellipsis),
            if (kDebugMode)
              Text(kBuildRef,
                  style: TextStyle(
                      fontSize: 9,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45))),
          ],
        ),
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
                Text('Settings', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 24),
                if (piece.sections.isNotEmpty) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Flexible(
                          child: Text('Organize by sections (ABAA)')),
                      Switch(
                        value: ref.watch(sectionOrganizedProvider),
                        onChanged: (v) => ref
                            .read(sectionOrganizedProvider.notifier)
                            .state = v,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Staff spacing'),
                    Text(ref.watch(staffSpacingProvider).toStringAsFixed(1),
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
                Slider(
                  value: ref.watch(staffSpacingProvider),
                  min: staffSpacingMin,
                  max: staffSpacingMax,
                  divisions: ((staffSpacingMax - staffSpacingMin) / 0.05).round(),
                  onChanged: (v) =>
                      ref.read(staffSpacingProvider.notifier).state = v,
                ),
                if (displayMode == DisplayMode.staffFingering) ...[
                  const Divider(),
                  const SizedBox(height: 8),
                  const _StringLabelPicker(),
                ],
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
              final sectionColors =
                  SectionPalette.colorsForSections(piece.sections);

              final notationView = _NotationView(
                mode: displayMode,
                layout: layout,
                selectedMeasures: selectedMeasureNumbers,
                sectionLabels: sectionLabels,
                sectionColors: sectionColors,
                sections: piece.sections,
                service: service,
                keySignature: parsedPiece?.keySignature,
              );

              final minimap = layout.runs.isEmpty
                  ? null
                  : SectionMinimap(
                      runs: layout.runs,
                      sectionColors: sectionColors,
                      service: service,
                      onTapRun: (i) {
                        final run = layout.runs[i];
                        ref.read(measureSelectionProvider.notifier).state =
                            MeasureSelection(run.firstMeasure, run.lastMeasure);
                        final cur = ref.read(navTargetRunProvider);
                        ref.read(navTargetRunProvider.notifier).state =
                            (run: i, seq: (cur?.seq ?? 0) + 1);
                      },
                    );

              if (useCompact) {
                return _CompactPieceLayout(
                  notationView: notationView,
                  minimap: minimap,
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
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: Stack(
                            children: [
                              Positioned.fill(child: notationView),
                              _FloatingEditButton(selection: selection),
                            ],
                          ),
                        ),
                        ?minimap,
                      ],
                    ),
                  ),
                  SectionBar(
                    sections: piece.sections,
                    selection: selection,
                    onSectionTap: (sel) =>
                        ref.read(measureSelectionProvider.notifier).state =
                            sel,
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

  // "Am" → "A minor", "Bb" → "B♭ major", "G" → "G major"
  static String _formatKey(String sig) {
    final isMinor = sig.endsWith('m');
    final root = isMinor ? sig.substring(0, sig.length - 1) : sig;
    return '${root.replaceAll('b', '♭')} ${isMinor ? 'minor' : 'major'}';
  }
}

class _StringLabelPicker extends ConsumerWidget {
  const _StringLabelPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(stringLabelStyleProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('String labels'),
        const SizedBox(height: 8),
        SegmentedButton<StringLabelStyle>(
          segments: const [
            ButtonSegment(value: StringLabelStyle.always,   label: Text('Always')),
            ButtonSegment(value: StringLabelStyle.onChange, label: Text('On change')),
            ButtonSegment(value: StringLabelStyle.never,    label: Text('Never')),
          ],
          selected: {style},
          onSelectionChanged: (s) =>
              ref.read(stringLabelStyleProvider.notifier).set(s.first),
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }
}

// ── Compact (phone) layout: music fills screen, controls slide up ─────────────

class _CompactPieceLayout extends ConsumerStatefulWidget {
  final Widget notationView;
  final Widget? minimap;
  final PieceLayout layout;
  final Piece piece;
  final PlaybackServiceBase service;
  final DisplayMode displayMode;
  final MeasureSelection? selection;

  const _CompactPieceLayout({
    required this.notationView,
    required this.minimap,
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
  static bool _hasPeeked = false;
  final _trayKey = GlobalKey();
  bool _sheetOpen = false;

  void _measureTray() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _trayKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        ref.read(staffViewBottomInsetProvider.notifier).state = box.size.height;
      }
    });
  }

  // Closes the sheet and re-measures the tray AFTER the AnimatedSize animation
  // (250 ms) finishes. Measuring immediately captures the pre-collapse height,
  // leaving a grey gap between the content and the compact tray.
  void _closeSheet() {
    if (!_sheetOpen) return;
    setState(() => _sheetOpen = false);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _measureTray();
    });
  }

  @override
  void initState() {
    super.initState();
    // Seed a conservative estimate before the first frame so the WebView
    // doesn't render behind the tray while the real measurement is pending.
    // Must be post-frame to avoid mutating a provider during tree build.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(staffViewBottomInsetProvider.notifier).state = 72;
    });
    _measureTray();
    if (!_hasPeeked) {
      _hasPeeked = true;
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) setState(() { _sheetOpen = true; _measureTray(); });
        Future.delayed(const Duration(milliseconds: 2500), () {
          if (mounted) _closeSheet();
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    final displayMode = widget.displayMode;
    final theme = Theme.of(context);

    ref.listen(playbackStateProvider, (_, next) {
      if (next.valueOrNull == PlaybackState.playing) _closeSheet();
    });

    return Column(
      children: [
        // ── music + bottom sheet overlay ─────────────────────────
        Expanded(
          child: Stack(
            children: [
              // Leave bottom clearance equal to the tray height so the last
              // staff row is never hidden behind the controls overlay.
              Positioned.fill(
                bottom: ref.watch(staffViewBottomInsetProvider),
                child: widget.minimap == null
                    ? widget.notationView
                    : Row(
                        children: [
                          Expanded(child: widget.notationView),
                          widget.minimap!,
                        ],
                      ),
              ),
              _FloatingEditButton(selection: selection),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Material(
                  key: _trayKey,
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
                                    ],
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      // ── always-visible: pill + full playback controls ──
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragUpdate: (d) {
                          if (d.delta.dy < -6 && !_sheetOpen) {
                            setState(() => _sheetOpen = true);
                            _measureTray();
                          } else if (d.delta.dy > 6 && _sheetOpen) {
                            _closeSheet();
                          }
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              onTap: () {
                                if (_sheetOpen) {
                                  _closeSheet();
                                } else {
                                  setState(() => _sheetOpen = true);
                                  _measureTray();
                                }
                              },
                              child: Padding(
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
                            ),
                            const PlaybackControls(),
                            // Spacer so interactive content sits above the
                            // home-indicator zone; Material background fills
                            // the safe area gap visually.
                            SizedBox(
                                height: MediaQuery.of(context).padding.bottom),
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

class _CompactModeSwitcher extends StatefulWidget {
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
  State<_CompactModeSwitcher> createState() => _CompactModeSwitcherState();
}

class _CompactModeSwitcherState extends State<_CompactModeSwitcher>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  int _indexForMode(DisplayMode mode) =>
      _CompactModeSwitcher._modes.indexWhere((m) => m.$1 == mode);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _CompactModeSwitcher._modes.length,
      vsync: this,
      initialIndex: _indexForMode(widget.current),
    );
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        widget.onChanged(_CompactModeSwitcher._modes[_tabController.index].$1);
      }
    });
  }

  @override
  void didUpdateWidget(_CompactModeSwitcher old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current) {
      final idx = _indexForMode(widget.current);
      if (idx != _tabController.index) {
        _tabController.animateTo(idx);
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final showLabels = constraints.maxWidth >= 500;
        return TabBar(
          controller: _tabController,
          tabs: [
            for (final (_, icon, label) in _CompactModeSwitcher._modes)
              Tab(
                height: 36,
                child: showLabels
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 14),
                          const SizedBox(width: 4),
                          Text(label, style: const TextStyle(fontSize: 12)),
                        ],
                      )
                    : Icon(icon, size: 18),
              ),
          ],
        );
      },
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

// ── Notation view ─────────────────────────────────────────────────────────────

class _NotationView extends ConsumerWidget {
  final DisplayMode mode;
  final PieceLayout layout;
  final Set<int> selectedMeasures;
  final Map<int, String> sectionLabels;
  final Map<String, Color> sectionColors;
  final List<Section> sections;
  final PlaybackServiceBase service;
  final String? keySignature;

  const _NotationView({
    required this.mode,
    required this.layout,
    required this.selectedMeasures,
    required this.sectionLabels,
    required this.sectionColors,
    required this.sections,
    required this.service,
    this.keySignature,
  });

  // Shared "tap anchor, tap to extend" selection logic, used by every notation
  // view (staff, jianpu, fingering). See MeasureSelection.afterTap.
  void _selectMeasure(WidgetRef ref, int measure) {
    final current = ref.read(measureSelectionProvider);
    ref.read(measureSelectionProvider.notifier).state =
        MeasureSelection.afterTap(current, measure);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(measureSelectionProvider);
    final parsed = ref.watch(parsedPieceProvider).valueOrNull;
    final flaggedMeasures = parsed?.flaggedMeasureNumbers ?? const <int>{};
    // Minimap → custom-view navigation, and custom-view scroll → minimap.
    final navTarget = ref.watch(navTargetRunProvider);
    void onVisibleRun(int i) {
      if (ref.read(scrollRunProvider) != i) {
        ref.read(scrollRunProvider.notifier).state = i;
      }
    }
    // In section-organized mode the staff XML is unfolded into performance
    // order, so the index↔number map and the stretch rule must match it. Gate
    // on sections present, identically to the providers that build the XML.
    final sectioned = ref.watch(sectionOrganizedProvider) &&
        (ref.watch(selectedPieceProvider)?.sections.isNotEmpty ?? false);
    final measureNumbers = parsed == null
        ? const <int>[]
        : (sectioned
            ? ParsedPiece.performanceOrder(parsed.measures)
                .map((i) => parsed.measures[i].number)
                .toList()
            : parsed.measures.map((m) => m.number).toList());
    // Section coloring/navigation is ABAA-only (no minimap, bars, or section
    // tints in folded mode), so the staff wash is empty unless sectioned.
    final sectionTints = sectioned
        ? sectionTintSpans(measureNumbers, sections, sectionColors)
        : const <SectionTintSpan>[];
    // Minimap tap → scroll the staff to the run's first measure index. Guard the
    // index: a stale navTarget (left over from a layout with more runs, e.g.
    // after toggling ABAA off or switching pieces) must not index out of range.
    final staffNav = (navTarget == null || navTarget.run >= layout.runs.length)
        ? null
        : () {
            final run = layout.runs[navTarget.run];
            final idx = measureNumbers.indexOf(run.firstMeasure);
            return idx < 0 ? null : (index: idx, seq: navTarget.seq);
          }();
    switch (mode) {
      case DisplayMode.staff:
        return ref.watch(staffXmlProvider).when(
          data: (xml) => xml != null
              ? StaffView(
                  musicXml: xml,
                  highlightNotifier: service.currentHighlightNotifier,
                  selection: selection,
                  onMeasureTapped: (m) => _selectMeasure(ref, m),
                  flaggedMeasures: flaggedMeasures,
                  measureNumbers: measureNumbers,
                  stretchLastSystem: !sectioned,
                  sectionTints: sectionTints,
                  scrollNav: staffNav,
                )
              : const Center(child: CircularProgressIndicator()),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
        );

      case DisplayMode.staffFingering:
        return ref.watch(staffFingeringXmlProvider).when(
          data: (xml) => xml != null
              ? StaffView(
                  musicXml: xml,
                  highlightNotifier: service.currentHighlightNotifier,
                  selection: selection,
                  onMeasureTapped: (m) => _selectMeasure(ref, m),
                  flaggedMeasures: flaggedMeasures,
                  measureNumbers: measureNumbers,
                  stretchLastSystem: !sectioned,
                  sectionTints: sectionTints,
                  scrollNav: staffNav,
                )
              : const Center(child: CircularProgressIndicator()),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
        );

      case DisplayMode.jianpu:
        return JianpuView(
          layout: layout,
          selectedMeasures: selectedMeasures,
          flaggedMeasures: flaggedMeasures,
          // Section identity now comes from the inline run headers + the
          // minimap, so the per-measure A/B label is redundant.
          sectionLabels: const {},
          sectionColors: sectionColors,
          navTarget: navTarget,
          onVisibleRunChanged: onVisibleRun,
          onMeasureTap: (m) => _selectMeasure(ref, m),
          keySignature: keySignature,
          notifierForMeasure: service.notifierForMeasure,
          currentMeasureNotifier: service.currentMeasureNotifier,
        );

      case DisplayMode.fingering:
        return FingeringView(
          layout: layout,
          selectedMeasures: selectedMeasures,
          flaggedMeasures: flaggedMeasures,
          sectionLabels: const {},
          sectionColors: sectionColors,
          navTarget: navTarget,
          onVisibleRunChanged: onVisibleRun,
          onMeasureTap: (m) => _selectMeasure(ref, m),
          notifierForMeasure: service.notifierForMeasure,
          currentMeasureNotifier: service.currentMeasureNotifier,
        );

      case DisplayMode.combined:
        return FingeringView(
          layout: layout,
          selectedMeasures: selectedMeasures,
          flaggedMeasures: flaggedMeasures,
          sectionLabels: const {},
          sectionColors: sectionColors,
          navTarget: navTarget,
          onVisibleRunChanged: onVisibleRun,
          onMeasureTap: (m) => _selectMeasure(ref, m),
          combined: true,
          notifierForMeasure: service.notifierForMeasure,
          currentMeasureNotifier: service.currentMeasureNotifier,
        );
    }
  }
}

// ── Floating edit-measure button ──────────────────────────────────────────
//
// Measure selection now happens directly on the notation (staff/jianpu/
// fingering). The §6 note editor is reachable from a floating button overlaid
// on the notation that appears whenever exactly one measure is selected on a
// platform with writable storage — independent of the drawer/tray state, so
// it's discoverable the moment you tap a measure. Fixtures are materialized to
// an editable file on first save (see EditMeasureScreen._save); web has no file
// storage so editing is disabled there via `supportsEditing` — no `kIsWeb`
// needed in shared code.
//
// Always returns a [Positioned] (must be used as a direct child of the notation
// [Stack]) — with an empty child when no single editable measure is selected.
// It must stay positioned even when hidden: a non-positioned child would make
// the Stack size itself to that child (collapsing it) instead of filling.
class _FloatingEditButton extends ConsumerWidget {
  final MeasureSelection? selection;

  const _FloatingEditButton({required this.selection});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sel = selection;
    final canEdit = sel != null &&
        sel.isSingle &&
        ref.watch(pieceRepositoryProvider).supportsEditing;

    return Positioned(
      top: 8,
      right: 8,
      child: canEdit
          ? FloatingActionButton.extended(
              heroTag: 'edit_measure_fab',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      EditMeasureScreen(measureNumber: sel.startMeasure),
                ),
              ),
              icon: const Icon(Icons.edit, size: 18),
              label: Text('Edit m. ${sel.startMeasure}'),
            )
          : const SizedBox.shrink(),
    );
  }
}

