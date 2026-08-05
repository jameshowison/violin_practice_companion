import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../build_info.dart';
import '../models/chord_palette.dart';
import '../models/count_in.dart';
import '../models/fingering_density.dart';
import '../models/note_event.dart';
import '../models/note_number_mode.dart';
import '../models/piece.dart';
import '../models/parsed_piece.dart';
import '../models/piece_layout.dart'; // for PieceLayout type
import '../models/section.dart';
import '../models/section_palette.dart';
import '../models/string_label_style.dart';
import '../models/violin_string_palette.dart';
import '../services/fingering_annotation_builder.dart';
import '../services/measure_xml_editor.dart';
import '../services/midi_generator.dart';
import '../services/musicxml_parser.dart';
import '../services/playback_service_base.dart';
import '../services/providers.dart';
import '../services/staff_zoom.dart';
import 'edit_measure_screen.dart';
import '../widgets/count_in_label.dart';
import '../widgets/fingering_view.dart';
import '../widgets/jianpu_view.dart';
import '../widgets/new_chords_block.dart';
import '../widgets/notation_switcher.dart';
import '../widgets/playback_controls.dart';
import '../widgets/section_bar.dart';
import '../widgets/section_minimap.dart';
import '../widgets/staff_view.dart';
import '../widgets/staff_view_verovio.dart';
import '../widgets/time_signature_dialog.dart';

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
                // First, and never hidden behind a display mode: it's the one
                // setting here that's about playing along rather than about how
                // the notation looks.
                const _CountInSlider(),
                const Divider(),
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
                if (displayMode == DisplayMode.staff ||
                    displayMode == DisplayMode.staffFingering ||
                    displayMode == DisplayMode.tab) ...[
                  const Divider(),
                  const _MeasuresPerLineSlider(),
                  const Divider(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Chord symbols'),
                    value: ref.watch(showChordsProvider),
                    onChanged: (v) =>
                        ref.read(showChordsProvider.notifier).state = v,
                  ),
                ],
                // Shared by the two views that put a number on a note: the tab
                // staff's string lines and the annotation view's fingering
                // channel. One preference, shown in whichever of them is open —
                // see [NoteNumberMode].
                if (displayMode == DisplayMode.staffFingering ||
                    displayMode == DisplayMode.tab) ...[
                  const Divider(),
                  const SizedBox(height: 8),
                  const _NoteNumberPicker(),
                  if (ref.watch(noteNumberModeProvider) ==
                      NoteNumberMode.mandolinFret) ...[
                    const SizedBox(height: 16),
                    const _FretStylePicker(),
                  ],
                ],
                if (displayMode == DisplayMode.staffFingering) ...[
                  const Divider(),
                  const SizedBox(height: 8),
                  const _StringColourPicker(),
                  // Only meaningful while the letter is actually drawn — while a
                  // colour is carrying the string, the label doesn't repeat it.
                  if (ref.watch(stringColourStyleProvider) ==
                      StringColourStyle.off) ...[
                    const SizedBox(height: 16),
                    const _StringLabelPicker(),
                  ],
                  const SizedBox(height: 16),
                  const _FingeringDensitySlider(),
                  if (ref.watch(fingeringDensityProvider) !=
                      FingeringDensity.all) ...[
                    const SizedBox(height: 16),
                    const _FingeringDensityPolicyPicker(),
                  ],
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
                // Jianpu numbers 1 from the signature's RELATIVE MAJOR (see
                // JianpuConverter, which keys its table on fifths alone), so a
                // modal piece must still be labelled "1 = D", not "1 = Amix".
                keySignature: parsedPiece == null
                    ? null
                    : MusicXmlParser.keyName(
                        parsedPiece.keyFifths, KeyMode.major),
              );

              // The minimap shows the UNFOLDED structure (A A B B); the notation
              // body stays folded. A tap maps the unfolded run back to the
              // folded run for in-view navigation + practice-range selection.
              final unfoldedRuns =
                  ref.watch(sectionRunsProvider).valueOrNull ?? const [];
              final minimap = unfoldedRuns.isEmpty
                  ? null
                  : SectionMinimap(
                      runs: unfoldedRuns,
                      sectionColors: sectionColors,
                      service: service,
                      onTapRun: (i) {
                        final run = unfoldedRuns[i];
                        ref.read(measureSelectionProvider.notifier).state =
                            MeasureSelection(run.firstMeasure, run.lastMeasure);
                        final foldedIdx = layout.runs.indexWhere((r) =>
                            run.firstMeasure >= r.firstMeasure &&
                            run.firstMeasure <= r.lastMeasure);
                        if (foldedIdx >= 0) {
                          final cur = ref.read(navTargetRunProvider);
                          ref.read(navTargetRunProvider.notifier).state =
                              (run: foldedIdx, seq: (cur?.seq ?? 0) + 1);
                        }
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
                              _FloatingMeasureActions(selection: selection),
                              _CountInOverlay(
                                  service: service, mode: displayMode),
                            ],
                          ),
                        ),
                        ?minimap,
                      ],
                    ),
                  ),
                  if (displayMode == DisplayMode.staff ||
                      displayMode == DisplayMode.staffFingering ||
                      displayMode == DisplayMode.tab)
                    const NewChordsBlock(),
                  SectionBar(
                    sections: piece.sections,
                    measures: parsedPiece?.measures ?? const [],
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
  // "Amix" → "A mixolydian", "F#m" → "F♯ minor", "Bb" → "B♭ major". The suffix
  // is whatever MusicXmlParser.keyName appended for the mode.
  static const _modeWords = {
    'dor': 'dorian', 'phr': 'phrygian', 'lyd': 'lydian',
    'mix': 'mixolydian', 'loc': 'locrian', 'm': 'minor',
  };

  static String _formatKey(String sig) {
    for (final e in _modeWords.entries) {
      if (sig.length > e.key.length && sig.endsWith(e.key)) {
        final root = sig.substring(0, sig.length - e.key.length);
        return '${_prettyRoot(root)} ${e.value}';
      }
    }
    return '${_prettyRoot(sig)} major';
  }

  static String _prettyRoot(String root) =>
      root.replaceAll('b', '♭').replaceAll('#', '♯');
}

