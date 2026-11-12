import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../build_info.dart';
import '../models/section_run_groups.dart';
import '../models/count_in.dart';
import '../models/engraved_measure_map.dart';
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
import '../models/piece_media.dart';
import '../services/abc_converter.dart';
import '../services/fingering_annotation_builder.dart';
import '../services/keep_awake.dart';
import '../services/measure_xml_editor.dart';
import '../services/midi_generator.dart';
import '../services/musicxml_parser.dart';
import '../services/nonstandard_fingerings.dart';
import '../services/playback_service_base.dart';
import '../services/providers.dart';
import '../services/instrument_setting.dart';
import '../services/media_catalog.dart';
import '../services/media_playback_service.dart';
import '../services/staff_overlays.dart';
import '../services/staff_zoom.dart';
import '../widgets/count_in_label.dart';
import '../widgets/fingering_view.dart';
import '../widgets/floating_video_overlay.dart';
import '../widgets/jianpu_view.dart';
import '../widgets/new_chords_block.dart';
import '../widgets/media_controls.dart';
import '../widgets/notation_switcher.dart';
import '../widgets/preamble_preview.dart';
import '../widgets/print_sheet.dart';
import '../widgets/section_chip_row.dart';
import '../widgets/section_minimap.dart';
import '../widgets/tempo_controls.dart';
import '../widgets/staff_view.dart';
import '../widgets/staff_view_verovio.dart';
import '../widgets/time_signature_dialog.dart';

class PieceDetailScreen extends ConsumerStatefulWidget {
  const PieceDetailScreen({super.key});

  @override
  ConsumerState<PieceDetailScreen> createState() => _PieceDetailScreenState();

  // "Am" → "A minor", "Bb" → "B♭ major", "G" → "G major"
  // "Amix" → "A mixolydian", "F#m" → "F♯ minor", "Bb" → "B♭ major". The suffix
  // is whatever MusicXmlParser.keyName appended for the mode.
  //
  // On the widget rather than its State because _KeyMeterButton calls it by
  // name from outside, and a State class is private to the screen.
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

/// Stateful only to own the wakelock. The screen is read from for minutes at a
/// time without a touch — the player is looking at the score, not the phone —
/// so the idle timer has to be held off for as long as a piece is open, rather
/// than only while the app's own playback runs. Most practice happens with the
/// audio off.
///
/// The hook sits on the screen and not on either layout because the two
/// branches disagree in shape: the compact one is a widget with state, the wide
/// one is a bare `Column`. One owner above both is the only place that covers
/// them equally and releases on every way out.
///
/// No `WidgetsBindingObserver`: iOS applies `isIdleTimerDisabled` only while
/// the app is frontmost and Android scopes `FLAG_KEEP_SCREEN_ON` to the window,
/// so backgrounding already suspends this without help.
class _PieceDetailScreenState extends ConsumerState<PieceDetailScreen> {
  // Outlives the compact layout, which a rotation rebuilds from scratch.
  final _drawers = _CompactDrawerMemo();

  @override
  void initState() {
    super.initState();
    KeepAwake.enable();
  }

  @override
  void dispose() {
    KeepAwake.disable();
    super.dispose();
  }

  Map<int, String> _sectionLabels(Piece piece) {
    return {for (final s in piece.sections) s.startMeasure: s.label};
  }

  @override
  Widget build(BuildContext context) {
    final piece = ref.watch(selectedPieceProvider);
    final layoutAsync = ref.watch(pieceLayoutProvider);
    final displayMode = ref.watch(displayModeProvider);
    final features = ref.watch(instrumentFeaturesProvider);
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

    // What's playing this piece. An inline choice, not a separate screen —
    // everything about the staff (fingering/chords/sections/tabs) stays as-is;
    // only the cursor's clock source and the transport in the bottom tray
    // change with it.
    //
    // The list always holds at least [PieceMedia.synthesized], so there is
    // always something selected and no "no media" state to handle. While the
    // list is still loading, the synthesized score stands in — it is what the
    // list will start with anyway, so nothing flickers.
    final mediaList = ref.watch(pieceMediaProvider(piece.id)).valueOrNull ??
        const [PieceMedia.synthesized];
    final selectedMedia = MediaCatalog.resolve(
        mediaList, ref.watch(selectedMediaIdProvider(piece.id)));
    final mediaService =
        selectedMedia.isSynthesized ? null : ref.watch(mediaPlaybackServiceProvider);

    // The highlight settings (lead, every-note) are applied by the service
    // providers themselves — see `_followHighlightSettings` in providers.dart.
    // The lead is autoDispose, and with the score selected nothing else
    // listens to it (no recording service, no slider), so hold it here for the
    // whole visit — otherwise score → recording would reset it to 60.
    ref.listen(highlightLeadMsProvider, (_, _) {});

    // The one service every view reads its highlight from.
    //
    // This used to be `playbackServiceProvider` unconditionally, with the
    // audio-driven notifier patched over the top of the staff view alone via a
    // `highlightNotifierOverride`. The jianpu view, the fingering view and the
    // section minimap were left reading the metronome service, which during
    // Play Along is not the thing making the sound — so they sat still, or
    // followed a clock nobody could hear. Passing the active service down
    // instead means every view follows whatever is actually playing, and the
    // override is gone. The same choice as `mediaService ?? service`, from the
    // provider that anything else needing "what is playing" also reads.
    final PlaybackServiceBase activeService =
        ref.watch(activePlaybackServiceProvider);

    // The synthesized tempo, from the tray's preset picker at this piece's
    // performance tempo. Checked against the service so an unchanged rebuild
    // doesn't regenerate (setTempo does).
    final bpm = ref.watch(tempoBpmProvider);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (service.currentBpm != bpm) service.setTempo(bpm);
    });

    // Phone in any orientation: short side < 600pt. iPad min is 768pt. Taken
    // from MediaQuery rather than the body's LayoutBuilder so the app bar — which
    // is outside it — reaches the same verdict as the layout beneath it.
    final screen = MediaQuery.sizeOf(context);
    final useCompact = screen.width < 600 || screen.height < 600;

