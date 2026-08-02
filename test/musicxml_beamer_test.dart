import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/musicxml_beamer.dart';
import 'package:xml/xml.dart';

/// Wraps [measures] (raw `<measure>` elements) in the minimum score around them.
/// `divisions` is 8, so a 32nd-note unit is exactly 1 and the `<duration>`
/// values below read as the beat arithmetic the beamer does.
String _score(String measures, {int beats = 4, int beatType = 4}) => '''
<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>
  <part id="P1">$measures</part>
</score-partwise>'''
    .replaceFirst('<measure number="1">', '''<measure number="1">
      <attributes>
        <divisions>8</divisions>
        <key><fifths>0</fifths></key>
        <time><beats>$beats</beats><beat-type>$beatType</beat-type></time>
      </attributes>''');

const _units = {
  'whole': 32,
  'half': 16,
  'quarter': 8,
  'eighth': 4,
  '16th': 2,
  '32nd': 1,
};

String _note(String type,
        {bool dot = false, bool rest = false, bool chord = false, String extra = ''}) =>
    '<note>${chord ? '<chord/>' : ''}'
    '${rest ? '<rest/>' : '<pitch><step>B</step><octave>4</octave></pitch>'}'
    '<duration>${dot ? _units[type]! * 3 ~/ 2 : _units[type]}</duration>'
    '<type>$type</type>${dot ? '<dot/>' : ''}$extra</note>';

String _grace(String type) =>
    '<note><grace/><pitch><step>C</step><octave>5</octave></pitch>'
    '<type>$type</type></note>';

/// The beams on each note of the first measure, in document order: one entry
/// per note, `'-'` where the note carries none.
List<String> _beams(String xml) {
  final out = <String>[];
  final measure =
      XmlDocument.parse(xml).findAllElements('measure').first;
  for (final note in measure.findElements('note')) {
    final beams = note
        .findElements('beam')
        .map((b) => '${b.getAttribute('number')}:${b.innerText}')
        .join(',');
    out.add(beams.isEmpty ? '-' : beams);
  }
  return out;
}

List<String> _rebeamed(String xml) => _beams(MusicXmlBeamer.rebeam(xml));

