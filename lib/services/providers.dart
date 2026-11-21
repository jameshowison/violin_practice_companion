import 'dart:async' show scheduleMicrotask, unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chord_shape.dart';
import '../models/instrument_profile.dart';
import 'instrument_view.dart';
import 'package:score_sync/score_sync.dart';
import '../models/tempo_presets.dart';
import '../models/engraved_measure_map.dart';
import '../models/fingering_density.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import '../models/note_annotation.dart';
import '../models/display_mode.dart';
import '../models/note_number_mode.dart';
import '../models/piece.dart';
import '../models/piece_layout.dart';
import '../models/piece_library.dart';
import '../models/piece_media.dart';
// Four of the notifier's methods share a name with the free function they wrap
// (renameCollection, reorderInCollection, setHidden, forgetPiece), where the
// method would otherwise shadow it.
import '../models/piece_library.dart' as plib;
import '../models/section.dart';
import '../models/section_run.dart';
import '../models/section_run_groups.dart';
import '../models/string_label_style.dart';
import '../models/violin_string_palette.dart';
import 'fingering_mapper.dart';
import 'tab_score_generator.dart';
import 'jianpu_converter.dart';
import 'midi_generator.dart';
import 'chord_shape_library.dart';
import 'count_in_store.dart';
import 'tempo_store.dart';
import 'piece_display_prefs.dart';
import 'instrument_setting.dart';
import 'palette_xml_generator.dart';
import 'piece_library_store.dart';
import 'piece_activity_store.dart';
import 'piece_repository.dart';
import 'dev_library.dart';
import 'scan_source_store.dart';
import 'abc_source_store.dart';
import 'media_alignment_store.dart';
import 'media_catalog.dart';
import 'media_paths.dart';
import 'audio_output.dart';
import 'media_playback_service.dart';
import 'rendered_score_cache.dart';
import 'rendered_score_playback_service.dart';
import 'silent_playback_service.dart';
import 'piece_media_store.dart';
import 'playback_service_base.dart';
import 'staff_zoom.dart';
import 'system_break_injector.dart';
import 'launch_timing.dart';

// ── Singletons ────────────────────────────────────────────────────────────────

final pieceRepositoryProvider = Provider<PieceRepository>(
  (_) => PieceRepository(),
);

final musicXmlParserProvider = Provider<MusicXmlParser>(
  (_) => MusicXmlParser(),
);

final jianpuConverterProvider = Provider<JianpuConverter>(
  (_) => JianpuConverter(),
);

final fingeringMapperProvider = Provider<FingeringMapper>(
  (_) => FingeringMapper(),
);

// ── Piece list ────────────────────────────────────────────────────────────────

/// Every piece there is, unfiltered — fixtures in declaration order, then user
/// pieces oldest-first.
///
/// Deliberately knows nothing about the library. Filtering hidden pieces inside
/// `loadAll()` would make the repository depend on `shared_preferences` (so it
/// could not run headless), would force this into a family so every
/// `ref.invalidate(piecesProvider)` site had to care about a flag unrelated to
/// importing a score, and would leave the hidden-pieces sheet — which needs
/// everything, with hidden marked — without a source.
final piecesProvider = FutureProvider<List<Piece>>((ref) async {
  await ref.watch(devLibraryProvider.future);
  return LaunchTiming.span(
      'loadAll', () => ref.watch(pieceRepositoryProvider).loadAll());
});

/// Merges a synced dev library (see [DevLibraryIngester]) once per launch,
/// before the first piece list or library read. A no-op unless
/// `scripts/sync_dev_library.sh` has staged one on this device, and never
/// fatal: a bad library must not stop the app showing everything else.
final devLibraryProvider = FutureProvider<void>((ref) async {
  try {
    await LaunchTiming.span('devLibrary ingest',
        DevLibraryIngester(skipUnchanged: true, deleteStagingWhenSettled: true)
            .ingest);
  } catch (e) {
    // ignore: avoid_print
    print('[dev_library] failed: $e');
  }
});

// ── Selected piece ────────────────────────────────────────────────────────────

final selectedPieceProvider = StateProvider<Piece?>((ref) => null);

// ── Piece library (collections, hidden pieces, renames) ──────────────────────

final pieceLibraryStoreProvider = Provider<PieceLibraryStore>(
  (_) => PieceLibraryStore(),
);

final libraryProvider =
    AsyncNotifierProvider<PieceLibraryNotifier, PieceLibrary>(
      PieceLibraryNotifier.new,
    );

class PieceLibraryNotifier extends AsyncNotifier<PieceLibrary> {
  @override
  Future<PieceLibrary> build() async {
    // A synced dev library may carry collections; read them after it lands.
    await ref.watch(devLibraryProvider.future);
    final store = ref.watch(pieceLibraryStoreProvider);
    final loaded = await LaunchTiming.span('library store.load', store.load);
    final seeded = seedLibrary(
      loaded,
      // No OMR demos ship any more (they are test data now), so seeding's
      // step 1 has nothing to hide; it stays version-gated and harmless.
      omrDemoIds: const [],
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    );
    // Value equality, so this writes on the first launch only.
    if (seeded != loaded) await store.save(seeded);
    return seeded;
  }

  /// Applies [f], publishes the result immediately, then writes.
  ///
  /// State first, persist after, so a chip tap or a drag never waits on
  /// storage. The write is best-effort
  /// ([PieceLibraryStore.save] swallows failures); the session still holds the
  /// value.
  Future<void> _mutate(PieceLibrary Function(PieceLibrary) f) async {
    final current = state.valueOrNull;
    if (current == null) return; // still loading; the tap is a no-op
    final next = f(current);
    if (next == current) return; // value equality: no rebuild, no write
    state = AsyncData(next);
    await ref.read(pieceLibraryStoreProvider).save(next);
  }

  Future<void> createCollection(String name) => _mutate(
    (l) => addCollection(
      l,
      name: name,
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    ),
  );

  Future<void> renameCollection(String id, String name) =>
      _mutate((l) => plib.renameCollection(l, id, name));

  Future<void> deleteCollection(String id) =>
      _mutate((l) => removeCollection(l, id));

  /// Book (numbered, hand-set order) or plain keyword (A–Z).
  Future<void> setOrdered(String id, bool ordered) =>
      _mutate((l) => setCollectionOrdered(l, id, ordered));

  Future<void> setTags(String pieceId, Set<String> collectionIds) => _mutate(
    (l) => setPieceTags(l, pieceId: pieceId, collectionIds: collectionIds),
  );

  /// [visibleIds] is the collection as displayed; see [reorderInCollection].
  Future<void> reorderInCollection(
    String collectionId,
    List<String> visibleIds,
    int oldIndex,
    int newIndex,
  ) => _mutate(
    (l) => plib.reorderInCollection(
      l,
      collectionId,
      visibleIds,
      oldIndex,
      newIndex,
    ),
  );

  Future<void> setHidden(String pieceId, bool hidden) =>
      _mutate((l) => plib.setHidden(l, pieceId, hidden));

  /// A null or blank [title] clears the override, reverting to the score's own.
  Future<void> renamePiece(String pieceId, String? title) =>
      _mutate((l) => setTitleOverride(l, pieceId, title));

  Future<void> forgetPiece(String pieceId) =>
      _mutate((l) => plib.forgetPiece(l, pieceId));
}

/// The piece list's search box. Lasts for the session.
final pieceSearchProvider = StateProvider<String>((_) => '');

/// The user's collections (the Keywords picker), in display order. Empty
/// while loading.
final collectionsProvider = Provider<List<Collection>>(
  (ref) => ref.watch(libraryProvider).valueOrNull?.collections ?? const [],
);

/// Which collections a piece belongs to — the tag dialog's initial checkboxes.
/// Derived, never stored: a persisted reverse index would be a second copy of
/// the membership, free to disagree with the first.
final pieceCollectionsProvider = Provider.family<Set<String>, String>(
  (ref, pieceId) => collectionIdsOf(
    ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty,
    pieceId,
  ),
);

final libraryActionsProvider = Provider<LibraryActions>(LibraryActions.new);

/// The one library operation that spans more than one store.
///
/// It does not live on [PieceRepository] because two of the stores involved
/// ([PieceLibraryStore], the media store) deliberately bypass it, and it does
/// not live on [PieceLibraryNotifier] because the library has no business
/// deleting files. It is the composition, and nothing else.
class LibraryActions {
  LibraryActions(this._ref);

  final Ref _ref;

  /// Everything a user-added piece owns comes out together: its MusicXML, its
  /// index row / prefs keys, its section-override sidecar, any editable copy,
  /// every medium recorded or imported for it, the
  /// images it was scanned from, and its membership in every collection — plus the selection, if it happened
  /// to be selected.
  ///
  /// Clearing the selection matters even though deletion happens on a screen the
  /// detail view isn't under: a stale [selectedPieceProvider] feeds
  /// [parsedPieceProvider], which would try to load a file that no longer
  /// exists and surface as an error the next time the user navigated back.
  Future<void> deletePiece(String pieceId) async {
    final repo = _ref.read(pieceRepositoryProvider);
    await repo.catalog(); // isBundled is answered from it
    if (repo.isBundled(pieceId)) {
      throw ArgumentError.value(
        pieceId,
        'pieceId',
        'Bundled fixtures are hidden, not deleted',
      );
    }
    await repo.deletePiece(pieceId);
    // Media are files under the documents directory, not prefs rows, so
    // leaving them behind would leak a recording's worth of disk per deleted
    // piece with nothing left in the app pointing at it.
    await _ref.read(mediaActionsProvider).deleteAllFor(pieceId);
    await _ref.read(scanSourceStoreProvider).delete(pieceId);
    await _ref.read(abcSourceStoreProvider).delete(pieceId);
    await _ref.read(libraryProvider.notifier).forgetPiece(pieceId);
    _ref.read(pieceActivityProvider.notifier).forget(pieceId);
    if (_ref.read(selectedPieceProvider)?.id == pieceId) {
      _ref.read(selectedPieceProvider.notifier).state = null;
      _ref.read(measureSelectionProvider.notifier).state = null;
    }
    _ref.invalidate(piecesProvider);
  }
}

