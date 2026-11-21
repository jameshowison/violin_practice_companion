import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:test/test.dart';

/// A one-bar score whose first `<attributes>` carries [attributes].
String _score(String attributes, {String more = ''}) => '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>Part</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>1</divisions>
        <key><fifths>0</fifths></key>
        <time><beats>4</beats><beat-type>4</beat-type></time>
        $attributes
      </attributes>
      <note><pitch><step>D</step><octave>4</octave></pitch><duration>4</duration><type>whole</type></note>
    </measure>
  </part>
  $more
</score-partwise>''';

void main() {
  final parser = MusicXmlParser();

  group('openingClef', () {
    test('treble', () {
      final p = parser.parse(_score('<clef><sign>G</sign><line>2</line></clef>'));
      expect(p.openingClef, Clef.treble);
      expect(p.openingClef!.octaveChange, 0);
    });

    test('alto', () {
      final p = parser.parse(_score('<clef><sign>C</sign><line>3</line></clef>'));
      expect(p.openingClef, Clef.alto);
    });

    test('treble-8vb', () {
      final p = parser.parse(_score(
          '<clef><sign>G</sign><line>2</line><clef-octave-change>-1</clef-octave-change></clef>'));
      expect(p.openingClef, const Clef('G', 2, octaveChange: -1));
      expect(p.openingClef, isNot(Clef.treble));
    });

    test('a missing line takes the sign\'s default', () {
      expect(parser.parse(_score('<clef><sign>G</sign></clef>')).openingClef,
          Clef.treble);
      expect(parser.parse(_score('<clef><sign>C</sign></clef>')).openingClef,
          Clef.alto);
      expect(parser.parse(_score('<clef><sign>F</sign><line>x</line></clef>')).openingClef,
          Clef.bass);
    });

    test('none', () {
      expect(parser.parse(_score('')).openingClef, isNull);
    });

    test('a clef with no sign is skipped', () {
      expect(parser.parse(_score('<clef><line>2</line></clef>')).openingClef,
          isNull);
    });

    test('a later part\'s clef does not stand in for the first part\'s', () {
      final p = parser.parse(_score('', more: '''
  <part id="P2">
    <measure number="1">
      <attributes><clef><sign>F</sign><line>4</line></clef></attributes>
    </measure>
  </part>'''));
      expect(p.openingClef, isNull);
    });
  });

  group('openingTranspose', () {
    test('B-flat: diatonic -1, chromatic -2', () {
      final p = parser.parse(_score(
          '<transpose><diatonic>-1</diatonic><chromatic>-2</chromatic></transpose>'));
      final t = p.openingTranspose!;
      expect(t, const Transpose(chromatic: -2, diatonic: -1));
      expect(t.semitones, -2);
      expect(t.soundingMidi(62), 60); // written D4 sounds C4
    });

    test('an octave change', () {
      final p = parser.parse(_score(
          '<transpose><diatonic>0</diatonic><chromatic>0</chromatic>'
          '<octave-change>-1</octave-change></transpose>'));
      final t = p.openingTranspose!;
      expect(t.octaveChange, -1);
      expect(t.semitones, -12);
      expect(t.soundingMidi(64), 52);
    });

    test('octave change and interval together', () {
      const t = Transpose(chromatic: -2, diatonic: -1, octaveChange: -1);
      expect(t.semitones, -14); // a bass clarinet
    });

    test('none', () {
      expect(parser.parse(_score('')).openingTranspose, isNull);
    });

    test('malformed values are skipped, not thrown', () {
      expect(
          parser
              .parse(_score('<transpose><diatonic>-1</diatonic></transpose>'))
              .openingTranspose,
          isNull);
      expect(
          parser
              .parse(_score('<transpose><chromatic>abc</chromatic></transpose>'))
              .openingTranspose,
          isNull);
      expect(
          parser
              .parse(_score(
                  '<transpose><diatonic>?</diatonic><chromatic>-3</chromatic></transpose>'))
              .openingTranspose,
          const Transpose(chromatic: -3));
    });
  });

  test('copies carry the clef and transpose', () {
    final p = parser.parse(_score(
        '<clef><sign>C</sign><line>3</line></clef>'
        '<transpose><diatonic>-1</diatonic><chromatic>-2</chromatic></transpose>'));
    final copy = p.copyWithMeasures(p.measures);
    expect(copy.openingClef, Clef.alto);
    expect(copy.openingTranspose, const Transpose(chromatic: -2, diatonic: -1));
    final changed = p.copyWithTimeChangeAt(0, const Meter(3, 4));
    expect(changed.openingClef, Clef.alto);
    expect(changed.openingTranspose, isNotNull);
  });
}