    // The staff zoom is saved per orientation, so the provider that reads it
    // needs to know which way up we are. Pushed from here rather than read in
    // the provider, which has no MediaQuery — the same arrangement as
    // measuresPerRowProvider below. Taken from the SCREEN, not the body's box:
    // it has to mean "how is the device being held".
    final orientation = screen.width >= screen.height
        ? StaffOrientation.landscape
        : StaffOrientation.portrait;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (ref.read(staffOrientationProvider) != orientation) {
        ref.read(staffOrientationProvider.notifier).state = orientation;
      }
    });

    return Scaffold(
      // The count-off takes over the whole bar while it runs — back arrow,
      // title and icons alike — as one extra line of music above the score.
      appBar: _CountInOverBar(
        service: activeService,
        bar: AppBar(
        toolbarHeight: kDebugMode ? 64 : 56,
        titleSpacing: 8,
        centerTitle: true,
        // The title line does triple duty on a tablet: what the piece is, what
        // key and meter it's in, and the handle on the note vocabulary. All
        // three used to own a strip of their own below the bar; none of them
        // needs one.
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The clef/key/time the staff itself no longer shows — see
            // `_hidePreambleFor` (services/providers.dart), which strips it
            // from the main render so its width goes to notes instead. Sized
            // to fill the toolbar height, since it's the whole point of this
            // widget and there's no other content competing for that space.
            // The key's name, and the fingerings off the hand's basic shape,
            // ride just ahead of it — see [_KeySummary].
            const _KeySummary(),
            const SizedBox(width: 6),
            const PreamblePreview(height: kDebugMode ? 64 : 56),
            const SizedBox(width: 8),
            // An invisible copy of the key block on the left, so the title
            // lands on the true centre instead of being shoved off it by the
            // key's width. The width has to be mirrored rather than guessed:
            // it's as long as the key name, and "C♯ minor · 6/8" is half again
            // "G · 4/4".
            if (!useCompact) ...[
              const _KeyMeterButton(mirror: true),
              const SizedBox(width: 12),
            ],
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(piece.title,
                      style: const TextStyle(fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (kDebugMode)
                    Text(kBuildRef,
                        style: TextStyle(
                            fontSize: 9,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45))),
                ],
              ),
            ),
            if (!useCompact) ...[
              const SizedBox(width: 12),
              const _KeyMeterButton(),
            ],
            // Mirrors the leading preview, same reasoning as the key block's
            // own mirror above. Not on a phone: there the title can't afford
            // to give up the preview's width twice, and centring the group
            // rather than the title alone is a fair price for reading it.
            if (!useCompact) ...[
              const SizedBox(width: 8),
              const PreamblePreview(mirror: true, height: kDebugMode ? 64 : 56),
              const SizedBox(width: 6),
              const _KeySummary(mirror: true),
            ],
          ],
        ),
        actions: [
          _NotePaletteToggle(compact: useCompact),
          // A phone's bar has no room to spare (the title gives it up first);
          // there Print lives in the drawer only.
          if (!useCompact && printAvailableFor(ref, displayMode))
            IconButton(
              key: const ValueKey('print_button'),
              tooltip: 'Print',
              icon: const Icon(Icons.print_outlined),
              onPressed: () => showPrintSheet(context, displayMode),
            ),
          // No mode toggles here any more. "Play Along", "Teacher Demo" and
          // "record a demo" were three app-bar buttons for what is one
          // question — what should play this piece — and two of them had to be
          // kept mutually exclusive by hand. All three are now entries in the
          // tray's media picker, next to the synthesized score and any
          // imported file, which is also where a new one gets added.
          Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
        ],
      ),
      ),
      endDrawer: Drawer(
        child: SafeArea(
          // One place to make everything in the tray smaller. The tray gained
          // the view picker and has to hold the whole fingering section under it
          // without a scroll on a tablet, so the sliders give up the height they
          // were spending on touch slop they don't need — this is a drawer, not
          // a control you hit while playing.
          child: Theme(
            data: Theme.of(context).copyWith(
              visualDensity: VisualDensity.compact,
              sliderTheme: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              dividerTheme: const DividerThemeData(space: 16),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // First because it's the setting that decides which of the
                  // ones below it even apply. The gear icon is now the only way
                  // to change view, so it can't be buried.
                  const _DrawerLabel('View'),
                  NotationSwitcher(
                    current: displayMode,
                    showTab: features.tabView,
                    onChanged: (mode) =>
                        ref.read(displayModePrefProvider.notifier).state = mode,
                  ),
                  // Second because it is the other question that decides what
                  // everything else says: which instrument the numbers are
                  // for. Shown in every view — the title line and the
                  // vocabulary follow it whatever the view. See
                  // [NoteNumberMode]. Only when the instrument setting has
                  // mandolin frets; otherwise the numbers are violin fingering.
                  const SizedBox(height: 12),
                  if (features.fretNumbers) ...[
                    const _NoteNumberPicker(),
                    const SizedBox(height: 12),
                  ],
                  if (ref.watch(noteNumberModeProvider) ==
                      NoteNumberMode.mandolinFret)
                    const _FretStylePicker()
                  else
                    const _ViolinStringPicker(),
                  const Divider(),
                  // Never hidden behind a display mode: it's the one setting
                  // here that's about playing along rather than about how the
                  // notation looks.
                  const _CountInSlider(),
                  const Divider(),
                  if (selectedMedia.isSynthesized) ...[
                    const TempoSettingsPanel(),
                    const Divider(),
                  ],
                  // Every note, or each bar's first. Shown for synthesized
                  // playback too: there the timing is exact, so per-note
                  // highlighting is the natural choice — it used to be
                  // reachable only with a recording selected, leaving MIDI
                  // stuck on downbeats.
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Highlight every note'),
                    subtitle: const Text('Off: first note of each bar'),
                    value: ref.watch(highlightEveryNoteProvider),
                    onChanged: (v) {
                      ref.read(highlightEveryNoteProvider.notifier).state = v;
                    },
                  ),
                  // The lead setting is about following a real recording, so it
                  // appears precisely when one is selected.
                  //
                  // The gate used to be `audioSyncFolder != null` — the
                  // presence of a BUNDLED asset folder. A piece whose only
                  // audio was a recorded demo therefore couldn't reach either
                  // setting, and the wiring underneath only ever pushed the
                  // value into the Play Along service, so opening the gate
                  // alone would not have helped. Now there is one service to
                  // push to and one condition that describes what the settings
                  // actually do.
                  if (!selectedMedia.isSynthesized) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Highlight lead'),
                        Text('${ref.watch(highlightLeadMsProvider).round()} ms',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                    Slider(
                      value: ref.watch(highlightLeadMsProvider),
                      min: 0,
                      max: 300,
                      divisions: 15,
                      onChanged: (v) =>
                          ref.read(highlightLeadMsProvider.notifier).state = v,
                    ),
                    const Divider(),
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
                    divisions:
                        ((staffSpacingMax - staffSpacingMin) / 0.05).round(),
                    onChanged: (v) =>
                        ref.read(staffSpacingProvider.notifier).state = v,
                  ),
                  if (displayMode == DisplayMode.staff ||
                      displayMode == DisplayMode.staffFingering ||
                      displayMode == DisplayMode.tab) ...[
                    // Tab is never laid out by section (its xml carries no
                    // section breaks — see [staffBySectionProvider]).
                    if (displayMode != DisplayMode.tab &&
                        ref.watch(printedLayoutAvailableProvider))
                      SwitchListTile(
                        key: const ValueKey('printed_layout_toggle'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Layout like printed page'),
                        value: ref.watch(printedLayoutProvider),
                        onChanged: (v) =>
                            ref.read(printedLayoutProvider.notifier).state = v,
                      ),
                    if (displayMode != DisplayMode.tab &&
                        ref.watch(sectionLayoutAvailableProvider) &&
                        !ref.watch(staffByPrintedLinesProvider))
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Layout by section'),
                        value: ref.watch(sectionLayoutProvider),
                        onChanged: (v) =>
                            ref.read(sectionLayoutProvider.notifier).state = v,
                      ),
                    if (displayMode != DisplayMode.tab)
                      const Row(children: [
                        Text('Sections:'),
                        _RedetectSectionsButton(),
                        _ClearSectionsButton(),
                      ]),
                    if (printAvailableFor(ref, displayMode))
                      ListTile(
                        key: const ValueKey('print_drawer_tile'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: const Icon(Icons.print_outlined),
                        title: const Text('Print or share PDF…'),
                        onTap: () {
                          Navigator.of(context).pop(); // the drawer
                          showPrintSheet(context, displayMode);
                        },
                      ),
                    _MeasuresPerLineSlider(
                      bySection: displayMode != DisplayMode.tab &&
                          (ref.watch(staffBySectionProvider) ||
                              ref.watch(staffByPrintedLinesProvider)),
                    ),
                    // Guaranteed-exact breaks aren't wired up for the tab
                    // view (see `system_break_injector.dart`'s callers) —
                    // only offer it where it actually takes effect. The
                    // section layout's breaks are exact already.
                    if (displayMode != DisplayMode.tab &&
                        !ref.watch(staffBySectionProvider) &&
                        !ref.watch(staffByPrintedLinesProvider))
                      const _MeasuresPerLineLockToggle(),
                    if (features.chords)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Chord symbols'),
                        value: ref.watch(showChordsProvider),
                        onChanged: (v) =>
                            ref.read(showChordsPrefProvider.notifier).state = v,
                      ),
                    if (displayMode != DisplayMode.tab)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Colour notes by string'),
                        value: ref.watch(colourNoteheadsByStringProvider),
                        onChanged: (v) => ref
                            .read(colourNoteheadsByStringProvider.notifier)
                            .state = v,
                      ),
                    if (displayMode != DisplayMode.tab &&
                        ref.watch(pieceVerseCountProvider) > 0)
                      const _LyricVersePicker(),
                  ],
                  if (displayMode == DisplayMode.staffFingering) ...[
                    const Divider(),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Note names'),
                      value: ref.watch(showNoteNamesProvider),
                      onChanged: (v) {
                        ref.read(showNoteNamesProvider.notifier).state = v;
                        final spacing = ref.read(staffSpacingProvider.notifier);
                        if (v && spacing.state < staffSpacingWithNoteNames) {
                          spacing.state = staffSpacingWithNoteNames;
                        }
                      },
                    ),
                    const _StringColourPicker(),
                    // Only meaningful while the letter is actually drawn — while
                    // a colour is carrying the string, the label doesn't repeat
                    // it.
                    if (ref.watch(stringColourStyleProvider) ==
                        StringColourStyle.off) ...[
                      const SizedBox(height: 12),
                      const _StringLabelPicker(),
                    ],
                    const SizedBox(height: 12),
                    const _FingeringDensitySlider(),
                    if (ref.watch(fingeringDensityProvider) !=
                        FingeringDensity.all) ...[
                      const SizedBox(height: 12),
                      const _FingeringDensityPolicyPicker(),
                    ],
                  ],
                ],
              ),
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
                service: activeService,
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
              // The two providers resolve separately: while they disagree
              // (a piece just switched), fold without the D.C. rather than
              // index runs that aren't there.
              final foldedRuns =
                  ref.watch(sectionRunGroupsProvider).valueOrNull ?? const [];
              final runGroups = unfoldedRuns.isEmpty
                  ? const <RunGroup>[]
                  : foldedRuns.isNotEmpty &&
                          foldedRuns.last.lastRun == unfoldedRuns.length - 1
                      ? foldedRuns
                      : foldRunGroups(unfoldedRuns);
              // Edit/Delete now live at the top of this rail (see
              // SectionMinimap's header), so a piece with no sections still
              // needs the rail the moment a measure is selected — otherwise
              // those actions would have nowhere to appear.
              final canEditSelection = selection != null &&
                  selection.isSingle &&
                  ref.watch(pieceRepositoryProvider).supportsEditing;
              void onTapSpan(int first, int last) {
                final run = unfoldedRuns[first];
                final picked =
                    MeasureSelection.ofRuns(run, unfoldedRuns[last]);
                final selection = ref.read(measureSelectionProvider.notifier);
                // Tapping the selected section again clears it, back to how
                // the piece opens.
                if (selection.state == picked) {
                  selection.state = null;
                  return;
                }
                selection.state = picked;
                final foldedIdx = layout.runs.indexWhere((r) =>
                    run.firstMeasure >= r.firstMeasure &&
                    run.firstMeasure <= r.lastMeasure);
                if (foldedIdx >= 0) {
                  final cur = ref.read(navTargetRunProvider);
                  ref.read(navTargetRunProvider.notifier).state =
                      (run: foldedIdx, seq: (cur?.seq ?? 0) + 1);
                }
              }

              // One section: the same as a span of just that run.
              void onTapRun(int i) => onTapSpan(i, i);

              final hasSectionUi = unfoldedRuns.isNotEmpty || canEditSelection;

              if (useCompact) {
                // On a phone the sections are a chip row in the play tray, not
                // a rail over the music (see SectionChipRow).
                return Column(children: [
                  const _PalettePanel(),
                  Expanded(child: _CompactPieceLayout(
                  notationView: notationView,
                  sectionRowHasStrip:
                      runGroups.any((g) => g.isLoop || g.isJump),
                  sectionRow: !hasSectionUi
                      ? null
                      : SectionChipRow(
                          runs: unfoldedRuns,
                          groups: runGroups,
                          sectionColors: sectionColors,
                          service: activeService,
                          onTapRun: onTapRun,
                          onTapSpan: onTapSpan,
                        ),
                  drawers: _drawers,
                  layout: layout,
                  piece: piece,
                  service: activeService,
                  displayMode: displayMode,
                  media: mediaList,
                  selectedMedia: selectedMedia,
                  mediaService: mediaService,
                  )),
                ]);
              }

              final minimap = !hasSectionUi
                  ? null
                  : SectionMinimap(
                      runs: unfoldedRuns,
                      groups: runGroups,
                      sectionColors: sectionColors,
                      service: activeService,
                      onTapRun: onTapRun,
                      onTapSpan: onTapSpan,
                    );

              return Column(
                children: [
                  const _PalettePanel(),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: Stack(
                            children: [
                              Positioned.fill(child: notationView),
                              // Any medium with a video gets the window: a
                              // recorded demo, or an imported mp4.
                              if (selectedMedia.video != null &&
                                  mediaService != null)
                                FloatingVideoOverlay(service: mediaService),
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
                  // No section pills here: the minimap down the right-hand edge
                  // shows the same sections, unfolded and in proportion, and
                  // selects the same practice range on a tap.
                  MediaControls(
                    piece: piece,
                    media: mediaList,
                    selected: selectedMedia,
                  ),
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

}

/// Small caps-ish heading for a group of tray controls. The tray's own controls
/// mostly label themselves; this exists for the ones that are a bare row of
/// chips with nothing to say what they choose between.
class _DrawerLabel extends StatelessWidget {
  const _DrawerLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600)),
    );
  }
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
        // A recording counts in over its own intro when it has one; this is
        // what fills the count when it doesn't, or when starting mid-piece.
        if (plan != null) ...[
          Text('With a recording',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          SegmentedButton<RecordingLeadInMode>(
            key: const ValueKey('recording_lead_in_picker'),
            segments: const [
              ButtonSegment(
                  value: RecordingLeadInMode.silent, label: Text('Silent')),
              ButtonSegment(
                  value: RecordingLeadInMode.preroll,
                  label: Text('Play bars before')),
            ],
            selected: {ref.watch(recordingLeadInProvider)},
            onSelectionChanged: (s) =>
                ref.read(recordingLeadInProvider.notifier).set(s.first),
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ],
    );
  }
}