/// How long the count-off before playback is: Off, or a minimum of
/// [countInMinBeats]…[countInMaxBeats] beats.
///
/// The setting is a MINIMUM because the count always spans whole bars less the
/// pickup (see `countInPlan`) — so the readout shows what that came to for this
/// score, which is the number the player will actually see counted. Stops below
/// [countInMinBeats] aren't reachable: a one- or two-beat count doesn't establish
/// a pulse.
class _CountInSlider extends ConsumerWidget {
  const _CountInSlider();

  /// 0 is "Off"; the rest are minimum beat counts. `final`, not `const`, because
  /// a `for` element can't appear in a const collection.
  static final _stops = <int>[
    0,
    for (var b = countInMinBeats; b <= countInMaxBeats; b++) b,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final minBeats = ref.watch(countInProvider);
    // What Play will actually count: whole bars less any pickup at the start
    // measure, so the readout never promises a four that comes out a three.
    final plan = ref.watch(resolvedCountInProvider);
    final counted = plan?.labels.length ?? 0;
    final position = _stops.indexOf(minBeats);
    final readout = plan == null
        ? 'Off'
        : (counted == minBeats ? '$counted beats' : '$counted beats (min $minBeats)');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Count-in'),
            Text(readout, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        Slider(
          // A stale saved value outside the stops parks at the top rather than
          // throwing.
          value: (position < 0 ? _stops.length - 1 : position).toDouble(),
          min: 0,
          max: (_stops.length - 1).toDouble(),
          divisions: _stops.length - 1,
          label: readout,
          onChanged: (v) =>
              ref.read(countInProvider.notifier).preview(_stops[v.round()]),
          onChangeEnd: (v) =>
              ref.read(countInProvider.notifier).commit(_stops[v.round()]),
        ),
      ],
    );
  }
}

