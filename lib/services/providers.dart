import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chord_shape.dart';
import '../models/count_in.dart';
import '../models/fingering_density.dart';
import '../models/note_event.dart';
import '../models/note_number_mode.dart';
import '../models/parsed_piece.dart';
import '../models/piece.dart';
import '../models/piece_layout.dart';
import '../models/piece_library.dart';
// Four of the notifier's methods share a name with the free function they wrap
// (renameCollection, reorderInCollection, setHidden, forgetPiece), where the
// method would otherwise shadow it.
import '../models/piece_library.dart' as plib;
import '../models/section.dart';
import '../models/section_run.dart';
import '../models/string_label_style.dart';
import '../models/violin_string_palette.dart';
import 'fingering_mapper.dart';
import 'tab_score_generator.dart';
import 'jianpu_converter.dart';
import 'midi_generator.dart';
import 'musicxml_parser.dart';
import 'fingering_xml_injector.dart';
import 'chord_shape_library.dart';
import 'chord_xml_injector.dart';
import 'count_in_store.dart';
import 'palette_xml_generator.dart';
import 'piece_library_store.dart';
import 'piece_repository.dart';
import 'playback_service.dart';
import 'playback_service_base.dart';
import 'staff_zoom.dart';
import 'staff_zoom_store.dart';
import 'system_break_injector.dart';

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
  return ref
      .watch(piecesProvider)
      .whenData(
        (pieces) => applyLibrary(lib, pieces, collectionId: collectionId),
      );
});

/// The chip row's collections, in display order. Empty while loading.
final collectionsProvider = Provider<List<Collection>>(
  (ref) => ref.watch(libraryProvider).valueOrNull?.collections ?? const [],
);

/// The count behind "10 hidden pieces", scoped to the active collection so the
/// footer never promises pieces that showing hidden wouldn't reveal. 0 hides the
/// footer entirely.
final hiddenPieceCountProvider = Provider<int>((ref) {
  final lib = ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty;
  final pieces = ref.watch(piecesProvider).valueOrNull ?? const <Piece>[];
  return hiddenCount(
    lib,
    pieces,
    collectionId: ref.watch(activeCollectionProvider),
  );
});

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
      throw ArgumentError.value(
        pieceId,
        'pieceId',
        'Bundled fixtures are hidden, not deleted',
      );
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

// ── Note vocabulary panel (the palette staff above the score) ────────────────
// Folded by default: on a tablet it costs ~170pt of the score's height, and it's
// reference material you consult once rather than read while playing. Lifted out
// of the panel's own State because the toggle now lives in the app bar, beside
// the title, rather than on the panel itself.
final notePaletteExpandedProvider = StateProvider<bool>((_) => false);

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

final staffZoomStoreProvider = Provider<StaffZoomStore>(
  (_) => StaffZoomStore(),
);

/// Which way up the screen is, pushed from the piece detail screen's layout —
/// the same shape as [measuresPerRowProvider], and for the same reason: a
/// provider cannot read `MediaQuery` itself.
///
/// The zoom is stored per orientation because measures-per-line means a
/// different note size in each (see [StaffZoomStore]).
final staffOrientationProvider = StateProvider<StaffOrientation>(
  (_) => StaffOrientation.portrait,
);

/// The user's measures-per-line override ([value]; null = auto, meaning fit a
/// short piece to ~75% of the viewport), plus whether the per-piece setting has
/// been read back from storage yet.
///
/// [restored] exists so the staff view can hold off its first engrave: the read
/// is async, so acting on the initial `null` would engrave the auto default and
/// then immediately re-engrave at the saved value — a wasted ~600ms engrave and a
/// visible reflow on every piece that has a saved zoom.
///
/// [locked]: guarantee [value] exactly, via explicit MusicXML system breaks
/// (`insertSystemBreaksEvery`) and `breaks: 'encoded'`, rather than Verovio's
/// own approximate auto-breaking. Only meaningful alongside a non-null
/// [value] — [MeasuresPerLineNotifier.commit] forces it false whenever
/// [value] is cleared back to auto.
typedef MeasuresPerLineState = ({int? value, bool restored, bool locked});

