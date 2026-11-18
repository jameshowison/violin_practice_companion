import 'package:xml/xml.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';

class MusicXmlParser {
  /// The score's own title — `<work-title>`, falling back to `<movement-title>`.
  /// Null when absent, blank, or the XML doesn't parse.
  ///
  /// Used to recover a piece's name from the file itself when the piece index is
  /// missing or incomplete, so the index is a rebuildable cache rather than the
  /// only record of a song's title. See `piece_storage_io.dart`.
  static String? titleOf(String xmlString) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlString);
    } catch (_) {
      return null;
    }
    for (final tag in const ['work-title', 'movement-title']) {
      final text = doc.findAllElements(tag).firstOrNull?.innerText.trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  ParsedPiece parse(String xmlString) {
    final doc = XmlDocument.parse(xmlString);

    final keyEl = doc.findAllElements('key').firstOrNull;
    final fifths = int.parse(keyEl?.findElements('fifths').firstOrNull?.innerText ?? '0');
    final keyMode =
        parseKeyMode(keyEl?.findElements('mode').firstOrNull?.innerText);
    final keySignature = keyName(fifths, keyMode);

    final divisions =
        int.tryParse(doc.findAllElements('divisions').firstOrNull?.innerText ?? '') ?? 1;
    // The opening meter: the first `<time>` in the document, which is bar 1's
    // in any well-formed score. A score with none is in 4/4 (MusicXML's
    // reading too). Later `<time>`s are per-bar changes, kept on each
    // measure as [Measure.timeChange].
    final opening = _meterOf(doc.findAllElements('time').firstOrNull) ??
        const Meter(4, 4);
    final beatsPerMeasure = opening.beats;
    final beatType = opening.beatType;

    final measures = <Measure>[];
    var meterInForce = opening;
    // The volta bracket open at this point, if any: its numbers, carried from
    // the measure whose `<ending type="start">` opened it to the one whose
    // `stop`/`discontinue` closes it (see [Measure.endings]).
    Set<int>? openEnding;
    for (final measureEl in doc.findAllElements('measure')) {
      meterInForce = _meterOf(measureEl
              .findElements('attributes')
              .expand((a) => a.findElements('time'))
              .firstOrNull) ??
          meterInForce;
      final numberStr = measureEl.getAttribute('number') ?? '1';
      final number = int.tryParse(numberStr) ?? measures.length + 1;
      final notes = <NoteEvent>[];
      final hiddenLeadNotes = <NoteEvent>[];
      bool seenVisibleNote = false;
      // A `<harmony>` applies to the note that follows it (MusicXML places it as
      // a sibling just before its note). Hold it until the next visible note
      // consumes it, so it survives intervening grace/hidden notes.
      String? pendingChord;
      // Rehearsal marks (an ABC tune's `[P:A]`, see abc_to_musicxml.js) and
      // authored line starts, each with the note index it sits before.
      String? partLabel;
      var partLabelNote = 0;
      int? lineStartNote;

      // Iterate children in document order so `<harmony>` and `<note>` interleave
      // correctly; `findElements('note')` would skip the harmony siblings.
      for (final el in measureEl.childElements) {
        if (el.name.local == 'harmony') {
          pendingChord = parseHarmonyLabel(el) ?? pendingChord;
          continue;
        }
        if (el.name.local == 'direction') {
          final types = el.findElements('direction-type');
          final rehearsal =
              types.expand((dt) => dt.findElements('rehearsal')).firstOrNull;
          if (rehearsal != null && rehearsal.innerText.isNotEmpty) {
            partLabel = rehearsal.innerText;
            partLabelNote = notes.length;
          }
          if (types
              .expand((dt) => dt.findElements('other-direction'))
              .any((o) => o.innerText.trim() == 'abc-line')) {
            lineStartNote ??= notes.length;
          }
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
        // A <chord/> child marks a note stacked on the previous note's stem: it
        // shares that note's onset and adds no time (see MidiGenerator).
        final isChord = noteEl.findElements('chord').isNotEmpty;
        // Ties: <tie> is the sounding half, <notations><tied> the engraved arc.
        // Read both, since some exporters write only the arc. A note in the
        // middle of a chain carries a stop and a start.
        final tieTypes = {
          for (final t in noteEl.findElements('tie')) t.getAttribute('type'),
          for (final t in noteEl
              .findElements('notations')
              .expand((n) => n.findElements('tied')))
            t.getAttribute('type'),
        };
        final isRest = noteEl.findElements('rest').isNotEmpty;
        var dotted = noteEl.findElements('dot').isNotEmpty;
        final typeStr = noteEl.findElements('type').firstOrNull?.innerText ?? 'quarter';
        var noteValue = _parseNoteValue(typeStr);
        // A whole-bar rest lasts the bar whatever its <type> says: often none
        // (MuseScore, the scanner's multi-measure rests), or "whole" in 3/4.
        // So it takes the length of the meter in force — not its <duration>,
        // which goes stale when the bar's meter is edited.
        final barRest = _barRestValue(noteEl, meterInForce, divisions);
        if (barRest != null) (noteValue, dotted) = barRest;

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

        // <lyric number="N"><text>…</text></lyric>, one per verse. A missing
        // number means verse 1 (the MusicXML default).
        final lyrics = <int, Lyric>{};
        for (final lyricEl in noteEl.findElements('lyric')) {
          final verse = int.tryParse(lyricEl.getAttribute('number') ?? '1') ?? 1;
          final text = lyricEl.findElements('text').map((t) => t.innerText).join();
          if (text.isEmpty) continue;
          lyrics[verse] = Lyric(
            text,
            syllabic:
                lyricEl.findElements('syllabic').firstOrNull?.innerText.trim() ??
                    'single',
            extend: lyricEl
                .findElements('extend')
                .any((e) => e.getAttribute('type') != 'stop'),
          );
        }

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
          isChord: isChord,
          lyrics: lyrics,
          tieStart: !isRest && tieTypes.contains('start'),
          tieStop: !isRest && tieTypes.contains('stop'),
          tuplet: _tupletOf(noteEl),
          bowing: isRest ? null : _bowingOf(noteEl),
          carriedNotations: _carriedNotationsOf(noteEl),
        ));
        pendingChord = null;
      }

      // Repeat barlines: <barline><repeat direction="forward|backward"/>.
      // A forward repeat is the start (left, `|:`); a backward repeat is the
      // end (right, `:|`). OMR scans usually omit these — the editor adds them.
      // A right-hand double barline that isn't a repeat is a section break
      // (see [Measure.doubleBarEnd]); the location defaults to right.
      var repeatStart = false;
      var repeatEnd = false;
      var doubleBarEnd = false;
      // Volta brackets: <barline><ending number="1" type="start"/> opens one,
      // type="stop" (closed hook) or "discontinue" (open end) closes it, on
      // this measure or a later one. A new start also closes any still open.
      Set<int>? endings;
      var closesEnding = false;
      for (final barlineEl in measureEl.findElements('barline')) {
        for (final e in barlineEl.findElements('ending')) {
          final type = e.getAttribute('type');
          if (type == 'start') {
            openEnding = _endingNumbers(e.getAttribute('number'));
            endings = openEnding;
          } else if (type == 'stop' || type == 'discontinue') {
            endings ??= openEnding ?? _endingNumbers(e.getAttribute('number'));
            closesEnding = true;
          }
        }
      }
      endings ??= openEnding;
      if (closesEnding) openEnding = null;

      for (final barlineEl in measureEl.findElements('barline')) {
        final dir = barlineEl.findElements('repeat').firstOrNull?.getAttribute('direction');
        if (dir == 'forward') repeatStart = true;
        if (dir == 'backward') repeatEnd = true;
        final style = barlineEl.findElements('bar-style').firstOrNull?.innerText.trim();
        if ((barlineEl.getAttribute('location') ?? 'right') == 'right' &&
            const {'light-light', 'heavy-heavy', 'light-heavy', 'heavy-light'}
                .contains(style)) {
          doubleBarEnd = true;
        }
      }

      // Navigation marks. `<sound>` attributes are the playback meaning; the
      // words are a fallback for a score that has only the text — matched
      // whole, so the "Fine" inside "D.C. al Fine" doesn't mark a Fine.
      bool hasSound(String attr) => measureEl
          .findAllElements('sound')
          .any((s) => s.getAttribute(attr) != null);
      final words = [
        for (final w in measureEl.findAllElements('words'))
          w.innerText.trim().toLowerCase(),
      ];
      bool wordsStart(List<String> prefixes) =>
          words.any((w) => prefixes.any(w.startsWith));
      final daCapo = hasSound('dacapo') || wordsStart(['d.c.', 'da capo']);
      final dalSegno = hasSound('dalsegno') || wordsStart(['d.s.', 'dal segno']);
      final fine = hasSound('fine') ||
          words.any((w) => RegExp(r'^fine\W*$').hasMatch(w));
      final toCoda = hasSound('tocoda') || wordsStart(['to coda']);
      final segno =
          hasSound('segno') || measureEl.findAllElements('segno').isNotEmpty;
      // A `<coda/>` symbol also decorates the To Coda mark itself.
      final coda = hasSound('coda') ||
          (!toCoda && measureEl.findAllElements('coda').isNotEmpty);

      measures.add(Measure(
        number: number,
        notes: notes,
        hiddenLeadNotes: hiddenLeadNotes,
        repeatStart: repeatStart,
        repeatEnd: repeatEnd,
        doubleBarEnd: doubleBarEnd && !repeatEnd,
        daCapo: daCapo,
        dalSegno: dalSegno,
        fine: fine,
        toCoda: toCoda,
        segno: segno,
        coda: coda,
        partLabel: partLabel,
        partLabelNote: partLabelNote,
        lineStartNote: lineStartNote,
        systemStart: measureEl
            .findElements('print')
            .any((p) => p.getAttribute('new-system') == 'yes'),
        timeChange: _meterOf(measureEl
            .findElements('attributes')
            .expand((a) => a.findElements('time'))
            .firstOrNull),
        keyChange: int.tryParse(measureEl
                .findElements('attributes')
                .expand((a) => a.findElements('key'))
                .expand((k) => k.findElements('fifths'))
                .firstOrNull
                ?.innerText
                .trim() ??
            ''),
        endings: endings ?? const {},
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
      markedBpm: markedBpmOf(doc),
    );
  }

  /// The score's first tempo, in quarter notes per minute: the printed
  /// `<metronome>` mark converted from its beat unit, else a sound element's
  /// `tempo` (quarter notes by definition). The printed mark wins because it
  /// is what the player sees; a file can state both and disagree (see
  /// `MusicXmlConsistency`). Null for none, or for a value outside what the
  /// app can play (40–208) — a mark that far out is more likely a typo than a
  /// tempo to practise towards.
  static double? markedBpmOf(XmlDocument doc) {
    double? playable(double? bpm) =>
        bpm != null && bpm >= 40 && bpm <= 208 ? bpm : null;
    for (final m in doc.findAllElements('metronome')) {
      final q = metronomeQuarters(m);
      if (q != null) return playable(q);
    }
    for (final sound in doc.findAllElements('sound')) {
      final t = double.tryParse(sound.getAttribute('tempo') ?? '');
      if (t != null) return playable(t);
    }
    return null;
  }

  /// A printed `<metronome>` mark in quarter notes per minute, or null when it
  /// isn't a plain beat-unit-equals-number mark.
  static double? metronomeQuarters(XmlElement m) {
    final perMinute = double.tryParse(
        m.findElements('per-minute').firstOrNull?.innerText.trim() ?? '');
    final unit = m.findElements('beat-unit').firstOrNull?.innerText.trim();
    if (perMinute == null || unit == null) return null;
    final quarters = const {
      'whole': 4.0,
      'half': 2.0,
      'quarter': 1.0,
      'eighth': 0.5,
      '16th': 0.25,
    }[unit];
    if (quarters == null) return null;
    // Each dot adds half again of the previous value.
    var length = quarters, add = quarters;
    for (final _ in m.findElements('beat-unit-dot')) {
      add /= 2;
      length += add;
    }
    return perMinute * length;
  }

  /// A note's bow direction mark (`<technical><down-bow/>`/`<up-bow/>`).
  /// Should a note carry both, the first written wins.
  static Bowing? _bowingOf(XmlElement note) {
    for (final t in note
        .findElements('notations')
        .expand((n) => n.findElements('technical'))) {
      for (final e in t.childElements) {
        if (e.name.local == 'down-bow') return Bowing.down;
        if (e.name.local == 'up-bow') return Bowing.up;
      }
    }
    return null;
  }

  /// The `<technical>` marks [NoteEvent] models itself, and so leaves out of
  /// [NoteEvent.carriedNotations].
  static const _modelledTechnical = {'fingering', 'up-bow', 'down-bow'};

  /// Every child of the note's `<notations>` that [NoteEvent] doesn't model,
  /// serialized — see [NoteEvent.carriedNotations]. Ties and tuplet brackets
  /// are modelled (and rebuilt from the model), so they stay out; a
  /// `<technical>` is kept with only its unmodelled marks, and dropped when it
  /// has none.
  static List<String> _carriedNotationsOf(XmlElement note) {
    final out = <String>[];
    for (final notations in note.findElements('notations')) {
      for (final child in notations.childElements) {
        switch (child.name.local) {
          case 'tied' || 'tuplet':
            continue;
          case 'technical':
            final rest = child.copy();
            rest.children.removeWhere((c) =>
                c is XmlElement && _modelledTechnical.contains(c.name.local));
            if (rest.childElements.isNotEmpty) out.add(rest.toXmlString());
          default:
            out.add(child.toXmlString());
        }
      }
    }
    return out;
  }

  /// A note's `<time-modification>` as a tuplet ratio; null for none, or for
  /// a 1:1 that changes nothing.
  static ({int actual, int normal})? _tupletOf(XmlElement note) {
    final tm = note.findElements('time-modification').firstOrNull;
    if (tm == null) return null;
    final actual = int.tryParse(
        tm.findElements('actual-notes').firstOrNull?.innerText.trim() ?? '');
    final normal = int.tryParse(
        tm.findElements('normal-notes').firstOrNull?.innerText.trim() ?? '');
    if (actual == null || normal == null || actual < 1 || normal < 1) {
      return null;
    }
    if (actual == normal) return null;
    return (actual: actual, normal: normal);
  }

  /// A `<time>` element's meter; null for none, or one without numbers
  /// (`<senza-misura>`).
  /// The passes an `<ending number="…">` names: `"1"`, `"1, 2"` or `"1,2"`.
  /// An unreadable number counts as a first ending.
  static Set<int> _endingNumbers(String? number) {
    final passes = {
      for (final m in RegExp(r'\d+').allMatches(number ?? ''))
        int.parse(m.group(0)!),
    }..remove(0);
    return passes.isEmpty ? const {1} : Set.unmodifiable(passes);
  }

  static Meter? _meterOf(XmlElement? time) {
    if (time == null) return null;
    final beats =
        int.tryParse(time.findElements('beats').firstOrNull?.innerText.trim() ?? '');
    final beatType = int.tryParse(
        time.findElements('beat-type').firstOrNull?.innerText.trim() ?? '');
    if (beats == null || beatType == null || beats < 1 || beatType < 1) {
      return null;
    }
    return Meter(beats, beatType);
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
  static String? parseHarmonyLabel(XmlElement harmonyEl) {
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

  static String _alterSign(int alter) {
    if (alter > 0) return '#' * alter;
    if (alter < 0) return 'b' * -alter;
    return '';
  }

  static String _kindSuffix(String kind) {
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

  /// The value of a `<rest measure="yes"/>`: a full bar of [meter] (or, if
  /// that has no single (dotted) value, of its `<duration>`). Null when
  /// [noteEl] isn't one or neither length has such a value.
  static (NoteValue, bool)? _barRestValue(
      XmlElement noteEl, Meter meter, int divisions) {
    if (noteEl.findElements('rest').firstOrNull?.getAttribute('measure') != 'yes') {
      return null;
    }
    final d = int.tryParse(
        noteEl.findElements('duration').firstOrNull?.innerText.trim() ?? '');
    return _valueOfSixteenths(meter.units / 2) ??
        (d == null || d <= 0 || divisions <= 0
            ? null
            : _valueOfSixteenths(d * 4 / divisions));
  }

  /// The single note value, plain or dotted, [q] sixteenths long.
  static (NoteValue, bool)? _valueOfSixteenths(num q) {
    return switch (q) {
      16 => (NoteValue.whole, false),
      24 => (NoteValue.whole, true),
      8 => (NoteValue.half, false),
      12 => (NoteValue.half, true),
      4 => (NoteValue.quarter, false),
      6 => (NoteValue.quarter, true),
      2 => (NoteValue.eighth, false),
      3 => (NoteValue.eighth, true),
      _ => null,
    };
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

  /// The MusicXML `<mode>` value as a [KeyMode]. Anything unrecognized (or
  /// absent) is major, matching MusicXML's own default.
  static KeyMode parseKeyMode(String? modeText) =>
      switch (modeText?.trim().toLowerCase()) {
        'minor' || 'aeolian' => KeyMode.minor,
        'dorian' => KeyMode.dorian,
        'phrygian' => KeyMode.phrygian,
        'lydian' => KeyMode.lydian,
        'mixolydian' => KeyMode.mixolydian,
        'locrian' => KeyMode.locrian,
        _ => KeyMode.major,
      };

  static const _majorKeyNames = {
    -7: 'Cb', -6: 'Gb', -5: 'Db', -4: 'Ab', -3: 'Eb', -2: 'Bb', -1: 'F',
    0: 'C', 1: 'G', 2: 'D', 3: 'A', 4: 'E', 5: 'B', 6: 'F#', 7: 'C#',
  };

  /// How far round the circle of fifths this mode's TONIC sits from the
  /// signature's relative major — mixolydian flattens the 7th, so A mixolydian
  /// carries two sharps where A major carries three. Indexed by [KeyMode].
  static const _tonicFifthsOffset = [0, 2, 4, -1, 1, 3, 5];
  static const _modeSuffix = ['', 'dor', 'phr', 'lyd', 'mix', 'm', 'loc'];

  /// Short key name for a signature + mode: `D`, `Am`, `Amix`, `Ddor`. Pass
  /// [KeyMode.major] to get the signature's relative major, which is what the
  /// jianpu numbering treats as `1`.
  static String keyName(int fifths, KeyMode mode) {
    final tonic = _majorKeyNames[fifths + _tonicFifthsOffset[mode.index]];
    if (tonic == null) return mode == KeyMode.minor ? 'Am' : 'C';
    return '$tonic${_modeSuffix[mode.index]}';
  }
}
