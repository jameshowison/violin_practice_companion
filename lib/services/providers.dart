import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/piece.dart';
import '../models/piece_layout.dart';
import '../models/piece_library.dart';
// Four of the notifier's methods share a name with the free function they wrap
// (renameCollection, reorderInCollection, setHidden, forgetPiece), where the
// method would otherwise shadow it.
import '../models/piece_library.dart' as plib;
import '../models/section_run.dart';
import '../models/string_label_style.dart';
import '../models/tab_number_mode.dart';
import 'fingering_mapper.dart';
import 'tab_score_generator.dart';
import 'jianpu_converter.dart';
import 'midi_generator.dart';
import 'musicxml_parser.dart';
import 'fingering_xml_injector.dart';
import 'chord_xml_injector.dart';
import 'palette_xml_generator.dart';
import 'piece_library_store.dart';
import 'piece_repository.dart';
import 'playback_service.dart';
import 'playback_service_base.dart';
import 'staff_zoom_store.dart';

// ── Singletons ────────────────────────────────────────────────────────────────

final pieceRepositoryProvider = Provider<PieceRepository>((_) => PieceRepository());

final musicXmlParserProvider = Provider<MusicXmlParser>((_) => MusicXmlParser());

final jianpuConverterProvider = Provider<JianpuConverter>((_) => JianpuConverter());

final fingeringMapperProvider = Provider<FingeringMapper>((_) => FingeringMapper());

// ── Piece list ────────────────────────────────────────────────────────────────

/// Every piece there is, unfiltered — fixtures in declaration order, then user
/// pieces oldest-first.
///
/// Deliberately knows nothing about the library. Filtering hidden pieces inside
/// `loadAll()` would make the repository depend on `shared_preferences` (so it
/// could not run headless), would force this into a family so all four
/// `ref.invalidate(piecesProvider)` sites had to care about a flag unrelated to
/// importing a score, and would leave the Manage screen — which needs
/// everything, with hidden marked — without a source. See [visiblePiecesProvider].
final piecesProvider = FutureProvider<List<Piece>>((ref) async {
  return ref.watch(pieceRepositoryProvider).loadAll();
});

// ── Selected piece ────────────────────────────────────────────────────────────

final selectedPieceProvider = StateProvider<Piece?>((ref) => null);

// ── Piece library (collections, hidden pieces, renames) ──────────────────────

final pieceLibraryStoreProvider =
    Provider<PieceLibraryStore>((_) => PieceLibraryStore());

final libraryProvider =
    AsyncNotifierProvider<PieceLibraryNotifier, PieceLibrary>(
        PieceLibraryNotifier.new);

class PieceLibraryNotifier extends AsyncNotifier<PieceLibrary> {
  @override
  Future<PieceLibrary> build() async {
    final store = ref.watch(pieceLibraryStoreProvider);
    final loaded = await store.load();
    final seeded = seedLibrary(
      loaded,
      omrDemoIds: PieceRepository.omrDemoFixtureIds,
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    );
    // Value equality, so this writes on the first launch only.
    if (seeded != loaded) await store.save(seeded);
    return seeded;
  }

  /// Applies [f], publishes the result immediately, then writes.
  ///
  /// State first, persist after — the same order as [MeasuresPerLineNotifier],
  /// so a chip tap or a drag never waits on storage. The write is best-effort
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

  Future<void> createCollection(String name) => _mutate((l) => addCollection(l,
      name: name, nowMillis: DateTime.now().millisecondsSinceEpoch));

  Future<void> renameCollection(String id, String name) =>
      _mutate((l) => plib.renameCollection(l, id, name));

  Future<void> deleteCollection(String id) =>
      _mutate((l) => removeCollection(l, id));

  Future<void> setTags(String pieceId, Set<String> collectionIds) => _mutate(
      (l) => setPieceTags(l, pieceId: pieceId, collectionIds: collectionIds));

  /// [visibleIds] is the collection as displayed; see [reorderInCollection].
  Future<void> reorderInCollection(
    String collectionId,
    List<String> visibleIds,
    int oldIndex,
    int newIndex,
  ) =>
      _mutate((l) => plib.reorderInCollection(
          l, collectionId, visibleIds, oldIndex, newIndex));