// ── Measure draft (the in-context editor's unsaved bar) ──────────────────────

/// One bar's unsaved edits, as the inline measure editor holds them (see
/// `measure_edit_session.dart`). While one is set, [pieceMusicXmlProvider]
/// serves the piece with this bar swapped in — through the same
/// [MeasureXmlEditor] calls Save makes — so every view engraves the edit in
/// place, in the context of the whole piece, before anything is written.
class MeasureDraft {
  final String pieceId;
  final int measureNumber;

  /// The bar's notes, or null to leave the file's (a key-only draft, which
  /// re-spells them in place instead of rebuilding the bar).
  final List<NoteEvent>? notes;
  final int divisions;
  final bool repeatStart;
  final bool repeatEnd;

  /// A key change at this bar, or null for none: `fifths` is the key it
  /// starts, or null to remove the change. Applied first, so the notes that
  /// follow the key move with it across every bar it governs.
  final ({int? fifths})? key;

  const MeasureDraft({
    required this.pieceId,
    required this.measureNumber,
    this.notes,
    required this.divisions,
    required this.repeatStart,
    required this.repeatEnd,
    this.key,
  });

  String applyTo(String xml) {
    final k = key;
    if (k != null) {
      final f = k.fifths;
      xml = f == null
          ? MeasureXmlEditor.removeKeyChange(xml, measureNumber)
          : MeasureXmlEditor.setKeyChange(xml, measureNumber, f);
    }
    final n = notes;
    if (n == null) return xml;
    final withNotes =
        MeasureXmlEditor.replaceMeasureNotes(xml, measureNumber, n, divisions);
    return MeasureXmlEditor.setMeasureRepeats(withNotes, measureNumber,
        start: repeatStart, end: repeatEnd);
  }
}

final measureDraftProvider = StateProvider<MeasureDraft?>((_) => null);

/// The selected piece's MusicXML as every view should see it: the file, with
/// any [measureDraftProvider] edit applied. Everything that engraves or parses
/// the piece reads this rather than [PieceRepository.loadMusicXml] directly.
final pieceMusicXmlProvider = FutureProvider<String?>((ref) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final repo = ref.watch(pieceRepositoryProvider);
  final draft = ref.watch(measureDraftProvider);
  final xml = await repo.loadMusicXml(piece);
  if (draft == null || draft.pieceId != piece.id) return xml;
  try {
    return draft.applyTo(xml);
  } catch (_) {
    // A draft that can't be applied must never take the piece view down.
    return xml;
  }
});

// ── The instrument layer (docs/family/layers.md) ──────────────────────────────

/// The instrument the piece is shown for. Violin, or mandolin when the piece
/// is in fret numbers; both read treble, so both see every source as it is.
final instrumentProfileProvider = Provider<InstrumentProfile>((ref) =>
    ref.watch(noteNumberModeProvider) == NoteNumberMode.mandolinFret
        ? InstrumentProfile.mandolin
        : InstrumentProfile.violin);

/// How the selected piece's source is shown for [instrumentProfileProvider].
final instrumentViewProvider = FutureProvider<InstrumentView?>((ref) async {
  final profile = ref.watch(instrumentProfileProvider);
  final xml = await ref.watch(pieceMusicXmlProvider.future);
  return xml == null ? null : InstrumentView.of(profile, xml);
});

/// The selected piece's MusicXML as the instrument reads it: the source
/// ([pieceMusicXmlProvider]) through [instrumentViewProvider]. What every view
/// engraves and parses. Never saved: an edit goes back to the source through
/// [InstrumentView.toSource] (`measure_edit_session.dart`).
final pieceViewXmlProvider = FutureProvider<String?>((ref) async {
  final xml = await ref.watch(pieceMusicXmlProvider.future);
  final view = await ref.watch(instrumentViewProvider.future);
  if (xml == null || view == null) return xml;
  return view.apply(xml);
});

// ── Parsed piece (loads + parses + converts on piece selection) ───────────────

/// The selected piece as its instrument reads it ([pieceViewXmlProvider]),
/// with Jianpu and fingering filled in.
final parsedPieceProvider = FutureProvider<ParsedPiece?>((ref) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;

  final parser = ref.watch(musicXmlParserProvider);
  final jianpu = ref.watch(jianpuConverterProvider);
  final fingering = ref.watch(fingeringMapperProvider);

  await jianpu.init();
  await fingering.init();

  final xml = await ref.watch(pieceViewXmlProvider.future);
  if (xml == null) return null;
  final parsed = parser.parse(xml);
  final withJianpu = jianpu.convert(parsed);
  final withFingering = fingering.map(withJianpu,
      preference: ref.watch(violinStringPreferenceProvider));
  return withFingering;
});

// ── Staff view bottom inset (height in logical px obscured by the bottom tray) ─
// Updated by _CompactPieceLayoutState; read by StaffView to inform scroll logic.
final staffViewBottomInsetProvider = StateProvider<double>((_) => 0);

// The most the bottom tray has ever covered on this screen, so every notation
// view can end with that much empty scroll room and its last row can be pulled
// clear of the tray. Grow-only on purpose: tracking the tray's CURRENT height
// would shrink the scroll extent each time the tray slid away, and a reader
// parked at the end would watch the score drop by a tray's height.
final notationBottomClearanceProvider = StateProvider<double>((_) => 0);

// ── Note vocabulary panel (the palette staff above the score) ────────────────
// Folded by default: it costs a good slice of the score's height (all the more
// on a phone), and it's reference material you consult once rather than read
// while playing. Lifted out of the panel's own State because the toggle lives
// in the app bar, beside the title, rather than on the panel itself.
final notePaletteExpandedProvider = StateProvider<bool>((_) => false);

// ── Staff spacing (Verovio `spacingSystem` via verovioSpacingSystemFor) ───────
// Exposed as constants so tests can assert min < max (a zero-range slider
// cannot claim drag gestures and they leak to parent handlers like Drawer close).
const staffSpacingMin = 0.1;
const staffSpacingMax = 1.5;
const staffSpacingDefault = 0.5;

/// The staff spacing the note-name row wants: turning names on raises the
/// spacing to at least this, since the row is a third line of type between
/// systems. Never lowers it, and turning names off leaves it where it is.
const staffSpacingWithNoteNames = 0.8;
final staffSpacingProvider = pieceDisplayPref<double>(
  'staffSpacing',
  staffSpacingDefault,
  encode: (v) => '$v',
  decode: double.parse,
);

// ── Measures per row (updated at runtime from screen width) ──────────────────

final measuresPerRowProvider = StateProvider<int>((_) => 4);

// ── Staff size: Fit, Small, Medium, Large ────────────────────────────────────
// The staff/annotation/tab views engrave to exactly the viewport width, so
// "fewer measures per line" and "bigger notes" are the same knob (Verovio's
// `scale`). The reader picks a size ([staffSizeProvider]); the staff view turns
// it into a layout. See `staff_zoom.dart` for the maths.
//
// Note this is NOT [measuresPerRowProvider], which is derived purely from screen
// width and drives the jianpu/fingering row layout.

final scanSourceStoreProvider = Provider<ScanSourceStore>(
  (_) => ScanSourceStore(compressInBackground: true),
);

/// How many original page photos a scanned piece kept (0 for one that wasn't
/// scanned). Gates the piece screen's "Original photo" entry. Reads file names
/// only — the viewer loads the images themselves.
final scanOriginalCountProvider = FutureProvider.autoDispose.family<int, String>(
  (ref, pieceId) => ref.read(scanSourceStoreProvider).originalCount(pieceId),
);

final abcSourceStoreProvider = Provider<AbcSourceStore>(
  (_) => AbcSourceStore(),
);

/// The view menu's three ways to show a piece, one at a time, per piece.
///
/// * [fit]: the app chooses everything — the biggest notes that keep the
///   whole piece on one screen, laid out by section when the piece has them.
/// * [custom]: the reader's own size ([customStaffSizeProvider]) and layout
///   ([sectionLayoutProvider]), remembered while another mode is on.
/// * [original]: the scanned page's own lines; offered for scans only
///   ([printedLayoutAvailableProvider]).
enum StaffViewMode {
  fit('Fit whole piece'),
  custom('Custom'),
  original('Like original scan');

  const StaffViewMode(this.label);
  final String label;
}

/// The mode the reader chose for the selected piece. Fit by default.
final staffViewModeProvider = pieceDisplayEnumPref<StaffViewMode>(
  'staffMode',
  StaffViewMode.fit,
  StaffViewMode.values,
);

/// The mode actually in force: [StaffViewMode.original] needs a scan, and
/// falls back to Fit on a piece that has none.
final effectiveStaffViewModeProvider = Provider<StaffViewMode>((ref) {
  final mode = ref.watch(staffViewModeProvider);
  if (mode == StaffViewMode.original &&
      !ref.watch(printedLayoutAvailableProvider)) {
    return StaffViewMode.fit;
  }
  return mode;
});

