import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/measure_xml_editor.dart';
import 'package:xml/xml.dart';

/// The staff's tuplet brackets come from the notes' timing, not from the
/// `<tuplet>` marks a scan wrote (see [MeasureXmlEditor.rebuildTupletBrackets]).
void main() {
  String score(String bar) => '''<?xml version="1.0"?>
<score-partwise><part-list><score-part id="P1"/></part-list><part id="P1">
<measure number="1"><attributes><divisions>6</divisions>
<time><beats>3</beats><beat-type>4</beat-type></time></attributes>
$bar</measure></part></score-partwise>''';

  const tm = '<time-modification><actual-notes>3</actual-notes>'
      '<normal-notes>2</normal-notes></time-modification>';
  String eighth(String step, {String notations = '', String extra = ''}) =>
      '<note>$extra<pitch><step>$step</step><octave>4</octave></pitch>'
      '<duration>2</duration><type>eighth</type>$tm'
      '${notations.isEmpty ? '' : '<notations>$notations</notations>'}</note>';
  String quarter(String step, {String notations = ''}) =>
      '<note><pitch><step>$step</step><octave>4</octave></pitch>'
      '<duration>6</duration><type>quarter</type>'
      '${notations.isEmpty ? '' : '<notations>$notations</notations>'}</note>';
  const start = '<tuplet type="start"/>';
  const stop = '<tuplet type="stop"/>';

  /// Each note's tuplet marks, in order: 's', 'e', 'se' or ''.
  List<String> marks(String xml) => [
        for (final n in XmlDocument.parse(xml).findAllElements('note'))
          n
              .findAllElements('tuplet')
              .map((t) => t.getAttribute('type') == 'start' ? 's' : 'e')
              .join(),
      ];

  test('a stop on the note after the triplet moves back onto it', () {
    // Minuet 2's scanned bars: three triplet eighths, the stop on the quarter.
    final xml = score(eighth('A', notations: start) +
        eighth('B') +
        eighth('C') +
        quarter('D', notations: '<slur type="start"/>$stop') +
        quarter('F'));
    final out = MeasureXmlEditor.rebuildTupletBrackets(xml);
    expect(marks(out), ['s', '', 'e', '', '']);
    // A start that stated no bracket draws one, as Save writes it.
    expect(
        XmlDocument.parse(out)
            .findAllElements('tuplet')
            .first
            .getAttribute('bracket'),
        'yes');
    // The quarter keeps its slur.
    expect(XmlDocument.parse(out).findAllElements('slur'), hasLength(1));
  });

  test('a start stating no bracket gets one even where the marks agree', () {
    final xml = score(eighth('A', notations: start) +
        eighth('B') +
        eighth('C', notations: stop) +
        quarter('D') +
        quarter('F'));
    final out = MeasureXmlEditor.rebuildTupletBrackets(xml);
    expect(marks(out), ['s', '', 'e', '', '']);
    expect(XmlDocument.parse(out).findAllElements('tuplet').first.getAttribute('bracket'),
        'yes');
  });

  test('brackets that already agree leave the xml as it was', () {
    final xml = score(eighth('A', notations: '<tuplet type="start" bracket="no"/>') +
        eighth('B') +
        eighth('C', notations: stop) +
        quarter('D') +
        quarter('F'));
    expect(MeasureXmlEditor.rebuildTupletBrackets(xml), same(xml));
  });

  test('one bracket over six triplet eighths becomes two, keeping its look',
      () {
    final xml = score(
        eighth('A', notations: '<tuplet type="start" bracket="no"/>') +
            eighth('B') +
            eighth('C') +
            eighth('D') +
            eighth('E') +
            eighth('F', notations: stop) +
            quarter('G'));
    final out = MeasureXmlEditor.rebuildTupletBrackets(xml);
    expect(marks(out), ['s', '', 'e', 's', '', 'e', '']);
    // The first group's start was the scan's: its bracket="no" stays.
    final starts = XmlDocument.parse(out)
        .findAllElements('tuplet')
        .where((t) => t.getAttribute('type') == 'start')
        .toList();
    expect(starts.first.getAttribute('bracket'), 'no');
    expect(starts.last.getAttribute('bracket'), 'yes');
  });

  test('a bracket with no tuplet under it goes, and its empty notations', () {
    final xml = score(quarter('A', notations: start) +
        quarter('B') +
        quarter('C', notations: stop));
    final out = MeasureXmlEditor.rebuildTupletBrackets(xml);
    expect(marks(out), ['', '', '']);
    expect(XmlDocument.parse(out).findAllElements('notations'), isEmpty);
  });

  test('marks are written where none were, and never on a chord member', () {
    final xml = score(eighth('A') +
        eighth('B') +
        eighth('C') +
        eighth('E', extra: '<chord/>') +
        quarter('D') +
        quarter('F'));
    expect(marks(MeasureXmlEditor.rebuildTupletBrackets(xml)),
        ['s', '', 'e', '', '', '']);
  });
}