  Future<void> setHidden(String pieceId, bool hidden) =>
      _mutate((l) => plib.setHidden(l, pieceId, hidden));

  /// A null or blank [title] clears the override, reverting to the score's own.
  Future<void> renamePiece(String pieceId, String? title) =>
      _mutate((l) => setTitleOverride(l, pieceId, title));

  Future<void> forgetPiece(String pieceId) =>
      _mutate((l) => plib.forgetPiece(l, pieceId));
}

/// The collection whose chip is selected, by ID — null is the "All" chip.
///
/// An ID rather than a name, so renaming the active collection doesn't drop the
/// filter. Session-only, like the other display-preference providers.
final activeCollectionProvider = StateProvider<String?>((_) => null);

/// Every piece with its user-chosen title applied — nothing filtered, nothing
/// reordered. What the Manage screen lists (it needs the hidden ones too).
///
/// The library is read with `valueOrNull` rather than awaited: while the
/// metadata read is in flight the raw list shows instead of a spinner.
/// Decoration must never gate the library screen.
final libraryPiecesProvider = Provider<AsyncValue<List<Piece>>>((ref) {
  final lib = ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty;
  return ref
      .watch(piecesProvider)
      .whenData((pieces) => applyLibrary(lib, pieces, showHidden: true));
});

/// The everyday piece list: overridden titles, hidden pieces dropped, and — when
/// a chip is selected — that collection's members in its hand-set order. With no
/// chip selected the repository's own order stands.
///
/// There is deliberately no "show hidden" escape hatch here. This list once had
/// a session-sticky toggle, and it was a trap: leave it on and hiding silently
/// stops applying on the one screen hiding exists to protect, with nothing but a
/// grey footer at the bottom of a long list to say so. Hidden pieces are always
/// visible (dimmed) on the Manage screen instead, which is where they can be
/// changed anyway — one place, no mode.
final visiblePiecesProvider = Provider<AsyncValue<List<Piece>>>((ref) {
  final lib = ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty;
  final collectionId = ref.watch(activeCollectionProvider);
  return ref.watch(piecesProvider).whenData(
      (pieces) => applyLibrary(lib, pieces, collectionId: collectionId));
});

/// The chip row's collections, in display order. Empty while loading.
final collectionsProvider = Provider<List<Collection>>(
    (ref) => ref.watch(libraryProvider).valueOrNull?.collections ?? const []);

/// The count behind "10 hidden pieces", scoped to the active collection so the
/// footer never promises pieces that showing hidden wouldn't reveal. 0 hides the
/// footer entirely.
final hiddenPieceCountProvider = Provider<int>((ref) {
  final lib = ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty;
  final pieces = ref.watch(piecesProvider).valueOrNull ?? const <Piece>[];
  return hiddenCount(lib, pieces,
      collectionId: ref.watch(activeCollectionProvider));
});

/// Which collections a piece belongs to — the tag dialog's initial checkboxes.
/// Derived, never stored: a persisted reverse index would be a second copy of
/// the membership, free to disagree with the first.
final pieceCollectionsProvider =
    Provider.family<Set<String>, String>((ref, pieceId) => collectionIdsOf(
        ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty, pieceId));

final libraryActionsProvider = Provider<LibraryActions>(LibraryActions.new);

/// The one library operation that spans more than one store.
///
/// It does not live on [PieceRepository] because two of the stores involved
/// ([StaffZoomStore], [PieceLibraryStore]) deliberately bypass it, and it does
/// not live on [PieceLibraryNotifier] because the library has no business
/// deleting files. It is the composition, and nothing else.
class LibraryActions {
  LibraryActions(this._ref);

  final Ref _ref;