/// Persisted per piece AND per orientation, so the notifier is rebuilt — and
/// re-read — whenever either changes.
///
/// Watching the orientation is what makes rotation cost a single engrave rather
/// than two: the rebuild drops `restored` back to false, and the staff view
/// already holds off its first engrave until the read returns (see
/// `staff_view_verovio.dart`), so the old orientation's value is never rendered
/// and thrown away.
final measuresPerLineProvider =
    StateNotifierProvider<MeasuresPerLineNotifier, MeasuresPerLineState>((ref) {
      return MeasuresPerLineNotifier(
        ref.watch(staffZoomStoreProvider),
        ref.watch(selectedPieceProvider)?.id,
        ref.watch(staffOrientationProvider),
      );
    });

class MeasuresPerLineNotifier extends StateNotifier<MeasuresPerLineState> {
  MeasuresPerLineNotifier(this._store, this._pieceId, this._orientation)
    // With no piece there is nothing to read, so we're trivially restored.
    : super((value: null, restored: _pieceId == null, locked: false)) {
    if (_pieceId != null) _restore();
  }

  final StaffZoomStore _store;
  final String? _pieceId;
  final StaffOrientation _orientation;
  bool _touched = false;

  Future<void> _restore() async {
    final id = _pieceId!;
    final value = await _store.load(id, _orientation);
    final locked = await _store.loadLocked(id, _orientation);
    if (!mounted) return;
    // A user move that landed before the async read returned wins.
    state = (
      value: _touched ? state.value : value,
      restored: true,
      locked: _touched ? state.locked : locked,
    );
  }

  /// Live slider position — state only, no write (a drag would otherwise write
  /// on every frame). Keeps whatever lock state was already set.
  void preview(int? v) {
    _touched = true;
    state = (value: v, restored: state.restored, locked: state.locked);
  }

