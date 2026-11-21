import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:violin_practice_companion/models/instrument_profile.dart';
import 'package:violin_practice_companion/models/note_annotation.dart';
import 'package:violin_practice_companion/models/note_number_mode.dart';
import 'package:violin_practice_companion/services/fingering_mapper.dart';
import 'package:violin_practice_companion/services/instrument_layer_store.dart';
import 'package:violin_practice_companion/services/piece_repository.dart';
import 'package:violin_practice_companion/services/piece_storage.dart';
import 'package:violin_practice_companion/services/string_choice_migration.dart';

import 'support/bundled_scores.dart';

/// [xml] with a <fingering> of 4 on every note that has the open-or-4th
/// choice, and 2 on the first note that doesn't: what the measure editor (or
/// a scan) used to leave in a score.
String _pinned(String xml) {
  final parsed = MusicXmlParser().parse(xml);
  var out = xml;
  var other = false;
  for (final m in parsed.measures) {
    var changed = false;
    final notes = [
      for (final n in m.notes)
        if (!n.isRest && FingeringMapper.hasFourthFingerChoice(n.midiNumber))
          () {
            changed = true;
            return n.copyWith(scoreFinger: 4);
          }()
        else if (!n.isRest && !other)
          () {
            other = changed = true;
            return n.copyWith(scoreFinger: 2);
          }()
        else
          n,
    ];
    if (changed) {
      out = MeasureXmlEditor.replaceMeasureNotes(
          out, m.number, notes, parsed.divisions);
    }
  }
  return out;
}