  /// Everything a user-added piece owns comes out together: its MusicXML, its
  /// index row / prefs keys, its section-override sidecar, any editable copy,
  /// its staff-zoom preference, and its membership in every collection — plus
  /// the selection, if it happened to be selected.
  ///
  /// Clearing the selection matters even though deletion happens on a screen the
  /// detail view isn't under: a stale [selectedPieceProvider] feeds
  /// [parsedPieceProvider], which would try to load a file that no longer
  /// exists and surface as an error the next time the user navigated back.
  Future<void> deletePiece(String pieceId) async {
    final repo = _ref.read(pieceRepositoryProvider);
    if (repo.isBundled(pieceId)) {
      throw ArgumentError.value(pieceId, 'pieceId',
          'Bundled fixtures are hidden, not deleted');
    }
    await repo.deletePiece(pieceId);
    await _ref.read(staffZoomStoreProvider).clear(pieceId);
    await _ref.read(libraryProvider.notifier).forgetPiece(pieceId);
    if (_ref.read(selectedPieceProvider)?.id == pieceId) {
      _ref.read(selectedPieceProvider.notifier).state = null;
      _ref.read(measureSelectionProvider.notifier).state = null;
    }
    _ref.invalidate(piecesProvider);
  }
}

// ── Parsed piece (loads + parses + converts on piece selection) ───────────────

final parsedPieceProvider = FutureProvider<ParsedPiece?>((ref) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;

  final repo = ref.watch(pieceRepositoryProvider);
  final parser = ref.watch(musicXmlParserProvider);
  final jianpu = ref.watch(jianpuConverterProvider);
  final fingering = ref.watch(fingeringMapperProvider);

  await jianpu.init();
  await fingering.init();

  final xml = await repo.loadMusicXml(piece);
  final parsed = parser.parse(xml);
  final withJianpu = jianpu.convert(parsed);
  final withFingering = fingering.map(withJianpu);
  return withFingering;
});

// ── Staff view bottom inset (height in logical px obscured by the bottom tray) ─
// Updated by _CompactPieceLayoutState; read by StaffView to inform scroll logic.
final staffViewBottomInsetProvider = StateProvider<double>((_) => 0);

// ── Staff spacing (MinSkyBottomDistBetweenSystems / MinimumDistanceBetweenSystems * 10) ──
// Exposed as constants so tests can assert min < max (a zero-range slider
// cannot claim drag gestures and they leak to parent handlers like Drawer close).
const staffSpacingMin = 0.1;
const staffSpacingMax = 1.5;
const staffSpacingDefault = 0.5;
final staffSpacingProvider = StateProvider<double>((_) => staffSpacingDefault);

// ── Measures per row (updated at runtime from screen width) ──────────────────

final measuresPerRowProvider = StateProvider<int>((_) => 4);

// ── Staff zoom: measures per line ─────────────────────────────────────────────
// The staff/annotation/tab views engrave to exactly the viewport width, so
// "fewer measures per line" and "bigger notes" are the same knob (Verovio's
// `scale`). See `staff_zoom.dart` for the maths and `measuresPerLineMin/Max`.
//
// Note this is NOT [measuresPerRowProvider], which is derived purely from screen
// width and drives the jianpu/fingering row layout.

final staffZoomStoreProvider = Provider<StaffZoomStore>((_) => StaffZoomStore());

/// The user's measures-per-line override ([value]; null = auto, meaning fit a
/// short piece to ~75% of the viewport), plus whether the per-piece setting has
/// been read back from storage yet.
///
/// [restored] exists so the staff view can hold off its first engrave: the read
/// is async, so acting on the initial `null` would engrave the auto default and
/// then immediately re-engrave at the saved value — a wasted ~600ms engrave and a
/// visible reflow on every piece that has a saved zoom.
typedef MeasuresPerLineState = ({int? value, bool restored});

/// Persisted per piece, so the notifier is rebuilt — and re-read — whenever the
/// selected piece changes.
final measuresPerLineProvider =
    StateNotifierProvider<MeasuresPerLineNotifier, MeasuresPerLineState>((ref) {
  return MeasuresPerLineNotifier(
    ref.watch(staffZoomStoreProvider),
    ref.watch(selectedPieceProvider)?.id,
  );
});

class MeasuresPerLineNotifier extends StateNotifier<MeasuresPerLineState> {
  MeasuresPerLineNotifier(this._store, this._pieceId)
      // With no piece there is nothing to read, so we're trivially restored.
      : super((value: null, restored: _pieceId == null)) {
    if (_pieceId != null) _restore();
  }

