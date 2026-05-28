import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/piece.dart';
import '../models/piece_layout.dart';
import 'fingering_mapper.dart';
import 'jianpu_converter.dart';
import 'musicxml_parser.dart';
import 'fingering_xml_injector.dart';
import 'piece_repository.dart';

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

// ── Piece layout (single source of truth for all notation views) ──────────────

final pieceLayoutProvider = FutureProvider<PieceLayout?>((ref) async {
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (parsed == null) return null;
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  return PieceLayout.compute(parsed.measures, piece.sections);
});

// ── Display mode ──────────────────────────────────────────────────────────────

final displayModeProvider = StateProvider<DisplayMode>((_) => DisplayMode.jianpu);

// ── Open-string preference ────────────────────────────────────────────────────

final openStringPreferenceProvider = StateNotifierProvider<OpenStringPreferenceNotifier, String>(
  (_) => OpenStringPreferenceNotifier(),
);

class OpenStringPreferenceNotifier extends StateNotifier<String> {
  OpenStringPreferenceNotifier() : super('fingered');

  void toggle() {
    state = state == 'fingered' ? 'open' : 'fingered';
  }

  void set(String value) => state = value;
}

// ── Processed staff XML providers ─────────────────────────────────────────────

final staffXmlProvider = FutureProvider<String?>((ref) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final layout = await ref.watch(pieceLayoutProvider.future);
  if (layout == null) return null;
  final repo = ref.watch(pieceRepositoryProvider);
  String xml = await repo.loadMusicXml(piece);
  return layout.injectSystemBreaks(xml);
});

final staffFingeringXmlProvider = FutureProvider<String?>((ref) async {
  final piece = ref.watch(selectedPieceProvider);
  if (piece == null) return null;
  final layout = await ref.watch(pieceLayoutProvider.future);
  if (layout == null) return null;
  final repo = ref.watch(pieceRepositoryProvider);
  String xml = await repo.loadMusicXml(piece);
  xml = layout.injectSystemBreaks(xml);
  final parsed = await ref.watch(parsedPieceProvider.future);
  if (parsed != null) xml = FingeringXmlInjector.inject(xml, parsed);
  return xml;
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
