import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/piece.dart';
import '../models/piece_layout.dart';
import '../models/section_run.dart';
import '../models/string_label_style.dart';
import '../models/tab_number_mode.dart';
import 'fingering_mapper.dart';
import 'tab_score_generator.dart';
import 'jianpu_converter.dart';
import 'midi_generator.dart';
import 'musicxml_parser.dart';
import 'fingering_xml_injector.dart';
import 'palette_xml_generator.dart';
import 'piece_repository.dart';
import 'playback_service.dart';
import 'playback_service_base.dart';

// ── Singletons ────────────────────────────────────────────────────────────────

final pieceRepositoryProvider = Provider<PieceRepository>((_) => PieceRepository());

final musicXmlParserProvider = Provider<MusicXmlParser>((_) => MusicXmlParser());

final jianpuConverterProvider = Provider<JianpuConverter>((_) => JianpuConverter());

final fingeringMapperProvider = Provider<FingeringMapper>((_) => FingeringMapper());

// ── Piece list ────────────────────────────────────────────────────────────────

final piecesProvider = FutureProvider<List<Piece>>((ref) async {
  return ref.watch(pieceRepositoryProvider).loadAll();
});

// ── Selected piece ────────────────────────────────────────────────────────────

final selectedPieceProvider = StateProvider<Piece?>((ref) => null);

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
  return xml;
});

/// Tab view: violin fingering (default) vs true mandolin fret numbers.
/// Session-only, matching the other display-preference providers.
final tabNumberModeProvider =
    StateProvider<TabNumberMode>((_) => TabNumberMode.violinFingering);

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
  final repo = ref.watch(pieceRepositoryProvider);
  String xml = await repo.loadMusicXml(piece);
  xml = layout.stripLayoutHints(xml);
  xml = FingeringXmlInjector.stripFingerings(xml);
  return TabScoreGenerator.generate(xml, parsed);
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