/// Custom's size: Small, Medium or Large, Medium by default. Kept while Fit
/// or Like original scan is on, so going back to Custom loses nothing.
final customStaffSizeProvider = pieceDisplayEnumPref<StaffSize>(
  'customStaffSize',
  StaffSize.medium,
  StaffSize.values,
);

/// How big the staff views draw the notes (see [StaffSize]): Fit unless the
/// reader chose Custom. Under Like original scan the printed lines set the
/// size and this is not read.
final staffSizeProvider = Provider<StaffSize>((ref) {
  if (ref.watch(effectiveStaffViewModeProvider) != StaffViewMode.custom) {
    return StaffSize.fit;
  }
  final size = ref.watch(customStaffSizeProvider);
  return size == StaffSize.fit ? StaffSize.medium : size;
});

/// Whether the staff on screen is Fit on a piece too long for one screen even
/// at Small's note size, so it scrolls (at Small's size and spacing). Set by
/// the staff view with each engrave; the view menu says so under Fit.
final fitTooLongProvider = StateProvider<bool>((_) => false);

/// Measures per line the renderer actually achieved on the last engrave. Set
/// by the staff view; the section minimap sizes its emblems from it.
final effectiveMeasuresPerLineProvider = StateProvider<int?>((_) => null);

/// Custom's layout: true for Sections (each section of a sectioned piece
/// starts its own line and fills whole lines), false for Flowing. See
/// [staffBySectionProvider] for when it applies; Fit always uses Sections
/// where it can. On by default; remembered per piece ([pieceDisplayPref]).
final sectionLayoutProvider = pieceDisplayPref<bool>(
  'sectionLayout',
  true,
  encode: (v) => '$v',
  decode: bool.parse,
);

/// Whether Like original scan is offered: the piece's MusicXML records where
/// its printed lines broke (a scan does).
final printedLayoutAvailableProvider = Provider<bool>((ref) {
  final parsed = ref.watch(parsedPieceProvider).valueOrNull;
  return parsed != null && parsed.measures.skip(1).any((m) => m.systemStart);
});

/// Whether the staff views break where the printed page did (Like original
/// scan). Lines are then engraved like the section
/// layout's segments — one segment per printed line, each kept whole, so the
/// widest printed line sets the note size (`StaffViewVerovio.printedLines`).
/// Never the tab view.
final staffByPrintedLinesProvider = Provider<bool>(
  (ref) =>
      ref.watch(effectiveStaffViewModeProvider) == StaffViewMode.original,
);

/// Lines per section the last section-layout engrave used — the most any
/// section took. Set by the staff view.
final effectiveLinesPerSectionProvider = StateProvider<int?>((_) => null);

// ── Piece layout (single source of truth for all notation views) ──────────────
// Always folded — the notation shows the score as written (repeat barlines
// intact). The unfolded "where are we in the whole piece" view is the minimap
// (see sectionRunsProvider), not the notation body.

final pieceLayoutProvider = FutureProvider<PieceLayout?>((ref) async {
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (parsed == null) return null;
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final measuresPerRow = ref.watch(measuresPerRowProvider);
  return PieceLayout.compute(
    parsed.measures,
    piece.sections,
    measuresPerRow: measuresPerRow,
  );
});

// ── Unfolded section runs (drives the minimap) ────────────────────────────────
// A `|: A :|` repeat — or a literal restatement — yields multiple same-label
// runs (A A B …) in performance order, each carrying its performance-order
// slice so the minimap can light the exact playing pass. Empty without sections.
final sectionRunsProvider = FutureProvider<List<SectionRun>>((ref) async {
  final parsed = await ref.watch(parsedPieceProvider.future);
  final piece = ref.watch(selectedPieceProvider);
  if (parsed == null || piece == null) return const [];
  return sectionRuns(parsed.measures, piece.sections);
});

// The section picker's view of [sectionRunsProvider]: repeats folded under
// loops, and the score's D.C./D.S. return as one labelled stretch.
final sectionRunGroupsProvider = FutureProvider<List<RunGroup>>((ref) async {
  final runs = await ref.watch(sectionRunsProvider.future);
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (runs.isEmpty || parsed == null) return const [];
  return foldRunGroups(runs,
      jump: ParsedPiece.navigationJump(parsed.measures));
});

// ── Display mode ──────────────────────────────────────────────────────────────

// Remembered per piece, like the other display preferences — see
// [pieceDisplayPref]. This is the STORED choice; read [displayModeProvider].
final displayModePrefProvider = pieceDisplayEnumPref<DisplayMode>(
  'view',
  // Annotated (staff plus fingering) is where a new piece opens.
  DisplayMode.staffFingering,
  DisplayMode.values,
);

/// The view in effect: [displayModePrefProvider], except that a saved tab view
/// opens annotated when the instrument setting has no tab view. The saved
/// choice is kept, so it comes back if the setting does.
final displayModeProvider = Provider<DisplayMode>((ref) {
  final stored = ref.watch(displayModePrefProvider);
  if (stored == DisplayMode.tab &&
      !ref.watch(instrumentFeaturesProvider).tabView) {
    return DisplayMode.staffFingering;
  }
  return stored;
});

// ── Piece media (what plays the piece) ───────────────────────────────────────
// One list per piece covering everything it can be played by — the synthesized
// score, bundled backing tracks, imported files, recorded demos — and one
// selection out of that list.
//
// This used to be two independent mode booleans (`playAlongMode`,
// `teacherDemoMode`) that had to be kept mutually exclusive by hand at each
// call site, with the synthesized engine as their shared `else` branch, plus a
// separate "which of the three bundled variants" provider and two stores. A
// single selected id makes the exclusivity structural, and makes "add another
// way to play this" a list entry rather than a third mode.
//
// Deliberately NOT folded into displayModeProvider: that enum is about how the
// notation *looks*, this is about what is *playing it*.

final pieceMediaStoreProvider = Provider<PieceMediaStore>(
  (_) => PieceMediaStore(),
);

final mediaAlignmentStoreProvider = Provider<MediaAlignmentStore>(
  (_) => MediaAlignmentStore(),
);

final mediaCatalogProvider = Provider<MediaCatalog>(
  (ref) => MediaCatalog(store: ref.watch(pieceMediaStoreProvider)),
);

/// Everything [pieceId] can be played by, in picker order. Always at least
/// one entry: [PieceMedia.synthesized].
final pieceMediaProvider =
    FutureProvider.family<List<PieceMedia>, String>((ref, pieceId) async {
  final repo = ref.watch(pieceRepositoryProvider);
  final catalog = ref.watch(mediaCatalogProvider);
  final audioFolder = await repo.audioSyncFolderFor(pieceId);
  return catalog.mediaFor(pieceId, audioFolder: audioFolder);
});

/// The selected medium's id, per piece; null means the synthesized score.
///
/// Per piece rather than global so that switching pieces doesn't carry a
/// teacher demo's selection onto a piece that hasn't got one. Session-only,
/// matching the other display-preference providers — a practice session picks
/// this up again where it left off, a relaunch starts from the score.
final selectedMediaIdProvider =
    StateProvider.family<String?, String>((ref, pieceId) => null);

/// One instance per piece-detail-screen visit (autoDispose ties its lifetime
/// to whoever's watching it — the screen watches it unconditionally, so it
/// lives exactly as long as the screen does, and is torn down on the way out
/// rather than accumulating one `AudioPlayer` per piece ever opened).
/// Deliberately not app-wide: this is a per-visit tool, not a persistent
/// session-wide service.
final mediaPlaybackServiceProvider =
    Provider.autoDispose<MediaPlaybackService>((ref) {
  AudioOutput.ensureStarted();
  final service = MediaPlaybackService(
    ref.watch(midiGeneratorProvider),
    store: ref.watch(mediaAlignmentStoreProvider),
  );
  _followHighlightSettings(ref, service);
  _follow<double>(ref, highlightLeadMsProvider,
      (ms) => service.highlightLeadSeconds = ms / 1000);
  ref.onDispose(service.dispose);
  return service;
});

final mediaActionsProvider = Provider<MediaActions>(MediaActions.new);

/// Removing a medium spans three stores plus the file system, so — like
/// [LibraryActions] for pieces — it is composed in one place rather than left
/// for each caller to remember all four steps.
class MediaActions {
  MediaActions(this._ref);

  final Ref _ref;

  /// Takes a user medium out: its files, its cached alignment, its row in the
  /// piece's media list, and the selection if it happened to be selected.
  ///
  /// Refuses bundled tracks and the synthesized score, which own no files and
  /// cannot be removed — the picker only offers delete on
  /// [PieceMedia.isRemovable], and this asserts the same thing.
  Future<void> deleteMedia(String pieceId, PieceMedia media) async {
    assert(media.isRemovable, 'Only imported or recorded media can be removed');
    await deleteMediaFiles(media);
    await _ref.read(mediaAlignmentStoreProvider).clear(media.alignmentKey);
    await _ref.read(pieceMediaStoreProvider).remove(pieceId, media.id);
    final selection = _ref.read(selectedMediaIdProvider(pieceId));
    if (selection == media.id) {
      _ref.read(selectedMediaIdProvider(pieceId).notifier).state = null;
    }
    _ref.invalidate(pieceMediaProvider(pieceId));
  }