  final StaffZoomStore _store;
  final String? _pieceId;
  bool _touched = false;

  Future<void> _restore() async {
    final saved = await _store.load(_pieceId!);
    if (!mounted) return;
    // A user move that landed before the async read returned wins.
    state = (value: _touched ? state.value : saved, restored: true);
  }

  /// Live slider position — state only, no write (a drag would otherwise write
  /// on every frame).
  void preview(int? v) {
    _touched = true;
    state = (value: v, restored: state.restored);
  }

  /// Settles on [v] (null = back to auto) and persists it for this piece.
  void commit(int? v) {
    _touched = true;
    state = (value: v, restored: state.restored);
    final id = _pieceId;
    if (id != null) _store.save(id, v);
  }
}

/// Measures per line the renderer actually achieved on the last engrave — the
/// slider position and readout while on auto, and honest feedback that Verovio's
/// musical break points may differ from the target by one. Set by the staff view.
final effectiveMeasuresPerLineProvider = StateProvider<int?>((_) => null);

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
  return PieceLayout.compute(parsed.measures, piece.sections,
      measuresPerRow: measuresPerRow);
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

// ── Display mode ──────────────────────────────────────────────────────────────

final displayModeProvider = StateProvider<DisplayMode>((_) => DisplayMode.staff);

// ── Staff renderer (native Verovio+jovial_svg, OSMD WebView as fallback) ───────
// `verovio` engraves on-device (FFI) and draws via jovial_svg + native overlays
// — note-level selection, full highlight control, and Marionette-visible
// notation. It is the renderer everywhere it works.
//
// `osmd` is the legacy WebView path, retained ONLY as a code-level fallback for
// environments where Verovio can't run (e.g. macOS — verovio_flutter has no
// macOS build, but webview_flutter does). It is deliberately NOT surfaced in
// the UI: there's no user toggle. A future task selects `osmd` per-platform
// (e.g. on macOS) when that target is revisited; until then the default is
// `verovio`. See docs/verovio_custompaint_migration_plan.md.
enum StaffRenderer { osmd, verovio }

final staffRendererProvider =
    StateProvider<StaffRenderer>((_) => StaffRenderer.verovio);

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
// Session-only, matching the other display-preference providers.
final showChordsProvider = StateProvider<bool>((_) => true);

/// Whether `<harmony>` should be stripped before the score is engraved.
///
/// Two independent reasons to strip. The obvious one is the user turning chords
/// off. The other is that the **native renderer draws chords itself**, as
/// labelled colored bars in a lane above the staff (`ChordRunRegion` /
/// `_ChordLanePainter`), so leaving the harmony in would have Verovio engrave a
/// second, unspanned copy of every symbol as `<harm>` text. The OSMD fallback has
/// no lane, so there it stays in and Verovio's own symbols are the display.
///
/// The `<harmony>` elements are only stripped from the ENGRAVED xml — the parsed
/// model still carries `NoteEvent.chordSymbol`, which is what the lane and the
/// footer diagrams are built from.
bool _stripHarmonyFor(Ref ref) =>
    !ref.watch(showChordsProvider) ||
    ref.watch(staffRendererProvider) == StaffRenderer.verovio;

// ── Processed staff XML providers ─────────────────────────────────────────────

final staffXmlProvider = FutureProvider<String?>((ref) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final layout = await ref.watch(pieceLayoutProvider.future);
  if (layout == null) return null;
  final repo = ref.watch(pieceRepositoryProvider);
  String xml = await repo.loadMusicXml(piece);
  xml = layout.stripLayoutHints(xml);
  xml = FingeringXmlInjector.stripFingerings(xml);
  if (_stripHarmonyFor(ref)) xml = ChordXmlInjector.stripHarmony(xml);
  return xml;
});

final staffFingeringXmlProvider = FutureProvider<String?>((ref) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final layout = await ref.watch(pieceLayoutProvider.future);
  if (layout == null) return null;
  final style = ref.watch(stringLabelStyleProvider);
  final repo = ref.watch(pieceRepositoryProvider);
  String xml = await repo.loadMusicXml(piece);
  xml = layout.stripLayoutHints(xml);
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (parsed != null) xml = FingeringXmlInjector.inject(xml, parsed, style);
  if (_stripHarmonyFor(ref)) xml = ChordXmlInjector.stripHarmony(xml);
  return xml;
});