/// Staff zoom. Fewer measures per line ⇒ bigger notes: the score is always
/// engraved to the viewport width, so the two are one knob (see `staff_zoom.dart`).
///
/// Null override = auto: the whole piece on one screen if that can be had
/// without shrinking the notes past the device's minimum physical size, and that
/// minimum otherwise (bigger notes and a scroll, rather than an illegible page).
/// The floor is per device class — see `minStaffScaleFor` in `staff_zoom.dart`.
///
/// The readout shows what Verovio actually achieved — its break points are
/// musical, so a dense bar can land one short of the target, hence "≈".
///
/// Saved per piece AND per orientation: the same count is a very different note
/// size in landscape, where the score has nearly twice the width to fill. A
/// caption under the label names which one is being edited. Pinching the staff
/// drives this same setting (see `staff_view_verovio.dart`), so the thumb tracks
/// a pinch.
///
/// [bySection]: the piece is laid out by section ([staffBySectionProvider]), and
/// the same slider sets lines per section instead ([linesPerSectionProvider]):
/// auto is the fewest lines that fit at the minimum note size, and more lines
/// mean bigger notes. Its breaks are exact, so its readout never says "≈".
class _MeasuresPerLineSlider extends ConsumerWidget {
  const _MeasuresPerLineSlider({required this.bySection});