/// Staff zoom. Fewer measures per line ⇒ bigger notes: the score is always
/// engraved to the viewport width, so the two are one knob (see `staff_zoom.dart`).
///
/// Null override = auto, which fits a short piece into ~75% of the viewport.
/// The readout shows what Verovio actually achieved — its break points are
/// musical, so a dense bar can land one short of the target, hence "≈".
class _MeasuresPerLineSlider extends ConsumerWidget {
  const _MeasuresPerLineSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final override = ref.watch(measuresPerLineProvider).value;
    final achieved = ref.watch(effectiveMeasuresPerLineProvider);
    // On auto, park the thumb on whatever the renderer settled at.
    final position = (override ?? achieved ?? measuresPerLineForWidth(
            MediaQuery.sizeOf(context).width))
        .clamp(measuresPerLineMin, measuresPerLineMax);
    final readout = achieved == null
        ? (override == null ? 'Auto' : '$override')
        : (override == null ? 'Auto (≈$achieved)' : '≈$achieved');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Measures per line'),
            Row(
              children: [
                Text(readout, style: Theme.of(context).textTheme.bodySmall),
                if (override != null)
                  TextButton(
                    onPressed: () =>
                        ref.read(measuresPerLineProvider.notifier).commit(null),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('Auto'),
                  ),
              ],
            ),
          ],
        ),
        Slider(
          value: position.toDouble(),
          min: measuresPerLineMin.toDouble(),
          max: measuresPerLineMax.toDouble(),
          divisions: measuresPerLineMax - measuresPerLineMin,
          label: '$position',
          // Drag moves the state (and so re-engraves); the write to disk waits
          // for the finger to lift so a drag persists once, not per frame.
          onChanged: (v) =>
              ref.read(measuresPerLineProvider.notifier).preview(v.round()),
          onChangeEnd: (v) =>
              ref.read(measuresPerLineProvider.notifier).commit(v.round()),
        ),
      ],
    );
  }
}