List<String> _fingered(ParsedPiece p) => [
      for (final m in p.measures)
        for (final n in m.notes) '${n.fingerString}${n.fingerNumber}',
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FingeringMapper mapper;
  setUpAll(() async {
    mapper = FingeringMapper();
    await mapper.init();
  });

  test('moving choices to the layer fingers every bundled score the same',
      () {
    for (final f in bundledScoreFiles()) {
      final pinned = _pinned(f.readAsStringSync());
      final moved = StringChoiceMigration.extract(pinned);
      expect(moved.choices, isNotEmpty, reason: f.path);
      expect(moved.choices.values.toSet(), {4});

      final before = mapper.map(MusicXmlParser().parse(pinned));
      final after = mapper.map(MusicXmlParser().parse(moved.xml),
          choices: moved.choices);
      expect(_fingered(after), _fingered(before), reason: f.path);

      // Out of the score, except the fingering that wasn't a choice.
      final left = MusicXmlParser()
          .parse(moved.xml)
          .measures
          .expand((m) => m.notes)
          .map((n) => n.scoreFinger)
          .whereType<int>()
          .toList();
      expect(left, [2], reason: f.path);
    }
  });

  test('a score with nothing to move comes back as it was', () {
    final xml = File(scorePath('lightly_row')).readAsStringSync();
    final moved = StringChoiceMigration.extract(xml);
    expect(identical(moved.xml, xml), isTrue);
    expect(moved.choices, isEmpty);
  });

  test('the editor holds a bar\'s choices on its notes, and gives them back',
      () {
    final m = MusicXmlParser()
        .parse(_pinned(File(scorePath('lightly_row')).readAsStringSync()))
        .measures
        .firstWhere((m) => StringChoiceMigration.ofNotes(m.notes).isNotEmpty);
    final choices = StringChoiceMigration.ofNotes(m.notes);
    final bare = StringChoiceMigration.withoutChoices(m.notes);
    expect(StringChoiceMigration.ofNotes(bare), isEmpty);
    final back = StringChoiceMigration.withChoices(bare, choices);
    expect(StringChoiceMigration.ofNotes(back), choices);
  });

  group('the layer store', () {
    late Directory root;
    late InstrumentLayerStore store;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('layers');
      store = InstrumentLayerStore(root: root);
    });
    tearDown(() => root.delete(recursive: true));

    test('keeps choices per piece and instrument', () async {
      await store.setStringChoices('tune_1', 'violin', {'2:0': 4, '7:3': 0});
      await store.setStringChoices('tune_1', 'viola', {'1:1': 4});
      expect(await store.stringChoices('tune_1', 'violin'),
          {'2:0': 4, '7:3': 0});
      expect(await store.instrumentsOf('tune_1'),
          unorderedEquals(['violin', 'viola']));
      expect(await store.stringChoices('tune_2', 'violin'), isEmpty);
      await store.setStringChoices('tune_1', 'viola', {});
      expect(await store.instrumentsOf('tune_1'), ['violin']);
      await store.delete('tune_1');
      expect(await store.instrumentsOf('tune_1'), isEmpty);
    });

    test('a bar\'s choices replace only that bar', () {
      expect(
          InstrumentLayerStore.withMeasure(
              {'2:0': 4, '2:5': 0, '3:1': 4}, 2, {1: 0}),
          {'3:1': 4, '2:1': 0});
    });

    test('deleting a bar drops its choices and moves the later ones back',
        () async {
      await store.setStringChoices(
          'tune_1', 'violin', {'1:0': 4, '2:0': 4, '3:2': 0, '10:1': 4});
      await store.afterMeasureDelete('tune_1', 2);
      expect(await store.stringChoices('tune_1', 'violin'),
          {'1:0': 4, '2:2': 0, '9:1': 4});
    });

    test('opening an older score moves its choices out, keeping the original',
        () async {
      final storage = PieceStorage(root: root);
      final repo = PieceRepository(storage: storage, layers: store);
      final pinned =
          _pinned(File(scorePath('lightly_row')).readAsStringSync());
      // Stored as an older build did: straight to disk, choices inside.
      await storage.saveScannedPieceAs('old_1', 'Old', pinned);
      final piece = (await storage.loadScannedPieces()).single;

      final opened = await repo.loadMusicXml(piece);
      expect(StringChoiceMigration.extract(opened).choices, isEmpty);
      final layer = await store.stringChoices('old_1', 'violin');
      expect(layer, StringChoiceMigration.extract(PieceRepository.repair(pinned)).choices);
      expect(await storage.readOriginal('old_1'), pinned);
      // Opening again changes nothing.
      expect(await repo.loadMusicXml(piece), opened);
    });

    test('the launch pass converts every stored score and seeds the mandolin',
        () async {
      final storage = PieceStorage(root: root);
      final repo = PieceRepository(storage: storage, layers: store);
      for (final id in ['one_1', 'two_2']) {
        await storage.saveScannedPieceAs(id, id,
            _pinned(File(scorePath('lightly_row')).readAsStringSync()));
      }
      final pieces = await storage.loadScannedPieces();
      expect(await repo.normalizeAll(pieces), 2);
      for (final p in pieces) {
        final xml = await storage.readScannedMusicXml(p.musicXmlFilePath!);
        expect(StringChoiceMigration.extract(xml).choices, isEmpty);
        final violin = await store.stringChoices(p.id, 'violin');
        expect(violin, isNotEmpty);
        expect(await store.stringChoices(p.id, 'mandolin'), violin);
      }
      // A mandolin layer of its own is never overwritten by the violin's.
      await store.setStringChoices('one_1', 'mandolin', {'1:0': 0});
      await repo.normalizeAll(pieces);
      expect(await store.stringChoices('one_1', 'mandolin'), {'1:0': 0});
    });
  });

  group('viola fingering', () {
    NoteEvent note(int midi) => NoteEvent(
        pitch: 'X4', midiNumber: midi, octave: 4,
        noteValue: NoteValue.quarter, dotted: false, isRest: false);
    ParsedPiece line(List<int> midis) => ParsedPiece(
        keySignature: 'C', keyFifths: 0, keyMode: KeyMode.major,
        measures: [Measure(number: 1, notes: [for (final m in midis) note(m)])]);

    test('every violin note is the same finger a fifth lower, a string lower',
        () {
      const rename = {'G': 'C', 'D': 'G', 'A': 'D', 'E': 'A'};
      final midis = [for (var m = 55; m <= 83; m++) m];
      final violin = mapper
          .map(line(midis), preference: ViolinStringPreference.openStrings)
          .measures.single.notes;
      final viola = mapper
          .map(line([for (final m in midis) m - 7]),
              preference: ViolinStringPreference.openStrings,
              profile: InstrumentProfile.viola)
          .measures.single.notes;
      for (var i = 0; i < midis.length; i++) {
        expect(viola[i].fingerNumber, violin[i].fingerNumber,
            reason: 'midi ${midis[i] - 7}');
        expect(viola[i].fingerString, rename[violin[i].fingerString],
            reason: 'midi ${midis[i] - 7}');
      }
      expect(viola.first.fingerString, 'C');
    });

    test('the choice notes are the open strings above C', () {
      const viola = InstrumentProfile.viola;
      expect([for (var m = 48; m <= 76; m++) if (viola.hasFourthFingerChoice(m)) m],
          [55, 62, 69]);
      final four = mapper
          .map(line([55]), choices: {'1:0': 4}, profile: viola)
          .measures.single.notes.single;
      expect((four.fingerString, four.fingerNumber), ('C', '4'));
    });
  });
}