  /// Records where the tune sits inside [media]'s file, and throws the cached
  /// alignment away so the next load recomputes with it. Nulls clear the
  /// window back to "work it out from the audio".
  ///
  /// Clearing the alignment is the whole point: the window is an INPUT to DTW,
  /// so leaving the previous run's anchors cached would store the answer and
  /// discard the question. The medium row itself is updated first, so a
  /// recompute that starts the moment the provider invalidates already sees
  /// the new figures.
  ///
  /// Only user media can carry a window — a bundled track has no stored row to
  /// write it to, and (per docs/audio-sync-next-steps.md) nobody to ask.
  Future<void> setContentWindow(
    String pieceId,
    PieceMedia media, {
    double? startSeconds,
    double? endSeconds,
  }) async {
    assert(media.isRemovable,
        'Only imported or recorded media have a stored row to annotate');
    final updated = media.withContentWindow(
        startSeconds: startSeconds, endSeconds: endSeconds);
    if (updated == media) return;
    await _ref.read(pieceMediaStoreProvider).update(pieceId, updated);
    await _ref.read(mediaAlignmentStoreProvider).clear(media.alignmentKey);
    _ref.invalidate(pieceMediaProvider(pieceId));
  }

  /// Stores [rating] on [media] (null clears it). Unlike [setContentWindow]
  /// the alignment is kept: a rating judges it, it doesn't change its inputs.
  Future<void> rateAlignment(
      String pieceId, PieceMedia media, AlignmentRating? rating) async {
    assert(media.isRemovable,
        'Only imported or recorded media have a stored row to rate');
    final updated = media.withAlignmentRating(rating);
    if (updated == media) return;
    await _ref.read(pieceMediaStoreProvider).update(pieceId, updated);
    _ref.invalidate(pieceMediaProvider(pieceId));
  }

  /// Everything a piece's media own, for when the piece itself is deleted.
  Future<void> deleteAllFor(String pieceId) async {
    final store = _ref.read(pieceMediaStoreProvider);
    final alignments = _ref.read(mediaAlignmentStoreProvider);
    for (final media in await store.load(pieceId)) {
      await deleteMediaFiles(media);
      await alignments.clear(media.alignmentKey);
    }
    await deletePieceMediaFolder(pieceId);
    await store.clear(pieceId);
    _ref.read(selectedMediaIdProvider(pieceId).notifier).state = null;
    _ref.invalidate(pieceMediaProvider(pieceId));
  }
}

// ── Section navigation (minimap) ──────────────────────────────────────────────
// Top-most visible MEASURE number in the jianpu/fingering views, pushed on
// scroll; the minimap reads it to show "where we are" by mapping the measure to
// its (unfolded) section run. Only meaningful for the scrollable custom views —
// the staff falls back to playback/selection.
final scrollMeasureProvider = StateProvider<int?>((_) => null);

// A scroll-to-run request from the minimap. The `seq` lets an identical run be
// re-requested (a plain int wouldn't re-notify); the active custom view listens
// and calls Scrollable.ensureVisible on that run's header.
final navTargetRunProvider = StateProvider<({int run, int seq})?>((_) => null);

// ── String-label style preference ─────────────────────────────────────────────

final stringLabelStyleProvider =
    StateNotifierProvider<StringLabelStyleNotifier, StringLabelStyle>(
      (_) => StringLabelStyleNotifier(),
    );

class StringLabelStyleNotifier extends StateNotifier<StringLabelStyle> {
  StringLabelStyleNotifier() : super(StringLabelStyle.always);
  void set(StringLabelStyle v) => state = v;
}

// ── Chord-symbol display preference ───────────────────────────────────────────
// Chord symbols are shown above the staff in the staff, annotation & tab views;
// toggling off hides them (and the "New chords" footer).
// Remembered per piece — see [pieceDisplayPref]. This is the STORED choice;
// read [showChordsProvider].
final showChordsPrefProvider = pieceDisplayPref<bool>(
  'chords',
  true,
  encode: (v) => '$v',
  decode: bool.parse,
);

/// Whether chord symbols show: [showChordsPrefProvider], but never when the
/// instrument setting has no chords. The saved choice is kept for when it does.
final showChordsProvider = Provider<bool>(
  (ref) =>
      ref.watch(instrumentFeaturesProvider).chords &&
      ref.watch(showChordsPrefProvider),
);

// ── Note names & string-coloured noteheads ───────────────────────────────────
/// Annotated view: name every note (B♭, F♯…) in the row above the fingering,
/// sharing it with the chord bars — chords win where a score has them. Off by
/// default; turning it on reserves that row, so it reflows the page.
/// Remembered per piece — see [pieceDisplayPref].
final showNoteNamesProvider = pieceDisplayPref<bool>(
  'noteNames',
  false,
  encode: (v) => '$v',
  decode: bool.parse,
);

/// Staff & annotated views: tint each notehead with the colour of the string
/// it is played on (follows the open-vs-4th preference). A repaint, not a
/// re-engrave. Remembered per piece — see [pieceDisplayPref].
final colourNoteheadsByStringProvider = pieceDisplayPref<bool>(
  'noteheadStringColour',
  false,
  encode: (v) => '$v',
  decode: bool.parse,
);

// ── Highlight granularity ─────────────────────────────────────────────────────
/// On (the default): playback steps the highlight through every note. Off: it
/// highlights each measure's first note and holds it through the bar — the
/// only beat a recording's alignment actually verifies (see
/// `PlaybackServiceBase.highlightDownbeatOnly`, whose own default is the
/// opposite and is overwritten by this the moment a service exists). Applies to
/// synthesized playback and recordings alike. Remembered per piece — see
/// [pieceDisplayPref]; a piece switched off before stays off.
final highlightEveryNoteProvider = pieceDisplayPref<bool>(
  'highlightEveryNote',
  true,
  encode: (v) => '$v',
  decode: bool.parse,
);

/// How far ahead of a recording's aligned onset the highlight fires, in ms
/// (see `PlaybackServiceBase.highlightLeadSeconds`). A perception experiment,
/// so not remembered: autoDispose, held for the whole visit by the piece
/// screen (which listens even while the score is selected), so it survives
/// score ↔ recording switches and starts at 60 on each visit.
/// Recordings only — the synthesized score keeps the base class's default.
final highlightLeadMsProvider = StateProvider.autoDispose<double>((_) => 60);

// ── Lyric display preference ──────────────────────────────────────────────────
/// Which lyric verse the staff and annotated views engrave: 1 by default, null
/// for none. Remembered per piece ([pieceDisplayPref]), so a verse picked on a
/// four-verse song doesn't leave the next piece silently showing nothing.
///
/// Unlike [showChordsProvider], this one DOES reach the xml under the native
/// renderer, so changing it re-engraves and may reflow the page (see
/// [_stripHarmonyFor] for why a chord toggle must not). That's deliberate:
/// Verovio spaces the notes to fit the syllables, so hiding a verse while
/// keeping its reservation would leave the staff full of gaps sized for words
/// that aren't there. The picker is experimental; if the reflow grates, the
/// reservation trick is the thing to revisit.
final lyricVerseProvider = pieceDisplayPref<int?>(
  'lyricVerse',
  1,
  encode: (v) => v == null ? 'none' : '$v',
  decode: (s) => s == 'none' ? null : int.parse(s),
);

/// How many lyric verses the selected piece has — 0 hides the verse picker.
final pieceVerseCountProvider = Provider<int>(
  (ref) => ref.watch(parsedPieceProvider).valueOrNull?.verseCount ?? 0,
);

/// The chords this piece introduces, in order of first appearance, limited to
/// the ones [ChordShapeLibrary] can draw.
///
/// Note what is NOT here: the [showChordsProvider] toggle and the display mode.
/// This answers "what could be drawn", not "should it be" — the callers layer
/// their own conditions on top, and keeping them out means a piece's chord list
/// doesn't get recomputed every time a switch is flipped.
///
/// Two callers, which is the reason it exists as a provider rather than staying
/// inline in the widget: `NewChordsBlock` renders it, and the phone's bottom
/// tray has to know **in advance** whether that block will draw anything, so it
/// can leave off the drag handle and the one-time peek rather than opening onto
/// an empty panel.
///
/// Silently drops chords with no known shape — the library is ten triads and no
/// sevenths, so a tune in D7/A7 legitimately yields an empty list.
final pieceChordShapesProvider = Provider<List<ChordShape>>((ref) {
  // No chords in this instrument setting: no diagrams, and so no tray either.
  if (!ref.watch(instrumentFeaturesProvider).chords) return const [];
  final parsed = ref.watch(parsedPieceProvider).valueOrNull;
  if (parsed == null) return const [];

  final seen = <String>{};
  return [
    for (final m in parsed.measures)
      for (final n in m.notes)
        if (n.chordSymbol case final c?)
          if (seen.add(c)) ?ChordShapeLibrary.lookup(c),
  ];
});

