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

    final divisions =
        int.tryParse(doc.findAllElements('divisions').firstOrNull?.innerText ?? '') ?? 1;
    final timeEl = doc.findAllElements('time').firstOrNull;
    final beatsPerMeasure =
        int.tryParse(timeEl?.findElements('beats').firstOrNull?.innerText ?? '') ?? 4;
    final beatType =
        int.tryParse(timeEl?.findElements('beat-type').firstOrNull?.innerText ?? '') ?? 4;

    final measures = <Measure>[];
    for (final measureEl in doc.findAllElements('measure')) {
      final numberStr = measureEl.getAttribute('number') ?? '1';
      final number = int.tryParse(numberStr) ?? measures.length + 1;
      final notes = <NoteEvent>[];
      final hiddenLeadNotes = <NoteEvent>[];
      bool seenVisibleNote = false;
      // A `<harmony>` applies to the note that follows it (MusicXML places it as
      // a sibling just before its note). Hold it until the next visible note
      // consumes it, so it survives intervening grace/hidden notes.
      String? pendingChord;

      // Iterate children in document order so `<harmony>` and `<note>` interleave
      // correctly; `findElements('note')` would skip the harmony siblings.
      for (final el in measureEl.childElements) {
        if (el.name.local == 'harmony') {
          pendingChord = _parseHarmony(el) ?? pendingChord;
          continue;
        }
        if (el.name.local != 'note') continue;
        final noteEl = el;
        if (noteEl.findElements('grace').isNotEmpty) continue;
        final isHidden = noteEl.getAttribute('print-object') == 'no';
        if (isHidden && !seenVisibleNote) {
          // Collect hidden notes that precede the first visible note so the
          // generator can advance timing past them (e.g. pickup measure rests).
          final typeStr = noteEl.findElements('type').firstOrNull?.innerText ?? 'quarter';
          final dotted = noteEl.findElements('dot').isNotEmpty;
          final isRest = noteEl.findElements('rest').isNotEmpty;
          hiddenLeadNotes.add(NoteEvent(
            pitch: 'R',
            midiNumber: 0,
            octave: 4,
            noteValue: _parseNoteValue(typeStr),
            dotted: dotted,
            isRest: isRest,
            scoreFinger: null,
          ));
          continue;
        }
        if (isHidden) continue;
        seenVisibleNote = true;
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

        // The visible accidental sign (may be redundant with the key sig, e.g.
        // a courtesy natural). Kept separate from the sounding alter so the
        // editor can render and clear it. Empty/whitespace → null.
        final accidentalText =
            noteEl.findElements('accidental').firstOrNull?.innerText.trim();
        final displayAccidental =
            (accidentalText == null || accidentalText.isEmpty)
                ? null
                : accidentalText;

        notes.add(NoteEvent(
          pitch: pitch,
          midiNumber: midiNumber,
          octave: octave,
          noteValue: noteValue,
          dotted: dotted,
          isRest: isRest,
          scoreFinger: scoreFinger,
          displayAccidental: displayAccidental,
          chordSymbol: pendingChord,
        ));
        pendingChord = null;
      }

      // Repeat barlines: <barline><repeat direction="forward|backward"/>.
      // A forward repeat is the start (left, `|:`); a backward repeat is the
      // end (right, `:|`). OMR scans usually omit these — the editor adds them.
      var repeatStart = false;
      var repeatEnd = false;
      for (final barlineEl in measureEl.findElements('barline')) {
        final dir = barlineEl.findElements('repeat').firstOrNull?.getAttribute('direction');
        if (dir == 'forward') repeatStart = true;
        if (dir == 'backward') repeatEnd = true;
      }

      measures.add(Measure(
        number: number,
        notes: notes,
        hiddenLeadNotes: hiddenLeadNotes,
        repeatStart: repeatStart,
        repeatEnd: repeatEnd,
      ));
    }

    return ParsedPiece(
      keySignature: keySignature,
      keyFifths: fifths,
      keyMode: keyMode,
      measures: measures,
      divisions: divisions,
      beatsPerMeasure: beatsPerMeasure,
      beatType: beatType,
    );
  }

  int _toMidi(String step, int octave, double alter) {
    const stepSemitones = {
      'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11,
    };
    final base = (stepSemitones[step] ?? 0) + (octave + 1) * 12;
    return base + alter.round();
  }

  /// Builds a chord display string from a MusicXML `<harmony>` element, e.g.
  /// `'A'`, `'E7'`, `'Am7'`, `'D/F#'`. Returns null if there's no usable root.
  String? _parseHarmony(XmlElement harmonyEl) {
    final rootEl = harmonyEl.findElements('root').firstOrNull;
    final rootStep = rootEl?.findElements('root-step').firstOrNull?.innerText;
    if (rootStep == null || rootStep.isEmpty) return null;
    final rootAlter =
        int.tryParse(rootEl?.findElements('root-alter').firstOrNull?.innerText ?? '') ?? 0;

    final kindEl = harmonyEl.findElements('kind').firstOrNull;
    // The `text` attribute is the engraver-preferred suffix; fall back to a
    // mapping of the canonical kind value.
    final kindText = kindEl?.getAttribute('text');
    final suffix = (kindText != null && kindText.isNotEmpty)
        ? kindText
        : _kindSuffix(kindEl?.innerText ?? 'major');

    var label = '$rootStep${_alterSign(rootAlter)}$suffix';

    final bassEl = harmonyEl.findElements('bass').firstOrNull;
    final bassStep = bassEl?.findElements('bass-step').firstOrNull?.innerText;
    if (bassStep != null && bassStep.isNotEmpty) {
      final bassAlter =
          int.tryParse(bassEl?.findElements('bass-alter').firstOrNull?.innerText ?? '') ?? 0;
      label = '$label/$bassStep${_alterSign(bassAlter)}';
    }
    return label;
  }

  String _alterSign(int alter) {
    if (alter > 0) return '#' * alter;
    if (alter < 0) return 'b' * -alter;
    return '';
  }

  String _kindSuffix(String kind) {
    switch (kind) {
      case 'major': return '';
      case 'minor': return 'm';
      case 'augmented': return 'aug';
      case 'diminished': return 'dim';
      case 'dominant': return '7';
      case 'major-seventh': return 'maj7';
      case 'minor-seventh': return 'm7';
      case 'diminished-seventh': return 'dim7';
      case 'half-diminished': return 'm7b5';
      case 'major-sixth': return '6';
      case 'minor-sixth': return 'm6';
      case 'dominant-ninth': return '9';
      case 'suspended-second': return 'sus2';
      case 'suspended-fourth': return 'sus4';
      case 'power': return '5';
      case 'none': return '';
      default: return kind; // best-effort for unmapped kinds
    }
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
