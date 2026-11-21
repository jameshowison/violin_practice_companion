import 'package:test/test.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:xml/xml.dart';

/// Facts MusicXML states twice, settled in favour of the copy the app reads
/// (see [MusicXmlConsistency]).
void main() {
  String score(String bars, {int divisions = 2}) => '''<?xml version="1.0"?>
<score-partwise><part-list><score-part id="P1"/></part-list><part id="P1">
<measure number="1"><attributes><divisions>$divisions</divisions>
<time><beats>2</beats><beat-type>4</beat-type></time></attributes>
$bars</measure></part></score-partwise>''';
  String note(String step,
          {int duration = 2,
          String type = 'quarter',
          String afterDuration = '',
          String notations = ''}) =>
      '<note><pitch><step>$step</step><octave>4</octave></pitch>'
      '<duration>$duration</duration>$afterDuration<type>$type</type>'
      '${notations.isEmpty ? '' : '<notations>$notations</notations>'}</note>';

  XmlDocument parse(String xml) => XmlDocument.parse(xml);
  List<String> kinds(String xml) =>
      MusicXmlConsistency.check(xml).map((i) => i.kind).toList();

  test('a consistent file comes back unchanged, and checks clean', () {
    final xml = score(note('C') +
        note('D', afterDuration: '<tie type="start"/>',
            notations: '<tied type="start"/><slur type="start"/>') +
        '</measure><measure number="2">' +
        note('D', afterDuration: '<tie type="stop"/>',
            notations: '<tied type="stop"/><slur type="stop"/>') +
        note('E'));
    expect(MusicXmlConsistency.repair(xml), same(xml));
    expect(MusicXmlConsistency.check(xml), isEmpty);
  });

  test('a duration that disagrees with the note type follows the type', () {
    // A quarter at 2 divisions is 2; the scan said 3.
    final xml = score(note('C', duration: 3) + note('D'));
    expect(kinds(xml), ['duration']);
    final out = MusicXmlConsistency.repair(xml);
    expect(parse(out).findAllElements('duration').map((d) => d.innerText),
        ['2', '2']);
    expect(MusicXmlConsistency.check(out), isEmpty);
  });

  test('a bar with several voices is reported, not repaired', () {
    final xml = score(note('C', duration: 3) +
        '<backup><duration>4</duration></backup>' +
        note('E') +
        note('F'));
    expect(kinds(xml), ['duration']);
    expect(MusicXmlConsistency.repair(xml), same(xml));
  });

  test('a tie gets the half it lacks: the arc, or the tie heard', () {
    final heardOnly = score(note('C', afterDuration: '<tie type="start"/>') +
        note('C', afterDuration: '<tie type="stop"/>'));
    final drawnOnly = score(note('C', notations: '<tied type="start"/>') +
        note('C', notations: '<tied type="stop"/>'));
    for (final xml in [heardOnly, drawnOnly]) {
      expect(kinds(xml), ['tie', 'tie']);
      final out = parse(MusicXmlConsistency.repair(xml));
      final notes = out.findAllElements('note').toList();
      for (final (i, t) in [(0, 'start'), (1, 'stop')]) {
        expect(notes[i].findElements('tie').single.getAttribute('type'), t);
        expect(notes[i].findAllElements('tied').single.getAttribute('type'), t);
      }
      // <tie> sits after <duration>, where MusicXML puts it.
      final names = notes[0].childElements.map((e) => e.name.local).toList();
      expect(names.indexOf('tie'), names.indexOf('duration') + 1);
    }
  });

  test('an unpaired slur end goes, with the notations it emptied', () {
    final xml = score(note('C', notations: '<slur type="stop"/>') +
        note('D', notations: '<slur type="start"/>') +
        '</measure><measure number="2">' +
        note('E', notations: '<slur type="stop"/>') +
        note('F'));
    expect(kinds(xml), ['slur']);
    final out = parse(MusicXmlConsistency.repair(xml));
    final notes = out.findAllElements('note').toList();
    expect(notes[0].findElements('notations'), isEmpty);
    expect(out.findAllElements('slur'), hasLength(2));
  });

  test('an unpaired wedge goes, with its direction', () {
    const cresc = '<direction><direction-type><wedge type="crescendo"/>'
        '</direction-type></direction>';
    final xml = score(cresc + note('C') + note('D'));
    expect(kinds(xml), ['wedge']);
    final out = parse(MusicXmlConsistency.repair(xml));
    expect(out.findAllElements('direction'), isEmpty);
  });

  test('the printed tempo mark wins over the tempo played', () {
    const mark = '<direction><direction-type><metronome>'
        '<beat-unit>quarter</beat-unit><per-minute>100</per-minute>'
        '</metronome></direction-type><sound tempo="116"/></direction>';
    final xml = score(mark + note('C') + note('D'));
    expect(kinds(xml), ['tempo']);
    // The parser already reads the mark, before any repair.
    expect(MusicXmlParser().parse(xml).markedBpm, 100);
    final out = MusicXmlConsistency.repair(xml);
    expect(parse(out).findAllElements('sound').single.getAttribute('tempo'),
        '100');
  });

  test('a bracket that disagrees with the timing is reported', () {
    const tm = '<time-modification><actual-notes>3</actual-notes>'
        '<normal-notes>2</normal-notes></time-modification>';
    String eighth(String s, [String n = '']) =>
        '<note><pitch><step>$s</step><octave>4</octave></pitch>'
        '<duration>1</duration><type>eighth</type>$tm'
        '${n.isEmpty ? '' : '<notations>$n</notations>'}</note>';
    final xml = score(
        eighth('C', '<tuplet type="start" bracket="yes"/>') +
            eighth('D') +
            eighth('E') +
            note('F', duration: 3, notations: '<tuplet type="stop"/>'),
        divisions: 3);
    final found = MusicXmlConsistency.check(xml);
    expect(found.map((i) => i.kind), ['tuplet']);
    expect(found.single.measure, '1');
    expect(MusicXmlConsistency.check(MusicXmlConsistency.repair(xml)), isEmpty);
  });

  test('a note value the app can\'t count is reported, a 32nd isn\'t', () {
    String short(String type, {String dot = '', int duration = 1}) =>
        '<note><pitch><step>D</step><octave>4</octave></pitch>'
        '<duration>$duration</duration><type>$type</type>$dot</note>';
    // 16 divisions a quarter: a 64th is 1, a 32nd 2, a dotted 32nd 3.
    final sixtyFourth = score(note('C', duration: 16) + short('64th'),
        divisions: 16);
    final dotted = score(
        note('C', duration: 16) + short('32nd', dot: '<dot/>', duration: 3),
        divisions: 16);
    final plain = score(note('C', duration: 16) + short('32nd', duration: 2),
        divisions: 16);
    expect(kinds(sixtyFourth), ['note-value']);
    expect(kinds(dotted), ['note-value']);
    expect(kinds(plain), isEmpty);
    expect(MusicXmlConsistency.repair(sixtyFourth), same(sixtyFourth));
    // And a 32nd is read as one.
    expect(MusicXmlParser().parse(plain).measures.first.notes.last.noteValue,
        NoteValue.thirtySecond);
  });

  test('a measure number used twice is reported and left alone', () {
    final xml = score('${note('C')}${note('D')}</measure><measure number="1">'
        '${note('E')}${note('F')}');
    expect(kinds(xml), ['measure-number']);
    expect(MusicXmlConsistency.repair(xml), same(xml));
  });
}