/// Whether `<harmony>` should be stripped before the score is engraved.
///
/// Never under the native renderer, whichever view is asking. The chord bars are
/// drawn from [EngravedScore.harmRegister] — the baseline Verovio engraved its own
/// chord symbols at — so an engrave with no `<harm>` yields no register and every
/// bar is silently skipped. Verovio's own `<harm>` glyphs are cut back out of the
/// SVG afterwards ([VerovioEngraver.stripAnnotationGlyphs]), so keeping them in
/// costs no duplicate ink — they are there for their geometry alone.
///
/// Only the ENGRAVED xml is at stake either way: the parsed model keeps
/// `NoteEvent.chordSymbol`, which is what the bars and the footer diagrams are
/// built from.
///
/// That is not hypothetical. This used to answer "yes, strip" for the native
/// renderer while a second predicate answered "no, keep" for the annotated view,
/// and the two were combined at two of the three call sites and not the third. The
/// result: the tab view and then the plain staff view each drew no chord bars at
/// all, silently, while the annotated view was fine. One question deserves one
/// answer, so there is now one function.
///
/// The chord-symbol toggle does NOT reach the xml: the row is reserved whether
/// or not the bars are painted, so toggling is a repaint, and
/// [showChordsProvider] is not even watched here — which matters because these are `FutureProvider`s.
/// Invalidating one drops the staff to a spinner, unmounts the render widget and
/// throws away its engrave and calibration; the re-engrave then re-runs the
/// auto-fit against whatever the viewport is now, and the page REFLOWS. A chord
/// toggle must never be able to do that.
///
/// The exception is the instrument setting: with no chords at all there is no
/// row to keep, so `<harmony>` goes — otherwise Verovio would reserve an empty
/// band above every staff. That setting is changed on
/// the Settings page, away from any engraved piece, so its re-engrave is fine.
bool _stripHarmonyFor(Ref ref) => !ref.watch(instrumentFeaturesProvider).chords;

// ── Fingering-annotation display preferences ──────────────────────────────────
// All three apply to the annotation view only, and none of them changes what is
// ENGRAVED — the labels are drawn in a Flutter lane (`_FingeringLanePainter`), so
// every one of these repaints without a re-engrave.
// Remembered per piece — see [pieceDisplayPref].

/// How the fingering channel shows the string (G green, D blue, A red, E
/// yellow): as a filled chip, as a rule under near-black numbers, or not at all.
///
/// While a colour is carrying the string the label drops the letter; with
/// [StringColourStyle.off] the [stringLabelStyleProvider] letter rules apply
/// instead. Three styles so they can be compared on real music — see
/// [StringColourStyle].
final stringColourStyleProvider = pieceDisplayEnumPref<StringColourStyle>(
  'stringColour',
  StringColourStyle.underline,
  StringColourStyle.values,
);

/// How much fingering the annotation view shows.
final fingeringDensityProvider = pieceDisplayEnumPref<FingeringDensity>(
  'fingeringDetail',
  FingeringDensity.all,
  FingeringDensity.values,
);

/// Which rule decides what "crucial" fingering means at the lower densities.
/// Surfaced in the UI because the definition needs playing feedback to settle —
/// see [FingeringDensityPolicy].
final fingeringDensityPolicyProvider = StateProvider<FingeringDensityPolicy>(
  (_) => FingeringDensityPolicy.difficulty,
);

/// Whether the staff views lay the selected piece out by section: it has two
/// or more sections, and either Fit is on or Custom with its Sections layout
/// ([sectionLayoutProvider]). Every section then starts a line, and a
/// section that starts on a lead-in mid-bar has that bar split so the lead-in
/// opens its line ([sectionBarSplits]). The staff view decides how each
/// section fills its lines, from [staffSizeProvider].
///
/// Never the tab view, whose xml is not broken by section.
final staffBySectionProvider = Provider<bool>(
  (ref) =>
      ref.watch(sectionLayoutAvailableProvider) &&
      switch (ref.watch(effectiveStaffViewModeProvider)) {
        StaffViewMode.fit => true,
        StaffViewMode.custom => ref.watch(sectionLayoutProvider),
        StaffViewMode.original => false,
      },
);

/// Whether the Sections layout is possible for the selected piece at all — the
/// conditions of [staffBySectionProvider] short of the mode and the toggle.
final sectionLayoutAvailableProvider = Provider<bool>((ref) {
  final piece = ref.watch(selectedPieceProvider);
  return piece != null && piece.sections.length >= 2;
});

/// The staff views' engraved measure map: one slice per measure, plus the
/// extra slice of every bar a [staffBySectionProvider] layout splits. Must
/// agree with [_breaksFor], which splits the xml at the same
/// [sectionBarSplits].
EngravedMeasureMap staffMeasureMapFor(
  List<Measure> measures,
  List<Section> sections, {
  required bool bySection,
}) =>
    bySection
        ? EngravedMeasureMap.withSplits(
            measures, sectionBarSplits(sections, measures),
            moved: movedRepeats(sections, measures),
            order: ParsedPiece.performanceOrder(measures))
        : EngravedMeasureMap.identity(measures.map((m) => m.number));

/// The staff views' line breaks, applied last so every injector before it
/// still addresses whole model measures:
///  * by section ([staffBySectionProvider]): bars split at section lead-ins,
///    repeats moved to include a lead-in the split sent to the next line
///    ([movedRepeats]), and a break before every section. The staff view
///    plans the rest.
///  * like the printed page ([staffByPrintedLinesProvider]): a break at each
///    of [printedLines] (document positions, read before the scan's own
///    breaks were stripped). The staff view plans the rest, as by section.
///  * otherwise untouched; Verovio breaks it.
String _breaksFor(
  Ref ref,
  String xml,
  List<Section> sections,
  ParsedPiece? parsed, {
  List<int> printedLines = const [],
}) {
  if (ref.watch(staffByPrintedLinesProvider)) {
    return insertBreaksAtPositions(xml, printedLines.toSet());
  }
  if (ref.watch(staffBySectionProvider) && parsed != null) {
    xml = splitBarsAtSections(xml, sectionBarSplits(sections, parsed.measures));
    xml = moveRepeatsOntoLeadIns(xml, movedRepeats(sections, parsed.measures));
    return insertSystemBreaks(xml, sections: sections);
  }
  return xml;
}

/// Hides the piece's own opening clef/key/time so the main render's first
/// system gets the same space back that [_breaksFor]/`freezeSystemBreaks`
/// already recover on every later one — paired with [preambleMusicXmlProvider],
/// which shows the same preamble next to the piece title instead.
String _hidePreambleFor(Ref ref, String xml) => hideFirstSystemPreamble(xml);

// ── Processed staff XML providers ─────────────────────────────────────────────

final staffXmlProvider = FutureProvider<String?>(
  (ref) => _staffXml(ref, fingering: false),
);

/// The staff views' xml: plain, or with the fingering row reserved
/// ([fingering], the annotation view). With [print], the xml print engraves
/// (`score_printer.dart`): the same pipeline, line breaks included, except
/// that it keeps the opening clef/key/time — paper has no title bar to move
/// them to.
Future<String?> _staffXml(Ref ref, {required bool fingering, bool print = false}) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  // Not [pieceLayoutProvider]: its rows follow the screen width, which the
  // detail screen pushes after its first frame, and waiting on it here made
  // that push redo this whole pipeline. stripLayoutHints never reads them.
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (parsed == null) return null;
  String? source = await ref.watch(pieceViewXmlProvider.future);
  if (source == null) return null;
  String xml = source;
  // The printed page's lines, before [PieceLayout.stripLayoutHints] drops them.
  final printedLines = systemStartPositions(xml);
  xml = PieceLayout.stripLayoutHints(xml);
  xml = PieceLayout.dropOpeningHiddenRests(xml);
  if (!print) xml = _hidePreambleFor(ref, xml);
  if (!fingering) {
    xml = FingeringXmlInjector.stripFingerings(xml);
  } else {
    // The staff hides the engraved glyph and paints its own chips (from
    // `NoteEvent.fingerString`/`fingerNumber`), so the xml carries
    // style-independent placeholders purely so Verovio reserves the row. The
    // publisher's own fingerings are replaced, so a leftover engraved label can
    // never contradict the app's note for note.
    xml = FingeringXmlInjector.injectPlaceholders(
        xml, fingeringLabelsOf(parsed));
  }
  // Keep `<harmony>` so the chord row is reserved too.
  if (_stripHarmonyFor(ref)) xml = ChordXmlInjector.stripHarmony(xml);
  xml = LyricXmlInjector.selectVerse(xml, ref.watch(lyricVerseProvider));
  // Print breaks exactly as the screen does, so the page follows the
  // current layout (by section, like the printed page, locked or free).
  return _breaksFor(ref, xml, piece.sections, parsed,
      printedLines: printedLines);
}

/// The xml print engraves, by whether it carries the fingering row (the
/// annotation view) — see [_staffXml].
final printStaffXmlProvider = FutureProvider.family<String?, bool>(
  (ref, fingering) => _staffXml(ref, fingering: fingering, print: true),
);

/// The piece's opening clef/key/time, engraved alone — the counterpart to
/// [_hidePreambleFor] stripping it from the main render. Read off the piece's
/// own untouched XML (not [staffXmlProvider]'s output, which has already had
/// it marked non-printing) so the real glyphs are always available to show.
final preambleMusicXmlProvider = FutureProvider<String?>((ref) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final repo = ref.watch(pieceRepositoryProvider);
  final xml = await repo.loadMusicXml(piece);
  return buildPreambleXml(xml);
});

final staffFingeringXmlProvider = FutureProvider<String?>(
  (ref) => _staffXml(ref, fingering: true),
);