  final bool bySection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider =
        bySection ? linesPerSectionProvider : measuresPerLineProvider;
    final min = bySection ? linesPerSectionMin : measuresPerLineMin;
    final max = bySection ? linesPerSectionMax : measuresPerLineMax;
    final zoom = ref.watch(provider);
    final override = zoom.value;
    final achieved = ref.watch(bySection
        ? effectiveLinesPerSectionProvider
        : effectiveMeasuresPerLineProvider);
    final orientation = ref.watch(staffOrientationProvider);
    // On auto, park the thumb on whatever the renderer settled at.
    final position = (override ??
            achieved ??
            (bySection
                ? linesPerSectionMin
                : measuresPerLineForWidth(MediaQuery.sizeOf(context).width)))
        .clamp(min, max);
    // Locked is guaranteed exact (explicit system breaks), so it drops the
    // "≈" the approximate auto-breaking modes carry; so is the section layout.
    final exact = bySection || zoom.locked;
    final readout = exact && override != null
        ? '$override'
        : (achieved == null
            ? (override == null ? 'Auto' : '$override')
            : override == null
                ? (exact ? 'Auto ($achieved)' : 'Auto (≈$achieved)')
                : '≈$achieved');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // The orientation is named because the setting is saved per
            // orientation: without it, setting a zoom and then rotating to find
            // a different one reads as a bug rather than as the feature.
            //
            // Flexible, and on its own line rather than appended to the label:
            // the drawer is only ~218pt wide on a phone in landscape, and
            // "Measures per line, landscape" on one line overflows the row and
            // pushes the Auto button off the edge.
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(bySection ? 'Lines per section' : 'Measures per line'),
                  Text(orientation.name,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Row(
              children: [
                Text(readout, style: Theme.of(context).textTheme.bodySmall),
                if (override != null)
                  TextButton(
                    onPressed: () =>
                        ref.read(provider.notifier).commit(null),
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
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          label: '$position',
          // Drag moves the state (and so re-engraves); the write to disk waits
          // for the finger to lift so a drag persists once, not per frame.
          onChanged: (v) => ref.read(provider.notifier).preview(v.round()),
          onChangeEnd: (v) => ref.read(provider.notifier).commit(v.round()),
        ),
      ],
    );
  }
}

/// Guarantees the measures-per-line count above exactly, via explicit
/// MusicXML system breaks (`insertSystemBreaksEvery`) and Verovio's
/// `breaks: 'encoded'`, instead of the ordinary `scale`-solved approximation
/// (see `_MeasuresPerLineSlider`'s "≈N" readout). Only meaningful against an
/// explicit value, so it's disabled on "Auto".
class _MeasuresPerLineLockToggle extends ConsumerWidget {
  const _MeasuresPerLineLockToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zoom = ref.watch(measuresPerLineProvider);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: const Text('Lock exactly'),
      value: zoom.locked,
      onChanged: zoom.value == null
          ? null
          : (v) => ref
              .read(measuresPerLineProvider.notifier)
              .commit(zoom.value, locked: v),
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
/// Which lyric verse the staff and annotated views engrave, or none. Only
/// shown for a piece that has lyrics. Experimental: a change re-engraves, so
/// the page can reflow — see [lyricVerseProvider].
/// Runs section detection again over the open piece (see
/// [PieceRepository.redetectSections]) and, once confirmed, replaces its
/// sections. The only way an existing piece gets a newer detector: import is
/// the only other place detection runs, and nothing records whether the
/// sections it would replace were detected or placed by hand.
class _RedetectSectionsButton extends ConsumerWidget {
  const _RedetectSectionsButton();

  static String _describe(List<Section> sections) => sections.isEmpty
      ? 'none'
      : [
          for (final s in sections)
            s.startNote > 0
                ? '${s.label}: bar ${s.startMeasure}, note ${s.startNote + 1}'
                : '${s.label}: bar ${s.startMeasure}',
        ].join('\n');

