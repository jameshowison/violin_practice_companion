import 'package:xml/xml.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';

class MusicXmlParser {
  ParsedPiece parse(String xmlString) {
    final doc = XmlDocument.parse(xmlString);

    final keyEl = doc.findAllElements('key').firstOrNull;
    final fifths = int.parse(keyEl?.findElements('fifths').firstOrNull?.innerText ?? '0');
    final modeStr = keyEl?.findElements('mode').firstOrNull?.innerText ?? 'major';
    final keyMode = modeStr == 'minor' ? KeyMode.minor : KeyMode.major;
    final keySignature = _fifthsToKeyName(fifths, keyMode);

    final measures = <Measure>[];
    for (final measureEl in doc.findAllElements('measure')) {
      final numberStr = measureEl.getAttribute('number') ?? '1';
      final number = int.tryParse(numberStr) ?? measures.length + 1;
      final notes = <NoteEvent>[];

      for (final noteEl in measureEl.findElements('note')) {
        final isRest = noteEl.findElements('rest').isNotEmpty;
        final dotted = noteEl.findElements('dot').isNotEmpty;
        final typeStr = noteEl.findElements('type').firstOrNull?.innerText ?? 'quarter';
        final noteValue = _parseNoteValue(typeStr);

        int midiNumber = 0;
        String pitch = 'R';
        int octave = 4;

        if (!isRest) {
          final pitchEl = noteEl.findElements('pitch').firstOrNull;
          if (pitchEl != null) {
            final step = pitchEl.findElements('step').firstOrNull?.innerText ?? 'C';
            octave = int.tryParse(pitchEl.findElements('octave').firstOrNull?.innerText ?? '4') ?? 4;
            final alter = double.tryParse(pitchEl.findElements('alter').firstOrNull?.innerText ?? '0') ?? 0.0;
            midiNumber = _toMidi(step, octave, alter);
            final alterSuffix = alter > 0 ? '#' : (alter < 0 ? 'b' : '');
            pitch = '$step$alterSuffix$octave';
          }
        }

        int? scoreFinger;
        final fingerEl = noteEl
            .findAllElements('fingering')
            .firstOrNull;
        if (fingerEl != null) {
          scoreFinger = int.tryParse(fingerEl.innerText);
        }

        notes.add(NoteEvent(
          pitch: pitch,
          midiNumber: midiNumber,
          octave: octave,
          noteValue: noteValue,
          dotted: dotted,
          isRest: isRest,
          scoreFinger: scoreFinger,
        ));
      }

      measures.add(Measure(number: number, notes: notes));
    }

    return ParsedPiece(
      keySignature: keySignature,
      keyFifths: fifths,
      keyMode: keyMode,
      measures: measures,
    );
  }

  int _toMidi(String step, int octave, double alter) {
    const stepSemitones = {
      'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11,
    };
    final base = (stepSemitones[step] ?? 0) + (octave + 1) * 12;
    return base + alter.round();
  }

  NoteValue _parseNoteValue(String type) {
    switch (type) {
      case 'whole': return NoteValue.whole;
      case 'half': return NoteValue.half;
      case 'eighth': return NoteValue.eighth;
      case '16th': return NoteValue.sixteenth;
      default: return NoteValue.quarter;
    }
  }

  String _fifthsToKeyName(int fifths, KeyMode mode) {
    const majorNames = {
      -4: 'Ab', -3: 'Eb', -2: 'Bb', -1: 'F',
      0: 'C', 1: 'G', 2: 'D', 3: 'A', 4: 'E',
    };
    const minorNames = {
      -4: 'Fm', -3: 'Cm', -2: 'Gm', -1: 'Dm',
      0: 'Am', 1: 'Em', 2: 'Bm', 3: 'F#m', 4: 'C#m',
    };
    if (mode == KeyMode.minor) return minorNames[fifths] ?? 'Am';
    return majorNames[fifths] ?? 'C';
  }
}