/// Violin fingering vs true mandolin fret numbers — the drawer's "Instrument" —
/// wherever a number labels a note: the tab staff's string lines, the
/// annotation view's fingering channel, the vocabulary palette and the title
/// line's low/high fingerings. ONE preference for all — see [NoteNumberMode].
///
/// Remembered per piece — see [pieceDisplayPref].
///
/// Note the asymmetry in what a change costs: the tab staff carries its numbers
/// in the engraved xml ([tabScoreProvider] watches this, so it re-engraves),
/// while the channel draws them in a Flutter overlay, so there it is a repaint.
///
/// This is the STORED choice; read [noteNumberModeProvider].
final noteNumberModePrefProvider = pieceDisplayEnumPref<NoteNumberMode>(
  'numbers',
  NoteNumberMode.violinFingering,
  NoteNumberMode.values,
);

/// The numbers in effect: [noteNumberModePrefProvider], but always the violin
/// fingering when the instrument setting has no fret numbers — a piece saved in
/// fret mode would otherwise open in frets with no picker to leave them. The
/// saved choice is kept, so it comes back if the setting does.
final noteNumberModeProvider = Provider<NoteNumberMode>(
  (ref) => ref.watch(instrumentFeaturesProvider).fretNumbers
      ? ref.watch(noteNumberModePrefProvider)
      : NoteNumberMode.violinFingering,
);

/// In fret mode: prefer open strings (frets ≤6, beginner-friendly) vs put the
/// fret on the fingering's string. Shared by the same two views as
/// [noteNumberModeProvider]. Remembered per piece; only affects fret numbers.
final fretStyleProvider = pieceDisplayEnumPref<FretStyle>(
  'fretStyle',
  FretStyle.openStrings,
  FretStyle.values,
);

/// On the violin: open string or 4th finger, where a note could be either.
/// Remembered per piece — see [ViolinStringPreference].
final violinStringPreferenceProvider =
    pieceDisplayEnumPref<ViolinStringPreference>(
  'violinStrings',
  ViolinStringPreference.auto,
  ViolinStringPreference.values,
);

/// The 2-staff MusicXML (melody + 4-line tab) plus the ordered fingering labels
/// for the tab view. Reuses the same strip pipeline as [staffXmlProvider] so the
/// melody staff shows no fingerings (they live only on the tab staff).
final tabScoreProvider = FutureProvider<TabScore?>((ref) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (parsed == null) return null;
  final numberMode = ref.watch(noteNumberModeProvider);
  final fretStyle = ref.watch(fretStyleProvider);
  final source = await ref.watch(pieceViewXmlProvider.future);
  if (source == null) return null;
  String xml = source;
  xml = PieceLayout.stripLayoutHints(xml);
  xml = FingeringXmlInjector.stripFingerings(xml);
  // Chord symbols ride above the melody staff here just like in the staff views
  // (the `<harmony>` elements stay on staff 1; the tab staff is staff 2).
  //
  // Kept in for the same reason as the annotated view:
  // the bars are drawn from `EngravedScore.harmRegister`, so with no engraved
  // `<harm>` there is no register and every bar is silently skipped. That is
  // exactly what this comment used to claim was happening while the view in fact
  // showed no chords at all.
  if (_stripHarmonyFor(ref)) xml = ChordXmlInjector.stripHarmony(xml);
  // No lyrics in the tab view (yet): the melody staff would carry them, but
  // the space under it is the tab staff's.
  xml = LyricXmlInjector.selectVerse(xml, null);
  return TabScoreGenerator.generate(
    xml,
    parsed,
    fretMode: numberMode == NoteNumberMode.mandolinFret,
    preferOpenFrets: fretStyle == FretStyle.openStrings,
  );
});

final paletteMusicXmlProvider = FutureProvider<String?>((ref) async {
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (parsed == null) return null;
  // The staff draws the labels itself, as the score's chips, from
  // [palettePieceProvider] — but only into a row Verovio has reserved, so it
  // gets placeholders, exactly as the annotation view's xml does.
  final palette = PaletteXmlGenerator.piece(parsed);
  if (palette == null) return null;
  return FingeringXmlInjector.injectPlaceholders(
      PaletteXmlGenerator.generate(parsed), fingeringLabelsOf(palette));
});

/// The note vocabulary as a piece of its own — see [PaletteXmlGenerator.piece].
final palettePieceProvider = FutureProvider<ParsedPiece?>((ref) async {
  final parsed = await ref.watch(parsedPieceProvider.future);
  return parsed == null ? null : PaletteXmlGenerator.piece(parsed);
});

// ── Measure selection ─────────────────────────────────────────────────────────

class MeasureSelection {
  final int startMeasure;
  final int endMeasure;

  /// Note edges, for a selection of a section that starts or ends mid-bar
  /// (see [SectionRun.startNote]): [startNote] is the first selected note of
  /// [startMeasure], [endNote] the EXCLUSIVE end in [endMeasure], `-1` for
  /// the whole bar. A tapped selection is always whole bars.
  final int startNote;
  final int endNote;

  /// The pass, for a selected section run: the performance-order indices of
  /// its first and last bars ([SectionRun.perfStart], `perfEnd - 1`). A run
  /// can start in a bar another run also starts in, on another pass (Devil's
  /// Dream's `e2` before `:|` leads into A², then into B), so the measure
  /// numbers alone don't say which. `-1` for a tapped selection.
  final int startPerf;
  final int endPerf;

  /// Bars inside the range that the selected pass doesn't play — a first
  /// ending under a second pass ([SectionRun.skipped]). Not selected, not
  /// highlighted; playback already skips them by its pinned pass.
  final Set<int> skipped;

  const MeasureSelection(this.startMeasure, this.endMeasure,
      {this.startNote = 0,
      this.endNote = -1,
      this.startPerf = -1,
      this.endPerf = -1,
      this.skipped = const {}});

  /// The selection covering exactly [run], mid-bar edges included.
  factory MeasureSelection.ofRun(SectionRun run) => MeasureSelection(
      run.firstMeasure, run.lastMeasure,
      startNote: run.startNote,
      endNote: run.endNote,
      startPerf: run.perfStart,
      endPerf: run.perfEnd < 0 ? -1 : run.perfEnd - 1,
      skipped: run.skipped);

  /// The selection from the start of [first] to the end of [last], pinned to
  /// those passes — e.g. a whole folded repeat, `B¹` through `C²`.
  factory MeasureSelection.ofRuns(SectionRun first, SectionRun last) =>
      MeasureSelection(first.firstMeasure, last.lastMeasure,
          startNote: first.startNote,
          endNote: last.endNote,
          startPerf: first.perfStart,
          endPerf: last.perfEnd < 0 ? -1 : last.perfEnd - 1,
          // A bar one pass skips and another plays is in the span.
          skipped: first.skipped.intersection(last.skipped));

  /// The part of bar [measure] that note [note] is in, where [sections]
  /// start mid-bar there: a bar split by a section break is two (or more)
  /// short chunks, selected and played apart. The whole bar without a break.
  static ({int startNote, int endNote}) chunkAt(
      List<Section> sections, int measure, int note) {
    var start = 0, end = -1;
    for (final s in sections) {
      if (s.startMeasure != measure || s.startNote <= 0) continue;
      if (s.startNote <= note && s.startNote > start) start = s.startNote;
      if (s.startNote > note && (end < 0 || s.startNote < end)) {
        end = s.startNote;
      }
    }
    return (startNote: start, endNote: end);
  }

  /// What Play plays of this selection: whole bars, except that a section
  /// starting mid-bar in the first or last bar cuts it there. Bars 6–14 of a
  /// piece whose next section's pickup is in bar 14 stop before the pickup,
  /// and start on bar 6's own section's pickup rather than on the last notes
  /// of the section before. Only a whole-bar range of two or more bars is
  /// cut: a selected section already has its edges, and a tapped bar is
  /// already the chunk the tap was in ([afterTap], [chunkAt]) — or, from a
  /// view that can't tell where in the bar it was tapped, the whole bar.
  MeasureSelection cutAtSections(List<Section> sections) {
    if (startNote != 0 || endNote != -1 || startMeasure == endMeasure) {
      return this;
    }
    int? first(int measure) {
      int? best;
      for (final s in sections) {
        if (s.startMeasure == measure &&
            s.startNote > 0 &&
            (best == null || s.startNote < best)) {
          best = s.startNote;
        }
      }
      return best;
    }

    final start = first(startMeasure), end = first(endMeasure);
    if (start == null && end == null) return this;
    return MeasureSelection(startMeasure, endMeasure,
        startNote: start ?? 0,
        endNote: end ?? -1,
        startPerf: startPerf,
        endPerf: endPerf,
        skipped: skipped);
  }

  bool contains(int measure) =>
      measure >= startMeasure &&
      measure <= endMeasure &&
      !skipped.contains(measure);

  bool get isSingle => startMeasure == endMeasure;

  /// New selection after tapping [tapped], given the [current] selection.
  ///
  /// A tap always means "this bar", shared by every notation view (staff,
  /// jianpu, fingering): it selects exactly [tapped], replacing whatever was
  /// selected — a range included. Tapping the bar that is already the whole
  /// selection clears it. Ranges come from a hold-and-drag ([spanning]) or
  /// the selection's end handles ([nudgeStart], [nudgeEnd]), never from a
  /// second tap: "tap to extend" made the same tap mean three things, and
  /// testers kept getting the one they didn't want.
  ///
  /// [chunk] narrows the bar to the part of it a section break leaves the
  /// tap in ([chunkAt]); null, or a bar with no break, is the whole bar.
  static MeasureSelection? afterTap(MeasureSelection? current, int tapped,
      {({int startNote, int endNote})? chunk}) {
    final single = MeasureSelection(tapped, tapped,
        startNote: chunk?.startNote ?? 0, endNote: chunk?.endNote ?? -1);
    return current == single ? null : single;
  }