  /// Settles on [v] (null = back to auto) and persists it for this piece.
  /// [locked], when given, sets whether [v] is enforced exactly (see
  /// [MeasuresPerLineState.locked]); omitted, the current lock state carries
  /// over. Clearing back to auto (`v == null`) always forces it off — locking
  /// only means something against an explicit value.
  void commit(int? v, {bool? locked}) {
    _touched = true;
    final newLocked = v == null ? false : (locked ?? state.locked);
    state = (value: v, restored: state.restored, locked: newLocked);
    final id = _pieceId;
    if (id != null) {
      _store.save(id, _orientation, v);
      _store.saveLocked(id, _orientation, newLocked);
    }
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

// ── Display mode ──────────────────────────────────────────────────────────────

final displayModeProvider = StateProvider<DisplayMode>(
  (_) => DisplayMode.staff,
);

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
// `verovio`. Background: `docs/explore.md` §10.
enum StaffRenderer { osmd, verovio }

final staffRendererProvider = StateProvider<StaffRenderer>(
  (_) => StaffRenderer.verovio,
);

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
/// The chord-symbol toggle does NOT reach the xml under the native renderer: the
/// row is reserved whether or not the bars are painted, so toggling is a repaint.
/// The renderer test comes first and short-circuits, so [showChordsProvider] is
/// not even watched there — which matters because these are `FutureProvider`s.
/// Invalidating one drops the staff to a spinner, unmounts the render widget and
/// throws away its engrave and calibration; the re-engrave then re-runs the
/// auto-fit against whatever the viewport is now, and the page REFLOWS. A chord
/// toggle must never be able to do that.
///
/// Under OSMD the engraved symbols ARE the display — there is no lane — so there
/// the toggle genuinely does belong in the xml.
bool _stripHarmonyFor(Ref ref) =>
    ref.watch(staffRendererProvider) == StaffRenderer.osmd &&
    !ref.watch(showChordsProvider);

// ── Fingering-annotation display preferences ──────────────────────────────────
// All three apply to the annotation view only, and none of them changes what is
// ENGRAVED — the labels are drawn in a Flutter lane (`_FingeringLanePainter`), so
// every one of these repaints without a re-engrave.
// Session-only, matching the other display-preference providers.

/// How the fingering channel shows the string (G green, D blue, A red, E
/// yellow): as a filled chip, as a rule under near-black numbers, or not at all.
///
/// While a colour is carrying the string the label drops the letter; with
/// [StringColourStyle.off] the [stringLabelStyleProvider] letter rules apply
/// instead. Three styles so they can be compared on real music — see
/// [StringColourStyle].
final stringColourStyleProvider = StateProvider<StringColourStyle>(
  (_) => StringColourStyle.chips,
);

/// How much fingering the annotation view shows.
final fingeringDensityProvider = StateProvider<FingeringDensity>(
  (_) => FingeringDensity.all,
);

/// Which rule decides what "crucial" fingering means at the lower densities.
/// Surfaced in the UI because the definition needs playing feedback to settle —
/// see [FingeringDensityPolicy].
final fingeringDensityPolicyProvider = StateProvider<FingeringDensityPolicy>(
  (_) => FingeringDensityPolicy.difficulty,
);

/// Whether the engraved `<fingering>` labels are the DISPLAY (OSMD) rather than
/// a space reserver (Verovio).
///
/// OSMD has no annotation lane, so there the engraved labels are all the user
/// sees and they must carry the real, styled text — which is why
/// [stringLabelStyleProvider] is watched inside that branch, and why a style
/// change legitimately re-engraves there.
///
/// The native renderer hides the engraved glyph and paints its own coloured
/// chips, so it injects style-independent placeholders instead
/// ([FingeringXmlInjector.injectPlaceholders]) purely so Verovio reserves the
/// row. Both paths inject; they differ only in what the text says.
///
/// The parsed model carries `NoteEvent.fingerString`/`fingerNumber` either way,
/// which is what [fingeringAnnotations] builds the chips from.
bool _injectFingeringFor(Ref ref) =>
    ref.watch(staffRendererProvider) == StaffRenderer.osmd;

/// Injects explicit system breaks — every N measures, with each [sections]
/// entry forcing its own fresh line — when the user has locked
/// measures-per-line to an exact value (see [MeasuresPerLineState.locked]),
/// so `VerovioEngraver` can be told `breaks: 'encoded'` instead of leaving
/// Verovio to choose its own — the guaranteed-exact counterpart to the
/// ordinary approximate zoom. A no-op on auto or on the approximate setting.
String _lockedBreaksFor(Ref ref, String xml, List<Section> sections) {
  final mpl = ref.watch(measuresPerLineProvider);
  if (!mpl.locked || mpl.value == null) return xml;
  return insertSystemBreaks(xml, measuresPerLine: mpl.value!, sections: sections);
}

// ── Processed staff XML providers ─────────────────────────────────────────────

final staffXmlProvider = FutureProvider<String?>((ref) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final layout = await ref.watch(pieceLayoutProvider.future);
  if (layout == null) return null;
  final repo = ref.watch(pieceRepositoryProvider);
  String xml = await repo.loadMusicXml(piece);
  xml = layout.stripLayoutHints(xml);
  xml = _lockedBreaksFor(ref, xml, piece.sections);
  xml = FingeringXmlInjector.stripFingerings(xml);
  if (_stripHarmonyFor(ref)) xml = ChordXmlInjector.stripHarmony(xml);
  return xml;
});

final staffFingeringXmlProvider = FutureProvider<String?>((ref) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final layout = await ref.watch(pieceLayoutProvider.future);
  if (layout == null) return null;
  final repo = ref.watch(pieceRepositoryProvider);
  String xml = await repo.loadMusicXml(piece);
  xml = layout.stripLayoutHints(xml);
  xml = _lockedBreaksFor(ref, xml, piece.sections);
  // Both renderers inject; see [_injectFingeringFor] for why the text differs.
  // The publisher's own fingerings are replaced either way, so a leftover
  // engraved label can never contradict the app's note for note.
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (_injectFingeringFor(ref)) {
    // Watched inside the branch on purpose: only here is the style an engraving
    // input, because only here is the engraved label the display.
    final style = ref.watch(stringLabelStyleProvider);
    if (parsed != null) xml = FingeringXmlInjector.inject(xml, parsed, style);
  } else if (parsed != null) {
    xml = FingeringXmlInjector.injectPlaceholders(xml, parsed);
  }
  // Keep `<harmony>` for the native renderer so the chord row is reserved too.
  if (_stripHarmonyFor(ref)) xml = ChordXmlInjector.stripHarmony(xml);
  return xml;
});