void main() {
  group('a run inside one span is beamed', () {
    test('two eighths', () {
      final xml = _score('<measure number="1">'
          '${_note('eighth')}${_note('eighth')}${_note('half')}'
          '${_note('quarter')}</measure>');
      expect(_rebeamed(xml), ['1:begin', '1:end', '-', '-']);
    });

    test('four eighths beam as one group, not two pairs', () {
      // The half-bar span is the whole point: engravers run eighths across two
      // beats, and beaming per beat would give a bar of Gossec's Gavotte four
      // pairs where the printed page has two fours.
      final xml = _score('<measure number="1">'
          '${_note('eighth')}${_note('eighth')}${_note('eighth')}${_note('eighth')}'
          '${_note('half')}</measure>');
      expect(_rebeamed(xml),
          ['1:begin', '1:continue', '1:continue', '1:end', '-']);
    });

    test('eight eighths break at the half bar', () {
      final xml =
          _score('<measure number="1">${_note('eighth') * 8}</measure>');
      expect(_rebeamed(xml), [
        '1:begin', '1:continue', '1:continue', '1:end', //
        '1:begin', '1:continue', '1:continue', '1:end',
      ]);
    });

    test('a pair straddling the half bar is left alone', () {
      // Half, eighth, quarter•… — the two eighths sit either side of the bar's
      // midpoint, so there is no group to beam.
      final xml = _score('<measure number="1">'
          '${_note('quarter', dot: true)}${_note('eighth')}'
          '${_note('eighth')}${_note('quarter', dot: true)}</measure>');
      expect(_rebeamed(xml), ['-', '-', '-', '-']);
    });
  });

  group('a run is broken by', () {
    test('a rest', () {
      final xml = _score('<measure number="1">'
          '${_note('eighth')}${_note('eighth', rest: true)}'
          '${_note('eighth')}${_note('eighth')}${_note('half')}</measure>');
      expect(_rebeamed(xml), ['-', '-', '1:begin', '1:end', '-']);
    });

    test('a quarter', () {
      final xml = _score('<measure number="1">'
          '${_note('quarter')}${_note('eighth')}${_note('eighth')}'
          '${_note('half')}</measure>');
      expect(_rebeamed(xml), ['-', '1:begin', '1:end', '-']);
    });
  });

  group('every level a note reaches gets a beam', () {
    test('four sixteenths carry two', () {
      final xml = _score('<measure number="1">'
          '${_note('16th')}${_note('16th')}${_note('16th')}${_note('16th')}'
          '${_note('half')}${_note('quarter')}</measure>');
      expect(_rebeamed(xml), [
        '1:begin,2:begin',
        '1:continue,2:continue',
        '1:continue,2:continue',
        '1:end,2:end',
        '-',
        '-',
      ]);
    });

    test('a dotted eighth + sixteenth hooks the sixteenth backwards', () {
      // The fiddle-tune rhythm. The second beam belongs to the 16th alone, so
      // it is a hook — a bare `2:begin` with no `2:end` would be malformed.
      final xml = _score('<measure number="1">'
          '${_note('eighth', dot: true)}${_note('16th')}'
          '${_note('half')}${_note('quarter')}</measure>');
      expect(_rebeamed(xml),
          ['1:begin', '1:end,2:backward hook', '-', '-']);
    });

    test('a sixteenth + dotted eighth hooks it forwards', () {
      final xml = _score('<measure number="1">'
          '${_note('16th')}${_note('eighth', dot: true)}'
          '${_note('half')}${_note('quarter')}</measure>');
      expect(_rebeamed(xml),
          ['1:begin,2:forward hook', '1:end', '-', '-']);
    });
  });

  group('notes that take no beam', () {
    test('a chord member shares the primary note\'s stem', () {
      // Two eighths, the first a two-note stack. The stack takes one beam, on
      // the primary note; and the member must not advance the position, or
      // everything after it would be measured a note too late.
      final xml = _score('<measure number="1">'
          '${_note('eighth')}${_note('eighth', chord: true)}${_note('eighth')}'
          '${_note('half')}${_note('quarter')}</measure>');
      expect(_rebeamed(xml), ['1:begin', '-', '1:end', '-', '-']);
    });

    test('a grace note is passed over without disturbing the beat', () {
      final xml = _score('<measure number="1">'
          '${_note('eighth')}${_grace('eighth')}${_note('eighth')}'
          '${_note('half')}${_note('quarter')}</measure>');
      expect(_rebeamed(xml), ['1:begin', '-', '1:end', '-', '-']);
    });
  });

  group('the meter decides where a group ends', () {
    test('cut time beams a whole half-note beat', () {
      // 2/2's beat *is* the span, so all four run together — which is what
      // Gossec's Gavotte, 17 Gavotte and 10 Allegretto all do (34/34 groups).
      final xml = _score(
          '<measure number="1">'
          '${_note('eighth') * 4}${_note('half')}</measure>',
          beats: 2,
          beatType: 2);
      expect(_rebeamed(xml),
          ['1:begin', '1:continue', '1:continue', '1:end', '-']);
    });

    test('6/8 beams a whole dotted beat', () {
      final xml = _score(
          '<measure number="1">'
          '${_note('eighth')}${_note('eighth')}${_note('eighth')}'
          '${_note('eighth')}${_note('eighth')}${_note('eighth')}</measure>',
          beats: 6,
          beatType: 8);
      expect(_rebeamed(xml), [
        '1:begin', '1:continue', '1:end', //
        '1:begin', '1:continue', '1:end',
      ]);
    });
  });

  group('a measure that states its own beaming is untouched', () {
    test('one beam anywhere in the bar gates the whole bar', () {
      // An engraver who beamed the first pair and deliberately left the second
      // alone gets to keep that decision.
      final xml = _score('<measure number="1">'
          '${_note('eighth', extra: '<beam number="1">begin</beam>')}'
          '${_note('eighth', extra: '<beam number="1">end</beam>')}'
          '${_note('eighth')}${_note('eighth')}${_note('half')}</measure>');
      expect(MusicXmlBeamer.rebeam(xml), xml);
    });

    test('the gate is per measure, not per document', () {
      final xml = _score('<measure number="1">'
              '${_note('eighth', extra: '<beam number="1">begin</beam>')}'
              '${_note('eighth', extra: '<beam number="1">end</beam>')}'
              '${_note('half')}${_note('quarter')}</measure>'
              '<measure number="2">'
              '${_note('eighth')}${_note('eighth')}'
              '${_note('half')}${_note('quarter')}</measure>');
      final out = MusicXmlBeamer.rebeam(xml);
      final second = XmlDocument.parse(out).findAllElements('measure').last;
      expect(second.findElements('note').first.findElements('beam').single.innerText,
          'begin');
    });

    test('every bundled fixture comes back byte-identical', () {
      // They were all written by an engraver or a converter that beams as the
      // tune was typed; the rule only fills silence.
      final fixtures = Directory('assets/fixtures')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.xml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      expect(fixtures, isNotEmpty);
      for (final f in fixtures) {
        final xml = f.readAsStringSync();
        expect(MusicXmlBeamer.rebeam(xml), xml, reason: f.path);
      }
    });
  });

  test('rebeaming twice is the same as rebeaming once', () {
    final xml = _score('<measure number="1">'
        '${_note('16th')}${_note('16th')}${_note('eighth')}'
        '${_note('half')}${_note('quarter')}</measure>');
    final once = MusicXmlBeamer.rebeam(xml);
    expect(MusicXmlBeamer.rebeam(once), once);
  });

  test('an unbeamable measure and malformed input are returned as they came',
      () {
    final quarters = _score('<measure number="1">'
        '${_note('quarter')}${_note('quarter')}'
        '${_note('quarter')}${_note('quarter')}</measure>');
    expect(MusicXmlBeamer.rebeam(quarters), quarters);
    expect(MusicXmlBeamer.rebeam('not xml at all'), 'not xml at all');
  });
}