  /// The whole bars from [anchor] to [other], in either order — what a
  /// hold-and-drag from [anchor] selects with the finger over [other].
  factory MeasureSelection.spanning(int anchor, int other) => MeasureSelection(
      anchor < other ? anchor : other, anchor > other ? anchor : other);

  /// This selection with its first bar moved by [delta] (negative grows it
  /// leftwards), kept within [first]..[last] and never past its own end. The
  /// result is whole bars: a nudged section loses its mid-bar edges and pass.
  MeasureSelection nudgeStart(int delta,
          {required int first, required int last}) =>
      MeasureSelection(
          (startMeasure + delta).clamp(first, endMeasure.clamp(first, last)),
          endMeasure.clamp(first, last));

  /// This selection with its last bar moved by [delta] (positive grows it
  /// rightwards), kept within [first]..[last] and never before its own start.
  MeasureSelection nudgeEnd(int delta,
          {required int first, required int last}) =>
      MeasureSelection(startMeasure.clamp(first, last),
          (endMeasure + delta).clamp(startMeasure.clamp(first, last), last));

  @override
  bool operator ==(Object other) =>
      other is MeasureSelection &&
      other.startMeasure == startMeasure &&
      other.endMeasure == endMeasure &&
      other.startNote == startNote &&
      other.endNote == endNote &&
      other.startPerf == startPerf &&
      other.endPerf == endPerf &&
      other.skipped.length == skipped.length &&
      other.skipped.containsAll(skipped);

  @override
  int get hashCode => Object.hash(startMeasure, endMeasure, startNote,
      endNote, startPerf, endPerf, Object.hashAllUnordered(skipped));
}

final measureSelectionProvider = StateProvider<MeasureSelection?>((_) => null);

/// [measureSelectionProvider] as Play takes it: cut at the section breaks
/// inside its first and last bars ([MeasureSelection.cutAtSections]).
final playedSelectionProvider = Provider<MeasureSelection?>((ref) => ref
    .watch(measureSelectionProvider)
    ?.cutAtSections(ref.watch(selectedPieceProvider)?.sections ?? const []));

/// A hold-and-drag range selection is in progress on the notation. The tray,
/// which rises on any new selection, waits for the finger to lift rather
/// than rising under it.
final measureDragActiveProvider = StateProvider<bool>((_) => false);

// ── Playback ──────────────────────────────────────────────────────────────────

final midiGeneratorProvider = Provider<MidiGenerator>((_) => MidiGenerator());

/// Settings every playback service takes, whichever one is playing. Applied
/// here rather than pushed in by the screen, so a service is right from the
/// moment it exists — the recording service is autoDispose and would otherwise
/// start every visit on the base class's defaults.
void _followHighlightSettings(Ref ref, PlaybackServiceBase service) {
  _follow<bool>(ref, highlightEveryNoteProvider,
      (everyNote) => service.highlightDownbeatOnly = !everyNote);
  _follow<PlayMode>(ref, playModeProvider,
      (mode) => service.loopEnabled = mode == PlayMode.loop);
}

/// What Play does with the selection (or, with none, the piece).
enum PlayMode {
  /// Play it, then stop.
  once,

  /// Go round it again until paused.
  loop,

  /// Start at it and carry on to the end of the piece, through every repeat,
  /// ending and D.C. after it.
  through,
}

/// The transport's Once / Loop / Through setting. One setting for every
/// source, so switching from the score to a recording keeps it — and so it
/// survives the recording service being rebuilt each visit. Session-only.
final playModeProvider = StateProvider<PlayMode>((_) => PlayMode.once);

/// Applies [provider]'s value to a service now, and again whenever it changes.
///
/// The first application is synchronous: the service was just constructed, has
/// no piece loaded, and so its setters touch no notifier. Later ones are
/// deferred to a microtask, because the setters resync the highlight — writing
/// `currentHighlightNotifier` — and a per-piece pref can be recomputed while a
/// widget is building (opening another piece), where a notifier write would
/// rebuild its listeners mid-build.
void _follow<T>(Ref ref, ProviderListenable<T> provider, void Function(T) apply) {
  var disposed = false;
  ref.onDispose(() => disposed = true);
  apply(ref.read(provider));
  ref.listen<T>(provider, (_, next) {
    scheduleMicrotask(() {
      if (!disposed) apply(next);
    });
  });
}

/// Whatever is playing the selected piece: the recording picked in the tray,
/// the synthesized score (rendered to a file, [RenderedScorePlaybackService]),
/// or Silent's clock. Every view's highlight and anything that reacts to
/// "Play was pressed" should follow this.
///
/// There was a live synth (flutter_midi_pro) until 2026-11-20; the rendered
/// score replaced it (docs/rendered-score-plan.md, phase 6). It struck notes
/// in real time, so it needed its own speaker-delay calibration and had to be
/// rebuilt on every speaker change, and on AirPlay it often went silent.
///
/// autoDispose because the players it holds are.
final activePlaybackServiceProvider =
    Provider.autoDispose<PlaybackServiceBase>((ref) {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return ref.watch(silentPlaybackServiceProvider);
  // While the list is still loading the synthesized score stands in — it is
  // what the list starts with anyway, so nothing flickers.
  final media = ref.watch(pieceMediaProvider(piece.id)).valueOrNull ??
      const [PieceMedia.synthesized];
  final selected =
      MediaCatalog.resolve(media, ref.watch(selectedMediaIdProvider(piece.id)));
  // "Silent" is the score's clock alone (SilentPlaybackService): the cursor
  // at the tempo, no audio, no speaker held.
  if (selected.isSilent) return ref.watch(silentPlaybackServiceProvider);
  return selected.isSynthesized
      ? ref.watch(renderedScoreServiceProvider)
      : ref.watch(mediaPlaybackServiceProvider);
});

/// The Silent track's player, for the selected piece at the tray's tempo.
/// autoDispose: one per visit, like the other players.
final silentPlaybackServiceProvider =
    Provider.autoDispose<SilentPlaybackService>((ref) {
  final service = SilentPlaybackService(ref.watch(midiGeneratorProvider));
  _followHighlightSettings(ref, service);
  void load() {
    final piece = ref.read(parsedPieceProvider).valueOrNull;
    if (piece != null) unawaited(service.loadPiece(piece));
  }

  void tempo() {
    final bpm = ref.read(tempoBpmProvider);
    if (service.currentBpm != bpm) service.setTempo(bpm);
  }

  ref.listen(parsedPieceProvider, (_, _) => load());
  ref.listen(tempoBpmProvider, (_, _) => tempo());
  // The tempo first, so the piece is generated at it once rather than twice.
  service.setTempo(ref.read(tempoBpmProvider));
  load();
  ref.onDispose(service.dispose);
  return service;
});

/// The synthesized score as a rendered recording, for the selected piece at
/// the tempo the tray asks for. autoDispose like the recording service: one
/// player per visit. The renders it keeps (RenderedScoreCache) outlive it.
final renderedScoreServiceProvider =
    Provider.autoDispose<RenderedScorePlaybackService>((ref) {
  AudioOutput.ensureStarted();
  final service = RenderedScorePlaybackService(
    ref.watch(midiGeneratorProvider),
    cache: ref.watch(renderedScoreCacheProvider),
  );
  _followHighlightSettings(ref, service);
  void configure() {
    final piece = ref.read(parsedPieceProvider).valueOrNull;
    if (piece == null) return;
    unawaited(service.configure(
      piece: piece,
      performanceBpm: ref.read(performanceTempoProvider).bpm,
      bpm: ref.read(tempoBpmProvider),
    ));
  }

  ref.listen(parsedPieceProvider, (_, _) => configure());
  ref.listen(performanceTempoProvider, (_, _) => configure());
  ref.listen(tempoBpmProvider, (_, _) => configure());
  configure();
  ref.onDispose(service.dispose);
  return service;
});

/// App-wide, so concurrent renders of one key are shared and the cache's
/// directory is opened once.
final renderedScoreCacheProvider =
    Provider<RenderedScoreCache>((_) => RenderedScoreCache());

/// [PlaybackState] of [activePlaybackServiceProvider].
final activePlaybackStateProvider =
    StreamProvider.autoDispose<PlaybackState>((ref) {
  final service = ref.watch(activePlaybackServiceProvider);
  // A switch of source mid-play must not leave the old one's last state
  // standing, so open on the new service's current state.
  Stream<PlaybackState> states() async* {
    yield service.playbackState;
    yield* service.state;
  }

  return states();
});

// ── Count-in ──────────────────────────────────────────────────────────────────

final countInStoreProvider = Provider<CountInStore>((_) => CountInStore());

/// The MINIMUM number of beats counted off when Play is pressed; 0 = off.
///
/// A minimum rather than an exact count, because the count always spans whole
/// bars less the pickup — see `countInPlan`. So 3 (the default) asks for a bar of
/// 4/4, two bars of 2/4, or a bar less the anacrusis, and only a bigger value
/// forces a longer lead-in.
///
/// One setting for the whole app rather than per piece, so it is restored once
/// per launch and not on every piece change. Nothing here has to wait for storage: the count-in matters
/// only when Play is pressed, by which time the read has long since landed.
final countInProvider = StateNotifierProvider<CountInNotifier, int>(
  (ref) => CountInNotifier(ref.watch(countInStoreProvider)),
);