  Future<void> _redetect(BuildContext context, WidgetRef ref) async {
    // The drawer can rebuild this button away while the dialog is up, taking
    // its `ref` with it; the container outlives it.
    final container = ProviderScope.containerOf(context, listen: false);
    final piece = container.read(selectedPieceProvider);
    if (piece == null) return;
    final messenger = ScaffoldMessenger.of(context);
    void say(String text) =>
        messenger.showSnackBar(SnackBar(content: Text(text)));

    final List<Section> found;
    try {
      String? sourceXml;
      final abc = await container.read(abcSourceStoreProvider).read(piece.id);
      if (abc != null) {
        final converter = AbcConverter();
        try {
          sourceXml = (await converter.convert(abc)).musicXml;
        } catch (_) {
          // Detect from the piece alone.
        } finally {
          converter.dispose();
        }
      }
      found = await container
          .read(pieceRepositoryProvider)
          .redetectSections(piece, sourceXml: sourceXml);
    } catch (e) {
      say('Could not detect sections: $e');
      return;
    }
    if (listEquals(found, piece.sections)) {
      say('Sections already match what detection finds.');
      return;
    }
    if (found.isEmpty) {
      say('No sections found; left as they are.');
      return;
    }
    if (piece.sections.isNotEmpty) {
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Replace sections?'),
          content: Text('Now:\n${_describe(piece.sections)}\n\n'
              'Detected:\n${_describe(found)}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const ValueKey('redetect_sections_replace'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await container.read(pieceRepositoryProvider).saveSections(piece.id, found);
    container.read(selectedPieceProvider.notifier).state =
        piece.copyWith(sections: found);
    container.invalidate(piecesProvider);
    container.invalidate(parsedPieceProvider);
    say('Sections re-detected.');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton.icon(
        key: const ValueKey('redetect_sections'),
        style: _sectionButtonStyle,
        icon: const Icon(Icons.auto_fix_high, size: 18),
        label: const Text('Re-detect'),
        onPressed: () => _redetect(context, ref),
      );
}

/// Compact, so "Sections:" and both its buttons share one drawer row.
final _sectionButtonStyle = TextButton.styleFrom(
  padding: const EdgeInsets.symmetric(horizontal: 6),
  visualDensity: VisualDensity.compact,
);

/// Removes every section from the open piece, once confirmed — a clean slate
/// for marking sections by hand when detection's guess is further off than
/// it is worth correcting. Saved as an empty override, so a bundled piece's
/// own sections don't come back either.
class _ClearSectionsButton extends ConsumerWidget {
  const _ClearSectionsButton();

  Future<void> _clear(BuildContext context) async {
    // As for [_RedetectSectionsButton]: the container outlives the drawer.
    final container = ProviderScope.containerOf(context, listen: false);
    final piece = container.read(selectedPieceProvider);
    if (piece == null || piece.sections.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete all sections?'),
        content: Text('This removes all ${piece.sections.length} sections '
            'from "${piece.title}". Re-detect can find them again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('clear_sections_confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await container.read(pieceRepositoryProvider).saveSections(piece.id, []);
    container.read(selectedPieceProvider.notifier).state =
        piece.copyWith(sections: const []);
    container.invalidate(piecesProvider);
    container.invalidate(parsedPieceProvider);
    messenger.showSnackBar(const SnackBar(content: Text('Sections deleted.')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSections =
        ref.watch(selectedPieceProvider)?.sections.isNotEmpty ?? false;
    return TextButton.icon(
      key: const ValueKey('clear_sections'),
        style: _sectionButtonStyle,
      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
      label: const Text('Delete all'),
      onPressed: hasSections ? () => _clear(context) : null,
    );
  }
}

class _LyricVersePicker extends ConsumerWidget {
  const _LyricVersePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pieceVerseCountProvider);
    final verse = ref.watch(lyricVerseProvider);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('Lyrics'),
        DropdownButton<int?>(
          value: verse != null && verse > count ? null : verse,
          isDense: true,
          items: [
            const DropdownMenuItem<int?>(value: null, child: Text('Off')),
            for (var v = 1; v <= count; v++)
              DropdownMenuItem<int?>(value: v, child: Text('Verse $v')),
          ],
          onChanged: (v) => ref.read(lyricVerseProvider.notifier).state = v,
        ),
      ],
    );
  }
}

class _NoteNumberPicker extends ConsumerWidget {
  const _NoteNumberPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(noteNumberModeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _DrawerLabel('Instrument'),
        SegmentedButton<NoteNumberMode>(
          key: const ValueKey('instrument_picker'),
          segments: const [
            ButtonSegment(
                value: NoteNumberMode.violinFingering,
                label: Text('Violin')),
            ButtonSegment(
                value: NoteNumberMode.mandolinFret, label: Text('Mandolin')),
          ],
          selected: {mode},
          onSelectionChanged: (s) =>
              ref.read(noteNumberModePrefProvider.notifier).state = s.first,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }
}

/// Open string or 4th finger, for the notes that could be either. Only shown
/// for the violin; the mandolin's counterpart is [_FretStylePicker].
class _ViolinStringPicker extends ConsumerWidget {
  const _ViolinStringPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pref = ref.watch(violinStringPreferenceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Prefer'),
        const SizedBox(height: 8),
        SegmentedButton<ViolinStringPreference>(
          key: const ValueKey('violin_string_picker'),
          segments: const [
            ButtonSegment(
                value: ViolinStringPreference.openStrings,
                label: Text('Open strings')),
            ButtonSegment(
                value: ViolinStringPreference.fourthFinger,
                label: Text('4th finger')),
          ],
          selected: {pref},
          onSelectionChanged: (s) =>
              ref.read(violinStringPreferenceProvider.notifier).state = s.first,
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

// ── Compact (phone) layout: music fills screen, controls are drawers over it ──
//
// On a phone every point of the score's box is worth having, so the play tray
// takes none of it: it is an overlay, sliding up over the score from the
// bottom, and the score is laid out once at the full body size (a shorter box
// is fine, but a narrower one would re-engrave it, since the staff reflows on
// width). Put away, it leaves a small tab on the bottom edge.
//
// The sections ride in the tray too, as a chip row above the play bar
// ([SectionChipRow]). They used to be a rail drawer down the right edge, but
// even put away its tab sat over the music, and choosing a section is done
// with the play controls anyway.
//
// The tray peeks: it's out when the piece opens and slides away a few seconds
// later, so the first thing you see is that it exists and where it went.
// Touching it during its peek keeps it out.

/// Where the compact layout's drawers were left, held by the screen rather than
/// the layout: a rotation rebuilds the layout from scratch, and it should come
/// back as it was — no second peek, and the drawers out only if they were out.
class _CompactDrawerMemo {
  bool trayPeeked = false;
  bool trayShown = true;
}

class _CompactPieceLayout extends ConsumerStatefulWidget {
  final Widget notationView;
  final _CompactDrawerMemo drawers;
  /// The section chips, on top of the play bar; null when the piece has no
  /// sections and nothing to edit.
  final Widget? sectionRow;

  /// [sectionRow] has a loop / D.C. strip over its chips (see
  /// [SectionChipRow.heightWithLoops]), which can tuck under the tray's edge.
  final bool sectionRowHasStrip;

  final PieceLayout layout;
  final Piece piece;
  final PlaybackServiceBase service;
  final DisplayMode displayMode;

  /// Everything this piece can be played by, and which of them is. The tray's
  /// picker needs the list; the video window and the highlight need the
  /// selection.
  final List<PieceMedia> media;
  final PieceMedia selectedMedia;

  /// Null exactly when [selectedMedia] is the synthesized score — there is no
  /// file-backed service in that case.
  final MediaPlaybackService? mediaService;

  const _CompactPieceLayout({
    required this.notationView,
    required this.sectionRow,
    required this.sectionRowHasStrip,
    required this.drawers,
    required this.layout,
    required this.piece,
    required this.service,
    required this.displayMode,
    required this.media,
    required this.selectedMedia,
    required this.mediaService,
  });

  @override
  ConsumerState<_CompactPieceLayout> createState() =>
      _CompactPieceLayoutState();
}

class _CompactPieceLayoutState extends ConsumerState<_CompactPieceLayout> {
  static bool _hasPeeked = false;
  static const _slide = Duration(milliseconds: 250);

  /// How far a section row with a loop strip tucks up under the tray's top
  /// edge — its arcs then sit beside the chevron rather than below it.
  static const double _tuck = 8;
  static const _peekFor = Duration(milliseconds: 3000);

  final _trayKey = GlobalKey();
  bool _sheetOpen = false;

  // Out, for the peek — or, after a rotation, as it was left.
  late bool _trayShown = widget.drawers.trayShown;
  Timer? _trayPeek;
  double _trayHeight = 72;

  // What the tray covers right now (nothing, once it's put away) → the staff's
  // autoscroll; the most it has ever covered → every view's trailing scroll
  // room. Neither resizes the score.
  void _publishInset() {
    ref.read(staffViewBottomInsetProvider.notifier).state =
        _trayShown ? _trayHeight : 0;
    final clearance = ref.read(notationBottomClearanceProvider.notifier);
    if (_trayHeight > clearance.state) clearance.state = _trayHeight;
  }

  void _measureTray() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _trayKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        setState(() => _trayHeight = box.size.height);
        _publishInset();
      }
    });
  }

  // Closes the sheet and re-measures the tray AFTER the AnimatedSize animation
  // (250 ms) finishes. Measuring immediately captures the pre-collapse height.
  void _closeSheet() {
    if (!_sheetOpen) return;
    setState(() => _sheetOpen = false);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _measureTray();
    });
  }

  // No measuring here: the tray's SizeChangedLayoutNotifier re-measures it on
  // every frame of the drawer's growth.
  void _openSheet() {
    if (_sheetOpen) return;
    setState(() => _sheetOpen = true);
  }

  void _setTray(bool shown) {
    _trayPeek?.cancel();
    if (_trayShown == shown) return;
    setState(() => _trayShown = widget.drawers.trayShown = shown);
    if (!shown) _closeSheet();
    _publishInset();
  }

  @override
  void initState() {
    super.initState();
    // Seed a conservative estimate before the first frame, and drop the
    // clearance a previous piece left behind. Post-frame to avoid mutating a
    // provider during tree build.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(notationBottomClearanceProvider.notifier).state = 0;
      _publishInset();
    });
    _measureTray();
    // Each peek is spent once its retreat is scheduled: a rebuilt layout
    // doesn't peek again.
    if (!widget.drawers.trayPeeked) {
      widget.drawers.trayPeeked = true;
      _trayPeek = Timer(_peekFor, () {
        if (mounted) _setTray(false);
      });
    }
  }

  @override
  void dispose() {
    _trayPeek?.cancel();
    super.dispose();
  }

