// The safety net for moving code into libraries (docs/libraries-migration.md).
//
// Every bundled score and every OMR reading kept as test data goes through
// the parser, the fingering and Jianpu passes, each MusicXML repair and
// injector, and the ABC exporter. A digest of each result is compared with
// test/fixtures/migration_snapshot.json. A seam, a move or an import rewrite
// must leave every digest identical; a real behaviour change refreshes them:
//
//   UPDATE_SNAPSHOT=1 flutter test test/migration_snapshot_test.dart
//
// To see WHAT changed, dump the full text before and after and diff the dirs:
//
//   SNAPSHOT_DUMP=/tmp/snap_before flutter test test/migration_snapshot_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/note_annotation.dart';
import 'package:violin_practice_companion/models/note_number_mode.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/abc_exporter.dart';
import 'package:violin_practice_companion/services/bar_rest_repair.dart';
import 'package:violin_practice_companion/services/chord_xml_injector.dart';
import 'package:violin_practice_companion/services/fingering_mapper.dart';
import 'package:violin_practice_companion/services/fingering_xml_injector.dart';
import 'package:violin_practice_companion/services/jianpu_converter.dart';
import 'package:violin_practice_companion/services/lyric_xml_injector.dart';
import 'package:violin_practice_companion/services/measure_xml_editor.dart';
import 'package:violin_practice_companion/services/meter_repair.dart';
import 'package:violin_practice_companion/services/musicxml_beamer.dart';
import 'package:violin_practice_companion/services/musicxml_consistency.dart';
import 'package:violin_practice_companion/services/musicxml_normalizer.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
import 'package:violin_practice_companion/services/palette_xml_generator.dart';
import 'package:violin_practice_companion/services/preamble_xml_generator.dart';
import 'package:violin_practice_companion/services/tuplet_repair.dart';

import 'support/bundled_scores.dart';

const _goldenPath = 'test/fixtures/migration_snapshot.json';

/// 64-bit FNV-1a over the UTF-8 bytes, as hex: stable, and no dependency.
String _digest(String s) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(s)) {
    h ^= b;
    h *= 0x100000001b3; // wraps at 64 bits on the VM
  }
  String hex32(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return hex32(h >>> 32) + hex32(h);
}

String _note(NoteEvent n) => [
      n.pitch, n.midiNumber, n.octave, n.noteValue.name, n.dotted, n.isRest,
      n.scoreFinger, n.displayAccidental,
      n.jianpuNumber, n.jianpuOctaveDots, n.jianpuAccidentalSharp,
      n.fingerString, n.fingerNumber,
      n.chordSymbol, n.isChord,
      (n.lyrics.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
          .map((e) => '${e.key}:${e.value}')
          .join(','),
      n.tieStart, n.tieStop, n.tuplet, n.bowing?.name,
      n.carriedNotations.join(','),
    ].join('|');

String _piece(ParsedPiece p) {
  final b = StringBuffer()
    ..writeln([
      p.keySignature, p.keyFifths, p.keyMode.name, p.divisions,
      p.beatsPerMeasure, p.beatType, p.markedBpm,
    ].join('|'));
  for (final m in p.measures) {
    b.writeln('M ${[
      m.number, m.repeatStart, m.repeatEnd, m.doubleBarEnd, m.daCapo,
      m.dalSegno, m.fine, m.toCoda, m.segno, m.coda, m.partLabel,
      m.partLabelNote, m.lineStartNote, m.systemStart, m.timeChange,
      m.keyChange, (m.endings.toList()..sort()).join(','),
    ].join('|')}');
    for (final n in m.hiddenLeadNotes) {
      b.writeln('  h ${_note(n)}');
    }
    for (final n in m.notes) {
      b.writeln('  ${_note(n)}');
    }
  }
  return b.toString();
}