/// How the fingering channel shows the string: filled chips, a coloured rule
/// under near-black numbers, or nothing.
///
/// Three styles side by side because which reads best at practice distance is a
/// question about eyes, not logic — this is here to be A/B'd on real music, the
/// same reason the density policies are.
class _StringColourPicker extends ConsumerWidget {
  const _StringColourPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(stringColourStyleProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('String colour'),
        Text('G green · D blue · A red · E yellow',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        SegmentedButton<StringColourStyle>(
          segments: const [
            ButtonSegment(
                value: StringColourStyle.chips, label: Text('Chips')),
            ButtonSegment(
                value: StringColourStyle.underline, label: Text('Underline')),
            ButtonSegment(value: StringColourStyle.off, label: Text('Off')),
          ],
          selected: {style},
          onSelectionChanged: (s) =>
              ref.read(stringColourStyleProvider.notifier).state = s.first,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
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

/// How much fingering the annotation view shows, as a three-stop slider.
///
/// A slider rather than a segmented button because the three levels are ordered
/// and nested — each shows a subset of the one before it — and "more/less" is the
/// thing being chosen. Purely a display filter, so unlike
/// [_MeasuresPerLineSlider] there's no preview/commit split: nothing is persisted
/// and nothing re-engraves.
class _FingeringDensitySlider extends ConsumerWidget {
  const _FingeringDensitySlider();

  static const _labels = ['All', 'Fewer', 'Least'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final density = ref.watch(fingeringDensityProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Fingering detail'),
            Text(_labels[density.index],
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        Slider(
          value: density.index.toDouble(),
          min: 0,
          max: (FingeringDensity.values.length - 1).toDouble(),
          divisions: FingeringDensity.values.length - 1,
          label: _labels[density.index],
          onChanged: (v) => ref.read(fingeringDensityProvider.notifier).state =
              FingeringDensity.values[v.round()],
        ),
      ],
    );
  }
}

/// Which rule decides what survives at "Fewer" and "Least".
///
/// Exposed in the UI, and only once the slider has left "All", because "crucial
/// fingering" is a pedagogical judgement that needs playing feedback to settle —
/// this control is how the two candidate definitions get compared on real music.
/// The weights behind `Difficulty` live in `fingering_density.dart`.
class _FingeringDensityPolicyPicker extends ConsumerWidget {
  const _FingeringDensityPolicyPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(fingeringDensityPolicyProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Which fingerings matter'),
        const SizedBox(height: 8),
        SegmentedButton<FingeringDensityPolicy>(
          segments: const [
            ButtonSegment(
                value: FingeringDensityPolicy.difficulty,
                label: Text('Difficulty')),
            ButtonSegment(
                value: FingeringDensityPolicy.changesAndLandmarks,
                label: Text('Changes')),
          ],
          selected: {policy},
          onSelectionChanged: (s) => ref
              .read(fingeringDensityPolicyProvider.notifier)
              .state = s.first,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }
}

/// Violin fingering vs mandolin fret, for the tab staff and the annotation
/// view's fingering channel alike — one preference, so the same control appears
/// in both sections of the drawer showing the same value.
class _NoteNumberPicker extends ConsumerWidget {
  const _NoteNumberPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(noteNumberModeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Numbers'),
        const SizedBox(height: 8),
        SegmentedButton<NoteNumberMode>(
          segments: const [
            ButtonSegment(
                value: NoteNumberMode.violinFingering,
                label: Text('Fingering')),
            ButtonSegment(
                value: NoteNumberMode.mandolinFret, label: Text('Fret')),
          ],
          selected: {mode},
          onSelectionChanged: (s) =>
              ref.read(noteNumberModeProvider.notifier).state = s.first,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }
}

/// Which string a fret sits on. Only shown in fret mode, since it has nothing to
/// say about fingerings.
///
/// In the fingering channel this also moves the chip COLOURS, because the colour
/// follows the string: "Match fingering" leaves every chip where it was and only
/// changes the digits, while "Open strings" can send a note to a different string
/// (and so a different colour) to keep its fret low.
class _FretStylePicker extends ConsumerWidget {
  const _FretStylePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(fretStyleProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Fret positions'),
        const SizedBox(height: 8),
        SegmentedButton<FretStyle>(
          segments: const [
            ButtonSegment(
                value: FretStyle.openStrings, label: Text('Open strings')),
            ButtonSegment(
                value: FretStyle.matchFingering, label: Text('Match fingering')),
          ],
          selected: {style},
          onSelectionChanged: (s) =>
              ref.read(fretStyleProvider.notifier).state = s.first,
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
              _FloatingMeasureActions(selection: selection),
              _CountInOverlay(service: widget.service, mode: displayMode),
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
                                        measures: [
                                          for (final row in widget.layout.rows)
                                            ...row
                                        ],
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
    (DisplayMode.tab, Icons.grid_4x4, 'Tab'),
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

  /// Relabels the score's meter. Note values are untouched — see
  /// [MeasureXmlEditor.setTimeSignature].
  ///
  /// No confirmation step: the change is fully reversible from the same control
  /// (unlike deleting a measure, which this otherwise mirrors), and the dialog
  /// has already shown what the new meter does to the bar totals.
  Future<void> _editTimeSignature(
      BuildContext context, WidgetRef ref, ParsedPiece parsed) async {
    final chosen = await showTimeSignatureDialog(context, piece: parsed);
    if (chosen == null || !context.mounted) return;

    final piece = ref.read(selectedPieceProvider);
    if (piece == null) return;
    final repo = ref.read(pieceRepositoryProvider);
    try {
      final original = await repo.loadMusicXml(piece);
      final newXml = MeasureXmlEditor.setTimeSignature(original,
          beats: chosen.beats, beatType: chosen.beatType);
      final updated = await repo.writeEditedMusicXml(piece, newXml);
      ref.read(selectedPieceProvider.notifier).state = updated;
      ref.invalidate(piecesProvider);
      ref.invalidate(parsedPieceProvider);
    } catch (e) {
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Could not change the time signature'),
          content: Text('$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
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
                // The meter joins the key here because this strip is the
                // piece's identity line, and because a wrong meter is something
                // you notice while looking at the staff — which is where this
                // is. Tapping opens the editor; the pencil says so, since
                // italic grey text otherwise reads as a label, not a control.
                child: InkWell(
                  key: const ValueKey('piece_meter_button'),
                  onTap: () => _editTimeSignature(context, ref, parsed),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '$keyTitle · ${parsed.beatsPerMeasure}/${parsed.beatType}',
                          style: const TextStyle(
                              fontSize: 13, fontStyle: FontStyle.italic),
                        ),
                        const SizedBox(width: 6),
                        Icon(Icons.edit_outlined,
                            size: 13, color: Theme.of(context).hintColor),
                      ],
                    ),
                  ),
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
    // Report the top-most visible run's first measure so the minimap can light
    // its (unfolded) section while scrolling the jianpu/fingering views.
    void onVisibleRun(int i) {
      final m =
          (i >= 0 && i < layout.runs.length) ? layout.runs[i].firstMeasure : null;
      if (ref.read(scrollMeasureProvider) != m) {
        ref.read(scrollMeasureProvider.notifier).state = m;
      }
    }
    // The notation is always folded, so the index↔number map is the plain
    // document order (numbers are unique).
    final measureNumbers =
        parsed == null ? const <int>[] : parsed.measures.map((m) => m.number).toList();
    // Per-section background wash (note-level edges so a mid-measure section
    // start/end splits the boundary measure). Empty without sections.
    final sectionTints = (parsed == null || sections.isEmpty)
        ? const <SectionTintRegion>[]
        : sectionTintRegions(
            measureNumbers, sections, sectionColors, parsed.measures);
    // Chord runs as labelled bars in a lane above the staff — the native renderer
    // owns the chord label now (the XML providers strip `<harmony>` for it), so
    // this list is the only thing that puts chords on the score.
    final chordRuns = (parsed == null || !ref.watch(showChordsProvider))
        ? const <ChordRunRegion>[]
        : chordRunRegions(measureNumbers, parsed);
    // Fingering labels as chips in a channel between the notes and the chord
    // lane. Built for the annotation view only, and — like the chord runs — this
    // list is now the ONLY thing that puts fingerings on the score: the XML
    // provider strips them so Verovio engraves none.
    final colourStyle = ref.watch(stringColourStyleProvider);
    final annotations = (parsed == null || mode != DisplayMode.staffFingering)
        ? const <FingeringAnnotation>[]
        : fingeringAnnotations(
            measureNumbers,
            parsed,
            density: ref.watch(fingeringDensityProvider),
            policy: ref.watch(fingeringDensityPolicyProvider),
            colourByString: colourStyle != StringColourStyle.off,
            stringLabelStyle: ref.watch(stringLabelStyleProvider),
            numberMode: ref.watch(noteNumberModeProvider),
            fretStyle: ref.watch(fretStyleProvider),
          );
    // The underline's string track spans every note, so it needs its own pass
    // over the piece — and only that style has any use for it.
    final stringRuns = (parsed == null ||
            mode != DisplayMode.staffFingering ||
            colourStyle != StringColourStyle.underline)
        ? const <StringRunRegion>[]
        : stringRunRegions(
            measureNumbers,
            parsed,
            numberMode: ref.watch(noteNumberModeProvider),
            fretStyle: ref.watch(fretStyleProvider),
          );
    // Minimap tap → scroll the staff to the (folded) run's first measure index.
    // Guard the index against a stale navTarget (e.g. after switching pieces).
    final staffNav = (navTarget == null || navTarget.run >= layout.runs.length)
        ? null
        : () {
            final run = layout.runs[navTarget.run];
            final idx = measureNumbers.indexOf(run.firstMeasure);
            return idx < 0 ? null : (index: idx, seq: navTarget.seq);
          }();
    // Build the staff via the selected renderer (native Verovio or OSMD
    // WebView), keeping one identical parameter set.
    final renderer = ref.watch(staffRendererProvider);
    // [fingeringChannel] reserves a second annotation lane and fills it with the
    // fingering chips — the annotation view's whole layout difference, now that
    // both views feed the same (fingering-stripped) xml. Reserved whether or not
    // chords are showing, so toggling chords never re-flows the page.
    Widget buildStaff(String xml, {bool fingeringChannel = false}) {
      if (renderer == StaffRenderer.verovio) {
        return StaffViewVerovio(
          musicXml: xml,
          highlightNotifier: service.currentHighlightNotifier,
          countInNotifier: service.countInNotifier,
          selection: selection,
          onMeasureTapped: (m) => _selectMeasure(ref, m),
          flaggedMeasures: flaggedMeasures,
          measureNumbers: measureNumbers,
          sectionTints: sectionTints,
          chordRuns: chordRuns,
          fingeringAnnotations: annotations,
          stringColourStyle: colourStyle,
          stringRuns: stringRuns,
          annotationLanes: fingeringChannel ? 2 : 1,
          scrollNav: staffNav,
        );
      }
      return StaffView(
        musicXml: xml,
        highlightNotifier: service.currentHighlightNotifier,
        selection: selection,
        onMeasureTapped: (m) => _selectMeasure(ref, m),
        flaggedMeasures: flaggedMeasures,
        measureNumbers: measureNumbers,
        sectionTints: sectionTints,
        scrollNav: staffNav,
      );
    }

    switch (mode) {
      case DisplayMode.staff:
        return ref.watch(staffXmlProvider).when(
          data: (xml) => xml != null
              ? buildStaff(xml)
              : const Center(child: CircularProgressIndicator()),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
        );

      case DisplayMode.staffFingering:
        return ref.watch(staffFingeringXmlProvider).when(
          data: (xml) => xml != null
              ? buildStaff(xml, fingeringChannel: true)
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

      case DisplayMode.tab:
        // Tab requires the native Verovio renderer (per-note anchors + tab
        // engraving). OSMD (macOS fallback) can't supply it.
        if (renderer != StaffRenderer.verovio) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Tab view needs the Verovio renderer.',
                  textAlign: TextAlign.center),
            ),
          );
        }
        return ref.watch(tabScoreProvider).when(
          data: (tab) => tab != null
              ? StaffViewVerovio(
                  musicXml: tab.musicXml,
                  highlightNotifier: service.currentHighlightNotifier,
                  countInNotifier: service.countInNotifier,
                  selection: selection,
                  onMeasureTapped: (m) => _selectMeasure(ref, m),
                  flaggedMeasures: flaggedMeasures,
                  measureNumbers: measureNumbers,
                  sectionTints: sectionTints,
                  chordRuns: chordRuns,
                  scrollNav: staffNav,
                  tabMode: true,
                  // Provider returns labels only in fingering mode (empty in
                  // fret mode → no swap, native frets shown).
                  tabFingerLabels:
                      tab.fingerLabels.isEmpty ? null : tab.fingerLabels,
                )
              : const Center(child: CircularProgressIndicator()),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
        );
    }
  }
}

/// The count-off for the views with no engraved time signature to sit above
/// (jianpu, fingering, combined). The staff-based views draw their own, anchored
/// to the meter — see [StaffViewVerovio]; without this the other three would
/// answer a tap on Play with a couple of seconds of silence and nothing on screen
/// to explain it.
///
/// Always returns a [Positioned], with an empty child when there is nothing to
/// count — same requirement as [_FloatingMeasureActions], for the same reason.
class _CountInOverlay extends StatelessWidget {
  const _CountInOverlay({required this.service, required this.mode});

  final PlaybackServiceBase service;
  final DisplayMode mode;

  static const _ownsItsCountIn = {
    DisplayMode.staff,
    DisplayMode.staffFingering,
    DisplayMode.tab,
  };

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 8,
      left: 0,
      right: 0,
      child: _ownsItsCountIn.contains(mode)
          ? const SizedBox.shrink()
          : Align(
              alignment: Alignment.topCenter,
              child: IgnorePointer(
                child: ValueListenableBuilder<CountInTick?>(
                  valueListenable: service.countInNotifier,
                  builder: (context, tick, _) => tick == null
                      ? const SizedBox.shrink()
                      : CountInLabel(tick: tick, height: 34),
                ),
              ),
            ),
    );
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
/// Edit + Delete actions for the selected measure, floating over the notation
/// view. Delete is here (rather than inside the measure editor) so removing a
/// stray bar — a common OMR fix — doesn't need a round trip through the editor.
class _FloatingMeasureActions extends ConsumerWidget {
  final MeasureSelection? selection;

  const _FloatingMeasureActions({required this.selection});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sel = selection;
    final canEdit = sel != null &&
        sel.isSingle &&
        ref.watch(pieceRepositoryProvider).supportsEditing;
    // A part must keep at least one measure (see MeasureXmlEditor.deleteMeasure).
    final measureCount =
        ref.watch(parsedPieceProvider).valueOrNull?.measures.length ?? 0;

    return Positioned(
      top: 8,
      right: 8,
      child: canEdit
          ? Row(
              children: [
                FloatingActionButton.extended(
                  heroTag: 'edit_measure_fab',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          EditMeasureScreen(measureNumber: sel.startMeasure),
                    ),
                  ),
                  icon: const Icon(Icons.edit, size: 18),
                  label: Text('Edit m. ${sel.startMeasure}'),
                ),
                const SizedBox(width: 8),
                FloatingActionButton.extended(
                  heroTag: 'delete_measure_fab',
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                  foregroundColor:
                      Theme.of(context).colorScheme.onErrorContainer,
                  onPressed: measureCount > 1
                      ? () => _confirmAndDelete(context, ref, sel.startMeasure)
                      : null,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Delete'),
                ),
              ],
            )
          : const SizedBox.shrink(),
    );
  }

  /// Confirms, then removes the measure from the piece's MusicXML. Destructive
  /// and there's no undo, hence the dialog.
  Future<void> _confirmAndDelete(
      BuildContext context, WidgetRef ref, int measureNumber) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete measure $measureNumber?'),
        content: const Text(
            'The bar and its notes are removed and the following bars shift '
            'back one. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final piece = ref.read(selectedPieceProvider);
    if (piece == null) return;
    final repo = ref.read(pieceRepositoryProvider);
    try {
      final original = await repo.loadMusicXml(piece);
      final newXml = MeasureXmlEditor.deleteMeasure(original, measureNumber);
      final updated = await repo.writeEditedMusicXml(piece, newXml);
      // Markers past the deleted bar shift back with it.
      final sections =
          sectionsAfterMeasureDelete(piece.sections, measureNumber);
      await repo.saveSections(piece.id, sections);
      ref.read(selectedPieceProvider.notifier).state =
          updated.copyWith(sections: sections);
      // The selected bar no longer exists (and the numbers around it moved).
      ref.read(measureSelectionProvider.notifier).state = null;
      ref.invalidate(piecesProvider);
      ref.invalidate(parsedPieceProvider);
    } catch (e) {
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Could not delete measure'),
          content: Text('$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }
}

