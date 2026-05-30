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

// ── Measures per row (updated at runtime from screen width) ──────────────────

final measuresPerRowProvider = StateProvider<int>((_) => 4);

// ── Piece layout (single source of truth for all notation views) ──────────────

final pieceLayoutProvider = FutureProvider<PieceLayout?>((ref) async {
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (parsed == null) return null;
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final measuresPerRow = ref.watch(measuresPerRowProvider);
  return PieceLayout.compute(parsed.measures, piece.sections,
      measuresPerRow: measuresPerRow);
});

// ── Display mode ──────────────────────────────────────────────────────────────

final displayModeProvider = StateProvider<DisplayMode>((_) => DisplayMode.staff);

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
  xml = layout.injectSystemBreaks(xml);
  return FingeringXmlInjector.stripFingerings(xml);
});

final staffFingeringXmlProvider = FutureProvider<String?>((ref) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final layout = await ref.watch(pieceLayoutProvider.future);
  if (layout == null) return null;
  final style = ref.watch(stringLabelStyleProvider);
  final repo = ref.watch(pieceRepositoryProvider);
  String xml = await repo.loadMusicXml(piece);
  xml = layout.injectSystemBreaks(xml);
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (parsed != null) xml = FingeringXmlInjector.inject(xml, parsed, style);
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
