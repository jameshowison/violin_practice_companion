import '../models/note_event.dart';
import '../models/parsed_piece.dart';

class PaletteXmlGenerator {
  static const _lhColor = '#FF9000';
  static const _chromColor = '#4488FF';

  static const _majorTonicPc = {
    -4: 8, -3: 3, -2: 10, -1: 5, 0: 0, 1: 7, 2: 2, 3: 9, 4: 4,
  };

  static Set<int> _keyPitchClasses(int fifths, KeyMode mode) {
    final maj = _majorTonicPc[fifths] ?? 0;
    final tonic = mode == KeyMode.minor ? (maj + 9) % 12 : maj;
    final intervals = mode == KeyMode.minor
        ? [0, 2, 3, 5, 7, 8, 10]
        : [0, 2, 4, 5, 7, 9, 11];
    return {for (final i in intervals) (tonic + i) % 12};
  }

  static ({String step, int alter, int octave}) _parsePitch(String pitch) {
    final m = RegExp(r'^([A-G])([#b]?)(\d)$').firstMatch(pitch);
    if (m == null) return (step: 'C', alter: 0, octave: 4);
    final alter = m.group(2) == '#'
        ? 1
        : m.group(2) == 'b'
            ? -1
            : 0;
    return (step: m.group(1)!, alter: alter, octave: int.parse(m.group(3)!));
  }

  static String _noteXml(NoteEvent ne, String colorAttr) {
    final p = _parsePitch(ne.pitch);
    final alterEl = p.alter != 0 ? '<alter>${p.alter}</alter>' : '';
    final hasLabel = ne.fingerString != null && ne.fingerNumber != null;
    final fingEl = hasLabel
        ? '<notations><technical>'
            '<fingering placement="above">'
            '${ne.fingerString}${ne.fingerNumber}'
            '</fingering>'
            '</technical></notations>'
        : '';
    return '<note$colorAttr>'
        '<pitch>'
        '<step>${p.step}</step>'
        '$alterEl'
        '<octave>${p.octave}</octave>'
        '</pitch>'
        '<duration>1</duration>'
        '<type>quarter</type>'
        '$fingEl'
        '</note>';
  }

  static String _padRest(int beats) {
    final type = beats == 1
        ? '<type>quarter</type>'
        : beats == 2
            ? '<type>half</type>'
            : '<type>half</type><dot/>';
    return '<note print-object="no"><rest/>'
        '<duration>$beats</duration>'
        '$type'
        '</note>';
  }

  static String generate(ParsedPiece parsed) {
    // Include all non-rest notes, even those missing fingering data.
    final noteByMidi = <int, NoteEvent>{};
    for (final n in parsed.allNotes) {
      if (n.isRest) continue;
      noteByMidi.putIfAbsent(n.midiNumber, () => n);
    }
    if (noteByMidi.isEmpty) return '';

    final sortedMidis = noteByMidi.keys.toList()..sort();
    final keyPcs = _keyPitchClasses(parsed.keyFifths, parsed.keyMode);

    final buf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<score-partwise version="3.1">')
      ..writeln('<part-list>'
          '<score-part id="P1"><part-name/></score-part>'
          '</part-list>')
      ..writeln('<part id="P1">');

    int idx = 0;
    int measureNum = 0;
    while (idx < sortedMidis.length) {
      measureNum++;
      buf.writeln('<measure number="$measureNum">');
      if (measureNum == 1) {
        buf.writeln('<attributes>'
            '<divisions>1</divisions>'
            '<key><fifths>${parsed.keyFifths}</fifths></key>'
            '<time><beats>4</beats><beat-type>4</beat-type></time>'
            '<clef><sign>G</sign><line>2</line></clef>'
            '</attributes>');
      }
      int inMeasure = 0;
      while (idx < sortedMidis.length && inMeasure < 4) {
        final ne = noteByMidi[sortedMidis[idx]]!;
        final fn = ne.fingerNumber;
        final isLH = fn != null && (fn.endsWith('L') || fn.endsWith('H'));
        final isChrom = !keyPcs.contains(ne.midiNumber % 12);
        final colorAttr = isLH
            ? ' color="$_lhColor"'
            : isChrom
                ? ' color="$_chromColor"'
                : '';
        buf.writeln(_noteXml(ne, colorAttr));
        idx++;
        inMeasure++;
      }
      final remaining = 4 - inMeasure;
      if (remaining > 0) buf.writeln(_padRest(remaining));
      buf.writeln('</measure>');
    }

    buf
      ..writeln('</part>')
      ..writeln('</score-partwise>');
    return buf.toString();
  }
}