/// Tab view: violin fingering (default) vs true mandolin fret numbers.
/// Session-only, matching the other display-preference providers.
final tabNumberModeProvider =
    StateProvider<TabNumberMode>((_) => TabNumberMode.violinFingering);

/// Tab fret mode: prefer open strings (frets ≤6, beginner-friendly) vs put the
/// fret on the fingering's string. Session-only; only affects fret numbers.
final tabFretStyleProvider =
    StateProvider<TabFretStyle>((_) => TabFretStyle.openStrings);

/// The 2-staff MusicXML (melody + 4-line tab) plus the ordered fingering labels
/// for the tab view. Reuses the same strip pipeline as [staffXmlProvider] so the
/// melody staff shows no fingerings (they live only on the tab staff).
final tabScoreProvider = FutureProvider<TabScore?>((ref) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final layout = await ref.watch(pieceLayoutProvider.future);
  if (layout == null) return null;
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (parsed == null) return null;
  final numberMode = ref.watch(tabNumberModeProvider);
  final fretStyle = ref.watch(tabFretStyleProvider);
  final repo = ref.watch(pieceRepositoryProvider);
  String xml = await repo.loadMusicXml(piece);
  xml = layout.stripLayoutHints(xml);
  xml = FingeringXmlInjector.stripFingerings(xml);
  // Chord symbols ride above the melody staff here just like in the staff views
  // (the `<harmony>` elements stay on staff 1; the tab staff is staff 2).
  if (_stripHarmonyFor(ref)) xml = ChordXmlInjector.stripHarmony(xml);
  return TabScoreGenerator.generate(
    xml,
    parsed,
    fretMode: numberMode == TabNumberMode.mandolinFret,
    preferOpenFrets: fretStyle == TabFretStyle.openStrings,
  );
});

final paletteMusicXmlProvider = FutureProvider<String?>((ref) async {
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (parsed == null) return null;
  final xml = PaletteXmlGenerator.generate(parsed);
  return xml.isEmpty ? null : xml;
});

// ── Measure selection ─────────────────────────────────────────────────────────

class MeasureSelection {
  final int startMeasure;
  final int endMeasure;

  const MeasureSelection(this.startMeasure, this.endMeasure);

  bool contains(int measure) =>
      measure >= startMeasure && measure <= endMeasure;

  bool get isSingle => startMeasure == endMeasure;

  /// New selection after tapping [tapped], given the [current] selection.
  ///
  /// "Tap anchor, tap to extend" semantics, shared by every notation view
  /// (staff, jianpu, fingering):
  ///   • nothing selected        → single-measure selection
  ///   • single anchor selected  → extend to the inclusive range anchor..tapped
  ///   • tap inside an existing range → clear (deselect)
  ///   • tap outside a range      → start a fresh single-measure anchor
  static MeasureSelection? afterTap(MeasureSelection? current, int tapped) {
    if (current == null) return MeasureSelection(tapped, tapped);
    if (current.contains(tapped)) return null;
    if (current.isSingle) {
      final s = current.startMeasure;
      return MeasureSelection(s < tapped ? s : tapped, s > tapped ? s : tapped);
    }
    return MeasureSelection(tapped, tapped);
  }

  @override
  bool operator ==(Object other) =>
      other is MeasureSelection &&
      other.startMeasure == startMeasure &&
      other.endMeasure == endMeasure;

  @override
  int get hashCode => Object.hash(startMeasure, endMeasure);
}

final measureSelectionProvider =
    StateProvider<MeasureSelection?>((_) => null);

// ── Playback ──────────────────────────────────────────────────────────────────

final midiGeneratorProvider = Provider<MidiGenerator>((_) => MidiGenerator());

final playbackServiceProvider = Provider<PlaybackService>((ref) {
  final service = PlaybackService(ref.watch(midiGeneratorProvider));
  ref.onDispose(service.dispose);
  return service;
});

final playbackStateProvider = StreamProvider<PlaybackState>((ref) {
  return ref.watch(playbackServiceProvider).state;
});
