import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/piece.dart';
import '../models/piece_layout.dart';
import '../models/string_label_style.dart';
import 'fingering_mapper.dart';
import 'jianpu_converter.dart';
import 'midi_generator.dart';
import 'musicxml_parser.dart';
import 'fingering_xml_injector.dart';
import 'palette_xml_generator.dart';
import 'section_unfold_xml.dart';
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

// ── Section-organized ("ABAA") layout preference ──────────────────────────────
// When on (and the piece carries section metadata), every notation view is
// organized by its A/B section structure: each section starts a new system,
// repeats are unfolded so a repeated section shows up twice. Off by default;
// no effect on pieces without sections. Runtime-only, like the other prefs.
final sectionOrganizedProvider = StateProvider<bool>((_) => false);

// ── Piece layout (single source of truth for all notation views) ──────────────

final pieceLayoutProvider = FutureProvider<PieceLayout?>((ref) async {
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (parsed == null) return null;
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final measuresPerRow = ref.watch(measuresPerRowProvider);
  final sectioned =
      ref.watch(sectionOrganizedProvider) && piece.sections.isNotEmpty;
  return sectioned
      ? PieceLayout.computeSectioned(parsed.measures, piece.sections,
          measuresPerRow: measuresPerRow)
      : PieceLayout.compute(parsed.measures, piece.sections,
          measuresPerRow: measuresPerRow);
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
// Top-most visible section-run index in the jianpu/fingering views, pushed on
// scroll; the minimap reads it to show "where we are" (only meaningful for the
// scrollable custom views — staff falls back to playback/selection).
final scrollRunProvider = StateProvider<int?>((_) => null);

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
  final sectioned =
      ref.watch(sectionOrganizedProvider) && piece.sections.isNotEmpty;
  if (sectioned) {
    final parsed = await ref.watch(parsedPieceProvider.future);
    if (parsed != null) {
      xml = SectionUnfoldXml.apply(xml, parsed.measures, piece.sections);
    }
  }
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
  // Inject fingerings on the folded score first, then unfold — so each
  // repeated copy carries the same fingering labels.
  if (parsed != null) xml = FingeringXmlInjector.inject(xml, parsed, style);
  final sectioned =
      ref.watch(sectionOrganizedProvider) && piece.sections.isNotEmpty;
  if (sectioned && parsed != null) {
    xml = SectionUnfoldXml.apply(xml, parsed.measures, piece.sections);
  }
  return xml;
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