  // The one-time peek that says "there is a chord drawer here". Driven from
  // build rather than initState because what's IN the drawer depends on the
  // parsed piece, which is still a pending future when initState runs — peeking
  // then would open an empty panel on every piece and teach the opposite of
  // what it's for. Closes before the tray's own peek puts the tray away.
  void _peekOnce() {
    if (_hasPeeked) return;
    _hasPeeked = true;
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted && _trayShown) _openSheet();
      Future.delayed(const Duration(milliseconds: 2000), () {
        if (mounted) _closeSheet();
      });
    });
  }

  // A flick down puts away the innermost thing that's out: the chord diagrams
  // if they're open, else the tray itself.
  void _onTrayDrag(DragUpdateDetails d, {required bool hasDrawer}) {
    if (d.delta.dy < -6 && hasDrawer && !_sheetOpen) {
      _openSheet();
    } else if (d.delta.dy > 6) {
      if (_sheetOpen) {
        _closeSheet();
      } else {
        _setTray(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayMode = widget.displayMode;
    final theme = Theme.of(context);
    final safeBottom = MediaQuery.paddingOf(context).bottom;

    // The ACTIVE source's state: a recording starting must close it too.
    ref.listen(activePlaybackStateProvider, (_, next) {
      if (next.valueOrNull == PlaybackState.playing) _closeSheet();
    });
    // Anything newly selected — a bar (its Edit/Delete are in the section
    // row), a section double-tapped on the score — brings the tray out, so
    // Play is one tap away. Clearing the selection leaves it where it is.
    // After the frame: _setTray publishes the tray inset to providers, and a
    // selection can change mid-build, where Riverpod forbids that write.
    ref.listen(measureSelectionProvider, (prev, next) {
      if (next == null || next == prev) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _setTray(true);
      });
    });

    // What the chord drawer holds is only the chord diagrams, and they aren't
    // always there: the wrong view, the chord toggle off, or a tune whose
    // chords aren't in the ten-shape library all leave it empty. So work out up
    // front whether there is anything to open, and when there isn't, drop the
    // handle and the peek entirely rather than offering a drawer onto nothing.
    final showsChords = displayMode == DisplayMode.staff ||
        displayMode == DisplayMode.staffFingering ||
        displayMode == DisplayMode.tab;
    final hasDrawer = showsChords &&
        ref.watch(showChordsProvider) &&
        ref.watch(pieceChordShapesProvider).isNotEmpty;

    if (hasDrawer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _peekOnce();
      });
    }
    // Guards the case where the drawer's contents go away while it's open —
    // switching to Jianpu, or turning chords off from the settings drawer.
    final sheetOpen = _sheetOpen && hasDrawer;
    // The tray's top edge: room for the chord handle, or just the chevron.
    final edgeH = hasDrawer ? 20.0 : 12.0;
    // The section row's loop strip tucks up under the edge, chords closed.
    final tuck = widget.sectionRowHasStrip && !sheetOpen;

    return Stack(
      children: [
        Positioned.fill(child: widget.notationView),
        if (widget.selectedMedia.video != null && widget.mediaService != null)
          FloatingVideoOverlay(service: widget.mediaService!),

        // ── play tray, bottom edge ──
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Listener(
            onPointerDown: (_) => _trayPeek?.cancel(),
            child: AnimatedSlide(
              offset: Offset(0, _trayShown ? 0 : 1),
              duration: _slide,
              curve: Curves.easeOut,
              // Re-measured on every change of size, so the autoscroll inset
              // follows the tray through the chord drawer's whole growth
              // rather than one guess at when that growth is over.
              child: NotificationListener<SizeChangedLayoutNotification>(
                onNotification: (_) {
                  _measureTray();
                  return true;
                },
                child: SizeChangedLayoutNotifier(
                  child: Material(
                key: _trayKey,
                elevation: 10,
                color: theme.colorScheme.surface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The top edge is drawn OVER the rest, so that on a piece
                    // whose section row has a loop strip, the strip can tuck
                    // up under it (while the chords are closed) instead of
                    // leaving the edge's height empty above it.
                    Stack(
                      children: [
                        AnimatedPadding(
                          duration: _slide,
                          curve: Curves.easeOut,
                          padding: EdgeInsets.only(
                              top: edgeH - (tuck ? _tuck : 0)),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                            // ── chord diagrams (slide up above the play bar) ──
                            //
                            // Tall on purpose, and that's fine: on a phone the
                            // diagrams are reference — read before playing, not
                            // while — and the drawer closes itself the moment Play is
                            // pressed (the activePlaybackStateProvider listener above). So
                            // the score it covers (about half the screen in portrait,
                            // all but one line in landscape on the SE) is not score
                            // anyone is trying to read. Don't shrink it to make room.
                            AnimatedSize(
                              duration: _slide,
                              curve: Curves.easeOut,
                              child: sheetOpen
                                  ? ConstrainedBox(
                                      constraints:
                                          const BoxConstraints(maxHeight: 280),
                                      child: const SingleChildScrollView(
                                        // The drag handle above is already the
                                        // boundary, so no second rule under it.
                                        child: NewChordsBlock(topBorder: false),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                            // ── the play bar ──
                            //
                            // Drag-sensitive too, so a flick up opens the chords and a
                            // flick down puts the tray away, without finding the edge.
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onVerticalDragUpdate: (d) =>
                                  _onTrayDrag(d, hasDrawer: hasDrawer),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ?widget.sectionRow,
                                  MediaControls(
                                    piece: widget.piece,
                                    media: widget.media,
                                    selected: widget.selectedMedia,
                                  ),
                                  // Spacer so interactive content sits above the
                                  // home-indicator zone; Material background fills
                                  // the safe area gap visually.
                                  SizedBox(height: safeBottom),
                                ],
                              ),
                            ),
                            ],
                          ),
                        ),
                        // ── the top edge: chord handle + put-away chevron ──
                        //
                        // The chord handle sits on the tray's own top edge so
                        // it travels with the panel as it grows. No handle
                        // when there's nothing behind it — an affordance that
                        // opens onto an empty panel is worse than no
                        // affordance.
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: GestureDetector(
                              // The edge overlaps what's below it when the strip is
                              // tucked under, or when it's only the chevron's
                              // (20pt over a 12pt edge) — then only the handle and
                              // the chevron take touches; the rest fall through.
                              behavior: tuck || !hasDrawer
                                  ? HitTestBehavior.deferToChild
                                  : HitTestBehavior.opaque,
                              onTap: !hasDrawer
                                  ? null
                                  : () => _sheetOpen ? _closeSheet() : _openSheet(),
                              onVerticalDragUpdate: (d) =>
                                  _onTrayDrag(d, hasDrawer: hasDrawer),
                              // Full width, or the Stack shrinks to the chord handle
                              // and the chevron lands on top of it.
                              // 20pt even over a 12pt edge: the chevron's target.
                              child: SizedBox(
                                height: 20,
                                width: double.infinity,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    if (hasDrawer)
                                      // A touch target wider than the bar it draws.
                                      Container(
                                        width: 80,
                                        height: edgeH,
                                        color: Colors.transparent,
                                        alignment: Alignment.center,
                                        child: Container(
                                          width: 40,
                                          height: 4,
                                          decoration: BoxDecoration(
                                            color: Colors.grey.shade400,
                                            borderRadius: BorderRadius.circular(2),
                                          ),
                                        ),
                                      ),
                                    Positioned(
                                      right: 8,
                                      top: 0,
                                      bottom: 0,
                                      child: IconButton(
                                        tooltip: 'Hide controls',
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints.tightFor(
                                            width: 36, height: 20),
                                        iconSize: 20,
                                        icon: const Icon(Icons.keyboard_arrow_down),
                                        onPressed: () => _setTray(false),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ),
                      ],
                    ),
                  ],
                ),
                  ),
                ),
              ),
            ),
          ),
        ),

        // ── the tray's tab, while it's away ──
        //
        // Lifted clear of the home indicator, where an upward swipe belongs to
        // the system rather than to us.
        Positioned(
          // A few points off the glass even where there's no home indicator
          // (the SE), so it reads as a tab rather than part of the bezel.
          bottom: safeBottom > 0 ? safeBottom : 6,
          left: 0,
          right: 0,
          child: Center(
            child: IgnorePointer(
              ignoring: _trayShown,
              child: AnimatedOpacity(
                opacity: _trayShown ? 0 : 1,
                duration: _slide,
                child: GestureDetector(
                  onVerticalDragUpdate: (d) {
                    if (d.delta.dy < -4) _setTray(true);
                  },
                  child: _DrawerTab(
                    icon: Icons.keyboard_arrow_up,
                    tooltip: 'Show controls',
                    onTap: () => _setTray(true),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The grab tab the compact layout's play tray leaves on the bottom edge while
/// it's away: a short rounded flap with a chevron pointing the way it will move.
class _DrawerTab extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _DrawerTab({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        elevation: 4,
        // Tinted, not surface: a white flap on a white page was easy to miss,
        // and finding it is the whole of its job.
        color: theme.colorScheme.secondaryContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
        child: InkWell(
          onTap: onTap,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
          child: SizedBox(
            width: 64,
            height: 22,
            child: Icon(icon,
                size: 20, color: theme.colorScheme.onSecondaryContainer),
          ),
        ),
      ),
    );
  }
}

// ── Piece identity + note vocabulary (app bar controls, palette staff below) ──

/// The meter, on the title line. Tapping opens the meter editor; the pencil
/// says so, since italic grey text otherwise reads as a label, not a control.
///
/// It used to carry the key's name too; that now leads the title line, in
/// [_KeySummary], beside the fingerings it implies. A wrong meter is something
/// you notice while looking at the staff, which is why it's up here at all
/// instead of on a strip of its own.
class _KeyMeterButton extends ConsumerWidget {
  const _KeyMeterButton({this.mirror = false});

  /// Lay out and take up space, but draw nothing and take no taps — the
  /// counterweight that centres the title. See the app bar's `title`.
  final bool mirror;

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
  Widget build(BuildContext context, WidgetRef ref) {
    final parsed = ref.watch(parsedPieceProvider).valueOrNull;
    if (parsed == null) return const SizedBox.shrink();
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${parsed.beatsPerMeasure}/${parsed.beatType}',
            style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
          ),
          const SizedBox(width: 5),
          Icon(Icons.edit_outlined,
              size: 13, color: Theme.of(context).hintColor),
        ],
      ),
    );

    if (mirror) {
      return ExcludeSemantics(
        child: IgnorePointer(child: Opacity(opacity: 0, child: body)),
      );
    }

    return InkWell(
      key: const ValueKey('piece_meter_button'),
      borderRadius: BorderRadius.circular(6),
      onTap: () => _editTimeSignature(context, ref, parsed),
      child: body,
    );
  }
}