/// Each stage's output for one score, as text.
Map<String, String> _stages(
    String xml, FingeringMapper mapper, JianpuConverter jianpu) {
  final out = <String, String>{};
  String guard(String Function() f) {
    try {
      return f();
    } catch (e) {
      return 'THREW ${e.runtimeType}: $e';
    }
  }

  final parsed = MusicXmlParser().parse(xml);
  out['parse'] = _piece(parsed);
  for (final pref in ViolinStringPreference.values) {
    out['fingering.${pref.name}'] =
        _piece(mapper.map(parsed, preference: pref));
  }
  final fingered = mapper.map(parsed);
  out['jianpu'] = _piece(jianpu.convert(fingered));

  out['title'] = '${MusicXmlParser.titleOf(xml)}';
  out['barRest.mark'] = guard(() => BarRestRepair.mark(xml));
  out['barRest.fit'] = guard(() => BarRestRepair.fit(xml));
  out['meter'] = guard(() => MeterRepair.repair(xml));
  out['tuplet'] = guard(() => TupletRepair.repair(xml));
  out['sounding'] = guard(() => MusicXmlNormalizer.toSoundingPitch(xml));
  out['accidentals'] = guard(() => MusicXmlNormalizer.drawAccidentals(xml));
  out['slursToTies'] = guard(() => MusicXmlNormalizer.slursToTies(xml));
  out['consistency.check'] =
      guard(() => MusicXmlConsistency.check(xml).join('\n'));
  out['consistency.repair'] = guard(() => MusicXmlConsistency.repair(xml));
  out['beam'] = guard(() => MusicXmlBeamer.rebeam(xml));
  out['stripHarmony'] = guard(() => ChordXmlInjector.stripHarmony(xml));
  out['verse1'] = guard(() => LyricXmlInjector.selectVerse(xml, 1));
  out['verseNone'] = guard(() => LyricXmlInjector.selectVerse(xml, null));
  out['fingering.strip'] = guard(() => FingeringXmlInjector.stripFingerings(xml));
  out['fingering.inject'] =
      guard(() => FingeringXmlInjector.injectPlaceholders(
          xml, fingeringLabelsOf(fingered)));
  out['preamble'] = guard(() => buildPreambleXml(xml));
  out['palette'] = guard(() => PaletteXmlGenerator.generate(fingered));
  out['abc'] = guard(() => AbcExporter.export(parsed, title: 'Snapshot'));
  // The editor writing each bar's own notes back: a round trip per bar.
  out['editor.roundTrip'] = guard(() {
    var doc = xml;
    for (final m in parsed.measures) {
      doc = MeasureXmlEditor.replaceMeasureNotes(
          doc, m.number, m.notes, parsed.divisions);
    }
    return doc;
  });
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every score through every stage matches the snapshot', () async {
    final mapper = FingeringMapper();
    await mapper.init();
    final jianpu = JianpuConverter();
    await jianpu.init();
    // Make sure the asset bundle is the real one, not an empty test double.
    expect(await rootBundle.loadString(
            'assets/engine/lookup_tables/jianpu_key_map.json'),
        isNotEmpty);

    final dumpDir = Platform.environment['SNAPSHOT_DUMP'];
    final actual = <String, String>{};
    for (final f in allScoreFixtures()) {
      final name = f.path;
      final stages = _stages(f.readAsStringSync(), mapper, jianpu);
      for (final e in stages.entries) {
        actual['$name ${e.key}'] = _digest(e.value);
        if (dumpDir != null) {
          final out = File('$dumpDir/${name.replaceAll('/', '_')}.${e.key}.txt');
          out.parent.createSync(recursive: true);
          out.writeAsStringSync(e.value);
        }
      }
    }

    final golden = File(_goldenPath);
    if (Platform.environment['UPDATE_SNAPSHOT'] == '1' || !golden.existsSync()) {
      final sorted = Map.fromEntries(
          actual.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
      golden.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(sorted)}\n');
      return;
    }
    final expected =
        (json.decode(golden.readAsStringSync()) as Map).cast<String, String>();
    final changed = [
      for (final k in {...expected.keys, ...actual.keys})
        if (expected[k] != actual[k]) k,
    ]..sort();
    expect(changed, isEmpty,
        reason: '${changed.length} stage outputs changed; dump with '
            'SNAPSHOT_DUMP before and after to see how');
  });
}