class CountInNotifier extends StateNotifier<int> {
  CountInNotifier(this._store) : super(countInMinBeats) {
    _restore();
  }

  final CountInStore _store;
  bool _touched = false;

  Future<void> _restore() async {
    final saved = await _store.load();
    if (!mounted || _touched || saved == null) return; // a user change wins
    state = saved;
  }

  /// Live slider position — state only, no write (a drag would otherwise write
  /// once per stop it crosses).
  void preview(int beats) {
    _touched = true;
    state = beats;
  }

  /// Settles on [beats] and persists it; 0 turns the count-in off.
  void commit(int beats) {
    preview(beats);
    _store.save(beats);
  }
}

/// Where a recording's count-in comes from when the recording itself has no
/// (or too short an) intro before the start: silence, or the bars before.
/// App-wide, restored once per launch on the same terms as [countInProvider].
final recordingLeadInProvider =
    StateNotifierProvider<RecordingLeadInNotifier, RecordingLeadInMode>(
  (ref) => RecordingLeadInNotifier(ref.watch(countInStoreProvider)),
);

class RecordingLeadInNotifier extends StateNotifier<RecordingLeadInMode> {
  RecordingLeadInNotifier(this._store) : super(RecordingLeadInMode.silent) {
    _restore();
  }

  final CountInStore _store;
  bool _touched = false;

  Future<void> _restore() async {
    final saved = await _store.loadLeadIn();
    if (!mounted || _touched || saved == null) return;
    for (final m in RecordingLeadInMode.values) {
      if (m.name == saved) state = m;
    }
  }

  void set(RecordingLeadInMode mode) {
    _touched = true;
    state = mode;
    _store.saveLeadIn(mode.name);
  }
}

// ── Tempo ─────────────────────────────────────────────────────────────────────
final tempoStoreProvider = Provider<TempoStore>((_) => TempoStore());

/// The synthesized playback's tempo presets and which is selected. App-wide and
/// restored once per launch, on the same terms as [countInProvider].
final tempoSettingsProvider =
    StateNotifierProvider<TempoSettingsNotifier, TempoSettings>(
  (ref) => TempoSettingsNotifier(ref.watch(tempoStoreProvider)),
);

class TempoSettingsNotifier extends StateNotifier<TempoSettings> {
  TempoSettingsNotifier(this._store) : super(const TempoSettings()) {
    _restore();
  }

  final TempoStore _store;
  bool _touched = false;

  Future<void> _restore() async {
    final saved = await _store.load();
    if (!mounted || _touched || saved == null) return; // a user change wins
    state = saved;
  }

  void _set(TempoSettings s) {
    _touched = true;
    state = s;
    _store.save(s);
  }

  void select(TempoPreset p) => _set(state.withPreset(p));

  void setPercent(TempoPreset p, int pct) => _set(state.withPercent(p, pct));

  void setDefaultPerformance(int bpm) =>
      _set(state.withDefaultPerformance(bpm));

  void setCustom(int bpm) => _set(state.withCustom(bpm));
}

/// A performance tempo set by hand for one piece, or null to follow its
/// recordings. Persisted per piece.
final piecePerformanceOverrideProvider = StateNotifierProvider.family<
    PiecePerformanceOverrideNotifier, int?, String>(
  (ref, pieceId) =>
      PiecePerformanceOverrideNotifier(ref.watch(tempoStoreProvider), pieceId),
);

class PiecePerformanceOverrideNotifier extends StateNotifier<int?> {
  PiecePerformanceOverrideNotifier(this._store, this._pieceId) : super(null) {
    _restore();
  }

  final TempoStore _store;
  final String _pieceId;
  bool _touched = false;

  Future<void> _restore() async {
    final saved = await _store.loadPiecePerformance(_pieceId);
    if (!mounted || _touched) return;
    state = saved;
  }

  /// Null goes back to following the recordings.
  void set(int? bpm) {
    _touched = true;
    state = bpm == null ? null : clampBpm(bpm);
    _store.savePiecePerformance(_pieceId, state);
  }
}

/// The tempo of the recording loaded in the tray right now, measured from its
/// alignment; null with the synthesized score selected or an unaligned
/// recording. Set by the media transport.
final loadedRecordingBpmProvider = StateProvider<double?>((_) => null);

/// [pieceId]'s recorded tempo, from the first of its media (in picker order)
/// with a cached alignment — so the synthesized score's Performance matches
/// the teacher's tracks without one having to be played first in this visit.
/// Null when nothing has been aligned on this device yet. Invalidated by the
/// media transport after a load or realign changes the cache.
final pieceRecordingBpmProvider =
    FutureProvider.family<double?, String>((ref, pieceId) async {
  final media = await ref.watch(pieceMediaProvider(pieceId).future);
  final store = ref.watch(mediaAlignmentStoreProvider);
  for (final m in media) {
    if (m.isSynthesized || !m.canAlign) continue;
    final a = await store.load(m.alignmentKey);
    if (a == null) continue;
    final bpm = MediaPlaybackService.recordingBpmFrom(
        MediaPlaybackService.dropDegenerateSegments(
            MediaPlaybackService.sortAnchors(a.anchors)),
        a.generationBpm);
    if (bpm != null) return bpm;
  }
  return null;
});

/// Where the selected piece's performance tempo came from.
enum PerformanceSource { piece, recording, score, defaultTempo }

/// The selected piece's performance tempo, which Slow and Medium are shares
/// of: set for the piece by hand; else the loaded recording's own tempo (so
/// Performance plays it at exactly 1.0x); else its recordings' tempo from the
/// alignment cache (so the synthesized score matches them); else the tempo
/// marked in the score; else the app-wide default.
final performanceTempoProvider =
    Provider<({double bpm, PerformanceSource source})>((ref) {
  final piece = ref.watch(selectedPieceProvider);
  final fallback = ref.watch(tempoSettingsProvider.select((s) => s.performance));
  if (piece == null) {
    return (bpm: fallback.toDouble(), source: PerformanceSource.defaultTempo);
  }
  final override = ref.watch(piecePerformanceOverrideProvider(piece.id));
  if (override != null) {
    return (bpm: override.toDouble(), source: PerformanceSource.piece);
  }
  final recorded = ref.watch(loadedRecordingBpmProvider) ??
      ref.watch(pieceRecordingBpmProvider(piece.id)).valueOrNull;
  if (recorded != null) {
    return (
      bpm: recorded.clamp(minBpm.toDouble(), maxBpm.toDouble()),
      source: PerformanceSource.recording,
    );
  }
  final marked = ref.watch(parsedPieceProvider).valueOrNull?.markedBpm;
  if (marked != null) {
    return (bpm: marked, source: PerformanceSource.score);
  }
  return (bpm: fallback.toDouble(), source: PerformanceSource.defaultTempo);
});

/// The selected preset's tempo for the selected piece, unrounded — a
/// recording's playback rate is this over its own tempo.
final exactTempoBpmProvider = Provider<double>((ref) {
  final settings = ref.watch(tempoSettingsProvider);
  return settings.exactBpmFor(
      settings.preset, ref.watch(performanceTempoProvider).bpm);
});

/// What the synthesized score plays at.
final tempoBpmProvider =
    Provider<int>((ref) => ref.watch(exactTempoBpmProvider).round());

/// The measure Play starts from: the practice selection's first bar, or — with
/// nothing selected — the score's own first measure.
///
/// Deliberately NOT a literal 1. A pickup is commonly numbered 0 (MuseGroup's
/// `<measure number="0" implicit="yes">`), and `play(fromMeasure: 1)` resolves
/// that to the first FULL bar, silently dropping the anacrusis — which is both
/// the wrong note to start on and the reason the count-in needs shortening.
final playbackStartMeasureProvider = Provider<int>((ref) {
  final selection = ref.watch(playedSelectionProvider);
  if (selection != null) return selection.startMeasure;
  final measures = ref.watch(parsedPieceProvider).valueOrNull?.measures;
  return (measures == null || measures.isEmpty) ? 1 : measures.first.number;
});

/// The note within [playbackStartMeasureProvider] Play starts on: 0 but for a
/// selected section that begins mid-bar, on its lead-in.
final playbackStartNoteProvider = Provider<int>(
    (ref) => ref.watch(playedSelectionProvider)?.startNote ?? 0);

/// The count-off Play will actually give: the preference resolved against this
/// score's meter and shortened by a pickup at the start measure. Null = no count.
///
/// One provider so the Play button and the drawer's readout can't disagree — the
/// setting says "3 beats" precisely when Play will count three.
final resolvedCountInProvider = Provider<CountInPlan?>((ref) {
  final parsed = ref.watch(parsedPieceProvider).valueOrNull;
  final start = ref.watch(playbackStartMeasureProvider);
  // Counted in the meter of the bar Play starts on: a piece may change meter.
  final meter = parsed?.meterAtNumber(start) ?? const Meter(4, 4);
  final beatsPerMeasure = meter.beats;
  final beatType = meter.beatType;
  Measure? startMeasure;
  for (final m in parsed?.measures ?? const <Measure>[]) {
    if (m.number == start) {
      startMeasure = m;
      break;
    }
  }
  return countInPlan(
    beatsPerMeasure: beatsPerMeasure,
    beatType: beatType,
    minBeats: ref.watch(countInProvider),
    pickupUnits: pickupUnitsOf(
      startMeasure,
      beatsPerMeasure: beatsPerMeasure,
      beatType: beatType,
      fromNote: ref.watch(playbackStartNoteProvider),
    ),
  );
});