/// The key by name and, under it, every low/high fingering the piece uses
/// ([nonStandardFingerings]) — what to have ready before playing a note, without
/// opening the vocabulary. On every screen size: it is the warning a phone
/// needs most. On the violin the labels are shown exactly as stored (`A2L`,
/// never `A2♭`); on the mandolin the same notes by string and fret. With none,
/// the home pattern on every string, in grey (`All: 1 2H 3`, frets
/// `All: 2 4 5`), so "nothing unusual" is said rather than left blank.
class _KeySummary extends ConsumerWidget {
  const _KeySummary({this.mirror = false});

  /// Lay out and take up space but draw nothing — the counterweight that
  /// centres the title on a tablet. See the app bar's `title`.
  final bool mirror;

  /// The colour the palette gives an L/H note, darkened to read as text.
  static const _lhText = Color(0xFFC86A00);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parsed = ref.watch(parsedPieceProvider).valueOrNull;
    if (parsed == null) return const SizedBox.shrink();
    final numberMode = ref.watch(noteNumberModeProvider);
    final odd = nonStandardFingerings(parsed,
        numberMode: numberMode,
        fretStyle: ref.watch(fretStyleProvider));

    final body = Column(
      key: mirror ? null : const ValueKey('key_summary'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(PieceDetailScreen._formatKey(parsed.keySignature),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        if (odd.isNotEmpty)
          Text(odd.join(' '),
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: _lhText))
        else
          Text(
              numberMode == NoteNumberMode.violinFingering
                  ? 'All: 1 2H 3'
                  : 'All: 2 4 5',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: 0.6))),
      ],
    );
    if (!mirror) return body;
    return ExcludeSemantics(
      child: IgnorePointer(child: Opacity(opacity: 0, child: body)),
    );
  }
}

/// Folds the note vocabulary in and out. Labelled rather than icon-only because
/// the panel is folded by default now, so this is the only thing on screen that
/// says the vocabulary exists.
class _NotePaletteToggle extends ConsumerWidget {
  const _NotePaletteToggle({this.compact = false});

  /// A phone's bar has no room for the label, so there it's an icon alone —
  /// but still there: the vocabulary is as much use on the phone.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(notePaletteExpandedProvider);
    if (compact) {
      return IconButton(
        key: const ValueKey('vocabulary_toggle'),
        tooltip: expanded ? 'Hide vocabulary' : 'Show vocabulary',
        isSelected: expanded,
        icon: const Icon(Icons.queue_music_outlined),
        selectedIcon: const Icon(Icons.queue_music),
        onPressed: () =>
            ref.read(notePaletteExpandedProvider.notifier).state = !expanded,
      );
    }
    return TextButton.icon(
      key: const ValueKey('vocabulary_toggle'),
      onPressed: () =>
          ref.read(notePaletteExpandedProvider.notifier).state = !expanded,
      icon: Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18),
      label: const Text('Vocabulary', style: TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
    );
  }
}

/// The palette staff itself — every distinct note in the piece, engraved once.
/// Occupies no height at all while folded, which is its default state; the
/// header it used to carry now lives in the app bar.
///
/// Always labelled, whatever the view: the label is what a vocabulary is for.
/// The labels follow the annotation view's settings (string colour style,
/// string letters, number mode), so the two never disagree about how a note is
/// written — only the density doesn't apply, since every note here is shown
/// exactly once.
class _PalettePanel extends ConsumerStatefulWidget {
  const _PalettePanel();

  @override
  ConsumerState<_PalettePanel> createState() => _PalettePanelState();
}

class _PalettePanelState extends ConsumerState<_PalettePanel> {
  final _noHighlight = ValueNotifier<HighlightEvent?>(null);

  /// What the native engrave actually drew at; the panel is sized to it. Null
  /// until the first engrave, which is laid out against [_firstGuess].
  double? _contentHeight;
  static const _firstGuess = 140.0;

  @override
  void dispose() {
    _noHighlight.dispose();
    super.dispose();
  }