/// Violin fingering (default) vs true mandolin fret numbers, wherever a number
/// labels a note: the tab staff's string lines AND the annotation view's
/// fingering channel. ONE preference for both — see [NoteNumberMode].
///
/// Session-only, matching the other display-preference providers.
///
/// Note the asymmetry in what a change costs: the tab staff carries its numbers
/// in the engraved xml ([tabScoreProvider] watches this, so it re-engraves),
/// while the channel draws them in a Flutter overlay, so there it is a repaint.
final noteNumberModeProvider = StateProvider<NoteNumberMode>(
  (_) => NoteNumberMode.violinFingering,
);

/// In fret mode: prefer open strings (frets ≤6, beginner-friendly) vs put the
/// fret on the fingering's string. Shared by the same two views as
/// [noteNumberModeProvider]. Session-only; only affects fret numbers.
final fretStyleProvider = StateProvider<FretStyle>(
  (_) => FretStyle.openStrings,
);

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
  final numberMode = ref.watch(noteNumberModeProvider);
  final fretStyle = ref.watch(fretStyleProvider);
  final repo = ref.watch(pieceRepositoryProvider);
  String xml = await repo.loadMusicXml(piece);
  xml = layout.stripLayoutHints(xml);
  xml = FingeringXmlInjector.stripFingerings(xml);
  // Chord symbols ride above the melody staff here just like in the staff views
  // (the `<harmony>` elements stay on staff 1; the tab staff is staff 2).
  //
  // Kept in for the native renderer for the same reason as the annotated view:
  // the bars are drawn from `EngravedScore.harmRegister`, so with no engraved
  // `<harm>` there is no register and every bar is silently skipped. That is
  // exactly what this comment used to claim was happening while the view in fact
  // showed no chords at all.
  if (_stripHarmonyFor(ref)) xml = ChordXmlInjector.stripHarmony(xml);
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

final measureSelectionProvider = StateProvider<MeasureSelection?>((_) => null);

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
/// per launch and not on every piece change (contrast [measuresPerLineProvider],
/// which is rebuilt per piece and so needs a `restored` flag to hold off the
/// first engrave). Nothing here has to wait for storage: the count-in matters
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

/// The measure Play starts from: the practice selection's first bar, or — with
/// nothing selected — the score's own first measure.
///
/// Deliberately NOT a literal 1. A pickup is commonly numbered 0 (MuseGroup's
/// `<measure number="0" implicit="yes">`), and `play(fromMeasure: 1)` resolves
/// that to the first FULL bar, silently dropping the anacrusis — which is both
/// the wrong note to start on and the reason the count-in needs shortening.
final playbackStartMeasureProvider = Provider<int>((ref) {
  final selection = ref.watch(measureSelectionProvider);
  if (selection != null) return selection.startMeasure;
  final measures = ref.watch(parsedPieceProvider).valueOrNull?.measures;
  return (measures == null || measures.isEmpty) ? 1 : measures.first.number;
});

/// The count-off Play will actually give: the preference resolved against this
/// score's meter and shortened by a pickup at the start measure. Null = no count.
///
/// One provider so the Play button and the drawer's readout can't disagree — the
/// setting says "3 beats" precisely when Play will count three.
final resolvedCountInProvider = Provider<CountInPlan?>((ref) {
  final parsed = ref.watch(parsedPieceProvider).valueOrNull;
  final beatsPerMeasure = parsed?.beatsPerMeasure ?? 4;
  final beatType = parsed?.beatType ?? 4;
  final start = ref.watch(playbackStartMeasureProvider);
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
    ),
  );
});
