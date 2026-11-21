import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:violin_practice_companion/services/piece_repository.dart';
import 'package:xml/xml.dart';

import 'support/restricted_fixtures.dart';

/// Guards over every score in reach, so the next scanner quirk or editor
/// regression shows up here rather than on a staff:
///
/// * after [PieceRepository.repair], no file says one thing twice and means
///   two ([MusicXmlConsistency.check]);
/// * a bar saved by the measure editor keeps everything it had but stems and
///   beams (which are recomputed), so a Save can't silently drop a slur, a
///   staccato or a grace note again.
///
/// The bundled pieces and test fixtures always run. The restricted fixtures
/// and the dev library ($VPC_DEV_LIBRARY, else ../violin_dev_library) join the
/// consistency check when they are there; the round trip, at ~0.5s a piece,
/// keeps to the always-present files.
void main() {
  List<File> scores(Directory dir, {bool recursive = true}) => dir.existsSync()
      ? (dir
            .listSync(recursive: recursive)
            .whereType<File>()
            .where((f) => f.path.endsWith('.musicxml') || f.path.endsWith('.xml'))
            .where((f) => f.readAsStringSync().contains('<score-partwise'))
            .toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      : const [];

  final always = [
    ...scores(Directory('assets/library')),
    ...scores(Directory('test/fixtures')),
  ];
  final restricted = restrictedDir();
  final devLibrary = Directory(
      Platform.environment['VPC_DEV_LIBRARY'] ?? '../violin_dev_library');
  final optional = [
    if (restricted != null) ...scores(Directory('${restricted.path}/fixtures')),
    ...scores(Directory('${devLibrary.path}/scanned_pieces'), recursive: false),
    ...scores(Directory('${devLibrary.path}/editable_fixtures'),
        recursive: false),
  ];

  test('every score is consistent once repaired', () {
    expect(always, isNotEmpty);
    final problems = <String>[
      for (final f in [...always, ...optional])
        for (final i in MusicXmlConsistency.check(
            PieceRepository.repair(f.readAsStringSync())))
          '${f.path}: $i',
    ];
    expect(problems, isEmpty);
  });

  test('a bar saved by the measure editor keeps all it had', () {
    final losses = <String>[];
    for (final f in always) {
      final base = PieceRepository.repair(f.readAsStringSync());
      final piece = MusicXmlParser().parse(base);
      for (final m in piece.measures) {
        // As Save does: the rebuilt bar, then the repository's repairs.
        final saved = PieceRepository.repair(MeasureXmlEditor.replaceMeasureNotes(
            base, m.number, m.notes, piece.divisions));
        final before = _bar(base, m.number), after = _bar(saved, m.number);
        if (before.join('|') != after.join('|')) {
          losses.add('${f.path} bar ${m.number}:\n  was ${before.join('\n      ')}'
              '\n  now ${after.join('\n      ')}');
        }
      }
    }
    expect(losses, isEmpty);
  });
}

/// What Save may change: drawing hints recomputed afterwards (stems, beams),
/// the voice and staff a single-voice bar always has, and an empty
/// `<notations/>`.
const _recomputed = {'stem', 'beam', 'voice', 'staff'};

/// Bar [number]'s notes as comparable lines, one per note: every element in
/// it (with its `type` and its text, when it has no children), sorted.
List<String> _bar(String xml, int number) {
  final m = XmlDocument.parse(xml)
      .findAllElements('measure')
      .firstWhere((m) => m.getAttribute('number') == '$number');
  String note(XmlElement n) {
    final out = <String>[];
    void walk(XmlElement e, String path) {
      for (final c in e.childElements) {
        if (_recomputed.contains(c.name.local)) continue;
        if (c.name.local == 'notations' && c.childElements.isEmpty) continue;
        final p = '$path/${c.name.local}';
        final t = c.getAttribute('type');
        final text = c.childElements.isEmpty ? c.innerText.trim() : '';
        out.add('$p${t == null ? '' : '[$t]'}${text.isEmpty ? '' : '=$text'}');
        walk(c, p);
      }
    }

    walk(n, '');
    return (out..sort()).join(' ');
  }

  return [for (final n in m.findElements('note')) note(n)];
}