  Widget _nativeStaff(String xml, ParsedPiece palette) {
    final style = ref.watch(stringColourStyleProvider);
    final numberMode = ref.watch(noteNumberModeProvider);
    final fretStyle = ref.watch(fretStyleProvider);
    final measureMap =
        EngravedMeasureMap.identity(palette.measures.map((m) => m.number));
    return StaffViewVerovio(
      musicXml: xml,
      highlightNotifier: _noHighlight,
      zoomable: false,
      onContentHeight: (h) {
        if (h != _contentHeight) setState(() => _contentHeight = h);
      },
      measureMap: measureMap,
      fingeringAnnotations: fingeringAnnotations(
        measureMap,
        palette,
        density: FingeringDensity.all,
        policy: ref.watch(fingeringDensityPolicyProvider),
        colourByString: style != StringColourStyle.off,
        stringLabelStyle: ref.watch(stringLabelStyleProvider),
        numberMode: numberMode,
        fretStyle: fretStyle,
        showImpliedHigh: true,
      ),
      stringColourStyle: style,
      stringRuns: style == StringColourStyle.underline
          ? stringRunRegions(measureMap, palette,
              numberMode: numberMode, fretStyle: fretStyle)
          : const [],
      // Always named here, whatever the staff's own setting: learning what
      // each note is called is what a vocabulary is for.
      noteNames: noteNameLabels(measureMap, palette,
          numberMode: numberMode, fretStyle: fretStyle),
      showNoteNames: true,
      colourNoteheads: ref.watch(colourNoteheadsByStringProvider),
      keySignatureLabel: keySignatureLabel(palette),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(notePaletteExpandedProvider)) {
      return const SizedBox.shrink();
    }
    if (ref.watch(parsedPieceProvider).valueOrNull == null) {
      return const SizedBox.shrink();
    }
    final paletteXml = ref.watch(paletteMusicXmlProvider).valueOrNull;
    final palette = ref.watch(palettePieceProvider).valueOrNull;
    final native = ref.watch(staffRendererProvider) == StaffRenderer.verovio;

    // Fit to the engraving, but never take more than a share of the screen —
    // a long vocabulary on a phone in landscape scrolls instead. OSMD reports
    // no height, so it keeps the fixed box.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.4;
    final height = native
        ? (_contentHeight ?? _firstGuess).clamp(40.0, maxHeight)
        : _firstGuess;

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: paletteXml == null || (native && palette == null)
          ? const Center(child: CircularProgressIndicator())
          : native
              ? _nativeStaff(paletteXml, palette!)
              : StaffView(
                  musicXml: paletteXml,
                  highlightNotifier: _noHighlight,
                  bridgeAsset: 'assets/engine/osmd/palette_bridge.html',
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

  // The previous tap, for spotting a double-tap. Static: there is only ever
  // one notation view on screen, and the widget itself is rebuilt constantly.
  static ({int measure, DateTime at, MeasureSelection? before})? _lastTap;

  // Shared "tap anchor, tap to extend" selection logic, used by every notation
  // view (staff, jianpu, fingering). See MeasureSelection.afterTap.
  //
  // A second tap on the same bar within the double-tap window selects the
  // whole section run it's in (see sectionRunForDoubleTap). That's detected
  // here rather than with a GestureDetector's onDoubleTap, which would hold
  // back EVERY single tap by kDoubleTapTimeout while it waited for a second.
  // So the first tap still acts at once; the second replaces its result.
  void _selectMeasure(WidgetRef ref, int measure) {
    final selection = ref.read(measureSelectionProvider.notifier);
    final now = DateTime.now();
    final prev = _lastTap;
    if (prev != null &&
        prev.measure == measure &&
        now.difference(prev.at) < kDoubleTapTimeout) {
      final runs = ref.read(sectionRunsProvider).valueOrNull ?? const [];
      final i = sectionRunForDoubleTap(runs, measure, prev.before);
      if (i != null) {
        _lastTap = null;
        selection.state = MeasureSelection.ofRun(runs[i]);
        return;
      }
    }
    final current = selection.state;
    _lastTap = (measure: measure, at: now, before: current);
    selection.state = MeasureSelection.afterTap(current, measure);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(measureSelectionProvider);
    final parsed = ref.watch(parsedPieceProvider).valueOrNull;
    final flaggedMeasures = parsed?.flaggedMeasureNumbers ?? const <int>{};
    // Minimap → custom-view navigation, and custom-view scroll → minimap.
    final navTarget = ref.watch(navTargetRunProvider);
    final bottomClearance = ref.watch(notationBottomClearanceProvider);
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
    // document order (numbers are unique) — except that the staff views, laid
    // out by section, engrave a bar split at a section's lead-in as two
    // measures. Tab is never split (see [staffBySectionProvider]).
    final bySection =
        mode != DisplayMode.tab && ref.watch(staffBySectionProvider);
    final byPrintedLines =
        mode != DisplayMode.tab && ref.watch(staffByPrintedLinesProvider);
    final overlays = staffOverlaysFor(
      ref.watch,
      parsed: parsed,
      mode: mode,
      sections: sections,
      sectionColors: sectionColors,
      bySection: bySection,
    );
    final measureMap = overlays.measureMap;
    final sectionTints = overlays.sectionTints;
    final chordRuns = overlays.chordRuns;
    final colourStyle = overlays.colourStyle;
    final annotations = overlays.annotations;
    final stringRuns = overlays.stringRuns;
    // Minimap tap → scroll the staff to the (folded) run's first measure index.
    // Guard the index against a stale navTarget (e.g. after switching pieces).
    final staffNav = (navTarget == null || navTarget.run >= layout.runs.length)
        ? null
        : () {
            final run = layout.runs[navTarget.run];
            final idx = measureMap.firstIndexOf(run.firstMeasure);
            return idx < 0 ? null : (index: idx, seq: navTarget.seq);
          }();
    // Build the staff via the selected renderer (native Verovio or OSMD
    // WebView), keeping one identical parameter set.
    final renderer = ref.watch(staffRendererProvider);
    // [fingeringChannel] reserves the fingering lane and fills it with the
    // chips — the annotation view's whole layout difference, now that both views
    // feed the same (fingering-stripped) xml.
    //
    // Each lane is reserved only when something will be drawn in it: an empty
    // [chordRuns] means the toggle is off or the piece has none, and reserving
    // for it anyway would spend gap that the staff-spacing preference could
    // otherwise close up. The trade is that toggling chords now re-flows the
    // page, which it previously didn't.
    Widget buildStaff(String xml, {bool fingeringChannel = false}) {
      // [service] is whichever engine is driving this piece — see the screen's
      // `activeService`. A recording's own service carries a permanently null
      // count-in notifier (there is nothing to count off into a fixed
      // recording), so the staff view needs no special case for it.
      if (renderer == StaffRenderer.verovio) {
        return StaffViewVerovio(
          musicXml: xml,
          highlightNotifier: service.currentHighlightNotifier,
          selection: selection,
          onMeasureTapped: (m) => _selectMeasure(ref, m),
          flaggedMeasures: flaggedMeasures,
          measureMap: measureMap,
          // The printed page's lines engrave the section layout's way: each
          // line a pre-broken segment (see [staffByPrintedLinesProvider]).
          sectionLayout: bySection || byPrintedLines,
          sectionTints: sectionTints,
          chordRuns: chordRuns,
          fingeringAnnotations: annotations,
          stringColourStyle: colourStyle,
          stringRuns: stringRuns,
          noteNames: overlays.noteNames,
          showNoteNames: overlays.showNoteNames,
          colourNoteheads: overlays.colourNoteheads,
          scrollNav: staffNav,
        );
      }
      return StaffView(
        musicXml: xml,
        highlightNotifier: service.currentHighlightNotifier,
        selection: selection,
        onMeasureTapped: (m) => _selectMeasure(ref, m),
        flaggedMeasures: flaggedMeasures,
        measureNumbers: measureMap.numbers,
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
          bottomClearance: bottomClearance,
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
          bottomClearance: bottomClearance,
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
          bottomClearance: bottomClearance,
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
                  selection: selection,
                  onMeasureTapped: (m) => _selectMeasure(ref, m),
                  flaggedMeasures: flaggedMeasures,
                  measureMap: measureMap,
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

/// [bar], with the count-off laid over the whole of it while it runs.
///
/// It used to sit on the title alone, squeezed between the key block and the
/// icons; a two-bar count then shrank to fit. Across the full bar it reads as a
/// line of music of its own, with room for its barlines. The backing is
/// opaque and swallows taps: the back arrow and gear it covers are out of
/// sight for those seconds, and must not be hit blind.
class _CountInOverBar extends StatelessWidget implements PreferredSizeWidget {
  const _CountInOverBar({required this.service, required this.bar});

  final PlaybackServiceBase service;
  final AppBar bar;

  @override
  Size get preferredSize => bar.preferredSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        bar,
        Positioned.fill(
          child: SafeArea(
            bottom: false,
            child: ValueListenableBuilder<CountInTick?>(
              valueListenable: service.countInNotifier,
              builder: (context, tick, _) => tick == null
                  ? const SizedBox.shrink()
                  : AbsorbPointer(
                      child: ColoredBox(
                        color: theme.appBarTheme.backgroundColor ??
                            theme.colorScheme.surface,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: CountInLabel(
                            tick: tick,
                            height: 34,
                            beatPosition: service.countInBeatPosition,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

// Edit/Delete-measure actions now live at the top of [SectionMinimap] (see
// that file) — they used to be FABs floating over the notation itself, which
// covered the music being edited, and briefly lived in the title bar before
// that. The minimap column is narrow but tall enough to hold them without
// touching either the title or the score.

